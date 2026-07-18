# earth_chunk_manager.gd — Geographic chunk partitioning and LOD selection.
# Divides the Earth into lat/lon chunks, each with its own mesh at the active LOD.
# Handles frustum culling, horizon culling, and LOD transitions.
class_name EarthChunkManager
extends Node3D

# Chunk grid: N chunks in longitude, M in latitude
const CHUNKS_LON := 18
const CHUNKS_LAT := 9

# LOD thresholds (in multiples of Earth radius)
const LOD_THRESHOLDS := {
	0: 1.5,   # 10km cells — zoomed close
	1: 3.0,   # 20km cells
	2: 5.0,   # 40km cells
	3: 8.0,   # 80km cells
	4: 999.0, # 160km cells — always
}

var _chunks: Array = []
var _earth_radius_km: float = 6371.0


func _ready() -> void:
	_create_chunks()


func _create_chunks() -> void:
	for lat_idx in range(CHUNKS_LAT):
		for lon_idx in range(CHUNKS_LON):
			var chunk: Node3D = _create_chunk(lat_idx, lon_idx)
			_chunks.append(chunk)
			add_child(chunk)

	print("Created %d chunks (%d×%d)" % [_chunks.size(), CHUNKS_LON, CHUNKS_LAT])


func _create_chunk(lat_idx: int, lon_idx: int) -> Node3D:
	var chunk: Node3D = Node3D.new()
	chunk.name = "Chunk_%d_%d" % [lat_idx, lon_idx]

	# Bounding box for culling
	var lat_min: float = -90.0 + 180.0 * lat_idx / CHUNKS_LAT
	var lat_max: float = -90.0 + 180.0 * (lat_idx + 1) / CHUNKS_LAT
	var lon_min: float = -180.0 + 360.0 * lon_idx / CHUNKS_LON
	var lon_max: float = -180.0 + 360.0 * (lon_idx + 1) / CHUNKS_LON

	chunk.set_meta("lat_range", Vector2(lat_min, lat_max))
	chunk.set_meta("lon_range", Vector2(lon_min, lon_max))

	return chunk


func select_lod(distance_to_chunk: float, earth_radius: float) -> int:
	var ratio: float = distance_to_chunk / earth_radius
	for lod in range(5):
		if ratio < LOD_THRESHOLDS[lod]:
			return lod
	return 4
