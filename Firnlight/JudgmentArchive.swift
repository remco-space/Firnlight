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
///
/// **A correction still updates a row already here.** A *toggle's* correction
/// — `VerdictRecord.isCleared`, `IgnoreRecord.isIgnored` — is append-only: a
/// new row with a later timestamp, so it always has fresh identity and is
/// never mistaken for a duplicate. FR-5.12's in-the-moment undo is the
/// exception, for both judgment kinds it applies to (`ChoiceRecord.isVoided`,
/// `VerdictRecord.isVoided`): taking a judgment back marks the *same* row in
/// place rather than appending one (see those doc comments for why), so its
/// identity never changes. Without special handling, an archive exported
/// after an undo would look like a plain duplicate of a judgment this device
/// already imported before the undo, and the correction would silently never
/// arrive: exactly what FR-5.12 forbids now that it says a correction
/// "travels wherever, and by whatever route, the judgment it corrects travels
/// (FR-9.1) — and a correction that arrives after the judgment it corrects
/// still wins." So a matching identity is not simply skipped: if the incoming
/// row is voided and the local one isn't, the local row is corrected in
/// place. Voiding has no undo of its own (`DuelModel` never re-offers Undo
/// for the same action twice), so this is a safe one-way merge — never the
/// reverse.
nonisolated enum JudgmentArchive {
    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "JudgmentArchive")

    /// The archive's own file type, so the exporter and importer name the same
    /// thing. Plain JSON — readable, diffable, and requiring nothing of a
    /// future version but that it can still parse it.
    static let contentType: UTType = .json

    static var defaultFilename: String { "Firnlight Judgments" }

    // MARK: The archive format

    /// Bumped only if the shape below changes incompatibly. A reader that
    /// meets a version it doesn't know refuses the file and says so rather
    /// than importing half of it (FR-8.12) — the same rule FR-7.3 sets for the
    /// store itself.
    ///
    /// Adding `Archive.standard` did not earn a bump: it is an optional field,
    /// so `JSONDecoder` leaves it `nil` when reading an archive written before
    /// it existed, and ignores it (as it does any unknown key) when an older
    /// build reads an archive that carries one. Neither direction misreads
    /// what the other wrote — the file just says less than it might. A bump
    /// is for a change where that stops being true: a renamed or repurposed
    /// key that an older or newer reader would misinterpret rather than
    /// simply not see.
    static let currentFormatVersion = 1

    struct Archive: Codable {
        var formatVersion = currentFormatVersion
        var exportedAt = Date()
        var choices: [Choice] = []
        var verdicts: [Verdict] = []
        var ignores: [Ignore] = []
        /// FR-6.12's album-size standard, held the same way `ExportModel`
        /// holds it: a ratio against the suggestion, not a photo count, so it
        /// still means "half as many as you think" on a device whose
        /// suggestion differs. `nil` means the archive names no standard —
        /// either it was written before this field existed, or the device
        /// that wrote it had never set a standard of its own (see
        /// `currentStandard`), which is not the same as having chosen `1.0`
        /// and must not be exported as though it were.
        var standard: Double?

        struct Choice: Codable {
            var winnerKey: String
            var loserKey: String
            var timestamp: Date
            /// FR-5.12's correction, carried the same way `Verdict.isCleared`
            /// already is. Optional so an archive written before this field
            /// existed decodes as `nil` — read as "not voided" — and an older
            /// build reading a newer archive simply ignores the key, neither
            /// direction earning a format-version bump per the note above.
            var isVoided: Bool?
        }

        struct Verdict: Codable {
            var photoKey: String
            var isGood: Bool
            var isCleared: Bool
            var timestamp: Date
            /// FR-5.12's in-the-moment correction of this verdict, carried
            /// exactly as `Choice.isVoided` is and optional for the same
            /// reason — see there. Distinct from `isCleared`, which is a
            /// separate row saying the photo's whole standing was toggled
            /// off; see `VerdictRecord.isVoided`.
            var isVoided: Bool?
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
        /// How many already-present judgments this restore corrected —
        /// i.e. the archive said voided (FR-5.12) where this device's copy
        /// didn't yet. Counted apart from `choices`, which is rows newly
        /// added: a correction adds no row, it updates one already here. Not
        /// folded into `skipped` either — a corrected row did change
        /// something, so reporting it as merely skipped would itself be the
        /// silent-failure FR-8.12 forbids.
        var corrections = 0
        /// Whether the archive's album-size standard (FR-6.12) was adopted —
        /// only when this device had never set one of its own; see the merge
        /// rule in `restore`.
        var standardAdopted = false

        var isEmpty: Bool { choices == 0 && verdicts == 0 && ignores == 0 && corrections == 0 && !standardAdopted }
    }

    enum ArchiveError: LocalizedError {
        case unreadableFormat(version: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableFormat(let version):
                "This file was written by a newer version of Firnlight (format \(version)). Nothing was changed — update Firnlight and try again."
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
            Archive.Choice(winnerKey: $0.winnerKey, loserKey: $0.loserKey, timestamp: $0.timestamp, isVoided: $0.isVoided)
        }
        archive.verdicts = try context.fetch(FetchDescriptor<VerdictRecord>()).map {
            Archive.Verdict(photoKey: $0.photoKey, isGood: $0.isGood, isCleared: $0.isCleared,
                            timestamp: $0.timestamp, isVoided: $0.isVoided)
        }
        archive.ignores = try context.fetch(FetchDescriptor<IgnoreRecord>()).map {
            Archive.Ignore(photoKey: $0.photoKey, isIgnored: $0.isIgnored, timestamp: $0.timestamp)
        }
        archive.standard = currentStandard()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        log.info("Exported \(archive.choices.count) choices, \(archive.verdicts.count) verdicts, \(archive.ignores.count) ignores, standard \(archive.standard.map { "\($0)" } ?? "never set")")
        return try encoder.encode(archive)
    }

    /// This device's album-size standard (FR-6.12), or `nil` if it has never
    /// set one. Read the same way `ExportModel.strictness` reads it:
    /// `UserDefaults.double(forKey:)` returns `0` for a key never written,
    /// and `0` is not a ratio any choice can produce, so it doubles as
    /// "never set" — the device is simply following the suggestion (FR-6.4).
    ///
    /// A never-set device exports no standard at all, rather than the `1.0`
    /// it currently behaves as. The two look alike on the exporting device
    /// and are opposites on the receiving one: `restore` adopts an archive's
    /// standard only into a device that has never chosen one, so a phantom
    /// `1.0` would be adopted as an explicit choice and would then block the
    /// user's real standard from ever arriving — a slider nobody touched,
    /// silently overriding one they did. Nothing may be carried out of a
    /// device that the user never put there (FR-7.4).
    ///
    /// Reads `UserDefaults` directly rather than going through an
    /// `ExportModel` instance: the standard lives at the device level, not in
    /// the SwiftData store the rest of this file walks, and `ExportModel` is
    /// `@MainActor`-isolated while this function runs `@concurrent` off it.
    private static func currentStandard() -> Double? {
        let stored = UserDefaults.standard.double(forKey: ExportModel.strictnessDefaultsKey)
        return stored > 0 ? stored : nil
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
        // Keyed by identity, not just collected into a Set: a matching
        // incoming row may still need to correct this one in place (see the
        // "A correction still updates a row already here" note above).
        var existingChoicesByKey: [String: ChoiceRecord] = [:]
        for record in try context.fetch(FetchDescriptor<ChoiceRecord>()) {
            existingChoicesByKey[identity(record.winnerKey, record.loserKey, record.timestamp)] = record
        }
        var existingVerdictsByKey: [String: VerdictRecord] = [:]
        for record in try context.fetch(FetchDescriptor<VerdictRecord>()) {
            existingVerdictsByKey[identity(record.photoKey, "\(record.isGood)|\(record.isCleared)", record.timestamp)] = record
        }
        var existingIgnores = Set(try context.fetch(FetchDescriptor<IgnoreRecord>())
            .map { identity($0.photoKey, "\($0.isIgnored)", $0.timestamp) })

        var summary = RestoreSummary()
        for choice in archive.choices {
            let key = identity(choice.winnerKey, choice.loserKey, choice.timestamp)
            if let existing = existingChoicesByKey[key] {
                // Same choice already here. FR-5.12/FR-9.1: a correction that
                // arrives after the judgment it corrects still wins — once
                // either side has voided it, it stays voided (voiding has no
                // undo, so this can never overwrite a live row with a stale
                // one).
                if (choice.isVoided ?? false) && !existing.isVoided {
                    existing.isVoided = true
                    summary.corrections += 1
                } else {
                    summary.skipped += 1
                }
                continue
            }
            let record = ChoiceRecord(
                winnerKey: choice.winnerKey,
                loserKey: choice.loserKey,
                timestamp: choice.timestamp,
                isVoided: choice.isVoided ?? false
            )
            context.insert(record)
            existingChoicesByKey[key] = record
            summary.choices += 1
        }
        for verdict in archive.verdicts {
            let key = identity(verdict.photoKey, "\(verdict.isGood)|\(verdict.isCleared)", verdict.timestamp)
            if let existing = existingVerdictsByKey[key] {
                // Same one-way correction merge the choices above take: an
                // undo that arrives after the verdict it corrects still wins
                // (FR-5.12/FR-9.1), and voiding has no undo of its own.
                if (verdict.isVoided ?? false) && !existing.isVoided {
                    existing.isVoided = true
                    summary.corrections += 1
                } else {
                    summary.skipped += 1
                }
                continue
            }
            let record = VerdictRecord(
                photoKey: verdict.photoKey,
                isGood: verdict.isGood,
                isCleared: verdict.isCleared,
                timestamp: verdict.timestamp,
                isVoided: verdict.isVoided ?? false
            )
            context.insert(record)
            existingVerdictsByKey[key] = record
            summary.verdicts += 1
        }
        for ignore in archive.ignores {
            let key = identity(ignore.photoKey, "\(ignore.isIgnored)", ignore.timestamp)
            guard existingIgnores.insert(key).inserted else { summary.skipped += 1; continue }
            context.insert(IgnoreRecord(photoKey: ignore.photoKey, isIgnored: ignore.isIgnored, timestamp: ignore.timestamp))
            summary.ignores += 1
        }

        // FR-6.12 + FR-7.4: the standard travels too, but as a single scalar
        // it has no "already here" row to skip against — the merge rule the
        // rows above use (skip a duplicate, keep both otherwise) doesn't
        // apply to one number. What "never silently rewinds" means for a
        // scalar is instead: an import may only fill in a standard this
        // device has never chosen for itself, never overwrite one it has.
        // `0` is `ExportModel.strictness`'s own sentinel for "never set" —
        // the device is still just following the suggestion (FR-6.4) — so
        // only then does the archive's value take over, the same threshold
        // FR-6.4 already uses to decide whether the suggestion still owns the
        // count. Once this device has its own explicit standard, restoring
        // an old archive must not quietly replace it, exactly as restoring
        // never replaces a choice, verdict or ignore already here.
        if let standard = archive.standard, standard > 0 {
            let key = ExportModel.strictnessDefaultsKey
            if UserDefaults.standard.double(forKey: key) == 0 {
                UserDefaults.standard.set(standard, forKey: key)
                summary.standardAdopted = true
            }
        }

        try context.save()
        log.info("Restored \(summary.choices) choices, \(summary.verdicts) verdicts, \(summary.ignores) ignores, \(summary.corrections) corrections applied (\(summary.skipped) already here), standard adopted: \(summary.standardAdopted)")
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
    /// The album-size standard (FR-6.12) belongs here, not in
    /// `resetGoesAway`: it is the user's own strictness, held relative to
    /// whatever the suggestion is, not a fact learned about any photo — a
    /// fresh suggestion after reset still moves the size to match it, same as
    /// always. `resetLearnedTaste` below leaves it untouched, which is what
    /// makes this sentence true rather than aspirational.
    static let resetStays = "Your photos, the wallpaper album in Photos, and everything the app has scanned and analyzed. Firnlight starts ranking from your Photos favorites again, as it did on the first launch. The album size you’ve set, relative to the suggestion, carries over unchanged."

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
