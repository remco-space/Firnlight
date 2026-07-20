# Alpenglow — Product Brief

A native macOS app that curates desktop wallpapers from the user's own Photos
library: it finds high-resolution nature photos without people, learns the
user's personal taste from quick pairwise comparisons, and maintains a Photos
album that System Settings can rotate as wallpaper.

This document is the product brief: WHAT the user experiences and WHY, in
human-readable language. Product and UX design must always be verifiable
against it. It deliberately contains no APIs, algorithms, or thresholds — the
technical documentation is the code itself (see CLAUDE.md for the contract).

The app has three tabs matching the three stages of the journey:
**Library** (find & rank) → **Duel** (learn taste) → **Export** (the album).

---

## 1. Photos access & privacy

- **FR-1.1** The app asks for Photos access only when the user takes an
  explicit action, never silently at launch. *(Why: no surprise permission
  prompts.)*
- **FR-1.2** The Library tab reflects the current access state (not yet asked /
  granted / limited / denied / restricted) and offers the right next step for
  each: a grant button, or a shortcut into Privacy Settings.
- **FR-1.3** A grant made in System Settings while the app is open takes
  effect when the user returns to the app — no relaunch needed.
- **FR-1.4** The app only ever adds or removes photos in its own wallpaper
  album; it never edits or deletes the user's actual photos. *(Why: trust —
  the library is safe. Revision of the original "never write to the library"
  rule, approved by the user for the album-based export, 2026-07-19.)*
- **FR-1.5** Everything happens on the user's Mac; photo content never leaves
  the device. *(Why: privacy is a headline feature of the product.)*
- **FR-1.6** Launching the app twice just brings the already-running window
  forward instead of opening a second one. *(Why: protects the user's data.)*

## 2. Finding candidate photos (Library tab)

- **FR-2.1** The app looks for photos that could plausibly work as wallpaper:
  wide (landscape) orientation, high enough resolution for a modern display,
  and not screenshots. Older, smaller photos are not hard-excluded — they are
  admitted and simply ranked lower if the user's choices show they matter.
  *(Why: photos from older cameras are rarer and shouldn't be thrown away
  outright.)*
- **FR-2.2** Re-scanning is always safe to repeat: it only adds genuinely new
  photos, never duplicates.
- **FR-2.3** Re-scans refresh what can change in Photos — in particular the
  favorite heart.
- **FR-2.4** Scanning shows live progress and ends with a clear summary: how
  many candidates there are and what changed (new / re-queued / removed).
- **FR-2.5** If the user edits a photo (crop, adjustments) after it was
  examined, only that photo is re-examined — never the whole library.
  *(Why: fast, and respects the user's edits.)*
- **FR-2.6** Photos deleted from the library, or edited until they no longer
  qualify (e.g. cropped too small), drop out of the app automatically.

## 3. Analysis (Library tab)

- **FR-3.1** The app examines each candidate on-device to keep only nature
  photos without people or city scapes without a lot of people; screenshots and utility images are set aside too.
- **FR-3.2** After analysis, the user sees a breakdown of why photos were set
  aside: contains people, utility image, not nature, or waiting on iCloud.
- **FR-3.3** Analysis can be interrupted at any time; quitting mid-run loses
  almost no progress, and the next launch picks up where it left off.
- **FR-3.4** Photos stored only in iCloud are deferred, not skipped: the app
  finishes everything local first, then comes back to download and examine the
  rest. Progress honestly distinguishes "waiting on iCloud" from "done" — the
  app never claims completion while deferred work remains.
- **FR-3.5** The Library tab always offers the one obvious next action as the
  pipeline progresses ("Analyze N Photos", "Resume", "Retry N iCloud Photos",
  and finally "Analysis complete").

## 4. The ranked grid (Library tab)

- **FR-4.1** Accepted photos appear as a thumbnail grid, best first, scrolling
  smoothly even with many hundreds of items.
- **FR-4.2** Near-duplicate shots of the same scene are collapsed so the grid
  isn't cluttered with the same view repeated. *(Why: re-takes of one vista
  should compete as one wallpaper, not crowd out variety.)*
- **FR-4.3** When duplicates are collapsed, the app keeps the best of the
  bunch — preferring a Photos favorite, then the one with the visibly
  straighter horizon.
- **FR-4.4** Favorites show a heart badge, and every thumbnail shows its
  current score.
- **FR-4.5** The grid re-orders itself live as the app learns the user's taste
  from duels.
- **FR-4.6** Right-clicking any photo anywhere in the app (grid, export
  preview, duel) offers "Open in Photos" and "Not Wallpaper Material".
- **FR-4.7** "Not Wallpaper Material" permanently removes a photo from the
  grid, future duels, the album-size suggestion, and (on next sync) the album.
  Using it mid-duel advances to a fresh pair.
- **FR-4.8** Every thumbnail is a clean, fixed-shape tile with the photo
  filling it; clicks and right-clicks land only on the visible tile — a wide
  panorama must not spill over or steal clicks from neighboring cells.

## 5. Learning taste (Duel tab)

- **FR-5.1** The user is shown two photos — "Which makes the better
  wallpaper?" — and clicks the winner. Both are cropped to the shape of the
  user's screen, so the choice judges what the wallpaper would actually look
  like.
- **FR-5.2** Ranking is learned entirely from the user's choices. Nothing is
  hard-coded: a low-resolution or tilted photo is penalized only as much as
  the user's own decisions imply.
- **FR-5.3** Every choice is remembered permanently, and the accumulated
  choices are always enough to rebuild the ranking from scratch — the user's
  invested judgment is never lost.
- **FR-5.4** Ranking starts from the user's existing Photos favorites, so
  recommendations feel personal from the very first duel. *(Why: no cold
  start.)*
- **FR-5.5** The app picks pairs it is most unsure about, avoids re-asking
  decided pairs, avoids near-identical pairs, and randomizes sides. *(Why:
  every click should teach the app as much as possible, without position
  bias.)*
- **FR-5.6** Duels deliberately probe a wider set than the album will hold, so
  the app also learns where the quality cutoff belongs — narrowing over time
  as that cutoff firms up.
- **FR-5.7** Besides picking a winner, the user can say "Both Are Great",
  "Both Are Bad", or Skip. Great/Bad record absolute quality (used to size the
  album, not to rank); Skip just moves on.
- **FR-5.8** The Duel tab shows how many choices the user has made, and a
  friendly empty state when there aren't yet two candidates to compare.

## 6. The wallpaper album (Export tab)

- **FR-6.1** The app maintains a Photos album named "Alpenglow" holding
  exactly the user's top-ranked, de-duplicated photos. Each sync reports the
  total plus how many were added and removed.
- **FR-6.2** The album is ordered for visual variety, so that on "rotate in
  order" consecutive wallpapers look as different as possible. *(Why: avoid
  samey streaks of the same scene or mood.)*
- **FR-6.3** The user picks how many photos go in the album, with **no upper
  limit** — if the whole library is awesome, the whole library can be the
  album.
- **FR-6.4** The app suggests a count — where quality drops off in the user's
  own ranking, informed by their Great/Bad verdicts. The suggestion is
  displayed, adopted automatically only the first time, and never overrides a
  manual adjustment.
- **FR-6.5** Before syncing, the Export tab previews exactly the photos a sync
  would put in the album, in the album's actual order, in the same grid style
  as the Library tab.
- **FR-6.6** After every sync, the app verifies the album really ended up in
  the requested order.
- **FR-6.7** The Export tab explains how to point System Settings → Wallpaper
  at the album for automatic rotation. *(Why: the hand-off to the OS is the
  product's finish line; the user should never have to guess it.)*

## 7. Durability

- **FR-7.1** All of the user's invested effort — scan results, analysis,
  choices, verdicts, exclusions — survives quitting, relaunching, and app
  updates. Long-running work always resumes where it stopped.
- **FR-7.2** The user's choice and verdict history is never pruned.
- **FR-7.3** Rebuilding or upgrading the app never requires the user to
  re-grant Photos access or re-train their taste from scratch.

## Deferred ideas (explicitly parked)

- Auto-leveling the horizon if the app ever sets wallpapers directly rather
  than via the album.
- Using "both great/bad" verdicts as ranking training signal (currently they
  only calibrate the album size).
