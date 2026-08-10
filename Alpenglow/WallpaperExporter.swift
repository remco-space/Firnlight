import Foundation
import Photos
import SwiftData
import os
#if os(iOS)
import UIKit
#endif

/// Keeps the "Alpenglow" album in Photos mirroring the current top-ranked,
/// deduplicated wallpaper candidates.
///
/// This is the app's ONLY write path into the Photos library, and it is
/// strictly limited to album creation and album membership — assets themselves
/// are never modified or deleted. (The original never-write rule was revised
/// to album-membership-only with explicit user approval.)
///
/// The album is tracked by `localIdentifier`, persisted in `UserDefaults`, not
/// by title: a title match would orphan the album on user rename (the next
/// sync would create a duplicate while System Settings keeps rotating the
/// stale one) and could hijack an unrelated pre-existing "Alpenglow" album.
/// The stored identifier is looked up first; title match is only a fallback
/// for the very first sync (or if the stored identifier no longer resolves,
/// e.g. the album was deleted), and any title match immediately persists its
/// identifier for next time.
/// Tracks whether an album sync is inside its remove→re-add span so app
/// termination (FR-1.7's quit-on-window-close) can wait for it.
///
/// `sync` rebuilds the album in two Photos transactions; its rollback only
/// runs on a caught error, not on process death. One click on the close
/// button in that gap would strand the album empty — violating FR-6.8's
/// restore promise — so `AppDelegate.applicationShouldTerminate` defers the
/// quit until this gate is idle. The gate lives here, set by `sync` itself
/// around the critical section, so no caller can forget it (ExportView's
/// `isSyncing` @State is view-local and dies with the view while the sync
/// task keeps running — unusable by the delegate).
///
/// Lock-based rather than @MainActor/@Observable: `applicationShouldTerminate`
/// must read it synchronously on the main actor while `sync` (nonisolated
/// async) sets it from wherever it resumes, and nobody needs SwiftUI
/// observation — just the one "now idle" callback. A begin-count (not a Bool)
/// keeps it correct even if two syncs ever overlap.
///
/// `sync` marks the critical section on every platform, but only macOS reads
/// the gate: FR-1.7 is macOS-only, and there is no iOS counterpart to hold off
/// a quit — the user never closes a window there. On iPhone and iPad the
/// equivalent threat is the system suspending a backgrounded app, so `sync`
/// takes a `BackgroundAssertion` over the same span instead (see below).
///
/// Neither mechanism survives a *hard* death — force-quit, crash, power loss —
/// on either platform, because both only defer a cooperative shutdown. That
/// gap is covered separately and durably: `sync` records the album's previous
/// membership to `UserDefaults` before it removes anything, and
/// `restoreInterruptedSync` puts it back on the next launch. The gate and the
/// assertion make the common case invisible; the record is what actually keeps
/// FR-6.8's promise.
nonisolated final class AlbumSyncGate: Sendable {
    static let shared = AlbumSyncGate()

    private struct State {
        var active = 0
        var idleWaiters: [@Sendable () -> Void] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isActive: Bool { state.withLock { $0.active > 0 } }

    func begin() { state.withLock { $0.active += 1 } }

    func end() {
        let waiters: [@Sendable () -> Void] = state.withLock {
            $0.active -= 1
            guard $0.active == 0 else { return [] }
            let waiting = $0.idleWaiters
            $0.idleWaiters = []
            return waiting
        }
        for waiter in waiters { waiter() }
    }

    /// Runs `action` immediately if no critical section is active, otherwise
    /// once the last one ends. `action` must hop to whatever isolation it
    /// needs — it may be called from the context that calls `end()`.
    func whenIdle(_ action: @escaping @Sendable () -> Void) {
        let runNow = state.withLock {
            if $0.active == 0 { return true }
            $0.idleWaiters.append(action)
            return false
        }
        if runNow { action() }
    }
}

#if os(iOS)
/// Keeps iOS from suspending the app mid-sync (FR-6.8).
///
/// `WallpaperAlbumSync.sync` rebuilds the album in two Photos transactions, and
/// on iPhone and iPad backgrounding mid-sync is the ordinary case, not an edge
/// one — a suspension between the two would strand the album empty until the
/// next launch. `AlbumSyncGate`'s macOS answer (defer the quit) has no
/// counterpart here, so `sync` holds one of these across the same span.
///
/// The expiration handler is not optional bookkeeping: iOS terminates an app
/// that lets a background task assertion expire without ending it. Ending sets
/// the identifier back to `.invalid` so the `defer` in `sync` can't end it a
/// second time.
///
/// `@MainActor` because `UIApplication.shared` is, and because the expiration
/// handler is delivered there (`NS_SWIFT_UI_ACTOR`); that also makes the class
/// implicitly `Sendable`, so `sync` — which is `nonisolated async` — can hold
/// one across its suspension points.
@MainActor
final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

nonisolated enum WallpaperAlbumSync {
    struct Outcome: Sendable, Equatable {
        var added = 0
        var removed = 0
        var total = 0
        /// FR-6.6: whether the post-sync read-back of the album actually
        /// matched the requested diversity order. `true` on the ordinary
        /// path; `false` surfaces a real (if rare) Photos-side mismatch to
        /// ExportView instead of only logging it.
        var orderVerified = true
    }

    enum SyncError: LocalizedError {
        case albumCreationFailed
        /// FR-6.11: the album isn't visible on this device — no stored
        /// identifier resolves and no album of that title exists. Syncing
        /// can't proceed, and silently creating one would be wrong: the
        /// user's devices share a single album (FR-6.10), so on a second
        /// device that just hasn't finished syncing yet, creating would leave
        /// them with two "Alpenglow" albums the moment the real one arrives.
        /// ExportView turns this into a wait-or-create choice rather than an
        /// error the user can only stare at.
        case albumNotVisible
        /// FR-6.8: the re-add after a remove failed, and the best-effort
        /// rollback that restores the previous membership *also* failed —
        /// the album may now be sitting empty. Thrown instead of the rollback
        /// staying a silent `try?`, so the user finds out (via ExportView's
        /// `errorMessage`) rather than discovering a blank wallpaper rotation
        /// later with no explanation.
        case syncFailedAndRollbackFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .albumCreationFailed:
                "Couldn't create the “\(Thresholds.wallpaperAlbumName)” album in Photos."
            case .albumNotVisible:
                "The “\(Thresholds.wallpaperAlbumName)” album isn't on this device yet."
            case .syncFailedAndRollbackFailed(let underlying):
                "Sync failed and the album may now be empty (\(underlying.localizedDescription)). Syncing again will rebuild it."
            }
        }
    }

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "WallpaperAlbumSync")

    /// Makes album membership exactly the current top `count` candidates, in
    /// diversity order (consecutive photos as different as possible), so
    /// "rotate in order" wallpaper settings avoid samey streaks.
    ///
    /// FR-6.10: this runs only when the user asks for it. Its two callers are
    /// the Export tab's "Sync Album" button and the menu bar command of the
    /// same name (FR-8.3) — both explicit acts. Nothing schedules it, and
    /// nothing may: the user's devices share one album, so an unattended sync
    /// on one would silently undo a deliberate one on another. The app's
    /// catching up with the library deliberately stops at scanning and
    /// analysis and never reaches here (FR-2.7).
    ///
    /// FR-1.9 puts a second gate in front of it: `confirm` is asked, with the
    /// exact counts this call has just worked out, before a single change
    /// request is made. It is called at the last moment when nothing has yet
    /// happened, so declining costs nothing and needs no undo. Returning `nil`
    /// is that decline — not an error, since the user answering a question is
    /// not a failure.
    static func sync(
        container: ModelContainer,
        count: Int,
        confirm: @Sendable (PhotosChange) async -> Bool
    ) async throws -> Outcome? {
        let ordered = try await FeatureStore(modelContainer: container)
            .albumCandidates(limit: count)
            .candidates
        let orderedIDs = ordered.map(\.localIdentifier)
        let targetIDs = Set(orderedIDs)

        guard let album = findAlbum(named: Thresholds.wallpaperAlbumName) else {
            throw SyncError.albumNotVisible
        }

        // Diff for reporting; the album itself is rebuilt to impose the order.
        // `currentOrder` keeps the sequence, not just the membership, because
        // it is also what gets recorded for the FR-6.8 restore below — putting
        // the album back means putting it back in the order it was in.
        let current = PHAsset.fetchAssets(in: album, options: nil)
        var currentOrder: [String] = []
        current.enumerateObjects { asset, _, _ in currentOrder.append(asset.localIdentifier) }
        let currentIDs = Set(currentOrder)
        let added = targetIDs.subtracting(currentIDs).count
        let removed = currentIDs.subtracting(targetIDs).count

        // fetchAssets(withLocalIdentifiers:) doesn't preserve input order.
        let fetchedTargets = PHAsset.fetchAssets(withLocalIdentifiers: orderedIDs, options: nil)
        var assetByID: [String: PHAsset] = [:]
        fetchedTargets.enumerateObjects { asset, _, _ in assetByID[asset.localIdentifier] = asset }
        let orderedAssets = orderedIDs.compactMap { assetByID[$0] }

        // FR-1.9: ask before touching the library, naming exactly what this
        // sync will do. Deliberately here — after the diff is known, so the
        // question is specific, and before the gate below is taken, so a user
        // reading an alert isn't holding off their own app's quit.
        guard await confirm(PhotosChange(
            kind: .changeAlbum,
            added: added,
            removed: removed,
            total: orderedAssets.count
        )) else {
            log.info("Album sync declined by the user; the library was not touched")
            return nil
        }

        // Hold the termination gate across the remove→re-add span below and
        // its rollback: quitting between the two transactions would strand
        // the album empty with no rollback (see AlbumSyncGate). Everything
        // above this line is read-only, so termination there is harmless;
        // `defer` also covers the trailing verification, but those are only
        // fast reads — a small price for covering every throw path.
        AlbumSyncGate.shared.begin()
        #if os(iOS)
        // The iOS half of the same protection: there is no quit to defer, but
        // there is a suspension to hold off. See BackgroundAssertion.
        let assertion = await BackgroundAssertion(name: "Album sync")
        #endif
        defer {
            AlbumSyncGate.shared.end()
            #if os(iOS)
            Task { @MainActor in assertion.end() }
            #endif
        }

        // FR-6.8, the durable half: record what the album held before touching
        // it. The gate and the assertion only defer a *cooperative* shutdown —
        // a crash, force-quit or power loss in the window below still skips
        // the rollback, and `current` lives only in memory, so without this
        // there would be nothing left to restore from on any platform. Written
        // before the remove and cleared only once the re-add is verified, so
        // its mere presence on the next launch means "the last sync did not
        // finish" (see restoreInterruptedSync).
        if !currentOrder.isEmpty {
            UserDefaults.standard.set(currentOrder, forKey: interruptedMembershipDefaultsKey)
        }

        // Two transactions: remove-and-re-add within a single change request
        // lets Photos keep surviving assets at their old positions, which
        // broke the diversity order (verified by the post-sync check).
        if current.count > 0 {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(current)
            }
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.addAssets(orderedAssets as NSArray)
            }
        } catch {
            // The re-add failed after the remove already committed, which
            // would otherwise leave the album — and the user's live wallpaper
            // rotation — empty. Best-effort restore what was just removed.
            log.error("Re-add failed after remove; restoring previous album membership: \(error.localizedDescription, privacy: .public)")
            if current.count > 0 {
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets(current)
                    }
                } catch let rollbackError {
                    // Both the sync and its rollback failed: the album may be
                    // stranded empty. Don't swallow this one (FR-6.8) — throw
                    // a distinct error so ExportView's errorMessage tells the
                    // user, rather than the previous `try?` hiding a second
                    // failure behind the first. The recorded membership stays
                    // put deliberately, so the next launch retries the restore.
                    log.error("Rollback ALSO failed; album may be empty: \(rollbackError.localizedDescription, privacy: .public)")
                    throw SyncError.syncFailedAndRollbackFailed(underlying: error)
                }
                // The rollback put the previous membership back, so there is
                // nothing left for the next launch to restore.
                UserDefaults.standard.removeObject(forKey: interruptedMembershipDefaultsKey)
            }
            throw error
        }

        // Verify the album actually ended up in the requested order.
        var resultingIDs: [String] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            resultingIDs.append(asset.localIdentifier)
        }
        let orderMatches = resultingIDs == orderedIDs.filter { assetByID[$0] != nil }
        if !orderMatches {
            let firstMismatch = Array(zip(resultingIDs, orderedIDs)).firstIndex { $0 != $1 } ?? -1
            log.error("Album order verification FAILED: album sequence differs from requested diversity order (first mismatch at index \(firstMismatch))")
        } else {
            log.info("Album order verified: \(resultingIDs.count) photos in diversity order")
        }

        // The album is rebuilt and read back, so the pre-sync membership is no
        // longer worth restoring to (FR-6.8).
        UserDefaults.standard.removeObject(forKey: interruptedMembershipDefaultsKey)

        // FR-6.6: carry the verification result in the outcome so ExportView
        // can tell the user honestly, not just log it.
        let outcome = Outcome(added: added, removed: removed, total: orderedAssets.count, orderVerified: orderMatches)
        log.info("Album sync: +\(outcome.added) −\(outcome.removed), total \(outcome.total) (diversity-ordered)")
        return outcome
    }

    private static let storedIdentifierDefaultsKey = "WallpaperAlbumSync.albumLocalIdentifier"
    private static let interruptedMembershipDefaultsKey = "WallpaperAlbumSync.interruptedMembership"

    /// Locates the album this device already knows about, or nil if it can't
    /// see one (FR-6.11).
    ///
    /// Deliberately never creates. The stored identifier is tried first; a
    /// title match is the fallback for a first sync or a stored identifier
    /// that no longer resolves, and adopting its identifier is what lets the
    /// album survive being renamed in Photos (FR-6.9). Finding nothing is a
    /// real state, not a failure to paper over — see `SyncError.albumNotVisible`.
    private static func findAlbum(named name: String) -> PHAssetCollection? {
        if let storedID = UserDefaults.standard.string(forKey: storedIdentifierDefaultsKey),
           let byIdentifier = fetchAlbum(identifier: storedID) {
            return byIdentifier
        }
        if let byTitle = fetchAlbum(named: name) {
            UserDefaults.standard.set(byTitle.localIdentifier, forKey: storedIdentifierDefaultsKey)
            return byTitle
        }
        return nil
    }

    /// Creates the wallpaper album, for the one case FR-6.11 leaves open: a
    /// device where it genuinely has never existed. Only ever called from the
    /// Export tab's explicit "Create Album" action — the app never decides on
    /// its own that an album is missing rather than merely unsynced, because
    /// PhotoKit exposes no way to tell those apart.
    ///
    /// Asked about like every other change (FR-1.9), under its own switch:
    /// bringing an album into existence is a different thing to agree to than
    /// changing what is in one. Returns whether it was created.
    @discardableResult
    static func createAlbum(confirm: @Sendable (PhotosChange) async -> Bool) async throws -> Bool {
        let name = Thresholds.wallpaperAlbumName
        guard await confirm(PhotosChange(kind: .createAlbum)) else {
            log.info("Album creation declined by the user")
            return false
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        guard let created = fetchAlbum(named: name) else {
            throw SyncError.albumCreationFailed
        }
        UserDefaults.standard.set(created.localIdentifier, forKey: storedIdentifierDefaultsKey)
        log.info("Created album “\(name, privacy: .public)”")
        return true
    }

    /// Puts the album back the way the last sync found it, if that sync never
    /// finished (FR-6.8).
    ///
    /// Called once per launch. A recorded membership that outlived its sync
    /// means the process died somewhere between the remove and the verified
    /// re-add — the one window where the user's live wallpaper rotation can be
    /// left pointing at an empty album, and the one `AlbumSyncGate` and
    /// `BackgroundAssertion` cannot cover because neither survives a hard kill.
    ///
    /// **Only ever called from an explicit user action**, never at launch, and
    /// that is a resolution of a genuine conflict between two requirements
    /// rather than an oversight. FR-6.8 wants the album restored; FR-6.10 says
    /// the album changes only when the user asks, precisely because *"the
    /// user's devices share one album, and unattended changes would let them
    /// undo each other's"*. An automatic restore is exactly that failure: the
    /// Mac dies mid-sync, the user syncs deliberately from the iPad, and the
    /// Mac's next launch silently rewrites the shared album back to its stale
    /// pre-sync membership. Offering the restore and letting the user trigger
    /// it satisfies both — the album is recoverable, and nothing writes to it
    /// unattended. The in-run rollback inside `sync` stays automatic, because
    /// that happens *within* a sync the user asked for.
    ///
    /// Remove-then-add rather than a bare add: the process may equally have
    /// died *during* the re-add, leaving a partial new membership, and a bare
    /// add would union the two into something that was never the album's
    /// contents. The record is cleared only on success, so an interrupted
    /// restore stays on offer.
    static func restoreInterruptedSync(confirm: @Sendable (PhotosChange) async -> Bool) async {
        let defaults = UserDefaults.standard
        guard let identifiers = defaults.stringArray(forKey: interruptedMembershipDefaultsKey),
              !identifiers.isEmpty else { return }

        guard let album = findAlbum(named: Thresholds.wallpaperAlbumName) else {
            // No album to restore into. Keep the record: on a second device
            // the album may simply not have synced down yet (FR-6.11), and
            // discarding it here would throw away the only copy of what the
            // album held.
            log.error("Interrupted sync recorded, but the album isn't visible on this device yet; will retry")
            return
        }

        let previous = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let stranded = PHAsset.fetchAssets(in: album, options: nil)

        // FR-1.9 again, and under the same switch as a sync: putting the album
        // back is the same kind of act — setting what is in it — done with a
        // different destination in mind.
        guard await confirm(PhotosChange(
            kind: .changeAlbum,
            added: previous.count,
            removed: stranded.count,
            total: previous.count
        )) else {
            log.info("Restore declined by the user; the record stays on offer")
            return
        }

        do {
            AlbumSyncGate.shared.begin()
            defer { AlbumSyncGate.shared.end() }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest(for: album)
                if stranded.count > 0 { request?.removeAssets(stranded) }
                request?.addAssets(previous)
            }
            defaults.removeObject(forKey: interruptedMembershipDefaultsKey)
            log.info("Restored \(previous.count) photos after an interrupted sync")
        } catch {
            log.error("Restoring after an interrupted sync failed; still on offer: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a previous sync died partway and left the album mid-rebuild, so
    /// the Export tab can offer to put it back (FR-6.8). A plain read of the
    /// record `sync` writes before it touches anything.
    static var hasInterruptedSync: Bool {
        UserDefaults.standard.stringArray(forKey: interruptedMembershipDefaultsKey)?.isEmpty == false
    }

    private static func fetchAlbum(identifier: String) -> PHAssetCollection? {
        PHAssetCollection
            .fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
            .firstObject
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }
}
