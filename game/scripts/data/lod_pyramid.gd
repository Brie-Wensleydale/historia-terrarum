# lod_pyramid.gd — Multi-LOD Earth mesh manager.
# Generates coarser meshes from Level 0 territory data.
# Each quad at LOD 1+ is classified solid (vertex color) or textured (R8 palette texture).
extends Node

const NUM_LODS := 5
const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 100.0  # Test: 100km; Production: 10km

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

# Mesh instance per LOD level
var _lod_meshes: Array = []

# ShaderMaterial per LOD level
var _lod_materials: Array = []

# Classification: "%d_%d_%d" % [lod, band, seg] → "solid"|"textured"
var _quad_classifications: Dictionary = {}

# Dirty quads waiting for regeneration: Array[[lod, band, seg], ...]
var _dirty_quads: Array = []

# Current active LOD
var _active_lod: int = 0


func _ready() -> void:
	_lod_structures = SphericalGridGenerator.compute_all_lod_structures(
		EARTH_RADIUS_KM, BASE_CELL_KM
	)
	_lod_meshes.resize(NUM_LODS)
	_lod_materials.resize(NUM_LODS)
	_print_summary()


func _print_summary() -> void:
	print("LOD Pyramid Manager initialized:")
	for lod in range(NUM_LODS):
		var count := SphericalGridGenerator.get_lod_tile_count(lod, _lod_structures)
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
	var first_owner := -1

	for db in range(span):
		for ds in range(span):
			var band0 := qband * span + db
			var seg0 := qseg * span + ds
			var tile_id := "B%d_%d" % [band0, seg0]
			var owner := territory_data.get_tile_owner_palette(tile_id)
			if first_owner == -1:
				first_owner = owner
			elif owner != first_owner:
				return "textured"

	return "solid"


## Get the majority palette index for a solid quad (center tile's owner).
func get_solid_owner(lod: int, qband: int, qseg: int, territory_data: Node) -> int:
	if lod == 0:
		var tile_id := "B%d_%d" % [qband, qseg]
		return territory_data.get_tile_owner_palette(tile_id)

	var span := 1 << lod
	# Sample center of the quad
	var center_band := qband * span + (span / 2)
	var center_seg := qseg * span + (span / 2)
	var tile_id := "B%d_%d" % [center_band, center_seg]
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


## Update visibility: show active LOD mesh, hide others.
func update_visibility(active_lod: int) -> void:
	if active_lod == _active_lod:
		return

	_active_lod = active_lod
	for lod in range(NUM_LODS):
		if lod < _lod_meshes.size() and _lod_meshes[lod]:
			_lod_meshes[lod].visible = (lod == _active_lod)


## Get classification stats for all quads at a LOD level.
func get_classification_stats(lod: int, territory_data: Node) -> Dictionary:
	if lod <= 0:
		return {"solid": 0, "textured": 0}

	var bs: Dictionary = _lod_structures[lod]
	var band_segs: Array = bs["band_segs"]
	var total_bands: int = bs["total_bands"]
	var solid := 0
	var textured := 0

	for b_idx in range(total_bands - 1):
		var segs_a: int = band_segs[b_idx]
		var segs_b: int = band_segs[b_idx + 1]
		if segs_a <= 0 or segs_b <= 0:
			continue
		var sparser_segs: int = mini(segs_a, segs_b)
		for s in range(sparser_segs):
			var cls := classify_quad(lod, b_idx, s, territory_data)
			var key := "%d_%d_%d" % [lod, b_idx, s]
			_quad_classifications[key] = cls
			if cls == "solid":
				solid += 1
			else:
				textured += 1

	return {"solid": solid, "textured": textured}
