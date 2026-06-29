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

var _manager: VisualizationManager
var _camera: Camera3D
var _wall: Object                 # WallConfig — physical→screen mapping for tracking
var _dragging: bool = false
var _proximity: Dictionary = {}   # "infl_id:target_id" -> bool

func setup(manager: VisualizationManager, camera: Camera3D, wall: Object = null) -> void:
	_manager = manager
	_camera = camera
	_wall = wall
	if not proximity_entered.is_connected(_on_proximity_entered):
		proximity_entered.connect(_on_proximity_entered)
	set_process(true)

func _process(_delta: float) -> void:
	if _manager == null:
		return
	_update_follow()
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

func _update_follow() -> void:
	for infl in _influences():
		if infl.track_rigid_body:
			infl.global_position = _optitrack_pos(infl)
		elif infl.follow_mouse:
			infl.global_position = _project_mouse(infl.global_position)

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
			strengths.append(infl.signed_strength())
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
