#!/usr/bin/env python3
"""
grid_graph.py — Build the grid vertex graph for river pathfinding.

The 10km spherical grid forms a graph where nodes are grid vertices
(intersections of band lines and segment lines) and edges are N-S
(meridian) and E-W (latitude band) connections.

Used by river_gen.py for A* pathfinding when snapping rivers to cell edges.
"""

import json
import math
import os
import sys

EARTH_RADIUS_KM = 6371.0


def compute_band_structure(radius_km: float, base_cell_km: float) -> dict:
    """Replicates SphericalGridGenerator.compute_band_structure()."""
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

    current_segs = equator_segs
    for b in range(bands + 1, total_bands + 1):
        lat = math.pi * 0.5 * (b - bands) / bands
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > 4 and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    current_segs = equator_segs
    for b in range(bands - 1, -1, -1):
        lat = math.pi * 0.5 * (bands - b) / bands
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / current_segs
        while cell_width < merge_threshold_m and current_segs > 4 and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / current_segs
        band_segs[b] = current_segs

    for i in range(total_bands + 1):
        if band_segs[i] < 4:
            band_segs[i] = 4

    return {
        "total_bands": total_bands,
        "band_segs": band_segs,
        "radius_km": radius_km,
    }


def grid_vertex_position(band: int, seg: int, radius_km: float, band_struct: dict) -> tuple:
    """Get 3D position of a grid vertex (band line × segment line intersection)."""
    total_bands = band_struct["total_bands"]
    band_segs = band_struct["band_segs"]
    
    lat = -math.pi * 0.5 + math.pi * band / total_bands
    segs_at_band = band_segs[band]
    if segs_at_band <= 0:
        segs_at_band = 4
    lon = 2.0 * math.pi * (seg % segs_at_band) / segs_at_band

    x = radius_km * math.cos(lat) * math.cos(lon)
    y = radius_km * math.sin(lat)
    z = radius_km * math.cos(lat) * math.sin(lon)
    return (x, y, z)


def map_segment(seg: int, from_band: int, to_band: int, band_struct: dict) -> int:
    """Map a segment index from one band to another (handles merge ratio)."""
    band_segs = band_struct["band_segs"]
    from_segs = band_segs[from_band]
    to_segs = band_segs[to_band]
    if from_segs <= 0 or to_segs <= 0:
        return 0
    return int(seg * to_segs / from_segs)


def build_grid_graph(band_struct: dict) -> dict:
    """
    Build adjacency graph for A* pathfinding on grid vertices.
    
    Returns: {
        "band_struct": band_struct,
        "node_positions": {(band, seg): (x, y, z)},
    }
    The graph edges are implicit — from any (band, seg), neighbors are:
      N: (band+1, map_segment(seg, band, band+1))
      S: (band-1, map_segment(seg, band, band-1))
      E: (band, seg+1)
      W: (band, seg-1)
    """
    total_bands = band_struct["total_bands"]
    band_segs = band_struct["band_segs"]
    radius_km = band_struct["radius_km"]

    positions = {}
    for band in range(total_bands + 1):
        segs = band_segs[band]
        if segs <= 0:
            continue
        for seg in range(segs):
            pos = grid_vertex_position(band, seg, radius_km, band_struct)
            positions[f"{band}_{seg}"] = pos

    graph = {
        "band_struct": band_struct,
        "node_positions": positions,
    }

    print(f"Grid graph: {total_bands} bands, {len(positions)} vertices")
    return graph


def get_neighbors(band: int, seg: int, band_struct: dict) -> list:
    """Get valid neighbor vertices from a grid vertex."""
    total_bands = band_struct["total_bands"]
    band_segs = band_struct["band_segs"]
    neighbors = []

    # North (band + 1)
    if band < total_bands:
        n_seg = map_segment(seg, band, band + 1, band_struct)
        n_segs = band_segs[band + 1]
        if 0 <= n_seg < n_segs:
            neighbors.append(("N", band + 1, n_seg))

    # South (band - 1)
    if band > 0:
        s_seg = map_segment(seg, band, band - 1, band_struct)
        s_segs = band_segs[band - 1]
        if 0 <= s_seg < s_segs:
            neighbors.append(("S", band - 1, s_seg))

    # East (seg + 1)
    segs = band_segs[band]
    if segs > 0:
        neighbors.append(("E", band, (seg + 1) % segs))

    # West (seg - 1)
    if segs > 0:
        neighbors.append(("W", band, (seg - 1) % segs))

    return neighbors


def distance_km(pos_a: tuple, pos_b: tuple) -> float:
    """Great-circle-ish distance between two 3D points (in km, assuming Earth radius)."""
    dx = pos_a[0] - pos_b[0]
    dy = pos_a[1] - pos_b[1]
    dz = pos_a[2] - pos_b[2]
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def astar_path(start_band: int, start_seg: int, end_band: int, end_seg: int, band_struct: dict, max_steps: int = 5000) -> list:
    """
    A* pathfinding on the grid graph.
    Returns list of (dir, band, seg) edges or empty list if no path found.
    """
    import heapq

    start_key = (start_band, start_seg)
    end_key = (end_band, end_seg)
    if start_key == end_key:
        return []

    # Pre-compute positions
    def get_pos(b, s):
        return grid_vertex_position(b, s, band_struct["radius_km"], band_struct)

    end_pos = get_pos(end_band, end_seg)

    # Heuristic: straight-line distance to target
    def heuristic(b, s):
        return distance_km(get_pos(b, s), end_pos)

    # Priority queue: (f_score, tiebreaker, (band, seg))
    counter = 0
    open_set = [(heuristic(start_band, start_seg), counter, start_key)]
    counter += 1

    came_from = {}  # (band, seg) → ((band, seg), dir)
    g_score = {start_key: 0.0}
    closed = set()

    while open_set and len(closed) < max_steps:
        _, _, current = heapq.heappop(open_set)
        if current in closed:
            continue

        if current == end_key:
            # Reconstruct path
            path = []
            node = current
            while node in came_from:
                prev_node, direction = came_from[node]
                # Convert direction to edge format:
                # N from prev means edge at (prev_band, prev_seg, "N")
                # E from prev means edge at (prev_band, prev_seg, "E")
                if direction in ("N", "S"):
                    edge_band = prev_node[0] if direction == "N" else node[0]
                    edge_dir = "N"  # Always store as N (going north)
                    path.append((edge_band, prev_node[1], edge_dir))
                else:
                    edge_dir = direction  # E or W, but we standardize
                    path.append((prev_node[0], prev_node[1], edge_dir))
                node = prev_node
            path.reverse()
            return path

        closed.add(current)
        c_band, c_seg = current

        for direction, n_band, n_seg in get_neighbors(c_band, c_seg, band_struct):
            neighbor = (n_band, n_seg)
            if neighbor in closed:
                continue

            # Edge cost: distance between vertices
            edge_cost = distance_km(get_pos(c_band, c_seg), get_pos(n_band, n_seg))
            tentative_g = g_score.get(current, float("inf")) + edge_cost

            if tentative_g < g_score.get(neighbor, float("inf")):
                came_from[neighbor] = (current, direction)
                g_score[neighbor] = tentative_g
                f = tentative_g + heuristic(n_band, n_seg)
                heapq.heappush(open_set, (f, counter, neighbor))
                counter += 1

    return []  # No path found


def main():
    parser = __import__("argparse").ArgumentParser()
    parser.add_argument("--resolution", "-r", type=float, default=10.0)
    parser.add_argument("--output", "-o", type=str, default=None)
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    if args.output:
        out_path = args.output
    else:
        out_dir = os.path.join(script_dir, "..", "output", f"grid_{args.resolution:.0f}km")
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "grid_graph.json")

    print(f"Building grid graph at {args.resolution:.0f}km resolution...")
    band_struct = compute_band_structure(EARTH_RADIUS_KM, args.resolution)
    graph = build_grid_graph(band_struct)

    print(f"Saving to {out_path}...")
    with open(out_path, "w") as f:
        json.dump(graph, f, separators=(",", ":"))

    print("Done.")


if __name__ == "__main__":
    main()
