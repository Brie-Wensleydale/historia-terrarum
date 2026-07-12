# palette_manager.gd — Manages territory color palettes for shader uniforms.
# Owns the 256-color arrays for each display mode (political, province, etc.)
# and pushes them to shader materials each frame.
#
# Display mode switching is zero-cost: just change which palette gets pushed.
# Highlighting works by building a blended highlight palette.
extends Node

const PALETTE_SIZE := 256

# Core palettes — one array per display mode
var _political_palette: Array = []        # index → Color
var _province_palette: Array = []         # index → Color
var _country_names: Array = []            # index → country name (for tooltips)

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
	add_country(1, "Test Red",    Color(0.8, 0.2, 0.2, 0.6), Color(0.9, 0.3, 0.3, 0.6))
	add_country(2, "Test Green",  Color(0.2, 0.6, 0.2, 0.6), Color(0.3, 0.7, 0.3, 0.6))
	add_country(3, "Test Blue",   Color(0.2, 0.2, 0.8, 0.6), Color(0.3, 0.3, 0.9, 0.6))
	add_country(4, "Test Gold",   Color(0.8, 0.7, 0.1, 0.6), Color(0.9, 0.8, 0.2, 0.6))
	add_country(5, "Test Purple", Color(0.6, 0.2, 0.6, 0.6), Color(0.7, 0.3, 0.7, 0.6))
	add_country(6, "Test Teal",   Color(0.2, 0.6, 0.6, 0.6), Color(0.3, 0.7, 0.7, 0.6))


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
