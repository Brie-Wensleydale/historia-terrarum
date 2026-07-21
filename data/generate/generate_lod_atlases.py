#!/usr/bin/env python3
"""
generate_lod_atlases.py — Pre-bake multi-mode texture atlases for LoD levels 1-4.

Extends generate_lod_terrain.py to output atlases for all 8 display modes:
  0: land/sea        1: elevation       2: climate (Köppen)
  3: temperature      4: precipitation   5: wind
  6: solar            7: slope

Each mode gets its own atlas directory under lod/<mode_name>/lod{1-4}/

Usage: python data/generate/generate_lod_atlases.py [--modes 1,2,3]
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

# ── Grid Constants (must match GDScript) ──
EQUATOR_SEGS = 4096
TOTAL_BANDS = 2048
EARTH_RADIUS_KM = 6371.0
CELL_KM = 10.0

# ── Chunk dimensions in BASE (LOD-0) cells ──
CHUNK_BANDS_0 = 64
CHUNK_SEGS_0 = 256

# ── LOD aggregation stride ──
LOD_STRIDE = [0, 4, 16, 64, 256]  # index 0 unused

# ── Atlas tile constants ──
TILE_DATA = 32
PAD = 1
TILE_PX = TILE_DATA + 2 * PAD  # 34

# ── Terrain colours (mode 1 - elevation) ──
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

# ── Climate colours (mode 2 - Köppen) ──
CLIMATE_COLORS_RGB = [
    ( 25,  76, 153),  # 0: ocean/unclassified
    (  0, 102, 255),  # 1: Af  Tropical rainforest
    (  0, 128, 204),  # 2: Am  Tropical monsoon
    ( 76, 153, 102),  # 3: Aw  Tropical savanna
    (255,  51,  51),  # 4: BWh Hot desert
    (230, 128,  76),  # 5: BWk Cold desert
    (255, 179,  51),  # 6: BSh Hot semi-arid
    (230, 204, 102),  # 7: BSk Cold semi-arid
    ( 51, 204,  51),  # 8: Csa Hot-summer Mediterranean
    (102, 204, 102),  # 9: Csb Warm-summer Mediterranean
    ( 76, 179,  76),  # 10: Csc Cold-summer Mediterranean
    (128, 230,  51),  # 11: Cwa Subtropical (dry winter)
    (128, 204,  76),  # 12: Cwb Subtropical highland
    (102, 179,  76),  # 13: Cwc Cold subtropical highland
    (  0, 255,   0),  # 14: Cfa Humid subtropical
    ( 51, 230,   0),  # 15: Cfb Oceanic
    ( 76, 204,   0),  # 16: Cfc Subpolar oceanic
    (  0, 179, 128),  # 17: Dsa Continental (dry summer, hot)
    ( 25, 179, 128),  # 18: Dsb Continental (dry summer, warm)
    ( 51, 153, 102),  # 19: Dsc Subarctic (dry summer)
    ( 25, 128,  76),  # 20: Dsd Cold subarctic (dry summer)
    ( 76, 179, 153),  # 21: Dwa Continental (dry winter, hot)
    ( 76, 153, 128),  # 22: Dwb Continental (dry winter, warm)
    ( 51, 128, 102),  # 23: Dwc Subarctic (dry winter)
    ( 25, 102,  76),  # 24: Dwd Cold subarctic (dry winter)
    (128, 179,   0),  # 25: Dfa Continental (hot summer)
    (128, 153,   0),  # 26: Dfb Continental (warm summer)
    ( 76, 128,  25),  # 27: Dfc Subarctic
    ( 51, 102,  25),  # 28: Dfd Cold subarctic
    (179, 204, 179),  # 29: ET  Tundra
    (230, 230, 230),  # 30: EF  Ice cap
]

# ── Slope colours (mode 7) ──
SLOPE_COLORS_RGB = [
    (217, 204, 140),  # flat: beige-yellow
    (204, 184, 153),  # gentle
    (179, 153, 179),  # moderate
    (153, 128, 199),  # steep
    (128, 102, 217),  # cliff: pale purple
]

# ── Mode metadata ──
MODE_INFO = {
    "terrain":  {"data_file": "terrain.bin",  "mode_idx": 1, "discrete": True,  "max_val": 10},
    "climate":  {"data_file": "climate.bin",  "mode_idx": 2, "discrete": True,  "max_val": 30},
    "slope":    {"data_file": "slope.bin",    "mode_idx": 7, "discrete": True,  "max_val": 4},
    "temp":     {"data_file": "weather.bin",  "mode_idx": 3, "discrete": False, "var_idx": 0},
    "precip":   {"data_file": "weather.bin",  "mode_idx": 4, "discrete": False, "var_idx": 1},
    "wind":     {"data_file": "weather.bin",  "mode_idx": 5, "discrete": False, "var_idx": 2},
    "solar":    {"data_file": "weather.bin",  "mode_idx": 6, "discrete": False, "var_idx": 3},
}


# ---------------------------------------------------------------------------
#  Grid helpers
# ---------------------------------------------------------------------------

def tile_to_lat_lon(band, seg, band_segs):
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
#  Data readers
# ---------------------------------------------------------------------------

class GridReader:
    """Base reader: loads band structure from land_mask_summary.json."""

    def __init__(self, data_dir):
        summary_path = os.path.join(data_dir, "land_mask_summary.json")
        with open(summary_path) as f:
            summary = json.load(f)

        self.total_bands = summary["grid"]["total_bands"]
        band_segs_dict = summary["band_segs"]
        self.band_segs = [band_segs_dict.get(str(b), 0) for b in range(self.total_bands + 1)]

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
        self.total_cells = offset


class TerrainReader(GridReader):
    """Reads terrain.bin (1 byte/cell, 0-10)."""

    def __init__(self, data_dir):
        super().__init__(data_dir)
        path = os.path.join(data_dir, "terrain.bin")
        with open(path, "rb") as f:
            self.data = f.read()
        assert len(self.data) == self.total_cells

    def get_color(self, band, seg):
        if band < 0 or band >= self.total_bands:
            return TERRAIN_COLORS_RGB[0]
        if seg < 0 or seg >= self.cell_segs_per_band[band]:
            return TERRAIN_COLORS_RGB[0]
        idx = self.band_offsets[band] + seg
        return TERRAIN_COLORS_RGB[self.data[idx]]


class ClimateReader(GridReader):
    """Reads climate.bin (1 byte/cell, 0-30)."""

    def __init__(self, data_dir):
        super().__init__(data_dir)
        path = os.path.join(data_dir, "climate.bin")
        with open(path, "rb") as f:
            self.data = f.read()
        assert len(self.data) == self.total_cells

    def get_color(self, band, seg):
        if band < 0 or band >= self.total_bands:
            return CLIMATE_COLORS_RGB[0]
        if seg < 0 or seg >= self.cell_segs_per_band[band]:
            return CLIMATE_COLORS_RGB[0]
        idx = self.band_offsets[band] + seg
        code = self.data[idx]
        if code < 0 or code >= len(CLIMATE_COLORS_RGB):
            return CLIMATE_COLORS_RGB[0]
        return CLIMATE_COLORS_RGB[code]


class SlopeReader(GridReader):
    """Reads slope.bin (1 byte/cell, 0-4)."""

    def __init__(self, data_dir):
        super().__init__(data_dir)
        path = os.path.join(data_dir, "slope.bin")
        with open(path, "rb") as f:
            self.data = f.read()
        assert len(self.data) == self.total_cells

    def get_color(self, band, seg):
        if band < 0 or band >= self.total_bands:
            return SLOPE_COLORS_RGB[0]
        if seg < 0 or seg >= self.cell_segs_per_band[band]:
            return SLOPE_COLORS_RGB[0]
        idx = self.band_offsets[band] + seg
        val = self.data[idx]
        if val < 0 or val >= len(SLOPE_COLORS_RGB):
            return SLOPE_COLORS_RGB[0]
        return SLOPE_COLORS_RGB[val]


class WeatherReader(GridReader):
    """Reads weather.bin (4 vars × 12 months × int16)."""

    def __init__(self, data_dir, var_idx):
        super().__init__(data_dir)
        self.var_idx = var_idx  # 0=temp, 1=precip, 2=wind, 3=solar
        path = os.path.join(data_dir, "weather.bin")
        self.data = None
        if os.path.exists(path):
            with open(path, "rb") as f:
                self.data = f.read()

    def _annual_avg(self, band, seg):
        """Compute annual average for a cell."""
        if self.data is None:
            return 0.0
        if band < 0 or band >= self.total_bands:
            return 0.0
        if seg < 0 or seg >= self.cell_segs_per_band[band]:
            return 0.0

        cell_idx = self.band_offsets[band] + seg
        # Each cell: 4 vars × 12 months × 2 bytes = 96 bytes
        record_size = 96
        offset = cell_idx * record_size + self.var_idx * 24  # 24 bytes = 12 months × int16

        total = 0.0
        for m in range(12):
            val = struct.unpack_from("<h", self.data, offset + m * 2)[0]
            total += val
        return total / 12.0

    def get_color_temp(self, band, seg):
        """Temperature heatmap: blue (-20°C) → cyan (0°) → green (10°) → yellow (20°) → red (40°C)."""
        celsius = self._annual_avg(band, seg)
        c = celsius / 10.0  # stored as °C×10
        t = max(0.0, min(1.0, (c + 20.0) / 60.0))
        if t < 0.33:
            return (0, int(t * 3.0 * 255), 255)
        elif t < 0.5:
            return (0, 255, int((1.0 - (t - 0.33) * 6.0) * 255))
        elif t < 0.67:
            return (int((t - 0.5) * 6.0 * 255), 255, 0)
        else:
            return (255, int((1.0 - (t - 0.67) * 3.0) * 255), 0)

    def get_color_precip(self, band, seg):
        """Precipitation ramp: pale blue (0mm) → deep blue (3000mm)."""
        mm = self._annual_avg(band, seg)  # raw mm (int)
        p = max(0.0, min(1.0, mm / 3000.0))
        return (int((0.6 - p * 0.4) * 255), int((0.7 - p * 0.5) * 255), int((0.6 + p * 0.4) * 255))

    def get_color_wind(self, band, seg):
        """Wind speed: grey → magenta (0 → 3 m/s). Stored as m/s×10."""
        ms_raw = self._annual_avg(band, seg)
        ms = ms_raw / 10.0
        w = max(0.0, min(1.0, ms / 3.0))
        return (int((0.4 + w * 0.6) * 255), int((0.4 + w * 0.1) * 255), int((0.4 + w * 0.6) * 255))

    def get_color_solar(self, band, seg):
        """Solar radiation: dark brown → orange → bright yellow (0 → 35000 kJ/m²/day)."""
        kj = self._annual_avg(band, seg)
        s = max(0.0, min(1.0, kj / 35000.0))
        return (int((0.2 + s * 0.8) * 255), int((0.1 + s * 0.8) * 255), int((0.0 + s * 0.2) * 255))


# ---------------------------------------------------------------------------
#  Atlas generation
# ---------------------------------------------------------------------------

def make_atlas_image(tiles_wide, tiles_high):
    w = tiles_wide * TILE_PX
    h = tiles_high * TILE_PX
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def fill_tile(atlas, tile_col, tile_row, reader, band_start, band_end,
              seg_start, seg_end, stride, mode_name):
    """
    Fill one tile with colors from the data reader.
    Tile = 32×32 data pixels + 1px border extending edge colors.
    Uses bulk byte writes — ~100× faster than putpixel.
    """
    n_bands = band_end - band_start
    n_segs = seg_end - seg_start
    if n_bands == 0 or n_segs == 0:
        return

    # Dispatch function based on mode
    if mode_name == "temp":
        getter = reader.get_color_temp
    elif mode_name == "precip":
        getter = reader.get_color_precip
    elif mode_name == "wind":
        getter = reader.get_color_wind
    elif mode_name == "solar":
        getter = reader.get_color_solar
    else:
        getter = reader.get_color

    # Pre-sample all data pixels into a flat list of (R,G,B)
    data_pixels = []
    for py in range(TILE_DATA):
        b_frac = py / TILE_DATA
        b_offset = int(b_frac * n_bands)
        base_band = band_start + b_offset
        if base_band >= reader.total_bands:
            base_band = reader.total_bands - 1
        cell_segs = reader.cell_segs_per_band[base_band]
        for px in range(TILE_DATA):
            if cell_segs <= 0:
                data_pixels.append(0)
                data_pixels.append(0)
                data_pixels.append(0)
                continue
            s_frac = px / TILE_DATA
            s_offset = int(s_frac * n_segs)
            base_seg = (seg_start + s_offset) % cell_segs
            r, g, b = getter(base_band, base_seg)
            data_pixels.append(r)
            data_pixels.append(g)
            data_pixels.append(b)

    # Build full tile with border: extend edge data outward
    tile_bytes = bytearray(TILE_PX * TILE_PX * 4)  # RGBA
    for py in range(TILE_PX):
        data_y = max(0, min(py - PAD, TILE_DATA - 1))
        for px in range(TILE_PX):
            data_x = max(0, min(px - PAD, TILE_DATA - 1))
            idx = (data_y * TILE_DATA + data_x) * 3
            ti = (py * TILE_PX + px) * 4
            tile_bytes[ti] = data_pixels[idx]
            tile_bytes[ti + 1] = data_pixels[idx + 1]
            tile_bytes[ti + 2] = data_pixels[idx + 2]
            tile_bytes[ti + 3] = 255

    # Paste tile into atlas via bulk Image.frombytes
    tile_img = Image.frombytes("RGBA", (TILE_PX, TILE_PX), bytes(tile_bytes))
    atlas.paste(tile_img, (tile_col * TILE_PX, tile_row * TILE_PX))

def generate_lod_level(lod, reader, output_dir, mode_name):
    """Generate all chunk atlases for a single LoD level and mode."""
    stride = LOD_STRIDE[lod]
    output_subdir = os.path.join(output_dir, f"lod{lod}")
    os.makedirs(output_subdir, exist_ok=True)

    total_chunks_vert = (TOTAL_BANDS + CHUNK_BANDS_0 - 1) // CHUNK_BANDS_0

    chunks_metadata = []
    chunk_count = 0
    t_start = time.time()

    for chunk_row in range(total_chunks_vert):
        band_start_0 = chunk_row * CHUNK_BANDS_0
        band_end_0 = min(band_start_0 + CHUNK_BANDS_0, TOTAL_BANDS)

        if band_end_0 <= band_start_0:
            continue

        max_segs_in_chunk = 0
        for b in range(band_start_0, band_end_0):
            cs = reader.cell_segs_per_band[b]
            if cs > max_segs_in_chunk:
                max_segs_in_chunk = cs

        total_chunks_horiz = (max_segs_in_chunk + CHUNK_SEGS_0 - 1) // CHUNK_SEGS_0

        for chunk_col in range(total_chunks_horiz):
            seg_start_0 = chunk_col * CHUNK_SEGS_0
            seg_end_0 = min(seg_start_0 + CHUNK_SEGS_0, max_segs_in_chunk)

            if seg_end_0 <= seg_start_0:
                continue

            mega_bands = max(1, (band_end_0 - band_start_0 + stride - 1) // stride)
            mega_segs = max(1, (seg_end_0 - seg_start_0 + stride - 1) // stride)

            atlas = make_atlas_image(mega_segs, mega_bands)

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
                    fill_tile(atlas, ms, mb, reader, b0, b1, s0, s1, stride, mode_name)

            filename = f"chunk_{chunk_row}_{chunk_col}_{mode_name}.png"
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
#  Mode-specific generator
# ---------------------------------------------------------------------------

def generate_mode(mode_name, data_dir, output_base_dir, info):
    """Generate all LOD atlases for a single display mode."""
    data_file = info["data_file"]
    data_path = os.path.join(data_dir, data_file)
    if not os.path.exists(data_path):
        print(f"\n  SKIP {mode_name}: {data_file} not found at {data_path}")
        return

    print(f"\n{'=' * 60}")
    print(f"Mode: {mode_name} (mode index {info['mode_idx']})")
    print(f"Data: {data_file}")
    print(f"{'=' * 60}")

    # Create reader
    if mode_name == "terrain":
        reader = TerrainReader(data_dir)
    elif mode_name == "climate":
        reader = ClimateReader(data_dir)
    elif mode_name == "slope":
        reader = SlopeReader(data_dir)
    elif mode_name in ("temp", "precip", "wind", "solar"):
        reader = WeatherReader(data_dir, info["var_idx"])
    else:
        print(f"  Unknown mode: {mode_name}")
        return

    print(f"  {reader.total_bands} bands, {reader.total_cells:,} cells")

    output_dir = os.path.join(output_base_dir, mode_name)
    os.makedirs(output_dir, exist_ok=True)

    all_metadata = {}
    for lod in [1, 2, 3, 4]:
        print(f"  Generating LOD {lod} (stride={LOD_STRIDE[lod]}×)...")
        meta = generate_lod_level(lod, reader, output_dir, mode_name)
        all_metadata[str(lod)] = meta

    # Save metadata
    metadata_path = os.path.join(output_dir, "lod_chunks.json")
    with open(metadata_path, "w") as f:
        json.dump(all_metadata, f, indent=2)
    print(f"  Metadata → {metadata_path}")


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    data_dir = os.path.join(project_root, "data", "output", "grid_10km_ht2")
    output_base_dir = os.path.join(data_dir, "lod")
    os.makedirs(output_base_dir, exist_ok=True)

    # Parse --modes filter
    arg_modes = None
    args = sys.argv[1:]
    if "--modes" in args:
        idx = args.index("--modes")
        if idx + 1 < len(args):
            arg_modes = set(m.strip() for m in args[idx + 1].split(","))

    # Validate terrain.bin exists (needed by all since we use terrain grid)
    terrain_path = os.path.join(data_dir, "terrain.bin")
    summary_path = os.path.join(data_dir, "land_mask_summary.json")
    if not os.path.exists(summary_path):
        print(f"ERROR: land_mask_summary.json not found at {summary_path}")
        sys.exit(1)
    if not os.path.exists(terrain_path):
        print(f"WARNING: terrain.bin not found at {terrain_path}")

    # Generate each mode
    modes_order = ["terrain", "climate", "temp", "precip", "wind", "solar", "slope"]
    for mode_name in modes_order:
        if arg_modes and mode_name not in arg_modes:
            continue
        info = MODE_INFO[mode_name]
        generate_mode(mode_name, data_dir, output_base_dir, info)

    print(f"\n{'=' * 60}")
    print("Done. All mode atlases in:")
    for mode_name in modes_order:
        path = os.path.join(output_base_dir, mode_name)
        if os.path.isdir(path):
            print(f"  {path}/")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
