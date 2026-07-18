# Project Anchor: Historia Terrarum 2

## 1. Vision & Purpose

A grand strategy game where players control a nation throughout history. **HT2 is a from-scratch rebuild** — clean, minimal, and correct.

The Earth is divided into a deterministic spherical grid:
- **4,096 segments at the equator** (~9.77 km wide)
- **2,048 vertical bands** (~9.77 km tall)
- Halving toward poles: `4096 → 2048 → 1024 → 512 → 256 → 128 → 64 → 32 → 16 → 8`
- **8 triangular cells** at each pole
- **~6.5M total tiles**

Every cell is either **land or water** (binary), pre-baked from Natural Earth admin-0 polygons → compact `land_mask.bin` (~812 KB). At runtime, only cells within ~500 km of the camera's sub-point are rendered (viewport culling). No LOD pyramid, no palette system, no territory data — single-level, clean, correct.

- **Working directory:** `D:\hermes-projects\historia-terrarum\`
- **Godot engine:** 4.6.3
- **Restore point:** tag `ht1-final` (original Historia Terrarum, Phase 1-11)
- **Active branch:** `ht2-rebuild`
- **Camera:** Stella Nostra orbit camera (right-drag orbit, scroll zoom, momentum)

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

### 2.2 Data Pipeline (Build-Time Only)

```
Natural Earth admin-0 (.shp)
    ↓  generate_land_mask.py  (runs ONCE, ~3.5 min)
land_mask.bin  (~812 KB, 1 bit/cell)
    ↓  land_mask_loader.gd  (loads at startup)
is_land(band, seg) → bool  (O(1) bit lookup)
```

### 2.3 Rendering

- **Earth sphere:** 4K texture at 1× radius (visual reference only)
- **Land mesh:** Green cells at 1.003× radius, only ~2,500 visible at tactical zoom
- **Culling:** 500 km radius around camera sub-point, rebuilt every 3 frames
- **No LOD pyramid:** Single-resolution mesh
- **No palette:** Land=green, Ocean=transparent (via vertex colors)

---

## 3. Project Structure

```
historia-terrarum/
├── ANCHOR.md
├── PROGRESS.md
├── _legacy/                     # HT1 archive (palette, LOD, territories, etc.)
├── game/                        # Godot project
│   ├── project.godot
│   ├── assets/
│   │   ├── flags/               # Country flags (from Stella Nostra, legacy)
│   │   └── textures/planet/earth/
│   │       └── earth_color_4k.png
│   ├── scenes/
│   │   └── main.tscn            # EarthDisplay + EarthCamera + Light + Env
│   ├── scripts/
│   │   ├── camera/
│   │   │   └── earth_camera.gd  # Orbit camera (Stella Nostra)
│   │   ├── data/
│   │   │   ├── spherical_grid_generator.gd  # Grid math + tint mesh
│   │   │   └── land_mask_loader.gd          # Binary mask reader
│   │   └── planetary/
│   │       └── earth_display.gd  # Earth body + culled land mesh
└── data/                        # Build pipeline
    ├── shapefiles/              # Natural Earth .shp files
    ├── generate/
    │   ├── generate_land_mask.py    # One-time land classification
    │   └── verify_land_mask.py      # Automated verification
    ├── output/
    │   └── grid_10km_ht2/
    │       ├── land_mask.bin           # 812 KB binary (committed)
    │       └── land_mask_summary.json  # Grid + tile stats
    └── _legacy/                 # HT1 pipeline scripts
```

---

## 4. Key Design Decisions

- **Deterministic grid:** 4096×2048 is hardcoded, not auto-calculated. Clean halving chain guaranteed.
- **Binary land/water:** No territory system yet. Green=land, transparent=ocean. Baked once, loaded fast.
- **Viewport culling, not LOD:** Only render what's on screen. Single mesh regenerated on camera move.
- **Camera from Stella Nostra:** Proven orbit camera, unchanged except for `:=` → explicit type fixes.
- **No palette, no shader uniforms:** Direct RGB vertex colors via `vertex_color_use_as_albedo = true`.

---

## 5. Development Phases (HT2)

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ | Git fork — tag ht1-final, branch ht2-rebuild, strip to scaffold |
| 2 | ✅ | Deterministic grid math — 4096×2048, halving to 8 polar cells |
| 3 | ✅ | Land/water pipeline — Natural Earth → land_mask.bin (29.0% land) |
| 4 | ✅ | Viewport-culled display — 500km radius around camera sub-point |
| 5 | ✅ | Camera integration — existing orbit camera, := fixes |
| 6 | ✅ | Verification — grid structure, known points, tile counts |
| 7 | ⬜ | Future: rivers, LoD pyramid, tile ownership, timeline |

---

## 6. Immediate Next Steps (Post-Launch)

1. **Launch in Godot** — verify the sphere + green land cells render correctly
2. **Test orbit/zoom** — verify camera movement and mesh regeneration
3. **Tune visible radius** — adjust 500km for best coverage at tactical zoom
4. **Add band-level debug overlay** — wireframe grid for visual validation
