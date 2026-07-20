# EarthCamera.gd — Polished orbit camera for Historia Terrarum.
# Phase 6: Zoom rungs, smooth transitions, surface tracking, momentum.
extends Camera3D

const EARTH_RADIUS_KM := 6371.0
const EARTH_RADIUS_DISPLAY := 6371.0

# ── Zoom Rungs ──
# Discrete zoom levels paired with LOD recommendations.
# Distance in km from Earth center. Each rung = 1 LOD level.
const ZOOM_RUNGS := [
	{"name": "Tactical",  "distance": 7500.0,  "lod": 0},
	{"name": "Regional",  "distance": 12000.0, "lod": 1},
	{"name": "Continental", "distance": 22000.0, "lod": 2},
	{"name": "Hemisphere",  "distance": 38000.0, "lod": 3},
	{"name": "Global",    "distance": 60000.0, "lod": 4},
]
var _current_rung: int = 2  # Start at continental view

# ── Orbit State ──
var _theta: float = 0.0        # Horizontal angle (radians)
var _phi: float = PI * 0.35    # Vertical angle from top (0 = north pole)
var _distance: float = 22000.0  # Current distance from Earth center
var _target_distance: float = 22000.0
var _target_theta: float = 0.0
var _target_phi: float = PI * 0.35

# ── Momentum ──
var _orbit_velocity: Vector2 = Vector2.ZERO  # (theta_vel, phi_vel)
const MOMENTUM_DECAY := 5.0       # How fast momentum fades (per second)
const ORBIT_SENSITIVITY := 0.004
const ZOOM_SPEED := 6.0           # Smooth zoom speed
const ROTATION_SPEED := 8.0       # Smooth rotation speed
const MIN_DISTANCE := EARTH_RADIUS_KM * 1.08  # Just above surface (no clipping)
const MAX_DISTANCE := EARTH_RADIUS_KM * 60.0  # Far orbit

# ── Object / Surface Mode ──
var _object_mode: bool = false
var _surface_point: Vector3 = Vector3.ZERO
var _object_body_radius: float = EARTH_RADIUS_DISPLAY

# ── Mouse State ──
var _is_dragging: bool = false
var _last_mouse_pos: Vector2
var _drag_button: int = -1

# ── Scroll Throttle ──
var _scroll_cooldown: float = 0.0
const SCROLL_COOLDOWN_SEC := 0.15  # Minimum time between rung changes

# ── Earth Center ──
var _earth_center: Vector3 = Vector3.ZERO


func _ready() -> void:
	# Camera far plane must cover the full orbit range (up to 100,000 units)
	near = 10.0
	far = 200000.0
	_snap_to_rung(_current_rung)
	_distance = _target_distance
	_update_camera_position()


func _process(delta: float) -> void:
	# Smooth zoom toward target distance
	var diff: float = _target_distance - _distance
	if abs(diff) > 0.01:
		_distance += diff * min(delta * ZOOM_SPEED, 1.0)
		_update_camera_position()

	# Smooth rotation toward target angles
	var theta_diff: float = _target_theta - _theta
	var phi_diff: float = _target_phi - _phi
	if abs(theta_diff) > 0.0001 or abs(phi_diff) > 0.0001:
		_theta += theta_diff * min(delta * ROTATION_SPEED, 1.0)
		_phi += phi_diff * min(delta * ROTATION_SPEED, 1.0)
		_update_camera_position()

	# Momentum decay
	if not _is_dragging and _orbit_velocity.length_squared() > 0.0001:
		_target_theta += _orbit_velocity.x * delta
		_target_phi += _orbit_velocity.y * delta
		_orbit_velocity *= exp(-MOMENTUM_DECAY * delta)
		_clamp_target_angles()

	# Scroll cooldown
	if _scroll_cooldown > 0.0:
		_scroll_cooldown -= delta


func _input(event: InputEvent) -> void:
	# Scroll wheel: jump between zoom rungs
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_rung(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_rung(1)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_begin_drag(MOUSE_BUTTON_RIGHT, event.position)
			else:
				_end_drag()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_drag(MOUSE_BUTTON_LEFT, event.position)
			else:
				_end_drag()

	# Mouse drag: orbit
	if event is InputEventMouseMotion and _is_dragging:
		_process_drag(event)

	# Keyboard zoom (for fine control)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_EQUAL or event.keycode == KEY_PLUS:
			_zoom_rung(-1)
		elif event.keycode == KEY_MINUS:
			_zoom_rung(1)
		elif event.keycode == KEY_R:  # Reset view
			_reset_view()


func _begin_drag(button: int, pos: Vector2) -> void:
	_is_dragging = true
	_drag_button = button
	_last_mouse_pos = pos
	_orbit_velocity = Vector2.ZERO  # Kill momentum on new drag


func _end_drag() -> void:
	# Transfer current drag velocity to momentum
	if _is_dragging:
		# Momentum is already being accumulated in _process_drag via _target changes
		pass
	_is_dragging = false
	_drag_button = -1


func _process_drag(event: InputEventMouseMotion) -> void:
	var delta_pos: Vector2 = event.position - _last_mouse_pos
	_last_mouse_pos = event.position

	if _drag_button == MOUSE_BUTTON_RIGHT:
		# Orbit — accumulate velocity for momentum
		var theta_delta: float = delta_pos.x * ORBIT_SENSITIVITY
		var phi_delta: float = -delta_pos.y * ORBIT_SENSITIVITY
		_target_theta += theta_delta
		_target_phi += phi_delta
		_orbit_velocity.x += theta_delta  # Accumulate for momentum
		_orbit_velocity.y += phi_delta
		_clamp_target_angles()

	elif _drag_button == MOUSE_BUTTON_LEFT and _object_mode:
		# Pan in surface mode
		var theta_delta: float = -delta_pos.x * ORBIT_SENSITIVITY * 0.5
		var phi_delta: float = -delta_pos.y * ORBIT_SENSITIVITY * 0.5
		_target_theta += theta_delta
		_target_phi += phi_delta
		_clamp_target_angles()


func _clamp_target_angles() -> void:
	_target_phi = clampf(_target_phi, 0.02, PI - 0.02)


## Jump to the next/previous zoom rung.
func _zoom_rung(direction: int) -> void:
	if _scroll_cooldown > 0.0:
		return
	_scroll_cooldown = SCROLL_COOLDOWN_SEC

	var new_rung: int = clampi(_current_rung + direction, 0, ZOOM_RUNGS.size() - 1)
	if new_rung != _current_rung:
		_current_rung = new_rung
		_snap_to_rung(_current_rung)
		print("Zoom: %s (%.0f km)" % [ZOOM_RUNGS[_current_rung]["name"], _target_distance])


## Snap target distance to a specific rung.
func _snap_to_rung(rung: int) -> void:
	var rung_data: Dictionary = ZOOM_RUNGS[clampi(rung, 0, ZOOM_RUNGS.size() - 1)]
	_target_distance = rung_data["distance"]


## Get current LOD recommendation (0-4).
func get_lod_recommendation() -> int:
	return ZOOM_RUNGS[_current_rung].get("lod", 2)


## Smoothly reset view to default angle.
func _reset_view() -> void:
	_current_rung = 2
	_snap_to_rung(_current_rung)
	_target_theta = 0.0
	_target_phi = PI * 0.35
	_orbit_velocity = Vector2.ZERO
	print("View reset: Continental (%.0f km)" % _target_distance)


## Focus camera on a surface point for close inspection.
func focus_on_surface(surface_point: Vector3, body_radius: float = EARTH_RADIUS_DISPLAY) -> void:
	_object_mode = true
	_surface_point = surface_point

	# Orient toward the point
	var dir: Vector3 = surface_point.normalized()
	_target_theta = atan2(-dir.z, dir.x)  # inverses negated-Z mesh
	_target_phi = acos(clampf(dir.y / dir.length(), -1.0, 1.0))

	# Snap to LOD 0 (tactical, closest)
	_current_rung = 0
	_target_distance = ZOOM_RUNGS[0]["distance"]

	_update_camera_position()


## Exit surface mode back to orbit.
func exit_surface_mode() -> void:
	_object_mode = false
	_current_rung = 1
	_snap_to_rung(_current_rung)


func is_object_mode() -> bool:
	return _object_mode


func get_distance() -> float:
	return _distance


func _update_camera_position() -> void:
	var x: float = _distance * sin(_phi) * cos(_theta)
	var y: float = _distance * cos(_phi)
	var z: float = _distance * sin(_phi) * sin(_theta)
	position = _earth_center + Vector3(x, y, z)
	look_at(_earth_center, Vector3.UP)
