# terrain_loader.gd — HT2 terrain type reader
# Loads pre-baked terrain.bin (1 byte per cell, ~6.5 MB).
# Provides O(1) get_terrain(band, seg) + get_slope(band, seg) lookup.
extends RefCounted

const DATA_DIR := "res://../data/output/grid_10km_ht2/"
const TERRAIN_FILE := "terrain.bin"
const SLOPE_FILE := "slope.bin"

# Terrain type names matching generate_terrain.py classification
const TERRAIN_NAMES := [
	"deep_ocean",
	"ocean",
	"shallow_ocean",
	"continental_shelf",
	"coastal",
	"lowland",
	"upland",
	"highland",
	"mountain",
	"high_mountain",
	"extreme_mountain",
]

# Terrain colours for visualisation (RGBA8)
const TERRAIN_COLORS := [
	Color(0.02, 0.10, 0.35, 1.0),  # deep ocean
	Color(0.05, 0.20, 0.55, 1.0),  # ocean
	Color(0.10, 0.35, 0.65, 1.0),  # shallow ocean
	Color(0.15, 0.45, 0.70, 1.0),  # continental shelf
	Color(0.85, 0.80, 0.40, 1.0),  # coastal
	Color(0.30, 0.70, 0.30, 1.0),  # lowland
	Color(0.40, 0.60, 0.25, 1.0),  # upland
	Color(0.55, 0.50, 0.20, 1.0),  # highland
	Color(0.45, 0.35, 0.20, 1.0),  # mountain
	Color(0.60, 0.50, 0.45, 1.0),  # high mountain
	Color(0.90, 0.90, 0.90, 1.0),  # extreme mountain
]

# Slope names
const SLOPE_NAMES := ["flat", "gentle", "moderate", "steep", "cliff"]

var _terrain_data: PackedByteArray = PackedByteArray()
var _slope_data: PackedByteArray = PackedByteArray()
var _total_tiles: int = 0
var _total_bands: int = 0
var _cell_segs_per_band: PackedInt32Array = PackedInt32Array()
var _band_offsets: PackedInt32Array = PackedInt32Array()


func load() -> bool:
	var terrain_path: String = DATA_DIR + TERRAIN_FILE
	var slope_path: String = DATA_DIR + SLOPE_FILE

	if not FileAccess.file_exists(terrain_path):
		push_error("TerrainLoader: terrain.bin not found at %s" % terrain_path)
		return false

	# Load band structure from land mask summary (shared grid)
	var land_summary_path: String = DATA_DIR + "land_mask_summary.json"
	if FileAccess.file_exists(land_summary_path):
		var lf: FileAccess = FileAccess.open(land_summary_path, FileAccess.READ)
		if lf:
			var ltext: String = lf.get_as_text()
			lf.close()
			var ljson: JSON = JSON.new()
			if ljson.parse(ltext) == OK:
				var ldata: Dictionary = ljson.get_data()
				_total_bands = ldata["grid"]["total_bands"]
				_total_tiles = ldata["tiles"]["total"]
				var ring_segs: Dictionary = ldata["band_segs"]
				var offset: int = 0
				_cell_segs_per_band.resize(_total_bands)
				_band_offsets.resize(_total_bands)
				for b in range(_total_bands):
					var segs_bot: int = ring_segs.get(str(b), 0)
					var segs_top: int = ring_segs.get(str(b + 1), segs_bot)
					var cell_segs: int = maxi(segs_bot, segs_top)
					_cell_segs_per_band[b] = cell_segs
					_band_offsets[b] = offset
					offset += cell_segs

	# Load terrain binary
	var tf: FileAccess = FileAccess.open(terrain_path, FileAccess.READ)
	if not tf:
		return false
	_terrain_data = tf.get_buffer(tf.get_length())
	tf.close()

	# Load slope binary (optional)
	if FileAccess.file_exists(slope_path):
		var sf: FileAccess = FileAccess.open(slope_path, FileAccess.READ)
		if sf:
			_slope_data = sf.get_buffer(sf.get_length())
			sf.close()

	print("TerrainLoader: loaded %d bytes terrain + %d bytes slope, %d tiles" % [
		_terrain_data.size(), _slope_data.size(), _total_tiles,
	])
	return true


func _idx(band: int, seg: int) -> int:
	if band < 0 or band >= _total_bands:
		return -1
	if _cell_segs_per_band.size() == 0:
		return -1
	if seg < 0 or seg >= _cell_segs_per_band[band]:
		return -1
	var idx: int = _band_offsets[band] + seg
	if idx >= _terrain_data.size():
		return -1
	return idx


func get_terrain(band: int, seg: int) -> int:
	var idx: int = _idx(band, seg)
	if idx < 0:
		return 0
	return _terrain_data[idx]


func get_terrain_name(band: int, seg: int) -> String:
	var t: int = get_terrain(band, seg)
	if t >= 0 and t < TERRAIN_NAMES.size():
		return TERRAIN_NAMES[t]
	return "unknown"


func get_terrain_color(band: int, seg: int) -> Color:
	var t: int = get_terrain(band, seg)
	if t >= 0 and t < TERRAIN_COLORS.size():
		return TERRAIN_COLORS[t]
	return Color.GRAY


func get_slope(band: int, seg: int) -> int:
	var idx: int = _idx(band, seg)
	if idx < 0 or idx >= _slope_data.size():
		return 0
	return _slope_data[idx]


func get_slope_name(band: int, seg: int) -> String:
	var s: int = get_slope(band, seg)
	if s >= 0 and s < SLOPE_NAMES.size():
		return SLOPE_NAMES[s]
	return "unknown"


func is_land(band: int, seg: int) -> bool:
	"""Terrain codes 4+ are land (coastal and above)."""
	return get_terrain(band, seg) >= 4
