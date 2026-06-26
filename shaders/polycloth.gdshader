shader_type spatial;
// Crumpled low-poly cloth surface (Prompt 9.x).
//
// Companion to polymesh_deform.gdshader but built for a draped plane instead of
// an icosphere: animated displacement and influence dents ride along world-up
// (coherent, crack-free), and the fragment stage adds a warm/cool two-tone split
// driven by face orientation — the pink-vs-periwinkle facet look of the
// reference image. The heavy static crumple is baked on the CPU (PolyCloth.gd);
// this shader handles flat shading, colormap, the cool tint, rim, and influence.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float u_time = 0.0;
uniform float u_anim_amplitude = 0.0;   // 0 == static
uniform float u_anim_frequency = 0.6;
uniform float u_anim_speed = 0.4;
uniform float u_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;

// --- colormap (shared with the mesh) ---------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
uniform vec3 u_base_color : source_color = vec3(0.85, 0.2, 0.45);
// 0 world-height, 1 planar-distance, 2 normal, 3 fold, 4 noise
uniform int u_color_source = 2;
uniform vec2 u_color_range = vec2(-1.0, 1.0);
uniform bool u_posterize = false;
uniform float u_posterize_steps : hint_range(1.0, 32.0) = 5.0;
uniform float u_contrast : hint_range(0.0, 2.0) = 1.0;
uniform float u_brightness : hint_range(0.0, 4.0) = 1.0;

// --- warm / cool two-tone --------------------------------------------------
// Faces oriented toward u_cool_dir pick up the cool tint; everything else keeps
// the warm colormap. This is what creates the periwinkle-vs-pink facet split.
uniform vec3 u_cool_color : source_color = vec3(0.62, 0.66, 0.98);
uniform float u_cool_strength : hint_range(0.0, 1.0) = 0.7;
uniform vec3 u_cool_dir = vec3(0.3, 1.0, 0.2);

// --- material polish --------------------------------------------------------
uniform float u_rim_strength : hint_range(0.0, 2.0) = 0.3;
uniform float u_rim_power : hint_range(0.5, 8.0) = 2.5;
uniform vec3 u_rim_color : source_color = vec3(1.0);
uniform float u_translucency : hint_range(0.0, 1.0) = 0.0;

// --- influence fields -------------------------------------------------------
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // signed: + presses in, - lifts out
uniform vec3 u_influence_color[8];

varying vec3 v_world_pos;
varying vec3 v_obj_pos;
varying vec3 v_face_n;       // baked object-space face normal (camera-stable color)
varying vec2 v_aux;          // x: baked height-noise, y: baked fold magnitude
varying float v_infl_amt;
varying vec3 v_infl_color;

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
	v_aux = UV2;
	v_face_n = NORMAL;   // object-space mesh normal — stable under camera orbit
	// Animated wave rides along world-up using a noise of the planar position,
	// so neighbouring triangles move together (no facet cracks).
	float wave = snoise(vec3(VERTEX.x * u_anim_frequency, VERTEX.z * u_anim_frequency,
			u_time * u_anim_speed));
	VERTEX.y += wave * u_anim_amplitude;

	// Influence fields press the cloth in (attract +) or lift it out (repel -).
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float infl_disp = 0.0;
	float infl_amt = 0.0;
	vec3 infl_col = vec3(0.0);
	float infl_wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		float d = distance(wpos, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		infl_disp -= fall * u_influence_strength[i];
		infl_amt = max(infl_amt, fall);
		infl_col += u_influence_color[i] * fall;
		infl_wsum += fall;
	}
	VERTEX.y += infl_disp;
	v_infl_amt = clamp(infl_amt, 0.0, 1.0);
	v_infl_color = infl_wsum > 0.0001 ? infl_col / infl_wsum : vec3(0.0);

	v_obj_pos = VERTEX;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float color_t(vec3 face_n) {
	float value;
	if (u_color_source == 0) {
		value = v_world_pos.y;
	} else if (u_color_source == 1) {
		value = length(v_obj_pos.xz);            // planar distance from center
	} else if (u_color_source == 2) {
		value = face_n.y;                        // up-facing facets read light
	} else if (u_color_source == 3) {
		value = v_aux.y;                         // baked fold magnitude
	} else {
		value = v_aux.x;                         // baked height noise
	}
	float t = clamp((value - u_color_range.x) / max(u_color_range.y - u_color_range.x, 0.0001), 0.0, 1.0);
	t = pow(t, 1.0 / max(u_contrast, 0.0001));
	if (u_posterize) {
		t = floor(t * u_posterize_steps) / max(u_posterize_steps - 1.0, 1.0);
	}
	return clamp(t, 0.0, 1.0);
}

void fragment() {
	// Flat-shade lighting: per-face view-space normal from screen derivatives,
	// so rim/lighting still react to the animated surface.
	vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = FRONT_FACING ? face_n : -face_n;

	// Color decisions use the baked OBJECT-space normal so the warm/cool split
	// stays put as the camera orbits (matches PolyMesh's camera-stable coloring).
	vec3 cn = normalize(v_face_n);
	vec3 warm = u_use_colormap ? texture(u_colormap, vec2(color_t(cn), 0.5)).rgb : u_base_color;

	float facing = clamp(dot(cn, normalize(u_cool_dir)), 0.0, 1.0);
	vec3 col = mix(warm, u_cool_color, facing * u_cool_strength);

	col = mix(col, v_infl_color, v_infl_amt);
	ALBEDO = col * u_brightness;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;

	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), u_rim_power);
	EMISSION += u_rim_color * rim * u_rim_strength;
	BACKLIGHT = vec3(u_translucency);
}
