#!/usr/bin/env python3
"""
generate_weather.py — Sample monthly temperature & precipitation for every tile. BUILD-TIME ONLY.

Uses WorldClim 2.1 monthly climate data (30 arc-second, ~1km at equator).
12 monthly temperature rasters + 12 monthly precipitation rasters → weather.bin (~312 MB).

Data source: https://www.worldclim.org/data/worldclim21.html
Files needed (24 GeoTIFFs, put in data/raster/worldclim/):
  wc2.1_30s_tavg_01.tif ... wc2.1_30s_tavg_12.tif  (monthly average temp, °C × 10)
  wc2.1_30s_prec_01.tif ... wc2.1_30s_prec_12.tif  (monthly precipitation, mm)

Storage per tile: 12 × int16 (temp) + 12 × int16 (precip) = 48 bytes
Total: ~6.5M × 48 = ~312 MB

Usage:  python data/generate/generate_weather.py
        python data/generate/generate_weather.py --raster-dir /path/to/worldclim/
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
RASTER_DIR = os.path.join(PROJECT_ROOT, "data", "raster", "worldclim")
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "output", "grid_10km_ht2")

MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


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
    lon = 2.0 * math.pi * seg / segs  # 0 to 2π, seg=0 at prime meridian
    lon_deg = math.degrees(lon)
    if lon_deg > 180.0:
        lon_deg -= 360.0
    if lon_deg >= 179.999:
        lon_deg = 179.999
    elif lon_deg <= -179.999:
        lon_deg = -179.999
    return math.degrees(lat), lon_deg


def generate_weather(raster_dir: str, cell_segs_per_band: list, total_tiles: int):
    """Sample all 24 monthly rasters at each tile center → weather.bin."""
    # Open all 24 rasters
    temp_srcs = []
    prec_srcs = []
    temp_data = []
    prec_data = []

    print("Opening monthly rasters...")
    for m in range(1, 13):
        temp_path = os.path.join(raster_dir, f"wc2.1_30s_tavg_{m:02d}.tif")
        prec_path = os.path.join(raster_dir, f"wc2.1_30s_prec_{m:02d}.tif")

        if not os.path.exists(temp_path):
            print(f"ERROR: {temp_path} not found")
            sys.exit(1)
        if not os.path.exists(prec_path):
            print(f"ERROR: {prec_path} not found")
            sys.exit(1)

        ts = rasterio.open(temp_path)
        ps = rasterio.open(prec_path)
        temp_srcs.append(ts)
        prec_srcs.append(ps)
        temp_data.append(ts.read(1))
        prec_data.append(ps.read(1))
        print(f"  Month {m:2d}: temp {temp_data[-1].shape}, prec {prec_data[-1].shape}")

    # Precompute row/col for every tile (too many to look up per-tile fast?)
    # Actually, src.index() is fast. Let's just sample per tile.
    STRIDE = 12 * 2  # 12 months × 2 bytes (int16)
    total_bytes = total_tiles * STRIDE
    weather_bytes = bytearray(total_bytes)

    t0 = time.time()
    tile_index = 0
    last_report = 0
    report_interval = 500000

    for band in range(TOTAL_BANDS):
        segs = cell_segs_per_band[band]
        if segs <= 0:
            continue

        for seg in range(segs):
            lat, lon = tile_to_lat_lon(band, seg, cell_segs_per_band)

            # Sample all 12 months from the first raster's geotransform
            # (all WorldClim rasters share the same grid)
            row, col = temp_srcs[0].index(lon, lat)
            row = max(0, min(row, temp_data[0].shape[0] - 1))
            col = max(0, min(col, temp_data[0].shape[1] - 1))

            offset = tile_index * STRIDE

            # Write temperature values (int16, °C × 10)
            for m in range(12):
                val = int(temp_data[m][row, col])
                struct.pack_into('<h', weather_bytes, offset + m * 2, val)

            # Write precipitation values (int16, mm)
            for m in range(12):
                val = int(prec_data[m][row, col])
                struct.pack_into('<h', weather_bytes, offset + 24 + m * 2, val)

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

    # Clean up
    for ts in temp_srcs:
        ts.close()
    for ps in prec_srcs:
        ps.close()

    # Write binary
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    weather_path = os.path.join(OUTPUT_DIR, "weather.bin")
    with open(weather_path, "wb") as f:
        f.write(weather_bytes)
    print(f"  Written: {weather_path} ({len(weather_bytes):,} bytes)")

    # Summary
    summary = {
        "source": "WorldClim 2.1 monthly (1970-2000)",
        "raster_dir": raster_dir,
        "total_tiles": total_tiles,
        "format": {
            "stride_bytes": STRIDE,
            "temp_offset": 0,
            "prec_offset": 24,
            "temp_units": "°C × 10 (int16)",
            "prec_units": "mm (int16)",
        },
    }
    summary_path = os.path.join(OUTPUT_DIR, "weather_summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Written: {summary_path}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate weather data from WorldClim")
    parser.add_argument("--raster-dir", type=str, default=RASTER_DIR,
                        help=f"Directory with WorldClim monthly GeoTIFFs (default: {RASTER_DIR})")
    args = parser.parse_args()

    # Check first file exists
    test_path = os.path.join(args.raster_dir, "wc2.1_30s_tavg_01.tif")
    if not os.path.exists(test_path):
        print(f"ERROR: WorldClim rasters not found in {args.raster_dir}")
        print(f"\nDownload from: https://www.worldclim.org/data/worldclim21.html")
        print(f"Download all 24 monthly GeoTIFFs (12 tavg + 12 prec) and place in:")
        print(f"  {RASTER_DIR}/")
        print(f"Or specify with: --raster-dir /path/to/worldclim/")
        sys.exit(1)

    print("=" * 60)
    print("HT2 — Weather Data Pipeline (WorldClim 2.1)")
    print("=" * 60)

    print("\n[1/2] Computing band structure...")
    band_segs, total_tiles, cell_segs_per_band = compute_band_structure()
    print(f"  Total tiles: {total_tiles:,}")
    print(f"  Output size: ~{total_tiles * 48 / 1024 / 1024:.0f} MB")

    print(f"\n[2/2] Sampling {total_tiles:,} tiles...")
    generate_weather(args.raster_dir, cell_segs_per_band, total_tiles)

    print(f"\nDone. Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
