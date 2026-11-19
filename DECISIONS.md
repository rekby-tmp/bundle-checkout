# Human decisions

This journal contains only durable decisions explicitly made by humans. Human decisions take priority over agent implementation notes. Do not silently violate an active entry or rewrite old entries; append a replacement and link both records.

## Journal

### D-001 — Bundle-first checkout to cut GitHub traffic
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Some workers have a poor network connection to GitHub.
- Decision: Build a reusable GitHub action used instead of actions/checkout. It first downloads a git bundle and unpacks it locally, then attaches the original repository as a remote and from there works like the standard checkout (branches, tags, fetch to update for the checkout). The main goal is to reduce network interaction with GitHub. The downloaded repository must be reusable by several local checkouts or clones so that already downloaded commits are reused.
- Links: —

### D-002 — Bundle source is an HTTP(S) URL; bundle creation stays outside this repository
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: The action needs a place to take the bundle from.
- Decision: The bundle is taken from an HTTP(S) URL (bundle-url, e.g. an internal mirror, S3 or CDN near the workers), plus optionally a local file path. This repository provides only the checkout: the bundle is created and published by external means, and the README only describes the command for creating it.
- Links: —

### D-003 — ydb-platform/ydb is the primary consumer; support only the subset of actions/checkout it needs
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Full compatibility with every actions/checkout input was proposed.
- Decision: The action is made first of all for ydb-platform/ydb. It does not need to support all of actions/checkout, only the subset needed for ydb. The aim is that a ydb workflow only has to change the action name; which inputs are supported follows from what ydb uses (sparse-checkout and fetch-depth were named as examples of compatibility inputs before the scope was narrowed to ydb's needs).
- Links: —

### D-004 — Priorities: maximum simplicity for people and minimal traffic from GitHub
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Design trade-offs of the action and the wrapper.
- Decision: Maximum simplicity for people and minimization of traffic from GitHub are required.
- Links: —

### D-005 — Logic in bash with a thin dependency-free node wrapper for the post step
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Implementation language; a composite action has no post step for cleanup like actions/checkout has.
- Decision: The logic is implemented in bash. A thin node wrapper (main.js/post.js without dependencies and without a build) only runs the bash scripts, which gives a post-step cleanup like actions/checkout.
- Reason: Chosen over a composite action to get the post-step cleanup.
- Links: —

### D-006 — Wrapper for git commands in ydb workflow scripts
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Some ydb workflow scripts run ordinary git commands.
- Decision: Provide a wrapper script (for example `cached-git`) that replaces ordinary git commands in some ydb workflow scripts: it works like the ordinary git from the environment but always uses the downloaded bundle cache. It must not require specifying a URL each time (these scripts usually work with the same repository); it should reuse the already cloned cache repository as much as possible.
- Links: —

### D-007 — Support both persistent and ephemeral runners; no cache baked into the VM image
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: The lifetime of ydb's auto-provisioned VMs is unknown.
- Decision: Support both runners whose disk survives between jobs and ones that start clean (cache-dir: reuse when persistent, otherwise work within the job; the mode is chosen by a setting). Do not support a pre-filled cache baked into the VM image; only the bundle by URL and the cache on the runner disk.
- Links: —

### D-008 — Documentation for people and agents in English
- Date: 2026-11-20
- Status: active
- Decision-maker: rekby
- Context: Who reads the documentation.
- Decision: Instructions are needed for people and for agents, in English.
- Links: —
