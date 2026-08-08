# Alpenglow — Product Brief

Alpenglow curates desktop wallpapers from the user's own Photos library: it
finds high-resolution nature photos without people, learns the user's personal
taste from quick pairwise comparisons, and maintains a Photos album that System
Settings can rotate as wallpaper.

It runs on macOS 27, and on iPhone and iPad on iOS 27; nothing earlier. The Mac
is where wallpaper happens: only there does the album become
the desktop. On iPhone and iPad Alpenglow is a companion — the same finding,
learning and curating, feeding the same album — but it never sets wallpaper.
Requirements apply everywhere unless marked *(macOS)* or *(iPhone and iPad)*.

This document is the product brief: WHAT the user experiences and WHY, in
human-readable language. Product and UX design must always be verifiable
against it. It deliberately contains no APIs, algorithms, or thresholds — the
technical documentation is the code itself (see CLAUDE.md for the contract).

The app has three tabs matching the three stages of the journey:
**Library** (find & rank) → **Duel** (learn taste) → **Export** (the album).

---

## 1. Photos access & privacy

- **FR-1.1** The app asks for Photos access only when the user takes an
  explicit action, never silently at launch.
- **FR-1.2** The Library tab reflects the current access state (not yet asked /
  granted / limited / denied / restricted) and offers the right next step for
  each: a grant button, or a shortcut into Privacy Settings. When access is
  limited to a selection of photos, the tab says so plainly and offers a
  shortcut to change the selection in Photos settings (but see FR-1.8).
- **FR-1.3** A grant made in System Settings while the app is open takes
  effect when the user returns to the app — no relaunch needed.
- **FR-1.4** The app only ever adds or removes photos in its own wallpaper
  album; it never edits or deletes the user's actual photos. *(Why: trust — the
  library is safe.)*
- **FR-1.5** Everything happens on the user's own devices, and photo content
  never leaves them for third-party servers. There are two exceptions, both
  Apple's and both the user's own: their iCloud account, which carries their
  judgments — never photos — between their devices; and Private Cloud Compute,
  for work the device cannot do alone.
- **FR-1.6** *(macOS)* Launching the app twice just brings the already-running
  window forward instead of opening a second one. *(Why: two copies running at
  once could destroy the taste the user has trained.)*
- **FR-1.7** *(macOS)* Alpenglow is a single-window app: closing the window
  quits it, as does ⌘Q (FR-8.3). *(Why: for a single-window utility a
  windowless, still-running state is a no-op with nothing for the user to do.)*
  If a sync is running, quitting waits for it to finish or undo itself (FR-6.8).
- **FR-1.8** *(iPhone and iPad)* With limited access the app cannot maintain the
  album at all. It says so and offers the upgrade to full access, rather than
  appearing to work.

## 2. Finding candidate photos (Library tab)

- **FR-2.1** The app looks for photos that could plausibly work as wallpaper:
  wide (landscape) orientation and high enough resolution for a modern display.
  Older, smaller photos are not thrown out — they are admitted and simply
  ranked lower if the user's choices show they matter. *(Why: photos from older
  cameras are rarer and shouldn't be thrown away outright.)*
- **FR-2.2** Re-scanning is always safe to repeat: it adds only genuinely new
  photos, never duplicates, and refreshes what can change in Photos — in
  particular the favorite heart.
- **FR-2.4** Scanning shows live progress and ends with a clear summary: how
  many candidates there are and what changed (new / re-queued / removed).
- **FR-2.5** If the user edits a photo (crop, adjustments) after it was
  examined, only that photo is re-examined — never the whole library.
- **FR-2.6** Photos deleted from the library, or edited until they no longer
  qualify (e.g. cropped too small), drop out of the app automatically.
- **FR-2.7** When Photos access is already granted, launching the app
  automatically re-syncs: scanning and analysis run to completion without the
  user clicking anything. Manual re-scan and retry controls remain available
  at any time.

## 3. Analysis (Library tab)

- **FR-3.1** The app examines each candidate on-device to keep only nature
  photos without people, or cityscapes without a lot of people; screenshots and
  utility images are set aside too.
- **FR-3.2** After analysis, the user sees a breakdown of why photos were set
  aside: contains people, utility image, not nature, or waiting on iCloud.
- **FR-3.3** Analysis can be interrupted at any time.
- **FR-3.4** Photos stored only in iCloud are deferred, not skipped: the app
  finishes everything local first, then comes back to download and examine the
  rest. Progress honestly distinguishes "waiting on iCloud" from "done" — the
  app never claims completion while deferred work remains.
- **FR-3.5** The Library tab always offers the one obvious next action as the
  pipeline progresses ("Analyze N Photos", "Resume", "Retry N iCloud Photos",
  and finally "Analysis complete").
- **FR-3.6** *(iPhone and iPad)* A long run needs no babysitting: the user
  starts it, can stop it at any moment, and it carries on with the screen locked
  while the device is charging. If continuing would cost too much battery or run
  the device hot, it pauses and says that it is waiting.
- **FR-3.7** The app obeys the user's system-wide choices about which networks
  may carry data, rather than inventing a rule of its own. When photos must come
  down from iCloud and the network does not allow it, the app says what it is
  waiting for.

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
  from duels. Live means whenever the grid is on screen: while the user is busy
  elsewhere — mid-duel especially — the ranking need not be kept current in the
  background, only brought up to date by the time they see it again. This holds
  for content as well as order, and for all three Library views (FR-4.9):
  whatever changes — a scan finding or refreshing photos, analysis finishing, a
  verdict or ignore given anywhere — the visible view brings itself up to date,
  and the user is never given, and never needs, a manual refresh control. *(Why:
  recomputing an order nobody is looking at is wasted work on a busy device,
  and a refresh button admits the app cannot tell when its own data changed —
  it always can.)*
- **FR-4.6** Every photo, anywhere in the app (grid, export preview, duel),
  offers three actions: "Open in Photos", "Not Wallpaper Material", and "Ignore
  This Photo" — reached by right-click on the Mac and by touch on iPhone and
  iPad, and always also by name as a command (FR-8.3, FR-8.4), never only by a
  gesture. The two verdicts are toggles: choosing one again on a photo that
  already carries it reverses it — undoing a decision uses the same action as
  making it. All three apply only to the exact photo, never to its collapsed
  near-duplicate siblings (FR-4.2).
- **FR-4.7** "Not Wallpaper Material" records the same absolute bad-quality
  verdict as "Both Are Bad" (FR-5.7): a judgment of the photo's visible,
  weighable merits. It does **not** remove the photo — it stays in the grid,
  future duels, and the album-size suggestion, but sinks in the ranking over
  time and so out of the album. Clearing the verdict (FR-4.6) returns the photo
  to normal standing, as if it had never been marked. Using it mid-duel
  advances to a fresh pair. *(Why: this verdict teaches the app what bad looks
  like, so it must be given for reasons visible in the photo — a flaw the app
  cannot see belongs to "Ignore This Photo" (FR-4.8).)*
- **FR-4.8** "Ignore This Photo" fully removes a photo from the grid, future
  duels, the album-size suggestion, and (on next sync) the album. It is the
  right verdict when the flaw is one the app cannot see — orthogonal or
  emotional, e.g. a person the user would rather not face every day — even on
  a genuinely good shot. *(Why: marking such a photo poor quality instead
  would teach the app a falsehood about photos like it; ignoring removes it
  without teaching anything.)* While a photo is ignored its quality verdict
  cannot be changed: the control stays visible but is unavailable, and says
  why. Un-ignoring re-enables it, with any earlier verdict still in force.
  Using it mid-duel advances to a fresh pair.
- **FR-4.9** The Library tab switches among three views: Library (top
  candidates), Not Wallpaper Material, and Ignored. The latter two list the
  photos currently carrying that verdict — however it was given, from the grid
  or in a duel — and the same toggle (FR-4.6) clears it from there, returning
  the photo to the normal grid, duels, and album sizing.
- **FR-4.10** Every thumbnail is a clean, fixed-shape tile with the photo
  filling it; clicks and taps land only on the visible tile — a wide
  panorama must not spill over or steal clicks from neighboring cells.
- **FR-4.11** Switching tabs is instant: a tab still loading shows progress
  instead of holding up the rest of the app — especially Export.
- **FR-4.13** Every status-indicator icon and icon-only control is
  self-describing without relying on hover. It always carries an accessibility
  label so VoiceOver and assistive tech announce it; anything essential the user
  needs to understand or act on is also conveyed in visible words nearby or
  reachable as a named command (FR-8.3, FR-8.4); and a pointer tooltip is
  layered on top as a convenience for mouse users. *(Why: hover text explains an
  icon to pointer users but is invisible to keyboard, VoiceOver, and touch — it
  can enrich meaning, never carry it alone.)*
- **FR-4.14** Every thumbnail carries the two verdict toggles (FR-4.6) as
  translucent overlay buttons in the same visual family as the favorite heart
  (FR-4.4), so one tap or click marks or unmarks a photo — no context menu or
  long-press needed. The verdict toggle is unavailable while the photo is
  ignored (FR-4.8). Like the heart badge, they are tile markings, not the
  bar-style glass FR-8.5 reserves for the app's own chrome.

## 5. Learning taste (Duel tab)

- **FR-5.1** The user is shown two photos — "Which makes the better
  wallpaper?" — and picks the winner. Both are cropped to the same wide desktop
  shape the wallpaper will fill — the same on every device — so a judgment made
  on a phone means exactly what one made on the Mac means. The
  learned ranking judges that same crop, not the whole photo — important for
  panoramas, where the crop can look very different from the full photo. Both
  photos are fully visible at once, however small the screen.
- **FR-5.2** Ranking is learned entirely from the user's choices. Nothing is
  hard-coded: a low-resolution or tilted photo is penalized only as much as
  the user's own decisions imply.
- **FR-5.3** Every choice and verdict is remembered permanently — the user's
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
  "Both Are Bad", or Skip. Both record absolute quality that helps size the
  album. A "Both Are Bad" verdict additionally penalizes the ranking — teaching
  the app these photos are less desirable, as a duel loss does — while "Both Are
  Great" affects album size only, since good photos already rise by winning
  duels. Skip just moves on.
- **FR-5.8** The Duel tab shows how many choices the user has made, and a
  friendly empty state when there aren't yet two candidates to compare.
- **FR-5.9** Each duel card carries a visible ignore control (FR-4.8), distinct
  from "Both Are Bad", which judges quality rather than removing the photo.
- **FR-5.10** Every newly drawn duel pair reflects all judgments made so far,
  anywhere in the app. A pair already on screen when a judgment changes
  elsewhere may predate it — judging it is still valid, since the user judges
  the photos in front of them, not the bookkeeping behind them.

## 6. The wallpaper album (Export tab)

- **FR-6.1** The app maintains a Photos album named "Alpenglow" holding
  exactly the user's top-ranked, de-duplicated photos. Each sync reports the
  total plus how many were added and removed.
- **FR-6.2** The album is ordered for visual variety, so that on "rotate in
  order" consecutive wallpapers look as different as possible. *(Why: avoid
  samey streaks of the same scene or mood.)*
- **FR-6.3** The user picks the album size with one slider running from a
  handful of photos to every candidate the library holds. The scale is
  proportional — a nudge changes the count by a fraction of it, not a fixed
  amount — and carries a few labeled marks at round counts so the unusual
  scale reads at a glance. The exact count is shown beside the slider and can
  be edited directly as a number. The thumb moves freely, and equally freely
  on every platform: the marks are a scale to read the track by, never stops
  the thumb is confined to — every count is reachable by dragging, with one
  deliberate exception: the suggestion's mark gently catches the passing
  thumb (FR-6.4), so the one point that is easy to mean and hard to hit is
  easy to hit too.
- **FR-6.4** The app suggests a count — where quality drops off in the user's
  own ranking, informed by their Great/Bad verdicts — and marks it on the
  slider's scale. Adopting it is moving the thumb onto the mark; there is no
  separate button. The suggestion is followed automatically until the user
  first sets a size of their own — by slider or by typing — and never
  overrides them after that (FR-6.12).
- **FR-6.12** The app remembers the choice **relative to the suggestion**,
  not as a count: when the suggestion shifts with new analysis and judgments,
  the set count shifts with it, preserving the user's strictness. A pool
  momentarily too small to honour that standard limits only what is shown,
  never what is remembered. The standard is the user's, not the device's: it
  counts on every device, like any other judgment (section 9). The album
  itself still changes only on sync (FR-6.10). *(Why: "half as many as you
  think" should be said once, not re-derived after every scan.)*
- **FR-6.5** Before syncing, the Export tab previews exactly the photos a sync
  would put in the album, in the album's actual order, in the same grid style
  as the Library tab. While the candidate pool is still loading, the tab shows
  a loading state rather than a fake or default count.
- **FR-6.6** After every sync, the app verifies the album really ended up in
  the requested order, and tells the user when it did not.
- **FR-6.7** *(macOS)* The Export tab explains how to point System Settings →
  Wallpaper at the album for automatic rotation. *(iPhone and iPad)* The app
  says plainly that
  wallpaper is set on the Mac, so the user never hunts for a button that cannot
  exist.
- **FR-6.8** If a sync into the album fails partway through, the app restores
  the album to its previous contents rather than leaving it empty or the
  user's live wallpaper rotation broken.
- **FR-6.9** The album survives being renamed by the user in Photos — a
  rename never orphans it or spawns a duplicate album on the next sync.
- **FR-6.10** The album changes only when the user asks for a sync. *(Why: the
  user's devices share one album, and unattended changes would let them undo
  each other's.)*
- **FR-6.11** A device that cannot yet see the Alpenglow album says so and
  waits.

## 7. Durability

- **FR-7.1** All of the user's invested effort — scan results, analysis,
  choices, verdicts, exclusions — survives quitting, relaunching, and app
  updates. Long-running work always resumes where it stopped.
- **FR-7.2** Rebuilding or upgrading the app never requires the user to
  re-grant Photos access.

## 8. Native feel

- **FR-8.1** Alpenglow follows Apple's Human Interface Guidelines for the
  platform it is running on. This single rule stands in for the whole
  native-feel checklist Apple already maintains: respecting the system
  light/dark appearance and accent, adapting cleanly to any window or screen
  size, using the platform's own controls, menus, gestures, and keyboard
  shortcuts, staying legible over system materials, remaining fully usable with
  VoiceOver, the keyboard, larger text sizes, and the reduce-motion /
  reduce-transparency / increase-contrast settings, and returning the user to
  where they left off (active tab, scroll position, and in-progress duel) on the
  next launch. *(Why: the HIG is the living definition of "native" on each OS;
  deferring to it keeps the app feeling like it belongs without this brief
  restating — and having to maintain — rules Apple already publishes and updates
  every release.)*
- **FR-8.2** The app always stays responsive: no action ever freezes the
  interface. Work that takes time runs out of the way behind live progress, and
  the rest of the app stays usable while it runs. *(Why: a frozen window with a
  spinning cursor looks broken and leaves the user with nothing to do — even
  honest waiting should never take the whole app hostage.)*
- **FR-8.3** *(macOS)* Alpenglow has a standard menu bar that exposes its real
  commands as named menu items with correct enabled/disabled state and standard
  keyboard shortcuts — at least Quit (⌘Q), the three photo actions of FR-4.6
  (worded as their reverse when the photo already carries the verdict), the
  Library view switch (FR-4.9), scan / re-scan, and album sync. *(Why: the
  menu bar is where macOS users look for a command first, and it names every
  action in words with a shortcut, so nothing essential lives only behind a
  right-click or an unlabeled icon.)*
- **FR-8.4** *(iPhone and iPad)* Every command is reachable by touch, and
  nothing lives only behind a gesture the user has to guess.
- **FR-8.5** Glass belongs to the app's own bars and controls, never to the
  photos: thumbnails, duel cards and previews stay plain, and glass looks the
  same everywhere it appears. Text on glass stays legible over the user's
  brightest and darkest photos, in light and dark. Nothing the user needs to see
  is half-hidden under a bar, and at most one action per screen is highlighted
  as prominent.
- **FR-8.6** The app icon shows off everything the system's glass icons can do:
  depth between layers, a colour gradient, layers that blend and show through
  one another, a highlight placed as if lit from one direction, light bending
  and blurring as it passes through the glass, and a shadow beneath. It reads
  clearly in all six appearances the system draws — default, dark, clear light
  and dark, tinted light and dark — and at the smallest size it is ever shown.
- **FR-8.7** The interface holds still: a control only ever moves or resizes
  as the direct result of the user's own act. Whatever the app shows of its
  own accord while it works — however it takes shape: a wait, a status, a
  running count, a whole view's busy state — leaves every control exactly
  where and as big as it was, and is shown at all only when the wait is long
  enough to notice: near-instant work finishes silently. Which actions are
  offered may itself change as work starts and settles — stopping a run is
  rightly only on offer while one is going — but an action that changes does
  so in place, taking no neighbour with it. What arrives and
  stays — a result, a notice, a banner — may take room, pushing what follows
  it, but never the control whose use produced it. And room once granted is
  kept: work that will end by replacing what the user already sees — a fresh
  summary where the last one stands — leaves the old one showing until the
  new one is ready, never clearing it only to refill the space, so redoing
  something moves nothing at all. *(Why: the moment a
  target moves is usually the moment a hand is reaching for it; an interface
  that jolts of its own accord reads as broken, and a calm, stable frame is
  as much of what makes an app feel native as any control style.)*
- **FR-8.8** The app tells the user what it is and which one they have, in
  each platform's own place for that: on macOS a filled-in About box —
  Alpenglow's icon and name, one sentence saying what it does, its true
  version, and a copyright line naming its author; on iPhone and iPad the
  same facts somewhere the user would naturally find them. The icon shown is
  the icon: the same rendering the system presents for the app everywhere
  else — Dock, Home Screen, app switcher — never a second, subtly different
  version of it. Nothing there is
  a template leftover or a placeholder. *(Why: About is where a user checks
  what they are running before reporting a problem or updating; an empty box
  or a stock "1.0" says nobody finished the app.)*
- **FR-8.9** Alpenglow is versioned as major.minor.patch, semantic-versioning
  style read for an app: the major number marks a release that changes what
  the app is or asks the user to relearn something, minor adds features, and
  patch only fixes. Every user-visible change bumps the version, the version
  shown to the user is always the one actually running, and no two different
  builds ever present the same version and build number. Until the app is
  fit for its first real release it stays at 0.minor.patch, so the version
  never claims a maturity the app does not have. *(Why: a version is the one
  handle user and author share when something must be identified — "which
  Alpenglow does this happen in?" — and it only works if it is truthful and
  moves with the app.)*

- **FR-8.10** The interface holds only what this brief calls for: every
  control, view, and adornment traces back to a requirement, and no two
  controls in one place do the same job — where several could, the one that
  serves the whole range of the task stays and the others are left out.
  *(Why: an unasked-for control is not a free extra — it is one more thing to
  read, reach past, and maintain, and two ways to do the same thing make each
  other harder to understand.)*
- **FR-8.11** Text never collides with text: no label, badge, or mark is ever
  drawn over another, at any window size, text size, or data the app can
  reach. When space runs short, something yields — moves, abbreviates, or
  goes — rather than overlaps. *(Why: two labels printed over each other read
  as neither; a layout is only correct if no reachable state breaks it.)*

## 9. Across the user's devices

- **FR-9.1** A judgment made on one device counts on all of them, against the
  same photo: the user trains one taste, not one per device.
- **FR-9.2** A photo that has not reached this device yet keeps everything the
  user decided about it: those judgments take effect the moment it arrives.
- **FR-9.3** Everything works with no network and with no iCloud account at
  all. Devices catch up later, and no judgment is ever lost because two of them
  were used apart.

## Parked (deferred, or not currently possible)

- The iCloud transport behind section 9 and FR-6.12: judgments and the
  album-size standard are held ready to travel, but carrying them needs an
  iCloud entitlement the app's current signing cannot have. Until it can,
  each device keeps its own copy and no judgment is lost — the fallback
  FR-9.3 demands anyway.

- Auto-leveling the horizon if the app ever sets wallpapers directly rather
  than via the album.
- Using a "good" verdict as an *upward* ranking signal (today only bad verdicts
  train the ranking — downward; good verdicts calibrate album size only).
- A "shared library" badge on photos from the iCloud Shared Photo Library: the
  system exposes no supported way to tell whether a photo belongs to it (the
  legacy Shared Albums signal is a different feature and would mislabel photos).
- Setting or rotating wallpaper from iPhone or iPad: no supported way exists for
  an app to touch wallpaper there, which is why the album is the finish line on
  those platforms (FR-6.7).
- Carrying the album's running order to another device: how an album is sorted
  on a given device is a Photos setting the user owns, which apps cannot read or
  change (FR-6.2).
