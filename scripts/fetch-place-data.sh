#!/usr/bin/env bash
#
# Fetches and builds Firnlight/PlaceData/{countries,natural,regions,places}.json
# — the offline place gazetteer FR-5.14 needs for its three scales with no
# network (FR-9.3) — from Natural Earth's public-domain map data
# (naturalearthdata.com/about/terms-of-use, "Crediting the authors is
# unnecessary" — Firnlight credits them anyway, in About.swift's
# AppIdentity.mapDataCredit, per FR-10.5's "credits it as its authors ask").
#
# This is the "setup instructions" FR-10.5 and FR-10.7 mean: "the repository
# still only carries the means to obtain it" — Firnlight/PlaceData/ is
# gitignored, and this script is what a fresh clone runs once, the same
# relationship the `.claude/skills-src/*` submodules have to the skill
# content they provide (never committed, only ever obtained fresh). Run it
# again whenever the upstream data or this script's own trimming changes;
# the app degrades to "no gazetteer answer at any scale" rather than
# crashing if PlaceData is missing (see PlaceGazetteer's doc comment), but
# every photo's location is then a bare, unnamed coordinate again — running
# this is part of building the app as the brief intends, not optional
# polish.
#
# Requires: curl, python3 (the trimming/simplification step,
# scripts/trim-place-data.py, is plain-stdlib Python — no pip packages).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Firnlight/PlaceData"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to trim and simplify the raw map data (see this script's header)." >&2
  exit 1
fi

BASE_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson"

# FR-5.14's coarse scale (country): 1:10m is the finest Natural Earth
# offers, and turned out to matter — 1:50m's coastline simplification put
# New York and Rio de Janeiro outside their own countries (verified; see
# trim-place-data.py's note on SIMPLIFY_EPSILON_DEGREES). Worldwide and
# complete; ~13 MB raw, trimmed and simplified down to under 2 MB.
echo "Fetching countries (1:10m, admin-0)..."
curl -sSL -m 90 "$BASE_URL/ne_10m_admin_0_countries.geojson" -o "$SCRATCH_DIR/countries.geojson"

# FR-5.14's medium scale, the natural half ("a landscape or mountain
# range"): named physical/landform regions — mountain ranges, plateaus,
# deserts and the like — point-in-polygon tested and preferred over the
# political admin-1 fallback below when a coordinate falls inside one.
echo "Fetching natural landscape regions (1:10m, geography regions)..."
curl -sSL -m 90 "$BASE_URL/ne_10m_geography_regions_polys.geojson" -o "$SCRATCH_DIR/natural.geojson"

# FR-5.14's medium scale, the political half and the fallback everywhere the
# natural layer above doesn't reach: the 1:50m admin-1 file only covers a
# handful of the largest countries (verified against the fetched data:
# Russia, the US, India, Indonesia, China, Brazil, Canada, Australia and
# South Africa only) — an artifact of how this mirror publishes that
# resolution tier, not a documented limitation of Natural Earth itself. The
# 1:10m tier is the complete, worldwide (253-country) admin-1 dataset;
# `trim-place-data.py` keeps only each region's own label point from it
# (already present in the source data), never the full boundary polygon, so
# the ~40 MB raw file trims down to a few hundred kilobytes.
echo "Fetching regions (1:10m, admin-1, label points only)..."
curl -sSL -m 90 "$BASE_URL/ne_10m_admin_1_states_provinces.geojson" -o "$SCRATCH_DIR/regions.geojson"

# FR-5.14's fine scale (town/park): 1:10m for the same completeness reason —
# 1:50m and 1:110m are too sparse (1,251 and 243 places worldwide
# respectively) to be a plausible "nearest town" for most photo locations.
echo "Fetching places (1:10m, populated places)..."
curl -sSL -m 90 "$BASE_URL/ne_10m_populated_places.geojson" -o "$SCRATCH_DIR/places.geojson"

echo "Trimming and simplifying..."
mkdir -p "$OUT_DIR"
python3 "$REPO_ROOT/scripts/trim-place-data.py" "$SCRATCH_DIR" "$OUT_DIR"

echo "Done. $(du -sh "$OUT_DIR" | cut -f1) in $OUT_DIR (gitignored — never committed, see this script's header)."
