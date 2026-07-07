// territory_palette.gdshader — Palette-index territory shader
//
// Renders textured quads where texture pixels are palette indices (0-255).
// The palette maps indices to country/province colors based on display mode.
// Highlighting is done by swapping the highlight_palette uniform.
//
// For solid quads (no texture), a simpler shader with vertex color is used instead.
// This shader is only for mixed-territory quads with sub-cell detail.

shader_type spatial;
render_mode unshaded, cull_disabled;

// The detail texture containing palette indices
// Each pixel's R channel contains the palette index (0-255)
uniform sampler2D cell_detail : source_color, filter_nearest;

// Normal display palette: 256 colors
uniform vec4 normal_palette[256];

// Highlight palette: used when a country/province is selected
// Same indices, but selected entity gets bright/glowing colors,
// others get dimmed
uniform vec4 highlight_palette[256];

// Blend between normal and highlight (0.0 = normal, 1.0 = highlighted)
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

// Whether to use the texture or fall back to vertex color (solid quads)
uniform bool use_texture = true;

// Alpha override (for fade effects)
uniform float alpha_override : hint_range(0.0, 1.0) = 1.0;

void fragment() {
    vec4 color;

    if (use_texture) {
        // Sample the palette index from the texture
        float index_raw = texture(cell_detail, UV).r;
        int idx = int(index_raw * 255.0 + 0.5);
        idx = clamp(idx, 0, 255);

        // Look up in both palettes and blend
        vec4 normal = normal_palette[idx];
        vec4 highlight = highlight_palette[idx];
        color = mix(normal, highlight, highlight_mix);
    } else {
        // Solid quad — use vertex color
        color = COLOR;
    }

    color.a *= alpha_override;
    ALBEDO = color.rgb;
    ALPHA = color.a;
}
