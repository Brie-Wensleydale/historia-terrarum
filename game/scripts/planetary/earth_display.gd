# earth_display.gd — HT2: chunk-based cell mesh with viewport culling
# Creates the Earth sphere, loads land mask, and renders visible cells
# based on the camera's sub-point on the sphere.
# TIER 2: Discrete chunk cache (64×256 base cells per chunk) — same grid as LOD.
extends Node3D

const EARTH_RADIUS_KM := 6371.0
const CELL_KM := 10.0
const REBUILD_FRAME_INTERVAL := 3
const LAND_COLOR := Color(0.2, 0.7, 0.3, 1.0)
const OCEAN_COLOR := Color(0.1, 0.3, 0.6, 1.0)
const POOL_SIZE := 2
const MAX_CACHED_CHUNKS := 128

# Climate palette — 31 entries (index 0 = ocean/unclassified, 1-30 = Köppen)
const CLIMATE_COLORS := [
	Color(0.1, 0.3, 0.6, 1.0),   # 0: ocean/unclassified
	Color(0.0, 0.4, 1.0, 1.0),   # 1: Af  Tropical rainforest
	Color(0.0, 0.5, 0.8, 1.0),   # 2: Am  Tropical monsoon
	Color(0.3, 0.6, 0.4, 1.0),   # 3: Aw  Tropical savanna
	Color(1.0, 0.2, 0.2, 1.0),   # 4: BWh Hot desert
	Color(0.9, 0.5, 0.3, 1.0),   # 5: BWk Cold desert
	Color(1.0, 0.7, 0.2, 1.0),   # 6: BSh Hot semi-arid
	Color(0.9, 0.8, 0.4, 1.0),   # 7: BSk Cold semi-arid
	Color(0.2, 0.8, 0.2, 1.0),   # 8: Csa Hot-summer Mediterranean
	Color(0.4, 0.8, 0.4, 1.0),   # 9: Csb Warm-summer Mediterranean
	Color(0.3, 0.7, 0.3, 1.0),   # 10: Csc Cold-summer Mediterranean
	Color(0.5, 0.9, 0.2, 1.0),   # 11: Cwa Subtropical (dry winter)
	Color(0.5, 0.8, 0.3, 1.0),   # 12: Cwb Subtropical highland
	Color(0.4, 0.7, 0.3, 1.0),   # 13: Cwc Cold subtropical highland
	Color(0.0, 1.0, 0.0, 1.0),   # 14: Cfa Humid subtropical
	Color(0.2, 0.9, 0.0, 1.0),   # 15: Cfb Oceanic
	Color(0.3, 0.8, 0.0, 1.0),   # 16: Cfc Subpolar oceanic
	Color(0.0, 0.7, 0.5, 1.0),   # 17: Dsa Continental (dry summer, hot)
	Color(0.1, 0.7, 0.5, 1.0),   # 18: Dsb Continental (dry summer, warm)
	Color(0.2, 0.6, 0.4, 1.0),   # 19: Dsc Subarctic (dry summer)
	Color(0.1, 0.5, 0.3, 1.0),   # 20: Dsd Cold subarctic (dry summer)
	Color(0.3, 0.7, 0.6, 1.0),   # 21: Dwa Continental (dry winter, hot)
	Color(0.3, 0.6, 0.5, 1.0),   # 22: Dwb Continental (dry winter, warm)
	Color(0.2, 0.5, 0.4, 1.0),   # 23: Dwc Subarctic (dry winter)
	Color(0.1, 0.4, 0.3, 1.0),   # 24: Dwd Cold subarctic (dry winter)
	Color(0.5, 0.7, 0.0, 1.0),   # 25: Dfa Continental (hot summer)
	Color(0.5, 0.6, 0.0, 1.0),   # 26: Dfb Continental (warm summer)
	Color(0.3, 0.5, 0.1, 1.0),   # 27: Dfc Subarctic
	Color(0.2, 0.4, 0.1, 1.0),   # 28: Dfd Cold subarctic
	Color(0.7, 0.8, 0.7, 1.0),   # 29: ET  Tundra
	Color(0.9, 0.9, 0.9, 1.0),   # 30: EF  Ice cap
]

# Chunk grid dimensions in base cells (same as LOD system)
const CHUNK_BANDS_0 := 64
const CHUNK_SEGS_0 := 256

var _earth_body: MeshInstance3D
var _camera: Camera3D
var _band_structure: Dictionary = {}
var _land_loader: RefCounted = null
var _terrain_loader: RefCounted = null
var _climate_loader: RefCounted = null
var _weather_loader: RefCounted = null
var _frame_counter: int = 0
var _display_mode: int = 1  # 0 = simple land/sea, 1 = elevation terrain palette
var _mat: StandardMaterial3D

# Mode label overlay
var _mode_label: Label = null
var _label_timer: float = 0.0
const LABEL_FADE_SEC := 2.5
const MODE_NAMES := ["Land", "Elevation", "Climate", "Temperature", "Precipitation", "Wind", "Daylight", "Slope"]

# Chunk cache: key = "R{row}_C{col}" → ArrayMesh
var _chunk_cache: Dictionary = {}
var _chunk_cache_order: Array = []  # LRU access order (String keys)

# Currently visible chunk nodes: key → MeshInstance3D
var _visible_chunks: Dictionary = {}
# Idle recycled nodes (hidden chunks we can reuse)
var _recycled_nodes: Array = []

# Preload state: when camera is idle, build neighboring chunks
var _last_cam_pos: Vector3 = Vector3.ZERO
var _idle_timer: float = 0.0
const IDLE_PRELOAD_SEC := 1.0
var _preload_queue: Array = []  # pending chunk keys to build


func _ready() -> void:
	print("HT2 EarthDisplay: starting setup...")
	_setup_earth_body()
	print("  Earth body done")

	_band_structure = SphericalGridGenerator.compute_band_structure(EARTH_RADIUS_KM, CELL_KM)
	print("  Band structure: %d bands, %d equator segs" % [
		_band_structure["total_bands"], _band_structure["equator_segs"],
	])

	var ll_script: Script = load("res://scripts/data/land_mask_loader.gd")
	_land_loader = ll_script.new()
	if not _land_loader.load():
		push_error("HT2: failed to load land mask")
		return
	print("  Land mask: %d land / %d total (%.1f%%)" % [
		_land_loader.land_count(), _land_loader.total_tiles(),
		float(_land_loader.land_count()) / float(_land_loader.total_tiles()) * 100.0,
	])

	# Terrain loader for elevation display mode (mode 1)
	var tl_script: Script = load("res://scripts/data/terrain_loader.gd")
	_terrain_loader = tl_script.new()
	if _terrain_loader.load():
		print("  Terrain data loaded: %d terrain types" % _terrain_loader.TERRAIN_NAMES.size())
	else:
		push_warning("HT2: terrain data not loaded — elevation mode unavailable")

	# Climate loader for Köppen display mode (mode 2)
	var cl_script: Script = load("res://scripts/data/climate_loader.gd")
	_climate_loader = cl_script.new()
	if _climate_loader.load():
		print("  Climate data loaded: %d Köppen zones" % _climate_loader.CLIMATE_NAMES.size())
	else:
		push_warning("HT2: climate data not loaded — climate mode unavailable")

	# Weather loader for temp/precip/wind/solar modes (modes 3-6)
	var wl_script: Script = load("res://scripts/data/weather_loader.gd")
	_weather_loader = wl_script.new()
	if _weather_loader.load():
		print("  Weather data loaded")
	else:
		push_warning("HT2: weather data not loaded — weather modes unavailable")

	_camera = _find_camera()
	if not _camera:
		push_error("HT2: no Camera3D found!")
		return
	print("  Camera found: %s" % _camera.name)

	# Mode name label overlay (CanvasLayer for screen-space text)
	var canvas: CanvasLayer = CanvasLayer.new()
	canvas.name = "ModeLabelCanvas"
	canvas.layer = 100
	add_child(canvas)

	_mode_label = Label.new()
	_mode_label.name = "ModeLabel"
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_mode_label.anchors_preset = Control.PRESET_FULL_RECT
	_mode_label.modulate = Color(0, 0, 0, 0)  # start invisible
	_mode_label.add_theme_font_size_override("font_size", 64)
	_mode_label.add_theme_color_override("font_color", Color(0, 0, 0, 1))
	canvas.add_child(_mode_label)

	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.flags_unshaded = true
	_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)

	print("HT2 EarthDisplay ready.")


func _process(delta: float) -> void:
	if not _land_loader or not _camera:
		return

	_frame_counter += 1
	if _frame_counter % REBUILD_FRAME_INTERVAL != 0:
		return

	var sub_point: Vector3 = _camera_to_sub_point()
	if sub_point.length() < 0.001:
		return

	# Track camera movement for idle preload
	var cam_pos: Vector3 = _camera.global_position
	var cam_moved: float = cam_pos.distance_to(_last_cam_pos)
	_last_cam_pos = cam_pos
	if cam_moved > 10.0:
		_idle_timer = 0.0
	else:
		_idle_timer += delta

	# Visible radius from camera height
	var cam_height_km: float = maxf(cam_pos.length() - EARTH_RADIUS_KM, 10.0)
	var horizon_km: float = EARTH_RADIUS_KM * acos(EARTH_RADIUS_KM / (EARTH_RADIUS_KM + cam_height_km))
	var visible_radius: float = minf(horizon_km, 1500.0)

	# Determine visible chunks: iterate all rows, check arc distance from sub_point to chunk center
	var total_bands: int = _band_structure["total_bands"]
	var band_segs: Array = _band_structure["band_segs"]
	var needed: Dictionary = {}

	var max_chunk_rows: int = (total_bands + CHUNK_BANDS_0 - 1) / CHUNK_BANDS_0

	for cr in range(max_chunk_rows):
		var cb0: int = cr * CHUNK_BANDS_0
		var cb1: int = mini(cb0 + CHUNK_BANDS_0, total_bands)
		if cb1 <= cb0: continue

		var row_center_band: float = float(cb0 + cb1) * 0.5
		var row_lat: float = -PI * 0.5 + PI * row_center_band / float(total_bands)
		var row_cos: float = cos(row_lat)

		var max_segs: int = 0
		var min_segs: int = 999999
		for b in range(cb0, cb1):
			var sb: int = band_segs[b] if b < band_segs.size() else 0
			var st: int = band_segs[b + 1] if b + 1 < band_segs.size() else sb
			var mb: int = maxi(sb, st)
			if mb > max_segs: max_segs = mb
			if mb < min_segs: min_segs = mb

		var ncols: int = maxi(1, (max_segs + CHUNK_SEGS_0 - 1) / CHUNK_SEGS_0)
		var chunk_h_km: float = PI * float(CHUNK_BANDS_0) / float(total_bands) * EARTH_RADIUS_KM

		for cc in range(ncols):
			var s0: int = cc * CHUNK_SEGS_0
			var segs_center: float = float(s0) + float(CHUNK_SEGS_0) * 0.5
			var row_lon: float = TAU * segs_center / float(max_segs)

			# Check post-halving center if this row straddles a halving boundary
			var is_visible: bool = false
			var lon_post: float = 0.0
			var has_halving: bool = min_segs < max_segs
			if has_halving:
				lon_post = TAU * fmod(segs_center, float(min_segs)) / float(min_segs)
			else:
				lon_post = row_lon  # unused, fall through to single check

			# Pre-halving center check
			var ccenter: Vector3 = Vector3(
				EARTH_RADIUS_KM * row_cos * cos(row_lon),
				EARTH_RADIUS_KM * sin(row_lat),
				-EARTH_RADIUS_KM * row_cos * sin(row_lon),
			)
			var dot: float = clampf(sub_point.normalized().dot(ccenter.normalized()), -1.0, 1.0)
			var chunk_w_km: float = TAU * float(CHUNK_SEGS_0) / float(max_segs) * EARTH_RADIUS_KM * maxf(row_cos, 0.01)
			var chunk_margin: float = sqrt(chunk_h_km * chunk_h_km + chunk_w_km * chunk_w_km) * 0.5 + 300.0
			var arc_km: float = acos(dot) * EARTH_RADIUS_KM
			if arc_km <= visible_radius + chunk_margin:
				is_visible = true

			# Post-halving center check (only for rows straddling a halving boundary)
			if not is_visible and has_halving:
				var ccenter_post: Vector3 = Vector3(
					EARTH_RADIUS_KM * row_cos * cos(lon_post),
					EARTH_RADIUS_KM * sin(row_lat),
					-EARTH_RADIUS_KM * row_cos * sin(lon_post),
				)
				var dot_post: float = clampf(sub_point.normalized().dot(ccenter_post.normalized()), -1.0, 1.0)
				var chunk_w_post: float = TAU * float(CHUNK_SEGS_0) / float(min_segs) * EARTH_RADIUS_KM * maxf(row_cos, 0.01)
				var chunk_margin_post: float = sqrt(chunk_h_km * chunk_h_km + chunk_w_post * chunk_w_post) * 0.5 + 300.0
				var arc_post: float = acos(dot_post) * EARTH_RADIUS_KM
				if arc_post <= visible_radius + chunk_margin_post:
					is_visible = true

			if is_visible:
				var key: String = "R%d_C%d" % [cr, cc]
				needed[key] = {"row": cr, "col": cc}

	# Show needed chunks, hide others
	_show_chunks(needed)

	# Fade mode label
	if _label_timer > 0.0:
		_label_timer -= delta
		if _mode_label:
			var alpha: float = clampf(_label_timer / LABEL_FADE_SEC, 0.0, 1.0)
			_mode_label.modulate = Color(0, 0, 0, alpha)

	# Auto-prefetch
	if _preload_queue.is_empty():
		_build_preload_queue(needed)
	_preload_one_chunk()


# ── Display mode switching ──

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key: int = event.keycode
	if key >= KEY_0 and key <= KEY_9:
		var mode: int = key - KEY_0
		set_display_mode(mode)


func set_display_mode(mode: int) -> void:
	if mode == _display_mode:
		return
	_display_mode = mode
	print("HT2: display mode = %d" % mode)

	# Update mode label text
	if _mode_label and mode >= 0 and mode < MODE_NAMES.size():
		_mode_label.text = MODE_NAMES[mode]
		_mode_label.modulate = Color(0, 0, 0, 1)
		_label_timer = LABEL_FADE_SEC

	# Invalidate all chunk caches — next _process will rebuild with new colours
	_chunk_cache.clear()
	_chunk_cache_order.clear()

	# Hide all currently visible chunk nodes (they reference old meshes)
	for key in _visible_chunks:
		var node: MeshInstance3D = _visible_chunks[key]
		if is_instance_valid(node):
			node.mesh = null
			node.visible = false
			_recycled_nodes.append(node)
	_visible_chunks.clear()
	_preload_queue.clear()


# ── Chunk visibility ──

func _show_chunks(needed: Dictionary) -> void:
	# Hide chunks no longer needed (recycle their nodes)
	var to_hide: Array = []
	for key in _visible_chunks:
		if not needed.has(key):
			to_hide.append(key)
	for key in to_hide:
		var node: MeshInstance3D = _visible_chunks[key]
		if is_instance_valid(node):
			node.visible = false
			_recycled_nodes.append(node)
		_visible_chunks.erase(key)

	# Show/generate needed chunks
	for key in needed:
		if _visible_chunks.has(key):
			# Already visible — nothing to do
			continue

		var info: Dictionary = needed[key]
		var mesh: ArrayMesh = _get_or_build_chunk(info["row"], info["col"])
		if not mesh:
			continue

		# Get or create a MeshInstance3D for this chunk
		var node: MeshInstance3D
		if not _recycled_nodes.is_empty():
			node = _recycled_nodes.pop_back()
		else:
			node = MeshInstance3D.new()
			node.material_override = _mat
			add_child(node)

		node.name = "Chunk_R%d_C%d" % [info["row"], info["col"]]
		node.mesh = mesh
		node.visible = true
		_visible_chunks[key] = node


func _get_or_build_chunk(row: int, col: int) -> ArrayMesh:
	var key: String = "R%d_C%d" % [row, col]

	# Check cache
	if _chunk_cache.has(key):
		_touch_chunk(key)
		return _chunk_cache[key]

	# Build chunk mesh
	var mesh: ArrayMesh = _build_chunk_mesh(row, col)
	if mesh:
		_chunk_cache[key] = mesh
		_touch_chunk(key)
		# Evict oldest if over limit
		while _chunk_cache_order.size() > MAX_CACHED_CHUNKS:
			var old_key: String = _chunk_cache_order[0]
			_chunk_cache_order.remove_at(0)
			_chunk_cache.erase(old_key)

	return mesh


func _touch_chunk(key: String) -> void:
	var idx: int = _chunk_cache_order.find(key)
	if idx >= 0:
		_chunk_cache_order.remove_at(idx)
	_chunk_cache_order.append(key)


func _build_chunk_mesh(row: int, col: int) -> ArrayMesh:
	var total_bands: int = _band_structure["total_bands"]
	var band_segs: Array = _band_structure["band_segs"]

	var b0: int = row * CHUNK_BANDS_0
	var b1: int = mini(b0 + CHUNK_BANDS_0, total_bands)
	if b1 <= b0:
		return null

	# Determine seg range for this chunk row
	var max_segs: int = 0
	for b in range(b0, b1):
		var sb: int = band_segs[b] if b < band_segs.size() else 0
		var st: int = band_segs[b + 1] if b + 1 < band_segs.size() else sb
		var cs: int = maxi(sb, st)
		if cs > max_segs: max_segs = cs

	var ncols: int = maxi(1, (max_segs + CHUNK_SEGS_0 - 1) / CHUNK_SEGS_0)
	var s0: int = col * CHUNK_SEGS_0
	var s1: int = mini(s0 + CHUNK_SEGS_0, max_segs)
	if s1 <= s0:
		return null

	# Build tile_colors for all cells in this chunk
	var tile_colors: Dictionary = {}
	for b_idx in range(b0, b1):
		var segs_bot_i: int = band_segs[b_idx] if b_idx < band_segs.size() else 0
		var segs_top_i: int = band_segs[b_idx + 1] if b_idx + 1 < band_segs.size() else segs_bot_i
		var cell_segs: int = mini(segs_bot_i, segs_top_i)
		var denser_segs: int = maxi(segs_bot_i, segs_top_i)
		if cell_segs <= 0:
			continue

		var scale_factor: int = maxi(1, denser_segs / maxi(cell_segs, 1))

		for s in range(s0, s1):
			var ws: int = ((s % cell_segs) + cell_segs) % cell_segs
			var land_seg: int = ws * scale_factor
			if land_seg >= denser_segs:
				continue
			var tid: String = "B%d_%d" % [b_idx, ws]

			if _display_mode == 0:
				# Simple land/sea binary
				if _land_loader.is_land(b_idx, land_seg):
					tile_colors[tid] = LAND_COLOR
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 1:
				# Elevation palette (11 terrain types)
				if _terrain_loader:
					tile_colors[tid] = _terrain_loader.get_terrain_color(b_idx, land_seg)
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 2:
				# Köppen climate zones (30 types)
				if _climate_loader:
					var code: int = _climate_loader.get_climate(b_idx, land_seg)
					if code >= 0 and code < CLIMATE_COLORS.size():
						tile_colors[tid] = CLIMATE_COLORS[code]
					else:
						tile_colors[tid] = OCEAN_COLOR
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 3:
				# Temperature heatmap (annual average)
				if _weather_loader:
					var t: float = _weather_loader.get_annual_temp(b_idx, land_seg)
					tile_colors[tid] = _temp_color(t)
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 4:
				# Precipitation ramp (annual total)
				if _weather_loader:
					var p: float = _weather_loader.get_annual_precip(b_idx, land_seg)
					tile_colors[tid] = _precip_color(p)
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 5:
				# Wind speed (annual average)
				if _weather_loader:
					var w: float = _weather_loader.get_annual_wind(b_idx, land_seg)
					tile_colors[tid] = _wind_color(w)
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 6:
				# Solar radiation (annual average)
				if _weather_loader:
					var sval: float = _weather_loader.get_annual_srad(b_idx, land_seg)
					tile_colors[tid] = _solar_color(sval)
				else:
					tile_colors[tid] = OCEAN_COLOR

			elif _display_mode == 7:
				# Slope (5 levels: flat → cliff)
				if _terrain_loader:
					var slope: int = _terrain_loader.get_slope(b_idx, land_seg)
					tile_colors[tid] = _slope_color(slope)
				else:
					tile_colors[tid] = OCEAN_COLOR

			else:
				tile_colors[tid] = OCEAN_COLOR

	if tile_colors.is_empty():
		return null

	var mi: MeshInstance3D = SphericalGridGenerator.generate_tint(
		EARTH_RADIUS_KM, _band_structure, tile_colors, b0, b1, s0, s1,
	)
	if not mi or not mi.mesh:
		return null
	return mi.mesh


# ── Colour ramp helpers ──

func _temp_color(celsius: float) -> Color:
	# Heatmap: blue (-20°C) → cyan (0°) → green (10°) → yellow (20°) → red (40°)
	var t: float = clampf((celsius + 20.0) / 60.0, 0.0, 1.0)
	if t < 0.33:
		return Color(0.0, t * 3.0, 1.0, 1.0)  # blue → cyan
	elif t < 0.5:
		return Color(0.0, 1.0, 1.0 - (t - 0.33) * 6.0, 1.0)  # cyan → green
	elif t < 0.67:
		return Color((t - 0.5) * 6.0, 1.0, 0.0, 1.0)  # green → yellow
	else:
		return Color(1.0, 1.0 - (t - 0.67) * 3.0, 0.0, 1.0)  # yellow → red


func _precip_color(mm: float) -> Color:
	# Blue ramp: pale blue (0mm) → deep blue (3000mm)
	var p: float = clampf(mm / 3000.0, 0.0, 1.0)
	return Color(0.6 - p * 0.4, 0.7 - p * 0.5, 0.6 + p * 0.4, 1.0)


func _wind_color(ms: float) -> Color:
	# Grey → magenta (0 → 3 m/s, real wind range is 0-2.3 m/s)
	var w: float = clampf(ms / 3.0, 0.0, 1.0)
	return Color(0.4 + w * 0.6, 0.4 + w * 0.1, 0.4 + w * 0.6, 1.0)


func _solar_color(kjm2: float) -> Color:
	# Dark brown → orange → bright yellow (0 → 35000 kJ/m²/day)
	# Real range: 0-32767 kJ/m²/day (WorldClim srad int16 values)
	var s: float = clampf(kjm2 / 35000.0, 0.0, 1.0)
	return Color(0.2 + s * 0.8, 0.1 + s * 0.8, 0.0 + s * 0.2, 1.0)


func _slope_color(slope: int) -> Color:
	# Beige-yellow → pale purple (flat 0 → cliff 4)
	var colors: Array = [
		Color(0.85, 0.80, 0.55, 1.0),   # flat: beige-yellow
		Color(0.80, 0.72, 0.60, 1.0),   # gentle
		Color(0.70, 0.60, 0.70, 1.0),   # moderate
		Color(0.60, 0.50, 0.78, 1.0),   # steep
		Color(0.50, 0.40, 0.85, 1.0),   # cliff: pale purple
	]
	if slope >= 0 and slope < colors.size():
		return colors[slope]
	return Color.GRAY


# ── Idle preload ──

func _build_preload_queue(needed: Dictionary) -> void:
	_preload_queue.clear()
	# Gather all chunk keys adjacent to needed chunks
	for key in needed:
		var info: Dictionary = needed[key]
		var row: int = info["row"]
		var col: int = info["col"]
		# Add neighboring chunks (N,S,E,W, NE,NW,SE,SW)
		for dr in [-1, 0, 1]:
			for dc in [-1, 0, 1]:
				if dr == 0 and dc == 0: continue
				var nr: int = row + dr
				var nc: int = col + dc
				if nr < 0: continue
				var adj_key: String = "R%d_C%d" % [nr, nc]
				if not needed.has(adj_key) and not _chunk_cache.has(adj_key):
					if not _preload_queue.has(adj_key):
						_preload_queue.append(adj_key)
	# Limit queue size
	if _preload_queue.size() > 32:
		_preload_queue.resize(32)


func _preload_one_chunk() -> void:
	if _preload_queue.is_empty():
		return
	var key: String = _preload_queue[0]
	_preload_queue.remove_at(0)

	if _chunk_cache.has(key):
		return

	# Parse key
	var parts: PackedStringArray = key.split("_")
	if parts.size() < 4: return
	var row: int = int(parts[1])
	var col: int = int(parts[3])

	var mesh: ArrayMesh = _build_chunk_mesh(row, col)
	if mesh:
		_chunk_cache[key] = mesh
		_touch_chunk(key)
		while _chunk_cache_order.size() > MAX_CACHED_CHUNKS:
			var old_key: String = _chunk_cache_order[0]
			_chunk_cache_order.remove_at(0)
			_chunk_cache.erase(old_key)


# ── Earth body + camera helpers ──

func _setup_earth_body() -> void:
	var sphere_mesh: SphereMesh = SphereMesh.new()
	sphere_mesh.radius = EARTH_RADIUS_KM
	sphere_mesh.height = EARTH_RADIUS_KM * 2.0
	sphere_mesh.radial_segments = 256
	sphere_mesh.rings = 128

	_earth_body = MeshInstance3D.new()
	_earth_body.name = "EarthBody"
	_earth_body.mesh = sphere_mesh

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var tex_path: String = "res://assets/textures/planet/earth/earth_color_4k.png"
	if ResourceLoader.exists(tex_path):
		var tex: Texture2D = load(tex_path)
		mat.albedo_texture = tex
		mat.albedo_color = Color.WHITE
		mat.uv1_offset.x = 0.25
		print("  Earth texture loaded: %s" % tex_path)
	else:
		mat.albedo_color = Color(0.15, 0.25, 0.55)
		print("  Earth texture not found — using blue placeholder")

	_earth_body.material_override = mat
	add_child(_earth_body)


func _find_camera() -> Camera3D:
	var parent_node: Node = get_parent()
	if parent_node:
		for child in parent_node.get_children():
			if child is Camera3D:
				return child
	return null


func _camera_to_sub_point() -> Vector3:
	var cam_pos: Vector3 = _camera.global_position
	var dir: Vector3 = (Vector3.ZERO - cam_pos).normalized()
	var a: float = dir.dot(dir)
	var b: float = 2.0 * cam_pos.dot(dir)
	var c: float = cam_pos.dot(cam_pos) - EARTH_RADIUS_KM * EARTH_RADIUS_KM
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return Vector3.ZERO
	var t: float = (-b - sqrt(disc)) / (2.0 * a)
	if t < 0.0: t = (-b + sqrt(disc)) / (2.0 * a)
	if t < 0.0: return Vector3.ZERO
	return cam_pos + dir * t
