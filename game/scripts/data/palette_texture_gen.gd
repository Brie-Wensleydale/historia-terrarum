# palette_texture_gen.gd — Static utility for generating palette-index textures.
# Each pixel's R channel stores a palette index (0-255).
# Used for mixed-territory quads where sub-cells have different owners.
extends RefCounted


## Create a palette-index Image from a 2D array of palette indices.
## indices_2d[y][x] = palette index (0-255). 0 = ocean/transparent.
## Returns an Image in FORMAT_R8 format (single channel, 8-bit).
static func create_from_indices(indices_2d: Array) -> Image:
	var height := indices_2d.size()
	if height == 0:
		return Image.create(1, 1, false, Image.FORMAT_R8)

	var width: int = indices_2d[0].size()
	var img := Image.create(width, height, false, Image.FORMAT_R8)

	for y in range(height):
		for x in range(width):
			var idx: int = indices_2d[y][x] & 0xFF
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))

	return img


## Create a solid palette-index texture (all pixels = same index).
## Useful for quads that are uniformly owned by one country.
static func create_solid(index: int, size: int = 2) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_R8)
	var val := Color(index / 255.0, 0, 0)
	img.fill(val)
	return img


## Create a checkerboard test pattern alternating two indices.
static func create_checker_test(idx_a: int, idx_b: int, size: int = 4) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_R8)
	for y in range(size):
		for x in range(size):
			var idx := idx_a if (x + y) % 2 == 0 else idx_b
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))
	return img


## Create a horizontal-stripe test pattern for visual alignment testing.
static func create_stripe_test(indices: Array, width: int, height: int) -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_R8)
	var num_stripes := indices.size()
	if num_stripes == 0:
		return img

	for y in range(height):
		var stripe := (y * num_stripes) / height
		var idx: int = indices[stripe] & 0xFF
		for x in range(width):
			img.set_pixel(x, y, Color(idx / 255.0, 0, 0))

	return img
