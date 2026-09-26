import CoreLocation
import Foundation
import MapKit
import SwiftData
import os

/// Asks Apple's maps service what a spot is called — FR-5.13's own end in
/// itself ("to learn what that place is called"), and, per FR-5.14, the
/// source of a genuine fifth ranking scale: "where the network allows, the
/// app also learns what Apple's maps call the place... and that name
/// counts as one more of the places the photo is known by." **Never** a
/// fallback or refinement of `PlaceGazetteer`'s four offline scales, which
/// stay fully available with no network either way (FR-9.3) — see
/// `PlaceHierarchy`'s doc comment for the concrete leak an earlier revision
/// risked by trying to fold a resolved name into an offline scale key
/// instead of keeping it separate (Apple's place-name vocabulary doesn't
/// line up with the offline gazetteer's dataset-native ids, and this is the
/// one lookup in the whole pipeline whose answer can change mid-run).
///
/// One coordinate per not-yet-answered spot (rounded to
/// `PlaceHierarchy.networkCacheKey`, purely for cache deduplication — see
/// that function's doc comment) is sent to `MKReverseGeocodingRequest` —
/// never a photo, never anything about the photo, exactly the "where a
/// photo was taken — never anything else about it" FR-1.5 allows.
/// `MKMapItem.placemark` is deprecated as of macOS/iOS 26 in favour of
/// `.addressRepresentations`, which is what this reads: `cityName` (see
/// `PlaceNameRecord`'s doc comment for `regionName`, cached but no longer
/// part of the composed key — see `PlaceHierarchy.networkPlaceKey`'s doc
/// comment for why: it is country-level only and identical across every
/// real place sharing Apple's own city name, confirmed empirically, so it
/// cannot disambiguate the way the key's actual anchor does) is composed
/// with each record's own offline region/country key and written onto
/// every `PhotoRecord` sharing the resolved cell (see `save`) — not just
/// cached in
/// `PlaceNameRecord`, which exists purely so the *next* photo taken near
/// the same spot never costs a second round trip.
///
/// Never triggers a download of anything: it reads `PhotoRecord.latitude`/
/// `longitude`, already on disk from the metadata scan, so resolving a place
/// name never "pulls down more of a photo than examining it already
/// requires" (FR-5.13, referencing FR-3.4).
///
/// Plain actor with its own `ModelContext`, matching every other store-owning
/// actor in this app (`FeatureStore`, `PreferenceRanker`, `AnalysisQueue`) —
/// same `DefaultSerialModelExecutor` reasoning as their doc comments give,
/// for the SwiftData work in `nextPendingSpot`/`save`. The network call in
/// between is a partial exception: `MKReverseGeocodingRequest`'s
/// `getMapItemsWithCompletionHandler:` is `NS_SWIFT_UI_ACTOR`-annotated in
/// the macOS/iOS 27 SDK (`#define NS_SWIFT_UI_ACTOR NS_SWIFT_MAIN_ACTOR`),
/// so the `mapItems` async property Swift synthesizes from it is
/// main-actor-isolated — `try await request.mapItems` in `resolveNext()`
/// hops to the main actor to await the network response and back to this
/// actor afterward. That hop is asynchronous, never blocking (FR-8.2's
/// concern is a frozen main thread, not a main-actor task that's merely
/// awaiting something), so it doesn't change anything this type promises;
/// it only means "this actor's own SwiftData work runs off the main actor"
/// is true of every method here except the one line that awaits the
/// network response.
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
        guard let target = try nextPendingSpot() else { return .nothingPending }

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
            try save(cacheKey: target.cacheKey, cityName: nil, regionName: nil)
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
        try save(cacheKey: target.cacheKey, cityName: address?.cityName, regionName: address?.regionName)
        Self.log.info("Resolved a place: city=\(address?.cityName ?? "none", privacy: .public) region=\(address?.regionName ?? "none", privacy: .public)")
        return .resolved
    }

    /// How many otherwise-eligible candidates have no FR-5.14 fifth-scale
    /// answer yet — `!networkPlaceResolved`, the state `LibraryScanner
    /// .applyNetworkPlaceNames` and `PlaceNameLookup.save` both set true
    /// once a record has an answer either way (a name, or a confirmed "no
    /// name"). Exposed so the Library tab can say what remains (FR-3.5)
    /// rather than let this background work go invisible the moment
    /// Vision's own analysis finishes — FR-3.4/FR-5.13's "the app never
    /// claims completion while deferred work remains" applies here too,
    /// not only to iCloud downloads. Same eligibility restriction as
    /// `nextPendingSpot`, counted instead of stopping at the first.
    func pendingCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.latitude != nil && !$0.networkPlaceResolved }
        ))
    }

    private struct PendingSpot {
        let cacheKey: String
        let latitude: Double
        let longitude: Double
    }

    /// One spot with no `PlaceNameRecord` yet, among the photos the rest of
    /// the app currently treats as live candidates — the same
    /// `isNature && !isExcluded` restriction every ranking-affecting query
    /// uses, so a lookup is never spent on a photo that has left the
    /// pipeline. Deliberately not restricted to a serving analysis
    /// generation (`AnalysisGeneration`): the location a photo records
    /// doesn't change between Vision pipeline versions, so a spot is worth
    /// resolving regardless of which generation is currently serving.
    private func nextPendingSpot() throws -> PendingSpot? {
        var descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.isNature && !$0.isExcluded && $0.latitude != nil && $0.longitude != nil }
        )
        // Only the two columns are needed to compute a cache key; the rest
        // of each row stays unfaulted, matching `AnalysisGeneration`'s
        // reasoning for the same kind of scan (FR-8.2).
        descriptor.propertiesToFetch = [\.latitude, \.longitude]

        let known = Set(try modelContext.fetch(FetchDescriptor<PlaceNameRecord>()).map(\.cacheKey))
        for record in try modelContext.fetch(descriptor) {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            let key = PlaceHierarchy.networkCacheKey(latitude: latitude, longitude: longitude)
            guard !known.contains(key) else { continue }
            return PendingSpot(cacheKey: key, latitude: latitude, longitude: longitude)
        }
        return nil
    }

    /// Records the answer once (`PlaceNameRecord`, keyed by grid cell, so
    /// the next photo near this spot skips the round trip) and writes it
    /// onto every `PhotoRecord` sharing that cell right away — not only the
    /// one that happened to trigger this lookup (`nextPendingSpot` returns
    /// the first pending spot it finds; several photos can round to the
    /// same cell) — so FR-5.14's fifth scale is available to every one of
    /// them the moment their cell resolves, never only lazily on some later
    /// call. Every record with a location is walked, not only current
    /// candidates: a photo excluded today and un-ignored tomorrow already
    /// carries the answer rather than waiting for its cell to be re-asked
    /// about (it never will be — `nextPendingSpot` only asks once per
    /// cell).
    ///
    /// The composed key is built **per record**, not once for the whole
    /// cell: `PlaceHierarchy.networkPlaceKey`'s anchor is each record's own
    /// offline region/country key, and while every photo in one ~1.1 km
    /// grid cell is almost always in the same region, a cell straddling a
    /// region boundary could anchor two of its own photos differently —
    /// correctly, since that anchor is what keeps two distinct real places
    /// from colliding into one key in the first place. Anchors are already
    /// resolved by the time this runs: `LibraryScanner` computes and saves
    /// every record's `gazetteerRegion`/`gazetteerCountry` before this
    /// actor's own `ModelContext` can see the row at all (a different
    /// context reading the same store never observes another context's
    /// uncommitted changes).
    private func save(cacheKey: String, cityName: String?, regionName: String?) throws {
        modelContext.insert(PlaceNameRecord(cacheKey: cacheKey, cityName: cityName, regionName: regionName))

        let descriptor = FetchDescriptor<PhotoRecord>(
            predicate: #Predicate { $0.latitude != nil && $0.longitude != nil }
        )
        for record in try modelContext.fetch(descriptor) {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            guard PlaceHierarchy.networkCacheKey(latitude: latitude, longitude: longitude) == cacheKey else { continue }
            let anchor = record.gazetteerRegion ?? record.gazetteerCountry
            record.networkPlaceName = PlaceHierarchy.networkPlaceKey(cityName: cityName, anchorKey: anchor)
            record.networkPlaceResolved = true
        }

        try modelContext.save()
    }
}
