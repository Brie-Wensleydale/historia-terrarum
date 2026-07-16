# time_manager.gd — Central game time system.
# Tracks game year, time scale, pause state.
# All game processes (research, building, battles, etc.) query this
# node for delta time so they all speed up/slow down/pause together.
extends Node

# Game clock
var _current_year: int = 11950     # Default: 1950 AD (year 0 = 10,000 BC)
var _current_day: int = 0           # Day of year (0-365)
var _elapsed_game_seconds: float = 0.0  # Accumulated game seconds

# Time scale — how many game seconds per real second
# Slowest: 15 min/sec = 900 game_sec/real_sec
# Fastest: 1 day/sec  = 86400 game_sec/real_sec
const SECONDS_PER_MINUTE := 60
const SECONDS_PER_HOUR := 3600
const SECONDS_PER_DAY := 86400
const SECONDS_PER_YEAR := 31536000  # 365 days

var _time_scale: float = SECONDS_PER_HOUR  # Default: 1 real sec = 1 game hour
var _paused: bool = false
var _time_scale_index: int = 4

# Speed rungs (interpolated between slowest and fastest from Stella Nostra)
const SPEED_RUNGS := [
	{"label": "15m/s",  "scale": SECONDS_PER_MINUTE * 15,  "desc": "15 min per sec"},
	{"label": "30m/s",  "scale": SECONDS_PER_MINUTE * 30,  "desc": "30 min per sec"},
	{"label": "1h/s",   "scale": SECONDS_PER_HOUR,          "desc": "1 hour per sec"},
	{"label": "3h/s",   "scale": SECONDS_PER_HOUR * 3,      "desc": "3 hours per sec"},
	{"label": "6h/s",   "scale": SECONDS_PER_HOUR * 6,      "desc": "6 hours per sec"},
	{"label": "12h/s",  "scale": SECONDS_PER_HOUR * 12,     "desc": "12 hours per sec"},
	{"label": "1d/s",   "scale": SECONDS_PER_DAY,           "desc": "1 day per sec"},
]

signal time_changed(year: int, day: int)
signal pause_changed(paused: bool)
signal speed_changed(speed_index: int)


func _ready() -> void:
	print("TimeManager: year %d, default speed %s" % [_current_year, SPEED_RUNGS[_time_scale_index]["label"]])


func _process(delta: float) -> void:
	if _paused:
		return

	# Advance game time
	var game_delta: float = delta * _time_scale
	_elapsed_game_seconds += game_delta

	# Check for day/year rollover
	var new_day: int = int(_elapsed_game_seconds / SECONDS_PER_DAY) % 365
	var new_year: int = _current_year + int(_elapsed_game_seconds / SECONDS_PER_YEAR)

	if new_year != _current_year:
		_current_year = new_year
		_elapsed_game_seconds = fmod(_elapsed_game_seconds, SECONDS_PER_YEAR)
		_current_day = int(_elapsed_game_seconds / SECONDS_PER_DAY)
		time_changed.emit(_current_year, _current_day)
	elif new_day != _current_day:
		_current_day = new_day
		time_changed.emit(_current_year, _current_day)


func get_game_delta() -> float:
	"""Return the game-time delta for this frame (0 if paused)."""
	if _paused:
		return 0.0
	return get_process_delta_time() * _time_scale


func set_paused(p: bool) -> void:
	if _paused != p:
		_paused = p
		pause_changed.emit(_paused)
		print("Time: %s" % ("PAUSED" if _paused else "RUNNING"))


func toggle_pause() -> void:
	set_paused(not _paused)


func is_paused() -> bool:
	return _paused


func set_speed(index: int) -> void:
	var clamped: int = clampi(index, 0, SPEED_RUNGS.size() - 1)
	if clamped != _time_scale_index:
		_time_scale_index = clamped
		_time_scale = SPEED_RUNGS[clamped]["scale"]
		speed_changed.emit(_time_scale_index)
		print("Time speed: %s" % SPEED_RUNGS[clamped]["label"])


func speed_up() -> void:
	set_speed(_time_scale_index + 1)


func speed_down() -> void:
	set_speed(_time_scale_index - 1)


func get_current_speed_label() -> String:
	return SPEED_RUNGS[_time_scale_index]["label"]


func get_current_speed_index() -> int:
	return _time_scale_index


func get_current_year() -> int:
	return _current_year


func get_date_string() -> String:
	"""Return human-readable date like 'July 16, 1950'."""
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var month_idx: int = (_current_day / 30) % 12
	var day_of_month: int = (_current_day % 30) + 1
	return "%s %d, %d" % [months[month_idx], day_of_month, _current_year]


func set_year(year: int) -> void:
	_current_year = year
	_current_day = 0
	_elapsed_game_seconds = 0.0
	time_changed.emit(_current_year, _current_day)
