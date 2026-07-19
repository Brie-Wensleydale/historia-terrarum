#!/usr/bin/env python3
"""
generate_terrain.py — Classify every tile with terrain type from global elevation. BUILD-TIME ONLY.

Uses GEBCO 2024 global bathymetry/topography (15 arc-second, ~450m at equator).
Sample elevation at each tile center → classify by elevation threshold → terrain.bin (~6.5 MB).
Also computes slope (max gradient within cell) → slope.bin (~6.5 MB).

Data source: https://www.bodc.ac.uk/data/open_download/gebco/gebco_2024/zip/
File: gebco_2024.tif (put in data/raster/, ~3 GB download, ~25 GB uncompressed)

Usage:  python data/generate/generate_terrain.py
        python data/generate/generate_terrain.py --raster /path/to/gebco.tif --fast  # center-pixel only
"""

import json
import math
import os
import struct
import sys
import time

import numpy as np
try:
    import rasterio
except ImportError:
    print("ERROR: rasterio not installed. Run: pip install rasterio numpy")
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

DEFAULT_RASTER = os.path.join(RASTER_DIR, "gebco_2024.tif")
DEFAULT_NC = os.path.join(RASTER_DIR, "GEBCO_2024_CF.nc")

# ── Terrain Classification ──
# Elevation thresholds in meters
TERRAIN_TYPES = [
    # (min_elev, max_elev, name, color_rgb)
    (-99999,  -4000, "deep_ocean",        (5,   25,  90)),
    (-4000,   -1000, "ocean",             (13,  50,  140)),
    (-1000,    -200, "shallow_ocean",     (25,  90,  165)),
    (-200,        0, "continental_shelf", (40,  115, 180)),
    (0,         20, "coastal",            (215, 200, 100)),
    (20,       200, "lowland",            (75,  180, 75)),
    (200,      500, "upland",             (100, 150, 65)),
    (500,     1000, "highland",           (140, 125, 50)),
    (1000,    2000, "mountain",           (115, 90,  50)),
    (2000,    4000, "high_mountain",      (150, 130, 115)),
    (4000,   99999, "extreme_mountain",   (230, 230, 230)),
]

# Slope classification in degrees
SLOPE_TYPES = [
    (0,  2,   "flat"),
    (2,  5,   "gentle"),
    (5,  15,  "moderate"),
    (15, 30,  "steep"),
    (30, 90,  "cliff"),
]


def classify_elevation(elev_m: float) -> int:
    """Return terrain type index (0-10) based on elevation in meters."""
    for i, (lo, hi, _, _) in enumerate(TERRAIN_TYPES):
        if elev_m >= lo and elev_m < hi:
            return i
    return 0


def classify_slope(slope_deg: float) -> int:
    """Return slope type index (0-4) based on slope in degrees."""
    for i, (lo, hi, _) in enumerate(SLOPE_TYPES):
        if slope_deg >= lo and slope_deg < hi:
            return i
    return 4


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
    """Compute tile center lat/lon in degrees."""
    lat = -math.pi * 0.5 + math.pi * (band + 0.5) / TOTAL_BANDS
    segs = cell_segs_per_band[band]
    if segs <= 0:
        segs = 1
    lon = 2.0 * math.pi * seg / segs - math.pi
    return math.degrees(lat), math.degrees(lon)


def generate_terrain(raster_path: str, cell_segs_per_band: list, total_tiles: int, fast_mode: bool = True):
    """Sample elevation at each tile center, classify terrain + slope."""
    print(f"Opening raster: {raster_path}")
    t0 = time.time()

    # Handle NetCDF: rasterio can open .nc but may need subdataset selection
    open_path = raster_path
    is_nc = raster_path.lower().endswith('.nc')
    if is_nc:
        # GEBCO NetCDF has subdatasets; use the elevation one
        with rasterio.open(raster_path) as probe:
            subs = probe.subdatasets
        if subs:
            # Find the elevation subdataset
            for s in subs:
                if 'elevation' in s.lower() or 'height' in s.lower():
                    open_path = s
                    break
            if open_path == raster_path:
                open_path = subs[0]  # fallback: first subdataset
            print(f"  NetCDF subdataset: {open_path}")

    with rasterio.open(open_path) as src:
        print(f"  CRS: {src.crs}")
        print(f"  Bounds: {src.bounds}")
        print(f"  Shape: {src.height} × {src.width}")

        band_data = src.read(1)
        # GEBCO uses NaN or large negative for no-data over land in some versions
        band_data = np.where(band_data < -90000, np.nan, band_data)

        terrain_bytes = bytearray(total_tiles)
        slope_bytes = bytearray(total_tiles)
        count_by_type = {}
        count_by_slope = {}

        tile_index = 0
        last_report = 0
        report_interval = 500000

        cell_lat_span_deg = 180.0 / TOTAL_BANDS  # ~0.088° per band
        cell_lon_span_deg_base = 360.0 / EQUATOR_SEGS  # ~0.088° at equator

        for band in range(TOTAL_BANDS):
            segs = cell_segs_per_band[band]
            if segs <= 0:
                continue

            cell_lon_span_deg = 360.0 / segs if segs > 0 else cell_lon_span_deg_base

            for seg in range(segs):
                lat, lon = tile_to_lat_lon(band, seg, cell_segs_per_band)

                # Convert to raster pixel
                row, col = src.index(lon, lat)
                row = max(0, min(row, band_data.shape[0] - 1))
                col = max(0, min(col, band_data.shape[1] - 1))

                if fast_mode:
                    # Single-pixel sample (fast, ~10 min for 6.5M tiles)
                    elev = float(band_data[row, col])
                    if np.isnan(elev):
                        elev = 0.0
                    slope = 0.0  # skip slope in fast mode
                else:
                    # Windowed median sample (slow, ~1-2 hours)
                    half_win_rows = max(1, int(cell_lat_span_deg / 2.0 / 0.0041667))  # ~10 pixels at 15 arc-sec
                    half_win_cols = max(1, int(cell_lon_span_deg / 2.0 / 0.0041667))
                    r_start = max(0, row - half_win_rows)
                    r_end = min(band_data.shape[0], row + half_win_rows + 1)
                    c_start = max(0, col - half_win_cols)
                    c_end = min(band_data.shape[1], col + half_win_cols + 1)
                    window = band_data[r_start:r_end, c_start:c_end]
                    window_valid = window[~np.isnan(window)]
                    if len(window_valid) > 0:
                        elev = float(np.median(window_valid))
                        # Slope: max gradient in window
                        gy, gx = np.gradient(window_valid.reshape(r_end-r_start, c_end-c_start))
                        slope_rad = np.arctan(np.sqrt(gx**2 + gy**2))
                        slope = float(np.degrees(np.max(slope_rad))) if slope_rad.size > 0 else 0.0
                    else:
                        elev = 0.0
                        slope = 0.0

                terrain_code = classify_elevation(elev)
                slope_code = classify_slope(slope) if not fast_mode else 0

                terrain_bytes[tile_index] = terrain_code
                slope_bytes[tile_index] = slope_code
                count_by_type[terrain_code] = count_by_type.get(terrain_code, 0) + 1
                count_by_slope[slope_code] = count_by_slope.get(slope_code, 0) + 1
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

    # Write binaries
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    terrain_path = os.path.join(OUTPUT_DIR, "terrain.bin")
    with open(terrain_path, "wb") as f:
        f.write(terrain_bytes)
    print(f"  Written: {terrain_path} ({len(terrain_bytes):,} bytes)")

    slope_path = os.path.join(OUTPUT_DIR, "slope.bin")
    with open(slope_path, "wb") as f:
        f.write(slope_bytes)
    print(f"  Written: {slope_path} ({len(slope_bytes):,} bytes)")

    # Summary
    summary = {
        "source": os.path.basename(raster_path),
        "total_tiles": total_tiles,
        "mode": "fast" if fast_mode else "windowed_median",
        "terrain_types": {},
        "slope_types": {},
    }
    for code in sorted(count_by_type.keys()):
        _, _, name, _ = TERRAIN_TYPES[code]
        summary["terrain_types"][name] = {
            "code": code, "count": count_by_type[code],
            "pct": round(count_by_type[code] / total_tiles * 100, 2),
        }
        print(f"  {name}: {count_by_type[code]:,} ({count_by_type[code]/total_tiles*100:.1f}%)")

    summary_path = os.path.join(OUTPUT_DIR, "terrain_summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Written: {summary_path}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate terrain classification from GEBCO")
    parser.add_argument("--raster", type=str, default=DEFAULT_RASTER,
                        help=f"Path to GEBCO GeoTIFF (default: {DEFAULT_RASTER})")
    parser.add_argument("--full", action="store_true",
                        help="Full windowed median mode (slow, 1-2 hours)")
    args = parser.parse_args()

    # Resolve raster: try .nc first (GEBCO default format), then .tif
    raster_path = args.raster
    if not os.path.exists(raster_path) and os.path.exists(DEFAULT_NC):
        raster_path = DEFAULT_NC
        print("Using NetCDF format: %s" % raster_path)
    elif not os.path.exists(raster_path) and os.path.exists(DEFAULT_RASTER):
        raster_path = DEFAULT_RASTER

    if not os.path.exists(raster_path):
        print(f"ERROR: GEBCO raster not found at {args.raster}")
        print(f"  Also checked: {DEFAULT_NC}, {DEFAULT_RASTER}")
        print(f"\nDownload from: https://www.bodc.ac.uk/data/open_download/gebco/gebco_2024/zip/")
        print(f"Place the .nc or .tif file in: {RASTER_DIR}/")
        print(f"Or specify with: --raster /path/to/gebco_file")
        sys.exit(1)

    print("=" * 60)
    print("HT2 — Terrain Classification Pipeline")
    print("=" * 60)

    print("\n[1/2] Computing band structure...")
    band_segs, total_tiles, cell_segs_per_band = compute_band_structure()
    print(f"  Total tiles: {total_tiles:,}")
    mode = "fast (center-pixel)" if not args.full else "full (windowed median)"
    print(f"  Mode: {mode}")

    print(f"\n[2/2] Classifying {total_tiles:,} tiles...")
    generate_terrain(args.raster, cell_segs_per_band, total_tiles, fast_mode=not args.full)

    print(f"\nDone. Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
