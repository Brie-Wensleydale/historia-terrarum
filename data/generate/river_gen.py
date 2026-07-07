#!/usr/bin/env python3
"""
river_gen.py — Snap Natural Earth rivers to grid cell edges.

Reads ne_10m_rivers_lake_centerlines.shp, for each river polyline:
  1. Find nearest grid vertex for each polyline vertex
  2. A* pathfind along cell edges between consecutive vertices
  3. Merge into continuous edge sequence
  4. Output rivers.json with edge sequences for Godot rendering

Uses grid_graph.py for the grid vertex graph and A* implementation.
"""

import json
import math
import os
import sys

import shapefile
from shapely.geometry import shape, LineString, MultiLineString

# Add parent to path for grid_graph import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from grid_graph import (
    EARTH_RADIUS_KM,
    compute_band_structure,
    grid_vertex_position,
    astar_path,
)


def lat_lon_to_grid_vertex(lat: float, lon: float, band_struct: dict) -> tuple:
    """Find the nearest grid vertex to a geographic point."""
    total_bands = band_struct["total_bands"]
    band_segs = band_struct["band_segs"]

    # Normalize lon to [0, 360) for the grid
    lon_norm = lon % 360.0

    # Find the nearest band
    lat_frac = (lat + 90.0) / 180.0
    band = int(round(lat_frac * total_bands))
    band = max(0, min(total_bands, band))

    # Find the nearest segment at that band
    segs = band_segs[band]
    if segs <= 0:
        segs = 4
    seg = int(round(lon_norm / 360.0 * segs))
    seg = seg % segs

    return (band, seg)


def extract_rivers(shp_path: str, max_rivers: int = None) -> list:
    """
    Extract river polylines from shapefile.
    Returns list of {name, coords: [(lon, lat), ...]}.
    """
    reader = shapefile.Reader(shp_path)
    rivers = []
    skipped = 0

    for sr in reader.shapeRecords():
        geom = shape(sr.shape)
        if geom.is_empty:
            skipped += 1
            continue

        # Get river name from attributes
        name = ""
        rec = sr.record
        if hasattr(rec, "name") and rec.name:
            name = rec.name
        elif hasattr(rec, "NAME") and rec.NAME:
            name = rec.NAME
        elif hasattr(rec, "Name") and rec.Name:
            name = rec.Name

        # Flatten to coordinates
        if isinstance(geom, MultiLineString):
            lines = list(geom.geoms)
        elif isinstance(geom, LineString):
            lines = [geom]
        else:
            skipped += 1
            continue

        for line in lines:
            coords = list(line.coords)
            if len(coords) < 3:
                skipped += 1
                continue
            rivers.append({
                "name": name if name else f"river_{len(rivers)}",
                "coords": coords,  # [(lon, lat), ...] in shapefile convention
            })

    print(f"Extracted {len(rivers)} river segments ({skipped} skipped)")
    return rivers


def snap_river_to_grid(river_coords: list, band_struct: dict, max_a_star_steps: int = 500) -> list:
    """
    Snap a river polyline to grid cell edges.
    
    Returns list of (band, seg, direction) edge tuples.
    direction: "N" (cross band boundary going north) or "E" (cross segment boundary going east)
    """
    if len(river_coords) < 2:
        return []

    # Step 1: Find grid vertices for each polyline vertex
    grid_verts = []
    for lon, lat in river_coords:
        band, seg = lat_lon_to_grid_vertex(lat, lon, band_struct)
        grid_verts.append((band, seg))

    # Step 2: Remove consecutive duplicates
    deduped = []
    for v in grid_verts:
        if not deduped or v != deduped[-1]:
            deduped.append(v)

    if len(deduped) < 2:
        return []

    # Step 3: A* path between consecutive vertices
    all_edges = []
    for i in range(len(deduped) - 1):
        start_band, start_seg = deduped[i]
        end_band, end_seg = deduped[i + 1]

        path = astar_path(start_band, start_seg, end_band, end_seg, band_struct, max_a_star_steps)

        if not path and (start_band != end_band or start_seg != end_seg):
            # Direct edge if within one step
            d_band = end_band - start_band
            d_seg = abs(end_seg - start_seg)
            if abs(d_band) == 1 and d_seg == 0:
                all_edges.append((start_band, start_seg, "N"))
            elif d_band == 0 and d_seg == 1:
                all_edges.append((start_band, start_seg, "E"))
            continue

        all_edges.extend(path)

    # Step 4: Merge to a simple format
    merged = []
    for band, seg, direction in all_edges:
        merged.append({
            "band": band,
            "seg": seg,
            "dir": direction,
        })

    return merged


def main():
    parser = __import__("argparse").ArgumentParser(description="Snap rivers to grid cell edges")
    parser.add_argument("--resolution", "-r", type=float, default=10.0,
                        help="Grid resolution in km (default: 10)")
    parser.add_argument("--max-rivers", type=int, default=None,
                        help="Max rivers to process (for testing)")
    parser.add_argument("--output", "-o", type=str, default=None)
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    shp_dir = os.path.join(script_dir, "..", "shapefiles")
    out_dir = os.path.join(script_dir, "..", "output", f"grid_{args.resolution:.0f}km")
    os.makedirs(out_dir, exist_ok=True)

    shp_path = os.path.join(shp_dir, "ne_10m_rivers_lake_centerlines.shp")
    if not os.path.exists(shp_path):
        print(f"ERROR: Shapefile not found: {shp_path}")
        sys.exit(1)

    # Build grid graph
    print(f"Building grid graph at {args.resolution:.0f}km...")
    band_struct = compute_band_structure(EARTH_RADIUS_KM, args.resolution)
    print(f"  {band_struct['total_bands']} bands, {sum(band_struct['band_segs'])} vertices")

    # Extract rivers
    print("Loading rivers shapefile...")
    rivers = extract_rivers(shp_path, args.max_rivers)

    # Snap each river
    print(f"Snapping {len(rivers)} rivers to grid...")
    snapped = {}
    skipped_no_path = 0
    skipped_empty = 0

    for i, river in enumerate(rivers):
        if i % 200 == 0 and i > 0:
            print(f"  Progress: {i}/{len(rivers)}...")

        edges = snap_river_to_grid(river["coords"], band_struct)

        if not edges:
            skipped_empty += 1
            continue

        # Group by river name (merge segments of the same named river)
        name = river["name"]
        if name in snapped:
            # Append edges with a small gap (degenerate segment)
            snapped[name]["edges"].extend(edges)
        else:
            snapped[name] = {
                "name": name,
                "edges": edges,
            }

    print(f"  Snapped: {len(snapped)} rivers")
    print(f"  Skipped (no path): {skipped_no_path}")
    print(f"  Skipped (empty): {skipped_empty}")

    # Count total edges
    total_edges = sum(len(r["edges"]) for r in snapped.values())
    print(f"  Total edges: {total_edges:,}")

    # Save
    out_path = args.output or os.path.join(out_dir, "rivers.json")
    with open(out_path, "w") as f:
        json.dump(snapped, f, separators=(",", ":"))

    file_size = os.path.getsize(out_path)
    print(f"\nSaved: {out_path} ({file_size:,} bytes)")
    print("Done.")


if __name__ == "__main__":
    main()
