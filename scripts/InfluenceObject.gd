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
## follow_mouse, but yields to track_skeleton_bone. No-op if the plugin isn't
## installed or Motive isn't connected.
@export var track_rigid_body: bool = false
## Motive asset ID of the rigid body to follow (matches the OptiTrackRigidBody
## node's Rigid Body Asset ID). 999 == unassigned.
@export var rigid_body_asset_id: int = 1
## When true the influence's position is driven by a specific bone of an
## OptiTrack skeleton streamed from Motive (skeleton_asset_id +
## skeleton_bone_name), resolved via OptiTrackSkeletonUtil. Takes priority over
## both track_rigid_body and follow_mouse. No-op if the plugin isn't installed,
## Motive isn't connected, or the asset/bone isn't found.
@export var track_skeleton_bone: bool = false
## Motive asset ID of the skeleton to track (matches the OptiTrackSkeleton
## node's Skeleton Asset ID).
@export var skeleton_asset_id: int = 1
## Name of the bone to follow within the skeleton (must match a key of
## OptiTrack.get_skeleton_bone_data(skeleton_asset_id), e.g. "Hip", "RHand",
## "Head" for Motive's default biped skeleton).
@export var skeleton_bone_name: String = "Hip"
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
## Negate the streamed X / Z axis independently. Flips left/right (X) or front/back
## (Z) so the rigid body's motion lines up with the LED wall when Motive's axes are
## mirrored relative to the view. Applied to the raw position before offset / wall
## mapping (see InfluenceController._optitrack_pos).
@export var invert_x: bool = true
@export var invert_z: bool = false
## Scales this influence's effective strength by (1 + speed * amount), where
## speed is its tracked OptiTrack motion speed (world units/sec, computed by
## InfluenceController._update_velocity). The stored `strength` is never
## mutated — see effective_signed_strength(). 0 (default) disables the effect;
## has no effect on untracked influences (their speed is always 0).
@export_range(0.0, 2.0) var velocity_strength_amount: float = 0.0
## When true, a fast motion — speed above velocity_burst_threshold — restarts
## every PolyParticles within `radius` of this influence. A rising-edge
## trigger: fires once per crossing, not every frame the motion stays fast.
@export var velocity_burst: bool = false
## Speed (world units/sec) above which velocity_burst fires.
@export_range(0.0, 20.0) var velocity_burst_threshold: float = 2.0

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
## Tracked motion speed (world units/sec), written each frame by
## InfluenceController._update_velocity for tracked influences. Not exported /
## serialized — purely a live readout, see tracked_speed_status().
var _tracked_speed: float = 0.0

func _ready() -> void:
	_ensure_visual()
	_update_visual()

## Signed strength: positive attracts, negative repels.
func signed_strength() -> float:
	return strength * (1.0 if mode == Mode.ATTRACT else -1.0)

## signed_strength() scaled by the influence's current tracked motion speed
## (velocity_strength_amount), without mutating the stored `strength`. `speed`
## is world units/sec, supplied by InfluenceController — always 0 for
## untracked influences, so this is a no-op for them regardless of amount.
func effective_signed_strength(speed: float) -> float:
	return signed_strength() * (1.0 + speed * velocity_strength_amount)

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

## Human-readable OptiTrack skeleton connection state, mirroring
## connection_status() but for track_skeleton_bone: distinguishes "not
## connected", "asset not streaming", "bone not found on this skeleton", and
## "connected". Fully guarded so it's a safe no-op without the plugin.
func skeleton_connection_status() -> String:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("is_connected_to_motive"):
		return "Not Connected (plugin unavailable)"
	if not ot.call("is_connected_to_motive"):
		return "Not Connected"
	if ot.has_method("get_skeleton_assets"):
		var assets: Dictionary = ot.call("get_skeleton_assets")
		if not assets.has(skeleton_asset_id):
			return "Connected (asset %d not found)" % skeleton_asset_id
	if ot.has_method("get_skeleton_bone_data"):
		var bones: Dictionary = ot.call("get_skeleton_bone_data", skeleton_asset_id)
		if bones.is_empty():
			return "Connected (no bone data)"
		if not bones.has(skeleton_bone_name):
			return "Connected (bone \"%s\" not found)" % skeleton_bone_name
		return "Skeleton Connected — bone \"%s\"" % skeleton_bone_name
	return "Connected"

## Live resolved world-space position of skeleton_bone_name, surfaced read-only
## the same way rigid_body_position_status() is. Resolved via
## OptiTrackSkeletonUtil (see that file for why a bone's world position needs
## walking the hierarchy rather than reading its raw streamed position).
## Returns "—" when there's nothing to show.
func skeleton_bone_position_status() -> String:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_skeleton_bone_data"):
		return "—"
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return "—"
	var bones: Dictionary = ot.call("get_skeleton_bone_data", skeleton_asset_id)
	if bones.is_empty() or not bones.has(skeleton_bone_name):
		return "—"
	var p := OptiTrackSkeletonUtil.bone_world_position(bones, skeleton_bone_name)
	return "(%.3f, %.3f, %.3f)" % [p.x, p.y, p.z]

## Live tracked motion speed (world units/sec), computed by InfluenceController
## each frame from the change in streamed position. Surfaced read-only so
## velocity_strength_amount / velocity_burst_threshold can be tuned without
## eyeballing the 3D view. "—" when this influence isn't tracked.
func tracked_speed_status() -> String:
	if not track_rigid_body and not track_skeleton_bone:
		return "—"
	return "%.3f u/s" % _tracked_speed

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
			{"name": "skeleton_connection_status", "type": "status", "label": "Skeleton Status",
				"hint": "Live OptiTrack skeleton connection / bone tracking state"},
			{"name": "skeleton_bone_position_status", "type": "status", "label": "Bone Position",
				"interval": 0.1,
				"hint": "Live resolved world-space position of the tracked bone (Godot space)"},
			{"name": "track_skeleton_bone", "type": "bool",
				"hint": "Drive this influence from a chosen skeleton bone — takes priority over track_rigid_body and follow_mouse"},
			{"name": "skeleton_asset_id", "type": "int_field", "min": 0, "max": 9999, "step": 1,
				"hint": "Motive asset ID of the skeleton to track"},
			{"name": "skeleton_bone_name", "type": "string",
				"hint": "Bone to follow, e.g. \"Hip\", \"RHand\", \"Head\" (must match the skeleton's bone names)"},
			{"name": "track_position_offset", "type": "vector3"},
			{"name": "project_to_view", "type": "bool",
				"hint": "Lock the tracked position to a projection onto the current view"},
			{"name": "map_to_wall", "type": "bool",
				"hint": "Map the tracked position through the LED wall (see LED Wall section)"},
			{"name": "invert_x", "type": "bool",
				"hint": "Negate the streamed X axis (flip left/right) for wall alignment"},
			{"name": "invert_z", "type": "bool",
				"hint": "Negate the streamed Z axis (flip front/back) for wall alignment"},
			{"name": "tracked_speed_status", "type": "status", "label": "Speed",
				"interval": 0.1, "hint": "Live tracked motion speed (world units/sec)"},
			{"name": "velocity_strength_amount", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01,
				"hint": "Scale effective strength by (1 + speed*amount) based on tracked motion speed — 0 disables"},
			{"name": "velocity_burst", "type": "bool",
				"hint": "Restart nearby particle systems (within radius) on a fast motion, once per crossing"},
			{"name": "velocity_burst_threshold", "type": "float", "min": 0.0, "max": 20.0, "step": 0.1,
				"hint": "Speed (world units/sec) above which velocity_burst triggers"},
			{"name": "optitrack_server_ip", "type": "string", "hint": "Motive host IP"},
			{"name": "optitrack_client_ip", "type": "string", "hint": "Local interface IP"},
			{"name": "optitrack_multicast", "type": "bool", "hint": "On = multicast, off = unicast"},
			{"name": "reconnect_optitrack", "type": "action", "label": "Connect / Reconnect",
				"hint": "Apply the IP / transport settings above and (re)connect to Motive"},
		]
	}]
