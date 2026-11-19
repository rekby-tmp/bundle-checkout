#!/usr/bin/env bash
# End-to-end test of the action and cached-git against a local "GitHub" served over file://.
# Usage: tests/e2e.sh   (needs git, node and bash)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/bc-e2e.XXXXXX")
trap 'rm -rf "$T"' EXIT
export BC_RETRY_SLEEP=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fail() {
  echo "FAIL: $*" >&2
  [ -f "$T/log" ] && sed 's/^/  | /' "$T/log" >&2
  exit 1
}
ok() { echo "ok - $*"; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

# --- A fake GitHub: $T/server/acme/app, plus a fork-free history with a tag, a feature branch
# and pull request refs. The bundle is made before the last main commit, as on a real mirror.
server="file://$T/server"
origin=$T/server/acme/app
git init -q --bare "$origin"
git -C "$origin" config uploadpack.allowAnySHA1InWant true
git init -q -b main "$T/src"
commit() { # commit FILE: adds FILE and prints the new HEAD
  mkdir -p "$T/src/$(dirname "$1")"
  echo "$1 $RANDOM" >"$T/src/$1"
  git -C "$T/src" add -A
  git -C "$T/src" commit -qm "$1"
  git -C "$T/src" rev-parse HEAD
}
c1=$(commit dir1/a)
git -C "$T/src" tag v1
c2=$(commit dir2/b)
git -C "$T/src" tag -a v2 -m "annotated v2"
git -C "$T/src" push -q "$origin" main v1 v2
git -C "$T/src" checkout -q -b feature
cf=$(commit feature.txt)
git -C "$T/src" push -q "$origin" feature "$cf:refs/pull/1/head" "$cf:refs/pull/1/merge"
git -C "$T/src" checkout -q main
git -C "$origin" bundle create -q "$T/app.bundle" --all
c3=$(commit dir1/c)
git -C "$T/src" push -q "$origin" main
bundle="file://$T/app.bundle"

offline() { mv "$origin" "$origin.off"; }
online() { mv "$origin.off" "$origin"; }

# run_action KEY=VALUE... runs dist/main.js like the runner does; inputs are INPUT_<NAME>.
run_action() {
  : >"$T/out"
  : >"$T/state"
  : >"$T/env"
  : >"$T/path"
  env GITHUB_WORKSPACE="$T/ws" GITHUB_REPOSITORY=acme/app GITHUB_SERVER_URL="$server" \
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_SHA="$c3" \
    RUNNER_TOOL_CACHE="$T/toolcache" GITHUB_OUTPUT="$T/out" GITHUB_STATE="$T/state" \
    GITHUB_ENV="$T/env" GITHUB_PATH="$T/path" "INPUT_BUNDLE-URL=$bundle" "$@" \
    node "$root/dist/main.js" >"$T/log" 2>&1
}
head_of() { git -C "$T/ws/$1" rev-parse HEAD; }
shallow_of() { git -C "$T/ws/$1" rev-parse --is-shallow-repository; }
cache=$T/toolcache/bundle-checkout/local/acme/app.git

# 1. First checkout downloads the bundle and fetches only the delta (c3) from the origin.
run_action INPUT_PATH=local "INPUT_BUNDLE-URL=$T/app.bundle" "INPUT_CACHE-DIR=$T/local-path" || fail "bundle from a local path"
eq "$(head_of local)" "$c3" "HEAD with a bundle from a local path"
run_action INPUT_PATH=a || fail "first checkout"
grep -q "downloading and unpacking bundle" "$T/log" || fail "bundle was not downloaded"
eq "$(head_of a)" "$c3" "HEAD after first checkout"
eq "$(cat "$T/ws/a/.git/objects/info/alternates")" "$cache/objects" "alternates"
eq "$(git -C "$T/ws/a" symbolic-ref --short HEAD)" main "branch"
grep -qx "commit=$c3" "$T/out" || fail "commit output"
grep -qx "ref=refs/heads/main" "$T/out" || fail "ref output"
grep -qx "BUNDLE_CHECKOUT_CACHE=$cache" "$T/env" || fail "BUNDLE_CHECKOUT_CACHE export"
grep -qx "GIT=cached-git" "$T/env" || fail "GIT export"
eq "$(cat "$T/path")" "$root/bin" "PATH export"
eq "$(git -C "$T/ws/a" count-objects -v | sed -n 's/^count: //p')" 0 "loose objects in the workspace"
eq "$(ls "$T/ws/a/.git/objects/pack" | wc -l | tr -d ' ')" 0 "packs in the workspace"
[ ! -e "$cache/bundle-refs" ] || fail "temporary file left behind"
ok "first checkout from the bundle plus delta"

# 2. A second checkout of a known commit needs no network and no bundle; history is complete.
offline
run_action INPUT_PATH=b INPUT_FETCH-DEPTH=2 || fail "offline checkout"
online
grep -q "downloading and unpacking bundle" "$T/log" && fail "bundle downloaded twice"
eq "$(head_of b)" "$c3" "HEAD of the second checkout"
eq "$(git -C "$T/ws/b" rev-parse HEAD~2)" "$c1" "history through the cache"
eq "$(shallow_of b)" false "shallow"
ok "second checkout is offline and not shallow"

# 3. Unqualified branch, tag, SHA and pull request refs, as in actions/checkout.
run_action INPUT_PATH=c INPUT_REF=feature || fail "branch checkout"
eq "$(git -C "$T/ws/c" symbolic-ref --short HEAD)" feature "branch name"
eq "$(head_of c)" "$cf" "branch HEAD"
run_action INPUT_PATH=c INPUT_REF=v1 || fail "tag checkout"
eq "$(head_of c)" "$c1" "tag HEAD"
git -C "$T/ws/c" symbolic-ref -q HEAD >/dev/null && fail "tag checkout is not detached"
offline
run_action INPUT_PATH=c INPUT_REF="$c2" || fail "SHA checkout"
online
eq "$(head_of c)" "$c2" "SHA HEAD"
run_action INPUT_PATH=c INPUT_REF=refs/pull/1/merge || fail "pull ref checkout"
eq "$(head_of c)" "$cf" "pull ref HEAD"
eq "$(git -C "$T/ws/c" rev-parse refs/remotes/pull/1/merge)" "$cf" "pull remote ref"
run_action INPUT_PATH=t GITHUB_REF=refs/tags/v2 GITHUB_SHA="$c2" || fail "tag event checkout"
eq "$(git -C "$T/ws/t" cat-file -t refs/tags/v2)" tag "annotated tag type"
eq "$(head_of t)" "$c2" "tag event HEAD"
run_action INPUT_PATH=t GITHUB_REF=refs/tags/v2 GITHUB_SHA="$c1" && fail "moved tag must fail"
grep -q "no longer points" "$T/log" || fail "moved tag message"
run_action INPUT_PATH=c INPUT_REF=no-such-branch && fail "missing branch must fail"
grep -q "could not be found" "$T/log" || fail "missing branch message"
ok "branch, tag, SHA and pull request refs"

# 4. fetch-depth 0 brings all branches and tags.
run_action INPUT_PATH=d INPUT_FETCH-DEPTH=0 || fail "fetch-depth 0"
git -C "$T/ws/d" rev-parse -q --verify refs/remotes/origin/feature >/dev/null || fail "origin/feature"
git -C "$T/ws/d" rev-parse -q --verify refs/tags/v1 >/dev/null || fail "tag v1"
ok "fetch-depth 0"

# 5. Sparse checkout, and a reused workspace is cleaned and loses the sparse setup.
run_action INPUT_PATH=a "INPUT_SPARSE-CHECKOUT=dir1" || fail "sparse checkout"
[ -f "$T/ws/a/dir1/a" ] && [ ! -e "$T/ws/a/dir2" ] || fail "sparse content"
echo junk >"$T/ws/a/untracked"
run_action INPUT_PATH=a || fail "reuse workspace"
[ ! -e "$T/ws/a/untracked" ] || fail "untracked file survived"
[ -f "$T/ws/a/dir2/b" ] || fail "sparse checkout was not disabled"
ok "sparse checkout and workspace reuse"

mkdir -p "$T/outside"
echo keep >"$T/outside/sentinel"
run_action INPUT_PATH=../outside && fail "path outside the workspace must fail"
grep -q "is not under" "$T/log" || fail "path outside message"
[ -f "$T/outside/sentinel" ] || fail "a file outside the workspace was deleted"
ok "path stays under the workspace"

# 6. Without a bundle and without a cache: a plain shallow checkout, as in actions/checkout.
run_action INPUT_PATH=e "INPUT_BUNDLE-URL=file://$T/missing.bundle" "INPUT_CACHE-DIR=$T/other-cache" || fail "fallback"
grep -q "::warning::.*unavailable" "$T/log" || fail "fallback warning"
eq "$(head_of e)" "$c3" "fallback HEAD"
eq "$(shallow_of e)" true "fallback shallow"
[ ! -e "$T/ws/e/.git/objects/info/alternates" ] || fail "fallback alternates"
ok "fallback without a bundle"

# 7. Token handling and a proxy-like insteadOf in GIT_CONFIG_* (as ydb sets it): the action
# fetches through the rewrite, persists the token and the post step removes it.
proxy=(GITHUB_SERVER_URL=https://github.example GIT_CONFIG_COUNT=1
  "GIT_CONFIG_KEY_0=url.$server/.insteadOf" GIT_CONFIG_VALUE_0=https://github.example/)
run_action "${proxy[@]}" INPUT_PATH=f INPUT_TOKEN=secret-token || fail "checkout through insteadOf"
eq "$(head_of f)" "$c3" "HEAD through insteadOf"
eq "$(git -C "$T/ws/f" config remote.origin.url)" https://github.example/acme/app "origin URL"
header=$(git -C "$T/ws/f" config --local http.https://github.example/.extraheader)
eq "$header" "AUTHORIZATION: basic $(printf 'x-access-token:secret-token' | base64)" "persisted header"
grep -q GIT_CONFIG "$T/env" && fail "GIT_CONFIG_* must not be exported"
grep -rq secret "$T/toolcache/bundle-checkout/github.example" && fail "token leaked into the cache"
env STATE_repo_path="$(sed -n 's/^repo_path=//p' "$T/state")" \
  STATE_auth_key="$(sed -n 's/^auth_key=//p' "$T/state")" node "$root/dist/post.js" || fail "post"
git -C "$T/ws/f" config --local http.https://github.example/.extraheader && fail "post kept the token"
run_action "${proxy[@]}" INPUT_PATH=g INPUT_TOKEN=secret-token INPUT_PERSIST-CREDENTIALS=false || fail "no persist"
git -C "$T/ws/g" config --local http.https://github.example/.extraheader && fail "token persisted"
ok "token, insteadOf proxy and post step"

# 8. Fork pull request code under pull_request_target needs allow-unsafe-pr-checkout.
cat >"$T/event.json" <<EOF
{"repository": {"id": 1}, "pull_request": {"head": {"sha": "$cf", "repo": {"id": 2, "full_name": "fork/app"}}, "merge_commit_sha": "$cf"}}
EOF
pr=(GITHUB_EVENT_NAME=pull_request_target "GITHUB_EVENT_PATH=$T/event.json" INPUT_PATH=h)
run_action "${pr[@]}" INPUT_REF=refs/pull/1/merge && fail "unsafe checkout must fail"
grep -q "allow-unsafe-pr-checkout" "$T/log" || fail "unsafe checkout message"
run_action "${pr[@]}" INPUT_REF="$cf" && fail "unsafe SHA checkout must fail"
run_action "${pr[@]}" INPUT_REF=refs/pull/1/merge INPUT_ALLOW-UNSAFE-PR-CHECKOUT=true || fail "allowed checkout"
run_action "${pr[@]}" || fail "default checkout of the base repository"
cat >"$T/wr.json" <<EOF
{"repository": {"id": 1}, "workflow_run": {"event": "pull_request", "head_sha": "$c3", "head_commit": {"id": "$cf"}, "head_repository": {"id": 2, "full_name": "fork/app"}}}
EOF
run_action GITHUB_EVENT_NAME=workflow_run "GITHUB_EVENT_PATH=$T/wr.json" INPUT_PATH=h INPUT_REF="$cf" &&
  fail "workflow_run fork head_commit must fail"
sed -i.bak 's/"event": "pull_request"/"event": "pull_request_target"/' "$T/wr.json"
run_action GITHUB_EVENT_NAME=workflow_run "GITHUB_EVENT_PATH=$T/wr.json" INPUT_PATH=h INPUT_REF="$c3" ||
  fail "head_sha of a pull_request_target workflow_run is the base commit"
ok "allow-unsafe-pr-checkout"

# 9. Concurrent first checkouts share one bundle download.
run_action INPUT_PATH=p1 "INPUT_CACHE-DIR=$T/race" && cp "$T/log" "$T/log1" &
p1=$!
sleep 0.2
(
  T2=$T/r2
  mkdir -p "$T2"
  env GITHUB_WORKSPACE="$T/ws" GITHUB_REPOSITORY=acme/app GITHUB_SERVER_URL="$server" \
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_SHA="$c3" \
    "INPUT_BUNDLE-URL=$bundle" "INPUT_CACHE-DIR=$T/race" INPUT_PATH=p2 \
    node "$root/dist/main.js" >"$T2/log" 2>&1
) || { cat "$T/r2/log" >&2; fail "second concurrent checkout"; }
wait "$p1" || fail "first concurrent checkout"
eq "$(cat "$T/log1" "$T/r2/log" | grep -c "downloading and unpacking bundle")" 1 "bundle downloads"
eq "$(head_of p1) $(head_of p2)" "$c3 $c3" "concurrent HEADs"
ok "concurrent checkouts"

# 10. A lock left by a killed process on this host is taken over. flock needs no stale
# detection, so the mkdir lock that is used without flock (macOS) is forced here.
export BC_LOCK_MKDIR=1
sleep 0 &
dead=$!
wait "$dead"
mkdir -p "$T/stale/local/acme/app.git.lock"
echo "$(hostname 2>/dev/null || uname -n):$dead" >"$T/stale/local/acme/app.git.lock/owner"
run_action INPUT_PATH=s "INPUT_CACHE-DIR=$T/stale" || fail "stale lock"
grep -q "removing stale lock" "$T/log" || fail "stale lock message"
mkdir -p "$T/stale2/local/acme/app.git.lock"
echo "$(hostname 2>/dev/null || uname -n):$dead" >"$T/stale2/local/acme/app.git.lock/owner"
for n in 1 2 3; do
  env GITHUB_WORKSPACE="$T/ws" GITHUB_REPOSITORY=acme/app GITHUB_SERVER_URL="$server" \
    GITHUB_REF=refs/heads/main GITHUB_SHA="$c3" "INPUT_BUNDLE-URL=$bundle" \
    "INPUT_CACHE-DIR=$T/stale2" INPUT_PATH="s$n" node "$root/dist/main.js" >"$T/stale2.$n.log" 2>&1 &
done
wait || true
for n in 1 2 3; do eq "$(head_of "s$n")" "$c3" "HEAD after competing reclaim $n"; done
eq "$(cat "$T"/stale2.*.log | grep -c "downloading and unpacking bundle")" 1 "bundle downloads after competing reclaim"
mkdir -p "$T/stale3/local/acme/app.git.lock" "$T/stale3/local/acme/app.git.lock.reclaim"
echo "$(hostname 2>/dev/null || uname -n):$dead" >"$T/stale3/local/acme/app.git.lock/owner"
echo "$(hostname 2>/dev/null || uname -n):$dead" >"$T/stale3/local/acme/app.git.lock.reclaim/owner"
run_action INPUT_PATH=s "INPUT_CACHE-DIR=$T/stale3" && fail "a dead reclaim guard must stop the job"
grep -q "remove it and .* by hand" "$T/log" || fail "dead reclaim guard message"
[ -d "$T/stale3/local/acme/app.git.lock.reclaim" ] || fail "the dead reclaim guard was removed"
rm -f "$T/stale3/local/acme/app.git.lock.reclaim/owner"
BC_LOCK_TIMEOUT=2 run_action INPUT_PATH=s "INPUT_CACHE-DIR=$T/stale3" && fail "an ownerless reclaim guard must time out"
grep -q "timed out" "$T/log" || fail "ownerless reclaim guard timeout message"
unset BC_LOCK_MKDIR
ok "stale lock"

# 11. cached-git: fetches of the ydb workflow scripts are served from the cache.
cg="$root/bin/cached-git"
ws=$T/ws/a
c4=$(commit dir2/d)
git -C "$T/src" push -q "$origin" main
(cd "$ws" && "$cg" fetch -q origin main) || fail "cached-git fetch origin main"
eq "$(git -C "$ws" rev-parse origin/main)" "$c4" "origin/main after cached-git fetch"
git -C "$cache" cat-file -e "$c4^{commit}" || fail "new commit is not in the cache"
eq "$(git -C "$ws" count-objects -v | sed -n 's/^count: //p')" 0 "objects copied into the workspace"

c5=$(commit dir1/e)
git -C "$T/src" push -q "$origin" main
"$cg" -C "$ws" fetch -q --shallow-since="30 days ago" origin "main:refs/remotes/origin/main" || fail "shallow-since"
eq "$(git -C "$ws" rev-parse origin/main)" "$c5" "origin/main after shallow-since"
"$cg" -C "$ws" fetch -q --deepen=500 origin "main:refs/remotes/origin/main" || fail "deepen"
"$cg" -C "$ws" fetch -q --depth=1 origin "$c2" || fail "depth=1 by SHA"
eq "$(git -C "$ws" rev-parse --is-shallow-repository)" false "shallow after cached-git"
"$cg" -C "$ws" fetch -q --no-tags origin "+refs/heads/main:refs/remotes/origin/main" refs/pull/1/head || fail "PR head"
grep -q "^$cf.*refs/pull/1/head" "$ws/.git/FETCH_HEAD" || fail "FETCH_HEAD of the PR head"
"$cg" -C "$ws" fetch -q --no-tags --no-recurse-submodules origin "+refs/pull/1/head:refs/remotes/origin/pr-1" || fail "PR ref"
eq "$(git -C "$ws" rev-parse origin/pr-1)" "$cf" "PR remote ref"

git -C "$ws" worktree add -q "$T/wt" "$c2"
offline
"$cg" -C "$T/wt" fetch -q origin "$c1" || fail "offline fetch of a cached SHA from a worktree"
online
eq "$(git -C "$T/wt" rev-parse FETCH_HEAD)" "$c1" "worktree FETCH_HEAD"

git -C "$T/src" push -q "$origin" "$c2:refs/heads/gone"
"$cg" -C "$ws" fetch -q origin || fail "fetch all branches"
git -C "$ws" rev-parse -q --verify refs/remotes/origin/gone >/dev/null || fail "origin/gone missing"
git -C "$T/src" push -q "$origin" :refs/heads/gone
"$cg" -C "$ws" fetch -q --prune origin || fail "fetch --prune"
git -C "$ws" rev-parse -q --verify refs/remotes/origin/gone >/dev/null && fail "--prune kept origin/gone"
git -C "$cache" update-ref refs/heads/stale "$c1"
"$cg" -C "$ws" fetch -q origin stale 2>/dev/null && fail "a branch missing on the origin must fail"
git -C "$cache" update-ref refs/tags/main "$c1"
"$cg" -C "$ws" fetch -q origin main || fail "fetch main with a stale tag main in the cache"
eq "$(git -C "$ws" rev-parse FETCH_HEAD)" "$c5" "FETCH_HEAD ignores a stale cached tag"
"$cg" -C "$ws" fetch -q origin "+main:refs/remotes/origin/main-copy" || fail "short source with a destination"
eq "$(git -C "$ws" rev-parse refs/remotes/origin/main-copy)" "$c5" "destination of a short source"

eq "$("$cg" -C "$ws" rev-parse HEAD)" "$(git -C "$ws" rev-parse HEAD)" "pass-through command"
git init -q --bare "$T/server/acme/other"
git -C "$T/src" push -q "$T/server/acme/other" "$c1:refs/heads/x"
git -C "$ws" remote add other "$server/acme/other"
"$cg" -C "$ws" fetch -q other x || fail "fetch from another remote"
git -C "$cache" rev-parse -q --verify refs/heads/x >/dev/null && fail "another remote went into the cache"
ok "cached-git"

echo "all tests passed"
