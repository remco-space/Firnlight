#!/usr/bin/env bash
#
# Scans an installed Apple SDK for symbols in one framework gated to a given
# OS version — a way to check whether a framework skill's pinned content (or
# no skill at all) still matches what the SDK actually ships, instead of
# trusting docs or skills that lag beta and even shipping SDKs.
#
# This is a best-effort text scan over .swiftinterface files (Swift-native
# frameworks) and public headers (Objective-C frameworks) — not a real
# parser. It surfaces candidates for a human or agent to read in context; it
# is not a certified API list. Matching is exact-version, not "at or above":
# pass the OS floor you actually care about (see usage).
#
# Usage: scan-sdk-capabilities.sh <FrameworkName> [minVersion] [platform ...]
#   minVersion  OS version to match, e.g. 27 or 26.4 (default: 27)
#   platform    one or more of macOS iOS watchOS tvOS visionOS
#               (default: macOS iOS)
#
# Respects DEVELOPER_DIR if set; otherwise uses `xcode-select -p`, falling
# back to the newest /Applications/Xcode*.app if that resolves to the
# Command Line Tools (which ship no platform SDKs).
#
# Examples:
#   scripts/scan-sdk-capabilities.sh Vision
#   scripts/scan-sdk-capabilities.sh Photos 27 macOS
#   scripts/scan-sdk-capabilities.sh FoundationModels 27 macOS iOS

set -euo pipefail

usage() {
  echo "Usage: $0 <FrameworkName> [minVersion] [platform ...]" >&2
  echo "  minVersion default: 27" >&2
  echo "  platform default: macOS iOS  (also: watchOS tvOS visionOS)" >&2
  exit 1
}

[ $# -ge 1 ] || usage
FRAMEWORK="$1"
MIN_VERSION="${2:-27}"
shift $(( $# >= 2 ? 2 : $# )) || true
PLATFORMS=("$@")
[ ${#PLATFORMS[@]} -gt 0 ] || PLATFORMS=(macOS iOS)

resolve_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return
  fi
  local selected
  selected=$(xcode-select -p 2>/dev/null || true)
  if [[ -z "$selected" || "$selected" == *CommandLineTools* ]]; then
    local candidate
    candidate=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)
    if [ -z "$candidate" ]; then
      echo "error: no full Xcode.app under /Applications and DEVELOPER_DIR is unset" >&2
      echo "       (command line tools ship no platform SDKs to scan)" >&2
      exit 1
    fi
    printf '%s\n' "$candidate/Contents/Developer"
  else
    printf '%s\n' "$selected"
  fi
}

DEV_DIR=$(resolve_developer_dir)
echo "Using toolchain: $DEV_DIR" >&2

platform_paths() {
  case "$1" in
    macOS)    echo "MacOSX.platform MacOSX" ;;
    iOS)      echo "iPhoneOS.platform iPhoneOS" ;;
    watchOS)  echo "WatchOS.platform WatchOS" ;;
    tvOS)     echo "AppleTVOS.platform AppleTVOS" ;;
    visionOS) echo "XROS.platform XROS" ;;
    *)        echo "" ;;
  esac
}

found_any=0

for platform in "${PLATFORMS[@]}"; do
  read -r platform_dir sdk_prefix <<<"$(platform_paths "$platform")"
  if [ -z "$platform_dir" ]; then
    echo "warning: unknown platform '$platform', skipping" >&2
    continue
  fi

  sdk_root="$DEV_DIR/Platforms/$platform_dir/Developer/SDKs"
  sdk_path=$(ls -d "$sdk_root/${sdk_prefix}"[0-9]*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$sdk_path" ] || sdk_path=$(ls -d "$sdk_root/${sdk_prefix}.sdk" 2>/dev/null || true)
  if [ -z "$sdk_path" ]; then
    echo "warning: no $platform SDK found under $sdk_root" >&2
    continue
  fi

  fw_dir="$sdk_path/System/Library/Frameworks/${FRAMEWORK}.framework"
  if [ ! -d "$fw_dir" ]; then
    echo
    echo "== $platform ($(basename "$sdk_path")): $FRAMEWORK.framework not present in this SDK =="
    continue
  fi

  found_any=1
  echo
  echo "== $platform SDK $(basename "$sdk_path") — $FRAMEWORK, symbols gated to version $MIN_VERSION =="

  # -L: macOS frameworks are versioned bundles (Modules -> Versions/Current/Modules)
  # Match only the platform actually being scanned: platforms' major version
  # numbers drift apart (e.g. watchOS reached "27" while iOS/macOS were still
  # on "26"), so matching any platform token against MIN_VERSION produces
  # false positives from unrelated platforms' availability on the same line.
  case "$platform" in
    macOS) swift_available_platform="macOS"; header_available_platform="macos" ;;
    iOS)   swift_available_platform="iOS";   header_available_platform="ios" ;;
    watchOS) swift_available_platform="watchOS"; header_available_platform="watchos" ;;
    tvOS)  swift_available_platform="tvOS";  header_available_platform="tvos" ;;
    visionOS) swift_available_platform="visionOS"; header_available_platform="visionos" ;;
  esac

  swiftinterface=$(find -L "$fw_dir/Modules" -iname "*.swiftinterface" 2>/dev/null \
    | grep -v -- '-macabi\.swiftinterface$' | grep -E 'arm64e?-apple' | head -1)
  [ -n "$swiftinterface" ] || swiftinterface=$(find -L "$fw_dir/Modules" -iname "*.swiftinterface" 2>/dev/null | head -1)
  if [ -n "$swiftinterface" ]; then
    echo "--- Swift interface ($(basename "$swiftinterface")) ---"
    grep -n -A2 -E "@available\([^)]*\b${swift_available_platform} ${MIN_VERSION}(\.[0-9]+)?\b" "$swiftinterface" \
      || echo "  (no matches)"
  fi

  headers_dir="$fw_dir/Headers"
  if [ -d "$headers_dir" ]; then
    echo "--- ObjC headers ---"
    # -L: macOS frameworks are versioned bundles (Headers -> Versions/Current/Headers)
    find -L "$headers_dir" -iname "*.h" -print0 2>/dev/null | xargs -0 grep -Hn -E \
      "API_AVAILABLE\([^)]*\b${header_available_platform}\(${MIN_VERSION}(\.[0-9]+)?\)" 2>/dev/null \
      || echo "  (no matches)"
  fi
done

if [ "$found_any" -eq 0 ]; then
  echo "error: $FRAMEWORK.framework not found in any requested SDK under $DEV_DIR" >&2
  exit 1
fi

echo
echo "Best-effort text scan, not a parser. Exact-version match only — rerun" >&2
echo "with a higher minVersion for a later OS floor. Cross-check anything" >&2
echo "relevant against real docs/behavior before depending on it." >&2
