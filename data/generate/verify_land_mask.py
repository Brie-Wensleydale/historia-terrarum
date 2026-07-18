#!/usr/bin/env python3
"""
verify_land_mask.py — Quick verification of the land mask.
Checks grid structure, tile counts, and known land/ocean points.
"""
import json
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "data", "output", "grid_10km_ht2")

SUMMARY_PATH = os.path.join(OUTPUT_DIR, "land_mask_summary.json")
MASK_PATH = os.path.join(OUTPUT_DIR, "land_mask.bin")


def load_summary():
    with open(SUMMARY_PATH) as f:
        return json.load(f)


def load_mask():
    with open(MASK_PATH, "rb") as f:
        return f.read()


def is_land(mask_bytes, band_offsets, cell_segs_per_band, band, seg):
    """Bit-level lookup matching land_mask_loader.gd logic."""
    if band < 0 or band >= len(cell_segs_per_band):
        return False
    if seg < 0 or seg >= cell_segs_per_band[band]:
        return False
    bit_index = band_offsets[band] + seg
    byte_idx = bit_index // 8
    bit_offset = bit_index % 8
    if byte_idx >= len(mask_bytes):
        return False
    return (mask_bytes[byte_idx] & (1 << bit_offset)) != 0


def main():
    if not os.path.exists(SUMMARY_PATH):
        print(f"ERROR: {SUMMARY_PATH} not found")
        return 1

    summary = load_summary()
    mask_bytes = load_mask()

    grid = summary["grid"]
    tiles = summary["tiles"]
    band_segs_raw = summary["band_segs"]  # ring segment counts

    total_bands = grid["total_bands"]
    equator_segs = grid["equator_segs"]

    # Build cell_segs_per_band + offsets
    cell_segs_per_band = []
    band_offsets = []
    offset = 0
    for b in range(total_bands):
        segs_bot = int(band_segs_raw.get(str(b), 0))
        segs_top = int(band_segs_raw.get(str(b + 1), segs_bot))
        cell_segs = max(segs_bot, segs_top)
        cell_segs_per_band.append(cell_segs)
        band_offsets.append(offset)
        offset += cell_segs

    print("=" * 50)
    print("HT2 Land Mask Verification")
    print("=" * 50)
    print()

    # Grid structure checks
    errors = 0

    print("[Grid Structure]")
    print(f"  Total bands: {total_bands} (expected 2048)")
    if total_bands != 2048:
        print("    ERROR!")
        errors += 1

    print(f"  Equator segs: {equator_segs} (expected 4096)")
    if equator_segs != 4096:
        print("    ERROR!")
        errors += 1

    eq_band = total_bands // 2
    eq_ring_segs = int(band_segs_raw[str(eq_band)])
    print(f"  Ring {eq_band} (equator) segs: {eq_ring_segs} (expected 4096)")
    if eq_ring_segs != 4096:
        print("    ERROR!")
        errors += 1

    south_segs = int(band_segs_raw["0"])
    north_segs = int(band_segs_raw[str(total_bands)])
    print(f"  South pole ring 0: {south_segs} (expected 8)")
    print(f"  North pole ring {total_bands}: {north_segs} (expected 8)")
    if south_segs != 8:
        print("    ERROR!")
        errors += 1
    if north_segs != 8:
        print("    ERROR!")
        errors += 1

    merge_chain = summary.get("merge_chain", [])
    expected_chain = [4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8]
    print(f"  Merge chain: {merge_chain}")
    if merge_chain != expected_chain:
        print(f"    Expected: {expected_chain}")
        print("    ERROR!")
        errors += 1

    # Tile count checks
    total_tiles = tiles["total"]
    land_count = tiles["land"]
    ocean_count = tiles["ocean"]
    land_pct = tiles["land_pct"]

    print(f"\n[Tile Counts]")
    print(f"  Total tiles: {total_tiles:,}")
    print(f"  Land: {land_count:,} ({land_pct}%)")
    print(f"  Ocean: {ocean_count:,}")

    expected_land_pct = 29.2
    if abs(land_pct - expected_land_pct) > 5.0:
        print(f"  Land percentage differs from expected ~{expected_land_pct}% by >5%")
        errors += 1
    else:
        print(f"  Land percentage within expected range (~{expected_land_pct}%)")

    # Binary mask size check
    expected_bytes = (total_tiles + 7) // 8
    actual_bytes = len(mask_bytes)
    print(f"  Mask file size: {actual_bytes:,} bytes (expected {expected_bytes:,})")
    if actual_bytes != expected_bytes:
        print("    ERROR!")
        errors += 1

    # Known point checks
    print(f"\n[Known Points]")

    # London: ~51.5°N, -0.1°W → should be land
    # Band: (51.5 + 90) / 180 * 2048 ≈ 1614
    london_band = int((51.5 + 90) / 180 * 2048)
    london_segs = cell_segs_per_band[london_band] if london_band < len(cell_segs_per_band) else 0
    london_seg = int((-0.1 + 180) / 360 * london_segs) if london_segs > 0 else 0
    london_result = is_land(mask_bytes, band_offsets, cell_segs_per_band, london_band, london_seg)
    print(f"  London (51.5°N, 0.1°W): band={london_band}, seg={london_seg}/{london_segs} → {'LAND' if london_result else 'OCEAN'} (expected LAND)")
    if not london_result:
        print("    WARNING: London classified as ocean!")

    # Pacific Ocean: 0°N, 140°W → should be ocean
    pacific_band = int((0 + 90) / 180 * 2048)
    pacific_segs = cell_segs_per_band[pacific_band] if pacific_band < len(cell_segs_per_band) else 0
    pacific_seg = int((-140 + 180) / 360 * pacific_segs) if pacific_segs > 0 else 0
    pacific_result = is_land(mask_bytes, band_offsets, cell_segs_per_band, pacific_band, pacific_seg)
    print(f"  Pacific (0°N, 140°W): band={pacific_band}, seg={pacific_seg}/{pacific_segs} → {'LAND' if pacific_result else 'OCEAN'} (expected OCEAN)")
    if pacific_result:
        print("    WARNING: Pacific classified as land!")

    # Sahara Desert: 23°N, 13°E → should be land
    sahara_band = int((23 + 90) / 180 * 2048)
    sahara_segs = cell_segs_per_band[sahara_band] if sahara_band < len(cell_segs_per_band) else 0
    sahara_seg = int((13 + 180) / 360 * sahara_segs) if sahara_segs > 0 else 0
    sahara_result = is_land(mask_bytes, band_offsets, cell_segs_per_band, sahara_band, sahara_seg)
    print(f"  Sahara (23°N, 13°E): band={sahara_band}, seg={sahara_seg}/{sahara_segs} → {'LAND' if sahara_result else 'OCEAN'} (expected LAND)")
    if not sahara_result:
        print("    WARNING: Sahara classified as ocean!")

    # South Atlantic: 30°S, 20°W → should be ocean
    satlantic_band = int((-30 + 90) / 180 * 2048)
    satlantic_segs = cell_segs_per_band[satlantic_band] if satlantic_band < len(cell_segs_per_band) else 0
    satlantic_seg = int((-20 + 180) / 360 * satlantic_segs) if satlantic_segs > 0 else 0
    satlantic_result = is_land(mask_bytes, band_offsets, cell_segs_per_band, satlantic_band, satlantic_seg)
    print(f"  S. Atlantic (30°S, 20°W): band={satlantic_band}, seg={satlantic_seg}/{satlantic_segs} → {'LAND' if satlantic_result else 'OCEAN'} (expected OCEAN)")
    if satlantic_result:
        print("    WARNING: South Atlantic classified as land!")

    print()
    if errors:
        print(f"VERIFICATION FAILED: {errors} error(s)")
        return 1
    else:
        print("VERIFICATION PASSED")
        return 0


if __name__ == "__main__":
    exit(main())
