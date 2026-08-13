import Accelerate
import Foundation
import SwiftData
import os

/// A ranked, deduplicated wallpaper candidate ready for display.
nonisolated struct Candidate: Sendable, Identifiable, Equatable {
    let localIdentifier: String
    let aestheticsScore: Float
    let isFavorite: Bool
    /// Raw (pre-sigmoid) preference score; nil until the ranker has scored it.
    let preferenceScore: Float?
    /// FR-4.8's "Ignore This Photo" state — `PhotoRecord.isExcluded` — carried
    /// on the candidate itself, rather than looked up per cell, so the grid's
    /// thumbnail overlay can render the toggle's current state without a
    /// per-cell fetch on the main actor (FR-8.2). Defaulted so every existing
    /// memberwise-init call site (duel cards, in particular, which don't
    /// carry either verdict flag) keeps compiling.
    // `var`, not `let`: a `let` stored property with an inline default is
    // excluded from the synthesized memberwise initializer entirely (it
    // becomes fixed at that value, unassignable via `init`), which is the
    // opposite of what's needed here — every existing call site should keep
    // compiling with these defaulting to `false`, while the handful that do
    // know the photo's verdict/ignore state still need to pass it in.
    var isIgnored: Bool = false
    /// FR-4.6's "Not Wallpaper Material" toggle's current state: whether the
    /// photo's *latest* verdict (FR-4.9 — however given, grid action or a
    /// duel's "Both Are Bad") is bad. Same rationale as `isIgnored`: rides on
    /// `Candidate` so the overlay renders live without a per-cell fetch.
    var isNotWallpaperMaterial: Bool = false

    var id: String { localIdentifier }

    /// 0–1 number for the UI: sigmoid of the raw preference score once the
    /// ranker has run, else the aesthetics prior.
    var displayScore: Float {
        preferenceScore.map(Candidate.sigmoid) ?? aestheticsScore
    }

    /// Logistic squash shared by the ranker and the display layer.
    static func sigmoid(_ z: Float) -> Float {
        1 / (1 + exp(-max(-30, min(30, z))))
    }
}

extension Data {
    /// Reinterprets raw bytes as a feature-print vector.
    nonisolated var floatVector: [Float] {
        withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// SwiftData queries for the ranking pipeline.
///
/// A plain actor owning its own `ModelContext` — deliberately NOT
/// `@ModelActor`. `@ModelActor`'s `DefaultSerialModelExecutor` runs each job
/// on the thread of whichever caller awaited it (verified empirically on
/// macOS 27 with a probe): called from main-actor code, as every view model
/// in this app does, every fetch/rank/dedupe silently became main-thread
/// work — the FR-8.2 beachball on switching to the Export tab was
/// `suggestedAlbumSize()`'s O(n²) dedupe walk sampled ON the main thread
/// despite living in a "background" model actor. A plain actor's default
/// executor lives on the cooperative pool, so cross-actor calls genuinely
/// hop off main. The context is created in the init and only ever touched
/// from actor-isolated methods, preserving SwiftData's serialized-access
/// requirement. `PreferenceRanker` and `AnalysisQueue` follow the same
/// pattern for the same reason.
actor FeatureStore {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    struct RankedResult: Sendable, Equatable {
        let candidates: [Candidate]
        let acceptedCount: Int
        let suppressedCount: Int
    }

    /// Top candidates in rank order, with greedy near-duplicate suppression:
    /// walking the ranked list best-first, a candidate is dropped when its
    /// feature-print distance to any already-kept candidate is below
    /// `Thresholds.nearDuplicateDistance`. The walk's order *is* the ranking,
    /// so the first member of a cluster it reaches is already that cluster's
    /// best by the standard everything else here ranks by, and nothing later
    /// ever takes the slot from it — FR-4.3, "the app keeps the best of the
    /// bunch by the same standards it ranks by".
    func rankedCandidates(limit: Int = Thresholds.gridMaxCandidates) throws -> RankedResult {
        let core = try rankedCore(limit: limit)
        return RankedResult(
            candidates: core.kept,
            acceptedCount: core.accepted,
            suppressedCount: core.suppressed
        )
    }

    /// Album contents in playback order: membership is the top `limit` by
    /// rank, but the sequence greedily maximizes the minimum feature-print
    /// distance to recently placed photos, so consecutive wallpapers look as
    /// different as possible.
    func albumCandidates(limit: Int) throws -> RankedResult {
        let core = try rankedCore(limit: limit)
        return RankedResult(
            candidates: diversityOrdered(core.kept, vectors: core.vectors),
            acceptedCount: core.accepted,
            suppressedCount: core.suppressed
        )
    }

    /// Ignored photos (isExcluded), newest first — for the Library tab's
    /// Ignored view (FR-4.9), where the same toggle un-ignores them.
    func ignoredCandidates() throws -> [Candidate] {
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isExcluded },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        let badVerdictKeys = try latestBadVerdictKeys()
        return try modelContext.fetch(descriptor).map { candidate(for: $0, badVerdictKeys: badVerdictKeys) }
    }

    /// Photos whose *latest* verdict is bad (FR-4.9), however given — a grid
    /// "Not Wallpaper Material" or a duel's "Both Are Bad" write the same
    /// `VerdictRecord` shape — newest first, for the Library tab's own view.
    ///
    /// Ignored photos are excluded (`isNature && !isExcluded`, same as the
    /// ranked queries) even if they also carry a bad verdict: an ignored
    /// photo is fully out of the pipeline and the Ignored view already owns
    /// showing it; listing it here too would surface it somewhere its
    /// ignored state isn't visible. Un-ignoring it brings it back to this
    /// list on the next fetch if the bad verdict is still its latest one.
    func notWallpaperMaterialCandidates() throws -> [Candidate] {
        let badVerdictKeys = try latestBadVerdictKeys()
        guard !badVerdictKeys.isEmpty else { return [] }
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
            .filter { badVerdictKeys.contains($0.judgmentKey) }
            .map { candidate(for: $0, badVerdictKeys: badVerdictKeys) }
    }

    /// `PhotoRecord.judgmentKey`s whose latest verdict (FR-4.9) is bad.
    /// Fetched and reduced ONCE per public query — never per record — and
    /// threaded into `candidate(for:badVerdictKeys:)`, the same once-per-query
    /// discipline `rankedCore` already applies to its own vector-distance
    /// walk: a per-cell fetch would run on the calling actor for every row
    /// in the grid, which is exactly the kind of per-row store traffic
    /// FR-8.2 exists to avoid.
    private func latestBadVerdictKeys() throws -> Set<String> {
        let verdicts = try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        let latest = VerdictCalibration.latestByPhoto(verdicts)
        return Set(latest.compactMap { key, isGood in isGood ? nil : key })
    }

    private func rankedCore(limit: Int) throws -> (kept: [Candidate], vectors: [[Float]], accepted: Int, suppressed: Int) {
        // Same serving-generation restriction as
        // `PreferenceRanker.loadEntries()`, and for the same reason (FR-5.2):
        // this walk ranks candidates against one another by score, so a photo
        // carrying a different Vision pipeline's feature print and aesthetics
        // score can't be compared "on equal terms" against one examined the
        // serving generation's way. It rejoins the grid/album once
        // `AnalysisQueue` re-examines it in the background and the new
        // generation takes over — see `AnalysisGeneration`.
        let version = AnalysisGeneration.servingVersion(in: modelContext)
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion == version }
        )
        let fetched = try modelContext.fetch(descriptor)
        let badVerdictKeys = try latestBadVerdictKeys()

        // Two tiers: records the ranker has scored rank by their raw score;
        // unscored ones (new scans, edited photos awaiting rescore) sit BELOW
        // all of them, ordered by aesthetics plus the favorite prior. Raw
        // scores are unbounded and the prior is 0–1, so the two scales must
        // never interleave. Unscored records are short-lived: analysis
        // completion triggers a ranker rescore (AnalysisModel).
        func rankKey(_ record: PhotoRecord) -> (Int, Float) {
            if let score = record.preferenceScore {
                (1, score)
            } else {
                (0, record.aestheticsScore + (record.isFavorite ? Thresholds.favoriteRankBoost : 0))
            }
        }
        let records = fetched.sorted { rankKey($0) > rankKey($1) }

        let thresholdSquared = Thresholds.nearDuplicateDistance * Thresholds.nearDuplicateDistance
        var kept: [Candidate] = []
        var keptVectors: [[Float]] = []
        var suppressed = 0

        // The walk stops at the cutoff. Nothing below it can change the
        // result any more: it can neither be kept (the grid is full) nor take
        // a cluster slot from something ranked above it, since FR-4.3 hands
        // every cluster to its best-ranked member and the walk has already
        // passed it. `suppressed` therefore counts the duplicates found down
        // to the cutoff, which is also what keeps the walk off
        // O(library × limit × dims) on every load.
        for record in records {
            if kept.count >= limit { break }
            guard let data = record.featurePrint else { continue }
            let vector = data.floatVector

            let clusterIndex = keptVectors.firstIndex {
                $0.count == vector.count && vDSP.distanceSquared($0, vector) < thresholdSquared
            }
            if clusterIndex != nil {
                // The cluster already holds its best member: `records` is
                // sorted best-first by `rankKey`, the same standard the whole
                // app ranks by, so whatever was kept first outranks this.
                // Nothing is swapped in over it on a standard ranking itself
                // doesn't use — an earlier revision handed the slot to a
                // Photos favorite, or to the more level of the two, either of
                // which could demote a higher-ranked photo on grounds the
                // user's own choices never asked for (FR-4.3, and FR-5.2's
                // "no trait counts for more or less than the user's own
                // decisions imply" — favoriteness and levelness both already
                // reach the ranking through learned weights).
                suppressed += 1
            } else {
                kept.append(candidate(for: record, badVerdictKeys: badVerdictKeys))
                keptVectors.append(vector)
            }
        }

        return (kept, keptVectors, records.count, suppressed)
    }

    /// Greedy max-min ordering: start from the top-ranked photo, then always
    /// append the remaining photo whose minimum distance to the last
    /// `albumDiversityWindow` placed photos is largest.
    private func diversityOrdered(_ candidates: [Candidate], vectors: [[Float]]) -> [Candidate] {
        guard candidates.count > 2 else { return candidates }

        var remaining = Array(candidates.indices.dropFirst())
        var order = [candidates.indices.first!]

        while !remaining.isEmpty {
            let recent = order.suffix(Thresholds.albumDiversityWindow)
            var bestPosition = 0
            var bestSeparation = -Float.greatestFiniteMagnitude
            for (position, index) in remaining.enumerated() {
                var separation = Float.greatestFiniteMagnitude
                for placed in recent {
                    separation = min(separation, vDSP.distanceSquared(vectors[index], vectors[placed]))
                }
                if separation > bestSeparation {
                    bestSeparation = separation
                    bestPosition = position
                }
            }
            order.append(remaining.remove(at: bestPosition))
        }
        return order.map { candidates[$0] }
    }

    /// Suggests how many photos belong in the wallpaper album.
    ///
    /// Primary: calibration from "both great"/"both bad" duel verdicts — finds
    /// the score threshold that best separates good from bad verdicts and
    /// counts the deduplicated candidates above it, UNCAPPED: if the whole
    /// library clears the bar, the album is the whole library. Fallback (too
    /// few bad verdicts): the knee of the ranked score curve (Kneedle-style —
    /// max deviation from the endpoint chord, per Satopää et al. 2011).
    func suggestedAlbumSize() throws -> Int {
        if let calibrated = try verdictCalibratedSize() {
            return calibrated
        }

        let candidates = try rankedCandidates(limit: Thresholds.albumSuggestionScanLimit).candidates
        let scores = candidates.map { $0.displayScore }
        guard scores.count > Thresholds.albumSuggestionMinimum else {
            return max(1, min(scores.count, Thresholds.defaultWallpaperCount))
        }
        return kneeSize(scores: scores)
    }

    /// Verdict scores → optimal split threshold → count of candidates above it.
    private func verdictCalibratedSize() throws -> Int? {
        let verdicts = try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        guard !verdicts.isEmpty else { return nil }

        // Latest verdict per photo wins, valued at the photo's current raw score.
        // Verdicts are keyed device-independently (FR-9.1) while PhotoRecord is
        // keyed locally, so the join runs in memory over the photo table rather
        // than as a `#Predicate`: `judgmentKey` is computed, and the two models
        // live in different stores, neither of which a predicate can span.
        //
        // Same `isNature && !isExcluded` + serving-generation restriction
        // `rankedCore`/`dedupedCount` already apply, and for the same reason
        // (FR-5.2): this is a threshold built from photos' standings, so an
        // ignored photo or one carrying a `preferenceScore` from a different
        // Vision pipeline (never cleared once its `analysisVersion` falls out
        // of the serving generation — see
        // `PreferenceRanker.writePreferenceCache`) must not be weighed into
        // the split as though it were on equal terms. Resolved once here and
        // handed to `dedupedCount` rather than re-read there, so both halves
        // of one calibration pass judge the same generation even if a
        // handover lands between them (see `AnalysisGeneration`).
        let version = AnalysisGeneration.servingVersion(in: modelContext)
        let latest = VerdictCalibration.latestByPhoto(verdicts)
        let records = try modelContext.fetch(FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion == version }
        ))
        var good: [Float] = []
        var bad: [Float] = []
        for record in records {
            guard let score = record.preferenceScore,
                  let isGood = latest[record.judgmentKey] else { continue }
            if isGood {
                good.append(score)
            } else {
                bad.append(score)
            }
        }
        guard bad.count >= Thresholds.albumCalibrationMinimumBadVerdicts else { return nil }

        let bestThreshold = VerdictCalibration.optimalSplitThreshold(good: good, bad: bad)
        let bestErrors = good.count(where: { $0 <= bestThreshold }) + bad.count(where: { $0 > bestThreshold })

        let above = try dedupedCount(aboveBar: bestThreshold, analysisVersion: version)
        let clamped = max(Thresholds.albumSuggestionMinimum, above)
        let suggestion = ((clamped + 5) / 10) * 10
        Self.log.info("Album suggestion (verdicts): good=\(good.count) bad=\(bad.count) threshold=\(String(format: "%.3f", bestThreshold), privacy: .public) errors=\(bestErrors) above=\(above) suggested=\(suggestion)")
        return suggestion
    }

    /// Deduplicated candidates scoring above the bar — walks the ranked list
    /// and stops at the bar, so cost scales with album size, not library size.
    ///
    /// Same serving-generation restriction as
    /// `rankedCore`/`verdictCalibratedSize` (FR-5.2): a photo carrying an
    /// out-of-generation `preferenceScore` must not be counted toward the bar
    /// as though it were on equal terms with the rest. The generation is the
    /// caller's already-resolved one (`verdictCalibratedSize` is the only
    /// caller), not re-derived here — see there.
    private func dedupedCount(aboveBar bar: Float, analysisVersion version: Int) throws -> Int {
        let fetched = try modelContext.fetch(FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.analysisVersion == version }
        ))
        // Unscored records sort to the bottom and break the walk at the bar.
        let records = fetched.sorted { ($0.preferenceScore ?? -.greatestFiniteMagnitude) > ($1.preferenceScore ?? -.greatestFiniteMagnitude) }
        let thresholdSquared = Thresholds.nearDuplicateDistance * Thresholds.nearDuplicateDistance

        var keptVectors: [[Float]] = []
        for record in records {
            guard let score = record.preferenceScore, score > bar else { break }
            guard let data = record.featurePrint else { continue }
            let vector = data.floatVector
            let isNearDuplicate = keptVectors.contains {
                $0.count == vector.count && vDSP.distanceSquared($0, vector) < thresholdSquared
            }
            if !isNearDuplicate {
                keptVectors.append(vector)
            }
        }
        return keptVectors.count
    }

    /// Knee of the ranked score curve, normalized to the unit square with the
    /// chord running (0,1) → (1,0).
    private func kneeSize(scores: [Float]) -> Int {
        guard let first = scores.first, let last = scores.last else {
            return Thresholds.defaultWallpaperCount
        }
        let spread = first - last
        guard spread >= Thresholds.albumSuggestionMinimumSpread else {
            // Curve too flat to carry a signal (e.g. barely-trained ranker).
            return Thresholds.defaultWallpaperCount
        }

        var kneeIndex = 0
        var bestDeviation: Float = 0
        let lastIndex = Float(scores.count - 1)
        for (index, score) in scores.enumerated() {
            let x = Float(index) / lastIndex
            let y = (score - last) / spread
            let deviation = abs((1 - x) - y)
            if deviation > bestDeviation {
                bestDeviation = deviation
                kneeIndex = index
            }
        }

        let clamped = max(Thresholds.albumSuggestionMinimum, kneeIndex + 1)
        let suggestion = ((clamped + 5) / 10) * 10

        // Curve diagnostics for threshold tuning against real library data.
        let samples = stride(from: 0, to: scores.count, by: 25)
            .map { "\($0):\(String(format: "%.3f", scores[$0]))" }
            .joined(separator: " ")
        Self.log.info("Album suggestion (knee): knee=\(kneeIndex + 1) deviation=\(String(format: "%.3f", bestDeviation), privacy: .public) spread=\(String(format: "%.3f", spread), privacy: .public) suggested=\(suggestion) curve[\(samples, privacy: .public)]")

        return suggestion
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "FeatureStore")

    /// `badVerdictKeys` is `latestBadVerdictKeys()`'s result, fetched once by
    /// the caller and passed through — never re-fetched here — so scoring a
    /// whole grid's worth of records costs one verdict fetch, not one per row.
    private func candidate(for record: PhotoRecord, badVerdictKeys: Set<String>) -> Candidate {
        Candidate(
            localIdentifier: record.localIdentifier,
            aestheticsScore: record.aestheticsScore,
            isFavorite: record.isFavorite,
            preferenceScore: record.preferenceScore,
            // preferenceScore is the record's raw cached score (nil = unscored).
            isIgnored: record.isExcluded,
            isNotWallpaperMaterial: badVerdictKeys.contains(record.judgmentKey)
        )
    }
}
