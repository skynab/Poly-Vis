extends Node3D
## Drives the interaction system (Prompts 5.2 / 5.4).
##
## Each frame it gathers all enabled InfluenceObjects from the VisualizationManager,
## packs their data into fixed-size arrays and pushes them to every visualization
## that implements set_influences(). It also moves the active influence with the
## mouse (drag, or continuous follow) and fires proximity enter/exit events that
## downstream effects can hook (bursts, colour flips, ...).
class_name InfluenceController

const MAX_INFLUENCES := 8

signal proximity_entered(influence: InfluenceObject, target: Node3D)
signal proximity_exited(influence: InfluenceObject, target: Node3D)

# --- gesture events ---------------------------------------------------------
# Emitted from the per-influence tracking data this controller already computes
# (_prev_pos / _velocity / _speed + live positions), one signal per recognized
# gesture. Nothing consumes these yet — they exist so downstream effects can
# connect to them later (a clap burst, a push-to-scatter, a dwell-to-select),
# mirroring how proximity_entered/exited are consumed via _on_proximity_entered.
## A tracked influence moved toward (direction = +1) or away from (−1) the active
## camera faster than push_pull_speed. Rising-edge: fires once per crossing.
signal push_pull(influence: InfluenceObject, direction: int)
## Two influences' spheres collided (surface gap fell below clap_distance). Rising-
## edge per pair: fires once on contact, re-arms when they separate.
signal clap(influence_a: InfluenceObject, influence_b: InfluenceObject)
## A tracked influence held within dwell_radius of a spot for dwell_seconds. Fires
## once per dwell episode, re-arms when the influence leaves the radius.
signal dwell(influence: InfluenceObject)

## Demo reaction: restart a particle system when an influence enters it. Off by
## default — with a follow-mouse influence it would restart constantly as the
## influence crosses the system's bounds, visibly resetting the particles.
@export var burst_on_enter: bool = false

## When true, one InfluenceObject is auto-spawned per streamed OptiTrack rigid
## body (up to MAX_INFLUENCES total) and auto-despawned when its rigid body
## stops streaming. See _update_auto_bind(). Off by default; manually-created
## influences are never touched, and turning this off simply stops the
## automatic add/remove — any influences it already spawned stay put as
## ordinary, manually-editable influences.
@export var auto_bind_rigid_bodies: bool = false

# --- gesture thresholds (exposed in the panel, serialized with the controller) --
## Surface-gap tolerance for a clap: the two spheres count as colliding when the
## gap between their surfaces drops below this (0 = must actually touch; positive
## fires slightly before contact).
@export var clap_distance: float = 0.0
## Camera-facing speed (world units/sec) a tracked influence must exceed for a
## push_pull gesture.
@export var push_pull_speed: float = 1.5
## How long a tracked influence must stay put (within dwell_radius) to dwell.
@export var dwell_seconds: float = 1.0
## The "stay put" radius for a dwell — the influence may drift this far and still
## be counted as dwelling.
@export var dwell_radius: float = 0.15

# --- trajectory history (shared recent-path buffer) -------------------------
## Seconds of each active influence's recent world-space path to retain.
@export var history_seconds: float = 1.5
## Path sampling rate (samples/sec). Framerate-independent, like PolyTrails.
@export var sample_hz: float = 30.0

var _manager: VisualizationManager
var _camera: Camera3D
var _wall: Object                 # WallConfig — physical→screen mapping for tracking
var _dragging: bool = false
var _proximity: Dictionary = {}   # "infl_id:target_id" -> bool
var _auto_bound: Dictionary = {}  # rigid_body_asset_id (int) -> InfluenceObject
var _prev_pos: Dictionary = {}    # infl instance_id -> Vector3, tracked influences only
var _speed: Dictionary = {}       # infl instance_id -> float (world units/sec)
var _velocity: Dictionary = {}    # infl instance_id -> Vector3 (world units/sec), tracked only
var _burst_was_over: Dictionary = {}  # infl instance_id -> bool, rising-edge state for velocity_burst
# Gesture rising-edge / accumulator bookkeeping, all keyed by influence instance_id
# (or "idA:idB" for clap pairs) and pruned each frame for influences no longer tracked.
var _push_pull_dir: Dictionary = {}  # infl instance_id -> int (-1/0/+1), last emitted push/pull dir
var _clap_pairs: Dictionary = {}     # "idA:idB" -> bool, sphere-collision rising-edge state
var _dwell_anchor: Dictionary = {}   # infl instance_id -> Vector3, current dwell spot
var _dwell_time: Dictionary = {}     # infl instance_id -> float, seconds held near the anchor
var _dwell_fired: Dictionary = {}    # infl instance_id -> bool, fired-once-per-episode latch
# Shared trajectory-history ring buffers, keyed by influence instance_id.
var _history: Dictionary = {}        # infl instance_id -> PackedVector3Array (oldest → newest)
var _history_accum: float = 0.0      # sample-cadence accumulator (framerate-stable)

func setup(manager: VisualizationManager, camera: Camera3D, wall: Object = null) -> void:
	_manager = manager
	_camera = camera
	_wall = wall
	if not proximity_entered.is_connected(_on_proximity_entered):
		proximity_entered.connect(_on_proximity_entered)
	set_process(true)

## Reset to the authored default (auto-bind off). Called when loading a
## composition that carries no "auto_bind" block, so a previous session's
## setting doesn't silently carry over. Auto-spawned influences are already
## gone by the time this runs — CompositionIO.apply() clears all managed
## objects before restoring any global module.
func reset_defaults() -> void:
	auto_bind_rigid_bodies = false
	clap_distance = 0.0
	push_pull_speed = 1.5
	dwell_seconds = 1.0
	dwell_radius = 0.15
	history_seconds = 1.5
	sample_hz = 30.0
	_history.clear()
	_history_accum = 0.0
	_auto_bound.clear()
	_prev_pos.clear()
	_speed.clear()
	_velocity.clear()
	_burst_was_over.clear()
	_push_pull_dir.clear()
	_clap_pairs.clear()
	_dwell_anchor.clear()
	_dwell_time.clear()
	_dwell_fired.clear()

func _process(delta: float) -> void:
	if _manager == null:
		return
	_update_follow(delta)
	_update_auto_bind()
	_update_history(delta)
	_push_uniforms()
	_update_proximity()
	_update_gestures(delta)

# --- input: drag / follow ---------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed and _active_influence() != null
	elif event is InputEventMouseMotion and _dragging:
		var infl := _active_influence()
		if infl:
			infl.global_position = _project_mouse(infl.global_position)

func _update_follow(delta: float) -> void:
	var tracked_ids := {}
	for infl in _influences():
		if infl.track_skeleton_bone:
			var id := infl.get_instance_id()
			tracked_ids[id] = true
			var new_pos := _skeleton_pos(infl)
			_update_velocity(infl, id, new_pos, delta)
			infl.global_position = new_pos
			_update_velocity_burst(infl, id)
		elif infl.track_rigid_body:
			var id := infl.get_instance_id()
			tracked_ids[id] = true
			var new_pos := _optitrack_pos(infl)
			_update_velocity(infl, id, new_pos, delta)
			infl.global_position = new_pos
			_update_velocity_burst(infl, id)
		elif infl.follow_mouse:
			infl.global_position = _project_mouse(infl.global_position)
	# Prune tracking state for influences that stopped being tracked (toggled off
	# or removed) so the dictionaries don't grow stale entries forever.
	for id in _prev_pos.keys().duplicate():
		if not tracked_ids.has(id):
			_prev_pos.erase(id)
			_speed.erase(id)
			_velocity.erase(id)
			_burst_was_over.erase(id)

## Motion speed of a tracked influence, world units/sec, from the change in its
## streamed position since last frame. Zero on the first frame it's seen (no
## previous sample yet), so a fresh spawn / track_rigid_body toggle never reads
## as a spurious burst of speed. Also mirrors the value onto the influence for
## its live "Speed" status row.
func _update_velocity(infl: InfluenceObject, id: int, new_pos: Vector3, delta: float) -> void:
	var speed := 0.0
	var vel := Vector3.ZERO
	if delta > 0.0 and _prev_pos.has(id):
		vel = (new_pos - _prev_pos[id]) / delta
		speed = vel.length()
	_speed[id] = speed
	_velocity[id] = vel   # full vector for direction-aware gestures (push_pull)
	_prev_pos[id] = new_pos
	infl._tracked_speed = speed

## Rising-edge trigger: when velocity_burst is on and speed crosses above
## velocity_burst_threshold, restart every PolyParticles within this influence's
## radius — once per crossing, so holding a fast motion doesn't reset particles
## every single frame.
func _update_velocity_burst(infl: InfluenceObject, id: int) -> void:
	if not infl.velocity_burst:
		_burst_was_over.erase(id)
		return
	var over: bool = _speed.get(id, 0.0) > infl.velocity_burst_threshold
	if over and not _burst_was_over.get(id, false):
		for target in _manager.objects:
			if target is PolyParticles and infl.global_position.distance_to(target.global_position) < infl.radius:
				(target as PolyParticles).restart()
	_burst_was_over[id] = over

# --- auto-bind: one influence per streamed rigid body -----------------------
## Keeps InfluenceObjects in 1:1 sync with the currently-streamed OptiTrack
## rigid bodies while auto_bind_rigid_bodies is on. Spawns a new influence
## (track_rigid_body = true, rigid_body_asset_id = the streamed asset) for
## every streamed asset that no influence — manual or auto — already tracks,
## and despawns any influence *this* controller spawned once its asset stops
## streaming. Manually-created influences are never spawned or removed by this,
## even if their tracked asset later goes offline. A no-op with the mode off,
## the plugin absent, or Motive disconnected (see _live_rigid_body_assets).
func _update_auto_bind() -> void:
	if not auto_bind_rigid_bodies:
		return
	var assets := _live_rigid_body_assets()

	# Despawn: influences we auto-spawned whose rigid body is no longer streamed.
	for asset_id in _auto_bound.keys().duplicate():
		var infl: InfluenceObject = _auto_bound[asset_id]
		if not is_instance_valid(infl) or not assets.has(asset_id):
			_auto_bound.erase(asset_id)
			if is_instance_valid(infl):
				_manager.remove(infl)

	# Spawn: streamed assets nothing is tracking yet, up to the shader's cap.
	var claimed := _claimed_asset_ids()
	for asset_id in assets:
		if _influences().size() >= MAX_INFLUENCES:
			break
		if claimed.has(asset_id):
			continue
		_spawn_auto_influence(asset_id)
		claimed[asset_id] = true

## Currently streamed rigid-body assets, keyed by asset id → Motive name.
## "Unassigned" slots are filtered out, mirroring InfluenceObject.connection_status().
## Defensive like _optitrack_pos: returns {} without the plugin, the autoload,
## or a live Motive connection.
func _live_rigid_body_assets() -> Dictionary:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_rigid_body_assets"):
		return {}
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return {}
	var raw: Dictionary = ot.call("get_rigid_body_assets")
	var out := {}
	for id in raw:
		if str(raw[id]) != "Unassigned":
			out[id] = raw[id]
	return out

## Asset ids already tracked by some influence (manual or auto) — these are
## left alone, so auto-bind never double-spawns for the same rigid body.
func _claimed_asset_ids() -> Dictionary:
	var claimed := {}
	for infl in _influences():
		if infl.track_rigid_body:
			claimed[infl.rigid_body_asset_id] = true
	return claimed

## Spawn one influence for `asset_id`, inheriting radius/strength/color from a
## template — the first manually-created influence found (never one of ours),
## so a hand-tuned look carries over to every auto-bound rigid body. Falls back
## to InfluenceObject's own defaults when no manual influence exists yet.
func _spawn_auto_influence(asset_id: int) -> void:
	var inf := _manager.spawn_influence(false) as InfluenceObject
	var tmpl := _template_influence()
	if tmpl:
		inf.radius = tmpl.radius
		inf.strength = tmpl.strength
		inf.influence_color = tmpl.influence_color
	inf.track_rigid_body = true
	inf.rigid_body_asset_id = asset_id
	_auto_bound[asset_id] = inf

func _template_influence() -> InfluenceObject:
	for o in _manager.objects:
		if o is InfluenceObject and not _auto_bound.values().has(o):
			return o
	return null

## Live readout for the panel's "status" row — how many rigid bodies are
## currently bound, or "Off" when the mode is disabled.
func auto_bind_status() -> String:
	if not auto_bind_rigid_bodies:
		return "Off"
	var live: Array = []
	for asset_id in _auto_bound:
		if is_instance_valid(_auto_bound[asset_id]):
			live.append(asset_id)
	if live.is_empty():
		return "On — none bound"
	live.sort()
	return "On — %d bound (assets %s)" % [live.size(), str(live)]

## Position from an OptiTrack rigid body via the OptiTrack autoload. Defensive:
## if the plugin isn't installed, the autoload is absent, or Motive isn't
## connected, the influence simply holds its current position (no error).
func _optitrack_pos(infl: InfluenceObject) -> Vector3:
	# Use call() so the plugin-specific methods dispatch dynamically — the script
	# compiles even when the OptiTrack GDExtension / autoload isn't present.
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_rigid_body_pos"):
		return infl.global_position
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return infl.global_position
	var raw: Vector3 = ot.call("get_rigid_body_pos", infl.rigid_body_asset_id)
	return _apply_tracking_transform(infl, raw)

## Position of infl.skeleton_bone_name within infl.skeleton_asset_id's streamed
## skeleton, resolved to world space via OptiTrackSkeletonUtil (a bone's raw
## streamed data is parent-relative, unlike a rigid body's). Defensive like
## _optitrack_pos: holds the influence's current position when the plugin, the
## connection, the asset, or the named bone isn't available.
func _skeleton_pos(infl: InfluenceObject) -> Vector3:
	var ot := get_node_or_null("/root/OptiTrack")
	if ot == null or not ot.has_method("get_skeleton_bone_data"):
		return infl.global_position
	if ot.has_method("is_connected_to_motive") and not ot.call("is_connected_to_motive"):
		return infl.global_position
	var bones: Dictionary = ot.call("get_skeleton_bone_data", infl.skeleton_asset_id)
	if bones.is_empty() or not bones.has(infl.skeleton_bone_name):
		return infl.global_position
	var raw := OptiTrackSkeletonUtil.bone_world_position(bones, infl.skeleton_bone_name)
	return _apply_tracking_transform(infl, raw)

## Shared tail of the tracking pipeline for both a rigid body and a skeleton
## bone: mirror the streamed axes if Motive's X / Z run opposite the view (so
## motion lines up with the wall), then either map through the LED wall, or
## apply the per-influence offset and optionally flatten onto the view plane.
func _apply_tracking_transform(infl: InfluenceObject, raw: Vector3) -> Vector3:
	if infl.invert_x:
		raw.x = -raw.x
	if infl.invert_z:
		raw.z = -raw.z
	# Wall mapping: place the influence at the object's real spot on the rendered
	# wall (physical metres → screen → view plane). Takes priority over the simpler
	# view projection, and ignores the per-influence offset (the wall origin is the
	# reference instead).
	if infl.map_to_wall and _wall != null:
		return _wall_to_view(raw)
	var p := raw + infl.track_position_offset
	if infl.project_to_view:
		p = _project_to_view(p)
	return p

## Map a physical position (metres) onto the rendered wall: WallConfig converts it
## to a normalized screen coord, which we unproject onto the camera's view plane
## (through the origin). So the LED-wall pixel the object is in front of lines up
## with where the influence acts on the visual.
func _wall_to_view(world_metres: Vector3) -> Vector3:
	if _camera == null:
		return world_metres
	var vp := get_viewport()
	if vp == null:
		return world_metres
	var uv: Vector2 = _wall.physical_to_uv(world_metres)
	var screen := uv * vp.get_visible_rect().size
	var origin := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	var n := -_camera.global_transform.basis.z
	var plane := Plane(n, 0.0)  # camera-facing plane through the world origin
	var hit = plane.intersects_ray(origin, dir)
	return hit if hit != null else world_metres

## Flatten a world point onto the plane the camera is looking at (a camera-facing
## plane through the world origin), keeping the point's on-screen location. Used by
## project_to_view to drive a tracked influence in screen space with locked depth.
func _project_to_view(world_point: Vector3) -> Vector3:
	if _camera == null:
		return world_point
	var screen := _camera.unproject_position(world_point)
	var origin := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	var n := -_camera.global_transform.basis.z
	var plane := Plane(n, 0.0)  # through the world origin, facing the camera
	var hit = plane.intersects_ray(origin, dir)
	return hit if hit != null else world_point

## Project the mouse onto a camera-facing plane through plane_point.
func _project_mouse(plane_point: Vector3) -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return plane_point
	var mouse := vp.get_mouse_position()
	var origin := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	var n := -_camera.global_transform.basis.z
	var plane := Plane(n, n.dot(plane_point))
	var hit = plane.intersects_ray(origin, dir)
	return hit if hit != null else plane_point

func _active_influence() -> InfluenceObject:
	if _manager.selected is InfluenceObject:
		return _manager.selected as InfluenceObject
	var all := _influences()
	return all[0] if not all.is_empty() else null

func _influences() -> Array[InfluenceObject]:
	var out: Array[InfluenceObject] = []
	for o in _manager.objects:
		if o is InfluenceObject:
			out.append(o as InfluenceObject)
	return out

# --- trajectory history -----------------------------------------------------
## Append each active influence's world position to its ring buffer at a fixed
## sample_hz cadence (framerate-stable, mirroring PolyTrails' sampling), capping the
## buffer at history_seconds worth of samples. Buffers for influences that went
## inactive this frame are pruned, so the history follows the active set exactly.
func _update_history(delta: float) -> void:
	_history_accum += delta
	var step := 1.0 / maxf(sample_hz, 0.001)
	var commit := _history_accum >= step
	if commit:
		_history_accum = 0.0
	var cap := maxi(int(ceil(history_seconds * maxf(sample_hz, 0.001))), 2)
	var live := {}
	for infl in _active_influences():
		var id := infl.get_instance_id()
		live[id] = true
		if commit:
			var buf: PackedVector3Array = _history.get(id, PackedVector3Array())
			buf.append(infl.global_position)
			while buf.size() > cap:
				buf.remove_at(0)
			_history[id] = buf
	# Prune buffers for influences that are no longer active.
	for id in _history.keys().duplicate():
		if not live.has(id):
			_history.erase(id)

## Recent world-space path of an influence (oldest → newest), sampled at sample_hz
## over the last history_seconds. Empty for an unknown or inactive influence. Lets
## any visualization react to where an influence has *been*, not just where it is
## now — e.g. PolyMetaballs elongating a blob along the trailing path. Returns a
## copy-on-write snapshot; callers may read it freely.
func get_influence_history(instance_id: int) -> PackedVector3Array:
	return _history.get(instance_id, PackedVector3Array())

# --- push uniforms to visualizations ---------------------------------------
## The enabled, non-zero-strength influences pushed to the shaders this frame,
## capped at MAX_INFLUENCES (the shader array size). Shared by _push_uniforms and
## the trajectory-history sampler so both agree on the "active" set.
func _active_influences() -> Array[InfluenceObject]:
	var active: Array[InfluenceObject] = []
	for infl in _influences():
		if infl.enabled and infl.strength > 0.0:
			active.append(infl)
			if active.size() >= MAX_INFLUENCES:
				break
	return active

func _push_uniforms() -> void:
	var active := _active_influences()

	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var strengths := PackedFloat32Array()
	var colors := PackedVector3Array()
	# Raw tracked speed (world units/sec) per active influence, padded to
	# MAX_INFLUENCES like the other arrays. PolyTrails reads this for its
	# motion-reactive width/brightness; other objects ignore it.
	var speeds := PackedFloat32Array()
	for i in MAX_INFLUENCES:
		if i < active.size():
			var infl := active[i]
			var spd: float = _speed.get(infl.get_instance_id(), 0.0)
			positions.append(infl.global_position)
			radii.append(infl.radius)
			strengths.append(infl.effective_signed_strength(spd))
			colors.append(Vector3(infl.influence_color.r, infl.influence_color.g, infl.influence_color.b))
			speeds.append(spd)
		else:
			positions.append(Vector3.ZERO)
			radii.append(0.0)
			strengths.append(0.0)
			colors.append(Vector3.ZERO)
			speeds.append(0.0)

	# Per-active-influence "smear" vector for motion-reactive blobs (PolyMetaballs):
	# oldest → newest displacement over the trajectory buffer, i.e. pointing back
	# along the recent path. Padded to MAX_INFLUENCES like the other arrays.
	var motion := PackedVector3Array()
	for i in MAX_INFLUENCES:
		if i < active.size():
			var hist := get_influence_history(active[i].get_instance_id())
			motion.append(hist[0] - hist[hist.size() - 1] if hist.size() >= 2 else Vector3.ZERO)
		else:
			motion.append(Vector3.ZERO)

	for o in _manager.objects:
		if not o.has_method("set_influences"):
			continue
		# Motion-reactive blobs also get the per-influence smear vectors so they can
		# elongate along each influence's recent path (comet effect).
		if o is PolyMetaballs:
			(o as PolyMetaballs).set_influence_motion(motion)
		# A "follow influence" particle system tracks the active influence's
		# position (its emitter rides along) and receives no pushing force.
		if o is PolyParticles and (o as PolyParticles).follow_influence:
			if not active.is_empty():
				o.global_position = active[0].global_position
			o.set_influences(0, positions, radii, strengths, colors, speeds)
		else:
			o.set_influences(active.size(), positions, radii, strengths, colors, speeds)

# --- proximity events (Prompt 5.4) -----------------------------------------
func _update_proximity() -> void:
	for infl in _influences():
		for target in _manager.objects:
			if target is InfluenceObject:
				continue
			var key := "%d:%d" % [infl.get_instance_id(), target.get_instance_id()]
			var inside := infl.enabled and infl.global_position.distance_to(target.global_position) < infl.radius
			var was_inside: bool = _proximity.get(key, false)
			if inside and not was_inside:
				proximity_entered.emit(infl, target)
			elif not inside and was_inside:
				proximity_exited.emit(infl, target)
			_proximity[key] = inside

func _on_proximity_entered(_influence: InfluenceObject, target: Node3D) -> void:
	if burst_on_enter and target is PolyParticles:
		(target as PolyParticles).restart()

# --- gesture detection ------------------------------------------------------
## Recognize push/pull, clap and dwell gestures from the tracking data already
## computed this frame, emitting a signal per gesture. Operates on the currently
## *tracked* influences (those with live `_prev_pos`/`_velocity` from a rigid body
## or skeleton) that are enabled — a follow-mouse influence carries no motion-capture
## velocity, so it isn't a gesture source. Each detector prunes its own rising-edge /
## accumulator bookkeeping for influences no longer in the tracked set, mirroring
## `_update_follow`'s prune of the tracking dictionaries.
func _update_gestures(delta: float) -> void:
	var tracked: Array[InfluenceObject] = []
	var ids := {}
	for infl in _influences():
		var id := infl.get_instance_id()
		if infl.enabled and _prev_pos.has(id):
			tracked.append(infl)
			ids[id] = true
	_detect_push_pull(tracked, ids)
	_detect_dwell(tracked, delta, ids)
	_detect_clap(tracked, ids)

## Push/pull: the component of a tracked influence's velocity along the direction to
## the active camera. When it crosses ±push_pull_speed, emit once with direction +1
## (toward the camera) or −1 (away). Rising-edge — re-arms once the speed falls back
## under the threshold, and a toward↔away flip re-fires immediately.
func _detect_push_pull(tracked: Array[InfluenceObject], ids: Dictionary) -> void:
	var cam_pos := _camera.global_position if _camera else Vector3.ZERO
	for infl in tracked:
		var id := infl.get_instance_id()
		var dir_state := 0
		var to_cam := cam_pos - infl.global_position
		if _camera and to_cam.length() > 0.0001:
			var comp: float = (_velocity.get(id, Vector3.ZERO) as Vector3).dot(to_cam.normalized())
			if absf(comp) > push_pull_speed:
				dir_state = 1 if comp > 0.0 else -1
		if dir_state != 0 and dir_state != _push_pull_dir.get(id, 0):
			push_pull.emit(infl, dir_state)
		_push_pull_dir[id] = dir_state
	for id in _push_pull_dir.keys().duplicate():
		if not ids.has(id):
			_push_pull_dir.erase(id)

## Dwell: accumulate time while a tracked influence stays within dwell_radius of an
## anchor spot; leaving the radius re-anchors and resets. Fires once when the held
## time reaches dwell_seconds, latched until it leaves (so it doesn't re-fire every
## frame it keeps holding).
func _detect_dwell(tracked: Array[InfluenceObject], delta: float, ids: Dictionary) -> void:
	for infl in tracked:
		var id := infl.get_instance_id()
		var pos := infl.global_position
		if not _dwell_anchor.has(id) or pos.distance_to(_dwell_anchor[id]) > dwell_radius:
			_dwell_anchor[id] = pos
			_dwell_time[id] = 0.0
			_dwell_fired[id] = false
		else:
			_dwell_time[id] = float(_dwell_time.get(id, 0.0)) + delta
			if _dwell_time[id] >= dwell_seconds and not _dwell_fired.get(id, false):
				dwell.emit(infl)
				_dwell_fired[id] = true
	for id in _dwell_anchor.keys().duplicate():
		if not ids.has(id):
			_dwell_anchor.erase(id)
			_dwell_time.erase(id)
			_dwell_fired.erase(id)

## Clap: every pair of tracked influences whose spheres collide (surface gap below
## clap_distance). Rising-edge per pair — emits once on contact, re-arms when they
## separate.
func _detect_clap(tracked: Array[InfluenceObject], ids: Dictionary) -> void:
	for i in tracked.size():
		for j in range(i + 1, tracked.size()):
			var a := tracked[i]
			var b := tracked[j]
			var ia := a.get_instance_id()
			var ib := b.get_instance_id()
			var key := "%d:%d" % [mini(ia, ib), maxi(ia, ib)]
			var gap := a.global_position.distance_to(b.global_position) - a.radius - b.radius
			var colliding := gap < clap_distance
			if colliding and not _clap_pairs.get(key, false):
				clap.emit(a, b)
			_clap_pairs[key] = colliding
	for key in _clap_pairs.keys().duplicate():
		var parts: PackedStringArray = (key as String).split(":")
		if not ids.has(int(parts[0])) or not ids.has(int(parts[1])):
			_clap_pairs.erase(key)

## Schema consumed by the ParameterPanel — a global module like SceneEnvironment
## / WallConfig, serialized by CompositionIO under "auto_bind".
func get_param_schema() -> Array:
	return [{
		"title": "Auto-Bind Rigid Bodies",
		"props": [
			{"name": "auto_bind_rigid_bodies", "type": "bool",
				"hint": "Spawn/despawn one Influence per streamed OptiTrack rigid body (up to %d). Radius/strength/color are copied from the first manually-created influence; manual influences are never touched, and turning this off just stops further auto add/remove." % MAX_INFLUENCES},
			{"name": "auto_bind_status", "type": "status", "label": "Bound",
				"interval": 0.5, "hint": "Currently auto-bound rigid-body assets"},
		]
	}, {
		"title": "Gestures",
		"props": [
			{"name": "clap_distance", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Surface-gap tolerance for a clap (0 = spheres must touch; higher fires sooner)"},
			{"name": "push_pull_speed", "type": "float", "min": 0.1, "max": 10.0, "step": 0.1,
				"hint": "Camera-facing speed (units/sec) a tracked influence must exceed to push/pull"},
			{"name": "dwell_seconds", "type": "float", "min": 0.1, "max": 10.0, "step": 0.1,
				"hint": "How long a tracked influence must hold still to dwell"},
			{"name": "dwell_radius", "type": "float", "min": 0.01, "max": 2.0, "step": 0.01,
				"hint": "How far the influence may drift and still count as holding still"},
		]
	}, {
		"title": "Trajectory History",
		"props": [
			{"name": "history_seconds", "type": "float", "min": 0.1, "max": 10.0, "step": 0.1,
				"hint": "Seconds of each active influence's recent path kept for get_influence_history() (drives PolyMetaballs' motion stretch)"},
			{"name": "sample_hz", "type": "float", "min": 5.0, "max": 120.0, "step": 1.0,
				"hint": "Path sampling rate (framerate-independent)"},
		]
	}]
