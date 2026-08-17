# Obsidian Git Backup Sidecar

A push-only Git backup companion for
[`obsidian-headless-sync-docker`](../obsidian-headless-sync-docker). It watches a
vault mounted read-only, copies stable snapshots into its own persistent Git
working tree, commits debounced changes, and pushes them to an empty Gitea
repository over SSH.

The live vault never contains a `.git` directory and this container never
writes to it. It also never pulls, fetches, merges, rebases, or checks out files
from Gitea. The persistent backup directory is the sole Git writer, so Gitea
should be treated as a backup destination rather than an editable remote.

## Why these debounce defaults?

- `DEBOUNCE_SECONDS=120` waits for two quiet minutes after the last filesystem
  event, allowing Obsidian Sync's burst of related writes to settle.
- `MAX_WAIT_SECONDS=900` prevents continuous activity from postponing a backup
  forever: one snapshot is taken at least every 15 minutes while changes flow.
- `RESCAN_SECONDS=300` detects content changes even if an inotify event is lost
  and retries a previously failed push.
- Each snapshot uses two `rsync` passes one second apart. Git operates only on
  the copied working tree, eliminating `.git/index.lock` and checkout conflicts
  with Obsidian Sync.

These settings typically produce one commit per editing/sync session rather
than one commit per file event. Raise the quiet window to 300 seconds if your
vault receives long bursts and you prefer fewer commits.

## Setup

1. In Gitea, create a **private, empty** repository. Do not initialize it with a
   README, license, or `.gitignore`. This sidecar intentionally does not pull or
   reconcile remote history.
2. Copy and edit the environment file:

   ```sh
   cp .env.example .env
   ```

3. Generate the sidecar's SSH key (it is saved under `BACKUP_DATA_PATH`):

   ```sh
   docker compose run --rm obsidian-git-backup print-key
   ```

   Add the printed key to Gitea as a repository deploy key with write access
   (or as an account SSH key).

4. Pin Gitea's SSH host key. From a trusted machine/network, capture it and
   verify its fingerprint with your Gitea administrator:

   ```sh
   ssh-keyscan -H gitea.example.com > ./data/ssh/known_hosts
   ```

   Alternatively, put the complete verified `known_hosts` line in
   `SSH_KNOWN_HOSTS` in `.env`. Host checking is deliberately never disabled.

5. Start the backup sidecar:

   ```sh
   docker compose up -d --build
   docker compose logs -f
   ```

The first successful start snapshots the entire vault and pushes `main`.

## Running beside the sync container

Both compose projects can bind-mount the same host path. The sync service keeps
its existing writable mount:

```yaml
- ${VAULT_HOST_PATH:-./vault}:/vault
```

This sidecar mounts that exact host path read-only:

```yaml
- ${VAULT_HOST_PATH:-./vault}:/vault:ro
```

For the existing neighboring checkout, the example value is:

```env
VAULT_HOST_PATH=../obsidian-headless-sync-docker/vault
```

Multi-vault mode works without special handling: the parent `/vault` tree,
including each vault subdirectory, is backed up in one Git repository.

## Operational notes

- Use one running sidecar and one persistent `BACKUP_DATA_PATH` per Gitea
  repository. A second writer or edits made in Gitea can cause a non-fast-forward
  rejection; the sidecar will report it and will not force-push.
- If Gitea is unavailable, commits accumulate locally and pushes are retried.
  No vault data is modified or blocked.
- Deletions are reflected in backup commits because `rsync --delete` mirrors
  the current vault. Git history still retains prior versions.
- The SSH private key and Git history live in `BACKUP_DATA_PATH`; protect and
  back up that directory appropriately. The generated key has no passphrase so
  the unattended container can use it.
- `PUID`/`PGID` control ownership only in the sidecar data directory. The vault
  needs only to be readable by that identity.

## Configuration

| Variable | Default | Purpose |
|---|---:|---|
| `GIT_REMOTE_URL` | required | Gitea SSH repository URL |
| `GIT_BRANCH` | `main` | Branch pushed to Gitea |
| `GIT_AUTHOR_NAME` | `Obsidian Backup` | Commit author name |
| `GIT_AUTHOR_EMAIL` | `obsidian-backup@localhost` | Commit author email |
| `COMMIT_MESSAGE` | `Obsidian backup` | Commit message prefix |
| `DEBOUNCE_SECONDS` | `120` | Required quiet time |
| `MAX_WAIT_SECONDS` | `900` | Maximum batching window |
| `RESCAN_SECONDS` | `300` | Periodic rescan/retry interval |
| `PUSH_RETRIES` | `5` | Push attempts per snapshot |
| `PUSH_RETRY_SECONDS` | `30` | Delay between push attempts |
| `SSH_KNOWN_HOSTS` | empty | Verified host-key line(s) |
| `PUID` / `PGID` | `1000` | Runtime identity |
