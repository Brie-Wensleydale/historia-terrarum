# earth_display.gd — HT2: chunk-based cell mesh with viewport culling
# Creates the Earth sphere, loads land mask, and renders visible cells
# based on the camera's sub-point on the sphere.
# TIER 2: Discrete chunk cache (64×256 base cells per chunk) — same grid as LOD.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const CELL_KM := 10.0
const REBUILD_FRAME_INTERVAL := 3
const LAND_COLOR := Color(0.2, 0.7, 0.3, 1.0)
const OCEAN_COLOR := Color(0.1, 0.3, 0.6, 1.0)
const POOL_SIZE := 2
const MAX_CACHED_CHUNKS := 128

# Chunk grid dimensions in base cells (same as LOD system)
const CHUNK_BANDS_0 := 64
const CHUNK_SEGS_0 := 256

var _earth_body: MeshInstance3D
var _camera: Camera3D
var _band_structure: Dictionary = {}
var _land_loader: RefCounted = null
var _frame_counter: int = 0

# Mesh pool — avoids queue_free() + MeshInstance3D.new() per rebuild
var _mesh_pool: Array = []
var _active_pool_idx: int = 0
var _mat: StandardMaterial3D

# Chunk cache: key = "R{row}_C{col}" → ArrayMesh
var _chunk_cache: Dictionary = {}
var _chunk_cache_order: Array = []  # LRU access order (String keys)

# Currently visible chunk nodes: key → MeshInstance3D
var _visible_chunks: Dictionary = {}

# Preload state: when camera is idle, build neighboring chunks
var _last_cam_pos: Vector3 = Vector3.ZERO
var _idle_timer: float = 0.0
const IDLE_PRELOAD_SEC := 1.0
var _preload_queue: Array = []  # pending chunk keys to build


func _ready() -> void:
	print("HT2 EarthDisplay: starting setup...")
	_setup_earth_body()
	print("  Earth body done")

	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, CELL_KM)
	print("  Band structure: %d bands, %d equator segs" % [
		_band_structure["total_bands"], _band_structure["equator_segs"],
	])

	var ll_script: Script = load("res://scripts/data/land_mask_loader.gd")
	_land_loader = ll_script.new()
	if not _land_loader.load():
		push_error("HT2: failed to load land mask")
		return
	print("  Land mask: %d land / %d total (%.1f%%)" % [
		_land_loader.land_count(), _land_loader.total_tiles(),
		float(_land_loader.land_count()) / float(_land_loader.total_tiles()) * 100.0,
	])

	_camera = _find_camera()
	if not _camera:
		push_error("HT2: no Camera3D found!")
		return
	print("  Camera found: %s" % _camera.name)

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


func _process(delta: float) -> void:
	if not _land_loader or not _camera:
		return

	_frame_counter += 1
	if _frame_counter % REBUILD_FRAME_INTERVAL != 0:
		return

	var sub_point: Vector3 = _camera_to_sub_point()
	if sub_point.length() < 0.001:
		return

	# Track camera movement for idle preload
	var cam_pos: Vector3 = _camera.global_position
	var cam_moved: float = cam_pos.distance_to(_last_cam_pos)
	_last_cam_pos = cam_pos
	if cam_moved > 10.0:
		_idle_timer = 0.0
	else:
		_idle_timer += delta

	# Visible radius from camera height
	var cam_height_km: float = maxf(cam_pos.length() - EARTH_RADIUS_KM, 10.0)
	var horizon_km: float = EARTH_RADIUS_KM * acos(EARTH_RADIUS_KM / (EARTH_RADIUS_KM + cam_height_km))
	var visible_radius: float = minf(horizon_km, 1000.0)

	# Determine visible chunks
	var lat: float = asin(clampf(sub_point.y / EARTH_RADIUS_KM, -1.0, 1.0))
	var lon: float = atan2(-sub_point.z, sub_point.x)
	if lon < 0.0: lon += TAU
	var lat_deg: float = rad_to_deg(lat)
	var lon_deg: float = rad_to_deg(lon) - 180.0

	var angular_radius_deg: float = rad_to_deg(visible_radius / EARTH_RADIUS_KM)
	var total_bands: int = _band_structure["total_bands"]
	var band_segs: Array = _band_structure["band_segs"]
	var bands_per_deg: float = float(total_bands) / 180.0

	var center_band: int = clampi(int((lat + PI * 0.5) / PI * float(total_bands)), 0, total_bands - 1)
	var band_range: int = maxi(int(angular_radius_deg * bands_per_deg) + 1, 1)
	var band_lo: int = maxi(center_band - band_range, 0)
	var band_hi: int = mini(center_band + band_range, total_bands - 1)

	# Find all chunks overlapping the visible band range
	var needed: Dictionary = {}
	var chunk_row_lo: int = band_lo / CHUNK_BANDS_0
	var chunk_row_hi: int = band_hi / CHUNK_BANDS_0

	for cr in range(chunk_row_lo, chunk_row_hi + 1):
		var cb0: int = cr * CHUNK_BANDS_0
		var cb1: int = mini(cb0 + CHUNK_BANDS_0, total_bands)
		if cb1 <= cb0:
			continue

		# Determine seg columns for this row (varies by latitude)
		var max_segs: int = 0
		for b in range(cb0, cb1):
			var sb: int = band_segs[b] if b < band_segs.size() else 0
			var st: int = band_segs[b + 1] if b + 1 < band_segs.size() else sb
			var cs: int = maxi(sb, st)
			if cs > max_segs: max_segs = cs
		var ncols: int = maxi(1, (max_segs + CHUNK_SEGS_0 - 1) / CHUNK_SEGS_0)

		# Determine which columns are needed
		var segs_at_row: int = max_segs
		var center_seg: int = int(((lon_deg + 180.0) / 360.0) * float(segs_at_row)) % maxi(segs_at_row, 1)
		var seg_range: int = maxi(int(angular_radius_deg / 360.0 * float(segs_at_row)) + 1, 1)
		var cos_lat2: float = cos(lat)
		if cos_lat2 > 0.01:
			seg_range = maxi(int(seg_range / cos_lat2), 1)

		var seg_lo: int = center_seg - seg_range
		var seg_hi: int = center_seg + seg_range
		var col_lo: int = seg_lo / CHUNK_SEGS_0
		var col_hi: int = seg_hi / CHUNK_SEGS_0

		# Handle wrap-around
		for cc in range(col_lo, col_hi + 1):
			var wc: int = ((cc % ncols) + ncols) % ncols
			var key: String = "R%d_C%d" % [cr, wc]
			if not needed.has(key):
				needed[key] = {"row": cr, "col": wc}

	# Show needed chunks, hide others
	_show_chunks(needed)

	# Idle preload: build neighboring chunks when camera is still
	if _idle_timer > IDLE_PRELOAD_SEC:
		_idle_timer = 0.0
		_build_preload_queue(needed)
	elif not _preload_queue.is_empty():
		_preload_one_chunk()


# ── Chunk management ──

func _show_chunks(needed: Dictionary) -> void:
	# Hide chunks no longer needed
	var to_hide: Array = []
	for key in _visible_chunks:
		if not needed.has(key):
			to_hide.append(key)
	for key in to_hide:
		var node: MeshInstance3D = _visible_chunks[key]
		if is_instance_valid(node):
			node.visible = false
		_visible_chunks.erase(key)

	# Show/generate needed chunks
	for key in needed:
		if _visible_chunks.has(key):
			var node: MeshInstance3D = _visible_chunks[key]
			if is_instance_valid(node) and not node.visible:
				node.visible = true
			continue

		var info: Dictionary = needed[key]
		var mesh: ArrayMesh = _get_or_build_chunk(info["row"], info["col"])
		if not mesh:
			continue

		# Use a pool slot
		var old_idx: int = _active_pool_idx
		var new_idx: int = (old_idx + 1) % POOL_SIZE
		_mesh_pool[old_idx].visible = false
		_mesh_pool[new_idx].mesh = mesh
		_mesh_pool[new_idx].visible = true
		_active_pool_idx = new_idx
		_visible_chunks[key] = _mesh_pool[new_idx]


func _get_or_build_chunk(row: int, col: int) -> ArrayMesh:
	var key: String = "R%d_C%d" % [row, col]

	# Check cache
	if _chunk_cache.has(key):
		_touch_chunk(key)
		return _chunk_cache[key]

	# Build chunk mesh
	var mesh: ArrayMesh = _build_chunk_mesh(row, col)
	if mesh:
		_chunk_cache[key] = mesh
		_touch_chunk(key)
		# Evict oldest if over limit
		while _chunk_cache_order.size() > MAX_CACHED_CHUNKS:
			var old_key: String = _chunk_cache_order[0]
			_chunk_cache_order.remove_at(0)
			_chunk_cache.erase(old_key)

	return mesh


func _touch_chunk(key: String) -> void:
	var idx: int = _chunk_cache_order.find(key)
	if idx >= 0:
		_chunk_cache_order.remove_at(idx)
	_chunk_cache_order.append(key)


func _build_chunk_mesh(row: int, col: int) -> ArrayMesh:
	var total_bands: int = _band_structure["total_bands"]
	var band_segs: Array = _band_structure["band_segs"]

	var b0: int = row * CHUNK_BANDS_0
	var b1: int = mini(b0 + CHUNK_BANDS_0, total_bands)
	if b1 <= b0:
		return null

	# Determine seg range for this chunk row
	var max_segs: int = 0
	for b in range(b0, b1):
		var sb: int = band_segs[b] if b < band_segs.size() else 0
		var st: int = band_segs[b + 1] if b + 1 < band_segs.size() else sb
		var cs: int = maxi(sb, st)
		if cs > max_segs: max_segs = cs

	var ncols: int = maxi(1, (max_segs + CHUNK_SEGS_0 - 1) / CHUNK_SEGS_0)
	var s0: int = col * CHUNK_SEGS_0
	var s1: int = mini(s0 + CHUNK_SEGS_0, max_segs)
	if s1 <= s0:
		return null

	# Build tile_colors for all cells in this chunk
	var tile_colors: Dictionary = {}
	for b_idx in range(b0, b1):
		var segs_bot_i: int = band_segs[b_idx] if b_idx < band_segs.size() else 0
		var segs_top_i: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs_bot_i
		var cell_segs: int = mini(segs_bot_i, segs_top_i)
		var denser_segs: int = maxi(segs_bot_i, segs_top_i)
		if cell_segs <= 0:
			continue

		var scale_factor: int = maxi(1, denser_segs / maxi(cell_segs, 1))

		for s in range(s0, s1):
			var ws: int = ((s % cell_segs) + cell_segs) % cell_segs
			var land_seg: int = ws * scale_factor
			if land_seg >= denser_segs:
				continue
			var tid: String = "B%d_%d" % [b_idx, ws]
			if _land_loader.is_land(b_idx, land_seg):
				tile_colors[tid] = LAND_COLOR
			else:
				tile_colors[tid] = OCEAN_COLOR

	if tile_colors.is_empty():
		return null

	var mi: MeshInstance3D = SphericalGridGenerator.generate_tint(
		EARTH_RADIUS_KM, _band_structure, tile_colors, b0, b1, s0, s1,
	)
	if not mi or not mi.mesh:
		return null
	return mi.mesh


# ── Idle preload ──

func _build_preload_queue(needed: Dictionary) -> void:
	_preload_queue.clear()
	# Gather all chunk keys adjacent to needed chunks
	for key in needed:
		var info: Dictionary = needed[key]
		var row: int = info["row"]
		var col: int = info["col"]
		# Add neighboring chunks (N,S,E,W, NE,NW,SE,SW)
		for dr in [-1, 0, 1]:
			for dc in [-1, 0, 1]:
				if dr == 0 and dc == 0: continue
				var nr: int = row + dr
				var nc: int = col + dc
				if nr < 0: continue
				var adj_key: String = "R%d_C%d" % [nr, nc]
				if not needed.has(adj_key) and not _chunk_cache.has(adj_key):
					if not _preload_queue.has(adj_key):
						_preload_queue.append(adj_key)
	# Limit queue size
	if _preload_queue.size() > 32:
		_preload_queue.resize(32)


func _preload_one_chunk() -> void:
	if _preload_queue.is_empty():
		return
	var key: String = _preload_queue[0]
	_preload_queue.remove_at(0)

	if _chunk_cache.has(key):
		return

	# Parse key
	var parts: PackedStringArray = key.split("_")
	if parts.size() < 4: return
	var row: int = int(parts[1])
	var col: int = int(parts[3])

	var mesh: ArrayMesh = _build_chunk_mesh(row, col)
	if mesh:
		_chunk_cache[key] = mesh
		_touch_chunk(key)
		while _chunk_cache_order.size() > MAX_CACHED_CHUNKS:
			var old_key: String = _chunk_cache_order[0]
			_chunk_cache_order.remove_at(0)
			_chunk_cache.erase(old_key)


# ── Earth body + camera helpers ──

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
		mat.uv1_offset.x = 0.25
		print("  Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)
		print("  Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _find_camera() -> Camera3D:
	var parent_node: Node = get_parent()
	if parent_node:
		for child in parent_node.get_children():
			if child is Camera3D:
				return child
	return null


func _camera_to_sub_point() -> Vector3:
	var cam_pos: Vector3 = _camera.global_position
	var dir: Vector3 = (Vector3.ZERO - cam_pos).normalized()
	var a: float = dir.dot(dir)
	var b: float = 2.0 * cam_pos.dot(dir)
	var c: float = cam_pos.dot(cam_pos) - EARTH_RADIUS_KM * EARTH_RADIUS_KM
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return Vector3.ZERO
	var t: float = (-b - sqrt(disc)) / (2.0 * a)
	if t < 0.0: t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 0.0: return Vector3.ZERO
	return cam_pos + dir * t
