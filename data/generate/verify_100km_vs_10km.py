#!/usr/bin/env python3
"""Independent cross-check of tile_mapping_100km.json against the 10km mapping.

For every 100km cell (band, seg in denser frame), independently locate the
10km tile at the cell's center lat/lon and compare land/ocean classification
against the aggregated 100km JSON. Mismatches clustered at merge bands would
prove pipeline corruption there.
"""
import json
from collections import defaultdict
from build_tile_mapping_100km import compute_band_segments

tb10, bs10 = compute_band_segments(10.0)
tb100, bs100 = compute_band_segments(100.0)
sparser_10 = [min(bs10[t], bs10[t + 1]) for t in range(tb10)]
denser_100 = [max(bs100[b], bs100[b + 1]) for b in range(tb100)]

with open("../countries/tile_mapping.json") as f:
    m10 = json.load(f)
with open("../countries/tile_mapping_100km.json") as f:
    m100 = json.load(f)

def land10_at(lat_deg, lon_frac):
    """Look up 10km tile by real latitude (deg) and longitude fraction [0,1)."""
    # band containing lat: transition t spans rings t..t+1
    t = int((lat_deg + 90.0) / 180.0 * tb10)
    t = max(0, min(tb10 - 1, t))
    n10 = sparser_10[t]
    s_math = int(lon_frac * n10)
    if s_math >= n10:
        s_math = n10 - 1
    seg10 = n10 - 1 - s_math
    return m10.get(f"B{t}_{seg10}")

mismatch_by_band = defaultdict(lambda: [0, 0])  # band -> [false_land, total_cells]
doubling_stats = {}

for b in range(tb100):
    n = denser_100[b]
    lat_c = -90.0 + 180.0 * (b + 0.5) / tb100
    false_land = 0
    for seg in range(n):
        s_math = n - 1 - seg
        lon_frac = (s_math + 0.5) / n
        tid = f"B{b}_{seg}"
        has_land_100 = tid in m100
        gt = land10_at(lat_c, lon_frac)
        if has_land_100 and gt is None:
            false_land += 1
    mismatch_by_band[b] = [false_land, n]

# Report bands with false-land rate > 2%
print("Bands with >2% 'filled sea' (100km says land, 10km center says ocean):")
flagged = []
for b in range(tb100):
    fl, n = mismatch_by_band[b]
    if n > 0 and fl / n > 0.02:
        is_merge = bs100[b] != bs100[b + 1]
        flagged.append((b, fl, n, is_merge))
        print(f"  band {b:3d} (segs {bs100[b]:3d}->{bs100[b+1]:3d}"
              f"{' MERGE' if is_merge else '      '}): {fl}/{n} false-land "
              f"({100.0*fl/n:.1f}%)")

print(f"\nTotal flagged bands: {len(flagged)} "
      f"(merges: {sum(1 for f in flagged if f[3])})")

# Doubling check at merge bands: is palette[2s]==palette[2s+1] suspiciously often?
print("\nDoubling check at denser-frame merge bands (adjacent-seg equality):")
for b in range(tb100):
    if bs100[b] == bs100[b + 1]:
        continue
    n = denser_100[b]
    same = 0
    both = 0
    for s in range(0, n - 1, 2):
        a = m100.get(f"B{b}_{s}")
        c = m100.get(f"B{b}_{s+1}")
        if a is not None and c is not None:
            both += 1
            if a == c:
                same += 1
    if both:
        print(f"  band {b:3d}: {same}/{both} adjacent pairs same palette "
              f"({100.0*same/both:.0f}%)")
