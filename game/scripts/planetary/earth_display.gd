# earth_display.gd — HT2: single-level land mesh with viewport culling
# Creates the Earth sphere, loads land mask, and renders visible land cells
# based on the camera's sub-point on the sphere.
# TIER 1c: Mesh pool — two pre-allocated MeshInstance3D nodes, swapped on rebuild.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const CELL_KM := 10.0
const VISIBLE_RADIUS_KM := 500.0   # render cells within this radius of camera sub-point
const REBUILD_FRAME_INTERVAL := 3   # throttle mesh rebuild
const LAND_COLOR := Color(0.2, 0.7, 0.3, 1.0)   # green land
const OCEAN_COLOR := Color(0.1, 0.3, 0.6, 1.0)  # blue ocean
const MESH_NAME := "CellMesh"
const POOL_SIZE := 2

var _earth_body: MeshInstance3D
var _camera: Camera3D
var _band_structure: Dictionary = {}
var _land_loader: RefCounted = null  # LandMaskLoader instance
var _frame_counter: int = 0
var _last_sub_point: Vector3 = Vector3.ZERO
var _mesh_dirty: bool = true

# Mesh pool — avoids queue_free() + MeshInstance3D.new() per rebuild
var _mesh_pool: Array = []
var _active_pool_idx: int = 0
var _mat: StandardMaterial3D  # shared material, created once


func _ready() -> void:
	print("HT2 EarthDisplay: starting setup...")

	# 1. Create the textured Earth sphere (visual reference)
	_setup_earth_body()
	print("  Earth body done")

	# 2. Load band structure
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, CELL_KM)
	var merge_set: Array = []
	for segs in _band_structure["band_segs"]:
		if not segs in merge_set:
			merge_set.append(segs)
	merge_set.sort()
	print("  Band structure: %d bands, %d equator segs, merge chain: %s" % [
		_band_structure["total_bands"],
		_band_structure["equator_segs"],
		merge_set,
	])

	# 3. Load land mask
	var ll_script: Script = load("res://scripts/data/land_mask_loader.gd")
	_land_loader = ll_script.new()
	if not _land_loader.load():
		push_error("HT2: failed to load land mask — check data/output/grid_10km_ht2/")
		return
	print("  Land mask: %d land / %d total (%.1f%%)" % [
		_land_loader.land_count(), _land_loader.total_tiles(),
		float(_land_loader.land_count()) / float(_land_loader.total_tiles()) * 100.0,
	])

	# 4. Find camera (sibling node)
	_camera = _find_camera()
	if not _camera:
		push_error("HT2: no Camera3D found in scene!")
		return
	print("  Camera found: %s" % _camera.name)

	# 5. Pre-create shared material + mesh pool
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.flags_unshaded = true
	_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)

	_mesh_pool.resize(POOL_SIZE)
	for i in range(POOL_SIZE):
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "CellMesh_%d" % i
		mi.material_override = _mat
		mi.visible = false
		add_child(mi)
		_mesh_pool[i] = mi

	print("HT2 EarthDisplay ready.")


func _process(_delta: float) -> void:
	if not _land_loader or not _camera:
		return

	_frame_counter += 1
	if _frame_counter % REBUILD_FRAME_INTERVAL != 0:
		return

	# Compute camera sub-point on Earth surface
	var sub_point: Vector3 = _camera_to_sub_point()
	if sub_point.length() < 0.001:
		return

	# Skip rebuild if camera hasn't moved significantly
	if not _mesh_dirty and sub_point.distance_squared_to(_last_sub_point) < 100.0 * 100.0:
		return

	_last_sub_point = sub_point
	_mesh_dirty = false
	_rebuild_visible_land_mesh(sub_point)


func _setup_earth_body() -> void:
	var sphere_mesh: SphereMesh = SphereMesh.new()
	sphere_mesh.radius = EARTH_RADIUS_KM
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 256
	sphere_mesh.rings = 128

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var tex_path: String = "res://assets/textures/planet/earth/earth_color_4k.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE
		mat.uv1_scale.x = -1.0  # mirror texture horizontally (east/west flip)
		mat.uv1_offset.x = 0.0  # no offset; scale handles the flip
		print("  Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)
		print("  Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _find_camera() -> Camera3D:
	# Search siblings for a Camera3D (earth_camera.gd is attached to it)
	var parent_node: Node = get_parent()
	if parent_node:
		for child in parent_node.get_children():
			if child is Camera3D:
				return child
	return null


## Compute the point on the Earth's surface directly beneath the camera.
## Uses ray-sphere intersection from camera position toward Earth center.
func _camera_to_sub_point() -> Vector3:
	var cam_pos: Vector3 = _camera.global_position
	var earth_center: Vector3 = Vector3.ZERO
	var dir: Vector3 = (earth_center - cam_pos).normalized()

	# Ray-sphere intersection: |cam_pos + t*dir| = EARTH_RADIUS_KM
	# In display units (km), Earth is at 1:1 scale
	var a: float = dir.dot(dir)  # = 1
	var b: float = 2.0 * cam_pos.dot(dir)
	var c: float = cam_pos.dot(cam_pos) - EARTH_RADIUS_KM * EARTH_RADIUS_KM
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return Vector3.ZERO

	var t: float = (-b - sqrt(disc)) / (2.0 * a)
	if t < 0.0:
		t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 0.0:
		return Vector3.ZERO

	return cam_pos + dir * t


## Rebuild the land mesh for cells within VISIBLE_RADIUS_KM of sub_point.
## TIER 1c: swaps between pool nodes — no queue_free() / MeshInstance3D.new() per rebuild.
func _rebuild_visible_land_mesh(sub_point: Vector3) -> void:
	# Convert sub_point to lat/lon
	var lat: float = asin(clampf(sub_point.y / EARTH_RADIUS_KM, -1.0, 1.0))
	var lon: float = atan2(sub_point.z, sub_point.x)
	if lon < 0.0:
		lon += TAU
	var lat_deg: float = rad_to_deg(lat)
	var lon_deg: float = rad_to_deg(lon) - 180.0  # to -180..180

	# Convert visible radius to angular spread (degrees)
	var angular_radius_deg: float = rad_to_deg(VISIBLE_RADIUS_KM / EARTH_RADIUS_KM)

	# Compute band range
	var total_bands: int = _band_structure["total_bands"]
	var band_segs: Array = _band_structure["band_segs"]
	var bands_per_deg: float = float(total_bands) / 180.0

	var center_band: int = clampi(int((lat + PI * 0.5) / PI * float(total_bands)), 0, total_bands - 1)
	var band_range: int = maxi(int(angular_radius_deg * bands_per_deg) + 1, 1)
	var band_start: int = maxi(center_band - band_range, 0)
	var band_end: int = mini(center_band + band_range, total_bands - 1)

	# Build tile_colors dict for visible cells (land + ocean)
	var tile_colors: Dictionary = {}
	var visible_land: int = 0
	var visible_ocean: int = 0

	for b_idx in range(band_start, band_end + 1):
		var segs_bot: int = band_segs[b_idx]
		var segs_top: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs_bot
		var cell_segs: int = maxi(segs_bot, segs_top)
		if cell_segs <= 0:
			continue

		var center_seg: int = int((lon_deg + 180.0) / 360.0 * float(cell_segs)) % cell_segs
		var seg_range: int = maxi(int(angular_radius_deg / 360.0 * float(cell_segs)) + 1, 1)
		var cos_lat: float = cos(lat)
		if cos_lat > 0.01:
			seg_range = maxi(int(seg_range / cos_lat), 1)

		for s in range(center_seg - seg_range, center_seg + seg_range + 1):
			var wrapped_seg: int = ((s % cell_segs) + cell_segs) % cell_segs
			var tile_id: String = "B%d_%d" % [b_idx, wrapped_seg]
			if _land_loader.is_land(b_idx, wrapped_seg):
				tile_colors[tile_id] = LAND_COLOR
				visible_land += 1
			else:
				tile_colors[tile_id] = OCEAN_COLOR
				visible_ocean += 1

	# Build new mesh via generate_tint
	if tile_colors.is_empty():
		return

	var new_mi: MeshInstance3D = SphericalGridGenerator.generate_tint(
		EARTH_RADIUS_KM,
		_band_structure,
		tile_colors,
		band_start,
		band_end + 1,  # band_end is inclusive, generate_tint uses exclusive
	)
	if not new_mi or not new_mi.mesh:
		return

	# Swap pool: hide active, show inactive with new mesh
	var old_idx: int = _active_pool_idx
	var new_idx: int = (old_idx + 1) % POOL_SIZE
	_mesh_pool[old_idx].visible = false
	_mesh_pool[new_idx].mesh = new_mi.mesh
	_mesh_pool[new_idx].visible = true
	_active_pool_idx = new_idx
	print_verbose("  Visible land mesh: %d cells in bands %d-%d" % [visible_land, band_start, band_end])


## Force mesh rebuild on next process frame.
func mark_dirty() -> void:
	_mesh_dirty = true
