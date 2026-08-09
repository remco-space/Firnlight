#!/usr/bin/env bash
#
# SessionStart hook — keep .claude/skills-src/swift-ios-skills current, but
# only up to the latest tagged release, not the branch tip.
#
# Why this exists: several project-scoped skills (photokit, vision-framework,
# swiftdata, swiftui-patterns, swiftui-uikit-interop, background-processing,
# ios-accessibility, ios-localization, swift-concurrency, app-store-review —
# see .claude/skills/README.md) are symlinks into this submodule rather than
# vendored copies, specifically so they auto-update instead of going stale.
#
# Why tags, not `--remote` branch tip: SKILL.md content is loaded straight
# into the assistant's context as instructions. Fast-forwarding to whatever
# an arbitrary commit on upstream's default branch happens to be would mean
# unreviewed third-party content (or a compromised commit) reaching context
# with no human in the loop. A tagged release is a discrete, named point the
# upstream maintainer stood behind — bounded exposure, still automatic.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUB="$REPO_ROOT/.claude/skills-src/swift-ios-skills"

[ -d "$SUB/.git" ] || exit 0   # submodule not checked out — nothing to do

emit() {  # $1 = message shown to the user
  python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"
}

# Best-effort: any network failure here is silent, not fatal to session start.
git -C "$SUB" fetch --tags --quiet origin >/dev/null 2>&1 || exit 0

latest_tag="$(git -C "$SUB" tag -l 'v*' --sort=-v:refname | head -1)"
[ -n "$latest_tag" ] || exit 0

before="$(git -C "$SUB" rev-parse HEAD 2>/dev/null || true)"
target="$(git -C "$SUB" rev-parse "$latest_tag" 2>/dev/null || true)"
[ -n "$target" ] || exit 0

[ "$before" = "$target" ] && exit 0   # already on the latest release — silent

git -C "$SUB" checkout --quiet "$latest_tag" -- . 2>/dev/null || exit 0
git -C "$SUB" checkout --quiet "$latest_tag" 2>/dev/null || exit 0

emit "🔄 swift-ios-skills advanced to $latest_tag — new SKILL.md content is live this session. Run 'git -C .claude/skills-src/swift-ios-skills log --oneline ${before:0:7}..${target:0:7}' to see what changed."
exit 0
