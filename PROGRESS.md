# Historia Terrarum 2 — Progress

## Phase 1: Project Setup ✓
- [x] Godot 4.6 project created
- [x] Spherical grid generator (4096×2048, 6.5M cells)
- [x] Earth texture sphere with correct UV offset
- [x] Camera: orbit, drag, zoom (8 rungs: Cell→Global)

## Phase 2: Land Mask ✓
- [x] generate_land_mask.py — Natural Earth admin-0 → bit-array land_mask.bin
- [x] land_mask_loader.gd — O(1) land/ocean lookup
- [x] Egypt fix: invalid geometry repair via buffer(0)

## Phase 3: Cell Rendering ✓
- [x] earth_display.gd — chunk-based vertex-color land cell mesh
- [x] generate_tint() — batched ArrayMesh with shared vertex rings
- [x] Halving-band pentagons (mini segs)
- [x] Polar fan triangulation
- [x] Cell flip (negated Z + 180° offset) — cells match Earth texture
- [x] Chunk cache: discrete 64×256 grid, LRU eviction, neighbor preload
- [x] Arc-distance chunk visibility (not broken band/seg math)

## Phase 4: Terrain ✓
- [x] generate_terrain.py — elevation bands → terrain.bin
- [x] terrain_loader.gd — 11 terrain types with colors
- [x] terrain_colors integrated into cell rendering

## Phase 5: Climate ✓
- [x] generate_climate.py — Köppen classification → climate.bin
- [x] climate_loader.gd — climate data reader

## Phase 6: Weather ✓
- [x] generate_weather.py — daily weather snapshot
- [x] weather_loader.gd — weather data reader

## Phase 7: LoD System ✓
- [x] generate_lod_terrain.py — pre-baked terrain atlases (LOD 1-4)
- [x] lod_display.gd — textured sphere-surface chunk meshes
- [x] Shared vertex rings, pole fan tris, mipmap filtering
- [x] Pre-load all chunks at LOD switch

## Phase 8: Visual Modes ✓
- [x] Mode 0: simple land/sea (green/blue) — key 0
- [x] Mode 1: elevation-based colors (11 terrain types) — key 1, default
- [x] terrain_loader wired into earth_display for elevation palette
- [x] Keybind: number keys 0-9 toggle modes via _unhandled_input()
- [x] Cache invalidation: mode switch clears chunks, rebuilds with new colours
- [ ] Mode 2+: climate, precipitation, temperature, wind, solar, day/night
- [ ] Reflect cell-level mode on LOD sphere textures

## Issues
- LOD texture banding (CRT effect) — improved but not fully resolved
- Chunk unloading near edges — improved with +300km margin
- No chunk preloading during fast camera movement
