#!/usr/bin/env python3
"""Trims and simplifies raw Natural Earth and GeoNames data into the compact
place gazetteer Firnlight bundles as a resource (`Firnlight/PlaceData/*.json`).

Only ever invoked by `scripts/fetch-place-data.sh`, which downloads the raw
inputs this reads into a scratch directory and passes both directories as
arguments. Not a standalone entry point.

FR-5.14 needs real named places, offline, at three scales at least — "as
published geographic references name and bound them", "the natural and the
political alike", "known down to the landscapes people name locally... not
only those a world map names" — and FR-10.5's exception for world reference
data is what lets a *fetch step* obtain this rather than redistributing it
(the repository itself never carries the raw or trimmed data — see
fetch-place-data.sh's own header). Two sources, for two different grains:

- Natural Earth (naturalearthdata.com/about/terms-of-use, public domain):
  countries, world-significant natural landscape polygons, and admin-1
  region label points — see `trim_countries`/`trim_natural`/`trim_regions`.
- GeoNames (geonames.org, CC BY 4.0 — credited in About.swift alongside
  Natural Earth): everything at *local* landscape and park granularity —
  named hills, ranges, forests, valleys and parks that no world atlas
  carries — see `trim_landscapes`/`trim_parks`.

Every table's entries are kept unique by the source dataset's own stable id
(never by name or name+country alone, which real places collide on far more
than seems obvious at a glance — see `dedupe_ids`), and dropped to just each
feature's name, its own id, its containing country where that helps a reader
tell two same-named places apart, and (for polygon data) a simplified
boundary — everything else in the raw data is discarded.
"""
import csv
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
# nearest-neighbour region/place/landscape/park lookups, but cheap to keep
# rather than thin further.
COORDINATE_DECIMAL_PLACES = 3

# A ring whose raw longitude span exceeds this is treated as crossing the
# ±180° antimeridian rather than genuinely spanning that much of the globe.
# Checked against every ring in the bundled countries data: only Antarctica's
# one ring actually exceeds it, and legitimately — it really does run across
# every longitude at its latitude band — so unwrapping finds nothing to do
# there either way (harmless; see `unwrap_polygon`). The countries whose
# overall *shape* crosses the seam (Russia, the USA, Fiji, New Zealand,
# Kiribati, the U.S. Minor Outlying Islands) don't need this: Natural Earth
# already represents each of them as a separate polygon piece per side of
# the seam rather than one ring that jumps, which is also why PlaceGazetteer
# boxes each piece individually instead of the whole feature (see its
# `PolygonPiece` — a feature-wide box would still span the whole globe for
# these regardless of anything this script does).
ANTIMERIDIAN_SPAN_DEGREES = 180

# GeoNames feature codes kept for FR-5.14's *landscape* grain — see
# geonames.org/export/codes.html. Deliberately the areal/extended codes
# ("a range of hills", "a mountain range", "a valley", "a forest") rather
# than every individual named summit or peak: GeoNames' T class alone has
# roughly 1.84 million point features once every hill, mountain, rock,
# ridge spur and cape is counted, which would multiply the bundled data
# several times over for coverage that's closer to "a landmark" than "the
# landscape a photo was taken in" — a single named peak is usually
# experienced as part of the broader range or valley it sits within anyway,
# which the codes below already capture. Verified: neither this nor any
# other Natural Earth or GeoNames layer names anything at the granularity of
# Germany's Odenwald specifically (searched "Odenwald" — the *region*-class
# entry is caught by `trim_landscapes`'s L.RGN-style admin fallback... no:
# it is present as GeoNames feature T.MTS "Odenwald", which these codes do
# include).
LANDSCAPE_CODES = {
    ("T", "HLLS"), ("T", "MTS"), ("T", "RDGE"), ("T", "VAL"), ("T", "VALS"),
    ("T", "UPLD"), ("T", "PLAT"),
    ("V", "FRST"), ("V", "GRSLD"), ("V", "MDW"), ("V", "HTH"), ("V", "SCRB"),
}

# GeoNames feature codes kept for FR-5.14's "a town or park" — the park half.
PARK_CODES = {
    ("L", "PRK"), ("L", "RESN"), ("L", "RESF"), ("L", "RESW"), ("L", "RESV"), ("L", "RES"),
}


def dedupe_ids(entries, id_key="id"):
    """Ensures every entry's id is unique within this file, even though each
    id already comes from the source dataset's own stable identifier (in
    every case checked, already unique on its own except natural.json's
    NE_ID, which repeats for a handful of features that are genuinely
    different places sharing one Natural Earth id — see `trim_natural`). A
    repeat gets a numeric suffix appended, deterministic because it depends
    only on each entry's own position in the source file, never on
    anything that could vary between runs.

    This is the fix for the leak FR-5.14 forbids ("What the user's choices
    reveal about one place never reaches another except through the larger
    places both belong to"): country-qualifying a name (an earlier version
    of this pipeline's approach) still collided for real, unrelated places
    that share both a name and a country — verified in the bundled data at
    63 town keys and 27 region keys. An id already unique in the source
    data, kept unique here even against its own rare exceptions, has no such
    failure mode: two different features can never end up with the same id."""
    seen = {}
    for entry in entries:
        base = str(entry[id_key])
        seen[base] = seen.get(base, 0) + 1
        entry[id_key] = base if seen[base] == 1 else f"{base}-{seen[base]}"
    return entries


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


def unwrap_polygon(polygon):
    """Shifts an entire polygon piece (its exterior ring and every hole
    ring together, never just one of them in isolation — a hole is only
    meaningful relative to its own exterior) into a contiguous longitude
    domain if *any* of its rings crosses the ±180° antimeridian, so both the
    simplifier's distance math and `PlaceGazetteer`'s ray-casting see one
    unbroken shape instead of a jump from +179.9 to −179.9 partway around.
    Every point with a negative longitude gets +360 added, moving it next to
    its eastern-hemisphere neighbours instead of wrapping back to the other
    side of the globe. A polygon that doesn't actually cross the seam at all
    is returned unchanged.

    Deciding this once per polygon rather than independently per ring
    matters for correctness even though no such case exists in the bundled
    data today (verified): an exterior ring that crosses the seam paired
    with a hole ring that doesn't would otherwise unwrap into two different
    coordinate spaces, breaking the hole's containment relative to its own
    exterior."""
    all_lons = [p[0] for ring in polygon for p in ring]
    if max(all_lons) - min(all_lons) <= ANTIMERIDIAN_SPAN_DEGREES:
        return polygon
    return [[[p[0] + 360 if p[0] < 0 else p[0], p[1]] for p in ring] for ring in polygon]


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
    """Unwrap (if needed), simplify and round every polygon of one feature's
    geometry — the shared pipeline `trim_countries` and `trim_natural` both
    run each feature through."""
    polygons = normalize_to_multipolygon(geometry)
    return [
        [[round_point(p) for p in rdp(ring, SIMPLIFY_EPSILON_DEGREES)] for ring in unwrap_polygon(polygon)]
        for polygon in polygons
    ]


def trim_countries():
    """FR-5.14's coarse scale: `ne_10m_admin_0_countries` polygons, simplified
    and rounded. Countries vary too much in size and shape for a
    nearest-point approximation to reliably tell "France" from "the USA" the
    way FR-5.14's own example demands, so this is real boundary geometry,
    point-in-polygon tested. Names are unique within this dataset (verified),
    so no id is needed here the way every other table needs one."""
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
    """FR-5.14's landscape scale, the world-significant tier:
    `ne_10m_geography_regions_polys` — named mountain ranges, plateaus,
    deserts, and similar physical landscape features with a real published
    boundary, tested by point-in-polygon exactly like a country and tried
    before `trim_landscapes`'s finer-grained point data (see
    PlaceGazetteer.landscape). Islands are excluded: an island nation's own
    name already comes from `countries.json`, so keeping them here would
    just relabel a country as a landform.

    `id` is `NE_ID`, deduplicated (see `dedupe_ids`) — the one table where
    the source dataset's own id isn't already unique on its own: six
    features share an id with another, unrelated one (e.g. two different,
    unrelated mountain ranges both named "Cordillera Oriental" happen to
    carry the same NE_ID) — `dedupe_ids` is what keeps that from becoming
    the same leak FR-5.14 forbids for names alone."""
    with open(f"{RAW_DIR}/natural.geojson") as f:
        data = json.load(f)
    excluded_classes = {"Island", "Island group", "Dragons-be-here"}
    out = []
    for feature in data["features"]:
        name = feature["properties"].get("NAME")
        feature_class = feature["properties"].get("FEATURECLA")
        ne_id = feature["properties"].get("NE_ID")
        if not name or feature_class in excluded_classes:
            continue
        out.append({"n": name, "id": ne_id, "g": simplified_polygons(feature["geometry"])})
    dedupe_ids(out)
    with open(f"{OUT_DIR}/natural.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"natural.json: {len(out)} entries")


def trim_regions():
    """FR-5.14's region scale (the political counterpart FR-5.14 keeps
    alongside the landscape scale, never in its place — see
    PlaceGazetteer.region): `ne_10m_admin_1_states_provinces`, kept as each
    region's own label point (the dataset's own `latitude`/`longitude`
    properties — a representative point Natural Earth already computed for
    map labelling) rather than its polygon. `PlaceGazetteer` matches a
    coordinate to the *nearest* region point rather than testing containment
    — an approximation (a Voronoi diagram over label points is not the same
    as the true administrative boundary), chosen deliberately: it gives a
    real, correctly-scoped region name without needing this file's full
    polygon geometry, which at 10m resolution is tens of megabytes raw.

    `id` is `adm1_code`, already unique in the source data on its own
    (verified — every entry has one, none repeat). `c` (the region's own
    country, `admin` in the source) stays purely for a reader's benefit —
    `PlaceGazetteer` no longer relies on name+country for uniqueness the way
    an earlier version of this pipeline did (63 town keys and 27 region keys
    in this same data collide on name+country alone, e.g. "Jelgava, Latvia"
    names more than one distinct region)."""
    with open(f"{RAW_DIR}/regions.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        p = feature["properties"]
        name = p.get("name")
        country = p.get("admin")
        adm1 = p.get("adm1_code")
        lat, lon = p.get("latitude"), p.get("longitude")
        if not name or not country or not adm1 or lat is None or lon is None:
            continue
        out.append({
            "n": name,
            "c": country,
            "id": adm1,
            "lat": round(lat, COORDINATE_DECIMAL_PLACES),
            "lon": round(lon, COORDINATE_DECIMAL_PLACES),
        })
    dedupe_ids(out)
    with open(f"{OUT_DIR}/regions.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"regions.json: {len(out)} entries")


def trim_places():
    """FR-5.14's fine scale, the town half: `ne_10m_populated_places`, name +
    point (+ its own country, `ADM0NAME` in the source) — `PlaceGazetteer`
    matches a coordinate to the nearest one (combined with `trim_parks`'s
    output — a "town or park" are one scale, tried together), the same
    nearest-point approximation `trim_regions` uses and for the same reason
    (a "town or park" has no published boundary polygon to test containment
    against in the first place).

    `id` is `NE_ID`, already unique in the source data on its own (verified
    — `GEONAMESID`, this table's other id-shaped column, is missing or -1
    for 543 entries and repeats for 6, which is why this uses `NE_ID`
    instead). `c` is purely for a reader's benefit, same reasoning
    `trim_regions` gives."""
    with open(f"{RAW_DIR}/places.geojson") as f:
        data = json.load(f)
    out = []
    for feature in data["features"]:
        p = feature["properties"]
        name = p.get("NAME")
        country = p.get("ADM0NAME")
        ne_id = p.get("NE_ID")
        if not name or ne_id is None:
            continue
        lon, lat = feature["geometry"]["coordinates"][:2]
        out.append({
            "n": name,
            "c": country,
            "id": ne_id,
            "lat": round(lat, COORDINATE_DECIMAL_PLACES),
            "lon": round(lon, COORDINATE_DECIMAL_PLACES),
        })
    dedupe_ids(out)
    with open(f"{OUT_DIR}/places.json", "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"places.json: {len(out)} entries")


def load_country_names():
    """ISO-3166 2-letter code → country name, from GeoNames' own
    `countryInfo.txt` — needed because `allCountries.txt`'s per-feature rows
    carry only the 2-letter code, and a reader-facing name is more useful
    than a bare code (the same reason every other table here keeps a country
    name, not a code, alongside its id)."""
    names = {}
    with open(f"{RAW_DIR}/countryInfo.txt", encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            columns = line.rstrip("\n").split("\t")
            if len(columns) > 4:
                names[columns[0]] = columns[4]
    return names


def trim_geonames(out_path, wanted_codes, label):
    """Shared pipeline for `trim_landscapes` and `trim_parks`: both filter
    the same GeoNames `allCountries.txt` dump by a set of (feature class,
    feature code) pairs and emit the same {n, c, id, lat, lon} shape
    `trim_places`/`trim_regions` already use. `id` is GeoNames' own
    `geonameid` — the primary key of their entire ~13 million-row database,
    already globally unique by construction, so `dedupe_ids` here is a
    defensive check rather than a fix for anything observed."""
    country_names = load_country_names()
    csv.field_size_limit(sys.maxsize)
    out = []
    with open(f"{RAW_DIR}/allCountries.txt", encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t")
        for row in reader:
            if len(row) < 9:
                continue
            geonameid, name = row[0], row[1]
            lat, lon = row[4], row[5]
            fclass, fcode = row[6], row[7]
            country_code = row[8]
            if not name or (fclass, fcode) not in wanted_codes:
                continue
            out.append({
                "n": name,
                "c": country_names.get(country_code, country_code),
                "id": geonameid,
                "lat": round(float(lat), COORDINATE_DECIMAL_PLACES),
                "lon": round(float(lon), COORDINATE_DECIMAL_PLACES),
            })
    dedupe_ids(out)
    with open(out_path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"{label}: {len(out)} entries")


def trim_landscapes():
    """FR-5.14's landscape scale, the local tier the brief specifically asks
    for ("known down to the landscapes people name locally — a range of
    hills, a forest, a valley — not only those a world map names"):
    GeoNames feature classes T (terrain) and V (vegetation), restricted to
    `LANDSCAPE_CODES` — see that constant for which codes and why. Tried by
    `PlaceGazetteer.landscape` after `trim_natural`'s world-significant
    polygons (a real boundary beats a nearest point when both are
    available) and before falling through to nil."""
    trim_geonames(f"{OUT_DIR}/landscapes.json", LANDSCAPE_CODES, "landscapes.json")


def trim_parks():
    """FR-5.14's fine scale, the park half ("a town or park"): GeoNames
    feature class L restricted to `PARK_CODES` (parks, nature/forest/wildlife
    reserves — see that constant). Tried together with `trim_places`'s towns
    as one nearest-point search (see PlaceGazetteer.town), since FR-5.14
    treats a town and a park as the same scale, not two separate ones."""
    trim_geonames(f"{OUT_DIR}/parks.json", PARK_CODES, "parks.json")


trim_countries()
trim_natural()
trim_regions()
trim_places()
trim_landscapes()
trim_parks()
