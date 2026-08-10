#!/usr/bin/env bash
#
# SessionStart hook — point this clone's git hooks at the tracked `.githooks`
# directory, so FR-10.4's pre-push check is armed without anyone remembering
# to arm it.
#
# Git deliberately never runs hooks straight out of a repository (a cloned
# hook would be arbitrary code running on `git clone`), so `core.hooksPath` is
# a per-clone setting that something has to set. On this machine that
# something is this hook; for anyone else it is the one line in the README.
# Either way the check itself is tracked, and the "Personal data check"
# GitHub Actions workflow runs it server-side regardless, so this only
# decides *when* a failure is found — before the push, or after it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Only ever sets it to the tracked directory, and only when it isn't already
# there: someone who has deliberately pointed hooks elsewhere keeps their
# choice, and the common case costs one config read.
current="$(git config --local --get core.hooksPath || true)"
if [ "$current" != ".githooks" ] && [ -z "$current" ]; then
  git config --local core.hooksPath .githooks
  echo "Armed the pre-push personal-data check (core.hooksPath = .githooks)."
fi

# The hook is tracked with its executable bit, but a clone made with a umask
# or filesystem that drops it would leave git silently ignoring the hook.
chmod +x .githooks/* scripts/*.sh 2>/dev/null || true
