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
    static let currentAnalysisVersion = 3 // v3 analyzes the fixed desktopAspectRatio center crop

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

    /// Long-edge size of the analysis bitmap requested from PHImageManager. Never analyze full-res.
    static let analysisPixelSize = 1024

    /// Minimum DetectHumanRectanglesRequest confidence that counts as a person.
    static let humanConfidenceThreshold: Float = 0.3

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
    static let rankerAlgorithmVersion = 5 // v5: bad verdicts train the ranking

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

    /// A near-duplicate only displaces its cluster's kept image on levelness
    /// grounds when it is at least this much more level (degrees).
    static let duplicateTiltMargin: Float = 0.5

    // MARK: Wallpaper album (Phase 6)

    /// Name of the Photos album the app keeps in sync with top candidates.
    static let wallpaperAlbumName = "Alpenglow"

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
