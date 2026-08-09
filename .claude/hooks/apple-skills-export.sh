#!/usr/bin/env bash
#
# SessionStart hook — regenerate the Apple-authored skills (swiftui-specialist,
# swiftui-whats-new-27) from the local Xcode toolchain instead of tracking
# them in the repo (FR-10.5: nothing authored by a third party is committed
# here, including Apple's own exported skill content — it's obtained fresh
# from the one place it can legitimately come from, the developer's own
# licensed Xcode install, via `xcrun agent skills export`).
#
# This only runs the export when the content is missing (a fresh clone, or
# after `xcode-select`-ing a newer Xcode) — not every session — since the
# export takes a few seconds and the content only changes with the Xcode
# version. Delete .claude/skills/swiftui-specialist or
# .claude/skills/swiftui-whats-new-27 to force a re-export after an Xcode
# update.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.claude/skills"
WANT=(swiftui-specialist swiftui-whats-new-27)

missing=0
for name in "${WANT[@]}"; do
  [ -f "$SKILLS_DIR/$name/SKILL.md" ] || missing=1
done
[ "$missing" -eq 1 ] || exit 0   # already present — nothing to do, silent

# Best-effort: no Xcode 27 / no `agent skills export` subcommand shouldn't
# break session start — the app just won't get these two skills until a
# toolchain that has them is selected.
command -v xcrun >/dev/null 2>&1 || exit 0
EXPORT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXPORT_DIR"' EXIT

xcrun agent skills export --output-dir "$EXPORT_DIR" --replace-existing >/dev/null 2>&1 || exit 0

fetched=()
for name in "${WANT[@]}"; do
  [ -d "$EXPORT_DIR/$name" ] || continue
  rm -rf "$SKILLS_DIR/$name"
  cp -R "$EXPORT_DIR/$name" "$SKILLS_DIR/$name"
  fetched+=("$name")
done

[ "${#fetched[@]}" -gt 0 ] || exit 0

python3 -c '
import json, sys
names = sys.argv[1:]
print(json.dumps({"systemMessage": "📦 Exported from Xcode: " + ", ".join(names) + " (not tracked in git — see .claude/skills/README.md)"}))
' "${fetched[@]}"
exit 0
