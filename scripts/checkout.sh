#!/usr/bin/env bash
# Main step of the action. Inputs arrive as INPUT_* variables prepared by dist/main.js.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

repository=$(trim "${INPUT_REPOSITORY:-${GITHUB_REPOSITORY:-}}")
ref=$(trim "${INPUT_REF:-}")
token=${INPUT_TOKEN:-}
fetch_depth=$(trim "${INPUT_FETCH_DEPTH:-1}")
sparse=${INPUT_SPARSE_CHECKOUT:-}
cone=$(trim "${INPUT_SPARSE_CHECKOUT_CONE_MODE:-true}")
persist=$(trim "${INPUT_PERSIST_CREDENTIALS:-true}")
filter=$(trim "${INPUT_FILTER:-}")
bundle_url=$(trim "${INPUT_BUNDLE_URL:-}")
cache_dir=$(trim "${INPUT_CACHE_DIR:-}")
cache_dir=${cache_dir:-${RUNNER_TOOL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}}/bundle-checkout}
server=${GITHUB_SERVER_URL:-https://github.com}
server=${server%/}
origin_url="$server/$repository"
workspace=${GITHUB_WORKSPACE:-$PWD}

[ -n "$repository" ] || bc_die "repository is not set"
case $fetch_depth in
  '' | *[!0-9]*) bc_die "fetch-depth must be a non-negative integer, got '$fetch_depth'" ;;
esac
case ${INPUT_PATH:-} in
  /*) repo_path=$INPUT_PATH ;;
  '') repo_path=$workspace ;;
  *) repo_path=$workspace/$INPUT_PATH ;;
esac
repo_path=${repo_path%/}
[ -n "$repo_path" ] || bc_die "refusing to check out into /"

auth_key="http.$server/.extraheader"
auth_value=
case $server in
  http://* | https://*)
    if [ -n "$token" ]; then
      basic=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
      echo "::add-mask::$basic"
      auth_value="AUTHORIZATION: basic $basic"
    fi
    ;;
esac

# Runs git with the token for requests to the server; the token is never written to the cache.
# Commands that need no repository run in /: a working copy with a persisted token would send
# its Authorization header a second time.
remote_git() {
  if [ -n "$auth_value" ]; then
    git -c "$auth_key=$auth_value" "$@"
  else
    git "$@"
  fi
}

# --- Resolve what to check out, the same way actions/checkout does.
commit=
if [ -z "$ref" ]; then
  if [ "$(bc_url_key "$repository")" = "$(bc_url_key "${GITHUB_REPOSITORY:-}")" ]; then
    ref=${GITHUB_REF:-}
    commit=${GITHUB_SHA:-}
    case $ref in
      '' | refs/*) ;;
      *) ref=refs/heads/$ref ;;
    esac
  else
    ref=$(remote_git -C / ls-remote --symref "$origin_url" HEAD | sed -n 's/^ref: \(.*\)[[:space:]]HEAD$/\1/p')
    [ -n "$ref" ] || bc_die "cannot resolve the default branch of $origin_url"
  fi
elif bc_is_sha "$ref"; then
  commit=$ref
  ref=
fi
[ -n "$ref" ] || [ -n "$commit" ] || bc_die "nothing to check out: no ref and no commit"

case $ref in
  '' | refs/*) ;;
  *)
    # An unqualified name is a branch, else a tag, as in actions/checkout. One small request
    # instead of fetching the refs/heads/<name>* patterns that actions/checkout uses.
    found=$(remote_git -C / ls-remote "$origin_url" "refs/heads/$ref" "refs/tags/$ref" | cut -f2)
    if printf '%s\n' "$found" | grep -qx "refs/heads/$ref"; then
      ref=refs/heads/$ref
    elif printf '%s\n' "$found" | grep -qx "refs/tags/$ref"; then
      ref=refs/tags/$ref
    else
      bc_die "a branch or tag with the name '$ref' could not be found"
    fi
    ;;
esac

# Refspecs of the workspace fetch, identical to those of actions/checkout.
src=${commit:-$ref}
case $ref in
  refs/heads/*) refspecs=("+$src:refs/remotes/origin/${ref#refs/heads/}") ;;
  refs/pull/*) refspecs=("+$src:refs/remotes/pull/${ref#refs/pull/}") ;;
  # By name even with a known commit, so that an annotated tag stays annotated.
  refs/tags/*) refspecs=("+$ref:$ref") ;;
  *) if [ -n "$commit" ]; then refspecs=("$commit"); else refspecs=("+$ref:$ref"); fi ;;
esac
# fetch-depth 0 first fetches all branches and tags, then the target ref only if it is still
# missing or points elsewhere, again as in actions/checkout.
all_refspecs=('+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*')
target_ref=
case ${refspecs[0]} in *:*) target_ref=${refspecs[0]#*:} ;; esac
if [ "$fetch_depth" = 0 ]; then
  wanted=("${all_refspecs[@]}" "${refspecs[@]}")
else
  wanted=("${refspecs[@]}")
fi

# ws_fetch SOURCE GIT-ARGS... fetches the wanted refs into the workspace from SOURCE.
ws_fetch() {
  local source=$1 current
  shift
  if [ "$fetch_depth" = 0 ]; then
    "$@" "$source" "${all_refspecs[@]}"
    if [ -n "$target_ref" ]; then
      current=$(git -C "$repo_path" rev-parse -q --verify "$target_ref^{commit}" || true)
      if [ -n "$current" ] && { [ -z "$commit" ] || [ "$current" = "$commit" ]; }; then
        return 0
      fi
    fi
  fi
  "$@" "$source" "${refspecs[@]}"
}

# --- Shared object cache.
cache=$(bc_cache_path "$cache_dir" "$server" "$repository")
use_cache=false
bundle_used=false
bc_lock "$cache"
if [ ! -d "$cache/objects" ] && [ -n "$bundle_url" ]; then
  if bc_cache_init_from_bundle "$cache" "$origin_url" "$bundle_url"; then
    bundle_used=true
  else
    bc_warn "bundle $bundle_url is unavailable, checking out directly from $origin_url"
  fi
fi
if [ -d "$cache/objects" ]; then
  use_cache=true
  bc_cache_configure "$cache" "$origin_url"
  # Download only what the cache lacks: a known commit costs no request at all.
  cache_refspecs=()
  for spec in "${wanted[@]}"; do
    s=${spec#+}
    s=${s%%:*}
    if bc_is_sha "$s"; then
      bc_has_commit "$cache" "$s" || cache_refspecs+=("+$s:refs/bundle-checkout/commits/$s")
    elif [ -n "$commit" ] && [ "$(git -C "$cache" rev-parse -q --verify "$s^{commit}" || true)" = "$commit" ]; then
      : # a tag of the event that the cache already has
    else
      cache_refspecs+=("+$s:$s")
    fi
  done
  if [ ${#cache_refspecs[@]} -gt 0 ]; then
    bc_log "updating cache from $origin_url: ${cache_refspecs[*]}"
    bc_retry "fetch into the cache" remote_git -C "$cache" fetch --progress --no-tags --no-write-fetch-head origin "${cache_refspecs[@]}"
  else
    bc_log "everything needed is already in the cache, nothing to download"
  fi
fi
bc_unlock

# --- Workspace.
mkdir -p "$repo_path"
if [ -d "$repo_path/.git" ] && [ "$(git -C "$repo_path" config remote.origin.url || true)" = "$origin_url" ]; then
  rm -f "$repo_path/.git/index.lock" "$repo_path/.git/shallow.lock"
  if ! { git -C "$repo_path" clean -ffdxq && { git -C "$repo_path" reset -q --hard HEAD 2>/dev/null || ! git -C "$repo_path" rev-parse -q --verify HEAD >/dev/null; }; }; then
    bc_warn "cannot clean $repo_path, recreating it"
    find "$repo_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
else
  find "$repo_path" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi
if [ ! -d "$repo_path/.git" ]; then
  git -C "$repo_path" init -q
  git -C "$repo_path" remote add origin "$origin_url"
  git -C "$repo_path" config gc.auto 0
fi
git -C "$repo_path" config --local --unset-all "$auth_key" 2>/dev/null || true

fetch_opts=(--no-tags --prune --no-recurse-submodules)
if [ "$use_cache" = true ]; then
  printf '%s\n' "$cache/objects" >"$repo_path/.git/objects/info/alternates"
  # The whole history is reachable through the cache; a leftover shallow boundary would hide it.
  rm -f "$repo_path/.git/shallow"
  bc_retry "fetch from the cache" ws_fetch "$cache" git -C "$repo_path" fetch -q "${fetch_opts[@]}"
else
  rm -f "$repo_path/.git/objects/info/alternates"
  if [ "$fetch_depth" -gt 0 ]; then
    fetch_opts+=("--depth=$fetch_depth")
  elif [ -f "$repo_path/.git/shallow" ]; then
    fetch_opts+=(--unshallow)
  fi
  if [ -n "$filter" ]; then
    fetch_opts+=("--filter=$filter")
  fi
  bc_retry "fetch from $origin_url" ws_fetch origin remote_git -C "$repo_path" fetch --progress "${fetch_opts[@]}"
fi

if [ -n "$(trim "$sparse")" ]; then
  cone_opt=--cone
  [ "$cone" = true ] || cone_opt=--no-cone
  printf '%s\n' "$sparse" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' |
    git -C "$repo_path" sparse-checkout set "$cone_opt" --stdin
elif [ "$(git -C "$repo_path" config --bool core.sparseCheckout || true)" = true ]; then
  git -C "$repo_path" sparse-checkout disable
fi

case $ref in
  refs/heads/*)
    branch=${ref#refs/heads/}
    git -C "$repo_path" checkout -q --force -B "$branch" "refs/remotes/origin/$branch"
    ;;
  refs/pull/*) git -C "$repo_path" checkout -q --force "refs/remotes/pull/${ref#refs/pull/}" ;;
  refs/tags/*)
    if [ -n "$commit" ] && [ "$(git -C "$repo_path" rev-parse "$ref^{commit}")" != "$commit" ]; then
      bc_die "tag $ref no longer points to $commit"
    fi
    git -C "$repo_path" checkout -q --force "$ref"
    ;;
  *) git -C "$repo_path" checkout -q --force "${commit:-$ref}" ;;
esac
head=$(git -C "$repo_path" rev-parse HEAD)
bc_log "checked out ${ref:-$commit} at $head (cache: $use_cache, bundle downloaded: $bundle_used)"

if [ "$persist" = true ] && [ -n "$auth_value" ]; then
  git -C "$repo_path" config --local "$auth_key" "$auth_value"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ref=$ref"
    echo "commit=$head"
  } >>"$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STATE:-}" ]; then
  {
    echo "repo_path=$repo_path"
    echo "auth_key=$auth_key"
  } >>"$GITHUB_STATE"
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  (cd "$here/../bin" && pwd) >>"$GITHUB_PATH"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "GIT=cached-git" >>"$GITHUB_ENV"
  if [ "$use_cache" = true ]; then
    echo "BUNDLE_CHECKOUT_CACHE=$cache" >>"$GITHUB_ENV"
  fi
fi
