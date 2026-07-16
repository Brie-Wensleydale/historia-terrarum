# edge_overlay.gd — Unified grid-edge overlay: borders + coastlines.
# All edges derived from the same grid LOD. Replaces old separate
# border_overlay.gd and coastline_overlay.gd (Natural Earth vectors).
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const BORDER_RADIUS := 1.007
const COASTLINE_RADIUS := 1.004
const DP_TOLERANCE_KM := 5.0

var _band_structure: Dictionary = {}
var _territory_data: Node
var _border_mesh: MeshInstance3D
var _coastline_mesh: MeshInstance3D


func _ready() -> void:
	pass


func initialize(band_structure: Dictionary, territory_data: Node) -> void:
	_band_structure = band_structure
	_territory_data = territory_data
	if territory_data and territory_data.has_signal("territory_changed"):
		if not territory_data.territory_changed.is_connected(_on_territory_changed):
			territory_data.territory_changed.connect(_on_territory_changed)
	regenerate_all()


func _on_territory_changed() -> void:
	call_deferred("regenerate_all")


func regenerate_all() -> void:
	if _band_structure.is_empty():
		return
	regenerate_borders()
	regenerate_coastlines()


# ═══════════════════════════ BORDERS ═══════════════════════════

func regenerate_borders() -> void:
	var edges: Array = _find_edges(false)
	print("Borders: %d edges" % edges.size())
	var chains: Array = _chain_and_simplify(edges)
	_replace_mesh("_border_mesh", "Borders", chains,
		Color(0.15, 0.15, 0.15, 0.9), BORDER_RADIUS)


# ═══════════════════════════ COASTLINES ═══════════════════════

func regenerate_coastlines() -> void:
	var edges: Array = _find_edges(true)
	print("Coastlines: %d edges" % edges.size())
	var chains: Array = _chain_and_simplify(edges)
	_replace_mesh("_coastline_mesh", "Coastlines", chains,
		Color(0.08, 0.15, 0.35, 0.95), COASTLINE_RADIUS)


# ═══════════════════════════ EDGE DETECTION ═══════════════════

## coastline=true: ocean-land edges. coastline=false: land-land borders.
func _find_edges(coastline: bool) -> Array:
	var band_segs: Array = _band_structure["band_segs"]
	var total_bands: int = _band_structure["total_bands"]
	var radius: float = EARTH_RADIUS_KM * (COASTLINE_RADIUS if coastline else BORDER_RADIUS)
	var edges: Array = []

	for b_idx in range(total_bands):
		var segs: int = band_segs[b_idx]
		if segs <= 0:
			continue
		var next_segs: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs
		var sparser_segs: int = mini(segs, next_segs)

		for s in range(sparser_segs):
			var owner: int = _get_owner(b_idx, s)

			# East neighbor
			var east_s := (s + 1) % sparser_segs
			if east_s != 0 or sparser_segs > 1:
				var east_owner: int = _get_owner(b_idx, east_s)
				if _match(coastline, owner, east_owner):
					var v1 := _vertex(b_idx, s + 1, radius, total_bands, band_segs)
					var v2 := _vertex(b_idx + 1, _map_seg(s + 1, b_idx, b_idx + 1, band_segs),
						radius, total_bands, band_segs)
					edges.append({"v1": v1, "v2": v2})

			# North neighbor
			if b_idx + 1 < total_bands:
				var north_segs: int = band_segs[b_idx + 1]
				if north_segs > 0:
					var north_seg := int(float(s) * float(north_segs) / float(sparser_segs))
					var north_owner: int = _get_owner(b_idx + 1, north_seg)
					if _match(coastline, owner, north_owner):
						var v1 := _vertex(b_idx + 1, s, radius, total_bands, band_segs)
						var v2 := _vertex(b_idx + 1, s + 1, radius, total_bands, band_segs)
						edges.append({"v1": v1, "v2": v2})

	return edges


func _match(coastline: bool, a: int, b: int) -> bool:
	if coastline:
		return (a == 0) != (b == 0)   # exactly one is ocean
	return a > 0 and b > 0 and a != b  # both land, different owners


# ═══════════════════════ CHAIN + SIMPLIFY ═════════════════════

func _chain_and_simplify(edges: Array) -> Array:
	var chains: Array = _chain_segments(edges)
	var simplified: Array = []
	for chain in chains:
		var result: Array = _douglas_peucker(chain, DP_TOLERANCE_KM)
		if result.size() >= 2:
			simplified.append(result)
	return simplified


# ═══════════════════════ MESH BUILDER ═════════════════════════

func _replace_mesh(mesh_var: String, name: String, chains: Array, color: Color, _radius_factor: float) -> void:
	var old: MeshInstance3D = get(mesh_var)
	if old:
		old.queue_free()

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var vc: int = 0

	for chain in chains:
		for i in range(chain.size() - 1):
			st.add_vertex(chain[i])
			st.add_vertex(chain[i + 1])
			vc += 2

	var mesh: ArrayMesh = st.commit()
	if not mesh or vc == 0:
		return

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.flags_unshaded = true
	mat.no_depth_test = false
	mi.material_override = mat

	set(mesh_var, mi)
	add_child(mi)
	print("  %s: %d line-segments" % [name, vc / 2])


# ═══════════════════════════ UTILITIES ════════════════════════

func _get_owner(band: int, seg: int) -> int:
	if _territory_data and _territory_data.has_method("get_tile_owner_palette"):
		return _territory_data.get_tile_owner_palette("B%d_%d" % [band, seg])
	return 0


func _vertex(band: int, seg: int, radius: float, total_bands: int, band_segs: Array) -> Vector3:
	var lat: float = -PI * 0.5 + PI * float(band) / float(total_bands)
	var segs_at_band: int = band_segs[band] if band < band_segs.size() else 4
	if segs_at_band <= 0:
		segs_at_band = 4
	var lon: float = TAU * float(seg % segs_at_band) / float(segs_at_band)
	return Vector3(radius * cos(lat) * cos(lon), radius * sin(lat), radius * cos(lat) * sin(lon))


func _map_seg(seg: int, from_band: int, to_band: int, band_segs: Array) -> int:
	var from_segs: int = band_segs[from_band] if from_band < band_segs.size() else 4
	var to_segs: int = band_segs[to_band] if to_band < band_segs.size() else 4
	if from_segs <= 0 or to_segs <= 0:
		return 0
	return int(float(seg) * float(to_segs) / float(from_segs))


# ═══════════════════ SPATIAL HASH CHAINING ════════════════════

func _chain_segments(edges: Array) -> Array:
	if edges.is_empty():
		return []
	var pos_to_edges: Dictionary = {}
	for i in range(edges.size()):
		var e: Dictionary = edges[i]
		_add_to_hash(pos_to_edges, e["v1"], i)
		_add_to_hash(pos_to_edges, e["v2"], i)

	var consumed: Array = []; consumed.resize(edges.size())
	for i in range(edges.size()): consumed[i] = false

	var chains: Array = []
	for start_idx in range(edges.size()):
		if consumed[start_idx]: continue
		var e: Dictionary = edges[start_idx]; consumed[start_idx] = true
		var chain: Array = [e["v1"], e["v2"]]
		var last: Vector3 = e["v2"]
		while true:
			var candidates: Array = pos_to_edges.get(_vkey(last), [])
			var found := false
			for ci in candidates:
				if consumed[ci]: continue
				var c: Dictionary = edges[ci]
				if (last - c["v1"]).length() < 1.0:
					chain.append(c["v2"]); last = c["v2"]; consumed[ci] = true; found = true; break
				elif (last - c["v2"]).length() < 1.0:
					chain.append(c["v1"]); last = c["v1"]; consumed[ci] = true; found = true; break
			if not found: break
		chains.append(chain)
	return chains


func _vkey(v: Vector3) -> String:
	return "%.0f,%.0f,%.0f" % [v.x, v.y, v.z]


func _add_to_hash(h: Dictionary, v: Vector3, idx: int) -> void:
	var k: String = _vkey(v)
	if not h.has(k): h[k] = []
	h[k].append(idx)


# ═══════════════════ DOUGLAS-PEUCKER ═════════════════════════

func _douglas_peucker(points: Array, tolerance: float) -> Array:
	if points.size() <= 2:
		return points.duplicate()
	var max_d := 0.0; var max_i := 0
	var s: Vector3 = points[0]; var e: Vector3 = points[-1]
	var dir: Vector3 = (e - s).normalized()
	for i in range(1, points.size() - 1):
		var d := (points[i] - s).cross(dir).length()
		if d > max_d: max_d = d; max_i = i
	if max_d > tolerance:
		var left: Array = _douglas_peucker(points.slice(0, max_i + 1), tolerance)
		var right: Array = _douglas_peucker(points.slice(max_i, points.size()), tolerance)
		var r: Array = left.duplicate(); r.resize(r.size() - 1); r.append_array(right)
		return r
	return [s, e]
