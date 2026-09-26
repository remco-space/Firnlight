import Foundation

/// What `PlaceGazetteer.nearest` needs from a table row — implemented
/// directly by `PlaceGazetteer.RegionJSON` and `PlaceGazetteer.PlaceJSON` at
/// their declarations (rather than via a later extension elsewhere in this
/// file) because both are `private` to `PlaceGazetteer`: a same-file
/// extension of a *nested* private type, written outside the enclosing
/// type's own braces, is not in that type's private scope.
private nonisolated protocol PlaceCoordinate {
    var lat: Double { get }
    var lon: Double { get }
}

/// Loads and queries the offline place gazetteer FR-5.14 needs — real,
/// published place names and boundaries, bundled as app resources rather
/// than fetched over a network (FR-9.3), under the exception FR-10.5 makes
/// for "reference data about the world."
///
/// `Firnlight/PlaceData/{countries,natural,regions,places}.json` is
/// gitignored and never committed — FR-10.5's "the repository still only
/// carries the means to obtain it" — built by `scripts/fetch-place-data.sh`
/// (which a fresh clone runs once; see CLAUDE.md's Build & run) from Natural
/// Earth's public-domain map data. Missing data degrades every query below
/// to "no gazetteer answer at any scale" (an empty table, not a crash — see
/// `load`) rather than failing the build or the app.
///
/// Four different lookup strategies over three scales, because the source
/// data itself only supports different things at each, and FR-5.14 wants
/// "the natural and the political alike" at the medium scale specifically:
///
/// - **Country** (coarse): real polygon boundaries, point-in-polygon tested.
///   Countries vary too much in size and shape for a nearest-point
///   approximation to reliably separate neighbours the way FR-5.14's own
///   example demands ("France, not the USA"). Names are unique within this
///   dataset, so no further disambiguation is needed.
/// - **Landscape** (medium, natural): named physical features — mountain
///   ranges, plateaus, deserts and the like — also point-in-polygon tested,
///   and tried *before* the political fallback below. Covers only the ~600
///   world-significant landforms Natural Earth publishes at any scale
///   (nothing at the resolution of, say, Germany's Odenwald), and a
///   five-name handful of those genuinely repeat across unrelated places
///   with no field in the source data to tell them apart by (e.g. two
///   different, unrelated mountain ranges are both named "Cordillera
///   Oriental") — a small, disclosed residual of exactly the kind of
///   collision FR-5.14's leakage clause is otherwise built to avoid, kept
///   because there's nothing in the published data to key it apart by.
/// - **Region** (medium, political): each region's own label point (Natural
///   Earth's own representative point for map text), matched by nearest
///   neighbour and qualified by its own country — effectively a Voronoi
///   approximation of the true administrative boundary. Good enough for
///   "which broad area is this in", which is what ranking generalization
///   needs, without carrying that dataset's full polygon geometry (tens of
///   megabytes at a resolution fine enough to cover every country).
/// - **Town/park** (fine): populated places, matched by nearest neighbour
///   and qualified by its own country — there is no published boundary for
///   "a town or park" to test containment against in the first place, so
///   nearest-point is the only strategy that was ever on the table here.
///
/// Region and town names are qualified by their own country
/// (`"<name>, <country>"`) because plenty of real, unrelated places share a
/// name: 188 town names and 95 region names in the bundled data each belong
/// to more than one distinct place (e.g. "La Paz" is four towns in four
/// different countries; "Alexandria" is four, two of them in the same
/// country). Without the qualifier, two unrelated places would collide into
/// one learned weight in `PreferenceRanker` — exactly what FR-5.14's "never
/// reaches another except through the larger places both belong to" rules
/// out. The qualifying country comes from each place's own record in the
/// source data (`ADM0NAME` for towns, `admin` for regions), not from a
/// separate lookup of the query coordinate's own country: the two can
/// legitimately disagree right at a border, and a place's own recorded
/// country is the more correct identity for *that place*, independent of
/// which specific photo is asking about it.
///
/// A coordinate too far from anything in the region/place lists (open
/// ocean, polar and other unpopulated regions) returns nil at that scale —
/// FR-3.8's gap, not a penalty, same as a photo with no location at all.
/// Country and landscape lookups have no such cutoff: every point on land
/// is inside some country's polygon, or isn't on land, in which case nil is
/// the honest answer anyway.
///
/// `nonisolated`: the loaded tables are immutable once read, and lookups are
/// pure functions of a coordinate — called from whichever actor is building
/// trait or diversity vectors (`PreferenceRanker`, `FeatureStore`), and once
/// from `LibraryScanner` on the main actor when a photo's location changes.
nonisolated enum PlaceGazetteer {
    // MARK: Bundled data shapes

    /// One JSON array element per file — see `scripts/trim-place-data.py`
    /// for exactly how these are produced from the raw Natural Earth
    /// GeoJSON. Short keys because this is generated, never hand-written.
    private nonisolated struct PolygonJSON: Codable {
        let n: String
        /// Normalized to MultiPolygon shape by the trim script regardless of
        /// the source's Polygon/MultiPolygon distinction: polygons →
        /// rings → points ([lon, lat]). Any individual ring that crosses the
        /// ±180° antimeridian is also pre-unwrapped there (see
        /// `PolygonPiece`'s doc comment) — this file never has to know which
        /// ones were, if any: in the bundled data only Antarctica's one ring
        /// actually does, since Natural Earth otherwise splits a
        /// dateline-crossing country into separate polygons per side rather
        /// than one ring that jumps.
        let g: [[[[Double]]]]
    }
    private nonisolated struct RegionJSON: Codable, PlaceCoordinate {
        let n: String
        let c: String
        let lat: Double
        let lon: Double
    }
    private nonisolated struct PlaceJSON: Codable, PlaceCoordinate {
        let n: String
        let c: String?
        let lat: Double
        let lon: Double
    }

    /// One top-level polygon of a feature's `MultiPolygon` (a country or
    /// natural region can be many disjoint pieces — a mainland plus islands,
    /// or, at the antimeridian, a piece on each side of the seam), with its
    /// *own* bounding box precomputed once at load, not per query.
    ///
    /// Per-piece, not one box for the whole feature: Natural Earth already
    /// splits an antimeridian-crossing country into separate pieces rather
    /// than one ring that jumps (verified against the bundled data — no
    /// single ring anywhere crosses the seam except Antarctica, which
    /// genuinely does span every longitude), but a *feature-wide* box built
    /// by unioning every piece's extent would still span the whole globe for
    /// Russia, the USA, Fiji, New Zealand, Kiribati and the U.S. Minor
    /// Outlying Islands — exactly reproducing "the bbox prefilter never
    /// rejects them" with the pieces merged back together. Boxing each piece
    /// on its own keeps every one of them tight.
    private nonisolated struct PolygonPiece {
        let rings: [[[Double]]]
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
    }

    private nonisolated struct PolygonFeature {
        let name: String
        let pieces: [PolygonPiece]
    }

    // MARK: Loaded tables (lazy, process-lifetime — the data never changes
    // once the app is built, so there is nothing to invalidate)

    private static let countries: [PolygonFeature] = loadPolygonFeatures("countries")
    private static let naturalRegions: [PolygonFeature] = loadPolygonFeatures("natural")
    private static let regions: [RegionJSON] = load("regions")
    private static let places: [PlaceJSON] = load("places")

    private static func resourceURL(_ name: String) -> URL? {
        // Tried both ways because a `PBXFileSystemSynchronizedRootGroup`
        // (what `Firnlight/` is — see CLAUDE.md's app-icon note for the
        // same caveat about a different resource type) has been observed
        // to sometimes flatten a subfolder's files into the bundle's
        // top-level Resources rather than preserving `PlaceData/` as a
        // subdirectory; this works either way rather than guessing once.
        Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "PlaceData")
            ?? Bundle.main.url(forResource: name, withExtension: "json")
    }

    private static func load<T: Decodable>(_ name: String) -> [T] {
        guard let url = resourceURL(name),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else {
            // Missing bundled data is a real, honest state — a build that
            // hasn't run `scripts/fetch-place-data.sh` yet — not a crash:
            // every lookup below degrades to "no gazetteer answer", the
            // same FR-3.8 gap a photo with no location already produces.
            return []
        }
        return decoded
    }

    private static func loadPolygonFeatures(_ name: String) -> [PolygonFeature] {
        let raw: [PolygonJSON] = load(name)
        return raw.map { entry in
            let pieces = entry.g.map { polygon -> PolygonPiece in
                var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
                var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
                for ring in polygon {
                    for point in ring {
                        minLon = min(minLon, point[0]); maxLon = max(maxLon, point[0])
                        minLat = min(minLat, point[1]); maxLat = max(maxLat, point[1])
                    }
                }
                return PolygonPiece(rings: polygon, minLon: minLon, maxLon: maxLon, minLat: minLat, maxLat: maxLat)
            }
            return PolygonFeature(name: entry.n, pieces: pieces)
        }
    }

    // MARK: Queries

    /// FR-5.14's coarse scale. Point-in-polygon, bbox-prefiltered.
    static func country(latitude: Double, longitude: Double) -> String? {
        pointInFeatures(countries, latitude: latitude, longitude: longitude)
    }

    /// FR-5.14's medium scale: the natural landscape a coordinate falls
    /// inside, if any — tried by `resolvedRegion` before the political
    /// fallback. Point-in-polygon, bbox-prefiltered, exactly like `country`.
    static func naturalRegion(latitude: Double, longitude: Double) -> String? {
        pointInFeatures(naturalRegions, latitude: latitude, longitude: longitude)
    }

    /// FR-5.14's medium scale, resolved: `naturalRegion` if the coordinate
    /// falls inside one, else the nearest political region (qualified by
    /// its own country) within `Thresholds.regionGazetteerMaxDistanceDegrees`.
    static func resolvedRegion(latitude: Double, longitude: Double) -> String? {
        if let natural = naturalRegion(latitude: latitude, longitude: longitude) {
            return natural
        }
        guard let match = nearest(latitude: latitude, longitude: longitude, in: regions, maxDistanceDegrees: Thresholds.regionGazetteerMaxDistanceDegrees) else {
            return nil
        }
        return "\(match.n), \(match.c)"
    }

    /// FR-5.14's fine scale. Nearest populated place within
    /// `Thresholds.placeGazetteerMaxDistanceDegrees`, qualified by its own
    /// country where the source data has one.
    static func nearestPlace(latitude: Double, longitude: Double) -> String? {
        guard let match = nearest(latitude: latitude, longitude: longitude, in: places, maxDistanceDegrees: Thresholds.placeGazetteerMaxDistanceDegrees) else {
            return nil
        }
        return match.c.map { "\(match.n), \($0)" } ?? match.n
    }

    // MARK: Geometry

    /// Squared equirectangular distance, longitude scaled by cos(latitude)
    /// so a degree of longitude at high latitude isn't overweighted against
    /// one nearer the equator, and the longitude delta itself wrapped to
    /// ±180° first — otherwise two points a fraction of a degree apart on
    /// opposite sides of the antimeridian (179.9°, −179.9°) would compute as
    /// nearly the whole width of the globe apart instead of the few
    /// kilometres they actually are. Not geodesically exact — unnecessary
    /// for "which of a few thousand points is nearest", which tolerates far
    /// more error than either approximation introduces.
    private static func squaredDistance(latA: Double, lonA: Double, latB: Double, lonB: Double) -> Double {
        let dLat = latA - latB
        var dLon = lonA - lonB
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        dLon *= cos((latA + latB) / 2 * .pi / 180)
        return dLat * dLat + dLon * dLon
    }

    private static func nearest<T>(
        latitude: Double, longitude: Double, in table: [T], maxDistanceDegrees: Double
    ) -> T? where T: PlaceCoordinate {
        let maxSquared = maxDistanceDegrees * maxDistanceDegrees
        var best: T?
        var bestDistance = Double.greatestFiniteMagnitude
        for entry in table {
            let d = squaredDistance(latA: latitude, lonA: longitude, latB: entry.lat, lonB: entry.lon)
            if d < bestDistance {
                bestDistance = d
                best = entry
            }
        }
        guard bestDistance <= maxSquared else { return nil }
        return best
    }

    /// Ray-casting point-in-ring test (PNPOLY, W. R. Franklin).
    private static func pointInRing(longitude: Double, latitude: Double, ring: [[Double]]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            if (yi > latitude) != (yj > latitude),
               longitude < (xj - xi) * (latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// A polygon piece's rings are XORed — exterior ring true, then each
    /// hole ring flips it back — which is equivalent to "inside the exterior
    /// and not inside any hole" whenever hole rings are properly nested
    /// inside their exterior (always true for valid GeoJSON), without
    /// needing to know which ring is which.
    ///
    /// `longitude` here is whichever candidate `pointInFeatures` is
    /// currently trying — see that function for why more than one is tried.
    private static func pointInPiece(longitude: Double, latitude: Double, piece: PolygonPiece) -> Bool {
        var inside = false
        for ring in piece.rings {
            if pointInRing(longitude: longitude, latitude: latitude, ring: ring) {
                inside.toggle()
            }
        }
        return inside
    }

    /// Point-in-polygon over a feature list, bbox-prefiltered per disjoint
    /// piece (not per whole feature — see `PolygonPiece`'s doc comment for
    /// why that distinction matters for Russia, the USA and similar) —
    /// shared by `country` and `naturalRegion`.
    ///
    /// Tries the query longitude both as given and shifted by ±360° against
    /// each piece's own box. Every piece in the bundled data already sits
    /// on one side or the other of the ±180° antimeridian (Natural Earth
    /// splits a country into a separate piece per side rather than
    /// crossing it within one ring — verified against the bundled data),
    /// so in practice this mainly guards against a future data update
    /// representing a crossing differently, and against Antarctica's one
    /// ring, which genuinely spans every longitude and matches at any
    /// shift's box regardless (correctly — it really is there).
    private static func pointInFeatures(_ features: [PolygonFeature], latitude: Double, longitude: Double) -> String? {
        let candidates = [longitude, longitude + 360, longitude - 360]
        for entry in features {
            for piece in entry.pieces {
                for lon in candidates {
                    guard lon >= piece.minLon, lon <= piece.maxLon,
                          latitude >= piece.minLat, latitude <= piece.maxLat else { continue }
                    if pointInPiece(longitude: lon, latitude: latitude, piece: piece) {
                        return entry.name
                    }
                }
            }
        }
        return nil
    }
}
