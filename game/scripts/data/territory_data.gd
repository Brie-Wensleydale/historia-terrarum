# territory_data.gd — Territory data loader and runtime state.
# Loads tile→country mappings from Phase 4b data, manages palette lookups,
# and supports territory updates (occupation, annexation) with dirty-tracking.
# Phase 8: Timeline engine — load events, fast-forward to any year.
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

# Timeline events
var _timeline_events: Array = []      # Sorted by year
var _country_name_to_idx: Dictionary = {}  # "Russia" → 1
var _country_idx_to_name: Dictionary = {}  # 1 → "Russia"
var _current_year: int = 11950        # Default: 1950
var _events_applied: int = 0

# Reference to PaletteManager
var _palette_manager: Node


func _ready() -> void:
	_palette_manager = get_node_or_null("/root/Main/PaletteManager")
	_load_tile_mapping()
	_load_country_name_map()
	_load_timeline()
	_load_region_index()
	print("TerritoryData: %d tiles, %d timeline events, start year %d" % [
		_tile_palette.size(), _timeline_events.size(), _current_year,
	])


func _load_tile_mapping() -> void:
	var path: String = "res://../data/countries/tile_mapping.json"
	if not FileAccess.file_exists(path):
		path = "res://assets/data/countries/tile_mapping.json"
	if not FileAccess.file_exists(path):
		push_warning("TerritoryData: tile_mapping.json not found")
		return

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		push_error("TerritoryData: failed to parse tile_mapping.json")
		return
	_tile_palette = json.get_data()


func _load_country_name_map() -> void:
	var path: String = "res://../data/countries/country_registry.json"
	if not FileAccess.file_exists(path):
		path = "res://assets/data/countries/country_registry.json"
	if not FileAccess.file_exists(path):
		return

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return

	var data: Dictionary = json.get_data()
	for c in data.get("countries", []):
		var name: String = c.get("id", "")
		var idx: int = c.get("palette_index", 0)
		if name != "" and idx > 0:
			_country_name_to_idx[name.to_lower()] = idx
			_country_idx_to_name[idx] = name


func _load_timeline() -> void:
	var path: String = "res://../data/timeline/events.json"
	if not FileAccess.file_exists(path):
		push_warning("TerritoryData: events.json not found — no timeline loaded")
		return

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		push_error("TerritoryData: failed to parse events.json")
		return

	var data: Dictionary = json.get_data()
	_timeline_events = data.get("events", [])
	_timeline_events.sort_custom(func(a, b): return a["year"] < b["year"])


func _load_region_index() -> void:
	pass  # Phase 5 — province-level detail LOD


func get_palette_index(tile_id: String) -> int:
	if _tile_ownership.has(tile_id):
		var own = _tile_ownership[tile_id]
		if own.get("occupier_idx", 0) > 0:
			return own["occupier_idx"]
		return own.get("owner_idx", 0)
	return _tile_palette.get(tile_id, 0)


func get_tile_owner_palette(tile_id: String) -> int:
	if _tile_ownership.has(tile_id):
		var own = _tile_ownership[tile_id]
		if own.get("occupier_idx", 0) > 0:
			return own["occupier_idx"]
		return own.get("owner_idx", 0)
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


## Fast-forward timeline events to a target year.
## Applies all events ≤ target_year, building the territory state.
func fast_forward_to(year: int) -> void:
	if _timeline_events.is_empty():
		print("Timeline: no events to apply")
		return

	_current_year = year
	_events_applied = 0

	for event in _timeline_events:
		var event_year: int = event["year"]
		if event_year > year:
			break
		_apply_event(event)
		_events_applied += 1

	print("Timeline: fast-forwarded to year %d — %d events applied" % [year, _events_applied])


## Apply a single timeline event's changes to territory state.
func _apply_event(event: Dictionary) -> void:
	var changes: Array = event.get("changes", [])
	if changes.is_empty():
		return

	for change in changes:
		var from_country: String = change.get("from_country", "")
		var to_country: String = change.get("to_country", "")
		var tile_list: Array = change.get("tiles", [])
		var bbox: Dictionary = change.get("bbox", {})

		var from_idx: int = -1
		var to_idx: int = -1

		if from_country != "":
			from_idx = _country_name_to_idx.get(from_country.to_lower(), -1)
		if to_country != "":
			to_idx = _country_name_to_idx.get(to_country.to_lower(), -1)

		if to_idx < 0:
			continue

		# Exact tile list
		if not tile_list.is_empty():
			for tid in tile_list:
				var current_idx: int = get_tile_owner_palette(tid)
				if from_idx < 0 or current_idx == from_idx:
					set_tile_owner(tid, to_idx)
			continue

		# Bbox — find all tiles within geographic region
		if not bbox.is_empty():
			var matching: Array = _find_tiles_in_bbox(bbox, from_idx)
			for tid in matching:
				set_tile_owner(tid, to_idx)


## Find all tiles within a bounding box that match from_idx (or all if from_idx < 0).
func _find_tiles_in_bbox(bbox: Dictionary, from_idx: int) -> Array:
	var result: Array = []
	var lat_min: float = bbox.get("lat_min", -90.0)
	var lat_max: float = bbox.get("lat_max", 90.0)
	var lon_min: float = bbox.get("lon_min", -180.0)
	var lon_max: float = bbox.get("lon_max", 180.0)

	for tid in _tile_palette:
		# Approximate lat/lon from tile ID
		var latlon := _tile_id_to_latlon(tid)
		if latlon.is_empty():
			continue
		var lat: float = latlon["lat"]
		var lon: float = latlon["lon"]

		if lat >= lat_min and lat <= lat_max and lon >= lon_min and lon <= lon_max:
			var idx: int = get_tile_owner_palette(tid)
			if from_idx < 0 or idx == from_idx:
				result.append(tid)

	return result


## Convert a tile ID like "B50_30" to approximate lat/lon.
## Uses 100km band structure: 200 bands, 400 equator segments.
func _tile_id_to_latlon(tid: String) -> Dictionary:
	var parts: PackedStringArray = tid.split("_")
	if parts.size() != 2 or not parts[0].begins_with("B"):
		return {}

	var band: int = parts[0].substr(1).to_int()
	var seg: int = parts[1].to_int()

	const TOTAL_BANDS := 200
	const EQUATOR_SEGS := 400

	# Approximate: band 0 = south pole, band 100 = equator, band 199 = north pole.
	# Segments: 0-399 around equator, fewer at poles.
	var lat: float = -90.0 + 180.0 * (float(band) + 0.5) / float(TOTAL_BANDS)
	var segs_at_band := _approx_segs_at_band(band)
	if segs_at_band <= 0:
		segs_at_band = 4
	var lon: float = -180.0 + 360.0 * (float(seg) + 0.5) / float(segs_at_band)

	return {"lat": lat, "lon": lon}


## Approximate segment count at a given band for lat/lon conversion.
func _approx_segs_at_band(band: int) -> int:
	# Rough approximation of the merge pattern:
	# Equator (band ~100): 400 segments
	# Poles (band 0, 199): 4 segments
	const TOTAL_BANDS := 200
	const EQUATOR_SEGS := 400
	const MIN_SEGS := 4

	var dist_from_equator: int = abs(band - TOTAL_BANDS / 2)
	var frac: float = float(dist_from_equator) / float(TOTAL_BANDS / 2)
	var segs: int = int(EQUATOR_SEGS * (1.0 - frac))
	return maxi(segs, MIN_SEGS)


## Get country name for a palette index (delegates to PaletteManager).
func get_country_name(idx: int) -> String:
	# Try local cache first
	if _country_idx_to_name.has(idx):
		return _country_idx_to_name[idx]
	if _palette_manager and _palette_manager.has_method("get_country_name"):
		return _palette_manager.get_country_name(idx)
	return ""


## Get the current game year.
func get_current_year() -> int:
	return _current_year


## Advance the game clock by one year (stub — Phase 8).
func advance_year() -> void:
	_current_year += 1
	# Apply any events for the new year
	for event in _timeline_events:
		if event["year"] == _current_year:
			_apply_event(event)
			_events_applied += 1
			print("  Event: %s (year %d)" % [event.get("name", "?"), _current_year])


## Get the number of events applied so far.
func get_events_applied() -> int:
	return _events_applied
