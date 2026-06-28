shader_type canvas_item;
// HUD logo drop shadow. Fills the source texture's alpha silhouette with a flat
// shadow color, so the shadow is the logo's SHAPE in the chosen color rather than
// a tint of the logo's own pixels. Used on a TextureRect placed behind the logo
// (same texture/size/stretch, offset by the shadow offset).
//
// u_blur softens the shadow edge: when > 0 the alpha is Gaussian-blurred over a
// radius of u_blur texels (the spread is clamped to the rect bounds, so leave the
// logo image some transparent padding for the blur to bleed into).
uniform vec4 u_shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
uniform float u_blur = 0.0;

void fragment() {
	float a;
	if (u_blur <= 0.01) {
		a = texture(TEXTURE, UV).a;
	} else {
		const int R = 4;            // 9x9 taps
		const float sigma = 2.0;
		float sum = 0.0;
		float wsum = 0.0;
		for (int y = -R; y <= R; y++) {
			for (int x = -R; x <= R; x++) {
				vec2 off = vec2(float(x), float(y)) * TEXTURE_PIXEL_SIZE * (u_blur / float(R));
				float d2 = float(x * x + y * y);
				float w = exp(-d2 / (2.0 * sigma * sigma));
				// Clamp so edge taps read the (transparent) border rather than wrapping.
				a = texture(TEXTURE, clamp(UV + off, vec2(0.0), vec2(1.0))).a;
				sum += a * w;
				wsum += w;
			}
		}
		a = sum / wsum;
	}
	COLOR = vec4(u_shadow_color.rgb, u_shadow_color.a * a);
}
