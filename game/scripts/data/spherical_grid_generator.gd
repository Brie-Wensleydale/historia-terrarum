# spherical_grid_generator.gd — Historia Terrarum 2
# Deterministic spherical grid: 4096 equator segments, 2048 total bands.
# Halving toward poles at <5km cell width. Ends with 8 triangular cells at each pole.
# Watertight tint mesh via canonical ring vertices + fan triangulation.
class_name SphericalGridGenerator
extends RefCounted

# ── Grid Constants ──
const EQUATOR_SEGS := 4096
const TOTAL_BANDS := 2048
const MIN_POLE_SEGS := 8
const EARTH_RADIUS_KM := 6371.0
const CELL_KM := 10.0  # approximate; exact is 9.77 km at equator

# ── Tint rendering ──
const TINT_RADIUS_FACTOR := 1.003  # offset above Earth surface to prevent z-fighting


## Compute deterministic band structure with fixed 4096 equator / 2048 bands.
## Halving: when cell_width < 5 km (half of CELL_KM), halve segment count.
## Halving repeats until 8 segments at the pole.
## Returns Dictionary: {total_bands, equator_segs, band_segs, radius_km, cell_km}
static func compute_band_structure(
	radius_km: float = EARTH_RADIUS_KM,
	cell_km: float = CELL_KM,
	equator_segs: int = EQUATOR_SEGS,
	total_bands: int = TOTAL_BANDS,
	min_segs: int = MIN_POLE_SEGS
) -> Dictionary:
	var radius_m: float = radius_km * 1000.0
	var half_cell_m: float = cell_km * 0.5 * 1000.0  # 5 km threshold
	var eq_band: int = total_bands / 2  # 1024

	var band_segs: Array[int] = []
	band_segs.resize(total_bands + 1)
	band_segs[eq_band] = equator_segs

	# Northward: equator → north pole
	var current_segs: int = equator_segs
	for b in range(eq_band + 1, total_bands + 1):
		var lat: float = -PI * 0.5 + PI * float(b) / float(total_bands)
		var ring_radius: float = radius_m * cos(lat)
		var cell_width: float = TAU * ring_radius / float(current_segs)
		while cell_width < half_cell_m and current_segs > min_segs and current_segs % 2 == 0:
			current_segs /= 2
			cell_width = TAU * ring_radius / float(current_segs)
		band_segs[b] = current_segs

	# Southward: equator → south pole
	current_segs = equator_segs
	for b in range(eq_band - 1, -1, -1):
		var lat: float = -PI * 0.5 + PI * float(b) / float(total_bands)
		var ring_radius: float = radius_m * cos(lat)
		var cell_width: float = TAU * ring_radius / float(current_segs)
		while cell_width < half_cell_m and current_segs > min_segs and current_segs % 2 == 0:
			current_segs /= 2
			cell_width = TAU * ring_radius / float(current_segs)
		band_segs[b] = current_segs

	return {
		"total_bands": total_bands,
		"equator_segs": equator_segs,
		"band_segs": band_segs,
		"radius_km": radius_km,
		"cell_km": cell_km,
	}


## Count total tiles for a band structure.
static func count_tiles(band_structure: Dictionary) -> int:
	var total: int = 0
	for segs in band_structure["band_segs"]:
		total += segs
	return total


## Convert a global 3D point on the sphere surface to cell coordinates.
## Returns Dictionary {band: int, seg: int, cell_seg: int} or {} if not on surface.
static func find_cell_at_point(
	point: Vector3,
	radius_km: float,
	total_bands: int,
	band_segs: Array
) -> Dictionary:
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
	var cell_segs: int = maxi(segs_lower, segs_upper)
	var cell_seg: int = int(lon / TAU * float(cell_segs)) % cell_segs

	return {"band": trans_band, "cell_seg": cell_seg, "total_segs": cell_segs}


## Generate tint mesh with per-cell colors.
## tile_colors: Dictionary[String, Color] — tile ID "B{band}_{seg}" → Color.
## Only generates cells with non-transparent colors (land cells).
## Uses canonical ring vertices + fan triangulation for watertightness.
## Optional band_start/band_end: only process bands in [start, end) — use for viewport culling.
##
## TIER 1 OPTIMIZED: vertices computed directly at target scale (km×TINT_RADIUS_FACTOR),
## batched ArrayMesh build (no SurfaceTool per-vertex overhead), no _scale_mesh copies.
## Coordinates: ring vertices computed directly at display scale.
static func generate_tint(
	radius_km: float,
	band_struct: Dictionary,
	tile_colors: Dictionary,
	band_start: int = -1,
	band_end: int = -1
) -> MeshInstance3D:
	var display_radius: float = radius_km * TINT_RADIUS_FACTOR  # compute directly at target scale
	var total_bands: int = band_struct["total_bands"]
	var full_band_segs: Array = band_struct["band_segs"]

	# Determine band range
	var b_start: int = band_start if band_start >= 0 else 0
	var b_end: int = band_end if band_end >= 0 else total_bands
	b_start = clampi(b_start, 0, total_bands - 1)
	b_end = clampi(b_end, 1, total_bands)

	# Precompute ring vertices only for the needed range (+1 for the top ring of b_end-1)
	# Vertices in display-km directly at TINT_RADIUS_FACTOR — no scaling pass needed.
	var ring_verts: Array = []
	var ring_is_pole: Array = []
	for ring_idx in range(b_start, b_end + 1):
		var ring_segs: int = full_band_segs[ring_idx]
		var ring_lat: float = -PI * 0.5 + PI * float(ring_idx) / float(total_bands)
		var ring_r: float = display_radius * cos(ring_lat)
		var ring_y: float = display_radius * sin(ring_lat)
		var verts: PackedVector3Array = PackedVector3Array()
		if absf(ring_r) < 1.0 / 1000.0:  # ~1 meter threshold at display scale
			verts.append(Vector3(0.0, ring_y, 0.0))
			ring_is_pole.append(true)
		else:
			verts.resize(ring_segs)
			for k in range(ring_segs):
				var ring_lon: float = TAU * float(k) / float(ring_segs)
				verts[k] = Vector3(ring_r * cos(ring_lon), ring_y, ring_r * sin(ring_lon))
			ring_is_pole.append(false)
		ring_verts.append(verts)

	# ── Batched ArrayMesh build (Tier 1b) ──
	# Build vertex + index arrays in one pass, then feed to SurfaceTool all at once.
	var all_verts: PackedVector3Array = PackedVector3Array()
	var all_colors: PackedColorArray = PackedColorArray()
	var all_indices: PackedInt32Array = PackedInt32Array()

	var colored_cells: int = 0
	var skipped_cells: int = 0

	for b_idx in range(b_start, b_end):
		var segs_bot: int = full_band_segs[b_idx]
		var segs_top: int = full_band_segs[b_idx + 1]
		if segs_bot <= 0 or segs_top <= 0:
			continue

		var cell_segs: int = maxi(segs_bot, segs_top)
		var bot_verts: PackedVector3Array = ring_verts[b_idx - b_start]
		var top_verts: PackedVector3Array = ring_verts[b_idx + 1 - b_start]
		var bot_pole: bool = ring_is_pole[b_idx - b_start]
		var top_pole: bool = ring_is_pole[b_idx + 1 - b_start]

		for t in range(cell_segs):
			var tile_id: String = "B%d_%d" % [b_idx, t]
			var color: Color = tile_colors.get(tile_id, Color.TRANSPARENT)
			if color.a < 0.01:
				skipped_cells += 1
				continue

			colored_cells += 1

			var poly: Array[Vector3] = []
			if bot_pole:
				poly.append(bot_verts[0])
			else:
				var db0: int = t * segs_bot / cell_segs
				var db1: int = (t + 1) * segs_bot / cell_segs
				if db0 == db1:
					poly.append(bot_verts[db0 % segs_bot])
				else:
					for k in range(db0, db1 + 1):
						poly.append(bot_verts[k % segs_bot])
			if top_pole:
				poly.append(top_verts[0])
			else:
				var dt0: int = t * segs_top / cell_segs
				var dt1: int = (t + 1) * segs_top / cell_segs
				if dt0 == dt1:
					poly.append(top_verts[dt0 % segs_top])
				else:
					for k in range(dt1, dt0 - 1, -1):
						poly.append(top_verts[k % segs_top])

			# Fan triangulation: first vertex is anchor, rest form triangle fan
			var base_idx: int = all_verts.size()
			for v in poly:
				all_verts.append(v)
				all_colors.append(color)

			var poly_count: int = poly.size()
			for i in range(1, poly_count - 1):
				all_indices.append(base_idx)
				all_indices.append(base_idx + i)
				all_indices.append(base_idx + i + 1)

	print_verbose("Tint mesh: %d colored cells, %d skipped (ocean) [bands %d-%d]" % [colored_cells, skipped_cells, b_start, b_end - 1])

	if all_verts.is_empty():
		return null

	# Feed batched arrays to SurfaceTool
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_vertices(all_verts)
	st.set_colors(all_colors)
	st.set_indices(all_indices)
	var mesh: ArrayMesh = st.commit()
	if not mesh:
		return null

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "Tint_Earth"
	mi.mesh = mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.flags_unshaded = true
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mi.material_override = mat

	return mi

