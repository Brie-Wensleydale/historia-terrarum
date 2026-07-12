# Phase 3: Palette Shader — Implementation Plan

> **For Hermes:** Implement task-by-task. Commit after each task.

**Goal:** Replace vertex-color territory tint with palette-index shader system enabling zero-cost display mode switching.

**Architecture:** Two shaders — `solid_tint.gdshader` (vertex color, no texture) for uniform quads, `territory_palette.gdshader` (palette-index texture lookup) for mixed-territory quads. A `PaletteManager` node owns the 256-color palette arrays and pushes them to shader uniforms each frame, enabling instant political/province/diplomatic mode swaps.

**Tech Stack:** Godot 4.6.3, GLSL ES (Godot spatial shaders), GDScript

---

## Current State

- `territory_palette.gdshader` exists as a stub — correct approach but untested in Godot
- `earth_display.gd` creates tint mesh via `SphericalGridGenerator.generate_tint()` using vertex colors + `StandardMaterial3D`
- `territory_data.gd` has palette stubs (arrays sized to 256, empty)
- Test pattern: vertical colored stripes (6 colors) — useful for verifying grid alignment

## What Changes

1. `earth_display.gd` tint mesh switches from `StandardMaterial3D` to our shaders
2. New `PaletteManager` node handles palette data and shader uniform updates
3. Solid quads render via vertex color (immediate win — no texture overhead)
4. Textured quads render via palette-index texture (scaffold for Phase 4 territory data)
5. Test palette proves the palette-swap mechanism works

---

### Task 1: Create solid tint shader (palette-index from vertex color)

**Objective:** Shader for uniform quads that decodes palette index from vertex color R channel, then looks up display color from palette uniforms. This enables zero-cost display mode switching even for solid quads.

**Key design:** Vertex color `COLOR.r` holds `palette_index / 255.0`. The shader decodes this, looks up `normal_palette[idx]`, and outputs the display color. Ocean (index 0) = transparent → Earth texture shows through.

**Files:**
- Create: `game/shaders/solid_tint.gdshader`

**Step 1: Create the shader**

```glsl
// solid_tint.gdshader — Palette-index tint for uniform-territory quads.
// Vertex color R channel encodes palette index (0-255).
// Shader decodes it and looks up display color from palette uniforms.
// Same uniforms as territory_palette.gdshader — PaletteManager updates both.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// 256-color palettes — set by PaletteManager each frame
uniform vec4 normal_palette[256];
uniform vec4 highlight_palette[256];

// Blend between normal and highlight (0.0 = normal, 1.0 = highlighted)
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
    // Decode palette index from vertex color R channel
    int idx = int(COLOR.r * 255.0 + 0.5);
    idx = clamp(idx, 0, 255);

    // Look up both palettes and blend
    vec4 normal = normal_palette[idx];
    vec4 highlight = highlight_palette[idx];
    vec4 color = mix(normal, highlight, highlight_mix);

    ALBEDO = color.rgb;
    ALPHA = color.a;
}
```

**Step 2: Verify file saved**

```bash
cat game/shaders/solid_tint.gdshader
```

**Step 3: Commit**

```bash
git add game/shaders/solid_tint.gdshader
git commit -m "feat(phase3): add solid_tint shader for uniform quads"
```

---

### Task 2: Fix territory_palette shader for Godot 4.6

**Objective:** Ensure the existing palette-index shader is valid Godot 4.6 GLSL and handles edge cases

**Files:**
- Modify: `game/shaders/territory_palette.gdshader`

**Step 1: Update the shader**

Issues to fix:
- `filter_nearest` hint on `sampler2D` → use `filter_nearest` (correct)
- Need `depth_draw_opaque` render mode
- Alpha handling: use `ALPHA` properly for transparency over ocean
- Ocean (index 0) should be fully transparent so Earth texture shows through

```glsl
// territory_palette.gdshader — Palette-index territory shader for mixed quads.
// Texture pixels hold palette indices (R channel, 0-255).
// Ocean (index 0) is transparent → Earth surface shows through.
// Other indices map to colors via the normal/highlight palette uniforms.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D cell_detail : source_color, filter_nearest;

// 256-color palettes — set by PaletteManager each frame
uniform vec4 normal_palette[256];
uniform vec4 highlight_palette[256];

// Blend between normal and highlight (0.0 = normal, 1.0 = highlighted)
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
    // Read palette index from texture R channel
    float index_raw = texture(cell_detail, UV).r;
    int idx = int(index_raw * 255.0 + 0.5);
    idx = clamp(idx, 0, 255);

    // Look up both palettes and blend
    vec4 normal = normal_palette[idx];
    vec4 highlight = highlight_palette[idx];
    vec4 color = mix(normal, highlight, highlight_mix);

    ALBEDO = color.rgb;
    ALPHA = color.a;
}
```

**Step 2: Verify**

```bash
cat game/shaders/territory_palette.gdshader
```

**Step 3: Commit**

```bash
git add game/shaders/territory_palette.gdshader
git commit -m "feat(phase3): finalize territory_palette shader for Godot 4.6"
```

---

### Task 3: Create PaletteManager node

**Objective:** Node that owns palette color arrays and pushes them to shader uniforms on all tint materials each frame

**Files:**
- Create: `game/scripts/data/palette_manager.gd`

**Step 1: Create the script**

```gdscript
# palette_manager.gd — Manages territory color palettes for shader uniforms.
# Owns the 256-color arrays for each display mode (political, province, etc.)
# and pushes them to shader materials each frame.
#
# Display mode switching is zero-cost: just change which palette gets pushed.
# Highlighting works by building a blended highlight palette.
extends Node

const PALETTE_SIZE := 256

# Core palettes — one array per display mode
var _political_palette: Array        # index → Color
var _province_palette: Array         # index → Color
var _country_names: Array            # index → country name (for tooltips)

# Current display state
var _display_mode: String = "political"
var _highlighted_idx: int = -1

# Shader materials to update each frame
var _registered_materials: Array[ShaderMaterial] = []


func _ready() -> void:
	_initialize_palettes()


func _process(_delta: float) -> void:
	_update_all_materials()


func register_material(mat: ShaderMaterial) -> void:
	if mat and mat not in _registered_materials:
		_registered_materials.append(mat)


func unregister_material(mat: ShaderMaterial) -> void:
	_registered_materials.erase(mat)


func set_display_mode(mode: String) -> void:
	if mode in ["political", "province", "diplomatic", "occupation"]:
		_display_mode = mode


func highlight_country(idx: int) -> void:
	_highlighted_idx = idx


func clear_highlight() -> void:
	_highlighted_idx = -1


func add_country(idx: int, name: String, political_color: Color, province_color: Color = Color.TRANSPARENT) -> void:
	if idx < 0 or idx >= PALETTE_SIZE:
		return
	_country_names[idx] = name
	_political_palette[idx] = political_color
	_province_palette[idx] = province_color


func _initialize_palettes() -> void:
	_political_palette.resize(PALETTE_SIZE)
	_province_palette.resize(PALETTE_SIZE)
	_country_names.resize(PALETTE_SIZE)

	# Default: all entries transparent (ocean)
	for i in range(PALETTE_SIZE):
		_political_palette[i] = Color.TRANSPARENT
		_province_palette[i] = Color.TRANSPARENT
		_country_names[i] = ""

	# Test palette — a few visible "countries" for Phase 3 verification
	_add_test_palette()
	print("PaletteManager initialized with %d test countries" % _count_test_countries())


func _add_test_palette() -> void:
	add_country(1, "Test Red",    Color(0.8, 0.2, 0.2), Color(0.9, 0.3, 0.3))
	add_country(2, "Test Green",  Color(0.2, 0.6, 0.2), Color(0.3, 0.7, 0.3))
	add_country(3, "Test Blue",   Color(0.2, 0.2, 0.8), Color(0.3, 0.3, 0.9))
	add_country(4, "Test Gold",   Color(0.8, 0.7, 0.1), Color(0.9, 0.8, 0.2))
	add_country(5, "Test Purple", Color(0.6, 0.2, 0.6), Color(0.7, 0.3, 0.7))
	add_country(6, "Test Teal",   Color(0.2, 0.6, 0.6), Color(0.3, 0.7, 0.7))


func _count_test_countries() -> int:
	var count := 0
	for i in range(1, PALETTE_SIZE):
		if _country_names[i] != "":
			count += 1
	return count


func get_active_palette() -> Array:
	match _display_mode:
		"province":
			return _province_palette
		_:
			return _political_palette


func _update_all_materials() -> void:
	if _registered_materials.is_empty():
		return

	var active: Array = get_active_palette()

	for mat in _registered_materials:
		if not is_instance_valid(mat):
			continue

		# Build normal palette array for the shader
		for i in range(PALETTE_SIZE):
			var c: Color = active[i]
			mat.set_shader_parameter("normal_palette[%d]" % i, c)

			# Build highlight palette: highlighted country bright, others dimmed
			if _highlighted_idx >= 0 and _highlighted_idx < PALETTE_SIZE:
				if i == _highlighted_idx:
					mat.set_shader_parameter("highlight_palette[%d]" % i,
						Color(c.r * 1.3, c.g * 1.3, c.b * 1.3, c.a))
				else:
					mat.set_shader_parameter("highlight_palette[%d]" % i,
						Color(c.r * 0.4, c.g * 0.4, c.b * 0.4, c.a))
			else:
				mat.set_shader_parameter("highlight_palette[%d]" % i, c)

		var mix_val: float = 1.0 if _highlighted_idx >= 0 else 0.0
		mat.set_shader_parameter("highlight_mix", mix_val)
```

**Step 2: Verify**

```bash
cat game/scripts/data/palette_manager.gd
```

**Step 3: Commit**

```bash
git add game/scripts/data/palette_manager.gd
git commit -m "feat(phase3): add PaletteManager for shader uniform updates"
```

---

### Task 4: Create palette-index texture generator utility

**Objective:** Utility script to generate small palette-index textures for testing. Each pixel's R channel encodes a palette index (0-255).

**Files:**
- Create: `game/scripts/data/palette_texture_gen.gd`

**Step 1: Create utility**

```gdscript
# palette_texture_gen.gd — Static utility for generating palette-index textures.
# Each pixel's R channel stores a palette index (0-255).
# Used for mixed-territory quads where sub-cells have different owners.
extends RefCounted


## Create a palette-index Image from a 2D array of palette indices.
## indices_2d[y][x] = palette index (0-255). 0 = ocean/transparent.
## Returns an Image in FORMAT_R8 format (single channel, 8-bit).
static func create_from_indices(indices_2d: Array) -> Image:
	var height := indices_2d.size()
	if height == 0:
		return Image.create(1, 1, false, Image.FORMAT_R8)

	var width := indices_2d[0].size()
	var img := Image.create(width, height, false, Image.FORMAT_R8)

	for y in range(height):
		for x in range(width):
			var idx: int = indices_2d[y][x] & 0xFF
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))

	return img


## Create a solid palette-index texture (all pixels = same index).
## Useful for quads that are uniformly owned by one country.
static func create_solid(index: int, size: int = 2) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_R8)
	var val := Color(index / 255.0, 0, 0)
	img.fill(val)
	return img


## Create a checkerboard test pattern alternating two indices.
static func create_checker_test(idx_a: int, idx_b: int, size: int = 4) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_R8)
	for y in range(size):
		for x in range(size):
			var idx := idx_a if (x + y) % 2 == 0 else idx_b
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))
	return img


## Create a horizontal-stripe test pattern for visual alignment testing.
static func create_stripe_test(indices: Array, width: int, height: int) -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_R8)
	var num_stripes := indices.size()
	if num_stripes == 0:
		return img

	for y in range(height):
		var stripe := (y * num_stripes) / height
		var idx: int = indices[stripe] & 0xFF
		for x in range(width):
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))

	return img
```

**Step 2: Verify**

```bash
cat game/scripts/data/palette_texture_gen.gd
```

**Step 3: Commit**

```bash
git add game/scripts/data/palette_texture_gen.gd
git commit -m "feat(phase3): add palette-index texture generator utility"
```

---

### Task 5: Integrate shaders into earth_display.gd

**Objective:** Replace the StandardMaterial3D-based tint with shader-material rendering. Solid shader for all current quads (no mixed territory yet), with PaletteManager integration.

**Files:**
- Modify: `game/scripts/planetary/earth_display.gd`

**Step 1: Update earth_display.gd**

Changes:
- Add PaletteManager as child node
- Replace `_create_tint()` to use `solid_tint.gdshader` via `ShaderMaterial`
- Remove `_generate_test_tile_colors()` (colors now come from PaletteManager via indices)
- Update tint mesh to use palette indices as vertex colors (index encoded in vertex color for now)

```gdscript
# earth_display.gd — Earth body with grid wireframe and territory tint.
# Creates the Earth sphere, generates grid mesh, loads territory data,
# and manages the visual layer stack.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # Start with 100km for testing (7.6K tiles, fast)

var _earth_body: MeshInstance3D
var _grid_mesh: MeshInstance3D
var _tint_mesh: MeshInstance3D
var _coastline_overlay: Node
var _river_overlay: Node
var _palette_manager: Node
var _band_structure: Dictionary = {}
var _tile_indices: Dictionary = {}  # tile_id → palette_index (1-255)


func _ready() -> void:
	_setup_earth_body()
	_setup_palette_manager()
	_assign_test_indices()
	_create_grid()
	_create_tint()
	_create_coastlines()
	_create_rivers()
	print("Earth display ready. Grid: %d bands, %d tiles" % [
		_band_structure.get("total_bands", 0),
		SphericalGridGenerator.count_tiles(_band_structure),
	])


func _setup_earth_body() -> void:
	# Create Earth sphere
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = EARTH_RADIUS_KM
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 256
	sphere_mesh.rings = 128
	sphere_mesh.is_double_sided = false

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	# Load real Earth texture from assets
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var tex_path := "res://assets/textures/planet/earth/earth_color_4k.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE
		# UV offset: align texture prime meridian with model 0° (matches Stella Nostra)
		mat.uv1_offset.x = 0.25
		print("Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)  # Blue fallback
		print("Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _setup_palette_manager() -> void:
	var pm_script := load("res://scripts/data/palette_manager.gd")
	_palette_manager = Node.new()
	_palette_manager.name = "PaletteManager"
	_palette_manager.set_script(pm_script)
	add_child(_palette_manager)


func _assign_test_indices() -> void:
	# Assign palette indices to tiles as a test pattern: vertical stripes
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, BASE_CELL_KM)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]

	# Use palette indices 1-6 (six "countries")
	var num_countries := 6

	for b_idx in range(total_bands):
		var grid_segs: int = band_segs[b_idx]
		if grid_segs <= 0:
			continue

		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else grid_segs
		var sparser_segs: int = mini(grid_segs, next_segs)
		var ratio: int = maxi(grid_segs / sparser_segs, 1)

		for s in range(grid_segs):
			var sparser_s: int = s / ratio
			var tile_id: String = "B%d_%d" % [b_idx, sparser_s]
			var lon_frac: float = float(s) / float(grid_segs)
			var idx: int = int(lon_frac * num_countries) % num_countries + 1
			_tile_indices[tile_id] = idx

	print("Assigned %d test tile indices (6 vertical stripes)" % _tile_indices.size())


func _create_grid() -> void:
	# Generate wireframe grid mesh
	_grid_mesh = SphericalGridGenerator.generate(
		"Earth",
		EARTH_RADIUS_KM,
		Color.WHITE,
		BASE_CELL_KM,
	)
	if _grid_mesh:
		_grid_mesh.visible = true
		add_child(_grid_mesh)
		print("Grid wireframe created")


func _create_tint() -> void:
	# Convert band_segs Array to Dictionary for generate_tint
	var band_segs_dict: Dictionary = {}
	var band_segs: Array = _band_structure["band_segs"]
	for i in range(band_segs.size()):
		band_segs_dict[str(i)] = band_segs[i]

	# Generate tint mesh using palette indices as vertex colors
	_tint_mesh = SphericalGridGenerator.generate_tint(
		"Earth",
		EARTH_RADIUS_KM,
		BASE_CELL_KM,
		_tile_indices,
		band_segs_dict,
	)
	if _tint_mesh:
		# Apply solid_tint shader material instead of StandardMaterial3D
		var shader_mat := ShaderMaterial.new()
		var shader := load("res://shaders/solid_tint.gdshader")
		shader_mat.shader = shader
		_tint_mesh.material_override = shader_mat

		# Register with palette manager
		if _palette_manager and _palette_manager.has_method("register_material"):
			# Defer — palette manager needs to be in tree first
			call_deferred("_register_tint_material")

		_tint_mesh.visible = true
		print("Tint mesh created with solid_tint shader")


func _register_tint_material() -> void:
	if _tint_mesh and _tint_mesh.material_override and _palette_manager:
		_palette_manager.register_material(_tint_mesh.material_override)


## Focus camera on a lat/lon position
func focus_on_lat_lon(lat_deg: float, lon_deg: float) -> Dictionary:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg + 180.0)

	var point := Vector3(
		-EARTH_RADIUS_KM * cos(lat) * cos(lon),
		EARTH_RADIUS_KM * sin(lat),
		EARTH_RADIUS_KM * cos(lat) * sin(lon),
	)

	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var cell: Dictionary = SphericalGridGenerator.find_cell_at_point(
		point, EARTH_RADIUS_KM, total_bands, band_segs,
	)
	return cell


## Toggle display mode (hooked up to UI or debug keys later)
func set_display_mode(mode: String) -> void:
	if _palette_manager and _palette_manager.has_method("set_display_mode"):
		_palette_manager.set_display_mode(mode)


func _create_coastlines() -> void:
	var coastline_script := load("res://scripts/planetary/coastline_overlay.gd")
	_coastline_overlay = Node.new()
	_coastline_overlay.name = "CoastlineOverlay"
	_coastline_overlay.set_script(coastline_script)
	add_child(_coastline_overlay)


func _create_rivers() -> void:
	var river_script := load("res://scripts/planetary/river_overlay.gd")
	_river_overlay = Node.new()
	_river_overlay.name = "RiverOverlay"
	_river_overlay.set_script(river_script)
	add_child(_river_overlay)
	# Initialize with band structure after a frame (needs _ready to fire first)
	call_deferred("_init_river_overlay")


func _init_river_overlay() -> void:
	if _river_overlay and _river_overlay.has_method("initialize"):
		_river_overlay.initialize(_band_structure)
```

**Step 2: Verify**

```bash
cat game/scripts/planetary/earth_display.gd
```

**Step 3: Commit**

```bash
git add game/scripts/planetary/earth_display.gd
git commit -m "feat(phase3): integrate palette shader system into earth_display"
```

---

### Task 6: Update spherical_grid_generator for palette indices

**Objective:** `generate_tint()` currently uses `_tile_colors` (Color values) for vertex colors. Now it receives palette indices (int) and encodes them in vertex colors for the solid shader. The solid shader treats `COLOR.r * 255` as the palette index.

Wait — actually, the solid shader just uses vertex color directly. So if we pass palette indices as vertex colors, each quad gets a single color... but that defeats the purpose.

**Rethink:** The solid shader should just use vertex color as the display color, period. The palette is irrelevant for solid quads — the PaletteManager already knows the right color. The tint mesh vertex colors should be set to the display color directly. The palette manager just needs to update material uniforms.

But wait — for textured quads, the texture holds palette indices. For solid quads, the vertex colors are the *final display colors* (pre-resolved from the palette). This means:
1. When display mode changes, solid quad vertex colors need updating too (re-generate or update mesh)
2. OR — we encode palette index in vertex color and have the solid shader look it up

The cleanest approach for Phase 3: **encode palette index in vertex color R channel**, and have the solid shader do a palette lookup. That way display mode switching is truly zero-cost for solid quads too.

Revised approach:

**solid_tint.gdshader** → does palette lookup from vertex color:

```glsl
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform vec4 normal_palette[256];
uniform vec4 highlight_palette[256];
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
    int idx = int(COLOR.r * 255.0 + 0.5);
    idx = clamp(idx, 0, 255);
    
    vec4 normal = normal_palette[idx];
    vec4 highlight = highlight_palette[idx];
    vec4 color = mix(normal, highlight, highlight_mix);
    
    ALBEDO = color.rgb;
    ALPHA = color.a;
}
```

Then `generate_tint()` needs to encode the palette index in vertex color. Currently it sets all 4 vertices to the same color. We need it to set `Color(idx/255.0, 0, 0, 1.0)` instead.

But wait, does `generate_tint()` support this? Let me check...

I need to look at what `generate_tint()` does with the color. It likely sets vertex colors on the ArrayMesh. If we pass palette indices (ints) instead of Colors, we need to modify the generator.

Actually, let me re-read the earth_display.gd code. The current call is:
```gdscript
_tint_mesh = SphericalGridGenerator.generate_tint(
    "Earth", EARTH_RADIUS_KM, BASE_CELL_KM, _tile_colors, band_segs_dict,
)
```

And `_tile_colors` is a `Dictionary` of `tile_id → Color`. We're changing it to `tile_id → int` (palette index).

So we need to modify `generate_tint()` to accept int values and encode them as `Color(idx/255.0, 0, 0, 1.0)` in vertex colors. Let me check the generator.

Actually, I should look at the generator to see what it does. Let me just read it.<｜end▁of▁thinking｜>Let me check the generator to understand how tint mesh vertex colors are set:

<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="read_file">
<｜｜DSML｜｜parameter name="path" string="true">D:\hermes-projects\historia-terrarum\game\scripts\data\spherical_grid_generator.gd