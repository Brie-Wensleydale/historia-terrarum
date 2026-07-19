#!/usr/bin/env python3
"""
generate_climate.py — Classify every tile with Köppen-Geiger climate zone. BUILD-TIME ONLY.

Uses Beck et al. 2018 Köppen-Geiger raster at 1km resolution (~7 MB GeoTIFF).
Sample at each tile center → 1-byte climate code → climate.bin (~6.5 MB).

Data source: https://globe.umbc.edu/apps/ckan/organization/koeppen-geiger.html
File: beck_koppen_2018.tif (put in data/raster/)

Usage:  python data/generate/generate_climate.py
        python data/generate/generate_climate.py --raster /path/to/koppen.tif
"""

import json
import math
import os
import struct
import sys
import time

# pip install rasterio numpy
import numpy as np
try:
    import rasterio
except ImportError:
    print("ERROR: rasterio not installed. Run: pip install rasterio")
    sys.exit(1)

# ── Grid Constants ──
EARTH_RADIUS_KM = 6371.0
EQUATOR_SEGS = 4096
TOTAL_BANDS = 2048
MIN_POLE_SEGS = 8
CELL_KM = 10.0

# ── Paths ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
RASTER_DIR = os.path.join(PROJECT_ROOT, "data", "raster")
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "output", "grid_10km_ht2")

DEFAULT_RASTER = os.path.join(RASTER_DIR, "beck_koppen_2018.tif")

# ── Köppen Climate Codes ──
# Beck et al. 2018 raster encoding (values 1-30)
CLIMATE_NAMES = {
    1:  "Af",  2:  "Am",  3:  "Aw",  4:  "As",
    5:  "BWh", 6:  "BWk", 7:  "BSh", 8:  "BSk",
    9:  "Csa", 10: "Csb", 11: "Csc",
    12: "Cwa", 13: "Cwb", 14: "Cwc",
    15: "Cfa", 16: "Cfb", 17: "Cfc",
    18: "Dsa", 19: "Dsb", 20: "Dsc", 21: "Dsd",
    22: "Dwa", 23: "Dwb", 24: "Dwc", 25: "Dwd",
    26: "Dfa", 27: "Dfb", 28: "Dfc", 29: "Dfd",
    30: "ET",  31: "EF",
}

CLIMATE_GROUPS = {
    "A": "Tropical",    "B": "Arid",       "C": "Temperate",
    "D": "Continental", "E": "Polar",
}


def compute_band_structure():
    """Mirrors SphericalGridGenerator.compute_band_structure()."""
    radius_m = EARTH_RADIUS_KM * 1000.0
    half_cell_m = CELL_KM * 0.5 * 1000.0
    eq_band = TOTAL_BANDS // 2

    band_segs = [0] * (TOTAL_BANDS + 1)
    band_segs[eq_band] = EQUATOR_SEGS

    current_segs = EQUATOR_SEGS
    for b in range(eq_band + 1, TOTAL_BANDS + 1):
        lat = -math.pi * 0.5 + math.pi * b / TOTAL_BANDS
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < half_cell_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    current_segs = EQUATOR_SEGS
    for b in range(eq_band - 1, -1, -1):
        lat = -math.pi * 0.5 + math.pi * b / TOTAL_BANDS
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < half_cell_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    cell_segs_per_band = []
    for b in range(TOTAL_BANDS):
        cell_segs_per_band.append(max(band_segs[b], band_segs[b + 1]))
    total_tiles = sum(cell_segs_per_band)

    return band_segs, total_tiles, cell_segs_per_band


def tile_to_lat_lon(band: int, seg: int, cell_segs_per_band: list):
    """Compute tile center lat/lon in degrees (-90..90, -180..180)."""
    lat = -math.pi * 0.5 + math.pi * (band + 0.5) / TOTAL_BANDS
    segs = cell_segs_per_band[band]
    if segs <= 0:
        segs = 1
    lon = 2.0 * math.pi * seg / segs  # 0 to 2π, seg=0 at prime meridian
    lon_deg = math.degrees(lon)
    if lon_deg > 180.0:
        lon_deg -= 360.0
    return math.degrees(lat), lon_deg


def generate_climate(raster_path: str, cell_segs_per_band: list, total_tiles: int):
    """Sample Köppen raster at each tile center → 1-byte climate codes."""
    print(f"Opening raster: {raster_path}")
    t0 = time.time()

    with rasterio.open(raster_path) as src:
        print(f"  CRS: {src.crs}")
        print(f"  Bounds: {src.bounds}")
        print(f"  Shape: {src.height} × {src.width}")
        print(f"  Data type: {src.dtypes[0]}")

        # Read the entire raster into memory (only ~7 MB)
        band_data = src.read(1)
        transform = src.transform

        # Build climate byte array
        climate_bytes = bytearray(total_tiles)
        count_by_code = {}

        tile_index = 0
        last_report = 0
        report_interval = 500000

        for band in range(TOTAL_BANDS):
            segs = cell_segs_per_band[band]
            if segs <= 0:
                continue

            for seg in range(segs):
                lat, lon = tile_to_lat_lon(band, seg, cell_segs_per_band)

                # Convert lat/lon to raster pixel coordinates
                row, col = src.index(lon, lat)

                # Clamp to raster bounds
                row = max(0, min(row, band_data.shape[0] - 1))
                col = max(0, min(col, band_data.shape[1] - 1))

                code = int(band_data[row, col])
                if code < 1 or code > 31:
                    code = 0  # missing data → use 0

                climate_bytes[tile_index] = code
                count_by_code[code] = count_by_code.get(code, 0) + 1
                tile_index += 1

                if tile_index - last_report >= report_interval:
                    elapsed = time.time() - t0
                    pct = tile_index / total_tiles * 100
                    rate = tile_index / elapsed if elapsed > 0 else 0
                    eta = (total_tiles - tile_index) / rate if rate > 0 else 0
                    print(f"  {tile_index:,}/{total_tiles:,} tiles ({pct:.1f}%) — "
                          f"{rate:,.0f} tiles/s, ETA {eta:.0f}s")
                    last_report = tile_index

    elapsed = time.time() - t0
    print(f"  Done: {tile_index:,} tiles in {elapsed:.1f}s ({tile_index/elapsed:,.0f} tiles/s)")

    # Write binary
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    bin_path = os.path.join(OUTPUT_DIR, "climate.bin")
    with open(bin_path, "wb") as f:
        f.write(climate_bytes)
    print(f"  Written: {bin_path} ({len(climate_bytes):,} bytes)")

    # Summary
    summary = {
        "source": os.path.basename(raster_path),
        "total_tiles": total_tiles,
        "climate_types": {},
    }
    for code in sorted(count_by_code.keys()):
        name = CLIMATE_NAMES.get(code, f"Unknown_{code}")
        group = name[0] if name[0] in CLIMATE_GROUPS else "?"
        group_name = CLIMATE_GROUPS.get(group, "Unknown")
        summary["climate_types"][str(code)] = {
            "code": name,
            "group": group_name,
            "count": count_by_code[code],
            "pct": round(count_by_code[code] / total_tiles * 100, 2),
        }
        print(f"  {name}: {count_by_code[code]:,} ({count_by_code[code]/total_tiles*100:.1f}%)")

    summary_path = os.path.join(OUTPUT_DIR, "climate_summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Written: {summary_path}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate Köppen climate mask")
    parser.add_argument("--raster", type=str, default=DEFAULT_RASTER,
                        help=f"Path to Köppen GeoTIFF (default: {DEFAULT_RASTER})")
    args = parser.parse_args()

    if not os.path.exists(args.raster):
        print(f"ERROR: Köppen raster not found at {args.raster}")
        print(f"\nDownload from: https://globe.umbc.edu/apps/ckan/organization/koeppen-geiger.html")
        print(f"Place the .tif file in: {RASTER_DIR}/")
        print(f"Or specify with: --raster /path/to/koppen.tif")
        sys.exit(1)

    print("=" * 60)
    print("HT2 — Köppen Climate Classification Pipeline")
    print("=" * 60)

    print("\n[1/2] Computing band structure...")
    band_segs, total_tiles, cell_segs_per_band = compute_band_structure()
    print(f"  Total tiles (denser frame): {total_tiles:,}")

    print(f"\n[2/2] Classifying {total_tiles:,} tiles...")
    generate_climate(args.raster, cell_segs_per_band, total_tiles)

    print(f"\nDone. Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
