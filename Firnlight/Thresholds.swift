import CoreGraphics
import Foundation

/// Every tunable magic number in the app lives here.
/// `nonisolated`: plain constants, readable from any actor (the analysis pipeline runs off-main).
nonisolated enum Thresholds {
    // MARK: The desktop shape (FR-5.1)

    /// Aspect ratio (width / height) of the wallpaper crop the app judges every
    /// photo through: the analysis bitmap is cut to it, the duel cards show it,
    /// and the grid tiles are drawn at it — so what the ranker learns, what the
    /// user compared, and what the grid displays are all the same rectangle.
    ///
    /// Deliberately one fixed shape rather than the running display's. Until
    /// 2026-07-25 this was read live from the main display (`NSScreen.main` in
    /// the duel, `CGDisplayBounds` in analysis), which FR-5.1 no longer allows:
    /// a choice made on an iPhone has to mean exactly what the same choice made
    /// on the Mac means, and both devices score the same photo into one shared
    /// ranking — a per-display crop would have them disagreeing about it. It
    /// also made the Mac disagree with *itself* when the user moved the window
    /// between a 16:9 external display and the built-in one.
    ///
    /// 16:10 because that is the shape of the built-in display on every Mac
    /// Apple currently ships, which is where the wallpaper actually lands; it
    /// was already this app's fallback whenever the display bounds couldn't be
    /// read, and it sits between the 16:9 of most external displays and the
    /// squarer 3:2-ish panels, so neither is badly misjudged.
    static let desktopAspectRatio: CGFloat = 16.0 / 10.0

    // MARK: The interface holding still (FR-8.7)

    /// How long work has to run before the interface admits to waiting on it.
    /// Anything that finishes sooner finishes silently — see the
    /// `shownWhileWaiting` modifier, which every spinner in the app goes
    /// through.
    ///
    /// Almost all of this app's waits are either far under this (a SwiftData
    /// count, a cached thumbnail, recording one duel choice) or far over it (a
    /// library scan, a Vision run, an iCloud download), so the exact value only
    /// has to separate the two populations, not sit at a perceptual boundary.
    /// 0.4 s is Apple's own long-standing spacing for this — it is what
    /// `NSProgressIndicator`'s `usesThreadedAnimation` era shipped as the
    /// delay before a spinner appears, and roughly what UIKit's refresh
    /// controls settle at — and it is comfortably longer than a warm fetch
    /// while still short enough that a real wait never feels unacknowledged.
    ///
    /// Erring low is the cheaper mistake here: showing a spinner slightly too
    /// eagerly costs a flicker, whereas a long silent wait reads as a hang.
    static let noticeableWaitDelay: Duration = .milliseconds(400)

    // MARK: Scan (Phase 2)

    /// Minimum pixel width for a wallpaper candidate. 3264 admits iPhone 5s-era
    /// 8 MP photos (3264×2448) — older photos are rarer, so they get a learned
    /// resolution penalty in the ranker instead of a hard cut.
    static let minimumCandidatePixelWidth = 3264

    /// Pixel width at which the ranker's resolution feature saturates at 1
    /// (extra pixels beyond this add no ranking benefit).
    static let resolutionFullScoreWidth: Float = 6000

    /// Newly inserted records between incremental SwiftData saves during a scan,
    /// so a killed app loses at most one batch of progress.
    static let scanSaveBatchSize = 1000

    /// Assets examined between progress updates and cooperative yields during a scan.
    static let scanProgressStride = 256

    /// Photos per `cloudIdentifierMappings(forLocalIdentifiers:)` call when
    /// resolving device-independent identifiers (FR-9.1).
    ///
    /// PhotoKit's header is blunt about the cost — "This method can be very
    /// expensive so they should be used sparingly for batch lookup of all
    /// needed identifiers" — so the call is made per chunk, never per photo.
    /// It is also synchronous and blocking, which is why it runs off the main
    /// actor. 500 balances the two failure modes: chunks too small pay the
    /// per-call overhead repeatedly, while one unbounded call over a library
    /// this size would block for an unpredictable stretch with no chance to
    /// save partway. Chunking also lets each batch be persisted as it lands,
    /// matching how the scan and analysis already checkpoint.
    static let cloudIdentifierBatchSize = 500

    // MARK: Vision analysis (Phase 3)

    /// Bump when analysis logic changes; records with an older version are re-analyzed.
    /// v3 is required: v2 cut its analysis bitmap to whatever the main display
    /// happened to be, so records analyzed on a 16:9 display measured a
    /// different rectangle than the fixed `desktopAspectRatio` crop the ranker
    /// now assumes — and than the same photo would measure on another device.
    /// v4 is required too: it adds the flawed-photo rejection (FR-3.1), so a
    /// badly blurred or smeared photo accepted under v3 must be re-scored
    /// against `severelyFlawedAestheticsScore` before it can keep counting as
    /// a candidate.
    /// v5 is required too: `ImageAnalyzer` now also runs
    /// `DetectLensSmudgeRequest`, a dedicated obstruction detector the
    /// aesthetics-score gate alone couldn't see — a photo the v4 gate let
    /// through must be re-checked against `lensSmudgeConfidenceThreshold`
    /// before it can keep counting as a candidate. Bumping this alone queues
    /// every already-analyzed record for re-analysis in the background, with
    /// no judgment lost and no user action required (FR-5.2's "must
    /// re-examine what it must" — see `AnalysisQueue.processNextBatch`).
    /// v6 is required too: it tightens the people gate (FR-3.1) after a real
    /// escape — `humanConfidenceThreshold` lowered to catch low-confidence
    /// reclining bodies, and the classification-label people check
    /// (`peopleLabels`) added — so a photo accepted under v5 must be re-judged
    /// before it can keep counting as a candidate.
    static let currentAnalysisVersion = 6 // v6 tightens the people gate: lower rectangle confidence + label check

    /// Records analyzed and saved per batch; a killed app loses at most one batch.
    static let analysisBatchSize = 32

    /// Concurrent Vision pipelines within a batch.
    static let analysisConcurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// How long a paused analysis run waits before re-testing the condition
    /// that paused it — device heat, Low Power Mode, or a network the user's
    /// settings don't allow downloads over (FR-3.6, FR-3.7).
    ///
    /// Polling rather than observing `thermalStateDidChangeNotification` /
    /// `NSProcessInfoPowerStateDidChange` / `NWPathMonitor.pathUpdateHandler`:
    /// the loop already has a natural checkpoint between batches, so a poll is
    /// a `guard` there instead of three observers, their registrations, and the
    /// actor hops to deliver them. 20s because none of these conditions clear
    /// quickly — a hot device needs tens of seconds of reduced load to cool,
    /// and Low Power Mode and network policy are user actions — so a shorter
    /// interval would only burn wakeups restating the same answer, while a
    /// longer one would leave the user staring at "waiting" well after the
    /// cause cleared.
    static let analysisPauseRecheckInterval: Duration = .seconds(20)

    /// How long a run waits before trying the photos iCloud hasn't delivered
    /// again (FR-3.4: deferred photos are the app's to retry, never the
    /// user's).
    ///
    /// Deliberately much longer than the pause re-check above, because it
    /// answers a different question. That one asks whether a *condition* has
    /// cleared, which costs a property read; this one asks PhotoKit to attempt
    /// the downloads again, which costs a network round trip per photo and had
    /// just failed. Five minutes is short enough that a download unblocked by
    /// the user opening Photos, or by iCloud finishing something else, is
    /// picked up while they are still at the machine, and long enough that a
    /// photo which will never arrive costs a handful of attempts an hour
    /// rather than a spin.
    static let deferredRetryInterval: Duration = .seconds(300)

    /// How long the app lets library changes settle before catching up with
    /// them (FR-2.6, FR-2.7).
    ///
    /// Photos reports changes as they happen, and a single user action rarely
    /// produces a single notification — importing a batch, an edit propagating
    /// from another device, or the app's own album sync all arrive as a burst.
    /// Catching up is a pass over the library, so the burst is worth
    /// collapsing into one. Two seconds is under the time it takes to notice a
    /// photo missing from the grid, and comfortably longer than the gaps
    /// within a burst.
    static let libraryChangeSettleDelay: Duration = .seconds(2)

    /// How often `LibraryCatchUp` re-reads Photos authorization on its own,
    /// independent of `PhotoLibraryWatcher` (FR-1.8).
    ///
    /// The fast path for noticing a narrowing — full access cut down to a
    /// selection while the app is open — is `photoLibraryDidChange`, and for
    /// most of the app's life that is also the only path: a narrowing made
    /// while backgrounded is caught by the `scenePhase` refresh in
    /// `ContentView` when the app returns to the foreground. Neither covers a
    /// session that stays foregrounded and idle the whole time: no scene-phase
    /// transition fires, and — see the doc comment on
    /// `PhotoLibraryWatcher.photoLibraryDidChange` — Apple documents the
    /// change observer firing for edits to an already-limited selection, not
    /// for the authorization-level transition itself, so relying on it alone
    /// for that case is an assumption this project could not verify. This
    /// timer is the fallback for exactly that gap, not the primary mechanism,
    /// which is why it can afford to be slow: `PHPhotoLibrary
    /// .authorizationStatus(for:)` is a local, synchronous read with no
    /// PhotoKit round trip, so the cost of checking is negligible, but there
    /// is nothing to gain from checking often — a narrowing is a deliberate
    /// trip to Settings, not an event that needs catching within seconds.
    /// Five minutes bounds how long the app could work on a library it no
    /// longer fully sees without ever bothering the user with a busy loop.
    static let authorizationNarrowingRecheckInterval: Duration = .seconds(300)

    /// Long-edge size of the analysis bitmap requested from PHImageManager. Never analyze full-res.
    static let analysisPixelSize = 1024

    /// Minimum DetectHumanRectanglesRequest confidence that counts as a person.
    ///
    /// Tuning history: shipped at 0.3; lowered to 0.2 on 2026-08-14 after a
    /// real escape (IMG_0259) — a reclining sunbather filling a third of the
    /// frame came back at confidence 0.27, one hundredth under the old floor.
    /// Vision's confidence drops on reclining or partially occluded bodies,
    /// and this gate only fires together with the prominence test
    /// (`personProminenceHeight`), so a lower floor cannot reject the distant
    /// figures FR-3.1 admits — it only tightens the call on rectangles already
    /// big enough to be the subject.
    static let humanConfidenceThreshold: Float = 0.2

    /// Classification labels that read as people being the subject of the
    /// photo, checked against the same `ClassifyImageRequest` results the
    /// nature gate uses (no extra Vision pass). This is the third, independent
    /// people signal (FR-3.1): the rectangle detectors measure geometry, but a
    /// person can defeat both — face too small when reclining, body confidence
    /// low in unusual poses — while the whole-image classifier still calls the
    /// scene "people" outright (0.85 on the escape that motivated this gate).
    /// Every entry verified against `ClassifyImageRequest().supportedIdentifiers`.
    static let peopleLabels: Set<String> = ["people", "adult", "child", "baby", "crowd"]

    /// Minimum confidence on any `peopleLabels` entry that rejects the photo.
    /// Higher than `natureConfidenceThreshold` on purpose: FR-3.1 admits
    /// distant figures in a cityscape, and a scene-dominating person should
    /// classify strongly (the motivating escape scored 0.85) while incidental
    /// figures should not. One real data point so far — tune from real library
    /// data via the ImageAnalyzer debug log, like `natureLabels`.
    static let peopleLabelConfidenceThreshold: Float = 0.75

    /// A face (or confident human rectangle) taller than this fraction of the
    /// analysis frame height reads as a foreground portrait subject, not a
    /// distant passer-by, and rejects the photo. Shared between faces and human
    /// rectangles: a body this tall is scenery-dominating either way.
    /// (FR-3.1 revision 2026-07-20: cityscapes admit distant people; only a lot
    /// of people, or a prominent one, reject.)
    /// CGFloat to match Vision's normalized bounding-box height.
    static let personProminenceHeight: CGFloat = 0.08

    /// Face count at or above which the frame reads as a crowd and rejects,
    /// regardless of how small any individual face is.
    static let crowdFaceCount = 6

    /// Minimum classification confidence for a label to count toward the nature check.
    static let natureConfidenceThreshold: Float = 0.4

    /// `CalculateImageAestheticsScoresRequest.overallScore` (range -1…1; Apple
    /// documents it as reflecting how well taken the image is, blur and
    /// exposure among its factors) below which a photo is rejected as flawed
    /// — FR-3.1's "finger over the lens, a badly blurred or smeared frame" —
    /// rather than merely ranked lower. Set well under the neutral midpoint
    /// (0) so an ordinarily mediocre but intact photo is never caught: this
    /// gate is for photos too damaged to use "however good the scene," not a
    /// second aesthetics cutoff. This is one of two independent flaw gates —
    /// see `lensSmudgeConfidenceThreshold` for the other — since aesthetics
    /// folds in technical quality generally but isn't a dedicated obstruction
    /// detector; unverified against real flawed photos, so tune from real
    /// library data the same way `natureLabels` is tuned, via the
    /// ImageAnalyzer debug log.
    static let severelyFlawedAestheticsScore: Float = -0.5

    /// `SmudgeObservation.confidence` (0…1) from `DetectLensSmudgeRequest`
    /// (macOS/iOS 26+) at or above which a photo is rejected as flawed — the
    /// dedicated detector for FR-3.1's "a finger over the lens" specifically,
    /// independent of `severelyFlawedAestheticsScore`: a smudge can sit in a
    /// corner of an otherwise well-exposed, sharp frame and never pull the
    /// overall aesthetics score low enough to trip that gate alone. 0.7 errs
    /// toward the same side `severelyFlawedAestheticsScore` does — reject only
    /// what the model is confident about, since a false rejection silently
    /// removes a candidate the user never gets a chance to see and choose in a
    /// duel, while a false negative is merely ranked on its other merits, same
    /// as any other request in this pipeline. Unverified against real smudged
    /// photos (no such photos in hand while this shipped); tune from real
    /// library data via the ImageAnalyzer debug log.
    static let lensSmudgeConfidenceThreshold: Float = 0.7

    // MARK: Candidate grid (Phase 4)

    /// Feature-print distance below which two photos count as near-duplicates
    /// (greedy pass over the ranked list; L2 distance on the raw print vectors).
    /// 0.35 let same-subject re-takes through on real library data; raised to 0.5.
    static let nearDuplicateDistance: Float = 0.5

    /// Maximum candidates shown in the grid; bounds the dedupe cost.
    static let gridMaxCandidates = 600

    /// Long-edge pixel size for grid thumbnails.
    static let gridThumbnailPixelSize = 320

    /// Added to aestheticsScore (range -1…1) when ranking: Photos favorites are
    /// a prior for "liked" until the preference ranker takes over.
    static let favoriteRankBoost: Float = 0.3

    // MARK: Duel + preference ranker (Phase 5)

    /// Bump when the ranker's algorithm changes (features, normalization,
    /// seeding, learning rate semantics). A mismatch with the stored weights
    /// file triggers an automatic rebuild: re-seed from current favorites,
    /// replay all choices (and, from v5, bad verdicts), re-rank everything.
    /// v5 is required, not optional: a bad verdict recorded before this
    /// version shipped was never applied to the weights that existed at the
    /// time, so only a full rebuild folds that backlog in — no incremental
    /// catch-up is possible (FR-5.3).
    /// v6 is required too: it adds the `time`/`location` features (FR-5.2's
    /// "when and where"), and `Weights` gained the two fields that carry
    /// their learned coefficients — a v5 weights file has no opinion about
    /// either, so only a full rebuild (re-seed + full choice/verdict replay)
    /// folds them in, same reasoning as v5's bad-verdict backlog.
    /// v7 is required too: v6's `time`/`location` were normalized against the
    /// current candidate set (oldest/newest dated photo, distance from the
    /// location centroid), which meant an ordinary library scan could shift
    /// those denominators and silently rescale every already-trained
    /// `weights.time`/`weights.location` coefficient's meaning — a v6 weights
    /// file may have been fit to a scale that no longer matches what
    /// `PreferenceRanker.loadEntries()` now computes, so it must be discarded
    /// and rebuilt rather than reused. v7 replaces both with fixed,
    /// library-independent scales (`PreferenceRanker.seasonFraction`,
    /// latitude ÷ 90) that never move under a growing library — see
    /// `PreferenceRanker`'s type doc comment.
    static let rankerAlgorithmVersion = 7 // v7: time/location use fixed scales, not candidate-set-relative ones (FR-5.2)

    /// SGD learning rate for the online Bradley–Terry ranker.
    static let rankerLearningRate: Float = 0.5

    /// L2 weight-decay factor applied before each SGD step; bounds weight growth
    /// so raw scores stay in a sane range and one duel can't swing the ranking.
    static let rankerWeightDecay: Float = 0.01

    /// Fixed seed for the deterministic RNG used when seeding fresh weights from
    /// favorites, so an identical choice history rebuilds the same ranking.
    static let rankerSeedRNG: UInt64 = 0x616C70656E676C6F // "alpenglo"

    /// Without verdict calibration, duels draw from this top fraction of all
    /// candidates — wide, so "both bad" verdicts can find the quality floor.
    static let duelPoolFraction: Float = 0.75

    /// Duel pool never shrinks below this many photos.
    static let duelPoolMinimum = 200

    /// With calibration, the duel pool is everything scoring above
    /// (verdict bar − this margin): export candidates plus a probing band below.
    /// Raw-score units: the sigmoid slope at the center is ¼, so this 0.5 raw
    /// margin ≈ the old 0.1 sigmoid margin.
    static let duelPoolScoreMargin: Float = 0.5

    /// Random pair samples per duel; the closest-scored valid pair wins (uncertainty sampling).
    static let duelPairSamples = 32

    /// Pseudo-choices per Photos favorite when seeding fresh ranker weights.
    static let favoriteSeedOpponents = 3

    /// Cap on total favorite pseudo-choices during seeding.
    static let favoriteSeedMaxPairs = 300

    /// Long-edge pixel size for duel images.
    static let duelImagePixelSize = 1024

    // MARK: Preference-score cache flush (Phase 5) — responsiveness (FR-8.2)

    /// A single duel choice nudges every candidate's raw score by a tiny amount
    /// (one SGD step + weight decay touches every weight). Rewriting the whole
    /// `PhotoRecord.preferenceScore` cache and saving on *every* choice held the
    /// SQLite write lock long enough to stall the main context's reads and
    /// beachball the UI (FR-8.2). Instead the cache is flushed off the hot path
    /// once a burst of choices settles — whichever of the two bounds below hits
    /// first. This one caps how many rapid-fire choices coalesce into one write,
    /// so the grid never lags further than a handful of clicks behind (FR-4.5).
    static let preferenceCacheFlushBatchSize = 8

    /// The other flush bound: quiet time after the last choice before the cache
    /// is written and the ranked views (grid re-order, export preview) refresh.
    /// Long enough to coalesce a fast clicking streak into one write, short
    /// enough that the grid catches up almost immediately once the user pauses,
    /// keeping the re-ordering "live" (FR-4.5).
    static let preferenceCacheFlushIdleInterval: Duration = .seconds(1.5)

    /// Minimum raw-score change that dirties a cached `preferenceScore`. Below
    /// this the shift is float noise — sub-visible after the sigmoid and
    /// rank-order-neutral — so skipping the write stops one SGD step from
    /// dirtying (and rewriting) every row, which is exactly the write
    /// amplification the debounce exists to avoid. Accumulated drift still
    /// crosses it within a few choices and gets written, and prepare() rewrites
    /// the whole cache on launch, so the cache always reconverges regardless.
    static let preferenceCacheEpsilon: Float = 0.001

    // MARK: Horizon prior

    /// Tilt (degrees) at which the ranker's levelness feature bottoms out at 0.
    static let horizonMaxTiltDegrees: Float = 45

    // MARK: Wallpaper album (Phase 6)

    /// Name of the Photos album the app keeps in sync with top candidates.
    static let wallpaperAlbumName = "Firnlight"

    /// Default number of top-ranked photos synced into the wallpaper album
    /// (used when the quality curve is too flat or small to suggest from).
    static let defaultWallpaperCount = 50

    /// Ranked candidates examined for the KNEE fallback only. The verdict
    /// calibration has no upper bound — if every photo clears the bar, the
    /// album is the whole library.
    static let albumSuggestionScanLimit = 500

    /// Suggested album size never drops below this.
    static let albumSuggestionMinimum = 20

    /// Minimum normalized score spread required to trust the knee detection.
    static let albumSuggestionMinimumSpread: Float = 0.05

    /// "Both bad" verdicts needed before they calibrate the album size
    /// (below that, the knee heuristic is used).
    static let albumCalibrationMinimumBadVerdicts = 2

    /// Album ordering maximizes the minimum feature-print distance to this
    /// many previously placed photos, so consecutive wallpapers look different.
    static let albumDiversityWindow = 5

    // MARK: The album-size scale (FR-6.3)

    /// The smallest album the size slider offers — FR-6.3's "a handful of
    /// photos". Ten is roughly a fortnight of daily desktops, below which the
    /// album stops being a rotation at all; and the difference between three
    /// and four is not worth track that has to reach the other end of a
    /// library measured in thousands. The number field is held to the same
    /// floor, so the two halves of the control cannot disagree about what the
    /// smallest album is.
    static let minimumWallpaperCount = 10

    /// Leading digits of the round counts the slider marks: 10, 20, 50, 100,
    /// 200, 500 … A 1-2-5 ladder is the standard round-number series for a
    /// logarithmic axis, because its steps are near-evenly spaced in log space
    /// (×2, ×2.5, ×2) — the marks land at even intervals along the track while
    /// every label stays a number a person would say out loud. A 1-3 ladder
    /// spaces more evenly still and reads worse; plain decades leave a gap of
    /// a whole ×10 between marks, which is what `albumSizeMarkLimit` falls
    /// back to only when the ladder gets crowded.
    static let albumSizeMarkMantissas = [1, 2, 5]

    /// How many round marks the slider may carry before it thins them to plain
    /// decades. FR-6.3 asks for "a few labeled marks"; past six, their labels
    /// start to touch in a narrow window, and a mark whose label is unreadable
    /// is worse than no mark.
    static let albumSizeMarkLimit = 6

    /// Distance from the end of a slider's track to the centre of its thumb
    /// when the thumb is parked there — the inset the app has to reproduce
    /// both to line its own mark labels up with the ticks the system draws
    /// (iPhone and iPad) and to know where any label will land when deciding
    /// which ones fit (FR-8.11, both platforms).
    ///
    /// There is no API that reports it, so it is measured. iOS 27 simulator: a
    /// 340pt track put its 0.0 and 1.0 ticks 17.5pt in from each end, which is
    /// half the width of the thumb; verified by putting a label row under a
    /// ticked slider and checking every label sat under its dot. macOS 27: the
    /// same measurement off the Export card's own slider gives about 6pt, its
    /// thumb being much the smaller. If a future thumb changes size these move
    /// with it, and the symptom is labels drifting off their marks toward the
    /// ends.
    static let sliderTrackInset: CGFloat = {
        #if os(macOS)
        6
        #else
        17.5
        #endif
    }()

    /// How much one VoiceOver or Full Keyboard Access step changes the album
    /// size, as a multiple of the current count.
    ///
    /// A tenth, matching the proportional nudge FR-6.3 asks of the thumb: the
    /// same press moves 20 to 22 and 2,000 to 2,200. A slider left to its own
    /// devices steps by a tenth of its *range*, which on a logarithmic scale
    /// is nearly a doubling — eleven or so counts reachable across a whole
    /// library, which is no way to pick a number.
    static let albumSizeAssistiveStep = 1.1

    /// Diameter of the dots drawn under the size slider's track on iPhone and
    /// iPad, where the app draws its own scale (see `ExportView.markScale`).
    ///
    /// Matched by eye to the ticks the system used to draw there, so the scale
    /// reads the same as before the ticks had to go: small enough to be a mark
    /// rather than a control, large enough to survive a Retina downscale.
    static let albumSizeMarkDotSize: CGFloat = 3

    /// Clear space demanded between two mark labels on the size slider before
    /// they count as fitting side by side (FR-8.11).
    ///
    /// Six points is about the width of a space at these sizes: enough that
    /// two labels read as two, and small enough that it costs no mark that
    /// would genuinely have fitted. It is deliberately a length and not a
    /// fraction of the track — the mistake that let "Suggested" print over
    /// "1,000" on the iPad was measuring a collision in units that stretch
    /// while the text does not.
    static let albumSizeLabelGap: CGFloat = 6

    /// How close to the suggestion's mark the thumb has to come, **in points
    /// on screen**, before the mark catches it (FR-6.3's one exception; see
    /// `AlbumSizeScale.detented`).
    ///
    /// A distance, not a share of the track, because what has to come within
    /// reach is a fingertip or a pointer and neither grows with the window: a
    /// share that catches nicely on a wide Mac is a couple of points on a
    /// narrow iPhone, which no finger can hit.
    ///
    /// 12pt is a little under half Apple's 44pt minimum touch target — close
    /// enough that a finger aiming at the mark lands inside it, and far enough
    /// from the neighbouring round marks (which the scale never places nearer
    /// than the width of their own labels) that nothing else is swallowed.
    /// Erring large is the cheaper mistake: the exact count either side is a
    /// keystroke away in the number field, while a catch too small to feel
    /// leaves FR-6.4's "adopting it is moving the thumb onto the mark"
    /// impossible to actually do.
    static let albumSizeDetentReach: CGFloat = 12


    /// A photo is "nature" if any label in this allowlist meets the confidence threshold.
    /// Every entry is verified to exist in ClassifyImageRequest().supportedIdentifiers
    /// (1303 identifiers on this SDK; all lowercase, multi-word joined by underscores —
    /// e.g. "sunset_sunrise", NOT "sunset"/"sunrise").
    /// Tune from real library data via the ImageAnalyzer debug log of rejected labels.
    /// If false positives appear, the broad umbrella labels ("land", "water_body",
    /// "vegetation", "plant") are the first candidates to remove.
    static let natureLabels: Set<String> = [
        // Landforms
        "mountain", "hill", "cliff", "canyon", "cave", "desert",
        "sand_dune", "sand", "rocks", "island", "volcano", "lava",
        "geyser", "land",

        // Ice & snow
        "glacier", "iceberg", "ice", "snow",

        // Water features
        "ocean", "lake", "river", "creek", "waterfall", "water",
        "water_body", "waterways", "wetland", "shore", "beach",
        "coral_reef", "underwater",

        // Sky, celestial & weather
        "sky", "blue_sky", "cloudy", "night_sky", "aurora", "rainbow",
        "sun", "moon", "celestial_body", "celestial_body_other",
        "sunset_sunrise", "storm", "thunderstorm", "lightning",
        "blizzard", "haze",

        // Forest & vegetation
        "forest", "jungle", "tree", "evergreen", "palm_tree",
        "maple_tree", "oak_tree", "eucalyptus_tree", "sequoia",
        "willow", "mangrove", "foliage", "branch", "vegetation",
        "plant", "grass", "moss", "ferns", "shrub", "ivy", "clover",
        "cactus", "blossom", "wheat",

        // Flowers
        "flower", "rose", "tulip", "sunflower", "orchid", "lily",
        "daisy", "daffodil", "dahlia", "dandelion", "carnation",
        "chrysanthemum", "cornflower", "begonia", "petunia",
        "marigold", "snapdragon",

        // Scenic cultivated landscapes & trails
        "vineyard", "orchard", "rice_field", "trail",

        // Cityscapes & landmarks (FR-3.1 revision 2026-07-20)
        "cityscape", "skyscraper", "bridge", "castle", "lighthouse",
        "harbour", "monument", "belltower", "clock_tower",
    ]
}
