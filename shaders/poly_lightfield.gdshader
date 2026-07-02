shader_type spatial;
// Reactive LED pixel field (PolyLightField).
//
// One emissive quad per grid cell, drawn as a single MultiMesh. Each cell lights
// up by proximity to the influence field: the vertex stage reads the cell's own
// world position (the MultiMesh instance origin, folded into MODEL_MATRIX) and the
// shared u_influence_* arrays, accumulates a distance falloff, and drives the
// cell's emission intensity + colormap hue from it. A per-cell random phase in
// INSTANCE_CUSTOM.x gives every pixel an out-of-sync idle shimmer so the dark wall
// still breathes. Unshaded so cells read as pure light (and bloom past the glow
// HDR threshold); everything is computed per-cell in the vertex stage — cheap.
render_mode unshaded, cull_disabled;

uniform float u_time = 0.0;

// --- field response --------------------------------------------------------
uniform float u_falloff : hint_range(0.1, 8.0) = 2.0;   // higher = tighter light pools
uniform float u_cell_gain : hint_range(0.0, 8.0) = 2.0; // brightness of lit cells
uniform float u_idle_brightness : hint_range(0.0, 2.0) = 0.05; // baseline glow
uniform float u_shimmer_amount : hint_range(0.0, 1.0) = 0.5;   // idle flicker depth
uniform float u_shimmer_speed : hint_range(0.0, 10.0) = 2.0;
uniform float u_tint_strength : hint_range(0.0, 1.0) = 0.6;    // adopt influence color

// --- color (shared colormap convention) ------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
uniform vec3 u_base_color : source_color = vec3(0.1, 0.7, 1.0);

// --- influence fields (shared fixed-size convention) -----------------------
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // magnitude drives brightness (sign ignored)
uniform vec3 u_influence_color[8];

varying vec3 v_color;

void vertex() {
	// Cell centre in world space = this MultiMesh instance's origin.
	vec3 cpos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

	// Proximity response: strongest nearby influence sets the lit intensity; its
	// color tints the cell.
	float lit = 0.0;
	vec3 tint = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		float d = distance(cpos, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		fall = pow(fall, u_falloff) * clamp(abs(u_influence_strength[i]), 0.0, 4.0);
		lit = max(lit, fall);
		tint += u_influence_color[i] * fall;
		wsum += fall;
	}
	vec3 infl_tint = wsum > 0.0001 ? tint / wsum : vec3(0.0);

	// Idle shimmer: per-cell phase (INSTANCE_CUSTOM.x) keeps pixels out of sync.
	float phase = INSTANCE_CUSTOM.x;
	float shimmer = 0.5 + 0.5 * sin(u_time * u_shimmer_speed + phase * 6.2831853);
	float idle = u_idle_brightness * mix(1.0 - u_shimmer_amount, 1.0, shimmer);

	float intensity = idle + lit * u_cell_gain;

	// Colormap hue follows intensity (dark → cool, bright → hot); influence color
	// tints lit cells.
	float t = clamp(intensity, 0.0, 1.0);
	vec3 base = u_use_colormap ? texture(u_colormap, vec2(t, 0.5)).rgb : u_base_color;
	base = mix(base, infl_tint, clamp(lit, 0.0, 1.0) * u_tint_strength);

	v_color = base * intensity;   // HDR-scaled so bright cells bloom
}

void fragment() {
	ALBEDO = v_color;
	EMISSION = v_color;   // treat as pure light regardless of tonemap
}
