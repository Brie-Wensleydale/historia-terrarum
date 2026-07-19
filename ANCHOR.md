# Project Anchor: Historia Terrarum 2

## 1. Vision & Purpose

A grand strategy game where players control a nation throughout history. **HT2 is a from-scratch rebuild** — clean, minimal, and correct.

The Earth is divided into a deterministic spherical grid:
- **4,096 segments at the equator** (~9.77 km wide)
- **2,048 vertical bands** (~9.77 km tall)
- Halving toward poles: `4096 → 2048 → 1024 → 512 → 256 → 128 → 64 → 32 → 16 → 8`
- **8 triangular cells** at each pole
- **~6.5M total tiles**

Every cell carries pre-baked data: land/water, terrain type, Köppen climate, monthly temperature, precipitation, solar radiation, and wind speed. All pipelines are build-time only — data is baked into compact binary files and loaded at startup with O(1) per-cell lookup.

- **Working directory:** `D:\hermes-projects\historia-terrarum\`
- **Godot engine:** 4.6.3
- **Restore point:** tag `ht1-final` (original Historia Terrarum, Phase 1-11)
- **Active branch:** `ht2-rebuild`
- **Camera:** Stella Nostra orbit camera (right-drag orbit, scroll zoom, momentum)
- **Git LFS:** enabled for `weather.bin`

---

## 2. Architecture

### 2.1 Grid System

| Property | Value |
|----------|-------|
| Equator segments | 4,096 (fixed) |
| Total bands | 2,048 (fixed) |
| Cell size at equator | ~9.77 × 9.77 km |
| Halving threshold | Cell width < 5 km |
| Halving chain | 4096→2048→1024→512→256→128→64→32→16→8 |
| Polar cells | 8 triangular wedges each |
| Total tiles | 6,498,160 |
| Coordinate convention | seg=0 at prime meridian (lon=0°), matches GDScript mesh |

### 2.2 Data Pipeline (Build-Time Only)

```
Natural Earth admin-0 (.shp)
    ↓  generate_land_mask.py  (3.5 min)
land_mask.bin  (812 KB, 1 bit/cell)

GEBCO 2024 (.nc)
    ↓  generate_terrain.py  (4 min)
terrain.bin + slope.bin  (13 MB, 1 byte/cell each)

Beck Köppen-Geiger (.tif)
    ↓  generate_climate.py  (5 min)
climate.bin  (6.5 MB, 1 byte/cell)

WorldClim 2.1 (48 GeoTIFFs)
    ↓  generate_weather.py  (4 min)
weather.bin  (624 MB, 96 bytes/cell)
```

### 2.3 Runtime Data

| Dataset | Binary | Size | Format | Loader |
|---------|--------|------|--------|--------|
| Land/water | `land_mask.bin` | 812 KB | 1 bit/cell | `land_mask_loader.gd` |
| Terrain | `terrain.bin` | 6.5 MB | 1 byte/cell (11 types) | `terrain_loader.gd` |
| Slope | `slope.bin` | 6.5 MB | 1 byte/cell (5 types) | `terrain_loader.gd` |
| Climate | `climate.bin` | 6.5 MB | 1 byte/cell (30 Köppen types) | `climate_loader.gd` |
| Weather | `weather.bin` | 624 MB | 96 bytes/cell (4 vars × 12 months × int16) | `weather_loader.gd` |

### 2.4 Terrain Types

| Code | Name | Elevation |
|------|------|-----------|
| 0 | deep_ocean | < -4000m |
| 1 | ocean | -4000 to -1000m |
| 2 | shallow_ocean | -1000 to -200m |
| 3 | continental_shelf | -200 to 0m |
| 4 | coastal | 0 to 20m |
| 5 | lowland | 20 to 200m |
| 6 | upland | 200 to 500m |
| 7 | highland | 500 to 1000m |
| 8 | mountain | 1000 to 2000m |
| 9 | high_mountain | 2000 to 4000m |
| 10 | extreme_mountain | > 4000m |

### 2.5 Köppen Climate Types

30 climate zones across 5 main groups: Tropical (A), Arid (B), Temperate (C), Continental (D), Polar (E). Code 0 = ocean/marine (not classified).

### 2.6 Weather Variables

| Variable | Units | Storage |
|----------|-------|---------|
| tavg | °C × 10 | int16 |
| prec | mm | int16 |
| srad | kJ/m²/day | int16 |
| wind | m/s × 10 | int16 |

### 2.7 Rendering

- **Earth sphere:** 4K texture at 1× radius (visual reference)
- **Cell mesh:** Land + ocean cells at 1.003× radius, ~10K visible at tactical zoom
- **Culling:** 500 km radius around camera sub-point, rebuilt every 3 frames
- **Colors:** Land=green, Ocean=blue (terrain-indexed colors available via `terrain_loader`)
- **No LOD pyramid:** Single-resolution mesh

---

## 3. Project Structure

```
historia-terrarum/
├── ANCHOR.md                    # This file
├── PROGRESS.md                  # Session log
├── .gitattributes               # Git LFS tracking
├── _legacy/                     # HT1 archive
├── game/                        # Godot project
│   ├── project.godot
│   ├── assets/
│   │   └── textures/planet/earth/
│   │       └── earth_color_4k.png
│   ├── scenes/
│   │   └── main.tscn
│   ├── scripts/
│   │   ├── camera/
│   │   │   └── earth_camera.gd
│   │   ├── data/
│   │   │   ├── spherical_grid_generator.gd
│   │   │   ├── land_mask_loader.gd
│   │   │   ├── terrain_loader.gd
│   │   │   ├── climate_loader.gd
│   │   │   └── weather_loader.gd
│   │   └── planetary/
│   │       └── earth_display.gd
└── data/
    ├── shapefiles/              # Natural Earth .shp
    ├── raster/                  # Build-time rasters (not committed)
    │   ├── GEBCO_2024_CF.nc     # 7 GB
    │   ├── Beck_KG_V1_present_0p0083.tif  # 23 MB
    │   └── worldclim/           # 48 GeoTIFFs, ~2.5 GB
    ├── generate/
    │   ├── generate_land_mask.py
    │   ├── generate_terrain.py
    │   ├── generate_climate.py
    │   ├── generate_weather.py
    │   └── verify_land_mask.py
    └── output/grid_10km_ht2/
        ├── land_mask.bin        # 812 KB
        ├── terrain.bin          # 6.5 MB
        ├── slope.bin            # 6.5 MB
        ├── climate.bin          # 6.5 MB
        ├── weather.bin          # 624 MB (Git LFS)
        └── *_summary.json       # Pipeline metadata
```

---

## 4. Key Design Decisions

- **Deterministic grid:** 4096×2048 hardcoded. Clean halving chain, seg=0 at prime meridian.
- **Build-time baking:** All rasters processed in Python; game loads only compact binaries.
- **Viewport culling:** Only render ~10K of 6.5M cells. Single mesh, rebuilt every 3 frames.
- **Band-range optimization:** `generate_tint` only processes visible bands (~100 of 2048).
- **Camera from Stella Nostra:** Proven orbit, x-axis mirrored per user preference.
- **Git LFS for weather.bin:** 624 MB file tracked via LFS.
- **Known issues:** Cells still laggy (1-2 FPS) — optimization deferred. Ocean band at dateline fixed via epsilon nudge. Camera mirror fixed.

---

## 5. Development Phases (HT2)

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ | Git fork — tag ht1-final, branch ht2-rebuild, strip to scaffold |
| 2 | ✅ | Deterministic grid math — 4096×2048, halving to 8 polar cells |
| 3 | ✅ | Land/water pipeline — Natural Earth → land_mask.bin (29.0% land) |
| 4 | ✅ | Viewport-culled display — 500km radius around camera sub-point |
| 5 | ✅ | Camera integration — x-axis mirror fix, := fixes |
| 6 | ✅ | Verification — grid structure, known points, tile counts |
| 7 | ✅ | Ocean cell rendering — both land and ocean opaque |
| 8 | ✅ | Terrain pipeline — GEBCO 2024 → 11 terrain types (29.5% land) |
| 9 | ✅ | Climate pipeline — Beck Köppen-Geiger → 30 climate types |
| 10 | ✅ | Weather pipeline — WorldClim 2.1 → 4 vars × 12 months (624 MB) |
| 11 | ⬜ | Performance optimization — reduce ~10K triangle rebuild cost |
| 12 | ⬜ | Visualisation toggles — T=terrain, C=climate, W=temp, P=precip |
| 13 | ⬜ | Future: rivers, LoD pyramid, tile ownership, timeline |

---

## 6. Immediate Next Steps

1. **Test in Godot** — verify sphere + cells render correctly after latest fixes
2. **Performance:** Fix 1-2 FPS lag from per-frame mesh regeneration
3. **Visualisation:** Wire terrain/climate/weather loaders into earth_display.gd with toggle keys
4. **Phase 11+:** Begin gameplay features (rivers, ownership, timeline)
