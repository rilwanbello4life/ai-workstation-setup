# The GPU queue

Phase 21 (`server/09-gpu-queue.sh`) puts a queue in front of the gateway so that several people can share one GPU without any of them having to think about it.

---

## The problem it solves

One card, 16 GB. The failure mode when several people use it at once is not slowness — it is that each request allocates KV cache, memory runs out partway through a generation, and requests fail in ways that look like bugs.

LiteLLM's `max_parallel_requests: 4` caps concurrency, but it **rejects** the overflow with a `429`. It does not hold anything. It also has no idea what the GPU is doing: four trivial completions and four long reasoning runs look identical to it.

The queue fixes both:

- a request that cannot run **waits** instead of being refused
- how many may run is decided from **live GPU state**, not a fixed number

The second is the part you asked for specifically: if the card is not busy, another job should start rather than wait for no reason.

---

## Where it sits

```
friend ──HTTPS :8447──▶ gpu-queue :4100 ──▶ LiteLLM :4000 ──▶ Strata / llama.cpp
                         (waits, profiles)   (keys, budgets)
```

The queue is in front, but it does **not** take over authorisation. It forwards the caller's original `Authorization` header to LiteLLM untouched, so budgets, rate limits, model allowlists and spend logging all still work and still belong to LiteLLM.

The practical consequence: `friends add` is unchanged, existing keys keep working, and nothing has to be reissued. Only the port behind the published URL moved.

---

## Admission

Every request is classified **heavy** or **light** before anything else happens.

Heavy means any of:

- the `brain` alias
- `reasoning_effort` of `high` or `xhigh`
- `max_tokens` above 4096
- any batch job

Everything else is light. Then:

| Rule | Value |
|---|---|
| Heavy jobs at once | 1 |
| Light jobs at once | 2 normally, up to 4 when the card is quiet |
| Light jobs while a heavy one runs | 0 |
| Per person at once | `max_concurrent`, default 1 |
| VRAM held back | 2 GB |

The light limit rises to 4 only while **both** are true: GPU utilisation is under 50%, and free VRAM exceeds the 2 GB reserve plus 2 GB of growth headroom. Either condition failing drops it back to 2. That is the adaptive behaviour — a quiet card takes more work, a loaded one does not.

A heavy job waits for in-flight light ones to finish before it starts, rather than starting alongside them. This is the one place the queue deliberately costs you a little throughput: a long reasoning run that begins while three other requests are mid-generation is the exact situation that runs the card out of memory.

### Fairness

Waiting requests are ordered by `(priority, arrival)`. Priority is per-person, lower first, default 100, and the owner profile is seeded at 10.

Priority is snapshotted when a request is enqueued, not read when it is dispatched. Raising someone's priority therefore affects their next request and does not reorder work that is already waiting — otherwise a single edit could starve somebody who had been queued for a minute.

`max_concurrent` is enforced separately and first: one person cannot occupy the whole queue by sending twenty requests, regardless of their priority.

---

## Per-person setup

Each key gets a profile: a system prompt, a set of skills, and queue limits. People who were never given one still work — the queue synthesises the defaults — so this is optional.

```sh
friends profile alice                       # show it
friends profile alice --edit                # edit the system prompt in $EDITOR
friends profile alice --concurrent 2 --priority 50
friends profile alice --allow-heavy yes     # let them use brain / batch jobs
```

Skills are reusable prompt fragments, stored once and granted to whoever needs them:

```sh
friends skills list
friends skills show sql
friends skills grant alice sql
friends skills revoke alice sql
```

Four ship by default: `concise`, `sql`, `k8s`, `shell`.

When a request arrives, the queue prepends the person's system prompt and the content of each granted skill as system messages, then forwards it. The caller sees normal OpenAI responses and does not need to know any of this happened.

A caller can also ask for skills per-request with a non-standard `"skills": ["sql"]` field in the body. The queue strips that field before forwarding, since LiteLLM would reject it.

Prompt edits are versioned into `user_profile_history`, so a change that made things worse is visible and revertible.

---

## Batch jobs

Image generation does not fit a request/response shape — it takes minutes, and holding an HTTP connection open for that is fragile. Those go through a job API instead:

```sh
curl -X POST http://127.0.0.1:4100/v1/jobs \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"kind":"comfyui","workflow":{ ... }}'
```

It returns a job id immediately. A worker picks it up, takes a heavy slot through the same scheduler as everything else, submits it to ComfyUI, and writes results to `/srv/platform/gpu-queue/outputs/<id>/` with a manifest.

```sh
curl http://127.0.0.1:4100/v1/jobs/42 -H "Authorization: Bearer $KEY"
queue list
queue cancel 42        # only if it has not started
```

Because batch work goes through the same scheduler, a render cannot start while someone is mid-conversation, and a conversation cannot start mid-render. That is the point — it is one card, and the two were never going to coexist.

Jobs are capped at one hour.

---

## Operating it

```sh
queue status           # depth, in-flight work, live GPU state
queue watch            # the same, refreshed every 2s
queue list             # recent jobs with wait and run times
queue drain            # finish current work, admit nothing new
queue resume
```

`queue status` looks like this:

```
  in flight    1 heavy, 2 light   (limits: 1 heavy, 4 light [2-4])
  queued       3, oldest waiting 14s
  gpu          37% busy, 9100 MB free of 16376 MB
  profiles     postgres
    alice          2 running, 0 queued
    bob            0 running, 3 queued
```

**`wait_ms` is the number to watch.** Consistently near zero means the limits never bind and the queue is only adding a hop. Consistently in minutes means the machine is oversubscribed and no amount of scheduling will fix it.

`ai-pause` calls `queue drain` before scaling anything down, so taking the GPU for a game does not drop somebody's in-flight request. `gaming-check` reports queue state but does not drain — a command called "check" should not change anything.

---

## How it knows about the GPU

`gpu-probe` is a small host systemd unit on `127.0.0.1:8101`. It shells out to `nvidia-smi`, caches for 1.5 seconds, and serves JSON. The queue polls it every 2 seconds.

It runs on the host rather than in the cluster because there is no device plugin here — Strata owns the GPU directly, and a pod has no view of it.

Every failure path returns `{"available": false, "reason": "..."}` rather than an error. If the probe is missing, slow, or `nvidia-smi` is absent, the queue falls back to the static floor of 2 light and 1 heavy and keeps working. **Losing GPU visibility degrades the policy; it does not stop the service.**

---

## Design notes

**One replica, deliberately.** It is a Deployment with `replicas: 1` and `strategy: Recreate`. Admission counters live in memory, so two replicas would each admit up to the limit and the cap would quietly become double what it says. State that needs to survive a restart — profiles, skills, job history — is in Postgres.

**Not a StatefulSet.** There is no per-replica identity or storage to preserve, which is the only thing a StatefulSet would add.

**Slots are released on every path**, including a client disconnecting mid-stream. An admission that leaks its slot is the worst bug this service could have: the queue would slowly convince itself the GPU is full and stop admitting anything, while the card sits idle.

---

## When it is not behaving

```sh
queue status
kubectl -n platform logs deploy/gpu-queue --tail=50
curl -s http://127.0.0.1:8101/gpu        # is the probe answering?
curl -s http://127.0.0.1:4100/healthz
```

| Symptom | Usual cause |
|---|---|
| Everything waits, GPU idle | Probe is down, so the limit is pinned at the floor. Check 8101. |
| `429` instead of waiting | Caller is hitting 4000 directly, not 4100. |
| Someone's prompt is ignored | No profile row. `friends profile <name>`. |
| Jobs stay `queued` forever | A heavy slot is held. `queue list`, then `queue cancel`. |
| Queue admits nothing at all | It is draining. `queue resume`. |

See also: [sharing-with-friends.md](sharing-with-friends.md), [ports.md](ports.md), [gitops.md](gitops.md).
