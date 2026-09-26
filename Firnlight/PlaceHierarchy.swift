import Foundation

/// Where a photo was taken, as a nested "place" rather than a bare
/// coordinate — FR-5.14's four scales (at least three — fine, landscape,
/// region, coarse — with the last two both political and natural always
/// independently known), always available with **no network** (FR-9.3),
/// and named "as published geographic references name and bound them"
/// rather than invented by the app.
///
/// The actual gazetteer — the bundled place names and boundaries, and the
/// point-in-polygon/nearest-point lookups over them — lives in
/// `PlaceGazetteer`; this type is the one place both `PreferenceRanker` and
/// `FeatureStore` go to read a record's four scale names, so the two can
/// never disagree about what a photo's place is (an earlier revision had
/// each file resolve it independently, which is exactly how a name
/// resolved by `PlaceNameLookup` ended up read under one key in one file
/// and a different key in the other).
///
/// **The network lookup (`PlaceNameLookup`, FR-1.5's exception) is
/// deliberately not read here.** FR-5.13 asks Apple's maps service "to
/// learn what that place is called", and `PlaceNameLookup` still does
/// exactly that — resolves, caches, rate-limits, respects the user's
/// network settings, defers like FR-3.4's iCloud downloads — but its answer
/// never used to replace or qualify a scale key returned here, for a
/// concrete reason found while fixing FR-5.14's leakage clause: Apple's own
/// country string differs from Natural Earth's ("United States" vs.
/// "United States of America", and likewise Russia, Czechia, Korea, Côte
/// d'Ivoire), so a photo's country key would change the moment its network
/// lookup completed — splitting one real place's learned weight across two
/// keys, exactly the leak "never reaches another except through the larger
/// places both belong to" forbids, and the network lookup carries no
/// dataset id of its own to anchor a key against the way every offline
/// table's entries do (see `PlaceGazetteer`'s doc comment). Feeding a
/// resolved name back into the ranking-relevant keys reintroduces
/// instability no offline table has; keeping the two separate is what keeps
/// FR-5.14's "never" true unconditionally rather than "except while a
/// lookup is mid-flight". This is a considered trade-off, not a reading the
/// brief spells out either way — flagged as such rather than left silent.
///
/// `nonisolated`: pure functions of a coordinate or a record, called from
/// whichever actor is building trait or diversity vectors.
nonisolated enum PlaceHierarchy {
    /// A photo's name at each of FR-5.14's four scales — independently nil
    /// where there's no answer for that scale (no location at all, or one
    /// too far from anything `PlaceGazetteer` knows: FR-3.8's gap, not a
    /// penalty).
    struct ScaleKeys: Sendable, Equatable {
        let fine: String?
        let landscape: String?
        let region: String?
        let coarse: String?
    }

    /// FR-5.14's whole offline answer (FR-9.3: no network involved at all)
    /// for a bare coordinate. Called from `LibraryScanner` when a photo's
    /// location is first seen or changes, and cached on `PhotoRecord`
    /// (`gazetteerTown`/`gazetteerLandscape`/`gazetteerRegion`/
    /// `gazetteerCountry`) — never recomputed on every ranker reload, which
    /// would otherwise repeat several point-in-polygon/nearest-point
    /// searches over the whole gazetteer for every candidate on every duel
    /// (FR-8.2).
    static func offlineKeys(latitude: Double, longitude: Double) -> ScaleKeys {
        ScaleKeys(
            fine: PlaceGazetteer.town(latitude: latitude, longitude: longitude),
            landscape: PlaceGazetteer.landscape(latitude: latitude, longitude: longitude),
            region: PlaceGazetteer.region(latitude: latitude, longitude: longitude),
            coarse: PlaceGazetteer.country(latitude: latitude, longitude: longitude)
        )
    }

    /// The keys `PreferenceRanker` and `FeatureStore` actually rank and mix
    /// by, for one record — simply its cached offline answer. A thin,
    /// explicitly-named wrapper rather than reading the four `PhotoRecord`
    /// fields inline at each call site, so both files keep going through
    /// one function and can't drift apart the way they once did.
    static func resolvedNames(for record: PhotoRecord) -> ScaleKeys {
        ScaleKeys(
            fine: record.gazetteerTown,
            landscape: record.gazetteerLandscape,
            region: record.gazetteerRegion,
            coarse: record.gazetteerCountry
        )
    }

    /// The grid `PlaceNameLookup` rounds a coordinate to when deciding
    /// whether it has already asked Apple's maps service about "this spot",
    /// and what `PlaceNameRecord.cacheKey` is keyed by. Purely a
    /// cache-deduplication granularity (`Thresholds.placeNameLookupCacheGridDegrees`)
    /// — never a place identity in its own right; see this type's own doc
    /// comment for why the resolved name it caches never becomes a ranking
    /// key.
    static func networkCacheKey(latitude: Double, longitude: Double) -> String {
        let grid = Thresholds.placeNameLookupCacheGridDegrees
        let latCell = (latitude / grid).rounded()
        let lonCell = (longitude / grid).rounded()
        return "\(latCell):\(lonCell)"
    }
}
