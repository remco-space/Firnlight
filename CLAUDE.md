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

A change that adds or alters UI is not done until it has been reviewed against
the **`ui-review-tahoe`** checklist and against section 8 of `REQUIREMENTS.md`
(Native feel) — run that review on the changed views before declaring the work
complete, and when a native-feel defect slips through anyway, add the missing
class of rule to section 8 as part of the fix (that is how FR-8.7 came to be).

## Versioning (FR-8.9)

Keeping the version truthful is Claude's job and part of making a change, not
a release chore. When work with any user-visible effect lands, bump the
version with it: **minor** for capability the user gains, **patch** for a fix
to something that already existed. One body of related work gets one bump —
the highest that applies, patch resetting to 0 on a minor bump — not one per
commit. The **major** number, and the call that the app has earned 1.0
(FR-8.9 holds it at 0.x until then), belong to the user alone; never bump
either unprompted. The build number rises with every version bump, and with
any rebuild that reaches a device without one, so no two different builds
ever present the same version-and-build pair. Where the numbers live in the
project and how they reach what the user sees is, as with all technical
detail, documented at the site.

## Committing

Claude commits its own work without asking. The moment a change is verified
to function as intended — built, and vetted at whatever depth the change
warrants (for UI, that includes the review the skills section requires) — it
is committed, with the version bump FR-8.9 ties to it, rather than left
waiting for permission. One body of related work is one commit. Two things
are never swept into such a commit silently: another agent's unfinished
edits sharing the working tree (coordinate a commit order instead — every
commit must describe a state that actually compiled and ran), and work the
user explicitly asked to hold. An unverified change stays uncommitted, and
saying so beats committing it with a hopeful message.

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

**Versioning (FR-8.9)** lives entirely in two build settings, because that is
the only place a version can live and still be the one the app is running:

- `MARKETING_VERSION` — FR-8.9's `0.minor.patch`. Bump it in the same change
  that makes the user-visible change: minor for capability the user gained,
  patch for fixes to what already existed. It stays `0.x.y` until the app is fit
  for its first real release.
- `CURRENT_PROJECT_VERSION` — the build number, a plain counter that only ever
  goes up. `VERSIONING_SYSTEM = "apple-generic"`, so Apple's own `agvtool`
  drives it: `xcrun agvtool what-version` reads it and `xcrun agvtool
  next-version -all` bumps it (from the project directory). Never let a build
  leave the machine sharing a version *and* build number with a different one.
  Set `MARKETING_VERSION` by editing the build setting, *not* with `agvtool
  new-marketing-version`: that subcommand looks for `CFBundleShortVersionString`
  in `Alpenglow-Info.plist`, which is only a partial plist here
  (`GENERATE_INFOPLIST_FILE = YES` supplies the key), so it reads an empty
  version and then tries to write to a path named after the setting's value.
  `next-version -all` prints the same `Cannot find "…/YES"` line for that
  reason; there it is harmless noise — it bumps the build number in the pbxproj
  correctly and writes no such file. Verify with `git status` if in doubt.

`GENERATE_INFOPLIST_FILE = YES` stamps both into the bundle as
`CFBundleShortVersionString` / `CFBundleVersion`, and `AppIdentity` in
`About.swift` reads them back from `Bundle.main` — no Swift literal anywhere
restates them. The copyright line FR-8.8 asks for is the third setting,
`INFOPLIST_KEY_NSHumanReadableCopyright`, read by the macOS About panel
directly and by the iOS footer through the same `AppIdentity`. (All of this
lives here for the same reason signing does: build settings cannot carry a
comment.)

**The app icon** is a hand-authored Icon Composer bundle, `Alpenglow/AppIcon.icon`
(one bundle serves macOS and iOS). Its artwork carries its own documentation as
comments in the `Assets/*.svg` files; the notes below are the parts JSON and
build settings cannot hold a comment for.

`icon.json` maps FR-8.6's clauses onto the glass-icon feature set, one clause per
key: `fill.linear-gradient` is the colour gradient; four `groups` — Prism,
Light, Ridge, Sun, front to back — give depth, with the glass and the spectrum
overlapping the dark flank (the shoulder peak's glass face is a *layer inside
the Ridge group*, not the Prism, because it stands beyond the saddle and the
fan must pass in front of it — see `Assets/shoulder.svg`); the Prism casts a `shadow` onto the ridge
and the Ridge one onto the ground (light and sun cast none — light does not
shadow); `translucency` on the glass plus the Light group's `blend-mode:
plus-lighter` is how the layers show through one another; `specular` on the
glass faces puts the highlight on them, on the sun's side, which is what makes
it read as lit from one direction; and `refractivity` + `blur-material` on the
Prism act on the beam layer *behind* it — the system itself bends and blurs
the sun's light through the glass (the dispersion geometry and its faux
physics are documented in `Assets/light.svg`). Four is the ceiling — a fifth
visible group is rejected with `too-many-visible-groups`.
The six appearances are *derived* by the system from this one composition — the
`fill-specializations` / `image-name-specializations` keys parse but do nothing in
Xcode 27b4, so per-appearance artwork is not authorable.

Two ways to get *no icon at all*, both silent — no warning, and the build still
succeeds:
- `ASSETCATALOG_COMPILER_APPICON_NAME` not matching the bundle's basename
  (`AppIcon`).
- Moving the `.icon` inside an `.xcassets`. It must stay a sibling of the Swift
  sources; the target's synchronized file group picks it up with no pbxproj edit.

**The icon exists in the built app three times over**, and they are not the
same picture — which matters because FR-8.8 forbids the app ever showing "a
second, subtly different version" of its own icon:
- the compiled Icon Composer composition in `Assets.car` (`CFBundleIconName`),
  which the system renders *live* — glass, deep tones, dispersion — and which
  is what the Dock, Finder and the Home Screen draw;
- `Contents/Resources/AppIcon.icns` (`CFBundleIconFile`), which `actool` bakes
  from the same composition as a flat compatibility fallback, and which comes
  out lighter and hazier than the live rendering. It is *not* what any surface
  here was observed to use, so it is left in place — removing it means
  `ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR = none`, which risks the
  silent no-icon failures above for no proven gain;
- on iOS, the rendered `AppIcon60x60@2x.png` / `AppIcon76x76@2x~ipad.png` files
  listed under `CFBundleIcons`. Comparing one against a Home Screen screenshot
  at the same size, they visibly differ (mean channel difference ≈ 22/255) —
  SpringBoard composes the layers live rather than blitting the file. There is
  no iOS API that hands back the composed icon, which is why `AboutFooter`
  shows no icon at all.

Only on macOS can code ask for *the* icon: `NSApp.applicationIconImage` is the
image the Dock tile draws, and passing it as the About panel's
`applicationIcon` option is the one way to guarantee the two agree.

**IconServices caches a rendered icon per bundle path, and the cache goes
stale.** Seen here: the app at its DerivedData path rendered the icon design
from *weeks* earlier through `NSWorkspace.icon(forFile:)` while its Dock tile
drew the empty Icon Composer placeholder grid — with the current artwork
sitting correctly in the same bundle's `.icns`. Rebuilding does not clear it,
and neither does `lsregister -f -R -trusted <app>` — which every build already
runs anyway, as Xcode's own `RegisterWithLaunchServices` phase. The tell is
that the *identical* bundle copied to a fresh path renders correctly; that copy
is also the way to check what the icon really looks like in situ:
```bash
cp -R "$(...)/Build/Products/Debug/Alpenglow.app" /tmp/iconcheck/ && open /tmp/iconcheck/Alpenglow.app
```
Deleting the icon store is what actually shifts it. `build-and-run.sh` does that
for you, but only when the contents of `AppIcon.icon` changed — the deletion is
machine-wide and the Dock restart blinks every tile, so routine builds stay
quiet. Outside the script, by hand:
```bash
# -exec, not a bare glob: under zsh an unmatched glob aborts the whole command.
# (2>/dev/null swallows the permission noise from unrelated sandboxed caches.)
find "$(getconf DARWIN_USER_CACHE_DIR)" -maxdepth 1 -name 'com.apple.iconservices*' \
  -exec rm -rf {} + 2>/dev/null
killall iconservicesagent; killall Dock
```

Validate and preview from the command line — there is no need to open the GUI:
```bash
ICT="/Applications/Xcode-27.0.0-Beta.4.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
# Diagnostics (empty array == valid):
"$ICT" Alpenglow/AppIcon.icon --export-intermediate-representation --output-directory /tmp/ir --platform macOS
# Render one of Default/Dark/ClearLight/ClearDark/TintedLight/TintedDark:
"$ICT" Alpenglow/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1
```

Runtime logs go to the unified logging system under subsystem
`space.remco.Alpenglow` (categories per component). Filter in Console.app or:
```bash
log stream --predicate 'subsystem == "space.remco.Alpenglow"'
```
For a simulator, the same predicate works through `xcrun simctl spawn <udid> log show`.

**Simulator screenshots need no permission**: `xcrun simctl io <udid> screenshot
shot.png` reads the simulator's framebuffer, so it needs neither Simulator.app
open nor the Screen Recording grant `screencapture` requires — without that grant
`screencapture` silently returns solid black. Load test photos with
`xcrun simctl addmedia <udid> *.jpg`.

**Vision does not run in the iOS simulator**: every request fails with `Failed to
create espresso context`, so analysis accepts nothing there and the grid, duels
and album preview stay empty however many photos are loaded. Scanning is
unaffected; anything downstream of `ImageAnalyzer` needs a real device or the Mac.
