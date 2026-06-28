shader_type sky;
// Dynamic noise background for SceneEnvironment's NOISE mode. Renders animated
// fractal value-noise across the sky dome, blending between two colors. Driven by
// the built-in sky TIME so it evolves every frame with no per-frame CPU push.

uniform vec3 color_a : source_color = vec3(0.92, 0.92, 0.94);
uniform vec3 color_b : source_color = vec3(0.62, 0.66, 0.98);
uniform float noise_scale = 2.5;   // spatial frequency of the field
uniform float noise_speed = 0.08;  // animation rate
uniform float contrast = 1.2;      // push the blend toward one color or the other

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
	float t = TIME * noise_speed;
	float n = fbm(EYEDIR * noise_scale + vec3(t, t * 0.5, -t * 0.3));
	n = clamp((n - 0.5) * contrast + 0.5, 0.0, 1.0);
	COLOR = mix(color_a, color_b, n);
}
