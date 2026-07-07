#!/usr/bin/env python3
"""
grid_registry.py — Generate Earth tile registry at any resolution.

Computes the spherical grid structure using the same math as
SphericalGridGenerator.compute_band_structure() in Godot.
Outputs tile IDs, centers, and bounding boxes.

Usage:
    python grid_registry.py --resolution 10     # 10km at equator
    python grid_registry.py --resolution 50     # 50km (matching Stella Nostra)
    python grid_registry.py --resolution 100    # 100km (coarse)
"""

import argparse
import json
import math
import os
import sys

EARTH_RADIUS_KM = 6371.0


def compute_band_structure(radius_km: float, base_cell_km: float) -> dict:
    """Replicates SphericalGridGenerator.compute_band_structure() in Python."""
    radius_m = radius_km * 1000.0
    cell_m = base_cell_km * 1000.0
    merge_threshold_m = base_cell_km * 0.5 * 1000.0

    equator_circumference = 2.0 * math.pi * radius_m
    raw_segs = max(int(round(equator_circumference / cell_m)), 16)
    equator_segs = ((raw_segs + 8) // 16) * 16
    equator_segs = max(equator_segs, 16)

    bands = max(int(round(math.pi * 0.5 * radius_m / cell_m)), 4)
    total_bands = bands * 2
    band_segs = [0] * (total_bands + 1)
    band_segs[bands] = equator_segs

    # Northward
    current_segs = equator_segs
    for b in range(bands + 1, total_bands + 1):
        lat = math.pi * 0.5 * (b - bands) / bands
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > 4 and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Southward
    current_segs = equator_segs
    for b in range(bands - 1, -1, -1):
        lat = math.pi * 0.5 * (bands - b) / bands
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > 4 and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Clamp poles
    for i in range(total_bands + 1):
        if band_segs[i] < 4:
            band_segs[i] = 4

    total_tiles = sum(band_segs)

    return {
        "radius_km": radius_km,
        "base_cell_km": base_cell_km,
        "total_bands": total_bands,
        "equator_segs": equator_segs,
        "band_segs": band_segs,
        "total_tiles": total_tiles,
        "merge_chain": sorted(set(band_segs), reverse=True),
    }


def generate_tile_registry(band_structure: dict) -> list:
    """Generate tile metadata for every cell."""
    radius_m = band_structure["radius_km"] * 1000.0
    total_bands = band_structure["total_bands"]
    band_segs = band_structure["band_segs"]
    tiles = []

    for band in range(total_bands):
        segs = band_segs[band]
        if segs <= 0:
            continue

        lat_center = -math.pi * 0.5 + math.pi * (band + 0.5) / total_bands
        lat_deg = math.degrees(lat_center)

        # Determine sparser segment count for this band
        next_segs = band_segs[band + 1] if band + 1 < len(band_segs) else segs
        sparser_segs = min(segs, next_segs)
        ratio = max(segs // sparser_segs, 1)

        for s in range(segs):
            sparser_s = s // ratio
            tile_id = f"B{band}_{sparser_s}"

            lon_center = 2.0 * math.pi * (s + 0.5) / segs
            lon_deg = math.degrees(lon_center) - 180.0  # Convert to -180..180

            # Bounding box
            bot_lat = -math.pi * 0.5 + math.pi * band / total_bands
            top_lat = -math.pi * 0.5 + math.pi * (band + 1) / total_bands
            lon_start = 2.0 * math.pi * s / segs
            lon_end = 2.0 * math.pi * (s + 1) / segs

            # Cell width at this latitude
            ring_radius = radius_m * math.cos(lat_center)
            cell_width_km = (2.0 * math.pi * ring_radius / segs) / 1000.0
            cell_height_km = abs(top_lat - bot_lat) * radius_m / 1000.0

            tiles.append({
                "id": tile_id,
                "band": band,
                "segment": sparser_s,
                "grid_segment": s,
                "lat": round(lat_deg, 6),
                "lon": round(lon_deg, 6),
                "bbox": {
                    "lat_min": round(math.degrees(bot_lat), 6),
                    "lat_max": round(math.degrees(top_lat), 6),
                    "lon_min": round(math.degrees(lon_start) - 180.0, 6),
                    "lon_max": round(math.degrees(lon_end) - 180.0, 6),
                },
                "cell_width_km": round(cell_width_km, 2),
                "cell_height_km": round(cell_height_km, 2),
            })

    return tiles


def main():
    parser = argparse.ArgumentParser(description="Generate Earth tile registry")
    parser.add_argument(
        "--resolution", "-r",
        type=float,
        default=10.0,
        help="Base cell size in km at equator (default: 10)",
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=None,
        help="Output directory (default: data/output/grid_{resolution}km/)",
    )
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="Only print summary, don't generate full registry",
    )
    args = parser.parse_args()

    print(f"Earth grid at {args.resolution:.0f}km resolution")
    print(f"Earth radius: {EARTH_RADIUS_KM} km")
    print()

    band_struct = compute_band_structure(EARTH_RADIUS_KM, args.resolution)

    print(f"Total bands: {band_struct['total_bands']}")
    print(f"Equator segments: {band_struct['equator_segs']}")
    print(f"Total tiles: {band_struct['total_tiles']:,}")
    print(f"Merge chain: {band_struct['merge_chain']}")
    print()

    # Memory estimates
    tile_count = band_struct['total_tiles']
    print(f"Memory estimates:")
    print(f"  Tile IDs (strings, JSON keys): ~{tile_count * 12 / 1024 / 1024:.1f} MB")
    print(f"  Full tile registry JSON: ~{tile_count * 120 / 1024 / 1024:.1f} MB")
    print(f"  Tile colors (palette indices, binary): ~{tile_count / 1024 / 1024:.1f} MB")
    print()

    if args.summary_only:
        return

    # Determine output path
    if args.output:
        out_dir = args.output
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        out_dir = os.path.join(script_dir, "..", "output", f"grid_{args.resolution:.0f}km")

    os.makedirs(out_dir, exist_ok=True)

    # Save band structure
    band_segs_dict = {str(i): s for i, s in enumerate(band_struct["band_segs"])}
    bs_path = os.path.join(out_dir, "band_segments.json")
    with open(bs_path, "w") as f:
        json.dump(band_segs_dict, f, separators=(",", ":"))
    print(f"Saved: {bs_path}")

    # Save summary
    summary_path = os.path.join(out_dir, "grid_summary.json")
    summary = {k: v for k, v in band_struct.items() if k != "band_segs"}
    summary["band_segments_file"] = "band_segments.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Saved: {summary_path}")

    # Generate full tile registry
    print(f"Generating {tile_count:,} tile entries...")
    tiles = generate_tile_registry(band_struct)
    registry_path = os.path.join(out_dir, "tile_registry.json")
    with open(registry_path, "w") as f:
        json.dump(tiles, f)
    print(f"Saved: {registry_path} ({len(tiles):,} tiles)")
    print()
    print("Done.")


if __name__ == "__main__":
    main()
