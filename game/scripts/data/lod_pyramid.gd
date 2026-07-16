# lod_pyramid.gd — Multi-LOD Earth mesh manager.
# Generates coarser meshes from Level 0 territory data.
# Each quad at LOD 1+ is classified solid (vertex color) or textured (R8 palette texture).
extends Node

const PaletteTextureGen := preload("res://scripts/data/palette_texture_gen.gd")

const NUM_LODS := 5
const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # LOD 0 at 100km; textures up-sample from territory data

# Distance thresholds for LOD switching (km from Earth center)
# Earth surface = 6371 km. Orbit at ~8000 km = LOD 1.
const LOD_THRESHOLDS := [
	8000.0,   # LOD 0 → 1: below 8,000 km (surface zoom, ~1,600 km altitude)
	16000.0,  # LOD 1 → 2
	32000.0,  # LOD 2 → 3
	64000.0,  # LOD 3 → 4
]

# Band structures for LOD 0-4 (Array[Dictionary])
var _lod_structures: Array = []

# Mesh instance per LOD level (solid quads)
var _lod_meshes: Array = []

# Textured quad meshes per LOD (container Node3D with per-quad MeshInstance3D children)
var _lod_textured: Array = []

# Palette RGB colors for direct vertex color encoding (index → Color)
var _palette_colors: Dictionary = {}

# ShaderMaterial per LOD level
var _lod_materials: Array = []

# Classification: "%d_%d_%d" % [lod, band, seg] → "solid"|"textured"
var _quad_classifications: Dictionary = {}

# Dirty quads waiting for regeneration: Array[[lod, band, seg], ...]
var _dirty_quads: Array = []

# Current active LOD
var _active_lod: int = 0

# Smooth LOD transition
var _transition_active: bool = false
var _transition_from: int = 0
var _transition_to: int = 0
var _transition_time: float = 0.0
const TRANSITION_DURATION := 0.35  # seconds


func _ready() -> void:
	_lod_structures = SphericalGridGenerator.compute_all_lod_structures(
		EARTH_RADIUS_KM, BASE_CELL_KM
	)
	_lod_meshes.resize(NUM_LODS)
	_lod_textured.resize(NUM_LODS)
	_lod_materials.resize(NUM_LODS)
	_print_summary()


func _process(delta: float) -> void:
	_animate_transition(delta)


func _animate_transition(delta: float) -> void:
	if not _transition_active:
		return

	_transition_time += delta
	var t := clampf(_transition_time / TRANSITION_DURATION, 0.0, 1.0)

	# Ease in-out
	var ease_t := t * t * (3.0 - 2.0 * t)

	# Old LOD fades out
	_set_lod_alpha(_transition_from, 1.0 - ease_t)
	# New LOD fades in
	_set_lod_alpha(_transition_to, ease_t)

	if t >= 1.0:
		# Transition complete — hide old, show new fully
		_set_lod_alpha(_transition_from, 1.0)
		# Reset active LOD to fully opaque
		_set_lod_alpha(_transition_to, 1.0)
		_show_only_lod(_transition_to)
		_transition_active = false
		_active_lod = _transition_to


func _set_lod_alpha(lod: int, alpha: float) -> void:
	# Use transparency for crossfade (0 = opaque, 1 = fully transparent)
	# Only MeshInstance3D / GeometryInstance3D has transparency; Node3D containers don't
	var transp: float = 1.0 - alpha

	if lod < _lod_meshes.size() and _lod_meshes[lod]:
		_lod_meshes[lod].transparency = transp

	if lod < _lod_textured.size() and _lod_textured[lod]:
		# Textured container is a Node3D — set transparency on each child MeshInstance3D
		for child in _lod_textured[lod].get_children():
			if child is MeshInstance3D:
				child.transparency = transp


func _show_only_lod(lod: int) -> void:
	for i in range(NUM_LODS):
		var visible := (i == lod)
		if i < _lod_meshes.size() and _lod_meshes[i]:
			_lod_meshes[i].visible = visible
		if i < _lod_textured.size() and _lod_textured[i]:
			_lod_textured[i].visible = visible


func _print_summary() -> void:
	print("LOD Pyramid Manager initialized:")
	for lod in range(NUM_LODS):
		var count: int = SphericalGridGenerator.get_lod_tile_count(lod, _lod_structures)
		var bs: Dictionary = SphericalGridGenerator.get_lod_structure(lod, _lod_structures)
		print("  LOD %d: %s tiles (%d bands, %d eq segs)" % [
			lod, count,
			bs.get("total_bands", 0),
			bs.get("equator_segs", 0),
		])


## Classify a quad at a given LOD level.
## A quad at LOD N covers (2^N)×(2^N) Level 0 tiles.
## Returns "solid" if all sub-tiles have the same owner, "textured" otherwise.
func classify_quad(lod: int, qband: int, qseg: int, territory_data: Node) -> String:
	if lod == 0:
		return "solid"  # LOD 0 = single tile, always solid

	var span := 1 << lod  # 2^lod
	var first_owner: int = -1

	for db in range(span):
		for ds in range(span):
			var band0 := qband * span + db
			var seg0 := qseg * span + ds
			var tile_id: String = "B%d_%d" % [band0, seg0]
			var owner: int = territory_data.get_tile_owner_palette(tile_id)
			if first_owner == -1:
				first_owner = owner
			elif owner != first_owner:
				return "textured"

	return "solid"


## Get the majority palette index for a solid quad (center tile's owner).
func get_solid_owner(lod: int, qband: int, qseg: int, territory_data: Node) -> int:
	if lod == 0:
		var tile_id: String = "B%d_%d" % [qband, qseg]
		return territory_data.get_tile_owner_palette(tile_id)

	var span := 1 << lod
	# Sample center of the quad
	var center_band := qband * span + (span / 2)
	var center_seg := qseg * span + (span / 2)
	var tile_id: String = "B%d_%d" % [center_band, center_seg]
	return territory_data.get_tile_owner_palette(tile_id)


## Mark a quad dirty for regeneration.
func mark_dirty(lod: int, qband: int, qseg: int) -> void:
	_dirty_quads.append([lod, qband, qseg])


## Check if a quad is dirty.
func is_dirty(lod: int, qband: int, qseg: int) -> bool:
	for entry in _dirty_quads:
		if entry[0] == lod and entry[1] == qband and entry[2] == qseg:
			return true
	return false


## Clear all dirty flags.
func clear_dirty() -> void:
	_dirty_quads.clear()


## Select active LOD based on camera distance from Earth center (km).
func select_lod(camera_distance_km: float) -> int:
	for lod in range(1, NUM_LODS):
		if camera_distance_km < LOD_THRESHOLDS[lod - 1]:
			return lod - 1
	return NUM_LODS - 1


## Update visibility with smooth crossfade between old and new LOD.
func update_visibility(active_lod: int) -> void:
	if active_lod == _active_lod and not _transition_active:
		return

	# If already transitioning to the same lod, skip
	if _transition_active and _transition_to == active_lod:
		return

	# Start crossfade
	_transition_from = _active_lod if not _transition_active else _transition_to
	_transition_to = active_lod
	_transition_time = 0.0
	_transition_active = true

	# Make both old and new visible for the crossfade
	if _transition_from < _lod_meshes.size() and _lod_meshes[_transition_from]:
		_lod_meshes[_transition_from].visible = true
	if _transition_from < _lod_textured.size() and _lod_textured[_transition_from]:
		_lod_textured[_transition_from].visible = true

	if _transition_to < _lod_meshes.size() and _lod_meshes[_transition_to]:
		_lod_meshes[_transition_to].visible = true
	if _transition_to < _lod_textured.size() and _lod_textured[_transition_to]:
		_lod_textured[_transition_to].visible = true


## Get classification stats for all quads at a LOD level.
func get_classification_stats(lod: int, territory_data: Node) -> Dictionary:
	if lod <= 0:
		return {"solid": 0, "textured": 0}

	var bs: Dictionary = _lod_structures[lod]
	var band_segs: Array = bs["band_segs"]
	var total_bands: int = bs["total_bands"]
	var solid: int = 0
	var textured: int = 0

	for b_idx in range(total_bands - 1):
		var segs_a: int = band_segs[b_idx]
		var segs_b: int = band_segs[b_idx + 1]
		if segs_a <= 0 or segs_b <= 0:
			continue
		var sparser_segs: int = mini(segs_a, segs_b)
		for s in range(sparser_segs):
			var cls: String = classify_quad(lod, b_idx, s, territory_data)
			var key: String = "%d_%d_%d" % [lod, b_idx, s]
			_quad_classifications[key] = cls
			if cls == "solid":
				solid += 1
			else:
				textured += 1

	return {"solid": solid, "textured": textured}


## Generate meshes for a given LOD level.
## Returns Dictionary with "solid" (MeshInstance3D) and "textured" (Node3D container).
## Solid quads use vertex colors + solid_tint shader.
## Textured quads use per-quad R8 textures + territory_palette shader.
func generate_lod_mesh(lod: int, territory_data: Node) -> Dictionary:
	var result: Dictionary = {"solid": null, "textured": null}

	if lod <= 0 or lod >= NUM_LODS:
		return result

	var span: int = 1 << lod

	# LOD N band structure (for iteration bounds only)
	var bs: Dictionary = _lod_structures[lod]
	var band_segs: Array = bs["band_segs"]
	var total_bands: int = bs["total_bands"]

	# LOD 0 band structure (for vertex positions — ground truth)
	var bs0: Dictionary = _lod_structures[0]
	var band_segs0: Array = bs0["band_segs"]
	var total_bands0: int = bs0["total_bands"]
	var radius_m: float = EARTH_RADIUS_KM * 1000.0
	var offset_factor: float = 1.003 + lod * 0.0005

	var st_solid: SurfaceTool = SurfaceTool.new()
	st_solid.begin(Mesh.PRIMITIVE_TRIANGLES)

	var solid_count: int = 0
	var textured_count: int = 0
	var ocean_count: int = 0

	var textured_quads: Array = []

	for b_idx in range(total_bands - 1):
		var segs_a: int = band_segs[b_idx]
		var segs_b: int = band_segs[b_idx + 1]
		if segs_a <= 0 or segs_b <= 0:
			continue

		var sparser_segs: int = mini(segs_a, segs_b)

		for s in range(sparser_segs):
			var classification: String = classify_quad(lod, b_idx, s, territory_data)
			var key: String = "%d_%d_%d" % [lod, b_idx, s]
			_quad_classifications[key] = classification

			# Quad corners from LOD 0 positions — ensures perfect alignment
			# with territory data (which uses LOD 0 tile IDs)
			var band0_bot: int = clampi(b_idx * span, 0, total_bands0 - 1)
			var band0_top: int = clampi((b_idx + 1) * span, 0, total_bands0)
			var seg0_left: int = s * span
			var seg0_right: int = (s + 1) * span

			var v_bl: Vector3 = _lod0_vertex(band0_bot, seg0_left, offset_factor, bs0, total_bands0, band_segs0, radius_m)
			var v_br: Vector3 = _lod0_vertex(band0_bot, seg0_right, offset_factor, bs0, total_bands0, band_segs0, radius_m)
			var v_tl: Vector3 = _lod0_vertex(band0_top, seg0_left, offset_factor, bs0, total_bands0, band_segs0, radius_m)
			var v_tr: Vector3 = _lod0_vertex(band0_top, seg0_right, offset_factor, bs0, total_bands0, band_segs0, radius_m)

			if classification == "textured":
				textured_count += 1
				var rgb_2d: Array = _build_texture_rgb(lod, b_idx, s, territory_data)
				textured_quads.append({
					"v_bl": v_bl, "v_br": v_br, "v_tl": v_tl, "v_tr": v_tr,
					"colors": rgb_2d,
					"key": key,
				})
				continue

			# Solid quad
			var palette_idx: int = get_solid_owner(lod, b_idx, s, territory_data)
			if palette_idx == 0:
				ocean_count += 1
				continue

			solid_count += 1
			var rgb: Color = _palette_colors.get(palette_idx, Color(0.5, 0.5, 0.5, 0.7))
			st_solid.set_color(rgb)
			st_solid.add_vertex(v_bl); st_solid.add_vertex(v_br); st_solid.add_vertex(v_tr)
			st_solid.add_vertex(v_bl); st_solid.add_vertex(v_tr); st_solid.add_vertex(v_tl)

	# Build solid mesh
	if solid_count > 0:
		var solid_mesh: ArrayMesh = st_solid.commit()
		if solid_mesh:
			var scaled: ArrayMesh = _scale_array_mesh(solid_mesh, 1.0 / 1000.0)
			var mi: MeshInstance3D = MeshInstance3D.new()
			mi.name = "LOD_%d_Solid" % lod
			mi.mesh = scaled
			mi.visible = false
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.vertex_color_use_as_albedo = true
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.flags_unshaded = true
			mi.material_override = mat
			result["solid"] = mi

	# Build textured mesh
	if textured_count > 0:
		var container: Node3D = Node3D.new()
		container.name = "LOD_%d_Textured" % lod
		container.visible = false

		for qdata in textured_quads:
			var quad_mi: MeshInstance3D = _build_textured_quad(qdata)
			if quad_mi:
				container.add_child(quad_mi)

		result["textured"] = container

	print("  LOD %d: %d solid, %d textured, %d ocean" % [lod, solid_count, textured_count, ocean_count])
	return result


## Compute 3D vertex position using LOD 0 band structure.
static func _lod0_vertex(band: int, seg: int, offset_factor: float,
		bs0: Dictionary, total_bands: int, band_segs: Array, radius_m: float) -> Vector3:
	band = clampi(band, 0, total_bands - 1)
	var segs_at_band: int = band_segs[band] if band < band_segs.size() else 4
	if segs_at_band <= 0:
		segs_at_band = 4
	var lat: float = -PI * 0.5 + PI * float(band) / float(total_bands)
	var lon: float = TAU * float(seg % segs_at_band) / float(segs_at_band)
	var r: float = radius_m * cos(lat) * offset_factor
	return Vector3(r * cos(lon), radius_m * sin(lat) * offset_factor, r * sin(lon))


## Build a 2D array of RGB Colors for a textured quad.
## Each element corresponds to a Level 0 sub-tile within the quad.
func _build_texture_rgb(lod: int, qband: int, qseg: int, territory_data: Node) -> Array:
	var span := 1 << lod
	var colors: Array = []
	for db in range(span):
		var row: Array = []
		for ds in range(span):
			var band0 := qband * span + db
			var seg0 := qseg * span + ds
			var tile_id: String = "B%d_%d" % [band0, seg0]
			var idx: int = territory_data.get_tile_owner_palette(tile_id)
			row.append(_palette_colors.get(idx, Color.TRANSPARENT))
		colors.append(row)
	return colors


## Create a single textured quad MeshInstance3D with RGB texture.
func _build_textured_quad(qdata: Dictionary) -> MeshInstance3D:
	var v_bl: Vector3 = qdata["v_bl"]
	var v_br: Vector3 = qdata["v_br"]
	var v_tl: Vector3 = qdata["v_tl"]
	var v_tr: Vector3 = qdata["v_tr"]
	var colors_2d: Array = qdata["colors"]

	# Generate RGB texture from color array
	var span: int = colors_2d.size()
	var img: Image = Image.create(span, span, false, Image.FORMAT_RGBA8)
	for row in range(span):
		for col in range(span):
			var c: Color = colors_2d[row][col]
			img.set_pixel(col, row, c)
	var texture: ImageTexture = ImageTexture.create_from_image(img)

	# Build quad mesh
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	st.set_uv(Vector2(0, 0)); st.add_vertex(v_bl)
	st.set_uv(Vector2(1, 0)); st.add_vertex(v_br)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v_tr)
	st.set_uv(Vector2(0, 0)); st.add_vertex(v_bl)
	st.set_uv(Vector2(1, 1)); st.add_vertex(v_tr)
	st.set_uv(Vector2(0, 1)); st.add_vertex(v_tl)

	var mesh: ArrayMesh = st.commit()
	if not mesh:
		return null

	var scaled := _scale_array_mesh(mesh, 1.0 / 1000.0)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "TexQuad_%s" % qdata.get("key", "?")
	mi.mesh = scaled

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.flags_unshaded = true
	mi.material_override = mat

	return mi


## Scale an ArrayMesh by a factor (meters → kilometers).
func _scale_array_mesh(mesh: ArrayMesh, factor: float) -> ArrayMesh:
	var scaled: ArrayMesh = ArrayMesh.new()
	for surface_idx in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var scaled_verts := PackedVector3Array()
		scaled_verts.resize(verts.size())
		for i in range(verts.size()):
			scaled_verts[i] = verts[i] * factor
		arrays[Mesh.ARRAY_VERTEX] = scaled_verts
		var prim: int = mesh.surface_get_primitive_type(surface_idx)
		scaled.add_surface_from_arrays(prim, arrays)
	return scaled


## Generate meshes for all LOD levels and store them.
func generate_all_lod_meshes(territory_data: Node, palette_manager: Node, palette_colors: Dictionary = {}) -> void:
	_palette_colors = palette_colors
	print("Generating LOD meshes...")
	for lod in range(1, NUM_LODS):
		var result: Dictionary = generate_lod_mesh(lod, territory_data)

		# Store solid mesh
		var solid_mi: MeshInstance3D = result.get("solid")
		if solid_mi:
			_lod_meshes[lod] = solid_mi
			add_child(solid_mi)

		# Store textured container
		var textured_container: Node3D = result.get("textured")
		if textured_container:
			_lod_textured[lod] = textured_container
			add_child(textured_container)

	print("LOD mesh generation complete (%d levels)" % (_lod_meshes.size() - 1))


## Register the existing LOD 0 tint mesh for visibility tracking.
func register_lod_zero(mesh: MeshInstance3D) -> void:
	_lod_meshes[0] = mesh
