import Accelerate
import Foundation
import SwiftData
import os

/// A ranked, deduplicated wallpaper candidate ready for display.
nonisolated struct Candidate: Sendable, Identifiable, Equatable {
    let localIdentifier: String
    let aestheticsScore: Float
    let isFavorite: Bool
    let preferenceScore: Float
    /// Horizon tilt in degrees; 0 when level or no horizon detected.
    let tiltDegrees: Float

    var id: String { localIdentifier }
}

/// SwiftData queries for the ranking pipeline.
@ModelActor
actor FeatureStore {
    struct RankedResult: Sendable, Equatable {
        let candidates: [Candidate]
        let acceptedCount: Int
        let suppressedCount: Int
    }

    /// Top candidates ranked by aesthetics score, with greedy near-duplicate
    /// suppression: walking the ranked list, a candidate is dropped when its
    /// feature-print distance to any already-kept candidate is below
    /// `Thresholds.nearDuplicateDistance` — unless the candidate is a Photos
    /// favorite and the kept one isn't, in which case the favorite takes over
    /// that cluster's slot.
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

    private func rankedCore(limit: Int) throws -> (kept: [Candidate], vectors: [[Float]], accepted: Int, suppressed: Int) {
        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature }
        )
        let fetched = try modelContext.fetch(descriptor)

        // Once the preference ranker has written its cache, rank by learned
        // preference (favorites influence it via seeding). Until then, fall
        // back to aesthetics plus the favorite prior.
        let usePreference = fetched.contains { $0.preferenceScore != 0 }
        func rankScore(_ record: PhotoRecord) -> Float {
            usePreference
                ? record.preferenceScore
                : record.aestheticsScore + (record.isFavorite ? Thresholds.favoriteRankBoost : 0)
        }
        let records = fetched.sorted { rankScore($0) > rankScore($1) }

        let thresholdSquared = Thresholds.nearDuplicateDistance * Thresholds.nearDuplicateDistance
        var kept: [Candidate] = []
        var keptVectors: [[Float]] = []
        var suppressed = 0

        // The walk continues past `limit` so a favorite ranked below the
        // cutoff can still claim its duplicate cluster's slot.
        for record in records {
            guard let data = record.featurePrint else { continue }
            let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            let clusterIndex = keptVectors.firstIndex {
                $0.count == vector.count && vDSP.distanceSquared($0, vector) < thresholdSquared
            }
            if let clusterIndex {
                // Cluster preference: favorite beats non-favorite; on equal
                // favorite status, the clearly more level image wins.
                let kept0 = kept[clusterIndex]
                let tilt = abs(record.horizonAngleDegrees ?? 0)
                let favoriteWins = record.isFavorite && !kept0.isFavorite
                let levelnessWins = record.isFavorite == kept0.isFavorite
                    && tilt + Thresholds.duplicateTiltMargin < kept0.tiltDegrees
                if favoriteWins || levelnessWins {
                    kept[clusterIndex] = candidate(for: record)
                    keptVectors[clusterIndex] = vector
                }
                suppressed += 1
            } else if kept.count < limit {
                kept.append(candidate(for: record))
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
        let scores = candidates.map { $0.preferenceScore != 0 ? $0.preferenceScore : $0.aestheticsScore }
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

        // Latest verdict per photo wins, valued at the photo's current score.
        var latest: [String: Bool] = [:]
        for verdict in verdicts { latest[verdict.localIdentifier] = verdict.isGood }
        let ids = Array(latest.keys)
        let records = try modelContext.fetch(
            FetchDescriptor<PhotoRecord>(predicate: #Predicate { ids.contains($0.localIdentifier) })
        )
        var good: [Float] = []
        var bad: [Float] = []
        for record in records {
            if latest[record.localIdentifier] == true {
                good.append(record.preferenceScore)
            } else {
                bad.append(record.preferenceScore)
            }
        }
        guard bad.count >= Thresholds.albumCalibrationMinimumBadVerdicts else { return nil }

        // Optimal 1-D split: minimize (goods below t) + (bads above t);
        // ascending scan means ties resolve to the higher (stricter) threshold.
        var bestThreshold = bad.max() ?? 0
        var bestErrors = Int.max
        for threshold in (good + bad).sorted() {
            let errors = good.count(where: { $0 <= threshold }) + bad.count(where: { $0 > threshold })
            if errors <= bestErrors {
                bestErrors = errors
                bestThreshold = threshold
            }
        }

        let above = try dedupedCount(aboveBar: bestThreshold)
        let clamped = max(Thresholds.albumSuggestionMinimum, above)
        let suggestion = ((clamped + 5) / 10) * 10
        Self.log.info("Album suggestion (verdicts): good=\(good.count) bad=\(bad.count) threshold=\(String(format: "%.3f", bestThreshold), privacy: .public) errors=\(bestErrors) above=\(above) suggested=\(suggestion)")
        return suggestion
    }

    /// Deduplicated candidates scoring above the bar — walks the ranked list
    /// and stops at the bar, so cost scales with album size, not library size.
    private func dedupedCount(aboveBar bar: Float) throws -> Int {
        let fetched = try modelContext.fetch(FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isNature }))
        let records = fetched.sorted { $0.preferenceScore > $1.preferenceScore }
        let thresholdSquared = Thresholds.nearDuplicateDistance * Thresholds.nearDuplicateDistance

        var keptVectors: [[Float]] = []
        for record in records {
            guard record.preferenceScore > bar else { break }
            guard let data = record.featurePrint else { continue }
            let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
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

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "FeatureStore")

    private func candidate(for record: PhotoRecord) -> Candidate {
        Candidate(
            localIdentifier: record.localIdentifier,
            aestheticsScore: record.aestheticsScore,
            isFavorite: record.isFavorite,
            preferenceScore: record.preferenceScore,
            tiltDegrees: abs(record.horizonAngleDegrees ?? 0)
        )
    }
}
