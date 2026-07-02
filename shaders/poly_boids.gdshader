shader_type particles;
// Boid flocking particle motion (PolyBoids).
//
// A GPU-friendly approximation of Reynolds' boids. A `shader_type particles` pass
// can't query other particles' state, so the three classic steering rules are
// approximated from shared noise fields keyed off u_neighbor_radius (the flock's
// characteristic length):
//   * ALIGNMENT — follow the local curl-noise heading; neighbours sample nearly the
//     same field, so they travel together (matched headings, like a murmuration).
//   * COHESION  — ascend a low-frequency attractor field toward the local flock
//     centre, so groups gather.
//   * SEPARATION— descend a high-frequency field, so crowded boids space apart.
// Influences act as attractors (+strength, gather) or predators (−strength, flee)
// via the shared u_influence_* arrays. Speed is capped at u_max_speed. Colour /
// palette / colormap / brightness match particle_flow.gdshader.
//
// Position is integrated by the engine from VELOCITY (no disable_velocity mode).

uniform int u_emitter_shape = 1;          // 0 point, 1 sphere, 2 box, 3 mesh-surface
uniform vec3 u_emitter_extents = vec3(1.0);
uniform vec3 u_direction = vec3(0.0, 1.0, 0.0);
uniform float u_initial_speed = 1.0;
uniform float u_spread : hint_range(0.0, 1.0) = 0.3;
uniform vec3 u_gravity = vec3(0.0, 0.0, 0.0);

// --- flocking --------------------------------------------------------------
uniform float u_neighbor_radius = 1.5;    // characteristic flock length
uniform float u_separation = 1.2;         // spacing weight
uniform float u_alignment = 1.0;          // heading-match weight
uniform float u_cohesion = 0.8;           // gather weight
uniform float u_max_speed = 4.0;          // boid speed cap
uniform float u_wander_speed = 0.4;       // how fast the fields scroll (flock drift)
uniform float u_drag : hint_range(0.0, 4.0) = 0.1;
uniform float u_seed = 0.0;

// Particle appearance
uniform float u_particle_size = 0.05;
uniform bool  u_size_curve    = false;    // shrink to 0 over lifetime
uniform float u_particle_brightness = 1.0;

uniform vec3 u_color_a : source_color = vec3(0.1, 0.8, 0.7);
uniform vec3 u_color_b : source_color = vec3(0.95, 0.95, 0.2);

// Palette mode (up to 6 colors); overrides colormap / a-b lerp when count > 0.
uniform int u_palette_count = 0;
uniform vec4 u_palette[6] : source_color;

// Shared colormap. When disabled, falls back to a/b lerp by age.
uniform sampler2D u_colormap : source_color, filter_linear;
uniform bool u_use_colormap = false;
// 0 height, 1 distance, 2 age, 3 velocity, 4 noise
uniform int u_color_source = 3;
uniform vec2 u_color_range = vec2(0.0, 6.0);

// Mesh-surface emission points, baked by PolyBoids.gd (one texel per vertex).
uniform sampler2D emission_points : filter_nearest, repeat_disable;
uniform int u_point_count = 0;

// Influence fields: signed strength + attracts (gather), - repels (predator flee).
uniform int u_influence_count = 0;
uniform vec3 u_influence_pos[8];
uniform float u_influence_radius[8];
uniform float u_influence_strength[8];
uniform vec3 u_influence_color[8];

// --- hash RNG --------------------------------------------------------------
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}
vec3 hash31(float p) {
	vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx) * 2.0 - 1.0;
}

// --- Ashima simplex noise --------------------------------------------------
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

// Divergence-free curl of a 3D noise potential (used for the alignment heading).
vec3 curl_noise(vec3 p) {
	const float e = 0.1;
	vec3 dx = vec3(e, 0.0, 0.0);
	vec3 dy = vec3(0.0, e, 0.0);
	vec3 dz = vec3(0.0, 0.0, e);
	vec3 p_x0 = vec3(snoise(p - dx), snoise(p - dx + vec3(31.4)), snoise(p - dx + vec3(67.2)));
	vec3 p_x1 = vec3(snoise(p + dx), snoise(p + dx + vec3(31.4)), snoise(p + dx + vec3(67.2)));
	vec3 p_y0 = vec3(snoise(p - dy), snoise(p - dy + vec3(31.4)), snoise(p - dy + vec3(67.2)));
	vec3 p_y1 = vec3(snoise(p + dy), snoise(p + dy + vec3(31.4)), snoise(p + dy + vec3(67.2)));
	vec3 p_z0 = vec3(snoise(p - dz), snoise(p - dz + vec3(31.4)), snoise(p - dz + vec3(67.2)));
	vec3 p_z1 = vec3(snoise(p + dz), snoise(p + dz + vec3(31.4)), snoise(p + dz + vec3(67.2)));
	float x = (p_y1.z - p_y0.z) - (p_z1.y - p_z0.y);
	float y = (p_z1.x - p_z0.x) - (p_x1.z - p_x0.z);
	float z = (p_x1.y - p_x0.y) - (p_y1.x - p_y0.x);
	return vec3(x, y, z) / (2.0 * e);
}

// Gradient of a scalar noise field at p — points uphill (toward higher values).
vec3 grad_noise(vec3 p) {
	const float e = 0.15;
	float nx = snoise(p + vec3(e, 0.0, 0.0)) - snoise(p - vec3(e, 0.0, 0.0));
	float ny = snoise(p + vec3(0.0, e, 0.0)) - snoise(p - vec3(0.0, e, 0.0));
	float nz = snoise(p + vec3(0.0, 0.0, e)) - snoise(p - vec3(0.0, 0.0, e));
	return vec3(nx, ny, nz) / (2.0 * e);
}

vec3 emit_local_position(float r) {
	if (u_emitter_shape == 0) {
		return vec3(0.0);                                   // point
	} else if (u_emitter_shape == 1) {
		vec3 d = normalize(hash31(r + 1.0) + 0.0001);
		float rad = pow(hash11(r + 2.0), 1.0 / 3.0);
		return d * rad * u_emitter_extents.x;               // sphere (volume)
	} else if (u_emitter_shape == 2) {
		return hash31(r + 3.0) * u_emitter_extents;         // box
	} else {
		int idx = int(hash11(r + 4.0) * float(max(u_point_count, 1)));
		return texelFetch(emission_points, ivec2(idx, 0), 0).xyz;  // mesh surface
	}
}

void start() {
	float r = float(INDEX) + u_seed * 1000.0 + float(NUMBER) * 0.013;
	vec3 local_pos = emit_local_position(r);
	TRANSFORM[3].xyz = (EMISSION_TRANSFORM * vec4(local_pos, 1.0)).xyz;

	vec3 jitter = hash31(r + 5.0) * u_spread;
	vec3 dir = normalize(u_direction + jitter + vec3(0.0, 0.0001, 0.0));
	VELOCITY = (EMISSION_TRANSFORM * vec4(dir * u_initial_speed, 0.0)).xyz;

	// x: per-particle seed  y: age fraction (accumulated in process)
	CUSTOM = vec4(hash11(r + 6.0), 0.0, hash11(r + 7.0) * 2.0 - 1.0, 0.0);

	TRANSFORM[0].xyz = vec3(u_particle_size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, u_particle_size, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, u_particle_size);
}

void process() {
	vec3 pos = TRANSFORM[3].xyz;
	float L = max(u_neighbor_radius, 0.001);
	float ts = TIME * u_wander_speed;

	// --- three boid rules, approximated from shared fields -------------------
	// Alignment: local coherent heading (curl noise at the neighbourhood scale).
	vec3 align = normalize(curl_noise(pos / L + vec3(0.0, ts, 0.0)) + vec3(0.0001));
	// Cohesion: climb a low-frequency attractor toward the local flock centre.
	vec3 coh = normalize(grad_noise(pos * (0.5 / L) + vec3(ts * 0.3)) + vec3(0.0001));
	// Separation: descend a high-frequency field so crowded boids spread out.
	vec3 sep = -normalize(grad_noise(pos * (3.0 / L) + vec3(19.0)) + vec3(0.0001));

	vec3 steer = align * u_alignment + coh * u_cohesion + sep * u_separation;
	VELOCITY += steer * u_max_speed * DELTA;
	VELOCITY += u_gravity * DELTA;

	// Influences: attractors (+) pull the flock in, predators (−) send it fleeing.
	float iamt = 0.0;
	vec3 icol = vec3(0.0);
	float iw = 0.0;
	for (int i = 0; i < u_influence_count; i++) {
		vec3 to = u_influence_pos[i] - pos;
		float d = length(to) + 0.0001;
		float fall = 1.0 - smoothstep(0.0, max(u_influence_radius[i], 0.0001), d);
		VELOCITY += (to / d) * u_influence_strength[i] * fall * u_max_speed * 2.0 * DELTA;
		iamt = max(iamt, fall);
		icol += u_influence_color[i] * fall;
		iw += fall;
	}

	VELOCITY *= clamp(1.0 - u_drag * DELTA, 0.0, 1.0);

	// Boid speed limit.
	float sp = length(VELOCITY);
	if (sp > u_max_speed) {
		VELOCITY = VELOCITY / sp * u_max_speed;
	}

	CUSTOM.y = clamp(CUSTOM.y + DELTA / LIFETIME, 0.0, 1.0);

	// --- orient the particle so its long (+Y) axis points along travel --------
	float sz = u_particle_size * (u_size_curve ? max(1.0 - CUSTOM.y, 0.0) : 1.0);
	vec3 vdir = sp > 0.0001 ? VELOCITY / sp : vec3(0.0, 1.0, 0.0);
	vec3 up = abs(vdir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 rgt = normalize(cross(up, vdir));
	vec3 fwd = cross(vdir, rgt);
	TRANSFORM[0].xyz = rgt * sz;
	TRANSFORM[1].xyz = vdir * sz;   // mesh long axis follows heading
	TRANSFORM[2].xyz = fwd * sz;

	float cval;
	if (u_color_source == 0) {
		cval = pos.y;
	} else if (u_color_source == 1) {
		cval = length(pos);
	} else if (u_color_source == 2) {
		cval = CUSTOM.y;
	} else if (u_color_source == 3) {
		cval = length(VELOCITY);
	} else {
		cval = snoise(pos / L);
	}
	float ct = clamp((cval - u_color_range.x) / max(u_color_range.y - u_color_range.x, 0.0001), 0.0, 1.0);
	if (u_palette_count > 0) {
		int pi = min(int(CUSTOM.x * float(u_palette_count)), u_palette_count - 1);
		COLOR = vec4(u_palette[pi].rgb, 1.0);
	} else if (u_use_colormap) {
		COLOR = vec4(texture(u_colormap, vec2(ct, 0.5)).rgb, 1.0);
	} else {
		COLOR = vec4(mix(u_color_a, u_color_b, ct), 1.0);
	}
	if (iw > 0.0001) {
		COLOR.rgb = mix(COLOR.rgb, icol / iw, iamt);
	}
	COLOR.rgb *= u_particle_brightness;
}
