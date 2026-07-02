shader_type spatial;
// Full-screen post-processing pass for PostFX.gd.
//
// Drawn as a full-screen quad (a MeshInstance3D whose vertex shader writes clip-space
// POSITION directly) so it can read BOTH the screen colour (hint_screen_texture) and
// the scene depth (hint_depth_texture) — depth is only exposed to `spatial` shaders,
// not `canvas_item`, which is why this is a spatial pass. It re-draws the rendered
// image with depth-of-field, motion blur, chromatic aberration, film grain and an
// optional colour grade. Every effect is identity at its zero / default value, so the
// master `enabled` toggle (which hides the quad) leaves the image untouched.
//
// Scope note: `hint_screen_texture` in a 3D pass contains the OPAQUE render, so the
// grade sits under any transparent geometry (particles / ribbons) that composites on
// top. Depth-of-field is likewise an opaque-geometry effect (transparent objects
// don't write depth) — exactly what you want for a focus blur.
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
// Scene depth buffer (spatial-only) — reverse-Z on Forward+, linearized below.
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;

// Vignette — darken toward the edges. amount = max corner darkening (0 = off).
uniform float u_vignette : hint_range(0.0, 1.0) = 0.0;
uniform float u_vignette_softness : hint_range(0.0, 1.0) = 0.4;

// Depth of field — blur pixels by how far their depth is from u_focus_distance.
// amount = max blur (0 = off); focus_distance / focus_range are in world units.
uniform float u_dof : hint_range(0.0, 1.0) = 0.0;
uniform float u_focus_distance = 6.0;
uniform float u_focus_range = 4.0;

// Motion blur — a cheap radial/zoom blur from screen center (0 = off). Stands in
// for a real per-pixel velocity pass, which this pass doesn't have.
uniform float u_mb : hint_range(0.0, 1.0) = 0.0;

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

// Screen sample with chromatic aberration folded in, so aberration applies whether
// or not the blur gather runs. Identity when u_aberration == 0.
vec3 sample_screen(vec2 uv) {
	if (u_aberration > 0.0001) {
		vec2 off = (uv - vec2(0.5)) * (u_aberration * 0.02);
		return vec3(
			texture(screen_tex, uv - off).r,
			texture(screen_tex, uv).g,
			texture(screen_tex, uv + off).b);
	}
	return texture(screen_tex, uv).rgb;
}

// Linearize the depth buffer to a world-space view distance via the inverse
// projection (handles the Forward+ reverse-Z automatically — no near/far uniforms).
float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).x;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -(v.z / v.w);
}

void vertex() {
	// Full-screen triangle/quad: write clip space directly (QuadMesh size 2 → ±1).
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Depth-of-field circle-of-confusion: 0 in the focus band, up to u_dof outside it.
	float coc = 0.0;
	if (u_dof > 0.0001) {
		float dist = linear_depth(uv, INV_PROJECTION_MATRIX);
		coc = clamp(abs(dist - u_focus_distance) / max(u_focus_range, 0.0001), 0.0, 1.0) * u_dof;
	}
	// Motion blur: zoom vector from screen center (zero at center / when u_mb == 0).
	vec2 mb_dir = (uv - vec2(0.5)) * u_mb;

	// Combined gather: a small disc (DoF) plus a radial streak (motion blur), both
	// reading the screen texture. When both are ~0 every tap lands on `uv`, so the
	// result is identity — hence the cheap fast path.
	vec3 col;
	if (coc > 0.0001 || dot(mb_dir, mb_dir) > 0.0000001) {
		const int TAPS = 8;
		vec3 acc = vec3(0.0);
		for (int i = 0; i < TAPS; i++) {
			float t = float(i) / float(TAPS - 1);         // 0..1 along the streak
			float ang = float(i) * 2.3999632;             // golden angle → even disc
			vec2 disc = vec2(cos(ang), sin(ang)) * sqrt(t) * coc * 0.012;
			vec2 radial = -mb_dir * 0.15 * t;
			acc += sample_screen(uv + disc + radial);
		}
		col = acc / float(TAPS);
	} else {
		col = sample_screen(uv);
	}

	// Optional color grade.
	if (u_grade) {
		col = (col - 0.5) * u_contrast + 0.5;
		float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(vec3(l), col, u_saturation);
		col *= u_tint;
	}

	// Film grain: animated per-pixel noise, resolution-independent via viewport size.
	if (u_grain > 0.0001) {
		vec2 px = uv * VIEWPORT_SIZE;
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

	ALBEDO = clamp(col, 0.0, 1.0);
}
