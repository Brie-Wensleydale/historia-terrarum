# game_state.gd — Central game state tracking.
# Tracks the player's country, selected entity, and game time.
# Used by UI panels, interaction system, and game mechanics.
extends Node

# Player's country (palette index)
var player_country_idx: int = 0
var player_country_name: String = ""

# Selected entity (country, tile, province, unit — future)
enum SelectionType { NONE, COUNTRY, TILE, PROVINCE, UNIT }
var selection_type: int = SelectionType.NONE
var selected_country_idx: int = 0
var selected_country_name: String = ""
var selected_tile_id: String = ""

# Game time
var current_year: int = 11950  # 1950 AD

# Signals
signal player_country_changed(idx: int, name: String)
signal selection_changed(type: int)


func _ready() -> void:
	# Default player: United States (palette index from country registry)
	# Will be set by _setup_player_country after territory data loads
	pass


func set_player_country(idx: int, name: String) -> void:
	player_country_idx = idx
	player_country_name = name
	player_country_changed.emit(idx, name)
	print("GameState: player country = %s [%d]" % [name, idx])


func select_country(idx: int, name: String) -> void:
	selection_type = SelectionType.COUNTRY
	selected_country_idx = idx
	selected_country_name = name
	selection_changed.emit(SelectionType.COUNTRY)


func select_tile(tile_id: String) -> void:
	selection_type = SelectionType.TILE
	selected_tile_id = tile_id
	selection_changed.emit(SelectionType.TILE)


func clear_selection() -> void:
	selection_type = SelectionType.NONE
	selected_country_idx = 0
	selected_country_name = ""
	selected_tile_id = ""
	selection_changed.emit(SelectionType.NONE)


func get_selection_display() -> String:
	match selection_type:
		SelectionType.COUNTRY:
			return selected_country_name
		SelectionType.TILE:
			return "Tile %s" % selected_tile_id
		_:
			return "Nothing selected"
