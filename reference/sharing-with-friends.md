# Sharing model access with friends

Giving a handful of people the ability to run AI jobs on your machine, without giving them your machine.

Installed by [`../server/06-friends.sh`](../server/06-friends.sh).

## The two things you are deciding

They are independent and people routinely conflate them:

1. **Transport** — how a request reaches your house.
2. **Authorisation** — what the request is allowed to do once it arrives.

Authorisation is settled: **LiteLLM virtual keys**. Each friend gets their own key, with a budget, a rate limit and a model allowlist, revocable in one command. This is built and enabled.

Transport is **your open decision**. The kit builds the Tailscale path because it is the one that cannot be left accidentally open to the internet. The Cloudflare path is documented below but deliberately not installed.

## Why the gateway, and not just a port

Without LiteLLM in front, "sharing my models" means handing someone an unauthenticated endpoint that can occupy your GPU indefinitely. There is no key to revoke, no record of who ran what, and no ceiling. One friend's runaway script is indistinguishable from an outage.

With it:

| Control | Effect |
|---|---|
| Virtual key | Per person, revocable without touching anyone else |
| `max_budget` | A hard stop, in notional dollars |
| `rpm_limit` / `tpm_limit` | Stops one person monopolising the queue |
| `models` allowlist | Give access to `worker`, not necessarily to `brain` |
| Spend log | Who ran what, when, and how much of it |

The budget is denominated in dollars against local models, which means nothing financially. Treat it as a **token quota with a dollar sign on it** — it still enforces a ceiling, which is the point.

### What the queue adds on top

Phase 21 puts the GPU queue on port 4100 in front of this gateway. LiteLLM still owns every control in the table above — the queue forwards each caller's key to it untouched, so keys, budgets and allowlists are unchanged and no key has to be reissued.

What changes is the behaviour when the machine is busy. LiteLLM caps concurrency and **refuses** the overflow with a `429`. The queue **holds** it and admits it when the card has room, and it decides that from live GPU state rather than a fixed number — so a quiet GPU accepts more work instead of making people wait for nothing.

It also gives each person a system prompt and a set of skills, which is the difference between "here is my endpoint" and "here is an assistant set up for you":

```sh
friends profile alice --edit
friends skills grant alice sql
```

If you have run phase 21, the `tailscale serve` line below points at 4100 instead of 4000; `06-friends.sh` and `09-gpu-queue.sh` both set this up and each detects what the other did. Details in [gpu-queue.md](gpu-queue.md).

## Transport option A — Tailscale node sharing (built)

Tailscale lets you share a single machine with a specific person's tailnet. They install Tailscale, accept the share, and reach your box at `your-host.your-tailnet.ts.net`. Nothing is published to the internet.

```sh
# done by 06-friends.sh, repointed to 4100 by 09-gpu-queue.sh
tailscale serve --bg --https=8447 http://127.0.0.1:4100
```

The address friends are given never changes, only what answers behind it — so moving the queue in front of the gateway costs nobody a reissued key.

Then, in the Tailscale admin console under **Machines → your host → Share**, generate an invite link per person.

**Advantages**

- Nothing is ever reachable from the public internet. There is no scanning, no credential stuffing, no bot traffic.
- Access is revoked in the admin console, instantly, per person.
- You see each shared device in your machine list.
- Free tier covers a handful of people comfortably.

**Costs**

- Every friend must install Tailscale and keep it running. This is the real friction, and for non-technical friends it is a genuine obstacle.
- Shared nodes count against your tailnet limits.
- It does not work from a device they cannot install software on.

## Transport option B — Cloudflare Tunnel plus Access (documented, not installed)

`cloudflared` makes an outbound connection to Cloudflare, which then serves `ai.yourdomain.com` publicly. Cloudflare Access sits in front and requires a Google or GitHub login from an allowlisted email before any request reaches you.

```sh
# Not run by this kit. Here for when you decide.
cloudflared tunnel login
cloudflared tunnel create homelab
cloudflared tunnel route dns homelab ai.yourdomain.com
cloudflared tunnel run --url http://127.0.0.1:4000 homelab
```

Then define an Access application for that hostname with an email allowlist. **The tunnel without Access in front of it is an open proxy to your GPU** — the two are not optional halves.

**Advantages**

- Friends need nothing installed. A URL and their existing Google account.
- Works from any device, including ones they do not administer.
- No port forwarding, and your home IP is never exposed.

**Costs**

- It is genuinely public. A misconfigured Access policy, an expired certificate, a tunnel restarted without the policy attached — each is a real exposure, and you will not necessarily notice.
- Access adds an authentication redirect that API clients handle poorly; programmatic use needs service tokens, which is extra configuration.
- You are trusting Cloudflare with the plaintext of every request.

## Choosing

| If | Then |
|---|---|
| Your friends are technical | Tailscale. The friction is one install and it is strictly safer. |
| They are not, and you want this to just work | Cloudflare, with Access configured before the tunnel ever runs. |
| You are unsure | Tailscale now. Moving later is one command; closing a leak is not. |

`tailscale funnel` is a third option that exposes a serve endpoint to the public internet. **Do not use it here.** It is the public exposure of option B with none of the authentication of option B.

## Managing people

```sh
friends add alice --budget 50 --rpm 10      # create a key
friends list                                # keys, budgets, spend to date
friends spend                               # who has used what
friends disable alice                       # revoke, immediately
friends remove alice                        # delete the key entirely
```

Suggested starting limits for a friend who is experimenting rather than working:

| Setting | Value | Reason |
|---|---|---|
| `max_budget` | 50 | Generous for local models; catches a loop |
| `rpm_limit` | 10 | A backstop; the queue handles pacing properly |
| `tpm_limit` | 100000 | Stops a single enormous context from stalling everyone |
| `models` | `worker`, `local` | `brain` at `xhigh` can occupy the GPU for minutes per call |

Restricting `brain` is not stinginess. A single `xhigh` reasoning call can run for several minutes, during which nothing else on the machine generates. One friend doing that on a loop takes your assistant offline.

With the queue in place you have a second, softer option: allow `brain` but leave `allow_heavy` off, so heavy requests are rejected at the queue rather than the model being hidden. Or allow it and rely on the one-heavy-job-at-a-time rule, which bounds the damage without forbidding it. `friends profile <name> --allow-heavy yes`.

## What your friends should expect

Tell them this up front and you will avoid most of the support questions:

- **It is one GPU.** Requests queue. Two people working simultaneously roughly halve each other's speed. With phase 21 the wait is explicit and fair rather than a refusal, and the response carries `X-Queue-Position` and `X-Queue-Wait-Ms` headers if they want to show it.
- **It goes away sometimes.** Rebooting into Windows, pausing for a game, or swapping a model pack all mean minutes of unavailability with no notice.
- **Everything is logged.** Prompts and completions are recorded in Postgres, in plaintext, and you can read them. Say so explicitly — people assume otherwise and will paste things they should not.
- **It is not an SLA.** It is a machine in someone's house.

## Where the liability actually sits

The uncomfortable part, stated plainly: **traffic leaving your connection is attributable to you.** Your name is on the internet service account.

- Content generated and then published by a friend can be traced to your IP.
- A compromised friend key can turn the box into a proxy for whatever the attacker wants to generate.
- Open WebUI accounts are not isolated from each other by default; a friend with an account can potentially see shared chats.

Mitigations that are actually worth doing:

1. **Keep the key list short and the people known.** This is the whole mitigation. Do not let it become "a friend of a friend asked".
2. **Review `friends spend` weekly.** A key doing ten times its usual volume is the signal.
3. **Give model access, not shell access.** No SSH, no Open WebUI admin, no n8n.
4. **Keep the logs.** If something does happen, the record of what was generated and under which key is what resolves it.

If your ISP's terms prohibit running services — many residential contracts do — the Tailscale path is private traffic between peers and is far less likely to be the thing that gets noticed.

## When a key goes wrong

```sh
friends disable alice            # revoke first, investigate after
agent-runs tail 100              # what was being run
kubectl -n platform logs deploy/litellm --tail=200 | grep alice
```

Revocation is immediate; LiteLLM checks the key on every request and does not cache the decision. An in-flight generation finishes, and nothing new starts.
