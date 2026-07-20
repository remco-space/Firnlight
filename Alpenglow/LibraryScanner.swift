import Foundation
import Photos
import SwiftData
import Observation
import os

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
        case finished(candidates: Int, examined: Int, newlyAdded: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let log = Logger(subsystem: "space.remco.Alpenglow", category: "LibraryScanner")

    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }

    /// Runs a full metadata scan, inserting records for candidates not seen before.
    /// Safe to re-run: existing records are left untouched.
    func scan(into context: ModelContext) async {
        guard !isScanning else { return }
        phase = .scanning(examined: 0, total: 0)

        do {
            // Existing records by identifier: re-scans insert new assets and
            // refresh mutable metadata (favorites) on known ones.
            let existingRecords = try context.fetch(FetchDescriptor<PhotoRecord>())
            let recordsByIdentifier = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.localIdentifier, $0) })

            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: options)
            let total = assets.count
            phase = .scanning(examined: 0, total: total)
            log.info("Scan started: \(total) images in library, \(existingRecords.count) records already stored")

            var newlyAdded = 0
            var unsavedChanges = 0

            for index in 0..<total {
                let asset = assets.object(at: index)

                if isCandidate(asset) {
                    if let record = recordsByIdentifier[asset.localIdentifier] {
                        if record.isFavorite != asset.isFavorite {
                            record.isFavorite = asset.isFavorite
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

            try context.save()
            let candidates = try context.fetchCount(FetchDescriptor<PhotoRecord>())
            phase = .finished(candidates: candidates, examined: total, newlyAdded: newlyAdded)
            log.info("Scan finished: \(total) examined, \(candidates) candidates (\(newlyAdded) new)")
        } catch {
            log.error("Scan failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Metadata-only wallpaper pre-filter; never touches pixel data.
    private func isCandidate(_ asset: PHAsset) -> Bool {
        asset.pixelWidth > asset.pixelHeight
            && asset.pixelWidth >= Thresholds.minimumCandidatePixelWidth
            && !asset.mediaSubtypes.contains(.photoScreenshot)
    }
}
