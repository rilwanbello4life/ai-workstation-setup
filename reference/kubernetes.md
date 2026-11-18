# Kubernetes on one node

k3s specifics, GPU handling, and the parts that behave differently from a normal cluster.

Installed by [`../server/02-k3s.sh`](../server/02-k3s.sh). Architecture and the reasoning behind the layering is in [server-architecture.md](server-architecture.md).

## Why k3s

| | Resident memory | Verdict |
|---|---:|---|
| **k3s** | ~1.5 GB | Chosen. One binary, CNCF-certified, bundles Traefik, CoreDNS and local-path storage |
| MicroK8s | ~2 GB | Equivalent, but snap-based and awkward to pin versions |
| kubeadm | ~4 GB+ | Several gigabytes to achieve the same thing on one node |
| Docker Compose | ~0 | Honestly enough for n8n and Postgres, but no ingress, no quotas, no declarative reconciliation |

k3s is real Kubernetes. `kubectl`, manifests, Helm charts and operators all behave normally, which matters if any of this ever moves to a second machine.

## What is different on a single node

- **No high availability.** The control plane, the only worker and your data are the same machine. A reboot is a full outage, and booting Windows is a planned one.
- **`local-path` and `srv-local` are node-bound.** A PersistentVolume here is a directory, not a network volume. There is nothing to fail over to.
- **The GPU is indivisible.** Covered below, and it is the constraint people find most surprising.
- **ServiceLB rather than a cloud load balancer.** `type: LoadBalancer` binds the port directly on the host. Useful for game servers, and the reason ports must be allocated deliberately.

## The GPU

`server/02-k3s.sh` installs `nvidia-container-toolkit` and creates a `RuntimeClass` named `nvidia`. A pod opts in:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - name: worker
      resources:
        limits:
          nvidia.com/gpu: 1
```

**This does not make the card shareable.** The device plugin advertises exactly one GPU and assigns it whole. Consequences worth internalising:

- A second pod requesting `nvidia.com/gpu: 1` stays `Pending` indefinitely. It is not broken; there is no second card.
- While Strata holds the card on the host, a GPU pod will schedule and start but find almost no free VRAM, then fail at model load with a CUDA out-of-memory error that looks like a bug and is not.
- Time-slicing (`nvidia.com/gpu.replicas`) interleaves kernels but does **not** partition VRAM. Two pods each wanting 12 GB still will not fit in 16 GB. It helps for many small inference calls, not for this workload.
- MIG, which does partition memory, is not supported on GeForce cards.

The practical rule: **run `ai-pause` before any GPU pod, and expect to run one at a time.** GPU pods are for batch work — a scheduled ComfyUI render, a fine-tune — not for serving.

## Reaching the host model servers

Pods address the host services by normal cluster DNS:

```
http://strata.platform.svc.cluster.local:8080/v1
http://llamacpp.platform.svc.cluster.local:8081/v1
http://voice.platform.svc.cluster.local:8100/v1
```

Two pieces make that work, defined in [`../server/k8s/03-host-models.yaml`](../server/k8s/03-host-models.yaml):

1. **A Service with no selector.** Without a selector Kubernetes creates no endpoints automatically, which is the point — we supply them by hand.
2. **An EndpointSlice pointing at the cni0 gateway**, normally `10.42.0.1`, which is the host as seen from inside a pod.

Then `ai-model-bridge.service` runs `socat` listeners bound *only* to that cni0 address, forwarding to `127.0.0.1`. The alternative would be rebinding Strata to `0.0.0.0`, which exposes an unauthenticated model server to the entire LAN. The bridge keeps the services on loopback while letting pods in.

If pods cannot reach the models, check in this order:

```sh
systemctl status ai-model-bridge         # is the bridge up
ss -ltn | grep -E '8080|8081|8100'       # is anything listening on 10.42.0.1
kubectl -n platform get endpointslices   # do the endpoints have the right IP
ip -4 addr show cni0                     # did cni0 change address
```

The last one matters: if `cni0` ever gets a different subnet, the EndpointSlice and the socat unit both need updating. Re-running `02-k3s.sh` fixes both.

## Resource quotas

Both namespaces carry a `ResourceQuota`, which is unusual on a personal cluster and deliberate here.

| Namespace | requests.memory | limits.memory |
|---|---:|---:|
| `platform` | 12 Gi | 20 Gi |
| `games` | 8 Gi | 12 Gi |

Without them, a runaway workflow can consume memory that Strata needs, and the kubelet then evicts whatever looks convenient — which on this box is frequently the wrong thing. The quota turns "the model server died mysteriously" into "the pod could not schedule", which is a far better failure.

The kubelet is also started with `--kubelet-arg=eviction-hard=memory.available<1Gi` and `system-reserved=memory=2Gi`, so it gives up memory early rather than letting the kernel OOM-kill k3s itself.

**A quota has a sharp edge**: once set, every pod in that namespace must declare `resources.requests` and `limits`. A manifest without them is rejected outright. All manifests in this kit comply; anything you add must too.

## Ingress

Traefik ships with k3s and is already running. Platform services are reached over loopback or through `tailscale serve`, so ingress is mostly for self-hosted apps:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: platform
spec:
  ingressClassName: traefik
  rules:
    - host: myapp.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8000
```

There is no public DNS and no real certificate unless you add Cloudflare Tunnel — see [sharing-with-friends.md](sharing-with-friends.md). For tailnet-only access, `tailscale serve` is simpler than ingress and gives you a genuine `*.ts.net` certificate for free.

## Housekeeping

```sh
k3s crictl rmi --prune                   # reclaim old container images
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl top nodes                        # needs metrics-server
kubectl -n platform logs deploy/litellm --tail=100 -f
```

Container images accumulate across upgrades and are the quietest consumer of disk in the whole build. Prune monthly.

## Backup and rebuild

The cluster is reproducible: every manifest lives in [`../server/k8s/`](../server/k8s/), and `server/setup-all.sh` rebuilds it from nothing. What is *not* reproducible is the data in `/srv/platform`.

[`../server/07-backup.sh`](../server/07-backup.sh) installs a nightly job that handles this. The two commands at its core, if you would rather run them by hand:

```sh
# Postgres. pg_dumpall, not pg_dump: it captures roles and their passwords,
# without which a restore gives you databases nothing can log into.
kubectl -n platform exec deploy/postgres -- \
  pg_dumpall -U postgres --clean --if-exists | gzip > /srv/backups/pg-$(date +%F).sql.gz

# n8n workflows as JSON, so they survive losing Postgres entirely
kubectl -n platform exec deploy/n8n -- n8n export:workflow --all --output=/tmp/wf.json
```

`/srv/backups` is on the same drive, so on its own it protects against mistakes rather than failure. The script adds an encrypted offsite copy, which is the half that matters when the drive dies. See [backups.md](backups.md), particularly the note on why the encryption key cannot live only on this machine.

## Uninstalling

k3s ships a clean uninstaller, which is reassuring when experimenting:

```sh
sudo /usr/local/bin/k3s-uninstall.sh
```

It removes the cluster, containerd and every image, but **leaves `/srv/platform` alone** because those are hostPath directories rather than k3s-managed storage. That separation is the main reason the volumes live on `/srv`.
