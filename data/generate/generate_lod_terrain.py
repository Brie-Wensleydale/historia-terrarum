#!/usr/bin/env python3
"""
generate_lod_terrain.py — Pre-bake terrain texture atlases for LoD levels 1-4.

For each LoD level, partitions the globe into fixed-size chunks (64×256 base cells).
Each chunk gets a texture atlas where every mega-cell is a 16×16 tile.
Mega-cells sample their child 10km terrain data to produce RGB colors.

Output:  data/output/grid_10km_ht2/lod/
         ├── lod1/chunk_{r}_{c}_terrain.png  (128 files)
         ├── lod2/chunk_{r}_{c}_terrain.png  (  8 files)
         ├── lod3/chunk_{r}_{c}_terrain.png  (  1 file)
         ├── lod4/chunk_{r}_{c}_terrain.png  (  1 file)
         └── lod_chunks.json                  (chunk metadata per level)

Usage: python data/generate/generate_lod_terrain.py
"""

import json
import math
import os
import struct
import sys
import time

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow not installed. Run: pip install Pillow")
    sys.exit(1)

# ── Grid Constants (must match GDScript SphericalGridGenerator) ──
EQUATOR_SEGS = 4096
TOTAL_BANDS = 2048
EARTH_RADIUS_KM = 6371.0
CELL_KM = 10.0

# ── Chunk dimensions in BASE (LOD-0) cells ──
CHUNK_BANDS_0 = 64   # vertical
CHUNK_SEGS_0 = 256   # horizontal (at equator)

# ── LOD aggregation stride ──
LOD_STRIDE = [1, 4, 16, 64, 256]  # index 0 unused, 1-4 = stride for LOD 1-4

# ── Terrain colours (must match GDScript terrain_loader.gd TERRAIN_COLORS) ──
TERRAIN_COLORS_RGB = [
    (  5,  25,  89),  # deep ocean
    ( 13,  51, 140),  # ocean
    ( 25,  89, 166),  # shallow ocean
    ( 38, 115, 179),  # continental shelf
    (217, 204, 102),  # coastal
    ( 77, 179,  77),  # lowland
    (102, 153,  64),  # upland
    (140, 128,  51),  # highland
    (115,  89,  51),  # mountain
    (153, 128, 115),  # high mountain
    (230, 230, 230),  # extreme mountain
]

# ── Tile size in atlas ──
# Tile = DATA + 2×PAD border pixels to prevent texture-filter edge bleeding
TILE_DATA = 32    # actual data pixels per tile
PAD = 1           # border pixels on each side
TILE_PX = TILE_DATA + 2 * PAD  # total pixels per tile (34)


# ---------------------------------------------------------------------------
#  Grid helpers
# ---------------------------------------------------------------------------

def compute_band_structure():
    """Replicate GDScript SphericalGridGenerator.compute_band_structure."""
    import math
    radius_m = EARTH_RADIUS_KM * 1000.0
    half_cell_m = CELL_KM * 0.5 * 1000.0
    eq_band = TOTAL_BANDS // 2

    band_segs = [0] * (TOTAL_BANDS + 1)
    band_segs[eq_band] = EQUATOR_SEGS

    # Northward
    current_segs = EQUATOR_SEGS
    for b in range(eq_band + 1, TOTAL_BANDS + 1):
        lat = -math.pi * 0.5 + math.pi * float(b) / float(TOTAL_BANDS)
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / float(current_segs)
        while (cell_width < half_cell_m and current_segs > 8
               and current_segs % 2 == 0):
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / float(current_segs)
        band_segs[b] = current_segs

    # Southward
    current_segs = EQUATOR_SEGS
    for b in range(eq_band - 1, -1, -1):
        lat = -math.pi * 0.5 + math.pi * float(b) / float(TOTAL_BANDS)
        ring_radius = radius_m * math.cos(lat)
        cell_width = 2.0 * math.pi * ring_radius / float(current_segs)
        while (cell_width < half_cell_m and current_segs > 8
               and current_segs % 2 == 0):
            current_segs //= 2
            cell_width = 2.0 * math.pi * ring_radius / float(current_segs)
        band_segs[b] = current_segs

    return {
        "total_bands": TOTAL_BANDS,
        "equator_segs": EQUATOR_SEGS,
        "band_segs": band_segs,
    }


def tile_to_lat_lon(band, seg, band_segs):
    """Convert (band, seg) to (lat_deg, lon_deg)."""
    lat = -math.pi * 0.5 + math.pi * float(band) / float(TOTAL_BANDS)
    segs_bot = band_segs[band]
    segs_top = band_segs[band + 1] if band + 1 < len(band_segs) else segs_bot
    cell_segs = max(segs_bot, segs_top)
    lon = 2.0 * math.pi * float(seg) / float(cell_segs)
    lat_deg = math.degrees(lat)
    lon_deg = math.degrees(lon)
    if lon_deg > 180.0:
        lon_deg -= 360.0
    return lat_deg, lon_deg


# ---------------------------------------------------------------------------
#  Terrain data reader
# ---------------------------------------------------------------------------

class TerrainReader:
    """Read terrain.bin + band offsets for O(1) lookup."""

    def __init__(self, data_dir):
        self.data_dir = data_dir

        # Load grid structure
        summary_path = os.path.join(data_dir, "land_mask_summary.json")
        with open(summary_path) as f:
            summary = json.load(f)

        self.total_bands = summary["grid"]["total_bands"]
        band_segs_dict = summary["band_segs"]
        self.band_segs = [band_segs_dict.get(str(b), 0) for b in range(self.total_bands + 1)]

        # Compute cell_segs and band offsets (denser frame = maxi)
        self.cell_segs_per_band = []
        self.band_offsets = []
        offset = 0
        for b in range(self.total_bands):
            segs_bot = self.band_segs[b]
            segs_top = self.band_segs[b + 1]
            cell_segs = max(segs_bot, segs_top)
            self.cell_segs_per_band.append(cell_segs)
            self.band_offsets.append(offset)
            offset += cell_segs

        # Load terrain binary
        terrain_path = os.path.join(data_dir, "terrain.bin")
        with open(terrain_path, "rb") as f:
            self.terrain_data = f.read()

        assert len(self.terrain_data) == offset, \
            f"terrain.bin size {len(self.terrain_data)} != expected {offset}"

    def get_terrain(self, band, seg):
        """Return terrain type (0-10)."""
        if band < 0 or band >= self.total_bands:
            return 0
        if seg < 0 or seg >= self.cell_segs_per_band[band]:
            return 0
        idx = self.band_offsets[band] + seg
        return self.terrain_data[idx]

    def get_terrain_color(self, band, seg):
        """Return (R, G, B) tuple for a base cell."""
        t = self.get_terrain(band, seg)
        return TERRAIN_COLORS_RGB[t]


# ---------------------------------------------------------------------------
#  Atlas generation
# ---------------------------------------------------------------------------

def make_atlas_image(tiles_wide, tiles_high):
    """Create a blank RGBA atlas image."""
    w = tiles_wide * TILE_PX
    h = tiles_high * TILE_PX
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def fill_tile(atlas, tile_col, tile_row, terrain_reader, band_start, band_end,
              seg_start, seg_end, stride):
    """
    Fill one tile in the atlas with terrain colors from child cells.
    Tile = 32×32 data pixels + 1px border extending edge colors.
    """
    x0 = tile_col * TILE_PX
    y0 = tile_row * TILE_PX

    n_bands = band_end - band_start
    n_segs = seg_end - seg_start

    if n_bands == 0 or n_segs == 0:
        return

    # Build data pixel array (32×32)
    pixels = []
    for py in range(TILE_DATA):
        b_frac = py / TILE_DATA
        b_offset = int(b_frac * n_bands)
        base_band = band_start + b_offset
        if base_band >= terrain_reader.total_bands:
            base_band = terrain_reader.total_bands - 1

        row_pixels = []
        for px in range(TILE_DATA):
            s_frac = px / TILE_DATA
            s_offset = int(s_frac * n_segs)
            cell_segs = terrain_reader.cell_segs_per_band[base_band]
            if cell_segs <= 0:
                row_pixels.append(TERRAIN_COLORS_RGB[0] + (255,))
                continue
            base_seg = (seg_start + s_offset) % cell_segs

            r, g, b = terrain_reader.get_terrain_color(base_band, base_seg)
            row_pixels.append((r, g, b, 255))
        pixels.append(row_pixels)

    # Write data + border (extend edge pixels outward)
    for py in range(TILE_PX):
        # Clamp data_y to valid range for border pixels
        data_y = max(0, min(py - PAD, TILE_DATA - 1))
        for px in range(TILE_PX):
            data_x = max(0, min(px - PAD, TILE_DATA - 1))
            atlas.putpixel((x0 + px, y0 + py), pixels[data_y][data_x])


def generate_lod_level(lod, terrain_reader, output_dir):
    """Generate all chunk atlases for a single LoD level."""
    stride = LOD_STRIDE[lod]
    output_subdir = os.path.join(output_dir, f"lod{lod}")
    os.makedirs(output_subdir, exist_ok=True)

    # Chunk dimensions at this LoD level (in base cells)
    # Each chunk covers CHUNK_BANDS_0 bands and CHUNK_SEGS_0 segs at LOD-0 scale
    total_chunks_vert = (TOTAL_BANDS + CHUNK_BANDS_0 - 1) // CHUNK_BANDS_0

    chunks_metadata = []
    chunk_count = 0
    t_start = time.time()

    for chunk_row in range(total_chunks_vert):
        band_start_0 = chunk_row * CHUNK_BANDS_0
        band_end_0 = min(band_start_0 + CHUNK_BANDS_0, TOTAL_BANDS)

        if band_end_0 <= band_start_0:
            continue

        # Determine max segs in this chunk row (varies by latitude — halving)
        max_segs_in_chunk = 0
        for b in range(band_start_0, band_end_0):
            cs = terrain_reader.cell_segs_per_band[b]
            if cs > max_segs_in_chunk:
                max_segs_in_chunk = cs

        total_chunks_horiz = (max_segs_in_chunk + CHUNK_SEGS_0 - 1) // CHUNK_SEGS_0

        for chunk_col in range(total_chunks_horiz):
            seg_start_0 = chunk_col * CHUNK_SEGS_0
            seg_end_0 = min(seg_start_0 + CHUNK_SEGS_0, max_segs_in_chunk)

            if seg_end_0 <= seg_start_0:
                continue

            # Count mega-cells in this chunk at the LoD stride
            # A mega-cell spans [b*stride, (b+1)*stride) in base bands
            # and [s*stride, (s+1)*stride) in base segs
            mega_bands = max(1, (band_end_0 - band_start_0 + stride - 1) // stride)
            mega_segs = max(1, (seg_end_0 - seg_start_0 + stride - 1) // stride)

            # Create atlas
            atlas = make_atlas_image(mega_segs, mega_bands)

            # Fill tiles
            for mb in range(mega_bands):
                b0 = band_start_0 + mb * stride
                b1 = min(b0 + stride, band_end_0)
                if b1 <= b0:
                    continue
                for ms in range(mega_segs):
                    s0 = seg_start_0 + ms * stride
                    s1 = min(s0 + stride, seg_end_0)
                    if s1 <= s0:
                        continue
                    fill_tile(atlas, ms, mb, terrain_reader, b0, b1, s0, s1, stride)

            # Save atlas
            filename = f"chunk_{chunk_row}_{chunk_col}_terrain.png"
            filepath = os.path.join(output_subdir, filename)
            atlas.save(filepath, "PNG", optimize=True)
            chunk_count += 1

            chunks_metadata.append({
                "chunk_row": chunk_row,
                "chunk_col": chunk_col,
                "band_start_0": band_start_0,
                "band_end_0": band_end_0,
                "seg_start_0": seg_start_0,
                "seg_end_0": seg_end_0,
                "mega_bands": mega_bands,
                "mega_segs": mega_segs,
                "atlas_width": mega_segs * TILE_PX,
                "atlas_height": mega_bands * TILE_PX,
                "tile_data": TILE_DATA,
                "pad": PAD,
                "filename": filename,
                "lod": lod,
            })

    elapsed = time.time() - t_start
    file_size_mb = 0
    for fn in os.listdir(output_subdir):
        file_size_mb += os.path.getsize(os.path.join(output_subdir, fn))
    file_size_mb /= (1024 * 1024)

    print(f"  LOD {lod}: {chunk_count} chunks in {elapsed:.1f}s, {file_size_mb:.1f} MB total")

    return chunks_metadata


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    data_dir = os.path.join(project_root, "data", "output", "grid_10km_ht2")
    output_dir = os.path.join(data_dir, "lod")
    os.makedirs(output_dir, exist_ok=True)

    print("=" * 60)
    print("LoD Terrain Atlas Generator")
    print("=" * 60)

    # Validate inputs
    terrain_path = os.path.join(data_dir, "terrain.bin")
    if not os.path.exists(terrain_path):
        print(f"ERROR: terrain.bin not found at {terrain_path}")
        print("Run generate_terrain.py first.")
        sys.exit(1)

    summary_path = os.path.join(data_dir, "land_mask_summary.json")
    if not os.path.exists(summary_path):
        print(f"ERROR: land_mask_summary.json not found at {summary_path}")
        sys.exit(1)

    # Load terrain data
    print(f"\nLoading terrain data from {data_dir}...")
    reader = TerrainReader(data_dir)
    print(f"  {reader.total_bands} bands, {len(reader.terrain_data):,} cells")

    # Generate each LoD level
    all_metadata = {}
    for lod in [1, 2, 3, 4]:
        print(f"\nGenerating LOD {lod} (stride={LOD_STRIDE[lod]}×)...")
        meta = generate_lod_level(lod, reader, output_dir)
        all_metadata[str(lod)] = meta

    # Save chunk metadata
    metadata_path = os.path.join(output_dir, "lod_chunks.json")
    with open(metadata_path, "w") as f:
        json.dump(all_metadata, f, indent=2)

    print(f"\nMetadata saved to {metadata_path}")
    print(f"\nDone. Atlases in {output_dir}/")
    print(f"Next: run Godot to load lod_display.gd (Phase B)")


if __name__ == "__main__":
    main()
