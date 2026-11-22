# Troubleshooting

## Booting and the two drives

**Only one OS appears at the F8 boot menu.**
The firmware did not enumerate the other drive. Enter BIOS with **Del** and check Advanced > NVMe Configuration lists both. If one is missing, it is seated badly — reseat it. If you installed into M.2_3, move it to M.2_2.

**The machine always boots the same OS and never shows a menu.**
That is the configured default, which is correct. **F8** at power-on gives the menu. To change the default, BIOS > Boot > Boot Option Priorities.

**GRUB does not list Windows.**
By design. Ubuntu's GRUB lives on the Ubuntu drive and never learns about the Windows drive, which is what stops a Windows update from breaking it. Use F8 to switch. If you would rather have a GRUB entry, `sudo os-prober && sudo update-grub` adds one — at the cost of reintroducing that coupling.

**The Ubuntu USB will not boot.**
Pick the entry prefixed `UEFI:` in the F8 boot menu. A non-UEFI boot produces a BIOS-mode install, which will not sit alongside your UEFI Windows. If no UEFI entry appears, the USB was written in MBR mode — rewrite it with Rufus in GPT/UEFI mode.

**Windows asks for the BitLocker recovery key.**
Expected, not damage. Pulling and refitting the drive shifts the TPM measurements BitLocker uses to unlock automatically. Enter the 48-digit key from Phase 1; Windows reseals itself on the next boot.

**Windows offers to format a partition after the Ubuntu install.**
Click **Cancel**. That is your ext4 Ubuntu root, which Windows cannot read and therefore assumes is unformatted. Formatting it destroys the Linux install. Seeing it as a healthy partition with no drive letter in Disk Management is normal.

**I need a file from the other OS.**
There is no shared partition, deliberately. Use the network — both systems are on the same LAN, so `scp` works — or a USB stick. In practice this comes up rarely, because each system has its own complete copy of the stack.

**The 2 TB NVMe does not appear at all — not in the installer, not in `lsblk`.**
If it is a Maxio MAP1602 drive (Lexar NM790 or NQ790, Acer Predator GM7, and others), this is a known kernel issue rather than dead hardware. The controller misreports its maximum initialisation time, and kernels between roughly 6.2 and 6.5.4 give up before it is ready. Fixed in **6.5.5**.

```bash
uname -r                                  # need 6.5.5 or newer
sudo nvme id-ctrl /dev/nvme0 | grep -i maxio   # confirms the controller
dmesg | grep -i 'nvme\|crto'
```

Ubuntu 24.04 LTS ships 6.8, so a normal install is unaffected. This bites when booting an older rescue or live USB. If a drive times out under load rather than failing to appear, the general NVMe workaround is to disable autonomous power state transitions by adding `nvme_core.default_ps_max_latency_us=0` to the kernel command line.

## NVIDIA

**Desktop is slow and `nvidia-smi` reports no devices.**
Secure Boot is blocking an unenrolled module. Confirm that is what is happening before fixing anything:

```bash
mokutil --sb-state                                  # Secure Boot enabled?
dkms status                                         # did the module build?
mokutil --test-key /var/lib/shim-signed/mok/MOK.der # enrolled?
sudo dmesg | grep -iE 'nvidia|lockdown|module verification'
```

A built module plus `Lockdown: ... unsigned module loading is restricted` is the signature. Re-enroll:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
mokutil --list-new | head        # confirm the request is pending BEFORE rebooting
sudo reboot                      # then: Enroll MOK -> Continue -> Yes -> password -> Reboot
```

**The MOK password is rejected at the blue screen.**
Two causes, and the first is much more common than it looks.

**MOK Manager always uses a US keyboard layout**, whatever your BIOS and OS are set to. On a Swedish keyboard every symbol lands somewhere different — `/` is Shift+7 rather than unshifted, `@` is AltGr+2 rather than Shift+2, `-` and `+` are on different keys. A password containing any symbol will not type the way you expect. Letters and digits are identical in both layouts.

So when you re-import, **use digits only** — `12345678` is fine. It is a one-time password that is discarded the moment the key is enrolled, and it never protects anything afterwards.

The other cause is simply using your login password. The MOK password is a separate one-time value set during `apt install` or `mokutil --import`.

**The blue MOK screen no longer appears on reboot.**
Expected, and not a new fault. When enrollment is cancelled or the password fails, shim **deletes the pending request** so it does not block every subsequent boot. The key was never enrolled and there is nothing left to enroll.

Re-arm it with `mokutil --import` as above. Watch for *"Press any key to perform MOK management"* on the next boot — it has about a ten-second timeout, and letting it lapse drops the request again.

**You would rather not deal with MOK at all.**
Turning Secure Boot off in BIOS is a legitimate answer; the open kernel modules load unsigned without complaint.

**Export your BitLocker recovery key first if you have not already.** Secure Boot state is measured into TPM PCR 7, so changing it can send Windows into BitLocker recovery on its next boot. [`../windows/01-preflight.ps1`](../windows/01-preflight.ps1) saves the key for exactly this reason — check you have that file before touching the setting.

**The screen flickers or shows colour artefacts when GPU work starts.**
First establish how much of the screen is affected, because it narrows the cause immediately.

**If only one application is corrupted** and windows drawn on top of it are clean, it is that application's own GPU rendering, not the driver and not the compositor. VS Code is the usual offender: it is Electron, Electron composites through Chromium's GPU process, and a CUDA context re-clocking the card mid-session is enough to leave that process in a broken state it never recovers from. Restarting the app does not help, because the damaged GPU cache is on disk.

```bash
rm -rf ~/.config/Code/GPUCache ~/.config/Code/'Code Cache'
```

If it returns, turn Electron's GPU acceleration off permanently in `~/.config/Code/argv.json`:

```json
{ "disable-hardware-acceleration": true }
```

VS Code loses nothing that matters on this machine — it is a text editor, and the GPU is wanted for inference.

**If the whole screen is affected**, suspect the desktop compositor. A CUDA context forces the card from its idle P8 state to P0 and re-clocks memory, and GNOME on Wayland with the NVIDIA driver handles that transition badly on some driver versions.

Either way, rule out the GPU itself before changing anything. Xid errors are the card's own fault reports:

```bash
echo "$XDG_SESSION_TYPE"
sudo dmesg -T | grep -iE 'nvidia|xid|drm|fallen off the bus' | tail -40
nvidia-smi -q | grep -iE 'xid|retired|remapp|pending'
```

| What you see | Meaning |
|---|---|
| No Xid at all | Compositor or display pipeline. Benign |
| Xid 13, 31, 43 | Application-level fault. The flicker is a side effect, not the cause |
| Xid 48, 63, 64, 94, 95 | **Framebuffer memory errors.** Stop and test the card |
| Xid 79, "fallen off the bus" | **Power delivery, seating or thermal.** Stop; reseat the 12V-2×6 connector |

The decisive test is to take the compositor out of the picture entirely:

```bash
ai-console-mode off          # drops to a text console, no desktop at all
cd ~/Projects/ai-workstation-setup/ubuntu && ./03-python-cuda.sh
ai-console-mode on
```

If the flicker disappears there, the GPU and the compute are fine and you are looking at a desktop bug. Two fixes, in order of effort: log out and pick **"Ubuntu on Xorg"** at the login screen, which resolves most NVIDIA Wayland flicker outright; or confirm `nvidia-drm.modeset=1` is active with `cat /sys/module/nvidia_drm/parameters/modeset`, since Wayland misbehaves badly without it.

Running heavy GPU work from a text console is the kit's recommended practice anyway — it also returns the 1–1.5 GB of VRAM the desktop holds.

**`nvidia-smi` works but PyTorch says no CUDA device.**
Almost always the wrong wheel. Blackwell is sm_120 and there are no sm_120 kernels in cu124 or earlier:

```bash
pip install torch --index-url https://download.pytorch.org/whl/cu128
```

**`CUDA error: no kernel image is available for execution on the device`.**
Same cause, stated plainly. The package pinned an old torch. Reinstall the whole environment against cu128 or newer — there is no way to patch around it.

**`nvcc` not found when building llama.cpp.**
Ubuntu's own `nvidia-cuda-toolkit` is CUDA 12.0, which predates sm_120. Install `cuda-toolkit` from NVIDIA's repository instead; `ubuntu/04-llamacpp.sh` does this automatically.

## Performance

**Strata fails to allocate, or pages heavily during generation on Linux.**
The memlock limit is too low. Ubuntu's default `RLIMIT_MEMLOCK` is 8 MB; Strata pins 25–30 GB. Check with `ulimit -l` — you want `unlimited`. If not, run `./02-tune-linux.sh` and **log out and back in**; PAM limits only apply to new sessions.

**Generation is slower on Linux than on Windows.**
Check three things in order. `nvidia-smi` should show `Persistence-M` as `On`, `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` should say `performance`, and the GPU should not be at its idle clock. `./02-tune-linux.sh` sets the first two permanently.

**The GPU runs out of memory on Linux but not Windows.**
The desktop session holds 1–1.5 GB of VRAM. Run `ai-console-mode off` to drop to a text console and get it back, then `ai-console-mode on` afterwards. The AI servers keep running either way; they are loopback services, not desktop apps.

**Games stutter on Windows despite good average frame rates.**
Confirm Resizable BAR is `Enabled` in `nvidia-smi -q`, and that Memory Integrity is off. Both are checked by `03-tune-windows.ps1`. Do not switch to the High Performance power plan — on an X3D chip it defeats core parking and makes things worse.

**Windows C: is nearly full.**
The full AI stack is ~199 GB on a 1 TB drive shared with Windows and games. Run `03-tune-windows.ps1` for the budget breakdown. The first thing to remove is the ComfyUI video models (55 GB) — Ubuntu has them, and Wan 2.2 is the slowest thing on this card regardless. Resist adding more Strata models here; each is 23–92 GB and Ubuntu's 2 TB drive is where the catalogue belongs. Confirm hibernation is off too; `hiberfil.sys` is another 32 GB.

## Strata

**"Host '…:8080' is not allowed (DNS rebinding protection)".**
Seen from n8n's AI Assistant, Open WebUI, or anything else calling through the gateway — usually reported as a *provider* error, which sends you looking at API keys and base URLs:

```
litellm.APIError: OpenAIException - Host 'strata.platform.svc.cluster.local:8080'
is not allowed (DNS rebinding protection)
```

Nothing is misconfigured upstream. Strata checks the `Host` header of every request and rejects names it does not recognise, which is a sensible defence against a web page in your browser being used to reach a service on your loopback. It only knows about `localhost`, and the cluster reaches it through the host bridge in `server/k8s/03-host-models.yaml`, so LiteLLM's request arrives naming the cluster service instead.

The fix is to tell Strata which names it is legitimately reached by. This is in the generated shell environment as of v3:

```bash
./ubuntu/11-shell-env.sh          # rewrites ~/.config/ai-workstation/env.sh
exec "$SHELL" -l                  # or just open a new terminal
echo "$STRATA_ALLOWED_HOSTS"
strata launch --family qwen36 --model UD-Q4_K_XL --yes --no-tui
```

It must be set **in the shell that launches Strata** — it is read at startup, so exporting it afterwards changes nothing until the next launch.

Strata's other suggestion, setting an `api_key`, disables the check entirely rather than narrowing it. That is a reasonable thing to want, since Strata has no authentication otherwise, but it is a larger change: the same key has to go into `api_key` for every Strata entry in LiteLLM's `model_list`, in both `server/k8s/11-litellm.yaml` and the chart's `_helpers.tpl`, and those two must stay byte-identical or Argo CD reads the difference as drift.

**The PC freezes for minutes on first start.**
Normal. Strata loads 35–55 GB into RAM and pins part of it for the GPU. Wait; do not close the window. Subsequent starts are faster but not instant.

**It will not start: not enough RAM.**
You picked a pack above what is free right now. The rule for Flash-Next is that RAM must fit the experts plus ~10 GB for the OS, and **the server platform takes a further ~15 GB** off the top:

| | Experts, cluster up | Experts, after `ai-pause` |
|---|---:|---:|
| 96 GB | ~68 GB — up to UD-IQ4_XS | ~83 GB |
| 64 GB | ~37 GB — up to IQ2_XS | ~52 GB |

Run `ai-pause` to free the platform, or pick a smaller pack. Check before downloading with `strata launch --plan --family <f> --model <m>`, and see the fit table in [strata-models.md](strata-models.md).

**It starts but generation is extremely slow.**
Two different causes, and `ai-status` distinguishes them.

If RAM is nearly full, the experts do not fit and are being read from the NVMe on every token. Low-RAM mode needs a 24 GB GPU to help, which this is not. `ai-pause`, or move down a pack.

If RAM looks fine, this is most likely just the memory bandwidth. Four DIMMs run at roughly DDR5-3600 rather than 5600, Strata computes cold experts on the CPU, and generation speed scales almost directly with bandwidth — so published tok/s figures are not reachable in the 96 GB configuration. That was the known cost of choosing capacity; see [ram-upgrade-decision.md](ram-upgrade-decision.md).

Before blaming bandwidth, rule out the uglier possibility. If the machine was recently moved to four DIMMs and *anything* else has been odd — a crash, a container image that would not unpack, a `segfault` in `dmesg` — the memory may be marginal rather than merely slow. `journalctl -k | grep -iE 'segfault|mce|machine check'` and a full `memtest86+` pass settle it.

**It feels slow to answer even on a fast pack.**
Both Qwen models think by default and Flash-Next defaults to `xhigh`, its longest reasoning tier. Omitting `reasoning_effort` does not disable it. Pass `reasoning_effort: "low"` or `"none"`, or use the Swift 1.5 fine-tune, which thinks much shorter at the same quality. Note that Qwen's own guidance is that lower effort does not reliably finish agentic tasks faster — it causes retries.

**It loads but pages constantly during generation.**
Check `ulimit -l` on Linux. Strata pins 25–30 GB and Ubuntu's default memlock limit is 8 MB. Run `./02-tune-linux.sh`, then log out and back in.

**Download keeps failing partway.**
It resumes. Re-run the same `strata launch` and it continues from where it stopped rather than restarting the download.

**My editor or browser gets killed while `07-strata.sh` is "downloading".**
It is not the download, and on this machine it is usually not the kernel either — it is `systemd-oomd`, which Ubuntu enables by default and which kills on *memory pressure* long before memory actually runs out. A confirmed example:

```
systemd-oomd: Killed /user.slice/user-1000.slice/user@1000.service/app.slice/
  app-com.microsoft.VSCode-14230.scope due to memory pressure for
  /user.slice/user-1000.slice/user@1000.service being 77.25% > 50.00% for > 20s
  Current Memory Usage: 27.6G
```

Read that number carefully. The editor was not using 27.6 GB — **Strata was**, and it was charged to the editor's cgroup, because a process started in an integrated terminal is a child of the editor and lives in its scope. `systemd-oomd` kills whole cgroups, so the editor and the download die together. That is why it looks like the download keeps failing on its own.

Underneath it is a load, not a transfer. `strata launch` downloads a pack and then *loads* it, and `02-tune-linux.sh` grants `memlock unlimited` so Strata can pin expert tensors, which makes the memory unreclaimable.

Two things follow. **Run the installer from a plain console or `tmux`, never an editor's built-in terminal** — the terminal is the download's parent, so killing the editor kills the download too, which is why it looks like the download keeps failing. And `07-strata.sh` now runs each load inside `systemd-run --user --scope -p MemoryMax=`, set to RAM minus 6 GB, so an overrun kills Strata rather than your session. On a 96 GB machine that cap never binds.

Distinguish the failure modes before changing anything. There are three, not two, and they need different queries:

```sh
# 1. The kernel OOM killer. Note that -k implies -b, so this is THIS BOOT
#    only - add -b -1 for the previous one. A kill looks like
#    "Out of memory: Killed process 1234 (code)".
journalctl -k | grep -iE 'out of memory|killed process'

# 2. systemd-oomd, which kills a whole cgroup on memory-pressure before the
#    kernel ever runs out. It is a SYSTEM service, so no --user, and it logs
#    nothing to the kernel buffer - query 1 cannot see it.
journalctl -u systemd-oomd --since -3d --no-pager | tail -30
systemctl is-active systemd-oomd

# 3. Everything, across reboots, when the first two come back empty.
journalctl --since -3d --no-pager | grep -iE 'oom|killed process|oom-kill'
```

`OOM killer disabled.` followed immediately by `OOM killer enabled.` is **not** an OOM event — the kernel disables it while freezing processes for suspend, so that pair just marks a suspend/resume cycle.

If all three are empty and the editor *reloaded its own window* or said `JavaScript heap out of memory`, nothing on the system killed it: that is the editor's own renderer heap, which is capped around 4 GB regardless of how much RAM you have. Strata and `hf` emit a very large number of progress-bar redraws, and the integrated terminal keeps them all. Lower the scrollback limit or, again, do not run the installer in it.

**I am on 32 GB and want to pre-download the 96 GB packs anyway.**
That is supported, with one caveat worth knowing: Strata has no download-only mode. `strata launch --plan` previews without downloading, and `strata models` only inspects — fetching happens as part of a real launch. So the pack downloads in full, the load that follows is killed, and the run reports a failure at the end. **The download is kept**, so after fitting the memory the same command only loads. Tiers F and G warn about exactly this before starting.

**Switching models says a model is already running.**
Only one serves at a time. Run `strata launch --stop` first, or add `--restart` to the new launch. Under `--no-tui` it refuses rather than prompting.

## ComfyUI

**Out of memory during video generation.**
Expected with Wan 2.2 14B at anything above 832×480. Either drop to the TI2V-5B model, or use the Q4_K_M GGUF with the LightX2V 4-step LoRAs at 832×480. Make sure nothing else holds VRAM — Strata in particular.

**Models download but ComfyUI does not see them.**
Check `extra_model_paths.yaml` in the ComfyUI directory and confirm `base_path` points at the models folder — `~/ai/comfyui/models` on Ubuntu, `C:\AI\comfyui\models` on Windows. Restart ComfyUI; it only reads that file at startup.

**Downloaded files ended up nested under `split_files/`.**
The Hugging Face CLI preserves repo-internal paths. `models/download-models.*` flattens them automatically; if you downloaded by hand, move the file up to the correct `models/<category>/` directory.

**A model repository returns 404.**
Repacks get renamed regularly. Search rather than guessing:

```bash
hf search z_image_turbo
```

Or use ComfyUI Manager's model browser, which tracks current locations.

## Voice server

**First request takes 30+ seconds.**
Models load lazily on first use. Only the first call is slow.

**`faster_whisper` fails to load on CUDA.**
The server falls back to CPU automatically and logs a warning. To force it: `--whisper-device cpu --whisper-compute-type int8`.

**Speech returns 400 for mp3.**
`libsndfile` in that wheel lacks MP3 encoding. Use `response_format=wav`, which always works.

## Remote access

**`tailscale serve` says HTTPS is not enabled.**
Follow the URL it prints and consent in the browser. One-time, per tailnet.

**The tailnet URL resolves but times out.**
The service behind it is not running. Check `curl http://127.0.0.1:<port>/` on the workstation first, then `tailscale serve status` for the mapping.

**Nothing is reachable and the workstation looks offline.**
Most likely it is booted into the other OS. Windows and Ubuntu are independent systems and never run at once, so only the one currently booted answers. Sleep also drops the tunnel.

**Open WebUI will not start, or port 8080 is busy.**
Open WebUI defaults to 8080, which is Strata. Start it with `--port 3000`.

**Everyone gets logged out of Open WebUI after a restart.**
`WEBUI_SECRET_KEY` is being regenerated each time. Persist it to a file and load it from the service definition.

**Open WebUI shows an empty model list.**
Either the connection URL is wrong — it should be `http://127.0.0.1:8080/v1`, since Open WebUI runs on the same machine — or the backend has no `GET /v1/models`. Add the model IDs by hand under Model IDs in the connection settings.

**Tailscale SSH does not work on Windows.**
Expected; the server component is Linux and macOS only. Use the OpenSSH server over the tailnet IP instead. Full detail in [remote-access.md](remote-access.md).

## Server platform

**Start here for anything in phases 12–21:**

```bash
ai-status                      # memory, VRAM, model ports, cluster state
kubectl get pods -A            # what is actually running
```

**LiteLLM restarts forever on first install; the logs always stop at the same line.**
The giveaway is that `kubectl logs deployment/litellm` and `kubectl logs deployment/litellm --previous` are byte-identical and end at the same instant, somewhere after:

```
Found 233 migrations at /app/.venv/.../litellm_proxy_extras
Waiting for the Prisma migration lock (up to 600.0s)
Acquired the Prisma migration lock
```

This is not a database problem — reaching the migration lock proves Postgres is up, reachable and authenticating. LiteLLM applies its full schema before it binds port 4000, and it allows itself 600 seconds. Port 4000 is closed for that whole period, so every HTTP probe fails.

The trap is that the failure sustains itself. A liveness probe that fires during the migration kills the container part-way; the replacement starts all 233 migrations again from the beginning; it is killed at the same point. It can never finish, because the restart budget is smaller than the work. Raising `initialDelaySeconds` is the wrong fix: no value large enough to cover a first-boot migration is a sensible steady-state liveness setting, and you would be choosing between killing a healthy slow start and ignoring a genuinely wedged process for ten minutes.

`startupProbe` exists for this. Liveness does not begin counting until it has succeeded once, so the two cases get separate budgets. Both manifests carry `periodSeconds: 10` with `failureThreshold: 90` — 900 seconds, over LiteLLM's own ceiling. Later boots have nothing to migrate and pass in under a minute, so it costs nothing in the normal case.

**That probe fix is necessary but not sufficient.** With it in place the pod stops restarting and simply hangs at `0/1 Running` forever, at zero CPU, with the log stopping mid-sentence. The cause is the AppArmor defect described in the next entry: Prisma finishes its work and then cannot kill its own schema-engine subprocess. Run the CLI by hand to see it, because LiteLLM swallows the error:

```bash
kubectl -n platform exec deploy/litellm -- sh -c \
  'cd /app/.venv/lib/python3.*/site-packages/litellm_proxy_extras; \
   timeout 90 /opt/prisma/binaries/node_modules/.bin/prisma migrate status --schema ./schema.prisma'
```

```
Database schema is up to date!
[schema-engine] error: Error: kill EACCES
    at SchemaEngine.stop (.../prisma/build/index.js)
  errno: -13, syscall: 'kill'
```

Note the order: the work succeeds, then the shutdown fails. `appArmorProfile: Unconfined` on the pod is the fix, and it is already in both the manifest and the chart.

Do not reach for `DISABLE_SCHEMA_UPDATE=True`. It looks like it helps — the migration log lines disappear — but LiteLLM then runs `prisma migrate diff` to check for drift instead, which hangs in exactly the same place. It moves the symptom one step and wastes an afternoon.

If a run was interrupted often enough to leave a half-applied migration, Prisma records it and then refuses to move:

```bash
kubectl -n platform exec deploy/postgres -- psql -U postgres -d litellm \
  -c "select migration_name, finished_at from _prisma_migrations where finished_at is null;"
```

Any row there must be cleared before it will progress. Note that `09-gpu-queue.sh` puts the job and profile tables in this same `litellm` database, so dropping the database to start clean means re-running that script afterwards.

**A pod stays `Running`, never becomes ready, and its logs are completely empty.**
Not slow, not erroring — zero bytes. `kubectl logs` returns nothing and `/var/log/pods/<namespace>_<pod>_*/<container>/*.log` is an empty file. Every probe fails, the liveness probe eventually restarts it, and the cycle repeats without a single line of output.

Check the kernel log rather than anything in Kubernetes:

```bash
sudo dmesg -T | grep -i 'apparmor.*DENIED'
```

On Ubuntu 24.04 and later this is usually AppArmor blocking `gosu`:

```
apparmor="DENIED" operation="signal" comm="gosu" requested_mask="send" signal=rtmin+1
```

Many official images start as root and drop privileges with `gosu` before exec'ing the real process. `gosu` is written in Go, and the Go runtime signals its own threads with `rtmin+1` to preempt goroutines. The AppArmor profile containerd applies denies cross-profile signals, so `gosu` hangs *before* it execs anything. The container is alive and the application has never run, which is why there is nothing to log.

The fix is to not become root in the first place, since these entrypoints only call `gosu` when they find themselves running as uid 0:

```yaml
securityContext:
  runAsUser: 70        # the uid the image expects; postgres:*-alpine is 70
  runAsGroup: 70
```

For a `hostPath` volume you also need an init container to `chown` the directory, because `fsGroup` does nothing there — the kubelet only manages ownership for volume plugins that support it, and `hostPath` is not one. `server/k8s/10-postgres.yaml` has a worked example of both halves.

This affects any image using `gosu` or `su-exec`, so expect it in the Minecraft, n8n and Open WebUI manifests if you change their images.

### The same denial, the other shape: `kill EACCES`

`runAsUser` only helps when the signal in question is the one sent during a startup privilege drop. The profile denies *all* cross-profile signals, so it equally breaks a long-running process that supervises a child — and there the symptom is different and much harder to read. Instead of a container that logs nothing, you get one that does its whole job, logs the success, and then hangs forever at zero CPU while shutting down.

LiteLLM is the worked example. Prisma applies all 233 migrations, prints `Database schema is up to date!`, and then cannot terminate its own schema-engine:

```
[schema-engine] error: Error: kill EACCES
  errno: -13, syscall: 'kill'
```

Postgres shows the third variant — it survives, but is denied the signals it uses internally:

```
apparmor="DENIED" operation="signal" comm="postgres" requested_mask="send" signal=urg
```

`SIGURG` is how one Postgres 16 backend wakes another's latch. Simple queries need no wakeup and return normally, so the database looks healthy while these fire several times a second.

For these, `Unconfined` on the pod is the right answer rather than a shortcut:

```yaml
spec:
  securityContext:
    appArmorProfile:
      type: Unconfined
```

The earlier advice here was that `Unconfined` is the wrong trade. That holds for the `gosu` case, where it disables confinement for the life of the pod to fix one thirty-second privilege drop. It does not hold when the denied signals are part of normal operation, because then there is nothing to sidestep — the alternatives are patching the host profile, which every containerd upgrade would silently revert, or not running the workload.

How to tell which you are looking at: a container that logs **nothing at all** wants `runAsUser`; one that logs its work and then **hangs at zero CPU** wants `Unconfined`. Check with `cat /proc/1/stat | cut -d' ' -f14,15` twice a few seconds apart — identical numbers mean blocked, not slow.

**`kubectl logs` and `kubectl exec` fail with `x509: certificate is valid for ... not <IP>`.**
The node registered under one address and the kubelet's serving certificate was issued for another — typically because Tailscale was up when the node first registered, so the node advertises `100.x.y.z` while the certificate covers the LAN address. Everything that proxies through the kubelet breaks: `logs`, `exec`, `cp`, `top`. Scripts that pipe SQL in with `kubectl exec` fail in ways that look like SQL errors.

Deleting the certificate does not help; k3s regenerates it with the same addresses. Pin the node address instead:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo sh -c 'printf "node-ip: 192.168.1.139\n" >> /etc/rancher/k3s/config.yaml'
sudo systemctl restart k3s
kubectl get nodes -o wide
```

Use the LAN address rather than the Tailscale one, so the cluster's internal addressing does not depend on Tailscale being up. Check the file first — appending a duplicate `node-ip` key stops k3s from starting. Container logs are readable from disk meanwhile, under `/var/log/pods`, which needs no working kubelet.

**A one-off `kubectl run` in `platform` is rejected with `failed quota: platform-ceiling`.**
The namespace quota requires every container to declare `requests.cpu`, `requests.memory` and `limits.memory`, and `kubectl run` sets none by default. This applies to init containers too:

```bash
kubectl -n platform run probe --rm -i --restart=Never --image=alpine \
  --overrides='{"spec":{"containers":[{"name":"probe","image":"alpine","command":["sh","-c","id"],"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"64Mi"}}}]}}'
```

Or use the `games` namespace, or `default`, neither of which is capped this way.

**`02-k3s.sh` ends with `mkdir: Permission denied`, four times.**
`01-server-base.sh --apply` has not been run. It is what creates `/srv/platform`, `/srv/games` and `/srv/backups` and hands `/srv` to your user; the PersistentVolumes in phase 13 bind to directories inside `/srv/platform` and are created as you, not with `sudo`.

The script now refuses at the start rather than part way through, but if you hit the old behaviour the cluster is half-built: k3s, kubectl, the GPU runtime and the namespaces exist, while the PVs, the host-model bridge and the loopback forwarding do not. Nothing is corrupted and no cleanup is needed:

```bash
./01-server-base.sh --apply
./02-k3s.sh                    # re-runnable; finishes the part that was skipped
```

Creating `/var/lib/rancher/k3s/storage` by hand does not help — that directory belongs to k3s, which runs as root and makes it when first needed. The line naming it in the output is informational, not the failure.

**`kubectl logs` fails with `certificate is valid for ... not 100.x.x.x`.**
k3s registered the node under its Tailscale address, and the kubelet serving certificate was issued for the LAN address instead. Everything that goes through the kubelet — `logs`, `exec`, `port-forward`, `top` — fails, while the cluster otherwise looks completely healthy. The usual trigger is Tailscale coming up between two k3s starts, because phase 13 restarts k3s to pick up the nvidia runtime.

`02-k3s.sh` now pins `--node-ip` at install and repairs an existing node on re-run, so the fix is to run it again. By hand it is the same two steps — k3s reissues the certificate from the current addresses whenever it is missing:

```bash
sudo systemctl stop k3s
sudo rm -f /var/lib/rancher/k3s/agent/serving-kubelet.{crt,key}
sudo systemctl start k3s
```

Confirm which address the node is actually using with `kubectl get node -o wide`. If it is a `100.x` address and you would rather it were not, pin it in `/etc/rancher/k3s/config.yaml` with `node-ip: <lan address>` and restart.

**`03-platform.sh` reports "Postgres did not start" and the pod never schedules.**
Almost always a missing PersistentVolumeClaim rather than anything wrong with Postgres. Check the claims before the logs:

```bash
kubectl -n platform get pvc
kubectl -n platform describe pod -l app=postgres
```

If the claims are absent, phase 13 did not finish — `02-k3s.sh` applies `k8s/02-storage.yaml` on the line immediately after it creates the `/srv/platform` subdirectories, so the permission failure described above stops it exactly one line short of creating the storage. Run `./01-server-base.sh --apply`, then `./02-k3s.sh`, then `./03-platform.sh`. The script now refuses up front if the claims are missing rather than waiting 180 seconds for a pod that cannot schedule.

**A pod sits `Pending` forever.**
Three causes, in order of likelihood. `kubectl -n platform describe pod <name>` names which one.
1. The namespace ResourceQuota is full. Every pod must declare requests and limits, and the totals are capped at 12Gi requests in `platform` and 8Gi in `games`.
2. There is not enough free memory, usually because Strata has mlocked it. `ai-pause` frees the platform's share.
3. It requests `nvidia.com/gpu` and the card is already assigned. **The GPU is indivisible** — one pod gets all of it, and Strata on the host is already using it.

**A pod cannot reach Strata, llama.cpp or the voice server.**
Check in this order:
```bash
curl -s http://127.0.0.1:8080/v1/models          # is the model server even up
systemctl status ai-model-bridge                 # is the socat bridge running
kubectl -n platform get endpointslices           # does the slice have the right IP
ip -4 addr show cni0                             # has the host IP changed
```
The usual cause is simply that Strata is not loaded. The second is that `cni0` got a different address after a cluster rebuild, leaving the EndpointSlice pointing at nothing — re-run `server/02-k3s.sh`.

**LiteLLM returns 500s shortly after deploying.**
It runs database migrations on first start. Wait, then `kubectl -n platform logs deploy/litellm`.

**A model call through the gateway times out.**
Expected behaviour, not a fault. `num_retries` is 0 on purpose: a timeout means the model is loading or the queue is deep, and retrying makes both worse. `max_parallel_requests` is 4, so requests genuinely queue.

**n8n reports that credentials cannot be decrypted.**
`N8N_ENCRYPTION_KEY` changed. Restore `/srv/platform/secrets/n8n-encryption-key` from backup and restart n8n. Without that file the credentials are unrecoverable and must be re-entered by hand. If you are restoring a whole machine, this is the step people get wrong: put the secrets back *before* starting n8n, or it mints a fresh key and the restored credentials stay unreadable even though you have both the database and the original key.

**The nightly backup reported errors.**
```bash
systemctl status platform-backup.service
journalctl -u platform-backup.service --since yesterday
```
A skipped Postgres dump usually means `ai-pause` had scaled it to zero, which is expected and logged rather than failed. The one message to act on immediately is a failure to re-enable Minecraft saving — run `games rcon` and issue `save-on`, or the world silently stops persisting.

**Is anything actually being backed up?**
```bash
platform-restore local     # local dumps, with dates
platform-restore list      # offsite snapshots
platform-restore check     # verify the repository reads back
```
If `list` says no offsite target is configured, backups are local-only and a drive failure still loses everything. Fill in a provider in `/srv/platform/secrets/backup.env`. See [backups.md](backups.md).

**Everything died at once.**
```bash
dmesg -T | grep -i 'oom\|killed process'
```
An OOM kill under memory pressure often takes k3s rather than whatever overcommitted. The kubelet eviction thresholds set in `02-k3s.sh` are what should prevent this; if it still happens, the 16 GB swapfile from `01-server-base.sh` is probably missing.

**`kubectl` says permission denied or cannot connect.**
`KUBECONFIG` is unset in this shell. `export KUBECONFIG=$HOME/.kube/config`, which `~/.profile` sets for login shells but not for a fresh `sudo -i`.

**A game server starts but nobody can join.**
If it is a UDP game, check the Service declares `protocol: UDP`. A UDP game exposed as TCP produces a server that looks perfectly healthy and that no client can reach.

**A friend's key stopped working.**
`friends list` shows whether it is blocked or over budget. Budgets are in notional dollars against local models, so "out of budget" means they have used a lot of tokens, not that anything was charged.

Deeper material: [kubernetes.md](kubernetes.md), [server-architecture.md](server-architecture.md), [agent-orchestration.md](agent-orchestration.md).

## GPU queue

**Everything waits, but `nvidia-smi` shows the card idle.**
The GPU probe is down, so the queue has fallen back to its static floor of two light requests and one heavy. `curl -s http://127.0.0.1:8101/gpu`, then `systemctl status gpu-probe`. The service degrades rather than failing, which is why this looks like a scheduling bug rather than a dead process.

**Requests get `429` instead of waiting.**
Something is calling LiteLLM on 4000 directly rather than the queue on 4100. That is what 4000 does — only the queue holds requests. Check what the client is configured with; for friends, check `tailscale serve status` points `:8447` at 4100.

**Someone's system prompt or skills are ignored.**
They have no profile row. `friends profile <name>` creates one on first use and shows it. Also confirm the key alias matches — the queue identifies people by LiteLLM key alias, so a key created without `--key_alias` has nothing to attach a profile to.

**Jobs sit at `queued` and never start.**
A heavy slot is held by something long-running. `queue list` shows what is in flight and for how long; `queue cancel <id>` releases a job that has not started. A render has a one-hour cap, so a genuinely stuck one clears itself eventually.

**The queue admits nothing at all.**
It is draining. `queue status` says so on the first line. `queue resume`. This is the state `ai-pause` leaves it in if it was interrupted between draining and scaling down.

**Two people get more concurrency than the limit says.**
There should only ever be one replica — admission counters are in memory, so a second replica would admit up to the limit independently. `kubectl -n platform get deploy gpu-queue` should show `1/1`.

Deeper material: [gpu-queue.md](gpu-queue.md).

## Code sandbox

**`multipass launch` fails with `failed to open file ... multipass_root_cert.pem`.**
The snap finished installing but its daemon had not generated its certificates yet. Wait a few seconds and re-run `./10-sandbox.sh --apply`. Re-running is always safe.

**The VM's address comes back as `zone1` or another nonsense value.**
Something is reading `multipass info --format csv` by column position. multipass 1.17 added a `Zone` column ahead of `IPv4`, so every positional field after it shifted by one. The kit reads by header name now; if you have a script of your own doing this, fix it the same way. The failure is quiet and delayed — the address gets written into the cluster bridge, and what you see later is n8n timing out.

**Sysbox installs, then `ERROR: sysbox service is not running`.**
The package is fine. Look further up for `Could not execute systemctl: at /usr/bin/deb-systemd-invoke line 148` — dpkg's post-install script cannot reach systemd over a non-interactive `multipass exec`, so the units are written and enabled but never started, and the installer's own closing check then fails. Start them by hand:

```sh
multipass exec n8n-sandbox -- sudo systemctl enable --now sysbox
multipass exec n8n-sandbox -- sudo systemctl restart docker
multipass exec n8n-sandbox -- docker info --format '{{json .Runtimes}}'
```

That last line is the real test; it must mention `sysbox-runc`. `./10-sandbox.sh --apply` now does all three itself.

**n8n cannot reach the sandbox although the VM is running.**
`./10-sandbox.sh --status` compares the VM's current address against the one in the EndpointSlice and says so if they differ. A guest that was rebuilt, or simply rebooted, can come back on a new address, and nothing in the cluster notices: the Service still resolves and the EndpointSlice still looks valid. `--apply` rewrites it.

**Did a failed run leave a second VM behind?**
No. The VM is addressed by name, so a re-run starts the existing one instead of launching another, and the containers are one named compose project. `multipass list` is the direct check, and `--status` warns if it sees any other VM with `sandbox` in its name.

**The VM is up but the API does not answer.**
First check whether the service was ever installed: `./10-sandbox.sh --status` lists the running containers, and if there are none, the previous `--apply` stopped before reaching them. Re-run `--apply`. If the containers are there, `--logs` — usually an image still pulling — and `--restart` recreates them without rebuilding the guest.

**Something inside the guest asks for the ubuntu password.**
There isn't one, and nothing is hiding it. multipass authenticates with its own key and grants the `ubuntu` user passwordless sudo, so no password was ever generated. A prompt means the program wanted a terminal rather than a credential — run it as `sudo <command>` directly. If you want a real password, `./10-sandbox.sh --password` sets one.

Also: there is no need to run anything in the guest by hand. `./10-sandbox.sh --apply` does every step non-interactively and is safe to re-run.

**Reclaiming the memory.**
`multipass stop n8n-sandbox` gives back 6 GB. Nothing else breaks — n8n starts without the sandbox, and only the Assistant's code execution stops working.

## GitOps and Argo CD

**An Application is `OutOfSync` and stays that way.**
Usually a render that was never committed. `gitops commit`. If it persists, `gitops diff` shows what Argo CD is seeing that you are not.

**An Application is stuck in `Unknown`.**
Argo CD cannot reach the repository. The git daemon is a host service, not a pod: `systemctl status git-daemon`. Confirm it is bound to the cni0 address and that `/srv/gitops.git` still contains its `git-daemon-export-ok` marker.

**Changes are committed but nothing happens.**
That app is on manual sync. `gitops apps` shows which. `gitops sync <app>` once, or `gitops automate <app>` permanently.

**`ImagePullBackOff` on an image you built yourself.**
There is no registry on this machine, so the image has to be imported into k3s directly: `gitops build <chart>`. The manifests set `imagePullPolicy: Never` on purpose — with `IfNotPresent` a failed import silently falls through to a Docker Hub lookup and the error names a public image you never referenced.

**Pods scale back up moments after `ai-pause`.**
Argo CD's self-heal is undoing it. The installed `ai-pause` is from before phase 20: re-run `01-server-base.sh`, which compares a version marker and replaces it. A stale copy appears to work, which makes this unpleasant to diagnose from scratch.

**A deleted file did not delete anything.**
Correct. `prune: false` everywhere. Removing an object is a deliberate `kubectl delete`; the Application will report `OutOfSync` until you do.

Deeper material: [gitops.md](gitops.md).

## Linux gaming

**A game will not launch.**
In this order, because it finds the cause fastest: check protondb.com for that title; try a different Proton version; run `gaming-check` to see whether Strata is holding the memory; launch from a terminal to see the real error.

**A game that used to run is now unplayably slow.**
Almost always the model. `ai-status`, then `ai-pause`.

**An online game rejects you or bans the account.**
Kernel-level anti-cheat. Valorant, Fortnite, Destiny 2, PUBG, modern Call of Duty and Rainbow Six Siege do not run on Linux and there is no workaround. See [linux-gaming.md](linux-gaming.md).

## Sanity checks

```bash
nvidia-smi dmon -s pucm        # live GPU utilisation, power, memory
watch -n1 'free -h; echo; nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv'
ai-status                      # the same picture plus the cluster
```

On Windows, HWiNFO (installed in Phase 5) gives the same picture plus thermals. Under sustained load the 9800X3D on a 240 mm AIO should stay well under 85 °C; if it does not, check the pump header is set to full speed in BIOS.
