extends CanvasLayer
## Heads-up-display logo overlay (Prompt 10.x).
##
## Renders a logo image over the front of the view. Ships the OptiTrack white and
## black logos as presets and accepts any imported image file as a custom logo.
##
## Lives on its OWN CanvasLayer at layer 0 — below the panel's layer (default 1)
## so the panel always draws on top, yet ABOVE the 3D view. Because it is not the
## CaptureManager's `ui_layer`, it stays visible in screenshots/recordings: the
## logo acts as a branding watermark on exported media, unlike the panel + FPS.
##
## Schema-driven like SceneEnvironment: editable in the ParameterPanel and
## serialized by CompositionIO under the "hud" key.
class_name HudLogo

enum LogoSource { OPTITRACK_WHITE, OPTITRACK_BLACK, CUSTOM }
enum LogoCorner { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, CENTER }

const WHITE_TEX := preload("res://resources/logos/optitrack_white.png")
const BLACK_TEX := preload("res://resources/logos/optitrack_black.png")
const SHADOW_SHADER := preload("res://shaders/hud_shadow.gdshader")

@export var enabled: bool = false: set = set_enabled
@export var logo: LogoSource = LogoSource.OPTITRACK_BLACK: set = set_logo
## Filesystem path of an imported custom image (used when logo == CUSTOM).
## Set via the Import button; serialized so custom logos survive save/load.
@export var custom_path: String = "": set = set_custom_path
@export var corner: LogoCorner = LogoCorner.BOTTOM_LEFT: set = set_corner
## Logo width as a fraction of the viewport width (height follows aspect).
@export_range(0.02, 0.6) var size_scale: float = 0.16: set = set_size_scale
@export_range(0.0, 1.0) var opacity: float = 1.0: set = set_opacity
@export_range(0.0, 200.0) var margin: float = 24.0: set = set_margin

@export_group("Drop Shadow")
@export var shadow_enabled: bool = false: set = set_shadow_enabled
## Shadow color (alpha controls shadow strength). It fills the logo's silhouette.
@export var shadow_color: Color = Color(0.0, 0.0, 0.0, 0.5): set = set_shadow_color
@export_range(-100.0, 100.0) var shadow_offset_x: float = 8.0: set = set_shadow_offset_x
@export_range(-100.0, 100.0) var shadow_offset_y: float = 8.0: set = set_shadow_offset_y
## Softens the shadow edge — Gaussian blur radius in texels (0 = hard silhouette).
## The blur is clamped to the logo rect, so very large values are limited by the
## image's transparent padding.
@export_range(0.0, 50.0) var shadow_blur: float = 0.0: set = set_shadow_blur

var _rect: TextureRect
var _shadow: TextureRect
var _file_dlg: FileDialog

func _ready() -> void:
	layer = 0  # below the panel CanvasLayer, above the 3D view
	_ensure_rect()
	var vp := get_viewport()
	if vp and not vp.size_changed.is_connected(_update_layout):
		vp.size_changed.connect(_update_layout)
	_apply()

func _ensure_rect() -> void:
	if is_instance_valid(_rect):
		return
	# Shadow first so it renders BEHIND the logo. Same texture/size/stretch; a
	# silhouette shader recolors the logo's alpha to the shadow color.
	_shadow = _new_logo_rect("LogoShadow")
	var mat := ShaderMaterial.new()
	mat.shader = SHADOW_SHADER
	_shadow.material = mat
	add_child(_shadow)

	_rect = _new_logo_rect("LogoRect")
	add_child(_rect)

func _new_logo_rect(rect_name: String) -> TextureRect:
	var r := TextureRect.new()
	r.name = rect_name
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never intercept camera input
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	return r

# --- texture + layout ------------------------------------------------------
## Re-resolve the texture (reads disk for custom logos) and refresh everything.
func _apply() -> void:
	if not is_instance_valid(_rect):
		return
	var tex := _resolve_texture()
	_rect.texture = tex
	_rect.visible = enabled and tex != null
	_rect.modulate = Color(1, 1, 1, opacity)
	if is_instance_valid(_shadow):
		_shadow.texture = tex
		_shadow.visible = enabled and shadow_enabled and tex != null
		_shadow.modulate = Color(1, 1, 1, opacity)
		var m := _shadow.material as ShaderMaterial
		if m:
			m.set_shader_parameter("u_shadow_color", shadow_color)
			m.set_shader_parameter("u_blur", shadow_blur)
	_update_layout()

func _resolve_texture() -> Texture2D:
	match logo:
		LogoSource.OPTITRACK_WHITE:
			return WHITE_TEX
		LogoSource.OPTITRACK_BLACK:
			return BLACK_TEX
		_:
			return _load_external(custom_path)

## Load an arbitrary image. res:// or user:// go through the resource loader;
## anything else is an OS path loaded as a raw image at runtime.
func _load_external(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if path.begins_with("res://") or path.begins_with("user://"):
		var res := load(path)
		return res if res is Texture2D else null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

func _update_layout() -> void:
	if not is_instance_valid(_rect) or _rect.texture == null:
		return
	var vp_size := get_viewport().get_visible_rect().size
	var tex_size := _rect.texture.get_size()
	if tex_size.x <= 0.0:
		return
	var w := vp_size.x * size_scale
	var h := w * (tex_size.y / tex_size.x)
	_rect.size = Vector2(w, h)
	var x := margin
	var y := margin
	match corner:
		LogoCorner.TOP_RIGHT:
			x = vp_size.x - w - margin
		LogoCorner.BOTTOM_LEFT:
			y = vp_size.y - h - margin
		LogoCorner.BOTTOM_RIGHT:
			x = vp_size.x - w - margin
			y = vp_size.y - h - margin
		LogoCorner.CENTER:
			x = (vp_size.x - w) * 0.5
			y = (vp_size.y - h) * 0.5
	_rect.position = Vector2(x, y)
	if is_instance_valid(_shadow):
		_shadow.size = Vector2(w, h)
		_shadow.position = Vector2(x + shadow_offset_x, y + shadow_offset_y)

# --- import ----------------------------------------------------------------
## Action button: pick any image file; on selection switch to the custom logo.
func import_logo() -> void:
	if not is_instance_valid(_file_dlg):
		_file_dlg = FileDialog.new()
		_file_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dlg.access = FileDialog.ACCESS_FILESYSTEM
		_file_dlg.filters = PackedStringArray([
			"*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga ; Image Files"])
		_file_dlg.title = "Import Logo Image"
		_file_dlg.size = Vector2i(640, 460)
		_file_dlg.file_selected.connect(_on_logo_picked)
		add_child(_file_dlg)
	_file_dlg.popup_centered()

func _on_logo_picked(path: String) -> void:
	custom_path = path
	logo = LogoSource.CUSTOM
	enabled = true

# --- setters ---------------------------------------------------------------
func set_enabled(v: bool) -> void:
	enabled = v
	_apply()

func set_logo(v: LogoSource) -> void:
	logo = v
	_apply()

func set_custom_path(v: String) -> void:
	custom_path = v
	_apply()

func set_corner(v: LogoCorner) -> void:
	corner = v
	_update_layout()

func set_size_scale(v: float) -> void:
	size_scale = v
	_update_layout()

func set_opacity(v: float) -> void:
	opacity = v
	if is_instance_valid(_rect):
		_rect.modulate = Color(1, 1, 1, opacity)
	if is_instance_valid(_shadow):
		_shadow.modulate = Color(1, 1, 1, opacity)

func set_margin(v: float) -> void:
	margin = v
	_update_layout()

func set_shadow_enabled(v: bool) -> void:
	shadow_enabled = v
	if is_instance_valid(_shadow):
		_shadow.visible = enabled and shadow_enabled and _rect != null and _rect.texture != null

func set_shadow_color(v: Color) -> void:
	shadow_color = v
	if is_instance_valid(_shadow):
		var m := _shadow.material as ShaderMaterial
		if m:
			m.set_shader_parameter("u_shadow_color", v)

func set_shadow_offset_x(v: float) -> void:
	shadow_offset_x = v
	_update_layout()

func set_shadow_offset_y(v: float) -> void:
	shadow_offset_y = v
	_update_layout()

func set_shadow_blur(v: float) -> void:
	shadow_blur = v
	if is_instance_valid(_shadow):
		var m := _shadow.material as ShaderMaterial
		if m:
			m.set_shader_parameter("u_blur", v)

## Restore defaults (logo off) when a loaded composition has no "hud" block.
func reset_defaults() -> void:
	enabled = false
	logo = LogoSource.OPTITRACK_BLACK
	custom_path = ""
	corner = LogoCorner.BOTTOM_LEFT
	size_scale = 0.16
	opacity = 1.0
	margin = 24.0
	shadow_enabled = false
	shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	shadow_offset_x = 8.0
	shadow_offset_y = 8.0
	shadow_blur = 0.0

func get_param_schema() -> Array:
	return [{
		"title": "HUD Logo",
		"props": [
			{"name": "enabled", "type": "bool"},
			{"name": "logo", "type": "enum", "options": ["OptiTrack White", "OptiTrack Black", "Custom"]},
			# Editable text field (or set via the Import button below); also serializes.
			{"name": "custom_path", "type": "string", "hint": "Path to a custom logo image"},
			{"name": "corner", "type": "enum", "options": ["Top Left", "Top Right", "Bottom Left", "Bottom Right", "Center"]},
			{"name": "size_scale", "type": "float", "min": 0.02, "max": 0.6, "step": 0.01},
			{"name": "opacity", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "margin", "type": "float", "min": 0.0, "max": 200.0, "step": 1.0},
			{"name": "shadow_enabled", "type": "bool"},
			{"name": "shadow_color", "type": "color"},
			{"name": "shadow_offset_x", "type": "float", "min": -100.0, "max": 100.0, "step": 1.0},
			{"name": "shadow_offset_y", "type": "float", "min": -100.0, "max": 100.0, "step": 1.0},
			{"name": "shadow_blur", "type": "float", "min": 0.0, "max": 50.0, "step": 0.5},
			{"name": "import_logo", "type": "action", "label": "Import Logo…",
				"hint": "Choose any image file to display as the logo"},
		]
	}]
