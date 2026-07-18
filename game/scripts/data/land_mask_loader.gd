# land_mask_loader.gd — HT2 binary land/water mask reader
# Loads pre-baked land_mask.bin (1 bit per cell, ~812 KB for ~6.5M cells).
# Provides O(1) is_land(band, seg) lookups via bit-level access.
# The binary is indexed band-first in denser-frame order matching generate_tint().
extends RefCounted

const MASK_DIR := "res://../data/output/grid_10km_ht2/"
const MASK_FILE := "land_mask.bin"
const SUMMARY_FILE := "land_mask_summary.json"

var _mask_bytes: PackedByteArray = PackedByteArray()
var _total_tiles: int = 0
var _land_count: int = 0
var _total_bands: int = 0
var _cell_segs_per_band: PackedInt32Array = PackedInt32Array()
var _band_offsets: PackedInt32Array = PackedInt32Array()  # prefix sum for O(1) index


## Load the binary mask and summary. Call once at startup.
## Returns true on success, false if files are missing or corrupt.
func load() -> bool:
	var mask_path: String = MASK_DIR + MASK_FILE
	var summary_path: String = MASK_DIR + SUMMARY_FILE

	if not FileAccess.file_exists(mask_path):
		push_error("LandMaskLoader: land_mask.bin not found at %s" % mask_path)
		return false

	if not FileAccess.file_exists(summary_path):
		push_error("LandMaskLoader: summary JSON not found at %s" % summary_path)
		return false

	# Load summary JSON
	var sf: FileAccess = FileAccess.open(summary_path, FileAccess.READ)
	if not sf:
		return false
	var json_text: String = sf.get_as_text()
	sf.close()

	var json: JSON = JSON.new()
	if json.parse(json_text) != OK:
		push_error("LandMaskLoader: failed to parse summary JSON")
		return false

	var data: Dictionary = json.get_data()
	_total_bands = data["grid"]["total_bands"]
	_total_tiles = data["tiles"]["total"]
	_land_count = data["tiles"]["land"]

	# Build cell_segs_per_band + band_offsets from band_segs rings
	var ring_segs: Dictionary = data["band_segs"]
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

	# Load binary mask
	var mf: FileAccess = FileAccess.open(mask_path, FileAccess.READ)
	if not mf:
		return false
	_mask_bytes = mf.get_buffer(mf.get_length())
	mf.close()

	print("LandMaskLoader: loaded %d bytes, %d tiles, %d land (%.1f%%)" % [
		_mask_bytes.size(), _total_tiles, _land_count,
		float(_land_count) / float(_total_tiles) * 100.0,
	])
	return true


## O(1) lookup: is the cell at (band, seg) land?
## seg uses the denser frame (0..cell_segs-1) — matching generate_tint() tile IDs.
func is_land(band: int, seg: int) -> bool:
	if band < 0 or band >= _total_bands:
		return false
	if seg < 0 or seg >= _cell_segs_per_band[band]:
		return false

	var bit_index: int = _band_offsets[band] + seg
	var byte_idx: int = bit_index / 8
	var bit_offset: int = bit_index % 8

	if byte_idx >= _mask_bytes.size():
		return false

	return (_mask_bytes[byte_idx] & (1 << bit_offset)) != 0


## Total tile count (from summary).
func total_tiles() -> int:
	return _total_tiles


## Land tile count (from summary).
func land_count() -> int:
	return _land_count


## Band count.
func total_bands() -> int:
	return _total_bands
