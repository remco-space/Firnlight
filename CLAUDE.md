# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Firnlight is a native macOS app (with an iPhone/iPad companion) that curates
desktop wallpapers from the user's own Photos library: it finds high-resolution
nature photos without people, learns preference from pairwise duels, and
maintains a Photos album ("Firnlight") that System Settings can rotate as
wallpaper. Everything runs on-device. Target: **macOS/iOS 27+**.

## How this project is documented

- **`REQUIREMENTS.md` is the product brief** — WHAT the user experiences and
  WHY (FR-x.y numbering). No APIs, thresholds, or algorithms. Product and UX
  must be verifiable against it; when product behavior changes, update the
  brief in the same change.
- **The code is the technical documentation.** Architecture, algorithms,
  concurrency, persistence, platform constraints live as doc comments at the
  implementation site and nowhere else. `Thresholds.swift` holds every tunable
  constant with its rationale and tuning history — never inline a magic number
  elsewhere. Never create separate technical documents, or duplicate technical
  detail into this file or the brief.

To learn *why*, read `REQUIREMENTS.md`; to learn *how*, read the code, starting
at `ContentView.swift` (the three tabs mirror the pipeline).

## UI & design skills (precedence)

For UI/UX, HIG, Liquid Glass, or accessibility work: **`liquid-glass`** is
authoritative for the glass API and its design rules (`.glassEffect()`, not
`.background(.material)`); **`ui-review-tahoe`** is the macOS review checklist
and defers to it on glass; **`swiftui-specialist`** covers SwiftUI generally;
**`swiftui-whats-new-27`** carries what the 27 SDK changed. Do not use the
third-party `apple-hig-designer-skill-2026` — it generates web/CSS, and is not
a native macOS reviewer.

A change that adds or alters UI is not done until reviewed against the
**`ui-review-tahoe`** checklist and section 8 of `REQUIREMENTS.md` (Native
feel). When a native-feel defect slips through anyway, add the missing class of
rule to section 8 as part of the fix — that is how FR-8.7 came to be.

## Framework skills (project-scoped, none tracked in git — FR-10.5)

`.claude/skills/` carries third-party skills that are never committed here,
whatever their license. Two mechanisms obtain them fresh:

- Symlinks into the `.claude/skills-src/swift-ios-skills` submodule
  ([dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills)):
  `photokit`, `vision-framework`, `swiftdata`, `swiftui-patterns`,
  `swiftui-uikit-interop`, `background-processing`, `ios-accessibility`,
  `ios-localization`, `swift-concurrency`, `app-store-review`; and into
  `.claude/skills-src/claude-code-apple-skills`
  ([rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills)):
  `liquid-glass`, `ui-review-tahoe`. A `SessionStart` hook
  (`.claude/hooks/skills-submodule-update.sh`) advances both submodules to each
  one's latest **tagged release** — not the branch tip, since SKILL.md loads
  straight into context as instructions and a tag is a bounded, named point.
- `swiftui-specialist` and `swiftui-whats-new-27` are Apple's own, published
  only via the local toolchain (`xcrun agent skills export`), so there is
  nothing to point a submodule at. `.claude/hooks/apple-skills-export.sh` runs
  that export on `SessionStart` when they're missing. Both are gitignored.

See `.claude/skills/README.md` for the provenance table and how to pin a
revision if a release regresses, and `THIRD_PARTY_NOTICES.md` for license
notices.

The upstream repo has ~86 skills; only the ones this app touches were added.
**When a change adds a framework or platform capability** (a new `import`, a
new App Store surface), check that repo for a matching skill before writing the
feature from scratch; if it fits, symlink
`.claude/skills-src/swift-ios-skills/skills/<name>` into `.claude/skills/<name>`
and add its provenance row. No speculative skills for unused frameworks.

## Versioning (FR-8.9)

Keeping the version truthful is part of making a change, not a release chore.
When work with any user-visible effect lands, bump with it: **minor** for
capability gained, **patch** for a fix to what existed. One body of related
work gets one bump — the highest that applies, patch resetting to 0 on a minor
bump. The **major** number, and the call that the app has earned 1.0, belong to
the user alone; never bump either unprompted — it stays `0.x.y` until then. The build number rises with every
version bump, and with any rebuild that reaches a device without one.

## Release process (FR-10)

Release steps are scripts, not prose: any step a machine can run — building,
rendering, capturing, checking — lives as a runnable script (in `scripts/`),
invoked by name from the docs. A recipe of copy-paste commands in documentation
is a script that hasn't been written yet.

Signing: automatic signing under the free personal team (`VGZ5MZ2P8B`) only —
no Developer ID, no notarization. A downloaded release is ad-hoc signed enough
to run, but Gatekeeper blocks first launch (FR-10.2); the fix is right-click →
Open, or `xattr -cr Firnlight.app`.

Releases are cut by pushing a `vX.Y.Z` tag matching `MARKETING_VERSION`; CI
builds and publishes, taking the release body from the matching `CHANGELOG.md`
section.

**Both build workflows are dormant** (manual dispatch only), because GitHub's
runner images carry Xcode 26 at the newest and cannot compile a 27 target. No
binary is produced and tagging publishes nothing; v0.15.0 stays the current
download. Each workflow's header says what to restore. The personal-data check
keeps running on every push — FR-10.4 admits no gap.

File formats: `LICENSE` follows
[choosealicense.com/licenses/mit](https://choosealicense.com/licenses/mit/);
`CHANGELOG.md` follows [keepachangelog.com](https://keepachangelog.com/), with
entries added to `Unreleased` as part of the change that prompts them, never
retroactively from git history; `README.md` follows
[makeareadme.com](https://www.makeareadme.com/), trimmed to what a small app
needs.

The README's picture story (FR-10.10) is backed by `docs/store/`: `icon.png`
plus one PNG per tab (`library.png`, `duel.png`, `export.png`), captioned with
the release they were captured for. `scripts/capture-store-screenshots.sh`
regenerates all four and updates that caption to the current
`MARKETING_VERSION`. Run it whenever a release changes what a tab looks like —
a stale screenshot is what FR-10.10 forbids. It needs a real, authorized Photos
library with analyzed candidates, so it cannot run in the Simulator (Vision
does not analyze there — see below). The script documents the rest.

First-party-only tree (FR-10.5): nothing authored by a third party is tracked
here, whatever its license — code, assets, or development aids such as skill
content. What the build or working practice needs from elsewhere is *obtained*,
not copied: a pointer plus an automatic fetch step a fresh clone can run.

Pre-publish check (FR-10.4): before every push, run
`scripts/check-no-personal-data.sh` — a standing check, not a one-time cleanup.
The Team ID and bundle identifier are public by design and are not personal
data; this check is about the developer's own machine and accounts.

## Committing

Claude commits its own work without asking. The moment a change is verified to
function as intended — built, and vetted at whatever depth it warrants (for UI,
the review above) — it is committed, with the version bump FR-8.9 ties to it.
One body of related work is one commit. Two things are never swept in silently:
another agent's unfinished edits sharing the working tree (coordinate a commit
order — every commit must describe a state that compiled and ran), and work the
user asked to hold. An unverified change stays uncommitted, and saying so beats
committing it with a hopeful message.

## Branching & merging (FR-10.6)

`main` always builds and always describes the current working state. Each body
of work lives on a short-lived branch named for the work (`fix-duel-flicker`,
not `wip2`), branched from `main` and merged back whole once verified; delete
the branch after. Merges use `--no-ff`, so each body of work stays legible as
one unit. Plain GitHub-flow trunk development — if a branch structure needs
explaining, it's wrong.

## Build & run

Xcode project (no SwiftPM manifest, no test target):

```bash
xcodebuild -project Firnlight.xcodeproj -scheme Firnlight -configuration Debug build
open Firnlight.xcodeproj   # or just this
```

Requires the full **Xcode 27+** toolchain, not the Command Line Tools. If
`xcodebuild` errors with *"requires Xcode, but active developer directory … is
a command line tools instance"*, the CLT are selected. Select the full Xcode
permanently with
`sudo xcode-select -s /Applications/Xcode<version>.app/Contents/Developer`, or
per-command via
`DEVELOPER_DIR=/Applications/Xcode<version>.app/Contents/Developer xcodebuild …`.

No automated tests — thresholds are tuned by hand against a real Photos
library, and the app needs interactive Photos authorization to do anything.

**Signing must stay stable** (`DEVELOPMENT_TEAM = VGZ5MZ2P8B`, automatic
signing). macOS TCC binds the Photos grant to the code signature, so changing
the signing identity forces the user to re-grant access.

**Versioning (FR-8.9)** lives in two build settings, the only place a version
can live and still be the one the app is running:

- `MARKETING_VERSION` — FR-8.9's `0.minor.patch`.
- `CURRENT_PROJECT_VERSION` — the build number, a counter that only goes up.
  `VERSIONING_SYSTEM = "apple-generic"`, so `agvtool` drives it: `xcrun agvtool
  what-version` reads, `xcrun agvtool next-version -all` bumps (from the
  project directory). Set `MARKETING_VERSION` by editing the build setting,
  *not* with `agvtool new-marketing-version`: that subcommand looks for
  `CFBundleShortVersionString` in `Firnlight-Info.plist`, which is only a
  partial plist here (`GENERATE_INFOPLIST_FILE = YES` supplies the key), so it
  reads an empty version and writes to a path named after the setting's value.
  `next-version -all` prints the same `Cannot find "…/YES"` line — there it is
  harmless noise; it bumps the pbxproj correctly and writes no such file.

`GENERATE_INFOPLIST_FILE = YES` stamps both into the bundle as
`CFBundleShortVersionString` / `CFBundleVersion`, and `AppIdentity` in
`About.swift` reads them back from `Bundle.main` — no Swift literal restates
them. FR-8.8's copyright line is a third setting,
`INFOPLIST_KEY_NSHumanReadableCopyright`, read by the macOS About panel directly
and by the iOS footer through `AppIdentity`. (Build settings cannot carry a
comment, which is why this and the signing note live here.)

### The app icon

A hand-authored Icon Composer bundle, `Firnlight/AppIcon.icon` (one bundle
serves both platforms). Artwork is documented in the `Assets/*.svg` files; below
is only what JSON and build settings cannot hold a comment for.

`icon.json` maps FR-8.6's clauses onto the glass-icon feature set, one clause
per key: `fill.linear-gradient` is the colour gradient; four `groups` — Prism,
Light, Ridge, Sun, front to back — give depth, with the glass and spectrum
overlapping the dark flank (the shoulder peak's glass face is a *layer inside
the Ridge group*, not the Prism, because it stands beyond the saddle and the fan
must pass in front of it — see `Assets/shoulder.svg`); the Prism casts a
`shadow` onto the ridge and the Ridge one onto the ground (light and sun cast
none); `translucency` on the glass plus the Light group's `blend-mode:
plus-lighter` makes layers show through one another; `specular` on the glass
faces puts the highlight on the sun's side, which is what reads as lit from one
direction; `refractivity` + `blur-material` on the Prism act on the beam layer
*behind* it, so the system bends and blurs the sun's light through the glass
(dispersion geometry documented in `Assets/light.svg`). Four visible groups is
the ceiling — a fifth is rejected with `too-many-visible-groups`. The six
appearances are *derived* from this one composition;
`fill-specializations` / `image-name-specializations` parse but do nothing in
Xcode 27 betas, so per-appearance artwork is not authorable.

Two ways to get *no icon at all*, both silent — no warning, build still
succeeds:
- `ASSETCATALOG_COMPILER_APPICON_NAME` not matching the bundle basename
  (`AppIcon`).
- Moving the `.icon` inside an `.xcassets`. It must stay a sibling of the Swift
  sources; the target's synchronized file group picks it up with no pbxproj edit.

`actool` also bakes a flat `AppIcon.icns` fallback into the bundle. Nothing here
was observed to use it, and it stays: removing it means
`ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR = none`, which risks the silent
failures above for no proven gain. (Why the bundle's several icon renderings are
not interchangeable, and what each surface actually draws, is in `About.swift`;
the IconServices cache trap and its only cure are in `build-and-run.sh`.)

Validate and preview without opening the GUI:

```bash
ICT="/Applications/Xcode<version>.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
# Diagnostics (empty array == valid):
"$ICT" Firnlight/AppIcon.icon --export-intermediate-representation --output-directory /tmp/ir --platform macOS
# Render one of Default/Dark/ClearLight/ClearDark/TintedLight/TintedDark:
"$ICT" Firnlight/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1
```

Runtime logs go to the unified logging system under subsystem
`space.remco.Firnlight`, a category per component.
