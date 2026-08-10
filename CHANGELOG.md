# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to the versioning scheme in REQUIREMENTS.md FR-8.9
(`major.minor.patch`, held at `0.x.y` until the app's first real release).

Entries are added to `Unreleased` as part of the change that prompts them —
not written retroactively from git history — and moved under a version
heading when that version is released (FR-10.3).

## [Unreleased]

## [0.14.2] - 2026-08-10

### Fixed

- The exact-count field in the Export tab now follows the album-size slider
  while dragging, instead of only the preview grid updating.

## [0.14.1] - 2026-08-10

### Fixed

- "Open in Photos" no longer crashes the app on the Mac after Photos opens.

## [0.14.0] - 2026-08-10

### Added

- Alpenglow now asks before every change it makes in Photos, naming exactly
  what will be created, added or removed. Each kind of change can be waved
  through for good from the alert itself, and turned back on in Settings.
- A Settings screen — the standard Settings window on the Mac (⌘,), a sheet
  from the foot of the Export tab on iPhone and iPad.
- Your judgments can be copied to a file and restored, here or on another
  device. Restoring merges rather than replaces.
- A deliberate way to start your taste over, which says what goes and what
  stays before it happens.
- Alpenglow can tell you when a newer release exists, if you agree to it
  asking. It reports nothing about you or your library, and you are asked
  once.

### Changed

- The app now keeps itself current with your library, with nothing to press:
  it catches up when it opens and follows changes as Photos reports them, so
  photos you add, edit or delete appear and disappear on their own. The
  scan and re-scan controls are gone — there is nothing left for them to
  find.
- Photos left only in iCloud are retried by the app itself when the network
  and the device allow, instead of waiting behind a retry button.
- The Library tab now offers only stopping a run, and resuming one you
  stopped. "Analyze N Photos", "Resume" as a starter and "Retry N iCloud
  Photos" are gone with the work they used to gate.
- Alpenglow now works only with access to your whole photo library. With
  access limited to a selection it says so and offers the upgrade, rather
  than appearing to work: it cannot tell a deleted photo from an unselected
  one, and Photos will not let it maintain an album at all.

### Fixed

- A version that can't read what another version saved now says so and leaves
  your data untouched, instead of refusing to open.
- Lists that fail to load say so instead of showing the same empty state as a
  library with nothing in it yet.

## [0.13.0] - 2026-08-09

### Changed

- Lowered the supported platforms to macOS 26+ and iOS 26+ (was 27+), so the
  app runs on the currently released system rather than only pre-release
  seeds. Release builds now come from GitHub Actions on the matching
  `macos-26` runner image instead of a local machine, so what ships is
  built against the same SDK generation it targets.
