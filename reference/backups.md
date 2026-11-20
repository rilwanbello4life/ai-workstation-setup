# Backups and disaster recovery

Installed by [`../server/07-backup.sh`](../server/07-backup.sh).

## What is actually at risk

The machine has one data drive and no redundancy. Sorted by how bad losing it would be, rather than by size:

| Data | Size | Recoverable without a backup? |
|---|---|---|
| `secrets/n8n-encryption-key` | 64 bytes | **No.** Every credential n8n has stored becomes permanently unreadable |
| `secrets/` generally | a few KB | No. Database passwords, API keys, the LiteLLM master key |
| Postgres | MB to GB | No. Agent history, prompt versions, spend, any app data |
| n8n workflows | KB | Only by rebuilding each one by hand |
| Game worlds | GB | No |
| Manifests in `server/k8s/` | KB | Yes, from this kit |
| Model files | ~1 006 GB | Yes, re-downloadable |

The pattern worth noticing is that **everything irreplaceable is small**. The whole protected set is megabytes to a few gigabytes, which is why offsite storage costs about 50 kr a month rather than being a hardware project.

## Why not a NAS

A NAS answers three questions, and this machine asks none of them.

**Capacity** is not the problem the NAS would solve. The 2 TB drive is tighter than the original 4 TB plan, but what needs protecting is under 10 GB — databases, workflow definitions, secrets and world saves. Buying terabytes to store gigabytes is the wrong shape of answer, and the things that *are* large here, the model packs and the Steam library, are re-downloadable.

**Shared storage across machines** does not apply to one machine.

**Redundancy** is the one that sounds right and is not. RAID protects against a disk failing. It does not protect against fire, theft, flood, ransomware, a bad migration, or `DROP TABLE` — and those are collectively far more likely than the single failure mode it does cover. A second box in the same room shares every risk that actually destroys data.

There is also a reason a NAS would hurt: the only large data here is the model files, and Strata streams cold experts off the SSD during generation. Those cannot live on network storage at any speed worth paying for.

Offsite object storage is strictly better protection for this workload, at a fraction of the cost and with no hardware to maintain.

## Two layers

They fail differently, which is the point of having both.

**Local, `/srv/backups`, same drive.** Protects against mistakes: a dropped table, a bad migration, an upgrade that ate a world. Fast to restore from, 14 days of retention. Useless if the drive dies.

**Offsite, restic to B2 or S3, encrypted before it leaves the house.** Protects against drive failure, fire, theft and ransomware. Retention is 7 daily, 4 weekly, 6 monthly.

Offsite is optional. With no provider configured the nightly job still runs and keeps local snapshots, so it is useful from day one and gains the second layer whenever you get round to it.

## The circular dependency

This is the detail that makes most home backups worthless, so it is worth stating plainly.

The restic repository is encrypted with a password. That password is generated into `/srv/platform/secrets/restic-password`, and the secrets directory is itself inside the backup. **If the only copy of the password is on the machine being backed up, then losing the machine loses the ability to read the backups.** The backup still exists; it is simply ciphertext forever.

Two values must therefore live somewhere that is not this machine:

- the **restic repository password**, or you cannot read the offsite copy
- the **n8n encryption key**, or a restored n8n cannot decrypt its own credentials

A password manager on another device, or paper in a drawer. The setup script prints the restic password once, on first run, for exactly this reason.

Neither the storage provider nor anyone else can recover these. That is a property of client-side encryption, not an oversight.

## Choosing a provider

```sh
sudoedit /srv/platform/secrets/backup.env
```

The file is written with all three options commented out.

| Provider | Cost | When it fits |
|---|---|---|
| **Backblaze B2** | ~6 USD per TB per month | The default. Cheapest at this volume |
| **AWS S3** | ~23 USD per TB per month | You already have an account and want one bill |
| **SFTP** | free | A friend's machine, or a box at another address |

Two things to get right whichever you pick. Use an **application key scoped to the one bucket**, never a master key or a root access key — a key with broad permissions on a machine that also runs other people's AI jobs is a bad combination. And if the provider supports **versioning or object lock**, enable it, because otherwise a compromised key can delete the backups as easily as it can write them.

## Running it

```sh
platform-backup              # now, local then offsite
platform-backup --local      # skip the offsite push

platform-restore list        # offsite snapshots
platform-restore local       # what is on this drive
platform-restore check       # verify the repository reads back
```

The nightly timer fires at 03:30 with up to 15 minutes of jitter, and `Persistent=true` means a night spent in Windows or powered off is caught at the next opportunity rather than silently skipped.

## What the nightly job does

`pg_dumpall` rather than `pg_dump`, because it captures roles and their passwords — without which a restore produces databases that nothing can log into. The dump is checked for gzip integrity and a plausible size afterwards, since a dump that failed halfway still exits zero through a pipe.

n8n workflows are exported as JSON **in addition to** being inside the Postgres dump. They are already in that dump, but as encrypted rows in a schema only n8n understands. The JSON is readable and importable by hand, and it is what saves you when the database restore is the part that is broken.

Minecraft is told to flush and hold writes with `save-off` / `save-all` before the world is copied, and `save-on` afterwards — unconditionally afterwards, including when something above failed, because a world that silently stops saving is worse than a missed backup. If that step ever fails the job says so loudly.

If Postgres is scaled to zero because you ran `ai-pause`, the job skips the database and says so. Skipping is correct there; failing would train you to ignore the output.

## Restoring

### A single database, after a mistake

```sh
platform-restore local                                   # find the dump
platform-restore postgres /srv/backups/postgres/pg-....sql.gz
kubectl -n platform rollout restart deploy/litellm deploy/n8n
```

This is **destructive**: the dump is taken with `--clean --if-exists`, so it drops and recreates every object it contains. Read the file first if you are unsure what is in it.

### The whole machine, from nothing

The order matters, because each step depends on the one before.

1. Install Ubuntu and run phases 8 and 12–14 as normal. You now have an empty cluster.
2. Restore the repository password from wherever you wrote it down, into `/srv/platform/secrets/restic-password`.
3. Recreate `backup.env` with the provider credentials.
4. `platform-restore list`, then `platform-restore fetch <snapshot-id> /tmp/restore`.
5. Copy `secrets/` back **before** starting anything, so n8n comes up with the encryption key it expects rather than generating a new one.
6. Load the Postgres dump.
7. Copy game worlds back into `/srv/games`.
8. Re-run `server/03-platform.sh`, which is idempotent and will reuse the restored secrets rather than generating new ones.

Step 5 is the one people get wrong. Starting n8n first makes it mint a fresh encryption key, and the restored credentials then cannot be decrypted even though you have both the database and the original key.

## Test it

```sh
platform-restore check       # monthly
```

That reads back a 5% sample of the actual data rather than only checking metadata, which is the difference between knowing the repository is intact and assuming it.

Once, early on, restore something for real — fetch a snapshot to `/tmp` and look at it. An untested backup is a hope, and the failure modes that matter only appear on the way back in.
