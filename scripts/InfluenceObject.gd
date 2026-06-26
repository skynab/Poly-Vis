@tool
extends Node3D
## Movable proximity driver — the "object getting close" (Prompt 5.1).
##
## Carries a world position (its own transform), a radius, a strength and a
## mode. The InfluenceController reads these to drive mesh/particle reactions
## and to fire proximity events. Drawn as a translucent sphere + solid core.
class_name InfluenceObject

enum Mode { ATTRACT, REPEL }

@export var enabled: bool = true: set = set_enabled
@export var mode: Mode = Mode.REPEL
@export_range(0.1, 20.0) var radius: float = 2.0: set = set_radius
@export_range(0.0, 10.0) var strength: float = 1.5: set = set_strength
@export var influence_color: Color = Color(0.1, 0.5, 1.0): set = set_influence_color
## When true the InfluenceController makes this follow the mouse on a plane.
@export var follow_mouse: bool = false

var _shell: MeshInstance3D
var _core: MeshInstance3D

func _ready() -> void:
	_ensure_visual()
	_update_visual()

## Signed strength: positive attracts, negative repels.
func signed_strength() -> float:
	return strength * (1.0 if mode == Mode.ATTRACT else -1.0)

func _ensure_visual() -> void:
	if is_instance_valid(_shell):
		return
	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 16
	sm.rings = 8
	_shell.mesh = sm
	add_child(_shell)

	_core = MeshInstance3D.new()
	_core.name = "Core"
	var cm := SphereMesh.new()
	cm.radius = 1.0
	cm.height = 2.0
	cm.radial_segments = 12
	cm.rings = 6
	_core.mesh = cm
	add_child(_core)

func _update_visual() -> void:
	if not is_instance_valid(_shell):
		return
	_shell.scale = Vector3.ONE * radius
	_core.scale = Vector3.ONE * 0.12
	visible = enabled

	var shell_mat := StandardMaterial3D.new()
	shell_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shell_mat.albedo_color = Color(influence_color.r, influence_color.g, influence_color.b, 0.12)
	shell_mat.emission_enabled = true
	shell_mat.emission = influence_color
	shell_mat.emission_energy_multiplier = 0.35
	shell_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_shell.material_override = shell_mat

	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = influence_color
	core_mat.emission_enabled = true
	core_mat.emission = influence_color
	core_mat.emission_energy_multiplier = 0.6
	_core.material_override = core_mat

func set_enabled(v: bool) -> void:
	enabled = v
	if is_instance_valid(_shell):
		visible = v

func set_radius(v: float) -> void:
	radius = v
	_update_visual()

func set_strength(v: float) -> void:
	strength = v

func set_influence_color(v: Color) -> void:
	influence_color = v
	_update_visual()

## Schema consumed by the ParameterPanel (Prompt 4.1).
func get_param_schema() -> Array:
	return [{
		"title": "Influence",
		"props": [
			{"name": "enabled", "type": "bool"},
			{"name": "mode", "type": "enum", "options": ["Attract", "Repel"]},
			{"name": "radius", "type": "float", "min": 0.1, "max": 20.0, "step": 0.1},
			{"name": "strength", "type": "float", "min": 0.0, "max": 10.0, "step": 0.1},
			{"name": "influence_color", "type": "color"},
			{"name": "follow_mouse", "type": "bool"},
		]
	}]
