shader_type spatial;
// Instanced blade/strand field (PolyStrands).
//
// A dense field of thin blades standing on the y=0 ground plane, baked once on the
// CPU (PolyStrands.gd) as a single mesh. This shader does the per-frame motion: an
// idle wind sway (curl-free position noise) plus influence "combing" — attract
// influences (+strength) bend blades toward them, repel (-strength) push away, with
// a smoothstep falloff over u_influence_radius. Bend grows toward the tip (t^2) and
// is resisted by u_stiffness. Shares the u_influence_* / colormap / posterize / rim
// conventions with polymesh_deform + polycloth.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float u_time = 0.0;

// --- blade motion -----------------------------------------------------------
uniform float u_blade_length : hint_range(0.1, 8.0) = 1.2; // world height; scales bend
uniform float u_stiffness : hint_range(0.05, 8.0) = 1.0;   // higher = resists bending
uniform float u_sway_amount : hint_range(0.0, 2.0) = 0.3;  // idle wind strength
uniform float u_sway_speed : hint_range(0.0, 4.0) = 0.6;   // idle wind rate

// --- surface ----------------------------------------------------------------
uniform float u_roughness : hint_range(0.0, 1.0) = 0.9;
uniform float u_metallic : hint_range(0.0, 1.0) = 0.0;
uniform float u_brightness : hint_range(0.0, 4.0) = 1.0;

// --- color (shared convention) ---------------------------------------------
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = true;
uniform vec3 u_base_color : source_color = vec3(0.10, 0.35, 0.12); // blade root
uniform vec3 u_tip_color : source_color = vec3(0.55, 0.85, 0.30);  // blade tip
uniform bool u_posterize = false;
uniform float u_posterize_steps : hint_range(1.0, 32.0) = 5.0;
uniform float u_contrast : hint_range(0.0, 2.0) = 1.0;

// --- material polish (shared) ----------------------------------------------
uniform float u_rim_strength : hint_range(0.0, 2.0) = 0.3;
uniform float u_rim_power : hint_range(0.5, 8.0) = 2.5;
uniform vec3 u_rim_color : source_color = vec3(1.0);

// --- influence fields (shared fixed-size convention) ------------------------
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];   // signed: + combs toward, - pushes away
uniform vec3 u_influence_color[8];

varying float v_t;           // normalized height along the blade (0 base -> 1 tip)
varying float v_field;       // per-blade field value for the colormap meadow tint
varying float v_infl_amt;
varying vec3 v_infl_color;

// --- Ashima simplex noise (snoise), shared with polycloth -------------------
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
	v_t = UV.y;                         // baked height (0 base -> 1 tip)
	vec2 base_xz = UV2;                 // blade root position, baked in object space
	// Root position in world space, so combing/sway are consistent as the field
	// is translated (matches polycloth's world-space influence sampling).
	vec3 base_world = (MODEL_MATRIX * vec4(base_xz.x, 0.0, base_xz.y, 1.0)).xyz;

	// Per-blade field for the meadow colormap tint (low-freq so it varies in patches).
	v_field = snoise(vec3(base_world.xz * 0.08, 0.0)) * 0.5 + 0.5;

	float tb = v_t * v_t;               // bend concentrates toward the tip

	// Idle wind: two curl-free noise samples give a drifting horizontal direction.
	vec2 sway = vec2(
		snoise(vec3(base_world.xz * 0.15, u_time * u_sway_speed)),
		snoise(vec3(base_world.zx * 0.15 + 37.0, u_time * u_sway_speed))
	) * u_sway_amount;

	// Influence combing: bend toward (+) or away from (-) each influence root.
	vec2 comb = vec2(0.0);
	float infl_amt = 0.0;
	vec3 infl_col = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		vec2 to = u_influence_pos[i].xz - base_world.xz;
		float d = distance(base_world, u_influence_pos[i]);
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		vec2 dir = length(to) > 0.0001 ? normalize(to) : vec2(0.0);
		comb += dir * fall * u_influence_strength[i];
		infl_amt = max(infl_amt, fall);
		infl_col += u_influence_color[i] * fall;
		wsum += fall;
	}
	comb /= max(u_stiffness, 0.01);     // stiffer blades resist the comb

	vec2 disp = (comb + sway) * tb * u_blade_length * 0.5;
	VERTEX.x += disp.x;
	VERTEX.z += disp.y;
	// Slight droop so a leaning blade arcs down instead of stretching taller.
	VERTEX.y -= length(disp) * 0.25;

	v_infl_amt = clamp(infl_amt, 0.0, 1.0);
	v_infl_color = wsum > 0.0001 ? infl_col / wsum : vec3(0.0);
}

void fragment() {
	// Baked flat normal; flip to face the camera under cull_disabled.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;

	float t = clamp(v_t, 0.0, 1.0);
	t = pow(t, 1.0 / max(u_contrast, 0.0001));
	if (u_posterize) {
		t = floor(t * u_posterize_steps) / max(u_posterize_steps - 1.0, 1.0);
	}
	t = clamp(t, 0.0, 1.0);

	// Colormap (when set) drives per-blade meadow color, shaded base->tip; otherwise
	// the tip/base two-color gradient is the fallback — the codebase's colormap-OR
	// -base-color idiom.
	vec3 col;
	if (u_use_colormap) {
		col = texture(u_colormap, vec2(v_field, 0.5)).rgb * mix(0.55, 1.0, t);
	} else {
		col = mix(u_base_color, u_tip_color, t);
	}

	// Tint toward a nearby influence's color.
	col = mix(col, v_infl_color, v_infl_amt * 0.6);

	ALBEDO = col * u_brightness;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;

	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), u_rim_power);
	EMISSION += u_rim_color * rim * u_rim_strength;
}
