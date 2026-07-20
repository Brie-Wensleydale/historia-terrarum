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

# Per-LOD shared mesh (one quad grid, UV-mapped for atlas tiles)
var _lod_meshes: Dictionary = {}  # lod → ArrayMesh
var _lod_materials: Dictionary = {}  # lod → StandardMaterial3D (shared, texture swapped per chunk)


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

	# Pre-build shared meshes + materials for LoD levels 1-4
	if not _lod_metadata.is_empty():
		for lod in range(1, 5):
			_build_lod_mesh(lod)

	print("LoD Display: ready (%d levels)" % _lod_metadata.size())


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

func _build_lod_mesh(lod: int) -> void:
	"""
	Build a shared quad-grid mesh for this LoD level.
	One quad per mega-cell in a chunk (16×16 px tile in atlas).
	UVs map to atlas tile positions.

	The mesh is built from the COARSER band structure at this LoD resolution.
	A chunk covers CHUNK_BANDS_0 base bands and CHUNK_SEGS_0 base segs.
	At LoD stride, this becomes mega_bands × mega_segs quads.
	"""
	# Determine stride for this LoD
	var stride: int = int(pow(4, lod))  # 4, 16, 64, 256
	var chunk_bands_0: int = 64   # base bands per chunk
	var chunk_segs_0: int = 256   # base segs per chunk

	var mega_bands: int = maxi(1, (chunk_bands_0 + stride - 1) / stride)
	var mega_segs: int = maxi(1, (chunk_segs_0 + stride - 1) / stride)

	print("  Building LOD %d mesh: stride=%d, %dx%d quads" % [lod, stride, mega_bands, mega_segs])

	var full_band_segs: Array = _band_structure["band_segs"]

	# Build ring vertices for a representative chunk at the equator
	# (the mesh is parametric — UVs handle the atlas mapping, vertex positions are approximate)
	var ring_verts: Array = []  # Array of PackedVector3Array, one per ring in the chunk
	var chunk_bands_lod: int = mega_bands  # number of LOD bands in this chunk's mesh
	var chunk_segs_lod: int = mega_segs  # number of LOD segs in this chunk's mesh

	# We need chunk_bands_lod + 1 rings of vertices
	# Each ring has chunk_segs_lod vertices (uniform for simplicity — atlas handles halving)
	var total_bands: int = _band_structure["total_bands"]
	var display_radius: float = EARTH_RADIUS_KM * SphericalGridGenerator.TINT_RADIUS_FACTOR

	# Build a regular grid of quads spanning a representative lat/lon patch
	# For simplicity, build the mesh for an equatorial chunk and rely on UVs for atlas mapping
	var lat_start: float = 0.0  # equator
	var lat_span: float = PI * float(chunk_bands_0) / float(total_bands)  # angular span of chunk

	for ring_idx in range(chunk_bands_lod + 1):
		var ring_lat: float = lat_start + lat_span * float(ring_idx) / float(chunk_bands_lod)
		var ring_r: float = display_radius * cos(ring_lat)
		var ring_y: float = display_radius * sin(ring_lat)
		var verts: PackedVector3Array = PackedVector3Array()
		verts.resize(chunk_segs_lod)
		for k in range(chunk_segs_lod):
			var ring_lon: float = TAU * float(k) / float(chunk_segs_lod)
			# negated Z mesh convention (matches generate_tint)
			verts[k] = Vector3(ring_r * cos(ring_lon), ring_y, -ring_r * sin(ring_lon))
		ring_verts.append(verts)

	# Build quad mesh
	var vertices: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	for row in range(chunk_bands_lod):
		var bot: PackedVector3Array = ring_verts[row]
		var top: PackedVector3Array = ring_verts[row + 1]
		for col in range(chunk_segs_lod):
			var vi: int = vertices.size()

			# Four corners of the quad
			vertices.append(bot[col])
			vertices.append(bot[(col + 1) % chunk_segs_lod])
			vertices.append(top[(col + 1) % chunk_segs_lod])
			vertices.append(top[col])

			# UVs: map to atlas tile at (col, row)
			var u0: float = float(col) / float(chunk_segs_lod)
			var u1: float = float(col + 1) / float(chunk_segs_lod)
			var v0: float = float(row) / float(chunk_bands_lod)
			var v1: float = float(row + 1) / float(chunk_bands_lod)
			uvs.append(Vector2(u0, v1))
			uvs.append(Vector2(u1, v1))
			uvs.append(Vector2(u1, v0))
			uvs.append(Vector2(u0, v0))

			# Two triangles
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

	# Create shared material for this LOD level
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_lod_meshes[lod] = mesh
	_lod_materials[lod] = mat


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
	# Check if already created
	if _chunk_nodes.has(key):
		var node: MeshInstance3D = _chunk_nodes[key]
		if is_instance_valid(node):
			if not node.visible:
				node.visible = true
			return

	# Create new chunk node
	var node: MeshInstance3D = MeshInstance3D.new()
	node.name = "LoD%d_Chunk_%d_%d" % [lod, row, col]
	node.mesh = _lod_meshes[lod]

	# Load atlas texture (or reuse cached)
	var tex_key: String = "lod%d_%s" % [lod, chunk["filename"]]
	if _chunk_textures.has(tex_key):
		node.material_override = _make_chunk_material(lod, _chunk_textures[tex_key])
	else:
		var atlas_path: String = DATA_DIR + "lod%d/%s" % [lod, chunk["filename"]]
		if FileAccess.file_exists(atlas_path):
			var img: Image = Image.load_from_file(atlas_path)
			if img:
				var tex: ImageTexture = ImageTexture.create_from_image(img)
				_chunk_textures[tex_key] = tex
				node.material_override = _make_chunk_material(lod, tex)

	if not node.material_override:
		# Fallback: use shared material without texture
		node.material_override = _lod_materials[lod]

	node.visible = true
	add_child(node)
	_chunk_nodes[key] = node


func _make_chunk_material(lod: int, tex: ImageTexture) -> StandardMaterial3D:
	var mat: StandardMaterial3D = _lod_materials[lod].duplicate()
	mat.albedo_texture = tex
	return mat


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
