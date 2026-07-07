# territory_data.gd — Territory data loader and runtime state.
# Loads tile→country mappings, manages the palette, and handles
# territory updates (occupation, annexation) with dirty-tracking
# for LOD regeneration.
extends Node

const PALETTE_SIZE := 256

# Territory palettes (indexed by palette_index)
var _country_palette: Array = []          # PaletteIndex → Color (political view)
var _country_names: Array = []            # PaletteIndex → country name
var _province_palette: Array = []         # PaletteIndex → Color (province view)
var _display_mode: String = "political"   # political | province | diplomatic | occupation

# Highlight state
var _highlighted_country: int = -1

# LOD 0 tile ownership: tile_id → {country_idx, province_idx, occupier_idx, control_pct}
var _tile_ownership: Dictionary = {}

# Shader uniforms (set per-frame)
var _shader_material: ShaderMaterial


func _ready() -> void:
	_load_palette_data()


func _load_palette_data() -> void:
	# Placeholder — will load from country registry YAML
	_country_palette.resize(PALETTE_SIZE)
	_country_names.resize(PALETTE_SIZE)
	_province_palette.resize(PALETTE_SIZE)

	# Default: all palette entries map to transparent (ocean)
	for i in range(PALETTE_SIZE):
		_country_palette[i] = Color.TRANSPARENT
		_province_palette[i] = Color.TRANSPARENT

	print("Territory data initialized")


func set_display_mode(mode: String) -> void:
	_display_mode = mode
	_update_shader_palettes()


func highlight_country(country_idx: int) -> void:
	_highlighted_country = country_idx
	_update_shader_palettes()


func clear_highlight() -> void:
	_highlighted_country = -1
	_update_shader_palettes()


func _update_shader_palettes() -> void:
	if not _shader_material:
		return

	# Build normal and highlight palettes from current state
	# (Stub — will be implemented with actual palette data)
	pass


func update_tile_ownership(tile_id: String, country_idx: int, province_idx: int = -1, occupier_idx: int = -1, control_pct: float = 1.0) -> void:
	_tile_ownership[tile_id] = {
		"country": country_idx,
		"province": province_idx,
		"occupier": occupier_idx,
		"control": control_pct,
	}
	# Mark upstream LOD quads dirty (handled by chunk manager)
