# lod_pyramid.gd — Multi-LOD Earth mesh manager.
# Generates coarser meshes from Level 0 territory data.
# Each quad at LOD 1+ is classified solid (vertex color) or textured (RGBA8 texture).
#
# VERTICAL GAP FIX (LOD 2-3):
# 1. Canonical ring subdivision: every latitude ring gets ONE vertex count
#    (lcm of the two adjacent strips' sparser counts). Both strips sharing a
#    ring sample it with identical vertices — watertight for ANY merge chain,
#    including non-power-of-2 ratios (4<->12, 25<->12) where the old
#    grid_below/grid_above heuristic could disagree.
# 2. Ring latitudes come from LOD N's own band structure (ring / total_bands).
#    Identical to the old band0=b*span mapping for LOD 1-2 (200=100*2=50*4),
#    but LOD 3 (26 bands, 26*8=208 != 200) placed rings at wrong latitudes and
#    LOD 4 (12 bands, 12*16=192 != 200) never reached the pole.
# 3. Tile lookups clamp/wrap into valid LOD 0 range. LOD 3's classify pass
#    read bands 200..207 (nonexistent) → owner 0 → ocean → skipped quads
#    (holes). Longitude is periodic, so out-of-range segs wrap.
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
	var t: float = clampf(_transition_time / TRANSITION_DURATION, 0.0, 1.0)

	# Ease in-out
	var ease_t: float = t * t * (3.0 - 2.0 * t)

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
		var visible: bool = (i == lod)
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

## Clamp a LOD 0 band index into the valid tile range [0, total_bands0 - 1].
## LOD 3 has 26 bands (26 × span 8 = 208 > 200), so qband*span+db can reach 207.
## Reading those invented bands returned owner 0 → quads misclassified as ocean
## → skipped → visible holes at LOD 3.
func _clamp_band0(band0: int) -> int:
	if _lod_structures.is_empty():
		return band0
	var bs0: Dictionary = _lod_structures[0]
	var total_bands0: int = bs0["total_bands"]
	return clampi(band0, 0, total_bands0 - 1)

## Classify a quad at a given LOD level.
## A quad at LOD N covers (2^N)×(2^N) Level 0 tiles.
## Uses denser segment convention (matches tile_mapping_100km.json keys).
## Returns "solid" if all sub-tiles have the same owner, "textured" otherwise.
func classify_quad(lod: int, qband: int, qseg: int, territory_data: Node) -> String:
	if lod == 0:
		return "solid"

	var span: int = 1 << lod
	var first_owner: int = -1

	for db in range(span):
		var band0: int = _clamp_band0(qband * span + db)
		for ds in range(span):
			var raw_seg: int = qseg * span + ds
			var cell_seg: int = _to_denser_seg(band0, raw_seg)
			var tile_id: String = "B%d_%d" % [band0, cell_seg]
			var owner: int = territory_data.get_tile_owner_palette(tile_id)
			if first_owner == -1:
				first_owner = owner
			elif owner != first_owner:
				return "textured"

	return "solid"

## Get the majority palette index for a solid quad (center tile's owner).
func get_solid_owner(lod: int, qband: int, qseg: int, territory_data: Node) -> int:
	if lod == 0:
		var sparser_seg: int = _to_sparser_seg(qband, qseg)
		var tile_id: String = "B%d_%d" % [qband, sparser_seg]
		return territory_data.get_tile_owner_palette(tile_id)

	var span: int = 1 << lod
	var center_band: int = _clamp_band0(qband * span + (span / 2))
	var center_raw: int = qseg * span + (span / 2)
	var sparser_seg: int = _to_sparser_seg(center_band, center_raw)
	var tile_id: String = "B%d_%d" % [center_band, sparser_seg]
	return territory_data.get_tile_owner_palette(tile_id)


## Convert a raw LOD 0 segment to sparser segment convention.
## At merge boundaries (ratio > 1), raw seg is ratio × sparser seg.
## Out-of-range raw segs wrap (longitude is periodic): LOD 2-3 quads near
## merge zones can request raw segs beyond the band's seg count
## (e.g. sparser*span = 48 > 25 LOD 0 segs) — without the wrap they hit
## nonexistent tile IDs and the quad was misclassified as ocean (a hole).
func _to_sparser_seg(band: int, raw_seg: int) -> int:
	if _lod_structures.is_empty():
		return raw_seg
	var bs0: Dictionary = _lod_structures[0]
	var band_segs: Array = bs0["band_segs"]
	if band >= band_segs.size() or band < 0:
		return raw_seg
	var segs_at: int = band_segs[band]
	if segs_at <= 0:
		return raw_seg
	var next_segs: int = band_segs[band + 1] if band + 1 < band_segs.size() else segs_at
	var sparser_segs: int = mini(segs_at, next_segs)
	if sparser_segs <= 0:
		return raw_seg
	var ratio: int = maxi(segs_at / sparser_segs, 1)
	return (raw_seg / ratio) % sparser_segs


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

	for b_idx in range(total_bands):
		var segs_a: int = band_segs[b_idx]
		var segs_b: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs_a
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


## Integer least common multiple (via Euclidean gcd).
static func _lcm(a: int, b: int) -> int:
	if a <= 0 or b <= 0:
		return maxi(a, b)
	var x: int = a
	var y: int = b
	while y != 0:
		var t: int = x % y
		x = y
		y = t
	return a / x * b


## Compute the canonical vertex count for every latitude ring.
## Both strips adjacent to ring r MUST sample it with the same vertex count,
## otherwise the shared edge has T-junctions → vertical gaps. ring_segs[r] is
## the lcm of the two adjacent strips' sparser counts — the minimal uniform
## longitude grid containing both sides' vertices. Every adjacent sparser
## count divides it exactly (works for 2:1, 3:1, and non-dividing ratios like
## 25<->12 where the old grid_below/grid_above heuristic disagreed).
static func _compute_ring_segs(band_segs: Array) -> Array[int]:
	var n: int = band_segs.size()  # total_bands + 1 ring entries
	var ring_segs: Array[int] = []
	ring_segs.resize(n)
	for r in range(n):
		var sparser_below: int = 0
		if r > 0:
			sparser_below = mini(band_segs[r - 1], band_segs[r])
		var sparser_above: int = 0
		if r + 1 < n:
			sparser_above = mini(band_segs[r], band_segs[r + 1])
		if sparser_below <= 0:
			ring_segs[r] = maxi(sparser_above, 1)
		elif sparser_above <= 0:
			ring_segs[r] = maxi(sparser_below, 1)
		else:
			ring_segs[r] = _lcm(sparser_below, sparser_above)
	return ring_segs


## Compute a 3D vertex on the offset sphere for a given ring + longitude.
## Latitude comes from the ring's own band fraction (ring / total_bands) —
## analytic, no seg modulo. For LOD 1-2 this is bit-identical to the old
## band0=b*span / total_bands0 mapping (200 = 100*2 = 50*4); for LOD 3
## (26 bands) and LOD 4 (12 bands) the old mapping distorted ring latitudes
## and missed/overran the pole.
static func _sphere_vertex(ring: int, total_bands: int, lon: float,
		offset_factor: float, radius_m: float) -> Vector3:
	ring = clampi(ring, 0, total_bands)
	var lat: float = -PI * 0.5 + PI * float(ring) / float(total_bands)
	var r: float = radius_m * cos(lat) * offset_factor
	return Vector3(r * cos(lon), radius_m * sin(lat) * offset_factor, r * sin(lon))


## Generate meshes for a given LOD level.
## Returns Dictionary with "solid" (MeshInstance3D) and "textured" (Node3D container).
## Solid quads use direct RGB vertex colors; textured quads use per-quad RGBA8 textures.
func generate_lod_mesh(lod: int, territory_data: Node) -> Dictionary:
	var result: Dictionary = {"solid": null, "textured": null}

	if lod <= 0 or lod >= NUM_LODS:
		return result

	# LOD N band structure — used for iteration AND vertex placement.
	var bs: Dictionary = _lod_structures[lod]
	var band_segs: Array = bs["band_segs"]
	var total_bands: int = bs["total_bands"]

	var radius_m: float = EARTH_RADIUS_KM * 1000.0
	var offset_factor: float = 1.003 + lod * 0.0005

	# Canonical vertex count per latitude ring (vertical gap fix — see header).
	var ring_segs: Array[int] = _compute_ring_segs(band_segs)

	var st_solid: SurfaceTool = SurfaceTool.new()
	st_solid.begin(Mesh.PRIMITIVE_TRIANGLES)

	var solid_count: int = 0
	var textured_count: int = 0
	var ocean_count: int = 0

	var textured_quads: Array = []

	for b_idx in range(total_bands):  # all bands (includes polar cap strip)
		var segs_a: int = band_segs[b_idx]
		var segs_b: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs_a
		if segs_a <= 0 or segs_b <= 0:
			continue

		var sparser_segs: int = mini(segs_a, segs_b)

		# Exact edge subdivisions from the canonical ring counts. Both divide
		# evenly by construction (ring_segs is an lcm of adjacent sparser
		# counts, and sparser_segs is one of them) — no truncation, and both
		# strips sharing a ring emit bit-identical vertices there.
		var bottom_sub: int = maxi(ring_segs[b_idx] / sparser_segs, 1)
		var top_sub: int = maxi(ring_segs[b_idx + 1] / sparser_segs, 1)

		for s in range(sparser_segs):
			var classification: String = classify_quad(lod, b_idx, s, territory_data)
			var key: String = "%d_%d_%d" % [lod, b_idx, s]
			_quad_classifications[key] = classification

			# Analytic longitude on the canonical ring grid:
			# denominator == ring_segs[ring] for both adjacent strips, so
			# shared-edge vertices are computed by identical float ops.
			var bottom_verts: Array[Vector3] = []
			for k in range(bottom_sub + 1):
				var lon_b: float = TAU * float(s * bottom_sub + k) / float(sparser_segs * bottom_sub)
				bottom_verts.append(_sphere_vertex(b_idx, total_bands, lon_b, offset_factor, radius_m))
			var top_verts: Array[Vector3] = []
			for k in range(top_sub + 1):
				var lon_t: float = TAU * float(s * top_sub + k) / float(sparser_segs * top_sub)
				top_verts.append(_sphere_vertex(b_idx + 1, total_bands, lon_t, offset_factor, radius_m))

			var centroid: Vector3 = (bottom_verts[0] + bottom_verts[bottom_sub] + top_verts[0] + top_verts[top_sub])
			if centroid.length() < 0.001:
				centroid = bottom_verts[0]
			else:
				centroid = centroid.normalized() * radius_m * offset_factor

			if classification == "textured":
				textured_count += 1
				var rgb_2d: Array = _build_texture_rgb(lod, b_idx, s, territory_data)
				textured_quads.append({
					"bottom_verts": bottom_verts,
					"top_verts": top_verts,
					"centroid": centroid,
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
			# Centroid fan — watertight for any bottom/top subdivision pairing.
			for k in range(bottom_sub):
				st_solid.add_vertex(bottom_verts[k]); st_solid.add_vertex(bottom_verts[k + 1]); st_solid.add_vertex(centroid)
			st_solid.add_vertex(bottom_verts[bottom_sub]); st_solid.add_vertex(top_verts[top_sub]); st_solid.add_vertex(centroid)
			for k in range(top_sub):
				st_solid.add_vertex(top_verts[k + 1]); st_solid.add_vertex(top_verts[k]); st_solid.add_vertex(centroid)
			st_solid.add_vertex(top_verts[0]); st_solid.add_vertex(bottom_verts[0]); st_solid.add_vertex(centroid)

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


## Build a 2D array of RGB Colors for a textured quad.
## Each element corresponds to a Level 0 sub-tile within the quad.
func _build_texture_rgb(lod: int, qband: int, qseg: int, territory_data: Node) -> Array:
	var span: int = 1 << lod
	var colors: Array = []
	for db in range(span):
		var band0: int = _clamp_band0(qband * span + db)
		var row: Array = []
		for ds in range(span):
			var raw_seg: int = qseg * span + ds
			var sparser_seg: int = _to_sparser_seg(band0, raw_seg)
			var tile_id: String = "B%d_%d" % [band0, sparser_seg]
			var idx: int = territory_data.get_tile_owner_palette(tile_id)
			row.append(_palette_colors.get(idx, Color.TRANSPARENT))
		colors.append(row)
	return colors


## Create a single textured quad MeshInstance3D with RGB texture.
## Triangulated as a centroid fan matching the solid path exactly, with UVs
## mapped along the (possibly subdivided) boundary edges.
func _build_textured_quad(qdata: Dictionary) -> MeshInstance3D:
	var bottom_verts: Array = qdata["bottom_verts"]
	var top_verts: Array = qdata["top_verts"]
	var centroid: Vector3 = qdata["centroid"]
	var colors_2d: Array = qdata["colors"]
	var bottom_sub: int = bottom_verts.size() - 1
	var top_sub: int = top_verts.size() - 1

	# Generate RGB texture from color array
	var span: int = colors_2d.size()
	var img: Image = Image.create(span, span, false, Image.FORMAT_RGBA8)
	for row in range(span):
		for col in range(span):
			var c: Color = colors_2d[row][col]
			img.set_pixel(col, row, c)
	var texture: ImageTexture = ImageTexture.create_from_image(img)

	# Build quad mesh (centroid fan, same winding as the solid path)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for k in range(bottom_sub):
		st.set_uv(Vector2(float(k) / bottom_sub, 0.0)); st.add_vertex(bottom_verts[k])
		st.set_uv(Vector2(float(k + 1) / bottom_sub, 0.0)); st.add_vertex(bottom_verts[k + 1])
		st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(centroid)
	st.set_uv(Vector2(1.0, 0.0)); st.add_vertex(bottom_verts[bottom_sub])
	st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(top_verts[top_sub])
	st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(centroid)
	for k in range(top_sub):
		st.set_uv(Vector2(float(k + 1) / top_sub, 1.0)); st.add_vertex(top_verts[k + 1])
		st.set_uv(Vector2(float(k) / top_sub, 1.0)); st.add_vertex(top_verts[k])
		st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(centroid)
	st.set_uv(Vector2(0.0, 1.0)); st.add_vertex(top_verts[0])
	st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(bottom_verts[0])
	st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(centroid)

	var mesh: ArrayMesh = st.commit()
	if not mesh:
		return null

	var scaled: ArrayMesh = _scale_array_mesh(mesh, 1.0 / 1000.0)

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
