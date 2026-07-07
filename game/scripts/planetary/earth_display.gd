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
var _band_structure: Dictionary = {}
var _tile_colors: Dictionary = {}


func _ready() -> void:
	_setup_earth_body()
	_generate_test_tile_colors()
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


func _generate_test_tile_colors() -> void:
	# Generate a simple test pattern: vertical stripes every 30°
	# This lets us verify the grid aligns with geometry
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, BASE_CELL_KM)
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]

	# Define a few test "countries" as longitude bands
	var test_colors := [
		Color(0.8, 0.2, 0.2),  # Red
		Color(0.2, 0.6, 0.2),  # Green
		Color(0.2, 0.2, 0.8),  # Blue
		Color(0.8, 0.7, 0.1),  # Gold
		Color(0.6, 0.2, 0.6),  # Purple
		Color(0.2, 0.6, 0.6),  # Teal
	]
	var num_colors: int = test_colors.size()

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

			# Assign color based on longitude: each 60° band gets a color
			var lon_frac: float = float(s) / float(grid_segs)
			var color_idx: int = int(lon_frac * num_colors) % num_colors
			_tile_colors[tile_id] = test_colors[color_idx]

	print("Generated %d test tile colors (vertical stripes)" % _tile_colors.size())


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
		_tile_colors,
		band_segs_dict,
	)
	if _tint_mesh:
		_tint_mesh.visible = true
		add_child(_tint_mesh)
		print("Tint mesh created")


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
