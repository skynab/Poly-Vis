shader_type spatial;
// Ribbon-trail surface for PolyTrails.gd.
//
// The strand geometry (a per-frame ImmediateMesh triangle strip, camera-facing
// and width-tapered) is built on the CPU; this shader only colors it, following
// the same colormap + influence conventions as polymesh_deform / polycloth so
// trails read as part of the same visual family. The length parameter t (0 at
// the fading tail, 1 at the head glued to the anchor) is baked into UV.x by the
// mesh builder; colormap lookup and the alpha fade both key off it.
render_mode cull_disabled, unshaded, blend_mix, depth_draw_never, shadows_disabled;

// --- colormap (shared with the mesh / cloth) -------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
uniform vec3 u_base_color : source_color = vec3(0.2, 0.7, 1.0);
// Overall brightness — push above 1 to bloom (matches particle_brightness).
uniform float u_brightness : hint_range(0.0, 4.0) = 1.0;
// Ribbon opacity at the head; the tail fades to 0 via u_fade.
uniform float u_opacity : hint_range(0.0, 1.0) = 1.0;
// Alpha falloff exponent along the length (higher = longer transparent tail).
uniform float u_fade : hint_range(0.1, 6.0) = 1.5;

// --- influence fields (shared convention) ----------------------------------
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // signed; only magnitude tints here
uniform vec3 u_influence_color[8];
// How strongly ribbon fragments adopt a nearby influence's color.
uniform float u_influence_tint : hint_range(0.0, 1.0) = 0.6;

varying float v_t;
varying vec3 v_world_pos;

void vertex() {
	v_t = UV.x;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 col = u_use_colormap ? texture(u_colormap, vec2(clamp(v_t, 0.0, 1.0), 0.5)).rgb : u_base_color;

	// Influence tint: ribbon fragments near an active influence pick up its color,
	// mirroring polycloth's mix toward v_infl_color.
	float amt = 0.0;
	vec3 icol = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		float d = distance(v_world_pos, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		amt = max(amt, fall);
		icol += u_influence_color[i] * fall;
		wsum += fall;
	}
	if (wsum > 0.0001) {
		col = mix(col, icol / wsum, clamp(amt, 0.0, 1.0) * u_influence_tint);
	}

	ALBEDO = col * u_brightness;
	// Head (t=1) is fully opaque, tail (t=0) fades out for the smooth trail look.
	ALPHA = pow(clamp(v_t, 0.0, 1.0), u_fade) * u_opacity;
}
