# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to the versioning scheme in REQUIREMENTS.md FR-8.9
(`major.minor.patch`, held at `0.x.y` until the app's first real release).

Entries are added to `Unreleased` as part of the change that prompts them —
not written retroactively from git history — and moved under a version
heading when that version is released (FR-10.3).

## [Unreleased]

### Added

- A long analysis run now keeps going while nobody is watching on the Mac: for
  as long as it is working on mains power, the Mac is held out of idle sleep,
  so a run started before you walk away is still going when you come back
  (FR-3.6). The Library tab states plainly what still ends it — the Mac
  sleeping, which closing the lid can cause — and says instead, on battery,
  that analyzing stops when the Mac sleeps. On iPhone and iPad the same line
  says the system decides how long a run continues once the app is left. None
  of this is claimed while a run is merely waiting on iCloud: the hold is
  released and the line goes with it (FR-8.12).

- Analysis now rejects severely flawed photos — a finger over the lens, a
  badly blurred or smeared frame — rather than only ranking them lower,
  whatever the scene (FR-3.1). The Library tab's breakdown gains a matching
  "Blurred or obstructed" count (FR-3.2). Photos already accepted before this
  change are re-examined the next time analysis runs.

### Fixed

- Indoor still lifes — a vase of tulips on the table, a houseplant — no longer
  count as nature. A flower or plant close-up now only qualifies when the
  photo also reads as taken outdoors; real scenes (mountains, water, sky,
  cityscapes) are untouched by the extra test. And a person the detectors see
  only weakly — a swimmer mid-frame whose body and "people" signals each fell
  just short on their own — is now caught by the two signals corroborating
  each other. Already-examined photos are re-examined in the background
  automatically.
- Photos with a person plainly the subject no longer slip into the candidates.
  A reclining subject could defeat both detectors at once — the face too small
  to trip the prominence check, the body detected but a hair under the old
  confidence bar — while grass and foliage carried the scene past the nature
  check. The body-detection bar is lowered for frame-dominating figures, and a
  third, independent signal now backs the two geometric ones: when the
  on-device classifier itself calls the scene "people" with high confidence,
  the photo is set aside. Already-examined photos are re-examined in the
  background automatically.
- A change in how Firnlight examines photos no longer empties the app while it
  catches up. Re-examining the library used to set every not-yet-re-examined
  photo aside at once, so the grid, the duels and the album suggestion could
  stand nearly empty for as long as the re-examination took. Firnlight now
  keeps showing the best picture its previous examination supports, and hands
  the grid, duels, album and album-size suggestion over to the new one
  together, at the point where the new one covers at least as much (FR-5.2). A
  change that doesn't alter how photos are examined still re-examines nothing.

- When near-duplicate shots of the same scene are collapsed in the grid, the
  one kept is now the best of them by the ranking itself. It could previously
  be taken over by a lower-ranked photo in the group for being a Photos
  favorite, or for having a more level horizon — standards the ranking already
  weighs for itself, as much as the user's own choices imply and no more
  (FR-4.3, FR-5.2).

- The wallpaper album's suggested size — the "both great"/"both bad" verdict
  calibration — no longer weighs an ignored photo, a non-nature one, or a
  photo whose cached preference score dates from an earlier Vision pipeline
  against the current library on equal footing. It could previously mix a
  stale, out-of-version score into the good/bad split as though the photo had
  been examined the current way (FR-5.2).
- A long run now also pauses on the Mac when the machine is too warm or Low
  Power Mode is on, saying which it is waiting for, as it already did on
  iPhone and iPad (FR-3.6). The Mac was left out of that on the view that
  pausing would surprise; it matters all the more now that Firnlight holds the
  Mac awake for a run.
- *(iPhone and iPad)* A background run ended by the system used to look
  exactly like one the user had stopped: the Library tab offered Resume and
  said nothing, so a run nobody stopped waited to be noticed. iOS reports a
  system reclaim and the user's own cancel identically, so Firnlight now says
  so — "Analysis stopped while you were away — by you, or by the system" —
  rather than guessing. It still never restarts the run by itself, because
  that would undo a stop the user may have just made (FR-3.3, FR-3.6,
  FR-8.12).
- A duel could resume, or be served, showing the same photo on both sides.
  Resuming after a relaunch trusted two persisted photo IDs without checking
  they were different, and the pair itself was persisted as two separate
  writes that a crash between them could leave mismatched or duplicated; both
  are now guarded, and the duel pair is written atomically as one value.
  Separately, the pair-draw fallback used when the sample budget finds no
  valid pair could serve a near-duplicate (visually identical) pair; it now
  applies the same distance guard the primary sampling loop already does.
- The preference ranker learned only from how a photo looks; FR-5.2's
  "when and where" half was silently missing — a photo's location was never
  even captured, and its capture date was used for display sort order only.
  Both now feed the ranker as learned features (never hard-coded weights), and
  a photo with no date or location is never penalized for the gap (FR-3.8).
  Separately, the blurred/obstructed rejection (FR-3.1) relied solely on the
  general aesthetics score as a blur proxy; it now also runs Vision's
  dedicated `DetectLensSmudgeRequest`, which catches a smudge an otherwise
  well-exposed, sharp frame's aesthetics score alone would miss. Both changes
  re-examine already-analyzed photos in the background, at no cost to any
  recorded judgment.
- FR-5.2's "equal terms" guarantee — no ranking or duel sets a photo examined
  the app's current way against one still examined an older way — was only
  enforced for the ranker's own algorithm version, not for the Vision analysis
  itself: a photo still carrying an earlier analysis pass's feature print and
  aesthetics score could be ranked and dueled directly against ones just
  re-examined the current way while a background re-analysis pass (FR-3.5,
  triggered by a Vision revision change) was still catching up. The Library
  grid, Export album, and Duel tab now hold such a photo out of ranking and
  duels until it is re-examined, at no cost to any recorded judgment (FR-5.3).
- FR-5.4's "a favorite found by a later scan counts the same as one found by
  the first" did not hold once the ranker's learned weights already existed:
  favorites were only ever folded in as pseudo-choices while building those
  weights from scratch, so a favorite Photos revealed on a later scan — or one
  removed — was silently never learned from (or un-learned) afterward. The
  ranker now notices when the favorite set has changed and rebuilds from it,
  the same way it already does for new choices and verdicts.

### Removed

- Support for macOS 26 and iOS 26. Firnlight now needs macOS 27 or iOS 27;
  0.15.0 remains available for 26 and is the last release that runs there.

## [0.15.0] - 2026-08-12

### Changed

- The app is renamed from Alpenglow to Firnlight. The new bundle identifier
  means macOS treats it as a new app: Photos access needs a one-time
  re-grant, and learned duel data does not carry over automatically. The
  Photos album the app maintains is now created as "Firnlight" — the old
  "Alpenglow" album is left untouched for you to delete — and on the Mac,
  System Settings → Wallpaper needs to be re-pointed at the new album.

### Deprecated

- **This is the last release for macOS 26 and iOS 26.** From the next
  release onwards Firnlight needs macOS 27 or iOS 27. This version goes on
  working on 26 for as long as you keep it, but no later one will install
  there, so stay on 0.15.0 if you are not moving to 27.

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
