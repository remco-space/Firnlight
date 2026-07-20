import Foundation
import Photos
import SwiftData
import os

/// Keeps the "Alpenglow" album in Photos mirroring the current top-ranked,
/// deduplicated wallpaper candidates.
///
/// This is the app's ONLY write path into the Photos library, and it is
/// strictly limited to album creation and album membership — assets themselves
/// are never modified or deleted. (The original never-write rule was revised
/// to album-membership-only with explicit user approval.)
nonisolated enum WallpaperAlbumSync {
    struct Outcome: Sendable, Equatable {
        var added = 0
        var removed = 0
        var total = 0
    }

    enum SyncError: LocalizedError {
        case albumCreationFailed

        var errorDescription: String? {
            switch self {
            case .albumCreationFailed:
                "Couldn't create the “\(Thresholds.wallpaperAlbumName)” album in Photos."
            }
        }
    }

    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "WallpaperAlbumSync")

    /// Makes album membership exactly the current top `count` candidates, in
    /// diversity order (consecutive photos as different as possible), so
    /// "rotate in order" wallpaper settings avoid samey streaks.
    static func sync(container: ModelContainer, count: Int) async throws -> Outcome {
        let ordered = try await FeatureStore(modelContainer: container)
            .albumCandidates(limit: count)
            .candidates
        let orderedIDs = ordered.map(\.localIdentifier)
        let targetIDs = Set(orderedIDs)

        let album = try await fetchOrCreateAlbum(named: Thresholds.wallpaperAlbumName)

        // Diff for reporting; the album itself is rebuilt to impose the order.
        let current = PHAsset.fetchAssets(in: album, options: nil)
        var currentIDs: Set<String> = []
        current.enumerateObjects { asset, _, _ in currentIDs.insert(asset.localIdentifier) }
        let added = targetIDs.subtracting(currentIDs).count
        let removed = currentIDs.subtracting(targetIDs).count

        // fetchAssets(withLocalIdentifiers:) doesn't preserve input order.
        let fetchedTargets = PHAsset.fetchAssets(withLocalIdentifiers: orderedIDs, options: nil)
        var assetByID: [String: PHAsset] = [:]
        fetchedTargets.enumerateObjects { asset, _, _ in assetByID[asset.localIdentifier] = asset }
        let orderedAssets = orderedIDs.compactMap { assetByID[$0] }

        // Two transactions: remove-and-re-add within a single change request
        // lets Photos keep surviving assets at their old positions, which
        // broke the diversity order (verified by the post-sync check).
        if current.count > 0 {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(current)
            }
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(orderedAssets as NSArray)
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

        let outcome = Outcome(added: added, removed: removed, total: orderedAssets.count)
        log.info("Album sync: +\(outcome.added) −\(outcome.removed), total \(outcome.total) (diversity-ordered)")
        return outcome
    }

    private static func fetchOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        if let existing = fetchAlbum(named: name) { return existing }

        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        guard let created = fetchAlbum(named: name) else {
            throw SyncError.albumCreationFailed
        }
        log.info("Created album “\(name, privacy: .public)”")
        return created
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject
    }
}
