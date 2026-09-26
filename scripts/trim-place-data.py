#!/usr/bin/env python3
"""Trims and simplifies raw Natural Earth GeoJSON into the compact place
gazetteer Firnlight bundles as a resource (`Firnlight/PlaceData/*.json`).

Only ever invoked by `scripts/fetch-place-data.sh`, which downloads the raw
inputs this reads into a scratch directory and passes both directories as
arguments. Not a standalone entry point.

FR-5.14 needs real named places, offline, at three scales — "as published
geographic references name and bound them" — and FR-10.5's exception for
world reference data is what lets the trimmed result below be committed to
the repository rather than merely fetched fresh on every clone. The raw
Natural Earth files are public domain (naturalearthdata.com/about/terms-of-use)
and far larger than the app needs: this keeps only each feature's name (and,
for countries, a simplified boundary) and drops everything else.
"""
import json
import sys

RAW_DIR = sys.argv[1]
OUT_DIR = sys.argv[2]

# Ramer-Douglas-Peucker tolerance, in degrees, for country polygons. Not a
# survey-grade simplification — country point-in-polygon lookups only have
# to be honest to within a few kilometres of any border for ranking
# generalization, not to the precision a legal boundary needs, and the raw
# 10m-resolution source is already a cartographic simplification itself.
#
# 0.03° chosen empirically, not measured: 0.05° (and the coarser 1:50m
# source this originally used) put real coastal cities outside their own
# country — verified false negatives at New York and Rio de Janeiro, both
# right at a complex bay/harbour coastline the coarser simplification
# smoothed away. 0.03° against the 1:10m source fixed both while still
# cutting the raw point count by around 85%. A few other coastal/archipelago
# spots (Venice, central Miami) still come up empty even completely
# unsimplified at 1:10m — an inherent limitation of a world-scale published
# dataset, not something this simplification step introduces or could fix by
# being more conservative; FR-3.8 already treats a place a photo's location
# can't be matched to as a gap, not a penalty.
COUNTRY_SIMPLIFY_EPSILON_DEGREES = 0.03

# Coordinate rounding for every file. ~111m at the equator per 0.001° of
# latitude — far finer than a country border needs and immaterial for the
# nearest-neighbour region/place lookups, but cheap to keep rather than
# thin further.
COORDINATE_DECIMAL_PLACES = 3


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


def normalize_to_multipolygon(geometry):
    """Every country geometry becomes the same shape on the way out — a list
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


def trim_countries():
    """FR-5.14's coarse scale: `ne_50m_admin_0_countries` polygons, simplified
    and rounded. This is the one scale that gets real boundary geometry —
    countries vary too much in size and shape for a nearest-point
    approximation to reliably tell "France" from "the USA" the way FR-5.14's
    own example demands."""
    with open(f"{RAW_DIR}/countries.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        if not name:
            continue
        polygons = normalize_to_multipolygon(feature["geometry"])
        simplified = [
            [[round_point(p) for p in rdp(ring, COUNTRY_SIMPLIFY_EPSILON_DEGREES)] for ring in polygon]
            for polygon in polygons
        ]
        out.append({"n": name, "g": simplified})
    with open(f"{OUT_DIR}/countries.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"countries.json: {len(out)} entries")


def trim_regions():
    """FR-5.14's medium scale: `ne_10m_admin_1_states_provinces`, kept as
    each region's own label point (the dataset's own `latitude`/`longitude`
    properties — a representative point Natural Earth already computed for
    map labelling) rather than its polygon. `PlaceGazetteer` matches a
    coordinate to the *nearest* region point rather than testing containment
    — an approximation (a Voronoi diagram over label points is not the same
    as the true administrative boundary), chosen deliberately: it gives a
    real, correctly-scoped region name without needing this file's full
    polygon geometry, which at 10m resolution is tens of megabytes raw."""
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
    """FR-5.14's fine scale: `ne_10m_populated_places`, name + point only —
    `PlaceGazetteer` matches a coordinate to the nearest one, the same
    nearest-point approximation `trim_regions` uses and for the same reason
    (a "town or park" has no published boundary polygon to test containment
    against in the first place)."""
    with open(f"{RAW_DIR}/places.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        if not name:
            continue
        lon, lat = feature["geometry"]["coordinates"][:2]
        out.append({
            "n": name,
            "lat": round(lat, COORDINATE_DECIMAL_PLACES),
            "lon": round(lon, COORDINATE_DECIMAL_PLACES),
        })
    with open(f"{OUT_DIR}/places.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"places.json: {len(out)} entries")


trim_countries()
trim_regions()
trim_places()
