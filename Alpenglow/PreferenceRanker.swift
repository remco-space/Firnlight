import Accelerate
import Foundation
import SwiftData
import os

/// Online logistic (Bradley–Terry) preference ranker over Vision feature prints.
///
/// Raw score: s = w·featurePrint + b₁·aesthetics + b₂·levelness + b₃·resolution
/// (levelness and resolution weights are learned from duels, never hard-coded —
/// low-resolution or tilted photos are penalized only as much as choices imply).
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
actor PreferenceRanker {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    struct DuelPair: Sendable, Equatable {
        let first: Candidate
        let second: Candidate
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
        let aesthetics: Float
        let isFavorite: Bool
        /// 1 = level horizon or none detected (neutral); 0 = tilted ≥ horizonMaxTiltDegrees.
        let levelness: Float
        let tiltDegrees: Float
        /// 0 at the minimum candidate width, 1 at resolutionFullScoreWidth
        /// (log scale). Its ranking weight is learned from duels, so old
        /// low-resolution photos are penalized only as much as choices imply.
        let resolution: Float
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
        var aesthetics: Float
        var horizon: Float
        var resolution: Float
        var seededWithFavorites: Bool
        /// How many judgments these weights already contain — see
        /// `applicableJudgmentCount`. Optional so weights written before this
        /// existed decode, and simply trigger one rebuild.
        var judgmentCount: Int?
    }

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "PreferenceRanker")

    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    /// `Entry.key` → index. The lookup every judgment goes through, since
    /// judgments are keyed device-independently while `indexByID` is local.
    private var indexByKey: [String: Int] = [:]
    private var weights = Weights(feature: [], aesthetics: 1, horizon: 0, resolution: 0, seededWithFavorites: false)
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

        let dimension = entries.first?.vector.count ?? 0
        if let stored = loadWeights(),
           stored.algorithmVersion == Thresholds.rankerAlgorithmVersion,
           stored.feature.count == dimension,
           stored.judgmentCount == applicable {
            weights = stored
        } else {
            weights = Weights(
                algorithmVersion: Thresholds.rankerAlgorithmVersion,
                feature: Array(repeating: 0, count: dimension),
                aesthetics: 1,
                horizon: 0,
                resolution: 0,
                seededWithFavorites: false,
                judgmentCount: applicable
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
        if weights.judgmentCount != applicableJudgmentCount(choices: choices, badVerdicts: badVerdicts) {
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
    /// candidate (deleted, edited out, ignored, etc.), or if the pair was
    /// already judged — a choice can persist before the next pair's
    /// identifiers do (process death in the window between them), and
    /// re-serving a judged pair would double-count its SGD step — in either
    /// case the caller should fall back to `nextPair()` as if this were a
    /// fresh start.
    func pair(first: String, second: String) -> DuelPair? {
        guard let firstIndex = indexByID[first], let secondIndex = indexByID[second],
              !judgedPairs.contains(Self.pairKey(first, second)) else {
            return nil
        }
        return DuelPair(first: candidate(for: entries[firstIndex]), second: candidate(for: entries[secondIndex]))
    }

    /// Loads every choice in timestamp order, refreshing the judged-pair set
    /// (FR-5.5) and the displayed count (FR-5.8). Returns them so the caller
    /// can also use them for training and the applicable-count check.
    @discardableResult
    private func loadJudgedPairsAndCount() throws -> [ChoiceRecord] {
        let choices = try modelContext.fetch(
            FetchDescriptor<ChoiceRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        judgedPairs = Set(choices.map { Self.pairKey($0.winnerKey, $0.loserKey) })
        choiceCount = choices.count
        return choices
    }

    /// Fetches the current nature, non-excluded candidates into `entries` and
    /// rebuilds `indexByID`. Weights are untouched.
    private func loadEntries() {
        // Sorted by identifier so the deterministic favorite seeding never
        // depends on SwiftData's unspecified default fetch order.
        var descriptor = FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isNature && !$0.isExcluded })
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
            let tilt = abs(record.horizonAngleDegrees ?? 0)
            let resolution = min(1, max(0, log2(Float(record.pixelWidth) / minWidth) / resolutionRange))
            return Entry(
                id: record.localIdentifier,
                key: record.judgmentKey,
                vector: data.floatVector,
                aesthetics: record.aestheticsScore,
                isFavorite: record.isFavorite,
                levelness: 1 - min(tilt, Thresholds.horizonMaxTiltDegrees) / Thresholds.horizonMaxTiltDegrees,
                tiltDegrees: tilt,
                resolution: resolution,
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

            guard !judgedPairs.contains(Self.pairKey(a.id, b.id)) else { continue }
            guard vDSP.distanceSquared(a.vector, b.vector) >= thresholdSquared else { continue }

            let delta = abs(a.score - b.score)
            if best == nil || delta < best!.delta {
                best = (a, b, delta)
            }
        }

        // All samples judged or near-duplicates: fall back to the first
        // still-unjudged pair. Re-serving a judged pair would double-count its
        // SGD step. If every pair is judged, return nil (view has an empty state).
        if best == nil {
            let shuffled = pool.shuffled()
            outer: for i in shuffled.indices {
                for j in shuffled.indices[(i + 1)...] {
                    if !judgedPairs.contains(Self.pairKey(shuffled[i].id, shuffled[j].id)) {
                        best = (shuffled[i], shuffled[j], 0)
                        break outer
                    }
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
    func recordVerdicts(_ localIdentifiers: [String], isGood: Bool, flushSynchronously: Bool = false) throws {
        let now = Date()
        // Callers hand over local identifiers (that is what the UI and
        // PhotoKit deal in); the verdict is filed under the device-independent
        // key so it counts on every device (FR-9.1).
        let keys = localIdentifiers.compactMap { indexByID[$0].map { entries[$0].key } }
        for key in keys {
            modelContext.insert(VerdictRecord(photoKey: key, isGood: isGood, timestamp: now))
        }
        try modelContext.save()

        guard !isGood else { return }
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
    func clearVerdicts(_ localIdentifiers: [String]) throws {
        let now = Date()
        let keys = localIdentifiers.compactMap { indexByID[$0].map { entries[$0].key } }
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
    func record(winnerID: String, loserID: String) throws {
        // Local identifiers in (from the duel cards), device-independent keys
        // stored (FR-9.1). A photo with no entry can't have been dueled.
        guard let winnerKey = indexByID[winnerID].map({ entries[$0].key }),
              let loserKey = indexByID[loserID].map({ entries[$0].key }) else { return }

        modelContext.insert(ChoiceRecord(winnerKey: winnerKey, loserKey: loserKey, timestamp: Date()))
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
    }

    // MARK: Model

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
        weights.aesthetics *= decay
        weights.horizon *= decay
        weights.resolution *= decay

        let difference = vDSP.subtract(winner.vector, loser.vector)
        weights.feature = vDSP.add(weights.feature, vDSP.multiply(gradient, difference))
        weights.aesthetics += gradient * (winner.aesthetics - loser.aesthetics)
        weights.horizon += gradient * (winner.levelness - loser.levelness)
        weights.resolution += gradient * (winner.resolution - loser.resolution)
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
    /// - levelness/resolution = copied from the bad photo's own values, so
    ///   those two SGD terms are always exactly zero. A single bad verdict
    ///   on its own isn't evidence that tilt or resolution *caused* the
    ///   badness — unlike a real duel, there's no second photo to contrast
    ///   against — so `weights.horizon`/`weights.resolution` stay untouched
    ///   by verdict training and only ever move from actual duel choices.
    ///
    /// Using a fixed reference instead of a live opponent is also what makes
    /// this replay-safe (FR-5.3): the pseudo-duel is fully determined by the
    /// bad photo's own stored feature print, never by which other
    /// candidates happen to exist at rebuild time.
    private func penalizeBadVerdict(key: String) {
        guard let index = indexByKey[key] else { return }
        let entry = entries[index]
        let neutral = Entry(
            id: "",
            key: "",
            vector: Array(repeating: 0, count: entry.vector.count),
            aesthetics: 0,
            isFavorite: false,
            levelness: entry.levelness,
            tiltDegrees: 0,
            resolution: entry.resolution
        )
        sgdStep(winner: neutral, loser: entry)
    }

    private func rawScore(_ entry: Entry) -> Float {
        vDSP.dot(weights.feature, entry.vector)
            + weights.aesthetics * entry.aesthetics
            + weights.horizon * entry.levelness
            + weights.resolution * entry.resolution
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

    private var weightsFileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alpenglow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ranker-weights.json")
    }

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
            aestheticsScore: entry.aesthetics,
            isFavorite: entry.isFavorite,
            preferenceScore: entry.score,
            tiltDegrees: entry.tiltDegrees,
            // isIgnored stays at its default (false): `loadEntries()` already
            // excludes ignored photos, so a duel `Entry` is never one.
            isNotWallpaperMaterial: entry.isNotWallpaperMaterial
        )
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }
}
