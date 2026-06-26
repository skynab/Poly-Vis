extends MeshInstance3D
## Draws a glowing ring under the currently selected object (Prompt 7.2).
##
## Uses ImmediateMesh so the ring radius updates each frame to match the
## selected object's bounding size. Added as a child of VisualizationManager
## by Main so it shares the same world space without transform coupling.
class_name SelectionGizmo

const STEPS := 64

var _im: ImmediateMesh
var _mat: StandardMaterial3D
var _target: Node3D = null

func _ready() -> void:
	_im = ImmediateMesh.new()
	mesh = _im
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.no_depth_test = true
	_mat.albedo_color = Color(0.25, 0.85, 1.0)
	_mat.emission_enabled = true
	_mat.emission = Color(0.25, 0.85, 1.0)
	_mat.emission_energy_multiplier = 3.0
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED

	visible = false

func select(obj: Node3D) -> void:
	_target = obj
	# Influence objects already draw their own radius shell; skip gizmo for them.
	visible = obj != null and not (obj is InfluenceObject)

func _process(_delta: float) -> void:
	if not is_instance_valid(_target):
		visible = false
		return
	global_position = _target.global_position
	_redraw(_ring_radius())

func _redraw(r: float) -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in STEPS + 1:
		var a := (float(i) / STEPS) * TAU
		_im.surface_add_vertex(Vector3(cos(a) * r, 0.0, sin(a) * r))
	_im.surface_end()
	_im.surface_set_material(0, _mat)

func _ring_radius() -> float:
	if _target is PolyMesh:
		return (_target as PolyMesh).radius * 1.2
	if _target is PolyParticles:
		var e: Vector3 = (_target as PolyParticles).emitter_extents
		return maxf(maxf(e.x, e.z), 0.5) * 1.15
	return 1.5
