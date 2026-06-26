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
## When false the shell/core meshes are hidden but the influence still acts —
## lets you feel the effect without seeing where the source is.
@export var show_visual: bool = true: set = set_show_visual
## When true the InfluenceController makes this follow the mouse on a plane.
@export var follow_mouse: bool = false

@export_group("OptiTrack")
## When true the influence's position is driven by an OptiTrack rigid body
## streamed from Motive (via the OptiTrack autoload). Takes priority over
## follow_mouse. No-op if the plugin isn't installed or Motive isn't connected.
@export var track_rigid_body: bool = false
## Motive asset ID of the rigid body to follow (matches the OptiTrackRigidBody
## node's Rigid Body Asset ID). 999 == unassigned.
@export var rigid_body_asset_id: int = 999
## Added to the streamed position — maps Motive's origin to a point in the scene.
@export var track_position_offset: Vector3 = Vector3.ZERO

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
	_update_visibility()

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

## Hide only the shell/core meshes (not the node), so the influence keeps acting
## while invisible. Meshes show only when both enabled and show_visual are true.
func _update_visibility() -> void:
	if not is_instance_valid(_shell):
		return
	var vis := enabled and show_visual
	_shell.visible = vis
	_core.visible = vis

func set_enabled(v: bool) -> void:
	enabled = v
	_update_visibility()

func set_show_visual(v: bool) -> void:
	show_visual = v
	_update_visibility()

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
			{"name": "show_visual", "type": "bool"},
			{"name": "follow_mouse", "type": "bool"},
			{"name": "track_rigid_body", "type": "bool"},
			{"name": "rigid_body_asset_id", "type": "int", "min": 0, "max": 9999, "step": 1},
			{"name": "track_position_offset", "type": "vector3"},
		]
	}]
