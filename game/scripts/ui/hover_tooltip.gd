# hover_tooltip.gd — Floating tooltip showing country name on mouse hover.
extends Label


func _ready() -> void:
	add_theme_font_size_override("font_size", 12)
	add_theme_color_override("font_color", Color.WHITE)
	visible = false
	# Semi-transparent background
	var bg := ColorRect.new()
	bg.name = "TooltipBg"
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.size = Vector2(200, 22)
	add_child(bg)
	move_child(bg, 0)


func _process(_delta: float) -> void:
	var earth := _find_earth_display()
	if not earth:
		visible = false
		return

	var country: String = ""
	if earth.has_method("get_hovered_country"):
		country = earth.get_hovered_country()

	if country == "":
		visible = false
		return

	text = country
	visible = true

	# Position near cursor
	var mouse_pos := get_viewport().get_mouse_position()
	var bg := get_node_or_null("TooltipBg") as ColorRect

	# Measure text width
	var text_width := country.length() * 8 + 20
	size = Vector2(text_width, 22)
	if bg:
		bg.size = size

	# Offset from cursor
	position = Vector2(mouse_pos.x + 16, mouse_pos.y - 28)

	# Clamp to viewport
	var vp_size := get_viewport().get_visible_rect().size
	if position.x + size.x > vp_size.x:
		position.x = mouse_pos.x - size.x - 8
	if position.y < 0:
		position.y = mouse_pos.y + 16


func _find_earth_display() -> Node:
	var root := get_tree().root
	if root:
		for child in root.get_children():
			if child.name == "Main":
				for sub in child.get_children():
					if sub.name == "EarthDisplay":
						return sub
	return null
