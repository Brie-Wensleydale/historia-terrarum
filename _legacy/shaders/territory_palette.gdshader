// territory_palette.gdshader — Palette-index territory shader for mixed quads.
// Texture pixels hold palette indices (R channel, 0-255).
// Ocean (index 0) is transparent → Earth surface shows through.
// Other indices map to colors via the normal/highlight palette uniforms.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D cell_detail : source_color, filter_nearest;

// 256-color palettes — set by PaletteManager each frame
uniform vec4 normal_palette[256];
uniform vec4 highlight_palette[256];

// Blend between normal and highlight (0.0 = normal, 1.0 = highlighted)
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Read palette index from texture R channel
	float index_raw = texture(cell_detail, UV).r;
	int idx = int(index_raw * 255.0 + 0.5);
	idx = clamp(idx, 0, 255);

	// Look up both palettes and blend
	vec4 normal = normal_palette[idx];
	vec4 highlight = highlight_palette[idx];
	vec4 color = mix(normal, highlight, highlight_mix);

	ALBEDO = color.rgb;
	ALPHA = color.a;
}
