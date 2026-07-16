# selection_panel.gd — Right panel showing selected object info.
# Stella Nostra-style: top-right, ~280px wide.
extends Control

var _game_state: Node


func _ready() -> void:
	_setup_ui()
	var root := get_tree().root
	if root:
		for child in root.get_children():
			if child.name == "Main":
				for sub in child.get_children():
					if sub.name == "GameState":
						_game_state = sub
						if _game_state.has_signal("selection_changed"):
							_game_state.selection_changed.connect(_on_selection_changed)
						_update_display()


func _setup_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.85)
	bg.size = Vector2(280, 200)
	bg.position = Vector2(10, 10)
	add_child(bg)

	# Title
	var title := Label.new()
	title.name = "SelTitle"
	title.text = "Nothing selected"
	title.position = Vector2(16, 12)
	title.size = Vector2(248, 24)
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)

	# Type label
	var type_lbl := Label.new()
	type_lbl.name = "SelType"
	type_lbl.text = ""
	type_lbl.position = Vector2(16, 40)
	type_lbl.size = Vector2(248, 18)
	type_lbl.add_theme_font_size_override("font_size", 12)
	type_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	add_child(type_lbl)

	# Divider
	var divider := ColorRect.new()
	divider.color = Color(0.2, 0.2, 0.25)
	divider.size = Vector2(248, 1)
	divider.position = Vector2(16, 64)
	add_child(divider)

	# Info lines
	var info_labels := [
		"Relations: —", "Trade: —", "Alliance: —",
		"Military power: —", "Diplomatic status: Neutral",
	]
	for i in range(info_labels.size()):
		var lbl := Label.new()
		lbl.text = info_labels[i]
		lbl.position = Vector2(16, 74 + i * 22)
		lbl.size = Vector2(248, 20)
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		lbl.name = "Info_%d" % i
		add_child(lbl)


func _on_selection_changed(_type: int) -> void:
	_update_display()


func _update_display() -> void:
	if not _game_state:
		return

	var title := get_node_or_null("SelTitle") as Label
	var type_lbl := get_node_or_null("SelType") as Label
	if not title or not type_lbl:
		return

	var sel_type: int = _game_state.get("selection_type")
	var sel_name: String = ""
	var type_text: String = ""

	match sel_type:
		1:  # COUNTRY
			sel_name = _game_state.get("selected_country_name")
			type_text = "Country"
		2:  # TILE
			sel_name = "Tile " + _game_state.get("selected_tile_id")
			type_text = "Tile"
		_:
			sel_name = "Nothing selected"
			type_text = ""

	title.text = sel_name
	type_lbl.text = type_text
