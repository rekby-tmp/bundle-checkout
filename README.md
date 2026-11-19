# bundle-checkout

A drop-in replacement for `actions/checkout` for runners with a slow or unreliable connection to
GitHub. Most of the repository comes from a [git bundle](https://git-scm.com/docs/git-bundle)
downloaded from a server close to the runners. The objects are kept in a local cache shared by
every checkout on the machine, and only the missing delta is fetched from GitHub.

It was built for [ydb-platform/ydb](https://github.com/ydb-platform/ydb) and supports exactly the
`actions/checkout` inputs that the ydb workflows use.

## Usage

Change `uses:` and add `bundle-url`. Everything else stays as it was:

```yaml
- uses: rekby-tmp/bundle-checkout@main
  with:
    bundle-url: https://storage.example.com/ydb/ydb.bundle
    ref: ${{ needs.check-running-allowed.outputs.commit_sha }}
    fetch-depth: 2
```

What happens:

1. **First run on a machine.** The bundle is downloaded once into the cache
   (`$RUNNER_TOOL_CACHE/bundle-checkout/github.com/<owner>/<repo>.git`). The download streams
   straight into `git bundle unbundle`, so unpacking runs while it downloads, and no copy of the
   bundle is written to disk. Then the commits added after the bundle was made are fetched from
   GitHub. Downloads and fetches show their progress in the log.
2. **Every later run.** Nothing is downloaded from the bundle server. A commit that is already in
   the cache needs no request to GitHub at all; otherwise only the missing delta is fetched.
3. **The working copy** in `path` borrows objects from the cache through
   [`objects/info/alternates`](https://git-scm.com/docs/gitrepository-layout#Documentation/gitrepository-layout.txt-objectsinfoalternates),
   so it takes almost no disk space. Its `origin` is the usual GitHub URL, and `git log`,
   `git diff`, `HEAD~1`, `git merge-base` and `git worktree` see the full history.

If the bundle cannot be downloaded and there is no cache yet, the action warns and does an
ordinary shallow checkout from GitHub, like `actions/checkout`.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `repository` | `${{ github.repository }}` | As in `actions/checkout`. |
| `ref` | event ref and SHA | Branch, tag, SHA or `refs/pull/N/merge`, as in `actions/checkout`. |
| `token` | `${{ github.token }}` | Used for GitHub requests. It is never written into the cache. |
| `path` | `$GITHUB_WORKSPACE` | Relative to `$GITHUB_WORKSPACE`. |
| `fetch-depth` | `1` | The working copy is never shallow: the cache already has the whole history, at no network cost. `0` also brings all branches and tags. Without a cache it limits the fetch, as in `actions/checkout`. |
| `sparse-checkout` | | Patterns, one per line. |
| `sparse-checkout-cone-mode` | `true` | |
| `persist-credentials` | `true` | The token stays in the local git config until the post step removes it. |
| `filter` | | Used only without a cache; with a cache every object is local anyway. |
| `allow-unsafe-pr-checkout` | `false` | Same guard as `actions/checkout` for fork code in `pull_request_target` and `workflow_run`. |
| `bundle-url` | | **New.** HTTP(S) URL of the bundle, or an absolute path to a local file. It is used only when the machine has no cache yet. |
| `cache-dir` | `$RUNNER_TOOL_CACHE/bundle-checkout` | **New.** Where the caches live. |

Outputs: `ref` and `commit`, as in `actions/checkout`.

Not supported, because ydb does not use them: `submodules`, `lfs`, `ssh-key` and the other
`ssh-*` inputs, `clean: false`, `fetch-tags`, `show-progress`, `set-safe-directory` and
`github-server-url` (the runner's `GITHUB_SERVER_URL` is used).

## `cached-git`: fetches in workflow scripts

The action puts `cached-git` on `PATH` and sets `GIT=cached-git` for the later steps of the job.
`cached-git` behaves exactly like `git`, except for `git fetch` from the checked-out repository:

1. it fetches into the shared cache only the refs and commits the cache does not have;
2. it then runs the requested `git fetch` against the local cache. Remote-tracking refs,
   `FETCH_HEAD`, `--prune` and tags work as with a fetch from GitHub.

It needs no URL or other extra arguments: it finds the cache through the working copy's
alternates, also from a `git worktree`. `--depth`, `--deepen`, `--shallow-since`, `--unshallow`
and `--filter` are dropped because the whole history is already local; with them the working
copy would only turn shallow. Fetches from other remotes and all other commands go straight to
`git`.

Replace `git fetch` with `cached-git fetch` in the scripts, for example:

```bash
cached-git fetch origin main
cached-git fetch origin "$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH"
cached-git fetch --no-tags origin "+refs/heads/main:refs/remotes/origin/main" "refs/pull/$PR_NUMBER/head"
cached-git fetch --depth=1 origin "$BASELINE_SHA"   # then: git worktree add ../baseline "$BASELINE_SHA"
```

In Python, take the binary from the environment:

```python
GIT = os.environ.get('GIT', 'git')
subprocess.run([GIT, 'fetch', f'--shallow-since={days} days ago', 'origin', refspec], cwd=repo)
```

## Making the bundle

Make the bundle on a machine with a good connection to GitHub, publish it at `bundle-url`, and
refresh it regularly, for example weekly. An older bundle still works; the runners just fetch a
larger delta from GitHub on their first run.

```bash
git clone --mirror https://github.com/ydb-platform/ydb.git ydb.git   # once
git -C ydb.git remote update --prune                                   # on every refresh
git -C ydb.git bundle create ydb.bundle.tmp --all && mv ydb.git/ydb.bundle.tmp ydb.bundle
# upload ydb.bundle to https://storage.example.com/ydb/ydb.bundle
```

A mirror also contains `refs/pull/*`. Leave them out with `--branches --tags` instead of `--all`
if the bundle grows too large.

## When it pays off

- **Self-hosted runners that keep their disk between jobs.** The bundle is downloaded once per
  machine, and later jobs fetch only the delta. This is the main case.
- **Runners that start from a clean disk.** The whole bundle (about 3 GB for ydb) is downloaded
  on every job. That still helps when the bundle server is much faster than GitHub; otherwise
  keep `actions/checkout` there.
- **GitHub-hosted runners (`ubuntu-latest`).** No benefit, keep `actions/checkout`.

## Caveats

- Never run `git gc`, `git prune` or `git repack` in a cache, and do not delete a cache while
  jobs run: working copies borrow its objects, including ones no cache ref points to any more.
  Caches have `gc.auto=0`.
  Deleting a whole cache directory between jobs is safe; the next run downloads the bundle again.
- Concurrent jobs on one machine are serialized with a lock next to the cache: `flock` on
  `<cache>.flock` on Linux, a `<cache>.lock` directory elsewhere. A lock left by a killed process
  is taken over. Without `flock`, a process killed exactly while taking over such a lock leaves
  `<cache>.lock.reclaim`; the next job stops and asks to remove it by hand.
- Linux and macOS runners. The action needs `bash`, `git` 2.31+ and `curl`.

## Development

Run `tests/e2e.sh` (needs `bash`, `git`, `node`). It simulates GitHub with a local repository
over `file://` and covers the inputs above and `cached-git`. CI also runs `shellcheck` and a real
run of the action. See [AGENTS.md](AGENTS.md) for the rules of this repository.
