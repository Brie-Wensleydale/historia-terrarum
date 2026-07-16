# Phase 5: LOD Pyramid + Dynamic Borders — Implementation Plan

> **For Hermes:** Implement task-by-task with `delegate_task`. Commit after each task.

**Goal:** Multi-resolution Earth rendering with LOD levels 0-4 and dynamic political borders between countries.

**Architecture:** LOD pyramid generates coarser quads from Level 0 territory data. Each quad is classified solid (single owner, vertex color) or textured (mixed, R8 palette texture). Border overlay traces boundaries between adjacent tiles of different owners, simplifies with Douglas-Peucker, renders as LineStrips. Both systems share dirty-tracking from `territory_data.gd`.

**Tech Stack:** Godot 4.6.3, GDScript, existing shaders (`solid_tint.gdshader`, `territory_palette.gdshader`), existing `spherical_grid_generator.gd`

**Key Files:**
- `game/scripts/data/spherical_grid_generator.gd` — grid math, LOD constants, mesh generation
- `game/scripts/data/palette_texture_gen.gd` — R8 palette-index texture generator
- `game/scripts/data/territory_data.gd` — tile ownership, dirty-tracking
- `game/scripts/planetary/earth_display.gd` — Earth setup, layer orchestration
- `game/scripts/planetary/coastline_overlay.gd` — reference for LineStrip rendering pattern
- `game/shaders/solid_tint.gdshader` — vertex-color palette lookup (solid quads)
- `game/shaders/territory_palette.gdshader` — texture palette lookup (textured quads)

---

## Task 1: LOD Band Structure Computation

**Objective:** Compute band structures for LOD levels 1-4 (20km, 40km, 80km, 160km) from the existing grid generator. Each LOD level reduces segment counts by factor of 2 per step.

**Files:**
- Modify: `game/scripts/data/spherical_grid_generator.gd`

**Implementation:**

Add a `compute_all_lod_structures()` static function:

```gdscript
## Compute band structures for all LOD levels 0-4.
## Returns Array[Dictionary] indexed by LOD level.
static func compute_all_lod_structures(radius_km: float, base_cell_km: float) -> Array:
    var lods: Array = []
    for mult in LOD_MULTIPLIERS:
        var cell_km := base_cell_km * float(mult)
        lods.append(compute_band_structure(radius_km, cell_km))
    return lods
```

Add a `get_lod_tile_count(lod_level: int, lod_structures: Array) -> int` helper:
```gdscript
static func get_lod_tile_count(lod_level: int, lod_structures: Array) -> int:
    if lod_level < 0 or lod_level >= lod_structures.size():
        return 0
    return count_tiles(lod_structures[lod_level])
```

**Verification:** Call from `earth_display.gd` at startup, print tile counts for each LOD. Expected: LOD 0 = ~62K (100km), LOD 1 = ~16K, LOD 2 = ~4K, LOD 3 = ~1K, LOD 4 = ~250 tiles.

---

## Task 2: LOD Pyramid Manager (scaffold)

**Objective:** Create `lod_pyramid.gd` — manages mesh generation for all LOD levels, solid/textured classification, and dirty-tracking.

**Files:**
- Create: `game/scripts/data/lod_pyramid.gd`

**Implementation:**

```gdscript
# lod_pyramid.gd — Multi-LOD Earth mesh manager.
# Generates coarser meshes from Level 0 territory data.
# Each quad at LOD 1+ is classified solid (vertex color) or textured (R8 palette texture).
extends Node

const NUM_LODS := 5
const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # Test: 100km; Production: 10km

var _lod_structures: Array = []      # Band structures for LOD 0-4
var _lod_meshes: Array = []          # MeshInstance3D per LOD (index 0 = existing tint)
var _lod_materials: Array = []       # ShaderMaterial per LOD

# Classification: (lod, band, seg) → "solid"|"textured"
var _quad_classifications: Dictionary = {}

# Dirty tracking
var _dirty_quads: Array = []  # [(lod, band, seg), ...]


func _ready() -> void:
    _lod_structures = SphericalGridGenerator.compute_all_lod_structures(
        EARTH_RADIUS_KM, BASE_CELL_KM
    )
    for lod in range(NUM_LODS):
        var count := SphericalGridGenerator.get_lod_tile_count(lod, _lod_structures)
        print("LOD %d: %s tiles" % [lod, count])


func classify_quad(lod: int, qband: int, qseg: int) -> String:
    # A quad at LOD N covers (2^N)×(2^N) Level 0 tiles.
    # If all Level 0 tiles have same owner → "solid"
    # Otherwise → "textured"
    var span := 1 << lod  # 2^lod
    var first_owner := -1
    var all_same := true

    for db in range(span):
        for ds in range(span):
            var band0 := qband * span + db
            var seg0 := qseg * span + ds
            var tile_id := "B%d_%d" % [band0, seg0]
            var owner := TerritoryData.get_tile_owner_palette(tile_id)
            if first_owner == -1:
                first_owner = owner
            elif owner != first_owner:
                return "textured"

    return "solid"


func mark_dirty(lod: int, qband: int, qseg: int) -> void:
    _dirty_quads.append([lod, qband, qseg])


func regenerate_dirty() -> void:
    # Deferred: regenerate meshes for dirty quads
    pass
```

**Verification:** Node added to scene, prints LOD tile counts at startup.

---

## Task 3: LOD Mesh Generation

**Objective:** Extend `lod_pyramid.gd` to generate actual meshes for LOD 1-4. Solid quads use vertex color; textured quads use `palette_texture_gen.gd` for R8 textures.

**Files:**
- Modify: `game/scripts/data/lod_pyramid.gd`
- Reference: `game/scripts/data/palette_texture_gen.gd`
- Reference: `game/scripts/data/spherical_grid_generator.gd` (generate_tint pattern)

**Implementation:**

Add `generate_lod_mesh(lod: int)` to `lod_pyramid.gd`:

```gdscript
func generate_lod_mesh(lod: int) -> MeshInstance3D:
    if lod <= 0:
        return null  # LOD 0 = existing tint mesh

    var band_struct: Dictionary = _lod_structures[lod]
    var band_segs: Array = band_struct["band_segs"]
    var total_bands: int = band_struct["total_bands"]

    var st_solid := SurfaceTool.new()
    st_solid.begin(Mesh.PRIMITIVE_TRIANGLES)

    for b_idx in range(total_bands - 1):
        var segs_a: int = band_segs[b_idx]
        var segs_b: int = band_segs[b_idx + 1]
        if segs_a <= 0 or segs_b <= 0:
            continue

        var sparser_segs: int = mini(segs_a, segs_b)
        var ratio: int = maxi(segs_a / sparser_segs, 1)

        for s in range(sparser_segs):
            var classification := classify_quad(lod, b_idx, s)
            _quad_classifications["%d_%d_%d" % [lod, b_idx, s]] = classification

            if classification == "textured":
                # Deferred: textured quad (Task 5)
                continue

            # Solid quad — sample the center tile's owner
            var center_band := b_idx * (1 << lod) + (1 << (lod - 1))
            var center_seg := s * (1 << lod) + (1 << (lod - 1))
            var tile_id := "B%d_%d" % [center_band, center_seg]
            var palette_idx := TerritoryData.get_tile_owner_palette(tile_id)

            # Build quad vertices
            var radius_m: float = EARTH_RADIUS_KM * 1000.0 * (1.003 + lod * 0.001)
            # ... (quad vertex generation using band structure math)
            # Set vertex color: Color(palette_idx / 255.0, 0, 0, 1.0)
            st_solid.set_color(Color(palette_idx / 255.0, 0.0, 0.0, 1.0))
            # Add 2 triangles (4 vertices) for this quad

    var mesh: ArrayMesh = st_solid.commit()
    if not mesh:
        return null

    var scaled := _scale_mesh(mesh, 1.0 / 1000.0)

    var mi := MeshInstance3D.new()
    mi.name = "LOD_%d_Solid" % lod
    mi.mesh = scaled

    # Apply solid_tint shader
    var mat := ShaderMaterial.new()
    mat.shader = load("res://shaders/solid_tint.gdshader")
    mi.material_override = mat

    return mi
```

**Verification:** LOD 1 mesh generates without errors. Print classification stats (% solid vs textured).

---

## Task 4: LOD Selection by Camera Distance

**Objective:** Wire LOD selection into the camera system. Show/hide LOD meshes based on camera distance from Earth center.

**Files:**
- Modify: `game/scripts/data/lod_pyramid.gd`
- Modify: `game/scripts/planetary/earth_display.gd`

**Implementation:**

Add to `lod_pyramid.gd`:
```gdscript
# Distance thresholds for LOD switching (km from Earth center)
const LOD_THRESHOLDS := [
    8000.0,   # LOD 0 → 1: below 8,000 km (surface zoom)
    16000.0,  # LOD 1 → 2
    32000.0,  # LOD 2 → 3
    64000.0,  # LOD 3 → 4
]

func select_lod(camera_distance_km: float) -> int:
    for lod in range(1, NUM_LODS):
        if camera_distance_km < LOD_THRESHOLDS[lod - 1]:
            return lod - 1
    return NUM_LODS - 1

func update_visibility(active_lod: int) -> void:
    for lod in range(NUM_LODS):
        if lod < _lod_meshes.size() and _lod_meshes[lod]:
            _lod_meshes[lod].visible = (lod == active_lod)
```

In `earth_display.gd`, call `_lod_pyramid.update_visibility()` each frame based on camera position.

**Verification:** Zoom in/out — mesh switches between LOD levels. At global view, see coarse mesh (~250 quads). Zoom in to see finer mesh.

---

## Task 5: Textured Quad Support (Palette Index Textures)

**Objective:** For mixed-ownership quads (borders, coastlines), generate small R8 palette-index textures showing sub-cell detail. Wire into `territory_palette.gdshader`.

**Files:**
- Modify: `game/scripts/data/lod_pyramid.gd`
- Reference: `game/scripts/data/palette_texture_gen.gd`
- Reference: `game/shaders/territory_palette.gdshader`

**Implementation:**

For each textured quad at LOD N (span = 2^N):
1. Create an `Image` of size `span × span`, Format R8
2. Fill each pixel with the palette index of the corresponding Level 0 tile
3. Create `ImageTexture` from the image
4. Assign to the quad's `ShaderMaterial` as `cell_detail` uniform
5. Set `use_texture = true` uniform

```gdscript
func _create_textured_quad(lod: int, qband: int, qseg: int) -> MeshInstance3D:
    var span := 1 << lod
    var img := Image.create(span, span, false, Image.FORMAT_R8)

    for db in range(span):
        for ds in range(span):
            var band0 := qband * span + db
            var seg0 := qseg * span + ds
            var tile_id := "B%d_%d" % [band0, seg0]
            var idx := TerritoryData.get_tile_owner_palette(tile_id)
            img.set_pixel(ds, db, Color(idx / 255.0, 0, 0, 1.0))

    var texture := ImageTexture.create_from_image(img)

    # Build quad mesh (same geometry as solid quad)
    var mi := _build_quad_mesh(lod, qband, qseg)

    var mat := ShaderMaterial.new()
    mat.shader = load("res://shaders/territory_palette.gdshader")
    mat.set_shader_parameter("cell_detail", texture)
    mat.set_shader_parameter("use_texture", true)

    mi.material_override = mat
    return mi
```

**Verification:** Zoom to a border region — textured quads show sub-cell detail while solid quads remain vertex-color only.

---

## Task 6: Dynamic Border Generation

**Objective:** Create `border_overlay.gd` — generates international border LineStrips from territory adjacency at the active LOD.

**Files:**
- Create: `game/scripts/planetary/border_overlay.gd`

**Implementation:**

```gdscript
# border_overlay.gd — Dynamic political border LineStrip renderer.
# Finds adjacent tiles with different owners and traces boundary polylines.
extends Node3D

const BORDER_OFFSET_FACTOR := 1.007  # Above tint, below rivers
const EARTH_RADIUS_KM := 6371.0
const DP_TOLERANCE_KM := 5.0  # Douglas-Peucker simplification tolerance

var _band_structure: Dictionary = {}
var _border_mesh: MeshInstance3D
var _province_border_mesh: MeshInstance3D


func _ready() -> void:
    pass  # Initialized by earth_display after territory data loads


func initialize(band_structure: Dictionary) -> void:
    _band_structure = band_structure
    regenerate_borders()


func regenerate_borders() -> void:
    # 1. Find all tile edges where adjacent tiles have different owners
    var border_segments: Array = _find_border_edges()

    # 2. Chain segments into continuous polylines
    var polylines: Array = _chain_segments(border_segments)

    # 3. Simplify with Douglas-Peucker
    var simplified: Array = []
    for polyline in polylines:
        simplified.append(_douglas_peucker(polyline, DP_TOLERANCE_KM))

    # 4. Build LineStrip mesh
    _build_border_mesh(simplified)


func _find_border_edges() -> Array:
    var band_segs: Array = _band_structure["band_segs"]
    var total_bands: int = _band_structure["total_bands"]
    var edges: Array = []

    for b_idx in range(total_bands):
        var segs: int = band_segs[b_idx]
        if segs <= 0:
            continue

        var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs
        var sparser_segs: int = mini(segs, next_segs)

        for s in range(sparser_segs):
            var owner := _get_owner(b_idx, s)

            # East neighbor
            if s + 1 < sparser_segs:
                var east_owner := _get_owner(b_idx, s + 1)
                if owner != east_owner and owner > 0 and east_owner > 0:
                    edges.append({"band": b_idx, "seg": s, "dir": "E"})

            # North neighbor (if not at top band)
            if b_idx + 1 < total_bands:
                var north_segs: int = band_segs[b_idx + 1]
                if north_segs > 0:
                    var north_seg := int(float(s) * float(north_segs) / float(sparser_segs))
                    var north_owner := _get_owner(b_idx + 1, north_seg)
                    if owner != north_owner and owner > 0 and north_owner > 0:
                        edges.append({"band": b_idx, "seg": s, "dir": "N"})

    return edges


func _douglas_peucker(points: Array, tolerance: float) -> Array:
    if points.size() <= 2:
        return points

    # Find point farthest from line between endpoints
    var max_dist: float = 0.0
    var max_idx: int = 0
    var start: Vector3 = points[0]
    var end: Vector3 = points[-1]

    for i in range(1, points.size() - 1):
        var dist := _point_line_distance(points[i], start, end)
        if dist > max_dist:
            max_dist = dist
            max_idx = i

    if max_dist > tolerance:
        var left := _douglas_peucker(points.slice(0, max_idx + 1), tolerance)
        var right := _douglas_peucker(points.slice(max_idx, points.size()), tolerance)
        # Merge, avoiding duplicate at split point
        left.resize(left.size() - 1)
        left.append_array(right)
        return left

    return [points[0], points[-1]]
```

**Verification:** Print border segment count. Start with a simple test (2 countries), verify border line appears.

---

## Task 7: Border Overlay Integration

**Objective:** Wire `border_overlay.gd` into `earth_display.gd` layer stack. Render international borders as dark lines between countries.

**Files:**
- Modify: `game/scripts/planetary/earth_display.gd`

**Implementation:**

In `earth_display.gd`, add border overlay to layer stack after territory tint is created:

```gdscript
func _create_borders() -> void:
    var border_script := load("res://scripts/planetary/border_overlay.gd")
    _border_overlay = Node.new()
    _border_overlay.name = "BorderOverlay"
    _border_overlay.set_script(border_script)
    add_child(_border_overlay)
    call_deferred("_init_border_overlay")

func _init_border_overlay() -> void:
    if _border_overlay and _border_overlay.has_method("initialize"):
        _border_overlay.initialize(_band_structure)
```

Update layer stack comment:
```
1.007×: International borders (solid, dynamic) — Phase 5
1.005×: Rivers           (blue, static)        — ✅
1.004×: Coastlines        (navy, 3 LODs)        — ✅
1.003×: Territory tint    (filled, palette)     — Phase 4b ✅
1.000×: Earth surface     (4K texture)          — ✅
```

**Verification:** Run project. International borders appear between countries. Test with known adjacent countries (France/Germany, Russia/China).

---

## Task 8: Border Regeneration on Territory Change

**Objective:** Wire dirty-tracking so borders auto-regenerate when territory changes. Hook into `territory_data.gd`.

**Files:**
- Modify: `game/scripts/planetary/border_overlay.gd`
- Modify: `game/scripts/data/territory_data.gd`

**Implementation:**

In `territory_data.gd`, emit a signal on territory change:
```gdscript
signal territory_changed

func set_tile_owner(tile_id: String, palette_idx: int) -> void:
    _tile_ownership[tile_id] = {"owner_idx": palette_idx, "occupier_idx": 0}
    _dirty_tiles.append(tile_id)
    territory_changed.emit()
```

In `border_overlay.gd`, connect to the signal:
```gdscript
func initialize(band_structure: Dictionary) -> void:
    _band_structure = band_structure
    var td := get_node_or_null("/root/Main/TerritoryData")
    if td and td.has_signal("territory_changed"):
        td.territory_changed.connect(_on_territory_changed)
    regenerate_borders()

func _on_territory_changed() -> void:
    call_deferred("regenerate_borders")
```

**Verification:** Programmatically change a tile's owner, verify border updates. (Test with debug key that toggles ownership of a tile between two countries.)

---

## Phase 5 Summary

| Task | What | Minutes |
|------|------|---------|
| 1 | LOD band structure computation | 5 |
| 2 | LOD pyramid manager scaffold | 10 |
| 3 | LOD mesh generation (solid quads) | 15 |
| 4 | LOD selection by camera distance | 10 |
| 5 | Textured quad support (R8 textures) | 15 |
| 6 | Dynamic border generation | 20 |
| 7 | Border overlay integration | 5 |
| 8 | Border regeneration on territory change | 10 |

**Total: ~90 minutes**

## Dependencies

- `territory_data.gd` — tile ownership lookups (from Phase 4b)
- `palette_texture_gen.gd` — R8 image generation utility
- `spherical_grid_generator.gd` — mesh generation patterns
- `solid_tint.gdshader` / `territory_palette.gdshader` — existing shaders

## Verification Checklist

- [ ] All 5 LOD levels print correct tile counts
- [ ] Solid quads render with correct country colors
- [ ] Textured quads show sub-cell border detail
- [ ] LOD switches smoothly with camera zoom
- [ ] International borders appear between countries
- [ ] Borders regenerate after territory change
- [ ] No visual artifacts (gaps, overlaps) between LOD meshes
- [ ] Ocean tiles are transparent at all LODs
