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
        case finished(candidates: Int, examined: Int, newlyAdded: Int, editedQueued: Int, removed: Int)
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
            var seenIdentifiers: Set<String> = []
            seenIdentifiers.reserveCapacity(existingRecords.count)

            for index in 0..<total {
                let asset = assets.object(at: index)
                let record = recordsByIdentifier[asset.localIdentifier]
                if record != nil {
                    seenIdentifiers.insert(asset.localIdentifier)
                }

                if isCandidate(asset) {
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
            for (identifier, record) in recordsByIdentifier where !seenIdentifiers.contains(identifier) {
                context.delete(record)
                removed += 1
            }

            try context.save()
            let candidates = try context.fetchCount(FetchDescriptor<PhotoRecord>())
            phase = .finished(candidates: candidates, examined: total, newlyAdded: newlyAdded, editedQueued: editedQueued, removed: removed)
            log.info("Scan finished: \(total) examined, \(candidates) candidates (\(newlyAdded) new, \(editedQueued) edited queued for re-analysis, \(removed) removed)")
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
