extends RefCounted
## Full-screen post-processing global module (vignette / chromatic aberration /
## film grain / optional color grade).
##
## Schema-driven like SceneEnvironment / WallConfig / AudioReactor: editable in
## the ParameterPanel and serialized by CompositionIO under the "postfx" key.
## Being RefCounted it can't live in the tree itself, so bind(host) creates the
## render nodes and parents them — mirroring SceneEnvironment.bind(env, host) and
## AudioReactor.bind(host).
##
## The pass is a ColorRect + screen-reading shader on its OWN CanvasLayer at
## layer 0 — above the 3D view, below the UI panel (layer 1). Like HudLogo it is
## NOT the CaptureManager's `ui_layer`, so the effect is baked into
## screenshots/recordings, while the UI (which sits above it) is hidden during
## capture and never gets post-processed. A BackBufferCopy in viewport mode feeds
## the 3D render into the shader's screen texture.
class_name PostFX

const POSTFX_SHADER := preload("res://shaders/poly_postfx.gdshader")

## Master switch — when off the whole pass is hidden (zero cost, image untouched).
var enabled: bool = false: set = set_enabled
## Edge darkening strength (0 = off) and the width of the darkened band.
var vignette_amount: float = 0.0: set = set_vignette_amount
var vignette_softness: float = 0.4: set = set_vignette_softness
## Radial R/B channel split at the edges (0 = off).
var aberration_amount: float = 0.0: set = set_aberration_amount
## Animated luminance noise (0 = off) and its temporal speed.
var grain_amount: float = 0.0: set = set_grain_amount
var grain_speed: float = 1.0: set = set_grain_speed
## Optional color grade: contrast around mid-grey, saturation, and a tint multiply.
var color_grade_enabled: bool = false: set = set_color_grade_enabled
var grade_contrast: float = 1.0: set = set_grade_contrast
var grade_saturation: float = 1.0: set = set_grade_saturation
var grade_tint: Color = Color(1, 1, 1): set = set_grade_tint

var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial

## Create the CanvasLayer + BackBufferCopy + ColorRect under `host` (Main). Added
## before HudLogo so the effect processes the 3D view and the logo overlays on top
## un-graded; the UI panel (layer 1) always stays above and un-processed.
func bind(host: Node) -> void:
	if is_instance_valid(_layer):
		return
	_layer = CanvasLayer.new()
	_layer.name = "PostFX"
	_layer.layer = 0  # above the 3D view, below the UI CanvasLayer (layer 1)

	# BackBufferCopy (viewport mode) copies the framebuffer-so-far — at this point
	# just the 3D render — into the screen texture the shader reads.
	var bbc := BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_layer.add_child(bbc)

	_mat = ShaderMaterial.new()
	_mat.shader = POSTFX_SHADER

	_rect = ColorRect.new()
	_rect.name = "PostFXRect"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never intercept camera input
	_rect.material = _mat
	_layer.add_child(_rect)

	host.add_child(_layer)
	var vp := _layer.get_viewport()
	if vp and not vp.size_changed.is_connected(_update_layout):
		vp.size_changed.connect(_update_layout)
	_update_layout()
	_apply()

## Full-screen sizing (manual, like HudLogo — the ColorRect is a direct CanvasLayer
## child so it has no stretching parent).
func _update_layout() -> void:
	if not is_instance_valid(_rect):
		return
	var vp := _layer.get_viewport()
	if vp == null:
		return
	_rect.position = Vector2.ZERO
	_rect.size = vp.get_visible_rect().size

## Push every parameter to the shader and toggle the layer's visibility.
func _apply() -> void:
	if is_instance_valid(_layer):
		_layer.visible = enabled
	if _mat == null:
		return
	_mat.set_shader_parameter("u_vignette", vignette_amount)
	_mat.set_shader_parameter("u_vignette_softness", vignette_softness)
	_mat.set_shader_parameter("u_aberration", aberration_amount)
	_mat.set_shader_parameter("u_grain", grain_amount)
	_mat.set_shader_parameter("u_grain_speed", grain_speed)
	_mat.set_shader_parameter("u_grade", color_grade_enabled)
	_mat.set_shader_parameter("u_contrast", grade_contrast)
	_mat.set_shader_parameter("u_saturation", grade_saturation)
	_mat.set_shader_parameter("u_tint", Vector3(grade_tint.r, grade_tint.g, grade_tint.b))

# --- setters ----------------------------------------------------------------
func set_enabled(v: bool) -> void:
	enabled = v
	_apply()

func set_vignette_amount(v: float) -> void:
	vignette_amount = v
	_apply()

func set_vignette_softness(v: float) -> void:
	vignette_softness = v
	_apply()

func set_aberration_amount(v: float) -> void:
	aberration_amount = v
	_apply()

func set_grain_amount(v: float) -> void:
	grain_amount = v
	_apply()

func set_grain_speed(v: float) -> void:
	grain_speed = v
	_apply()

func set_color_grade_enabled(v: bool) -> void:
	color_grade_enabled = v
	_apply()

func set_grade_contrast(v: float) -> void:
	grade_contrast = v
	_apply()

func set_grade_saturation(v: float) -> void:
	grade_saturation = v
	_apply()

func set_grade_tint(v: Color) -> void:
	grade_tint = v
	_apply()

## Restore defaults (all effects off) when a loaded composition has no "postfx"
## block, so a previous session's grade never carries over silently.
func reset_defaults() -> void:
	enabled = false
	vignette_amount = 0.0
	vignette_softness = 0.4
	aberration_amount = 0.0
	grain_amount = 0.0
	grain_speed = 1.0
	color_grade_enabled = false
	grade_contrast = 1.0
	grade_saturation = 1.0
	grade_tint = Color(1, 1, 1)

func get_param_schema() -> Array:
	return [{
		"title": "Post FX",
		"props": [
			{"name": "enabled", "type": "bool",
				"hint": "Master toggle for the full-screen post-processing pass"},
			{"name": "vignette_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Edge darkening strength (0 = off)"},
			{"name": "vignette_softness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Width of the darkened edge band"},
			{"name": "aberration_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Chromatic aberration — radial R/B split at the edges (0 = off)"},
			{"name": "grain_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Animated film grain (0 = off)"},
			{"name": "grain_speed", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Grain animation speed"},
			{"name": "color_grade_enabled", "type": "bool",
				"hint": "Enable the contrast / saturation / tint grade below"},
			{"name": "grade_contrast", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "grade_saturation", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "grade_tint", "type": "color"},
		]
	}]
