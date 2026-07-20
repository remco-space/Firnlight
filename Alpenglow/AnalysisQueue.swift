import AppKit
import Foundation
import Photos
import SwiftData
import os

/// Aggregate analysis counters across the whole store.
/// `nonisolated`: plain value type, produced inside the AnalysisQueue actor.
nonisolated struct AnalysisStatistics: Sendable, Equatable {
    var total = 0
    var pending = 0
    var accepted = 0
    var utility = 0
    var people = 0
    var notNature = 0
    var skipped = 0
    var horizonPending = 0

    var analyzed: Int { total - pending }

    /// Fully analyzed — deferred iCloud records don't count until they're done.
    var completed: Int { total - pending - skipped }
}

/// Resumable Vision pipeline over the candidate store.
///
/// Processes records in batches of `Thresholds.analysisBatchSize`, saving after
/// each batch, so killing the app mid-analysis loses at most one batch. Pending
/// work is simply every record with `analysisVersion < currentAnalysisVersion`.
@ModelActor
actor AnalysisQueue {
    private static let log = Logger(subsystem: "space.remco.Alpenglow", category: "AnalysisQueue")

    private enum ItemResult: Sendable {
        case analyzed(String, ImageAnalyzer.Outcome)
        case skipped(String)
    }

    /// Deferred (iCloud-only) records already retried this run session, so a
    /// record whose download keeps failing can't loop forever.
    private var attemptedNetworkRetries: Set<String> = []

    /// Starts a fresh run session, making deferred records eligible for retry again.
    func beginSession() {
        attemptedNetworkRetries.removeAll()
    }

    /// Analyzes the next batch and saves. Returns the number of records
    /// processed, or nil when nothing is left to do this session.
    ///
    /// Two passes: first every pending record, local resources only. Once none
    /// are pending, deferred iCloud-only records are retried with network
    /// downloads allowed — so local photos always finish first.
    func processNextBatch() async throws -> Int? {
        let version = Thresholds.currentAnalysisVersion
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.analysisVersion < version }
        )
        descriptor.fetchLimit = Thresholds.analysisBatchSize
        var batch = try modelContext.fetch(descriptor)
        var allowNetwork = false

        if batch.isEmpty {
            let attempted = Array(attemptedNetworkRetries)
            var retryDescriptor = FetchDescriptor<PhotoRecord>(
                predicate: #Predicate { $0.isSkipped && !attempted.contains($0.localIdentifier) }
            )
            retryDescriptor.fetchLimit = Thresholds.analysisBatchSize
            batch = try modelContext.fetch(retryDescriptor)
            allowNetwork = true
            attemptedNetworkRetries.formUnion(batch.map(\.localIdentifier))
        }

        // Third pass: horizon backfill for accepted photos analyzed before the
        // horizon prior existed. New analyses measure it inline.
        if batch.isEmpty {
            return try await processHorizonBatch()
        }
        guard !batch.isEmpty else { return nil }

        let byIdentifier = Dictionary(uniqueKeysWithValues: batch.map { ($0.localIdentifier, $0) })

        // Vision work runs outside the actor; only Sendable values cross the boundary.
        let useNetwork = allowNetwork
        let results = try await runBatch(batch.map(\.localIdentifier)) { id in
            await Self.analyzeAsset(id, allowNetwork: useNetwork)
        }

        for result in results {
            switch result {
            case .analyzed(let id, let outcome):
                guard let record = byIdentifier[id] else { continue }
                record.isUtility = outcome.isUtility
                record.hasPeople = outcome.hasPeople
                record.isNature = outcome.isNature
                record.aestheticsScore = outcome.aestheticsScore
                record.featurePrint = outcome.featurePrint
                record.horizonAngleDegrees = outcome.horizonAngleDegrees
                record.horizonMeasured = true
                record.isSkipped = false
                record.analysisVersion = version
                record.analyzedAt = Date()
            case .skipped(let id):
                guard let record = byIdentifier[id] else { continue }
                record.isSkipped = true
                record.analysisVersion = version
                record.analyzedAt = Date()
            }
        }
        try modelContext.save()
        return results.count
    }

    /// Measures horizon tilt for accepted records that predate the horizon
    /// prior. Returns nil when none remain.
    private func processHorizonBatch() async throws -> Int? {
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.horizonMeasured }
        )
        descriptor.fetchLimit = Thresholds.analysisBatchSize
        let batch = try modelContext.fetch(descriptor)
        guard !batch.isEmpty else { return nil }

        let byIdentifier = Dictionary(uniqueKeysWithValues: batch.map { ($0.localIdentifier, $0) })

        let results = try await runBatch(batch.map(\.localIdentifier)) { id in
            await Self.measureHorizonForAsset(id)
        }

        for (id, angle) in results {
            guard let record = byIdentifier[id] else { continue }
            record.horizonAngleDegrees = angle
            record.horizonMeasured = true
        }
        try modelContext.save()
        return results.count
    }

    /// Bounded-concurrency batch runner shared by the analysis and horizon
    /// passes: seeds `Thresholds.analysisConcurrency` tasks, then refills one
    /// at a time as each finishes, so at most that many requests are ever in
    /// flight regardless of batch size.
    private func runBatch<T: Sendable>(
        _ ids: [String],
        work: @Sendable @escaping (String) async -> T
    ) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(ids.count)
        try await withThrowingTaskGroup(of: T.self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<Thresholds.analysisConcurrency {
                if let id = pending.next() {
                    group.addTask { await work(id) }
                }
            }
            while let result = try await group.next() {
                results.append(result)
                if let id = pending.next() {
                    group.addTask { await work(id) }
                }
            }
        }
        return results
    }

    /// Returns nil for the angle when the photo is unmeasurable now, so the
    /// pass still marks it measured and completes.
    private static func measureHorizonForAsset(_ identifier: String) async -> (String, Float?) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let image = await analysisBitmap(for: asset, allowNetwork: true) else {
            return (identifier, nil)
        }
        let angle = (try? await ImageAnalyzer.measureHorizon(image)) ?? nil
        return (identifier, angle)
    }

    func statistics() throws -> AnalysisStatistics {
        let version = Thresholds.currentAnalysisVersion
        func count(_ predicate: Predicate<PhotoRecord>) throws -> Int {
            try modelContext.fetchCount(FetchDescriptor(predicate: predicate))
        }
        var stats = AnalysisStatistics()
        stats.total = try modelContext.fetchCount(FetchDescriptor<PhotoRecord>())
        stats.pending = try count(#Predicate { $0.analysisVersion < version })
        stats.accepted = try count(#Predicate { $0.isNature })
        stats.utility = try count(#Predicate { $0.isUtility })
        stats.people = try count(#Predicate { $0.hasPeople })
        stats.notNature = try count(#Predicate {
            $0.analysisVersion == version && !$0.isNature && !$0.isUtility && !$0.hasPeople && !$0.isSkipped
        })
        stats.skipped = try count(#Predicate { $0.isSkipped })
        stats.horizonPending = try count(#Predicate { $0.isNature && !$0.horizonMeasured })
        return stats
    }

    // MARK: Per-asset work (off-actor; no model objects cross this boundary)

    private static func analyzeAsset(_ identifier: String, allowNetwork: Bool) async -> ItemResult {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let image = await analysisBitmap(for: asset, allowNetwork: allowNetwork) else {
            return .skipped(identifier)
        }
        do {
            return .analyzed(identifier, try await ImageAnalyzer.analyze(image))
        } catch {
            log.error("Vision analysis failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .skipped(identifier)
        }
    }

    /// Requests a ≤1024 px analysis bitmap, center-cropped to the main display's
    /// aspect ratio. In the local pass, iCloud-only originals return nil and the
    /// record is deferred; the retry pass allows network downloads so deferred
    /// photos are analyzed after all local ones.
    ///
    /// Cropping before any Vision request is deliberate: macOS fills the desktop
    /// with a center crop and the duels judge that same crop, so the ranker must
    /// learn from the pixels the user will actually see — not the whole panorama.
    private static func analysisBitmap(for asset: PHAsset, allowNetwork: Bool) async -> CGImage? {
        let side = CGFloat(Thresholds.analysisPixelSize)
        guard let image = await PhotoImageLoading.image(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            allowNetwork: allowNetwork
        ) else { return nil }
        return centerCropped(image, toAspect: mainDisplayAspectRatio)
    }

    /// Main display's aspect ratio (width / height). Read via CoreGraphics so it
    /// is safe off the main actor; falls back to 16:10 when the bounds are
    /// unavailable (e.g. headless) and would otherwise be zero.
    private static var mainDisplayAspectRatio: CGFloat {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return 16.0 / 10.0 }
        return bounds.width / bounds.height
    }

    /// Center-crops `image` to `aspect` (width / height), trimming whichever
    /// pair of edges overhangs. Returns the original if cropping fails.
    private static func centerCropped(_ image: CGImage, toAspect aspect: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropRect: CGRect
        if width / height > aspect {
            // Too wide — trim the sides.
            let cropWidth = (height * aspect).rounded()
            cropRect = CGRect(x: ((width - cropWidth) / 2).rounded(), y: 0, width: cropWidth, height: height)
        } else {
            // Too tall — trim top and bottom.
            let cropHeight = (width / aspect).rounded()
            cropRect = CGRect(x: 0, y: ((height - cropHeight) / 2).rounded(), width: width, height: cropHeight)
        }
        return image.cropping(to: cropRect) ?? image
    }
}
