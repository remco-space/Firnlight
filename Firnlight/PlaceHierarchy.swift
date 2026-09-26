import Foundation

/// Where a photo was taken, as a nested "place" rather than a bare
/// coordinate — FR-5.14's three scales, always available with **no
/// network** (FR-9.3).
///
/// FR-5.14 asks for the photo's location to count "not only as a position on
/// the map but as the places people name it by, at every scale they name it
/// — a town or park, a landscape or mountain range, a region, a country,"
/// and for that to hold with no network at all. There is no on-device
/// gazetteer to consult for that: `sdk-capability-scan` against CoreLocation
/// and MapKit on the macOS/iOS 27 SDKs found no offline reverse-geocoding
/// API — `MKReverseGeocodingRequest` (the non-deprecated replacement for
/// `CLGeocoder`, itself deprecated 26+) reaches Apple's maps service over the
/// network, full stop; there is no on-device fallback mode. Bundling one
/// would also cost this repository its FR-10.5 promise ("nothing authored by
/// a third party is tracked here") for a country/place-boundary dataset the
/// app did not create.
///
/// So the offline floor this type builds is the app's own: a fixed
/// three-resolution grid over the globe. A grid cell is not a real named
/// place, but it stands in for one well enough for what the three scales are
/// *for* — see `PreferenceRanker`'s use of these keys and FR-5.11's "leans on
/// the larger places around it": what matters for ranking is that photos from
/// the same real place consistently land in the same cell at each scale, not
/// that the cell has a name. `PlaceNameLookup` is the separate, network-based
/// mechanism (FR-1.5's exception, FR-5.13's mechanics) that upgrades the fine
/// and coarse scales to real place names — "a town," "a country" — once
/// Apple's maps service has answered for that cell; until then, and forever
/// where it never answers (open ocean, no signal), the grid key already
/// computed here is what the ranker uses. The medium scale ("a landscape or
/// mountain range") is never upgraded: neither the deprecated `CLPlacemark`
/// hierarchy nor its replacement, `MKAddressRepresentations`, names anything
/// at that scale — a landscape doesn't have the kind of canonical name a
/// city or a country does — so the grid is the only honest source for it,
/// lookup or no lookup.
///
/// `nonisolated`: pure arithmetic over a coordinate, called from whichever
/// actor is building trait or diversity vectors (`PreferenceRanker`,
/// `FeatureStore`).
nonisolated enum PlaceHierarchy {
    /// The three grid keys a coordinate falls into, finest first. Plain
    /// strings rather than an enum or a struct of doubles: both `PreferenceRanker`
    /// (hashed into a learned weight bucket) and `FeatureStore` (compared for
    /// exact equality when judging FR-6.1's mix) only ever need "is this the
    /// same place as that one," which a string already answers, and a string
    /// is also what a resolved place *name* naturally is — letting
    /// `PlaceNameLookup`'s result stand in for the grid key at the same type,
    /// with nothing downstream needing to know which kind of key it got.
    struct ScaleKeys: Sendable, Equatable {
        let fine: String
        let medium: String
        let coarse: String
    }

    /// Grid cell edge, in degrees of latitude and longitude, at each scale.
    /// Not measured against anything — there is no ground truth for "how big
    /// is a landscape" — but chosen to land near the human scales FR-5.14
    /// names: a degree of latitude is about 111 km everywhere, and of
    /// longitude the same at the equator, narrowing toward the poles, so
    /// these read as rough diameters rather than exact ones.
    ///
    /// - Fine, 0.1° (~11 km): a town or a park.
    /// - Medium, 1° (~111 km): a landscape, a mountain range, a small region.
    /// - Coarse, 6° (~660 km): a region or a country — deliberately coarser
    ///   than most single countries so a photographer's whole trip through a
    ///   small one still shares a cell, while a large country (the ranking
    ///   case FR-5.14's own example cares about — "France, not the USA")
    ///   still spans several, which is honest: the USA is not one place at
    ///   this scale either.
    ///
    /// Unverified against a real library's spread of locations; tune the
    /// same way every other geometric threshold in `Thresholds` is tuned, by
    /// watching what real photos land in the same cell as one another.
    static let fineCellDegrees = 0.1
    static let mediumCellDegrees = 1.0
    static let coarseCellDegrees = 6.0

    /// The three scale keys for a coordinate. Pure function of latitude and
    /// longitude — no store, no cache, no network — so it is always available
    /// the instant a photo's location is known, which is what makes FR-5.14's
    /// "no network" promise true unconditionally rather than only until a
    /// lookup completes.
    static func scaleKeys(latitude: Double, longitude: Double) -> ScaleKeys {
        ScaleKeys(
            fine: cellKey(scale: "fine", latitude: latitude, longitude: longitude, cellDegrees: fineCellDegrees),
            medium: cellKey(scale: "medium", latitude: latitude, longitude: longitude, cellDegrees: mediumCellDegrees),
            coarse: cellKey(scale: "coarse", latitude: latitude, longitude: longitude, cellDegrees: coarseCellDegrees)
        )
    }

    /// Longitude wraps at ±180° the same way it does everywhere else in this
    /// app (see `PreferenceRanker`'s doc comment on why latitude alone is its
    /// *linear* trait) — but a seam only matters to a linear scale, not a
    /// categorical bucket like this one: two cells on either side of the
    /// antimeridian are simply two different, correctly distinct keys, same
    /// as any other two neighbouring cells. There is nothing to correct for.
    ///
    /// `scale` is folded into the key so the three scales can never collide —
    /// cell (0, 0) at the fine grid and cell (0, 0) at the coarse grid name
    /// two different places, and must hash to different buckets.
    private static func cellKey(scale: String, latitude: Double, longitude: Double, cellDegrees: Double) -> String {
        let latCell = Int(floor(latitude / cellDegrees))
        let lonCell = Int(floor(longitude / cellDegrees))
        return "\(scale):\(latCell):\(lonCell)"
    }
}
