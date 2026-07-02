extends RefCounted
## Two-hand distance controller — a global module like WallConfig / AudioReactor.
##
## When enabled, each frame it measures the distance between the two nearest enabled
## *tracked* influences (OptiTrack rigid-body or skeleton driven), maps that distance
## from [min_distance, max_distance] to a normalized 0..1, expands it to
## [output_min, output_max], and drives a chosen `target` parameter with the result —
## Bloom (scene glow), the selected object's metaball radius / cloth wave amplitude,
## or a global uniform scale on the selected object.
##
## Non-destructive, exactly like the audio-band pattern: it writes the *live*
## representation (the Environment's glow, a shader uniform, or the node transform)
## and never touches the object's stored/serialized parameter — so the modulation is
## invisible to CompositionIO and vanishes the instant the control is disabled (or the
## target / selection changes, or reset_defaults runs), leaving everything at what the
## user authored. Editable in the ParameterPanel and serialized by CompositionIO under
## "two_hand".
class_name TwoHandControl

## Which parameter the hand-distance drives.
enum Target { BLOOM, METABALL_RADIUS, CLOTH_AMPLITUDE, GLOBAL_SCALE }

## Master toggle — off by default (never grabs a parameter uninvited).
var enabled: bool = false: set = set_enabled
## Hand distance (world units) mapped to output_min.
var min_distance: float = 0.2
## Hand distance mapped to output_max.
var max_distance: float = 3.0
## Which parameter to drive (see Target). Switching restores the previous target.
var target: Target = Target.BLOOM: set = set_target
## Output range the normalized 0..1 is expanded into and written to the target.
var output_min: float = 0.0
var output_max: float = 2.0

var _manager: VisualizationManager
var _scene_env: Object            # SceneEnvironment — where the Bloom target lives
# Live-override bookkeeping so the live value can always be returned to the authored one.
var _driving_obj: Object = null   # object currently overridden (scene_env for Bloom)
var _driving_target: int = -1     # which Target is live
var _base_scale: Vector3 = Vector3.ONE  # authored node scale (GLOBAL_SCALE isn't a stored schema param)
var _last_applied: float = INF    # skip redundant writes when the value hasn't moved
var _distance: float = -1.0       # last measured hand distance for the status row (−1 = none)

## `manager` supplies the influences + current selection; `scene_env` is the Bloom
## target. Mirrors SkeletonAutoBind.setup / SceneEnvironment.bind.
func setup(manager: VisualizationManager, scene_env: Object) -> void:
	_manager = manager
	_scene_env = scene_env

## Reset to the authored default (off). Called when loading a composition with no
## "two_hand" block. Releases any live override first so the target returns to its
## authored value before we forget it.
func reset_defaults() -> void:
	_release()
	enabled = false
	min_distance = 0.2
	max_distance = 3.0
	target = Target.BLOOM
	output_min = 0.0
	output_max = 2.0

func set_enabled(v: bool) -> void:
	enabled = v
	if not enabled:
		_release()

func set_target(v: Target) -> void:
	if v != target:
		_release()   # restore the old target before switching to the new one
	target = v

## Called from Main._process every frame.
func update(_delta: float) -> void:
	if not enabled or _manager == null:
		_release()
		_distance = -1.0
		return
	var d := _two_hand_distance()
	if d < 0.0:
		_release()          # fewer than two tracked influences → drive nothing
		_distance = -1.0
		return
	_distance = d
	var obj := _target_object()
	if obj == null:
		_release()          # target needs a compatible selection that isn't present
		return
	# Start driving, or switch when the object/target under us changed — restoring
	# the previous one first. Only GLOBAL_SCALE needs a cached base (scale isn't a
	# stored schema param); the others re-derive from the untouched stored value.
	if obj != _driving_obj or _driving_target != int(target):
		_release()
		_driving_obj = obj
		_driving_target = int(target)
		_last_applied = INF
		if target == Target.GLOBAL_SCALE and obj is Node3D:
			_base_scale = (obj as Node3D).scale
	var norm := clampf((d - min_distance) / maxf(max_distance - min_distance, 0.0001), 0.0, 1.0)
	var mapped := lerpf(output_min, output_max, norm)
	if absf(mapped - _last_applied) > 0.0001:
		_drive(int(target), obj, mapped)
		_last_applied = mapped

## Distance between the two nearest enabled tracked influences, or −1 if fewer than
## two exist. "Tracked" = driven by an OptiTrack rigid body or skeleton bone.
func _two_hand_distance() -> float:
	var pts: Array[Vector3] = []
	for o in _manager.objects:
		if o is InfluenceObject:
			var infl := o as InfluenceObject
			if infl.enabled and (infl.track_rigid_body or infl.track_skeleton_bone):
				pts.append(infl.global_position)
	if pts.size() < 2:
		return -1.0
	var best := INF
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			best = minf(best, pts[i].distance_to(pts[j]))
	return best

## The object the current target applies to, or null if unavailable (e.g. the
## Metaball target with no PolyMetaballs selected). Bloom always resolves to the
## SceneEnvironment; the rest follow the manager's current selection.
func _target_object() -> Object:
	match target:
		Target.BLOOM:
			return _scene_env
		Target.METABALL_RADIUS:
			return _manager.selected if _manager.selected is PolyMetaballs else null
		Target.CLOTH_AMPLITUDE:
			return _manager.selected if _manager.selected is PolyCloth else null
		Target.GLOBAL_SCALE:
			return _manager.selected if _manager.selected is Node3D else null
	return null

## Write the mapped value to the target's LIVE representation, leaving its stored /
## serialized parameter untouched (the audio-band convention). Guards freed objects
## and unbuilt materials so nothing errors mid-frame.
func _drive(t: int, obj: Object, v: float) -> void:
	match t:
		Target.BLOOM:
			if _scene_env and _scene_env.env:
				_scene_env.env.glow_intensity = v          # not _scene_env.bloom_intensity
		Target.METABALL_RADIUS:
			if is_instance_valid(obj):
				var m: ShaderMaterial = (obj as PolyMetaballs)._mat
				if m:
					m.set_shader_parameter("u_blob_radius", v)
		Target.CLOTH_AMPLITUDE:
			if is_instance_valid(obj):
				var m: ShaderMaterial = (obj as PolyCloth)._surface_mat
				if m:
					m.set_shader_parameter("u_anim_amplitude", v)   # live wave amplitude
		Target.GLOBAL_SCALE:
			if is_instance_valid(obj):
				(obj as Node3D).scale = Vector3.ONE * v

## Return the currently-driven target's live representation to the authored value and
## forget it. Re-derives from the untouched stored value (or the cached base scale).
## A no-op when nothing is being driven.
func _release() -> void:
	if _driving_obj == null:
		return
	match _driving_target:
		Target.BLOOM:
			if _scene_env and _scene_env.env:
				_scene_env.env.glow_intensity = _scene_env.bloom_intensity
		Target.METABALL_RADIUS:
			if is_instance_valid(_driving_obj):
				var mb := _driving_obj as PolyMetaballs
				if mb._mat:
					mb._mat.set_shader_parameter("u_blob_radius", mb.blob_radius)
		Target.CLOTH_AMPLITUDE:
			if is_instance_valid(_driving_obj):
				var cl := _driving_obj as PolyCloth
				if cl._surface_mat:
					cl._surface_mat.set_shader_parameter("u_anim_amplitude",
							cl.anim_amplitude if cl.animate else 0.0)
		Target.GLOBAL_SCALE:
			if is_instance_valid(_driving_obj):
				(_driving_obj as Node3D).scale = _base_scale
	_driving_obj = null
	_driving_target = -1
	_last_applied = INF

## Live status row: the measured distance and the value it currently maps to.
func distance_status() -> String:
	if not enabled:
		return "Off"
	if _distance < 0.0:
		return "No pair (need 2 tracked influences)"
	var norm := clampf((_distance - min_distance) / maxf(max_distance - min_distance, 0.0001), 0.0, 1.0)
	return "%.2f  →  %.2f" % [_distance, lerpf(output_min, output_max, norm)]

func get_param_schema() -> Array:
	return [{
		"title": "Two-Hand Control",
		"props": [
			{"name": "enabled", "type": "bool",
				"hint": "Map the distance between the two nearest tracked influences onto a parameter"},
			{"name": "min_distance", "type": "float", "min": 0.0, "max": 10.0, "step": 0.05,
				"hint": "Hand distance mapped to output_min"},
			{"name": "max_distance", "type": "float", "min": 0.05, "max": 20.0, "step": 0.05,
				"hint": "Hand distance mapped to output_max"},
			{"name": "target", "type": "enum",
				"options": ["Bloom", "Metaball Radius", "Cloth Amplitude", "Global Scale"],
				"hint": "Bloom = scene glow; the others drive the selected object (Metaball Radius / Cloth wave amplitude / uniform scale)"},
			{"name": "output_min", "type": "float", "min": -10.0, "max": 20.0, "step": 0.05},
			{"name": "output_max", "type": "float", "min": -10.0, "max": 20.0, "step": 0.05},
			{"name": "distance_status", "type": "status", "label": "Distance", "interval": 0.1},
		]
	}]
