# border_overlay.gd — Dynamic political border LineStrip renderer.
# Finds adjacent tiles with different owners, traces boundary polylines,
# simplifies with Douglas-Peucker, and renders as LineStrips.
extends Node3D

const BORDER_OFFSET_FACTOR := 1.007
const PROVINCE_OFFSET_FACTOR := 1.006
const EARTH_RADIUS_KM := 6371.0
const DP_TOLERANCE_KM := 5.0  # Douglas-Peucker simplification tolerance (km)

var _band_structure: Dictionary = {}
var _territory_data: Node
var _international_mesh: MeshInstance3D
var _provincial_mesh: MeshInstance3D


func _ready() -> void:
	pass  # Initialized by earth_display after territory data loads


## Initialize with band structure and territory data, then generate borders.
func initialize(band_structure: Dictionary, territory_data: Node) -> void:
	_band_structure = band_structure
	_territory_data = territory_data

	# Connect to territory change signal for auto-regeneration
	if territory_data and territory_data.has_signal("territory_changed"):
		if not territory_data.territory_changed.is_connected(_on_territory_changed):
			territory_data.territory_changed.connect(_on_territory_changed)

	regenerate_borders()


## Called when territory changes — regenerate borders.
func _on_territory_changed() -> void:
	call_deferred("regenerate_borders")


## Regenerate all border meshes. Called on territory change.
func regenerate_borders() -> void:
	if _band_structure.is_empty():
		return

	# Find all border edges
	var border_edges: Array = _find_border_edges()
	print("Border overlay: %d border edges found" % border_edges.size())

	# Chain into polylines
	var polylines: Array = _chain_segments(border_edges)
	print("  Chained into %d polylines" % polylines.size())

	# Simplify
	var simplified: Array = []
	for polyline in polylines:
		var result: Array = _douglas_peucker(polyline, DP_TOLERANCE_KM)
		if result.size() >= 2:
			simplified.append(result)

	print("  Simplified to %d polylines (%.1f km tolerance)" % [
		simplified.size(), DP_TOLERANCE_KM,
	])

	# Build mesh
	_build_border_mesh(simplified)


## Find all tile edges where adjacent tiles have different owners.
## Returns Array of edge dicts: {band, seg, dir, vertex1, vertex2}
func _find_border_edges() -> Array:
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var radius: float = EARTH_RADIUS_KM * BORDER_OFFSET_FACTOR
	var edges: Array = []

	for b_idx in range(total_bands):
		var segs: int = band_segs[b_idx]
		if segs <= 0:
			continue

		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs
		var sparser_segs: int = mini(segs, next_segs)
		var ratio: int = maxi(segs / sparser_segs, 1)

		for s in range(sparser_segs):
			var owner: int = _get_owner(b_idx, s, band_segs, total_bands)

			# East neighbor (same band)
			var east_s := (s + 1) % sparser_segs
			if east_s != 0 or sparser_segs > 1:  # Avoid wrap-around at full circle
				var east_owner: int = _get_owner(b_idx, east_s, band_segs, total_bands)
				if owner > 0 and east_owner > 0 and owner != east_owner:
					var v1 := _grid_vertex(b_idx, s + 1, radius, total_bands, band_segs, true)
					var v2 := _grid_vertex(b_idx + 1, _map_seg(s + 1, b_idx, b_idx + 1, band_segs),
						radius, total_bands, band_segs, false)
					edges.append({"band": b_idx, "seg": s, "dir": "E",
						"v1": v1, "v2": v2, "owner_a": owner, "owner_b": east_owner})

			# North neighbor (next band)
			if b_idx + 1 < total_bands:
				var north_segs: int = band_segs[b_idx + 1]
				if north_segs > 0:
					var north_seg := int(float(s) * float(north_segs) / float(sparser_segs))
					var north_owner: int = _get_owner(b_idx + 1, north_seg, band_segs, total_bands)
					if owner > 0 and north_owner > 0 and owner != north_owner:
						var v1 := _grid_vertex(b_idx + 1, s, radius, total_bands, band_segs, true)
						var v2 := _grid_vertex(b_idx + 1, s + 1, radius, total_bands, band_segs, true)
						edges.append({"band": b_idx, "seg": s, "dir": "N",
							"v1": v1, "v2": v2, "owner_a": owner, "owner_b": north_owner})

	return edges


## Get the palette index for a tile at (band, seg).
func _get_owner(band: int, seg: int, band_segs: Array, total_bands: int) -> int:
	if _territory_data and _territory_data.has_method("get_tile_owner_palette"):
		var tile_id: String = "B%d_%d" % [band, seg]
		return _territory_data.get_tile_owner_palette(tile_id)
	return 0


## Compute 3D position of a grid vertex at (band, seg).
func _grid_vertex(band: int, seg: int, radius: float, total_bands: int,
	band_segs: Array, is_sparser: bool) -> Vector3:
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


## Chain unordered edge segments into continuous polylines.
## Simple greedy algorithm: pick a segment, find next that connects, repeat.
func _chain_segments(edges: Array) -> Array:
	if edges.is_empty():
		return []

	var remaining: Array = edges.duplicate()
	var polylines: Array = []

	while not remaining.is_empty():
		# Start a new polyline
		var current: Variant = remaining.pop_front()
		var polyline: Array = [current["v1"], current["v2"]]
		var last_v: Vector3 = current["v2"]

		# Extend forward
		var extended: bool = true
		while extended and not remaining.is_empty():
			extended = false
			for i in range(remaining.size() - 1, -1, -1):
				var edge: Dictionary = remaining[i]
				var dist_start: float = (last_v - edge["v1"]).length()
				var dist_end: float = (last_v - edge["v2"]).length()

				if dist_start < 1.0:  # Within 1 km tolerance
					polyline.append(edge["v2"])
					last_v = edge["v2"]
					remaining.remove_at(i)
					extended = true
					break
				elif dist_end < 1.0:
					polyline.append(edge["v1"])
					last_v = edge["v1"]
					remaining.remove_at(i)
					extended = true
					break

		polylines.append(polyline)

	return polylines


## Douglas-Peucker simplification.
## Simplifies a polyline to within tolerance of the original.
func _douglas_peucker(points: Array, tolerance: float) -> Array:
	if points.size() <= 2:
		return points.duplicate()

	# Find point farthest from line between endpoints
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
		# Merge avoiding duplicate at split point
		var result: Array = left.duplicate()
		result.resize(result.size() - 1)
		result.append_array(right)
		return result

	return [start, end]


## Distance from point to infinite line defined by origin + direction.
func _point_line_distance(point: Vector3, line_origin: Vector3, line_dir: Vector3) -> float:
	return (point - line_origin).cross(line_dir).length()


## Build LineStrip mesh from simplified polylines and add to scene.
func _build_border_mesh(polylines: Array) -> void:
	# Remove old mesh
	if _international_mesh:
		_international_mesh.queue_free()

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var vertex_count: int = 0

	for polyline in polylines:
		if polyline.size() < 2:
			continue

		for i in range(polyline.size() - 1):
			st.add_vertex(polyline[i])
			st.add_vertex(polyline[i + 1])
			vertex_count += 2

	var mesh: ArrayMesh = st.commit()
	if not mesh or vertex_count == 0:
		return

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "InternationalBorders"
	mi.mesh = mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.15, 0.9)  # Dark border lines
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_unshaded = true
	mat.no_depth_test = true
	mi.material_override = mat

	_international_mesh = mi
	add_child(mi)

	print("  Border mesh: %d vertices, %d lines" % [vertex_count, vertex_count / 2])
