import Accelerate
import Foundation
import SwiftData
import os

/// Online logistic (Bradley–Terry) preference ranker over Vision feature prints.
///
/// Raw score: s = w · featurePrint + b · aestheticsScore
/// Choice model: P(winner beats loser) = sigmoid(s_winner − s_loser)
/// One SGD step per recorded choice; `PhotoRecord.preferenceScore` caches
/// sigmoid(s) after every update so the grid can re-rank live.
///
/// Weights persist as JSON in Application Support. If the file is missing,
/// weights are rebuilt by seeding from Photos favorites (pseudo-choices:
/// favorite beats random non-favorite) and then replaying every ChoiceRecord
/// in timestamp order.
@ModelActor
actor PreferenceRanker {
    struct DuelPair: Sendable, Equatable {
        let first: Candidate
        let second: Candidate
    }

    private struct Entry {
        let id: String
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
    }

    // An algorithmVersion mismatch (or undecodable file) triggers an automatic
    // rebuild: re-seed from current favorites + full choice replay + re-rank.
    private struct Weights: Codable {
        var algorithmVersion: Int = 1
        var feature: [Float]
        var aesthetics: Float
        var horizon: Float
        var resolution: Float
        var trainedChoices: Int
        var seededWithFavorites: Bool
    }

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "PreferenceRanker")

    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    private var weights = Weights(feature: [], aesthetics: 1, horizon: 0, resolution: 0, trainedChoices: 0, seededWithFavorites: false)
    private var judgedPairs: Set<String> = []
    private var isPrepared = false

    private(set) var choiceCount = 0

    // MARK: Lifecycle

    /// Loads candidate vectors, then loads — or rebuilds — the weights, and
    /// refreshes the preference-score cache.
    func prepare() throws {
        guard !isPrepared else { return }

        let records = try modelContext.fetch(FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isNature }))
        let minWidth = Float(Thresholds.minimumCandidatePixelWidth)
        let resolutionRange = log2(Thresholds.resolutionFullScoreWidth / minWidth)
        entries = records.compactMap { record in
            guard let data = record.featurePrint else { return nil }
            let tilt = abs(record.horizonAngleDegrees ?? 0)
            let resolution = min(1, max(0, log2(Float(record.pixelWidth) / minWidth) / resolutionRange))
            return Entry(
                id: record.localIdentifier,
                vector: data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) },
                aesthetics: record.aestheticsScore,
                isFavorite: record.isFavorite,
                levelness: 1 - min(tilt, Thresholds.horizonMaxTiltDegrees) / Thresholds.horizonMaxTiltDegrees,
                tiltDegrees: tilt,
                resolution: resolution
            )
        }
        indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })

        let choices = try modelContext.fetch(
            FetchDescriptor<ChoiceRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        judgedPairs = Set(choices.map { Self.pairKey($0.winnerID, $0.loserID) })
        choiceCount = choices.count

        let dimension = entries.first?.vector.count ?? 0
        if let stored = loadWeights(),
           stored.algorithmVersion == Thresholds.rankerAlgorithmVersion,
           stored.feature.count == dimension {
            weights = stored
        } else {
            weights = Weights(
                algorithmVersion: Thresholds.rankerAlgorithmVersion,
                feature: Array(repeating: 0, count: dimension),
                aesthetics: 1,
                horizon: 0,
                resolution: 0,
                trainedChoices: 0,
                seededWithFavorites: false
            )
            seedFromFavorites()
            for choice in choices {
                sgdStep(winnerID: choice.winnerID, loserID: choice.loserID)
            }
            weights.trainedChoices = choices.count
            saveWeights()
            Self.log.info("Rebuilt weights: seeded=\(self.weights.seededWithFavorites), replayed \(choices.count) choices")
        }

        recomputeScores()
        try writePreferenceCache()
        isPrepared = true
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

        // All samples judged or near-duplicates: fall back to any distinct pair.
        if best == nil {
            let shuffled = pool.shuffled()
            best = (shuffled[0], shuffled[1], 0)
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
        let aboveCut = sorted.prefix { Self.sigmoid($0.score) > cut }.count
        let bounded = min(max(aboveCut, Thresholds.duelPoolMinimum), fractionCount)
        return Array(sorted.prefix(bounded))
    }

    /// The quality bar from "both great"/"both bad" verdicts: the preference
    /// score that best separates good from bad. Nil until enough bad verdicts.
    private func verdictBar() throws -> Float? {
        let verdicts = try modelContext.fetch(
            FetchDescriptor<VerdictRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        guard !verdicts.isEmpty else { return nil }

        var latest: [String: Bool] = [:]
        for verdict in verdicts { latest[verdict.localIdentifier] = verdict.isGood }

        var good: [Float] = []
        var bad: [Float] = []
        for (id, isGood) in latest {
            guard let index = indexByID[id] else { continue }
            let score = Self.sigmoid(entries[index].score)
            if isGood { good.append(score) } else { bad.append(score) }
        }
        guard bad.count >= Thresholds.albumCalibrationMinimumBadVerdicts else { return nil }

        var bestThreshold = bad.max() ?? 0
        var bestErrors = Int.max
        for threshold in (good + bad).sorted() {
            let errors = good.count(where: { $0 <= threshold }) + bad.count(where: { $0 > threshold })
            if errors <= bestErrors {
                bestErrors = errors
                bestThreshold = threshold
            }
        }
        return bestThreshold
    }

    /// Records absolute quality verdicts ("both great" / "both bad") for the
    /// album-size calibration. Doesn't touch the pairwise weights.
    func recordVerdicts(_ localIdentifiers: [String], isGood: Bool) throws {
        let now = Date()
        for id in localIdentifiers {
            modelContext.insert(VerdictRecord(localIdentifier: id, isGood: isGood, timestamp: now))
        }
        try modelContext.save()
    }

    /// Records a choice, takes one SGD step, persists weights + score cache.
    func record(winnerID: String, loserID: String) throws {
        modelContext.insert(ChoiceRecord(winnerID: winnerID, loserID: loserID, timestamp: Date()))
        judgedPairs.insert(Self.pairKey(winnerID, loserID))

        sgdStep(winnerID: winnerID, loserID: loserID)
        weights.trainedChoices += 1
        choiceCount += 1
        saveWeights()

        recomputeScores()
        try writePreferenceCache()
    }

    // MARK: Model

    private func sgdStep(winnerID: String, loserID: String) {
        guard let w = indexByID[winnerID], let l = indexByID[loserID] else { return }
        let winner = entries[w], loser = entries[l]

        let probability = Self.sigmoid(rawScore(winner) - rawScore(loser))
        let gradient = (1 - probability) * Thresholds.rankerLearningRate

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

        var pairs = 0
        outer: for favorite in favorites.shuffled() {
            for _ in 0..<Thresholds.favoriteSeedOpponents {
                guard pairs < Thresholds.favoriteSeedMaxPairs else { break outer }
                sgdStep(winnerID: entries[favorite].id, loserID: entries[others.randomElement()!].id)
                pairs += 1
            }
        }
        weights.seededWithFavorites = true
        Self.log.info("Seeded ranker with \(pairs) favorite pseudo-choices")
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

    /// Denormalizes sigmoid(score) into PhotoRecord.preferenceScore and saves.
    private func writePreferenceCache() throws {
        let records = try modelContext.fetch(FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isNature }))
        for record in records {
            guard let index = indexByID[record.localIdentifier] else { continue }
            let score = Self.sigmoid(entries[index].score)
            if record.preferenceScore != score {
                record.preferenceScore = score
            }
        }
        try modelContext.save()
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
            preferenceScore: Self.sigmoid(entry.score),
            tiltDegrees: entry.tiltDegrees
        )
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    private static func sigmoid(_ z: Float) -> Float {
        1 / (1 + exp(-max(-30, min(30, z))))
    }
}
