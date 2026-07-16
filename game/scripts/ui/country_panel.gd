# country_panel.gd — Left panel showing player's country info.
# Stella Nostra-style: top-left, ~300px wide, tabs at top.
extends Control

var _game_state: Node
var _player_idx: int = 0
var _player_name: String = ""
var _flag_rect: TextureRect


func _ready() -> void:
	_setup_ui()
	# Find GameState
	var root := get_tree().root
	if root:
		for child in root.get_children():
			if child.name == "Main":
				for sub in child.get_children():
					if sub.name == "GameState":
						_game_state = sub
						if _game_state.has_signal("player_country_changed"):
							_game_state.player_country_changed.connect(_on_player_changed)
						_update_display()


func _setup_ui() -> void:
	# Panel background
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.85)
	bg.size = Vector2(300, 320)
	bg.position = Vector2(10, 10)
	add_child(bg)

	# Country name + flag placeholder
	var title: Label = Label.new()
	title.name = "CountryTitle"
	title.text = "United States of America"
	title.position = Vector2(16, 12)
	title.size = Vector2(268, 28)
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color.WHITE)
	add_child(title)

	# Flag image
	_flag_rect = TextureRect.new()
	_flag_rect.name = "FlagImage"
	_flag_rect.size = Vector2(60, 36)
	_flag_rect.position = Vector2(16, 46)
	_flag_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_flag_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_flag_rect)

	# Tabs
	var tabs_y: float = 92.0
	var tab_names: Array = ["Stats", "Diplomacy", "Military", "Tech"]
	var tab_width: float = 67.0
	for i in range(tab_names.size()):
		var tab: Button = Button.new()
		tab.text = tab_names[i]
		tab.position = Vector2(16 + i * (tab_width + 4), tabs_y)
		tab.size = Vector2(tab_width, 26)
		tab.flat = true
		add_child(tab)

	# Stats content
	var stats_y := tabs_y + 34
	var stats := [
		"Population: —",
		"GDP: —",
		"Territory: — tiles",
		"Regions: —",
		"Year: 1950",
		"Government: —",
	]
	for i in range(stats.size()):
		var lbl: Label = Label.new()
		lbl.text = stats[i]
		lbl.position = Vector2(20, stats_y + i * 22)
		lbl.size = Vector2(260, 20)
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
		lbl.name = "Stat_%d" % i
		add_child(lbl)

	# Divider
	var divider: ColorRect = ColorRect.new()
	divider.color = Color(0.2, 0.2, 0.25)
	divider.size = Vector2(268, 1)
	divider.position = Vector2(16, 90)
	add_child(divider)


func _on_player_changed(idx: int, name: String) -> void:
	_player_idx = idx
	_player_name = name
	_update_display()
	_load_flag(idx, name)


func _load_flag(palette_idx: int, country_name: String) -> void:
	if not _flag_rect:
		return

	# Try to load flag from country name
	# Flag files are named by country ID from registry (e.g., "United_States.png")
	var flag_path: String = "res://assets/flags/%s.png" % country_name
	if ResourceLoader.exists(flag_path):
		var tex: Texture2D = load(flag_path)
		_flag_rect.texture = tex
		return

	# Try common alternatives
	var alt_paths := [
		"res://assets/flags/%s.png" % country_name.replace(" ", "_"),
		"res://assets/flags/%s.png" % country_name.to_lower(),
	]
	for p in alt_paths:
		if ResourceLoader.exists(p):
			_flag_rect.texture = load(p)
			return

	# No flag found — clear to show grey background
	_flag_rect.texture = null


func _update_display() -> void:
	var title := get_node_or_null("CountryTitle") as Label
	if title:
		if _player_name != "":
			title.text = _player_name
		elif _game_state and _game_state.has_method("get"):
			title.text = _game_state.get("player_country_name")


func _process(_delta: float) -> void:
	# Update stats periodically
	pass
