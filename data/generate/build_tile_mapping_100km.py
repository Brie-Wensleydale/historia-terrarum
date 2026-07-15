#!/usr/bin/env python3
"""Generate 100km tile mapping from 10km tile mapping via majority-vote aggregation."""
import json, os, sys
from collections import Counter

PROJECT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
COUNTRIES_DIR = os.path.join(PROJECT_DIR, "countries")

# Load 10km tile mapping
with open(os.path.join(COUNTRIES_DIR, "tile_mapping.json"), encoding="utf-8") as f:
    mapping_10km = json.load(f)
print(f"Loaded {len(mapping_10km):,} 10km tile assignments")

# 10km → 100km aggregation
# 10km: 2002 bands, 4000 equator segs (band 1001 = equator)
# 100km: 200 bands, 400 equator segs (band 100 = equator)
# Ratio: band_100km = band_10km // 10, seg_100km = seg_10km // 10

mapping_100km = Counter()  # (band, seg) → Counter(palette_index → count)

for tid_10km, palette_idx in mapping_10km.items():
    # Parse "B{band}_{seg}"
    parts = tid_10km.split("_")
    if len(parts) != 2 or not parts[0].startswith("B"):
        continue
    try:
        band_10 = int(parts[0][1:])
        seg_10 = int(parts[1])
    except ValueError:
        continue

    band_100 = band_10 // 10
    seg_100 = seg_10 // 10
    key = (band_100, seg_100)
    if key not in mapping_100km:
        mapping_100km[key] = Counter()
    mapping_100km[key][palette_idx] += 1

print(f"Aggregated into {len(mapping_100km):,} 100km tile groups")

# Majority vote
result = {}
for (band, seg), counts in mapping_100km.items():
    if counts:
        result[f"B{band}_{seg}"] = counts.most_common(1)[0][0]

print(f"Final 100km mapping: {len(result):,} tiles")
with open(os.path.join(COUNTRIES_DIR, "tile_mapping_100km.json"), "w") as f:
    json.dump(result, f, separators=(",", ":"))
size_mb = os.path.getsize(os.path.join(COUNTRIES_DIR, "tile_mapping_100km.json")) / 1024 / 1024
print(f"Written: tile_mapping_100km.json ({size_mb:.1f} MB)")
