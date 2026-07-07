# Project Anchor: Historia Terrarum

## 1. Vision & Purpose

A grand strategy game where players control a nation throughout history, commanding land troops, naval squadrons, and air wings to conquer the globe. Modeled after Europa Universalis, built on Stella Nostra's proven spherical Earth grid system.

The Earth is divided into a high-resolution spherical grid (10km cells at the equator at Level 0), with a multi-resolution LOD pyramid for efficient rendering and information condensation. Political territories, province boundaries, and contested occupations are tracked at the per-cell level, with dynamic texture-based detail at coarser LOD levels.

- **Working directory:** `D:\hermes-projects\historia-terrarum\`
- **Parent system:** Stella Nostra (grid generator, coordinate math)
- **Godot engine:** 4.6.3
- **Target resolution:** 10km base cell at equator (Level 0), with LOD pyramid up to 160km (Level 4)

---

## 2. Architecture

### 2.1 Grid System

Multi-resolution spherical grid with LOD pyramid:

| Level | Cell size | Tile count (est.) | Use |
|-------|-----------|-------------------|-----|
| 0 | 10 km | ~7.6M | Tactical / single-country view |
| 1 | 20 km | ~1.9M | Regional view |
| 2 | 40 km | ~475K | Continental view |
| 3 | 80 km | ~119K | Multi-continent |
| 4 | 160 km | ~30K | Global view |

Each level has the same mesh structure (band-based quads). Quads at coarser levels can be:
- **Solid:** single color via vertex color (fast path)
- **Textured:** downward-resolution detail via palette-index textures (2×2 to 16×16)

### 2.2 Rendering Pipeline

```
Camera distance → LOD selection per chunk
    → Solid quads: MultiMesh with vertex color
    → Textured quads: MultiMesh with texture atlas + palette shader
    → Highlighting: shader uniform palette swap
```

### 2.3 Territory System

- Per-cell ownership at Level 0 (country + province + occupier)
- LOD pyramid regenerated on demand from Level 0 data (lazy, dirty-tracking)
- Palette-based shader enables instant display mode switching (political, province, diplomatic, occupation)
- Historical timeline with dynamic border changes

### 2.4 Data Pipeline

```
Python: grid math → tile registry (Level 0)
    → Region assignment from Natural Earth shapefiles
    → LOD pyramid pre-computation (texture generation)
    → Runtime: territory timeline events update Level 0, dirty-track LODs
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
│   ├── scenes/
│   │   └── main.tscn
│   ├── scripts/
│   │   ├── core/
│   │   │   └── game_state.gd
│   │   ├── data/
│   │   │   ├── spherical_grid_generator.gd
│   │   │   ├── earth_chunk_manager.gd
│   │   │   └── territory_data.gd
│   │   ├── camera/
│   │   │   └── earth_camera.gd
│   │   ├── planetary/
│   │   │   └── earth_display.gd
│   │   └── hud/
│   │       └── territory_hud.gd
│   └── shaders/
│       └── territory_palette.gdshader
└── data/                       # Python data pipeline
    ├── generate/
    │   ├── grid_registry.py     # Generate tile registry at any resolution
    │   ├── lod_pyramid.py       # Generate LOD pyramid textures
    │   └── region_assign.py     # Natural Earth → tile assignments
    └── output/
        ├── grid_10km/
        ├── grid_20km/
        ├── grid_40km/
        ├── grid_80km/
        └── grid_160km/
```

---

## 4. Key Design Decisions

- **Derived LODs, not stored:** All LOD levels above 0 are views into Level 0 data. Changes at Level 0 propagate upward via dirty-tracking.
- **Palette-index shaders:** Textures store territory identities as palette indices, not RGB. Display mode changes are uniform swaps — zero texture regeneration.
- **Chunked rendering:** Earth divided into geographic chunks for frustum + horizon culling. Each chunk manages its own mesh at the active LOD.
- **Lazy regeneration:** Quads are marked dirty on territory change, regenerated only when visible.
- **The grid generator is resolution-agnostic:** The same `SphericalGridGenerator` class works for any `base_cell_km`. Just change the parameter.

---

## 5. Development Phases

| Phase | Name | Description |
|-------|------|-------------|
| 1 | Grid pipeline | Generate 10km tile registry. Verify tile counts and merge chain. |
| 2 | Earth display | Chunked Earth mesh with LOD selection. Wireframe + tint at Level 0. |
| 3 | Palette shader | Territory palette-index shader. Solid + textured quad rendering. |
| 4 | Territory data | Region assignment at 10km. Territory timeline + dynamic updates. |
| 5 | LOD pyramid | Pre-compute LOD textures. Dirty-tracking + lazy regeneration. |
| 6 | Camera | Zoom rungs, continent-level views, surface tracking. |
| 7 | Game mechanics | Army/navy/air wing entities, movement, combat, supply. |
| 8 | UI | Territory info panel, diplomatic map modes, army selection. |
