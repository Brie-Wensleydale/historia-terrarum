# earth_display.gd — Earth body with texture, grid overlay, and territory tint.
# Creates the Earth sphere, applies the grid wireframe and tint mesh,
# and manages LOD selection via the chunk manager.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const BASE_CELL_KM := 10.0

var _earth_body: MeshInstance3D
var _grid_mesh: MeshInstance3D
var _tint_mesh: MeshInstance3D
var _chunk_manager: Node

func _ready() -> void:
	_setup_earth_body()


func _setup_earth_body() -> void:
	# Create a simple sphere for the Earth body
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 1.0
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 128
	sphere_mesh.rings = 64

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	# Apply Earth texture (placeholder)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.3, 0.6)  # Blue placeholder
	_earth_body.material_override = mat

	add_child(_earth_body)

	print("Earth body created. Radius: %.1f km" % EARTH_RADIUS_KM)
