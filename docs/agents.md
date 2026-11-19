# Instructions for agents in repositories that use bundle-checkout

Copy the block below into the agent instructions (`AGENTS.md`, `CLAUDE.md`) of a repository whose
workflows use `bundle-checkout`.

```markdown
## Checkout in CI workflows

- On self-hosted runners with a slow connection to GitHub, check out with
  `rekby-tmp/bundle-checkout` instead of `actions/checkout`: change only `uses:` and add
  `bundle-url`. It accepts the same inputs that the existing checkout steps use. Keep
  `actions/checkout` on GitHub-hosted runners.
- In workflow scripts that run after that checkout, use `cached-git fetch` instead of
  `git fetch`, and in Python take the binary from `os.environ.get('GIT', 'git')`. Arguments stay
  the same. `--depth`, `--deepen`, `--shallow-since` and `--unshallow` are ignored because the
  full history is already local, so do not rely on the working copy becoming shallow.
- Other git commands need no change. `cached-git` passes them to `git` unchanged.
- Never run `git gc`, `git prune` or `git repack` in the bundle-checkout cache
  (`$RUNNER_TOOL_CACHE/bundle-checkout`), and do not delete it from a job: working copies
  borrow its objects.
```
