shader_type spatial;
// Fractured Voronoi icosphere (PolyVoronoi).
//
// The surface is split on the CPU (PolyVoronoi.gd) into Voronoi cells; every
// triangle of a cell carries that cell's object-space centroid in CUSTOM0.xyz and
// a per-cell id in CUSTOM0.w. Here the vertex stage translates each cell outward as
// a rigid chunk along its centroid direction, by how close the cell centre is to
// the influence field — so the shell cracks open where an influence is near (the
// gaps between separating cells reveal the interior through the cull_disabled
// backfaces). Because every vertex of a cell shares the same centre + push, the
// cell stays intact and only the seams between cells open. Reuses
// polymesh_deform.gdshader's flat-shading, colormap / posterize / contrast / rim /
// influence-tint conventions.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// --- fracture --------------------------------------------------------------
uniform float u_shatter_amount = 0.6;   // world push per unit influence proximity
uniform float u_gap_falloff : hint_range(0.1, 8.0) = 2.0;  // higher = tighter cracks

uniform vec3 u_base_color : source_color = vec3(0.85, 0.2, 0.45);
uniform float u_roughness : hint_range(0.0, 1.0) = 0.6;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;

// --- colormap (shared convention) ------------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
// 0 world-height, 1 distance-from-center, 2 normal, 3 cell id, 4 shatter amount
uniform int u_color_source = 3;
uniform vec2 u_color_range = vec2(0.0, 1.0);
uniform bool u_posterize = false;
uniform float u_posterize_steps : hint_range(1.0, 32.0) = 5.0;
uniform float u_contrast : hint_range(0.0, 2.0) = 1.0;
uniform float u_brightness : hint_range(0.0, 4.0) = 1.0;

// --- material polish (shared) ----------------------------------------------
uniform float u_rim_strength : hint_range(0.0, 2.0) = 0.0;
uniform float u_rim_power : hint_range(0.5, 8.0) = 2.5;
uniform vec3 u_rim_color : source_color = vec3(1.0);
uniform float u_translucency : hint_range(0.0, 1.0) = 0.0;

// --- influence fields (shared fixed-size convention) -----------------------
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // signed: + cracks open outward, - implodes
uniform vec3 u_influence_color[8];

varying vec3 v_world_pos;
varying vec3 v_obj_pos;
varying float v_cellid;
varying float v_shatter;
varying float v_infl_amt;
varying vec3 v_infl_color;

void vertex() {
	vec3 cell_c = CUSTOM0.xyz;                       // cell centroid (object space)
	vec3 cell_n = normalize(cell_c + vec3(0.0, 0.0001, 0.0));  // rigid push direction
	v_cellid = CUSTOM0.w;

	// Influence proximity is evaluated once per cell, at the cell centre in world
	// space, so every vertex of the cell moves identically (rigid chunk).
	vec3 wcenter = (MODEL_MATRIX * vec4(cell_c, 1.0)).xyz;
	float push = 0.0;
	float infl_amt = 0.0;
	vec3 infl_col = vec3(0.0);
	float infl_wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		float d = distance(wcenter, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		fall = pow(fall, u_gap_falloff);            // sharpen the crack edge
		push += fall * u_influence_strength[i];      // + opens outward, - pulls in
		infl_amt = max(infl_amt, fall);
		infl_col += u_influence_color[i] * fall;
		infl_wsum += fall;
	}
	VERTEX += cell_n * push * u_shatter_amount;
	v_shatter = push;
	v_infl_amt = clamp(infl_amt, 0.0, 1.0);
	v_infl_color = infl_wsum > 0.0001 ? infl_col / infl_wsum : vec3(0.0);

	v_obj_pos = VERTEX;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float color_t() {
	float value;
	if (u_color_source == 0) {
		value = v_world_pos.y;
	} else if (u_color_source == 1) {
		value = length(v_obj_pos);
	} else if (u_color_source == 2) {
		value = normalize(v_obj_pos).y;        // object-space radial dir (camera-stable)
	} else if (u_color_source == 3) {
		value = v_cellid;                       // flat per-cell → Voronoi mosaic
	} else {
		value = v_shatter;                      // how far this cell cracked open
	}
	float t = clamp((value - u_color_range.x) / max(u_color_range.y - u_color_range.x, 0.0001), 0.0, 1.0);
	t = pow(t, 1.0 / max(u_contrast, 0.0001));
	if (u_posterize) {
		t = floor(t * u_posterize_steps) / max(u_posterize_steps - 1.0, 1.0);
	}
	return clamp(t, 0.0, 1.0);
}

void fragment() {
	// Flat-shade: face normal from derivatives of the interpolated view position.
	vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = FRONT_FACING ? face_n : -face_n;

	ALBEDO = u_use_colormap ? texture(u_colormap, vec2(color_t(), 0.5)).rgb : u_base_color;
	ALBEDO = mix(ALBEDO, v_infl_color, v_infl_amt);
	ALBEDO *= u_brightness;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;

	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), u_rim_power);
	EMISSION += u_rim_color * rim * u_rim_strength;
	BACKLIGHT = vec3(u_translucency);
}
