#!/usr/bin/env python3
"""Analyze tile_mapping_100km.json at merge bands for 'filled sea' anomalies."""
import json, math, sys
sys.path.insert(0, ".")
from build_tile_mapping_100km import compute_band_segments

total_bands, bs = compute_band_segments(100.0)
print(f"100km grid: {total_bands} bands")

# Merge bands: where bs[b] != bs[b+1]
print("\nMerge transitions (band b spans ring b..b+1):")
merge_bands = []
for b in range(total_bands):
    if bs[b] != bs[b + 1]:
        lat_bot = -90 + 180 * b / total_bands
        lat_top = -90 + 180 * (b + 1) / total_bands
        denser = max(bs[b], bs[b + 1])
        merge_bands.append((b, bs[b], bs[b + 1], denser, lat_bot, lat_top))
        print(f"  band {b:3d}: {bs[b]:3d} -> {bs[b+1]:3d} segs "
              f"(denser={denser}) lat [{lat_bot:6.2f}, {lat_top:6.2f}]")

with open("../countries/tile_mapping_100km.json") as f:
    mapping = json.load(f)

# Group land tiles by band
band_tiles = {}
for tid, pal in mapping.items():
    b, s = tid.split("_")
    b = int(b[1:]); s = int(s)
    band_tiles.setdefault(b, []).append(s)

print(f"\nTotal land tiles: {len(mapping)}, bands with land: {len(band_tiles)}")

# Per-band land counts around merge bands (+/- 2)
print("\nLand tile counts near merge bands (and seg ranges vs denser frame):")
for (mb, sb, st, denser, la, lb) in merge_bands:
    print(f"--- merge band {mb} ({sb}->{st}, denser={denser}) lat [{la:.2f},{lb:.2f}] ---")
    for b in range(max(0, mb - 2), min(total_bands, mb + 3)):
        segs = band_tiles.get(b, [])
        d = max(bs[b], bs[b + 1])
        rng = f"[{min(segs)}..{max(segs)}]" if segs else "  (none)  "
        marker = " <== MERGE" if b == mb else ""
        print(f"  band {b:3d} (segs {bs[b]:3d}->{bs[b+1]:3d}, denser {d:3d}): "
              f"{len(segs):4d} land tiles, seg range {rng} (valid 0..{d-1}){marker}")

# Global sanity: any seg out of denser range?
bad = 0
for tid in mapping:
    b, s = tid.split("_")
    b = int(b[1:]); s = int(s)
    d = max(bs[b], bs[b + 1])
    if s < 0 or s >= d:
        bad += 1
        if bad < 10:
            print(f"OUT-OF-RANGE: {tid} (denser={d})")
print(f"\nOut-of-range segs: {bad}")

# Bands above merge: check seg range uses full denser frame
print("\nSeg-range utilization at merge bands (max_seg vs denser-1):")
for (mb, sb, st, denser, la, lb) in merge_bands:
    segs = band_tiles.get(mb, [])
    if segs:
        print(f"  band {mb}: land max seg = {max(segs)}, denser-1 = {denser-1}, "
              f"min = {min(segs)}")
