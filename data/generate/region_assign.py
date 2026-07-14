#!/usr/bin/env python3
"""
region_assign.py — Phase B: Assign Earth tiles to political regions at 10km.

Uses Natural Earth 10m shapefiles + tile_registry.json to produce
region YAML files with optional parent hierarchy for admin-2 subdivisions.

Strategies (from region_config.yaml):
  adm_0   — one region = whole country
  adm_1   — one region per province/state (Natural Earth admin-1)
  adm_2   — one region per county/district (Natural Earth admin-2),
            parent = admin-1 region looked up from admin-1 shapefile
  custom  — special handling (UK: use_subunits + admin-2)

Usage: python data/generate/region_assign.py

Requires: pip install shapely fiona pyyaml
"""

import json, math, os, sys, yaml
from collections import defaultdict

# ── Paths ─────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
DATA_DIR = os.path.join(PROJECT_ROOT, "data")
GRID_DIR = os.path.join(DATA_DIR, "output", "grid_10km")
REGISTRY_PATH = os.path.join(GRID_DIR, "tile_registry.json")
CONFIG_PATH = os.path.join(SCRIPT_DIR, "region_config.yaml")
REGIONS_DIR = os.path.join(DATA_DIR, "regions")
SHAPEFILE_DIR = os.path.join(DATA_DIR, "shapefiles")

# ── Thresholds ────────────────────────────────────────────────────
COASTAL_OFFSET_FRAC = 0.35  # offset test points at 35% of tile bbox
MIN_TILE_GUARANTEE = 1      # every territory gets at least 1 tile


def load_tile_registry():
    """Load the tile registry JSON. Returns dict and list of tile entries."""
    with open(REGISTRY_PATH) as f:
        registry = json.load(f)
    tiles = []
    for tid, data in registry.items():
        tiles.append({
            "id": tid,
            "band": data["band"],
            "segment": data["segment"],
            "lat": data["lat"],
            "lon": data["lon"],
            "bbox": data["bbox"],
        })
    return registry, tiles


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def load_country_shapes():
    """Load Natural Earth admin-0 shapefile."""
    try:
        import fiona
        from shapely.geometry import shape
    except ImportError:
        print("ERROR: Install dependencies: pip install shapely fiona pyyaml")
        sys.exit(1)

    countries_path = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_0_countries.shp")
    if not os.path.exists(countries_path):
        print(f"ERROR: Shapefile not found at {countries_path}")
        sys.exit(1)

    countries = []
    with fiona.open(countries_path) as src:
        for feat in src:
            props = feat["properties"]
            geom = shape(feat["geometry"])
            countries.append({
                "name": props.get("ADMIN", ""),
                "sovereign": props.get("SOVEREIGNT", ""),
                "iso_a2": props.get("ISO_A2", ""),
                "adm0_a3": props.get("ADM0_A3", ""),
                "type": props.get("TYPE", ""),
                "polygon": geom,
                "bbox": geom.bounds,
            })
    return countries


def load_province_shapes():
    """Load Natural Earth admin-1 shapefile."""
    import fiona
    from shapely.geometry import shape

    path = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_1_states_provinces.shp")
    if not os.path.exists(path):
        print(f"ERROR: Shapefile not found at {path}")
        sys.exit(1)

    provinces = []
    with fiona.open(path) as src:
        for feat in src:
            props = feat["properties"]
            geom = shape(feat["geometry"])
            provinces.append({
                "name": props.get("name", ""),
                "adm1_code": props.get("adm1_code", ""),
                "iso_3166_2": props.get("iso_3166_2", ""),
                "admin": props.get("admin", ""),
                "polygon": geom,
                "bbox": geom.bounds,
            })
    return provinces


def load_county_shapes():
    """Load Natural Earth admin-2 shapefile (counties/districts)."""
    import fiona
    from shapely.geometry import shape

    path = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_2_counties.shp")
    if not os.path.exists(path):
        print(f"  Admin-2 shapefile not found at {path}, skipping admin-2 support")
        return []

    counties = []
    with fiona.open(path) as src:
        for feat in src:
            props = feat["properties"]
            geom = shape(feat["geometry"])
            counties.append({
                "name": props.get("NAME", props.get("name", "")),
                "admin": props.get("ADMIN", props.get("admin", "")),
                "adm1_code": props.get("adm1_code", ""),
                "polygon": geom,
                "bbox": geom.bounds,
            })
    return counties


def load_subunit_shapes():
    """Load Natural Earth map_subunits shapefile."""
    import fiona
    from shapely.geometry import shape

    path = os.path.join(SHAPEFILE_DIR, "ne_10m_admin_0_map_subunits.shp")
    if not os.path.exists(path):
        print(f"  Subunit shapefile not found at {path}, skipping")
        return []

    subunits = []
    with fiona.open(path) as src:
        for feat in src:
            props = feat["properties"]
            geom = shape(feat["geometry"])
            subunits.append({
                "name": props.get("NAME", ""),
                "admin": props.get("ADMIN", ""),
                "polygon": geom,
                "bbox": geom.bounds,
            })
    return subunits


# ── ISO → country name mapping for GADM lookup ──
_ISO_MAP = {
    "ita": "Italy", "deu": "Germany", "aus": "Australia", "can": "Canada",
    "rus": "Russia", "chn": "China", "bra": "Brazil", "kaz": "Kazakhstan",
    "sdn": "Sudan", "cod": "Democratic Republic of the Congo", "mli": "Mali",
}


def load_gadm_counties():
    """
    Load GADM admin-2 shapefiles for countries we have data for.
    Returns dict: {country_name_lower: [county_dicts]} — same format as NE county_shapes.
    """
    import fiona
    from shapely.geometry import shape

    gadm_dir = os.path.join(SHAPEFILE_DIR, "gadm")
    gadm_counties = defaultdict(list)
    loaded = 0

    for iso3, country in _ISO_MAP.items():
        path = os.path.join(gadm_dir, f"gadm41_{iso3.upper()}_2.shp")
        if not os.path.exists(path):
            continue
        try:
            with fiona.open(path) as src:
                for feat in src:
                    props = feat["properties"]
                    name = props.get("NAME_2", "")
                    admin1 = props.get("NAME_1", "")
                    if not name:
                        continue
                    geom = shape(feat["geometry"])
                    gadm_counties[country.lower()].append({
                        "name": name,
                        "admin": country,
                        "admin1": admin1,
                        "polygon": geom,
                        "bbox": geom.bounds,
                    })
            loaded += 1
        except Exception as e:
            print(f"  WARNING: failed to load GADM for {iso3}: {e}")

    print(f"  GADM admin-2: {loaded} countries, {sum(len(v) for v in gadm_counties.values()):,} counties total")
    return dict(gadm_counties)


def _load_gadm_province_counties(gadm_list, prov_poly):
    """Find GADM admin-2 counties whose centroid is inside a province polygon."""
    result = {}
    for c in gadm_list:
        centroid = c["polygon"].centroid
        if prov_poly.contains(centroid):
            result[c["name"]] = c
    return result


def get_strategy(country_name, sovereign_name, config):
    """Determine the strategy for a country."""
    adm_0_list = [n.lower() for n in config.get("adm_0", [])]
    adm_2_list = [n.lower() for n in config.get("adm_2", [])]
    custom_dict = config.get("custom", {})
    ignore_list = [n.lower() for n in config.get("ignore", [])]

    if country_name.lower() in ignore_list:
        return "ignore", None

    if sovereign_name.lower() in ignore_list:
        return "ignore", None

    # Check custom
    for cname, cdata in custom_dict.items():
        if country_name.lower() == cname.lower():
            return "custom", cdata

    # Overseas territory: ADMIN != SOVEREIGNT → always split
    is_overseas = (country_name.lower() != sovereign_name.lower() and sovereign_name != "")

    # Check adm_2
    if country_name.lower() in adm_2_list:
        return "adm_2", None

    # Check adm_0
    if country_name.lower() in adm_0_list:
        return "adm_0", None

    # Overseas territories: separate region
    if is_overseas:
        return "overseas", None

    # Default: adm_1 for everything else
    return "adm_1", None


def find_parent_admin1(lat, lon, province_shapes, subunit_shapes, country_name, use_subunits=False):
    """
    For an admin-2 entity, find which admin-1 (or subunit) region contains its centroid.
    Used to set the 'parent' field for admin-2 regions.
    """
    from shapely.geometry import Point
    pt = Point(lon, lat)

    if use_subunits and subunit_shapes:
        for s in subunit_shapes:
            if s["polygon"].contains(pt):
                return s["name"]
        return None

    for p in province_shapes:
        if p["polygon"].contains(pt):
            return p["name"]

    return None


def test_tile_land(tile, country_shapes, province_shapes, county_shapes=None, subunit_shapes=None):
    """
    Determine which territory a tile belongs to.
    Uses 3-point majority test: center + 2 offset points.

    Returns:
      (country, province, sovereign, iso_a2, adm1_code, county_name, subunit_name, strategy_meta)
    strategy_meta = {"strategy": <str>, "custom_data": <dict or None>}
    """
    from shapely.geometry import Point

    if county_shapes is None:
        county_shapes = []
    if subunit_shapes is None:
        subunit_shapes = []

    lat = tile["lat"]
    lon = tile["lon"]
    bbox = tile["bbox"]

    # Compute offset points
    lat_span = bbox["lat_max"] - bbox["lat_min"]
    raw_lon_span = bbox["lon_max"] - bbox["lon_min"]
    lon_span = 360.0 - raw_lon_span if raw_lon_span > 180.0 else raw_lon_span
    dlat = lat_span * COASTAL_OFFSET_FRAC
    dlon = lon_span * COASTAL_OFFSET_FRAC

    test_points = [
        (lat, lon),
        (lat + dlat, lon + dlon),
        (lat - dlat, lon - dlon),
    ]

    # Test each point against countries
    country_votes = defaultdict(int)
    country_meta = {}

    for pt_lat, pt_lon in test_points:
        pt = Point(pt_lon, pt_lat)
        for c in country_shapes:
            minx, miny, maxx, maxy = c["bbox"]
            if pt_lon < minx or pt_lon > maxx or pt_lat < miny or pt_lat > maxy:
                continue
            if c["polygon"].contains(pt):
                country_votes[c["name"]] += 1
                country_meta[c["name"]] = c
                break

    if not country_votes:
        return None, None, None, None, None, None, None

    best_country = max(country_votes, key=country_votes.get)
    meta = country_meta[best_country]
    sovereign = meta["sovereign"]
    iso = meta["iso_a2"]

    # County votes (admin-2)
    county_name = None
    for pt_lat, pt_lon in test_points:
        pt = Point(pt_lon, pt_lat)
        for c in county_shapes:
            minx, miny, maxx, maxy = c["bbox"]
            if pt_lon < minx or pt_lon > maxx or pt_lat < miny or pt_lat > maxy:
                continue
            if c["polygon"].contains(pt):
                county_name = c["name"]
                break
        if county_name:
            break

    # Province votes (admin-1)
    province_votes = defaultdict(int)
    province_meta = {}

    for pt_lat, pt_lon in test_points:
        pt = Point(pt_lon, pt_lat)
        for p in province_shapes:
            minx, miny, maxx, maxy = p["bbox"]
            if pt_lon < minx or pt_lon > maxx or pt_lat < miny or pt_lat > maxy:
                continue
            if p["polygon"].contains(pt):
                province_votes[p["name"]] += 1
                province_meta[p["name"]] = p
                break

    if province_votes:
        best_province = max(province_votes, key=province_votes.get)
        pmeta = province_meta[best_province]
        province_name = best_province
        adm1_code = pmeta.get("iso_3166_2", "") or pmeta.get("adm1_code", "")
    else:
        province_name = None
        adm1_code = ""

    # Subunit votes
    subunit_name = None
    for pt_lat, pt_lon in test_points:
        pt = Point(pt_lon, pt_lat)
        for s in subunit_shapes:
            minx, miny, maxx, maxy = s["bbox"]
            if pt_lon < minx or pt_lon > maxx or pt_lat < miny or pt_lat > maxy:
                continue
            if s["polygon"].contains(pt):
                subunit_name = s["name"]
                break
        if subunit_name:
            break

    return best_country, province_name, sovereign, iso, adm1_code, county_name, subunit_name


def sanitize_id(s: str) -> str:
    """Remove special characters from region/file IDs."""
    for ch in " `'\"-().,&/\\:":
        s = s.replace(ch, "_")
    while "__" in s:
        s = s.replace("__", "_")
    return s.strip("_")


def build_region_id_and_parent(country, province, adm1_code, county_name, subunit_name,
                                strategy, custom_data, is_overseas, sovereign, config):
    """
    Build a stable region ID, name, and parent from assignment data.

    Returns (region_id, region_name, parent_id) or (None, None, None) for ignored.
    """
    if strategy == "ignore":
        return None, None, None

    if strategy == "overseas":
        rid = sanitize_id(country)
        rname = country
        if sovereign and sovereign != country:
            rname = f"{country} ({sovereign})"
        return rid, rname, None

    if strategy == "adm_2":
        # Admin-2: use county name, parent = admin-1 province
        if county_name:
            parent_name = province if province else country
            rid = sanitize_id(county_name)
            rname = county_name
            parent_id = sanitize_id(parent_name)
            return rid, rname, parent_id
        # Fallback to admin-1 if no county matched
        if province:
            return sanitize_id(province), province, None
        return sanitize_id(country), country, None

    if strategy == "custom" and custom_data:
        # UK: use_subunits + admin-2
        if custom_data.get("use_subunits"):
            # For admin-2 entities, parent = subunit
            if county_name and subunit_name:
                rid = sanitize_id(county_name)
                rname = county_name
                parent_id = sanitize_id(subunit_name)
                return rid, rname, parent_id
            # No county — just subunit
            if subunit_name:
                return sanitize_id(subunit_name), subunit_name, None
        # Other custom: match on adm1_code
        for region_def in custom_data.get("regions", []):
            if adm1_code in region_def.get("adm1_codes", []):
                return region_def["id"], region_def["name"], None
        # Fallback
        if province:
            return sanitize_id(province), province, None
        return sanitize_id(country), country, None

    # adm_1 or adm_0
    if province and strategy == "adm_1":
        return sanitize_id(province), province, None

    # adm_0: whole country
    return sanitize_id(country), country, None


def apply_one_tile_rule(assignments, region_names, region_countries, region_parents, country_shapes, tiles, config):
    """
    Ensure every legitimate territory has at least 1 tile.
    Skips countries already covered by sub-regions.
    """
    from shapely.geometry import Point

    ignore_list = [n.lower() for n in config.get("ignore", [])]
    adm_0_list = [n.lower() for n in config.get("adm_0", [])]
    adm_2_list = [n.lower() for n in config.get("adm_2", [])]
    custom_dict = config.get("custom", {})

    assigned_regions = set(assignments.keys())

    # Build set of all countries that have sub-region coverage
    countries_with_subregions = set()
    for rid in assigned_regions:
        parent = region_parents.get(rid)
        country = region_countries.get(rid, "")
        if parent:
            countries_with_subregions.add(parent.lower())
        countries_with_subregions.add(country.lower())

    # Find missing territories
    missing = []
    for c in country_shapes:
        name = c["name"]
        if name.lower() in ignore_list:
            continue

        rid = sanitize_id(name)
        if rid in assigned_regions:
            continue
        if name.lower() in countries_with_subregions:
            continue  # Covered by sub-regions

        # Skip non-sovereign/non-country types
        ctype = c.get("type", "")
        if ctype in ["Indeterminate", "Lease", "Dependency"]:
            continue
        if any(skip in name for skip in ["No Mans", "Ice Field", "Brazilian Island"]):
            continue

        missing.append((rid, name, c))

    if not missing:
        return assignments

    assigned_tile_list = set()
    for tiles_list in assignments.values():
        assigned_tile_list.update(tiles_list)

    unassigned_tiles = [t for t in tiles if t["id"] not in assigned_tile_list]

    for rid, tname, cdata in missing:
        poly = cdata["polygon"]
        centroid = poly.centroid
        best_tile = None
        best_dist = float("inf")
        for tile in unassigned_tiles:
            dlat = math.radians(tile["lat"] - centroid.y)
            dlon = math.radians(tile["lon"] - centroid.x)
            a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(centroid.y)) * math.cos(math.radians(tile["lat"])) * math.sin(dlon / 2) ** 2
            dist = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a)) * 6371
            if dist < best_dist:
                best_dist = dist
                best_tile = tile

        if best_tile:
            if rid not in assignments:
                assignments[rid] = []
            assignments[rid].append(best_tile["id"])
            region_names[rid] = tname
            region_countries[rid] = tname
            unassigned_tiles.remove(best_tile)
            print(f"  1-tile rule: {best_tile['id']} → {tname} (dist={best_dist:.0f}km)")

    return assignments


def _geometric_split_province(prov_poly, rid, rname, country, tile_list, tile_latlon,
                               registry, max_tiles, new_assignments, new_names,
                               new_countries, new_parents):
    """
    Geometric fallback: split a province polygon along its longest axis
    into N ≈ ceil(tiles/max_tiles) sub-regions using recursive BSP.
    Each sub-region's tiles are assigned by spatial containment.
    """
    n_splits = max(2, math.ceil(len(tile_list) / max_tiles))
    if n_splits < 2:
        return

    from shapely.ops import split
    from shapely.geometry import LineString

    # Compute the bounding box and decide split axis
    minx, miny, maxx, maxy = prov_poly.bounds
    dx = maxx - minx
    dy = maxy - miny
    split_horiz = dx > dy  # split along the longer axis

    # Recursively split into n_splits regions
    sub_polys = [prov_poly]
    while len(sub_polys) < n_splits:
        # Find the polygon with largest area to split
        largest_idx = max(range(len(sub_polys)), key=lambda i: sub_polys[i].area)
        largest = sub_polys[largest_idx]
        b = largest.bounds

        if b[2] - b[0] > b[3] - b[1]:  # wider than tall → vertical cut
            mid = (b[0] + b[2]) / 2
            cutter = LineString([(mid, b[1] - 1), (mid, b[3] + 1)])
        else:
            mid = (b[1] + b[3]) / 2
            cutter = LineString([(b[0] - 1, mid), (b[2] + 1, mid)])

        try:
            result = split(largest, cutter)
            if len(result.geoms) >= 2:
                sub_polys[largest_idx] = result.geoms[0]
                sub_polys.append(result.geoms[1])
            else:
                break  # can't split further
        except Exception:
            break

    if len(sub_polys) < 2:
        return

    # Assign tiles to sub-polygons
    from shapely.geometry import Point
    sub_tiles = {i: [] for i in range(len(sub_polys))}
    for tid in tile_list:
        lat, lon = tile_latlon.get(tid, (0, 0))
        pt = Point(lon, lat)
        for i, sp in enumerate(sub_polys):
            if sp.contains(pt):
                sub_tiles[i].append(tid)
                break

    # Create sub-regions
    for i, tiles in sub_tiles.items():
        if not tiles:
            continue
        cluster_name = sanitize_id(f"{rid}_{i+1}")
        new_assignments[cluster_name] = tiles
        new_names[cluster_name] = f"{rname} {i+1}"
        new_countries[cluster_name] = country
        new_parents[cluster_name] = rid

    # Keep parent with any unmatched tiles
    all_matched = set()
    for tiles in sub_tiles.values():
        all_matched.update(tiles)
    unmatched = [t for t in tile_list if t not in all_matched]
    if rid not in new_assignments:
        new_assignments[rid] = unmatched
        new_names[rid] = rname
        new_countries[rid] = country

    print(f"    → {len([t for t in sub_tiles.values() if t])} geometric splits")


def auto_split_mega_regions(assignments, region_names, region_countries, region_parents,
                             tiles, registry, config, province_shapes, county_shapes,
                             gadm_counties=None, tile_to_county=None):
    """
    Split any region with > max_tiles into contiguous admin-2 clusters.

    Uses adjacency-guaranteed agglomerative merging:
    1. Find admin-2 counties inside the province polygon
    2. Count tiles per county
    3. Build adjacency graph (shapely.touches)
    4. Agglomeratively merge smallest clusters first until all ≥ min_cluster
    5. Produce sub-regions with parent = original province name
    """
    from shapely.geometry import Point
    from collections import defaultdict as dd

    auto_cfg = config.get("auto_split", {})
    max_tiles_val = auto_cfg.get("max_tiles", 5000)
    min_cluster_val = auto_cfg.get("min_cluster", 2500)

    print(f"\nAuto-split: scanning for mega-provinces (> {max_tiles_val:,} tiles)...")

    # Load admin-2 counties with polygons (reload with full geometry for adjacency)
    # We need name, admin (country), polygon for adjacency testing
    county_polygons = {}   # county_name → {admin, polygon, bbox, centroid}
    for c in county_shapes:
        name = c["name"]
        if name:
            county_polygons[name] = {
                "admin": c.get("admin", ""),
                "polygon": c["polygon"],
                "bbox": c["bbox"],
                "centroid": c["polygon"].centroid,
            }

    # Build province polygon lookup: (country, sanitized_name) → polygon
    # Must key by country to avoid name collisions (e.g., Montana in Bulgaria vs US)
    province_polygons = {}
    for p in province_shapes:
        name = p["name"]
        admin = p.get("admin", "")
        if name and admin:
            province_polygons[(admin.lower(), sanitize_id(name))] = p["polygon"]

    # Build tile lat/lon lookup
    tile_latlon = {}
    for tid, tdata in registry.items():
        tile_latlon[tid] = (tdata["lat"], tdata["lon"])

    # Prepare result containers (we'll remove split regions and add new ones)
    new_assignments = {}
    new_names = {}
    new_countries = {}
    new_parents = {}

    splittable = []
    for rid, tile_list in assignments.items():
        # Only split top-level regions (no parent) — children of adm_2 are already granular
        if rid in region_parents and region_parents[rid]:
            continue
        if len(tile_list) > max_tiles_val:
            splittable.append((rid, len(tile_list), region_names.get(rid, rid),
                               region_countries.get(rid, "Unknown")))

    if not splittable:
        print(f"  No mega-provinces found (all ≤ {max_tiles_val:,} tiles)")
        return assignments, region_names, region_countries, region_parents

    splittable.sort(key=lambda x: -x[1])
    print(f"  Found {len(splittable)} mega-provinces to split:")

    split_set = {r[0] for r in splittable}

    for rid, tile_count, rname, country in splittable:
        print(f"\n  Splitting {rname} ({tile_count:,} tiles) [{country}]...")

        # Get the actual tile list for this region
        tile_list = assignments[rid]

        # Find the admin-1 polygon (keyed by country + sanitized name)
        prov_poly = province_polygons.get((country.lower(), rid))
        if prov_poly is None:
            print(f"    WARNING: no admin-1 polygon found for {rname}, skipping")
            continue

        # Find admin-2 counties inside this province
        province_counties = {}
        for cname, cdata in county_polygons.items():
            centroid = cdata["centroid"]
            if prov_poly.contains(centroid):
                province_counties[cname] = cdata

        if len(province_counties) < 2:
            print(f"    Only {len(province_counties)} NE admin-2 counties found", end="")
            # Try GADM admin-2 for this country
            if gadm_counties and country.lower() in gadm_counties:
                gadm_prov = _load_gadm_province_counties(gadm_counties[country.lower()],
                                                          prov_poly)
                if len(gadm_prov) >= 2:
                    province_counties = gadm_prov
                    print(f", using {len(province_counties)} GADM counties instead")
                    # Fall through to clustering code below
                else:
                    print(f", GADM also insufficient ({len(gadm_prov)}), geometric split")
                    _geometric_split_province(prov_poly, rid, rname, country, tile_list,
                                              tile_latlon, registry, max_tiles_val,
                                              new_assignments, new_names, new_countries, new_parents)
                    continue
            elif len(province_counties) == 0 and prov_poly is not None:
                print(f", falling back to geometric split")
                _geometric_split_province(prov_poly, rid, rname, country, tile_list,
                                          tile_latlon, registry, max_tiles_val,
                                          new_assignments, new_names, new_countries, new_parents)
            else:
                print(f", skipping")
            continue

        print(f"    {len(province_counties)} admin-2 counties inside province")

        # Count tiles per county.
        # For NE admin-2 (US): use tile_to_county from main assignment.
        # For GADM: do fast point-in-polygon lookup with bbox pre-filter.
        county_tile_count = dd(int)
        county_tile_list = dd(list)
        matched = 0

        # Build spatial index for fast point-in-polygon lookup
        from shapely.strtree import STRtree
        county_list = list(province_counties.keys())
        county_polys = [province_counties[c]["polygon"] for c in county_list]
        tree = STRtree(county_polys) if county_polys else None

        for tid in tile_list:
            # Try tile_to_county first (works for NE admin-2)
            cname = tile_to_county.get(tid) if tile_to_county else None
            if cname and cname in province_counties:
                county_tile_count[cname] += 1
                county_tile_list[cname].append(tid)
                matched += 1
                continue

            # Fallback: STRtree spatial index lookup (for GADM provinces)
            if not tree:
                continue
            tdata = registry.get(tid, {})
            lat = tdata.get("lat", 0)
            lon = tdata.get("lon", 0)
            if lat == 0 and lon == 0:
                continue
            pt = Point(lon, lat)
            # Query STRtree for nearby polygons, then test contains
            candidates = tree.query(pt)
            for cand_poly in candidates:
                if cand_poly.contains(pt):
                    # Find which county this polygon belongs to
                    for i, cpoly in enumerate(county_polys):
                        if cpoly is cand_poly:
                            cname = county_list[i]
                            county_tile_count[cname] += 1
                            county_tile_list[cname].append(tid)
                            matched += 1
                            break
                    break

        print(f"    {matched:,}/{len(tile_list):,} tiles matched to counties ({100*matched/max(len(tile_list),1):.1f}%)")

        # Filter: only counties with tiles
        active_counties = {c: n for c, n in county_tile_count.items() if n > 0}
        if len(active_counties) < 3:
            print(f"    Only {len(active_counties)} counties with tiles (too few to split), skipping")
            continue

        # Build adjacency graph
        adjacency = dd(set)
        county_list = list(active_counties.keys())
        for i, c1 in enumerate(county_list):
            poly1 = province_counties[c1]["polygon"]
            for j in range(i + 1, len(county_list)):
                c2 = county_list[j]
                poly2 = province_counties[c2]["polygon"]
                try:
                    if poly1.touches(poly2) or poly1.intersects(poly2):
                        adjacency[c1].add(c2)
                        adjacency[c2].add(c1)
                except Exception:
                    pass  # geometry error — skip this edge

        # Count connected components
        visited = set()
        components = []
        for cname in county_list:
            if cname in visited:
                continue
            comp = set()
            stack = [cname]
            while stack:
                cn = stack.pop()
                if cn in visited:
                    continue
                visited.add(cn)
                comp.add(cn)
                stack.extend(adjacency[cn] - visited)
            if comp:
                components.append(comp)

        print(f"    {len(components)} connected components")

        # Agglomerative merging per component
        cluster_id = 0
        clusters = {}  # cluster_name → {tiles, counties}
        unsplit_tiles = 0

        for comp in components:
            # Initialize: each county = its own cluster
            comp_clusters = {}
            for cname in comp:
                comp_clusters[cname] = {
                    "tiles": county_tile_list.get(cname, []),
                    "tile_count": county_tile_count.get(cname, 0),
                    "counties": {cname},
                    "neighbors": set(adjacency.get(cname, set())) & comp,
                }

            # Agglomeratively merge smallest with smallest neighbor
            changed = True
            while changed:
                changed = False
                # Find smallest cluster below min_cluster
                small = [(cid, cd) for cid, cd in comp_clusters.items()
                         if cd["tile_count"] < min_cluster_val and cd["tile_count"] > 0]
                if not small:
                    break
                small.sort(key=lambda x: x[1]["tile_count"])

                for scid, scdata in small:
                    if scid not in comp_clusters:
                        continue
                    # Find best neighbor to merge with (smallest neighbor)
                    best_neighbor = None
                    best_size = float("inf")
                    for nid in scdata["neighbors"]:
                        if nid in comp_clusters:
                            ns = comp_clusters[nid]["tile_count"]
                            if ns < best_size:
                                best_size = ns
                                best_neighbor = nid
                    if best_neighbor is None:
                        continue

                    # Merge
                    ndata = comp_clusters[best_neighbor]
                    new_id = f"{best_neighbor}+{scid}"
                    comp_clusters[new_id] = {
                        "tiles": ndata["tiles"] + scdata["tiles"],
                        "tile_count": ndata["tile_count"] + scdata["tile_count"],
                        "counties": ndata["counties"] | scdata["counties"],
                        "neighbors": (ndata["neighbors"] | scdata["neighbors"]) - {scid, best_neighbor},
                    }
                    # Update neighbors pointing to scid or best_neighbor
                    for cid in comp_clusters:
                        if cid == new_id:
                            continue
                        nbrs = comp_clusters[cid]["neighbors"]
                        if scid in nbrs or best_neighbor in nbrs:
                            nbrs.discard(scid)
                            nbrs.discard(best_neighbor)
                            nbrs.add(new_id)
                    del comp_clusters[scid]
                    del comp_clusters[best_neighbor]
                    changed = True
                    break  # restart scan after merge

            # Assign cluster names: largest county in each cluster
            for cid, cdata in comp_clusters.items():
                best_cname = max(cdata["counties"], key=lambda c: county_tile_count.get(c, 0))
                cluster_name = sanitize_id(f"{rname}_{best_cname}")
                clusters[cluster_name] = cdata

        # Move non-matching tiles (outside any admin-2 polygon) to parent
        matched_tiles = set()
        for cdata in clusters.values():
            matched_tiles.update(cdata["tiles"])
        unmatched = [t for t in tile_list if t not in matched_tiles]
        if unmatched:
            unsplit_tiles = len(unmatched)

        # Replace the mega-region with clusters
        if len(clusters) >= 2:
            for cluster_name, cdata in clusters.items():
                new_assignments[cluster_name] = cdata["tiles"]
                new_names[cluster_name] = cluster_name.replace("_", " ")
                new_countries[cluster_name] = country
                new_parents[cluster_name] = rid

            # Keep parent with unmatched tiles
            if rid not in new_assignments:
                new_assignments[rid] = unmatched
                new_names[rid] = rname
                new_countries[rid] = country

            print(f"    → {len(clusters)} contiguous clusters"
                  f"{f' (+{unsplit_tiles} unmatched tiles in parent)' if unsplit_tiles else ''}")
        else:
            # Only 1 cluster — not enough to split meaningfully, use geometric
            print(f"    → only 1 cluster with agglomerative, falling back to geometric split")
            _geometric_split_province(prov_poly, rid, rname, country, tile_list,
                                      tile_latlon, registry, max_tiles_val,
                                      new_assignments, new_names, new_countries, new_parents)

    # Copy non-split regions
    copies = 0
    for rid, tile_list in assignments.items():
        if rid not in split_set or rid not in new_assignments:
            new_assignments[rid] = tile_list
            new_names[rid] = region_names.get(rid, rid)
            new_countries[rid] = region_countries.get(rid, "Unknown")
            if rid in region_parents:
                new_parents[rid] = region_parents[rid]
            copies += 1
        else:
            # Was split — keep the entry from new_assignments
            pass

    total_new = len(new_assignments)
    splits = len(splittable)
    print(f"\n  Auto-split complete: {splits} mega-provinces split")
    print(f"  Regions before: {len(assignments)} → after: {total_new} (+{total_new - len(assignments)})")
    return new_assignments, new_names, new_countries, new_parents


def write_region_files(assignments, region_names, region_countries, region_parents, config):
    """Write region YAML files and _index.yaml with parent hierarchy."""
    os.makedirs(REGIONS_DIR, exist_ok=True)

    # Clean up old region files
    for fname in os.listdir(REGIONS_DIR):
        if fname.endswith(".yaml"):
            try:
                os.remove(os.path.join(REGIONS_DIR, fname))
            except OSError:
                pass

    # Also write parent regions (empty — just metadata, tiles come from children)
    # Unless auto-split left unmatched tiles in the parent
    all_parents = set()
    for rid in region_parents:
        pid = region_parents[rid]
        if pid and pid not in assignments:
            all_parents.add(pid)

    for pid in all_parents:
        # Find country by looking at children
        parent_country = "Unknown"
        for rid, p in region_parents.items():
            if p == pid and rid in region_countries:
                parent_country = region_countries[rid]
                break
        assignments[pid] = []
        region_names[pid] = pid.replace("_", " ")
        region_countries[pid] = parent_country

    index_entries = []

    for rid, tile_list in sorted(assignments.items()):
        rname = region_names.get(rid, rid)
        parent = region_parents.get(rid)
        country = region_countries.get(rid, "Unknown")

        filepath = os.path.join(REGIONS_DIR, f"{rid}.yaml")
        entry = {
            "id": rid,
            "name": rname,
            "type": "province",
            "country": country,
        }
        if parent:
            entry["parent"] = parent
        if tile_list:
            entry["tiles"] = sorted(set(tile_list))

        with open(filepath, "w") as f:
            yaml.dump(entry, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

        index_entries.append({
            "id": rid,
            "country": country,
            "parent": parent,
            "file": f"{rid}.yaml",
            "tile_count": len(entry.get("tiles", [])),
        })

    # Write index
    index_path = os.path.join(REGIONS_DIR, "_index.yaml")
    index_data = {"regions": sorted(index_entries, key=lambda e: (e.get("country", ""), e["id"]))}
    with open(index_path, "w") as f:
        yaml.dump(index_data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

    print(f"\nWrote {len(assignments)} region files to {REGIONS_DIR}/")
    print(f"  ({len(all_parents)} parent regions without direct tiles)")
    print(f"Index: {index_path}")


def main():
    print("=" * 60)
    print("Historia Terrarum — Region Assignment (10km grid)")
    print("=" * 60)
    print()

    # Load data
    print("Loading tile registry...")
    registry, tiles = load_tile_registry()
    print(f"  {len(tiles):,} tiles loaded")

    print("Loading Natural Earth shapefiles...")
    country_shapes = load_country_shapes()
    print(f"  {len(country_shapes)} countries (admin-0)")
    province_shapes = load_province_shapes()
    print(f"  {len(province_shapes)} provinces (admin-1)")
    county_shapes = load_county_shapes()
    print(f"  {len(county_shapes)} counties (admin-2)")
    subunit_shapes = load_subunit_shapes()
    print(f"  {len(subunit_shapes)} subunits")

    config = load_config()
    adm_0_list = [n.lower() for n in config.get("adm_0", [])]
    adm_2_list = [n.lower() for n in config.get("adm_2", [])]
    ignore_list = [n.lower() for n in config.get("ignore", [])]
    custom_dict = config.get("custom", {})

    # Load GADM admin-2 (supplements US-only Natural Earth admin-2)
    print("Loading GADM admin-2 shapefiles...")
    gadm_counties = load_gadm_counties()

    # Merge GADM counties into county_shapes ONLY for adm_2 countries
    # (Natural Earth admin-2 is US-only, so adm_2 countries need GADM for the main assignment)
    # Auto-split loads GADM separately via gadm_counties dict — doesn't need to be in main pool.
    if gadm_counties:
        adm_2_set = set(adm_2_list)
        gadm_merged = 0
        for country_key, clist in gadm_counties.items():
            if country_key in adm_2_set:
                for c in clist:
                    county_shapes.append(c)
                    gadm_merged += 1
        print(f"  Merged {gadm_merged:,} GADM counties into assignment pool (adm_2 countries only)")

    print(f"\nStrategies: adm_0={len(adm_0_list)}, adm_2={len(adm_2_list)}, "
          f"custom={len(custom_dict)}, ignore={len(ignore_list)}, "
          f"default adm_1 for remaining ~{len(country_shapes) - len(adm_0_list) - len(adm_2_list) - len(custom_dict) - len(ignore_list)}")

    # Assign tiles to regions
    print("\nAssigning tiles to regions (3-point majority test)...")
    assignments = defaultdict(list)  # region_id → [tile_list]
    region_names = {}                # region_id → display name
    region_countries = {}            # region_id → country
    region_parents = {}              # region_id → parent_id (for admin-2)

    ocean_tiles = 0
    land_tiles = 0
    total = len(tiles)
    report_every = max(total // 20, 1)
    tile_to_county = {}  # tile_id → county_name (from 3-point test during main loop)

    for i, tile in enumerate(tiles):
        if (i + 1) % report_every == 0:
            pct = (i + 1) * 100 / total
            print(f"  {pct:.0f}% ({i+1:,}/{total:,}) — {len(assignments)} regions, "
                  f"{land_tiles:,} land, {ocean_tiles:,} ocean")

        result = test_tile_land(tile, country_shapes, province_shapes, county_shapes, subunit_shapes)
        if result is None:
            continue

        country, province, sovereign, iso, adm1_code, county_name, subunit_name = result
        if country is None:
            ocean_tiles += 1
            continue
        land_tiles += 1

        # Save county assignment for auto-split
        if county_name:
            tile_to_county[tile["id"]] = county_name

        strategy, custom_data = get_strategy(country, sovereign, config)
        is_overseas = (country.lower() != sovereign.lower() and sovereign != "")

        rid, rname, parent = build_region_id_and_parent(
            country, province, adm1_code, county_name, subunit_name,
            strategy, custom_data, is_overseas, sovereign, config
        )

        if rid is None:
            continue  # ignored

        if rid not in assignments:
            assignments[rid] = []
        assignments[rid].append(tile["id"])
        region_names[rid] = rname
        region_countries[rid] = country
        if parent:
            region_parents[rid] = parent

    print(f"\n  Land tiles: {land_tiles:,}")
    print(f"  Ocean tiles: {ocean_tiles:,}")
    print(f"  Regions: {len(assignments)}")
    print(f"  With parents: {len(region_parents)}")

    # Apply 1-tile guarantee
    print("\nApplying 1-tile minimum guarantee...")
    assignments = apply_one_tile_rule(assignments, region_names, region_countries,
                                      region_parents, country_shapes, tiles, config)

    # Auto-split mega-provinces using admin-2 clustering
    auto_split = config.get("auto_split", {})
    if auto_split:
        assignments, region_names, region_countries, region_parents = \
            auto_split_mega_regions(assignments, region_names, region_countries,
                                    region_parents, tiles, registry, config,
                                    province_shapes, county_shapes, gadm_counties,
                                    tile_to_county)

    # Write output
    print("\nWriting region files...")
    write_region_files(assignments, region_names, region_countries, region_parents, config)

    # Summary stats
    print(f"\n{'=' * 60}")
    print(f"Done. {land_tiles:,} land tiles → {len(assignments)} regions.")
    print(f"  Admin-2 regions with parents: {len(region_parents)}")
    total_assigned = sum(len(t) for t in assignments.values())
    print(f"  Total assigned tiles: {total_assigned:,}")


if __name__ == "__main__":
    main()
