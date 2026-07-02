shader_type spatial;
// Raymarched metaball surface (SDF sphere-blend) for PolyMetaballs.gd.
//
// A proxy box (rendered back-faces-only, cull_front) triggers fragments over the
// blob volume; each fragment sphere-traces the scene's SDF from the camera. The
// SDF is a smooth-minimum union of one sphere per active influence, so as two
// influences approach their blobs bulge and merge into one surface. All marching
// is in WORLD space (influences are world-space), so the node transform only
// needs to keep the box big enough to contain the blobs (see u_bounds hint).
//
// Shares the colormap / posterize / contrast / rim / influence conventions with
// polymesh_deform.gdshader: the colormap drives ALBEDO, then the fragment mixes
// toward nearby influence colors exactly like the mesh does.
render_mode cull_front, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

uniform vec3 u_base_color : source_color = vec3(0.85, 0.2, 0.45);
uniform float u_roughness : hint_range(0.0, 1.0) = 0.4;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;

// --- colormap (shared with the mesh) ---------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
// 0 world-height, 1 distance-from-center, 2 normal-Y
uniform int u_color_source = 1;
uniform vec2 u_color_range = vec2(-2.0, 2.0);
uniform bool u_posterize = false;
uniform float u_posterize_steps : hint_range(1.0, 32.0) = 5.0;
uniform float u_contrast : hint_range(0.0, 2.0) = 1.0;
uniform float u_brightness : hint_range(0.0, 4.0) = 1.0;

// --- material polish (shared with the mesh) --------------------------------
uniform float u_rim_strength : hint_range(0.0, 2.0) = 0.0;
uniform float u_rim_power : hint_range(0.5, 8.0) = 2.5;
uniform vec3 u_rim_color : source_color = vec3(1.0);
uniform float u_translucency : hint_range(0.0, 1.0) = 0.0;

// --- metaball field ---------------------------------------------------------
// Base blob radius, scaled per-influence by its normalized radius (radius/2).
uniform float u_blob_radius : hint_range(0.05, 6.0) = 1.0;
// Smooth-min blend width — higher fuses nearby blobs into rounder merges.
uniform float u_smoothness : hint_range(0.0, 4.0) = 0.6;
// Raymarch budget: max sphere-tracing steps per pixel. Primary GPU-cost knob.
uniform int u_max_steps = 96;
// Surface hit threshold; also the finite-difference epsilon for the normal.
uniform float u_surface_eps : hint_range(0.001, 0.1) = 0.01;
// Max marching distance from the camera before giving up (empty pixels discard).
uniform float u_max_dist = 60.0;

// --- influence fields (shared fixed-size convention, MAX_INFLUENCES = 8) ----
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // packed for convention parity (unused here)
uniform vec3 u_influence_color[8];
// Per-influence recent-motion vector (oldest→newest displacement of its path),
// from InfluenceController's shared trajectory buffer. Scaled by u_motion_stretch
// to elongate each blob backward along its path (comet / smear). 0 = no stretch.
uniform vec3 u_influence_motion[8];
uniform float u_motion_stretch : hint_range(0.0, 4.0) = 0.0;

varying vec3 v_world;
varying vec3 v_center;   // node origin in world space (NODE_POSITION_WORLD isn't in fragment)

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

// Polynomial smooth minimum — the blend that makes blobs merge.
float smin(float a, float b, float k) {
	if (k <= 0.0001) { return min(a, b); }
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

// Scene SDF: smooth union of one sphere per active influence. Each sphere is
// optionally elongated backward along its influence's recent motion — sweeping the
// centre from the current position toward the trailing path turns the blob into a
// one-sided capsule (a comet head with a smeared tail).
float map(vec3 p) {
	float d = 1.0e6;
	for (int i = 0; i < u_influence_count; i++) {
		float r = max(u_blob_radius * (u_influence_radius[i] * 0.5), 0.0001);
		vec3 rel = p - u_influence_pos[i];
		vec3 smear = u_influence_motion[i] * u_motion_stretch;
		float len = length(smear);
		if (len > 0.0001) {
			// Sweep the sphere centre along the smear direction over [0, len]:
			// clamp the projection so only the tail side elongates (comet, not a
			// symmetric capsule).
			vec3 dir = smear / len;
			rel -= dir * clamp(dot(rel, dir), 0.0, len);
		}
		float sph = length(rel) - r;
		d = smin(d, sph, u_smoothness);
	}
	return d;
}

vec3 calc_normal(vec3 p) {
	vec2 e = vec2(u_surface_eps, 0.0);
	return normalize(vec3(
		map(p + e.xyy) - map(p - e.xyy),
		map(p + e.yxy) - map(p - e.yxy),
		map(p + e.yyx) - map(p - e.yyx)));
}

float color_t(vec3 hit, vec3 n_world) {
	float value;
	if (u_color_source == 0) {
		value = hit.y;                                   // world height
	} else if (u_color_source == 1) {
		value = distance(hit, v_center);                 // distance from center
	} else {
		value = n_world.y;                               // up-facing normal
	}
	float t = clamp((value - u_color_range.x) / max(u_color_range.y - u_color_range.x, 0.0001), 0.0, 1.0);
	t = pow(t, 1.0 / max(u_contrast, 0.0001));
	if (u_posterize) {
		t = floor(t * u_posterize_steps) / max(u_posterize_steps - 1.0, 1.0);
	}
	return clamp(t, 0.0, 1.0);
}

void fragment() {
	if (u_influence_count == 0) { discard; }

	// Sphere-trace from the camera toward this back-face fragment. In empty space
	// map() returns large distances, so the ray leaps across the void cheaply.
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(v_world - ro);
	float t = 0.0;
	bool hit = false;
	for (int s = 0; s < u_max_steps; s++) {
		vec3 p = ro + rd * t;
		float d = map(p);
		if (d < u_surface_eps) { hit = true; break; }
		t += d;
		if (t > u_max_dist) { break; }
	}
	if (!hit) { discard; }

	vec3 hit_world = ro + rd * t;
	vec3 n_world = calc_normal(hit_world);

	// Write true scene depth so the blob occludes / is occluded like solid geometry.
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(hit_world, 1.0);
	DEPTH = clip.z / clip.w;

	// View-space normal for the built-in lighting.
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	vec3 col = u_use_colormap ? texture(u_colormap, vec2(color_t(hit_world, n_world), 0.5)).rgb : u_base_color;

	// Influence tint: mix toward nearby influence colors, same as the mesh shader.
	float infl_amt = 0.0;
	vec3 infl_col = vec3(0.0);
	float infl_wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		float dd = distance(hit_world, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), dd);
		infl_amt = max(infl_amt, fall);
		infl_col += u_influence_color[i] * fall;
		infl_wsum += fall;
	}
	if (infl_wsum > 0.0001) {
		col = mix(col, infl_col / infl_wsum, clamp(infl_amt, 0.0, 1.0));
	}

	ALBEDO = col * u_brightness;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;

	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), u_rim_power);
	EMISSION += u_rim_color * rim * u_rim_strength;
	BACKLIGHT = vec3(u_translucency);
}
