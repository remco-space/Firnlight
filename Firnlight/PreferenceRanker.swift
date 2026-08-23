import Accelerate
import Foundation
import SwiftData
import os

/// Online logistic (Bradley–Terry) preference ranker over Vision feature prints.
///
/// Raw score: s = w·featurePrint + Σᵢ bᵢ·traitᵢ, over every `ScalarTrait` —
/// how the photo scored, how level it is, how many pixels it has, when and
/// where it was taken, how much the wallpaper crop discards, how prominent a
/// person and the salient subject are, where that subject sits, and how
/// bright the frame is. Every b weight is learned from duels, never
/// hard-coded: a low-resolution, tilted, dim, or seasonally atypical photo is
/// penalized — or favored — only as much as the user's choices imply
/// (FR-5.2). The set is open by design and expected to grow; `ScalarTrait`
/// is where it lives and `traits(of:)` is where each is measured.
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
/// rather than a penalty (FR-3.8), and `sgdStep` additionally skips the
/// gradient term entirely for any duel where either side lacks it, so an
/// unmeasured trait never itself becomes a trained signal, only ever a
/// genuinely uninformative one.
/// Choice model: P(winner beats loser) = sigmoid(s_winner − s_loser)
/// One SGD step per recorded choice; `PhotoRecord.preferenceScore` caches the
/// raw score s after every update so the grid can re-rank live. A bad
/// verdict ("Both Are Bad" / "Not Wallpaper Material") trains the same way,
/// as one SGD step against a fixed neutral reference rather than a real
/// opponent — see `penalizeBadVerdict` (FR-4.7/FR-5.7). A good verdict never
/// touches these weights (deferred — see REQUIREMENTS.md).
///
/// Weights persist as JSON in Application Support. If the file is missing,
/// weights are rebuilt by seeding from Photos favorites (pseudo-choices:
/// favorite beats random non-favorite) and then replaying every ChoiceRecord
/// and bad VerdictRecord, interleaved in timestamp order (FR-5.3).
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
    /// Time of year, 0…1 — FR-5.2's "when". See `seasonFraction`.
    case season
    /// Latitude ÷ 90, −1…1 — FR-5.2's "where". See `traits(of:)` for why
    /// longitude is not its partner here.
    case latitude
    /// Local solar time of day, 0…1 wrapping at midnight — see
    /// `solarTimeFraction`. Distinct from `season`, and the trait that
    /// separates a golden-hour frame from a midday one.
    case solarTime
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

    /// The value a photo takes on this trait when it was never measured for
    /// it (FR-3.8): the point on the trait's own scale that carries no
    /// information, so an unmeasured photo sits where "nothing is known"
    /// belongs rather than at one extreme. It is *only* a scoring
    /// placeholder — `sgdStep` additionally trains nothing on a trait either
    /// side is missing, so a gap never becomes a signal in its own right.
    var neutral: Float {
        switch self {
        // Zero-centred scales: their own midpoint is 0.
        case .aesthetics, .latitude: 0
        // "Nothing detected" already reads as level, so a missing horizon and
        // a level one are the same value — this is the one trait whose
        // no-information point is an end of its scale rather than its middle.
        case .levelness: 1
        // 0…1 scales: the midpoint.
        case .resolution, .season, .solarTime, .cropLoss,
             .personProminence, .subjectProminence, .subjectCentrality, .luminance: 0.5
        }
    }

    /// Whether a bad verdict may move this trait's weight.
    ///
    /// Only `aesthetics`. A verdict has no opponent photo to contrast
    /// against, so it is no evidence that tilt, resolution, when, where, or
    /// how bright the photo is *caused* the badness — see
    /// `penalizeBadVerdict`. Aesthetics is exempt because it is the app's own
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

    /// A durable judgment being replayed into the ranker during a rebuild —
    /// either a relative choice or a bad-quality verdict (FR-5.3/FR-5.7).
    /// See `prepare()` for why these need a single, deterministically
    /// ordered replay stream rather than two separate passes.
    private enum TrainingEvent {
        case choice(winnerKey: String, loserKey: String)
        case badVerdict(key: String)

        /// Deterministic secondary sort key for same-timestamp events
        /// (both event kinds sort by their own persisted identifiers, never
        /// by anything that could vary between runs), so ties always
        /// resolve the same way on every rebuild.
        var orderKey: String {
            switch self {
            case .choice(let winnerKey, let loserKey): return "0|\(winnerKey)|\(loserKey)"
            case .badVerdict(let key): return "1|\(key)"
            }
        }
    }

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
        var seededWithFavorites: Bool
        /// How many judgments these weights already contain — see
        /// `applicableJudgmentCount`. Optional so weights written before this
        /// existed decode, and simply trigger one rebuild.
        var judgmentCount: Int?
        /// Fingerprint of the favorite set these weights were last seeded
        /// from — see `favoriteFingerprint(of:)`. FR-5.4: "What the user has
        /// said [in Photos] is folded in whenever the app learns of it — a
        /// favorite found by a later scan counts the same as one found by the
        /// first." `seedFromFavorites()` only runs during a rebuild, so a
        /// change to the favorite set has to be detected the same way a
        /// change to the judgment set already is (`judgmentCount`) — by
        /// comparing against what these weights were built from — or a
        /// favorite discovered after the first rebuild would never be
        /// seeded. Optional so weights written before this existed decode,
        /// and simply trigger one rebuild (favorites already folded into
        /// them get re-seeded exactly the same way a version bump's full
        /// replay always does — deterministic, so this costs nothing new).
        var favoriteFingerprint: String?
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "PreferenceRanker")

    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    /// `Entry.key` → index. The lookup every judgment goes through, since
    /// judgments are keyed device-independently while `indexByID` is local.
    private var indexByKey: [String: Int] = [:]
    private var weights = Weights(feature: [], scalars: PreferenceRanker.initialScalarWeights, seededWithFavorites: false)

    /// Untrained coefficients: every trait at 0 except `aesthetics` at 1, so
    /// a library with no judgments at all is ordered by the app's own reading
    /// of the photos and nothing else — FR-5.4's "opening guess only, which
    /// anything the user then says fully supersedes".
    private static let initialScalarWeights: [Float] =
        ScalarTrait.allCases.map { $0 == .aesthetics ? 1 : 0 }
    private var judgedPairs: Set<String> = []
    private var isPrepared = false

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
        if let stored = loadWeights(),
           stored.algorithmVersion == Thresholds.rankerAlgorithmVersion,
           stored.feature.count == dimension,
           stored.scalars.count == ScalarTrait.allCases.count,
           stored.judgmentCount == applicable,
           stored.favoriteFingerprint == currentFavorites {
            weights = stored
        } else {
            weights = Weights(
                algorithmVersion: Thresholds.rankerAlgorithmVersion,
                feature: Array(repeating: 0, count: dimension),
                scalars: Self.initialScalarWeights,
                seededWithFavorites: false,
                judgmentCount: applicable,
                favoriteFingerprint: currentFavorites
            )
            seedFromFavorites()
            // Choices and bad verdicts both train the ranker (FR-5.7), so a
            // rebuild must replay them interleaved in the order the user
            // actually produced them, not choices-then-verdicts or vice
            // versa — SGD is order-dependent (weight decay + gradient path),
            // so a different order would rebuild a different ranking and
            // break the FR-5.3 guarantee. `TrainingEvent.orderKey` gives a
            // deterministic tie-break for same-timestamp events (e.g. both
            // photos of a single "Both Are Bad" verdict share one Date()),
            // since SwiftData doesn't promise fetch order beyond the given
            // SortDescriptors.
            var events: [(timestamp: Date, event: TrainingEvent)] =
                choices.map { ($0.timestamp, .choice(winnerKey: $0.winnerKey, loserKey: $0.loserKey)) }
                + badVerdicts.map { ($0.timestamp, .badVerdict(key: $0.photoKey)) }
            events.sort {
                $0.timestamp != $1.timestamp
                    ? $0.timestamp < $1.timestamp
                    : $0.event.orderKey < $1.event.orderKey
            }
            for (_, event) in events {
                switch event {
                case .choice(let winnerKey, let loserKey):
                    sgdStep(winnerKey: winnerKey, loserKey: loserKey)
                case .badVerdict(let key):
                    penalizeBadVerdict(key: key)
                }
            }
            saveWeights()
            Self.log.info("Rebuilt weights: seeded=\(self.weights.seededWithFavorites), replayed \(choices.count) choices, \(badVerdicts.count) bad verdicts")
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
        // longer contain what the user has decided, and only a replay can fold
        // the difference in — SGD has no way to add one historical step after
        // the fact. Rebuilding from scratch is the same path a version bump
        // takes and is what makes an arriving photo's judgments count.
        //
        // Same for the favorite set (FR-5.4): `seedFromFavorites()` only ever
        // runs as part of a rebuild, so a favorite Photos discovers after the
        // weights were last built — or one a rescan un-favorites — needs the
        // same rebuild trigger `judgmentCount` already gives explicit choices,
        // or it would never be folded in (or un-folded) at all.
        if weights.judgmentCount != applicableJudgmentCount(choices: choices, badVerdicts: badVerdicts)
            || weights.favoriteFingerprint != Self.favoriteFingerprint(of: entries) {
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
        entries = records.compactMap { record in
            guard let data = record.featurePrint else { return nil }
            return Entry(
                id: record.localIdentifier,
                key: record.judgmentKey,
                vector: data.floatVector,
                isFavorite: record.isFavorite,
                traits: Self.traits(of: record, minWidth: minWidth, resolutionRange: resolutionRange),
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
    /// arrived here yet trains nothing, because `sgdStep` can't find it; when
    /// the photo does arrive, the count changes and `prepare()`/`reload()`
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
    /// losing a duel (FR-4.7/FR-5.7): see `penalizeBadVerdict`. A GOOD
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
        for key in keys {
            penalizeBadVerdict(key: key)
            weights.judgmentCount = (weights.judgmentCount ?? 0) + 1
        }
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
    /// Unlike `recordVerdicts`, this cannot take an incremental SGD step to
    /// undo the training: SGD has no inverse, so the only way to un-apply a
    /// bad verdict's step is to leave it out of a full replay. That means
    /// this forces exactly the rebuild path a version bump or an arriving
    /// synced judgment already takes — `isPrepared = false` then `prepare()`,
    /// which reloads entries, replays every judgment still applicable
    /// (`VerdictCalibration.trainingBadVerdicts` now excludes this photo's
    /// bad verdicts, having seen the clearing record), saves weights,
    /// recomputes scores and rewrites the preference cache. A full weights
    /// replay is real cost, but it is paid only here: clearing is a rare,
    /// deliberate, single-photo action, not the rapid per-choice duel path
    /// FR-8.2 guards (`record`'s debounced cache flush).
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
    /// `scheduleCacheFlush`). Weights are a small file write, kept synchronous.
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

        sgdStep(winnerKey: winnerKey, loserKey: loserKey)
        choiceCount += 1
        // Kept in step with the weights so the next reload doesn't mistake
        // this incremental step for a divergence and rebuild needlessly.
        weights.judgmentCount = (weights.judgmentCount ?? 0) + 1
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
    /// here — then forces the same full-replay rebuild `clearVerdicts` already
    /// takes: SGD has no inverse, so un-applying the step this choice took is
    /// only possible by leaving it out of a fresh replay.
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
    /// Forces the same full-replay rebuild as `undoLastChoice`/`clearVerdicts`:
    /// a bad verdict took an SGD step, and SGD has no inverse, so un-applying
    /// it is only possible by leaving it out of a fresh replay. A *good*
    /// verdict trains nothing and would need no replay, but it does feed the
    /// album-size calibration, which `prepare()` is what refreshes — and one
    /// path for both is worth more here than saving a rebuild on the rarer of
    /// two rare actions.
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

    /// Every `ScalarTrait` read off one record. The single place a trait is
    /// derived, so adding one to `ScalarTrait` means adding one line here.
    ///
    /// Traits the analyzer measured are read straight off the record; the
    /// rest are derived from what the photo records of itself. A record that
    /// predates a trait carries nil for it and is passed through as such —
    /// `TraitValues.set` marks it unknown rather than guessing, which is what
    /// keeps FR-3.8's "ranked on what is known" true through a trait's
    /// introduction.
    private static func traits(
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

        traits.set(.season, record.creationDate.map(Self.seasonFraction))

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
        if let created = record.creationDate, let longitude = record.longitude {
            traits.set(.solarTime, Self.solarTimeFraction(of: created, longitude: longitude))
        }

        traits.set(.personProminence, record.personProminence)
        traits.set(.subjectProminence, record.subjectProminence)
        traits.set(.subjectCentrality, record.subjectCentrality)
        traits.set(.luminance, record.luminance)

        return traits
    }

    /// Looks the pair up by judgment key, so a choice made on another device
    /// trains this one. A key with no local entry — the photo hasn't arrived,
    /// or has left — is skipped, and `applicableJudgmentCount` is what notices
    /// when that changes (FR-9.2).
    private func sgdStep(winnerKey: String, loserKey: String) {
        guard let w = indexByKey[winnerKey], let l = indexByKey[loserKey] else { return }
        sgdStep(winner: entries[w], loser: entries[l])
    }

    /// One pairwise SGD step, "winner" beating "loser" — the primitive both
    /// real duel choices and bad-verdict pseudo-duels (`penalizeBadVerdict`)
    /// go through, so both train the exact same model the exact same way.
    private func sgdStep(winner: Entry, loser: Entry) {
        let probability = Candidate.sigmoid(rawScore(winner) - rawScore(loser))
        let gradient = (1 - probability) * Thresholds.rankerLearningRate

        // L2 weight decay before the gradient step, bounding weight growth.
        let decay = 1 - Thresholds.rankerLearningRate * Thresholds.rankerWeightDecay
        weights.feature = vDSP.multiply(decay, weights.feature)
        weights.scalars = vDSP.multiply(decay, weights.scalars)

        let difference = vDSP.subtract(winner.vector, loser.vector)
        weights.feature = vDSP.add(weights.feature, vDSP.multiply(gradient, difference))
        // FR-3.8: a duel where either side was never measured for a trait
        // trains nothing on it — the difference is forced to 0 rather than
        // comparing a real value against the other side's neutral
        // placeholder, which would otherwise treat "unknown" as if it meant
        // "average" and let the gap itself become a trained signal.
        for trait in ScalarTrait.allCases {
            let index = trait.rawValue
            let bothKnown = winner.traits.known[index] && loser.traits.known[index]
            weights.scalars[index] += gradient
                * (bothKnown ? winner.traits.values[index] - loser.traits.values[index] : 0)
        }
    }

    private func seedFromFavorites() {
        let favorites = entries.indices.filter { entries[$0].isFavorite }
        let others = entries.indices.filter { !entries[$0].isFavorite }
        guard !favorites.isEmpty, !others.isEmpty else {
            weights.seededWithFavorites = true
            return
        }

        // Deterministic RNG so an identical rebuild reproduces the same seeding.
        var rng = SplitMix64(seed: Thresholds.rankerSeedRNG)
        var pairs = 0
        outer: for favorite in favorites.shuffled(using: &rng) {
            for _ in 0..<Thresholds.favoriteSeedOpponents {
                guard pairs < Thresholds.favoriteSeedMaxPairs else { break outer }
                sgdStep(winnerKey: entries[favorite].key, loserKey: entries[others.randomElement(using: &rng)!].key)
                pairs += 1
            }
        }
        weights.seededWithFavorites = true
        Self.log.info("Seeded ranker with \(pairs) favorite pseudo-choices")
    }

    /// Trains a bad verdict into the ranking the same way a lost duel does
    /// (FR-4.7/FR-5.7), as one pairwise SGD step against a fixed "neutral"
    /// reference point rather than a real opponent photo:
    /// - feature vector = all zeros, aesthetics = 0 — aestheticsScore is
    ///   already zero-centered (−1…1), so 0 is a genuine neutral midpoint,
    ///   not an arbitrary choice. These are the two terms the gradient
    ///   actually moves, and they're what generalizes: pushing
    ///   `weights.feature` away from this photo's feature direction is what
    ///   drags visually-similar photos down too ("and others like it",
    ///   FR-4.7), independent of anything else in the candidate set.
    /// - every other trait = copied from the bad photo's own values, known
    ///   flags included, so those SGD terms are always exactly zero. A single
    ///   bad verdict on its own isn't evidence that tilt, resolution, when,
    ///   where, or how bright the photo is *caused* the badness — unlike a
    ///   real duel, there's no second photo to contrast against — so those
    ///   weights stay untouched by verdict training and only ever move from
    ///   actual duel choices. `ScalarTrait.trainsOnVerdict` is where that
    ///   split lives, so a trait added later inherits the safe side of it.
    ///
    /// Using a fixed reference instead of a live opponent is also what makes
    /// this replay-safe (FR-5.3): the pseudo-duel is fully determined by the
    /// bad photo's own stored feature print, never by which other
    /// candidates happen to exist at rebuild time.
    private func penalizeBadVerdict(key: String) {
        guard let index = indexByKey[key] else { return }
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
            traits: reference
        )
        sgdStep(winner: neutral, loser: entry)
    }

    private func rawScore(_ entry: Entry) -> Float {
        vDSP.dot(weights.feature, entry.vector)
            + vDSP.dot(weights.scalars, entry.traits.values)
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
    /// Local solar time of day as a fraction, 0…1 (0 = solar midnight).
    ///
    /// Solar rather than civil time, and derived from longitude rather than
    /// from a stored time zone, because a `PhotoRecord` has no time zone to
    /// store: PhotoKit hands back an absolute instant, and the UTC hour of a
    /// photo means nothing across a library that spans continents — noon in
    /// Zermatt and noon in Vancouver would sit nine hours apart on this
    /// trait despite looking identical. Longitude ÷ 15° per hour recovers
    /// what the light was actually doing, which is what the trait is for: it
    /// is the difference between a golden-hour frame and a midday one.
    ///
    /// It is also a better signal than civil time even where a zone *were*
    /// available — civil zones are political, offset by up to hours from the
    /// sun (China runs one zone across five), and shift under daylight
    /// saving, so two photos of the same light would disagree. It ignores
    /// the equation of time and the seasonal swing in day length, both worth
    /// under a quarter-hour and a fraction of an hour respectively — far
    /// inside the resolution a single learned weight over this scale can use.
    ///
    /// Wrapping is handled by the modulo rather than by the encoding: like
    /// `seasonFraction` this stays one linear scalar, so 23:30 and 00:30 sit
    /// at opposite ends despite being half an hour apart. Same trade for the
    /// same reason — one scalar with one learned weight, and the seam falls
    /// at solar midnight, which is the least photographed moment of the day.
    private static func solarTimeFraction(of date: Date, longitude: Double) -> Float {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let utcHours = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let solarHours = (utcHours + longitude / 15).truncatingRemainder(dividingBy: 24)
        return Float((solarHours < 0 ? solarHours + 24 : solarHours) / 24)
    }

    private static func seasonFraction(of date: Date) -> Float {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let daysInYear = calendar.range(of: .day, in: .year, for: date)?.count ?? 365
        return Float(dayOfYear - 1) / Float(daysInYear)
    }
}
