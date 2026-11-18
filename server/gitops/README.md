# /srv/gitops — the deployment repository

Copied here by `server/08-gitops.sh`. This is the working tree; the bare repo
Argo CD reads from is `/srv/gitops.git`, and GitHub, if configured, is a
mirror rather than the source of truth.

```
source/      Helm charts. Edit these.
rendered/    helm template output. Argo CD applies this. Generated.
rendered/manual/   hand-written manifests. Never touched by render.
apps/        Argo CD Application definitions (app of apps).
```

## The two ways in

**Change a chart** — edit something under `source/`, then:

```bash
gitops commit -m "raise the n8n memory limit"
```

That renders, commits, pushes to the bare repo, mirrors to GitHub and lets
Argo CD pick it up within 30 seconds. `gitops sync` if you do not want to
wait.

**Change a manifest directly** — edit a file under `rendered/manual/` and
commit the same way. Nothing regenerates that directory, so your edit stands.

Editing a file under `rendered/` that is *not* in `manual/` works exactly
once: the next render overwrites it. `gitops render` warns when it is about
to do that.

## Why rendered manifests rather than pointing Argo CD at the charts

Argo CD can render Helm itself, which would make `rendered/` unnecessary. The
reason it exists anyway is that the diff you review before a change goes live
is then a diff of real Kubernetes objects rather than of template inputs. On
a single-node machine where a bad memory limit evicts the model server, that
is worth one extra directory.

## Safety rails

- **Nothing is pruned.** Deleting a manifest stops Argo CD managing the
  object; it does not delete it. Removing something for real is deliberate.
- **Replica counts are ignored.** `ai-pause` and `games stop` scale
  deployments to zero, and self-heal would otherwise undo them within
  seconds. See the `ignoreDifferences` block in `apps/platform.yaml`.
- **No secrets.** See `.gitignore`, and keep it that way.
