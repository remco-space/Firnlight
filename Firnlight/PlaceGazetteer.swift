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
/// `Firnlight/PlaceData/{countries,regions,places}.json` is committed to the
/// repository (not fetched at build time — see `scripts/fetch-place-data.sh`
/// for how to regenerate it, the same relationship
/// `scripts/capture-store-screenshots.sh` has to `docs/store/*.png`), trimmed
/// and simplified from Natural Earth's public-domain map data. Three
/// different lookup strategies, one per scale, because the source data
/// itself only supports different things at each:
///
/// - **Country** (coarse): real polygon boundaries, point-in-polygon tested.
///   Countries vary too much in size and shape for a nearest-point
///   approximation to reliably separate neighbours the way FR-5.14's own
///   example demands ("France, not the USA").
/// - **Region** (medium): each region's own label point (Natural Earth's own
///   representative point for map text), matched by nearest neighbour —
///   effectively a Voronoi approximation of the true administrative
///   boundary. Good enough for "which broad area is this in", which is what
///   ranking generalization needs, without carrying that dataset's full
///   polygon geometry (tens of megabytes at a resolution fine enough to
///   cover every country).
/// - **Town/park** (fine): populated places, matched by nearest neighbour —
///   there is no published boundary for "a town or park" to test
///   containment against in the first place, so nearest-point is the only
///   strategy that was ever on the table here.
///
/// A coordinate too far from anything in the region/place lists (open ocean,
/// polar and other unpopulated regions) returns nil at that scale — FR-3.8's
/// gap, not a penalty, same as a photo with no location at all. Country
/// lookup has no such cutoff: every point on land is inside some country's
/// polygon, or isn't on land, in which case nil is the honest answer anyway.
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
    // `nonisolated` on every nested type explicitly: the project's default
    // actor isolation is `MainActor` (see the target's
    // `SWIFT_DEFAULT_ACTOR_ISOLATION` build setting), which does not cascade
    // from an outer `nonisolated enum` down into types nested inside it —
    // each nested declaration gets its own default isolation unless told
    // otherwise, and these are plain data loaded and queried off the main
    // actor (`PreferenceRanker`, `FeatureStore`) as well as on it
    // (`LibraryScanner`).
    private nonisolated struct CountryJSON: Codable {
        let n: String
        /// Normalized to MultiPolygon shape by the trim script regardless of
        /// the source's Polygon/MultiPolygon distinction: polygons →
        /// rings → points ([lon, lat]).
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
        let lat: Double
        let lon: Double
    }

    private nonisolated struct Country {
        let name: String
        let polygons: [[[[Double]]]]
        // Precomputed once at load, not per query: most countries are
        // rejected by this alone before a single ring is ever walked.
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
    }

    // MARK: Loaded tables (lazy, process-lifetime — the data never changes
    // once the app is built, so there is nothing to invalidate)

    private static let countries: [Country] = loadCountries()
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
            // hasn't run `scripts/fetch-place-data.sh` yet, or one that
            // deliberately strips it — not a crash: every lookup below
            // degrades to "no gazetteer answer", the same FR-3.8 gap a
            // photo with no location already produces. Logged once, not
            // per query, via the guard in `country`/`nearestRegion`/
            // `nearestPlace` below never firing more than the first time
            // for an empty table.
            return []
        }
        return decoded
    }

    private static func loadCountries() -> [Country] {
        let raw: [CountryJSON] = load("countries")
        return raw.map { entry in
            var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
            var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
            for polygon in entry.g {
                for ring in polygon {
                    for point in ring {
                        minLon = min(minLon, point[0]); maxLon = max(maxLon, point[0])
                        minLat = min(minLat, point[1]); maxLat = max(maxLat, point[1])
                    }
                }
            }
            return Country(name: entry.n, polygons: entry.g, minLon: minLon, maxLon: maxLon, minLat: minLat, maxLat: maxLat)
        }
    }

    // MARK: Queries

    /// FR-5.14's coarse scale. Point-in-polygon, bbox-prefiltered.
    static func country(latitude: Double, longitude: Double) -> String? {
        for entry in countries {
            guard longitude >= entry.minLon, longitude <= entry.maxLon,
                  latitude >= entry.minLat, latitude <= entry.maxLat else { continue }
            if pointInMultiPolygon(longitude: longitude, latitude: latitude, polygons: entry.polygons) {
                return entry.name
            }
        }
        return nil
    }

    /// FR-5.14's medium scale. Nearest label point within
    /// `Thresholds.regionGazetteerMaxDistanceDegrees`.
    static func nearestRegion(latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude, in: regions, maxDistanceDegrees: Thresholds.regionGazetteerMaxDistanceDegrees)?.n
    }

    /// FR-5.14's fine scale. Nearest populated place within
    /// `Thresholds.placeGazetteerMaxDistanceDegrees`.
    static func nearestPlace(latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude, in: places, maxDistanceDegrees: Thresholds.placeGazetteerMaxDistanceDegrees)?.n
    }

    // MARK: Geometry

    /// Squared equirectangular distance, longitude scaled by cos(latitude)
    /// so a degree of longitude at high latitude isn't overweighted against
    /// one nearer the equator. Not geodesically exact — unnecessary for
    /// "which of a few thousand points is nearest", which tolerates far
    /// more error than this introduces.
    private static func squaredDistance(latA: Double, lonA: Double, latB: Double, lonB: Double) -> Double {
        let dLat = latA - latB
        let dLon = (lonA - lonB) * cos((latA + latB) / 2 * .pi / 180)
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

    /// A polygon's rings are XORed — exterior ring true, then each hole ring
    /// flips it back — which is equivalent to "inside the exterior and not
    /// inside any hole" whenever hole rings are properly nested inside their
    /// exterior (always true for valid GeoJSON), without needing to know
    /// which ring is which. A MultiPolygon is true if any of its (disjoint)
    /// polygons is.
    private static func pointInMultiPolygon(longitude: Double, latitude: Double, polygons: [[[[Double]]]]) -> Bool {
        for polygon in polygons {
            var inside = false
            for ring in polygon {
                if pointInRing(longitude: longitude, latitude: latitude, ring: ring) {
                    inside.toggle()
                }
            }
            if inside { return true }
        }
        return false
    }
}
