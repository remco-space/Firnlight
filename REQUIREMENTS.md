# Alpenglow — Functional Requirements

A native macOS app that curates desktop wallpapers from the user's own Photos
library: it finds high-resolution nature photos without people, ranks them by
learned personal preference, and maintains a Photos album that System Settings
can use for rotating wallpaper. Everything runs on-device.

Target: macOS 27+, Apple Silicon. Swift 6 (strict concurrency), SwiftUI,
PhotoKit, Vision (modern async struct API), SwiftData, Accelerate. No
third-party dependencies, no network calls, no telemetry.

---

## 1. Photos access & privacy

- **FR-1.1** The app requests Photos authorization (`.readWrite` level) on
  explicit user action, never automatically at launch.
- **FR-1.2** The Library tab reflects the authorization state (not determined /
  authorized / limited / denied / restricted) and offers the grant flow or a
  shortcut to Privacy Settings as appropriate.
- **FR-1.3** Authorization status is re-checked whenever the app becomes
  active, so a grant made in System Settings applies without relaunch.
- **FR-1.4** Library writes are strictly limited to wallpaper-album creation
  and album membership. Assets are never modified or deleted.
  *(Revision of the original "never write to the library" rule — approved by
  the user for the album-based export, 2026-07-19.)*
- **FR-1.5** All processing happens on-device; photo content never leaves the
  Mac.
- **FR-1.6** Only one app instance runs at a time: a second launch defers to
  (and activates) the existing instance, protecting the data store.

## 2. Library scan (metadata pre-filter)

- **FR-2.1** The scan enumerates image assets only and pre-filters on metadata
  before any pixel data is requested: landscape orientation
  (width > height), width ≥ 3264 px (admits iPhone 5s-era 8 MP photos — older
  photos are rarer and should not be hard-excluded), not a screenshot.
- **FR-2.2** Each candidate is persisted once, keyed by the PhotoKit asset
  identifier; re-scans are idempotent (only new assets are added).
- **FR-2.3** Re-scans refresh mutable metadata on existing records —
  specifically the Photos favorite flag.
- **FR-2.4** The scan shows live progress and finishes with a candidate count
  plus what changed (new / edited-queued / removed).
- **FR-2.5** Photos edited since their analysis (detected via the asset's
  modification date) are queued for re-analysis by the same resumable
  pipeline — only the edited photos re-run Vision, never the whole library.
- **FR-2.6** Records are removed when their asset is deleted from the library
  or edited out of candidacy (e.g. cropped below the minimum size).

## 3. Vision analysis

- **FR-3.1** Analysis bitmaps are requested at ≤1024 px long edge; full-res
  images are never analyzed.
- **FR-3.2** Rejection order, cheapest first: utility images (screenshots-like
  content per aesthetics analysis) → photos with people (any detected face, or
  human rectangle with confidence ≥ 0.3) → photos that aren't nature.
- **FR-3.3** "Nature" = any Vision classification label from a curated
  allowlist at confidence ≥ 0.4. The allowlist contains only identifiers
  verified to exist in the Vision taxonomy (101 entries; note that intuitive
  labels like "sunset", "cloud", "sea" do not exist — the actual identifiers
  are "sunset_sunrise", "cloudy", "ocean", …).
- **FR-3.4** Accepted photos additionally get: an aesthetics score, a feature
  print (embedding), and a horizon angle (nil when no horizon is visible —
  treated as neutral, never penalized).
- **FR-3.5** Analysis runs in batches of 32 with bounded concurrency, saving
  after each batch; killing the app mid-run loses at most one batch and the
  run resumes on relaunch.
- **FR-3.6** iCloud-only originals are deferred, not skipped: the local pass
  completes first, then deferred photos are retried with network downloads
  allowed. Progress reporting distinguishes the phases and never claims
  completion while deferred work remains.
- **FR-3.7** Per-reason rejection counts (people / utility / not nature /
  deferred) are displayed.
- **FR-3.8** Analysis is versioned; bumping the version re-runs the pipeline
  incrementally. One-time backfill passes (e.g. horizon measurement for
  records analyzed before that feature existed) never appear for fresh
  installs.

## 4. Candidate grid (Library tab)

- **FR-4.1** Accepted candidates are shown in a lazily-loading thumbnail grid,
  ranked best-first, and must scroll smoothly at 500+ items.
- **FR-4.2** Near-duplicate suppression: walking the ranked list, a candidate
  is hidden when its feature-print distance to an already-shown photo is below
  threshold (tuned to 0.5 on real library data after 0.35 let same-subject
  re-takes through).
- **FR-4.3** Within a near-duplicate cluster, the kept representative is
  chosen by: Photos favorite first, then the more level horizon (≥0.5°
  improvement required).
- **FR-4.4** Favorites are marked (heart badge); each cell shows its current
  score.
- **FR-4.5** The grid re-ranks live as the preference ranker learns.
- **FR-4.6** Right-clicking any image in the app (grid, export preview, duel)
  shows a standard context menu with "Open in Photos" (deep link to the asset)
  and "Not Wallpaper Material".
- **FR-4.7** "Not Wallpaper Material" permanently excludes the photo from the
  grid, future duels, the album-size calibration, and (on next sync) the
  album. Excluding a photo mid-duel advances to a fresh pair.
- **FR-4.8** Every image tile renders at a fixed aspect ratio with the photo
  center-crop-filled, and its click/right-click area matches the visible tile
  exactly — panoramas must not draw over or steal clicks from neighboring
  cells or gaps.

## 5. Preference learning (Duel tab)

- **FR-5.1** The user compares photo pairs ("Which makes the better
  wallpaper?") and clicks the winner. Images are center-cropped to the main
  display's aspect ratio, so choices judge the actual wallpaper crop.
- **FR-5.2** Ranking model: online logistic (Bradley–Terry) over Vision
  feature prints — P(A beats B) = sigmoid(sᴀ − s_B) with
  s = w·featurePrint + b₁·aesthetics + b₂·levelness + b₃·resolution. One SGD
  step per choice. Levelness derives from the horizon angle (level or no
  horizon = 1, ≥45° tilt = 0); resolution is log-scaled from the minimum
  candidate width (0) to 6000 px (1). Both weights are learned from duels, not
  hard-coded — low-resolution photos are penalized only as much as the user's
  choices imply.
- **FR-5.3** Every choice is stored permanently. Weights persist to a file;
  a missing/invalid file — including any algorithm-version mismatch — triggers
  an automatic rebuild: seed from favorites, replay all choices, re-rank.
- **FR-5.4** Fresh weights are seeded from Photos favorites (pseudo-choices:
  favorite beats random non-favorite), so ranking starts from the user's
  existing taste.
- **FR-5.5** Pair selection is uncertainty sampling: closest-scored pairs from
  an adaptive pool, excluding near-duplicate pairs and already-judged pairs;
  sides are shuffled against position bias.
- **FR-5.6** The duel pool is always wider than the export set: top 75% of all
  candidates until the quality bar is calibrated, then everything above
  (bar − margin) with a floor of 200 — narrowing over time as the bar firms up.
- **FR-5.7** "Both Are Great" / "Both Are Bad" buttons record absolute quality
  verdicts on both photos (they do not train the pairwise weights) and advance
  to the next pair. A plain Skip is also available.

## 6. Export (wallpaper album)

- **FR-6.1** Export maintains a Photos album ("Alpenglow") whose membership is
  exactly the top-N ranked, deduplicated candidates. Syncing adds newcomers
  and removes photos that dropped out; results are reported as
  total (+added, −removed).
- **FR-6.2** Album order maximizes visual variety: greedy max-min feature-print
  separation against the last 5 placed photos, so consecutive wallpapers look
  as different as possible (relevant for "rotate in order").
- **FR-6.3** N is user-adjustable with **no hardcoded maximum** — the ceiling
  is the library itself ("it may be that all the pictures are awesome").
- **FR-6.4** The app suggests N automatically:
  - Primary: verdict calibration — the score threshold that best separates
    "both great" from "both bad" verdicts (valued at current scores, so the
    bar moves as the ranker learns); N = deduplicated candidates above the
    bar, uncapped.
  - Fallback (fewer than 2 bad verdicts): the knee of the ranked score curve
    (Kneedle: max deviation from the endpoint chord).
  - The suggestion is displayed, auto-adopted only initially, and never
    overrides a manual stepper change.
- **FR-6.5** The Export tab previews exactly the photos a sync would put in
  the album, in the same grid style as the Library tab and in the album's
  actual (diversity) order.
- **FR-6.6** After every sync, the app reads the album back and verifies the
  resulting sequence matches the requested order, logging the result.

## 7. Persistence & operational requirements

- **FR-7.1** SwiftData store keyed by asset identifier: photo records
  (metadata, analysis results, feature print, cached preference score),
  choice records, and verdict records. Choices and verdicts are never pruned —
  they are sufficient to rebuild the ranker from scratch.
- **FR-7.2** Every stage (scan, analysis, horizon backfill, iCloud retry) is
  resumable across app restarts.
- **FR-7.3** All tunable constants live in one file (`Thresholds.swift`), each
  with a one-line rationale; several were tuned against the real library
  (dedupe distance, suggestion caps removed, allowlist contents).
- **FR-7.4** Signing uses a stable development identity so Photos permission
  survives rebuilds (TCC binds grants to the code signature).

## Deferred ideas (explicitly parked)

- Auto-leveling the horizon (via the observation's transform) if the app ever
  sets wallpapers directly rather than via the album.
- Using "both great/bad" verdicts as ranker training signal (currently they
  only calibrate the album size).
