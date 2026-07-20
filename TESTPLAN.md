# Alpenglow — Manual Test Plan (build 2026-07-20)

Covers the changes of this session's build: raw-score ranking (ranker v4),
display-crop analysis (analysis v2), Ignore vs Not Wallpaper Material,
cityscape admission, startup auto-resync, typed album count, lazy tabs,
album-sync hardening, and accessibility labels. Each item names the FR(s) it
verifies (see REQUIREMENTS.md). The app has no automated test target — Photos
authorization is interactive and thresholds are tuned by hand — so this is a
manual plan. Run on macOS 27 against a real Photos library.

**Legend**: each test lists Setup → Steps → Expected. Run sections in order;
later sections assume the migrations of section 1 have completed.

**Isolation notes** (verified against the code):
- Section 4's ignores and bad verdicts persist and legitimately change
  Section 6's pool, album counts, and suggestion (two or more bad verdicts
  switch the suggestion from the knee heuristic to verdict calibration).
  Either accept that Section 6 reflects Section 4's state, or reset the data
  store between sections.
- Section 5 leaves edited photos un-analyzed; run "Resume" to completion
  after Section 5, before Section 6, or those photos are missing from the
  grid and preview.

---

## 1. Migration & first launch after update

Existing install with pre-session data (analyzed library, duel history,
weights file).

- **T1.1 Analysis v2 re-run (FR-3.3, FR-7.1)** — Launch the app. Expected:
  the Library tab's analysis card shows the whole library pending again
  (analysis version bump) and the startup auto-resync begins working through
  it with live progress. Quit mid-run, relaunch: it resumes where it stopped,
  no photos lost or duplicated.
- **T1.2 Ranker v4 rebuild (FR-5.3)** — After analysis completes, open the
  Duel tab. Expected: no error; the ranking is rebuilt from favorites +
  full choice history automatically (weights file mismatch triggers rebuild).
  Check the log (`log stream --predicate 'subsystem == "space.remco.Alpenglow"'`)
  for the "Rebuilt weights … replayed N choices" line, N = your choice count.
  The line is emitted when the startup analysis completes or on first
  Duel-tab open, whichever happens first.
- **T1.3 Rebuild determinism (FR-5.3)** — Quit. Delete
  `~/Library/Application Support/Alpenglow/ranker-weights.json`. Relaunch,
  let the ranker rebuild, note the top 10 grid photos. Repeat delete +
  relaunch. Expected: identical top 10 in identical order both times.

## 2. Startup auto-resync (FR-2.7)

- **T2.1 Runs by itself** — With access granted, launch the app and touch
  nothing. Expected: scan runs (progress visible), then analysis runs to
  completion, then the grid populates/refreshes — zero clicks.
- **T2.2 Once per session** — After T2.1 finishes, switch tabs back and
  forth. Expected: no second automatic scan starts.
- **T2.3 No fight with manual controls (FR-3.5)** — Launch, and while
  auto-analysis is running press the manual button area. Expected: buttons
  reflect the running state (Stop visible); no double run, no crash.
- **T2.4 First grant (FR-1.1, FR-1.3)** — Fresh install (or reset Photos
  permission via System Settings): launch. Expected: NO permission prompt at
  launch; the Library tab shows the grant button. Grant → auto-resync starts
  right after authorization lands, without relaunch.

## 3. Ranking correctness (FR-4.1, FR-4.5, FR-5.2)

- **T3.1 No mid-ranking strangers** — After a session of duels, add a few
  new photos to Photos (AirDrop or import), stay OFF the Duel tab, and rescan
  + analyze from the Library tab. Expected: the new photos appear in the grid
  ranked by their looks (not stuck at the very bottom, not suspiciously in
  the top ranks either) — analysis completion rescores them into the learned
  ranking automatically.
- **T3.2 Live re-rank (FR-4.5)** — Keep Library visible (second window not
  needed; switch after each duel), do 5 duels. Expected: grid order visibly
  updates after choices; the score badges change; no beachball between duels.
- **T3.3 Duel responsiveness (regression check)** — On a large library, click
  through 10 duels quickly. Expected: each next pair appears promptly; no
  growing lag (the per-choice double-rescore was removed this build).
- **T3.4 Score badges (FR-4.4)** — Grid cells show a 0–1 score; favorites
  show the heart badge.
- **T3.5 Near-duplicate collapse (FR-4.2, FR-4.3)** — Ensure two
  near-identical shots of one scene exist (re-takes). Expected: only one
  shows in the grid, and the header's "near-duplicates hidden" count is
  ≥ 1. If one of the pair is a favorite, the favorite is the one shown; with
  equal favorite status, the visibly straighter one is shown.

## 4. Ignore vs Not Wallpaper Material (FR-4.6–4.9, FR-5.9)

- **T4.1 Context menu everywhere (FR-4.6)** — Right-click a photo in the
  Library grid, the Export preview, and a duel card. Expected: all three
  menus offer Open in Photos / Not Wallpaper Material / Ignore This Photo
  (Export preview and grid share the cell; duel has its own).
- **T4.2 Ignore removes everywhere (FR-4.8)** — Ignore a recognizable photo
  from the grid. Expected: it leaves the grid immediately; it never appears
  in subsequent duels (do ~10); after Sync it is removed from the album.
- **T4.3 Ignore mid-duel (FR-5.9)** — In a duel, click the eye-slash button
  on one card. Expected: a fresh pair appears (the very next pair may
  momentarily still include the photo before the pool reloads); once
  reloaded it is gone from all subsequent duels this session (no relaunch).
- **T4.4 Not Wallpaper Material keeps the photo (FR-4.7)** — Mark a photo
  NWM from the grid. Expected: it stays in the grid at its rank and remains
  duel-eligible; the Export tab's suggestion recomputes to reflect the new
  bad verdict (note: the second-ever bad verdict switches the suggestion
  from the curve heuristic to verdict calibration, which can move the number
  in either direction — that jump is expected).
- **T4.5 NWM mid-duel advances (FR-4.7)** — Use NWM from a duel card's
  context menu. Expected: fresh pair; the marked photo may legitimately
  reappear in later duels.
- **T4.6 Review & un-ignore (FR-4.9)** — Toggle "Show Ignored". Expected:
  only ignored photos, each badged with the eye-slash; right-click offers
  Un-ignore; un-ignoring returns the photo to the normal grid (toggle back)
  and to duel eligibility.

## 5. Analysis rules (FR-3.1, FR-5.1)

- **T5.1 Cityscapes admitted** — Ensure the library has a people-free
  cityscape/landmark shot (skyline, bridge, castle, lighthouse). Expected:
  after this build's re-analysis it is accepted into the grid.
- **T5.2 Crowds still rejected** — A street scene full of people stays
  rejected (People bucket in the analysis breakdown).
- **T5.3 Distant-figure tolerance** — A landscape with a tiny distant hiker
  is now accepted (was rejected before this build).
- **T5.4 Portraits still rejected** — Any photo with a prominent person
  remains in the People bucket.
- **T5.4b iCloud deferral honesty (FR-3.4)** — Ensure at least one original
  is iCloud-only (enable "Optimize Mac Storage", or remove a local copy).
  Run analysis. Expected: the photo lands in the "iCloud (deferred)" count
  during the local pass; progress never reads "Analysis complete" while it
  is deferred; the retry pass (automatic in the same run, or via "Retry N
  iCloud Photos") downloads and analyzes it and the deferred count reaches 0.
- **T5.5 Wallpaper-crop learning (FR-5.1)** — Pick a wide panorama. In a
  duel it renders center-cropped to your screen's shape. After re-analysis,
  its ranking should track what that crop looks like, not the full pano
  (spot-check: a pano whose center slice is boring should sink despite a
  spectacular full frame).
- **T5.6 Edited photo (FR-2.5, FR-2.6)** — Crop a candidate in Photos (keep
  it landscape and wider than 3264 px). Rescan, then click "Resume" so the
  queued photo actually re-analyzes (a scan only queues it; mid-session
  nothing runs analysis automatically). Expected: only that photo re-runs;
  it drops out of the grid until re-analyzed, then returns at a rank
  reflecting the edit (not its old rank). Crop another below 3264 px wide
  (e.g. 2500 px) or to portrait: it drops out entirely.
- **T5.7 Favorite refresh (FR-2.3)** — Toggle a favorite in Photos, rescan,
  then click Refresh on the grid (or let the triggered re-analysis finish —
  a plain scan alone doesn't reload the grid). Expected: heart badge
  updates; the photo briefly loses its rank until rescored. Known cost: that
  one photo re-analyzes (modification-date side effect) — only that photo.

## 6. Export tab (FR-6.x)

- **T6.1 Typed count (FR-6.3)** — Type 37 in the count field, press Return.
  Expected: preview shows exactly 37 (or fewer if fewer exist); typing 0 or
  a huge number clamps to 1…accepted; stepper still steps by 10.
- **T6.2 Loading honesty (FR-6.5)** — Switch to Export immediately after
  launch. Expected: the tab appears instantly; the count controls are
  disabled (showing the default 50) with a loading indicator, and no preview
  renders until the real pool arrives.
- **T6.3 Suggestion behavior (FR-6.4)** — Note the suggested count; change
  the count manually; do more duels with Both Are Bad verdicts. Expected:
  suggestion updates but never overrides your manual value; "Use" adopts it.
- **T6.4 Sync & report (FR-6.1)** — Sync. Expected: Photos album matches the
  preview exactly, in the same order (FR-6.6 check runs automatically — see
  the log for "Album order verified"); the +added/−removed report is right.
- **T6.4b Sync-failure rollback (FR-6.8) — knowingly unverified.** The
  restore-previous-membership path needs a PhotoKit failure between the
  remove and re-add transactions, which cannot be arranged reliably by hand.
  Covered by code review only; if a sync ever errors in the field, verify
  the album is NOT empty afterwards.
- **T6.5 Rename survival (FR-6.9)** — Rename the album in Photos to
  "Wallpapers". Sync again. Expected: the SAME (renamed) album is updated —
  no new "Alpenglow" album appears.
- **T6.6 Tab switching (FR-4.11)** — From Library mid-analysis, click Duel,
  Export, Library in quick succession. Expected: every switch is instant;
  content fills in behind placeholders.

## 7. Access states (FR-1.2)

- **T7.1 Limited access** — Set Alpenglow to "Selected Photos" in System
  Settings. Expected: Library tab shows the orange limited-access banner
  with a working "Open Photos Settings" button; pipeline still runs on the
  selection.
- **T7.2 Revocation (FR-1.3)** — Revoke access while the app runs. Expected:
  macOS (TCC) normally terminates the app on revocation — that is a pass; if
  the process survives, returning to it shows the grant/settings prompt. On
  the next launch the prompt appears either way.

## 8. Accessibility (VoiceOver)

- **T8.1 Duel with VoiceOver** — Enable VoiceOver (⌘F5). Navigate the Duel
  tab. Expected: cards announce "Left photo"/"Right photo" (+ ", favorite"),
  the ignore buttons announce "Ignore Left/Right photo", and a duel can be
  completed by keyboard/VO alone.
- **T8.2 Grid cells** — Each cell announces one element: score + favorite
  (or "Ignored photo" in the ignored filter) — not a jumble of sub-elements.

## 9. Durability sweep (FR-7.x)

- **T9.1 Kill mid-anything** — Force-quit during scan, during analysis, and
  right after a duel choice. Relaunch each time. Expected: at most one batch
  of progress lost; choices/verdicts/ignores all persisted; auto-resync picks
  up the remainder.
- **T9.2 Rebuild identity (FR-7.3)** — Build & run from Xcode again.
  Expected: no Photos re-grant prompt (signing stable), taste intact.
