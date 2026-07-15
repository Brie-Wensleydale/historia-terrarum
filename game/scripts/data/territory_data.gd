# territory_data.gd — Territory data loader and runtime state.
# Loads tile→country mappings from Phase 4b data, manages palette lookups,
# and supports territory updates (occupation, annexation) with dirty-tracking.
extends Node

signal territory_changed

# Tile → palette_index mapping (loaded from tile_mapping.json)
var _tile_palette: Dictionary = {}

# Region metadata cache
var _region_data: Dictionary = {}  # region_id → {country, parent, tile_count}

# Territory state that can be modified by timeline events
var _tile_ownership: Dictionary = {}  # tile_id → {owner_idx, occupier_idx}

# Dirty tracking for LOD pyramid
var _dirty_tiles: Array[String] = []

# Reference to PaletteManager
var _palette_manager: Node


func _ready() -> void:
	_palette_manager = get_node_or_null("/root/Main/PaletteManager")
	_load_tile_mapping()
	_load_region_index()
	print("TerritoryData: loaded %d tile assignments" % _tile_palette.size())


func _load_tile_mapping() -> void:
	var path := "res://../data/countries/tile_mapping.json"
	if not FileAccess.file_exists(path):
		path = "res://assets/data/countries/tile_mapping.json"
	if not FileAccess.file_exists(path):
		push_warning("TerritoryData: tile_mapping.json not found")
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("TerritoryData: failed to parse tile_mapping.json")
		return

	_tile_palette = json.get_data()


func _load_region_index() -> void:
	# Load region metadata for province display mode (lazy — full data is 5,171 files)
	pass  # Phase 5 — province-level detail LOD


func get_palette_index(tile_id: String) -> int:
	if _tile_ownership.has(tile_id):
		# Check for occupation override
		var own = _tile_ownership[tile_id]
		if own.get("occupier_idx", 0) > 0:
			return own["occupier_idx"]
		return own.get("owner_idx", 0)
	return _tile_palette.get(tile_id, 0)


func get_tile_owner_palette(tile_id: String) -> int:
	return _tile_palette.get(tile_id, 0)


func set_tile_owner(tile_id: String, palette_idx: int) -> void:
	_tile_ownership[tile_id] = {"owner_idx": palette_idx, "occupier_idx": 0}
	_dirty_tiles.append(tile_id)
	territory_changed.emit()


func occupy_tile(tile_id: String, occupier_idx: int) -> void:
	if not _tile_ownership.has(tile_id):
		_tile_ownership[tile_id] = {"owner_idx": _tile_palette.get(tile_id, 0), "occupier_idx": occupier_idx}
	else:
		_tile_ownership[tile_id]["occupier_idx"] = occupier_idx
	_dirty_tiles.append(tile_id)
	territory_changed.emit()


func clear_occupation(tile_id: String) -> void:
	if _tile_ownership.has(tile_id):
		_tile_ownership[tile_id]["occupier_idx"] = 0


func is_tile_dirty(tile_id: String) -> bool:
	return tile_id in _dirty_tiles


func clear_dirty_tiles() -> void:
	_dirty_tiles.clear()


## Fast-forward timeline events to a target year (Phase 8 — stub)
func fast_forward_to(year: int) -> void:
	# TODO: load events.yaml, apply all events ≤ year
	pass


## Get country name for a palette index (delegates to PaletteManager)
func get_country_name(idx: int) -> String:
	if _palette_manager and _palette_manager.has_method("get_country_name"):
		return _palette_manager.get_country_name(idx)
	return ""
