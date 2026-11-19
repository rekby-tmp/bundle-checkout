# bundle-checkout — instructions for agents

A GitHub action that replaces `actions/checkout` for runners with a poor connection to GitHub.
Objects come from a git bundle into a shared bare cache, working copies borrow them through
alternates, and only the delta is fetched from GitHub. `cached-git` does the same for
`git fetch` in workflow scripts. The user-facing description is in [README.md](README.md); the
block for consumer repositories is in [docs/agents.md](docs/agents.md).

## Layout

- `action.yml` — inputs and outputs; `runs: node24` with a post step.
- `dist/main.js`, `dist/post.js`, `dist/run.js` — dependency-free wrappers that run the bash
  scripts. `main.js` also holds the `allow-unsafe-pr-checkout` guard, which needs the event JSON.
  There is no build step: edit these files directly.
- `scripts/checkout.sh` — the main step; `scripts/post.sh` — removes the persisted token.
- `scripts/lib.sh` — shared by the action and `cached-git`: cache path, lock, bundle import.
- `bin/cached-git` — the git wrapper.
- `tests/e2e.sh` — end-to-end tests against a fake GitHub over `file://`.

## Rules

- Main consumer: ydb-platform/ydb. Support only the `actions/checkout` inputs and git usage that
  ydb workflows need; do not add an input or option without such a need.
- Priorities, in order: minimal traffic from GitHub, then simplicity for the people who use the
  action. Never download from GitHub what the cache already has.
- Scripts must work with bash 3.2 (macOS): no associative arrays, no `mapfile`, no `${x,,}`;
  expand arrays that may be empty as `${a[@]+"${a[@]}"}`.
- Pass git settings only with `git -c`. Never set or clear `GIT_CONFIG_*`: ydb uses them to route
  GitHub traffic through a proxy.
- The token must never reach the cache config or the logs.
- Never prune objects in a cache: working copies borrow them through alternates.
- Keep `README.md`, `docs/agents.md` and `action.yml` consistent with the behaviour.

## Checks

Before finishing a change, run:

```bash
tests/e2e.sh
shellcheck -x -P SCRIPTDIR scripts/*.sh bin/cached-git tests/e2e.sh
```

CI (`.github/workflows/test.yml`) runs both on Linux and macOS, plus a real run of the action.
A behaviour change needs a test in `tests/e2e.sh`.

## Decision records

Project-specific decision rules take priority over this section.

- Before planning or changing the project, read `DECISIONS.md` and `AGENT-NOTES.md`.
- `DECISIONS.md` contains only durable decisions explicitly made by humans. Record the decision-maker; sign decisions by the current user as `rekby`. Never present an agent inference or implementation choice as a human decision.
- `AGENT-NOTES.md` contains agent implementation decisions, tool choices, tradeoffs, and research findings. These notes never override human decisions.
- Preserve history in both journals. Append replacements, mark old entries replaced or cancelled, and link related records instead of silently rewriting them.
- Before writing any human decision, give an independent separate agent the complete user message, material surrounding context, and every proposed journal mutation. Write only after it confirms that the user decided the point explicitly and that the entry preserves the decision's meaning, conditions, and scope without strengthening them. On any doubt, do not write and explicitly ask the user to decide.
- If a request conflicts with an active human decision, stop and discuss the conflict before changing behavior.
- Do not ask the user to decide routine implementation details inside established constraints; keep them in `AGENT-NOTES.md`.
- The user's global decisions (`GD-NNN`) also apply to this project. They are kept outside the repository and are not copied here.

Use `D-NNN` for human decisions and `A-NNN` for agent notes unless the project establishes another convention.
