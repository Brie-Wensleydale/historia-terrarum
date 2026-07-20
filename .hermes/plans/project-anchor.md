# Historia Terrarum 2 — Project Anchor

## Overview
HT2 is a Godot 4.6 rebuild of Historia Terrarum — a spherical-grid Earth simulation with terrain, climate, weather, and data layers rendered on 10km cells wrapping a textured globe.

## Technical Foundation
- **Engine:** Godot 4.6, `warnings_as_errors` enabled
- **Grid:** 4096 equator × 2048 bands spherical grid (~6.5M cells), 10km resolution
- **Coordinate system:** +X = prime meridian, +Y = north pole, +Z = 90°E, negated-Z mesh convention
- **GDScript rules:** No `:=` on non-const variables, no `Array[Type]` typed arrays
- **Data pipeline:** Python (shapely + fiona) → binary files (land_mask.bin, terrain.bin, weather.bin)

## Current Architecture
- `earth_display.gd` — LOD 0: chunk-based vertex-color cell meshes (64×256 base cells per chunk), 8 display modes (0=land/sea, 1=elevation, 2=climate, 3=temp, 4=precip, 5=wind, 6=daylight, 7=slope)
- `lod_display.gd` — LOD 1-4: pre-baked terrain texture atlases on sphere-surface chunk meshes (reportedly broken)
- `spherical_grid_generator.gd` — mesh generation with shared vertex rings, halving-band pentagons, polar fan triangulation
- `earth_camera.gd` — 8 zoom rungs (Cell through Global), mouse drag/zoom
- `land_mask_loader.gd` / `terrain_loader.gd` / `climate_loader.gd` / `weather_loader.gd` — data readers (all wired into display)

## Key Fixes Applied (2026-07-20)
- Cells flipped to match Earth texture (negated Z + 180° offset)
- Tier 1-3 optimization: batched mesh build, chunk cache, rebuild-on-stop, neighbor preload
- Halving-band pentagons instead of tri+trapezoid pairs
- Egypt land mask fix (invalid geometry repair in shapefile pipeline)
- LOD: shared vertex rings, pole fan tris, mipmap filtering, hemisphere pre-load
- Halving-band chunk visibility: dual-center check for rows straddling halving rings
- Display modes 0-7 with number keys, mode name overlay with fade
- Wind/solar ramps rescaled to match real data ranges

## Next Sessions
- Chunk loading/unloading threshold tuning
- LOD system repair
- Mode-switching performance optimization (pre-baked textures?)
- Time system port from Stella Nostra / previous HT
- Day/night cycle after time system
- Slope data regeneration (--full flag for real slope computation)
