# PROGRESS.md — Historia Terrarum

> Last updated: 2026-07-07

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
- [x] `palette_manager.gd` — 256-color palette arrays, zero-cost display mode switching
- [x] `palette_texture_gen.gd` — R8 palette-index texture generator utility
- [x] `earth_display.gd` integration — ShaderMaterial replaces StandardMaterial3D for tint
- [x] Highlight palette swap (bright/dim blend via highlight_mix uniform)
- [ ] MultiMesh batching (deferred to Phase 5 LOD — batch with chunk system)

---

## Phase 4: Territory Data

**Status:** ⬜ Not started

- [ ] `data/generate/region_assign.py` — Natural Earth shapefile intersection at 10km
- [ ] Region YAML files at 10km resolution
- [ ] Territory timeline YAML (events from 1950 baseline)
- [ ] Country registry with palette indices
- [ ] `territory_data.gd` — Godot-side territory data loader
- [ ] Dynamic territory updates (occupation, annexation)
- [ ] Dirty-tracking for LOD regeneration

---

## Phase 5: LOD Pyramid

**Status:** ⬜ Not started

- [ ] `data/generate/lod_pyramid.py` — pre-compute LOD textures from Level 0
- [ ] Generate LOD 1-4 tile registries
- [ ] Solid/mixed classification per quad
- [ ] Texture atlas generation per chunk per LOD
- [ ] Lazy regeneration on territory change
- [ ] Verify wireframe + tint rendering at all LOD levels

---

## Phase 6: Camera

**Status:** ⬜ Not started

- [ ] `earth_camera.gd` — camera controller for Earth
- [ ] Zoom rungs (global, continental, regional, tactical)
- [ ] Surface tracking
- [ ] Smooth LOD transitions

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

## Phase 8: UI

**Status:** ⬜ Not started

- [ ] Territory info panel (country, province, population)
- [ ] Diplomatic map modes
- [ ] Army selection and orders
- [ ] Time controls

---

## Issues / Blockers

*None yet.*

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-07 | Start as clean repo, not Stella Nostra fork | Clean history, no solar system baggage |
| 2026-07-07 | LOD pyramid derived from Level 0 | Single source of truth, dynamic updates |
| 2026-07-07 | Palette-index shader for territory | Zero-cost display mode switching |
| 2026-07-07 | Chunked rendering with geographic partitioning | Frustum + horizon culling for free |
