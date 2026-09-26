import Foundation

/// Where a photo was taken, as a nested "place" rather than a bare
/// coordinate — FR-5.14's three scales, always available with **no
/// network** (FR-9.3), and named "as published geographic references name
/// and bound them" rather than invented by the app.
///
/// The actual gazetteer — the bundled place names and boundaries, and the
/// point-in-polygon/nearest-point lookups over them — lives in
/// `PlaceGazetteer`; this type is the one place both `PreferenceRanker` and
/// `FeatureStore` go to resolve a record's three scale names, so the two can
/// never compute a different answer for the same photo. (An earlier
/// revision had each file do its own resolution, which is exactly how a
/// name resolved by `PlaceNameLookup` ended up read under one key in one
/// file and a different key in the other.)
///
/// `nonisolated`: pure functions of a coordinate or a record, called from
/// whichever actor is building trait or diversity vectors.
nonisolated enum PlaceHierarchy {
    /// A photo's name at each of FR-5.14's three scales — a town or park, a
    /// region or landscape, a country — independently nil where there's no
    /// answer for that scale (no location at all, or one too far from
    /// anything `PlaceGazetteer` knows: FR-3.8's gap, not a penalty).
    struct ScaleKeys: Sendable, Equatable {
        let fine: String?
        let medium: String?
        let coarse: String?
    }

    /// The offline floor (FR-5.14, FR-9.3): `PlaceGazetteer`'s answer for a
    /// bare coordinate, with no network and no cache involved. Called from
    /// `LibraryScanner` when a photo's location is first seen or changes,
    /// and cached on `PhotoRecord` (`gazetteerTown`/`gazetteerRegion`/
    /// `gazetteerCountry`) — never recomputed on every ranker reload, which
    /// would otherwise repeat a point-in-polygon/nearest-point search over
    /// the whole gazetteer for every candidate on every duel (FR-8.2).
    static func offlineKeys(latitude: Double, longitude: Double) -> ScaleKeys {
        ScaleKeys(
            fine: PlaceGazetteer.nearestPlace(latitude: latitude, longitude: longitude),
            medium: PlaceGazetteer.nearestRegion(latitude: latitude, longitude: longitude),
            coarse: PlaceGazetteer.country(latitude: latitude, longitude: longitude)
        )
    }

    /// The keys `PreferenceRanker` and `FeatureStore` actually rank and mix
    /// by, for one record: the cached offline floor
    /// (`PhotoRecord.gazetteerTown`/`gazetteerRegion`/`gazetteerCountry`),
    /// with the fine and coarse scales replaced by a network-resolved name
    /// once `PlaceNameLookup` has one for this location (FR-5.13's "what
    /// cannot be looked up yet waits… until it is complete the app ranks on
    /// what it already knows" — the gazetteer name is what it already
    /// knows). The medium scale never has a network-resolved replacement —
    /// see `PlaceGazetteer`'s doc comment on why nothing names that scale
    /// more precisely than the gazetteer already does.
    ///
    /// `networkNameCache` is the caller's one fetch of every
    /// `PlaceNameRecord`, keyed by `networkCacheKey` — passed in rather than
    /// fetched here, the once-per-query discipline this app's other
    /// per-record helpers already follow.
    static func resolvedNames(
        for record: PhotoRecord,
        networkNameCache: [String: (city: String?, region: String?)]
    ) -> ScaleKeys {
        guard let latitude = record.latitude, let longitude = record.longitude else {
            return ScaleKeys(fine: nil, medium: nil, coarse: nil)
        }
        let resolved = networkNameCache[networkCacheKey(latitude: latitude, longitude: longitude)]
        return ScaleKeys(
            fine: resolved?.city ?? record.gazetteerTown,
            medium: record.gazetteerRegion,
            coarse: resolved?.region ?? record.gazetteerCountry
        )
    }

    /// The grid `PlaceNameLookup` rounds a coordinate to when deciding
    /// whether it has already asked Apple's maps service about "this spot",
    /// and what `PlaceNameRecord.cacheKey` is keyed by. Purely a
    /// cache-deduplication granularity (`Thresholds.placeNameLookupCacheGridDegrees`)
    /// — never a place identity in its own right, unlike the grid this
    /// module used to define for ranking before it was rewritten around
    /// `PlaceGazetteer`'s real, published places (see git history if that
    /// design needs revisiting; nothing in the current code depends on it).
    static func networkCacheKey(latitude: Double, longitude: Double) -> String {
        let grid = Thresholds.placeNameLookupCacheGridDegrees
        let latCell = (latitude / grid).rounded()
        let lonCell = (longitude / grid).rounded()
        return "\(latCell):\(lonCell)"
    }
}
