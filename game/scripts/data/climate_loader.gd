# climate_loader.gd — HT2 Köppen climate zone reader
# Loads pre-baked climate.bin (1 byte per cell, ~6.5 MB).
# Provides O(1) get_climate(band, seg) lookup.
extends RefCounted

const DATA_DIR := "res://../data/output/grid_10km_ht2/"
const CLIMATE_FILE := "climate.bin"
const SUMMARY_FILE := "climate_summary.json"

# Köppen climate names matching generate_climate.py encoding
const CLIMATE_NAMES := {
	1: "Af", 2: "Am", 3: "Aw",
	4: "BWh", 5: "BWk", 6: "BSh", 7: "BSk",
	8: "Csa", 9: "Csb", 10: "Csc",
	11: "Cwa", 12: "Cwb", 13: "Cwc",
	14: "Cfa", 15: "Cfb", 16: "Cfc",
	17: "Dsa", 18: "Dsb", 19: "Dsc", 20: "Dsd",
	21: "Dwa", 22: "Dwb", 23: "Dwc", 24: "Dwd",
	25: "Dfa", 26: "Dfb", 27: "Dfc", 28: "Dfd",
	29: "ET", 30: "EF",
}

const CLIMATE_GROUPS := {
	"A": "Tropical", "B": "Arid", "C": "Temperate",
	"D": "Continental", "E": "Polar",
}

var _data: PackedByteArray = PackedByteArray()
var _total_tiles: int = 0
var _total_bands: int = 0
var _cell_segs_per_band: PackedInt32Array = PackedInt32Array()
var _band_offsets: PackedInt32Array = PackedInt32Array()


func load() -> bool:
	var bin_path: String = DATA_DIR + CLIMATE_FILE
	var summary_path: String = DATA_DIR + SUMMARY_FILE

	if not FileAccess.file_exists(bin_path):
		push_error("ClimateLoader: climate.bin not found at %s" % bin_path)
		return false

	if not FileAccess.file_exists(summary_path):
		push_error("ClimateLoader: summary JSON not found")
		return false

	# Load summary
	var sf: FileAccess = FileAccess.open(summary_path, FileAccess.READ)
	if not sf:
		return false
	var json_text: String = sf.get_as_text()
	sf.close()
	var json: JSON = JSON.new()
	if json.parse(json_text) != OK:
		return false
	var data: Dictionary = json.get_data()
	_total_tiles = data["total_tiles"]

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

	# Load binary
	var mf: FileAccess = FileAccess.open(bin_path, FileAccess.READ)
	if not mf:
		return false
	_data = mf.get_buffer(mf.get_length())
	mf.close()

	print("ClimateLoader: loaded %d bytes, %d tiles" % [_data.size(), _total_tiles])
	return true


func get_climate(band: int, seg: int) -> int:
	"""Returns Köppen climate code (1-31). 0 = no data."""
	if band < 0 or band >= _total_bands:
		return 0
	if seg < 0 or _cell_segs_per_band.size() == 0:
		return 0
	if seg >= _cell_segs_per_band[band]:
		return 0
	var idx: int = _band_offsets[band] + seg
	if idx >= _data.size():
		return 0
	return _data[idx]


func get_climate_name(band: int, seg: int) -> String:
	var code: int = get_climate(band, seg)
	return CLIMATE_NAMES.get(code, "??")


func get_climate_group(band: int, seg: int) -> String:
	var name: String = get_climate_name(band, seg)
	if name.length() > 0:
		return CLIMATE_GROUPS.get(name[0], "Unknown")
	return "Unknown"
