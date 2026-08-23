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

- The app now notices, on its own, when the system's Vision framework starts
  resolving a face, human, classification, aesthetics, lens-smudge, horizon,
  or feature-print request to a different revision than it did on a previous
  launch — including a revision that arrived with an OS update rather than
  a Firnlight update — and, if that ever actually changes what a photo
  measures as, re-examines affected photos in the background with no
  judgment lost, the same way a hand-tuned pipeline change already did; on
  an ordinary launch where nothing has changed, this adds nothing to the
  version every already-analyzed photo already carries, so no library is
  re-examined for a reason that never happened (FR-5.2).
- The Duel tab now has an "Undo" command, reachable both as an on-screen
  button (disabled, not hidden, when there is nothing to take back) and as
  the Mac's Edit-menu ⌘Z: it reverses the single most recent duel choice or
  "Both Are Great"/"Both Are Bad" verdict, restoring the ranking to what it
  would have been had that judgment never been given, and re-serves the same
  pair (FR-5.12). "Not Wallpaper Material" and "Ignore This Photo" already
  satisfied FR-5.12 a different way — they stay visible as a toggle in the
  Library tab for as long as they hold, and clicking again there already
  reverses them (FR-4.6).

### Fixed

- The Export tab now says a device can't yet see the "Firnlight" album as a
  standing fact the moment the tab appears, instead of only after a failed
  Sync press (FR-6.11), and clears a stale sync success tally (or error)
  rather than leaving it standing beside that notice if the album later
  drops out of sight (FR-8.12).
- The Export tab now says plainly when it can't show a size control or a
  suggestion because Photos access hasn't been granted yet, instead of
  showing "Suggested: 0" with no explanation (FR-8.13).
- The Library tab's pre-analysis candidate count no longer reads as
  contradicting the Analysis card's own "Wallpaper candidates" count below
  it — the two numbers measure different things, and that difference is
  now said in visible words rather than only a hover tooltip (FR-4.13).
- The album-size suggestion's middle-zone scan no longer caps itself at 500
  candidates when the user has duels but no explicit "Both Are Bad"/"Not
  Wallpaper Material" verdict — a duel choice alone was never such a
  judgment, and the cap was a working shortcut silently narrowing the pool
  the estimate is drawn from (FR-6.4).
- Counts throughout the Library and Export tabs are now locale-grouped and
  agree grammatically with what they count ("1 photo", not "1 photos"),
  including the album-size control's VoiceOver value (FR-8.1).
- The two verdict toggles and the iOS actions menu on every thumbnail now
  meet the HIG's 44x44pt minimum touch target on iPhone and iPad, without
  growing the glass controls themselves (FR-8.1).
- The score badge on thumbnails is now also explained by a visible, named
  menu row (Mac right-click and iOS actions menu alike), not only by a
  VoiceOver label and a pointer-only tooltip (FR-4.13/FR-8.13).
- iPhone and iPad now give each tab its own navigation bar and title,
  matching the HIG's structure for tab-based apps; the Export tab's
  Settings entry moved from the bottom of its scrolling content — where it
  could rest partly under the floating tab bar — into that navigation bar's
  own toolbar (FR-8.1/FR-8.5). Fixed a regression the first version of this
  change introduced: adding each tab's `NavigationStack` cost every tab's
  scrolling content the floating tab bar's own bottom spacing, letting the
  Library tab's Analysis stat rows and the Export tab's "Create Album"
  button render under the bar. Two follow-up attempts (a `GeometryReader`
  that measured the tab bar's height but discarded it, then republishing
  that measurement so each `ScrollView` could re-apply it as its own
  `.safeAreaInset`) both still left short content — including the exact
  album-missing state this bug was filed against — rendering straight
  through the bar; a third attempt constrained each tab's own frame to the
  tab bar's own height *subtracted from* the space a `GeometryReader`
  measured there — but that `GeometryReader` already excludes the bar's
  footprint, so the subtraction removed it twice, clipping the Library
  tab's per-reason `Grid` and the Export tab's "Create Album" button well
  short of the bar instead of merely stopping short of it. The fix that
  survived screenshot verification constrains each tab's frame to that
  measurement as-is, with `.clipped()` added so `NavigationStack` (which
  does not clip a descendant `ScrollView` to a proposed frame on its own)
  actually honors it — nothing inside is ever laid out into the tab bar's
  space, and taller content still scrolls clear of it (light and dark,
  Library and Export).
- The Library tab's scan-status card is now titled "Library Scan" rather
  than "Library" — it used to repeat, word for word, the navigation title
  now shown directly above it on iPhone and iPad (FR-8.10/FR-4.13).
- Fixed a residual FR-8.5 defect the fixes above left behind: at the Library
  tab's maximum reachable scroll, "No Candidates Yet"'s second description
  line stayed permanently under the tab bar — unreachable at any scroll
  offset. Measured cause: the persisted-scroll restore (FR-8.1) is a
  one-shot `ScrollPosition(y:)` applied before the ranked-candidate grid's
  own async load finishes growing the content, and re-issuing that same
  absolute offset once the grid settles clamps to the same short position
  regardless — `ScrollPosition(y:)` against this `ScrollView`'s own
  reported geometry isn't to be trusted at this content size on the 27
  beta. Fixed by falling back to `ScrollPosition(edge: .bottom)` — the
  ScrollView's own idea of its real end — whenever the one-shot restore
  settles short of its target. The Export tab's "Create Album" button had
  the identical, previously unverified defect (no persisted scroll offset
  existed there to seed and confirm it); it now has one (FR-8.1, matching
  the Library tab), which both restores the Export tab's own scroll
  position across launches and let this fix be verified there the same
  way: seeding, relaunching, and screenshotting the fully-visible button,
  clear of the bar, light and dark.
- Fixed two defects in the growth-triggered scroll restore just above.
  First, re-applying the saved target on every content-growth step had no
  guard against the user's own scrolling (FR-8.7): a user who started
  scrolling during a long-running scan — the window during which growth
  events keep arriving — was yanked back to the saved offset by the next
  one. It now stops the instant a `.tracking` scroll phase (the user's own
  finger driving the content) is observed. Second, the `edge: .bottom`
  fallback fired once layout had gone quiet for a fixed window, which is a
  debounce on layout churn, not a load-completion signal — a slow scan or
  an iCloud-backed load can space growth events further apart than that
  window while still mid-load, so the fallback could fire against
  incomplete content and snap to an intermediate "bottom" the user never
  visited, with no way to correct itself afterward. It now also checks the
  page's own "still loading" signal (the Library grid's `GridModel
  .isLoading`, the Export tab's `model.totalAccepted == nil`) and backs off
  to let the next growth step's debounce re-examine rather than finishing
  early. The prior claim that "a target genuinely inside the scrollable
  range is never clamped down" overstated what a layout-quiet debounce can
  actually guarantee; the fix above is what makes that true.
- Fixed two defects this same guard shipped with. First, the Library tab's
  `isLoading` check above was read through `@FocusedValue`, which
  `.focusedSceneValue` only publishes while the Library view is mounted *and*
  the scene holds keyboard focus — not guaranteed during a slow or
  backgrounded scan, letting a nil read fall through as "not loading" and
  finalize the restore against still-growing content, the exact snap this
  guard exists to prevent. The Library tab's `GridModel` is now owned by the
  tab itself and handed down to the grid, so `isLoading` is live state
  present the whole time the tab is showing, focus or no — the same
  always-present shape the Export tab's `model.totalAccepted == nil` check
  already had (the two were not, as first written, the same kind of
  signal). Second, the guard that lets the user's own scroll win over the
  restore (FR-8.7) only cleared on a `.tracking` scroll phase, which covers a
  drag or flick but passes straight through user-driven motion that never
  tracks — a status-bar tap-to-top, or keyboard/VoiceOver-driven scrolling —
  leaving a later growth event free to yank that position back. It now
  clears on `ScrollPhase.isScrolling` (true for `.tracking`, `.interacting`,
  `.decelerating`, and `.animating` alike), confirmed not to cancel the
  restore's own writes, which never move the phase off `.idle`.
- The database contexts the ranking pipeline's background workers use are now
  created by the worker that uses them, not on the main thread that happened
  to construct the worker — ending the repeated "Unbinding from the main
  queue" recovery path the system log showed on every launch, and removing a
  latent threading hazard in how photo records were read and written.
- A library change that turns out to change nothing — the common case, six
  times in one logged session — no longer pays a full re-scoring of every
  ranked photo and a refresh of every view watching the ranking.
- Photo identifiers are no longer written to the system log in the clear when
  an action on a photo fails; they are redacted like the rest of the log's
  dynamic values. Authorization changes now log as readable states rather
  than raw numbers.
- Opening a photo in Photos from the grid no longer risks a crash when the
  first, per-photo route fails and the fallback fires from the system's own
  callback queue (the last main-actor isolation warnings in the build, now
  zero).

- Dragging the album-size slider no longer leaves the exact count beside it
  showing a stale number. Once the number field had keyboard focus — which
  dragging the slider on the Mac is enough to give it — the field stopped
  following the thumb, so the two halves of one setting disagreed about how
  many photos the album would hold. The size is one number again, wherever it
  is shown, and starting a drag now abandons a half-typed count rather than
  holding the field at it.

- Undoing a duel choice (FR-5.12) now actually reaches another device through
  the judgment archive (FR-7.4) — today's only working route for FR-9.1's "a
  judgment made on one device counts on all of them." A duel choice's undo is
  recorded by marking the same row voided in place rather than by appending a
  new one, so an archive exported after an undo carried the same identity
  (winner, loser, timestamp) as the copy a device may have already imported
  before the undo — and a plain duplicate check silently dropped the
  correction instead of applying it. Restoring an archive now updates an
  already-present choice in place when the incoming copy says voided and the
  local one doesn't, so a correction that arrives after the judgment it
  corrects still wins, as FR-5.12 now says explicitly it must.

- A failed duel choice, verdict, or Undo press used to leave the screen
  looking exactly like a success: the pair stayed on screen, the count didn't
  move, nothing said anything went wrong. It's now reported in an alert over
  the pair, on every input route (FR-8.12).

- Undo could be offered right after a choice that was silently never
  recorded — most often because the photo had just stopped being a candidate
  (ignored elsewhere while the pair was on screen). Pressing it then either
  did nothing while still reporting success, or, worse, voided a different,
  legitimate earlier choice for the same pair, because it hunted only by
  winner/loser rather than by the exact choice just made. Recording a choice
  now hands back a receipt naming exactly the row it wrote (or throws,
  honestly, if it wrote nothing), Undo matches that receipt exactly instead
  of guessing, and refreshing the duel pool now withdraws a pending Undo
  whose subject has since stopped being a candidate rather than continuing
  to offer it (FR-5.12, FR-8.12).

- The Mac's Edit-menu Undo/Redo (⌘Z/⇧⌘Z) stopped doing ordinary text-editing
  undo anywhere in the app — including the album-size count field on the
  Export tab — from the moment the Duel tab's own Undo command took over the
  Edit menu's Undo/Redo group application-wide rather than only while the
  Duel tab was actually showing. The system's own Undo/Redo, and the
  standard keyboard shortcuts behind it, are back everywhere except the Duel
  tab, which is the one place ⌘Z is unambiguous (FR-8.1's HIG "place undo
  and redo commands in the Edit menu and support the standard keyboard
  shortcuts" — the Undo and redo guidelines' point being *whatever's being
  edited*, not one screen claimed for the whole app). This was a regression
  in the Undo command added above and went undisclosed here at the time.

- On iPhone and iPad, the grid's touch photo-actions menu disabled "Not
  Wallpaper Material" for an ignored photo with no way for touch to learn
  why — the reason lived only in a `.help()` tooltip, which only a pointer
  ever sees. The menu row's own visible label now says why it's unavailable,
  and carries the same explanation as a VoiceOver hint (FR-8.13).

- Undoing "Both Are Great"/"Both Are Bad" could clear only one photo's
  verdict while claiming to clear both, when the other photo had stopped
  being a candidate in the meantime — the same silently-partial write the
  fix above closed for recording a verdict, still open on the clearing
  path. Clearing a verdict is now all-or-nothing too, so a failed Undo
  reports failure honestly rather than half-correcting and calling it done
  (FR-5.12, FR-8.12).

- A pending Undo offer could be silently withdrawn out from under a duel the
  user had just judged: if a fresh, valid choice or verdict armed a new Undo
  while a duel-pool refresh was mid-flight checking an older, stale one, the
  refresh's cleanup — resuming afterward — cleared whatever was pending *by
  then*, not the stale offer it had actually checked. The refresh now
  re-confirms nothing changed underneath before withdrawing anything
  (FR-5.12).

- A second failure landing while an earlier one's alert was still up used to
  silently replace it — one of the two was never shown. Failures now queue
  and are shown one at a time (FR-8.12).

- That queue's own dismissal defeated it: tapping "OK" popped it twice — once
  from the button and once more from the alert's own teardown — so a queued
  second failure was silently discarded unseen the moment the first was
  acknowledged. The button no longer double-dismisses (FR-8.12).

- A duel-action failure's alert could replay an old, already-resolved
  startup error once a pair appeared, one dismissal at a time, because both
  kinds of failure shared one queue. The two are tracked separately now, and
  a startup/reload problem is retired the moment its retry succeeds or a
  pair actually appears — an alert over a working Duel tab never again shows
  a problem that's already gone (FR-8.13).

- A quick double-click on that alert's "OK" — ordinary behavior, not an edge
  case — could still land on the button before the alert had a chance to
  redraw with a second queued message, discarding it unseen: two clicks
  registered as two dismissals even though the user only ever saw one alert.
  A dismissal in flight now absorbs a second one that arrives before it
  finishes, rather than treating it as a second, distinct alert being
  dismissed (FR-8.12).

- A choice, verdict, or Undo that failed because its photo had just dropped
  out of the pool could have that one-off failure filed as the *reason there
  is currently nothing to compare* — the same event that failed the action
  could also empty the pool, so asking "is a pair on screen right now" at
  that instant picked the wrong report. That message stayed pinned as the
  screen's standing explanation until something unrelated came along to
  clear it, in place of "Nothing to Compare" once the pool actually settled.
  A duel-action failure now always reports as what it is — a one-off,
  dismissible event — never as a persistent explanation for an empty screen
  (FR-8.12, FR-8.13).

- Floating badges and controls over a photo — the favorite heart, the score,
  the verdict toggles, the actions menu, and the Duel tab's ignore control —
  were backed by a hand-built `.background(.regularMaterial)` circle or
  capsule, a stand-in for glass, not glass itself; FR-4.14's own text still
  described the pre-amendment reading of FR-8.5 that excused it. FR-8.5 was
  amended to say explicitly that a control floating over a photo is still
  one of the app's own controls, not part of the photo, and wears the
  platform's real glass wherever it stands; every one of them now uses
  `.glassEffect()`, in both the grid (Library and Export previews share
  `ThumbnailCell`) and the Duel tab, sharing one `GlassEffectContainer` per
  cell/card rather than rendering in isolation — Apple's own guidance treats
  a shared container as correctness where glass surfaces sit close together,
  not just a performance nicety — and FR-4.14 was corrected to match.

  Chasing that fix down surfaced four further defects in the same tab, fixed
  alongside it: the Duel-tab pick buttons, ignore control, and
  touch/right-click "Not Wallpaper Material"/"Ignore This Photo" entries
  stayed clickable while a prior choice, verdict, or Undo was still being
  recorded, silently swallowing the press against `DuelModel`'s own
  `!isRecording` guard — they now disable themselves, like the verdict
  buttons already did (FR-8.12). The failure alert required a pair still be
  on screen before it could present, so a failure that emptied the
  candidate pool in the same stroke that caused it left the message queued
  forever behind "Nothing to Compare" with nothing on screen ever mentioning
  it — it now presents whenever a failure is queued, regardless of what else
  the screen is showing (FR-8.12). The favorite badge, the ignore control,
  and the Library grid's two verdict toggles explained their consequence —
  and how each differs from its neighbor (FR-4.7 vs FR-4.8, "Both Are Bad"
  vs Ignore) — only in a `.help()` tooltip, a route touch and VoiceOver
  users never reach; each now also carries a matching accessibility hint
  (FR-8.13, FR-4.13). And `DuelModel` — the ranker session, the pending
  pair, and the Undo offer — was owned by `DuelView`'s own `@State`, which
  the "Tab" value-based `TabView` genuinely tears down and rebuilds on
  every switch away from the tab (not just a lazy first build), silently
  discarding a standing Undo offer; it's now owned by `ContentView` instead
  — the same fix already applied to the library catch-up pipeline — so the
  offer survives every tab switch, spent only by the next judgment as
  FR-5.12 requires, never by the user's gaze.

  Three more turned up chasing that consequence-explaining fix further: the
  accessibility hint above still left a sighted user without VoiceOver —
  touch or pointer alike — with no on-screen route to the same distinction,
  since `.help()` only reaches a mouse and a control's own name may only
  state its act, never its consequence (FR-8.13). The favorite badge, the
  Duel tab's ignore control, and the Library grid's two verdict toggles now
  also carry that explanation as a visible subtitle line on their matching
  entry in the touch/right-click menu — reachable as that entry's own named
  command, on every platform (FR-8.13, FR-4.13). Separately, the Duel tab's
  "Nothing to Compare" empty state showed even with Photos access never
  granted — a claim that "Firnlight is still working through your library"
  when nothing was or ever would be, since `DuelModel` never consulted
  authorization at all; it now states that precondition as a standing fact
  before attempting anything, pointing to the Library tab where granting
  actually lives (FR-8.13, FR-6.11's pattern, FR-8.10). And the verdict
  row's four buttons ("Both Are Great"/"Both Are Bad"/"Skip"/Undo) carried no
  explicit button style, which resolved to the standard bordered push button
  on the Mac but to bare tinted text with no border on iPhone/iPad — nothing
  marked them as tappable on the screen's persistent, always-visible action
  row. They're `.bordered` now on every platform (matching macOS's existing
  look exactly), with none `.borderedProminent` — the two duel cards above
  stay this screen's one prominent action (FR-8.1, FR-8.5).

## [0.19.4] - 2026-08-14

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

- One extreme verdict no longer decides the whole album suggestion. What a
  photo has to score to count as "like" the great- or bad-judged photos is
  now measured against the bulk of those judgments, not the single most
  extreme one — a lone "Both Are Bad" on a photo the ranking happened to love
  used to collapse the suggestion to almost nothing, and a lone generous
  "Both Are Great" could stretch it to almost everything. Every judgment now
  shifts the estimate a little; none can overrule all the others.
- The suggested album size (FR-6.4) now actually reflects "Both Are Great" and
  "Not Wallpaper Material"/"Both Are Bad" verdicts as soon as either exists,
  instead of requiring two bad verdicts before either kind had any effect.
  Photos scoring like an explicit bad verdict are now always excluded, photos
  scoring like an explicit great verdict are now always included with no
  upper bound, and only the doubtful stretch between the two is left to the
  shape of the ranking — the same rule whichever kind of verdict exists, or
  both, or neither. The estimate itself is no longer floored at 20 or rounded
  to the nearest ten: a small or zero suggestion is now reported as it comes
  out, with the album-size slider still never dropping below its own working
  minimum and labeling that mark "Minimum" rather than "Suggested" when the
  true estimate falls below it (FR-6.3).
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
