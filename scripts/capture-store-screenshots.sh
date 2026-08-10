#!/usr/bin/env bash
#
# Regenerate docs/store/{icon,library,duel,export}.png — the front-page
# screenshots FR-10.10 requires — and update README.md's caption to the
# release they were captured for.
#
# Everything below runs without touching the pointer: tab selection goes
# through the same UserDefaults key FR-8.1 already restores it from, and the
# window is found by reading its real frame back rather than assuming one or
# clicking to raise it. That matters because this may run on a machine doing
# other things with the screen at the same time — a synthetic click has
# nowhere safe to land.
#
# Requires: the full Xcode toolchain (for ictool and xcodebuild — see
# CLAUDE.md's Build & run section for selecting it); a Photos library the app
# is already authorized against with real analyzed candidates (an empty or
# simulated library produces empty, unrepresentative screenshots — precisely
# the "look the app doesn't really have" FR-10.10 forbids, which is also why
# this can't run in the iOS Simulator: Vision doesn't analyze anything
# there); and the Screen Recording grant for whatever runs this script —
# screencapture fails *silently*, returning a solid black image with a zero
# exit code, which the size check below exists to catch.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Firnlight"
BUNDLE_ID="space.remco.Firnlight"
OUT_DIR="docs/store"
# A real screenshot of this UI runs well into six figures of bytes; a solid
# black or white capture (the missing-permission failure mode) compresses to
# a small fraction of that. Comfortably below the smallest real capture seen
# and comfortably above what a blank capture produces.
MIN_BYTES=51200

mkdir -p "$OUT_DIR"

check_size() {
  local f="$1"
  local size
  size="$(stat -f%z "$f")"
  if (( size < MIN_BYTES )); then
    echo "error: $f is only $size bytes — looks like a black capture (missing Screen Recording grant?)" >&2
    exit 1
  fi
}

echo "==> Building $APP_NAME (Debug)…"
xcodebuild -project Firnlight.xcodeproj -scheme "$APP_NAME" -configuration Debug build

APP_PATH="$(
  xcodebuild -project Firnlight.xcodeproj -scheme "$APP_NAME" -configuration Debug \
    -showBuildSettings 2>/dev/null \
  | awk -F' = ' '
      / BUILT_PRODUCTS_DIR / { dir = $2 }
      / FULL_PRODUCT_NAME /   { name = $2 }
      END { if (dir && name) print dir "/" name }
'
)"
[[ -d "$APP_PATH" ]] || { echo "error: build reported success but no app at: $APP_PATH" >&2; exit 1; }

echo "==> Rendering the icon…"
XCODE_ROOT="$(xcode-select -p)"
XCODE_ROOT="${XCODE_ROOT%/Contents/Developer}"
ICT="$XCODE_ROOT/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICT" ]] || { echo "error: ictool not found at: $ICT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$ICT" Firnlight/AppIcon.icon --export-image --output-file "$WORK/icon.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
sips -Z 256 "$WORK/icon.png" --out "$OUT_DIR/icon.png" >/dev/null
check_size "$OUT_DIR/icon.png"

quit_app() {
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.5
  done
}

capture_tab() {
  local tab="$1"
  # Braced, not bare "$tab…": under a UTF-8 locale bash's parameter-name
  # scanner can swallow part of a following multibyte character (the
  # ellipsis) into the variable name, producing a spurious "unbound
  # variable" under `set -u`. "${tab}" has an explicit boundary.
  echo "==> Capturing ${tab}…"
  quit_app
  defaults write "$BUNDLE_ID" selectedTab -string "$tab"
  open "$APP_PATH"
  osascript -e "tell application \"$APP_NAME\" to activate"
  # Poll for the window rather than a fixed sleep: a fresh build's first
  # launch (code-signing verification, catching the library up) takes an
  # unpredictable amount of time longer than a warm relaunch.
  local frame x y w h
  frame=""
  for _ in $(seq 1 30); do
    frame="$(osascript -e "tell application \"System Events\" to tell process \"$APP_NAME\" to get {position, size} of window 1" 2>/dev/null || true)"
    [[ -n "$frame" ]] && break
    sleep 1
  done
  [[ -n "$frame" ]] || { echo "error: ${tab}'s window never appeared" >&2; exit 1; }
  IFS=', ' read -r x y w h <<<"$frame"
  # The window existing isn't the tab being ready: Export in particular shows
  # "Loading candidates…" for a moment after the window appears while it
  # reads the ranked list back. A fixed settle beats polling for content
  # here — there's no cheap, generic way to ask the view "are you done
  # loading" from outside it.
  sleep 3
  screencapture -x -R"$x,$y,$w,$h" "$WORK/$tab-raw.png"
  sips -Z 1400 "$WORK/$tab-raw.png" --out "$OUT_DIR/$tab.png" >/dev/null
  check_size "$OUT_DIR/$tab.png"
}

capture_tab library
capture_tab duel
capture_tab export
quit_app

echo "==> Updating README.md's caption to the current release…"
VERSION="$(sed -n 's/^\t*MARKETING_VERSION = \(.*\);/\1/p' Firnlight.xcodeproj/project.pbxproj | head -1)"
[[ -n "$VERSION" ]] || { echo "error: could not read MARKETING_VERSION" >&2; exit 1; }
sed -i '' -E "s/Screens as of v[0-9]+\.[0-9]+\.[0-9]+\./Screens as of v${VERSION}./" README.md

echo "==> Done — docs/store/*.png and README.md's caption are current with v$VERSION."
