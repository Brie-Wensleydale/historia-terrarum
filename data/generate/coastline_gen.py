#!/usr/bin/env python3
"""
coastline_gen.py — Extract and simplify coastlines from Natural Earth shapefile.

Reads ne_10m_coastline.shp, extracts polyline rings, simplifies to 3 LOD levels,
and outputs coastline data as JSON with 3D sphere coordinates.

LOD levels:
  - fine:   2km tolerance (~200K vertices globally)
  - medium: 10km tolerance (~40K vertices)
  - coarse: 50km tolerance (~8K vertices)
"""

import json
import math
import os
import sys

import shapefile
from shapely.geometry import shape, LineString, MultiLineString
from shapely.ops import unary_union

EARTH_RADIUS_KM = 6371.0
SIMPLIFY_TOLERANCES = {
    "fine": 0.02,     # ~2km in degrees
    "medium": 0.09,   # ~10km
    "coarse": 0.45,   # ~50km
}


def lat_lon_to_3d(lat: float, lon: float, radius: float) -> tuple:
    """Convert geographic lat/lon to 3D point on sphere."""
    lat_rad = math.radians(lat)
    lon_rad = math.radians(lon)
    x = radius * math.cos(lat_rad) * math.cos(lon_rad)
    y = radius * math.sin(lat_rad)
    z = radius * math.cos(lat_rad) * math.sin(lon_rad)
    return (round(x, 3), round(y, 3), round(z, 3))


def extract_coastlines(shp_path: str) -> list:
    """Extract all polyline rings from the coastline shapefile."""
    reader = shapefile.Reader(shp_path)
    rings = []

    for sr in reader.shapeRecords():
        geom = shape(sr.shape)
        if geom.is_empty:
            continue

        # Flatten MultiLineString into individual rings
        if isinstance(geom, MultiLineString):
            lines = list(geom.geoms)
        elif isinstance(geom, LineString):
            lines = [geom]
        else:
            continue

        for line in lines:
            coords = list(line.coords)
            if len(coords) < 3:
                continue
            rings.append(coords)

    print(f"Extracted {len(rings)} coastline rings")
    return rings


def simplify_rings(rings: list, tolerance_deg: float) -> list:
    """Simplify rings using Douglas-Peucker, keeping min 4 points."""
    simplified = []
    for ring in rings:
        line = LineString(ring)
        simple = line.simplify(tolerance_deg, preserve_topology=True)
        coords = list(simple.coords)
        if len(coords) >= 4:
            simplified.append(coords)
    return simplified


def rings_to_json(rings: list, radius: float) -> list:
    """Convert ring coordinates to 3D sphere points for JSON."""
    output = []
    for ring in rings:
        ring_data = []
        for lon, lat in ring:  # Note: shapefile coords are (lon, lat)
            x, y, z = lat_lon_to_3d(lat, lon, radius)
            ring_data.extend([x, y, z])
        output.append(ring_data)
    return output


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    shp_dir = os.path.join(script_dir, "..", "shapefiles")
    out_dir = os.path.join(script_dir, "..", "output")
    os.makedirs(out_dir, exist_ok=True)

    shp_path = os.path.join(shp_dir, "ne_10m_coastline.shp")
    if not os.path.exists(shp_path):
        print(f"ERROR: Shapefile not found: {shp_path}")
        sys.exit(1)

    print("Loading coastline shapefile...")
    rings = extract_coastlines(shp_path)

    # Generate each LOD level
    coastline_data = {}
    for lod_name, tolerance in SIMPLIFY_TOLERANCES.items():
        radius = EARTH_RADIUS_KM * 1.004  # Offset slightly above surface
        print(f"  Simplifying to {lod_name} (tolerance={tolerance}°)...")
        simple = simplify_rings(rings, tolerance)
        print(f"  {len(simple)} rings → converting to 3D...")
        coastline_data[lod_name] = rings_to_json(simple, radius)

    # Save
    out_path = os.path.join(out_dir, "coastlines.json")
    with open(out_path, "w") as f:
        json.dump(coastline_data, f)
    
    sizes = {k: len(json.dumps(v)) for k, v in coastline_data.items()}
    print(f"\nSaved: {out_path}")
    for lod, size in sizes.items():
        print(f"  {lod}: {size:,} bytes")
    print("Done.")


if __name__ == "__main__":
    main()
