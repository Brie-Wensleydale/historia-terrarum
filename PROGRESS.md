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
- [x] Halving-band visibility fix: dual-center check for rows straddling halving rings

## Phase 4: Terrain ✓
- [x] generate_terrain.py — elevation bands → terrain.bin + slope.bin
- [x] terrain_loader.gd — 11 terrain types with colors, 5 slope levels
- [x] terrain_colors integrated into cell rendering (mode 1)
- [ ] Slope data needs regeneration with --full (fast mode left all cells flat)

## Phase 5: Climate ✓
- [x] generate_climate.py — Köppen classification → climate.bin
- [x] climate_loader.gd — 30 climate zones, wired into display (mode 2)

## Phase 6: Weather ✓
- [x] generate_weather.py — 4 vars × 12 months, 595 MB
- [x] weather_loader.gd — O(1) temp/precip/wind/srad lookup
- [x] Wired into display modes 3-6 with color ramps

## Phase 7: LoD System ✓ (partial — broken)
- [x] generate_lod_terrain.py — pre-baked terrain atlases (LOD 1-4)
- [x] lod_display.gd — textured sphere-surface chunk meshes
- [x] Shared vertex rings, pole fan tris, mipmap filtering
- [x] Pre-load all chunks at LOD switch
- [ ] LOD system broken — needs investigation (likely source of lag)

## Phase 8: Visual Modes ✓
- [x] Mode 0: simple land/sea (green/blue) — key 0
- [x] Mode 1: elevation-based colors (11 terrain types) — key 1, default
- [x] Mode 2: Köppen climate (30 zones) — key 2
- [x] Mode 3: temperature heatmap (annual avg) — key 3
- [x] Mode 4: precipitation ramp (annual total) — key 4
- [x] Mode 5: wind speed (annual avg) — key 5
- [x] Mode 6: solar radiation / daylight (annual avg) — key 6
- [x] Mode 7: slope (5 levels) — key 7
- [x] terrain_loader, climate_loader, weather_loader wired into earth_display
- [x] Keybind: number keys 0-7 toggle modes via _input()
- [x] Cache invalidation: mode switch clears chunks, rebuilds with new colours
- [x] Mode name overlay: centered bold text, 2.5s fade-out
- [ ] Mode-switching performance — cells are fixed per mode, consider pre-baking
- [ ] Reflect cell-level mode on LOD sphere textures

## Phase 9: Performance & Polish (Next)
- [ ] Chunk loading threshold tuning — prevent premature unloading
- [ ] LOD system repair — investigation needed
- [ ] Mode-switching optimization — pre-baked textures?
- [ ] Time system — port from Stella Nostra / previous HT
- [ ] Day/night cycle — after time system

## Issues
- LOD system reportedly broken — needs investigation
- LOD texture banding (CRT effect) — improved but not fully resolved
- Chunk unloading near edges — improved with +300km margin, needs more tuning
- No chunk preloading during fast camera movement
- Mode switch causes lag — chunks rebuilt from scratch each time
- Slope data all flat — needs terrain regeneration with --full flag
