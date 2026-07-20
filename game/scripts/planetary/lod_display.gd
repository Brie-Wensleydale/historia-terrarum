# lod_display.gd — HT2 Tier 3: Pre-baked LoD terrain display
# Loads texture atlases built by generate_lod_terrain.py.
# At runtime: select LoD level by camera distance, show/hide chunks.
# No mesh generation — everything is pre-baked.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const DATA_DIR := "res://../data/output/grid_10km_ht2/lod/"
const METADATA_FILE := "lod_chunks.json"

# LoD level → (max camera distance from Earth center to use this level, index)
const LOD_THRESHOLDS := [
	{"max_dist": 0.0,       "level": 0},   # LOD 0 = current system, unused here
	{"max_dist": 8000.0,    "level": 0},   # below 8000km = LOD 0 (current vertex-color)
	{"max_dist": 16000.0,   "level": 1},   # 8000-16000km = LOD 1
	{"max_dist": 30000.0,   "level": 2},   # 16000-30000km = LOD 2
	{"max_dist": 45000.0,   "level": 3},   # 30000-45000km = LOD 3
	{"max_dist": INF,       "level": 4},   # 45000+ = LOD 4
]

var _camera: Camera3D
var _earth_display: Node  # EarthDisplay node — toggled visibility at LOD switch
var _band_structure: Dictionary = {}

# Metadata from Python pipeline
var _lod_metadata: Dictionary = {}  # lod → [chunk entries]
var _active_lod: int = -1

# Per-chunk runtime state: key = "lod_{lod}_{row}_{col}"
var _chunk_nodes: Dictionary = {}  # key → MeshInstance3D
var _chunk_textures: Dictionary = {}  # key → ImageTexture (cached)


func _ready() -> void:
	print("LoD Display: initializing...")

	# Find camera
	_camera = _find_camera()
	if not _camera:
		push_error("LoD: no Camera3D found!")
		return

	# Find EarthDisplay sibling (for LOD 0 handoff)
	var parent_node: Node = get_parent()
	if parent_node:
		_earth_display = parent_node.get_node_or_null("EarthDisplay")

	# Load band structure
	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, 10.0)

	# Load chunk metadata
	if not _load_metadata():
		print("  LoD: no atlas data — run generate_lod_terrain.py to build. Using EarthDisplay only.")
		# Don't return; let _process handle graceful fallback

	var total_chunks: int = 0
	for lod_key in _lod_metadata:
		total_chunks += _lod_metadata[lod_key].size()
	print("LoD Display: ready (%d levels, %d total chunks)" % [_lod_metadata.size(), total_chunks])


func _process(_delta: float) -> void:
	if not _camera or _lod_metadata.is_empty():
		# No LOD data — show earth_display and bail
		if _earth_display:
			_earth_display.visible = true
		return

	# Determine active LoD from camera distance
	var cam_dist: float = _camera.global_position.length()
	var new_lod: int = 0
	for threshold in LOD_THRESHOLDS:
		if cam_dist <= threshold["max_dist"]:
			new_lod = threshold["level"]
			break

	if new_lod == 0:
		# LOD 0 = current earth_display.gd system — hide our chunks, show earth_display
		if _active_lod != 0:
			_hide_all_chunks()
			if _earth_display:
				_earth_display.visible = true
			_active_lod = 0
		return

	if new_lod != _active_lod and _active_lod > 0:
		_hide_all_chunks()

	if _active_lod <= 0 and _earth_display:
		# Switching from LOD 0 to LOD 1+ — hide earth_display
		_earth_display.visible = false
		print("LOD switch: EarthDisplay OFF, LoDDisplay level %d (%d chunks)" % [new_lod, _lod_metadata.get(new_lod, []).size()])

	_active_lod = new_lod

	# Compute visible chunks
	var sub_point: Vector3 = _camera_to_sub_point()
	if sub_point.length() < 0.001:
		return

	_show_visible_chunks(new_lod, sub_point)


# ── Metadata loading ──

func _load_metadata() -> bool:
	var path: String = DATA_DIR + METADATA_FILE
	if not FileAccess.file_exists(path):
		push_warning("LoD: lod_chunks.json not found — run generate_lod_terrain.py to build atlases")
		return false

	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("LoD: cannot open %s" % path)
		return false

	var text: String = f.get_as_text()
	f.close()

	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		push_error("LoD: invalid JSON in %s" % path)
		return false

	var data: Dictionary = json.get_data()

	# Organize by lod level
	for lod_str in data:
		var lod: int = int(lod_str)
		_lod_metadata[lod] = data[lod_str]

	var lod_list: Array = []
	for lod_str in data:
		lod_list.append(lod_str)
	print("  Loaded metadata: %s" % lod_list)
	return true


# ── Shared mesh builder ──
# Builds a sphere-surface quad mesh for a specific chunk at a given LoD level.
# Vertices are on the sphere at TINT_RADIUS_FACTOR, UVs map atlas tiles to quads.

func _build_chunk_mesh(chunk: Dictionary, lod: int) -> ArrayMesh:
	var full_band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var display_radius: float = EARTH_RADIUS_KM * SphericalGridGenerator.TINT_RADIUS_FACTOR

	var b0: int = chunk["band_start_0"]
	var b1: int = chunk["band_end_0"]
	var s0: int = chunk["seg_start_0"]
	var s1: int = chunk["seg_end_0"]
	var mega_bands: int = chunk["mega_bands"]
	var mega_segs: int = chunk["mega_segs"]

	if mega_bands <= 0 or mega_segs <= 0:
		return null

	# Build ring vertices at this chunk's actual latitude/longitude range
	var ring_verts: Array = []  # PackedVector3Array per ring (mega_bands + 1 rings)

	# Determine longitude span: fraction of 360° that this chunk covers
	var center_b0: float = (float(b0) + float(b1)) * 0.5
	var center_band: int = clampi(int(center_b0), 0, total_bands - 1)
	var segs_bot_c: int = full_band_segs[center_band]
	var segs_top_c: int = full_band_segs[center_band + 1] if center_band + 1 < full_band_segs.size() else segs_bot_c
	var segs_at_center: int = maxi(segs_bot_c, segs_top_c)
	var lon_start: float = TAU * float(s0) / float(segs_at_center)
	var lon_end: float = TAU * float(s1) / float(segs_at_center)

	for ring_i in range(mega_bands + 1):
		var base_band_f: float = float(b0) + float(ring_i) / float(mega_bands) * float(b1 - b0)
		var ring_lat: float = -PI * 0.5 + PI * base_band_f / float(total_bands)
		var ring_r: float = display_radius * cos(ring_lat)
		var ring_y: float = display_radius * sin(ring_lat)
		var verts: PackedVector3Array = PackedVector3Array()
		verts.resize(mega_segs)
		for k in range(mega_segs):
			var frac: float = float(k) / float(mega_segs)
			var ring_lon: float = lon_start + frac * (lon_end - lon_start)
			verts[k] = Vector3(ring_r * cos(ring_lon), ring_y, -ring_r * sin(ring_lon))
		ring_verts.append(verts)

	# Build quad mesh with UVs
	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	for row in range(mega_bands):
		var bot: PackedVector3Array = ring_verts[row]
		var top: PackedVector3Array = ring_verts[row + 1]
		for col in range(mega_segs):
			var vi: int = vertices.size()
			vertices.append(bot[col])
			vertices.append(bot[(col + 1) % mega_segs])
			vertices.append(top[(col + 1) % mega_segs])
			vertices.append(top[col])

			var u0: float = float(col) / float(mega_segs)
			var u1: float = float(col + 1) / float(mega_segs)
			var v0: float = float(row) / float(mega_bands)
			var v1: float = float(row + 1) / float(mega_bands)
			uvs.append(Vector2(u0, v1))
			uvs.append(Vector2(u1, v1))
			uvs.append(Vector2(u1, v0))
			uvs.append(Vector2(u0, v0))

			indices.append(vi)
			indices.append(vi + 1)
			indices.append(vi + 2)
			indices.append(vi)
			indices.append(vi + 2)
			indices.append(vi + 3)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ── Chunk visibility ──

func _show_visible_chunks(lod: int, sub_point: Vector3) -> void:
	if not _lod_metadata.has(lod):
		return

	var chunks: Array = _lod_metadata[lod]
	var visible_keys: Dictionary = {}  # keys that should be visible this frame

	# Convert sub_point to lat/lon to find which chunk the camera is over
	var lat: float = asin(clampf(sub_point.y / EARTH_RADIUS_KM, -1.0, 1.0))
	var lon: float = atan2(-sub_point.z, sub_point.x)
	if lon < 0.0:
		lon += TAU
	var lat_deg: float = rad_to_deg(lat)
	var lon_deg: float = rad_to_deg(lon) - 180.0

	# Compute which base bands/seg the sub_point is in
	var total_bands: int = _band_structure["total_bands"]
	var center_band: int = clampi(int((lat + PI * 0.5) / PI * float(total_bands)), 0, total_bands - 1)
	var eq_segs: int = _band_structure["equator_segs"]
	var band_segs: Array = _band_structure["band_segs"]
	var cell_segs_center: int = maxi(
		band_segs[center_band] if center_band < band_segs.size() else eq_segs,
		band_segs[center_band + 1] if center_band + 1 < band_segs.size() else eq_segs
	)
	var center_seg: int = int(((lon_deg + 180.0) / 360.0) * float(cell_segs_center)) % maxi(cell_segs_center, 1)

	# Show chunks near the camera sub_point
	for chunk in chunks:
		var cr: int = chunk["chunk_row"]
		var cc: int = chunk["chunk_col"]
		var key: String = "lod_%d_%d_%d" % [lod, cr, cc]

		# Check if this chunk is near the camera
		var bs: int = chunk["band_start_0"]
		var be: int = chunk["band_end_0"]
		var ss: int = chunk["seg_start_0"]
		var se: int = chunk["seg_end_0"]

		var near_band: bool = center_band >= bs - 256 and center_band <= be + 256
		var near_seg: bool = false
		# Seg check is approximate — chunks near the camera longitudinally
		var seg_dist: int = mini(abs(center_seg - ss), mini(abs(center_seg - se), abs(center_seg + cell_segs_center - ss)))
		near_seg = seg_dist < 512

		if near_band and near_seg:
			visible_keys[key] = true
			_ensure_chunk_visible(lod, cr, cc, key, chunk)

	# Hide chunks not visible this frame
	var keys_to_hide: Array = []
	for key in _chunk_nodes:
		if not visible_keys.has(key):
			var node: MeshInstance3D = _chunk_nodes[key]
			if is_instance_valid(node) and node.visible:
				node.visible = false


func _ensure_chunk_visible(lod: int, row: int, col: int, key: String, chunk: Dictionary) -> void:
	if _chunk_nodes.has(key):
		var node: MeshInstance3D = _chunk_nodes[key]
		if is_instance_valid(node):
			if not node.visible:
				node.visible = true
			return

	# Build chunk mesh on the sphere surface
	var mesh: ArrayMesh = _build_chunk_mesh(chunk, lod)
	if not mesh:
		return

	# Create chunk node
	var node: MeshInstance3D = MeshInstance3D.new()
	node.name = "LoD%d_Chunk_%d_%d" % [lod, row, col]
	node.mesh = mesh

	# Load atlas texture
	var tex_key: String = "lod%d_%s" % [lod, chunk["filename"]]
	var tex: ImageTexture
	if _chunk_textures.has(tex_key):
		tex = _chunk_textures[tex_key]
	else:
		var atlas_path: String = DATA_DIR + "lod%d/%s" % [lod, chunk["filename"]]
		if FileAccess.file_exists(atlas_path):
			var img: Image = Image.load_from_file(atlas_path)
			if img:
				tex = ImageTexture.create_from_image(img)
				_chunk_textures[tex_key] = tex

	# Create material
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex:
		mat.albedo_texture = tex
	node.material_override = mat

	node.visible = true
	add_child(node)
	_chunk_nodes[key] = node


func _hide_all_chunks() -> void:
	for key in _chunk_nodes:
		var node: MeshInstance3D = _chunk_nodes[key]
		if is_instance_valid(node):
			node.visible = false


# ── Camera helpers ──

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
	if t < 0.0:
		t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 0.0:
		return Vector3.ZERO
	return cam_pos + dir * t
