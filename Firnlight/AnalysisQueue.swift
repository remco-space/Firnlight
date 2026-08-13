import CoreGraphics
import Foundation
import Network
import Photos
import SwiftData
import os
#if os(iOS)
import UIKit
#endif

/// Why an analysis run is waiting rather than working (FR-3.4, FR-3.6, FR-3.7).
///
/// Every case but the last is a condition the *system* reports, never one the
/// app invented: the requirements are explicit that Firnlight obeys the user's
/// system-wide choices rather than adding settings of its own, so there is
/// deliberately no in-app "Wi-Fi only" toggle or thermal preference to pair
/// with these. `iCloudRetryPending` is the exception and the one wait the app
/// does schedule for itself, because FR-3.4 hands it that job: deferred photos
/// are retried by the app when network and power allow, so between rounds
/// there is a wait that belongs to nobody but the app, and saying so is better
/// than a run that looks stalled.
///
/// `CaseIterable` so the view can lay out every message this can carry and
/// size its slot to the longest of them before any wait begins (FR-8.7) — see
/// `AnalysisView`'s waiting label.
nonisolated enum AnalysisWait: Sendable, Equatable, CaseIterable {
    case deviceHot
    case lowPowerMode
    case systemBusy
    case lowDataMode
    case cellularNetwork
    case noNetwork
    case iCloudRetryPending

    /// Said in the user's terms — what is being waited for, and why — rather
    /// than naming the API that reported it.
    var message: String {
        switch self {
        case .deviceHot:
            // Named for the machine the user is looking at: "device" is what
            // an iPhone is called and what a Mac is not.
            #if os(macOS)
            "Waiting — the Mac is too warm to keep analyzing."
            #else
            "Waiting — the device is too warm to keep analyzing."
            #endif
        case .lowPowerMode:
            "Waiting — Low Power Mode is on."
        case .systemBusy:
            "Waiting — the system has asked apps to ease off."
        case .lowDataMode:
            "Waiting for Wi-Fi — Low Data Mode is on, so iCloud photos aren't downloading."
        case .cellularNetwork:
            "Waiting for Wi-Fi — iCloud photos aren't downloading over cellular."
        case .noNetwork:
            "Waiting for a network connection to download iCloud photos."
        case .iCloudRetryPending:
            "Waiting to try the remaining iCloud photos again."
        }
    }
}

/// FR-3.7: the user's system-wide network policy, taken from the system's own
/// description of the current path.
///
/// `isConstrained` is Low Data Mode and `isExpensive` is cellular — the two
/// ways the user tells the whole system to go easy on a network. PhotoKit
/// offers exactly one knob, `isNetworkAccessAllowed`, with no per-request
/// constrained/expensive option, and the download runs out-of-process in the
/// Photos daemon, so the app's own `URLSessionConfiguration` flags cannot
/// reach it. Consulting the path and declining to *ask* is therefore the only
/// way to honour those settings for iCloud originals — which are exactly the
/// kind of deferrable bulk transfer they exist to hold back.
///
/// One long-lived monitor: `currentPath` is only populated once started, and
/// starting one per query would answer from a default path. The first query
/// after launch can still race the monitor's first update; the run re-checks
/// on `Thresholds.analysisPauseRecheckInterval`, so a momentarily wrong answer
/// costs one interval and nothing else.
nonisolated final class NetworkPolicy: Sendable {
    static let shared = NetworkPolicy()

    private let monitor = NWPathMonitor()

    private init() {
        monitor.start(queue: DispatchQueue(label: "space.remco.Firnlight.NetworkPolicy"))
    }

    /// nil when iCloud downloads may proceed, else what to wait for.
    var iCloudDownloadWait: AnalysisWait? {
        let path = monitor.currentPath
        guard path.status == .satisfied else { return .noNetwork }
        if path.isConstrained { return .lowDataMode }
        if path.isExpensive { return .cellularNetwork }
        return nil
    }
}

/// The system conditions that decide whether a run may proceed at all, and
/// whether it may pull originals down from iCloud.
@MainActor
enum RunConditions {
    /// FR-3.6: a long run shouldn't cost the user battery or a hot device.
    /// Checked between batches, which is already the loop's natural
    /// checkpoint — analysis is saved per batch, so pausing there costs
    /// nothing and resumes exactly where it stopped.
    ///
    /// Every platform, because the requirement carries no platform marker and
    /// REQUIREMENTS.md's opening says an unmarked requirement applies
    /// everywhere. A Mac was once left out here on the grounds that pausing
    /// would surprise the user, which was reading a preference into a brief
    /// that states the opposite — and it stopped being even arguable once
    /// `UnattendedRun` began holding the Mac awake through a long run: a
    /// laptop the app keeps from sleeping, on Low Power Mode, warm on the
    /// user's knees, is precisely the case the clause was written for. The
    /// two signals it names are `ProcessInfo`'s, which reports both on macOS
    /// and iOS.
    ///
    /// `systemPrefersReducedResourceUsage` is checked first where it exists,
    /// as the system's own aggregate judgement; it is genuinely iPhone- and
    /// iPad-only, being `UIApplication`'s. Thermal state and Low Power Mode
    /// follow as the specific conditions FR-3.6 names, since the aggregate
    /// signal is not documented to cover both. All three are unconditional —
    /// the deployment floor is macOS/iOS 27 (REQUIREMENTS.md's opening), which
    /// is at or past every one of their introductions.
    static func pauseReason() -> AnalysisWait? {
        #if os(iOS)
        if UIApplication.shared.systemPrefersReducedResourceUsage {
            return .systemBusy
        }
        #endif
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .deviceHot
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        return nil
    }

    /// FR-3.7: nil when iCloud downloads may proceed. Applies on every
    /// platform — the requirement is unmarked, and Low Data Mode exists on
    /// the Mac too.
    static var iCloudDownloadWait: AnalysisWait? {
        NetworkPolicy.shared.iCloudDownloadWait
    }
}

/// Aggregate analysis counters across the whole store.
/// `nonisolated`: plain value type, produced inside the AnalysisQueue actor.
nonisolated struct AnalysisStatistics: Sendable, Equatable {
    var total = 0
    var pending = 0
    var accepted = 0
    var utility = 0
    var flawed = 0
    var people = 0
    var notNature = 0
    var skipped = 0
    /// Pixels were available and Vision failed anyway — see
    /// `PhotoRecord.analysisFailed`. Distinct from `skipped`, which is the
    /// genuinely-waiting-on-iCloud bucket.
    var failed = 0

    var analyzed: Int { total - pending }

    /// Fully analyzed — deferred iCloud records don't count until they're done.
    /// Failures *do* count: nothing further will happen to them, so leaving
    /// them out would stall the pipeline short of "complete" forever (FR-3.5).
    var completed: Int { total - pending - skipped }
}

/// Resumable Vision pipeline over the candidate store.
///
/// Processes records in batches of `Thresholds.analysisBatchSize`, saving after
/// each batch, so killing the app mid-analysis loses at most one batch. Pending
/// work is simply every record with `analysisVersion < currentAnalysisVersion`.
/// Plain actor with its own `ModelContext`, not `@ModelActor`, so its work
/// truly runs off the main thread — see FeatureStore's doc comment for the
/// `DefaultSerialModelExecutor` caller-thread pitfall this avoids (FR-8.2).
actor AnalysisQueue {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "AnalysisQueue")

    private enum ItemResult: Sendable {
        case analyzed(String, ImageAnalyzer.Outcome)
        /// Pixels weren't available locally — retryable once the network allows
        /// the download.
        case deferred(String)
        /// Pixels were there and Vision failed anyway. Never retried as an
        /// iCloud download, because the network was never the problem.
        case failed(String)
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
    ///
    /// `allowNetworkDownloads` is the caller's answer to FR-3.7: when the
    /// user's network settings don't permit pulling originals down, the second
    /// pass is skipped entirely and this returns nil once local work is done.
    /// Deferred records then stay deferred, which is the honest state — the
    /// caller distinguishes "finished" from "waiting on the network" by
    /// whether any remain (FR-3.4).
    func processNextBatch(allowNetworkDownloads: Bool) async throws -> Int? {
        let version = Thresholds.currentAnalysisVersion
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.analysisVersion < version }
        )
        descriptor.fetchLimit = Thresholds.analysisBatchSize
        var batch = try modelContext.fetch(descriptor)
        var allowNetwork = false

        if batch.isEmpty && allowNetworkDownloads {
            let attempted = Array(attemptedNetworkRetries)
            var retryDescriptor = FetchDescriptor<PhotoRecord>(
                predicate: #Predicate { $0.isSkipped && !attempted.contains($0.localIdentifier) }
            )
            retryDescriptor.fetchLimit = Thresholds.analysisBatchSize
            batch = try modelContext.fetch(retryDescriptor)
            allowNetwork = true
            attemptedNetworkRetries.formUnion(batch.map(\.localIdentifier))
        }

        if batch.isEmpty { return nil }

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
                record.isFlawed = outcome.isFlawed
                record.hasPeople = outcome.hasPeople
                record.isNature = outcome.isNature
                record.aestheticsScore = outcome.aestheticsScore
                record.featurePrint = outcome.featurePrint
                record.horizonAngleDegrees = outcome.horizonAngleDegrees
                record.horizonMeasured = true
                record.isSkipped = false
                record.analysisFailed = false
                record.analysisVersion = version
                record.analyzedAt = Date()
            case .deferred(let id):
                guard let record = byIdentifier[id] else { continue }
                record.isSkipped = true
                record.analysisFailed = false
                record.analysisVersion = version
                record.analyzedAt = Date()
            case .failed(let id):
                guard let record = byIdentifier[id] else { continue }
                // Finished, not deferred: `isSkipped` stays false so this never
                // enters the iCloud retry pass or the "waiting on iCloud"
                // tally, and `analysisVersion` is stamped so the pending pass
                // doesn't pick it up forever either. A version bump re-tries it,
                // which is the right trigger — the analysis logic changing is
                // the one thing that might make it succeed.
                record.isSkipped = false
                record.analysisFailed = true
                record.analysisVersion = version
                record.analyzedAt = Date()
            }
        }
        try modelContext.save()
        return results.count
    }

    /// Bounded-concurrency batch runner for the analysis pass: seeds
    /// `Thresholds.analysisConcurrency` tasks, then refills one
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
        stats.flawed = try count(#Predicate { $0.isFlawed })
        stats.people = try count(#Predicate { $0.hasPeople })
        // `analysisFailed` is excluded here too: a photo Vision couldn't read
        // was never judged "not nature" — the app has no opinion about it.
        stats.notNature = try count(#Predicate {
            $0.analysisVersion == version && !$0.isNature && !$0.isUtility && !$0.isFlawed && !$0.hasPeople && !$0.isSkipped && !$0.analysisFailed
        })
        stats.skipped = try count(#Predicate { $0.isSkipped })
        stats.failed = try count(#Predicate { $0.analysisFailed })
        return stats
    }

    // MARK: Per-asset work (off-actor; no model objects cross this boundary)

    private static func analyzeAsset(_ identifier: String, allowNetwork: Bool) async -> ItemResult {
        // No pixels: genuinely waiting on a download, so deferrable.
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let image = await analysisBitmap(for: asset, allowNetwork: allowNetwork) else {
            return .deferred(identifier)
        }
        do {
            return .analyzed(identifier, try await ImageAnalyzer.analyze(image))
        } catch {
            // The pixels were here and Vision still failed, so this is not an
            // iCloud problem and must not be reported as one. Seen for real in
            // the iOS Simulator, where CoreML has no ANE and every request
            // fails with "Failed to create espresso context" — which the app
            // used to present as ten photos waiting on iCloud, on a device with
            // no iCloud account at all.
            log.error("Vision analysis failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(identifier)
        }
    }

    /// Requests a ≤1024 px analysis bitmap, center-cropped to
    /// `Thresholds.desktopAspectRatio`. In the local pass, iCloud-only
    /// originals return nil and the record is deferred; the retry pass allows
    /// network downloads so deferred photos are analyzed after all local ones.
    ///
    /// Cropping before any Vision request is deliberate: the desktop is filled
    /// with a center crop and the duels judge that same crop, so the ranker
    /// must learn from the pixels the user will actually see — not the whole
    /// panorama. The crop is the one fixed desktop shape rather than this
    /// device's screen, so a record analyzed on an iPhone measures the same
    /// rectangle as one analyzed on the Mac (FR-5.1).
    private static func analysisBitmap(for asset: PHAsset, allowNetwork: Bool) async -> CGImage? {
        let side = CGFloat(Thresholds.analysisPixelSize)
        guard let image = await PhotoImageLoading.image(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            allowNetwork: allowNetwork
        ) else { return nil }
        return centerCropped(image, toAspect: Thresholds.desktopAspectRatio)
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
