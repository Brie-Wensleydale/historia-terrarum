#!/usr/bin/env python3
"""
generate_land_mask.py — Classify every tile as land or water.  BUILD-TIME ONLY.

Uses Natural Earth 10m coastline to test tile centers against the land polygon.
Outputs:
  land_mask.bin          — compact binary, 1 bit per cell (~500 KB for ~4M cells)
  land_mask_summary.json  — band_segs, total_tiles, land_count, ocean_count
  land_mask.json          — optional JSON for debugging (disabled by default, use --json)

The coastline shapefile and this script are build tools — they never ship with the game.
The game only loads land_mask.bin via land_mask_loader.gd (~50ns bit lookup).

Usage:  python data/generate/generate_land_mask.py
        python data/generate/generate_land_mask.py --json   # also output land_mask.json
"""

import json
import math
import os
import struct
import sys
import time

# pip install shapely fiona
from shapely.geometry import Point, shape
from shapely import prepare
import fiona

# ── Grid Constants (must match spherical_grid_generator.gd) ──
EARTH_RADIUS_KM = 6371.0
EQUATOR_SEGS = 4096
TOTAL_BANDS = 2048
MIN_POLE_SEGS = 8
CELL_KM = 10.0  # approximate; actual is ~9.77 km at equator

# ── Paths ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
SHAPEFILE_DIR = os.path.join(PROJECT_ROOT, "data", "shapefiles")
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "output", "grid_10km_ht2")

COASTLINE_PATH = os.path.join(SHAPEFILE_DIR, "ne_10m_coastline.shp")

# ── Antarctica admin-0 path (for rock boundary, not ice shelf) ──
ANTARCTICA_PATH = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_0_countries.shp")


def compute_band_structure():
    """Mirrors SphericalGridGenerator.compute_band_structure() in Python.
    Returns (band_segs, total_tiles, cell_segs_per_band) where:
      - band_segs[i] = segment count at ring i (0..TOTAL_BANDS)
      - cell_segs_per_band[b] = max(band_segs[b], band_segs[b+1]) — the denser frame
      - total_tiles = sum(cell_segs_per_band)
    The game uses cell_segs for tile IDs: "B{band}_{seg}" with seg in 0..cell_segs-1.
    """
    radius_m = EARTH_RADIUS_KM * 1000.0
    half_cell_m = CELL_KM * 0.5 * 1000.0
    eq_band = TOTAL_BANDS // 2

    band_segs = [0] * (TOTAL_BANDS + 1)
    band_segs[eq_band] = EQUATOR_SEGS

    # Northward
    current_segs = EQUATOR_SEGS
    for b in range(eq_band + 1, TOTAL_BANDS + 1):
        lat = -math.pi * 0.5 + math.pi * b / TOTAL_BANDS
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < half_cell_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Southward
    current_segs = EQUATOR_SEGS
    for b in range(eq_band - 1, -1, -1):
        lat = -math.pi * 0.5 + math.pi * b / TOTAL_BANDS
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < half_cell_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Compute cell_segs per band (tile count per band = denser frame)
    cell_segs_per_band = []
    for b in range(TOTAL_BANDS):
        cell_segs_per_band.append(max(band_segs[b], band_segs[b + 1]))
    total_tiles = sum(cell_segs_per_band)

    return band_segs, total_tiles, cell_segs_per_band


def load_coastline():
    """Load Natural Earth admin-0 countries as a unified land polygon.
    
    Uses ne_10m_admin_0_countries.shp (polygon geometries) — NOT the coastline
    line shapefile. Admin-0 countries properly define land area as filled polygons.
    This is unioned into one big Multipolygon for fast contains() queries.
    """
    admin0_path = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_0_countries.shp")
    if not os.path.exists(admin0_path):
        print(f"ERROR: Admin-0 shapefile not found at {admin0_path}")
        sys.exit(1)

    print(f"Loading land polygons from {admin0_path}...")
    t0 = time.time()
    polygons = []
    with fiona.open(admin0_path) as src:
        for feat in src:
            geom = shape(feat["geometry"])
            if geom.is_valid and not geom.is_empty:
                polygons.append(geom)

    from shapely.ops import unary_union
    land = unary_union(polygons)
    prepare(land)
    elapsed = time.time() - t0
    print(f"  Loaded {len(polygons)} country polygons in {elapsed:.1f}s")
    print(f"  Land type: {land.geom_type}")
    if hasattr(land, 'area'):
        print(f"  Land area: {land.area:.1f} sq degrees")
    return land


def load_antarctica():
    """Load Antarctica's admin-0 boundary (rock, not ice shelf)."""
    if not os.path.exists(ANTARCTICA_PATH):
        print("  Antarctica shapefile not found, skipping")
        return None

    with fiona.open(ANTARCTICA_PATH) as src:
        for feat in src:
            props = feat["properties"]
            if props.get("ADMIN", "") == "Antarctica":
                geom = shape(feat["geometry"])
                prepare(geom)
                print(f"  Loaded Antarctica admin-0 boundary")
                return geom
    return None


def tile_to_lat_lon(band: int, seg: int, band_segs: list):
    """Compute the center lat/lon of a tile (band, segment).
    Seg=0 → lon=0° (prime meridian), matching GDScript spherical_grid_generator convention."""
    lat = -math.pi * 0.5 + math.pi * (band + 0.5) / TOTAL_BANDS
    segs_at_band = band_segs[band]
    if segs_at_band <= 0:
        segs_at_band = 1
    lon = 2.0 * math.pi * seg / segs_at_band  # 0 to 2π
    lon_deg = math.degrees(lon)  # 0 to 360
    if lon_deg > 180.0:
        lon_deg -= 360.0  # to -180..180
    # Nudge points at exact antimeridian to avoid polygon-edge misses
    if lon_deg >= 179.999:
        lon_deg = 179.999
    elif lon_deg <= -179.999:
        lon_deg = -179.999
    return math.degrees(lat), lon_deg


def generate_mask(band_segs: list, total_tiles: int, cell_segs_per_band: list,
                  land_polygon, antarctica_polygon,
                  output_json: bool = False):
    """
    Classify every tile and write land_mask.bin.
    Iterates using cell_segs_per_band (denser frame) — matching the game's tile IDs.
    Returns (land_count, ocean_count, [tile_list if output_json else None])
    """
    # Allocate bit array
    total_bits = total_tiles
    total_bytes = (total_bits + 7) // 8
    bit_array = bytearray(total_bytes)

    land_count = 0
    tile_list = [] if output_json else None

    t0 = time.time()
    tile_index = 0
    last_report = 0
    report_interval = 500000

    for band in range(TOTAL_BANDS):
        segs = cell_segs_per_band[band]  # denser frame — matches game
        if segs <= 0:
            continue

        for seg in range(segs):
            lat, lon = tile_to_lat_lon(band, seg, band_segs)

            is_land = False
            pt = Point(lon, lat)

            if land_polygon.contains(pt):
                is_land = True
            elif antarctica_polygon and antarctica_polygon.contains(pt):
                is_land = True

            if is_land:
                byte_idx = tile_index // 8
                bit_offset = tile_index % 8
                bit_array[byte_idx] |= (1 << bit_offset)
                land_count += 1

            if output_json and is_land:
                tile_list.append(f"B{band}_{seg}")

            tile_index += 1

            if tile_index - last_report >= report_interval:
                elapsed = time.time() - t0
                pct = tile_index / total_tiles * 100
                rate = tile_index / elapsed if elapsed > 0 else 0
                eta = (total_tiles - tile_index) / rate if rate > 0 else 0
                print(f"  {tile_index:,}/{total_tiles:,} tiles ({pct:.1f}%) — "
                      f"{land_count:,} land, {rate:,.0f} tiles/s, ETA {eta:.0f}s")
                last_report = tile_index

    elapsed = time.time() - t0
    ocean_count = total_tiles - land_count
    print(f"  Done: {tile_index:,} tiles in {elapsed:.1f}s ({tile_index/elapsed:,.0f} tiles/s)")
    print(f"  Land: {land_count:,} ({land_count/total_tiles*100:.1f}%)")
    print(f"  Ocean: {ocean_count:,} ({ocean_count/total_tiles*100:.1f}%)")

    # Write binary mask
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    mask_path = os.path.join(OUTPUT_DIR, "land_mask.bin")
    with open(mask_path, "wb") as f:
        f.write(bit_array)
    print(f"  Written: {mask_path} ({len(bit_array):,} bytes)")

    return land_count, ocean_count, tile_list


def write_summary(band_segs: list, total_tiles: int, land_count: int, ocean_count: int):
    """Write land_mask_summary.json with band structure and counts."""
    summary_path = os.path.join(OUTPUT_DIR, "land_mask_summary.json")
    band_segs_dict = {str(i): s for i, s in enumerate(band_segs)}
    summary = {
        "grid": {
            "earth_radius_km": EARTH_RADIUS_KM,
            "equator_segs": EQUATOR_SEGS,
            "total_bands": TOTAL_BANDS,
            "cell_km_approx": CELL_KM,
            "min_pole_segs": MIN_POLE_SEGS,
        },
        "tiles": {
            "total": total_tiles,
            "land": land_count,
            "ocean": ocean_count,
            "land_pct": round(land_count / total_tiles * 100, 2),
        },
        "band_segs": band_segs_dict,
        "merge_chain": sorted(set(band_segs), reverse=True),
    }
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Written: {summary_path}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate land/water binary mask")
    parser.add_argument("--json", action="store_true",
                        help="Also output land_mask.json (list of land tile IDs)")
    args = parser.parse_args()

    print("=" * 60)
    print("Historia Terrarum 2 — Land/Water Mask Generator")
    print("=" * 60)

    # 1. Compute band structure
    print("\n[1/4] Computing band structure...")
    t0 = time.time()
    band_segs, total_tiles, cell_segs_per_band = compute_band_structure()
    print(f"  Total bands: {TOTAL_BANDS}")
    print(f"  Equator segments: {EQUATOR_SEGS}")
    print(f"  Total tiles (denser frame): {total_tiles:,}")
    merge_chain = sorted(set(band_segs), reverse=True)
    print(f"  Merge chain: {merge_chain}")
    print(f"  Polar cells: {band_segs[0]} (south), {band_segs[TOTAL_BANDS]} (north)")

    # 2. Load coastline
    print(f"\n[2/4] Loading coastline data...")
    land_polygon = load_coastline()
    antarctica_polygon = load_antarctica()

    # 3. Classify tiles
    print(f"\n[3/4] Classifying {total_tiles:,} tiles...")
    land_count, ocean_count, tile_list = generate_mask(
        band_segs, total_tiles, cell_segs_per_band, land_polygon, antarctica_polygon, args.json
    )

    # 4. Write summary
    print(f"\n[4/4] Writing outputs...")
    write_summary(band_segs, total_tiles, land_count, ocean_count)

    if args.json and tile_list:
        json_path = os.path.join(OUTPUT_DIR, "land_mask.json")
        with open(json_path, "w") as f:
            json.dump(sorted(tile_list), f)
        print(f"  Written: {json_path} ({len(tile_list):,} land tile IDs)")

    total_elapsed = time.time() - t0
    print(f"\nDone in {total_elapsed:.1f}s total.")
    print(f"Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
