#!/usr/bin/env bash
#
# SessionStart hook — keep .claude/skills-src/swift-ios-skills current.
#
# Why this exists: several project-scoped skills (photokit, vision-framework,
# swiftdata, swiftui-patterns, swiftui-uikit-interop, background-processing,
# ios-accessibility, ios-localization, swift-concurrency, app-store-review —
# see .claude/skills/README.md) are symlinks into this submodule rather than
# vendored copies, specifically so they auto-update instead of going stale.
# This hook is what makes that true: it fast-forwards the submodule to the
# upstream default branch on every session start. Silent when already current
# or offline; a one-line heads-up when it moved.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUB="$REPO_ROOT/.claude/skills-src/swift-ios-skills"

[ -d "$SUB/.git" ] || exit 0   # submodule not checked out — nothing to do

emit() {  # $1 = message shown to the user
  python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"
}

before="$(git -C "$SUB" rev-parse HEAD 2>/dev/null || true)"

# Best-effort: no network, no remote change, and any failure are all silent.
if ! git -C "$REPO_ROOT" submodule update --remote --merge -- .claude/skills-src/swift-ios-skills >/dev/null 2>&1; then
  exit 0
fi

after="$(git -C "$SUB" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
  emit "🔄 swift-ios-skills updated ($(git -C "$SUB" log -1 --format=%h "$before")→$(git -C "$SUB" log -1 --format=%h "$after")) — new SKILL.md content is live this session."
fi
exit 0
