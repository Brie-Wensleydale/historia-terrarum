# palette_manager.gd — Loads country registry + palette from Phase 4b data.
# Manages 256-color palette arrays for shader uniforms.
# Display mode switching via keyboard shortcuts (1/2/3/4).
extends Node

const PALETTE_SIZE := 256
const OCEAN_INDEX := 0
const UNCLAIMED_INDEX := 255

# Data from country_registry.json
var _countries: Array = []           # country metadata dicts
var _country_by_index: Dictionary = {}  # palette_index → country dict

# Core palettes — one array per display mode
var _political_palette: Array = []
var _province_palette: Array = []
var _terrain_palette: Array = []

# Current display state
enum DisplayMode { POLITICAL, PROVINCE, TERRAIN, DIPLOMATIC }
var _display_mode: int = DisplayMode.POLITICAL
var _highlighted_idx: int = -1

# Shader materials to update each frame
var _registered_materials: Array[ShaderMaterial] = []


func _ready() -> void:
	_load_data()


func _load_data() -> void:
	_political_palette.resize(PALETTE_SIZE)
	_province_palette.resize(PALETTE_SIZE)
	_terrain_palette.resize(PALETTE_SIZE)

	# Default: all transparent
	for i in range(PALETTE_SIZE):
		_political_palette[i] = Color.TRANSPARENT
		_province_palette[i] = Color.TRANSPARENT
		_terrain_palette[i] = Color.TRANSPARENT

	# Ocean
	_political_palette[OCEAN_INDEX] = Color(0.1, 0.15, 0.4, 0.0)

	# Load palette colors
	var palette_colors: Array = _load_palette_json()
	if palette_colors.is_empty():
		push_warning("PaletteManager: no palette found, using fallback test colors")
		_add_fallback_palette()
		return

	# Load country registry
	_load_country_registry()

	# Apply palette colors to political palette
	for entry in palette_colors:
		var idx: int = entry["index"]
		if idx < 1 or idx >= PALETTE_SIZE:
			continue
		var c := Color(entry["r"], entry["g"], entry["b"], entry["a"])
		_political_palette[idx] = c

		# Province palette: slightly lighter variant
		_province_palette[idx] = Color(
			minf(c.r * 1.15, 1.0),
			minf(c.g * 1.15, 1.0),
			minf(c.b * 1.15, 1.0),
			c.a,
		)

		# Terrain palette: desaturated
		var gray: float = c.r * 0.299 + c.g * 0.587 + c.b * 0.114
		_terrain_palette[idx] = Color(
			gray * 0.3 + c.r * 0.2,
			gray * 0.4 + c.g * 0.3,
			gray * 0.3 + c.b * 0.3,
			c.a,
		)

	print("PaletteManager: loaded %d countries, %d palette entries" % [
		_countries.size(), palette_colors.size(),
	])


func _load_palette_json() -> Array:
	var path := "res://../data/countries/palette.json"
	if not FileAccess.file_exists(path):
		# Try alternate path (for editor vs runtime)
		path = "res://assets/data/countries/palette.json"
	if not FileAccess.file_exists(path):
		return []

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return []

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("PaletteManager: failed to parse palette.json: %s" % json.get_error_message())
		return []

	var data = json.get_data()
	return data.get("colors", [])


func _load_country_registry() -> void:
	var path := "res://../data/countries/country_registry.json"
	if not FileAccess.file_exists(path):
		path = "res://assets/data/countries/country_registry.json"
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		return

	var data = json.get_data()
	var raw_countries: Array = data.get("countries", [])
	for c in raw_countries:
		_countries.append(c)
		var idx: int = c.get("palette_index", 0)
		if idx > 0 and idx < PALETTE_SIZE:
			_country_by_index[idx] = c


func _add_fallback_palette() -> void:
	# Test colors if JSON loading fails
	_political_palette[1] = Color(0.8, 0.2, 0.2, 0.6)
	_political_palette[2] = Color(0.2, 0.6, 0.2, 0.6)
	_political_palette[3] = Color(0.2, 0.2, 0.8, 0.6)
	_political_palette[4] = Color(0.8, 0.7, 0.1, 0.6)
	_political_palette[5] = Color(0.6, 0.2, 0.6, 0.6)
	_political_palette[6] = Color(0.2, 0.6, 0.6, 0.6)
	for i in range(1, 7):
		_province_palette[i] = _political_palette[i].lightened(0.15)
		_terrain_palette[i] = Color(0.5, 0.5, 0.5, 0.6)


func _process(_delta: float) -> void:
	_handle_input()
	_update_all_materials()


func _handle_input() -> void:
	if Input.is_action_just_pressed("map_political"):
		_display_mode = DisplayMode.POLITICAL
		print("Display mode: Political")
	elif Input.is_action_just_pressed("map_province"):
		_display_mode = DisplayMode.PROVINCE
		print("Display mode: Province")
	elif Input.is_action_just_pressed("map_terrain"):
		_display_mode = DisplayMode.TERRAIN
		print("Display mode: Terrain")
	elif Input.is_action_just_pressed("map_diplomatic"):
		_display_mode = DisplayMode.DIPLOMATIC
		print("Display mode: Diplomatic")


func register_material(mat: ShaderMaterial) -> void:
	if mat and mat not in _registered_materials:
		_registered_materials.append(mat)


func unregister_material(mat: ShaderMaterial) -> void:
	_registered_materials.erase(mat)


func highlight_country(idx: int) -> void:
	_highlighted_idx = idx


func clear_highlight() -> void:
	_highlighted_idx = -1


func get_active_palette() -> Array:
	match _display_mode:
		DisplayMode.PROVINCE:
			return _province_palette
		DisplayMode.TERRAIN:
			return _terrain_palette
		_:
			return _political_palette


func get_country_name(idx: int) -> String:
	if idx < 0 or idx >= PALETTE_SIZE:
		return ""
	var entry: Dictionary = _country_by_index.get(idx, {})
	return entry.get("id", "")


func _update_all_materials() -> void:
	if _registered_materials.is_empty():
		return

	var active: Array = get_active_palette()

	for mat in _registered_materials:
		if not is_instance_valid(mat):
			continue

		for i in range(PALETTE_SIZE):
			var c: Color = active[i]
			mat.set_shader_parameter("normal_palette[%d]" % i, c)

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
