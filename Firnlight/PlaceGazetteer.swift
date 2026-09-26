import Foundation

/// What `PlaceGazetteer.nearest` needs from a table row — implemented
/// directly by `PlaceGazetteer.NamedPointJSON` at its declaration (rather
/// than via a later extension elsewhere in this file) because it's
/// `private` to `PlaceGazetteer`: a same-file extension of a *nested*
/// private type, written outside the enclosing type's own braces, is not in
/// that type's private scope.
private nonisolated protocol PlaceCoordinate {
    var lat: Double { get }
    var lon: Double { get }
}

/// Loads and queries the offline place gazetteer FR-5.14 needs — real,
/// published place names and boundaries, bundled as app resources rather
/// than fetched over a network (FR-9.3), under the exception FR-10.5 makes
/// for "reference data about the world."
///
/// `Firnlight/PlaceData/{countries,natural,regions,places,landscapes,parks}.json`
/// is gitignored and never committed — FR-10.5's "the repository still only
/// carries the means to obtain it" — built by `scripts/fetch-place-data.sh`
/// (which a fresh clone runs once; see CLAUDE.md's Build & run) from two
/// public sources: Natural Earth (countries, world-significant landscapes,
/// admin-1 regions) and GeoNames (local-granularity landscapes and parks —
/// see `landscape`/`town`'s doc comments for why two sources). Missing data
/// degrades every query below to "no gazetteer answer at any scale" (an
/// empty table, not a crash — see `load`) rather than failing the build or
/// the app.
///
/// **Every returned name embeds the source dataset's own stable id**
/// (`"<name> (#<id>)"`, or `"<name>, <country> (#<id>)"` where a country
/// reads naturally) rather than relying on the name — or name plus country —
/// being unique on its own. An earlier revision qualified by country alone
/// and still collided for real: 63 town keys and 27 region keys in the
/// bundled data each name more than one distinct place even *within* the
/// same country (e.g. "Springfield, United States of America" is five
/// different towns; "Las Vegas, United States of America" is two, in Nevada
/// and New Mexico) — exactly the leak FR-5.14 forbids ("What the user's
/// choices reveal about one place never reaches another except through the
/// larger places both belong to" says *never*, not *rarely*). A dataset's
/// own id is different in kind: it is that dataset's actual primary key, so
/// two different features cannot share one short of a data error, and
/// `scripts/trim-place-data.py`'s `dedupe_ids` closes even that (six
/// `natural.json` features share a Natural Earth id with an unrelated
/// feature; every other table's id was already unique on its own,
/// verified). Country, where kept, is purely a courtesy for a reader of a
/// log line — the id is what actually guarantees uniqueness.
///
/// Four different lookup strategies over four scales — fine, landscape,
/// region, coarse — because the source data itself only supports different
/// things at each, and FR-5.14 wants "the natural and the political alike"
/// *both* always known, never one standing in for the other when both have
/// an answer (see `landscape` and `region`'s own doc comments — an earlier
/// revision let a landscape match suppress the region a coordinate is also
/// in, which is exactly the "alike" FR-5.14 asks for, not "whichever one
/// wins"):
///
/// - **Country** (coarse): real Natural Earth polygon boundaries,
///   point-in-polygon tested. Countries vary too much in size and shape for
///   a nearest-point approximation to reliably separate neighbours the way
///   FR-5.14's own example demands ("France, not the USA").
/// - **Landscape** (natural — a range of hills, a mountain range, a forest,
///   a valley): `naturalRegion` (Natural Earth's ~600 world-significant
///   physical features, point-in-polygon tested) tried first, then
///   `nearestLandscapePoint` (GeoNames' local-granularity hills, ranges,
///   forests, valleys — hundreds of thousands of them, nearest-point
///   matched) — see `landscape`.
/// - **Region** (political): each admin-1 region's own label point (Natural
///   Earth's own representative point for map text), matched by nearest
///   neighbour — effectively a Voronoi approximation of the true
///   administrative boundary. Good enough for "which broad area is this
///   in", which is what ranking generalization needs, without carrying that
///   dataset's full polygon geometry (tens of megabytes at a resolution
///   fine enough to cover every country). Always computed, independent of
///   whether `landscape` also found an answer.
/// - **Town/park** (fine): populated places and parks/reserves (GeoNames),
///   matched by nearest neighbour together — there is no published
///   boundary for either to test containment against in the first place,
///   and FR-5.14 treats "a town or park" as one scale, not two.
///
/// A coordinate too far from anything in a nearest-point table (open ocean,
/// polar and other unpopulated regions) returns nil at that scale — FR-3.8's
/// gap, not a penalty, same as a photo with no location at all. Country and
/// natural-landscape-polygon lookups have no such cutoff: every point on
/// land is inside some country's polygon, or isn't on land, in which case
/// nil is the honest answer anyway.
///
/// `nonisolated`: the loaded tables are immutable once read, and lookups are
/// pure functions of a coordinate — called from whichever actor is building
/// trait or diversity vectors (`PreferenceRanker`, `FeatureStore`), and once
/// from `LibraryScanner` on the main actor when a photo's location changes
/// (after `preload()` has warmed the tables off it — see that function).
nonisolated enum PlaceGazetteer {
    // MARK: Bundled data shapes

    // `nonisolated` on every nested type explicitly: the project's default
    // actor isolation is `MainActor` (see the target's
    // `SWIFT_DEFAULT_ACTOR_ISOLATION` build setting), which does not cascade
    // from an outer `nonisolated enum` down into types nested inside it —
    // each nested declaration gets its own default isolation unless told
    // otherwise, and these are plain data loaded and queried off the main
    // actor (`PreferenceRanker`, `FeatureStore`) as well as on it
    // (`LibraryScanner`).

    /// One JSON array element per polygon file — see
    /// `scripts/trim-place-data.py` for exactly how these are produced.
    /// Short keys because this is generated, never hand-written.
    private nonisolated struct PolygonJSON: Codable {
        let n: String
        /// Present only in `natural.json` — `countries.json`'s names are
        /// already unique on their own (verified), so it has nothing to
        /// disambiguate and the trim script never writes this key there.
        let id: String?
        /// Normalized to MultiPolygon shape by the trim script regardless of
        /// the source's Polygon/MultiPolygon distinction: polygons →
        /// rings → points ([lon, lat]). Any individual polygon that crosses
        /// the ±180° antimeridian is also pre-unwrapped there (see
        /// `PolygonPiece`'s doc comment) — this file never has to know
        /// which ones were, if any: in the bundled data only Antarctica's
        /// one polygon actually does, since Natural Earth otherwise splits
        /// a dateline-crossing country into separate polygons per side
        /// rather than one ring that jumps.
        let g: [[[[Double]]]]
    }

    /// One JSON array element per nearest-point file (`regions.json`,
    /// `places.json`, `landscapes.json`, `parks.json`) — all four share this
    /// exact shape.
    private nonisolated struct NamedPointJSON: Codable, PlaceCoordinate {
        let n: String
        let c: String?
        let id: String
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
        /// `"<name> (#<id>)"` where an id exists (natural.json), else just
        /// the name (countries.json, already unique on its own).
        let key: String
        let pieces: [PolygonPiece]
    }

    // MARK: Loaded tables (lazy, process-lifetime — the data never changes
    // once the app is built, so there is nothing to invalidate)

    private static let countries: [PolygonFeature] = loadPolygonFeatures("countries")
    private static let naturalRegions: [PolygonFeature] = loadPolygonFeatures("natural")
    private static let regions: [NamedPointJSON] = load("regions")
    private static let places: [NamedPointJSON] = load("places")
    private static let landscapePoints: [NamedPointJSON] = load("landscapes")
    private static let parks: [NamedPointJSON] = load("parks")
    /// `places` and `parks` searched together — FR-5.14 treats "a town or
    /// park" as one scale, not two (see `town`).
    private static let townsAndParks: [NamedPointJSON] = places + parks

    /// A fingerprint of the raw bytes of every bundled file, computed once
    /// at first access (same lazy-`static-let` machinery as the tables
    /// themselves). `PreferenceRanker` and `LibraryScanner` both compare
    /// this against a stored value to notice when the gazetteer data itself
    /// changed underneath already-cached results — a re-run of
    /// `scripts/fetch-place-data.sh`, or an app update that ships different
    /// `PlaceData` — the same "app's understanding changed, re-examine
    /// without costing the user a judgment" pattern FR-5.2 already asks for
    /// when Vision's own models drift (see `VisionRevisionFingerprint`),
    /// applied here to the gazetteer instead. Fixed FNV-1a over the raw
    /// file contents, not `Hasher`, for the same determinism reason
    /// `PreferenceRanker.favoriteFingerprint` documents: every device must
    /// agree on whether the data changed.
    static let dataFingerprint: String = {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a 64-bit offset basis
        for name in ["countries", "natural", "regions", "places", "landscapes", "parks"] {
            guard let url = resourceURL(name), let data = try? Data(contentsOf: url) else { continue }
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3 // FNV prime
            }
        }
        return String(hash, radix: 16)
    }()

    /// Forces every table above (and `dataFingerprint`) to load off the main
    /// actor. Without this, the first real query is `LibraryScanner
    /// .updateGazetteer`'s, on the main actor — decoding and bbox-building
    /// six JSON files (tens of megabytes once GeoNames' local-landscape and
    /// park tables are included) synchronously there would be exactly the
    /// frozen-interface moment FR-8.2 forbids. `Task.detached` genuinely
    /// breaks isolation from whatever actor calls this (never assume the
    /// caller already runs in the background); `await`ing its `.value` from
    /// the main actor suspends without blocking it, which is what makes this
    /// safe to call from `LibraryCatchUp.begin()`. Idempotent and cheap on
    /// every call after the first — the tables are `static let`, so a
    /// second `preload()` just re-reads already-resolved values.
    static func preload() async {
        await Task.detached {
            _ = countries.count
            _ = naturalRegions.count
            _ = regions.count
            _ = townsAndParks.count
            _ = landscapePoints.count
            _ = dataFingerprint
        }.value
    }

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
            let key = entry.id.map { "\(entry.n) (#\($0))" } ?? entry.n
            return PolygonFeature(name: entry.n, key: key, pieces: pieces)
        }
    }

    private static func key(for entry: NamedPointJSON) -> String {
        if let country = entry.c {
            "\(entry.n), \(country) (#\(entry.id))"
        } else {
            "\(entry.n) (#\(entry.id))"
        }
    }

    // MARK: Queries

    /// FR-5.14's coarse scale. Point-in-polygon, bbox-prefiltered.
    static func country(latitude: Double, longitude: Double) -> String? {
        pointInFeatures(countries, latitude: latitude, longitude: longitude)
    }

    /// FR-5.14's landscape scale — "a landscape or mountain range", tried at
    /// two grains before giving up: `naturalRegion` (Natural Earth's
    /// world-significant physical features, a real published boundary) and,
    /// failing that, `nearestLandscapePoint` (GeoNames' local-granularity
    /// hills, ranges, forests and valleys — the tier the brief specifically
    /// asks for: "known down to the landscapes people name locally... not
    /// only those a world map names"). Independent of `region` — a
    /// coordinate inside a landscape is *also* always in some political
    /// region, and `region` answers that on its own, never suppressed by
    /// this one having an answer (FR-5.14's "the natural and the political
    /// alike", both, not either/or).
    static func landscape(latitude: Double, longitude: Double) -> String? {
        pointInFeatures(naturalRegions, latitude: latitude, longitude: longitude)
            ?? nearest(latitude: latitude, longitude: longitude, in: landscapePoints, maxDistanceDegrees: Thresholds.landscapeGazetteerMaxDistanceDegrees).map(key(for:))
    }

    /// FR-5.14's region scale — the political counterpart `landscape` never
    /// stands in for, and vice versa. Nearest admin-1 label point within
    /// `Thresholds.regionGazetteerMaxDistanceDegrees`.
    static func region(latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude, in: regions, maxDistanceDegrees: Thresholds.regionGazetteerMaxDistanceDegrees).map(key(for:))
    }

    /// FR-5.14's fine scale — "a town or park", searched together as one
    /// scale within `Thresholds.placeGazetteerMaxDistanceDegrees`.
    static func town(latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude, in: townsAndParks, maxDistanceDegrees: Thresholds.placeGazetteerMaxDistanceDegrees).map(key(for:))
    }

    // MARK: Geometry

    /// Squared equirectangular distance, longitude scaled by cos(latitude)
    /// so a degree of longitude at high latitude isn't overweighted against
    /// one nearer the equator, and the longitude delta itself wrapped to
    /// ±180° first — otherwise two points a fraction of a degree apart on
    /// opposite sides of the antimeridian (179.9°, −179.9°) would compute as
    /// nearly the whole width of the globe apart instead of the few
    /// kilometres they actually are. Not geodesically exact — unnecessary
    /// for "which of a few hundred thousand points is nearest", which
    /// tolerates far more error than either approximation introduces.
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
    /// shared by `country` and `landscape`'s Natural Earth tier.
    ///
    /// Tries the query longitude both as given and shifted by ±360° against
    /// each piece's own box. Every piece in the bundled data already sits
    /// on one side or the other of the ±180° antimeridian (Natural Earth
    /// splits a country into a separate piece per side rather than
    /// crossing it within one ring — verified against the bundled data),
    /// so in practice this mainly guards against a future data update
    /// representing a crossing differently, and against Antarctica's one
    /// piece, which genuinely spans every longitude and matches at any
    /// shift's box regardless (correctly — it really is there).
    private static func pointInFeatures(_ features: [PolygonFeature], latitude: Double, longitude: Double) -> String? {
        let candidates = [longitude, longitude + 360, longitude - 360]
        for entry in features {
            for piece in entry.pieces {
                for lon in candidates {
                    guard lon >= piece.minLon, lon <= piece.maxLon,
                          latitude >= piece.minLat, latitude <= piece.maxLat else { continue }
                    if pointInPiece(longitude: lon, latitude: latitude, piece: piece) {
                        return entry.key
                    }
                }
            }
        }
        return nil
    }
}
