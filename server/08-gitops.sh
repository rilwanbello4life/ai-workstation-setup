#!/usr/bin/env bash
# Phase 20 - GitOps: Argo CD, a Helm source tree and a rendered destination.
#
# Two directories and one rule. You edit charts in /srv/gitops/source, a
# render turns them into plain Kubernetes objects in /srv/gitops/rendered,
# and Argo CD applies whatever is in rendered. Edit either side; both end up
# in the cluster.
#
# Argo CD cannot watch a directory - it reads git, a Helm repo or OCI and
# nothing else - so the destination has a bare repository behind it, served
# read-only to the cluster by git-daemon on the cni0 address. A private
# GitHub repo can be added as a push mirror, which is backup and history
# rather than the source of truth: a dead internet connection must never be
# able to stop a deploy on a machine sitting in the same room.
#
# The existing platform manifests are ADOPTED rather than reapplied. The
# chart in source/platform renders to exactly what 03-platform.sh already
# put in the cluster, which is checked before anything is handed over.
#
# Read-only by default. Pass --apply to make changes.
#
# Background: reference/gitops.md

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root
require_k3s

APPLY=no
WATCH=no
MIRROR=""
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-}"

while (( $# )); do
    case "$1" in
        --apply)   APPLY=yes; shift ;;
        --watch)   WATCH=yes; shift ;;
        --mirror)  MIRROR="${2:?--mirror needs a git URL}"; shift 2 ;;
        -y|--yes)  APPLY=yes; shift ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

GITOPS_DIR="${GITOPS_DIR:-/srv/gitops}"
GITOPS_BARE="${GITOPS_BARE:-/srv/gitops.git}"
SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gitops"
ARGO_NS=argocd

changed=0
note_change() { changed=$((changed + 1)); }

if [[ "$APPLY" != yes ]]; then
    warn "Read-only. Re-run with --apply to make these changes."
    echo
fi

# ---------------------------------------------------------------------------
section "Prerequisites"

# The host address as seen from pods: the cni0 gateway, normally 10.42.0.1.
# Same value 02-k3s.sh uses for the model services.
HOST_IP="$(ip -4 addr show cni0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
[[ -n "$HOST_IP" ]] || HOST_IP="10.42.0.1"
export HOST_IP
info "Pods reach the host at $HOST_IP"

if have helm; then
    ok "helm present ($(helm version --short 2>/dev/null))"
elif [[ "$APPLY" == yes ]]; then
    info "Installing helm."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | sudo bash >/dev/null 2>&1 || die "helm install failed."
    ok "helm installed ($(helm version --short 2>/dev/null))"
    note_change
else
    todo "helm is not installed. --apply installs it."
fi

for tool in git envsubst; do
    if have "$tool"; then
        ok "$tool present"
    elif [[ "$APPLY" == yes ]]; then
        pkg="$tool"; [[ "$tool" == envsubst ]] && pkg=gettext-base
        sudo apt-get install -y "$pkg" >/dev/null && ok "Installed $pkg" && note_change
    else
        todo "$tool is missing."
    fi
done

# git-daemon ships separately from git on Debian and Ubuntu, and its absence
# only shows up later as a systemd unit that exits 127.
if dpkg -s git-daemon-sysvinit >/dev/null 2>&1 || [[ -x /usr/lib/git-core/git-daemon ]]; then
    ok "git-daemon present"
elif [[ "$APPLY" == yes ]]; then
    sudo apt-get install -y git-daemon-sysvinit >/dev/null 2>&1 \
        && ok "Installed git-daemon" && note_change \
        || warn "Could not install git-daemon-sysvinit; git daemon may not start."
else
    todo "git-daemon is missing."
fi

[[ "$APPLY" == yes ]] || { warn "Stopping here. Re-run with --apply."; exit 0; }

# ---------------------------------------------------------------------------
section "The repository"

# Bare repo first: the working tree needs somewhere to push.
if [[ -d "$GITOPS_BARE" ]]; then
    ok "Bare repo exists at $GITOPS_BARE"
else
    sudo mkdir -p "$GITOPS_BARE"
    sudo chown -R "$USER:$USER" "$GITOPS_BARE"
    # '-c init.defaultBranch=main' rather than '--initial-branch', which
    # needs git 2.28. It also suppresses the twelve-line hint git prints
    # when the default is unconfigured - noise that buries real output.
    # The symbolic-ref is the belt to that braces on git older than 2.28.
    git -c init.defaultBranch=main init --bare "$GITOPS_BARE" >/dev/null
    git -C "$GITOPS_BARE" symbolic-ref HEAD refs/heads/main
    ok "Created $GITOPS_BARE"
    note_change
fi

# Only repositories carrying this marker are served. git-daemon is started
# without --export-all precisely so that a future git repo created anywhere
# else under /srv is not published to the cluster by accident.
touch "$GITOPS_BARE/git-daemon-export-ok"

if [[ -d "$GITOPS_DIR/.git" ]]; then
    ok "Working tree exists at $GITOPS_DIR"
else
    sudo mkdir -p "$GITOPS_DIR"
    sudo chown -R "$USER:$USER" "$GITOPS_DIR"
    git -c init.defaultBranch=main init "$GITOPS_DIR" >/dev/null
    git -C "$GITOPS_DIR" symbolic-ref HEAD refs/heads/main
    ok "Created $GITOPS_DIR"
    note_change
fi

# Give the repository its own identity.
#
# Every commit here is made by a script or a systemd timer, not by a person,
# so the author should say that rather than borrow whoever happens to be
# logged in. More immediately: a machine with no global user.email cannot
# commit at all, and git's refusal arrives at the end of a long successful
# run with "Please tell me who you are" and a global config suggestion -
# which is the wrong fix, since this identity should not leak into the
# user's other repositories.
#
# Set unconditionally rather than only on creation: a repo created before
# this existed would otherwise stay broken.
git -C "$GITOPS_DIR" config user.email "gitops@$(hostname -s 2>/dev/null || echo localhost)"
git -C "$GITOPS_DIR" config user.name  "GitOps automation"

mkdir -p "$GITOPS_DIR"/{source,rendered/manual,apps}

# Seed the charts and Applications shipped with the kit. Existing files are
# left alone: re-running this script must never discard a local edit.
copied=0
while IFS= read -r -d '' src; do
    rel="${src#"$SEED_DIR"/}"
    dst="$GITOPS_DIR/$rel"
    [[ "$rel" == "gitignore" ]] && dst="$GITOPS_DIR/.gitignore"
    if [[ ! -f "$dst" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        copied=$((copied + 1))
    fi
done < <(find "$SEED_DIR" -type f -print0)
(( copied )) && { ok "Seeded $copied file(s) from the kit."; note_change; } \
             || ok "Charts and Applications already present."

# hostIP is the one value that cannot be shipped correct, because it depends
# on the pod CIDR this cluster came up with.
values="$GITOPS_DIR/source/platform/values.yaml"
if [[ -f "$values" ]] && ! grep -q "hostIP: \"$HOST_IP\"" "$values"; then
    sed -i "s|^hostIP: .*|hostIP: \"$HOST_IP\"|" "$values"
    ok "Set hostIP to $HOST_IP in the platform chart."
    note_change
fi

cat > "$GITOPS_DIR/rendered/manual/README.md" <<'MANUAL_EOF'
# Hand-written manifests

`gitops render` never touches this directory, so anything here survives a
render. Use it for one-off objects that do not justify a chart.

Nothing applies this directory until an Application points at it. To add one,
copy `apps/platform.yaml` to `apps/manual.yaml`, set `path: rendered/manual`,
and commit.
MANUAL_EOF

if [[ -n "$MIRROR" ]]; then
    if git -C "$GITOPS_DIR" remote get-url github >/dev/null 2>&1; then
        git -C "$GITOPS_DIR" remote set-url github "$MIRROR"
    else
        git -C "$GITOPS_DIR" remote add github "$MIRROR"
    fi
    ok "GitHub mirror set to $MIRROR"
    note_change
fi

if git -C "$GITOPS_DIR" remote get-url origin >/dev/null 2>&1; then
    git -C "$GITOPS_DIR" remote set-url origin "$GITOPS_BARE"
else
    git -C "$GITOPS_DIR" remote add origin "$GITOPS_BARE"
fi
ok "origin -> $GITOPS_BARE"

# ---------------------------------------------------------------------------
section "git daemon"

GIT_UNIT=/etc/systemd/system/gitops-git-daemon.service
if [[ -f "$GIT_UNIT" ]] && grep -q "listen=$HOST_IP" "$GIT_UNIT"; then
    ok "gitops-git-daemon already installed."
else
    sudo tee "$GIT_UNIT" >/dev/null <<EOF
[Unit]
Description=Read-only git daemon serving /srv/gitops.git to the cluster
After=k3s.service
Wants=k3s.service

[Service]
Type=simple
User=$USER
# Bound to the cni0 address, never 0.0.0.0: pods can reach it, the LAN
# cannot. No --export-all, so only repositories carrying the marker file
# git-daemon-export-ok are served. No --enable=receive-pack, so nothing
# reachable through this can write.
ExecStart=/usr/lib/git-core/git-daemon \\
  --reuseaddr \\
  --base-path=/srv \\
  --listen=$HOST_IP \\
  --port=9418 \\
  $GITOPS_BARE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now gitops-git-daemon.service
    ok "git daemon serving git://$HOST_IP:9418/gitops.git"
    note_change
fi

apply_manifest "$K8S_DIR/05-gitops-repo.yaml"
ok "Cluster name: git://gitops.$K8S_NS.svc.cluster.local:9418/gitops.git"

# ---------------------------------------------------------------------------
section "Argo CD"

kubectl apply -f "$K8S_DIR/04-argocd.yaml" >/dev/null
ok "Namespace, ResourceQuota and LimitRange applied."

if ! helm repo list 2>/dev/null | grep -q '^argo[[:space:]]'; then
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
fi
helm repo update argo >/dev/null 2>&1 || helm repo update >/dev/null 2>&1

ver_args=()
[[ -n "$ARGOCD_CHART_VERSION" ]] && ver_args=(--version "$ARGOCD_CHART_VERSION")

# Rendered and applied rather than `helm install`, for the same reason the
# platform is: what reaches the cluster should be plain objects you can read.
# Argo CD manages its own upgrades afterwards only if you add an Application
# for it - deliberately not done here, because an Argo CD that can break its
# own controller mid-sync is a bad morning.
info "Rendering the Argo CD chart."
if ! helm template argocd argo/argo-cd \
        --namespace "$ARGO_NS" \
        -f "$K8S_DIR/argocd-values.yaml" \
        "${ver_args[@]}" > /tmp/argocd-render.yaml 2>/tmp/argocd-render.err; then
    sed 's/^/      /' /tmp/argocd-render.err >&2
    die "Could not render the Argo CD chart."
fi

resolved="$(helm show chart argo/argo-cd "${ver_args[@]}" 2>/dev/null \
            | awk '/^version:/{print $2}')"
printf '%s\n' "${resolved:-unknown}" > "$GITOPS_DIR/source/argocd-chart-version.txt"
info "Chart version ${resolved:-unknown} (recorded in the repo)."

# server-side apply: the CRDs in this chart exceed the annotation size limit
# that client-side apply uses to store its last-applied state.
kubectl apply -n "$ARGO_NS" --server-side --force-conflicts \
    -f /tmp/argocd-render.yaml >/dev/null
ok "Argo CD applied."
note_change

info "Waiting for Argo CD to become ready (up to 300s)."
for deploy in argocd-repo-server argocd-server; do
    kubectl -n "$ARGO_NS" rollout status "deploy/$deploy" --timeout=300s >/dev/null 2>&1 \
        && ok "$deploy ready" \
        || warn "$deploy not ready yet. kubectl -n $ARGO_NS get pods"
done
kubectl -n "$ARGO_NS" rollout status statefulset/argocd-application-controller \
    --timeout=300s >/dev/null 2>&1 && ok "argocd-application-controller ready" \
    || warn "argocd-application-controller not ready yet."

ADMIN_PW="$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"

# Copy it next to every other credential on this machine.
#
# Argo CD generates this into a Secret named argocd-initial-admin-secret and
# considers it disposable - the documented flow is that you log in, set your
# own password, and delete it. If you never do, one 'kubectl delete secret'
# or a reinstall takes the only copy of the only password with it.
#
# Keeping it in $SECRETS also means the nightly backup captures it; a
# Kubernetes Secret in argocd is not in the backup set, and would not help
# anyway in the case where you are rebuilding the cluster.
if [[ -n "$ADMIN_PW" && ! -f "$SECRETS/argocd-admin-password" ]]; then
    sudo mkdir -p "$SECRETS"
    printf '%s\n' "$ADMIN_PW" | sudo tee "$SECRETS/argocd-admin-password" >/dev/null
    sudo chmod 600 "$SECRETS/argocd-admin-password"
    ok "Admin password saved to $SECRETS/argocd-admin-password"
elif [[ -f "$SECRETS/argocd-admin-password" ]]; then
    ok "Admin password already stored at $SECRETS/argocd-admin-password"
fi

# ---------------------------------------------------------------------------
section "Loopback access"

# platform-forward already publishes 4000, 5678 and 3000. Argo CD's UI joins
# them on 8090 rather than getting an ingress of its own.
FWD_UNIT=/etc/systemd/system/platform-forward.service
if [[ -f "$FWD_UNIT" ]] && grep -q '8090:80' "$FWD_UNIT"; then
    ok "platform-forward already publishes 8090."
else
    sudo tee "$FWD_UNIT" >/dev/null <<EOF
[Unit]
Description=Expose platform services on loopback
After=k3s.service
Wants=k3s.service

[Service]
Type=simple
User=$USER
Environment=KUBECONFIG=$HOME/.kube/config
# --address 127.0.0.1 is the default but stated explicitly: binding 0.0.0.0
# here would put an unauthenticated gateway on the LAN.
ExecStart=/bin/sh -c '\\
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/litellm 4000:4000 & \\
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/n8n 5678:5678 & \\
  kubectl -n $K8S_NS port-forward --address 127.0.0.1 svc/open-webui 3000:3000 & \\
  kubectl -n $ARGO_NS port-forward --address 127.0.0.1 svc/argocd-server 8090:80 & \\
  wait'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable platform-forward.service >/dev/null 2>&1 || true
    sudo systemctl restart platform-forward.service
    ok "Forwarding 4000, 5678, 3000 and 8090 to loopback."
    note_change
fi

# ---------------------------------------------------------------------------
section "The gitops command"

sudo tee /usr/local/bin/gitops >/dev/null <<'GITOPS_EOF'
#!/usr/bin/env bash
# Drive the deployment pipeline: render charts, commit, and let Argo CD apply.
#
#   gitops status             repo and Application state at a glance
#   gitops render [chart]     helm template source/ -> rendered/
#   gitops diff [chart]       what a render would change, and cluster drift
#   gitops commit [-m msg]    render, commit, push to the bare repo and mirror
#   gitops sync [app]         tell Argo CD to reconcile now
#   gitops apps               Applications with sync and health status
#   gitops automate <app>     turn on auto-sync with self-heal
#   gitops manual <app>       turn auto-sync back off
#   gitops build <chart>      build a local image and import it into k3s
#   gitops pause | resume     stop and start reconciliation
#   gitops log                recent commits
#
# Nothing here prunes. Removing a manifest stops Argo CD managing the object;
# it does not delete it.
set -uo pipefail

DIR="${GITOPS_DIR:-/srv/gitops}"
ARGO_NS="${ARGO_NS:-argocd}"
NS="${K8S_NS:-platform}"
TMP="$DIR/.render-tmp"

if [[ -t 1 ]]; then
  G=$'\033[32m'; Y=$'\033[33m'; E=$'\033[31m'; C=$'\033[36m'; R=$'\033[0m'
else G=''; Y=''; E=''; C=''; R=''; fi
ok()   { printf '  %s[ok]%s %s\n'   "$G" "$R" "$*"; }
warn() { printf '  %s[!!]%s %s\n'   "$Y" "$R" "$*"; }
err()  { printf '  %s[xx]%s %s\n'   "$E" "$R" "$*" >&2; }
sec()  { printf '\n%s=== %s ===%s\n' "$C" "$*" "$R"; }

[[ -d "$DIR" ]] || { err "$DIR does not exist. Run server/08-gitops.sh --apply."; exit 1; }

charts() {
  local c
  for c in "$DIR"/source/*/; do
    [[ -f "$c/Chart.yaml" ]] && basename "$c"
  done
}

render_one() {
  # Split declarations: older bash declares every name in one `local` as
  # unset before assigning, so "$TMP/$name" here would be unbound under -u.
  local name="$1"
  local out="$TMP/$name"
  mkdir -p "$out"
  if ! helm template "$name" "$DIR/source/$name" --namespace "$NS" \
        > "$out/manifests.yaml" 2>"$out/err"; then
    err "render failed: $name"
    sed 's/^/      /' "$out/err" >&2
    return 1
  fi
  return 0
}

# Render into scratch first and only then move results into place, so a chart
# that fails to template cannot leave a half-written manifest behind for Argo
# CD to apply.
do_render() {
  local only="${1-}" rc=0 n
  rm -rf "$TMP"; mkdir -p "$TMP"
  for n in $(charts); do
    [[ -n "$only" && "$n" != "$only" ]] && continue
    render_one "$n" || { rc=1; continue; }
  done
  (( rc == 0 )) || { rm -rf "$TMP"; return 1; }

  for n in $(charts); do
    [[ -n "$only" && "$n" != "$only" ]] && continue
    mkdir -p "$DIR/rendered/$n"
    if [[ -f "$DIR/rendered/$n/manifests.yaml" ]] && \
       ! diff -q "$DIR/rendered/$n/manifests.yaml" "$TMP/$n/manifests.yaml" >/dev/null; then
      ok "changed: rendered/$n/manifests.yaml"
    fi
    cp "$TMP/$n/manifests.yaml" "$DIR/rendered/$n/manifests.yaml"
  done
  rm -rf "$TMP"
  return 0
}

case "${1:-status}" in

  render)
    sec "Render"
    do_render "${2-}" || exit 1
    ok "rendered/ is up to date with source/"
    ;;

  diff)
    sec "Source vs rendered"
    rm -rf "$TMP"; mkdir -p "$TMP"
    any=0
    for n in $(charts); do
      [[ -n "${2-}" && "$n" != "${2-}" ]] && continue
      render_one "$n" || exit 1
      if [[ -f "$DIR/rendered/$n/manifests.yaml" ]]; then
        if diff -u "$DIR/rendered/$n/manifests.yaml" "$TMP/$n/manifests.yaml" \
             --label "rendered/$n" --label "source/$n"; then
          ok "$n: rendered output matches the chart"
        else any=1; fi
      else
        warn "$n: never rendered"; any=1
      fi
    done
    rm -rf "$TMP"
    (( any )) && warn "Run 'gitops commit' to publish these."

    sec "Rendered vs cluster"
    # The gate before adopting anything: if this is empty, Argo CD taking
    # ownership changes nothing.
    if kubectl diff -f "$DIR/rendered" -R >/dev/null 2>&1; then
      ok "No drift. The cluster already matches rendered/."
    else
      kubectl diff -f "$DIR/rendered" -R 2>/dev/null | sed 's/^/  /'
      warn "The cluster differs from rendered/. Resolve before adopting."
    fi
    ;;

  commit)
    shift
    msg="automated render"
    auto=no
    while (( $# )); do
      case "$1" in
        -m) msg="${2:?-m needs a message}"; shift 2 ;;
        --auto) auto=yes; msg="auto: $(date '+%Y-%m-%d %H:%M:%S')"; shift ;;
        *) msg="$1"; shift ;;
      esac
    done
    sec "Render"
    do_render || exit 1
    cd "$DIR" || exit 1
    git add -A
    if git diff --cached --quiet; then
      [[ "$auto" == yes ]] || ok "Nothing to commit."
      exit 0
    fi
    # Refuse to publish anything that looks like key material, even though
    # .gitignore should already have caught it. This repo is mirrored.
    if git diff --cached --name-only | grep -Eiq '(^|/)[^/]*(secret|\.key|\.pem|\.env)([^/]*)$'; then
      err "Refusing to commit: a staged path looks like key material."
      git diff --cached --name-only | sed 's/^/      /' >&2
      git reset >/dev/null
      exit 1
    fi
    git commit -q -m "$msg"
    ok "Committed: $msg"
    git push -q origin HEAD:main 2>/dev/null && ok "Pushed to the bare repo." \
      || err "Push to origin failed."
    if git remote get-url github >/dev/null 2>&1; then
      if timeout 30 git push -q github HEAD:main 2>/dev/null; then
        ok "Mirrored to GitHub."
      else
        warn "GitHub mirror push failed. The deploy is unaffected."
      fi
    fi
    ;;

  sync)
    app="${2-}"
    if [[ -n "$app" ]]; then
      list="$app"
    else
      list="$(kubectl -n "$ARGO_NS" get app \
              -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    fi
    for a in $list; do
      [[ -n "$a" ]] || continue
      kubectl -n "$ARGO_NS" annotate app "$a" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1
      kubectl -n "$ARGO_NS" patch app "$a" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"gitops"},"sync":{"revision":"HEAD"}}}' \
        >/dev/null 2>&1 && ok "sync requested: $a" || err "could not sync $a"
    done
    ;;

  apps)
    kubectl -n "$ARGO_NS" get app -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTO:.spec.syncPolicy.automated,REV:.status.sync.revision' \
      2>/dev/null | cut -c1-110
    ;;

  automate)
    app="${2:?usage: gitops automate <app>}"
    kubectl -n "$ARGO_NS" patch app "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}' >/dev/null \
      && ok "$app now auto-syncs. Pruning stays off." \
      || err "could not patch $app"
    warn "Edit apps/$app.yaml and commit, or the root app will revert this."
    ;;

  manual)
    app="${2:?usage: gitops manual <app>}"
    kubectl -n "$ARGO_NS" patch app "$app" --type json \
      -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1 \
      && ok "$app is manual-sync now." || warn "$app was already manual."
    ;;

  build)
    name="${2:?usage: gitops build <chart>}"
    ctx="$DIR/source/$name/image"
    [[ -d "$ctx" ]] || { err "No image context at $ctx"; exit 1; }
    tag="$(date '+%Y%m%d-%H%M%S')"
    ref="localhost/$name:$tag"

    # k3s bundles containerd but no way to build with it - 'ctr' imports
    # images, it does not build them. So a builder has to come from
    # somewhere, and a fresh server has none.
    #
    # podman is the one to install: no daemon, no background service, and
    # nothing to run when we are not building. Docker would add a root
    # daemon permanently for the sake of an occasional build.
    builder=""
    for b in nerdctl podman docker; do command -v "$b" >/dev/null && { builder="$b"; break; }; done

    if [[ -z "$builder" ]]; then
        warn "No container builder found, and k3s cannot build images itself."
        info "podman is the lightest fit here: no daemon, nothing left running."
        if confirm "Install podman now?"; then
            sudo apt-get update -qq
            sudo apt-get install -y podman >/dev/null || { err "podman install failed"; exit 1; }
            builder=podman
            ok "podman installed."
        else
            err "Cannot build without one. Re-run after installing nerdctl, podman or docker."
            exit 1
        fi
    fi

    # Ubuntu 24.04 sets kernel.apparmor_restrict_unprivileged_userns=1, which
    # stops rootless podman creating the user namespace it needs. Root podman
    # is unaffected, and we already need sudo below for the containerd import,
    # so fall back rather than asking the user to loosen a kernel hardening
    # setting for one build.
    SUDO_B=""
    if [[ "$builder" == podman ]] && ! podman info >/dev/null 2>&1; then
        info "Rootless podman is unavailable here, so building as root."
        info "Ubuntu 24.04 restricts unprivileged user namespaces; see"
        info "reference/troubleshooting.md."
        SUDO_B="sudo"
    fi

    sec "Build"
    $SUDO_B "$builder" build -t "$ref" "$ctx" || { err "build failed"; exit 1; }
    ok "built $ref"

    # No registry on this machine, so the image is handed to k3s's containerd
    # directly. This is why the Deployment sets imagePullPolicy: Never.
    sec "Import into k3s"
    tmp="$(mktemp -d)"
    $SUDO_B "$builder" save -o "$tmp/img.tar" "$ref" || {
      err "save failed"; sudo rm -rf "$tmp"; exit 1; }
    sudo k3s ctr images import "$tmp/img.tar" >/dev/null || {
      err "import failed"; sudo rm -rf "$tmp"; exit 1; }
    # sudo, because a root build leaves a root-owned tarball behind.
    sudo rm -rf "$tmp"
    ok "imported into containerd"

    sed -i "s|^\( *tag:\).*|\1 \"$tag\"|" "$DIR/source/$name/values.yaml"
    ok "values.yaml tag -> $tag"
    echo
    ok "Now: gitops commit -m \"$name $tag\""
    ;;

  pause)
    kubectl -n "$ARGO_NS" scale statefulset/argocd-application-controller --replicas=0 >/dev/null 2>&1 \
      && ok "Reconciliation stopped." || err "could not scale the controller"
    ;;

  resume)
    kubectl -n "$ARGO_NS" scale statefulset/argocd-application-controller --replicas=1 >/dev/null 2>&1 \
      && ok "Reconciliation running." || err "could not scale the controller"
    ;;

  log)
    git -C "$DIR" log --oneline --decorate -n "${2:-15}"
    ;;

  status)
    sec "Repository"
    cd "$DIR" || exit 1
    printf '  %-14s %s\n' "working tree" "$DIR"
    printf '  %-14s %s\n' "bare repo" "$(git remote get-url origin 2>/dev/null || echo none)"
    printf '  %-14s %s\n' "mirror" "$(git remote get-url github 2>/dev/null || echo 'none configured')"
    printf '  %-14s %s\n' "branch" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    printf '  %-14s %s\n' "head" "$(git log -1 --format='%h %s' 2>/dev/null || echo 'no commits')"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      warn "Uncommitted changes:"
      git status --porcelain | sed 's/^/      /'
    else
      ok "Working tree clean."
    fi

    sec "Charts"
    for n in $(charts); do
      if [[ -f "$DIR/rendered/$n/manifests.yaml" ]]; then
        printf '  %-16s %s object(s) rendered\n' "$n" \
          "$(grep -c '^kind:' "$DIR/rendered/$n/manifests.yaml" 2>/dev/null || echo 0)"
      else
        warn "$n: not rendered yet"
      fi
    done

    sec "Argo CD"
    if kubectl -n "$ARGO_NS" get statefulset argocd-application-controller >/dev/null 2>&1; then
      want="$(kubectl -n "$ARGO_NS" get statefulset argocd-application-controller \
              -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      [[ "${want:-0}" == "0" ]] && warn "Controller scaled to zero - nothing is reconciling." \
                                || ok "Controller running."
      kubectl -n "$ARGO_NS" get app -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null \
        | sed 's/^/  /'
    else
      warn "Argo CD is not installed."
    fi
    ;;

  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
GITOPS_EOF
sudo chmod +x /usr/local/bin/gitops
ok "Installed 'gitops'."
note_change

# ---------------------------------------------------------------------------
section "Change watcher"

# A path unit rather than a daemon. Editors write a file several times while
# saving, so the service debounces before doing anything: without the sleep
# a single save produces a handful of commits.
sudo tee /etc/systemd/system/gitops-watch.service >/dev/null <<EOF
[Unit]
Description=Render and commit the gitops repository after a change
After=k3s.service

[Service]
Type=oneshot
User=$USER
Environment=KUBECONFIG=$HOME/.kube/config
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/gitops commit --auto
EOF

sudo tee /etc/systemd/system/gitops-watch.path >/dev/null <<EOF
[Unit]
Description=Watch the gitops source and rendered trees

[Path]
PathChanged=$GITOPS_DIR/source
PathChanged=$GITOPS_DIR/rendered/manual
Unit=gitops-watch.service

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
if [[ "$WATCH" == yes ]]; then
    sudo systemctl enable --now gitops-watch.path
    ok "Watcher enabled: edits are rendered and committed automatically."
else
    sudo systemctl disable --now gitops-watch.path >/dev/null 2>&1 || true
    ok "Watcher installed but disabled. Enable with --watch, or:"
    info "  sudo systemctl enable --now gitops-watch.path"
fi
note_change

# ---------------------------------------------------------------------------
section "First render"

gitops render || die "The shipped charts did not render. Nothing was adopted."

cd "$GITOPS_DIR"
git add -A
if ! git diff --cached --quiet; then
    git commit -q -m "Initial render from the setup kit"
    git push -q origin HEAD:main 2>/dev/null || warn "Could not push to the bare repo."
    ok "Committed and pushed the initial state."
    note_change
else
    ok "Repository already current."
fi

# ---------------------------------------------------------------------------
section "Adoption check"

# The gate. If the rendered chart does not already match the cluster, do not
# hand the cluster over - fix the chart first. An Application created against
# a mismatched render makes its first sync a surprise rollout.
if kubectl diff -f "$GITOPS_DIR/rendered" -R >/dev/null 2>&1; then
    ok "No drift: rendered/ matches what is running."
    DRIFT=no
else
    warn "The cluster differs from rendered/:"
    kubectl diff -f "$GITOPS_DIR/rendered" -R 2>/dev/null | head -60 | sed 's/^/      /'
    warn "Not creating Applications. Reconcile with 'gitops diff' first."
    DRIFT=yes
fi

if [[ "$DRIFT" == no ]]; then
    kubectl apply -n "$ARGO_NS" -f "$GITOPS_DIR/apps/platform.yaml" >/dev/null
    kubectl apply -n "$ARGO_NS" -f "$GITOPS_DIR/apps/root.yaml" >/dev/null
    ok "Applications created: root (auto-sync), platform (manual)."
    note_change
fi

# ---------------------------------------------------------------------------
section "Done"

cat <<EOF
  $changed change(s) applied.

  Argo CD UI        http://127.0.0.1:8090
    user            admin
    password        ${ADMIN_PW:-<kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d>}

  The two directories:

      $GITOPS_DIR/source/      Helm charts. Edit these.
      $GITOPS_DIR/rendered/    What Argo CD applies. Generated.

  Everyday use:

      gitops status                  repo and Application state
      gitops commit -m "message"     render, commit, push, deploy
      gitops diff                    what would change, and any cluster drift
      gitops sync                    reconcile now instead of waiting 30s

  The platform Application is adopted but on MANUAL sync. Watch it stay
  Synced through a couple of real changes, then:

      gitops automate platform

  Two things that are off on purpose and should stay off:

    Pruning. Deleting a manifest stops Argo CD managing the object, it does
    not delete it. Storage and Secrets are outside the repo entirely.

    Replica reconciliation. ai-pause and 'games stop' scale deployments to
    zero; self-heal would undo that within seconds and the memory would
    never come back. apps/platform.yaml ignores /spec/replicas.

  Next: ./09-gpu-queue.sh
EOF
