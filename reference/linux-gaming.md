# Gaming on Ubuntu

Installed by [`../ubuntu/09-gaming.sh`](../ubuntu/09-gaming.sh).

The reason this phase exists: the plan is for Ubuntu to be the machine you actually use, with Windows kept bootable as a fallback you rarely touch. Whether that works is decided almost entirely by one thing, so read the anti-cheat section before anything else.

## The one thing that decides it

**Anti-cheat, not performance.** Proton runs the overwhelming majority of single-player games at 90–100% of their Windows framerate, and on an RTX 5070 Ti with a 9800X3D you will not notice the difference in most titles. What Proton cannot do is run kernel-level anti-cheat that the publisher has not enabled for Linux.

### Will not run on Linux, at all

| Game | Why |
|---|---|
| Valorant | Vanguard, kernel-level, Windows-only by design |
| Fortnite | Easy Anti-Cheat, Epic has declined to enable Linux |
| Destiny 2 | BattlEye, bans Linux players on sight |
| PUBG: Battlegrounds | BattlEye, not enabled |
| Call of Duty (modern) | Ricochet, kernel-level |
| Rainbow Six Siege | BattlEye, not enabled |
| Roblox | Dropped Linux support deliberately |

This is not a configuration problem and there is no workaround. Attempting one risks a hardware ban on the account. **If you play any of these regularly, Windows is not a fallback — it is your gaming OS, and the always-on server plan has a real cost attached.**

### Runs fine

Apex Legends, Counter-Strike 2, Dota 2, Elden Ring, Baldur's Gate 3, Cyberpunk 2077, most of Steam's single-player catalogue, and anything with a native Linux build. EA and Respawn enabled Proton support for Apex; Valve's own titles are native.

Check any specific game at [protondb.com](https://www.protondb.com) before concluding anything. Gold or Platinum means it works.

## The memory conversation

This is where gaming meets the rest of the machine, and it is more awkward than the anti-cheat question because it bites daily rather than once.

A modern game wants 8–16 GB of system RAM and most of the 16 GB of VRAM. Strata wants 25–40 GB of system RAM and all the VRAM it can get. **They cannot both have it.**

What actually happens if you launch a game with Strata resident:

- Strata has `mlock`ed its experts, so that memory cannot be swapped or reclaimed. The kernel cannot page it out to make room.
- The GPU will have 2–14 GB already occupied by Strata's hot experts.
- The game either fails to allocate, or runs at a framerate that makes you close it.

So:

```sh
ai-pause          # stop the model servers and scale the cluster down
# play
ai-resume         # bring back exactly what was running
```

`ai-pause` records the replica count of every deployment before scaling it to zero, so `ai-resume` restores the state you had rather than a default. It does not relaunch Strata automatically — loading a pack takes 1–3 minutes and you should choose when to spend that.

If you only need VRAM and want the cluster to keep running:

```sh
ai-pause --games  # just the game servers
pkill -f strata   # just the model
```

### What you can leave running

| Service | During a game | Note |
|---|---|---|
| k3s, Postgres, n8n, LiteLLM | yes | ~5 GB, negligible GPU |
| Open WebUI | yes | idle cost is small |
| Strata | **no** | takes the RAM and the VRAM |
| llama.cpp | **no** | ~9 GB of VRAM |
| ComfyUI | **no** | 12–15 GB of VRAM when generating |
| A game server | maybe | 4 GB; fine for light games, not for a demanding one |

An n8n workflow firing mid-game will call a model that is no longer there and the run will fail. That is working as designed — the run log records it and you can re-run afterwards — but schedule anything important outside your play time.

## Proton

Steam Play runs Windows games through Proton, a Wine fork with Valve's patches. `09-gaming.sh` enables it for all titles, including those Valve has not whitelisted.

**Proton-GE** is a community build with extra media codecs and fixes that land ahead of Valve's releases. Install it with ProtonUp-Qt and select it per game under Properties → Compatibility. Try stock Proton first; reach for GE when a specific game misbehaves.

Shader compilation stutter on first launch is normal and not a misconfiguration. Steam downloads precompiled shader caches for popular titles; for the rest the first thirty minutes are rougher than the rest.

## What gets installed and why

| Package | Purpose |
|---|---|
| Steam | The launcher, and Proton comes with it |
| GameMode | Switches the CPU governor to performance and raises the game's I/O priority for its lifetime |
| MangoHud | FPS, frametime, CPU and GPU overlay — essential for knowing whether a problem is real |
| Lutris | Non-Steam games: GOG, Epic, Battle.net |
| ProtonUp-Qt | Installs and manages Proton-GE |
| `gamepad` udev rules | Non-Steam launchers often need these for controllers |

GameMode matters more here than on a typical desktop. The server tuning from `02-tune-linux.sh` may leave the governor somewhere sensible for sustained inference rather than for latency; GameMode overrides that for the duration of the game and puts it back afterwards.

Use them together:

```sh
gamemoderun mangohud %command%     # in Steam, Properties > Launch Options
```

## NVIDIA specifics

The open kernel modules installed in `01-nvidia.sh` are the right choice for Blackwell and are what NVIDIA supports going forward.

- **Wayland vs X11.** Wayland is the default on Ubuntu 24.04 and is now fine for most games, but some older titles and some overlays still behave better on X11. If a game will not go fullscreen properly or the overlay does not appear, log out and pick "Ubuntu on Xorg" at the login screen before debugging anything else.
- **G-Sync / VRR** works, but on Wayland it is per-monitor in Settings → Displays, and on X11 it needs `nvidia-settings`.
- **HDR** is still rough on Linux generally. If you care about it, that is a Windows reason.

## Where games live

Install them under your home directory on the 2 TB Ubuntu drive. In Steam: Settings → Storage → add a library folder.

Budget roughly **431 GB** for the library — about five modern titles at once, or 542 GB if you install Strata only through tier E. The AI stack is installed in full and takes priority on this drive, so gaming is what absorbs the smaller disk. [4tb-upgrade.md](4tb-upgrade.md) itemises what a larger drive would buy back.

Keep game installs out of `/srv`. That path is the backup target for the platform and game-server data, and a 200 GB Steam install inside it turns a quick backup into an impossible one.

## If a game will not start

In order, because this order finds it fastest:

1. **Check protondb.com for that specific title.** Most problems are known, with a known fix.
2. **Force a different Proton version.** Properties → Compatibility → try Proton Experimental, then Proton-GE.
3. **Check the memory.** `ai-status` — if Strata is resident, that is very likely your answer.
4. **Run from a terminal** to see the actual error: `steam steam://rungameid/<id>`.
5. **Delete the compatdata prefix** for that game and let it rebuild. This loses in-prefix save data for games that do not use Steam Cloud, so check first.

Verify the installation with:

```sh
gaming-check
```

which reports driver version, Vulkan status, whether GameMode is active, and whether anything is currently holding the memory a game would need.
