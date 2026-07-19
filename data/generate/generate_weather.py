#!/usr/bin/env python3
"""
generate_weather.py — Sample monthly climate data for every tile. BUILD-TIME ONLY.

Uses WorldClim 2.1 monthly data (30 arc-second, ~1km at equator).
4 variables × 12 months = 48 rasters → weather.bin (~624 MB).

Variables:
  tavg  — average temperature (°C × 10, int16)
  prec  — precipitation (mm, int16)
  srad  — solar radiation (kJ/m²/day, int16)
  wind  — wind speed (m/s × 10, int16)

Storage per tile: 4 vars × 12 months × 2 bytes (int16) = 96 bytes
Total: ~6.5M × 96 = ~624 MB

Data source: https://www.worldclim.org/data/worldclim21.html
Files needed (48 GeoTIFFs, put in data/raster/worldclim/):
  wc2.1_30s_tavg_01.tif ... wc2.1_30s_tavg_12.tif
  wc2.1_30s_prec_01.tif ... wc2.1_30s_prec_12.tif
  wc2.1_30s_srad_01.tif ... wc2.1_30s_srad_12.tif
  wc2.1_30s_wind_01.tif ... wc2.1_30s_wind_12.tif

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

# Variable definitions: (prefix, units, description)
VARIABLES = [
    ("tavg", "°C × 10", "Average temperature"),
    ("prec", "mm",      "Precipitation"),
    ("srad", "kJ/m²/d", "Solar radiation"),
    ("wind", "m/s × 10","Wind speed"),
]

BYTES_PER_VAR_MONTH = 2  # int16
MONTHS = 12
NVARS = len(VARIABLES)
STRIDE = NVARS * MONTHS * BYTES_PER_VAR_MONTH  # 96 bytes per cell


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
    lon = 2.0 * math.pi * seg / segs
    lon_deg = math.degrees(lon)
    if lon_deg > 180.0:
        lon_deg -= 360.0
    if lon_deg >= 179.999:
        lon_deg = 179.999
    elif lon_deg <= -179.999:
        lon_deg = -179.999
    return math.degrees(lat), lon_deg


def generate_weather(raster_dir: str, cell_segs_per_band: list, total_tiles: int):
    """Sample all 48 monthly rasters at each tile center → weather.bin."""
    print("Opening monthly rasters...")
    
    # Structure: data[v][m] = 2D numpy array
    all_data = []  # [var][month] = numpy array
    ref_src = None
    
    for v_idx, (prefix, units, desc) in enumerate(VARIABLES):
        var_rasters = []
        print(f"  {prefix} ({desc}):")
        for m in range(1, 13):
            path = os.path.join(raster_dir, f"wc2.1_30s_{prefix}_{m:02d}.tif")
            if not os.path.exists(path):
                print(f"    ERROR: {path} not found")
                sys.exit(1)
            src = rasterio.open(path)
            if v_idx == 0 and m == 1:
                ref_src = src  # reference for coordinate transforms
            data = src.read(1)
            var_rasters.append(data)
            src.close()
        all_data.append(var_rasters)
        print(f"    loaded 12 rasters, shape {var_rasters[0].shape}")
    
    print(f"  Total: {NVARS} vars × {MONTHS} months = {NVARS*MONTHS} rasters")
    print(f"  Stride: {STRIDE} bytes/cell, total output: ~{total_tiles * STRIDE / 1024 / 1024:.0f} MB")
    
    # Pre-allocate output buffer
    total_bytes = total_tiles * STRIDE
    weather_bytes = bytearray(total_bytes)
    
    t0 = time.time()
    tile_index = 0
    last_report = 0
    report_interval = 250000
    
    for band in range(TOTAL_BANDS):
        segs = cell_segs_per_band[band]
        if segs <= 0:
            continue
        
        for seg in range(segs):
            lat, lon = tile_to_lat_lon(band, seg, cell_segs_per_band)
            
            # All rasters share the same grid — use ref_src for coordinate transform
            row, col = ref_src.index(lon, lat)
            row = max(0, min(row, all_data[0][0].shape[0] - 1))
            col = max(0, min(col, all_data[0][0].shape[1] - 1))
            
            offset = tile_index * STRIDE
            
            for v_idx in range(NVARS):
                for m in range(12):
                    raw_val = all_data[v_idx][m][row, col]
                    # Handle nodata (float rasters use large negative values)
                    if isinstance(raw_val, (np.floating, float)):
                        if raw_val < -1e30:
                            raw_val = 0.0
                    val = int(raw_val)
                    # Clamp to int16 range for struct packing
                    val = max(-32768, min(32767, val))
                    byte_pos = offset + (v_idx * MONTHS + m) * BYTES_PER_VAR_MONTH
                    struct.pack_into('<h', weather_bytes, byte_pos, val)
            
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
    weather_path = os.path.join(OUTPUT_DIR, "weather.bin")
    with open(weather_path, "wb") as f:
        f.write(weather_bytes)
    print(f"  Written: {weather_path} ({len(weather_bytes):,} bytes)")
    
    # Summary
    summary = {
        "source": "WorldClim 2.1 monthly (1970-2000)",
        "raster_dir": raster_dir,
        "total_tiles": total_tiles,
        "nvars": NVARS,
        "nmonths": MONTHS,
        "stride_bytes": STRIDE,
        "variables": {},
    }
    for v_idx, (prefix, units, desc) in enumerate(VARIABLES):
        summary["variables"][prefix] = {
            "index": v_idx,
            "offset_bytes": v_idx * MONTHS * BYTES_PER_VAR_MONTH,
            "units": units,
            "description": desc,
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
        print(f"Place all 48 monthly GeoTIFFs in: {RASTER_DIR}/")
        sys.exit(1)
    
    print("=" * 60)
    print("HT2 — Weather Data Pipeline (WorldClim 2.1, 4 variables)")
    print("=" * 60)
    
    print("\n[1/2] Computing band structure...")
    band_segs, total_tiles, cell_segs_per_band = compute_band_structure()
    print(f"  Total tiles: {total_tiles:,}")
    print(f"  Output size: ~{total_tiles * STRIDE / 1024 / 1024:.0f} MB")
    
    print(f"\n[2/2] Sampling {total_tiles:,} tiles from {NVARS * MONTHS} rasters...")
    generate_weather(args.raster_dir, cell_segs_per_band, total_tiles)
    
    print(f"\nDone. Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
