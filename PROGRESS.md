# PROGRESS.md — Historia Terrarum 2

> Last updated: 2026-07-20 (session: HT2 rebuild — grid, land mask, terrain, climate, weather)

---

## HT2 Rebuild (2026-07-20)

**Restore point:** tag `ht1-final` → branch `ht2-rebuild`

### Phase 1: Git Fork & Bare Scaffold ✅

- [x] Tag ht1-final at commit fdc42c6
- [x] Create ht2-rebuild branch
- [x] Move HT1 code to `_legacy/` (palette, LOD, territories, UI, shaders, overlays)
- [x] Strip main.tscn to EarthDisplay + EarthCamera + Light + Environment
- [x] Simplify project.godot

### Phase 2: Deterministic Grid Math ✅

- [x] Rewrite `spherical_grid_generator.gd` — hardcoded 4096×2048
- [x] Halving chain: 4096→2048→1024→512→256→128→64→32→16→8
- [x] 8 triangular polar cells at each pole
- [x] 6,498,160 total tiles
- [x] seg=0 at prime meridian (lon=0°), matching GDScript mesh convention

### Phase 3: Land/Water Pipeline ✅

- [x] `generate_land_mask.py` — Natural Earth admin-0 polygons → `land_mask.bin`
- [x] `land_mask_loader.gd` — O(1) bit-packing reader
- [x] 1,887,685 land tiles (29.0%), 812 KB binary
- [x] `verify_land_mask.py` — London/Sahara/Pacific/South Atlantic checks
- [x] Fix: seg=0 at prime meridian (was dateline, 180° offset)
- [x] Fix: antimeridian epsilon nudge for polygon-edge misses

### Phase 4: Viewport-Culled Display ✅

- [x] Rewrite `earth_display.gd` — Earth sphere + culled cell mesh
- [x] 500 km visible radius around camera sub-point
- [x] Band-range optimization: ~100 visible bands out of 2048
- [x] Both land and ocean cells rendered (green/blue, opaque)
- [x] Lag: 1-2 FPS — performance optimization deferred

### Phase 5: Camera Integration ✅

- [x] `earth_camera.gd` from Stella Nostra — orbit, zoom rungs, momentum
- [x] Fix: `:=` → explicit types for Godot 4.6 warnings-as-errors
- [x] Fix: x-axis mirror — right-drag now orbits right

### Phase 6: Verification ✅

- [x] Grid structure: 2048 bands, 4096 equator, 8 polar ✅
- [x] Known points: London/LAND, Pacific/OCEAN, Sahara/LAND, S. Atlantic/OCEAN ✅
- [x] Land percentage: 29.0% (expected ~29.2%)

### Phase 8a: Terrain Pipeline (GEBCO 2024) ✅

- [x] `generate_terrain.py` — 7 GB GEBCO NetCDF → `terrain.bin` + `slope.bin`
- [x] 11 terrain types: deep_ocean through extreme_mountain
- [x] 5 slope types: flat/gentle/moderate/steep/cliff
- [x] `terrain_loader.gd` — O(1) byte lookup
- [x] 29.5% land from elevation (matches expected)
- [x] 6.5 MB each, 4 minutes runtime

### Phase 8b: Climate Pipeline (Beck Köppen-Geiger) ✅

- [x] `generate_climate.py` — Beck_KG_V1_0p0083.tif → `climate.bin`
- [x] 30 Köppen types: Af/Am/Aw, BWh/BWk/BSh/BSk, Csa/Csb/Csc, Cwa/Cwb/Cwc, Cfa/Cfb/Cfc, Dsa/Dsb/Dsc/Dsd, Dwa/Dwb/Dwc/Dwd, Dfa/Dfb/Dfc/Dfd, ET/EF
- [x] `climate_loader.gd` — O(1) byte lookup
- [x] Code 0 = ocean/marine (not classified)
- [x] Fix: label mapping corrected (Beck 1-30, not 1-31)
- [x] 6.5 MB, 5 minutes runtime

### Phase 8c: Weather Pipeline (WorldClim 2.1) ✅

- [x] `generate_weather.py` — 48 GeoTIFFs → `weather.bin`
- [x] 4 variables: tavg (°C×10), prec (mm), srad (kJ/m²/d), wind (m/s×10)
- [x] 12 monthly values per variable = 96 bytes/cell total
- [x] `weather_loader.gd` — O(1) lookup + day-level interpolation
- [x] 624 MB, tracked via Git LFS
- [x] Fix: wind raster float32 + nodata (-3.4e38) handling
- [x] 4 minutes runtime

---

## Current State

| Layer | Status | Size | Loader |
|-------|--------|------|--------|
| Grid | ✅ 4096×2048 | — | `spherical_grid_generator.gd` |
| Land/water | ✅ | 812 KB | `land_mask_loader.gd` |
| Terrain | ✅ | 6.5 MB | `terrain_loader.gd` |
| Climate | ✅ | 6.5 MB | `climate_loader.gd` |
| Weather | ✅ | 624 MB | `weather_loader.gd` |

**Total binary data: ~644 MB** (624 MB via Git LFS)

---

## Known Issues

| Issue | Status | Notes |
|-------|--------|-------|
| 1-2 FPS lag | Deferred | ~10K triangles rebuilt every 3 frames. Needs mesh pooling or static batching |
| Ocean band at dateline | ✅ Fixed | Antimeridian epsilon nudge in all pipelines |
| 180° longitude offset | ✅ Fixed | seg=0 now at prime meridian matching GDScript mesh |
| Camera x-axis reversed | ✅ Fixed | Mirrored orbit direction |
| Climate label mapping | ✅ Fixed | Beck et al. 2018 encoding (1-30, 0=ocean) |

---

## Next Steps (Post-Ready)

1. **Performance** — fix 1-2 FPS lag from per-frame mesh rebuild
2. **Visual toggles** — wire terrain/climate/weather loaders into earth_display.gd
   - T key: terrain colors
   - C key: climate overlay
   - W key: temperature map
   - P key: precipitation map
3. **Rivers** — re-implement river pipeline on new grid
4. **LoD pyramid** — multi-level zoom support
5. **Tile ownership** — territory system
6. **Timeline** — historical date engine

---

## Decisions Log (HT2)

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-20 | Full rebuild vs incremental refactor | HT1 code too complex (palettes, territories, LOD) |
| 2026-07-20 | Deterministic 4096×2048 grid | Guaranteed clean halving chain |
| 2026-07-20 | Binary land/water baked from shapefiles | Shapefiles never enter the game |
| 2026-07-20 | Viewport culling, no LOD pyramid | Simpler rendering, single mesh |
| 2026-07-20 | All data baked at build-time | Python pipelines + GDScript loaders, O(1) lookup |
| 2026-07-20 | seg=0 at prime meridian | Matches GDScript mesh from Stella Nostra |
| 2026-07-20 | Camera x-axis mirrored | Per user preference |
| 2026-07-20 | Git LFS for weather.bin | 624 MB exceeds GitHub 100 MB limit |
| 2026-07-20 | 4 weather variables (tavg, prec, srad, wind) | Per user request for comprehensive climate data |

---

## HT1 Archive

The original HT1 (Phases 1-11) is archived at tag `ht1-final` and in `_legacy/`. See the [HT1 PROGRESS.md](https://github.com/Brie-Wensleydale/historia-terrarum/blob/ht1-final/PROGRESS.md) for the full history.
