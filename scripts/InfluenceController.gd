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

var _manager: VisualizationManager
var _camera: Camera3D
var _wall: Object                 # WallConfig — physical→screen mapping for tracking
var _dragging: bool = false
var _proximity: Dictionary = {}   # "infl_id:target_id" -> bool
var _auto_bound: Dictionary = {}  # rigid_body_asset_id (int) -> InfluenceObject
var _prev_pos: Dictionary = {}    # infl instance_id -> Vector3, tracked influences only
var _speed: Dictionary = {}       # infl instance_id -> float (world units/sec)
var _burst_was_over: Dictionary = {}  # infl instance_id -> bool, rising-edge state for velocity_burst

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
	_auto_bound.clear()
	_prev_pos.clear()
	_speed.clear()
	_burst_was_over.clear()

func _process(delta: float) -> void:
	if _manager == null:
		return
	_update_follow(delta)
	_update_auto_bind()
	_push_uniforms()
	_update_proximity()

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
		if infl.track_rigid_body:
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
			_burst_was_over.erase(id)

## Motion speed of a tracked influence, world units/sec, from the change in its
## streamed position since last frame. Zero on the first frame it's seen (no
## previous sample yet), so a fresh spawn / track_rigid_body toggle never reads
## as a spurious burst of speed. Also mirrors the value onto the influence for
## its live "Speed" status row.
func _update_velocity(infl: InfluenceObject, id: int, new_pos: Vector3, delta: float) -> void:
	var speed := 0.0
	if delta > 0.0 and _prev_pos.has(id):
		speed = (new_pos - _prev_pos[id]).length() / delta
	_speed[id] = speed
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
	var inf := _manager.add_influence(false) as InfluenceObject
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
	# Mirror the streamed axes if Motive's X / Z run opposite the view, so motion
	# lines up with the wall. Applied to the raw position before offset / mapping.
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

# --- push uniforms to visualizations ---------------------------------------
func _push_uniforms() -> void:
	var active: Array[InfluenceObject] = []
	for infl in _influences():
		if infl.enabled and infl.strength > 0.0:
			active.append(infl)
			if active.size() >= MAX_INFLUENCES:
				break

	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var strengths := PackedFloat32Array()
	var colors := PackedVector3Array()
	for i in MAX_INFLUENCES:
		if i < active.size():
			var infl := active[i]
			positions.append(infl.global_position)
			radii.append(infl.radius)
			strengths.append(infl.effective_signed_strength(_speed.get(infl.get_instance_id(), 0.0)))
			colors.append(Vector3(infl.influence_color.r, infl.influence_color.g, infl.influence_color.b))
		else:
			positions.append(Vector3.ZERO)
			radii.append(0.0)
			strengths.append(0.0)
			colors.append(Vector3.ZERO)

	for o in _manager.objects:
		if not o.has_method("set_influences"):
			continue
		# A "follow influence" particle system tracks the active influence's
		# position (its emitter rides along) and receives no pushing force.
		if o is PolyParticles and (o as PolyParticles).follow_influence:
			if not active.is_empty():
				o.global_position = active[0].global_position
			o.set_influences(0, positions, radii, strengths, colors)
		else:
			o.set_influences(active.size(), positions, radii, strengths, colors)

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
	}]
