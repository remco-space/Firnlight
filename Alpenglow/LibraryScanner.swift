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
    enum Phase: Equatable {
        case idle
        case scanning(examined: Int, total: Int)
        /// `hidden` is the number of stored candidates this scan could not see,
        /// which is only ever non-zero under limited access. It is reported
        /// separately rather than folded into `candidates`, because a count
        /// that silently includes photos the app can no longer read is not the
        /// "clear summary" FR-2.4 asks for — the user was shown 10 candidates
        /// beside "Examined 3 photos", with nothing to say where the other 7
        /// went. Their records are deliberately kept (see the orphan-cleanup
        /// guard), so the honest report is that they exist and are out of reach.
        case finished(candidates: Int, examined: Int, newlyAdded: Int, editedQueued: Int, removed: Int, hidden: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "LibraryScanner")

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    /// Runs a full metadata scan. Inserts records for new candidates, refreshes
    /// mutable metadata (favorites), queues photos edited since their analysis
    /// for targeted re-analysis, and removes records whose assets were deleted
    /// or no longer qualify.
    func scan(into context: ModelContext) async {
        guard !isScanning else { return }
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
            /// Candidate assets this scan actually saw. Equals the stored count
            /// with full access; falls short of it under limited access, and
            /// the difference is what the summary reports as hidden.
            var visibleCandidates = 0
            var seenIdentifiers: Set<String> = []
            seenIdentifiers.reserveCapacity(existingRecords.count)

            for index in 0..<total {
                let asset = assets.object(at: index)
                let record = recordsByIdentifier[asset.localIdentifier]
                if record != nil {
                    seenIdentifiers.insert(asset.localIdentifier)
                }

                if isCandidate(asset) {
                    visibleCandidates += 1
                    if let record {
                        if record.isFavorite != asset.isFavorite {
                            record.isFavorite = asset.isFavorite
                            unsavedChanges += 1
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
                    }
                } else if let record {
                    // Edited out of candidacy (e.g. cropped to portrait or below
                    // the minimum width).
                    context.delete(record)
                    removed += 1
                    unsavedChanges += 1
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

            // Assets deleted from the library leave orphaned records — clean up.
            //
            // Only safe with full access, where "not in the fetch" really does
            // mean "not in the library". Under `.limited` the fetch returns
            // only the user's chosen selection, so this would read every photo
            // outside that selection as deleted and destroy its record —
            // feature print, aesthetics score, horizon measurement and cached
            // rank alike. It would happen unattended, too: `isAuthorized` is
            // true for `.limited`, so FR-2.7 re-scans at every launch without
            // the user clicking anything. Narrowing access must cost reach and
            // nothing else (FR-7.1).
            //
            // What is *not* at stake is the user's trained taste. Choices,
            // verdicts and ignores live in `Judgments.store`, which this file
            // never opens, so the worst case is the analysis cache — costly to
            // rebuild but rebuildable, and the judgments simply reattach to the
            // photos when they return. That separation is why this is a bad day
            // rather than an unrecoverable one.
            //
            // Records outside the selection simply go stale instead, which is
            // harmless: they can't be re-analyzed or exported while they're
            // invisible, and widening access again brings them straight back.
            // The in-loop deletion above stays — it only ever fires for assets
            // the fetch *did* return, so it judges a photo the app can see.
            if isLimitedAccess {
                log.info("Skipping orphan cleanup: limited access can't distinguish a deleted photo from an unselected one")
            } else {
                for (identifier, record) in recordsByIdentifier where !seenIdentifiers.contains(identifier) {
                    context.delete(record)
                    removed += 1
                }
            }

            try context.save()

            // Everything below is the cross-device half of a scan (section 9),
            // done here because this is already the one place that walks the
            // library and reconciles it with the store.
            try await resolveCloudIdentifiers(in: context)
            try rekeyJudgments(in: context)
            try reconcileIgnores(in: context)

            let stored = try context.fetchCount(FetchDescriptor<PhotoRecord>())
            // Report what this scan could see, and account for the rest
            // separately. With full access these are the same number.
            let hidden = max(0, stored - visibleCandidates)
            phase = .finished(
                candidates: visibleCandidates,
                examined: total,
                newlyAdded: newlyAdded,
                editedQueued: editedQueued,
                removed: removed,
                hidden: hidden
            )
            log.info("Scan finished: \(total) examined, \(visibleCandidates) candidates visible of \(stored) stored (\(newlyAdded) new, \(editedQueued) edited queued for re-analysis, \(removed) removed, \(hidden) hidden)")
        } catch {
            log.error("Scan failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
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
    @concurrent
    private static func cloudIdentifiers(for localIdentifiers: [String]) async -> [String: String] {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIdentifiers)
        return mappings.reduce(into: [:]) { result, pair in
            if case .success(let cloud) = pair.value {
                result[pair.key] = cloud.archivalStringValue
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
    private func reconcileIgnores(in context: ModelContext) throws {
        let ignores = try context.fetch(
            FetchDescriptor<IgnoreRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )
        guard !ignores.isEmpty else { return }
        var latest: [String: Bool] = [:]
        for ignore in ignores { latest[ignore.photoKey] = ignore.isIgnored }

        var changed = 0
        for record in try context.fetch(FetchDescriptor<PhotoRecord>()) {
            guard let shouldIgnore = latest[record.judgmentKey], record.isExcluded != shouldIgnore else { continue }
            record.isExcluded = shouldIgnore
            changed += 1
        }
        guard changed > 0 else { return }
        try context.save()
        log.info("Applied \(changed) ignore judgments from the shared store")
    }

    /// Whether the app can currently see only a user-chosen subset of the
    /// library. Read at the point of use rather than cached, because the user
    /// can change the selection while the app is running.
    private var isLimitedAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    /// Metadata-only wallpaper pre-filter; never touches pixel data.
    private func isCandidate(_ asset: PHAsset) -> Bool {
        asset.pixelWidth > asset.pixelHeight
            && asset.pixelWidth >= Thresholds.minimumCandidatePixelWidth
            && !asset.mediaSubtypes.contains(.photoScreenshot)
    }
}
