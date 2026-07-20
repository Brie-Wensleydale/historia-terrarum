# HT2 Visual Display Mode Switching — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Enable number-key switching between display modes on the cell mesh, starting with mode 0 (simple land/sea) and mode 1 (elevation terrain colours).

**Architecture:** `earth_display.gd` owns the `display_mode` int and handles `_unhandled_input()` for number keys. Mode changes invalidate the entire chunk cache and force a rebuild with new colours. Mode 1 uses `terrain_loader.gd` → `get_terrain_color(band, seg)` which already maps 11 terrain types to a smooth elevation palette (deep ocean dark blue → shallow light blue → lowland green → upland → highland brown → mountain grey → extreme mountain white).

**Tech Stack:** Godot 4.6 GDScript — no `:=` on non-const vars, no `Array[Type]` typed arrays.

---

## Current State

### What already works:
- `terrain_loader.gd` — terrain.bin is loaded, `get_terrain_color(band, seg)` returns 11-colour elevation palette ✓
- `earth_display.gd` — chunk-cached cell rendering with `_build_chunk_mesh()` that assigns `LAND_COLOR` / `OCEAN_COLOR` ✓
- `earth_camera.gd` — `_input()` handles PLUS/MINUS, R, scroll, drag. Number keys NOT consumed → fall through to `_unhandled_input()` ✓

### What we need:
1. Terrain loader instance in earth_display
2. `_display_mode` property (default `1` = elevation, per user request)
3. `_unhandled_input()` capturing KEY_0–KEY_9
4. `_build_chunk_mesh()` using terrain colours when mode ≠ 0
5. Cache invalidation on mode switch
6. Update planning files

---

## Task 1: Add terrain_loader instance to earth_display.gd

**Objective:** Instanciate and load the terrain data during `_ready()`.

**Files:**
- Modify: `game/scripts/planetary/earth_display.gd`

**Changes:**
1. Add `_terrain_loader: RefCounted = null` member variable alongside `_land_loader`
2. In `_ready()`, after land mask loads successfully, load terrain loader:

```gdscript
var tl_script: Script = load("res://scripts/data/terrain_loader.gd")
_terrain_loader = tl_script.new()
if _terrain_loader.load():
    print("  Terrain data loaded: %d terrain types" % _terrain_loader.TERRAIN_NAMES.size())
else:
    push_warning("HT2: terrain data not loaded — elevation mode unavailable")
```

3. Run Godot to verify both loaders print their status messages without errors.

**Verification:** Godot output shows both "Land mask: ..." and "Terrain data loaded: 11 terrain types"

---

## Task 2: Add _display_mode and `_unhandled_input()` for number keys

**Objective:** Track the current display mode and react to number key presses.

**Files:**
- Modify: `game/scripts/planetary/earth_display.gd`

**Changes:**
1. Add member variable: `var _display_mode: int = 1` (default = elevation)
2. Add `_unhandled_input(event)` method:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey) or not event.pressed:
        return
    var key: int = event.keycode
    if key >= KEY_0 and key <= KEY_9:
        var mode: int = key - KEY_0
        set_display_mode(mode)
```

3. Add `set_display_mode(mode: int)` method:

```gdscript
func set_display_mode(mode: int) -> void:
    if mode == _display_mode:
        return
    _display_mode = mode
    # Invalidate all caches — next _process will rebuild with new colours
    _chunk_cache.clear()
    _chunk_cache_order.clear()
    # Hide all visible chunk nodes (they reference old meshes)
    for key in _visible_chunks:
        var node: MeshInstance3D = _visible_chunks[key]
        if is_instance_valid(node):
            node.mesh = null
            node.visible = false
            _recycled_nodes.append(node)
    _visible_chunks.clear()
    _preload_queue.clear()
    print("HT2: display mode = %d" % mode)
```

**Verification:** Godot output shows "HT2: display mode = 0" on key 0 press, "= 1" on key 1 press.

---

## Task 3: Use terrain colours in `_build_chunk_mesh()` for mode ≠ 0

**Objective:** When mode ≠ 0, call `_terrain_loader.get_terrain_color(band, seg)` instead of using `LAND_COLOR`/`OCEAN_COLOR`.

**Files:**
- Modify: `game/scripts/planetary/earth_display.gd` — `_build_chunk_mesh()` method

**Changes:**
Replace the colour assignment block (lines 268–272):

```gdscript
# OLD (mode-insensitive):
if _land_loader.is_land(b_idx, land_seg):
    tile_colors[tid] = LAND_COLOR
else:
    tile_colors[tid] = OCEAN_COLOR
```

With:

```gdscript
# NEW (mode-aware):
if _display_mode == 0:
    # Simple land/sea binary
    if _land_loader.is_land(b_idx, land_seg):
        tile_colors[tid] = LAND_COLOR
    else:
        tile_colors[tid] = OCEAN_COLOR
elif _terrain_loader:
    # Elevation palette (mode 1) and all future modes use terrain base
    tile_colors[tid] = _terrain_loader.get_terrain_color(b_idx, land_seg)
else:
    # Fallback if terrain not loaded
    tile_colors[tid] = OCEAN_COLOR
```

**Note:** The `land_seg` variable already maps from chunk seg to the denser band's seg index — same coordinate space as `terrain_loader.get_terrain_color(band, seg)` expects. No coordinate math changes needed.

**Verification:** Key 0 → green land / blue ocean. Key 1 → elevation colours (deep blue oceans, green lowlands, brown highlands, white peaks).

---

## Task 4: Run Godot and verify switching

**Objective:** Visual confirmation that modes 0 and 1 work correctly.

**Steps:**
1. Launch Godot project
2. Default view should be mode 1 (elevation) — oceans should be various blues, land should show terrain gradient
3. Press 0 — cells switch to simple green/blue
4. Press 1 — cells switch back to elevation
5. Drag/orbit around — chunks rebuild with correct colours
6. Zoom in/out — verify modes persist across chunk rebuilds

**Verification checklist:**
- [ ] Mode 0 shows green land, blue ocean across all zoom levels
- [ ] Mode 1 shows terrain palette: deep ocean (dark blue), shallow ocean (light blue), coastal (yellowish), lowland (green), mountains (brown/grey/white)
- [ ] Switching modes clears visible chunks then rebuilds with new colours
- [ ] No GDScript errors in output
- [ ] No `:=` or `Array[Type]` warnings

---

## Task 5: Update planning files

**Objective:** Log the completed work in dailies, update PROGRESS.md and project anchor.

**Files:**
- Modify: `.hermes/dailies/2026-07-20.md`
- Modify: `PROGRESS.md`
- Modify: `.hermes/plans/project-anchor.md`

**Changes:**
Add to daily:
```markdown
## Visual Display Modes
- Mode system: `_display_mode` int with `set_display_mode()` + `_unhandled_input()` for number keys
- Mode 0: simple green land / blue ocean (bound to key 0)
- Mode 1: elevation terrain palette (bound to key 1, default)
- terrain_loader wired into earth_display — `get_terrain_color(band, seg)` produces 11-colour gradient
- Cache invalidation on mode switch: chunks rebuild with correct colours immediately
```

Update PROGRESS.md Phase 8:
```markdown
## Phase 8: Visual Modes ✓
- [x] Mode 0: simple land/sea (green/blue) — key 0
- [x] Mode 1: elevation-based colors (terrain palette) — key 1, default
- [ ] Mode 2+: climate, precipitation, temperature, etc.
- [x] Keybind: number keys toggle modes
- [ ] Reflect cell-level mode on LOD sphere textures
```

---

## Architecture Notes for Future Modes

The foundation we're laying supports future modes cleanly:

```
Mode | Key | Data Source                 | Colour Scheme
-----|-----|-----------------------------|------------------
0    | 0   | land_mask_loader.is_land()  | LAND_COLOR / OCEAN_COLOR
1    | 1   | terrain_loader.get_terrain_color() | 11-level elevation
2    | 2   | climate_loader.get_climate_color() | Köppen 30-zone
3    | 3   | weather_loader.get_temp()    | temperature heatmap
4    | 4   | weather_loader.get_precip()  | precipitation ramp
5    | 5   | weather_loader.get_wind()    | wind vector colours
6    | 6   | weather_loader.get_srad()    | solar radiation
7    | 7   | (TBD)                       | day/night cycle
```

Each new mode adds an `elif _display_mode == N:` branch in `_build_chunk_mesh()` and instantiates the relevant loader in `_ready()`. The chunk cache invalidation and input wiring don't need to change.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Terrain data not found | Mode 1 falls back to ocean colour | Loader prints warning; fallback path in code |
| terrain_loader band/seg index mismatch | Wrong colours per cell | Uses same `land_seg` variable as land_mask — proven coordinate mapping |
| Cache clear causes stutter on mode switch | Brief visual flicker | 64×256 chunk rebuild is fast (~20ms); LRU cache caps at 128 chunks |

---

## Files Changed (Summary)

| File | Type | Lines |
|------|------|-------|
| `game/scripts/planetary/earth_display.gd` | Modify | ~40 added, ~5 changed |
| `.hermes/dailies/2026-07-20.md` | Modify | ~5 added |
| `PROGRESS.md` | Modify | ~3 changed |
| `.hermes/plans/project-anchor.md` | Modify | ~3 changed |
