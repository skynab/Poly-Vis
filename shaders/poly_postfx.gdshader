shader_type canvas_item;
// Full-screen post-processing pass for PostFX.gd.
//
// Rendered by a ColorRect on a CanvasLayer that sits above the 3D view but below
// the UI. A BackBufferCopy (viewport mode) feeds the 3D render into the screen
// texture, then this shader re-draws it with vignette, chromatic aberration,
// film grain and an optional color grade. Every effect is identity at its zero /
// default value, so the master `enabled` toggle can leave the image untouched.
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

// Vignette — darken toward the edges. amount = max corner darkening (0 = off).
uniform float u_vignette : hint_range(0.0, 1.0) = 0.0;
uniform float u_vignette_softness : hint_range(0.0, 1.0) = 0.4;

// Chromatic aberration — radial R/B channel split (0 = off), scaled to a small
// fraction of the screen so the 0..1 control stays gentle.
uniform float u_aberration : hint_range(0.0, 1.0) = 0.0;

// Film grain — animated luminance noise (0 = off).
uniform float u_grain : hint_range(0.0, 1.0) = 0.0;
uniform float u_grain_speed : hint_range(0.0, 4.0) = 1.0;

// Color grade — contrast (around mid-grey), saturation, and a tint multiply.
uniform bool u_grade = false;
uniform float u_contrast : hint_range(0.0, 2.0) = 1.0;
uniform float u_saturation : hint_range(0.0, 2.0) = 1.0;
uniform vec3 u_tint : source_color = vec3(1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Chromatic aberration: sample R/B with a radial offset from screen center.
	vec3 col;
	if (u_aberration > 0.0001) {
		vec2 dir = uv - vec2(0.5);
		vec2 off = dir * (u_aberration * 0.02);
		col = vec3(
			texture(screen_tex, uv - off).r,
			texture(screen_tex, uv).g,
			texture(screen_tex, uv + off).b);
	} else {
		col = texture(screen_tex, uv).rgb;
	}

	// Optional color grade.
	if (u_grade) {
		col = (col - 0.5) * u_contrast + 0.5;
		float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(vec3(l), col, u_saturation);
		col *= u_tint;
	}

	// Film grain: animated per-pixel noise, resolution-independent via pixel size.
	if (u_grain > 0.0001) {
		vec2 px = uv / max(SCREEN_PIXEL_SIZE, vec2(0.0001));
		float n = hash(px + fract(TIME * u_grain_speed) * 137.0);
		col += (n - 0.5) * u_grain;
	}

	// Vignette: 0 at center, growing to `amount` darkening at the corners over
	// the outer `softness` band.
	if (u_vignette > 0.0001) {
		float dn = distance(uv, vec2(0.5)) / 0.7071;      // 0 center → 1 corner
		float edge = smoothstep(1.0 - u_vignette_softness, 1.0, dn);
		col *= 1.0 - edge * u_vignette;
	}

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
