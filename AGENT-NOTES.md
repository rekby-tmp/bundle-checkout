# Agent implementation notes

This journal contains implementation decisions and findings made by the agent within the user's constraints. These records never override `DECISIONS.md`.

## Journal

### A-001 — Working copies borrow cache objects through alternates; the cache never prunes
- Date: 2026-11-20
- Status: active
- Within: —
- Decision / Finding: Each working copy gets objects/info/alternates pointing at the shared bare cache instead of a copy of the objects (no --dissociate). The cache is configured with gc.auto=0, gc.pruneExpire=never, and every commit fetched by SHA is kept under refs/bundle-checkout/commits/<sha>.
- Reason: Several checkouts and clones on one machine must reuse already downloaded objects without disk copies; the price is that pruning the cache could break working copies, so pruning is forbidden and documented.

### A-002 — fetch-depth and filter semantics with a cache
- Date: 2026-11-20
- Status: active
- Within: —
- Decision / Finding: With a cache the working copy is never shallow: any fetch-depth gets the full history through alternates, and fetch-depth 0 also fetches all branches and tags (two fetches, as actions/checkout does). filter is ignored with a cache. Without a cache (no bundle yet and download failed) both behave as in actions/checkout, so a missing bundle never turns into a full 2.5 GB download from GitHub.
- Reason: History in the cache costs no traffic and ydb scripts need HEAD~1 and merge-base; shallow boundaries would only hide it.

### A-003 — cached-git routes fetch through an exact url.<cache>.insteadOf
- Date: 2026-11-20
- Status: active
- Within: —
- Decision / Finding: cached-git first updates the cache with only the missing refs and SHAs, then runs the user's git fetch with -c url.<cache>.insteadOf=<configured remote URL>. The exact URL is longer than ydb's proxy rule url.<proxy>/https://github.com/.insteadOf from GIT_CONFIG_*, so git's longest-match picks the cache. Remote-tracking refs, FETCH_HEAD and --prune stay those of the real remote. -c remote.<r>.url was rejected because it appends a second URL and fetch keeps using the first.
- Reason: Keeps the semantics of the user's fetch unchanged with no refspec rewriting.

### A-004 — Unqualified ref is resolved with one ls-remote
- Date: 2026-11-20
- Status: active
- Within: —
- Decision / Finding: For an unqualified ref the action asks ls-remote for refs/heads/<name> and refs/tags/<name> (branch first, as actions/checkout) and then fetches the exact ref, instead of the refs/heads/<name>* wildcard that actions/checkout fetches. cached-git does the same for short refspec sources, in git's own order (tags first).
- Reason: The wildcard could pull many unrelated branches such as main-*; a filtered ref advertisement is tiny.

### A-005 — mkdir lock with kill -0 stale detection
- Date: 2026-11-20
- Status: replaced
- Within: —
- Decision / Finding: Cache writers are serialized with mkdir <cache>.lock holding host:pid. A lock is taken over only when the owner is on this host and kill -0 reports 'No such process'; EPERM or any other failure keeps the lock. flock is not used because macOS lacks it; ps is not used because it may be forbidden in sandboxes (it made the lock look stale in local tests).
- Reason: One portable mechanism for Linux and macOS runners.
- Links: Replaced by A-007

### A-006 — Why bash and node instead of Go (GD-007)
- Date: 2026-11-20
- Status: active
- Within: D-005
- Decision / Finding: Go is not used: the runner would need setup-go and a build on every run (extra network traffic, against D-004) or prebuilt binaries released per platform. All logic is git CLI calls, which bash expresses directly. Node is used only because the runner gives post steps to JavaScript actions alone; dist/*.js just run the bash scripts, and main.js keeps the allow-unsafe-pr-checkout guard because it parses the event JSON.
- Reason: Concrete blockers per GD-007: per-run build traffic and the platform's post-step integration.

### A-007 — flock where available, mkdir lock with owner-checked reclaim otherwise
- Date: 2026-11-20
- Status: replaced
- Within: —
- Decision / Finding: Cache writers take flock on <cache>.flock when flock exists (Linux, all ydb runners): the kernel releases it when the holder dies, so no stale detection is needed. Without flock (macOS) a mkdir lock <cache>.lock holding host:pid is used. It is reclaimed only when its owner is on this host and kill -0 reports 'No such process'. Reclaimers are serialized by the guard <cache>.lock.reclaim, which records its own owner and is dropped only when that owner is gone; an ownerless guard is dropped after a minute. ps is not used because sandboxes may forbid it. BC_LOCK_MKDIR=1 forces the mkdir lock for tests.
- Reason: An independent review showed that age-based expiry of the reclaim guard lets a suspended reclaimer delete a live lock; flock removes the problem on the platform that matters.
- Links: Replaces A-005; Replaced by A-008

### A-008 — flock where available, mkdir lock with a fail-safe reclaim guard otherwise
- Date: 2026-11-20
- Status: active
- Within: —
- Decision / Finding: Cache writers take flock on <cache>.flock when flock exists (Linux, all ydb runners); the kernel releases it when the holder dies. Without flock (macOS) a mkdir lock <cache>.lock holding host:pid is used and reclaimed only when its owner is on this host and kill -0 reports 'No such process'. Reclaimers are serialized by the guard <cache>.lock.reclaim, which records its owner and is never removed automatically: a guard of a dead owner stops the job with a message to remove it by hand. ps is not used because sandboxes may forbid it. BC_LOCK_MKDIR=1 forces the mkdir lock for tests.
- Reason: Independent review showed that both age-based and owner-based automatic removal of the guard let two reclaimers overlap; correctness wins over liveness in this double-fault case, which only the macOS fallback can hit.
- Links: Replaces A-007
