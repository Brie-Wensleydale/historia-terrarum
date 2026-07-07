# SphericalGridGenerator.gd — Historia Terrarum
# Generates latitude/longitude wireframe + tint grid for spherical bodies.
# Adapted from Stella Nostra's grid system.
# Base cell: configurable (10km–100km) at equator, tapering toward poles.
# When cell width drops below half-base, adjacent cells merge
# (halved segment count). Merging repeats toward poles.
# Equator segments forced to multiple of 16 for clean halving chain.
#
# LOD System: the grid supports multiple resolution levels (Level 0 = finest).
# Each level doubles the cell size from the previous. The pyramid is used
# for culling and information condensation at different zoom distances.
class_name SphericalGridGenerator
extends RefCounted

const MIN_POLE_SEGS := 4           # Absolute minimum segments at pole cap
const POLE_CLAMP_SEGS := 4         # Clamp any band below this up to this

# ── Opacity states ──
const OPACITY_IDLE := 0.04
const OPACITY_HOVER := 0.22
const OPACITY_SELECTED := 0.28
const OPACITY_EASE_SPEED := 6.0

# ── LOD Level Definitions ──
# Level 0: base_cell_km (finest)
# Level 1: 2× base_cell_km
# Level 2: 4× base_cell_km
# Level 3: 8× base_cell_km
# Level 4: 16× base_cell_km
const LOD_MULTIPLIERS := [1, 2, 4, 8, 16]


## Compute band segment counts for a given resolution.
## Returns Dictionary with {total_bands, equator_segs, band_segs: Array[int], radius_km}
static func compute_band_structure(radius_km: float, base_cell_km: float) -> Dictionary:
	var radius_m: float = radius_km * 1000.0
	var cell_m: float = base_cell_km * 1000.0
	var merge_threshold_m: float = base_cell_km * 0.5 * 1000.0

	var equator_circumference: float = TAU * radius_m
	var raw_segs: int = maxi(int(round(equator_circumference / cell_m)), 16)
	var equator_segs: int = ((raw_segs + 8) / 16) * 16
	equator_segs = maxi(equator_segs, 16)

	var bands: int = maxi(int(round(PI * 0.5 * radius_m / cell_m)), 4)
	var total_bands: int = bands * 2
	var band_segs: Array[int] = []
	band_segs.resize(total_bands + 1)
	band_segs[bands] = equator_segs

	# Northward
	var current_segs: int = equator_segs
	for b in range(bands + 1, total_bands + 1):
		var lat: float = PI * 0.5 * float(b - bands) / float(bands)
		var ring_radius: float = radius_m * cos(lat)
		var cell_width: float = TAU * ring_radius / float(current_segs)
		while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
			current_segs = current_segs / 2
			cell_width = TAU * ring_radius / float(current_segs)
		band_segs[b] = current_segs

	# Southward
	current_segs = equator_segs
	for b in range(bands - 1, -1, -1):
		var lat: float = PI * 0.5 * float(bands - b) / float(bands)
		var ring_radius: float = radius_m * cos(lat)
		var cell_width: float = TAU * ring_radius / float(current_segs)
		while cell_width < merge_threshold_m and current_segs > MIN_POLE_SEGS and current_segs % 2 == 0:
			current_segs = current_segs / 2
			cell_width = TAU * ring_radius / float(current_segs)
		band_segs[b] = current_segs

	# Clamp poles
	for i in range(total_bands + 1):
		if band_segs[i] < POLE_CLAMP_SEGS:
			band_segs[i] = POLE_CLAMP_SEGS

	return {
		"total_bands": total_bands,
		"equator_segs": equator_segs,
		"band_segs": band_segs,
		"radius_km": radius_km,
		"base_cell_km": base_cell_km,
	}


## Count total tiles for a band structure
static func count_tiles(band_structure: Dictionary) -> int:
	var total: int = 0
	for segs in band_structure["band_segs"]:
		total += segs
	return total


## Generate wireframe grid mesh for a spherical body.
## Returns a MeshInstance3D positioned at origin.
static func generate(body_name: String, radius_km: float, body_color: Color, base_cell_km: float = 100.0) -> MeshInstance3D:
	var band_struct: Dictionary = compute_band_structure(radius_km, base_cell_km)
	var radius_m: float = radius_km * 1000.0
	var total_bands: int = band_struct["total_bands"]
	var band_segs: Array = band_struct["band_segs"]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)

	for b in range(total_bands):
		var segs_a: int = band_segs[b]
		var segs_b: int = band_segs[b + 1]
		if segs_a <= 0 or segs_b <= 0:
			continue

		var sparser_idx: int
		var denser_idx: int
		var sparser_segs: int
		var denser_segs: int
		if segs_a >= segs_b:
			sparser_idx = b + 1; denser_idx = b
			sparser_segs = segs_b; denser_segs = segs_a
		else:
			sparser_idx = b; denser_idx = b + 1
			sparser_segs = segs_a; denser_segs = segs_b

		var ratio: int = denser_segs / sparser_segs

		var lat_sparse: float = -PI * 0.5 + PI * float(sparser_idx) / float(total_bands)
		var lat_dense: float = -PI * 0.5 + PI * float(denser_idx) / float(total_bands)
		var r_sparse: float = radius_m * cos(lat_sparse)
		var r_dense: float = radius_m * cos(lat_dense)
		var y_sparse: float = radius_m * sin(lat_sparse)
		var y_dense: float = radius_m * sin(lat_dense)

		for s in range(sparser_segs):
			# Meridian
			var lon_sparse: float = TAU * float(s) / float(sparser_segs)
			var dense_start: int = s * ratio
			var lon_dense_start: float = TAU * float(dense_start) / float(denser_segs)

			st.add_vertex(Vector3(r_sparse * cos(lon_sparse), y_sparse, r_sparse * sin(lon_sparse)))
			st.add_vertex(Vector3(r_dense * cos(lon_dense_start), y_dense, r_dense * sin(lon_dense_start)))

			# Denser-band latitude edge
			var dense_end: int = (s + 1) * ratio
			var lon_dense_end: float = TAU * float(dense_end) / float(denser_segs)

			st.add_vertex(Vector3(r_dense * cos(lon_dense_start), y_dense, r_dense * sin(lon_dense_start)))
			st.add_vertex(Vector3(r_dense * cos(lon_dense_end), y_dense, r_dense * sin(lon_dense_end)))

			# Sparser-band latitude edge
			var lon_sparse_next: float = TAU * float(s + 1) / float(sparser_segs)
			st.add_vertex(Vector3(r_sparse * cos(lon_sparse), y_sparse, r_sparse * sin(lon_sparse)))
			st.add_vertex(Vector3(r_sparse * cos(lon_sparse_next), y_sparse, r_sparse * sin(lon_sparse_next)))

	# South pole
	var s_segs: int = band_segs[1]
	var s_lat: float = -PI * 0.5 + PI * 1.0 / float(total_bands)
	var s_r: float = radius_m * cos(s_lat)
	var s_y: float = radius_m * sin(s_lat)
	for i in range(s_segs):
		var a1: float = TAU * float(i) / float(s_segs)
		var a2: float = TAU * float(i + 1) / float(s_segs)
		st.add_vertex(Vector3(s_r * cos(a1), s_y, s_r * sin(a1)))
		st.add_vertex(Vector3(s_r * cos(a2), s_y, s_r * sin(a2)))
	var sp := Vector3(0, -radius_m, 0)
	for i in range(s_segs):
		var a: float = TAU * float(i) / float(s_segs)
		st.add_vertex(Vector3(s_r * cos(a), s_y, s_r * sin(a)))
		st.add_vertex(sp)

	# North pole
	var n_segs: int = band_segs[total_bands - 1]
	var n_lat: float = PI * 0.5 - PI * 1.0 / float(total_bands)
	var n_r: float = radius_m * cos(n_lat)
	var n_y: float = radius_m * sin(n_lat)
	for i in range(n_segs):
		var a1: float = TAU * float(i) / float(n_segs)
		var a2: float = TAU * float(i + 1) / float(n_segs)
		st.add_vertex(Vector3(n_r * cos(a1), n_y, n_r * sin(a1)))
		st.add_vertex(Vector3(n_r * cos(a2), n_y, n_r * sin(a2)))
	var np := Vector3(0, radius_m, 0)
	for i in range(n_segs):
		var a: float = TAU * float(i) / float(n_segs)
		st.add_vertex(Vector3(n_r * cos(a), n_y, n_r * sin(a)))
		st.add_vertex(np)

	var mesh: ArrayMesh = st.commit()
	if not mesh:
		return null

	var scaled_mesh: ArrayMesh = _scale_mesh(mesh, 1.0 / 1000.0)
	var offset_mesh: ArrayMesh = _scale_mesh(scaled_mesh, 1.005)

	var mi := MeshInstance3D.new()
	mi.name = "Grid_" + body_name
	mi.mesh = offset_mesh
	mi.visible = false
	mi.set_meta("grid_total_bands", total_bands)
	mi.set_meta("grid_band_segs", band_segs)
	mi.set_meta("grid_radius_km", radius_km)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(body_color.r, body_color.g, body_color.b, OPACITY_IDLE)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.flags_unshaded = true
	mat.vertex_color_use_as_albedo = false
	mi.material_override = mat

	return mi


## Ease grid opacity toward target
static func ease_opacity(mi: MeshInstance3D, target: float, delta: float) -> void:
	if not mi or not is_instance_valid(mi):
		return
	var mat: StandardMaterial3D = mi.material_override
	if not mat:
		return
	var current: float = mat.albedo_color.a
	var t: float = 1.0 - exp(-delta * OPACITY_EASE_SPEED)
	var new_a: float = lerpf(current, target, clampf(t, 0.0, 0.5))
	mat.albedo_color.a = new_a


## Find which grid cell contains a surface point.
## Returns Dictionary {transition: int, sparser_seg: int} or {} if not found.
static func find_cell_at_point(point: Vector3, radius_km: float, total_bands: int, band_segs: Array) -> Dictionary:
	if point.length() < 0.001:
		return {}
	var lat: float = asin(clampf(point.y / point.length(), -1.0, 1.0))
	var lon: float = atan2(point.z, point.x)
	if lon < 0.0:
		lon += TAU

	var lat_frac: float = (lat + PI * 0.5) / PI
	var trans_band: int = clampi(int(lat_frac * float(total_bands)), 0, total_bands - 1)

	var segs_lower: int = band_segs[trans_band] if trans_band < band_segs.size() else 8
	var segs_upper: int = band_segs[trans_band + 1] if trans_band + 1 < band_segs.size() else segs_lower
	var sparser_segs: int = segs_lower if segs_lower <= segs_upper else segs_upper
	var sparser_seg: int = int(lon / TAU * float(sparser_segs)) % sparser_segs

	return {"transition": trans_band, "sparser_seg": sparser_seg}


## Get the 3D corners of a grid cell for highlight rendering.
static func get_cell_corners(cell: Dictionary, radius_km: float, total_bands: int, band_segs: Array) -> PackedVector3Array:
	var transition: int = cell.get("transition", 0)
	var sparser_seg: int = cell.get("sparser_seg", 0)
	var radius_m: float = radius_km * 1000.0

	var segs_a: int = band_segs[transition] if transition < band_segs.size() else 8
	var segs_b: int = band_segs[transition + 1] if transition + 1 < band_segs.size() else segs_a

	var sparser_idx: int
	var denser_idx: int
	var sparser_segs: int
	var denser_segs: int
	if segs_a >= segs_b:
		sparser_idx = transition + 1; denser_idx = transition
		sparser_segs = segs_b; denser_segs = segs_a
	else:
		sparser_idx = transition; denser_idx = transition + 1
		sparser_segs = segs_a; denser_segs = segs_b

	var ratio: int = denser_segs / sparser_segs
	var lat_sparse: float = -PI * 0.5 + PI * float(sparser_idx) / float(total_bands)
	var lat_dense: float = -PI * 0.5 + PI * float(denser_idx) / float(total_bands)

	var points := PackedVector3Array()
	var scale: float = 1.0 / 1000.0 * 1.005

	var lon_s: float = TAU * float(sparser_seg) / float(sparser_segs)
	points.append(Vector3(radius_m * cos(lat_sparse) * cos(lon_s), radius_m * sin(lat_sparse), radius_m * cos(lat_sparse) * sin(lon_s)) * scale)

	var lon_s_next: float = TAU * float(sparser_seg + 1) / float(sparser_segs)
	points.append(Vector3(radius_m * cos(lat_sparse) * cos(lon_s_next), radius_m * sin(lat_sparse), radius_m * cos(lat_sparse) * sin(lon_s_next)) * scale)

	var dense_end: int = (sparser_seg + 1) * ratio
	var dense_start: int = sparser_seg * ratio
	for d in range(dense_end, dense_start - 1, -1):
		var lon_d: float = TAU * float(d) / float(denser_segs)
		points.append(Vector3(radius_m * cos(lat_dense) * cos(lon_d), radius_m * sin(lat_dense), radius_m * cos(lat_dense) * sin(lon_d)) * scale)

	return points


## Generate filled tint mesh with per-cell colors.
## tile_colors: Dictionary[String, Color] — tile ID "B{band}_{seg}" → Color.
static func generate_tint(body_name: String, radius_km: float, base_cell_km: float, tile_colors: Dictionary, band_segs: Dictionary) -> MeshInstance3D:
	var band_struct: Dictionary = compute_band_structure(radius_km, base_cell_km)
	var radius_m: float = radius_km * 1000.0
	var total_bands: int = band_struct["total_bands"]
	var full_band_segs: Array = band_struct["band_segs"]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var colored_cells: int = 0
	var skipped_cells: int = 0

	for b_idx in range(total_bands):
		var grid_segs: int = full_band_segs[b_idx]
		if grid_segs <= 0:
			continue

		var next_segs: int = full_band_segs[b_idx + 1] if b_idx + 1 < full_band_segs.size() else grid_segs
		var sparser_segs: int = mini(grid_segs, next_segs)
		var ratio: int = maxi(grid_segs / sparser_segs, 1)

		var lat_center: float = -PI * 0.5 + PI * float(b_idx) / float(total_bands)
		var bot_lat: float = lat_center
		var top_lat: float = -PI * 0.5 + PI * float(b_idx + 1) / float(total_bands)

		var r_bot: float = radius_m * cos(bot_lat)
		var r_top: float = radius_m * cos(top_lat)
		var y_bot: float = radius_m * sin(bot_lat)
		var y_top: float = radius_m * sin(top_lat)

		for s in range(grid_segs):
			var sparser_s: int = s / ratio
			var tile_id: String = "B%d_%d" % [b_idx, sparser_s]
			var color: Color = tile_colors.get(tile_id, Color.TRANSPARENT)
			if color.a < 0.01:
				skipped_cells += 1
				continue

			colored_cells += 1
			st.set_color(color)

			var lon_s: float = TAU * float(s) / float(grid_segs)
			var lon_s_next: float = TAU * float(s + 1) / float(grid_segs)

			var v_bl := Vector3(r_bot * cos(lon_s), y_bot, r_bot * sin(lon_s))
			var v_br := Vector3(r_bot * cos(lon_s_next), y_bot, r_bot * sin(lon_s_next))
			var v_tl := Vector3(r_top * cos(lon_s), y_top, r_top * sin(lon_s))
			var v_tr := Vector3(r_top * cos(lon_s_next), y_top, r_top * sin(lon_s_next))

			st.add_vertex(v_bl); st.add_vertex(v_br); st.add_vertex(v_tr)
			st.add_vertex(v_bl); st.add_vertex(v_tr); st.add_vertex(v_tl)

	print_verbose("Tint mesh: %d colored cells, %d skipped (ocean)" % [colored_cells, skipped_cells])

	var mesh: ArrayMesh = st.commit()
	if not mesh:
		return null

	var scaled_mesh: ArrayMesh = _scale_mesh(mesh, 1.0 / 1000.0)
	var offset_mesh: ArrayMesh = _scale_mesh(scaled_mesh, 1.003)

	var mi := MeshInstance3D.new()
	mi.name = "Tint_" + body_name
	mi.mesh = offset_mesh
	mi.visible = false

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.flags_unshaded = true
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.6)
	mi.material_override = mat

	return mi


static func _scale_mesh(mesh: ArrayMesh, factor: float) -> ArrayMesh:
	var scaled := ArrayMesh.new()
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
