#!/usr/bin/env python3
"""Build tile-to-palette-index mapping from region YAMLs."""
import json, os, sys, yaml

PROJECT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REGIONS_DIR = os.path.join(PROJECT_DIR, "regions")
COUNTRIES_DIR = os.path.join(PROJECT_DIR, "countries")

# Load country palette indices
with open(os.path.join(COUNTRIES_DIR, "country_registry.yaml"), encoding="utf-8") as f:
    reg = yaml.safe_load(f)
country_idx = {c["id"]: c["palette_index"] for c in reg["countries"]}

# Load _index and build region→country mapping
with open(os.path.join(REGIONS_DIR, "_index.yaml"), encoding="utf-8") as f:
    idx = yaml.safe_load(f)

tile_map = {}
ocean = 0
total_regions = len(idx["regions"])
for i, r in enumerate(idx["regions"]):
    if (i + 1) % 500 == 0:
        print(f"  {i+1}/{total_regions} regions...")
    if r["tile_count"] == 0:
        continue
    country = r["country"]
    if country not in country_idx:
        continue
    pi = country_idx[country]
    path = os.path.join(REGIONS_DIR, f'{r["id"]}.yaml')
    if not os.path.exists(path):
        continue
    with open(path, encoding="utf-8") as f:
        rdata = yaml.safe_load(f)
    for tid in rdata.get("tiles", []):
        tile_map[tid] = pi

print(f"Built tile mapping: {len(tile_map):,} tiles → {len(set(tile_map.values()))} palette indices")

with open(os.path.join(COUNTRIES_DIR, "tile_mapping.json"), "w") as f:
    json.dump(tile_map, f, separators=(",", ":"))
print(f"Written: {os.path.join(COUNTRIES_DIR, 'tile_mapping.json')} "
      f"({os.path.getsize(os.path.join(COUNTRIES_DIR, 'tile_mapping.json'))/1024/1024:.1f} MB)")
