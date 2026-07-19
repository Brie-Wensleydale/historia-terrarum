# Terrain, Climate & Weather — Implementation Plan

> **For Hermes:** Do NOT execute. Await user confirmation.

**Goal:** Classify every 10km grid cell with terrain type, Köppen climate zone, and annual temperature/precipitation cycle. All data is pre-baked at build time from global rasters → compact binary files → per-cell lookup at runtime (~50ns). Same `land_mask.bin` pattern.

**Architecture:** Three independent Python pipelines, each: download geospatial raster → sample at tile centers → classify → write compact binary. GDScript loaders provide `get_terrain(band, seg)`, `get_climate(band, seg)`, `get_monthly_temp(band, seg, month)`, `get_monthly_precip(band, seg, month)`. Visualisation: terrain = cell colour tint, climate = optional overlay, weather = seasonal effects on movement/attrition (gameplay, not visuals yet).

**Tech Stack:** Python (rasterio, numpy, shapely), GDScript (binary loaders), Godot 4.6.3.

---

## 1. Terrain

### Data Source
**GEBCO 2024** — global bathymetry/topography grid.
- URL: `https://www.bodc.ac.uk/data/open_download/gebco/gebco_2024/zip/`
- Format: GeoTIFF, 15 arc-second (~450m at equator)
- Size: ~3 GB download, ~25 GB uncompressed
- Coverage: global (land + ocean floor)
- Our cells are ~10 km → ~22 GEBCO samples per cell → average or median elevation per cell

### Terrain Classification

```python
TERRAIN_TYPES = {
    0:  "deep_ocean",         # < -4000m
    1:  "ocean",              # -4000 to -1000m
    2:  "shallow_ocean",      # -1000 to -200m
    3:  "continental_shelf",  # -200 to 0m
    4:  "coastal",            # 0 to 20m
    5:  "lowland",            # 20 to 200m
    6:  "upland",             # 200 to 500m
    7:  "highland",           # 500 to 1000m
    8:  "mountain",           # 1000 to 2000m
    9:  "high_mountain",      # 2000 to 4000m
    10: "extreme_mountain",   # > 4000m
}
```

Classification based on **median elevation** of all GEBCO samples within the cell's bounding box. For a 10km cell at the equator, this is ~22×22 = ~484 samples — median is robust against edge-of-cliff artifacts.

### Slope (Secondary Terrain Attribute)
From the same elevation data: compute max slope within the cell. Classify:
- Flat (< 2°), Gentle (2-5°), Moderate (5-15°), Steep (15-30°), Cliff (> 30°)

### Pipeline Script
`data/generate/generate_terrain.py`:
1. Download/extract GEBCO GeoTIFF (user provides path or script downloads)
2. For each tile: read GEBCO window around tile center → compute median elevation → classify terrain + slope
3. Output: `data/output/grid_10km_ht2/terrain.bin` (~6.5 MB, 1 byte/cell) + `terrain_summary.json`

### GDScript Loader
`game/scripts/data/terrain_loader.gd`:
```gdscript
func get_terrain(band: int, seg: int) -> int      # 0-10
func get_terrain_name(band: int, seg: int) -> String
func get_slope(band: int, seg: int) -> int         # 0-4
func is_land(band: int, seg: int) -> bool           # shorthand: terrain >= COASTAL
```

Note: `terrain_loader.is_land()` can eventually replace `land_mask_loader.is_land()` — terrain already encodes land/ocean via elevation threshold. Keep land_mask for now as the canonical binary mask; terrain is derived independently.

### Terrain Colours (Visualisation)
Replace current `LAND_COLOR`/`OCEAN_COLOR` constants with terrain-indexed colours:
```gdscript
const TERRAIN_COLORS := [
    Color(0.02, 0.10, 0.35),  # deep ocean
    Color(0.05, 0.20, 0.55),  # ocean
    Color(0.10, 0.35, 0.65),  # shallow ocean
    Color(0.15, 0.45, 0.70),  # continental shelf
    Color(0.85, 0.80, 0.40),  # coastal
    Color(0.30, 0.70, 0.30),  # lowland
    Color(0.40, 0.60, 0.25),  # upland
    Color(0.55, 0.50, 0.20),  # highland
    Color(0.45, 0.35, 0.20),  # mountain
    Color(0.60, 0.50, 0.45),  # high mountain
    Color(0.90, 0.90, 0.90),  # extreme mountain
]
```

---

## 2. Climate (Köppen-Geiger)

### Data Source
**Beck et al. 2018** — Present and future Köppen-Geiger climate classification maps at 1-km resolution.
- Paper: https://www.nature.com/articles/sdata2018214
- Download: https://globe.umbc.edu/apps/ckan/organization/koeppen-geiger.html (GeoTIFF, ~7 MB)
- Resolution: 30 arc-second (~1km at equator)
- Classification: 30 climate types in 5 main groups

### Köppen Classification Groups

| Group | Name | Subtypes |
|-------|------|----------|
| A | Tropical | Af (rainforest), Am (monsoon), Aw (savanna) |
| B | Arid | BWh (hot desert), BWk (cold desert), BSh (hot semi-arid), BSk (cold semi-arid) |
| C | Temperate | Cfa (humid subtropical), Cfb (oceanic), Cfc (subpolar oceanic), Csa (hot-summer Mediterranean), Csb (warm-summer Mediterranean), Csc (cool-summer Mediterranean), Cwa (monsoon-influenced humid subtropical), Cwb (subtropical highland) |
| D | Continental | Dfa (hot-summer humid continental), Dfb (warm-summer humid continental), Dfc (subarctic), Dfd (extremely cold subarctic), Dwa (monsoon-influenced hot-summer), Dwb (monsoon-influenced warm-summer), Dwc (monsoon-influenced subarctic), Dwd (monsoon-influenced extremely cold) |
| E | Polar | ET (tundra), EF (ice cap) |

### Pipeline Script
`data/generate/generate_climate.py`:
1. Load Beck et al. Köppen GeoTIFF (~7 MB — tiny, can be committed to repo)
2. For each tile: sample raster at tile center (single pixel — 1km is well within 10km cell)
3. Output: `data/output/grid_10km_ht2/climate.bin` (~6.5 MB, 1 byte/cell) + `climate_summary.json`

### GDScript Loader
`game/scripts/data/climate_loader.gd`:
```gdscript
func get_climate(band: int, seg: int) -> int         # 0-29
func get_climate_group(band: int, seg: int) -> String  # "Tropical", "Arid", etc.
func get_climate_name(band: int, seg: int) -> String   # "Cfb", "Aw", etc.
```

---

## 3. Weather (Annual Temperature & Precipitation Cycle)

### Data Source
**WorldClim 2.1** — Monthly climate data for 1970-2000.
- URL: https://www.worldclim.org/data/worldclim21.html
- Variables: monthly average temperature (°C × 10), monthly precipitation (mm)
- Resolution: 30 arc-second (~1km)
- Files: 12 GeoTIFFs for temp (~400 MB each uncompressed), 12 for precip (~400 MB each)
- Total: ~10 GB uncompressed, ~2 GB compressed download

### Sampling Strategy
For each 10km cell:
1. Sample WorldClim pixel at tile center
2. Store 12 monthly temperature values + 12 monthly precipitation values

### Storage Format (Compact)
**Option A — Full resolution (recommended):**
Store all values per cell. Total: 6.5M cells × 24 values (12 temp + 12 precip) × 2 bytes (int16) = ~312 MB. This is large but:
- Data is committed and never changes
- Laptop loads it once at startup (~300ms from SSD)
- No interpolation overhead at runtime

**Option B — Downsampled + interpolation:**
Store at 100km resolution (~62K cells × 48 bytes = ~3 MB). At runtime, for a 10km cell, find the 4 nearest 100km cells and bilinearly interpolate. Saves storage but adds runtime cost.

**Recommendation:** Use Option A (full resolution). 312 MB is acceptable for a desktop/laptop game. Can be compressed with zstd to ~80 MB if needed.

### Binary Format
```python
# Per cell: 12 × int16 (temp) + 12 × int16 (precip) = 48 bytes per cell
# Total: 6,498,160 × 48 = 311,911,680 bytes (~298 MB)
# Format: [t_jan, t_feb, ..., t_dec, p_jan, p_feb, ..., p_dec] × N_cells
# Each int16: temperature in °C × 10 (range -500 to +500), precipitation in mm (range 0 to 65535)
```

### Pipeline Script
`data/generate/generate_weather.py`:
1. Download WorldClim monthly GeoTIFFs (12 temp + 12 precip = 24 files)
2. For each tile: sample all 24 rasters at tile center
3. Output: `data/output/grid_10km_ht2/weather.bin` (~298 MB) + `weather_summary.json`

### GDScript Loader
`game/scripts/data/weather_loader.gd`:
```gdscript
func get_monthly_temp(band: int, seg: int, month: int) -> float       # 0=Jan, 11=Dec, °C
func get_monthly_precip(band: int, seg: int, month: int) -> float     # mm
func get_annual_temp(band: int, seg: int) -> float                    # annual mean
func get_annual_precip(band: int, seg: int) -> float                  # annual total
func get_growing_season_months(band: int, seg: int) -> Array           # months where tavg > 5°C
```

---

## 4. Data Pipeline Architecture (Unified Pattern)

All three pipelines follow the exact same pattern as `generate_land_mask.py`:

```
┌─────────────────────────────────────────────────────────┐
│  BUILD-TIME PIPELINE  (Python, runs ONCE on desktop)     │
│                                                         │
│  GeoTIFF raster  ──→  sample at tile centers  ──→  .bin │
│  (global dataset)      (6.5M points)              (compact)│
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  RUNTIME  (Godot, loaded at startup)                    │
│                                                         │
│  .bin file  ──→  PackedByteArray  ──→  O(1) lookup     │
│  (~300 MB)       (kept in memory)      (~50ns)          │
└─────────────────────────────────────────────────────────┘
```

### File Sizes (6.5M tiles)

| Dataset | Bits/cell | File size | Data source |
|---------|-----------|-----------|-------------|
| Land mask | 1 bit | ~812 KB | Natural Earth admin-0 |
| Terrain | 8 bits | ~6.5 MB | GEBCO 2024 |
| Climate | 8 bits | ~6.5 MB | Beck et al. 2018 Köppen |
| Weather | 384 bits | ~298 MB | WorldClim 2.1 |
| **Total** | | **~312 MB** | |

### Directory Structure
```
data/output/grid_10km_ht2/
├── land_mask.bin              # 812 KB  (Phase 3 — done)
├── land_mask_summary.json
├── terrain.bin                # 6.5 MB  (Phase 8a)
├── terrain_summary.json
├── climate.bin                # 6.5 MB  (Phase 8b)
├── climate_summary.json
├── weather.bin                # 298 MB  (Phase 8c)
└── weather_summary.json

data/raster/                   # Downloaded GeoTIFFs (gitignored)
├── gebco_2024.tif             # ~3 GB
├── beck_koppen_2018.tif       # ~7 MB
├── wc2.1_tavg_01.tif ... 12   # WorldClim monthly temp
└── wc2.1_prec_01.tif ... 12   # WorldClim monthly precip

game/scripts/data/
├── land_mask_loader.gd        # Phase 3 (done)
├── terrain_loader.gd          # Phase 8a
├── climate_loader.gd          # Phase 8b
└── weather_loader.gd          # Phase 8c

data/generate/
├── generate_land_mask.py      # Phase 3 (done)
├── generate_terrain.py        # Phase 8a
├── generate_climate.py        # Phase 8b
└── generate_weather.py        # Phase 8c
```

---

## 5. Implementation Phases

### Phase 8a: Terrain Pipeline
1. Download GEBCO 2024 GeoTIFF (~3 GB, one-time)
2. Write `generate_terrain.py` — sample elevation, classify, output `terrain.bin`
3. Write `terrain_loader.gd` — `get_terrain()`, `get_slope()`
4. Update `earth_display.gd` — use terrain colours instead of flat land/ocean
5. Verify: run pipeline, check Himalayas→high_mountain, Pacific→deep_ocean, Netherlands→lowland

### Phase 8b: Climate Pipeline
1. Download Beck et al. Köppen GeoTIFF (~7 MB — commit to repo)
2. Write `generate_climate.py` — sample classification, output `climate.bin`
3. Write `climate_loader.gd` — `get_climate()`, `get_climate_group()`
4. Add climate overlay toggle (keyboard shortcut) — tint cells by climate zone
5. Verify: check Sahara→BWh, Amazon→Af, London→Cfb, Siberia→Dfc

### Phase 8c: Weather Pipeline
1. Download WorldClim monthly GeoTIFFs (~2 GB compressed)
2. Write `generate_weather.py` — sample all 24 monthly rasters, output `weather.bin`
3. Write `weather_loader.gd` — monthly temp/precip lookup
4. Add season visualisation toggle — tint by current month temperature
5. Verify: July→Sahara hot/dry, January→Siberia cold/dry

### Phase 8d: Integration & Visualisation
1. Unified `cell_data_loader.gd` that loads all datasets and provides combined queries
2. Terrain-coloured cell mesh (replace flat green/blue)
3. Toggle keys: T=terrain, C=climate, W=weather (temperature), P=precipitation
4. Hover tooltip showing all cell attributes
5. Performance: verify 312 MB loads in < 500ms on laptop

---

## 6. Risks & Tradeoffs

1. **GEBCO download (3 GB):** Large but one-time. Could sample a lower-resolution version (30 arc-second) if bandwidth is a concern.

2. **Weather data size (298 MB):** Largest file. Option B (100km + interpolation) would be ~3 MB but adds runtime cost. Recommend full resolution — 300 MB is acceptable for a desktop game in 2026.

3. **Raster alignment:** All three datasets use different projections and resolutions. GEBCO is EPSG:4326, Köppen is EPSG:4326, WorldClim is EPSG:4326 — all WGS84 lat/lon, so alignment is straightforward. Just need to handle pixel-is-point vs pixel-is-area conventions.

4. **Cell coverage at poles:** At the 8-cell polar wedge, terrain/climate/weather sampling needs special handling. The tile center lat/lon computation already works for all bands; just verify the northernmost/southernmost bands sample correctly (no out-of-bounds raster access near ±90°).

5. **Pipeline runtime:** Terrain pipeline (sampling 484 GEBCO pixels × 6.5M cells) could be very slow. Mitigation: read GEBCO into a numpy memmap, use vectorized sampling with nearest-neighbour, batch by band for memory locality. Estimated 15-30 minutes for full terrain pipeline.

6. **Disk space:** ~25 GB for uncompressed GEBCO GeoTIFF during pipeline run. Delete after `terrain.bin` is generated. The game only needs the ~312 MB of `.bin` files.

---

## 7. What's NOT in Scope

- Wind patterns (ERA5) — complex vector field, defer to future phase
- Humidity — derivable from temperature + precipitation if needed
- Seasonal snow/ice cover — can be inferred from temperature + precipitation
- River/lake mapping — separate phase (requires hydrography data)
- Biome classification (e.g., Holdridge) — derivable from terrain + climate + weather
- Dynamic weather simulation — purely static annual cycle for now

---

**Total estimated implementation time:** 6-8 hours (agent work)
**Total new files:** 6 Python scripts + 6 GDScript loaders
**Total new data:** ~312 MB across 3 binary files
