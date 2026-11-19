# Shared functions of the action and cached-git. Bash 3.2 compatible (macOS).
# shellcheck shell=bash

BC_LOCK_TIMEOUT=${BC_LOCK_TIMEOUT:-3600}
BC_LOCK_DIR=
BC_LOCK_FD=

bc_log() { echo "bundle-checkout: $*" >&2; }
bc_warn() { echo "::warning::bundle-checkout: $*" >&2; }
bc_die() {
  echo "::error::bundle-checkout: $*" >&2
  exit 1
}

# Reduces a remote URL to "host/owner/repo" so that https, ssh and scp-like forms of the same
# repository compare equal. file:// URLs map to "local/<path>".
bc_url_key() {
  local u=$1
  case $u in
    file://*) u="local/${u#file://}" ;;
    *://*)
      u=${u#*://}
      u=${u#*@}
      ;;
    *@*:*)
      u=${u#*@}
      u=${u%%:*}/${u#*:}
      ;;
  esac
  u=${u%/}
  u=${u%.git}
  # Drop a port, e.g. ssh://git@github.com:22/owner/repo.
  case ${u%%/*} in
    *:*) u="${u%%:*}/${u#*/}" ;;
  esac
  echo "$u" | tr '[:upper:]' '[:lower:]'
}

# bc_cache_path CACHE_DIR SERVER_URL REPOSITORY
bc_cache_path() {
  local host
  case $2 in
    file://*) host=local ;;
    *)
      host=${2#*://}
      host=${host%%/*}
      ;;
  esac
  echo "$1/$(echo "$host/$3" | tr '[:upper:]' '[:lower:]').git"
}

# bc_retry WHAT CMD... runs CMD up to three times, like actions/checkout does for fetches.
# WHAT is logged instead of CMD, which may carry credentials.
bc_retry() {
  local what=$1 attempt
  shift
  for attempt in 1 2; do
    "$@" && return 0
    bc_warn "$what failed (attempt $attempt), retrying"
    sleep $((attempt * ${BC_RETRY_SLEEP:-10}))
  done
  "$@"
}

bc_hostname() { hostname 2>/dev/null || uname -n; }

# A process counts as gone only on an explicit "No such process": EPERM for a process of
# another user, or any other failure, keeps its lock.
bc_pid_gone() {
  case $(kill -0 "$1" 2>&1) in
    *"No such process"* | *"no such process"*) return 0 ;;
  esac
  return 1
}

# Serializes writers of one cache across jobs and runners on the same machine. Readers do not
# lock: git refs and object writes are safe for concurrent readers. flock (Linux) is released by
# the kernel when its holder dies; without it (macOS) a mkdir lock with stale detection is used.
# BC_LOCK_MKDIR=1 forces the mkdir lock, for tests.
bc_lock() {
  mkdir -p "$(dirname "$1")"
  trap bc_unlock EXIT
  if [ -z "${BC_LOCK_MKDIR:-}" ] && command -v flock >/dev/null 2>&1; then
    exec 9>>"$1.flock"
    BC_LOCK_FD=9
    if ! flock -n 9; then
      bc_log "waiting for $1.flock"
      flock -w "$BC_LOCK_TIMEOUT" 9 || bc_die "timed out after ${BC_LOCK_TIMEOUT}s waiting for $1.flock"
    fi
    return 0
  fi
  local dir=$1.lock owner host pid waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    owner=$(cat "$dir/owner" 2>/dev/null || true)
    host=${owner%:*}
    pid=${owner##*:}
    if [ -n "$owner" ] && [ "$host" = "$(bc_hostname)" ] && bc_pid_gone "$pid" &&
      bc_reclaim_lock "$dir" "$owner"; then
      continue
    fi
    if [ "$waited" -ge "$BC_LOCK_TIMEOUT" ]; then
      bc_die "timed out after ${waited}s waiting for $dir (owner: ${owner:-unknown})"
    fi
    if [ $((waited % 60)) -eq 0 ]; then
      bc_log "waiting for $dir (owner: ${owner:-unknown})"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "$(bc_hostname):$$" >"$dir/owner"
  BC_LOCK_DIR=$dir
}

# bc_reclaim_lock DIR OWNER removes the stale lock DIR if it still belongs to OWNER and fails if
# another reclaimer holds the guard, so that the caller's wait counts toward its timeout. Reclaimers
# are serialized by the guard DIR.reclaim, so a slow one cannot delete a lock that another
# process has acquired in the meantime. The guard itself is never removed automatically: that
# could not be serialized. A guard left by a killed reclaimer is a double fault and stops the job
# with a message to remove it by hand.
bc_reclaim_lock() {
  local guard=$1.reclaim gowner
  if ! mkdir "$guard" 2>/dev/null; then
    gowner=$(cat "$guard/owner" 2>/dev/null || true)
    if [ -n "$gowner" ] && [ "${gowner%:*}" = "$(bc_hostname)" ] && bc_pid_gone "${gowner##*:}"; then
      bc_die "$guard was left by a killed process; remove it and $1 by hand if no job is running"
    fi
    return 1
  fi
  echo "$(bc_hostname):$$" >"$guard/owner"
  if [ "$(cat "$1/owner" 2>/dev/null || true)" = "$2" ]; then
    bc_log "removing stale lock of process ${2##*:}"
    rm -rf "$1"
  fi
  rm -rf "$guard"
}

bc_unlock() {
  if [ -n "$BC_LOCK_FD" ]; then
    exec 9>&-
    BC_LOCK_FD=
  fi
  if [ -n "$BC_LOCK_DIR" ]; then
    rm -rf "$BC_LOCK_DIR"
    BC_LOCK_DIR=
  fi
}

# bc_cache_configure CACHE ORIGIN_URL
bc_cache_configure() {
  git -C "$1" config bundle-checkout.cache true
  git -C "$1" config remote.origin.url "$2"
  # Workspaces borrow objects through alternates, so the cache must never drop any of them.
  git -C "$1" config gc.auto 0
  git -C "$1" config gc.pruneExpire never
  git -C "$1" config core.logAllRefUpdates false
  # Lets workspaces fetch a commit by SHA from the cache.
  git -C "$1" config uploadpack.allowAnySHA1InWant true
}

# bc_cache_init_from_bundle CACHE ORIGIN_URL BUNDLE_URL (or an absolute path). Must run under
# bc_lock. The download streams straight into git, which unpacks it as it arrives: no copy of the
# bundle on disk and no second pass over it.
bc_cache_init_from_bundle() {
  local cache=$1 tmp="$1.tmp.$$" start url=$3 progress=
  case $url in
    /*) url=file://$url ;;
  esac
  rm -rf "$tmp"
  git init -q --bare "$tmp"
  bc_cache_configure "$tmp" "$2"
  if git bundle unbundle -h 2>&1 | grep -q -- --progress; then
    progress=--progress
  fi
  start=$(date +%s)
  bc_log "downloading and unpacking bundle $url"
  # No --retry: a retry would resend the start of the file into the same stream. A transfer that
  # stays below 1 MB/s for a minute is cut: the checkout from GitHub is the faster way then.
  # /dev/stdin rather than "-", which older git versions do not accept.
  if ! curl --fail --location --speed-limit 1000000 --speed-time 60 "$url" |
    git -C "$tmp" bundle unbundle $progress /dev/stdin >"$tmp/bundle-refs"; then
    rm -rf "$tmp"
    return 1
  fi
  # unbundle only stores the objects and prints the refs; a broken transfer leaves no refs.
  awk '$2 ~ /^refs\// { print "update", $2, $1 }' "$tmp/bundle-refs" | git -C "$tmp" update-ref --stdin
  rm -f "$tmp/bundle-refs"
  mv "$tmp" "$cache"
  bc_log "cache ready at $cache in $(($(date +%s) - start))s"
}

bc_has_commit() { git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null; }

bc_is_sha() {
  case $1 in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ ${#1} -eq 40 ] || [ ${#1} -eq 64 ]
}
