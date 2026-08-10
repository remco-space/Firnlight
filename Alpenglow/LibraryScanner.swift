import Foundation
import Photos
import SwiftData
import Observation
import os

extension Array {
    /// Fixed-size slices, for the batched PhotoKit lookups in this file.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Scans the Photos library metadata and persists a `PhotoRecord` for every
/// wallpaper candidate. Metadata only — no pixel data is requested here.
///
/// Candidate pre-filter (cheap, before any pixels are ever loaded):
/// image media type, landscape orientation, width ≥ `Thresholds.minimumCandidatePixelWidth`,
/// and not a screenshot.
@MainActor
@Observable
final class LibraryScanner {
    /// Whether a scan is running, and how far along — live state only.
    enum Phase: Equatable {
        case idle
        case scanning(examined: Int, total: Int)
    }

    /// How the last scan ended. Split out of `Phase` deliberately: FR-8.7 asks
    /// that redoing something move nothing at all, which means the summary a
    /// scan produced has to stay on screen while the *next* scan runs, right
    /// up until its replacement is ready. While the two lived in one enum that
    /// was impossible — entering `.scanning` destroyed the result by
    /// construction, the card emptied out, and everything below it slid up and
    /// back down again a moment later.
    enum Outcome: Equatable {
        case finished(candidates: Int, examined: Int, newlyAdded: Int, editedQueued: Int, removed: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// The last scan's result, kept across the next one and overwritten only
    /// when its replacement exists. Never set back to `nil` — room once
    /// granted is kept (FR-8.7).
    private(set) var outcome: Outcome?

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "LibraryScanner")

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    /// Set while a scan is running by a change that arrived during it, so the
    /// pass that would have been dropped is run once at the end instead.
    ///
    /// Nothing asks for a scan by hand any more (FR-2.7), so every one of them
    /// is the app catching up with a library change — and a change that lands
    /// mid-scan is exactly the one a plain "already scanning, ignore" guard
    /// would lose, leaving the app quietly out of date with no control anywhere
    /// to put it right.
    private var rescanRequested = false

    /// Brings the store in line with the library: inserts records for new
    /// candidates, refreshes mutable metadata (favorites), queues photos edited
    /// since their analysis for targeted re-analysis, and removes records whose
    /// assets were deleted or no longer qualify (FR-2.2, FR-2.6).
    func scan(into context: ModelContext) async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        repeat {
            rescanRequested = false
            await runScan(into: context)
        } while rescanRequested
    }

    private func runScan(into context: ModelContext) async {
        phase = .scanning(examined: 0, total: 0)

        do {
            let existingRecords = try context.fetch(FetchDescriptor<PhotoRecord>())
            let recordsByIdentifier = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.localIdentifier, $0) })

            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: options)
            let total = assets.count
            phase = .scanning(examined: 0, total: total)
            log.info("Scan started: \(total) images in library, \(existingRecords.count) records already stored")

            var newlyAdded = 0
            var editedQueued = 0
            var removed = 0
            var unsavedChanges = 0
            var candidates = 0
            var seenIdentifiers: Set<String> = []
            seenIdentifiers.reserveCapacity(existingRecords.count)
            /// Whether this scan touched any `PhotoRecord` the grid reads —
            /// added, removed, re-queued for analysis, or just re-flagged
            /// favorite. Drives the `RankingClock` bump below (FR-4.5).
            var contentChanged = false

            for index in 0..<total {
                let asset = assets.object(at: index)
                let record = recordsByIdentifier[asset.localIdentifier]
                if record != nil {
                    seenIdentifiers.insert(asset.localIdentifier)
                }

                if isCandidate(asset) {
                    candidates += 1
                    if let record {
                        if record.isFavorite != asset.isFavorite {
                            record.isFavorite = asset.isFavorite
                            unsavedChanges += 1
                            contentChanged = true // favorite feeds ranking (FeatureStore)
                        }
                        // Edited since analysis (crop, adjustments, …): refresh
                        // metadata and queue for re-analysis. Only this photo
                        // re-runs Vision — never the whole library. Clear the old
                        // analysis outputs now: if the re-analysis defers to
                        // iCloud, the record must not re-enter the grid pairing a
                        // stale feature print with the new dimensions.
                        if let modified = asset.modificationDate,
                           let analyzedAt = record.analyzedAt,
                           modified > analyzedAt {
                            record.pixelWidth = asset.pixelWidth
                            record.pixelHeight = asset.pixelHeight
                            record.preferenceScore = nil // pre-edit rank is stale too
                            record.analysisVersion = 0
                            record.horizonMeasured = false
                            record.isSkipped = false
                            record.isNature = false
                            record.hasPeople = false
                            record.isUtility = false
                            record.aestheticsScore = 0
                            record.featurePrint = nil
                            record.horizonAngleDegrees = nil
                            editedQueued += 1
                            unsavedChanges += 1
                            contentChanged = true
                        }
                    } else {
                        context.insert(PhotoRecord(
                            localIdentifier: asset.localIdentifier,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            creationDate: asset.creationDate,
                            isFavorite: asset.isFavorite
                        ))
                        newlyAdded += 1
                        unsavedChanges += 1
                        contentChanged = true
                    }
                } else if let record {
                    // Edited out of candidacy (e.g. cropped to portrait or below
                    // the minimum width).
                    context.delete(record)
                    removed += 1
                    unsavedChanges += 1
                    contentChanged = true
                }

                if unsavedChanges >= Thresholds.scanSaveBatchSize {
                    try context.save()
                    unsavedChanges = 0
                }

                // Keep the UI responsive and the progress bar moving.
                if index % Thresholds.scanProgressStride == 0 {
                    phase = .scanning(examined: index + 1, total: total)
                    await Task.yield()
                }
            }

            // Assets deleted from the library leave orphaned records — clean up
            // (FR-2.6).
            //
            // This is only sound because the app runs on the whole library and
            // nothing less (FR-1.8): "not in the fetch" then really does mean
            // "not in the library". Under a limited selection the fetch returns
            // only the user's chosen photos, so this would read every photo
            // outside the selection as deleted and destroy its record — feature
            // print, aesthetics score, horizon measurement and cached rank
            // alike — unattended, since catching up needs no click. That is the
            // concrete reason a selection counts as not granted rather than as
            // a narrower kind of access.
            //
            // The `total`/`assets` fetch above was taken when the scan started,
            // and nothing in the loop above observes cancellation — a scan
            // already running when access narrows to a selection runs to
            // completion on that stale, now-partial fetch. `LibraryCatchUp.end()`
            // only stops the *next* pass. So this is re-checked here, live,
            // immediately before the one step that is unsound on anything less
            // than the whole library, rather than trusted to have stayed true
            // for as long as the scan above took to run.
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                for (identifier, record) in recordsByIdentifier where !seenIdentifiers.contains(identifier) {
                    context.delete(record)
                    removed += 1
                    contentChanged = true
                }
            } else {
                log.info("Access narrowed mid-scan; skipping orphan cleanup so photos outside this fetch are not mistaken for deleted")
            }

            try context.save()

            // Everything below is the cross-device half of a scan (section 9),
            // done here because this is already the one place that walks the
            // library and reconciles it with the store.
            try await resolveCloudIdentifiers(in: context)
            try rekeyJudgments(in: context)
            if try reconcileIgnores(in: context) > 0 {
                contentChanged = true
            }

            // Written in this order, and only here: the outcome is swapped for
            // its replacement in one step, then the run is marked over. The
            // card therefore never sees a moment with no summary in it.
            outcome = .finished(
                candidates: candidates,
                examined: total,
                newlyAdded: newlyAdded,
                editedQueued: editedQueued,
                removed: removed
            )
            phase = .idle
            log.info("Scan finished: \(total) examined, \(candidates) candidates (\(newlyAdded) new, \(editedQueued) edited queued for re-analysis, \(removed) removed)")
            // FR-4.5: the visible Library view brings itself up to date for
            // content, not just order. A scan can change what belongs in the
            // grid — add, remove, or re-flag a favorite (FR-2.2), drop a
            // deleted/disqualified photo (FR-2.6) — without ever queuing
            // analysis, which is the only other thing that bumps this clock
            // outside a duel/verdict/ignore write. Nothing else would notice
            // this scan's changes, so bump here, but only when something
            // actually changed — an unattended re-scan that found nothing new
            // (the common case) must not force every ranked view to reload.
            if contentChanged {
                RankingClock.shared.bump()
            }
        } catch {
            log.error("Scan failed: \(error.localizedDescription)")
            outcome = .failed(error.localizedDescription)
            phase = .idle
        }
    }

    /// Fills in `PhotoRecord.cloudIdentifier` for records that don't have one
    /// yet, so the user's judgments can be filed against the photo rather than
    /// against this device's name for it (FR-9.1).
    ///
    /// Only unresolved records are looked up, so the expensive call is paid
    /// once per photo across the app's lifetime rather than once per scan.
    /// Failures are left nil and simply retried next scan: `judgmentKey` falls
    /// back to the local identifier, so an unresolved photo is still fully
    /// usable, just not yet portable.
    private func resolveCloudIdentifiers(in context: ModelContext) async throws {
        let unresolved = try context.fetch(
            FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.cloudIdentifier == nil })
        )
        guard !unresolved.isEmpty else { return }

        // Saved per chunk so a long resolve is interruptible like the rest of
        // the scan. That leaves a real but self-correcting window: a scan that
        // dies here has moved some photos onto cloud keys while their
        // judgments still carry local ones, so until the next scan reaches
        // `rekeyJudgments` those judgments match nothing, the ranker sees its
        // applicable count collapse, and it rebuilds from the favorites seed
        // alone — the user's trained taste *appears* to vanish for a session.
        // Nothing is lost on disk and the next completed scan restores it
        // exactly, which is why this is a note rather than a transaction:
        // holding every chunk unsaved to close it would risk the opposite and
        // worse failure, a whole library's resolution discarded on one
        // interruption.
        var resolved = 0
        for chunk in unresolved.chunked(into: Thresholds.cloudIdentifierBatchSize) {
            let identifiers = chunk.map(\.localIdentifier)
            let mappings = await Self.cloudIdentifiers(for: identifiers)
            for record in chunk {
                guard let cloud = mappings[record.localIdentifier] else { continue }
                record.cloudIdentifier = cloud
                resolved += 1
            }
            try context.save()
            await Task.yield()
        }
        log.info("Resolved \(resolved) of \(unresolved.count) cloud identifiers")
    }

    /// The blocking PhotoKit call, off the main actor.
    ///
    /// `cloudIdentifierMappings` is synchronous and documented as very
    /// expensive; `@concurrent` forces it onto the background executor even
    /// though the scanner that calls it is `@MainActor`, so a large library
    /// can't freeze the UI (FR-8.2). Per-photo failures arrive as `.failure`
    /// in the `Result` and are simply omitted.
    ///
    /// Uses `PHCloudIdentifier.stringValue`, not the newer `archivalStringValue`
    /// its header deprecates it in favor of: the CI runner's Xcode 26.6
    /// (macOS26.5 SDK) is missing `archivalStringValue` outright, despite
    /// Apple's Xcode 27 headers annotating it available since macOS 15.2 — a
    /// genuine SDK gap in that Xcode release, not a beta-only symbol. Verified
    /// on-device across 20 real `PHCloudIdentifier`s from this library that
    /// both accessors produce byte-identical strings, so switching carries no
    /// risk to `PhotoRecord.cloudIdentifier` values already persisted or
    /// synced under FR-9.1/FR-9.2 — nothing here ever reconstructs a
    /// `PHCloudIdentifier` from the stored string, so it only ever needs to
    /// compare equal to itself.
    @concurrent
    private static func cloudIdentifiers(for localIdentifiers: [String]) async -> [String: String] {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        return mappings.reduce(into: [:]) { result, pair in
            if case .success(let cloud) = pair.value {
                result[pair.key] = cloud.stringValue
            }
        }
    }

    /// Moves judgments recorded before their photo's cloud identifier was
    /// known onto that key (FR-9.1).
    ///
    /// Two things produce local-keyed judgments: the one-time migration out of
    /// the pre-split store, and any judgment made on a photo whose resolution
    /// hadn't happened or had failed. Both are healed the same way, so there
    /// is one path rather than a migration special case.
    private func rekeyJudgments(in context: ModelContext) throws {
        let records = try context.fetch(
            FetchDescriptor<PhotoRecord>(predicate: #Predicate { $0.cloudIdentifier != nil })
        )
        var newKeyByOldKey: [String: String] = [:]
        for record in records where record.cloudIdentifier != record.localIdentifier {
            newKeyByOldKey[record.localIdentifier] = record.cloudIdentifier
        }
        guard !newKeyByOldKey.isEmpty else { return }

        var moved = 0
        for choice in try context.fetch(FetchDescriptor<ChoiceRecord>()) {
            if let key = newKeyByOldKey[choice.winnerKey] { choice.winnerKey = key; moved += 1 }
            if let key = newKeyByOldKey[choice.loserKey] { choice.loserKey = key; moved += 1 }
        }
        for verdict in try context.fetch(FetchDescriptor<VerdictRecord>()) {
            if let key = newKeyByOldKey[verdict.photoKey] { verdict.photoKey = key; moved += 1 }
        }
        for ignore in try context.fetch(FetchDescriptor<IgnoreRecord>()) {
            if let key = newKeyByOldKey[ignore.photoKey] { ignore.photoKey = key; moved += 1 }
        }
        guard moved > 0 else { return }
        try context.save()
        log.info("Re-keyed \(moved) judgment references onto cloud identifiers")
    }

    /// Brings `PhotoRecord.isExcluded` in line with the ignore judgments
    /// (FR-9.1, FR-9.2), latest timestamp winning.
    ///
    /// This is where an ignore made on another device would take effect here,
    /// and where one made about a photo that had not yet arrived applies the
    /// moment it does — the record was always there, it just had nothing to
    /// apply to. Today only the second half can actually happen: no ignores
    /// arrive from anywhere, because the judgments store is
    /// `cloudKitDatabase: .none` (see `JudgmentStore`). The reconcile is still
    /// load-bearing without it — it applies the flags the migration seeded. `isExcluded` is only a cache of this (see `IgnoreRecord`), so
    /// the judgment is the thing being honoured, not overwritten.
    @discardableResult
    private func reconcileIgnores(in context: ModelContext) throws -> Int {
        let ignores = try context.fetch(
            FetchDescriptor<IgnoreRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        guard !ignores.isEmpty else { return 0 }
        var latest: [String: Bool] = [:]
        for ignore in ignores { latest[ignore.photoKey] = ignore.isIgnored }

        var changed = 0
        for record in try context.fetch(FetchDescriptor<PhotoRecord>()) {
            guard let shouldIgnore = latest[record.judgmentKey], record.isExcluded != shouldIgnore else { continue }
            record.isExcluded = shouldIgnore
            changed += 1
        }
        guard changed > 0 else { return 0 }
        try context.save()
        log.info("Applied \(changed) ignore judgments from the shared store")
        return changed
    }

    /// Metadata-only wallpaper pre-filter; never touches pixel data.
    private func isCandidate(_ asset: PHAsset) -> Bool {
        asset.pixelWidth > asset.pixelHeight
            && asset.pixelWidth >= Thresholds.minimumCandidatePixelWidth
            && !asset.mediaSubtypes.contains(.photoScreenshot)
    }
}
