# EarthCamera.gd — Camera for Historia Terrarum
# Simplified from Stella Nostra's camera_controller.gd.
# Orbit around Earth, zoom in/out, object mode (surface zoom).
#
# Inputs:
#   - Left mouse drag: pan (orbit)
#   - Middle mouse / right mouse drag: orbit around Earth
#   - Scroll wheel / +/- keys: zoom between rungs
#   - Mouse hover: grid cell detection
extends Camera3D

const EARTH_RADIUS_KM := 6371.0
const EARTH_RADIUS_DISPLAY := 6371.0  # 1 unit = 1 km

# Orbit state
var _theta: float = 0.0        # Horizontal angle (radians)
var _phi: float = PI * 0.35    # Vertical angle (from top, 0=north pole)
var _distance: float = 15000.0  # Current distance from Earth center
var _target_distance: float = 15000.0

const ORBIT_SENSITIVITY := 0.004
const ZOOM_SPEED := 8.0
const MIN_DISTANCE := EARTH_RADIUS_KM * 1.05   # Just above surface
const MAX_DISTANCE := EARTH_RADIUS_KM * 50.0   # Far orbit

# Object mode (surface zoom)
var _object_mode: bool = false
var _object_body_radius: float = EARTH_RADIUS_DISPLAY

# Mouse state
var _is_dragging: bool = false
var _last_mouse_pos: Vector2
var _drag_button: int = -1

# Scroll throttle
var _last_scroll_time: float = -1.0
var _pending_scroll_dir: int = 0
const SCROLL_THROTTLE_MS := 80.0

# Earth center reference
var _earth_center: Vector3 = Vector3.ZERO


func _ready() -> void:
	position = Vector3(0, EARTH_RADIUS_DISPLAY * 0.5, EARTH_RADIUS_DISPLAY * 2.5)
	look_at(_earth_center, Vector3.UP)
	_distance = position.length()


func _process(delta: float) -> void:
	# Smooth zoom
	var diff: float = _target_distance - _distance
	if abs(diff) > 0.01:
		_distance += diff * min(delta * ZOOM_SPEED, 1.0)
		_update_camera_position()

	# Process queued scroll
	var now: float = Time.get_ticks_msec() / 1000.0
	if _pending_scroll_dir != 0 and (now - _last_scroll_time) * 1000.0 > SCROLL_THROTTLE_MS:
		_zoom(_pending_scroll_dir)
		_pending_scroll_dir = 0
		_last_scroll_time = now


func _input(event: InputEvent) -> void:
	# Scroll wheel zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_pending_scroll_dir = -1
			_last_scroll_time = Time.get_ticks_msec() / 1000.0
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_pending_scroll_dir = 1
			_last_scroll_time = Time.get_ticks_msec() / 1000.0
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_is_dragging = true
				_drag_button = MOUSE_BUTTON_RIGHT
				_last_mouse_pos = event.position
			else:
				_is_dragging = false
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_is_dragging = true
				_drag_button = MOUSE_BUTTON_LEFT
				_last_mouse_pos = event.position
			else:
				_is_dragging = false

	# Mouse drag for orbit
	if event is InputEventMouseMotion and _is_dragging:
		var delta_pos: Vector2 = event.position - _last_mouse_pos
		_last_mouse_pos = event.position

		if _drag_button == MOUSE_BUTTON_RIGHT:
			# Orbit
			_theta -= delta_pos.x * ORBIT_SENSITIVITY
			_phi -= delta_pos.y * ORBIT_SENSITIVITY
			_phi = clampf(_phi, 0.05, PI - 0.05)
			_update_camera_position()
		elif _drag_button == MOUSE_BUTTON_LEFT and _object_mode:
			# Pan in object mode (rotate around surface point)
			_theta -= delta_pos.x * ORBIT_SENSITIVITY * 0.5
			_phi -= delta_pos.y * ORBIT_SENSITIVITY * 0.5
			_phi = clampf(_phi, 0.05, PI - 0.05)
			_update_camera_position()

	# Keyboard zoom
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_EQUAL or event.keycode == KEY_PLUS:
			_zoom(-1)
		elif event.keycode == KEY_MINUS:
			_zoom(1)


func _zoom(direction: int) -> void:
	# direction: -1 = zoom in, +1 = zoom out
	var factor: float = 0.7 if direction < 0 else 1.4
	_target_distance = clampf(_target_distance * factor, MIN_DISTANCE, MAX_DISTANCE)


func _update_camera_position() -> void:
	var x: float = _distance * sin(_phi) * cos(_theta)
	var y: float = _distance * cos(_phi)
	var z: float = _distance * sin(_phi) * sin(_theta)
	position = _earth_center + Vector3(x, y, z)
	look_at(_earth_center, Vector3.UP)


## Focus camera on a surface point (for cell selection, city focus)
func look_at_surface_point(surface_point: Vector3, body_radius: float = EARTH_RADIUS_DISPLAY) -> void:
	# Enter object mode: zoom close to surface
	_object_mode = true
	var target: Vector3 = surface_point.normalized() * body_radius
	_target_distance = body_radius * 1.15  # Just above surface

	# Orient camera toward the point
	var dir: Vector3 = target.normalized()
	_theta = atan2(dir.z, dir.x)
	_phi = acos(clampf(dir.y / dir.length(), -1.0, 1.0))

	_update_camera_position()


## Exit object mode back to orbit
func exit_object_mode() -> void:
	_object_mode = false
	_target_distance = EARTH_RADIUS_KM * 3.0


func is_object_mode() -> bool:
	return _object_mode


func get_distance() -> float:
	return _distance
