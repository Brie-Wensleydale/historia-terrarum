#!/usr/bin/env python3
"""
build_country_registry.py — Build country registry and palette from Phase 4 region data.

Reads _index.yaml and region YAML files, aggregates per-country statistics,
assigns palette indices with deterministic color generation based on continent/tier.

Outputs:
  data/countries/country_registry.yaml  — full country metadata + palette indices
  data/countries/palette.json           — 256 RGBA color array for shader uniforms

Usage:
    python build_country_registry.py
"""

import json
import math
import os
import sys
import yaml
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.join(SCRIPT_DIR, "..")
REGIONS_DIR = os.path.join(PROJECT_DIR, "regions")
COUNTRIES_DIR = os.path.join(PROJECT_DIR, "countries")
INDEX_PATH = os.path.join(REGIONS_DIR, "_index.yaml")

PALETTE_SIZE = 256
OCEAN_INDEX = 0
UNCLAIMED_INDEX = 255

# Continent assignment by country name (manual but small — 249 countries)
# Countries not listed here get assigned by region bounding box
CONTINENT_MAP = {
    "Russia": ["Europe", "Asia"],
    "Turkey": ["Europe", "Asia"],
    "Kazakhstan": ["Europe", "Asia"],
    "Azerbaijan": ["Europe", "Asia"],
    "Georgia": ["Europe", "Asia"],
    "Egypt": ["Africa", "Asia"],
    "Panama": ["North America", "South America"],
    "Indonesia": ["Asia", "Oceania"],
}

# Tier thresholds
MAJOR_THRESHOLD = 50000      # >50K tiles → major
REGIONAL_THRESHOLD = 10000   # 10K-50K → regional
MINOR_THRESHOLD = 1000       # 1K-10K → minor
# <1K → micro


def load_index():
    with open(INDEX_PATH, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data["regions"]


def aggregate_countries(regions):
    """Aggregate per-country stats from region entries."""
    countries = defaultdict(lambda: {
        "tile_count": 0,
        "region_count": 0,
        "admin2_count": 0,
        "lat_sum": 0.0,
        "lon_sum": 0.0,
        "lat_min": 90.0,
        "lat_max": -90.0,
        "lon_min": 180.0,
        "lon_max": -180.0,
    })

    for r in regions:
        c = r["country"]
        tc = r.get("tile_count", 0)
        cdata = countries[c]
        cdata["tile_count"] += tc
        cdata["region_count"] += 1
        if r.get("parent"):
            cdata["admin2_count"] += 1

        # Estimate centroid from tile distribution
        # (Full accuracy would require reading region YAMLs, but _index has no coords)
        # We'll approximate from region names / known locations later

    return dict(countries)


def assign_continent(country_name, tile_count, region_count):
    """Assign primary continent for palette coloring."""
    # Manual overrides
    if country_name in CONTINENT_MAP:
        return CONTINENT_MAP[country_name][0]

    # By name
    europe_countries = {
        "Albania", "Andorra", "Austria", "Belarus", "Belgium", "Bosnia and Herzegovina",
        "Bulgaria", "Croatia", "Czech Republic", "Czechia", "Denmark", "Estonia",
        "Finland", "France", "Germany", "Greece", "Hungary", "Iceland", "Ireland",
        "Italy", "Kosovo", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg",
        "Malta", "Moldova", "Monaco", "Montenegro", "Netherlands", "North Macedonia",
        "Norway", "Poland", "Portugal", "Romania", "San Marino", "Serbia", "Slovakia",
        "Slovenia", "Spain", "Sweden", "Switzerland", "Ukraine", "United Kingdom",
        "Vatican", "Vatican City",
    }
    asia_countries = {
        "Afghanistan", "Armenia", "Bahrain", "Bangladesh", "Bhutan", "Brunei",
        "Cambodia", "China", "Cyprus", "East Timor", "India", "Iran", "Iraq",
        "Israel", "Japan", "Jordan", "Kuwait", "Kyrgyzstan", "Laos", "Lebanon",
        "Malaysia", "Maldives", "Mongolia", "Myanmar", "Nepal", "North Korea",
        "Oman", "Pakistan", "Palestine", "Philippines", "Qatar", "Saudi Arabia",
        "Singapore", "South Korea", "Sri Lanka", "Syria", "Taiwan", "Tajikistan",
        "Thailand", "Turkmenistan", "United Arab Emirates", "Uzbekistan", "Vietnam",
        "Yemen",
    }
    africa_countries = {
        "Algeria", "Angola", "Benin", "Botswana", "Burkina Faso", "Burundi",
        "Cabo Verde", "Cameroon", "Central African Republic", "Chad", "Comoros",
        "Congo", "Côte d'Ivoire", "Democratic Republic of the Congo", "Djibouti",
        "Equatorial Guinea", "Eritrea", "Eswatini", "Ethiopia", "Gabon", "Gambia",
        "Ghana", "Guinea", "Guinea-Bissau", "Ivory Coast", "Kenya", "Lesotho",
        "Liberia", "Libya", "Madagascar", "Malawi", "Mali", "Mauritania", "Mauritius",
        "Morocco", "Mozambique", "Namibia", "Niger", "Nigeria", "Republic of the Congo",
        "Rwanda", "São Tomé and Príncipe", "Senegal", "Seychelles", "Sierra Leone",
        "Somalia", "South Africa", "South Sudan", "Sudan", "Tanzania", "Togo",
        "Tunisia", "Uganda", "Zambia", "Zimbabwe", "Western Sahara",
    }
    north_america = {
        "Canada", "United States of America", "Mexico", "Belize", "Costa Rica",
        "El Salvador", "Guatemala", "Honduras", "Nicaragua", "Cuba", "Jamaica",
        "Haiti", "Dominican Republic", "Bahamas", "Barbados", "Dominica",
        "Grenada", "Saint Kitts and Nevis", "Saint Lucia",
        "Saint Vincent and the Grenadines", "Trinidad and Tobago",
        "Antigua and Barbuda", "Greenland",
    }
    south_america = {
        "Argentina", "Bolivia", "Brazil", "Chile", "Colombia", "Ecuador",
        "Guyana", "Paraguay", "Peru", "Suriname", "Uruguay", "Venezuela",
    }
    oceania = {
        "Australia", "Fiji", "Kiribati", "Marshall Islands", "Micronesia",
        "Nauru", "New Zealand", "Palau", "Papua New Guinea", "Samoa",
        "Solomon Islands", "Tonga", "Tuvalu", "Vanuatu",
    }

    if country_name in europe_countries:
        return "Europe"
    if country_name in asia_countries:
        return "Asia"
    if country_name in africa_countries:
        return "Africa"
    if country_name in north_america:
        return "North America"
    if country_name in south_america:
        return "South America"
    if country_name in oceania:
        return "Oceania"
    if country_name == "Antarctica":
        return "Antarctica"

    return "Unknown"


def assign_tier(tile_count):
    if tile_count > MAJOR_THRESHOLD:
        return "major"
    if tile_count > REGIONAL_THRESHOLD:
        return "regional"
    if tile_count > MINOR_THRESHOLD:
        return "minor"
    return "micro"


def continent_hue_range(continent):
    """Return (hue_start, hue_end) for each continent."""
    return {
        "Europe": (0.0, 0.08),          # Reds
        "Asia": (0.52, 0.65),           # Blues → teals
        "Africa": (0.08, 0.18),         # Oranges → golds
        "North America": (0.22, 0.35),  # Greens
        "South America": (0.65, 0.80),  # Purples → magentas
        "Oceania": (0.35, 0.52),        # Cyans → blue-greens
        "Antarctica": (0.90, 0.95),     # Pinks
        "Unknown": (0.0, 1.0),          # Full spectrum fallback
    }.get(continent, (0.0, 1.0))


def hsl_to_rgb(h, s, l):
    """Convert HSL to RGB. h in [0,1], s in [0,1], l in [0,1]."""
    if s == 0:
        return (l, l, l)

    def hue_to_rgb(p, q, t):
        if t < 0: t += 1
        if t > 1: t -= 1
        if t < 1/6: return p + (q - p) * 6 * t
        if t < 1/2: return q
        if t < 2/3: return p + (q - p) * (2/3 - t) * 6
        return p

    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
    return (hue_to_rgb(p, q, h + 1/3), hue_to_rgb(p, q, h), hue_to_rgb(p, q, h - 1/3))


def generate_palette(countries):
    """Generate deterministic palette for all countries."""
    palette = [(0.1, 0.2, 0.4, 0.0)] * PALETTE_SIZE  # Ocean default (transparent)
    palette[OCEAN_INDEX] = (0.1, 0.2, 0.5, 0.0)  # Ocean = fully transparent

    # Group countries by continent and tier
    by_continent = defaultdict(lambda: defaultdict(list))
    for cname, cdata in countries.items():
        continent = cdata["continent"]
        tier = cdata["tier"]
        by_continent[continent][tier].append((cname, cdata["tile_count"]))

    # Dynamic index ranges based on actual counts
    tier_counts = defaultdict(int)
    for cdata in countries.values():
        tier_counts[cdata["tier"]] += 1

    idx = 1
    tier_ranges = {}
    for tier in ["major", "regional", "minor", "micro"]:
        count = tier_counts.get(tier, 0)
        end = min(idx + count - 1, 254)
        tier_ranges[tier] = (idx, min(idx + max(count, 1) - 1, 254))
        idx = end + 1
        if idx > 254:
            break

    historical_range = (idx, 254) if idx <= 254 else (254, 254)

    # Assign within each (continent, tier) bucket
    next_idx_map = {t: start for t, (start, end) in tier_ranges.items()}

    for continent in ["Europe", "Asia", "Africa", "North America", "South America",
                       "Oceania", "Antarctica", "Unknown"]:
        hue_range = continent_hue_range(continent)
        hue_span = hue_range[1] - hue_range[0]

        for tier in ["major", "regional", "minor", "micro"]:
            tier_countries = sorted(by_continent[continent][tier],
                                    key=lambda x: -x[1])  # biggest first

            n = len(tier_countries)
            if n == 0:
                continue

            for i, (cname, tile_count) in enumerate(tier_countries):
                idx = next_idx_map[tier]

                tier_start, tier_end = tier_ranges[tier]
                if idx > tier_end:
                    # Overflow — push to next tier
                    print(f"  WARNING: palette overflow for {tier}, country {cname}")
                    continue

                # Hue: spread evenly within continent range
                if n > 1:
                    hue = hue_range[0] + (i / (n - 1)) * hue_span
                else:
                    hue = hue_range[0] + hue_span * 0.5

                # Saturation: larger countries more saturated
                max_tiles = max(tc for _, tc in tier_countries) if tier_countries else 1
                sat_ratio = tile_count / max(max_tiles, 1)
                saturation = 0.4 + 0.45 * sat_ratio  # 0.4-0.85

                # Lightness: varies by tier, slightly by size
                tier_base_light = {"major": 0.45, "regional": 0.50,
                                   "minor": 0.55, "micro": 0.58}[tier]
                lightness = tier_base_light + 0.05 * (1 - sat_ratio)

                r, g, b = hsl_to_rgb(hue, saturation, lightness)
                palette[idx] = (r, g, b, 0.7)

                countries[cname]["palette_index"] = idx

                next_idx_map[tier] += 1

    # Assign unclaimed
    palette[UNCLAIMED_INDEX] = (0.3, 0.3, 0.3, 0.0)

    return palette


def build_country_registry():
    """Main entry point."""
    print("=" * 60)
    print("Building Country Registry from Phase 4 data")
    print("=" * 60)

    # Load
    regions = load_index()
    print(f"\nLoaded {len(regions):,} regions from _index.yaml")

    # Aggregate
    countries = aggregate_countries(regions)
    print(f"Aggregated into {len(countries)} countries")

    # Assign metadata
    for cname, cdata in countries.items():
        cdata["continent"] = assign_continent(cname, cdata["tile_count"], cdata["region_count"])
        cdata["tier"] = assign_tier(cdata["tile_count"])

    # Show summary
    print("\nCountry tiers:")
    tier_counts = defaultdict(int)
    for cname, cdata in sorted(countries.items(), key=lambda x: -x[1]["tile_count"]):
        tier_counts[cdata["tier"]] += 1
    for tier in ["major", "regional", "minor", "micro"]:
        print(f"  {tier}: {tier_counts[tier]} countries")

    # Generate palette
    palette = generate_palette(countries)

    # Write country registry
    os.makedirs(COUNTRIES_DIR, exist_ok=True)

    registry = {
        "palette_size": PALETTE_SIZE,
        "ocean_index": OCEAN_INDEX,
        "unclaimed_index": UNCLAIMED_INDEX,
        "countries": [],
    }

    for cname in sorted(countries.keys()):
        cdata = countries[cname]
        registry["countries"].append({
            "id": cname,
            "palette_index": cdata.get("palette_index", 0),
            "tier": cdata["tier"],
            "continent": cdata["continent"],
            "tile_count": cdata["tile_count"],
            "region_count": cdata["region_count"],
            "admin2_count": cdata["admin2_count"],
        })

    registry_path = os.path.join(COUNTRIES_DIR, "country_registry.yaml")
    with open(registry_path, "w", encoding="utf-8") as f:
        yaml.dump(registry, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    print(f"\nCountry registry written: {registry_path}")
    print(f"  {len(registry['countries'])} countries with palette indices")

    # Also write as JSON for Godot (supports native JSON parsing)
    json_path = os.path.join(COUNTRIES_DIR, "country_registry.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(registry, f, indent=2)
    print(f"Country registry (JSON): {json_path}")

    # Write palette
    palette_data = {
        "size": PALETTE_SIZE,
        "colors": [
            {"index": i, "r": round(c[0], 4), "g": round(c[1], 4),
             "b": round(c[2], 4), "a": round(c[3], 4)}
            for i, c in enumerate(palette)
        ],
    }

    palette_path = os.path.join(COUNTRIES_DIR, "palette.json")
    with open(palette_path, "w", encoding="utf-8") as f:
        json.dump(palette_data, f, indent=2)
    print(f"Palette written: {palette_path}")

    # Quick sanity checks
    print("\nTop 10 countries by tile count:")
    top = sorted(countries.items(), key=lambda x: -x[1]["tile_count"])[:10]
    for cname, cdata in top:
        idx = cdata.get("palette_index", "?")
        print(f"  [{idx:3d}] {cname}: {cdata['tile_count']:,} tiles "
              f"({cdata['tier']}, {cdata['continent']})")

    # Neighbor check for bordering major countries
    major_countries = [(cname, cdata) for cname, cdata in countries.items()
                       if cdata["tier"] == "major"]
    print(f"\nNeighbor hue check ({len(major_countries)} major countries):")
    for i, (c1_name, c1_data) in enumerate(major_countries):
        for j in range(i + 1, len(major_countries)):
            c2_name, c2_data = major_countries[j]
            if c1_data["continent"] == c2_data["continent"]:
                idx1 = c1_data.get("palette_index", 0)
                idx2 = c2_data.get("palette_index", 0)
                # Approximate hue distance from palette colors
                r1, g1, b1 = palette[idx1][:3]
                r2, g2, b2 = palette[idx2][:3]
                hue1 = rgb_to_hue(r1, g1, b1)
                hue2 = rgb_to_hue(r2, g2, b2)
                dhue = abs(hue1 - hue2)
                if dhue > 0.5:
                    dhue = 1.0 - dhue
                if dhue < 0.05:
                    print(f"  ⚠ {c1_name} vs {c2_name}: hue distance = {dhue*360:.0f}°")

    print("\nDone.")


def rgb_to_hue(r, g, b):
    """Approximate hue from RGB."""
    mx = max(r, g, b)
    mn = min(r, g, b)
    if mx == mn:
        return 0
    d = mx - mn
    if mx == r:
        h = (g - b) / d + (6 if g < b else 0)
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return h / 6.0


if __name__ == "__main__":
    build_country_registry()
