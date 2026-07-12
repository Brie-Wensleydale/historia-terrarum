// solid_tint.gdshader — Palette-index tint for uniform-territory quads.
// Vertex color R channel encodes palette index (0-255).
// Shader decodes it and looks up display color from palette uniforms.
// Same uniforms as territory_palette.gdshader — PaletteManager updates both.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// 256-color palettes — set by PaletteManager each frame
uniform vec4 normal_palette[256];
uniform vec4 highlight_palette[256];

// Blend between normal and highlight (0.0 = normal, 1.0 = highlighted)
uniform float highlight_mix : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// Decode palette index from vertex color R channel
	int idx = int(COLOR.r * 255.0 + 0.5);
	idx = clamp(idx, 0, 255);

	// Look up both palettes and blend
	vec4 normal = normal_palette[idx];
	vec4 highlight = highlight_palette[idx];
	vec4 color = mix(normal, highlight, highlight_mix);

	ALBEDO = color.rgb;
	ALPHA = color.a;
}
