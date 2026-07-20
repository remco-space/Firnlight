import Foundation

/// Every tunable magic number in the app lives here.
/// `nonisolated`: plain constants, readable from any actor (the analysis pipeline runs off-main).
nonisolated enum Thresholds {
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

    // MARK: Vision analysis (Phase 3)

    /// Bump when analysis logic changes; records with an older version are re-analyzed.
    static let currentAnalysisVersion = 1

    /// Records analyzed and saved per batch; a killed app loses at most one batch.
    static let analysisBatchSize = 32

    /// Concurrent Vision pipelines within a batch.
    static let analysisConcurrency = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Long-edge size of the analysis bitmap requested from PHImageManager. Never analyze full-res.
    static let analysisPixelSize = 1024

    /// Minimum DetectHumanRectanglesRequest confidence that counts as a person.
    static let humanConfidenceThreshold: Float = 0.3

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
    /// replay all choices, re-rank everything.
    static let rankerAlgorithmVersion = 3 // v3: resolution feature added

    /// SGD learning rate for the online Bradley–Terry ranker.
    static let rankerLearningRate: Float = 0.5

    /// Without verdict calibration, duels draw from this top fraction of all
    /// candidates — wide, so "both bad" verdicts can find the quality floor.
    static let duelPoolFraction: Float = 0.75

    /// Duel pool never shrinks below this many photos.
    static let duelPoolMinimum = 200

    /// With calibration, the duel pool is everything scoring above
    /// (verdict bar − this margin): export candidates plus a probing band below.
    static let duelPoolScoreMargin: Float = 0.1

    /// Random pair samples per duel; the closest-scored valid pair wins (uncertainty sampling).
    static let duelPairSamples = 32

    /// Pseudo-choices per Photos favorite when seeding fresh ranker weights.
    static let favoriteSeedOpponents = 3

    /// Cap on total favorite pseudo-choices during seeding.
    static let favoriteSeedMaxPairs = 300

    /// Long-edge pixel size for duel images.
    static let duelImagePixelSize = 1024

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
    ]
}
