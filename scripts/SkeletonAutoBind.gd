extends RefCounted
## Keeps one InfluenceObject bound to each named bone of a streamed OptiTrack
## skeleton — the skeleton counterpart to InfluenceController.auto_bind_rigid_bodies.
##
## While `enabled`, each frame it reads OptiTrack.get_skeleton_bone_data(
## skeleton_asset_id) (guarded exactly like InfluenceController._skeleton_pos:
## get_node_or_null + has_method + connection check + asset/bone presence) and:
## despawns any influence *it* previously spawned whose bone stopped streaming or
## was removed from the list; then spawns one influence per wanted bone that is
## streaming and nothing already tracks, setting track_skeleton_bone = true and the
## right skeleton_asset_id + skeleton_bone_name, and copying radius/strength/color
## from a template (the first manually-created influence, else InfluenceObject's own
## defaults). Manually-created influences — and their own track_skeleton_bone
## assignments — are never spawned or despawned by this. Spawning stops once the
## total influence count hits MAX_INFLUENCES (8), matching the shader's fixed-size
## influence arrays.
##
## Schema-driven global module like WallConfig / AudioReactor: created by Main,
## editable in the ParameterPanel's global area, serialized by CompositionIO under
## "skeleton_bind". reset_defaults() turns it off. A no-op with the mode off, the
## plugin absent, Motive disconnected, or the skeleton asset offline.
class_name SkeletonAutoBind

const MAX_INFLUENCES := 8

## Default bone list — the common extremity joints for a full-body skeleton.
const DEFAULT_BONES := "Head, LHand, RHand, LFoot, RFoot"

## When true, bones in `bone_names` are kept 1:1 with spawned influences each frame.
var enabled: bool = false
## OptiTrack skeleton asset id whose bones drive the auto-bound influences.
var skeleton_asset_id: int = 1
## Comma-separated bone names to bind (must match keys of get_skeleton_bone_data,
## e.g. "Head, LHand, RHand, LFoot, RFoot"). Whitespace around names is trimmed.
var bone_names: String = DEFAULT_BONES

var _manager: VisualizationManager
var _bound: Dictionary = {}  # bone_name (String) -> InfluenceObject

func setup(manager: VisualizationManager) -> void:
	_manager = manager

## Reset to the authored default (off). Called when loading a composition that
## carries no "skeleton_bind" block, so a previous session's setting doesn't carry
## over. Auto-spawned influences are already gone by the time this runs —
## CompositionIO.apply() clears all managed objects before restoring any module.
func reset_defaults() -> void:
	enabled = false
	_bound.clear()

## Called each frame from Main._process. Keeps the bound influences in sync with
## the wanted bones that are currently streaming.
func update() -> void:
	if not enabled or _manager == null:
		return
	var bones := _live_bones()
	var wanted := _bone_list()

	# Despawn: influences we spawned whose bone stopped streaming or left the list.
	for bone in _bound.keys().duplicate():
		var infl: InfluenceObject = _bound[bone]
		if not is_instance_valid(infl) or not bones.has(bone) or not wanted.has(bone):
			_bound.erase(bone)
			if is_instance_valid(infl):
				_manager.remove(infl)

	# Spawn: wanted bones currently streaming that nothing already tracks, up to cap.
	var claimed := _claimed_bones()
	for bone in wanted:
		if _influence_count() >= MAX_INFLUENCES:
			break
		if not bones.has(bone):
			continue
		if claimed.has(bone):
			continue
		_spawn_bone_influence(bone)
		claimed[bone] = true

## Bone data for skeleton_asset_id (bone_name → [id, parent_id, pos, rot]) or {}.
## Guarded exactly like InfluenceController._skeleton_pos: no plugin, no autoload,
## no live Motive connection, or the asset not streaming all yield {} (a no-op).
func _live_bones() -> Dictionary:
	if _manager == null:
		return {}
	var ot := _manager.get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_skeleton_bone_data"):
		return {}
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return {}
	var bones: Dictionary = ot.call("get_skeleton_bone_data", skeleton_asset_id)
	return bones

## Parse `bone_names` into a de-duplicated, order-preserving list of trimmed names,
## dropping blank entries so a trailing comma or stray space never spawns a phantom.
func _bone_list() -> Array:
	var out: Array = []
	for raw in bone_names.split(","):
		var trimmed := raw.strip_edges()
		if trimmed != "" and not out.has(trimmed):
			out.append(trimmed)
	return out

## Bones already tracked by some influence (manual or ours) on this skeleton asset —
## left alone, so auto-bind never double-spawns for the same bone.
func _claimed_bones() -> Dictionary:
	var claimed := {}
	for o in _manager.objects:
		if o is InfluenceObject:
			var infl := o as InfluenceObject
			if infl.track_skeleton_bone and infl.skeleton_asset_id == skeleton_asset_id:
				claimed[infl.skeleton_bone_name] = true
	return claimed

## Spawn one influence for `bone`, inheriting radius/strength/color from a template
## (the first manually-created influence found, never one of ours) so a hand-tuned
## look carries over. Undo-free (spawn_influence(false)) like _update_auto_bind, so
## the background spawn stays out of the undo history and doesn't steal selection.
func _spawn_bone_influence(bone: String) -> void:
	var inf := _manager.spawn_influence(false) as InfluenceObject
	var tmpl := _template_influence()
	if tmpl:
		inf.radius = tmpl.radius
		inf.strength = tmpl.strength
		inf.influence_color = tmpl.influence_color
	inf.track_skeleton_bone = true
	inf.skeleton_asset_id = skeleton_asset_id
	inf.skeleton_bone_name = bone
	_bound[bone] = inf

func _template_influence() -> InfluenceObject:
	for o in _manager.objects:
		if o is InfluenceObject and not _bound.values().has(o):
			return o
	return null

func _influence_count() -> int:
	var n := 0
	for o in _manager.objects:
		if o is InfluenceObject:
			n += 1
	return n

## Live readout for the panel's "status" row — how many bones are currently bound,
## or "Off" when the mode is disabled.
func bound_status() -> String:
	if not enabled:
		return "Off"
	var live: Array = []
	for bone in _bound:
		if is_instance_valid(_bound[bone]):
			live.append(bone)
	if live.is_empty():
		return "On — none bound"
	live.sort()
	return "On — %d bound (%s)" % [live.size(), ", ".join(live)]

## Schema consumed by the ParameterPanel — a global module like WallConfig /
## AudioReactor, serialized by CompositionIO under "skeleton_bind".
func get_param_schema() -> Array:
	return [{
		"title": "Auto-Bind Skeleton",
		"props": [
			{"name": "enabled", "type": "bool",
				"hint": "Spawn/despawn one Influence per named bone of a streamed OptiTrack skeleton (up to %d total). Radius/strength/color are copied from the first manually-created influence; manual influences are never touched, and turning this off just stops further auto add/remove." % MAX_INFLUENCES},
			{"name": "skeleton_asset_id", "type": "int_field", "min": 0, "max": 9999, "step": 1,
				"hint": "OptiTrack skeleton asset id to bind bones from"},
			{"name": "bone_names", "type": "string",
				"hint": "Comma-separated bone names to track (must match streamed bone names, e.g. Head, LHand, RHand, LFoot, RFoot)"},
			{"name": "bound_status", "type": "status", "label": "Bound",
				"interval": 0.5, "hint": "Currently auto-bound skeleton bones"},
		]
	}]
