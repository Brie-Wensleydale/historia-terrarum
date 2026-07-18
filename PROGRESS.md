# PROGRESS.md — Historia Terrarum

> Last updated: 2026-07-16 (session: P0-P4 execution, direct RGB tints, LOD alignment, sparser_seg fix)

---

## Phase 1: Grid Pipeline

**Status:** ✅ Complete

- [x] Create `data/generate/grid_registry.py` — generate tile registry at configurable resolution
- [x] Verify 10km tile count (6,249,000 tiles, 2,002 bands, 4,000 equator segs)
- [x] Verify 100km tile count (62,400 tiles, 200 bands, 400 equator segs — matches Stella Nostra)
- [x] Grid pipeline works for any resolution

---

## Phase 2: Earth Display

**Status:** ✅ Complete

- [x] Godot project setup — `project.godot`, main scene with camera + lights
- [x] `earth_display.gd` — Earth body with grid wireframe + tint (test stripes)
- [x] `earth_camera.gd` — simplified orbit camera from Stella Nostra (scroll zoom, drag orbit)
- [x] `earth_chunk_manager.gd` — geographic chunk partitioning stub
- [x] Grid wireframe generation at 100km (test resolution, 62K tiles)
- [x] Tint mesh generation with test territory colors (vertical stripes)
- [x] Main scene validated in Godot
- [x] Earth texture from Stella Nostra applied (4K, uv1_offset alignment)

---

## Phase 2b: Static Overlays (Coastlines + Rivers)

**Status:** ✅ Complete

- [x] Natural Earth 10m shapefiles downloaded (coastline + rivers)
- [x] `coastline_gen.py` — extract + simplify to 3 LODs (4,133 rings)
- [x] `grid_graph.py` — grid vertex graph for river A* pathfinding
- [x] `river_gen.py` — snap 1,213 rivers to grid cell edges (89,685 edges)
- [x] `coastline_overlay.gd` — LOD-switching LineStrip renderer
- [x] `river_overlay.gd` — cell-edge river LineStrip renderer
- [x] Overlays integrated into earth_display.gd layer stack

---

## Phase 3: Palette Shader

**Status:** ✅ Complete

- [x] `solid_tint.gdshader` — palette-index from vertex color R channel (solid quads)
- [x] `territory_palette.gdshader` — palette-index texture lookup (mixed quads)
- [x] `palette_manager.gd` — 256-color palette arrays, display mode switching
- [x] `palette_texture_gen.gd` — R8 palette-index texture generator utility
- [x] `earth_display.gd` integration — ShaderMaterial replaces StandardMaterial3D for tint
- [x] Highlight palette swap (bright/dim blend via highlight_mix uniform)
- [ ] MultiMesh batching (deferred)

---

## Phase 4: Territory Core (Data Pipeline)

**Status:** ✅ Complete

- [x] `tile_registry.py` — generate 10km tile registry (913 MB, 6,245,000 tiles)
- [x] Natural Earth shapefiles (admin-0, admin-1, admin-2 US-only, subunits)
- [x] GADM admin-2 shapefiles downloaded for 11 countries
- [x] `region_config.yaml` — strategy config (adm_0: 43, adm_2: 4, adm_1 default, UK custom)
- [x] `region_assign.py` — 3-point majority test + GADM/NE admin-2 + auto-split
- [x] **Result: 5,171 regions** from 1,852,412 land tiles
- [x] 1,578 admin-2 regions with parent-linked hierarchy
- [x] 41 mega-provinces auto-split (Sakha→29, Alaska→16, Xinjiang→11, etc.)

### Phase 4b: Country Registry & Palette Indices

**Status:** ✅ Complete

- [x] Build country registry from 5,171 regions → `data/countries/country_registry.yaml`
- [x] Deterministic palette color assignment → `data/countries/palette.json`
- [x] 249 countries, 228 unique palette indices (major=7, regional=27, minor=91, micro=124)
- [x] 100km tile mapping via majority-vote aggregation → `data/countries/tile_mapping_100km.json`
- [x] Wire into PaletteManager — loads JSON at startup
- [x] `territory_data.gd` — loads tile mapping (now `tile_mapping_100km.json` as primary)
- [x] `earth_display.gd` — real country colors instead of test stripes
- [x] Display mode switching — keys 1/2/3/4

---

## Phase 5: LOD Pyramid

**Status:** 🟡 In Progress — code written, meshes generate, LOD 1-4 visible

- [x] `lod_pyramid.gd` — LOD pyramid manager (classify, generate, crossfade)
- [x] Quad classification — `classify_quad()` per-LOD (solid vs textured)
- [x] Solid mesh generation — vertex-color palette indices + `solid_tint.gdshader`
- [x] Textured mesh generation — per-quad R8 textures + `territory_palette.gdshader`
- [x] LOD crossfade — smooth alpha transition with `transparency` property
- [x] `generate_all_lod_meshes()` — LOD 1-4 from territory data
- [x] `register_lod_zero()` — existing tint mesh as LOD 0
- [x] `update_visibility()` — show/hide with crossfade on camera distance change
- [ ] Static LOD pre-compute pipeline (Python — currently all in-engine at startup)
- [ ] Dirty-tracking for lazy regeneration on territory change
- [ ] Verify wireframe + tint rendering at all LOD levels

---

## Phase 6: Camera

**Status:** ✅ Complete

- [x] Zoom rungs — 5 discrete levels (Tactical/Regional/Continental/Hemisphere/Global)
- [x] Smooth LOD crossfade — alpha transition (0.35s ease-in-out)
- [x] Orbit momentum — right-drag velocity decays on release
- [x] Surface tracking — focus_on_surface() snaps to LOD 0
- [x] Edge clamping — no underground orbits, phi bounds, min/max distance
- [x] View reset — R key returns to Continental default
- [x] **Fixed:** Camera far plane set to 200,000 (was default 4,000 — everything clipped)

---

## Phase 7: Game Mechanics

**Status:** ⬜ Not started

- [ ] Army/navy/air wing entity system
- [ ] Movement on the grid
- [ ] Combat resolution
- [ ] Supply system
- [ ] Province-level administration
- [ ] Historical timeline engine

---

## Phase 8: Timeline Engine

**Status:** ✅ Complete

- [x] Timeline event format — JSON with year, name, changes (tiles + bbox)
- [x] Sample events — WWI (1914/1918), USSR dissolution (1991), test swap events
- [x] Event loader — native JSON parsing, country name → palette index mapping
- [x] Fast-forward engine — apply all events ≤ target year to territory state
- [x] Bbox support — find tiles in lat/lon region, approximate from tile IDs
- [x] Year advancement — T key advances one year, F key jumps to 1991
- [x] Default start: 1950, events validated with tile ownership changes

---

## Phase 9: UI

**Status:** ✅ Complete (basic selection + panels + flags)

- [x] Click detection — ray-sphere intersection, find tile + country
- [x] Drag-vs-click discrimination — 5px threshold
- [x] GameState node — player country, selected entity tracking
- [x] Country highlight — brighten selected, dim others via PaletteManager
- [x] Left panel — player country name, flag, tabs (Stats/Diplomacy/Military/Tech)
- [x] Right panel — selected object name + type, flag, info rows
- [x] Hover tooltip — country name follows cursor
- [x] Country flags — 464 flag PNGs from Stella Nostra, loaded from `res://assets/flags/`

---

## Phase 10: Time Controls

**Status:** 🟡 In Progress — base system running, needs perf fix

- [x] `time_manager.gd` — central time tracking, 7 speed rungs (15m/s → 1d/s)
- [x] Pause/resume — all game processes query `TimeManager.get_game_delta()`
- [x] `time_control.gd` — top-right UI bar with date, speed label, pause/play/speed buttons
- [x] Universal time scale — any process plugs into TimeManager for synchronized speed
- [ ] Time controls feel laggy due to P0 palette performance issue (see Issues)
- [ ] Day/month display logic (currently placeholder month names)

---

## Phase 11: Optimization (P0-P4)

**Status:** 🟡 Mostly done — tints + LOD working; overlay alignment deferred

| Id | Priority | Issue | Fix | Status |
|----|----------|-------|-----|--------|
| P0 | 🔴 Critical | `_update_all_materials()` every frame ~6.3M calls | Dirty flag on palette/highlight change | ✅ Done — game playable |
| P1 | 🟡 High | O(n²) border chaining | O(n) spatial hash + Douglas-Peucker | ✅ Done |
| P2 | 🟡 High | Overlays visible through Earth | `no_depth_test = false` | ✅ Done |
| P3 | 🟢 Medium | Borders offset 90° | REVERTED — uv1_offset is UV, not 3D | ❌ Misdiagnosis |
| P4 | 🟢 Low | Earth texture blurred | `texture_filter = NEAREST` | ✅ Done |

### Additional work this session
- **Direct RGB vertex colors**: `_assign_real_tile_colors()` loads palette.json and bakes RGB into vertex colors. StandardMaterial3D with `vertex_color_use_as_albedo=true`. Removed ShaderMaterial pipeline entirely — no more palette uniform timing issues.
- **Unified grid edge overlay** (`edge_overlay.gd`): Borders + coastlines from same 100km grid. Replaced Natural Earth coastline vectors. Currently **disabled** — focus on tints + LOD.
- **10km attempt**: Changed `BASE_CELL_KM=10.0` (6.25M tiles). Game crashes silently. Reverted to 100km. 10km data should be loaded as textures on 100km LOD quads, not as full grid.
- **LOD pyramid alignment**: `generate_lod_mesh()` now derives quad corners from LOD 0 vertex positions (`_lod0_vertex()`). This fixed spatial offset between quad geometry and territory data.
- **sparser segment conversion**: `classify_quad()`, `get_solid_owner()`, `_build_texture_rgb()` now use `_to_sparser_seg()` — territory queries use sparser segment convention matching tile_mapping keys. Fixed gaps at merge boundaries.

### Known issues (deferred)
- LOD quad alignment at merge boundaries still has artifacts (vertical gap, sheared cells)
- Borders/coastlines/rivers disabled pending tint + LOD stabilization
- 10km data not yet integrated into LOD textures

---

## File Paths & Cross-Reference from Stella Nostra

| Asset | Source | Destination |
|-------|--------|-------------|
| Flags (464 PNGs) | `stella-nostra-geo-data/data/flags/` | `game/assets/flags/` |
| Earth 4K texture | Already committed | `game/assets/textures/planet/earth/earth_color_4k.png` |
| 100km tile mapping | Generated by pipeline | `data/countries/tile_mapping_100km.json` (committed) |
| 10km tile mapping | Generated by pipeline | `data/countries/tile_mapping.json` (gitignored, 26MB) |
| Coastlines | Generated by pipeline | `data/output/coastlines.json` (committed) |
| Rivers | Generated by pipeline | `data/output/grid_10km/rivers.json` (committed) |

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-07 | Start as clean repo, not Stella Nostra fork | Clean history, no solar system baggage |
| 2026-07-07 | LOD pyramid derived from Level 0 | Single source of truth, dynamic updates |
| 2026-07-07 | Palette-index shader for territory | Zero-cost display mode switching |
| 2026-07-07 | Chunked rendering with geographic partitioning | Frustum + horizon culling for free |
| 2026-07-15 | Camera zoom rungs with discrete LOD mapping | Scroll snaps between levels instead of continuous zoom |
| 2026-07-15 | Smooth LOD crossfade via transparency | No material swaps mid-zoom, cheap GPU blend |
| 2026-07-15 | Timeline events as JSON | Native Godot parsing, no YAML dependency |
| 2026-07-16 | Time scale 1:900 through 1:86400 | Stella Nostra speeds, capped at 1 day/sec, no reverse |
| 2026-07-16 | Flags committed to repo (84MB) | First-time clone gets everything, no manual copy step |
| 2026-07-16 | Develop at 100km, pipeline at 10km | 62K tiles fast enough for iteration; 10km ready for production |
