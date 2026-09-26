import Foundation

/// Where a photo was taken, as a nested "place" rather than a bare
/// coordinate — FR-5.14's four offline scales (at least three — fine,
/// landscape, region, coarse — with the last two both political and
/// natural always independently known), always available with **no
/// network** (FR-9.3), plus a fifth, genuinely separate scale learned
/// through Apple's maps service where the network allows.
///
/// The actual gazetteer — the bundled place names and boundaries, and the
/// point-in-polygon/nearest-point lookups over them — lives in
/// `PlaceGazetteer`; this type is the one place both `PreferenceRanker` and
/// `FeatureStore` go to read a record's scale names, so the two can never
/// disagree about what a photo's place is.
///
/// **The network scale never replaces or qualifies any offline one.**
/// FR-5.14 asks for both: the four offline scales, "with no network", and,
/// "where the network allows", Apple's own answer as "one more of the
/// places the photo is known by" — additive, not a refinement of an
/// existing scale. That distinction is load-bearing, not stylistic: an
/// earlier revision tried using the network answer to *qualify* the
/// offline fine/coarse keys (e.g. appending Apple's country string to a
/// resolved city), and that broke the moment a real coordinate's answer was
/// compared — Apple's own country vocabulary differs from Natural Earth's
/// ("United States" vs. "United States of America", and likewise Russia,
/// Czechia, Korea, Côte d'Ivoire), so the *same* offline key would change
/// the instant its network lookup resolved, splitting one real place's
/// learned weight across two keys — exactly the leak "never reaches
/// another except through the larger places both belong to" forbids. Kept
/// as `network` below, in its own weight-key namespace
/// (`PreferenceRanker.placeWeightKey(scale: "network", ...)`), that risk
/// doesn't arise: the offline scales never read it, and it never reads
/// them.
///
/// `nonisolated`: pure functions of a coordinate or a record, called from
/// whichever actor is building trait or diversity vectors.
nonisolated enum PlaceHierarchy {
    /// A photo's name at each of FR-5.14's scales — independently nil
    /// where there's no answer for it (no location at all, one too far from
    /// anything `PlaceGazetteer` knows: FR-3.8's gap, not a penalty; or, for
    /// `network`, not yet resolved, no network allowed, or Apple genuinely
    /// had no name for the spot).
    struct ScaleKeys: Sendable, Equatable {
        let fine: String?
        let landscape: String?
        let region: String?
        let coarse: String?
        /// FR-5.14's fifth scale — "where the network allows, the app also
        /// learns what Apple's maps call the place... and that name counts
        /// as one more of the places the photo is known by." Composed by
        /// `networkPlaceKey` from `PlaceNameLookup`'s cached answer; see
        /// this type's own doc comment for why it is never folded into the
        /// four scales above.
        let network: String?
    }

    /// FR-5.14's offline answer (FR-9.3: no network involved at all) for a
    /// bare coordinate — `network` is always nil here, since this function
    /// knows nothing about any network resolution; that field is filled in
    /// separately, from `PhotoRecord.networkPlaceName`, by `resolvedNames`.
    /// Called from `LibraryScanner` when a photo's location is first seen
    /// or changes, and cached on `PhotoRecord` (`gazetteerTown`/
    /// `gazetteerLandscape`/`gazetteerRegion`/`gazetteerCountry`) — never
    /// recomputed on every ranker reload, which would otherwise repeat
    /// several point-in-polygon/nearest-point searches over the whole
    /// gazetteer for every candidate on every duel (FR-8.2).
    static func offlineKeys(latitude: Double, longitude: Double) -> ScaleKeys {
        ScaleKeys(
            fine: PlaceGazetteer.town(latitude: latitude, longitude: longitude),
            landscape: PlaceGazetteer.landscape(latitude: latitude, longitude: longitude),
            region: PlaceGazetteer.region(latitude: latitude, longitude: longitude),
            coarse: PlaceGazetteer.country(latitude: latitude, longitude: longitude),
            network: nil
        )
    }

    /// The keys `PreferenceRanker` and `FeatureStore` actually rank and mix
    /// by, for one record — its cached offline answer, plus its cached
    /// network answer if one has been resolved. A thin, explicitly-named
    /// wrapper rather than reading the five `PhotoRecord` fields inline at
    /// each call site, so both files keep going through one function and
    /// can't drift apart the way they once did.
    static func resolvedNames(for record: PhotoRecord) -> ScaleKeys {
        ScaleKeys(
            fine: record.gazetteerTown,
            landscape: record.gazetteerLandscape,
            region: record.gazetteerRegion,
            coarse: record.gazetteerCountry,
            network: record.networkPlaceName
        )
    }

    /// FR-5.14's fifth scale, named — combines `MKAddressRepresentations
    /// .cityName`/`.regionName` (see `PlaceNameLookup`) into the one place
    /// name FR-5.14 speaks of ("the place", singular), since Apple's
    /// address representation has no single field for it. Either component
    /// may be nil (open water, a wilderness with no indexed settlement or
    /// country nearby, or one present without the other); both nil means no
    /// name at all. No dataset id anchors this the way every offline
    /// table's key does — Apple's reverse-geocoding API returns none — so
    /// two distinct real places that happen to share Apple's own city and
    /// region strings would collide into one key here; a residual,
    /// disclosed limitation of a single, id-less network source, not a bug
    /// in this composition.
    static func networkPlaceKey(cityName: String?, regionName: String?) -> String? {
        switch (cityName, regionName) {
        case (let city?, let region?): "\(city), \(region)"
        case (let city?, nil): city
        case (nil, let region?): region
        case (nil, nil): nil
        }
    }

    /// The grid `PlaceNameLookup` rounds a coordinate to when deciding
    /// whether it has already asked Apple's maps service about "this spot",
    /// and what `PlaceNameRecord.cacheKey` is keyed by. Purely a
    /// cache-deduplication granularity (`Thresholds.placeNameLookupCacheGridDegrees`)
    /// — distinct from `networkPlaceKey`, which is the actual place
    /// *identity* trained and mixed by.
    static func networkCacheKey(latitude: Double, longitude: Double) -> String {
        let grid = Thresholds.placeNameLookupCacheGridDegrees
        let latCell = (latitude / grid).rounded()
        let lonCell = (longitude / grid).rounded()
        return "\(latCell):\(lonCell)"
    }
}
