#!/usr/bin/env bash
#
# SessionStart hook — keep ~/Developer/Xcode-current pointing at a valid Xcode.
#
# Why this exists: the xcode MCP (xcrun mcpbridge) and command-line xcodebuild
# both resolve their toolchain through the ~/Developer/Xcode-current symlink.
# When a beta is deleted after being upgraded (e.g. Beta 3 → Beta 4), the
# symlink dangles and the MCP dies with -32000. This hook heals that on startup.
#
# Behavior (chosen policy: "auto-fix only if broken"):
#   - symlink missing / target deleted → repoint to newest installed Xcode, tell the user
#   - symlink valid but a newer Xcode exists → heads-up only, change nothing
#   - symlink valid and already newest → silent
#
# It never runs sudo and never touches xcode-select — repointing the symlink is
# enough for both MCP servers; the user re-runs xcode-select only if they want
# the bare-CLI toolchain moved too (the message reminds them).
set -euo pipefail

LINK="$HOME/Developer/Xcode-current"

# Newest installed Xcode, by version sort. A GA "Xcode.app" (no version in the
# name) sorts after "Xcode-27.0.0-Beta.N.app" because '.' > '-', so a release
# wins over a beta — which is the toolchain you'd want.
newest_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)"
[ -z "$newest_app" ] && exit 0   # no Xcode installed — nothing to manage
newest_dev="$newest_app/Contents/Developer"

emit() {  # $1 = message shown to the user
  python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"
}

# -e follows the symlink: false when the link is absent OR dangling (target gone).
if [ ! -e "$LINK" ]; then
  old="$(readlink "$LINK" 2>/dev/null || true)"
  mkdir -p "$HOME/Developer"
  ln -sfn "$newest_dev" "$LINK"
  emit "⚠️  Xcode-current was broken (→ ${old:-missing}); repointed to $(basename "$newest_app"). If the plain-CLI toolchain is also stale, run: sudo xcode-select -s $LINK"
  exit 0
fi

# Link is valid — is a newer Xcode installed than what it points at?
current_real="$(cd "$LINK" && pwd -P)"
newest_real="$(cd "$newest_dev" && pwd -P)"
if [ "$current_real" != "$newest_real" ]; then
  emit "ℹ️  A newer Xcode is installed ($(basename "$newest_app")). Xcode-current still points at a working toolchain, so nothing changed. To switch: ln -sfn $newest_dev $LINK"
fi
exit 0
