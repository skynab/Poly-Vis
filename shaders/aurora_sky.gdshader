shader_type sky;
// Procedural aurora borealis for SceneEnvironment's AURORA mode. Renders animated
// vertical curtains of light (with finer ray striations and color shifting toward
// the tips) over a dark sky, concentrated in a band above the horizon. Driven by
// the built-in sky TIME so it shimmers every frame with no per-frame CPU push.

uniform vec3 u_sky_color : source_color = vec3(0.0, 0.0, 0.0);  // night sky base
uniform vec3 u_color : source_color = vec3(0.1, 0.95, 0.45);    // dominant curtain color
uniform float u_scale = 1.0;       // curtain/ray frequency
uniform float u_speed = 0.15;      // shimmer rate
uniform float u_intensity = 1.5;   // brightness of the curtains

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i + vec3(0.0, 0.0, 0.0)), hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
		mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y),
		f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h = dir.y;                       // height: 0 at horizon, 1 at zenith
	float az = atan(dir.x, dir.z);         // azimuth around the horizon
	float t = TIME * u_speed;

	// Slow horizontal wave that bends the curtains, then high-frequency vertical
	// rays riding on it — the classic striated aurora curtain.
	float wave = fbm(vec3(az * 1.5 * u_scale, t * 0.4, 0.0));
	float rays = fbm(vec3(az * 8.0 * u_scale + wave * 3.0, h * 3.0 - t * 1.2, t * 0.3));
	float aurora = pow(max(rays, 0.0), 1.5);

	// Concentrate into a band above the horizon (fade out at the horizon and zenith).
	float band = smoothstep(0.02, 0.30, h) * (1.0 - smoothstep(0.5, 0.95, h));
	aurora *= band * u_intensity;

	// Vertical color shift: dominant color low, cooler blue higher, magenta tips.
	vec3 aurora_high = mix(u_color, vec3(0.2, 0.4, 1.0), 0.6);
	vec3 aurora_tip = vec3(0.85, 0.2, 0.95);
	float g = clamp((h - 0.05) * 2.2, 0.0, 1.0);
	vec3 col = mix(u_color, aurora_high, g);
	col = mix(col, aurora_tip, smoothstep(0.7, 1.1, aurora));

	COLOR = u_sky_color + col * aurora;
}
