# earth_display.gd — Earth body with grid wireframe and territory tint.
# Creates the Earth sphere, generates grid mesh, loads territory data,
# and manages the visual layer stack.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # Start with 100km for testing (7.6K tiles, fast)

var _earth_body: MeshInstance3D
var _grid_mesh: MeshInstance3D
var _tint_mesh: MeshInstance3D
var _coastline_overlay: Node
var _river_overlay: Node
var _palette_manager: Node
var _band_structure: Dictionary = {}
# Encoded tile colors: palette index packed in vertex color R channel.
# Color(idx/255.0, 0, 0, 1.0) — the shader decodes this to look up display color.
var _tile_colors: Dictionary = {}


func _ready() -> void:
	_setup_earth_body()
	_setup_palette_manager()
	_assign_test_indices()
	_create_grid()
	_create_tint()
	_create_coastlines()
	_create_rivers()
	print("Earth display ready. Grid: %d bands, %d tiles" % [
		_band_structure.get("total_bands", 0),
		SphericalGridGenerator.count_tiles(_band_structure),
	])


func _setup_earth_body() -> void:
	# Create Earth sphere
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = EARTH_RADIUS_KM
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 256
	sphere_mesh.rings = 128
	sphere_mesh.is_double_sided = false

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	# Load real Earth texture from assets
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var tex_path := "res://assets/textures/planet/earth/earth_color_4k.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE
		# UV offset: align texture prime meridian with model 0° (matches Stella Nostra)
		mat.uv1_offset.x = 0.25
		print("Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)  # Blue fallback
		print("Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _setup_palette_manager() -> void:
	var pm_script := load("res://scripts/data/palette_manager.gd")
	_palette_manager = Node.new()
	_palette_manager.name = "PaletteManager"
	_palette_manager.set_script(pm_script)
	add_child(_palette_manager)


func _assign_test_indices() -> void:
	# Assign palette indices to tiles, encoded in vertex color R channel.
	# Index 0 = ocean (transparent), indices 1-6 = test "countries".
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, BASE_CELL_KM)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]

	var num_countries := 6  # palette indices 1-6

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

			# Assign color based on longitude: each 60° band gets a palette index
			var lon_frac: float = float(s) / float(grid_segs)
			var idx: int = int(lon_frac * num_countries) % num_countries + 1
			# Encode palette index as Color R channel — shader decodes it
			_tile_colors[tile_id] = Color(idx / 255.0, 0.0, 0.0, 1.0)

	print("Assigned %d test tile indices (6 vertical stripes via palette R-channel)" % _tile_colors.size())


func _create_grid() -> void:
	# Generate wireframe grid mesh
	_grid_mesh = SphericalGridGenerator.generate(
		"Earth",
		EARTH_RADIUS_KM,
		Color.WHITE,
		BASE_CELL_KM,
	)
	if _grid_mesh:
		_grid_mesh.visible = true
		add_child(_grid_mesh)
		print("Grid wireframe created")


func _create_tint() -> void:
	# Convert band_segs Array to Dictionary for generate_tint
	var band_segs_dict: Dictionary = {}
	var band_segs: Array = _band_structure["band_segs"]
	for i in range(band_segs.size()):
		band_segs_dict[str(i)] = band_segs[i]

	_tint_mesh = SphericalGridGenerator.generate_tint(
		"Earth",
		EARTH_RADIUS_KM,
		BASE_CELL_KM,
		_tile_colors,  # Now encoded as palette indices in R channel
		band_segs_dict,
	)
	if _tint_mesh:
		# Apply solid_tint shader material (palette-index lookup from vertex color)
		var shader_mat := ShaderMaterial.new()
		var shader := load("res://shaders/solid_tint.gdshader")
		shader_mat.shader = shader
		_tint_mesh.material_override = shader_mat

		# Register with palette manager (deferred — PM needs to be in tree)
		call_deferred("_register_tint_material")

		_tint_mesh.visible = true
		print("Tint mesh created with solid_tint shader (palette-index)")


func _register_tint_material() -> void:
	if _tint_mesh and _tint_mesh.material_override and _palette_manager:
		_palette_manager.register_material(_tint_mesh.material_override)


## Focus camera on a lat/lon position
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
	var cell: Dictionary = SphericalGridGenerator.find_cell_at_point(
		point, EARTH_RADIUS_KM, total_bands, band_segs,
	)
	return cell


## Toggle display mode (hooked up to UI or debug keys later)
func set_display_mode(mode: String) -> void:
	if _palette_manager and _palette_manager.has_method("set_display_mode"):
		_palette_manager.set_display_mode(mode)


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
	# Initialize with band structure after a frame (needs _ready to fire first)
	call_deferred("_init_river_overlay")


func _init_river_overlay() -> void:
	if _river_overlay and _river_overlay.has_method("initialize"):
		_river_overlay.initialize(_band_structure)
