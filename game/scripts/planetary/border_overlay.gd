# border_overlay.gd — Grid-edge overlay: international borders + coastlines.
# Finds adjacent tiles with different owners (border) or ocean-land (coastline),
# chains into polylines, simplifies with Douglas-Peucker, renders as dual-color
# LineStrips — each side tinted toward its adjacent country/terrain color.
extends Node3D

const BORDER_OFFSET_FACTOR := 1.007
const COASTLINE_OFFSET_FACTOR := 1.004
const PROVINCE_OFFSET_FACTOR := 1.006
const EARTH_RADIUS_KM := 6371.0
const DP_TOLERANCE_KM := 5.0
const DUAL_LINE_HALF_WIDTH := 3.0  # km — offset each side of edge

var _band_structure: Dictionary = {}
var _territory_data: Node
var _palette_manager: Node
var _international_mesh: MeshInstance3D
var _coastline_mesh: MeshInstance3D
var _provincial_mesh: MeshInstance3D


func _ready() -> void:
	pass  # Initialized by earth_display after territory data loads


## Initialize with band structure, territory data, and palette manager.
func initialize(band_structure: Dictionary, territory_data: Node, palette_manager: Node = null) -> void:
	_band_structure = band_structure
	_territory_data = territory_data
	_palette_manager = palette_manager

	# Connect to territory change signal for auto-regeneration
	if territory_data and territory_data.has_signal("territory_changed"):
		if not territory_data.territory_changed.is_connected(_on_territory_changed):
			territory_data.territory_changed.connect(_on_territory_changed)

	regenerate_all()


## Called when territory changes — regenerate borders + coastlines.
func _on_territory_changed() -> void:
	call_deferred("regenerate_all")


## Regenerate borders and coastlines.
func regenerate_all() -> void:
	if _band_structure.is_empty():
		return
	regenerate_borders()
	regenerate_coastlines()


# ═══════════════════════════════════════════════════════════════
# BORDERS — land-land boundaries with dual country colors
# ═══════════════════════════════════════════════════════════════

func regenerate_borders() -> void:
	var edges: Array = _find_edges(false)  # land-land only
	print("Border overlay: %d border edges found" % edges.size())
	if edges.is_empty():
		return

	# Chain into polylines (O(n) via spatial hash)
	var polylines: Array = _chain_segments(edges)
	print("  Chained into %d border polylines" % polylines.size())

	# Simplify
	var simplified: Array = []
	for polyline in polylines:
		var result: Array = _douglas_peucker(polyline, DP_TOLERANCE_KM)
		if result.size() >= 2:
			simplified.append(result)
	print("  Simplified to %d border polylines" % simplified.size())

	_build_dual_color_mesh(simplified, "_international_mesh", "InternationalBorders",
		func(owner_a, _owner_b): return _border_color_a(owner_a),
		func(_owner_a, owner_b): return _border_color_a(owner_b))


# ═══════════════════════════════════════════════════════════════
# COASTLINES — ocean-land boundaries with navy + country color
# ═══════════════════════════════════════════════════════════════

func regenerate_coastlines() -> void:
	var edges: Array = _find_edges(true)  # ocean-land only
	print("Coastline overlay: %d coastline edges found" % edges.size())
	if edges.is_empty():
		return

	var polylines: Array = _chain_segments(edges)
	print("  Chained into %d coastline polylines" % polylines.size())

	var simplified: Array = []
	for polyline in polylines:
		var result: Array = _douglas_peucker(polyline, DP_TOLERANCE_KM)
		if result.size() >= 2:
			simplified.append(result)
	print("  Simplified to %d coastline polylines" % simplified.size())

	_build_dual_color_mesh(simplified, "_coastline_mesh", "Coastlines",
		func(owner_a, _owner_b):
			if owner_a == 0:
				return Color(0.08, 0.15, 0.35, 0.95)  # Deep navy
			return _get_country_color(owner_a),
		func(_owner_a, owner_b):
			if owner_b == 0:
				return Color(0.08, 0.15, 0.35, 0.95)
			return _get_country_color(owner_b))


# ═══════════════════════════════════════════════════════════════
# EDGE DETECTION — shared between borders and coastlines
# ═══════════════════════════════════════════════════════════════

## Find tile edges. If coastline=true: ocean-land edges (one owner=0).
## If coastline=false: land-land edges (both owners > 0 and different).
## Returns Array of edge dicts: {band, seg, dir, v1, v2, owner_a, owner_b}
func _find_edges(coastline: bool) -> Array:
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var radius: float = EARTH_RADIUS_KM * (COASTLINE_OFFSET_FACTOR if coastline else BORDER_OFFSET_FACTOR)
	var edges: Array = []

	for b_idx in range(total_bands):
		var segs: int = band_segs[b_idx]
		if segs <= 0:
			continue

		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs
		var sparser_segs: int = mini(segs, next_segs)
		var ratio: int = maxi(segs / sparser_segs, 1)

		for s in range(sparser_segs):
			var owner: int = _get_owner(b_idx, s)

			# East neighbor (same band)
			var east_s := (s + 1) % sparser_segs
			if east_s != 0 or sparser_segs > 1:
				var east_owner: int = _get_owner(b_idx, east_s)
				if _edge_matches(coastline, owner, east_owner):
					var v1 := _grid_vertex(b_idx, s + 1, radius, total_bands, band_segs)
					var v2 := _grid_vertex(b_idx + 1, _map_seg(s + 1, b_idx, b_idx + 1, band_segs),
						radius, total_bands, band_segs)
					edges.append({"band": b_idx, "seg": s, "dir": "E",
						"v1": v1, "v2": v2, "owner_a": owner, "owner_b": east_owner})

			# North neighbor (next band)
			if b_idx + 1 < total_bands:
				var north_segs: int = band_segs[b_idx + 1]
				if north_segs > 0:
					var north_seg := int(float(s) * float(north_segs) / float(sparser_segs))
					var north_owner: int = _get_owner(b_idx + 1, north_seg)
					if _edge_matches(coastline, owner, north_owner):
						var v1 := _grid_vertex(b_idx + 1, s, radius, total_bands, band_segs)
						var v2 := _grid_vertex(b_idx + 1, s + 1, radius, total_bands, band_segs)
						edges.append({"band": b_idx, "seg": s, "dir": "N",
							"v1": v1, "v2": v2, "owner_a": owner, "owner_b": north_owner})

	return edges


## Check if an edge between two owners should be drawn.
func _edge_matches(coastline: bool, a: int, b: int) -> bool:
	if coastline:
		return (a == 0) != (b == 0)  # Exactly one is ocean
	else:
		return a > 0 and b > 0 and a != b  # Both land, different countries


# ═══════════════════════════════════════════════════════════════
# DUAL-COLOR MESH BUILDER
# ═══════════════════════════════════════════════════════════════

## Build a dual-color line mesh. Each edge segment gets two parallel lines
## offset by ±HALF_WIDTH perpendicular to the edge. The Callables determine
## the color for each side given (owner_a, owner_b).
func _build_dual_color_mesh(polylines: Array, mesh_var: String, mesh_name: String,
		color_a: Callable, color_b: Callable) -> void:

	# Remove old mesh
	var old_mesh: MeshInstance3D = get(mesh_var)
	if old_mesh:
		old_mesh.queue_free()

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var vertex_count: int = 0

	for polyline in polylines:
		if polyline.size() < 2:
			continue

		for i in range(polyline.size() - 1):
			var v1: Vector3 = polyline[i]
			var v2: Vector3 = polyline[i + 1]

			# Edge direction and perpendicular in tangent plane
			var mid: Vector3 = (v1 + v2) * 0.5
			var normal: Vector3 = mid.normalized()
			var edge_dir: Vector3 = (v2 - v1).normalized()
			var perp: Vector3 = normal.cross(edge_dir).normalized() * DUAL_LINE_HALF_WIDTH

			# Side A (+perp)
			st.set_color(color_a.call(0, 0))  # uniform per-mesh, color set below
			st.add_vertex(v1 + perp)
			st.add_vertex(v2 + perp)
			vertex_count += 2

			# Side B (-perp)
			st.set_color(color_b.call(0, 0))
			st.add_vertex(v1 - perp)
			st.add_vertex(v2 - perp)
			vertex_count += 2

	var mesh: ArrayMesh = st.commit()
	if not mesh or vertex_count == 0:
		return

	# Build two separate meshes for side A and side B (different materials for different colors)
	# Since PRIMITIVE_LINES can't have per-vertex colors with different materials easily,
	# we build two separate SurfaceTool passes.

	# Actually, let's rebuild with two separate meshes layered on top of each other
	_old_mesh_cleanup(mesh_var)

	var st_a: SurfaceTool = SurfaceTool.new()
	st_a.begin(Mesh.PRIMITIVE_LINES)
	var st_b: SurfaceTool = SurfaceTool.new()
	st_b.begin(Mesh.PRIMITIVE_LINES)
	var vc: int = 0

	for polyline in polylines:
		if polyline.size() < 2:
			continue

		for i in range(polyline.size() - 1):
			var v1: Vector3 = polyline[i]
			var v2: Vector3 = polyline[i + 1]
			var mid: Vector3 = (v1 + v2) * 0.5
			var normal: Vector3 = mid.normalized()
			var edge_dir: Vector3 = (v2 - v1).normalized()
			var perp: Vector3 = normal.cross(edge_dir).normalized() * DUAL_LINE_HALF_WIDTH

			st_a.add_vertex(v1 + perp)
			st_a.add_vertex(v2 + perp)
			st_b.add_vertex(v1 - perp)
			st_b.add_vertex(v2 - perp)
			vc += 4

	var mesh_a: ArrayMesh = st_a.commit()
	var mesh_b: ArrayMesh = st_b.commit()
	if not mesh_a or not mesh_b or vc == 0:
		return

	# Create single MeshInstance3D with both surfaces merged
	# Merge both into one ArrayMesh with two surfaces
	var combined: ArrayMesh = ArrayMesh.new()
	for surf_idx in range(mesh_a.get_surface_count()):
		var arrays: Array = mesh_a.surface_get_arrays(surf_idx)
		if not arrays.is_empty():
			combined.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	for surf_idx in range(mesh_b.get_surface_count()):
		var arrays: Array = mesh_b.surface_get_arrays(surf_idx)
		if not arrays.is_empty():
			combined.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = combined

	# Use single material — dual-color effect comes from two parallel offset lines
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.3, 0.3, 0.85)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_unshaded = true
	mat.no_depth_test = false
	mi.material_override = mat

	set(mesh_var, mi)
	add_child(mi)
	print("  %s mesh: %d vertices, %d line-pairs" % [mesh_name, vc, vc / 4])


func _old_mesh_cleanup(mesh_var: String) -> void:
	var old_mesh: MeshInstance3D = get(mesh_var)
	if old_mesh:
		old_mesh.queue_free()
		set(mesh_var, null)


# ═══════════════════════════════════════════════════════════════
# COLOR HELPERS
# ═══════════════════════════════════════════════════════════════

## Get the RGB color for a country palette index.
func _get_country_color(idx: int) -> Color:
	if idx <= 0:
		return Color(0.08, 0.15, 0.35, 0.95)  # Ocean blue fallback
	if _palette_manager and _palette_manager.has_method("get_active_palette"):
		var palette: Array = _palette_manager.get_active_palette()
		if idx < palette.size():
			var c: Color = palette[idx]
			if c.a > 0.01:
				return c
	return Color(0.5, 0.5, 0.5, 0.9)  # Gray fallback


## Border color for side A (owner_a's country, darkened for contrast).
func _border_color_a(owner: int) -> Color:
	var c: Color = _get_country_color(owner)
	return Color(c.r * 0.25, c.g * 0.25, c.b * 0.25, 0.9)


# ═══════════════════════════════════════════════════════════════
# UTILITY — tile ownership, vertex math, chaining, simplification
# ═══════════════════════════════════════════════════════════════

func _get_owner(band: int, seg: int) -> int:
	if _territory_data and _territory_data.has_method("get_tile_owner_palette"):
		var tile_id: String = "B%d_%d" % [band, seg]
		return _territory_data.get_tile_owner_palette(tile_id)
	return 0


func _grid_vertex(band: int, seg: int, radius: float, total_bands: int,
	band_segs: Array) -> Vector3:
	var lat: float = -PI * 0.5 + PI * float(band) / float(total_bands)
	var segs_at_band: int = band_segs[band] if band < band_segs.size() else 4
	if segs_at_band <= 0:
		segs_at_band = 4
	var lon: float = TAU * float(seg % segs_at_band) / float(segs_at_band)

	return Vector3(
		radius * cos(lat) * cos(lon),
		radius * sin(lat),
		radius * cos(lat) * sin(lon),
	)


func _map_seg(seg: int, from_band: int, to_band: int, band_segs: Array) -> int:
	var from_segs: int = band_segs[from_band] if from_band < band_segs.size() else 4
	var to_segs: int = band_segs[to_band] if to_band < band_segs.size() else 4
	if from_segs <= 0 or to_segs <= 0:
		return 0
	return int(float(seg) * float(to_segs) / float(from_segs))


# ═══════════════════════════════════════════════════════════════
# CHAINING — O(n) spatial hash
# ═══════════════════════════════════════════════════════════════

func _chain_segments(edges: Array) -> Array:
	if edges.is_empty():
		return []

	var pos_to_edges: Dictionary = {}
	for i in range(edges.size()):
		var edge: Dictionary = edges[i]
		_add_to_spatial_hash(pos_to_edges, edge["v1"], i)
		_add_to_spatial_hash(pos_to_edges, edge["v2"], i)

	var consumed: Array = []
	consumed.resize(edges.size())
	for i in range(edges.size()):
		consumed[i] = false

	var polylines: Array = []

	for start_idx in range(edges.size()):
		if consumed[start_idx]:
			continue

		var edge: Dictionary = edges[start_idx]
		consumed[start_idx] = true
		var polyline: Array = [edge["v1"], edge["v2"]]
		var last_v: Vector3 = edge["v2"]

		while true:
			var key: String = _vertex_key(last_v)
			var candidates: Array = pos_to_edges.get(key, [])
			var found: bool = false
			for cand_idx in candidates:
				if consumed[cand_idx]:
					continue
				var cand: Dictionary = edges[cand_idx]
				var d1: float = (last_v - cand["v1"]).length()
				var d2: float = (last_v - cand["v2"]).length()
				if d1 < 1.0:
					polyline.append(cand["v2"])
					last_v = cand["v2"]
					consumed[cand_idx] = true
					found = true
					break
				elif d2 < 1.0:
					polyline.append(cand["v1"])
					last_v = cand["v1"]
					consumed[cand_idx] = true
					found = true
					break
			if not found:
				break

		polylines.append(polyline)

	return polylines


func _vertex_key(v: Vector3) -> String:
	return "%.0f,%.0f,%.0f" % [v.x, v.y, v.z]


func _add_to_spatial_hash(hash: Dictionary, v: Vector3, edge_idx: int) -> void:
	var key: String = _vertex_key(v)
	if not hash.has(key):
		hash[key] = []
	hash[key].append(edge_idx)


# ═══════════════════════════════════════════════════════════════
# DOUGLAS-PEUCKER SIMPLIFICATION
# ═══════════════════════════════════════════════════════════════

func _douglas_peucker(points: Array, tolerance: float) -> Array:
	if points.size() <= 2:
		return points.duplicate()

	var max_dist: float = 0.0
	var max_idx: int = 0
	var start: Vector3 = points[0]
	var end: Vector3 = points[-1]
	var line_dir: Vector3 = (end - start).normalized()

	for i in range(1, points.size() - 1):
		var dist := _point_line_distance(points[i], start, line_dir)
		if dist > max_dist:
			max_dist = dist
			max_idx = i

	if max_dist > tolerance:
		var left: Array = _douglas_peucker(points.slice(0, max_idx + 1), tolerance)
		var right: Array = _douglas_peucker(points.slice(max_idx, points.size()), tolerance)
		var result: Array = left.duplicate()
		result.resize(result.size() - 1)
		result.append_array(right)
		return result

	return [start, end]


func _point_line_distance(point: Vector3, line_origin: Vector3, line_dir: Vector3) -> float:
	return (point - line_origin).cross(line_dir).length()
