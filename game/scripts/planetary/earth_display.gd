# earth_display.gd — Earth body with grid wireframe and territory tint.
# Creates the Earth sphere, generates grid mesh, loads territory data,
# and manages the visual layer stack.
# Phase 4b: Real country colors from palette, display mode switching.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # 100km for fast testing

var _earth_body: MeshInstance3D
var _grid_mesh: MeshInstance3D
var _tint_mesh: MeshInstance3D
var _coastline_overlay: Node
var _river_overlay: Node
var _border_overlay: Node
var _palette_manager: Node
var _territory_data: Node
var _lod_pyramid: Node
var _camera: Camera3D
var _band_structure: Dictionary = {}
var _tile_colors: Dictionary = {}  # tile_id → Color(palette_idx/255, 0, 0, 1)
var _game_state: Node
var _hovered_tile: String = ""
var _hovered_country: String = ""
var _click_start_pos: Vector2 = Vector2.ZERO
const CLICK_DRAG_THRESHOLD := 5.0  # pixels — beyond this it's a drag, not a click


func _ready() -> void:
	_setup_earth_body()
	_setup_palette_manager()
	_setup_territory_data()
	_setup_lod_pyramid()
	_assign_real_tile_colors()
	_create_grid()
	_create_tint()
	_create_lod_meshes()
	_create_coastlines()
	_create_rivers()
	_create_borders()
	_fast_forward_timeline()
	_connect_game_state()
	print("Earth display ready. Grid: %d bands, %d tiles" % [
		_band_structure.get("total_bands", 0),
		SphericalGridGenerator.count_tiles(_band_structure),
	])
	_print_lod_summary()


func _print_lod_summary() -> void:
	var lod_structures := SphericalGridGenerator.compute_all_lod_structures(
		EARTH_RADIUS_KM, BASE_CELL_KM
	)
	print("LOD Pyramid (base %.0f km):" % BASE_CELL_KM)
	for lod in range(lod_structures.size()):
		var count := SphericalGridGenerator.get_lod_tile_count(lod, lod_structures)
		var bs: Dictionary = SphericalGridGenerator.get_lod_structure(lod, lod_structures)
		print("  LOD %d: %s tiles (%d bands, %d equator segs)" % [
			lod, count, bs.get("total_bands", 0), bs.get("equator_segs", 0),
		])


func _setup_earth_body() -> void:
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = EARTH_RADIUS_KM
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 256
	sphere_mesh.rings = 128

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var tex_path := "res://assets/textures/planet/earth/earth_color_4k.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE
		mat.uv1_offset.x = 0.25
		print("Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)
		print("Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _setup_palette_manager() -> void:
	var pm_script := load("res://scripts/data/palette_manager.gd")
	_palette_manager = Node.new()
	_palette_manager.name = "PaletteManager"
	_palette_manager.set_script(pm_script)
	add_child(_palette_manager)


func _setup_territory_data() -> void:
	var td_script := load("res://scripts/data/territory_data.gd")
	_territory_data = Node.new()
	_territory_data.name = "TerritoryData"
	_territory_data.set_script(td_script)
	add_child(_territory_data)


func _setup_lod_pyramid() -> void:
	var lp_script := load("res://scripts/data/lod_pyramid.gd")
	_lod_pyramid = Node.new()
	_lod_pyramid.name = "LODPyramid"
	_lod_pyramid.set_script(lp_script)
	add_child(_lod_pyramid)


func _assign_real_tile_colors() -> void:
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, BASE_CELL_KM)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]

	# Load 100km tile mapping (aggregated from 10km data)
	var tile_mapping: Dictionary = _load_tile_mapping_100km()
	var mapped_count: int = 0
	var ocean_count: int = 0

	for b_idx in range(total_bands):
		var grid_segs: int = band_segs[b_idx]
		if grid_segs <= 0:
			continue

		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else grid_segs
		var sparser_segs: int = mini(grid_segs, next_segs)
		var ratio: int = maxi(grid_segs / sparser_segs, 1)

		for s in range(grid_segs):
			var sparser_s: int = s / ratio
			var tile_id: String = "B%d_%d" % [b_idx, sparser_s]

			if tile_mapping.has(tile_id):
				var palette_idx: int = tile_mapping[tile_id]
				_tile_colors[tile_id] = Color(palette_idx / 255.0, 0.0, 0.0, 1.0)
				mapped_count += 1
			else:
				# Ocean — index 0, transparent in shader
				_tile_colors[tile_id] = Color(0.0, 0.0, 0.0, 1.0)
				ocean_count += 1

	print("Tile colors: %d land (from mapping), %d ocean (total %d)" % [
		mapped_count, ocean_count, _tile_colors.size(),
	])


func _load_tile_mapping_100km() -> Dictionary:
	var path := "res://../data/countries/tile_mapping_100km.json"
	if not FileAccess.file_exists(path):
		path = "res://assets/data/countries/tile_mapping_100km.json"
	if not FileAccess.file_exists(path):
		push_warning("earth_display: tile_mapping_100km.json not found, using test stripes")
		return _fallback_stripe_mapping()

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("earth_display: failed to parse tile_mapping_100km.json")
		return {}

	return json.get_data()


func _fallback_stripe_mapping() -> Dictionary:
	# Longitude-based stripes with real palette indices as fallback
	var result := {}
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, BASE_CELL_KM)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var num_stripes := 6

	for b_idx in range(total_bands):
		var grid_segs: int = band_segs[b_idx]
		if grid_segs <= 0:
			continue
		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else grid_segs
		var sparser_segs: int = mini(grid_segs, next_segs)
		var ratio: int = maxi(grid_segs / sparser_segs, 1)

		for s in range(grid_segs):
			var sparser_s: int = s / ratio
			var tile_id: String = "B%d_%d" % [b_idx, sparser_s]
			var lon_frac: float = float(s) / float(grid_segs)
			var idx: int = int(lon_frac * num_stripes) % num_stripes + 1
			result[tile_id] = idx

	return result


func _create_grid() -> void:
	_grid_mesh = SphericalGridGenerator.generate(
		"Earth", EARTH_RADIUS_KM, Color.WHITE, BASE_CELL_KM,
	)
	if _grid_mesh:
		_grid_mesh.visible = true
		add_child(_grid_mesh)
		print("Grid wireframe created")


func _create_tint() -> void:
	var band_segs_dict: Dictionary = {}
	var band_segs: Array = _band_structure["band_segs"]
	for i in range(band_segs.size()):
		band_segs_dict[str(i)] = band_segs[i]

	_tint_mesh = SphericalGridGenerator.generate_tint(
		"Earth", EARTH_RADIUS_KM, BASE_CELL_KM,
		_tile_colors, band_segs_dict,
	)
	if _tint_mesh:
		var shader_mat := ShaderMaterial.new()
		var shader := load("res://shaders/solid_tint.gdshader")
		shader_mat.shader = shader
		_tint_mesh.material_override = shader_mat

		call_deferred("_register_tint_material")

		_tint_mesh.visible = true
		print("Tint mesh created with real country palette (solid_tint shader)")


func _register_tint_material() -> void:
	if _tint_mesh and _tint_mesh.material_override and _palette_manager:
		_palette_manager.register_material(_tint_mesh.material_override)


func focus_on_lat_lon(lat_deg: float, lon_deg: float) -> Dictionary:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg + 180.0)
	var point := Vector3(
		-EARTH_RADIUS_KM * cos(lat) * cos(lon),
		EARTH_RADIUS_KM * sin(lat),
		EARTH_RADIUS_KM * cos(lat) * sin(lon),
	)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	return SphericalGridGenerator.find_cell_at_point(
		point, EARTH_RADIUS_KM, total_bands, band_segs,
	)


func _create_coastlines() -> void:
	var coastline_script := load("res://scripts/planetary/coastline_overlay.gd")
	_coastline_overlay = Node.new()
	_coastline_overlay.name = "CoastlineOverlay"
	_coastline_overlay.set_script(coastline_script)
	add_child(_coastline_overlay)


func _create_rivers() -> void:
	var river_script := load("res://scripts/planetary/river_overlay.gd")
	_river_overlay = Node.new()
	_river_overlay.name = "RiverOverlay"
	_river_overlay.set_script(river_script)
	add_child(_river_overlay)
	call_deferred("_init_river_overlay")


func _create_borders() -> void:
	var border_script := load("res://scripts/planetary/border_overlay.gd")
	_border_overlay = Node.new()
	_border_overlay.name = "BorderOverlay"
	_border_overlay.set_script(border_script)
	add_child(_border_overlay)
	call_deferred("_init_border_overlay")


func _init_river_overlay() -> void:
	if _river_overlay and _river_overlay.has_method("initialize"):
		_river_overlay.initialize(_band_structure)


func _init_border_overlay() -> void:
	if _border_overlay and _border_overlay.has_method("initialize"):
		_border_overlay.initialize(_band_structure, _territory_data)


## Generate LOD 1-4 meshes from the LOD pyramid manager.
## LOD 0 is the existing tint mesh (already created by _create_tint).
func _create_lod_meshes() -> void:
	if not _lod_pyramid:
		return

	# Set LOD 0 = existing tint mesh
	if _lod_pyramid.has_method("_lod_meshes"):
		pass  # Deferred registration handled by generate_all_lod_meshes

	if _lod_pyramid.has_method("generate_all_lod_meshes"):
		_lod_pyramid.generate_all_lod_meshes(_territory_data, _palette_manager)

	# Register LOD 0 (existing tint mesh) with the pyramid
	if _tint_mesh and _lod_pyramid and _lod_pyramid.has_method("register_lod_zero"):
		_lod_pyramid.register_lod_zero(_tint_mesh)


func _process(_delta: float) -> void:
	_update_lod()
	_handle_timeline_input()
	_update_hover()


func _handle_timeline_input() -> void:
	# T = advance one year (test key)
	if Input.is_action_just_pressed("timeline_advance"):
		if _territory_data and _territory_data.has_method("advance_year"):
			_territory_data.advance_year()
			var yr: int = _territory_data.get_current_year()
			print("Timeline: advanced to year %d" % yr)
	# F = fast-forward to 1991 (USSR dissolves)
	if Input.is_action_just_pressed("timeline_ff_1991"):
		if _territory_data and _territory_data.has_method("fast_forward_to"):
			_territory_data.fast_forward_to(11991)
			print("Timeline: fast-forwarded to 1991")


func _fast_forward_timeline() -> void:
	if _territory_data and _territory_data.has_method("fast_forward_to"):
		_territory_data.fast_forward_to(11950)  # Default: 1950


## Handle mouse clicks on the Earth for country selection.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_click_start_pos = event.position
			else:
				# Released — check if it was a click (not a drag)
				var dist: float = (event.position - _click_start_pos).length()
				if dist < CLICK_DRAG_THRESHOLD:
					_try_select_at(event.position)


func _connect_game_state() -> void:
	var root := get_tree().root
	if root:
		for child in root.get_children():
			if child.name == "Main":
				for sub in child.get_children():
					if sub.name == "GameState":
						set_game_state(sub)
						return


## Raycast from mouse position to Earth sphere, find tile and country.
func _try_select_at(screen_pos: Vector2) -> void:
	if not _camera:
		_camera = get_viewport().get_camera_3d()
	if not _camera:
		return

	# Ray from camera through screen position
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)

	# Sphere intersection: Earth at origin, radius = EARTH_RADIUS_KM
	var hit_point := _ray_sphere_intersect(from, dir, Vector3.ZERO, EARTH_RADIUS_KM)
	if hit_point == Vector3.ZERO:
		return  # Missed the sphere

	# Convert hit point to tile ID
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var cell: Dictionary = SphericalGridGenerator.find_cell_at_point(
		hit_point, EARTH_RADIUS_KM, total_bands, band_segs,
	)
	if cell.is_empty():
		return

	var tile_id := "B%d_%d" % [cell["transition"], cell["sparser_seg"]]

	# Get the country
	if not _territory_data or not _territory_data.has_method("get_tile_owner_palette"):
		return

	var idx: int = _territory_data.get_tile_owner_palette(tile_id)
	if idx <= 0:
		# Clicked ocean — clear selection
		if _game_state and _game_state.has_method("clear_selection"):
			_game_state.clear_selection()
		if _palette_manager and _palette_manager.has_method("clear_highlight"):
			_palette_manager.clear_highlight()
		return

	var country_name: String = ""
	if _territory_data.has_method("get_country_name"):
		country_name = _territory_data.get_country_name(idx)
	if country_name == "":
		country_name = "Country #%d" % idx

	# Select the country
	if _game_state and _game_state.has_method("select_country"):
		_game_state.select_country(idx, country_name)

	# Highlight it
	if _palette_manager and _palette_manager.has_method("highlight_country"):
		_palette_manager.highlight_country(idx)

	print("Selected: %s [%d] (tile %s)" % [country_name, idx, tile_id])


## Update hover state — find country under mouse cursor.
func _update_hover() -> void:
	if not _camera:
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var from := _camera.project_ray_origin(mouse_pos)
	var dir := _camera.project_ray_normal(mouse_pos)
	var hit_point := _ray_sphere_intersect(from, dir, Vector3.ZERO, EARTH_RADIUS_KM)

	if hit_point == Vector3.ZERO:
		_hovered_tile = ""
		_hovered_country = ""
		return

	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var cell: Dictionary = SphericalGridGenerator.find_cell_at_point(
		hit_point, EARTH_RADIUS_KM, total_bands, band_segs,
	)
	if cell.is_empty():
		return

	_hovered_tile = "B%d_%d" % [cell["transition"], cell["sparser_seg"]]
	if _territory_data and _territory_data.has_method("get_tile_owner_palette"):
		var idx: int = _territory_data.get_tile_owner_palette(_hovered_tile)
		if idx > 0 and _territory_data.has_method("get_country_name"):
			_hovered_country = _territory_data.get_country_name(idx)
		else:
			_hovered_country = ""
	else:
		_hovered_country = ""


func get_hovered_country() -> String:
	return _hovered_country


## Ray-sphere intersection. Returns hit point or Vector3.ZERO if miss.
func _ray_sphere_intersect(ray_origin: Vector3, ray_dir: Vector3,
		sphere_center: Vector3, sphere_radius: float) -> Vector3:
	var oc := ray_origin - sphere_center
	var a := ray_dir.dot(ray_dir)
	var b := 2.0 * oc.dot(ray_dir)
	var c := oc.dot(oc) - sphere_radius * sphere_radius
	var discriminant := b * b - 4.0 * a * c

	if discriminant < 0.0:
		return Vector3.ZERO

	var t := (-b - sqrt(discriminant)) / (2.0 * a)
	if t < 0.0:
		t = (-b + sqrt(discriminant)) / (2.0 * a)
	if t < 0.0:
		return Vector3.ZERO

	return ray_origin + ray_dir * t


## Set game state reference (called after setup).
func set_game_state(gs: Node) -> void:
	_game_state = gs
	# Auto-set player country from territory data
	if _territory_data and gs and gs.has_method("set_player_country"):
		# Default: United States
		var us_idx := 4  # Palette index for USA
		if _territory_data.has_method("get_country_name"):
			var country_name: String = _territory_data.get_country_name(us_idx)
			if country_name != "":
				gs.set_player_country(us_idx, country_name)


## Select LOD based on camera distance and update visibility.
func _update_lod() -> void:
	if not _lod_pyramid:
		return

	# Find camera if not cached
	if not _camera:
		_camera = get_viewport().get_camera_3d()

	if not _camera:
		return

	var camera_distance := _camera.global_position.length()

	if _lod_pyramid.has_method("select_lod"):
		var active_lod: int = _lod_pyramid.select_lod(camera_distance)
		if _lod_pyramid.has_method("update_visibility"):
			_lod_pyramid.update_visibility(active_lod)
