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
## When true the streamed position is flattened onto the plane the camera is
## currently looking at (through the world origin), so the rigid body drives the
## influence in screen space — depth is locked to the view. See
## InfluenceController._project_to_view.
@export var project_to_view: bool = false
## When true the streamed position is mapped through the LED wall (WallConfig):
## physical metres → wall pixel → view plane, so the influence lines up with the
## object's real position on the wall. Takes priority over project_to_view.
@export var map_to_wall: bool = false

@export_subgroup("Connection")
## NatNet server (Motive host) IP. Applied to the OptiTrack autoload by
## reconnect_optitrack(); travels with the saved composition.
@export var optitrack_server_ip: String = "127.0.0.1"
## NatNet client (this machine) IP — the local interface that receives the stream.
@export var optitrack_client_ip: String = "127.0.0.1"
## Transport mode: true = multicast, false = unicast.
@export var optitrack_multicast: bool = true

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

## Human-readable OptiTrack connection state, surfaced read-only in the panel to
## help debug rigid-body tracking. Three states:
##   "Not Connected"        — no OptiTrack autoload (plugin absent / non-Windows)
##                            or Motive isn't connected.
##   "Connected"            — Motive is streaming, but this influence's
##                            rigid_body_asset_id isn't among the streamed assets
##                            (wrong ID, or the rigid body isn't tracked right now).
##   "Rigid Body Connected" — the asset ID is live; the streamed name is appended.
## Fully guarded so it's a safe no-op without the plugin.
func connection_status() -> String:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("is_connected_to_motive"):
		return "Not Connected (plugin unavailable)"
	if not ot.call("is_connected_to_motive"):
		return "Not Connected"
	# Connected to Motive — is this influence's rigid body actually streaming?
	if ot.has_method("get_rigid_body_assets"):
		var assets: Dictionary = ot.call("get_rigid_body_assets")
		if assets.has(rigid_body_asset_id) and str(assets[rigid_body_asset_id]) != "Unassigned":
			return "Rigid Body Connected — %s" % str(assets[rigid_body_asset_id])
		return "Connected (asset %d not found)" % rigid_body_asset_id
	return "Connected"

## Live streamed position of this influence's rigid body, surfaced read-only in the
## panel beneath the connection status so you can confirm data is actually moving
## (not just that the asset is listed). Returns "—" when there's nothing to show.
## Guarded like connection_status() — safe with the plugin absent.
func rigid_body_position_status() -> String:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_rigid_body_pos"):
		return "—"
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return "—"
	var p: Vector3 = ot.call("get_rigid_body_pos", rigid_body_asset_id)
	return "(%.3f, %.3f, %.3f)" % [p.x, p.y, p.z]

## Push the connection settings to the OptiTrack autoload and (re)connect. Safe to
## call with the plugin absent / autoload missing — every call is guarded, so it's
## simply a no-op off Windows or without Motive. Invoked by the panel's action
## button; the dynamic call() keeps this compiling without the GDExtension present.
func reconnect_optitrack() -> void:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null:
		return
	if ot.has_method("set_server_address"):
		ot.call("set_server_address", optitrack_server_ip)
	if ot.has_method("set_client_address"):
		ot.call("set_client_address", optitrack_client_ip)
	if ot.has_method("set_multicast"):
		ot.call("set_multicast", optitrack_multicast)
	if ot.has_method("disconnect_from_motive"):
		ot.call("disconnect_from_motive")
	if ot.has_method("connect_to_motive"):
		ot.call("connect_to_motive")

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
		]
	}, {
		"title": "OptiTrack",
		"props": [
			{"name": "connection_status", "type": "status", "label": "Status",
				"hint": "Live OptiTrack connection / rigid-body tracking state"},
			{"name": "rigid_body_position_status", "type": "status", "label": "Position",
				"interval": 0.1,
				"hint": "Live streamed position of the rigid body (Godot space)"},
			{"name": "track_rigid_body", "type": "bool"},
			{"name": "rigid_body_asset_id", "type": "int_field", "min": 0, "max": 9999, "step": 1,
				"hint": "Motive asset ID of the rigid body to follow"},
			{"name": "track_position_offset", "type": "vector3"},
			{"name": "project_to_view", "type": "bool",
				"hint": "Lock the tracked position to a projection onto the current view"},
			{"name": "map_to_wall", "type": "bool",
				"hint": "Map the tracked position through the LED wall (see LED Wall section)"},
			{"name": "optitrack_server_ip", "type": "string", "hint": "Motive host IP"},
			{"name": "optitrack_client_ip", "type": "string", "hint": "Local interface IP"},
			{"name": "optitrack_multicast", "type": "bool", "hint": "On = multicast, off = unicast"},
			{"name": "reconnect_optitrack", "type": "action", "label": "Connect / Reconnect",
				"hint": "Apply the IP / transport settings above and (re)connect to Motive"},
		]
	}]
