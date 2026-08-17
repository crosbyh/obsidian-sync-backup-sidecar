#!/bin/sh
set -eu

VAULT_PATH="${VAULT_PATH:-/vault}"
DATA_PATH="${DATA_PATH:-/data}"
REPO_PATH="${DATA_PATH}/repository"
SSH_PATH="${DATA_PATH}/ssh"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-120}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
RESCAN_SECONDS="${RESCAN_SECONDS:-300}"
PUSH_RETRIES="${PUSH_RETRIES:-5}"
PUSH_RETRY_SECONDS="${PUSH_RETRY_SECONDS:-30}"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
is_positive_int() { case "$1" in ''|*[!0-9]*|0) return 1;; *) return 0;; esac; }

case "${SSH_KEY_TYPE:-ed25519}" in
  ed25519|ecdsa|rsa) ;;
  *) fail "SSH_KEY_TYPE must be ed25519, ecdsa, or rsa" ;;
esac

mkdir -p "$REPO_PATH" "$SSH_PATH"
chown -R "$PUID:$PGID" "$DATA_PATH"
chmod 0700 "$SSH_PATH"

KEY_FILE="$SSH_PATH/id_${SSH_KEY_TYPE:-ed25519}"
if [ ! -f "$KEY_FILE" ]; then
  log "Generating ${SSH_KEY_TYPE:-ed25519} SSH key at $KEY_FILE"
  su-exec "$PUID:$PGID" ssh-keygen -q -t "${SSH_KEY_TYPE:-ed25519}" -N '' \
    -C "${SSH_KEY_COMMENT:-obsidian-git-backup}" -f "$KEY_FILE"
fi

if [ "${1:-}" = "print-key" ]; then
  cat "$KEY_FILE.pub"
  exit 0
fi
if [ "$#" -gt 0 ]; then
  exec su-exec "$PUID:$PGID" "$@"
fi

for _item in \
  "DEBOUNCE_SECONDS:$DEBOUNCE_SECONDS" \
  "MAX_WAIT_SECONDS:$MAX_WAIT_SECONDS" \
  "RESCAN_SECONDS:$RESCAN_SECONDS" \
  "PUSH_RETRIES:$PUSH_RETRIES" \
  "PUSH_RETRY_SECONDS:$PUSH_RETRY_SECONDS"; do
  _name=${_item%%:*}; _value=${_item#*:}
  is_positive_int "$_value" || fail "$_name must be a positive integer"
done
[ "$MAX_WAIT_SECONDS" -ge "$DEBOUNCE_SECONDS" ] || fail "MAX_WAIT_SECONDS must be at least DEBOUNCE_SECONDS"
[ -d "$VAULT_PATH" ] || fail "vault directory does not exist: $VAULT_PATH"
[ -n "${GIT_REMOTE_URL:-}" ] || fail "GIT_REMOTE_URL is required"

if [ -n "${SSH_KNOWN_HOSTS:-}" ]; then
  printf '%s\n' "$SSH_KNOWN_HOSTS" > "$SSH_PATH/known_hosts"
  chown "$PUID:$PGID" "$SSH_PATH/known_hosts"
  chmod 0600 "$SSH_PATH/known_hosts"
fi
[ -s "$SSH_PATH/known_hosts" ] || fail "no SSH host key configured; set SSH_KNOWN_HOSTS or create $SSH_PATH/known_hosts"

export HOME="$DATA_PATH"
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes -o UserKnownHostsFile=$SSH_PATH/known_hosts -o StrictHostKeyChecking=yes"

as_user() { su-exec "$PUID:$PGID" "$@"; }

if [ ! -d "$REPO_PATH/.git" ]; then
  log "Initializing persistent backup repository"
  as_user git -C "$REPO_PATH" init -b "$GIT_BRANCH"
fi
as_user git -C "$REPO_PATH" config user.name "${GIT_AUTHOR_NAME:-Obsidian Backup}"
as_user git -C "$REPO_PATH" config user.email "${GIT_AUTHOR_EMAIL:-obsidian-backup@localhost}"
as_user git -C "$REPO_PATH" config core.fileMode false
if as_user git -C "$REPO_PATH" remote get-url origin >/dev/null 2>&1; then
  as_user git -C "$REPO_PATH" remote set-url origin "$GIT_REMOTE_URL"
else
  as_user git -C "$REPO_PATH" remote add origin "$GIT_REMOTE_URL"
fi

push_backup() {
  _try=1
  while [ "$_try" -le "$PUSH_RETRIES" ]; do
    if as_user git -C "$REPO_PATH" push -u origin "$GIT_BRANCH"; then
      return 0
    fi
    log "Push attempt $_try/$PUSH_RETRIES failed"
    _try=$((_try + 1))
    [ "$_try" -le "$PUSH_RETRIES" ] && sleep "$PUSH_RETRY_SECONDS"
  done
  return 1
}

snapshot() {
  log "Copying stable snapshot from read-only vault"
  # Two passes greatly reduce the chance of catching a file halfway through an
  # atomic-save sequence. Git never touches the source vault.
  _copy_try=1
  while ! as_user rsync -a --delete --exclude=/.git/ "$VAULT_PATH/" "$REPO_PATH/"; do
    [ "$_copy_try" -lt 3 ] || { log "Snapshot copy failed after 3 attempts; leaving the last commit unchanged"; return 1; }
    _copy_try=$((_copy_try + 1))
    log "Vault changed during copy; retrying snapshot ($_copy_try/3)"
    sleep 2
  done
  sleep 1
  if ! as_user rsync -a --delete --exclude=/.git/ "$VAULT_PATH/" "$REPO_PATH/"; then
    log "Snapshot did not settle; deferring commit until the next scan"
    return 1
  fi
  as_user git -C "$REPO_PATH" add -A
  if as_user git -C "$REPO_PATH" diff --cached --quiet; then
    log "No vault changes to commit"
  else
    as_user git -C "$REPO_PATH" commit -m "${COMMIT_MESSAGE:-Obsidian backup} $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  fi

  if as_user git -C "$REPO_PATH" rev-parse --verify HEAD >/dev/null 2>&1; then
    push_backup || log "Push remains pending; it will be retried after the next scan"
  fi
}

snapshot || true
log "Watching $VAULT_PATH (quiet window ${DEBOUNCE_SECONDS}s, maximum window ${MAX_WAIT_SECONDS}s)"

while :; do
  # Wait for the first event, or periodically rescan to cover missed events and
  # retry failed pushes. inotifywait timeout returns nonzero by design.
  inotifywait -q -r -t "$RESCAN_SECONDS" \
    -e close_write,create,delete,move,attrib "$VAULT_PATH" >/dev/null 2>&1 || true

  _started=$(date +%s)
  while :; do
    _now=$(date +%s)
    _elapsed=$((_now - _started))
    [ "$_elapsed" -ge "$MAX_WAIT_SECONDS" ] && break
    _remaining=$((MAX_WAIT_SECONDS - _elapsed))
    _wait=$DEBOUNCE_SECONDS
    [ "$_remaining" -lt "$_wait" ] && _wait=$_remaining
    if inotifywait -q -r -t "$_wait" \
      -e close_write,create,delete,move,attrib "$VAULT_PATH" >/dev/null 2>&1; then
      continue
    fi
    break
  done
  snapshot || true
done
