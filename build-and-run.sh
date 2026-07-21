#!/usr/bin/env bash
#
# Build Alpenglow (Debug), quit any running instance, and launch the fresh
# build. Intended for a quick edit → rebuild → see-it-running dev loop.
#
# Killing first (rather than just re-launching) is deliberate: FR-1.6 makes a
# second launch merely re-focus the already-running window, so without a quit
# you'd keep looking at the OLD build. We quit gracefully, then hard-kill as a
# fallback.
#
# Requires the full Xcode toolchain (not the Command Line Tools). If xcodebuild
# complains that the active developer dir is a CLT instance, point it at Xcode
# for this run:  DEVELOPER_DIR=/Applications/Xcode<version>.app/Contents/Developer ./build-and-run.sh
set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Alpenglow.xcodeproj"
SCHEME="Alpenglow"
CONFIG="Debug"
APP_NAME="Alpenglow"

# Resolve the built .app path from the build settings (works with whatever
# DerivedData location Xcode uses, so it stays in sync with the IDE).
echo "==> Resolving product path…"
APP_PATH="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null \
  | awk -F' = ' '
      / BUILT_PRODUCTS_DIR / { dir = $2 }
      / FULL_PRODUCT_NAME /   { name = $2 }
      END { if (dir && name) print dir "/" name }
'
)"
if [[ -z "$APP_PATH" ]]; then
  echo "error: could not resolve the product path from build settings" >&2
  exit 1
fi

echo "==> Building $SCHEME ($CONFIG)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build reported success but no app at: $APP_PATH" >&2
  exit 1
fi

echo "==> Quitting running $APP_NAME (if any)…"
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
# Fall back to a hard kill for anything the graceful quit didn't catch, then
# wait briefly so the old process releases its window/Photos handles.
pkill -x "$APP_NAME" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  pgrep -x "$APP_NAME" >/dev/null || break
  sleep 0.5
done

echo "==> Launching $APP_PATH"
open "$APP_PATH"
