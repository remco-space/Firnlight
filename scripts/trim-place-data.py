#!/usr/bin/env python3
"""Trims and simplifies raw Natural Earth GeoJSON into the compact place
gazetteer Firnlight bundles as a resource (`Firnlight/PlaceData/*.json`).

Only ever invoked by `scripts/fetch-place-data.sh`, which downloads the raw
inputs this reads into a scratch directory and passes both directories as
arguments. Not a standalone entry point.

FR-5.14 needs real named places, offline, at three scales — "as published
geographic references name and bound them", "the natural and the political
alike" — and FR-10.5's exception for world reference data is what lets a
*fetch step* obtain this rather than redistributing it (the repository
itself never carries the raw or trimmed data — see fetch-place-data.sh's own
header). The raw Natural Earth files are public domain
(naturalearthdata.com/about/terms-of-use) and far larger than the app needs:
this keeps only each feature's name, its containing country where that
disambiguates same-named places, and (for polygon data) a simplified
boundary — dropping everything else.
"""
import json
import sys

RAW_DIR = sys.argv[1]
OUT_DIR = sys.argv[2]

# Ramer-Douglas-Peucker tolerance, in degrees, for polygon data (countries
# and natural regions alike). Not a survey-grade simplification — these
# lookups only have to be honest to within a few kilometres of any boundary
# for ranking generalization, not to the precision a legal boundary needs,
# and the raw 10m-resolution source is already a cartographic simplification
# itself.
#
# 0.03° chosen empirically, not measured: 0.05° (and the coarser 1:50m
# source this originally used for countries) put real coastal cities outside
# their own country — verified false negatives at New York and Rio de
# Janeiro, both right at a complex bay/harbour coastline the coarser
# simplification smoothed away. 0.03° against the 1:10m source fixed both
# while still cutting the raw point count by around 85%. A few other
# coastal/archipelago spots (Venice, central Miami) still come up empty even
# completely unsimplified at 1:10m — an inherent limitation of a world-scale
# published dataset, not something this simplification step introduces or
# could fix by being more conservative; FR-3.8 already treats a place a
# photo's location can't be matched to as a gap, not a penalty.
SIMPLIFY_EPSILON_DEGREES = 0.03

# Coordinate rounding for every file. ~111m at the equator per 0.001° of
# latitude — far finer than a country border needs and immaterial for the
# nearest-neighbour region/place lookups, but cheap to keep rather than
# thin further.
COORDINATE_DECIMAL_PLACES = 3

# A ring whose raw longitude span exceeds this is treated as crossing the
# ±180° antimeridian rather than genuinely spanning that much of the globe.
# Checked against every ring in the bundled countries data: only Antarctica's
# one ring actually exceeds it, and legitimately — it really does run across
# every longitude at its latitude band — so unwrapping finds nothing to do
# there either way (harmless; see `unwrap_ring`). The countries whose overall
# *shape* crosses the seam (Russia, the USA, Fiji, New Zealand, Kiribati, the
# U.S. Minor Outlying Islands) don't need this: Natural Earth already
# represents each of them as a separate polygon piece per side of the seam
# rather than one ring that jumps, which is also why PlaceGazetteer boxes
# each piece individually instead of the whole feature (see its
# `PolygonPiece` — a feature-wide box would still span the whole globe for
# these regardless of anything this script does).
ANTIMERIDIAN_SPAN_DEGREES = 180


def rdp(points, epsilon):
    """Ramer-Douglas-Peucker polyline simplification."""
    if len(points) < 3:
        return points

    def perp_dist(pt, a, b):
        (x, y), (ax, ay), (bx, by) = pt, a, b
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0:
            return ((x - ax) ** 2 + (y - ay) ** 2) ** 0.5
        t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)
        t = max(0, min(1, t))
        px, py = ax + t * dx, ay + t * dy
        return ((x - px) ** 2 + (y - py) ** 2) ** 0.5

    def simplify(pts):
        if len(pts) < 3:
            return pts
        a, b = pts[0], pts[-1]
        max_d, idx = -1, -1
        for i in range(1, len(pts) - 1):
            d = perp_dist(pts[i], a, b)
            if d > max_d:
                max_d, idx = d, i
        if max_d > epsilon:
            left = simplify(pts[: idx + 1])
            right = simplify(pts[idx:])
            return left[:-1] + right
        return [a, b]

    return simplify(points)


def unwrap_ring(ring):
    """Shifts a ring that crosses the ±180° antimeridian into a contiguous
    longitude domain, so both the simplifier's distance math and
    `PlaceGazetteer`'s ray-casting see one unbroken shape instead of a jump
    from +179.9 to −179.9 partway around. Every point with a negative
    longitude gets +360 added, moving it next to its eastern-hemisphere
    neighbours instead of wrapping back to the other side of the globe.
    A ring that doesn't actually cross the seam is returned unchanged."""
    lons = [p[0] for p in ring]
    if max(lons) - min(lons) <= ANTIMERIDIAN_SPAN_DEGREES:
        return ring
    return [[p[0] + 360 if p[0] < 0 else p[0], p[1]] for p in ring]


def normalize_to_multipolygon(geometry):
    """Every polygon geometry becomes the same shape on the way out — a list
    of polygons, each a list of rings, each a list of [lon, lat] pairs — so
    the Swift decoder never has to branch on GeoJSON's Polygon vs
    MultiPolygon distinction (see PlaceGazetteer.swift)."""
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    raise ValueError(f"Unexpected geometry type: {geometry['type']}")


def round_point(pt):
    return [round(pt[0], COORDINATE_DECIMAL_PLACES), round(pt[1], COORDINATE_DECIMAL_PLACES)]


def simplified_polygons(geometry):
    """Unwrap (if needed), simplify and round every ring of one feature's
    geometry — the shared pipeline `trim_countries` and `trim_natural` both
    run each feature through."""
    polygons = normalize_to_multipolygon(geometry)
    return [
        [[round_point(p) for p in rdp(unwrap_ring(ring), SIMPLIFY_EPSILON_DEGREES)] for ring in polygon]
        for polygon in polygons
    ]


def trim_countries():
    """FR-5.14's coarse scale: `ne_10m_admin_0_countries` polygons, simplified
    and rounded. This is one of two scales that gets real boundary geometry
    — countries vary too much in size and shape for a nearest-point
    approximation to reliably tell "France" from "the USA" the way FR-5.14's
    own example demands. Never needs disambiguating by anything else:
    country names are unique within this dataset."""
    with open(f"{RAW_DIR}/countries.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        if not name:
            continue
        out.append({"n": name, "g": simplified_polygons(feature["geometry"])})
    with open(f"{OUT_DIR}/countries.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"countries.json: {len(out)} entries")


def trim_natural():
    """FR-5.14's medium scale, the *natural* half: `ne_10m_geography_regions_polys`
    — named mountain ranges, plateaus, deserts, and similar physical
    landscape features, tested by point-in-polygon exactly like a country
    and preferred over the political `regions.json` fallback when a
    coordinate falls inside one (see PlaceGazetteer.nearestRegion). Islands
    are excluded: an island nation's own name already comes from
    `countries.json`, so keeping them here would just relabel a country as
    a landform.

    This does not cover every named landscape a person might call a place by
    — Natural Earth's most granular tier still only carries the ~600
    world-significant physical features below, not e.g. Germany's Odenwald
    — but it is what "the natural... alike" can mean from data actually
    published at this detail, and is strictly additive to the political
    fallback that covers everywhere else."""
    with open(f"{RAW_DIR}/natural.geojson") as f:
        data = json.load(f)
    excluded_classes = {"Island", "Island group", "Dragons-be-here"}
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        feature_class = feature["properties"].get("FEATURECLA")
        if not name or feature_class in excluded_classes:
            continue
        out.append({"n": name, "g": simplified_polygons(feature["geometry"])})
    with open(f"{OUT_DIR}/natural.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"natural.json: {len(out)} entries")


def trim_regions():
    """FR-5.14's medium scale, the *political* half and the fallback
    everywhere `trim_natural`'s coverage doesn't reach:
    `ne_10m_admin_1_states_provinces`, kept as each region's own label point
    (the dataset's own `latitude`/`longitude` properties — a representative
    point Natural Earth already computed for map labelling) rather than its
    polygon. `PlaceGazetteer` matches a coordinate to the *nearest* region
    point rather than testing containment — an approximation (a Voronoi
    diagram over label points is not the same as the true administrative
    boundary), chosen deliberately: it gives a real, correctly-scoped region
    name without needing this file's full polygon geometry, which at 10m
    resolution is tens of megabytes raw.

    `c` (the region's own country, already in the source as `admin`) is what
    lets `PlaceGazetteer` tell apart the 95 region names — verified in the
    bundled data — that name more than one distinct place (e.g. "Nord"),
    matching a state/province against the wrong country's region of the same
    name (FR-5.14's "never reaches another except through the larger places
    both belong to" — two *different* regions sharing a weight by name
    collision is exactly that leak)."""
    with open(f"{RAW_DIR}/regions.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        p = feature["properties"]
        name = p.get("name")
        country = p.get("admin")
        lat, lon = p.get("latitude"), p.get("longitude")
        if not name or not country or lat is None or lon is None:
            continue
        out.append({
            "n": name,
            "c": country,
            "lat": round(lat, COORDINATE_DECIMAL_PLACES),
            "lon": round(lon, COORDINATE_DECIMAL_PLACES),
        })
    with open(f"{OUT_DIR}/regions.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"regions.json: {len(out)} entries")


def trim_places():
    """FR-5.14's fine scale: `ne_10m_populated_places`, name + point (+ its
    own country, `ADM0NAME` in the source, present on every entry) —
    `PlaceGazetteer` matches a coordinate to the nearest one, the same
    nearest-point approximation `trim_regions` uses and for the same reason
    (a "town or park" has no published boundary polygon to test containment
    against in the first place).

    `c` is here for the same reason `trim_regions` keeps one: 188 town names
    in the bundled data name more than one distinct place (e.g. "La Paz" is
    four towns in four different countries; "Alexandria" is four, two of
    them in the same country) — without it, `PreferenceRanker` would key a
    learned preference by name alone and let two unrelated towns share a
    weight neither one's judgments produced."""
    with open(f"{RAW_DIR}/places.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        country = feature["properties"].get("ADM0NAME")
        if not name:
            continue
        lon, lat = feature["geometry"]["coordinates"][:2]
        out.append({
            "n": name,
            "c": country,
            "lat": round(lat, COORDINATE_DECIMAL_PLACES),
            "lon": round(lon, COORDINATE_DECIMAL_PLACES),
        })
    with open(f"{OUT_DIR}/places.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"places.json: {len(out)} entries")


trim_countries()
trim_natural()
trim_regions()
trim_places()
