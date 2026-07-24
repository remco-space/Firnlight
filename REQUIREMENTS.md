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
  each: a grant button, or a shortcut into Privacy Settings. When access is
  limited to a selection of photos, the tab says so plainly and offers a
  shortcut to change the selection in Photos settings.
- **FR-1.3** A grant made in System Settings while the app is open takes
  effect when the user returns to the app — no relaunch needed.
- **FR-1.4** The app only ever adds or removes photos in its own wallpaper
  album; it never edits or deletes the user's actual photos. *(Why: trust —
  the library is safe. Revision of the original "never write to the library"
  rule, approved by the user for the album-based export, 2026-07-19.)*
- **FR-1.5** Everything happens on the user's Mac and photo content never
  leaves it for third-party servers. *(Why: privacy is a headline feature of
  the product.)* The one sanctioned exception is Apple's Private Cloud Compute
  — which extends the device's privacy guarantees to Apple silicon servers and
  retains no data — permitted where a task needs a higher-level foundation
  model than can run locally.
- **FR-1.6** Launching the app twice just brings the already-running window
  forward instead of opening a second one. *(Why: protects the user's data.)*
- **FR-1.7** Alpenglow is a single-window app, so closing its window quits it —
  the standard behavior for a single-window utility (as with System Settings),
  not an override of the platform. Quitting is also always available the usual
  way, through the app's Quit command (⌘Q, see FR-8.3). *(Why: for a
  single-window utility a windowless, still-running state is a confusing no-op
  with nothing for the user to do.)* The one exception: if a process such as an
  album sync is in progress, the quit waits for it to finish (or safely roll
  back) first, so closing the window mid-sync can never leave application state
  or the photos album half-written (see FR-6.8).

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
- **FR-2.7** When Photos access is already granted, launching the app
  automatically re-syncs: scanning and analysis run to completion in the
  background, with the same live progress the manual buttons show, without the
  user clicking anything. Manual re-scan and retry controls remain available
  at any time. *(Why: the library stays current without the user having to
  remember to click Scan.)*

## 3. Analysis (Library tab)

- **FR-3.1** The app examines each candidate on-device to keep only nature
  photos without people, or cityscapes without a lot of people; screenshots and
  utility images are set aside too.
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
  preview, duel) offers three actions: "Open in Photos", "Not Wallpaper
  Material", and "Ignore This Photo". These same three actions are also
  available as named commands in the menu bar, acting on the focused photo (see
  FR-8.3), so right-click is a convenient accelerator — never the only way to
  reach them.
- **FR-4.7** "Not Wallpaper Material" records that the human judges this a bad
  wallpaper on its face — the same absolute bad-quality verdict as "Both Are
  Bad" in a duel. It does **not** remove the photo: it stays in the grid,
  future duels, and the album-size suggestion. But it also teaches the ranking
  — the same way losing a duel does — that this photo, and others like it, are
  less desirable as wallpaper, pushing them down over time (and so out of the
  album's top-ranked selection). Using it mid-duel advances to a fresh pair.
- **FR-4.8** "Ignore This Photo" fully removes a photo from the grid, future
  duels, the album-size suggestion, and (on next sync) the album. *(Why: some
  photos are a genuinely good shot but personally unwanted as a wallpaper —
  e.g. emotionally triggering — and should disappear entirely rather than
  merely be marked poor quality.)* Using it mid-duel advances to a fresh pair.
- **FR-4.9** The Library tab has a "Show Ignored" filter to review ignored
  photos and un-ignore any of them, returning them to the normal grid, duels,
  and album sizing.
- **FR-4.10** Every thumbnail is a clean, fixed-shape tile with the photo
  filling it; clicks and right-clicks land only on the visible tile — a wide
  panorama must not spill over or steal clicks from neighboring cells.
- **FR-4.11** Switching tabs is instant: each tab's content loads lazily in
  the background behind a progress placeholder, so no tab — especially
  Export — blocks the rest of the app while it loads.
- **FR-4.12** A photo that comes from the user's shared library shows a small
  "shared library" badge on its thumbnail. *(Why: helps the user tell at a
  glance whether they took a photo themselves or it came from someone else in
  the shared library.)* **Known unimplementable as of macOS 27 beta 4:** the
  system exposes no supported way for an app to tell whether a photo belongs to
  the iCloud Shared Photo Library (the legacy Shared Albums signal is a
  different feature and would mislabel photos). Kept as a requirement to
  revisit when the OS provides this.
- **FR-4.13** Every status-indicator icon and icon-only control is
  self-describing without relying on hover. It always carries an accessibility
  label so VoiceOver and assistive tech announce it; anything essential the user
  needs to understand or act on is also conveyed in visible words nearby (as
  FR-1.2 and FR-3.2 already do for access state and set-aside reasons) or
  reachable as a named menu command (FR-8.3); and a pointer tooltip is layered
  on top as a convenience for mouse users. *(Why: an icon alone is ambiguous.
  Hover text explains it for pointer users but is invisible to keyboard,
  VoiceOver, and touch — so it can enrich meaning but must never be the only
  carrier of it. Merely-nice-to-know badges like the favorite heart or score can
  still lean on the label + tooltip, keeping the interface free of permanent
  clutter.)*

## 5. Learning taste (Duel tab)

- **FR-5.1** The user is shown two photos — "Which makes the better
  wallpaper?" — and clicks the winner. Both are cropped to the shape of the
  user's screen, so the choice judges what the wallpaper would actually look
  like. The learned ranking judges that same screen-shaped crop, not the whole
  photo, so what the app learns always matches what the user actually judged
  — important for panoramas, where the crop can look very different from the
  full photo.
- **FR-5.2** Ranking is learned entirely from the user's choices. Nothing is
  hard-coded: a low-resolution or tilted photo is penalized only as much as
  the user's own decisions imply.
- **FR-5.3** Every choice and verdict is remembered permanently, and the
  accumulated judgments are always enough to rebuild the ranking from scratch —
  the user's invested judgment is never lost.
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
  "Both Are Bad", or Skip. Both record absolute quality that helps size the
  album. A "Both Are Bad" verdict additionally penalizes the ranking — teaching
  the app these photos are less desirable, as a duel loss does — while "Both Are
  Great" affects album size only, since good photos already rise by winning
  duels. Skip just moves on.
- **FR-5.8** The Duel tab shows how many choices the user has made, and a
  friendly empty state when there aren't yet two candidates to compare.
- **FR-5.9** Each duel card has its own visible ignore control, for a photo
  that doesn't belong in consideration at all — distinct from "Both Are Bad",
  which judges quality rather than removing the photo. Ignoring advances to a
  fresh pair.

## 6. The wallpaper album (Export tab)

- **FR-6.1** The app maintains a Photos album named "Alpenglow" holding
  exactly the user's top-ranked, de-duplicated photos. Each sync reports the
  total plus how many were added and removed.
- **FR-6.2** The album is ordered for visual variety, so that on "rotate in
  order" consecutive wallpapers look as different as possible. *(Why: avoid
  samey streaks of the same scene or mood.)*
- **FR-6.3** The user picks how many photos go in the album by typing an exact
  number or nudging a stepper, with **no upper limit** — if the whole library
  is awesome, the whole library can be the album. The count is clamped to what
  the library actually has available.
- **FR-6.4** The app suggests a count — where quality drops off in the user's
  own ranking, informed by their Great/Bad verdicts. The suggestion is
  displayed, adopted automatically only the first time, and never overrides a
  manual adjustment.
- **FR-6.5** Before syncing, the Export tab previews exactly the photos a sync
  would put in the album, in the album's actual order, in the same grid style
  as the Library tab. While the candidate pool is still loading, the tab shows
  a loading state rather than a fake or default count.
- **FR-6.6** After every sync, the app verifies the album really ended up in
  the requested order.
- **FR-6.7** The Export tab explains how to point System Settings → Wallpaper
  at the album for automatic rotation. *(Why: the hand-off to the OS is the
  product's finish line; the user should never have to guess it.)*
- **FR-6.8** If a sync into the album fails partway through, the app restores
  the album to its previous contents rather than leaving it empty or the
  user's live wallpaper rotation broken.
- **FR-6.9** The album survives being renamed by the user in Photos — a
  rename never orphans it or spawns a duplicate album on the next sync.

## 7. Durability

- **FR-7.1** All of the user's invested effort — scan results, analysis,
  choices, verdicts, exclusions — survives quitting, relaunching, and app
  updates. Long-running work always resumes where it stopped.
- **FR-7.2** The user's choice and verdict history is never pruned.
- **FR-7.3** Rebuilding or upgrading the app never requires the user to
  re-grant Photos access or re-train their taste from scratch.

## 8. Native feel

- **FR-8.1** Alpenglow follows Apple's Human Interface Guidelines for the
  platform it ships on (macOS today) — it looks, behaves, and feels like a
  native app, not a port. This single rule stands in for the whole native-feel
  checklist Apple already maintains: respecting the system light/dark appearance
  and accent, adapting cleanly to any window size, using the platform's own
  controls, menus, gestures, and keyboard shortcuts, staying legible over system
  materials, remaining fully usable with VoiceOver, the keyboard, larger text
  sizes, and the reduce-motion / reduce-transparency / increase-contrast
  settings, and returning the user to where they left off (active tab, scroll
  position, and in-progress duel) on the next launch. *(Why: the HIG is the
  living definition of "native" on the OS; deferring to it keeps the app feeling
  like it belongs without this brief restating — and having to maintain — rules
  Apple already publishes and updates every release. If Alpenglow ever ships on
  another platform, this requirement extends to that platform's HIG too.)*
- **FR-8.2** The app always stays responsive: no action ever freezes the
  interface. Work that takes time runs out of the way behind live progress, and
  the rest of the app stays usable while it runs. *(Why: a frozen window with a
  spinning cursor looks broken and leaves the user with nothing to do — even
  honest waiting should never take the whole app hostage. Of all of FR-8.1's
  native-feel promises this is the one concrete enough to test directly, so it is
  called out explicitly rather than left to the umbrella.)*
- **FR-8.3** Alpenglow has a standard macOS menu bar that exposes its real
  commands as named menu items with correct enabled/disabled state and standard
  keyboard shortcuts — at least Quit (⌘Q), the three photo actions of FR-4.6, the
  Show Ignored toggle (FR-4.9), scan / re-scan, and album sync. *(Why: the menu
  bar is where macOS users look for a command first, and it names every action
  in words with a shortcut. It makes actions discoverable and keyboard-reachable,
  so nothing essential lives only behind a right-click (FR-4.6) or an unlabeled
  icon (FR-4.13) — the one structural place these native-feel promises come
  together.)*

## Deferred ideas (explicitly parked)

- Auto-leveling the horizon if the app ever sets wallpapers directly rather
  than via the album.
- Using a "good" verdict as an *upward* ranking signal (today only bad verdicts
  train the ranking — downward; good verdicts calibrate album size only).
