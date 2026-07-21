# LOD Banding Fix + Static Data Atlas Pre-Baking

> **For Hermes:** Implement directly — two phases, Phase A first, Phase B is generation-only (no in-game wiring yet).

**Goal:** Fix LOD 1-4 texture banding/sheering AND pre-bake all 8 display modes as atlas textures at all LOD levels.

**Architecture:** Phase A fixes visual quality by adding shared vertex rings + atlas border padding + higher tile resolution. Phase B extends `generate_lod_terrain.py` to bake climate, temp, precip, wind, solar, and slope atlases (not just terrain).

**Constraint:** Do NOT wire LOD 0 atlases into `earth_display.gd` — continue using per-cell vertex colors at LOD 0 until LOD 1-4 quality is confirmed.

---

## Phase A: Fix LOD 1-4 Banding & Sheering

### Root Cause Analysis

The banding has three potential sources:

1. **Texture atlas seams between chunks** — adjacent chunks reference different atlas files. If the atlas tile colors differ at edges (e.g., terrain classification at chunk boundaries), the seam is visible as a hard color discontinuity.

2. **Atlas tile pixel bleeding** — 16×16 px tiles with `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS` causes GPU to sample across tile boundaries within the atlas, bleeding adjacent tile colors into each other. No border padding between tiles.

3. **Independent per-chunk vertex rings** — each chunk computes its own vertex ring positions. Adjacent chunks at the same latitude should have bit-identical boundary vertices, but floating-point computation paths differ slightly.

### Task A1: Add 1px border padding to atlas tiles

**Files:** `data/generate/generate_lod_terrain.py`

Each tile in the atlas is 16×16 px with no border. Add 1px padding:
- Tiles become 18×18 (16×16 data + 1px border on each side)
- Border pixels = same color as adjacent data pixel (clamp-to-edge)
- UV coordinates adjusted: u0,u1,v0,v1 map to the inner 16×16 region

This prevents texture filtering from sampling across adjacent tiles in the atlas.

### Task A2: Increase tile resolution from 16×16 to 32×32

**Files:** `data/generate/generate_lod_terrain.py` → constant `TILE_PX`

16×16 px tiles stretched over large quads look pixelated. 32×32 gives 4× more detail per tile.

### Task A3: Shared vertex rings across chunks at same LOD level

**Files:** `game/scripts/planetary/lod_display.gd` → `_build_chunk_mesh()`

Pre-compute canonical vertex rings for the entire globe at each LOD level:
- One ring per mega-band boundary (bands that are multiples of stride)
- Ring has `floor(band_segs[band_idx] / stride)` vertices, evenly spaced at longitude `2π × k / seg_count`
- Each chunk references its slice of each pre-computed ring
- Adjacent chunks share boundary vertices → bitwise identical → no geometry gaps

Implementation approach:
```gdscript
# Per (lod, global_mega_band_idx) → PackedVector3Array of ring vertices
var _lod_rings: Dictionary = {}  # key = "L{lid}_B{bid}" → PackedVector3Array

func _get_or_build_ring(lod, mega_band_idx, band_segs, total_bands) -> PackedVector3Array:
    var key = "L%d_B%d" % [lod, mega_band_idx]
    if _lod_rings.has(key):
        return _lod_rings[key]
    # Build ring at this latitude with stride-reduced segment count
    var stride = LOD_STRIDE[lod]
    var base_band = mega_band_idx * stride
    var seg_count = maxi(1, band_segs[base_band] / stride)
    # ... compute ring vertices ...
    _lod_rings[key] = verts
    return verts
```

### Task A4: Regenerate all LOD atlases

Run `generate_lod_terrain.py` with the new tile size + padding.

---

## Phase B: Pre-Bake All Display Modes as LOD Atlases

### Task B1: Extend `generate_lod_terrain.py` to accept data source parameter

**Files:** `data/generate/generate_lod_terrain.py`

Add support for climate, temperature, precipitation, wind, solar, and slope data sources. Refactor tile fill logic to select color from the chosen data source.

New readers needed:
- `ClimateReader` — reads `climate.bin`, returns Köppen code → RGB via `CLIMATE_COLORS` dict
- `WeatherReader` — reads `weather.bin`, returns temp/precip/wind/srad → RGB via color ramp

### Task B2: Generate climate atlases (mode 2)

Run the generator with climate data source → output to `lod/climate/lod{1-4}/`

### Task B3: Generate temperature atlases (mode 3)

### Task B4: Generate precipitation atlases (mode 4)

### Task B5: Generate wind atlases (mode 5)

### Task B6: Generate solar atlases (mode 6)

### Task B7: Generate slope atlases (mode 7)

**Note:** Slope data is all zeros (fast mode). Generate anyway for when --full is run.

---

## Verification

1. Phase A: Launch Godot, zoom to LOD 1-4 distances → verify no visible seams between chunks, no pixel bleeding between atlas tiles
2. Phase B: Check that atlas files exist at `data/output/grid_10km_ht2/lod/{climate,temp,precip,wind,solar,slope}/lod{1-4}/`
3. Phase B: Verify atlases produce correct colors by sampling known locations
