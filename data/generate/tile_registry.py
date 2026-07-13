#!/usr/bin/env python3
"""
tile_registry.py — Phase A: Generate Earth tile registry at configurable resolution.

Replicates SphericalGridGenerator's band/segment math in pure Python.
Outputs tile_registry.json with tile IDs, center lat/lon, and bounding boxes.

Usage:
  python data/generate/tile_registry.py --resolution 10    # 10km (HT production)
  python data/generate/tile_registry.py --resolution 10 --summary-only   # counts only
  python data/generate/tile_registry.py --resolution 50    # 50km (match SN)
  python data/generate/tile_registry.py --resolution 100   # 100km (fast testing)
"""

import json, math, os, argparse

# ── Constants (matching SphericalGridGenerator.gd) ──
RADIUS_KM = 6371.0
MERGE_FACTOR = 0.5          # merge when cell width < base * 0.5
MIN_POLE_SEGS = 4
POLE_CLAMP_SEGS = 4

# ── Paths ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))  # up from data/generate/ to project root
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "output")


def compute_band_segments(radius_km: float, base_cell_km: float) -> tuple[int, list[int]]:
    """Returns (total_bands, band_segs) where band_segs[i] = segment count at band i."""
    radius_m = radius_km * 1000.0
    cell_m = base_cell_km * 1000.0
    merge_threshold_m = base_cell_km * MERGE_FACTOR * 1000.0

    equator_circumference = 2 * math.pi * radius_m
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
        cell_width = 2 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Southward
    current_segs = equator_segs
    for b in range(bands - 1, -1, -1):
        lat = math.pi * 0.5 * (bands - b) / bands
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    # Post-clamp
    for i in range(total_bands + 1):
        if band_segs[i] < POLE_CLAMP_SEGS:
            band_segs[i] = POLE_CLAMP_SEGS

    return total_bands, band_segs


def cell_corners(band_segs: list[int], total_bands: int, transition: int, sparser_seg: int, radius_km: float):
    """Returns list of (lat_deg, lon_deg) corners for a cell."""
    segs_a = band_segs[transition]
    segs_b = band_segs[transition + 1]

    if segs_a >= segs_b:
        sparser_idx = transition + 1
        denser_idx = transition
        sparser_segs_val = segs_b
        denser_segs_val = segs_a
    else:
        sparser_idx = transition
        denser_idx = transition + 1
        sparser_segs_val = segs_a
        denser_segs_val = segs_b

    ratio = denser_segs_val // sparser_segs_val

    def band_lat(band_idx: int) -> float:
        return -math.pi * 0.5 + math.pi * band_idx / total_bands

    radius_m = radius_km * 1000.0
    lat_sparse = band_lat(sparser_idx)
    lat_dense = band_lat(denser_idx)
    r_sparse = radius_m * math.cos(lat_sparse)
    r_dense = radius_m * math.cos(lat_dense)
    y_sparse = radius_m * math.sin(lat_sparse)
    y_dense = radius_m * math.sin(lat_dense)

    def to_latlon(x, y, z):
        r = math.sqrt(x * x + y * y + z * z)
        lat = math.asin(y / r) if r > 0 else 0.0
        lon = math.atan2(z, x)
        return math.degrees(lat), math.degrees(lon)

    corners = []
    # Vertex 1: sparser band, segment s
    lon_s = 2 * math.pi * sparser_seg / sparser_segs_val
    corners.append(to_latlon(r_sparse * math.cos(lon_s), y_sparse, r_sparse * math.sin(lon_s)))

    # Vertex 2: sparser band, segment s+1
    lon_s_next = 2 * math.pi * (sparser_seg + 1) / sparser_segs_val
    corners.append(to_latlon(r_sparse * math.cos(lon_s_next), y_sparse, r_sparse * math.sin(lon_s_next)))

    # Vertices 3..N: denser band (reversed)
    dense_end = (sparser_seg + 1) * ratio
    dense_start = sparser_seg * ratio
    for d in range(dense_end, dense_start - 1, -1):
        lon_d = 2 * math.pi * d / denser_segs_val
        corners.append(to_latlon(r_dense * math.cos(lon_d), y_dense, r_dense * math.sin(lon_d)))

    return corners


def generate_registry(base_cell_km: float) -> dict:
    total_bands, band_segs = compute_band_segments(RADIUS_KM, base_cell_km)
    registry = {}
    tile_count = 0

    for transition in range(total_bands):
        segs_a = band_segs[transition]
        segs_b = band_segs[transition + 1]
        if segs_a <= 0 or segs_b <= 0:
            continue

        sparser_segs = segs_b if segs_a >= segs_b else segs_a

        for s in range(sparser_segs):
            corners = cell_corners(band_segs, total_bands, transition, s, RADIUS_KM)

            # Grid-space segment: mirror baked in
            grid_seg = sparser_segs - 1 - s

            # Center = circular mean of corners
            lats = [c[0] for c in corners]
            lons = [c[1] for c in corners]

            avg_sin = sum(math.sin(math.radians(lon)) for lon in lons) / len(lons)
            avg_cos = sum(math.cos(math.radians(lon)) for lon in lons) / len(lons)
            center_lon = math.degrees(math.atan2(avg_sin, avg_cos))
            center_lat = sum(lats) / len(lats)

            lat_min = min(lats)
            lat_max = max(lats)
            lon_min = min(lons)
            lon_max = max(lons)

            tile_id = f"B{transition}_{grid_seg}"
            registry[tile_id] = {
                "band": transition,
                "segment": grid_seg,
                "lat": round(center_lat, 6),
                "lon": round(center_lon, 6),
                "bbox": {
                    "lat_min": round(lat_min, 6),
                    "lat_max": round(lat_max, 6),
                    "lon_min": round(lon_min, 6),
                    "lon_max": round(lon_max, 6),
                },
            }
            tile_count += 1

    return registry, tile_count, total_bands, band_segs


def main():
    parser = argparse.ArgumentParser(description="Generate Earth tile registry at configurable resolution")
    parser.add_argument("--resolution", type=int, default=10, help="Base cell size in km (default: 10)")
    parser.add_argument("--summary-only", action="store_true", help="Print counts only, don't generate file")
    args = parser.parse_args()

    print(f"Tile registry at {args.resolution}km resolution")
    print(f"  Earth radius: {RADIUS_KM} km")
    print(f"  Merge factor: {MERGE_FACTOR} (merge when cell < {args.resolution * MERGE_FACTOR}km)")
    print()

    total_bands, band_segs = compute_band_segments(RADIUS_KM, args.resolution)
    tile_count = sum(1 for i in range(total_bands)
                     if band_segs[i] > 0 and band_segs[i + 1] > 0
                     for _ in range(min(band_segs[i], band_segs[i + 1])))

    equator_segs = band_segs[total_bands // 2]
    merge_chain = [equator_segs]
    while merge_chain[-1] > 4:
        merge_chain.append(merge_chain[-1] // 2)
    merge_chain_str = " → ".join(str(s) for s in merge_chain)

    print(f"  Total bands: {total_bands} ({total_bands // 2} per hemisphere)")
    print(f"  Equator segments: {equator_segs}")
    print(f"  Merge chain: {merge_chain_str}")
    print(f"  Total tiles: {tile_count:,}")
    print(f"  ~{tile_count * 200 / 1_000_000:.0f} MB estimated JSON size")

    if args.summary_only:
        return

    # Full generation
    grid_dir = os.path.join(OUTPUT_DIR, f"grid_{args.resolution}km")
    os.makedirs(grid_dir, exist_ok=True)
    out_path = os.path.join(grid_dir, "tile_registry.json")

    registry, count, _, _ = generate_registry(args.resolution)

    with open(out_path, "w") as f:
        json.dump(registry, f, separators=(",", ":"))

    file_size_mb = os.path.getsize(out_path) / (1024 * 1024)
    print(f"\nWritten: {out_path}")
    print(f"File size: {file_size_mb:.1f} MB")
    print(f"Tiles: {count:,}")


if __name__ == "__main__":
    main()
