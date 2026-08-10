import Foundation
import SwiftData
import UniformTypeIdentifiers
import os

/// The user's judgments, in a form that can leave the device and come back
/// (FR-7.4) — and the one place that deliberately throws them away (FR-7.5).
///
/// **Why a file, and why only this.** Choices, verdicts and ignores are the one
/// thing the app cannot recompute: scan results and Vision analysis can be
/// rebuilt from the library at the cost of time, but nobody can reconstruct
/// which of two photos the user preferred at three in the morning. Section 9's
/// transport, which would carry them between devices on its own, is parked for
/// want of an iCloud entitlement — so until then one container is the only copy
/// of the irreplaceable half, and a way to copy it off is what stands between a
/// lost container and a total loss. Everything else is left out on purpose: an
/// archive of feature prints would be larger by orders of magnitude and worth
/// nothing, since re-analysis reproduces it exactly.
///
/// **Keys travel, identifiers don't.** Every judgment is filed under
/// `PhotoRecord.judgmentKey` — the photo's cloud identifier where one is known
/// (see `PhotoRecord`) — which is precisely what makes an archive meaningful on
/// another device: the same photo is the same key there. A judgment that was
/// recorded before its photo's cloud identifier resolved travels under the
/// local one and simply means nothing elsewhere, exactly as FR-9.2 already has
/// it; `LibraryScanner.rekeyJudgments` moves it across on both devices once the
/// resolution lands.
///
/// **Restoring merges; it never replaces.** The archive is added to what is
/// already there, skipping rows the store already holds, so restoring onto a
/// device that has been used since the copy was made keeps both sets of
/// judgments rather than rewinding to the archive's moment. Identity is the
/// row's own values — the same test `JudgmentStore`'s legacy migration uses,
/// and for the same reason: a replayed duel choice is not a harmless duplicate
/// but a second SGD step the user never made.
nonisolated enum JudgmentArchive {
    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "JudgmentArchive")

    /// The archive's own file type, so the exporter and importer name the same
    /// thing. Plain JSON — readable, diffable, and requiring nothing of a
    /// future version but that it can still parse it.
    static let contentType: UTType = .json

    static var defaultFilename: String { "Alpenglow Judgments" }

    // MARK: The archive format

    /// Bumped only if the shape below changes incompatibly. A reader that
    /// meets a version it doesn't know refuses the file and says so rather
    /// than importing half of it (FR-8.12) — the same rule FR-7.3 sets for the
    /// store itself.
    static let currentFormatVersion = 1

    struct Archive: Codable {
        var formatVersion = currentFormatVersion
        var exportedAt = Date()
        var choices: [Choice] = []
        var verdicts: [Verdict] = []
        var ignores: [Ignore] = []

        struct Choice: Codable {
            var winnerKey: String
            var loserKey: String
            var timestamp: Date
        }

        struct Verdict: Codable {
            var photoKey: String
            var isGood: Bool
            var isCleared: Bool
            var timestamp: Date
        }

        struct Ignore: Codable {
            var photoKey: String
            var isIgnored: Bool
            var timestamp: Date
        }
    }

    /// What a restore did, so the user is told rather than left to guess
    /// whether anything happened.
    struct RestoreSummary: Sendable, Equatable {
        var choices = 0
        var verdicts = 0
        var ignores = 0
        var skipped = 0

        var isEmpty: Bool { choices == 0 && verdicts == 0 && ignores == 0 }
    }

    enum ArchiveError: LocalizedError {
        case unreadableFormat(version: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableFormat(let version):
                "This file was written by a newer version of Alpenglow (format \(version)). Nothing was changed — update Alpenglow and try again."
            }
        }
    }

    // MARK: Copying off the device (FR-7.4)

    /// Reads every judgment out of the store. `@concurrent` because it walks
    /// three tables and the interface must not wait on it (FR-8.2).
    @concurrent
    static func export(container: ModelContainer) async throws -> Data {
        let context = ModelContext(container)
        var archive = Archive()
        archive.choices = try context.fetch(FetchDescriptor<ChoiceRecord>()).map {
            Archive.Choice(winnerKey: $0.winnerKey, loserKey: $0.loserKey, timestamp: $0.timestamp)
        }
        archive.verdicts = try context.fetch(FetchDescriptor<VerdictRecord>()).map {
            Archive.Verdict(photoKey: $0.photoKey, isGood: $0.isGood, isCleared: $0.isCleared, timestamp: $0.timestamp)
        }
        archive.ignores = try context.fetch(FetchDescriptor<IgnoreRecord>()).map {
            Archive.Ignore(photoKey: $0.photoKey, isIgnored: $0.isIgnored, timestamp: $0.timestamp)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        log.info("Exported \(archive.choices.count) choices, \(archive.verdicts.count) verdicts, \(archive.ignores.count) ignores")
        return try encoder.encode(archive)
    }

    /// Merges an archive into this device's judgments (FR-7.4's other half).
    @concurrent
    static func restore(from data: Data, container: ModelContainer) async throws -> RestoreSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: data)
        guard archive.formatVersion <= currentFormatVersion else {
            throw ArchiveError.unreadableFormat(version: archive.formatVersion)
        }

        let context = ModelContext(container)
        var existingChoices = Set(try context.fetch(FetchDescriptor<ChoiceRecord>())
            .map { identity($0.winnerKey, $0.loserKey, $0.timestamp) })
        var existingVerdicts = Set(try context.fetch(FetchDescriptor<VerdictRecord>())
            .map { identity($0.photoKey, "\($0.isGood)|\($0.isCleared)", $0.timestamp) })
        var existingIgnores = Set(try context.fetch(FetchDescriptor<IgnoreRecord>())
            .map { identity($0.photoKey, "\($0.isIgnored)", $0.timestamp) })

        var summary = RestoreSummary()
        for choice in archive.choices {
            let key = identity(choice.winnerKey, choice.loserKey, choice.timestamp)
            guard existingChoices.insert(key).inserted else { summary.skipped += 1; continue }
            context.insert(ChoiceRecord(winnerKey: choice.winnerKey, loserKey: choice.loserKey, timestamp: choice.timestamp))
            summary.choices += 1
        }
        for verdict in archive.verdicts {
            let key = identity(verdict.photoKey, "\(verdict.isGood)|\(verdict.isCleared)", verdict.timestamp)
            guard existingVerdicts.insert(key).inserted else { summary.skipped += 1; continue }
            context.insert(VerdictRecord(
                photoKey: verdict.photoKey,
                isGood: verdict.isGood,
                isCleared: verdict.isCleared,
                timestamp: verdict.timestamp
            ))
            summary.verdicts += 1
        }
        for ignore in archive.ignores {
            let key = identity(ignore.photoKey, "\(ignore.isIgnored)", ignore.timestamp)
            guard existingIgnores.insert(key).inserted else { summary.skipped += 1; continue }
            context.insert(IgnoreRecord(photoKey: ignore.photoKey, isIgnored: ignore.isIgnored, timestamp: ignore.timestamp))
            summary.ignores += 1
        }
        try context.save()
        log.info("Restored \(summary.choices) choices, \(summary.verdicts) verdicts, \(summary.ignores) ignores (\(summary.skipped) already here)")
        return summary
    }

    /// A row's own values, which is what makes a restore idempotent: the same
    /// archive imported twice adds nothing the second time.
    private static func identity(_ first: String, _ second: String, _ timestamp: Date) -> String {
        "\(first)|\(second)|\(timestamp.timeIntervalSinceReferenceDate)"
    }

    // MARK: Starting over (FR-7.5)

    /// What a reset would take and what it would leave, in the words the
    /// confirmation shows. Held here, beside the code that does it, so the two
    /// cannot come to describe different things.
    static let resetGoesAway = "Every duel choice, every “Both Are Great” and “Both Are Bad”, every “Not Wallpaper Material” verdict and every ignored photo, along with the ranking learned from them."
    static let resetStays = "Your photos, the wallpaper album in Photos, and everything the app has scanned and analyzed. Alpenglow starts ranking from your Photos favorites again, as it did on the first launch."

    /// Discards everything the app has learned about the user's taste.
    ///
    /// Three things have to go together, or the reset is a half-reset: the
    /// judgments themselves, the weights they were baked into (which would
    /// otherwise keep ranking by the taste just discarded), and the cached
    /// scores in the photo records (which would otherwise keep the old order on
    /// screen until something happened to rewrite them). The ignore flag on
    /// each photo goes too — it is a cache of an `IgnoreRecord`, and records
    /// deleted while the flags stayed would leave photos out of the grid with
    /// no judgment left to explain why.
    ///
    /// The photos, the album and the analysis are untouched, which is the half
    /// of FR-7.5's promise that the confirmation has to be able to make
    /// truthfully.
    @concurrent
    static func resetLearnedTaste(container: ModelContainer) async throws {
        let context = ModelContext(container)
        try context.delete(model: ChoiceRecord.self)
        try context.delete(model: VerdictRecord.self)
        try context.delete(model: IgnoreRecord.self)
        for record in try context.fetch(FetchDescriptor<PhotoRecord>()) {
            record.isExcluded = false
            record.preferenceScore = nil
        }
        try context.save()
        try? FileManager.default.removeItem(at: PreferenceRanker.weightsFileURL)
        log.info("Learned taste reset: judgments, weights and cached scores discarded")
    }
}
