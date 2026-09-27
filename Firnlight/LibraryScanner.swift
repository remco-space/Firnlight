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

    private let log = Logger(subsystem: "space.remco.Firnlight", category: "LibraryScanner")

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

        // Forces `PlaceGazetteer`'s lazy static tables (JSON decode plus
        // every polygon's bounding box) to build now, off the main actor,
        // rather than synchronously on this actor the moment the first
        // candidate below needs a lookup — see `PlaceGazetteer.preload`'s
        // doc comment for the measured cost this avoids (FR-8.2).
        await PlaceGazetteer.preload()

        do {
            let existingRecords = try context.fetch(FetchDescriptor<PhotoRecord>())
            let recordsByIdentifier = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.localIdentifier, $0) })

            // The gazetteer's own bundled data (not just this scan's
            // per-record inputs) may have changed since the last scan —
            // `PlaceData/*.json` rebuilt, or the lookup logic itself
            // changed in a build the device just updated to. Detected by
            // `dataFingerprint` rather than any timestamp SwiftData can see;
            // see `gazetteerDataChanged`'s doc comment. When it has, every
            // already-resolved record is marked unresolved up front so the
            // ordinary `!record.gazetteerResolved` branch below (already
            // there to backfill records that predate the fields at all)
            // picks every one of them up in this same pass, rather than
            // leaving them cached against stale data indefinitely.
            if Self.gazetteerDataChanged {
                for record in existingRecords {
                    record.gazetteerResolved = false
                }
                log.info("Place gazetteer data changed; re-resolving \(existingRecords.count) records' cached place names")
            }

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
            /// Every record whose location changed, is new, or predates
            /// `gazetteerResolved` — collected during the loop below rather
            /// than resolved inline, so the actual point-in-polygon/
            /// nearest-point work can run in one batch, off the main actor
            /// (see `computeGazetteerKeys`, applied once after the loop).
            var pendingGazetteerUpdates: [PendingGazetteerUpdate] = []
            /// `recordsByIdentifier` plus every record newly inserted this
            /// pass — what the batch-apply step after the loop looks a
            /// record up in, since a new record isn't in the fetch above.
            var allRecordsByIdentifier = recordsByIdentifier

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
                        // Photos lets a location be assigned or corrected after
                        // import, so this is re-synced the same way favorite is
                        // rather than captured once at insert (FR-5.2).
                        //
                        // `!record.gazetteerResolved` is also a trigger, not
                        // just a location change: a record whose location
                        // never changes still needs its FR-5.14 place names
                        // backfilling once, on whichever scan first ships this
                        // field — the location-changed branch alone would
                        // leave every already-scanned photo's gazetteer fields
                        // unset forever, since nothing about its location ever
                        // differs from what's already stored.
                        let heading = (asset.location?.course).flatMap { $0 >= 0 ? $0 : nil }
                        if record.latitude != asset.location?.coordinate.latitude
                            || record.longitude != asset.location?.coordinate.longitude
                            || record.altitude != asset.location?.altitude
                            || record.cameraHeading != heading
                            || !record.gazetteerResolved {
                            record.latitude = asset.location?.coordinate.latitude
                            record.longitude = asset.location?.coordinate.longitude
                            record.altitude = asset.location?.altitude
                            record.cameraHeading = heading
                            pendingGazetteerUpdates.append(
                                PendingGazetteerUpdate(identifier: asset.localIdentifier, latitude: record.latitude, longitude: record.longitude)
                            )
                            unsavedChanges += 1
                            contentChanged = true // location feeds ranking (PreferenceRanker)
                        }
                        // Same re-sync for the subtype bits, and the path that
                        // backfills them onto records that predate the field.
                        let subtypes = Int(bitPattern: asset.mediaSubtypes.rawValue)
                        if record.mediaSubtypes != subtypes {
                            record.mediaSubtypes = subtypes
                            unsavedChanges += 1
                            contentChanged = true
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
                            record.isFlawed = false
                            record.aestheticsScore = 0
                            record.featurePrint = nil
                            record.horizonAngleDegrees = nil
                            editedQueued += 1
                            unsavedChanges += 1
                            contentChanged = true
                        }
                    } else {
                        let newRecord = PhotoRecord(
                            localIdentifier: asset.localIdentifier,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            creationDate: asset.creationDate,
                            location: asset.location,
                            isFavorite: asset.isFavorite,
                            mediaSubtypes: Int(bitPattern: asset.mediaSubtypes.rawValue)
                        )
                        pendingGazetteerUpdates.append(
                            PendingGazetteerUpdate(identifier: asset.localIdentifier, latitude: newRecord.latitude, longitude: newRecord.longitude)
                        )
                        allRecordsByIdentifier[asset.localIdentifier] = newRecord
                        context.insert(newRecord)
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

            // FR-5.14's offline place hierarchy, resolved for every record
            // this pass touched — in one batch, entirely off the main actor
            // (`computeGazetteerKeys`'s doc comment has the measured cost
            // this avoids: FR-8.2). Applying the result back is just a
            // dictionary lookup and four field assignments per record, cheap
            // enough to do right here on the main actor.
            if !pendingGazetteerUpdates.isEmpty {
                let keysByIdentifier = await Self.computeGazetteerKeys(for: pendingGazetteerUpdates)
                for update in pendingGazetteerUpdates {
                    guard let record = allRecordsByIdentifier[update.identifier] else { continue }
                    let keys = keysByIdentifier[update.identifier] ?? PlaceHierarchy.ScaleKeys(fine: nil, landscape: nil, region: nil, coarse: nil, network: nil)
                    record.gazetteerTown = keys.fine
                    record.gazetteerLandscape = keys.landscape
                    record.gazetteerRegion = keys.region
                    record.gazetteerCountry = keys.coarse
                    record.gazetteerResolved = true
                }
            }

            // FR-5.14's fifth scale, applied fresh every scan — not gated
            // behind any "did something change" check, and deliberately
            // not restricted to records `PlaceNameLookup` hasn't already
            // marked resolved. `PlaceNameLookup.save` already applies its
            // answer immediately to every record sharing a cell at the
            // moment that cell first resolves, but it only ever asks about
            // a given cell once — so a photo imported later, a location
            // corrected into an already-answered cell, or a record whose
            // offline anchor genuinely wasn't ready yet at that moment
            // (stuck resolved with a nil name) would otherwise never
            // receive FR-5.13's "remembered answer" at all. This pass is
            // what actually guarantees it: unconditional, so there is no
            // "first run after the gate ships" gap the way a version-gated
            // check would have (a store already carrying a stale answer
            // adopts a fresh baseline silently and is never revisited).
            // Run after the gazetteer batch above, not before, so it
            // anchors against each record's *current*
            // gazetteerRegion/gazetteerCountry.
            let networkPlaceNamesChanged = try await Self.applyNetworkPlaceNames(in: context)
            if networkPlaceNamesChanged > 0 {
                contentChanged = true
                log.info("Applied \(networkPlaceNamesChanged) network place-name changes")
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
    /// Uses `PHCloudIdentifier.archivalStringValue`, not the older
    /// `stringValue` it replaces: this project's required toolchain is Xcode
    /// 27+ (see CLAUDE.md), whose SDK both declares `archivalStringValue`
    /// (available since macOS 15.2/iOS 18.2 — well under the app's macOS/iOS
    /// 27+ floor) and marks `stringValue` deprecated, so the deprecated
    /// accessor is a standing warning on the one toolchain this project
    /// builds with. (An older Xcode 26.6 runner was once a reason to keep
    /// `stringValue` instead — that runner's SDK lacked
    /// `archivalStringValue` outright — but both CI build workflows are
    /// dormant (CLAUDE.md's Release process), so nothing currently compiles
    /// this file against that SDK; if a workflow is ever revived on pre-27
    /// Xcode, this line needs revisiting.) Verified on-device across 20 real
    /// `PHCloudIdentifier`s from this library that `stringValue` and
    /// `archivalStringValue` produce byte-identical strings, so switching
    /// carries no risk to `PhotoRecord.cloudIdentifier` values already
    /// persisted or synced under FR-9.1/FR-9.2 — nothing here ever
    /// reconstructs a `PHCloudIdentifier` from the stored string, so it only
    /// ever needs to compare equal to itself.
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

    /// One record's identifier and coordinate, captured during the main scan
    /// loop for `computeGazetteerKeys` to resolve later, off the main actor —
    /// a plain `Sendable` value rather than the `PhotoRecord` itself, which
    /// is bound to this actor's `ModelContext` and can't safely cross to the
    /// background executor `@concurrent` runs on.
    private struct PendingGazetteerUpdate: Sendable {
        let identifier: String
        let latitude: Double?
        let longitude: Double?
    }

    /// FR-5.14's offline floor for a whole batch of records at once, cached
    /// on each record so nothing downstream ever recomputes a gazetteer
    /// lookup on the ranker's hot path (see `PhotoRecord.gazetteerTown`'s
    /// doc comment).
    ///
    /// `@concurrent`, like `cloudIdentifiers(for:)` below, moves the actual
    /// point-in-polygon/nearest-point work onto the background executor
    /// even though this scanner is `@MainActor` — measured (a `swiftc -O`
    /// harness against the bundled files) at roughly 3.4 ms per record
    /// across the ~483k-entry nearest-point tables, which a real library's
    /// one-time backfill pass could easily spend a minute or more of on the
    /// main actor even chopped into per-record slices with a yield between
    /// each — exactly the "rest of the app stays usable while it runs"
    /// FR-8.2 asks for, not merely "never freezes for a whole minute
    /// straight". Batched — one call for every record this scan touched,
    /// not one `@concurrent` call per record — because the actor hop itself
    /// has a cost, and nothing about this work benefits from interleaving
    /// with anything else on the main actor the way a progress update does;
    /// the caller (`runScan`) awaits the single result and only then touches
    /// any `PhotoRecord`, which is cheap main-actor work (a dictionary
    /// lookup and four field assignments per record).
    @concurrent
    private static func computeGazetteerKeys(
        for updates: [PendingGazetteerUpdate]
    ) async -> [String: PlaceHierarchy.ScaleKeys] {
        var result: [String: PlaceHierarchy.ScaleKeys] = [:]
        result.reserveCapacity(updates.count)
        for update in updates {
            guard let latitude = update.latitude, let longitude = update.longitude else {
                result[update.identifier] = PlaceHierarchy.ScaleKeys(fine: nil, landscape: nil, region: nil, coarse: nil, network: nil)
                continue
            }
            result[update.identifier] = PlaceHierarchy.offlineKeys(latitude: latitude, longitude: longitude)
        }
        return result
    }

    /// Whether `PlaceGazetteer`'s bundled data has changed since the last
    /// scan that resolved any `PhotoRecord` against it — detected via
    /// `PlaceGazetteer.dataFingerprint` (an FNV-1a hash over the raw bytes
    /// of every bundled `PlaceData/*.json` file) rather than a file
    /// modification time SwiftData has no visibility into. This catches
    /// both a rebuilt `PlaceData/*.json` (`scripts/fetch-place-data.sh` run
    /// again against updated upstream sources) and a bundled build whose
    /// gazetteer *logic* changed in a way that changes what the same
    /// bytes resolve to — either way, a `PhotoRecord`'s cached
    /// `gazetteerTown`/`gazetteerLandscape`/`gazetteerRegion`/
    /// `gazetteerCountry` from before the change is simply wrong now, not
    /// merely out of date the way an untouched photo's location is not.
    ///
    /// Checked once per process and persisted in `UserDefaults`, mirroring
    /// `VisionRevisionFingerprint.generation`'s baseline pattern: the very
    /// first read on a device with no stored baseline adopts the current
    /// fingerprint without forcing a reset — there is nothing to compare
    /// against yet, and a record with no cached gazetteer fields at all is
    /// already picked up by the ordinary `!record.gazetteerResolved` check,
    /// so treating "nothing on record" as "a change happened" would only
    /// force a redundant second pass over the exact same records.
    private static let gazetteerDataChanged: Bool = {
        let defaults = UserDefaults.standard
        let key = "space.remco.Firnlight.placeGazetteerFingerprint.baseline"
        let observed = PlaceGazetteer.dataFingerprint
        guard let baseline = defaults.string(forKey: key) else {
            defaults.set(observed, forKey: key)
            return false
        }
        guard baseline != observed else { return false }
        defaults.set(observed, forKey: key)
        return true
    }()

    /// One record's identifier, the grid cell its coordinate rounds to, and
    /// its own current offline anchor — everything `composeNetworkPlaceNames`
    /// needs to decide FR-5.14's fifth-scale name for it, gathered here (on
    /// the main actor, cheaply — no geometry, just field reads) so the
    /// actual composition can run off it.
    private struct PendingNetworkPlaceUpdate: Sendable {
        let identifier: String
        let cacheKey: String
        let anchorKey: String?
    }

    /// Applies FR-5.14's fifth scale to every located `PhotoRecord`, every
    /// scan — unconditionally, not behind any "did the format change"
    /// gate. `PlaceNameLookup.save` already writes this immediately, onto
    /// every record sharing a cell, the moment that cell first resolves,
    /// but it only ever asks about one cell once (`nextPendingSpot` skips
    /// any cell `PlaceNameRecord` already answers) — so a photo imported
    /// later, one whose location was corrected into an already-answered
    /// cell, or one whose offline anchor genuinely wasn't ready yet at
    /// write time (left `networkPlaceResolved = true` with a nil name,
    /// permanently, with nothing else to revisit it) would otherwise never
    /// receive FR-5.13's "remembered answer" at all. This pass is what
    /// actually guarantees it, every time, for every record — an earlier
    /// revision instead gated this behind a stored version baseline, which
    /// had exactly the bug it existed to fix: the *first* run after such a
    /// gate ships adopts the current version as its baseline and returns
    /// "unchanged", so a store already carrying a stale answer at that
    /// moment is the one store the gate would never revisit.
    ///
    /// No network call, ever: `cityName` is already cached in
    /// `PlaceNameRecord` (keyed by grid cell, from a resolution that
    /// already happened), so this only re-runs the cheap composition step
    /// against each record's current `gazetteerRegion`/`gazetteerCountry`
    /// anchor. The composition itself runs `@concurrent`, off the main
    /// actor — the same shape `computeGazetteerKeys` uses and for the same
    /// reason (FR-8.2): every located record in the library, every scan, is
    /// enough records that even cheap per-record work adds up, and none of
    /// it needs to run on the actor the UI lives on. The two fetches that
    /// gather `Sendable` inputs still run here, on the main actor, matching
    /// `computeGazetteerKeys`'s own call site — restricted to the columns
    /// actually read (never `featurePrint`, the one genuinely large field
    /// on this model) — and the final field-assignment loop is chunked
    /// with a yield between each batch (`Thresholds.networkPlaceApplyBatchSize`),
    /// for the same reason the scan loop above yields on its own progress
    /// stride: cheap per-record work is still real main-actor time in
    /// aggregate across thousands of records.
    ///
    /// Returns how many records' cached value actually changed, so the
    /// caller can decide whether this counts as `contentChanged` for
    /// `RankingClock`'s purposes — the common case (nothing new resolved
    /// since the last scan) should not force every ranked view to reload.
    private static func applyNetworkPlaceNames(in context: ModelContext) async throws -> Int {
        let placeNameRecords = try context.fetch(FetchDescriptor<PlaceNameRecord>())
        guard !placeNameRecords.isEmpty else { return 0 }
        let cityNameByCacheKey: [String: String?] = Dictionary(uniqueKeysWithValues: placeNameRecords.map { ($0.cacheKey, $0.cityName) })

        // Only the columns this pass actually reads — never `featurePrint`,
        // which every located record (thousands, on a real library) would
        // otherwise fault in for nothing. Matches `PlaceNameLookup
        // .nextPendingSpot`'s own restriction and `AnalysisGeneration`'s
        // reasoning for the same kind of whole-library scan (FR-8.2).
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.latitude != nil && $0.longitude != nil }
        )
        descriptor.propertiesToFetch = [\.latitude, \.longitude, \.gazetteerRegion, \.gazetteerCountry]
        let records = try context.fetch(descriptor)
        let recordsByIdentifier = Dictionary(uniqueKeysWithValues: records.map { ($0.localIdentifier, $0) })
        let pending: [PendingNetworkPlaceUpdate] = records.compactMap { record in
            guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
            return PendingNetworkPlaceUpdate(
                identifier: record.localIdentifier,
                cacheKey: PlaceHierarchy.networkCacheKey(latitude: latitude, longitude: longitude),
                anchorKey: record.gazetteerRegion ?? record.gazetteerCountry
            )
        }
        guard !pending.isEmpty else { return 0 }

        let namesByIdentifier = await Self.composeNetworkPlaceNames(for: pending, cityNameByCacheKey: cityNameByCacheKey)

        // Applied in chunks, with a yield (and a save) between each — the
        // same shape `resolveCloudIdentifiers` and the scan loop's own
        // progress stride already use, and for the same reason (FR-8.2):
        // this now runs unconditionally over every located record on every
        // scan, so even cheap per-record work (a dictionary lookup, two
        // field writes) is a long unbroken main-actor stretch on a library
        // with thousands of them if done in one pass with nothing
        // interleaved.
        var changed = 0
        for chunk in pending.chunked(into: Thresholds.networkPlaceApplyBatchSize) {
            var chunkChanged = 0
            for update in chunk {
                // Presence in `namesByIdentifier` means this cell has been
                // asked about (even if the composed name itself is nil);
                // absence means it hasn't, and `PlaceNameLookup` will get
                // to it in due course — leave those records exactly as
                // they are.
                guard let composed = namesByIdentifier[update.identifier] else { continue }
                guard let record = recordsByIdentifier[update.identifier] else { continue }
                if record.networkPlaceName != composed || !record.networkPlaceResolved {
                    record.networkPlaceName = composed
                    record.networkPlaceResolved = true
                    chunkChanged += 1
                }
            }
            if chunkChanged > 0 {
                try context.save()
                changed += chunkChanged
            }
            await Task.yield()
        }
        return changed
    }

    /// The actual per-record composition for `applyNetworkPlaceNames`,
    /// `@concurrent` so it runs off the main actor (see that function's doc
    /// comment). Pure: reads only its `Sendable` arguments, calls
    /// `PlaceHierarchy.networkPlaceKey`, returns a plain dictionary.
    ///
    /// The result only ever holds an entry for a `cacheKey` present in
    /// `cityNameByCacheKey` — a cell `PlaceNameLookup` has genuinely asked
    /// about — so a record whose cell is still unanswered is simply left
    /// out, not given a nil entry; the caller's `guard let` on membership,
    /// not on the composed value, is what tells the two apart.
    @concurrent
    private static func composeNetworkPlaceNames(
        for updates: [PendingNetworkPlaceUpdate],
        cityNameByCacheKey: [String: String?]
    ) async -> [String: String?] {
        var result: [String: String?] = [:]
        result.reserveCapacity(updates.count)
        for update in updates {
            guard let cityName = cityNameByCacheKey[update.cacheKey] else { continue }
            result[update.identifier] = PlaceHierarchy.networkPlaceKey(cityName: cityName, anchorKey: update.anchorKey)
        }
        return result
    }

    /// Metadata-only wallpaper pre-filter; never touches pixel data.
    private func isCandidate(_ asset: PHAsset) -> Bool {
        asset.pixelWidth > asset.pixelHeight
            && asset.pixelWidth >= Thresholds.minimumCandidatePixelWidth
            && !asset.mediaSubtypes.contains(.photoScreenshot)
    }
}
