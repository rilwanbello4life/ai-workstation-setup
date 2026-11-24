# GitOps with Argo CD

Phase 20 (`server/08-gitops.sh`) puts a deployment pipeline on the machine. You edit files; the cluster follows.

This exists because the alternative was a pile of `kubectl apply -f` commands whose effect depended on which ones you remembered to run. With Argo CD the question "what is supposed to be running?" has a single answer you can read, and "what is actually running?" is a command away.

---

## The shape of it

Two directories, one of which you edit and one of which you review:

```
/srv/gitops/
  source/      Helm charts - what you write
  rendered/    plain Kubernetes objects - what Argo CD applies
  apps/        Argo CD Application definitions
```

`gitops render` runs `helm template` over everything in `source/` and writes the output to `rendered/`. Argo CD only ever looks at `rendered/`.

This is the **rendered manifests pattern**, and the reason for it is reviewability. If Argo CD read the charts directly, a one-character change to a values file would show up in the diff as exactly that: one character, with no indication of what it did to the cluster. Rendering first means the diff you review is the diff the cluster will experience — the actual objects, with the actual values substituted.

It also means a template that fails to render fails on your terminal, in the foreground, instead of in a controller log you have to go looking for.

### Why there is a git daemon

Argo CD cannot watch a directory. It reads git, Helm repositories or OCI registries, and nothing else. A path on disk is not something it knows how to poll.

So `/srv/gitops` is a working tree with a bare repo behind it at `/srv/gitops.git`, and a read-only `git daemon` serves that bare repo on port 9418, bound to loopback: the cluster reaches it through a `host-model-proxy` unix socket like every other host service, and the LAN cannot reach it at all. Argo CD clones `git://gitops.platform.svc.cluster.local:9418/gitops.git` like any other remote.

The daemon does not use `--export-all`. A repository is only served if it contains a `git-daemon-export-ok` marker file, so a second repo created in that directory later is not silently published.

---

## The two ways in

**Edit a chart.** This is the normal path.

```sh
cd /srv/gitops
$EDITOR source/platform/values.yaml

gitops render        # helm template -> rendered/
gitops diff          # what would change in the cluster
gitops commit -m "give n8n more memory"
gitops sync platform
```

**Drop in a plain manifest.** For something that is not worth a chart:

```sh
cp my-thing.yaml /srv/gitops/rendered/manual/
gitops commit -m "add my-thing"
```

`rendered/manual/` is never overwritten by `gitops render`, which is the only reason it is a separate directory. Everything else under `rendered/` is generated and will be replaced.

---

## Commands

| Command | What it does |
|---|---|
| `gitops status` | Repo state, Argo CD health, every Application and its sync state |
| `gitops render` | Re-render all charts into `rendered/` |
| `gitops diff` | `kubectl diff` of the rendered tree against the live cluster |
| `gitops commit [-m msg]` | Render, check for secrets, commit, push to the bare repo and any mirror |
| `gitops sync [app]` | Tell Argo CD to reconcile now instead of waiting |
| `gitops apps` | List Applications with sync and health |
| `gitops automate <app>` / `gitops manual <app>` | Turn auto-sync on or off for one app |
| `gitops build <chart>` | Build a local image and import it into k3s |
| `gitops pause` / `gitops resume` | Stop and start Argo CD reconciling at all |
| `gitops log` | Recent commits |

`gitops commit` renders first, every time. Committing a stale `rendered/` is the one mistake in this workflow that produces a confusing outcome — the cluster converges on something you did not write — so it is not possible.

---

## Safety rails

**Nothing is pruned.** Every Application sets `prune: false`. If you delete a file, Argo CD leaves the object running and reports the Application as out of sync. Deleting is therefore a deliberate `kubectl delete`, never a side effect of a file edit. On a single-node cluster holding your own data, this is the right trade: a stray object costs memory, an auto-pruned PersistentVolumeClaim costs the data.

**Secrets cannot be committed.** Two independent checks, because one is not enough:

- `.gitignore` refuses `*secret*.yaml`, `*.key`, `*.pem`, `.env*` and similar
- `gitops commit` separately inspects the staged paths and aborts, resetting the index, if any of them look like key material

The second exists because `.gitignore` only helps for files that match it. A file called `credentials.json` is not caught by any sensible pattern but is caught by the explicit check.

Real secrets stay in `/srv/platform/secrets` at mode 600 and reach the cluster as `Secret` objects created by the phase scripts. They are not in git and are not managed by Argo CD.

**The platform app starts on manual sync.** Adoption of the already-running platform is gated: `08-gitops.sh` will not enable anything until `kubectl diff` shows that the chart renders exactly what is already live. If it shows a difference, the script stops and tells you, rather than letting Argo CD "fix" a discrepancy it does not understand.

Once you trust it:

```sh
gitops automate platform
```

---

## Argo CD and ai-pause

These two want opposite things, and the conflict is worth understanding before it surprises you.

`ai-pause` scales the platform to zero to free memory for a game or a large model. Argo CD's self-heal sees `replicas: 0`, decides the cluster has drifted from git, and scales it back up. Within about thirty seconds your pause has been undone.

Three things prevent that, and all three are needed:

1. **`ignoreDifferences` on `/spec/replicas`** for every Deployment and StatefulSet. Argo CD stops treating the replica count as something it owns. This is the main fix.
2. **`ai-pause` scales the `argocd` namespace down first**, before anything else, and `ai-resume` brings it back up last. Nothing is watching during the window when it would matter.
3. **`prune: false`**, so a scaled-down workload is never mistaken for a deleted one.

The `argocd` namespace carries `ai-workstation/pausable: "true"`, which is what makes the first point work — it is how `ai-pause` knows the namespace is fair game.

> If you edited `ai-pause` before phase 20, note that the installed copy carries a version marker. Re-running `01-server-base.sh` replaces an older one. A stale `ai-pause` appears to work and is silently reversed, which is a bad failure to debug from scratch.

Argo CD costs about 1 GB at rest, which is why it is pausable at all. The `ResourceQuota` on the namespace caps it at 1280Mi of requests and 2560Mi of limits, and a `LimitRange` supplies defaults for the chart's hooks and init containers, which do not always declare their own.

---

## The change watcher

`gitops-watch.path` watches `/srv/gitops/source` and runs `gitops render && gitops commit --auto` when it changes, with a five second debounce so an editor writing a file in three steps produces one commit.

**It is installed disabled**, deliberately. Automatic commit-on-save is pleasant until you are halfway through an edit that does not make sense yet. Turn it on when you want it:

```sh
sudo systemctl enable --now gitops-watch.path
```

---

## Pushing to GitHub

The bare repo at `/srv/gitops.git` is the source of truth. A GitHub remote, if configured, is a **push mirror** — a backup and a way to read your configuration from elsewhere, not something Argo CD consults.

That ordering matters: the cluster never depends on the network, your laptop, or GitHub being up. It reads from a repository on the same machine.

Make the GitHub repo private. The rendered manifests do not contain secrets, but they do contain a complete description of what you run and where.

---

## When it is not behaving

```sh
gitops status                 # start here
gitops diff                   # cluster vs what you committed
kubectl -n argocd get applications
kubectl -n argocd logs deploy/argocd-application-controller --tail=50
```

The UI is on `http://127.0.0.1:8090`, with the password in `/srv/platform/secrets/argocd-admin-password`.

| Symptom | Usual cause |
|---|---|
| `OutOfSync` that will not clear | You rendered but did not commit. `gitops commit`. |
| Application stuck `Unknown` | The git daemon is down. `systemctl status git-daemon`. |
| Changes ignored | Auto-sync is off for that app. `gitops sync <app>`, or `gitops automate <app>`. |
| `ImagePullBackOff` on a local image | Built but not imported. `gitops build <chart>`. |
| Pods scale back up after `ai-pause` | Stale `ai-pause`. Re-run `01-server-base.sh`. |

See also: [kubernetes.md](kubernetes.md), [server-architecture.md](server-architecture.md), [gpu-queue.md](gpu-queue.md).
