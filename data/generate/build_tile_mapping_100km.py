#!/usr/bin/env python3
"""Generate 100km tile mapping from 10km tile mapping via majority-vote aggregation.

TILE ID CONVENTION (must match Godot's generate_tint()):
  Tile IDs are "B{band}_{seg}" where `band` is the 100km transition index
  (0..199) and `seg` is the DENSER-frame segment index at that band:
      seg in [0, max(band_segs_100km[band], band_segs_100km[band+1]))
  The mirror is baked in exactly as tile_registry.py does it:
      seg = N - 1 - floor(lon_frac * N)   (N = denser segment count)
  so Godot can look up tiles directly by mesh segment index with no
  per-merge-ratio rescaling. At non-merge bands denser == sparser, so this
  reproduces the historical working convention 1:1.

WHY NOT seg_10km // 10 (the old approach)?
  The old script aggregated with band_100 = band_10 // 10, seg_100 = seg_10 // 10.
  That inherits whatever frame the 10km grid uses at each latitude, which is
  inconsistent: sparser-frame at some merge bands (25/50), denser-frame at
  others (200), and MIXED frames inside a single 100km band wherever a 10km
  merge ring falls inside the band's latitude span (e.g. band 166). Godot's
  sparser-indexed lookup then read only half the entries at merge bands and
  stretched them across the full 360 degrees. It also mis-assigned bands by up
  to one full band because 2002 does not divide evenly into groups of 10.

  This script instead recomputes each 10km tile's center lat/lon from the
  replicated band structure (same math as tile_registry.py / the GDScript
  SphericalGridGenerator), then assigns it to the 100km band containing its
  center latitude and the denser-frame slot containing its center longitude.
  Majority vote per (band, seg) as before.
"""
import json, math, os, sys
from collections import Counter

PROJECT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
COUNTRIES_DIR = os.path.join(PROJECT_DIR, "countries")

RADIUS_KM = 6371.0
MERGE_FACTOR = 0.5
MIN_POLE_SEGS = 4
POLE_CLAMP_SEGS = 4


def compute_band_segments(base_cell_km: float):
    """Replica of SphericalGridGenerator.compute_band_structure()."""
    radius_m = RADIUS_KM * 1000.0
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

    current_segs = equator_segs
    for b in range(bands + 1, total_bands + 1):
        lat = math.pi * 0.5 * (b - bands) / bands
        cell_width = 2 * math.pi * radius_m * math.cos(lat) / current_segs
        while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2 * math.pi * radius_m * math.cos(lat) / current_segs
        band_segs[b] = current_segs

    current_segs = equator_segs
    for b in range(bands - 1, -1, -1):
        lat = math.pi * 0.5 * (bands - b) / bands
        cell_width = 2 * math.pi * radius_m * math.cos(lat) / current_segs
        while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
            current_segs //= 2
            cell_width = 2 * math.pi * radius_m * math.cos(lat) / current_segs
        band_segs[b] = current_segs

    for i in range(total_bands + 1):
        if band_segs[i] < POLE_CLAMP_SEGS:
            band_segs[i] = POLE_CLAMP_SEGS

    return total_bands, band_segs


def main():
    total_bands_10, bs10 = compute_band_segments(10.0)
    total_bands_100, bs100 = compute_band_segments(100.0)
    print(f"10km: {total_bands_10} bands, equator {bs10[total_bands_10 // 2]} segs")
    print(f"100km: {total_bands_100} bands, equator {bs100[total_bands_100 // 2]} segs")

    # Sparser count per 10km transition (frame the 10km tile IDs live in)
    sparser_10 = [min(bs10[t], bs10[t + 1]) for t in range(total_bands_10)]
    # Denser count per 100km band (frame Godot looks up at generate_tint())
    denser_100 = [max(bs100[b], bs100[b + 1]) for b in range(total_bands_100)]

    with open(os.path.join(COUNTRIES_DIR, "tile_mapping.json"), encoding="utf-8") as f:
        mapping_10km = json.load(f)
    print(f"Loaded {len(mapping_10km):,} 10km tile assignments")

    mapping_100km = Counter()  # (band, seg) -> Counter(palette_index -> count)
    skipped = 0

    for tid_10km, palette_idx in mapping_10km.items():
        parts = tid_10km.split("_")
        if len(parts) != 2 or not parts[0].startswith("B"):
            continue
        try:
            band_10 = int(parts[0][1:])
            seg_10 = int(parts[1])
        except ValueError:
            continue
        if band_10 < 0 or band_10 >= total_bands_10:
            skipped += 1
            continue

        n10 = sparser_10[band_10]
        if seg_10 < 0 or seg_10 >= n10:
            skipped += 1
            continue

        # Undo the baked-in mirror to recover the math-frame cell index,
        # then the center longitude as a fraction of the full circle.
        s_math = n10 - 1 - seg_10
        lon_frac = (s_math + 0.5) / n10  # in [0, 1)

        # Band containing the tile's center latitude (transition t spans
        # rings t..t+1; center at t+0.5). Fixes the old band_10 // 10 shift.
        band_100 = int((band_10 + 0.5) * total_bands_100 / total_bands_10)
        if band_100 < 0:
            band_100 = 0
        elif band_100 >= total_bands_100:
            band_100 = total_bands_100 - 1

        # Denser-frame slot containing the center longitude, mirror baked in.
        n100 = denser_100[band_100]
        s_100 = int(lon_frac * n100)
        if s_100 >= n100:
            s_100 = n100 - 1
        seg_100 = n100 - 1 - s_100

        key = (band_100, seg_100)
        if key not in mapping_100km:
            mapping_100km[key] = Counter()
        mapping_100km[key][palette_idx] += 1

    print(f"Aggregated into {len(mapping_100km):,} 100km tile groups (skipped {skipped})")

    # Majority vote
    result = {}
    for (band, seg), counts in mapping_100km.items():
        if counts:
            result[f"B{band}_{seg}"] = counts.most_common(1)[0][0]

    print(f"Final 100km mapping: {len(result):,} tiles")
    out_path = os.path.join(COUNTRIES_DIR, "tile_mapping_100km.json")
    with open(out_path, "w") as f:
        json.dump(result, f, separators=(",", ":"))
    size_mb = os.path.getsize(out_path) / 1024 / 1024
    print(f"Written: tile_mapping_100km.json ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
