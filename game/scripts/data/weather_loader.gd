# weather_loader.gd — HT2 monthly climate data reader (4 variables)
# Loads pre-baked weather.bin (96 bytes per cell, ~624 MB for ~6.5M tiles).
# Format per cell (96 bytes):
#   24 bytes: tavg (temp °C × 10, 12 × int16)
#   24 bytes: prec (precip mm, 12 × int16)
#   24 bytes: srad (solar radiation kJ/m²/d, 12 × int16)
#   24 bytes: wind (wind speed m/s × 10, 12 × int16)
# Provides O(1) monthly lookups.
extends RefCounted

const DATA_DIR := "res://../data/output/grid_10km_ht2/"
const WEATHER_FILE := "weather.bin"

const STRIDE := 96              # bytes per cell: 4 vars × 12 months × int16
const MONTH_COUNT := 12
const NVARS := 4

# Variable index within stride
const VAR_TEMP := 0   # tavg: °C × 10
const VAR_PREC := 1   # prec: mm
const VAR_SRAD := 2   # srad: kJ/m²/day
const VAR_WIND := 3   # wind: m/s × 10
const VAR_BYTES := MONTH_COUNT * 2  # 24 bytes per variable

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
	if offset < 0 or offset + 2 > _data.size():
		return 0
	return (_data[offset] | (_data[offset + 1] << 8)) as int


func _get_var_value(band: int, seg: int, var_idx: int, month: int) -> int:
	var cell_off: int = _cell_offset(band, seg)
	if cell_off < 0:
		return 0
	if month < 0 or month >= MONTH_COUNT:
		return 0
	var offset: int = cell_off + var_idx * VAR_BYTES + month * 2
	var raw: int = _read_int16(offset)
	if raw >= 32768:
		raw -= 65536  # unsigned → signed
	return raw


# ── Temperature ──

func get_monthly_temp(band: int, seg: int, month: int) -> float:
	return float(_get_var_value(band, seg, VAR_TEMP, month)) / 10.0


func get_annual_temp(band: int, seg: int) -> float:
	var s: float = 0.0
	for m in range(MONTH_COUNT):
		s += get_monthly_temp(band, seg, m)
	return s / float(MONTH_COUNT)


# ── Precipitation ──

func get_monthly_precip(band: int, seg: int, month: int) -> float:
	return float(_get_var_value(band, seg, VAR_PREC, month))


func get_annual_precip(band: int, seg: int) -> float:
	var s: float = 0.0
	for m in range(MONTH_COUNT):
		s += get_monthly_precip(band, seg, m)
	return s


# ── Solar Radiation ──

func get_monthly_srad(band: int, seg: int, month: int) -> float:
	return float(_get_var_value(band, seg, VAR_SRAD, month))


func get_annual_srad(band: int, seg: int) -> float:
	var s: float = 0.0
	for m in range(MONTH_COUNT):
		s += get_monthly_srad(band, seg, m)
	return s


# ── Wind Speed ──

func get_monthly_wind(band: int, seg: int, month: int) -> float:
	return float(_get_var_value(band, seg, VAR_WIND, month)) / 10.0


func get_annual_wind(band: int, seg: int) -> float:
	var s: float = 0.0
	for m in range(MONTH_COUNT):
		s += get_monthly_wind(band, seg, m)
	return s / float(MONTH_COUNT)


# ── Interpolation ──

func get_temp_by_day(band: int, seg: int, day_of_year: int) -> float:
	var month: int = clampi(day_of_year / 30, 0, 11)
	var next_month: int = (month + 1) % 12
	var frac: float = float(day_of_year % 30) / 30.0
	var t0: float = get_monthly_temp(band, seg, month)
	var t1: float = get_monthly_temp(band, seg, next_month)
	return lerpf(t0, t1, frac)
