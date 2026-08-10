import Foundation
import SwiftData
import os

/// Builds the app's `ModelContainer` as two stores, and moves the user's
/// existing judgments into the second one exactly once.
///
/// **Why two stores.** The app holds two kinds of data with opposite rules.
/// `PhotoRecord` is derived local analysis — feature prints, scores,
/// dimensions — which FR-1.5 keeps on the device and which is expensive to
/// recompute. Choices, verdicts and ignores are the user's own judgments,
/// which FR-9.1 says must count on every device they own. SwiftData binds
/// sync to a *store*, not to a model, so the two have to live in separate
/// stores for one to be shareable without the other.
///
/// Both stores are `.none` today: section 9's transport needs an iCloud
/// container entitlement, which this project's signing team cannot provision.
/// Everything else — the device-independent keys, the split, this migration —
/// stands on its own and is what FR-9.1 actually requires; flipping the
/// judgments store to `.automatic` is the only remaining step, and it is
/// deliberately a one-line change here rather than a rewrite elsewhere.
///
/// **Why the URLs are pinned.** A `ModelConfiguration`'s name determines its
/// store filename, so naming a configuration that previously had none moves
/// its file — and silently starts the user from an empty library. The local
/// store is therefore pinned to the `default.store` SwiftData already created,
/// verified against the real container before this was written, rather than
/// trusted to reproduce the same name.
nonisolated enum JudgmentStore {
    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "JudgmentStore")

    /// Every model the app persists. The container is built from the union;
    /// each configuration below then claims a disjoint subset.
    private static var fullSchema: Schema {
        Schema([PhotoRecord.self, ChoiceRecord.self, VerdictRecord.self, IgnoreRecord.self])
    }

    private static var applicationSupport: URL {
        // Same base `PreferenceRanker` already writes its weights under, which
        // is how the sandbox-container path is known to resolve correctly.
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var localStoreURL: URL { applicationSupport.appending(path: "default.store") }
    static var judgmentsStoreURL: URL { applicationSupport.appending(path: "Judgments.store") }

    /// The container every view and actor shares.
    static func makeContainer() throws -> ModelContainer {
        migrateLegacyJudgmentsIfNeeded()

        let local = ModelConfiguration(
            "default",
            schema: Schema([PhotoRecord.self]),
            url: localStoreURL,
            cloudKitDatabase: .none
        )
        let judgments = ModelConfiguration(
            "Judgments",
            schema: Schema([ChoiceRecord.self, VerdictRecord.self, IgnoreRecord.self]),
            url: judgmentsStoreURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: fullSchema, configurations: [local, judgments])
    }

    // MARK: Migration

    private static let migratedDefaultsKey = "JudgmentStore.migratedLegacyJudgments"

    /// Moves choices and verdicts out of the pre-split store, once.
    ///
    /// Before the split, all three models shared `default.store`. Opening that
    /// file with a configuration that declares only `PhotoRecord` does not
    /// destroy the judgment rows — verified against a copy of the real store,
    /// where they stayed readable afterwards — but it does make them invisible,
    /// which would silently cost the user every duel they have ever decided
    /// (FR-5.3, FR-7.1). So they are copied across first.
    ///
    /// Runs before the real container is built and touches no Photos API, so
    /// it works at first launch regardless of authorization. Rows arrive keyed
    /// by the local identifier they were written with; `LibraryScanner`
    /// re-keys them to cloud identifiers once a scan resolves those — the same
    /// path any judgment recorded before resolution takes, not a special case.
    ///
    /// Failure is safe and retried: the marker is only set after a successful
    /// save, and the source rows are deleted only once the copy has committed.
    /// Because the legacy rows survive a split open, a launch that skips this
    /// loses nothing permanently.
    ///
    /// The marker lives in `UserDefaults`, which means it is tied to the bundle
    /// identifier and does **not** automatically follow the app to a new
    /// sandbox container — as happened when the placeholder bundle ID was
    /// replaced. Losing it re-runs this against a `default.store` whose choices
    /// and verdicts have already been moved out, so those fetch empty, but the
    /// `isExcluded` photos are still there and would be re-seeded as duplicate
    /// `IgnoreRecord`s. The value-identity check below is what makes that a
    /// no-op rather than a slow accumulation, so the marker is an optimisation
    /// and the dedupe is the actual guarantee. Anyone moving the container
    /// should still carry the marker across; anyone who forgets is covered.
    private static func migrateLegacyJudgmentsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedDefaultsKey) else { return }
        guard FileManager.default.fileExists(atPath: localStoreURL.path(percentEncoded: false)) else {
            // Fresh install: nothing to carry over.
            defaults.set(true, forKey: migratedDefaultsKey)
            return
        }

        do {
            // Opened in the shape the file was written in, so it is guaranteed
            // to load, and released before the real container opens it again.
            let legacyConfiguration = ModelConfiguration(
                schema: fullSchema,
                url: localStoreURL,
                cloudKitDatabase: .none
            )
            let legacy = try ModelContainer(for: fullSchema, configurations: [legacyConfiguration])
            let legacyContext = ModelContext(legacy)

            let choices = try legacyContext.fetch(FetchDescriptor<ChoiceRecord>())
            let verdicts = try legacyContext.fetch(FetchDescriptor<VerdictRecord>())
            // "Ignore This Photo" predates this split as a flag on the photo
            // itself; seed it so an ignore made before the upgrade is a
            // first-class judgment like any other (FR-9.1).
            let ignored = try legacyContext.fetch(
                FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.isExcluded })
            )

            guard !choices.isEmpty || !verdicts.isEmpty || !ignored.isEmpty else {
                defaults.set(true, forKey: migratedDefaultsKey)
                log.info("No legacy judgments to migrate")
                return
            }

            let judgmentsConfiguration = ModelConfiguration(
                "Judgments",
                schema: Schema([ChoiceRecord.self, VerdictRecord.self, IgnoreRecord.self]),
                url: judgmentsStoreURL,
                cloudKitDatabase: .none
            )
            let destination = try ModelContainer(
                for: Schema([ChoiceRecord.self, VerdictRecord.self, IgnoreRecord.self]),
                configurations: [judgmentsConfiguration]
            )
            let destinationContext = ModelContext(destination)

            // Copy only what isn't already there, so a second attempt can't
            // double-count. There is one window where that matters: dying
            // between the save below and the source deletes that follow it
            // leaves the copy durable but the originals intact, and the next
            // launch — marker still unset, by design — runs this again. A
            // replayed duplicate choice is not a harmless no-op; it is a
            // second SGD step the user never made, permanently skewing the
            // ranking (FR-5.3). Identity is the row's own values, which are
            // reproduced exactly by a re-read of the same source rows.
            //
            // "Destination is non-empty ⇒ already copied" would be the cheaper
            // test and is wrong: a migration that failed *before* this point
            // still leaves the app usable, so the user can record fresh
            // judgments into this store, and skipping on that basis would
            // strand the legacy rows forever.
            let existingChoices = Set(try destinationContext.fetch(FetchDescriptor<ChoiceRecord>())
                .map { "\($0.winnerKey)|\($0.loserKey)|\($0.timestamp.timeIntervalSinceReferenceDate)" })
            let existingVerdicts = Set(try destinationContext.fetch(FetchDescriptor<VerdictRecord>())
                .map { "\($0.photoKey)|\($0.isGood)|\($0.isCleared)|\($0.timestamp.timeIntervalSinceReferenceDate)" })
            let existingIgnores = Set(try destinationContext.fetch(FetchDescriptor<IgnoreRecord>())
                .map(\.photoKey))

            for choice in choices {
                let identity = "\(choice.winnerKey)|\(choice.loserKey)|\(choice.timestamp.timeIntervalSinceReferenceDate)"
                guard !existingChoices.contains(identity) else { continue }
                destinationContext.insert(ChoiceRecord(
                    winnerKey: choice.winnerKey,
                    loserKey: choice.loserKey,
                    timestamp: choice.timestamp
                ))
            }
            for verdict in verdicts {
                let identity = "\(verdict.photoKey)|\(verdict.isGood)|\(verdict.isCleared)|\(verdict.timestamp.timeIntervalSinceReferenceDate)"
                guard !existingVerdicts.contains(identity) else { continue }
                destinationContext.insert(VerdictRecord(
                    photoKey: verdict.photoKey,
                    isGood: verdict.isGood,
                    isCleared: verdict.isCleared,
                    timestamp: verdict.timestamp
                ))
            }
            for photo in ignored {
                // Keyed by photo alone: an ignore is a latest-wins toggle, so
                // one seeded record per photo is all this can ever mean.
                guard !existingIgnores.contains(photo.judgmentKey) else { continue }
                destinationContext.insert(IgnoreRecord(
                    photoKey: photo.judgmentKey,
                    isIgnored: true,
                    timestamp: photo.analyzedAt ?? Date()
                ))
            }
            try destinationContext.save()

            // Only now that the copy is durable is it safe to drop the
            // originals; leaving them would double-count on a later replay.
            for choice in choices { legacyContext.delete(choice) }
            for verdict in verdicts { legacyContext.delete(verdict) }
            try legacyContext.save()

            defaults.set(true, forKey: migratedDefaultsKey)
            log.info("Migrated judgments to their own store: \(choices.count) choices, \(verdicts.count) verdicts, \(ignored.count) ignores")
        } catch {
            // Left un-migrated on purpose: the legacy rows are still on disk
            // and still readable, so the next launch tries again rather than
            // this having silently discarded them.
            log.error("Legacy judgment migration failed; will retry next launch: \(error.localizedDescription, privacy: .public)")
        }
    }
}
