import CoreLocation
import Foundation
import MapKit
import SwiftData
import os

/// Resolves place names for the app's own offline grid cells (FR-5.13,
/// FR-1.5's exception) — never required for ranking to work (see
/// `PlaceHierarchy`), only ever a refinement of it.
///
/// One coordinate per not-yet-answered fine cell is sent to
/// `MKReverseGeocodingRequest` — never a photo, never anything about the
/// photo, exactly the "where a photo was taken — never anything else about
/// it" FR-1.5 allows. `MKMapItem.placemark` is deprecated as of macOS/iOS 26
/// in favour of `.addressRepresentations`, which is what this reads:
/// `cityName` for FR-5.14's fine scale and `regionName` for its coarse scale
/// (see `PlaceNameRecord`'s doc comment for why `regionName` is the country
/// despite its name). Neither replaces the medium scale, which
/// `MKAddressRepresentations` has no field for at all — see
/// `PlaceHierarchy`'s doc comment.
///
/// Never triggers a download of anything: it reads `PhotoRecord.latitude`/
/// `longitude`, already on disk from the metadata scan, so resolving a place
/// name never "pulls down more of a photo than examining it already
/// requires" (FR-5.13, referencing FR-3.4).
///
/// Plain actor with its own `ModelContext`, matching every other store-owning
/// actor in this app (`FeatureStore`, `PreferenceRanker`, `AnalysisQueue`) —
/// same `DefaultSerialModelExecutor` reasoning as their doc comments give.
actor PlaceNameLookup {
    private let modelContainer: ModelContainer
    private lazy var modelContext = ModelContext(modelContainer)

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private static let log = Logger(subsystem: "space.remco.Firnlight", category: "PlaceNameLookup")

    /// What one call accomplished — the caller's cue for how long to wait
    /// before calling again. `.resolved` paces itself gently (FR-5.13's "at
    /// the pace the source permits"); the other two back off longer, since
    /// nothing will have changed until the library gains a new location or
    /// the network does.
    enum Outcome: Sendable, Equatable {
        case resolved
        case nothingPending
        case waitingForNetwork
    }

    func resolveNext() async throws -> Outcome {
        guard NetworkPolicy.shared.allowsNetworkUse else { return .waitingForNetwork }
        guard let target = try nextPendingCell() else { return .nothingPending }

        // Exactly the coordinate, nothing else about the photo it came from —
        // FR-1.5's "never anything else about it". A fresh, minimal
        // `CLLocation` rather than reusing `PhotoRecord`'s own
        // `CLLocation`-derived fields, which also carry altitude and camera
        // heading that have no business leaving the device.
        let location = CLLocation(latitude: target.latitude, longitude: target.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            // Documented to fail only on an invalid location; caching a
            // permanent "no name" keeps a malformed coordinate from being
            // retried forever.
            try save(cellKey: target.cellKey, cityName: nil, regionName: nil)
            return .resolved
        }

        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch {
            // A real failure to reach the service — leave this cell pending.
            // The caller backs off and the exact same cell is tried again
            // later, the deferred-retry shape FR-3.4 already established for
            // iCloud downloads, applied here to a different kind of deferred
            // work.
            Self.log.info("Place name lookup deferred: \(error.localizedDescription, privacy: .public)")
            return .waitingForNetwork
        }

        // An answer, even an empty one, is remembered permanently (FR-5.13's
        // "asks about each place once") — open water and unindexed places
        // genuinely have no name to give, and that is itself the answer.
        let address = items.first?.addressRepresentations
        try save(cellKey: target.cellKey, cityName: address?.cityName, regionName: address?.regionName)
        Self.log.info("Resolved a place cell: city=\(address?.cityName ?? "none", privacy: .public) region=\(address?.regionName ?? "none", privacy: .public)")
        return .resolved
    }

    private struct PendingCell {
        let cellKey: String
        let latitude: Double
        let longitude: Double
    }

    /// One fine cell with no `PlaceNameRecord` yet, among the photos the rest
    /// of the app currently treats as live candidates — the same
    /// `isNature && !isExcluded` restriction every ranking-affecting query
    /// uses, so a lookup is never spent on a photo that has left the
    /// pipeline. Deliberately not restricted to a serving analysis
    /// generation (`AnalysisGeneration`): the location a photo records
    /// doesn't change between Vision pipeline versions, so a cell is worth
    /// resolving regardless of which generation is currently serving.
    private func nextPendingCell() throws -> PendingCell? {
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.latitude != nil && $0.longitude != nil }
        )
        // Only the two columns are needed to compute a cell key; the rest of
        // each row stays unfaulted, matching `AnalysisGeneration`'s reasoning
        // for the same kind of scan (FR-8.2).
        descriptor.propertiesToFetch = [\.latitude, \.longitude]

        let known = Set(try modelContext.fetch(FetchDescriptor<PlaceNameRecord>()).map(\.fineCellKey))
        for record in try modelContext.fetch(descriptor) {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            let fine = PlaceHierarchy.scaleKeys(latitude: latitude, longitude: longitude).fine
            guard !known.contains(fine) else { continue }
            return PendingCell(cellKey: fine, latitude: latitude, longitude: longitude)
        }
        return nil
    }

    private func save(cellKey: String, cityName: String?, regionName: String?) throws {
        modelContext.insert(PlaceNameRecord(fineCellKey: cellKey, cityName: cityName, regionName: regionName))
        try modelContext.save()
    }
}
