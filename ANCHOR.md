# Project Anchor: Historia Terrarum

## 1. Vision & Purpose

A grand strategy game where players control a nation throughout history, commanding land troops, naval squadrons, and air wings to conquer the globe. Modeled after Europa Universalis, built on Stella Nostra's proven spherical Earth grid system.

The Earth is divided into a high-resolution spherical grid (10km cells at the equator at Level 0), with a multi-resolution LOD pyramid for efficient rendering and information condensation. Political territories, province boundaries, and contested occupations are tracked at the per-cell level, with dynamic texture-based detail at coarser LOD levels.

- **Working directory:** `D:\hermes-projects\historia-terrarum\`
- **Parent system:** Stella Nostra (grid generator, coordinate math)
- **Godot engine:** 4.6.3
- **Current test resolution:** 100km (62,400 tiles, fast iteration)
- **Target resolution:** 10km base cell at equator (Level 0), LOD pyramid up to 160km (Level 4)
- **Current time scale:** 7 rungs from 15 min/sec to 1 day/sec
- **Default start year:** 1950 (year index 11950, where 0 = 10,000 BC)

---

## 2. Architecture

### 2.1 Grid System

Multi-resolution spherical grid with LOD pyramid. Trapezoidal lat/lon cells with polar merging — "hexagonal-ish" (avg ~6 neighbors per cell due to merge pattern).

| Level | Cell size | Span | Tile count (100km) | Use |
|-------|-----------|------|---------------------|-----|
| 0 | 100 km | 1× | 62,400 | Tactical / regional view |
| 1 | 200 km | 2× | 15,990 | Regional view |
| 2 | 400 km | 4× | 3,872 | Continental view |
| 3 | 800 km | 8× | 968 | Multi-continent |
| 4 | 1,600 km | 16× | 280 | Global view |

Each level has the same mesh structure (band-based quads). Quads at coarser levels can be:
- **Solid:** all sub-tiles same owner → single color via vertex color + solid_tint shader
- **Textured:** mixed owners → per-quad R8 palette-index texture + territory_palette shader

### 2.2 Rendering Pipeline

```
Camera distance → LOD selection per frame
    → Crossfade: old LOD transparency ↑, new LOD transparency ↓ (0.35s ease)
    → Solid quads: MeshInstance3D with vertex color R = palette index
    → Textured quads: Node3D container of per-quad MeshInstance3D with R8 texture
    → Highlighting: shader uniform palette swap (brighten selected, dim others)
```

### 2.3 Territory System

- Per-cell ownership at Level 0 (country + province + occupier)
- Palette-based shader enables instant display mode switching (political, province, diplomatic)
- `territory_changed` signal → border_overlay regenerates borders
- Historical timeline with dynamic border changes (WWI, USSR dissolution, etc.)

### 2.4 Data Pipeline

```
Python: grid math → tile registry (Level 0, 10km)
    → Region assignment from Natural Earth + GADM shapefiles (5,171 regions)
    → 100km tile mapping via majority-vote aggregation (committed)
    → Coastline extraction + simplification (3 LODs)
    → River snapping to grid edges
    → Runtime: territory timeline events update Level 0
```

---

## 3. Project Structure

```
historia-terrarum/
├── ANCHOR.md
├── PROGRESS.md
├── README.md
├── .gitignore
├── game/                       # Godot project
│   ├── project.godot
│   ├── assets/
│   │   ├── flags/              # 464 country flag PNGs (from Stella Nostra)
│   │   └── textures/planet/earth/
│   │       └── earth_color_4k.png
│   ├── scenes/
│   │   └── main.tscn
│   ├── scripts/
│   │   ├── core/
│   │   │   ├── game_state.gd        # Player country, selection state
│   │   │   └── time_manager.gd      # Central time tracking, 7 speed rungs
│   │   ├── camera/
│   │   │   └── earth_camera.gd      # Orbit camera, zoom rungs, crossfade
│   │   ├── data/
│   │   │   ├── spherical_grid_generator.gd
│   │   │   ├── earth_chunk_manager.gd
│   │   │   ├── territory_data.gd
│   │   │   ├── lod_pyramid.gd        # LOD mesh generation + classification
│   │   │   ├── palette_manager.gd    # 256-color palette, display modes
│   │   │   └── palette_texture_gen.gd
│   │   ├── planetary/
│   │   │   ├── earth_display.gd      # Earth body, grid, tint, overlays
│   │   │   ├── border_overlay.gd     # Dynamic political border rendering
│   │   │   ├── coastline_overlay.gd  # Coastline LineStrips (3 LODs)
│   │   │   └── river_overlay.gd      # River LineStrips
│   │   └── ui/
│   │       ├── country_panel.gd      # Left panel: player country + flag
│   │       ├── selection_panel.gd    # Right panel: selected entity + flag
│   │       ├── hover_tooltip.gd      # Country name under cursor
│   │       └── time_control.gd       # Top-right time bar
│   └── shaders/
│       ├── solid_tint.gdshader       # Vertex-color palette lookup
│       └── territory_palette.gdshader # R8 texture palette lookup
└── data/                       # Python data pipeline
    ├── countries/
    │   ├── country_registry.json     # 249 countries with palette indices
    │   ├── country_registry.yaml
    │   ├── palette.json              # 256-color palette
    │   └── tile_mapping_100km.json   # 100km tile → palette index (committed)
    ├── timeline/
    │   └── events.json              # Historical events
    ├── regions/                     # 5,171 region YAML files
    ├── output/
    │   ├── coastlines.json
    │   └── grid_10km/rivers.json
    └── generate/                    # Python pipeline scripts
```

---

## 4. Key Design Decisions

- **Derived LODs, not stored:** All LOD levels above 0 are views into Level 0 data. Changes at Level 0 propagate upward via dirty-tracking.
- **Palette-index shaders:** Textures store territory identities as palette indices, not RGB. Display mode changes are uniform swaps — zero texture regeneration.
- **Chunked rendering (planned):** Earth divided into geographic chunks for frustum + horizon culling.
- **Lazy regeneration (planned):** Quads marked dirty on territory change, regenerated only when visible.
- **Resolution-agnostic grid:** Same `SphericalGridGenerator` works for any `base_cell_km`.
- **100km for dev, 10km for prod:** 62K tiles fast enough for iteration; pipeline outputs at 10km ready to switch.
- **Flags committed:** 464 PNGs in repo so first-time clone needs nothing extra.
- **Time scale rungs from Stella Nostra:** 15m/s, 30m/s, 1h/s, 3h/s, 6h/s, 12h/s, 1d/s. Pause stops ALL processing.

---

## 5. Development Phases

| Phase | Name | Status | Description |
|-------|------|--------|-------------|
| 1 | Grid pipeline | ✅ | Generate 10km tile registry. Verify tile counts and merge chain. |
| 2 | Earth display | ✅ | Earth sphere with grid wireframe + tint at 100km. |
| 2b | Static overlays | ✅ | Coastlines (3 LODs) + rivers from Natural Earth. |
| 3 | Palette shader | ✅ | Territory palette-index shader. Solid + textured quad rendering. |
| 4 | Territory data | ✅ | Region assignment (5,171 regions). 100km tile mapping. |
| 4b | Country registry | ✅ | 249 countries, palette indices, display mode switching. |
| 5 | LOD pyramid | 🟡 | LOD 1-4 mesh generation. Crossfade. Needs Python pre-compute + dirty-tracking. |
| 6 | Camera | ✅ | Zoom rungs, orbital momentum, far plane fix. |
| 7 | Game mechanics | ⬜ | Army/navy/air wing entities, movement, combat, supply. |
| 8 | Timeline | ✅ | JSON events, fast-forward engine, bbox support. |
| 9 | UI | ✅ | Country selection, flags, left/right panels, hover tooltip. |
| 10 | Time controls | 🟡 | Time manager, 7 speed rungs, pause, top-right bar. |
| 11 | Optimization | ⬜ | P0-P4 plan ready (palette perf, depth cull, border offset, texture sharpness). |

---

## 6. Immediate Next Session

**Priority order:**

1. **P0 (CRITICAL):** Guard `_update_all_materials()` with dirty flag — only run on palette/highlight change. Remove from `_process()`. This single fix eliminates ~6.3M uniform calls/frame and should make the game responsive.

2. **P2:** Set `no_depth_test = false` on all overlay materials (borders, rivers, coastlines, grid) — stop rendering far-side geometry through the Earth.

3. **P1:** Skip O(n²) border chaining — render border edges directly as line pairs.

4. **P3:** Apply 90° rotation to border vertex math matching `uv1_offset.x = 0.25`.

5. **P4:** Set `texture_filter = TEXTURE_FILTER_NEAREST` on Earth material.
