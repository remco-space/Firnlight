# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Alpenglow is a native macOS app that curates desktop wallpapers from the user's own
Photos library: it finds high-resolution nature photos without people, learns
personal preference from pairwise duels, and maintains a Photos album ("Alpenglow")
that System Settings can rotate as wallpaper. Everything runs on-device.

## How this project is documented

Two layers, with a strict division of labor:

- **`REQUIREMENTS.md` is the product brief** — WHAT the user experiences and WHY,
  in human-readable language (FR-x.y numbering). Product and UX design must always
  be verifiable against it. It contains no APIs, thresholds, or algorithm details.
  When product behavior changes, update the brief in the same change.
- **The code is the technical documentation.** How things work — architecture,
  algorithms, concurrency, persistence, platform constraints — lives as doc
  comments at the implementation site, and nowhere else. `Thresholds.swift` holds
  every tunable constant with its rationale and tuning history (never inline a
  magic number elsewhere). When technical behavior changes, update the doc
  comments in place; do not create separate technical documents or duplicate
  technical detail into this file or the brief.

So: to learn *why* the app behaves some way, read `REQUIREMENTS.md`; to learn
*how*, read the code — start with `ContentView.swift` (the three tabs mirror the
pipeline) and follow the doc comments.

## UI & design skills (precedence)

For any UI/UX, HIG, Liquid Glass, or accessibility work, prefer these skills:
**`liquid-glass`** is authoritative for the glass API and its design rules
(`.glassEffect()`, not `.background(.material)`); **`ui-review-tahoe`** is the
review checklist for macOS UI and defers to it on glass; **`swiftui-specialist`**
covers native SwiftUI generally. These are native-focused and current. Do not use
the third-party `apple-hig-designer-skill-2026` — it is a web/CSS generation skill
targeting the older 26 era, not a native macOS reviewer.

## Build & run

Xcode project (no SwiftPM manifest, no test target):

```bash
# Build
xcodebuild -project Alpenglow.xcodeproj -scheme Alpenglow -configuration Debug build

# Or just open it
open Alpenglow.xcodeproj
```

Requires the full **Xcode 27+** toolchain, not the Command Line Tools. If
`xcodebuild` errors with *"requires Xcode, but active developer directory …
is a command line tools instance"*, the CLT are selected. This machine manages
Xcode via the Xcodes app, so the exact path varies — select the full Xcode
permanently with `sudo xcode-select -s /Applications/Xcode<version>.app/Contents/Developer`,
or override for one command without sudo via
`DEVELOPER_DIR=/Applications/Xcode<version>.app/Contents/Developer xcodebuild …`.

There are no automated tests — thresholds are tuned by hand against a real Photos
library, and the app requires interactive Photos authorization to do anything.

**Signing must stay stable** (`DEVELOPMENT_TEAM = VGZ5MZ2P8B`, automatic signing).
macOS TCC binds the Photos permission grant to the code signature, so changing the
signing identity forces the user to re-grant access. (This lives here because it
is project configuration, not code — it cannot carry its own comment.)

Runtime logs go to the unified logging system under subsystem
`space.remco.Alpenglow` (categories per component). Filter in Console.app or:
```bash
log stream --predicate 'subsystem == "space.remco.Alpenglow"'
```
