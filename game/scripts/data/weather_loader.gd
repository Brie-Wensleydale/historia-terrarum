# weather_loader.gd — HT2 monthly temperature & precipitation reader
# Loads pre-baked weather.bin (48 bytes per cell, ~312 MB for ~6.5M tiles).
# Format per cell: 12 × int16 temp (°C×10) + 12 × int16 precip (mm)
# Provides O(1) monthly lookups.
extends RefCounted

const DATA_DIR := "res://../data/output/grid_10km_ht2/"
const WEATHER_FILE := "weather.bin"
const SUMMARY_FILE := "weather_summary.json"

const STRIDE := 48         # bytes per cell: 12 temp + 12 precip, int16 each
const TEMP_OFFSET := 0     # bytes from cell start
const PREC_OFFSET := 24    # bytes from cell start
const MONTH_COUNT := 12

const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var _data: PackedByteArray = PackedByteArray()
var _total_tiles: int = 0
var _total_bands: int = 0
var _cell_segs_per_band: PackedInt32Array = PackedInt32Array()
var _band_offsets: PackedInt32Array = PackedInt32Array()


func load() -> bool:
	var bin_path: String = DATA_DIR + WEATHER_FILE

	if not FileAccess.file_exists(bin_path):
		push_error("WeatherLoader: weather.bin not found at %s" % bin_path)
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

	# Load binary
	var mf: FileAccess = FileAccess.open(bin_path, FileAccess.READ)
	if not mf:
		return false
	_data = mf.get_buffer(mf.get_length())
	mf.close()

	print("WeatherLoader: loaded %d bytes, %d tiles (%.0f MB)" % [
		_data.size(), _total_tiles, float(_data.size()) / 1048576.0,
	])
	return true


func _cell_offset(band: int, seg: int) -> int:
	"""Byte offset for a cell in weather.bin."""
	if band < 0 or band >= _total_bands:
		return -1
	if _cell_segs_per_band.size() == 0:
		return -1
	if seg < 0 or seg >= _cell_segs_per_band[band]:
		return -1
	var tile_index: int = _band_offsets[band] + seg
	var byte_offset: int = tile_index * STRIDE
	if byte_offset + STRIDE > _data.size():
		return -1
	return byte_offset


func _read_int16(offset: int) -> int:
	"""Read a little-endian int16 from the byte array at given offset."""
	if offset < 0 or offset + 2 > _data.size():
		return 0
	return (_data[offset] | (_data[offset + 1] << 8)) as int


func get_monthly_temp(band: int, seg: int, month: int) -> float:
	"""Temperature in °C for given month (0=Jan, 11=Dec)."""
	var offset: int = _cell_offset(band, seg)
	if offset < 0:
		return 0.0
	if month < 0 or month >= MONTH_COUNT:
		return 0.0
	var raw: int = _read_int16(offset + TEMP_OFFSET + month * 2)
	# Handle signed int16 from unsigned read
	if raw >= 32768:
		raw -= 65536
	return float(raw) / 10.0


func get_monthly_precip(band: int, seg: int, month: int) -> float:
	"""Precipitation in mm for given month (0=Jan, 11=Dec)."""
	var offset: int = _cell_offset(band, seg)
	if offset < 0:
		return 0.0
	if month < 0 or month >= MONTH_COUNT:
		return 0.0
	var raw: int = _read_int16(offset + PREC_OFFSET + month * 2)
	return float(raw)


func get_annual_temp(band: int, seg: int) -> float:
	"""Annual mean temperature in °C."""
	var sum_temp: float = 0.0
	for m in range(MONTH_COUNT):
		sum_temp += get_monthly_temp(band, seg, m)
	return sum_temp / float(MONTH_COUNT)


func get_annual_precip(band: int, seg: int) -> float:
	"""Annual total precipitation in mm."""
	var sum_prec: float = 0.0
	for m in range(MONTH_COUNT):
		sum_prec += get_monthly_precip(band, seg, m)
	return sum_prec


func get_temp_by_day(band: int, seg: int, day_of_year: int) -> float:
	"""Interpolated temperature for a given day (0-364)."""
	var month: int = clampi(day_of_year / 30, 0, 11)
	var next_month: int = (month + 1) % 12
	var frac: float = float(day_of_year % 30) / 30.0
	var t0: float = get_monthly_temp(band, seg, month)
	var t1: float = get_monthly_temp(band, seg, next_month)
	return lerpf(t0, t1, frac)
