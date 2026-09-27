import Accelerate
import Foundation
import SwiftData
import os

/// Batch logistic (Bradley–Terry) preference ranker over Vision feature prints.
///
/// Raw score: s = w·featurePrint + Σᵢ bᵢ·traitᵢ + Σₛ pₛ, over every
/// `ScalarTrait` — how the photo scored, how level it is, how many pixels it
/// has, when and where it was taken, how much of itself the wallpaper crop
/// discards and in which direction, how prominent a person, an animal and the
/// salient subject are, where that subject sits, how much foreground and
/// text cover the frame, and how bright and how vivid it reads — plus one
/// learned weight pₛ per named place at each of FR-5.14's five scales: the
/// exact town, landscape, region and country `PlaceHierarchy` names the
/// photo's location offline, plus — where the network allows — what Apple's
/// maps call the place, one more scale never folded into the other four
/// (see `PlaceHierarchy`'s doc comment for why). Every b and p weight is
/// learned from duels, never hard-coded: a
/// low-resolution, tilted, dim, seasonally atypical, or unfamiliar-place
/// photo is penalized — or favored — only as much as the user's choices
/// imply (FR-5.2). The scalar set is open by design and expected to grow;
/// `ScalarTrait` is where it lives and `traits(of:)` is where each is
/// measured. The place terms are deliberately not folded into that same set
/// — see `Weights.place`'s doc comment for why an open-ended set of exact
/// names doesn't fit a fixed-size parallel array the way scalar traits do.
///
/// Every trait is computed from the record alone — **never** from where it
/// falls in the current candidate set. That gives them all the same
/// library-independent, fixed scale: a calendar has 12 months, a globe has
/// 90° of latitude either way and 24 hours of rotation, and a bounding box
/// is already a fraction of its frame, so there is nothing here to tune.
/// This is deliberate, not merely simple: an earlier revision normalized
/// "when" against the oldest/newest dated photo in the live candidate set and
/// "where" against distance from that set's location centroid, both of which
/// silently rescaled every already-trained weight's effective meaning the
/// moment an ordinary library scan added one new extreme-dated or
/// off-centroid photo — reshuffling the whole ranking with zero new user
/// judgment behind it, which is exactly what FR-5.2 ("no trait counts for
/// more or less than the user's own decisions imply") forbids. A fixed scale
/// has no such moving target: the same photo always maps to the same trait
/// values, on every device, at every library size, so every learned weight
/// means the same thing for as long as it exists. A photo never measured for
/// a trait gets that trait's own no-information value (`ScalarTrait.neutral`)
/// rather than a penalty (FR-3.8), and `fitWeights`'s design matrix
/// additionally masks that column to 0 entirely for any duel where either
/// side lacks it, so an unmeasured trait never itself becomes a trained
/// signal, only ever a genuinely uninformative one.
/// Choice model: P(winner beats loser) = sigmoid(s_winner − s_loser).
///
/// The weights are a **batch MAP fit**, not one online step per choice: every
/// choice (and every pseudo-choice — the favorites seed and each bad verdict,
/// see below) is a term Σ c·softplus(−(s_winner − s_loser)) in one convex
/// objective (c = 1, except `Thresholds.rankerFavoriteSeedWeight` for a
/// favorite pseudo-choice), minimized in one shot by `fitWeights`'s L-BFGS solver, with an
/// L2 penalty pulling each of three parameter blocks (feature print, scalar
/// traits, place) toward its own prior — `initialScalarWeights`/0/0, FR-5.4's
/// opening guess — so an untrained weight starts exactly where it always has
/// and only moves as far as the accumulated evidence pulls it. This replaced
/// an earlier revision's online SGD (`Thresholds.rankerAlgorithmVersion`
/// v16 and before: one decayed gradient step per choice, in whatever order
/// the choices happened to arrive) after an offline study replaying a real
/// user's duels found that path overconfident (prequential log-loss 1.02,
/// worse than a coin flip) and order-dependent — swapping roughly a quarter
/// of a 200-photo album on one new duel — while the identical score function
/// fit in batch was neither: see `Thresholds.rankerAlgorithmVersion`'s v17
/// paragraph for the numbers. A **convex** objective has one global optimum
/// regardless of the order its terms are summed in or the point an L-BFGS
/// run starts iterating from, so this also *proves* FR-5.2/FR-7.1's "the
/// same library and the same judgments always produce the same ranking" —
/// weight decay's path-dependence was the previous revision's actual source
/// of order-sensitivity, and there is no decay here to be order-sensitive.
///
/// `PhotoRecord.preferenceScore` caches the raw score s after every fit so
/// the grid can re-rank live. A bad verdict ("Both Are Bad" / "Not Wallpaper
/// Material") is one pseudo-choice term against a fixed neutral reference
/// rather than a real opponent — see `appendBadVerdictTerm`
/// (FR-4.7/FR-5.7). A good verdict never touches these weights (deferred —
/// see REQUIREMENTS.md).
///
/// Weights persist as JSON in Application Support. If the file is missing (or
/// stale — see `Weights.algorithmVersion`), weights are rebuilt by seeding
/// from Photos favorites (pseudo-choices: favorite beats random
/// non-favorite) and then fitting every ChoiceRecord and bad VerdictRecord
/// term at once (FR-5.3) — order no longer matters (see above), so unlike
/// the SGD revision this replaced, the replay needs no interleaved
/// timestamp ordering across the two record kinds, only every term present.
/// Every later choice or verdict (`record`/`recordVerdicts`) appends one more
/// term to the same running set and re-fits, **warm-started** from the
/// current weights (`fitWeights(warmStart: true)`) purely so L-BFGS
/// converges in a handful of iterations instead of from a cold prior; being
/// convex, the fit lands on the exact same weights either way. A rebuild
/// always cold-starts from the prior (`fitWeights(warmStart: false)`), since
/// there is no previous fit of *this* term set to warm-start from.
/// Plain actor with its own `ModelContext`, not `@ModelActor`, so its work
/// truly runs off the main thread — see FeatureStore's doc comment for the
/// `DefaultSerialModelExecutor` caller-thread pitfall this avoids (FR-8.2).
/// One scalar trait the ranker weighs alongside the feature print.
///
/// FR-5.2 makes this set deliberately open — "whatever the app can measure is
/// a trait the user's choices may weigh, and it grows as the platform and the
/// app do". So the traits are enumerated here rather than written out
/// individually in the score, the weight decay, the gradient step and the
/// verdict reference: adding one is adding a case plus a line in
/// `traits(of:)`, and all four of those sites pick it up unchanged. The
/// shape this replaced needed six coordinated edits per trait and a matching
/// pair of stored properties on `Weights` — a cost that quietly argued
/// against ever measuring one more thing, which is the opposite of what the
/// requirement asks for.
///
/// Every trait is on a **fixed scale**: a photo maps to the same value on
/// every device at every library size, so a trained weight means the same
/// thing for as long as it exists. Nothing here may be normalized against the
/// current candidate set — see this actor's doc comment for the ranking
/// reshuffle that property exists to prevent.
///
/// `Int` raw values are the index into `Weights.scalars` and into
/// `TraitValues`, so **cases may be appended but never reordered or removed**
/// without a `Thresholds.rankerAlgorithmVersion` bump to force a rebuild.
nonisolated enum ScalarTrait: Int, CaseIterable, Sendable {
    /// Vision's aesthetics score, −1…1. The app's own opening reading of the
    /// photo (FR-5.4), and the only trait a bad verdict may move.
    case aesthetics
    /// 1 = level horizon or none visible, 0 = tilted at or past
    /// `Thresholds.horizonMaxTiltDegrees`.
    case levelness
    /// 0 at `Thresholds.minimumCandidatePixelWidth`, 1 at
    /// `Thresholds.resolutionFullScoreWidth`, log scale between.
    case resolution
    // FR-5.2's "when", as two harmonics of the calendar year rather than one
    // linear scalar — see `TraitValues.setCyclical` for why a quantity that
    // runs on a circle needs four features before it is learnable at all.
    case seasonCos
    case seasonSin
    case seasonCos2
    case seasonSin2
    // The first harmonic again, multiplied by sin(latitude). Seasons are a
    // hemisphere apart: day-of-year alone calls January winter, which is
    // wrong for half the planet, so a library spanning both teaches the
    // ranker nothing coherent. sin(latitude) flips sign across the equator,
    // and a sign flip on the first harmonic *is* a half-year phase shift, so
    // "local summer" becomes one preference the weights can state worldwide.
    // It fades to zero at the equator rather than jumping — which is true of
    // the thing itself, since equatorial regions have no thermal seasons.
    // The second harmonic needs no such partner: local phase is θ + π in the
    // south, so 2θ + 2π ≡ 2θ, hemisphere-invariant already.
    case localSeasonCos
    case localSeasonSin
    /// Latitude ÷ 90, −1…1 — FR-5.2's "where". See `traits(of:)` for why
    /// longitude is not its partner here.
    case latitude
    // How high the sun stood, on the compressed scale `sunElevationBasis`
    // builds — plus its square and cube, so the learned weights can put a
    // peak anywhere along it. A single weight could only say "lower is
    // better", which would rank deep night above golden hour; golden hour is
    // a band a few degrees above the horizon, and a band needs a basis.
    case sunElevation
    case sunElevation2
    case sunElevation3
    // Morning versus evening. Elevation is symmetric about solar noon, so a
    // sunrise and a sunset of identical height are one number to it; this
    // pair is the only thing that separates them.
    case solarTimeCos
    case solarTimeSin
    // Where the sun was relative to where the camera looked: cos is +1 shot
    // straight into the sun and −1 with the sun behind the photographer, sin
    // separates sun-left from sun-right. Backlit-at-low-sun and
    // front-lit-at-low-sun are different photographs, and without this the
    // ranker can only tell them apart through the feature print.
    case sunRelativeCos
    case sunRelativeSin
    /// Metres above sea level on a fixed scale — sea level to high alpine.
    case altitude
    /// When the photo was taken, on a fixed scale of calendar years.
    ///
    /// Absolute date, deliberately not age: age changes every day, so a
    /// ranking trained on it would drift with no new judgment behind it,
    /// breaking FR-5.2's "the same library and the same judgments always
    /// produce the same ranking". A fixed epoch carries the same preference
    /// — older photos over newer, or the reverse — and never moves.
    case captureEra
    // What Photos already knows the photo is. The scanner reads all of these
    // and used only `photoScreenshot`, as a gate; the rest are things known
    // about the picture, and so things the user's choices may weigh.
    case isPanorama
    case isHDR
    case isDepthEffect
    case isLivePhoto
    /// Fraction of the photo's area the fixed wallpaper crop discards, 0…1.
    /// FR-5.1 judges the crop, not the whole photo, so how much of itself a
    /// photo loses on the way there is a property of the photo the user may
    /// well have opinions about — panoramas lose most of themselves.
    case cropLoss
    /// Tallest person in the frame as a fraction of frame height, 0…1 —
    /// where inside the band FR-3.1 admits this photo falls.
    case personProminence
    /// Fraction of the frame the dominant salient region covers, 0…1.
    case subjectProminence
    /// How centred that region is — 1 at the frame's centre, 0 at a corner.
    case subjectCentrality
    /// Mean relative luminance, 0 (black) … 1 (white).
    case luminance
    /// Mean chroma, 0 (muted) … 1 (vivid).
    case colorfulness
    /// Fraction of the frame covered by segmented foreground objects, 0…1.
    /// Distinct from `subjectProminence`: saliency measures where attention
    /// goes, segmentation measures what is physically in front.
    case foregroundCoverage
    /// Distinct foreground objects, 0…1, saturating at
    /// `Thresholds.subjectCountFullScale`.
    case subjectCount
    /// Tallest recognized animal as a fraction of frame height, 0…1.
    case animalProminence
    /// Fraction of the frame covered by text regions, 0…1.
    case textCoverage
    /// Signed aspect mismatch, −1 (tall) … 0 (the wallpaper shape) … +1
    /// (wide), saturating at `Thresholds.aspectSkewFullScale`. Paired with
    /// `cropLoss` rather than replacing it: `cropLoss` is the magnitude of
    /// the mismatch and this is its direction, and a linear model needs both
    /// to express "any mismatch is worse" and "wide beats tall" at once —
    /// either alone can state only one of the two.
    case aspectSkew

    /// The value a photo takes on this trait when it was never measured for
    /// it (FR-3.8): the point on the trait's own scale that carries no
    /// information, so an unmeasured photo sits where "nothing is known"
    /// belongs rather than at one extreme. It is *only* a scoring
    /// placeholder — `fitWeights`'s design matrix additionally trains
    /// nothing on a trait either side is missing, so a gap never becomes a
    /// signal in its own right.
    var neutral: Float {
        switch self {
        // Zero-centred scales: their own midpoint is 0.
        case .aesthetics, .latitude, .captureEra,
             .seasonCos, .seasonSin, .seasonCos2, .seasonSin2,
             .localSeasonCos, .localSeasonSin,
             .solarTimeCos, .solarTimeSin, .sunRelativeCos, .sunRelativeSin: 0
        // Altitude's own zero is sea level, which is where a photo that says
        // nothing about its height may as well sit.
        case .altitude: 0
        // A basis expansion has no meaningful midpoint — its terms are not a
        // quantity but a shape. "Nothing known" means "no contribution", so
        // every term is 0 rather than the middle of its range.
        case .sunElevation, .sunElevation2, .sunElevation3: 0
        // "Nothing detected" already reads as level, so a missing horizon and
        // a level one are the same value — this is the one trait whose
        // no-information point is an end of its scale rather than its middle.
        case .levelness: 1
        // 0…1 scales: the midpoint.
        case .resolution, .cropLoss,
             .isPanorama, .isHDR, .isDepthEffect, .isLivePhoto,
             .personProminence, .subjectProminence, .subjectCentrality,
             .luminance, .colorfulness, .foregroundCoverage, .subjectCount,
             .animalProminence, .textCoverage: 0.5
        // Signed like `latitude`, so its no-information point is 0 — which
        // is also the wallpaper shape itself, the honest thing to assume of
        // a photo whose proportions are unknown.
        case .aspectSkew: 0
        }
    }

    /// Whether a bad verdict may move this trait's weight.
    ///
    /// Only `aesthetics`. A verdict has no opponent photo to contrast
    /// against, so it is no evidence that tilt, resolution, when, where, or
    /// how bright the photo is *caused* the badness — see
    /// `appendBadVerdictTerm`. Aesthetics is exempt because it is the app's own
    /// quality reading and 0 is a real neutral on its scale, so "worse than
    /// neutral quality" is a claim a verdict genuinely makes.
    var trainsOnVerdict: Bool { self == .aesthetics }
}

/// One photo's value for every `ScalarTrait`, parallel-indexed by raw value.
nonisolated struct TraitValues: Sendable {
    /// The trait's value, with `ScalarTrait.neutral` substituted wherever
    /// `known` is false.
    var values: [Float]
    /// False where this photo was never measured for the trait.
    var known: [Bool]

    static let neutral = TraitValues(
        values: ScalarTrait.allCases.map(\.neutral),
        known: ScalarTrait.allCases.map { _ in false }
    )

    subscript(trait: ScalarTrait) -> Float { values[trait.rawValue] }

    /// Sets a quantity that runs on a circle — time of year, an angle — as
    /// two harmonics: cos θ, sin θ, cos 2θ, sin 2θ, with θ a full turn of
    /// `fraction`.
    ///
    /// A cyclical quantity encoded as one linear scalar is not merely
    /// imprecise at the seam; it cannot state most preferences about itself.
    /// One weight over day-of-year says only "later in the year is better" or
    /// "earlier is better", because the contribution is monotonic in the
    /// value — so "summer and autumn, but not winter and spring" has no
    /// expression at all, and December and January land at opposite extremes
    /// while being adjacent. That makes the trait count for something other
    /// than what the user's decisions imply, which FR-5.2 does not allow.
    ///
    /// The first harmonic fixes it for any single-peaked preference:
    /// a·cos θ + b·sin θ is R·cos(θ − φ), one peak the weights may place
    /// anywhere on the circle, seamless everywhere. The second adds a
    /// two-peaked component at any phase. Together they cover one peak, two
    /// peaks, or a peak with a shoulder — the whole range of shapes a taste
    /// in "when" takes.
    mutating func setCyclical(
        _ traits: (ScalarTrait, ScalarTrait, ScalarTrait, ScalarTrait),
        turns fraction: Float?
    ) {
        guard let fraction else {
            for trait in [traits.0, traits.1, traits.2, traits.3] { set(trait, nil) }
            return
        }
        let angle = 2 * Float.pi * fraction
        set(traits.0, cos(angle))
        set(traits.1, sin(angle))
        set(traits.2, cos(2 * angle))
        set(traits.3, sin(2 * angle))
    }

    /// The first harmonic only, for an angle whose second harmonic would say
    /// nothing — a compass direction, where "twice the bearing" is not a
    /// quantity anyone has a taste about.
    mutating func setDirection(_ traits: (ScalarTrait, ScalarTrait), degrees: Double?) {
        guard let degrees else {
            set(traits.0, nil)
            set(traits.1, nil)
            return
        }
        let angle = Float(degrees) * .pi / 180
        set(traits.0, cos(angle))
        set(traits.1, sin(angle))
    }

    /// Sets a trait from an optional measurement, marking it unknown when the
    /// photo was never measured for it (FR-3.8).
    mutating func set(_ trait: ScalarTrait, _ measured: Float?) {
        if let measured {
            values[trait.rawValue] = measured
            known[trait.rawValue] = true
        } else {
            values[trait.rawValue] = trait.neutral
            known[trait.rawValue] = false
        }
    }
}

actor PreferenceRanker {
    private let modelContainer: ModelContainer
    // Lazy so the context is created by the actor's own executor on first
    // isolated access — an actor's init is nonisolated and runs on the
    // caller's (main) thread, and a ModelContext binds to the queue that
    // creates it. See FeatureStore's doc comment.
    private lazy var modelContext = ModelContext(modelContainer)

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    struct DuelPair: Sendable, Equatable {
        let first: Candidate
        let second: Candidate
    }

    /// A durable receipt for exactly the `ChoiceRecord` `record(winnerID:loserID:)`
    /// just wrote — the device-independent keys and the exact timestamp, not
    /// the local identifiers the pair was shown under. `undoLastChoice`
    /// matches on this triple rather than "the most recent choice for this
    /// pair" (see its doc comment for why that distinction matters, FR-5.12).
    struct ChoiceReceipt: Sendable, Equatable {
        let winnerKey: String
        let loserKey: String
        let timestamp: Date
    }

    /// The same durable receipt for exactly the `VerdictRecord`s
    /// `recordVerdicts` just wrote — every key it filed under, and the one
    /// timestamp they all share. `undoVerdicts` voids precisely these rows,
    /// which is what keeps an in-the-moment correction (FR-5.12) from
    /// touching any *other* verdict the same photos carry: see
    /// `VerdictRecord.isVoided` for what appending a clearing record instead
    /// would silently throw away.
    struct VerdictReceipt: Sendable, Equatable {
        let keys: [String]
        let isGood: Bool
        let timestamp: Date
    }

    /// FR-8.12: a control that offers Undo has to be honoring a judgment that
    /// was actually recorded. `record`/`recordVerdicts`/`undoLastChoice` throw
    /// these rather than silently doing nothing when a photo the caller named
    /// is no longer a live candidate (e.g. ignored elsewhere while the pair
    /// was on screen) or when the specific judgment being undone can't be
    /// found — the two ways a "no-op that reports success" used to happen.
    enum RankerError: LocalizedError {
        case candidateNotLive
        case nothingToUndo

        var errorDescription: String? {
            switch self {
            case .candidateNotLive:
                "That photo is no longer a candidate — it may have been ignored or marked elsewhere. Nothing was recorded."
            case .nothingToUndo:
                "There's nothing to undo — that judgment either wasn't recorded or has already been taken back."
            }
        }
    }

    /// Deterministic RNG (SplitMix64) so seeding a fresh weights file from the
    /// same favorites + choice history rebuilds the exact same ranking — the
    /// choices must be sufficient to reproduce it (FR-7.1).
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // FR-5.14's five-scale place hierarchy is `PlaceHierarchy.ScaleKeys` —
    // a real, published name per scale (a town, a landscape, a region, a
    // country, and — where the network allows — what Apple's maps call the
    // place), or nil at a scale with no answer — shared with `FeatureStore`
    // rather than declared again here, so both files resolve a photo's place
    // the exact same way (see `PlaceHierarchy.resolvedNames(for:)`).
    // `Weights.place` keys into this by exact name, never a hashed bucket —
    // see that field's doc comment for why: two unrelated places must never
    // collide into sharing a weight neither one's judgments produced
    // (FR-5.14's "never reaches another except through the larger places
    // both belong to").

    private struct Entry {
        /// PhotoKit's device-local identifier — what the UI and PhotoKit use.
        let id: String
        /// `PhotoRecord.judgmentKey` — what choices and verdicts are filed
        /// under, so a judgment made on another device lands on this photo
        /// (FR-9.1). Kept alongside `id` rather than replacing it: the ranker
        /// needs the local one to build `Candidate`s that PhotoKit can load.
        let key: String
        let vector: [Float]
        let isFavorite: Bool
        /// Every scalar trait this photo is weighed on — see `ScalarTrait`.
        let traits: TraitValues
        /// FR-5.14's five-scale place hierarchy — each scale independently
        /// nil where there's no answer for it. See `PlaceHierarchy.ScaleKeys`.
        let place: PlaceHierarchy.ScaleKeys
        var score: Float = 0 // raw, pre-sigmoid
        /// FR-4.6's "Not Wallpaper Material" toggle's current state, for the
        /// duel cards' overlay — whether this photo's *latest* verdict
        /// (FR-4.9) is bad. Populated once in `loadEntries()` from
        /// `VerdictCalibration.latestByPhoto`, not looked up per duel. There
        /// is no equivalent `isIgnored` field: `loadEntries()`'s own fetch
        /// predicate (`isNature && !isExcluded`) already keeps ignored
        /// photos out of `entries` entirely, so every `Entry` here is
        /// trivially not ignored — a duel could never serve one.
        var isNotWallpaperMaterial: Bool = false
    }

    /// One term of `fitWeights`'s objective: "winner" scores higher than
    /// "loser". Built from real `Entry`s for an ordinary choice, or from a
    /// synthetic `Entry` for a pseudo-choice (`appendFavoriteTerms`'s
    /// favorite-over-random-non-favorite, `appendBadVerdictTerm`'s
    /// neutral-reference-over-bad-photo) — the fit treats every term
    /// identically either way, which is exactly FR-5.7's "the same signal
    /// strength as losing a duel". Value type, holding its own copies of
    /// whatever `Entry` fields the fit reads: a term stays valid for the
    /// life of the ranker even after `loadEntries()` replaces `entries` with
    /// a fresh snapshot on the next `reload()`.
    private struct DuelTerm {
        let winner: Entry
        let loser: Entry
        /// How much this term counts in the objective: 1 for a real choice
        /// or a bad verdict, `Thresholds.rankerFavoriteSeedWeight` for a
        /// favorite pseudo-choice (see that constant for why a favorite is
        /// weaker evidence than a duel).
        var weight: Float = 1
    }

    /// Every term `fitWeights` minimizes over — the running set `prepare()`
    /// builds (seed favorites + every applicable choice + every applicable
    /// bad verdict) and `record`/`recordVerdicts` append one term to at a
    /// time. See this actor's own doc comment for why appending one term and
    /// re-fitting from here, rather than taking one online step, is what
    /// FR-5.2/FR-7.1's order-independence now rests on.
    private var trainingTerms: [DuelTerm] = []

    // An algorithmVersion mismatch (or undecodable file) triggers an automatic
    // rebuild: re-seed from current favorites + full choice replay + re-rank.
    private struct Weights: Codable {
        var algorithmVersion: Int = 1
        var feature: [Float]
        /// One coefficient per `ScalarTrait`, parallel-indexed by raw value.
        /// A file written against a different trait set decodes to a
        /// different count and is rebuilt — the same way an
        /// `algorithmVersion` mismatch is.
        var scalars: [Float]
        /// FR-5.14: one learned weight per place actually seen, keyed
        /// `"<scale>:<name>"` (see `PreferenceRanker.placeWeightKey`) — never
        /// a fixed-size table, so there is no bucket for two unrelated
        /// places to collide into (see `PlaceNames`'s doc comment). Missing
        /// keys read as 0 (an untrained place carries no preference, FR-5.2),
        /// so this only ever grows as new places are encountered; nothing
        /// here ever needs a count-mismatch check the way `scalars` does.
        var place: [String: Float]
        var seededWithFavorites: Bool
        /// How many judgments these weights already contain — see
        /// `applicableJudgmentCount`. Optional so weights written before this
        /// existed decode, and simply trigger one rebuild.
        var judgmentCount: Int?
        /// Fingerprint of the favorite set these weights were last fit
        /// against — see `favoriteFingerprint(of:)`. FR-5.4: "What the user has
        /// said [in Photos] is folded in whenever the app learns of it — a
        /// favorite found by a later scan counts the same as one found by the
        /// first." `prepare()` regenerates `appendFavoriteTerms()`'s
        /// pseudo-choices into `trainingTerms` on every call, but only a
        /// *rebuild* actually re-fits `weights` against them, so a change to
        /// the favorite set has to be detected the same way a change to the
        /// judgment set already is (`judgmentCount`) — by comparing against
        /// what these weights were built from — or a favorite discovered
        /// after the first rebuild would never be folded into the fit.
        /// Optional so weights written before this existed decode, and
        /// simply trigger one rebuild (favorites already folded into them
        /// get re-fit exactly the same way a version bump's full rebuild
        /// always does — deterministic, so this costs nothing new).
        var favoriteFingerprint: String?
        /// `PlaceGazetteer.dataFingerprint` these weights were last built
        /// against. The gazetteer's bundled data can change underneath an
        /// unchanged set of photos — `PlaceData/*.json` rebuilt, or the
        /// lookup logic itself changed in a new build — which changes what
        /// `placeWeightKey` computes for those photos at every scale
        /// (a differently-named or differently-bounded place is, for
        /// `Weights.place`'s purposes, a *different* place) — exactly the
        /// kind of understanding-change FR-5.2 says the app "re-examines...
        /// without costing the user a single judgment": without this check, a
        /// preference already learned under the old key would sit stranded
        /// there forever once the gazetteer data changes which key a photo's
        /// scores are read from and trained through. Optional for the same
        /// decode-safe reason `favoriteFingerprint` is.
        var gazetteerFingerprint: String?
        /// Fingerprint of every `PhotoRecord.networkPlaceName`/
        /// `networkPlaceResolved` pair these weights were last built
        /// against — see `networkFingerprint(of:)`. FR-5.14's fifth scale
        /// resolves *after* the photos it names are already being ranked
        /// (`PlaceNameLookup` runs in the background, at its own pace), so a
        /// resolution completing changes what `placeWeightKey(scale:
        /// "network", ...)` computes for the photos there — the same
        /// understanding-change reasoning `gazetteerFingerprint` documents,
        /// applied to a value that changes over the app's own lifetime
        /// rather than only across builds. Optional for the same
        /// decode-safe reason the others are.
        var networkFingerprint: String?
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "PreferenceRanker")

    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    /// `Entry.key` → index. The lookup every judgment goes through, since
    /// judgments are keyed device-independently while `indexByID` is local.
    private var indexByKey: [String: Int] = [:]
    private var weights = Weights(
        feature: [],
        scalars: PreferenceRanker.initialScalarWeights,
        place: [:],
        seededWithFavorites: false
    )

    /// Untrained coefficients: every trait at 0 except `aesthetics` at 1, so
    /// a library with no judgments at all is ordered by the app's own reading
    /// of the photos and nothing else — FR-5.4's "opening guess only, which
    /// anything the user then says fully supersedes".
    private static let initialScalarWeights: [Float] =
        ScalarTrait.allCases.map { $0 == .aesthetics ? 1 : 0 }
    private var judgedPairs: Set<String> = []
    private var isPrepared = false
    /// Set by `loadEntries()` on every call — see `Weights.gazetteerFingerprint`.
    private var currentGazetteerFingerprint = ""
    /// Set by `loadEntries()` on every call — see `Weights.networkFingerprint`.
    private var currentNetworkFingerprint = ""

    /// Debounced preference-cache flush state (see `scheduleCacheFlush`).
    private var flushTask: Task<Void, Never>?
    private var unflushedChoices = 0

    private(set) var choiceCount = 0

    // MARK: Lifecycle

    /// Loads candidate vectors, then loads — or rebuilds — the weights, and
    /// refreshes the preference-score cache.
    func prepare() throws {
        guard !isPrepared else { return }

        loadEntries()

        let choices = try loadJudgedPairsAndCount()
        // `trainingBadVerdicts` — not a plain `!$0.isGood` filter — so a bad
        // verdict that has since been cleared (FR-4.6/FR-4.7) drops out of
        // both the replay and `applicableJudgmentCount` together; see its
        // doc comment for why leaving the verdict out of the replay is the
        // only way to un-apply the SGD step it once took.
        let badVerdicts = VerdictCalibration.trainingBadVerdicts(try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        ))
        let applicable = applicableJudgmentCount(choices: choices, badVerdicts: badVerdicts)
        let currentFavorites = Self.favoriteFingerprint(of: entries)

        let dimension = entries.first?.vector.count ?? 0

        // Every term `fitWeights` minimizes over, rebuilt from scratch here
        // regardless of whether the stored weights below turn out to still
        // be valid: an incremental `record`/`recordVerdicts` call needs the
        // full running set to append one more term to and re-fit, not just
        // whichever weights happened to load. Order doesn't matter — the
        // fit is convex, see this actor's own doc comment — so favorites,
        // choices and bad verdicts are simply appended one group at a time,
        // unlike the SGD revision this replaced, which needed them
        // interleaved in the exact timestamp order the user produced them.
        trainingTerms = []
        let seededPairs = appendFavoriteTerms()
        for choice in choices {
            appendChoiceTerm(winnerKey: choice.winnerKey, loserKey: choice.loserKey)
        }
        for badVerdict in badVerdicts {
            appendBadVerdictTerm(key: badVerdict.photoKey)
        }

        if let stored = loadWeights(),
           stored.algorithmVersion == Thresholds.rankerAlgorithmVersion,
           stored.feature.count == dimension,
           stored.scalars.count == ScalarTrait.allCases.count,
           stored.judgmentCount == applicable,
           stored.favoriteFingerprint == currentFavorites,
           stored.gazetteerFingerprint == currentGazetteerFingerprint,
           stored.networkFingerprint == currentNetworkFingerprint {
            weights = stored
        } else {
            weights = Weights(
                algorithmVersion: Thresholds.rankerAlgorithmVersion,
                feature: Array(repeating: 0, count: dimension),
                scalars: Self.initialScalarWeights,
                place: [:],
                seededWithFavorites: true,
                judgmentCount: applicable,
                favoriteFingerprint: currentFavorites,
                gazetteerFingerprint: currentGazetteerFingerprint,
                networkFingerprint: currentNetworkFingerprint
            )
            let elapsed = fitWeights(warmStart: false)
            saveWeights()
            Self.log.info("Rebuilt weights: seeded \(seededPairs) favorite pseudo-choices, fit \(choices.count) choices + \(badVerdicts.count) bad verdicts (\(self.trainingTerms.count) terms) in \(elapsed.milliseconds, format: .fixed(precision: 1))ms, \(elapsed.iterations) L-BFGS iterations")
        }

        recomputeScores()
        try writePreferenceCache()
        isPrepared = true
    }

    /// Refreshes the candidate snapshot from the store (new scans, exclusions)
    /// and rescores against the already-loaded weights, so the duel screen sees
    /// current photos without a relaunch. Prepares from scratch if not yet done.
    func reload() throws {
        guard isPrepared else { try prepare(); return }
        loadEntries()

        // Judgments are re-read, not assumed unchanged: a scan may have just
        // brought in photos whose choices were already recorded (FR-9.2), and
        // `judgedPairs` decides which pairs the duel refuses to re-ask
        // (FR-5.5) while `choiceCount` is what the Duel tab displays (FR-5.8).
        let choices = try loadJudgedPairsAndCount()
        // Same `trainingBadVerdicts` replay-set as `prepare()` — see there.
        let badVerdicts = VerdictCalibration.trainingBadVerdicts(try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        ))

        // If the set of judgments that *apply here* changed, the weights no
        // longer contain what the user has decided, and only a full rebuild
        // can fold the difference in: unlike `record`/`recordVerdicts`, this
        // path has no specific new term to append and warm-start-refit —
        // judgments synced in from another device (FR-9.2) or a photo
        // newly arriving change *which* terms `trainingTerms` should hold,
        // not just add one more, so `trainingTerms` has to be rebuilt from
        // the current judgment set from scratch, same as a version bump.
        //
        // Same for the favorite set (FR-5.4): `appendFavoriteTerms()`'s
        // pseudo-choices only get re-fit into `weights` as part of a
        // rebuild (see `Weights.favoriteFingerprint`'s doc comment), so a
        // favorite Photos discovers after the weights were last built — or
        // one a rescan un-favorites — needs the same rebuild trigger
        // `judgmentCount` already gives explicit choices, or it would never
        // be folded in (or un-folded) at all.
        // Third trigger, same reasoning as the two above: the gazetteer's
        // own bundled data changing changes what `placeWeightKey` computes
        // for the photos there (see `Weights.gazetteerFingerprint`'s doc
        // comment), so a preference already learned under the superseded
        // key must be replayed onto the current one rather than left behind.
        // Fourth, same reasoning again: `PlaceNameLookup` resolving a place's
        // name changes what `placeWeightKey(scale: "network", ...)`
        // computes for the photos there (see `Weights.networkFingerprint`'s
        // doc comment).
        if weights.judgmentCount != applicableJudgmentCount(choices: choices, badVerdicts: badVerdicts)
            || weights.favoriteFingerprint != Self.favoriteFingerprint(of: entries)
            || weights.gazetteerFingerprint != currentGazetteerFingerprint
            || weights.networkFingerprint != currentNetworkFingerprint {
            isPrepared = false
            try prepare()
            return
        }

        recomputeScores()
        // A reload is a flush boundary: any pending debounced write is folded
        // into this synchronous one, so callers that read the cache right after
        // a reload (FeatureStore.rankedCandidates/albumCandidates/…) never see
        // scores older than the last choice.
        cancelPendingFlush()
        try writePreferenceCache()
    }

    /// True while both photos of a served pair are still live candidates.
    func contains(_ pair: DuelPair) -> Bool {
        indexByID[pair.first.localIdentifier] != nil
            && indexByID[pair.second.localIdentifier] != nil
    }

    /// Reconstructs a `DuelPair` from two persisted local identifiers — used
    /// to resume the exact pair the user was looking at on the previous
    /// launch (FR-8.1). Returns nil if either photo is no longer a live
    /// candidate (deleted, edited out, ignored, etc.), if the pair was
    /// already judged — a choice can persist before the next pair's
    /// identifiers do (process death in the window between them), and
    /// re-serving a judged pair would double-count its SGD step — or if the
    /// two identifiers are the same photo: the persisted state is meant to
    /// name two distinct candidates, and corrupted resume state (a process
    /// kill between the two `UserDefaults` writes that used to back this,
    /// leaving one stale ID under both keys) must not hand back a same-photo
    /// pair (FR-5.1's "shown two photos"). In every one of these cases the
    /// caller falls back to `nextPair()` as if this were a fresh start.
    func pair(first: String, second: String) -> DuelPair? {
        guard first != second,
              let firstIndex = indexByID[first], let secondIndex = indexByID[second],
              // `judgedPairs` is keyed by `judgmentKey`, not by local
              // identifier (FR-9.2 files judgments under the cloud-stable
              // key), so the resumed identifiers must be translated before
              // the set can answer "was this pair already judged?".
              !judgedPairs.contains(Self.pairKey(entries[firstIndex].key, entries[secondIndex].key)) else {
            return nil
        }
        return DuelPair(first: candidate(for: entries[firstIndex]), second: candidate(for: entries[secondIndex]))
    }

    /// Loads every choice in timestamp order, refreshing the judged-pair set
    /// (FR-5.5) and the displayed count (FR-5.8). Returns them so the caller
    /// can also use them for training and the applicable-count check.
    @discardableResult
    private func loadJudgedPairsAndCount() throws -> [ChoiceRecord] {
        // A voided choice (FR-5.12) is excluded here, not just from training:
        // it must also drop out of `judgedPairs` so the pair it named becomes
        // askable again, exactly as if it had never been judged.
        let choices = try modelContext.fetch(
            FetchDescriptor<ChoiceRecord>(
                predicate: #Predicate { !$0.isVoided },
                sortBy: [SortDescriptor(\.timestamp)]
            )
        )
        judgedPairs = Set(choices.map { Self.pairKey($0.winnerKey, $0.loserKey) })
        choiceCount = choices.count
        return choices
    }

    /// Fetches the current nature, non-excluded candidates into `entries` and
    /// rebuilds `indexByID`. Weights are untouched.
    ///
    /// Restricted to the serving analysis generation — FR-5.2's "photos are
    /// always compared on equal terms: no ranking or duel sets a photo
    /// examined the app's current way against one still examined an older way
    /// as though they had been examined alike." A record whose
    /// `featurePrint`/`aestheticsScore`/etc. were extracted under a different
    /// Vision pipeline isn't on the same footing as one examined the serving
    /// generation's way — their feature vectors aren't dot-product-comparable
    /// — so it simply sits out of ranking and duels until `AnalysisQueue`'s
    /// background pass re-examines it (FR-3.8, FR-3.5), at which point it
    /// rejoins on equal terms. This costs the user no judgment: choices
    /// already recorded about it stay durable (FR-5.3) and take effect via
    /// `applicableJudgmentCount`'s rebuild trigger once the photo is back in
    /// `entries`.
    ///
    /// The serving generation is `Thresholds.currentAnalysisVersion` in every
    /// ordinary case, and the previous one only while a re-examination is
    /// still less complete than what it is replacing — see
    /// `AnalysisGeneration`, which is also why this reads it per call instead
    /// of holding onto it: the ranker, grid, calibration and album all derive
    /// it from the same rows, so they hand over together.
    private func loadEntries() {
        let version = AnalysisGeneration.servingVersion(in: modelContext)
        // Sorted by identifier so the deterministic favorite seeding never
        // depends on SwiftData's unspecified default fetch order.
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion == version }
        )
        descriptor.sortBy = [SortDescriptor(\.localIdentifier)]
        let records = (try? modelContext.fetch(descriptor)) ?? []
        let minWidth = Float(Thresholds.minimumCandidatePixelWidth)
        let resolutionRange = log2(Thresholds.resolutionFullScoreWidth / minWidth)

        // Fetched once here, not per entry, for the same reason
        // `FeatureStore.latestBadVerdictKeys()` is fetched once per query
        // rather than per candidate (FR-8.2).
        let badVerdictKeys: Set<String> = {
            let verdicts = (try? modelContext.fetch(
                FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
            )) ?? []
            let latest = VerdictCalibration.latestByPhoto(verdicts)
            return Set(latest.compactMap { key, isGood in isGood ? nil : key })
        }()
        // `currentGazetteerFingerprint` is what `prepare()`/`reload()` diff
        // against `Weights.gazetteerFingerprint` to notice the gazetteer's
        // own bundled data changing since the weights were last built (see
        // that field's doc comment). Cheap: `PlaceGazetteer.dataFingerprint`
        // is computed once and cached (`static let`), not recomputed here.
        currentGazetteerFingerprint = PlaceGazetteer.dataFingerprint
        // `currentNetworkFingerprint` is the same idea for FR-5.14's fifth
        // scale — built from `records` (already fetched above, sorted by
        // `localIdentifier` for the same determinism `favoriteFingerprint`
        // needs), not a separate `PlaceNameRecord` fetch: the network name
        // ranking actually reads is cached directly on `PhotoRecord`
        // (`networkPlaceName`), so that is what has to be fingerprinted.
        currentNetworkFingerprint = Self.networkFingerprint(of: records)

        entries = records.compactMap { record in
            guard let data = record.featurePrint else { return nil }
            return Entry(
                id: record.localIdentifier,
                key: record.judgmentKey,
                vector: data.floatVector,
                isFavorite: record.isFavorite,
                traits: Self.traits(of: record, minWidth: minWidth, resolutionRange: resolutionRange),
                place: PlaceHierarchy.resolvedNames(for: record),
                isNotWallpaperMaterial: badVerdictKeys.contains(record.judgmentKey)
            )
        }
        indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: two photos can
        // share a judgment key if neither resolved to a cloud identifier and
        // PhotoKit handed back the same local one, which would trap. Keeping
        // the first is arbitrary but safe — the alternative is a crash.
        indexByKey = Dictionary(entries.enumerated().map { ($0.element.key, $0.offset) },
                                uniquingKeysWith: { first, _ in first })
    }

    /// How many stored judgments actually apply to the photos on *this*
    /// device — the count folded into `Weights.judgmentCount`.
    ///
    /// This is the mechanism behind FR-9.2. A choice about a photo that hasn't
    /// arrived here yet trains nothing, because `appendChoiceTerm` can't find
    /// it; when the photo does arrive, the count changes and `prepare()`/`reload()`
    /// rebuild so the judgment finally takes effect. It moves for every reason
    /// it should — a photo arriving or leaving, judgments synced in from
    /// another device — and a local `record()` bumps it in step, so the
    /// incremental path never triggers a spurious rebuild.
    private func applicableJudgmentCount(choices: [ChoiceRecord], badVerdicts: [VerdictRecord]) -> Int {
        let applicableChoices = choices.count {
            indexByKey[$0.winnerKey] != nil && indexByKey[$0.loserKey] != nil
        }
        let applicableVerdicts = badVerdicts.count { indexByKey[$0.photoKey] != nil }
        return applicableChoices + applicableVerdicts
    }

    // MARK: Duels

    /// Uncertainty sampling: from the adaptive duel pool, pick the
    /// closest-scored sampled pair that isn't near-duplicate and hasn't been
    /// judged before. Sides are shuffled to avoid position bias.
    func nextPair() -> DuelPair? {
        let pool = duelPool()
        guard pool.count >= 2 else { return nil }

        let thresholdSquared = Thresholds.nearDuplicateDistance * Thresholds.nearDuplicateDistance
        var best: (first: Entry, second: Entry, delta: Float)?

        for _ in 0..<Thresholds.duelPairSamples {
            let i = pool.indices.randomElement()!
            let j = pool.indices.randomElement()!
            guard i != j else { continue }
            let a = pool[i], b = pool[j]

            guard !judgedPairs.contains(Self.pairKey(a.key, b.key)) else { continue }
            guard vDSP.distanceSquared(a.vector, b.vector) >= thresholdSquared else { continue }

            let delta = abs(a.score - b.score)
            if best == nil || delta < best!.delta {
                best = (a, b, delta)
            }
        }

        // All samples judged or near-duplicates: fall back to the first
        // still-unjudged, non-near-duplicate pair — the same two guards the
        // sampling loop above applies, so a small pool can't degrade into
        // serving a visually-identical pair just because the fallback found
        // it before a properly-distinct one (FR-5.5). Re-serving a judged
        // pair would double-count its SGD step. If every remaining pair is
        // judged or near-duplicate, return nil (view has an empty state).
        if best == nil {
            let shuffled = pool.shuffled()
            outer: for i in shuffled.indices {
                for j in shuffled.indices[(i + 1)...] {
                    guard !judgedPairs.contains(Self.pairKey(shuffled[i].key, shuffled[j].key)) else { continue }
                    guard vDSP.distanceSquared(shuffled[i].vector, shuffled[j].vector) >= thresholdSquared else { continue }
                    best = (shuffled[i], shuffled[j], 0)
                    break outer
                }
            }
        }

        guard let best else { return nil }
        let sides = Bool.random() ? (best.first, best.second) : (best.second, best.first)
        return DuelPair(first: candidate(for: sides.0), second: candidate(for: sides.1))
    }

    /// Adaptive duel pool — always wider than the export set.
    ///
    /// Uncalibrated: the top `duelPoolFraction` of all candidates, so verdicts
    /// can locate the quality floor. Calibrated: everything above
    /// (verdict bar − margin), i.e. export candidates plus a probing band
    /// below the cutoff — narrowing over time as the bar firms up.
    private func duelPool() -> [Entry] {
        let sorted = entries.sorted { $0.score > $1.score }
        let fractionCount = max(2, Int(Float(sorted.count) * Thresholds.duelPoolFraction))

        guard let bar = try? verdictBar() else {
            return Array(sorted.prefix(fractionCount))
        }
        let cut = bar - Thresholds.duelPoolScoreMargin
        let aboveCut = sorted.prefix { $0.score > cut }.count
        let bounded = min(max(aboveCut, Thresholds.duelPoolMinimum), fractionCount)
        return Array(sorted.prefix(bounded))
    }

    /// The quality bar from "both great"/"both bad" verdicts: the raw preference
    /// score that best separates good from bad. Nil until enough bad verdicts.
    private func verdictBar() throws -> Float? {
        let verdicts = try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        guard !verdicts.isEmpty else { return nil }

        let latest = VerdictCalibration.latestByPhoto(verdicts)
        var good: [Float] = []
        var bad: [Float] = []
        for (key, isGood) in latest {
            guard let index = indexByKey[key] else { continue }
            let score = entries[index].score
            if isGood { good.append(score) } else { bad.append(score) }
        }
        guard bad.count >= Thresholds.albumCalibrationMinimumBadVerdicts else { return nil }

        return VerdictCalibration.optimalSplitThreshold(good: good, bad: bad)
    }

    /// Records absolute quality verdicts ("both great"/"both bad" from a
    /// duel, or a single-photo "Not Wallpaper Material") — always durable
    /// and always feeding the album-size calibration (FR-6.x). A BAD verdict
    /// additionally trains the pairwise ranking, the same signal strength as
    /// losing a duel (FR-4.7/FR-5.7): see `appendBadVerdictTerm`. A GOOD
    /// verdict never touches ranking weights — good photos already rise by
    /// winning duels, and using "good" as an upward signal is explicitly
    /// deferred (REQUIREMENTS.md Deferred ideas).
    ///
    /// `flushSynchronously` controls how the (bad-verdict) score cache write
    /// is scheduled, same tradeoff as `record()`'s doc comment:
    /// - `false` (default, used by the Duel tab's long-lived ranker): debounce
    ///   via `scheduleCacheFlush`, so a burst of rapid "Both Are Bad" verdicts
    ///   coalesces into one write instead of beachballing (FR-8.2).
    /// - `true` (used by `CandidateActions.markNotWallpaperMaterial`'s
    ///   short-lived, one-off ranker instance): flush immediately via
    ///   `flushCacheNow`. That ranker has no owner once this call returns —
    ///   `scheduleCacheFlush`'s idle timer captures `self` weakly and would
    ///   fire into a `nil` self after the actor's already been deallocated,
    ///   so `PhotoRecord.preferenceScore` would never be rewritten and
    ///   `RankingClock` would never bump, leaving the grid/Export stale until
    ///   the next relaunch. A single grid click writing once is not the rapid
    ///   dueling case FR-8.2 guards against, so flushing it synchronously is
    ///   safe.
    @discardableResult
    func recordVerdicts(_ localIdentifiers: [String], isGood: Bool, flushSynchronously: Bool = false) throws -> VerdictReceipt {
        let now = Date()
        // Callers hand over local identifiers (that is what the UI and
        // PhotoKit deal in); the verdict is filed under the device-independent
        // key so it counts on every device (FR-9.1). All-or-nothing: a
        // `compactMap` here used to drop whichever identifiers no longer
        // resolved and silently record a verdict for only the rest — the
        // "Both Are Great"/"Both Are Bad" buttons say they judge the whole
        // pair, so a caller (`DuelModel.judgeBoth`) that treats a
        // non-throwing return as "the pair was judged" and offers Undo on
        // that basis needs the guarantee to actually be all or nothing
        // (FR-8.12).
        let keys = try localIdentifiers.map { id -> String in
            guard let index = indexByID[id] else { throw RankerError.candidateNotLive }
            return entries[index].key
        }
        for key in keys {
            modelContext.insert(VerdictRecord(photoKey: key, isGood: isGood, timestamp: now))
        }
        try modelContext.save()
        let receipt = VerdictReceipt(keys: keys, isGood: isGood, timestamp: now)

        guard !isGood else { return receipt }
        for key in keys where appendBadVerdictTerm(key: key) {
            weights.judgmentCount = (weights.judgmentCount ?? 0) + 1
        }
        let elapsed = fitWeights(warmStart: true)
        Self.log.debug("Fit weights after \(keys.count) bad verdict(s): \(self.trainingTerms.count) terms, \(elapsed.milliseconds, format: .fixed(precision: 1))ms, \(elapsed.iterations) L-BFGS iterations")
        saveWeights()
        recomputeScores()
        if flushSynchronously {
            flushCacheNow()
        } else {
            scheduleCacheFlush()
        }
        return receipt
    }

    /// FR-4.6's toggle un-doing a bad verdict, and FR-4.7's "return to normal
    /// standing" more generally: appends a clearing `VerdictRecord`
    /// (`isCleared: true`) per photo rather than deleting the bad one it
    /// retires — append-only, device-portable, last-write-wins, the same
    /// reasoning `IgnoreRecord`'s doc comment gives for why a toggle has to
    /// resolve this way (two devices toggling apart must land on whichever
    /// the user did last, and only an added row can express that against a
    /// racing sync).
    ///
    /// Unlike `recordVerdicts`, this cannot just append one more pseudo-term
    /// and warm-start-refit: the fit is convex, so it *could* in principle
    /// re-fit against `trainingTerms` minus this photo's bad-verdict term,
    /// but nothing here tracks which array index that term is, and rebuilding
    /// that mapping is no simpler than just rebuilding the whole set — so
    /// this forces exactly the rebuild path a version bump or an arriving
    /// synced judgment already takes — `isPrepared = false` then `prepare()`,
    /// which reloads entries, rebuilds `trainingTerms` from every judgment
    /// still applicable (`VerdictCalibration.trainingBadVerdicts` now
    /// excludes this photo's bad verdicts, having seen the clearing record),
    /// cold-refits, saves weights, recomputes scores and rewrites the
    /// preference cache. A full re-fit is real cost, but it is paid only
    /// here: clearing is a rare, deliberate, single-photo action, not the
    /// rapid per-choice duel path FR-8.2 guards (`record`'s debounced cache
    /// flush) — and being convex, this cold re-fit lands on exactly the
    /// weights a warm-started one would have (FR-5.2/FR-7.1).
    ///
    /// There is deliberately no `flushSynchronously` parameter, unlike
    /// `recordVerdicts`: that one exists because a short-lived, one-off
    /// ranker has no owner left once the call returns, so a *debounced*
    /// write's weakly captured `self` would never fire. Here `prepare()`
    /// above already writes the whole cache synchronously — it has no
    /// debounce path at all — so there is nothing left to schedule either
    /// way, and a parameter that changed nothing would only mislead.
    ///
    /// This does NOT route the follow-up notification through
    /// `flushCacheNow`/`scheduleCacheFlush` themselves, unlike
    /// `recordVerdicts`: those coalesce per-choice writes and bump
    /// `RankingClock` only when `writePreferenceCache` finds a row that
    /// actually moved — but `prepare()` just wrote the full cache as its
    /// last step, so every row is already current and a follow-up
    /// `flushCacheNow` would find nothing changed and skip the bump,
    /// silently stranding the grid/Export on stale scores despite the
    /// rebuild having happened. So the bump is unconditional here, the same
    /// rebuild-then-bump pairing `AnalysisView`'s one-off `prepare()` call
    /// already uses.
    ///
    /// All-or-nothing, like `recordVerdicts`: a `compactMap` here used to
    /// silently drop whichever identifier no longer resolved (e.g. ignored
    /// elsewhere since the verdict was given) and clear only the rest,
    /// reporting full success either way. For the Duel tab's Undo of a
    /// "Both Are Great"/"Both Are Bad" verdict that's a correction left half
    /// done while claiming to be whole — the opposite of FR-5.12's "outcome
    /// as if the corrected judgment had always been the one given" — so this
    /// now throws `RankerError.candidateNotLive` and clears nothing rather
    /// than clearing one photo's verdict and silently leaving the other's in
    /// force (FR-8.12).
    func clearVerdicts(_ localIdentifiers: [String]) throws {
        let now = Date()
        let keys = try localIdentifiers.map { id -> String in
            guard let index = indexByID[id] else { throw RankerError.candidateNotLive }
            return entries[index].key
        }
        for key in keys {
            modelContext.insert(VerdictRecord(photoKey: key, isGood: false, isCleared: true, timestamp: now))
        }
        try modelContext.save()

        isPrepared = false
        try prepare()

        Task { @MainActor in RankingClock.shared.bump() }
    }

    /// Records a choice, takes one SGD step, and updates the in-memory scores.
    ///
    /// The choice itself is durable, rebuild-critical state (FR-5.3/FR-7.1), so
    /// its `ChoiceRecord` is saved synchronously — a crash never loses a
    /// judgment. The heavy part — rewriting every `PhotoRecord.preferenceScore`
    /// and saving — is only a denormalized cache (replayable from the choices in
    /// prepare()), so it is *not* done here per choice; that per-choice full
    /// write is what beachballed the UI (FR-8.2). Instead the new scores live in
    /// `entries` immediately and the store cache is flushed on a debounce (see
    /// `scheduleCacheFlush`). Weights are re-fit synchronously
    /// (`fitWeights(warmStart: true)`, warm-started from the weights this
    /// choice is being added to) and then a small file write — this actor's
    /// own doc comment measures that fit in the tens of milliseconds, well
    /// inside FR-8.2's budget for a synchronous step on this off-main actor.
    ///
    /// Throws `RankerError.candidateNotLive` — never silently records nothing
    /// — if either photo has stopped being a live candidate since the pair
    /// was drawn (e.g. ignored elsewhere while it sat on screen): a caller
    /// that can't tell a real write from a no-op would otherwise go on to
    /// offer Undo for a choice that was never taken (FR-8.12). Returns a
    /// `ChoiceReceipt` naming exactly the row just written, which
    /// `undoLastChoice` needs to undo this exact choice rather than guessing
    /// which of possibly several past choices for the same pair is meant
    /// (FR-5.12).
    @discardableResult
    func record(winnerID: String, loserID: String) throws -> ChoiceReceipt {
        // Local identifiers in (from the duel cards), device-independent keys
        // stored (FR-9.1). A photo with no entry can't have been dueled.
        guard let winnerKey = indexByID[winnerID].map({ entries[$0].key }),
              let loserKey = indexByID[loserID].map({ entries[$0].key }) else {
            throw RankerError.candidateNotLive
        }

        let timestamp = Date()
        modelContext.insert(ChoiceRecord(winnerKey: winnerKey, loserKey: loserKey, timestamp: timestamp))
        try modelContext.save()
        judgedPairs.insert(Self.pairKey(winnerKey, loserKey))

        appendChoiceTerm(winnerKey: winnerKey, loserKey: loserKey)
        choiceCount += 1
        // Kept in step with the weights so the next reload doesn't mistake
        // this incremental step for a divergence and rebuild needlessly.
        weights.judgmentCount = (weights.judgmentCount ?? 0) + 1
        let elapsed = fitWeights(warmStart: true)
        Self.log.debug("Fit weights after 1 choice: \(self.trainingTerms.count) terms, \(elapsed.milliseconds, format: .fixed(precision: 1))ms, \(elapsed.iterations) L-BFGS iterations")
        saveWeights()

        recomputeScores()
        scheduleCacheFlush()
        return ChoiceReceipt(winnerKey: winnerKey, loserKey: loserKey, timestamp: timestamp)
    }

    /// FR-5.12: reverses exactly the `record()` call that produced `receipt`
    /// — the Duel tab's "Undo" button, offered right after a choice and
    /// nowhere else, since a raw pairwise choice has no persistent visible
    /// mark anywhere else in the app for a later toggle to correct (unlike
    /// "Not Wallpaper Material"/"Ignore This Photo", which stay visible in the
    /// Library tab and are already correctable there per FR-4.6).
    ///
    /// Matches the `ChoiceRecord` by `receipt`'s winner key, loser key AND
    /// timestamp — not by "the most recent non-voided choice for this pair",
    /// which this used to do. That was wrong whenever the choice `record()`
    /// just returned to the caller didn't actually exist: if the photo had
    /// meanwhile stopped being a live candidate, `record()` threw and wrote
    /// nothing, but a caller that didn't check would still offer Undo — and
    /// pressing it, hunting only by pair, would happily void an earlier,
    /// wholly unrelated legitimate choice for the same two photos, or find
    /// none and silently do nothing while reporting success either way. Now
    /// undoing something that was never recorded throws
    /// `RankerError.nothingToUndo` instead of guessing (FR-8.12).
    ///
    /// Voids the matching `ChoiceRecord` in place (see its doc comment) rather
    /// than deleting it — an append-only ledger, like every other judgment
    /// here — then forces the same full rebuild `clearVerdicts` already takes:
    /// see that method's doc comment for why leaving the voided choice's
    /// term out of a fresh `prepare()` is simpler than surgically removing
    /// it from `trainingTerms`, even though the fit itself is convex.
    func undoLastChoice(_ receipt: ChoiceReceipt) throws {
        let winnerKey = receipt.winnerKey
        let loserKey = receipt.loserKey
        let timestamp = receipt.timestamp
        let descriptor = FetchDescriptor<ChoiceRecord>(
            predicate: #Predicate {
                $0.winnerKey == winnerKey && $0.loserKey == loserKey
                    && $0.timestamp == timestamp && !$0.isVoided
            }
        )
        guard let match = try modelContext.fetch(descriptor).first else {
            throw RankerError.nothingToUndo
        }
        match.isVoided = true
        try modelContext.save()

        isPrepared = false
        try prepare()

        Task { @MainActor in RankingClock.shared.bump() }
    }

    /// FR-5.12 for "Both Are Great"/"Both Are Bad": reverses exactly the
    /// `recordVerdicts` call that produced `receipt` — the Duel tab's Undo,
    /// offered in the moment right after the verdict.
    ///
    /// Deliberately not `clearVerdicts`, which this used to call. Clearing is
    /// FR-4.6's toggle and speaks about the photo's whole standing: it retires
    /// every bad verdict the photo carries, from any surface and any device.
    /// Undo speaks about one judgment. A photo already marked Not Wallpaper
    /// Material in the Library, then given a slipped "Both Are Great" here,
    /// would have come out of the Undo *unmarked* — a judgment the user never
    /// took back, dropped as a side effect of correcting a different one, and
    /// the opposite of FR-5.12's "outcome as if the corrected judgment had
    /// always been the one given". Voiding precisely the rows the receipt
    /// names leaves everything else the photo stands for exactly where it was.
    ///
    /// All-or-nothing, and matched on the receipt's own triple (keys, verdict
    /// side, timestamp) rather than "the photo's most recent verdict", for the
    /// same reasons `undoLastChoice` documents: a receipt for rows that aren't
    /// there — never written, or already voided — throws
    /// `RankerError.nothingToUndo` instead of quietly voiding some other
    /// verdict, or nothing at all while reporting success (FR-8.12).
    ///
    /// Forces the same full rebuild as `undoLastChoice`/`clearVerdicts`, for
    /// the same reason `clearVerdicts` documents. A *good* verdict trains
    /// nothing and would need no re-fit, but it does feed the album-size
    /// calibration, which `prepare()` is what refreshes — and one path for
    /// both is worth more here than saving a rebuild on the rarer of two
    /// rare actions.
    func undoVerdicts(_ receipt: VerdictReceipt) throws {
        let timestamp = receipt.timestamp
        let isGood = receipt.isGood
        let candidates = try modelContext.fetch(FetchDescriptor<VerdictRecord>(
            predicate: #Predicate {
                $0.timestamp == timestamp && $0.isGood == isGood
                    && !$0.isVoided && !$0.isCleared
            }
        ))
        let wanted = Set(receipt.keys)
        let matches = candidates.filter { wanted.contains($0.photoKey) }
        guard Set(matches.map(\.photoKey)) == wanted else {
            throw RankerError.nothingToUndo
        }
        for match in matches {
            match.isVoided = true
        }
        try modelContext.save()

        isPrepared = false
        try prepare()

        Task { @MainActor in RankingClock.shared.bump() }
    }

    // MARK: Model

    /// Convenience for a caller with no reason to know `minWidth`/
    /// `resolutionRange` are themselves derived from fixed `Thresholds`
    /// constants — `FeatureStore`'s FR-6.1 mix reuses the ranker's own
    /// trait vector as one of the axes its diversity signature is judged
    /// on ("anything else the app weighs", not only place/season/visual —
    /// see `FeatureStore.MixSignature`), and has no independent opinion
    /// about resolution scaling to supply.
    static func traits(of record: PhotoRecord) -> TraitValues {
        let minWidth = Float(Thresholds.minimumCandidatePixelWidth)
        let resolutionRange = log2(Thresholds.resolutionFullScoreWidth / minWidth)
        return traits(of: record, minWidth: minWidth, resolutionRange: resolutionRange)
    }

    /// Every `ScalarTrait` read off one record. The single place a trait is
    /// derived, so adding one to `ScalarTrait` means adding one line here.
    ///
    /// Traits the analyzer measured are read straight off the record; the
    /// rest are derived from what the photo records of itself. A record that
    /// predates a trait carries nil for it and is passed through as such —
    /// `TraitValues.set` marks it unknown rather than guessing, which is what
    /// keeps FR-3.8's "ranked on what is known" true through a trait's
    /// introduction.
    static func traits(
        of record: PhotoRecord,
        minWidth: Float,
        resolutionRange: Float
    ) -> TraitValues {
        var traits = TraitValues.neutral

        traits.set(.aesthetics, record.aestheticsScore)

        // A photo with no visible horizon (a forest interior) is not tilted;
        // it simply has nothing to be tilted about, which is `levelness`'s
        // own no-information value rather than a gap (FR-3.8).
        let tilt = abs(record.horizonAngleDegrees ?? 0)
        traits.set(.levelness, 1 - min(tilt, Thresholds.horizonMaxTiltDegrees) / Thresholds.horizonMaxTiltDegrees)

        traits.set(.resolution, min(1, max(0, log2(Float(record.pixelWidth) / minWidth) / resolutionRange)))

        // FR-5.1 judges the fixed wallpaper crop, so what the crop throws
        // away is a property of the photo: the crop keeps the smaller of the
        // two aspect ratios over the larger, whichever way the mismatch runs.
        let aspect = Float(record.pixelWidth) / Float(max(1, record.pixelHeight))
        let target = Float(Thresholds.desktopAspectRatio)
        traits.set(.cropLoss, 1 - min(aspect, target) / max(aspect, target))
        // The direction of that same mismatch — see `ScalarTrait.aspectSkew`
        // for why the magnitude alone is not enough.
        let skewRange = log2(Thresholds.aspectSkewFullScale)
        traits.set(.aspectSkew, min(1, max(-1, log2(aspect / target) / skewRange)))

        let season = record.creationDate.map(Self.seasonFraction)
        traits.setCyclical((.seasonCos, .seasonSin, .seasonCos2, .seasonSin2), turns: season)
        // Hemisphere-corrected first harmonic; see `ScalarTrait.localSeasonCos`.
        if let season, let latitude = record.latitude {
            let angle = 2 * Float.pi * season
            let hemisphere = Float(sin(latitude * .pi / 180))
            traits.set(.localSeasonCos, cos(angle) * hemisphere)
            traits.set(.localSeasonSin, sin(angle) * hemisphere)
        }

        traits.set(.captureEra, record.creationDate.map(Self.captureEra))
        traits.set(.altitude, record.altitude.map {
            Float(min(1, max(-1, $0 / Thresholds.altitudeFullScaleMetres)))
        })

        // What Photos already knows the photo is; the app only reads it.
        traits.set(.isPanorama, record.isPanorama.map { $0 ? 1 : 0 })
        traits.set(.isHDR, record.isHDR.map { $0 ? 1 : 0 })
        traits.set(.isDepthEffect, record.isDepthEffect.map { $0 ? 1 : 0 })
        traits.set(.isLivePhoto, record.isLivePhoto.map { $0 ? 1 : 0 })

        // Latitude alone is the "where" trait. Longitude is captured on
        // `PhotoRecord` but deliberately not its partner: a fixed linear
        // encoding of it (e.g. ÷180) wraps discontinuously at the ±180°
        // antimeridian, so two photos taken meters apart on either side of
        // that line would read as maximally far apart — a false signal no
        // duel choice produced. Latitude runs −90…90 with no such seam.
        traits.set(.latitude, record.latitude.map { Float($0 / 90) })

        // Longitude *is* used here, where its wraparound is the point rather
        // than a seam: it converts the stored absolute timestamp into the
        // photo's own local solar time. See `solarTimeFraction`.
        // FR-5.13: derived, not measured — the app's own astronomy applied to
        // the instant and coordinate the photo already records. Needs all
        // three; a photo missing any of them simply has no sun traits, which
        // FR-3.8 makes a gap rather than a penalty.
        if let created = record.creationDate,
           let latitude = record.latitude,
           let longitude = record.longitude {
            let sun = SolarPosition.angles(date: created, latitude: latitude, longitude: longitude)
            let basis = Self.sunElevationBasis(sun.elevation)
            traits.set(.sunElevation, basis)
            traits.set(.sunElevation2, basis * basis)
            traits.set(.sunElevation3, basis * basis * basis)
            // Hour angle runs −180…180 around solar noon; as a turn of the
            // circle that is (H + 180) / 360.
            let dayTurn = Float((sun.hourAngle + 180) / 360)
            traits.set(.solarTimeCos, cos(2 * .pi * dayTurn))
            traits.set(.solarTimeSin, sin(2 * .pi * dayTurn))
            // Where the sun sat relative to where the lens looked. Both are
            // degrees clockwise from true north, so the difference is the
            // angle between them: 0° is shooting into the sun.
            traits.setDirection(
                (.sunRelativeCos, .sunRelativeSin),
                degrees: record.cameraHeading.map { sun.azimuth - $0 }
            )
        }

        traits.set(.personProminence, record.personProminence)
        traits.set(.subjectProminence, record.subjectProminence)
        traits.set(.subjectCentrality, record.subjectCentrality)
        traits.set(.luminance, record.luminance)
        traits.set(.colorfulness, record.colorfulness)
        traits.set(.foregroundCoverage, record.foregroundCoverage)
        traits.set(.animalProminence, record.animalProminence)
        traits.set(.textCoverage, record.textCoverage)

        // Counts arrive raw and are put on their fixed scales here, so the
        // store keeps what was actually measured and only the ranker decides
        // where a count saturates — a saturation point can then be retuned
        // without re-examining a single photo.
        traits.set(.subjectCount, record.subjectCount.map {
            min(1, Float($0) / Float(Thresholds.subjectCountFullScale))
        })

        return traits
    }

    /// The exact `Weights.place` dictionary key for one scale of one named
    /// place — `"<scale>:<name>"`, so "fine:Georgia" (a town) and
    /// "coarse:Georgia" (a country) never collide, and two different real
    /// places never share a key either (contrast the hashed-bucket design
    /// this replaced, whose whole failure mode was exactly that kind of
    /// collision). Callers already guard out the case of no name for a
    /// scale (FR-3.8) before ever needing a key for it.
    private static func placeWeightKey(scale: String, name: String) -> String {
        "\(scale):\(name)"
    }

    /// Looks the pair up by judgment key, so a choice made on another device
    /// trains this one. A key with no local entry — the photo hasn't arrived,
    /// or has left — is skipped, and `applicableJudgmentCount` is what notices
    /// when that changes (FR-9.2).
    @discardableResult
    private func appendChoiceTerm(winnerKey: String, loserKey: String) -> Bool {
        guard let w = indexByKey[winnerKey], let l = indexByKey[loserKey] else { return false }
        trainingTerms.append(DuelTerm(winner: entries[w], loser: entries[l]))
        return true
    }

    /// Appends FR-5.4's favorite-seed pseudo-choices — a deterministic
    /// sample of "some favorite beats some random non-favorite" — to
    /// `trainingTerms`, and returns how many were appended (0 if there are
    /// no favorites or no non-favorites to pair them against). Pure: unlike
    /// the online SGD revision's `seedFromFavorites`, this never touches
    /// `weights` — every term it appends is just one more summand in
    /// `fitWeights`'s objective, down-weighted by
    /// `Thresholds.rankerFavoriteSeedWeight` relative to a real choice.
    @discardableResult
    private func appendFavoriteTerms() -> Int {
        let favorites = entries.indices.filter { entries[$0].isFavorite }
        let others = entries.indices.filter { !entries[$0].isFavorite }
        guard !favorites.isEmpty, !others.isEmpty else { return 0 }

        // Deterministic RNG so an identical rebuild reproduces the same seeding.
        var rng = SplitMix64(seed: Thresholds.rankerSeedRNG)
        var pairs = 0
        outer: for favorite in favorites.shuffled(using: &rng) {
            for _ in 0..<Thresholds.favoriteSeedOpponents {
                guard pairs < Thresholds.favoriteSeedMaxPairs else { break outer }
                trainingTerms.append(DuelTerm(
                    winner: entries[favorite],
                    loser: entries[others.randomElement(using: &rng)!],
                    weight: Thresholds.rankerFavoriteSeedWeight
                ))
                pairs += 1
            }
        }
        return pairs
    }

    /// Appends a bad verdict's pseudo-choice term to `trainingTerms` — the
    /// same "against a fixed neutral reference" shape `penalizeBadVerdict`
    /// used to feed straight into one SGD step (FR-4.7/FR-5.7):
    /// - feature vector = all zeros, aesthetics = 0 — aestheticsScore is
    ///   already zero-centered (−1…1), so 0 is a genuine neutral midpoint,
    ///   not an arbitrary choice. These are the two terms whose difference
    ///   from the bad photo's own values is nonzero, and they're what
    ///   generalizes: pulling `weights.feature` away from this photo's
    ///   feature direction is what drags visually-similar photos down too
    ///   ("and others like it", FR-4.7), independent of anything else in
    ///   the candidate set.
    /// - every other trait = copied from the bad photo's own values, known
    ///   flags included, so those columns of this one term are always
    ///   exactly zero. A single bad verdict on its own isn't evidence that
    ///   tilt, resolution, when, where, or how bright the photo is *caused*
    ///   the badness — unlike a real duel, there's no second photo to
    ///   contrast against — so those weights stay untouched by verdict
    ///   training and only ever move from actual duel choices.
    ///   `ScalarTrait.trainsOnVerdict` is where that split lives, so a
    ///   trait added later inherits the safe side of it.
    /// - place = copied from the bad photo's own place at every scale, so
    ///   every scale is "the same place" for this term and contributes
    ///   nothing to the fit's place columns — same reasoning as the trait
    ///   bullet above, extended to place.
    ///
    /// Using a fixed reference instead of a live opponent is also what keeps
    /// this replay-safe (FR-5.3): the pseudo-choice is fully determined by
    /// the bad photo's own stored feature print, never by which other
    /// candidates happen to exist when `trainingTerms` is rebuilt.
    @discardableResult
    private func appendBadVerdictTerm(key: String) -> Bool {
        guard let index = indexByKey[key] else { return false }
        let entry = entries[index]
        var reference = entry.traits
        for trait in ScalarTrait.allCases where trait.trainsOnVerdict {
            reference.values[trait.rawValue] = trait.neutral
        }
        let neutral = Entry(
            id: "",
            key: "",
            vector: Array(repeating: 0, count: entry.vector.count),
            isFavorite: false,
            traits: reference,
            place: entry.place
        )
        trainingTerms.append(DuelTerm(winner: neutral, loser: entry))
        return true
    }

    /// What one `fitWeights` call returned — its wall-clock cost and how
    /// many L-BFGS iterations it took, logged by every caller
    /// (`prepare`/`record`/`recordVerdicts`) so FR-8.2's "stays in the tens
    /// of milliseconds" is something the unified log actually shows, not
    /// only a doc-comment claim.
    private struct FitResult {
        let milliseconds: Double
        let iterations: Int
    }

    /// Minimizes `trainingTerms`'s batch MAP objective and writes the
    /// result into `weights.feature`/`scalars`/`place` — the batch fit this
    /// actor's own doc comment describes, replacing the online SGD revision
    /// (`Thresholds.rankerAlgorithmVersion` v16 and before) that used to
    /// mutate `weights` one `sgdStep` at a time.
    ///
    /// `warmStart` chooses only where L-BFGS starts iterating from: the
    /// *prior* (`initialScalarWeights`/0/0, `warmStart: false`, used by a
    /// cold rebuild with no previous fit to start from) or the *current*
    /// `weights` (`warmStart: true`, used by `record`/`recordVerdicts` right
    /// after appending one more term). The objective — and so its unique
    /// global minimum — is identical either way, because it is convex: the
    /// L2 penalty below is strictly convex in every parameter, and a
    /// strictly-convex-plus-convex sum stays strictly convex. Two fits over
    /// the same `trainingTerms` converge to the same weights to float32
    /// precision regardless of the starting point — which is what makes
    /// FR-5.2/FR-7.1's "the same library and the same judgments always
    /// produce the same ranking" hold for this algorithm, unlike the SGD
    /// revision it replaced, whose weight decay made the *order* choices
    /// arrived in part of what the final weights meant.
    ///
    /// **Objective:** Σ over `trainingTerms` of softplus(−(s_winner −
    /// s_loser)) + ½ Σ over three parameter blocks of λ_block·‖block −
    /// prior_block‖², with prior = `initialScalarWeights`/0/0 (feature print
    /// and place start untrained; aesthetics starts at 1, every other
    /// scalar trait at 0 — FR-5.4's opening guess). λ_block is
    /// `Thresholds.rankerFeaturePrintPenalty`/`rankerScalarPenalty`/
    /// `rankerPlacePenalty`, all three from the same offline-study grid
    /// search — see those constants' doc comments for the numbers.
    ///
    /// **The score inside each term's softplus is *not* a plain
    /// `rawScore(winner) − rawScore(loser)`.** Its place contribution
    /// divides by however many of the five scales the winner and loser
    /// differ at, mirroring what the online SGD revision's `sgdStep` used
    /// to split its *gradient step* by (see `Thresholds.rankerAlgorithmVersion`'s
    /// v16 paragraph for why: without the split, "where a photo was taken"
    /// could learn up to 5× faster than any other single trait, since two
    /// geographically distant photos routinely differ at all five scales in
    /// one duel — FR-5.2). Baking the same division into the *design
    /// matrix* built below — rather than special-casing one block's
    /// gradient after the fact — keeps the objective an ordinary sum of
    /// softplus terms, still convex, still solvable by a generic L-BFGS:
    /// the division only changes what each term's design-matrix place
    /// columns *are* (1/differingScaleCount rather than 1), not how the
    /// solver treats them, so the standard chain rule through those columns
    /// reproduces the split automatically. This is training-time only —
    /// `rawScore`, what every candidate is actually ranked and served by,
    /// still sums a photo's full, undivided place weights across every
    /// scale it is named at, exactly as before this method replaced
    /// `sgdStep`.
    ///
    /// **Feature-print conditioning:** the feature-print block is fit in a
    /// rescaled parameterization — see `Thresholds.rankerFeaturePrintScale`'s
    /// doc comment for why, and for the algebraic identity that makes it
    /// score-function-neutral — and converted back to `weights.feature`'s
    /// raw units by `applySolution` before this returns.
    @discardableResult
    private func fitWeights(warmStart: Bool) -> FitResult {
        let start = Date()
        let featureDim = weights.feature.count
        let scalarDim = ScalarTrait.allCases.count

        // Every place key any term actually differs at — the fit's place
        // parameter space, and each term's place columns (delta 0 unless
        // this scale differs, ±1/differingScaleCount where it does — see
        // this method's doc comment for why that division belongs here
        // rather than in the solver).
        var placeIndex: [String: Int] = [:]
        struct PlaceColumn { let index: Int; let delta: Float }
        var placeColumns: [[PlaceColumn]] = []
        placeColumns.reserveCapacity(trainingTerms.count)
        for term in trainingTerms {
            let differingScales: [(scale: String, winnerName: String, loserName: String)] = [
                ("fine", term.winner.place.fine, term.loser.place.fine),
                ("landscape", term.winner.place.landscape, term.loser.place.landscape),
                ("region", term.winner.place.region, term.loser.place.region),
                ("coarse", term.winner.place.coarse, term.loser.place.coarse),
                ("network", term.winner.place.network, term.loser.place.network),
            ].compactMap { scale, winnerName, loserName in
                guard let winnerName, let loserName, winnerName != loserName else { return nil }
                return (scale, winnerName, loserName)
            }
            guard !differingScales.isEmpty else {
                placeColumns.append([])
                continue
            }
            let delta = 1 / Float(differingScales.count)
            var columns: [PlaceColumn] = []
            columns.reserveCapacity(differingScales.count * 2)
            for (scale, winnerName, loserName) in differingScales {
                let winnerKey = Self.placeWeightKey(scale: scale, name: winnerName)
                let loserKey = Self.placeWeightKey(scale: scale, name: loserName)
                let winnerIndex = placeIndex[winnerKey] ?? {
                    let i = placeIndex.count
                    placeIndex[winnerKey] = i
                    return i
                }()
                let loserIndex = placeIndex[loserKey] ?? {
                    let i = placeIndex.count
                    placeIndex[loserKey] = i
                    return i
                }()
                columns.append(PlaceColumn(index: winnerIndex, delta: delta))
                columns.append(PlaceColumn(index: loserIndex, delta: -delta))
            }
            placeColumns.append(columns)
        }
        let placeDim = placeIndex.count
        let dimension = featureDim + scalarDim + placeDim
        let n = trainingTerms.count

        var prior = [Float](repeating: 0, count: dimension)
        prior[featureDim + ScalarTrait.aesthetics.rawValue] = 1

        var lambda = [Float](repeating: 0, count: dimension)
        for j in 0..<featureDim { lambda[j] = Thresholds.rankerFeaturePrintPenalty }
        for j in featureDim..<(featureDim + scalarDim) { lambda[j] = Thresholds.rankerScalarPenalty }
        for j in (featureDim + scalarDim)..<dimension { lambda[j] = Thresholds.rankerPlacePenalty }

        let fpScale = Thresholds.rankerFeaturePrintScale
        var x0 = prior
        if warmStart {
            for j in 0..<featureDim { x0[j] = weights.feature[j] / fpScale }
            for j in 0..<scalarDim { x0[featureDim + j] = weights.scalars[j] }
            for (key, index) in placeIndex { x0[featureDim + scalarDim + index] = weights.place[key] ?? 0 }
        }

        guard n > 0 else {
            // No terms at all (an empty library, or a rebuild with no
            // judgments yet): the fit is exactly its prior — matching the
            // offline study's `LinearBT.fit`'s own `if not duels: self.w =
            // prior; return`, which this ported from.
            applySolution(prior, featureDim: featureDim, scalarDim: scalarDim, placeIndex: placeIndex)
            return FitResult(milliseconds: Date().timeIntervalSince(start) * 1000, iterations: 0)
        }

        // Dense row-major design matrix: row t is `trainingTerms[t]`'s
        // contribution to the score difference, one column per parameter —
        // feature print (scaled by `rankerFeaturePrintScale`), scalar
        // traits (masked to 0 wherever either side is unmeasured, FR-3.8 —
        // the same masking `sgdStep`'s gradient used to apply), then place
        // (the divided ±1/count columns built above).
        var designMatrix = [Float](repeating: 0, count: n * dimension)
        designMatrix.withUnsafeMutableBufferPointer { buffer in
            for (t, term) in trainingTerms.enumerated() {
                let base = t * dimension
                for j in 0..<featureDim {
                    buffer[base + j] = (term.winner.vector[j] - term.loser.vector[j]) * fpScale
                }
                for i in 0..<scalarDim {
                    let bothKnown = term.winner.traits.known[i] && term.loser.traits.known[i]
                    buffer[base + featureDim + i] = bothKnown
                        ? term.winner.traits.values[i] - term.loser.traits.values[i] : 0
                }
                for column in placeColumns[t] {
                    buffer[base + featureDim + scalarDim + column.index] = column.delta
                }
            }
        }

        let (solution, iterations, _) = Self.lbfgs(
            designMatrix: designMatrix, rows: n, dimension: dimension,
            termWeights: trainingTerms.map(\.weight),
            prior: prior, lambda: lambda, start: x0
        )
        applySolution(solution, featureDim: featureDim, scalarDim: scalarDim, placeIndex: placeIndex)
        return FitResult(milliseconds: Date().timeIntervalSince(start) * 1000, iterations: iterations)
    }

    /// Unpacks a solved parameter vector back into `weights` — the inverse
    /// of `fitWeights`'s design-matrix layout. The feature-print block is
    /// converted out of its fit-time conditioning (see
    /// `Thresholds.rankerFeaturePrintScale`'s doc comment); scalars and
    /// place are copied straight across, place by name via `placeIndex`.
    private func applySolution(_ solution: [Float], featureDim: Int, scalarDim: Int, placeIndex: [String: Int]) {
        let fpScale = Thresholds.rankerFeaturePrintScale
        weights.feature = (0..<featureDim).map { solution[$0] * fpScale }
        weights.scalars = Array(solution[featureDim..<(featureDim + scalarDim)])
        var place: [String: Float] = [:]
        place.reserveCapacity(placeIndex.count)
        for (key, index) in placeIndex {
            place[key] = solution[featureDim + scalarDim + index]
        }
        weights.place = place
    }

    /// Batch L2-regularized pairwise-logistic fit — minimizes Σₜ
    /// cₜ·softplus(−(designMatrix·u)ₜ) + ½ Σⱼ λⱼ(uⱼ − priorⱼ)² over `u`
    /// (cₜ = `termWeights[t]`), via
    /// L-BFGS (two-loop recursion, `Thresholds.rankerLBFGSMemory` pairs of
    /// history) with Armijo backtracking, on Accelerate (`cblas_sgemv` for
    /// the forward and transposed matrix-vector products, `vDSP` for the
    /// vector arithmetic in between).
    ///
    /// Pure numerical core, no actor state: every semantic that makes this
    /// *the ranker's* fit — the trait masking, the place-gradient split, the
    /// feature-print conditioning — lives entirely in how `fitWeights`
    /// builds `designMatrix`/`prior`/`lambda`, not here, so this function
    /// can't accidentally depend on `Entry`/`Weights`/`ScalarTrait`. Ported
    /// from the offline study's Swift prototype (`fable/swift/fit.swift`),
    /// itself verified there against the same study's Python
    /// `scipy.optimize.minimize` L-BFGS-B solution on the frozen judgment
    /// snapshot to ~1e-3 — see this file's own numerical-parity check for
    /// the equivalent verification against this port.
    private static func lbfgs(
        designMatrix X: [Float], rows n: Int, dimension d: Int,
        termWeights c: [Float],
        prior: [Float], lambda: [Float], start: [Float]
    ) -> (solution: [Float], iterations: Int, finalLoss: Float) {
        func objective(_ u: [Float]) -> (Float, [Float]) {
            var z = [Float](repeating: 0, count: n)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(d), 1, X, Int32(d), u, 1, 0, &z, 1)
            var loss: Float = 0
            var r = [Float](repeating: 0, count: n) // d(softplus(-z))/dz = -sigmoid(-z)
            for i in 0..<n {
                let zi = z[i]
                // Stable softplus(-z): log(1 + exp(-z)) computed without
                // ever exponentiating a large positive number.
                loss += c[i] * (zi > 0 ? log1p(exp(-zi)) : -zi + log1p(exp(zi)))
                r[i] = -c[i] / (1 + exp(zi))
            }
            var g = [Float](repeating: 0, count: d)
            cblas_sgemv(CblasRowMajor, CblasTrans, Int32(n), Int32(d), 1, X, Int32(d), r, 1, 0, &g, 1)
            for j in 0..<d {
                let diff = u[j] - prior[j]
                loss += 0.5 * lambda[j] * diff * diff
                g[j] += lambda[j] * diff
            }
            return (loss, g)
        }

        var u = start
        var (f, g) = objective(u)
        var s: [[Float]] = [], y: [[Float]] = [], rho: [Float] = []
        var iterations = 0
        for it in 0..<Thresholds.rankerLBFGSMaxIterations {
            iterations = it + 1
            let gradientNorm = sqrt(vDSP.dot(g, g))
            if gradientNorm < Thresholds.rankerLBFGSGradientTolerance { break }

            // Two-loop recursion: the L-BFGS search direction from the last
            // `rankerLBFGSMemory` (step, gradient-change) pairs, with no
            // explicit Hessian ever formed.
            var q = g
            var alpha = [Float](repeating: 0, count: s.count)
            for i in stride(from: s.count - 1, through: 0, by: -1) {
                alpha[i] = rho[i] * vDSP.dot(s[i], q)
                q = vDSP.add(q, vDSP.multiply(-alpha[i], y[i]))
            }
            var gamma: Float = 1
            if let lastS = s.last, let lastY = y.last { gamma = vDSP.dot(lastS, lastY) / vDSP.dot(lastY, lastY) }
            var z = vDSP.multiply(gamma, q)
            for i in 0..<s.count {
                let beta = rho[i] * vDSP.dot(y[i], z)
                z = vDSP.add(z, vDSP.multiply(alpha[i] - beta, s[i]))
            }
            let direction = vDSP.multiply(-1, z)
            let slope = vDSP.dot(g, direction)

            // Armijo backtracking: halve the step until it gives a
            // sufficient decrease, or the step is too small to matter — the
            // objective is convex and smooth, so this always terminates.
            var step: Float = 1
            var uNew = u, fNew = f, gNew = g
            while true {
                uNew = vDSP.add(u, vDSP.multiply(step, direction))
                (fNew, gNew) = objective(uNew)
                if fNew <= f + Thresholds.rankerLBFGSArmijoConstant * step * slope
                    || step < Thresholds.rankerLBFGSMinimumStep { break }
                step *= Thresholds.rankerLBFGSStepShrinkFactor
            }

            let sStep = vDSP.subtract(uNew, u), yStep = vDSP.subtract(gNew, g)
            let sy = vDSP.dot(sStep, yStep)
            if sy > Thresholds.rankerLBFGSCurvatureMinimum {
                s.append(sStep); y.append(yStep); rho.append(1 / sy)
                if s.count > Thresholds.rankerLBFGSMemory { s.removeFirst(); y.removeFirst(); rho.removeFirst() }
            }

            // Relative function-decrease stop — see
            // `Thresholds.rankerLBFGSFunctionTolerance`'s doc comment for
            // why this, not the gradient-norm check above, is what actually
            // ends the loop on a fit this size: without it, float32's noise
            // floor in the gradient norm keeps this loop spending the full
            // `rankerLBFGSMaxIterations` re-backtracking to a vanishing step
            // long after the objective stopped improving, which is exactly
            // what FR-8.2 forbids.
            let relativeDecrease = (f - fNew) / max(1, abs(f))
            u = uNew; f = fNew; g = gNew
            if relativeDecrease < Thresholds.rankerLBFGSFunctionTolerance { break }
        }
        return (u, iterations, f)
    }

    private func rawScore(_ entry: Entry) -> Float {
        var score = vDSP.dot(weights.feature, entry.vector)
            + vDSP.dot(weights.scalars, entry.traits.values)
        // FR-5.14: whatever this photo's five place scales are actually
        // named contribute their own learned weight (0 for a place never
        // yet judged, FR-5.2); a scale with no name at all contributes
        // nothing rather than a penalty (FR-3.8) — including `network`
        // before it's resolved, or when the network never allows it.
        if let fine = entry.place.fine {
            score += weights.place[Self.placeWeightKey(scale: "fine", name: fine), default: 0]
        }
        if let landscape = entry.place.landscape {
            score += weights.place[Self.placeWeightKey(scale: "landscape", name: landscape), default: 0]
        }
        if let region = entry.place.region {
            score += weights.place[Self.placeWeightKey(scale: "region", name: region), default: 0]
        }
        if let coarse = entry.place.coarse {
            score += weights.place[Self.placeWeightKey(scale: "coarse", name: coarse), default: 0]
        }
        if let network = entry.place.network {
            score += weights.place[Self.placeWeightKey(scale: "network", name: network), default: 0]
        }
        return score
    }

    private func recomputeScores() {
        for index in entries.indices {
            entries[index].score = rawScore(entries[index])
        }
    }

    // MARK: Preference-cache flush (debounced)
    //
    // `writePreferenceCache` rewrites `PhotoRecord.preferenceScore` for the whole
    // candidate set and saves — a heavy write transaction that holds the store's
    // write lock. Running it per duel choice starved the main context's reads and
    // autosave, beachballing the UI (FR-8.2). Instead each choice updates the
    // in-memory `entries` scores (cheap) and calls `scheduleCacheFlush`; the store
    // is written once a burst settles (batch-size or idle bound, whichever first).
    //
    // The RankingClock bump that tells the grid/export to re-read the cache fires
    // *from the flush*, only when a flush actually persisted new scores — so those
    // reads never see a value older than the last flush, and no per-choice writer
    // contends with them (FR-4.5 tolerates this short coalescing delay).
    //
    // Convergence — the cache is only a denormalized, replayable cache — is
    // guaranteed by: the idle-timer flush after the user pauses; the synchronous
    // boundary flush in reload()/prepare(); and prepare() rewriting the whole
    // cache on every launch. So a deferred (or process-death-dropped) flush is
    // always eventually reconciled without any data loss.

    /// Coalesces per-choice score writes: bumps the pending count and either
    /// flushes immediately once a burst reaches the batch bound, or (re)arms the
    /// idle timer so a pause flushes what's pending.
    private func scheduleCacheFlush() {
        unflushedChoices += 1
        if unflushedChoices >= Thresholds.preferenceCacheFlushBatchSize {
            flushCacheNow()
            return
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Thresholds.preferenceCacheFlushIdleInterval)
            guard !Task.isCancelled else { return }
            await self?.flushCacheNow()
        }
    }

    /// Writes the pending score changes; if any were material, tells the ranked
    /// views to re-read. Safe to call with nothing pending (writes nothing).
    private func flushCacheNow() {
        flushTask?.cancel()
        flushTask = nil
        unflushedChoices = 0
        let changed = (try? writePreferenceCache()) ?? false
        if changed {
            Task { @MainActor in RankingClock.shared.bump() }
        }
    }

    /// Drops a pending debounced flush without writing — used when a boundary
    /// flush (reload/prepare) is about to write everything synchronously anyway.
    private func cancelPendingFlush() {
        flushTask?.cancel()
        flushTask = nil
        unflushedChoices = 0
    }

    /// Denormalizes each candidate's raw score into `PhotoRecord.preferenceScore`
    /// and saves. Only rows whose cached value moved by more than
    /// `preferenceCacheEpsilon` are touched, so the float-noise nudges from a
    /// single SGD step don't dirty (and rewrite) the entire table. Returns
    /// whether any row actually changed, so a no-op flush skips both the save and
    /// the dependent-view bump.
    @discardableResult
    private func writePreferenceCache() throws -> Bool {
        let records = try modelContext.fetch(FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isNature && !$0.isExcluded }))
        var changed = false
        for record in records {
            guard let index = indexByID[record.localIdentifier] else { continue }
            let score = entries[index].score
            if let current = record.preferenceScore {
                guard abs(current - score) > Thresholds.preferenceCacheEpsilon else { continue }
            }
            record.preferenceScore = score
            changed = true
        }
        if changed {
            try modelContext.save()
        }
        return changed
    }

    // MARK: Persistence

    /// Where the learned weights live.
    ///
    /// `static` and reachable from outside the actor because starting the
    /// user's taste over (FR-7.5) has to delete this file as well as the
    /// judgments: the weights are what those judgments were baked into, and
    /// leaving them behind would have the app carry on ranking by a taste the
    /// user had just discarded. Everything else about them stays private —
    /// `JudgmentArchive.resetLearnedTaste` deletes the file and nothing more.
    nonisolated static var weightsFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firnlight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ranker-weights.json")
    }

    private var weightsFileURL: URL { Self.weightsFileURL }

    private func loadWeights() -> Weights? {
        guard let data = try? Data(contentsOf: weightsFileURL) else { return nil }
        return try? JSONDecoder().decode(Weights.self, from: data)
    }

    private func saveWeights() {
        guard let data = try? JSONEncoder().encode(weights) else { return }
        try? data.write(to: weightsFileURL, options: .atomic)
    }

    // MARK: Helpers

    private func candidate(for entry: Entry) -> Candidate {
        Candidate(
            localIdentifier: entry.id,
            aestheticsScore: entry.traits[.aesthetics],
            isFavorite: entry.isFavorite,
            preferenceScore: entry.score,
            // isIgnored stays at its default (false): `loadEntries()` already
            // excludes ignored photos, so a duel `Entry` is never one.
            isNotWallpaperMaterial: entry.isNotWallpaperMaterial
        )
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// Deterministic fingerprint of which candidates are currently Photos
    /// favorites — FR-5.4's rebuild trigger (see `Weights.favoriteFingerprint`).
    /// Sorted judgment keys, not `Set`/`Dictionary` order, which Swift leaves
    /// unspecified and would make this fingerprint (and so whether a rebuild
    /// fires) depend on hash-seed randomization rather than the favorite set
    /// itself. Hashed with a fixed, non-randomized algorithm (FNV-1a) rather
    /// than `Hasher` — `Hasher`'s per-process random seed (`hashValue`/
    /// `Hasher` are explicitly documented as varying between runs) would make
    /// two identical favorite sets fingerprint differently across launches or
    /// devices, permanently forcing a rebuild every single `prepare()`/
    /// `reload()` rather than only when the set actually changed.
    private static func favoriteFingerprint(of entries: [Entry]) -> String {
        let keys = entries.filter(\.isFavorite).map(\.key).sorted()
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
        for key in keys {
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3 // FNV prime
            }
            hash ^= 0xA // separator, so ["ab","c"] and ["a","bc"] don't collide
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Deterministic fingerprint of every record's FR-5.14 fifth-scale
    /// answer — see `Weights.networkFingerprint`'s doc comment for what
    /// this triggers. `records` is already sorted by `localIdentifier`
    /// (`loadEntries`'s own fetch), so no separate sort is needed here;
    /// fixed FNV-1a rather than `Hasher`, whose per-process random seed
    /// would otherwise make two identical inputs fingerprint differently
    /// across launches on the *same* device, forcing a rebuild every
    /// `prepare()`/`reload()` rather than only when the network name set
    /// actually changed — the same reason `favoriteFingerprint` gives for
    /// its own choice of FNV-1a. Mixing in `localIdentifier`, not
    /// `judgmentKey` the way `favoriteFingerprint` mixes in `entry.key`,
    /// is deliberately not claimed to give this the same cross-device
    /// agreement that one has: `localIdentifier` is device-scoped by its
    /// own doc comment, so this fingerprint can differ across two devices
    /// holding the identical resolved network names. That gap is harmless
    /// today only because `Weights` itself never leaves the device (see
    /// `JudgmentStore`'s two-store split) — revisit this fingerprint's key
    /// if that ever changes. Only resolved records are mixed in — an
    /// unresolved one contributes nothing, so a library with no network
    /// lookups yet (or none at all) fingerprints identically to one with no
    /// photos with locations, rather than churning as more spots are
    /// merely *attempted*.
    private static func networkFingerprint(of records: [PhotoRecord]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3 // FNV prime
            }
            hash ^= 0xA
            hash = hash &* 0x100000001b3
        }
        for record in records where record.networkPlaceResolved {
            mix(record.localIdentifier)
            mix(record.networkPlaceName ?? "")
        }
        return String(hash, radix: 16)
    }

    /// FR-5.2's "when", as a fixed, library-independent 0…1 reading of a
    /// date's position in the calendar year — day-of-year over the year's
    /// actual length (365 or 366), so Dec 31 in a leap year isn't quietly
    /// treated as 0.3% short of the year. A fixed UTC calendar, not
    /// `Calendar.current`: the same photo must map to the same value on
    /// every device regardless of its time zone (FR-5.2's "same library and
    /// same judgments always produce the same ranking" — a Mac in Berlin and
    /// an iPhone in Los Angeles training the same shared weights file must
    /// compute the exact same feature for it). Deliberately linear rather
    /// than a cyclical (sin/cos) encoding: Dec 31 and Jan 1 sit at opposite
    /// ends of the 0…1 range despite being adjacent in the calendar, which
    /// costs the feature some precision right at the year boundary but keeps
    /// it a single scalar with a single learned weight, matching every other
    /// feature here — not worth two dimensions for one edge case.
    /// The photo's own date on a fixed scale of calendar years, −1…1.
    ///
    /// Anchored to fixed years rather than to `now`, which is the whole point:
    /// see `ScalarTrait.captureEra`.
    private static func captureEra(of date: Date) -> Float {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = Float(calendar.component(.year, from: date))
        return min(1, max(-1, (year - Thresholds.captureEraCentreYear)
            / Thresholds.captureEraHalfSpanYears))
    }

    /// Solar elevation, compressed so the near-horizon degrees the light
    /// actually changes over get room on the scale.
    ///
    /// `asinh` rather than a plain division by 90: golden hour spans roughly
    /// the first six degrees above the horizon, three per cent of a −90…90
    /// range, and a polynomial over that raw range cannot resolve a band so
    /// narrow. Illumination and colour temperature change enormously per
    /// degree near the horizon and almost not at all between 50° and 70°, so
    /// expanding the one end and compressing the other is a fact about
    /// sunlight, not an assumption about taste. Signed, so the sun below the
    /// horizon stays distinguishable from the sun above it.
    private static func sunElevationBasis(_ elevationDegrees: Double) -> Float {
        let scale = Thresholds.sunElevationHorizonScaleDegrees
        return Float(asinh(elevationDegrees / scale) / asinh(90 / scale))
    }

    /// Not `private`: `FeatureStore.selectDiverseMix` (FR-6.1) reuses this
    /// exact calendar arithmetic for its own season-quarter signature, rather
    /// than a second, possibly-divergent leap-year-safe implementation.
    static func seasonFraction(of date: Date) -> Float {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let daysInYear = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
        return Float(dayOfYear - 1) / Float(daysInYear)
    }
}
