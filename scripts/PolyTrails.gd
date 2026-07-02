@tool
extends MeshInstance3D
## Ribbon-trail visualization: N strands that trail behind moving anchors.
##
## Where PolyParticles emits a cloud and PolyMesh/PolyCloth are static surfaces,
## PolyTrails leaves flowing, fading ribbons chasing whatever moves — the active
## influence positions (the default), or a node it's attached to (attach_to).
## Each strand keeps a short history of world-space anchor samples; every frame
## _rebuild_mesh() turns each history polyline into a camera-facing, width-tapered
## triangle strip on a shared ImmediateMesh. Color runs along the length via the
## shared GradientColormap, and poly_trails.gdshader adds the influence tint using
## the same u_influence_* convention as the mesh/cloth shaders.
class_name PolyTrails

const TRAIL_SHADER := preload("res://shaders/poly_trails.gdshader")
const MAX_INFLUENCES := 8

@export_group("Strands")
## Number of independent ribbons. When following influences each strand chases
## influence[i % active_count]; when attached to a node they share it, fanned out
## by `spread`.
@export_range(1, 32) var strand_count: int = 6: set = set_strand_count
## History length in samples — longer = a longer ribbon (more of the recent path).
@export_range(2, 256) var segments: int = 64: set = set_segments
## How many anchor samples are committed per second. Decouples ribbon length from
## framerate: the head stays glued to the anchor every frame, but a new trailing
## point is only laid down at this cadence.
@export_range(6.0, 120.0) var sample_hz: float = 60.0
## Ribbon width at the head (world units); tapers to 0 at the tail.
@export_range(0.01, 2.0) var width: float = 0.18: set = set_width
## Fans the strands out around their shared anchor (world units). With a single
## anchor (one influence, or attach_to) this is what keeps strands from overlapping.
@export_range(0.0, 4.0) var spread: float = 0.6: set = set_spread
## Random seed for the per-strand fan-out offsets — change for a different spray.
@export var seed: int = 0: set = set_seed

@export_group("Anchor")
## Optional node the strands trail behind instead of the influences. When set and
## valid it takes priority; clear it to fall back to the active influence anchors.
@export var attach_to: NodePath: set = set_attach_to

@export_group("Color")
@export var colormap: GradientColormap: set = set_colormap
## Overall brightness; push above 1 to bloom (like particle_brightness).
@export_range(0.0, 4.0) var brightness: float = 1.4: set = set_brightness
## Head opacity; the tail always fades to transparent (see fade).
@export_range(0.0, 1.0) var opacity: float = 1.0: set = set_opacity
## Alpha falloff exponent along the length — higher leaves a longer faint tail.
@export_range(0.1, 6.0) var fade: float = 1.5: set = set_fade
## Fallback color when no colormap is assigned.
@export var base_color: Color = Color(0.2, 0.7, 1.0): set = set_base_color
## How strongly ribbons adopt the color of a nearby influence.
@export_range(0.0, 1.0) var influence_tint: float = 0.6: set = set_influence_tint

@export_group("Motion Reactivity")
## Scale each ribbon's width by the speed of the influence it follows:
## width *= 1 + speed * this. 0 = off. Speed comes from InfluenceController's
## tracked-speed measurement, so only OptiTrack-driven anchors react (a still or
## untracked anchor is speed 0 → no change).
@export_range(0.0, 4.0) var speed_width_amount: float = 0.0: set = set_speed_width_amount
## Scale ribbon brightness by tracked influence speed the same way. 0 = off.
@export_range(0.0, 4.0) var speed_brightness_amount: float = 0.0: set = set_speed_brightness_amount
## Exponential smoothing of the speed reading (0 = instant, near 1 = slow),
## matching AudioReactor's smoothing.
@export_range(0.0, 0.98) var speed_smoothing: float = 0.8: set = set_speed_smoothing

var _mesh: ImmediateMesh
var _mat: ShaderMaterial
## Per-strand committed history of world-space points (index 0 = oldest tail).
var _history: Array = []
## Per-strand fan-out offset (world units), deterministic from `seed`.
var _offsets: PackedVector3Array = PackedVector3Array()
var _sample_accum: float = 0.0

# Influence data from the last set_influences() push. Positions double as anchors.
var _infl_count: int = 0
var _infl_pos: PackedVector3Array = PackedVector3Array()
## Per-influence tracked speed (world units/sec), cached from set_influences the
## same way _infl_pos is — indexed identically so a strand's anchor speed is
## _infl_speed[i % _infl_count].
var _infl_speed: PackedFloat32Array = PackedFloat32Array()
## Smoothed per-strand anchor speed, updated each frame from _infl_speed.
var _strand_speed: PackedFloat32Array = PackedFloat32Array()

func _ready() -> void:
	_ensure_setup()
	_reset_strands()
	set_process(true)

func _ensure_setup() -> void:
	if _mesh == null:
		_mesh = ImmediateMesh.new()
		mesh = _mesh
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = TRAIL_SHADER
		material_override = _mat
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.ICE))
	_apply_color()

# --- strand bookkeeping -----------------------------------------------------
## Resize the per-strand history + offset buffers to match strand_count and
## reseed the fan-out offsets. Clears history so a resize starts trails fresh.
func _reset_strands() -> void:
	_history.clear()
	for i in strand_count:
		_history.append(PackedVector3Array())
	_strand_speed = PackedFloat32Array()
	_strand_speed.resize(strand_count)  # zero-filled
	_rebuild_offsets()

## Deterministic per-strand fan-out directions from `seed`, scaled by `spread`.
func _rebuild_offsets() -> void:
	_offsets = PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed)
	for i in strand_count:
		# Random unit vector (biased slightly flat so strands fan sideways).
		var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.5, 0.5),
				rng.randf_range(-1.0, 1.0))
		if dir.length() < 0.001:
			dir = Vector3.RIGHT
		_offsets.append(dir.normalized() * spread)

## World-space base anchor for strand `i` before its fan-out offset: the attached
## node if set & valid, else influence[i % count], else our own position (so with
## nothing to follow the ribbons simply collapse to a point rather than erroring).
func _anchor_base(i: int) -> Vector3:
	if not attach_to.is_empty():
		var n := get_node_or_null(attach_to)
		if n is Node3D:
			return (n as Node3D).global_position
	if _infl_count > 0:
		return _infl_pos[i % _infl_count]
	return global_position

## Raw tracked speed (world units/sec) of strand `i`'s anchor, mirroring
## _anchor_base's index math. An attach_to node or absent influences have no
## tracked speed, so this returns 0 (the reactivity no-ops on untracked anchors).
func _anchor_speed(i: int) -> float:
	if not attach_to.is_empty():
		var n := get_node_or_null(attach_to)
		if n is Node3D:
			return 0.0
	if _infl_count > 0:
		var idx := i % _infl_count
		if idx < _infl_speed.size():
			return _infl_speed[idx]
	return 0.0

# --- per-frame update -------------------------------------------------------
func _process(delta: float) -> void:
	if _history.size() != strand_count:
		_reset_strands()
	# Glue each strand's head to its live anchor every frame; commit a new
	# trailing sample at the sample_hz cadence so ribbon length is framerate-stable.
	var commit := false
	_sample_accum += delta
	var step := 1.0 / maxf(sample_hz, 0.001)
	if _sample_accum >= step:
		_sample_accum = 0.0
		commit = true

	for i in strand_count:
		var hist: PackedVector3Array = _history[i]
		var anchor := _anchor_base(i) + (_offsets[i] if i < _offsets.size() else Vector3.ZERO)
		if hist.is_empty():
			hist.append(anchor)
		else:
			hist[hist.size() - 1] = anchor  # live head tracks the anchor
		if commit:
			hist.append(anchor)
			while hist.size() > segments:
				hist.remove_at(0)
		_history[i] = hist

	_update_motion_speed(delta)
	_rebuild_mesh()

## Smooth each strand's anchor speed toward its live tracked value and push the
## motion-scaled brightness into the shader per-frame (like PolyParticles'
## brightness_audio path — the stored `brightness` is never mutated). Width is
## applied per-strand in _rebuild_mesh from the same _strand_speed values. Both
## no-op when their amount is 0 (multiplier collapses to 1) or the anchor is
## untracked (speed 0).
func _update_motion_speed(_delta: float) -> void:
	if _strand_speed.size() != strand_count:
		_strand_speed.resize(strand_count)
	var a := clampf(speed_smoothing, 0.0, 0.98)
	var max_speed := 0.0
	for i in strand_count:
		var raw := _anchor_speed(i)
		var sm := lerpf(raw, _strand_speed[i], a)
		_strand_speed[i] = sm
		max_speed = maxf(max_speed, sm)
	if _mat:
		_mat.set_shader_parameter("u_brightness",
				brightness * (1.0 + max_speed * speed_brightness_amount))

## Rebuild the ImmediateMesh: one camera-facing, width-tapered triangle strip per
## strand. t (0 tail → 1 head) is written into UV.x for the shader's colormap +
## fade. Skips degenerate strands (< 2 points) so differing anchor counts / a
## just-reset buffer never error.
func _rebuild_mesh() -> void:
	if _mesh == null:
		return
	_mesh.clear_surfaces()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var cam_pos := cam.global_position if cam else global_position + Vector3(0, 0, 10)

	var began := false
	for i in strand_count:
		var pts: PackedVector3Array = _history[i]
		var n := pts.size()
		if n < 2:
			continue
		if not began:
			_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
			began = true
		# Motion-scaled width: the stored `width` is never mutated — the tracked
		# anchor speed (0 when untracked, or when speed_width_amount is 0) just
		# scales it for this frame.
		var sp := _strand_speed[i] if i < _strand_speed.size() else 0.0
		var w := width * (1.0 + sp * speed_width_amount)
		# Precompute per-point local position, side offset and length param.
		for s in n - 1:
			var pa := pts[s]
			var pb := pts[s + 1]
			var ta := float(s) / float(n - 1)
			var tb := float(s + 1) / float(n - 1)
			var side_a := _side(pa, pb, cam_pos) * (w * 0.5 * ta)
			var side_b := _side(pa, pb, cam_pos) * (w * 0.5 * tb)
			# Local space so the node transform (and selection gizmo) still apply.
			var la := to_local(pa)
			var lb := to_local(pb)
			var lsa := to_local(pa + side_a) - la
			var lsb := to_local(pb + side_b) - lb
			# Quad (a-left, a-right, b-right, b-left) as two triangles.
			var al := la + lsa
			var ar := la - lsa
			var bl := lb + lsb
			var br := lb - lsb
			_emit_tri(al, ar, br, ta, ta, tb)
			_emit_tri(al, br, bl, ta, tb, tb)
	if began:
		_mesh.surface_end()

## Camera-facing "side" unit vector for the segment pa→pb: perpendicular to both
## the segment and the view direction, so the flat ribbon always faces the camera.
func _side(pa: Vector3, pb: Vector3, cam_pos: Vector3) -> Vector3:
	var seg := pb - pa
	if seg.length() < 0.0001:
		seg = Vector3.RIGHT
	var to_cam := cam_pos - pa
	var side := seg.cross(to_cam)
	if side.length() < 0.0001:
		side = seg.cross(Vector3.UP)
		if side.length() < 0.0001:
			side = Vector3.RIGHT
	return side.normalized()

func _emit_tri(a: Vector3, b: Vector3, c: Vector3, ta: float, tb: float, tc: float) -> void:
	_mesh.surface_set_uv(Vector2(ta, 0.0))
	_mesh.surface_add_vertex(a)
	_mesh.surface_set_uv(Vector2(tb, 0.0))
	_mesh.surface_add_vertex(b)
	_mesh.surface_set_uv(Vector2(tc, 0.0))
	_mesh.surface_add_vertex(c)

# --- shader params ----------------------------------------------------------
func _apply_color() -> void:
	if _mat == null:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_base_color", base_color)
	_mat.set_shader_parameter("u_brightness", brightness)
	_mat.set_shader_parameter("u_opacity", opacity)
	_mat.set_shader_parameter("u_fade", fade)
	_mat.set_shader_parameter("u_influence_tint", influence_tint)

## Store the influence data as anchors and push it to the shader for the tint —
## same fixed-size (MAX_INFLUENCES) convention as the mesh/cloth/particle shaders.
func set_influences(count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array,
		speeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	_infl_count = count
	_infl_pos = positions
	_infl_speed = speeds
	if _mat == null:
		return
	_mat.set_shader_parameter("u_influence_count", count)
	_mat.set_shader_parameter("u_influence_pos", positions)
	_mat.set_shader_parameter("u_influence_radius", radii)
	_mat.set_shader_parameter("u_influence_strength", strengths)
	_mat.set_shader_parameter("u_influence_color", colors)

# --- setters ----------------------------------------------------------------
func set_strand_count(v: int) -> void:
	strand_count = max(v, 1)
	if is_inside_tree():
		_reset_strands()

func set_segments(v: int) -> void:
	segments = max(v, 2)

func set_width(v: float) -> void:
	width = v

func set_spread(v: float) -> void:
	spread = v
	_rebuild_offsets()

func set_seed(v: int) -> void:
	seed = v
	_rebuild_offsets()

func set_attach_to(v: NodePath) -> void:
	attach_to = v

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_color):
		colormap.changed.disconnect(_apply_color)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_color):
		colormap.changed.connect(_apply_color)
	if is_inside_tree():
		_apply_color()

func set_brightness(v: float) -> void:
	brightness = v
	_apply_color()

func set_opacity(v: float) -> void:
	opacity = v
	_apply_color()

func set_fade(v: float) -> void:
	fade = v
	_apply_color()

func set_base_color(v: Color) -> void:
	base_color = v
	_apply_color()

func set_influence_tint(v: float) -> void:
	influence_tint = v
	_apply_color()

func set_speed_width_amount(v: float) -> void:
	speed_width_amount = v

func set_speed_brightness_amount(v: float) -> void:
	speed_brightness_amount = v
	# Restore the stored brightness when turning reactivity off; _process re-pushes
	# the scaled value each frame while it's on.
	if v == 0.0:
		_apply_color()

func set_speed_smoothing(v: float) -> void:
	speed_smoothing = v

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Strands", "props": [
			{"name": "strand_count", "type": "int", "min": 1, "max": 32, "step": 1},
			{"name": "segments", "type": "int", "min": 2, "max": 256, "step": 1},
			{"name": "sample_hz", "type": "float", "min": 6.0, "max": 120.0, "step": 1.0},
			{"name": "width", "type": "float", "min": 0.01, "max": 2.0, "step": 0.01},
			{"name": "spread", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "seed", "type": "int", "min": 0, "max": 9999, "step": 1},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "opacity", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "fade", "type": "float", "min": 0.1, "max": 6.0, "step": 0.05},
			{"name": "base_color", "type": "color"},
			{"name": "influence_tint", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Motion Reactivity", "props": [
			{"name": "speed_width_amount", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "speed_brightness_amount", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "speed_smoothing", "type": "float", "min": 0.0, "max": 0.98, "step": 0.01},
		]},
	]
