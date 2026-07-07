# Historia Terrarum

A grand strategy game where you control a nation throughout history, commanding land troops, naval squadrons, and air wings to conquer the globe.

Built on a high-resolution 10km spherical Earth grid adapted from [Stella Nostra](https://github.com/Brie-Wensleydale/godot-stella-nostra).

## Status

**Pre-alpha — Grid pipeline under construction.**

- [x] Project scaffold
- [x] Grid generator (adapted from Stella Nostra)
- [x] Palette shader
- [ ] 10km tile registry
- [ ] Chunked Earth renderer
- [ ] Territory data pipeline
- [ ] Game mechanics

## Architecture

- **Godot 4.6.3** — game engine
- **10km spherical grid** — ~7.6M cells at equator
- **5-level LOD pyramid** — 10km → 160km, selected by camera distance
- **Palette-index shader** — instant display mode switching (political, province, diplomatic, occupation)
- **Chunked rendering** — frustum + horizon culling, lazy LOD regeneration
- **Derived LODs** — single source of truth at Level 0, everything above is a view

## Development

```bash
# Clone
git clone git@github.com:Brie-Wensleydale/historia-terrarum.git

# Generate grid data
cd data/
python generate/grid_registry.py --resolution 10 --summary-only
python generate/grid_registry.py --resolution 10  # full generation

# Open in Godot
# Open game/project.godot in Godot 4.6.3
```

## License

Private — all rights reserved.
