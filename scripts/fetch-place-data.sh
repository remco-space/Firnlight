#!/usr/bin/env bash
#
# Fetches and builds Firnlight/PlaceData/{countries,natural,regions,places,landscapes,parks}.json
# — the offline place gazetteer FR-5.14 needs for its scales with no network
# (FR-9.3) — from two public sources:
#
# - Natural Earth (naturalearthdata.com/about/terms-of-use, public domain):
#   countries, world-significant landscapes, and admin-1 region points.
# - GeoNames (geonames.org, CC BY 4.0): local-granularity landscapes and
#   parks — named hills, ranges, forests, valleys and parks no world atlas
#   carries, which FR-5.14 explicitly asks for ("known down to the
#   landscapes people name locally... not only those a world map names").
#   Both credited in About.swift's AppIdentity.mapDataCredit per FR-10.5's
#   "credits it as its authors ask".
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
# polish. Not only a local developer setup step, either: CI runs this same
# script before every build (build.yml/release.yml) — a CI artifact with no
# gazetteer data would silently ship every user the same false "no place
# known at any scale" state FR-5.14 forbids.
#
# Both sources are pinned rather than left to whatever "latest" currently
# means, because FR-5.2/FR-9.1 need every device to resolve one coordinate
# to the exact same key: Natural Earth is fetched from an exact, immutable
# commit (`NE_PIN_COMMIT` below); GeoNames publishes no such versioned
# archive, so `GEONAMES_CHECKSUM_MANIFEST` (`scripts/geonames-checksums.txt`,
# committed — it's a hash, not the data itself, so FR-10.5 is untouched)
# records the last-known-good checksum and warns loudly, rather than failing
# silently, the next time the live dump has moved. See both variables' own
# comments below for the full reasoning and residual limitation.
#
# GeoNames' allCountries.zip is the whole world in one file (~400 MB
# compressed, ~1.8 GB / 13.5 million rows uncompressed) because GeoNames
# doesn't publish a pre-filtered "natural features only" extract the way it
# does for cities by population; trim-place-data.py does the filtering down
# to the few hundred thousand rows Firnlight actually keeps. Downloading and
# filtering the whole file is slow and disk-hungry but is a one-time setup
# cost, run on the developer's own machine, never at app build or run time.
#
# Requires: curl, unzip, python3 (the trimming/simplification step,
# scripts/trim-place-data.py, is plain-stdlib Python — no pip packages).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Firnlight/PlaceData"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

for tool in python3 unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required (see this script's header)." >&2
    exit 1
  fi
done

# Pinned to an exact commit, not `master`'s moving tip: FR-5.2 ("the same
# library and the same judgments always produce the same ranking") and
# FR-9.1 ("a judgment made on one device counts on all of them") both need
# every device to resolve a given coordinate to the exact same gazetteer
# key, which an unpinned branch tip cannot promise — two clones made months
# apart, or a developer's machine and CI, could otherwise fetch different
# bytes and train the same replayed judgment onto two different keys. A
# GitHub commit sha is immutable (short of the upstream owner rewriting
# history, an accepted, standard risk of depending on any single upstream at
# all — the same one every commit-pinned Swift package or git submodule
# already carries); re-pin deliberately, as its own visible diff, if the
# upstream mirror ever needs to move (e.g. new NE data superseding this
# commit) — never silently.
NE_PIN_COMMIT="ca96624a56bd078437bca8184e78163e5039ad19" # nvkelso/natural-earth-vector, 2022-06-02
NE_BASE_URL="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$NE_PIN_COMMIT/geojson"
GEONAMES_BASE_URL="https://download.geonames.org/export/dump"
# GeoNames publishes no versioned or dated archive for `allCountries.zip` —
# every fetch reads whatever the live dump currently is, so the commit-pin
# trick above doesn't apply here. `GEONAMES_CHECKSUM_MANIFEST` is the best
# achievable substitute: not a guarantee of byte-identical data across two
# fetches (nothing can promise that against a live, continuously-regenerated
# third-party feed with no history), but a way to make drift *visible and
# deliberate* rather than silent — see the checksum check below, after the
# download, for exactly what it does on a mismatch.
GEONAMES_CHECKSUM_MANIFEST="$REPO_ROOT/scripts/geonames-checksums.txt"

# FR-5.14's coarse scale (country): 1:10m is the finest Natural Earth
# offers, and turned out to matter — 1:50m's coastline simplification put
# New York and Rio de Janeiro outside their own countries (verified; see
# trim-place-data.py's note on SIMPLIFY_EPSILON_DEGREES). Worldwide and
# complete; ~13 MB raw, trimmed and simplified down to under 2 MB.
echo "Fetching countries (Natural Earth 1:10m, admin-0)..."
curl -sSL -m 90 "$NE_BASE_URL/ne_10m_admin_0_countries.geojson" -o "$SCRATCH_DIR/countries.geojson"

# FR-5.14's landscape scale, the world-significant tier: named physical
# landform regions — mountain ranges, plateaus, deserts and the like —
# point-in-polygon tested and tried before the local-granularity GeoNames
# tier below.
echo "Fetching world-significant landscapes (Natural Earth 1:10m, geography regions)..."
curl -sSL -m 90 "$NE_BASE_URL/ne_10m_geography_regions_polys.geojson" -o "$SCRATCH_DIR/natural.geojson"

# FR-5.14's region scale, the political counterpart the landscape scale
# never replaces (see PlaceGazetteer.region — both are always independently
# known): the 1:50m admin-1 file only covers a handful of the largest
# countries (verified against the fetched data: Russia, the US, India,
# Indonesia, China, Brazil, Canada, Australia and South Africa only) — an
# artifact of how this mirror publishes that resolution tier, not a
# documented limitation of Natural Earth itself. The 1:10m tier is the
# complete, worldwide (253-country) admin-1 dataset; `trim-place-data.py`
# keeps both each region's real boundary polygon (simplified, like
# countries/natural landscapes) and its label point (for the rare fallback
# where no polygon claims a coordinate) — see PlaceGazetteer.region.
echo "Fetching regions (Natural Earth 1:10m, admin-1, boundaries + label points)..."
curl -sSL -m 90 "$NE_BASE_URL/ne_10m_admin_1_states_provinces.geojson" -o "$SCRATCH_DIR/regions.geojson"

# FR-5.14's fine scale, the town half: 1:10m for the same completeness
# reason — 1:50m and 1:110m are too sparse (1,251 and 243 places worldwide
# respectively) to be a plausible "nearest town" for most photo locations.
echo "Fetching places (Natural Earth 1:10m, populated places)..."
curl -sSL -m 90 "$NE_BASE_URL/ne_10m_populated_places.geojson" -o "$SCRATCH_DIR/places.geojson"

# FR-5.14's landscape scale (local tier) and fine scale (park half): GeoNames'
# whole-world gazetteer, filtered down by trim-place-data.py. See this
# script's header for why the whole file is fetched rather than something
# pre-filtered — GeoNames doesn't offer that split.
echo "Fetching GeoNames (~400 MB — this is the slow step)..."
curl -sSL -m 550 "$GEONAMES_BASE_URL/allCountries.zip" -o "$SCRATCH_DIR/allCountries.zip"
echo "Fetching GeoNames country code table..."
curl -sSL -m 30 "$GEONAMES_BASE_URL/countryInfo.txt" -o "$SCRATCH_DIR/countryInfo.txt"

# Best-achievable substitute for a real pin (see this script's header):
# checksum what was just fetched against the last-known-good manifest, so a
# live dump that has moved since is a loud, visible warning rather than a
# silent difference discovered only by comparing two devices' rankings.
# Never a hard failure — GeoNames offers no historical archive, so treating
# a mismatch as fatal would permanently break every future clone the moment
# the live dump next changes, which is worse than the problem this guards
# against. The first-ever run has nothing to compare against and simply
# records today's checksums as the new baseline.
GEONAMES_SHA="$(shasum -a 256 "$SCRATCH_DIR/allCountries.zip" | awk '{print $1}')"
COUNTRY_INFO_SHA="$(shasum -a 256 "$SCRATCH_DIR/countryInfo.txt" | awk '{print $1}')"
if [ -f "$GEONAMES_CHECKSUM_MANIFEST" ]; then
  PINNED_GEONAMES_SHA="$(awk -F= '/^allCountries.zip=/ { print $2 }' "$GEONAMES_CHECKSUM_MANIFEST")"
  PINNED_COUNTRY_INFO_SHA="$(awk -F= '/^countryInfo.txt=/ { print $2 }' "$GEONAMES_CHECKSUM_MANIFEST")"
  if [ "$GEONAMES_SHA" != "$PINNED_GEONAMES_SHA" ] || [ "$COUNTRY_INFO_SHA" != "$PINNED_COUNTRY_INFO_SHA" ]; then
    echo "::warning::GeoNames' live dump has changed since scripts/geonames-checksums.txt was last recorded." >&2
    echo "This build's landscape/park data may differ from a device (or CI run) that fetched it earlier —" >&2
    echo "a real, disclosed limitation of relying on a feed GeoNames publishes with no version history" >&2
    echo "(see this script's header). Proceeding with today's data. To accept this as the new baseline" >&2
    echo "(and note the change in CHANGELOG.md, since it can shift FR-5.2/FR-9.1's determinism guarantee)," >&2
    echo "run: FETCH_PLACE_DATA_UPDATE_GEONAMES_PIN=1 scripts/fetch-place-data.sh" >&2
  fi
fi
if [ ! -f "$GEONAMES_CHECKSUM_MANIFEST" ] || [ "${FETCH_PLACE_DATA_UPDATE_GEONAMES_PIN:-}" = "1" ]; then
  {
    echo "allCountries.zip=$GEONAMES_SHA"
    echo "countryInfo.txt=$COUNTRY_INFO_SHA"
  } > "$GEONAMES_CHECKSUM_MANIFEST"
  echo "Recorded GeoNames checksums in $GEONAMES_CHECKSUM_MANIFEST (commit this — it's a hash, not the data itself)."
fi

echo "Unzipping GeoNames..."
unzip -q -o "$SCRATCH_DIR/allCountries.zip" -d "$SCRATCH_DIR"

echo "Trimming and simplifying..."
mkdir -p "$OUT_DIR"
python3 "$REPO_ROOT/scripts/trim-place-data.py" "$SCRATCH_DIR" "$OUT_DIR"

echo "Done. $(du -sh "$OUT_DIR" | cut -f1) in $OUT_DIR (gitignored — never committed, see this script's header)."
