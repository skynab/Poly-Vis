shader_type canvas_item;
// HUD logo drop shadow. Fills the source texture's alpha silhouette with a flat
// shadow color, so the shadow is the logo's SHAPE in the chosen color rather than
// a tint of the logo's own pixels. Used on a TextureRect placed behind the logo
// (same texture/size/stretch, offset by the shadow offset).
uniform vec4 u_shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);

void fragment() {
	float a = texture(TEXTURE, UV).a;
	COLOR = vec4(u_shadow_color.rgb, u_shadow_color.a * a);
}
