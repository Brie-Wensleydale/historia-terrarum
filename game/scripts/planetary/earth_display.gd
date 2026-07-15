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
var _palette_manager: Node
var _territory_data: Node
var _lod_pyramid: Node
var _band_structure: Dictionary = {}
var _tile_colors: Dictionary = {}  # tile_id → Color(palette_idx/255, 0, 0, 1)


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
	sphere_mesh.is_double_sided = false

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


func _init_river_overlay() -> void:
	if _river_overlay and _river_overlay.has_method("initialize"):
		_river_overlay.initialize(_band_structure)


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
