shader_type spatial;
// Low-poly faceted surface with optional animated displacement (Prompt 1.3).
//
// Displacement is driven entirely by uniforms (cheap, GPU-side). Flat per-face
// normals are recomputed in the fragment stage from screen-space derivatives of
// the view-space position, so the surface stays faceted even while it churns.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float u_time = 0.0;
uniform float u_anim_amplitude = 0.0;   // 0 == static
uniform float u_anim_frequency = 1.2;
uniform float u_anim_speed = 0.6;
uniform vec3 u_base_color : source_color = vec3(0.85, 0.2, 0.45);
uniform float u_roughness : hint_range(0.0, 1.0) = 0.7;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;

// --- colormap (Prompt 3.1) -------------------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = false;
// 0 world-height, 1 distance-from-center, 2 normal, 3 displacement, 4 noise
uniform int u_color_source = 1;
uniform vec2 u_color_range = vec2(-1.8, 1.8);
uniform bool u_posterize = false;
uniform float u_posterize_steps : hint_range(1.0, 32.0) = 5.0;

// --- material polish (Prompt 3.2) ------------------------------------------
uniform float u_rim_strength : hint_range(0.0, 2.0) = 0.0;
uniform float u_rim_power : hint_range(0.5, 8.0) = 2.5;
uniform vec3 u_rim_color : source_color = vec3(1.0);
uniform float u_translucency : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world_pos;
varying vec3 v_obj_pos;
varying float v_disp;

// --- Ashima simplex noise (snoise) -----------------------------------------
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 1.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(vec3 v) {
	const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
	const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
	vec3 i = floor(v + dot(v, C.yyy));
	vec3 x0 = v - i + dot(i, C.xxx);
	vec3 g = step(x0.yzx, x0.xyz);
	vec3 l = 1.0 - g;
	vec3 i1 = min(g.xyz, l.zxy);
	vec3 i2 = max(g.xyz, l.zxy);
	vec3 x1 = x0 - i1 + C.xxx;
	vec3 x2 = x0 - i2 + C.yyy;
	vec3 x3 = x0 - D.yyy;
	i = mod289(i);
	vec4 p = permute(permute(permute(
			i.z + vec4(0.0, i1.z, i2.z, 1.0))
			+ i.y + vec4(0.0, i1.y, i2.y, 1.0))
			+ i.x + vec4(0.0, i1.x, i2.x, 1.0));
	float n_ = 0.142857142857;
	vec3 ns = n_ * D.wyz - D.xzx;
	vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
	vec4 x_ = floor(j * ns.z);
	vec4 y_ = floor(j - 7.0 * x_);
	vec4 x = x_ * ns.x + ns.yyyy;
	vec4 y = y_ * ns.x + ns.yyyy;
	vec4 h = 1.0 - abs(x) - abs(y);
	vec4 b0 = vec4(x.xy, y.xy);
	vec4 b1 = vec4(x.zw, y.zw);
	vec4 s0 = floor(b0) * 2.0 + 1.0;
	vec4 s1 = floor(b1) * 2.0 + 1.0;
	vec4 sh = -step(h, vec4(0.0));
	vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
	vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
	vec3 p0 = vec3(a0.xy, h.x);
	vec3 p1 = vec3(a0.zw, h.y);
	vec3 p2 = vec3(a1.xy, h.z);
	vec3 p3 = vec3(a1.zw, h.w);
	vec4 norm = taylorInvSqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
	p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
	vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
	m = m * m;
	return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}
// ---------------------------------------------------------------------------

void vertex() {
	vec3 dir = normalize(VERTEX);
	float n = snoise(VERTEX * u_anim_frequency + vec3(0.0, u_time * u_anim_speed, 0.0));
	v_disp = n;
	VERTEX += dir * n * u_anim_amplitude;
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
		value = abs(v_disp);                    // displacement magnitude
	} else {
		value = v_disp;                         // raw noise
	}
	float t = clamp((value - u_color_range.x) / max(u_color_range.y - u_color_range.x, 0.0001), 0.0, 1.0);
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
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;

	// Rim glow (view-dependent fresnel added as emission) + soft translucency.
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), u_rim_power);
	EMISSION += u_rim_color * rim * u_rim_strength;
	BACKLIGHT = vec3(u_translucency);
}
