# time_control.gd — Top-right time control bar.
# Shows current date, pause/play, speed up/down buttons.
# Stella Nostra-style: compact bar above the selection panel.
extends Control

var _time_manager: Node
var _date_label: Label
var _speed_label: Label


func _ready() -> void:
	_setup_ui()
	_find_time_manager()


func _setup_ui() -> void:
	# Background bar
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.85)
	bg.size = Vector2(280, 36)
	bg.position = Vector2(10, 10)
	add_child(bg)

	# Date display (left side)
	_date_label = Label.new()
	_date_label.name = "DateLabel"
	_date_label.text = "Jan 1, 1950"
	_date_label.position = Vector2(14, 10)
	_date_label.size = Vector2(130, 18)
	_date_label.add_theme_font_size_override("font_size", 13)
	_date_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_date_label)

	# Speed label (center-right)
	_speed_label = Label.new()
	_speed_label.name = "SpeedLabel"
	_speed_label.text = "1h/s"
	_speed_label.position = Vector2(148, 10)
	_speed_label.size = Vector2(44, 18)
	_speed_label.add_theme_font_size_override("font_size", 12)
	_speed_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_speed_label)

	# Pause/Play button
	var pause_btn := Button.new()
	pause_btn.name = "PauseBtn"
	pause_btn.text = "⏸"
	pause_btn.position = Vector2(196, 8)
	pause_btn.size = Vector2(24, 22)
	pause_btn.flat = true
	pause_btn.pressed.connect(_on_pause_pressed)
	add_child(pause_btn)

	# Speed Down button
	var slow_btn := Button.new()
	slow_btn.name = "SlowBtn"
	slow_btn.text = "◀"
	slow_btn.position = Vector2(224, 8)
	slow_btn.size = Vector2(24, 22)
	slow_btn.flat = true
	slow_btn.pressed.connect(_on_speed_down)
	add_child(slow_btn)

	# Speed Up button
	var fast_btn := Button.new()
	fast_btn.name = "FastBtn"
	fast_btn.text = "▶"
	fast_btn.position = Vector2(252, 8)
	fast_btn.size = Vector2(24, 22)
	fast_btn.flat = true
	fast_btn.pressed.connect(_on_speed_up)
	add_child(fast_btn)


func _find_time_manager() -> void:
	var root := get_tree().root
	if root:
		for child in root.get_children():
			if child.name == "Main":
				for sub in child.get_children():
					if sub.name == "TimeManager":
						_time_manager = sub
						if _time_manager.has_signal("time_changed"):
							_time_manager.time_changed.connect(_on_time_changed)
						if _time_manager.has_signal("speed_changed"):
							_time_manager.speed_changed.connect(_on_speed_changed)
						if _time_manager.has_signal("pause_changed"):
							_time_manager.pause_changed.connect(_on_pause_changed)
						_update_display()
						return


func _update_display() -> void:
	if not _time_manager:
		return

	if _time_manager.has_method("get_date_string"):
		_date_label.text = _time_manager.get_date_string()

	if _time_manager.has_method("get_current_speed_label"):
		_speed_label.text = _time_manager.get_current_speed_label()

	var pause_btn := get_node_or_null("PauseBtn") as Button
	if pause_btn and _time_manager.has_method("is_paused"):
		pause_btn.text = "▶" if _time_manager.is_paused() else "⏸"


func _on_pause_pressed() -> void:
	if _time_manager and _time_manager.has_method("toggle_pause"):
		_time_manager.toggle_pause()


func _on_speed_down() -> void:
	if _time_manager and _time_manager.has_method("speed_down"):
		_time_manager.speed_down()


func _on_speed_up() -> void:
	if _time_manager and _time_manager.has_method("speed_up"):
		_time_manager.speed_up()


func _on_time_changed(_year: int, _day: int) -> void:
	_update_display()


func _on_speed_changed(_idx: int) -> void:
	_update_display()


func _on_pause_changed(_paused: bool) -> void:
	_update_display()
