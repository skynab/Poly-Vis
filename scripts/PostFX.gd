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
## The pass is a full-screen quad `MeshInstance3D` running poly_postfx.gdshader (a
## spatial shader whose vertex stage writes clip-space POSITION directly). It has to
## be a spatial pass — not a CanvasLayer/ColorRect — because Godot only exposes the
## depth buffer (`hint_depth_texture`, needed for depth of field) to spatial shaders.
## The quad is parented to the camera and drawn on top of the 3D render, so it re-draws
## the rendered image and the UI CanvasLayer (layer 1, hidden during capture) always
## sits above it un-processed — the effect bakes into screenshots exactly as before.
## `hint_screen_texture` in a 3D pass is the OPAQUE render, so the grade sits under any
## transparent geometry that composites on top; depth of field is likewise opaque-only
## (transparent objects don't write depth), which is what a focus blur wants.
class_name PostFX

const POSTFX_SHADER := preload("res://shaders/poly_postfx.gdshader")

## Master switch — when off the whole pass is hidden (zero cost, image untouched).
var enabled: bool = false: set = set_enabled
## Edge darkening strength (0 = off) and the width of the darkened band.
var vignette_amount: float = 0.0: set = set_vignette_amount
var vignette_softness: float = 0.4: set = set_vignette_softness
## Depth of field: blur pixels by how far their depth is from focus_distance.
## amount = max blur (0 = off); focus_distance / focus_range are in world units.
var dof_amount: float = 0.0: set = set_dof_amount
var focus_distance: float = 6.0: set = set_focus_distance
var focus_range: float = 4.0: set = set_focus_range
## Motion blur — a cheap radial/zoom blur from screen center (0 = off), standing in
## for a per-pixel velocity pass this canvas pass doesn't have.
var mb_amount: float = 0.0: set = set_mb_amount
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

var _quad: MeshInstance3D
var _mat: ShaderMaterial

## Create the full-screen quad running the post shader and parent it to the active
## camera (so it always fills the view and is never frustum-culled), falling back to
## `host` (Main). Bound before HudLogo so the logo's CanvasLayer overlays it un-graded.
func bind(host: Node) -> void:
	if is_instance_valid(_quad):
		return
	_mat = ShaderMaterial.new()
	_mat.shader = POSTFX_SHADER
	# Draw after the scene's opaque geometry so hint_screen_texture sees the full
	# opaque render before this quad re-draws it.
	_mat.render_priority = 100

	_quad = MeshInstance3D.new()
	_quad.name = "PostFX"
	var qm := QuadMesh.new()
	qm.size = Vector2(2.0, 2.0)  # ±1 in XY → full clip space via the vertex shader
	_quad.mesh = qm
	_quad.material_override = _mat
	# The vertex shader overrides POSITION, so the mesh's world AABB is irrelevant —
	# keep it from ever being frustum-culled.
	_quad.extra_cull_margin = 16384.0
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var parent: Node = host
	var vp := host.get_viewport()
	if vp and vp.get_camera_3d():
		parent = vp.get_camera_3d()
	parent.add_child(_quad)
	_apply()

## Push every parameter to the shader and toggle the quad's visibility.
func _apply() -> void:
	if is_instance_valid(_quad):
		_quad.visible = enabled
	if _mat == null:
		return
	_mat.set_shader_parameter("u_vignette", vignette_amount)
	_mat.set_shader_parameter("u_vignette_softness", vignette_softness)
	_mat.set_shader_parameter("u_dof", dof_amount)
	_mat.set_shader_parameter("u_focus_distance", focus_distance)
	_mat.set_shader_parameter("u_focus_range", focus_range)
	_mat.set_shader_parameter("u_mb", mb_amount)
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

func set_dof_amount(v: float) -> void:
	dof_amount = v
	_apply()

func set_focus_distance(v: float) -> void:
	focus_distance = v
	_apply()

func set_focus_range(v: float) -> void:
	focus_range = v
	_apply()

func set_mb_amount(v: float) -> void:
	mb_amount = v
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
	dof_amount = 0.0
	focus_distance = 6.0
	focus_range = 4.0
	mb_amount = 0.0
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
			{"name": "dof_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Depth of field — blur strength for out-of-focus pixels (0 = off)"},
			{"name": "focus_distance", "type": "float", "min": 0.0, "max": 100.0, "step": 0.1,
				"hint": "World distance kept in focus"},
			{"name": "focus_range", "type": "float", "min": 0.1, "max": 50.0, "step": 0.1,
				"hint": "Depth band around focus_distance that stays sharp"},
			{"name": "mb_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01,
				"hint": "Motion blur — radial/zoom blur from screen center (0 = off)"},
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
