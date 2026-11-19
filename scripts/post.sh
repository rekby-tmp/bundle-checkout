#!/usr/bin/env bash
# Post step: removes the token that the main step persisted into the workspace config.
set -euo pipefail

repo_path=${STATE_repo_path:-}
auth_key=${STATE_auth_key:-}
if [ -n "$repo_path" ] && [ -n "$auth_key" ] && [ -d "$repo_path/.git" ]; then
  git -C "$repo_path" config --local --unset-all "$auth_key" 2>/dev/null || true
fi
