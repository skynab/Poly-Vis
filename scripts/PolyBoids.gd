@tool
extends GPUParticles3D
## Boid-flocking GPU particle system (PolyBoids).
##
## Same engine substrate as PolyParticles — a GPUParticles3D driven by a custom
## `shader_type particles` process material — but the motion is boid flocking
## instead of a curl-noise flow. A particle shader can't read its neighbours'
## state, so poly_boids.gdshader approximates Reynolds' three rules from shared
## noise fields keyed off `neighbor_radius` (alignment = follow the local curl
## heading, cohesion = climb a low-frequency attractor, separation = descend a
## high-frequency one). Influences act as attractors (+) or predators (−) through
## the shared u_influence_* arrays and set_influences(). Particle shape / colormap
## / palette / brightness / auto-budget conventions are reused from PolyParticles.
class_name PolyBoids

enum EmitterShape { POINT, SPHERE, BOX, MESH_SURFACE }
## Value driving the colormap lookup (points have no normal, so 2 == age).
enum ColorSource { HEIGHT, DISTANCE, AGE, VELOCITY, NOISE }
## Shape of each boid's draw mesh. All shapes are built at unit scale; the shader
## orients the mesh's +Y axis along the boid's heading and scales by particle_size.
enum ParticleShape { SPHERE, TETRA, SHARD, DISC, SPARK, STREAK }
## Which AudioReactor band (if any) drives brightness_audio_amount.
enum AudioBand { NONE, BASS, MID, TREBLE }

const BOIDS_SHADER := preload("res://shaders/poly_boids.gdshader")

@export_group("Emission")
@export var count: int = 4000: set = set_count
@export_range(0.1, 30.0) var particle_lifetime: float = 8.0: set = set_particle_lifetime
@export var emitter_shape: EmitterShape = EmitterShape.SPHERE: set = set_emitter_shape
@export var emitter_extents: Vector3 = Vector3(3.0, 3.0, 3.0): set = set_emitter_extents
## Uniform scale on the spawn volume — raise it to spread boids over a larger area
## (lower density) without changing the count.
@export_range(0.1, 8.0) var emitter_size: float = 1.0: set = set_emitter_size
@export var particle_shape: ParticleShape = ParticleShape.SHARD: set = set_particle_shape
@export_range(0.01, 0.5) var particle_size: float = 0.06: set = set_particle_size
## Shrink each boid from full size to zero over its lifetime.
@export var particle_size_curve: bool = false: set = set_particle_size_curve
## When emitter_shape is MESH_SURFACE, vertices of this MeshInstance3D are used.
@export var emission_source: NodePath: set = set_emission_source

@export_group("Initial Motion")
@export var direction: Vector3 = Vector3(0.0, 1.0, 0.0): set = set_direction
@export_range(0.0, 20.0) var initial_speed: float = 1.0: set = set_initial_speed
@export_range(0.0, 1.0) var spread: float = 0.5: set = set_spread
@export var gravity: Vector3 = Vector3(0.0, 0.0, 0.0): set = set_gravity

@export_group("Flocking")
## Characteristic flock length — the neighbourhood scale of every steering rule.
## Larger = broader, looser flocks; smaller = tight local groups.
@export_range(0.2, 10.0) var neighbor_radius: float = 1.5: set = set_neighbor_radius
## Weight of the spacing rule (keep boids apart).
@export_range(0.0, 4.0) var separation: float = 1.2: set = set_separation
## Weight of the heading-match rule (steer with the local group).
@export_range(0.0, 4.0) var alignment: float = 1.0: set = set_alignment
## Weight of the gather rule (steer toward the local flock centre).
@export_range(0.0, 4.0) var cohesion: float = 0.8: set = set_cohesion
## Speed cap — boids never move faster than this.
@export_range(0.5, 20.0) var max_speed: float = 4.0: set = set_max_speed
## How fast the flock fields drift/scroll (overall wander rate).
@export_range(0.0, 4.0) var wander_speed: float = 0.4: set = set_wander_speed
## Velocity damping — higher settles the flock, lower keeps it lively.
@export_range(0.0, 4.0) var drag: float = 0.1: set = set_drag
@export var flow_seed: float = 0.0: set = set_flow_seed

@export_group("Performance")
## Automatically scales the boid count down when FPS drops below budget_target_fps.
@export var auto_budget: bool = false: set = set_auto_budget
@export_range(15, 120) var budget_target_fps: int = 60

@export_group("Color")
## Shared colormap. When null, falls back to color_a/color_b lerp.
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.VELOCITY: set = set_color_source
@export var color_min: float = 0.0: set = set_color_min
@export var color_max: float = 6.0: set = set_color_max
@export var color_a: Color = Color(0.1, 0.8, 0.7): set = set_color_a
@export var color_b: Color = Color(0.95, 0.95, 0.2): set = set_color_b
## Scalar multiplied against final boid color.
@export_range(0.0, 4.0) var particle_brightness: float = 1.0: set = set_particle_brightness
## Audio band (if any) that modulates brightness each frame — see _process().
@export var brightness_audio_band: AudioBand = AudioBand.NONE
@export_range(0.0, 4.0) var brightness_audio_amount: float = 1.0

@export_group("Palette")
## When any palette slot is enabled, each boid takes a flat random color from the
## enabled slots — overrides colormap / color_a-b. Toggle slots on/off freely.
@export var palette_enable_1: bool = false: set = set_palette_enable_1
@export var palette_color_1: Color = Color(1.0, 0.2, 0.4): set = set_palette_color_1
@export var palette_enable_2: bool = false: set = set_palette_enable_2
@export var palette_color_2: Color = Color(1.0, 0.6, 0.1): set = set_palette_color_2
@export var palette_enable_3: bool = false: set = set_palette_enable_3
@export var palette_color_3: Color = Color(1.0, 0.95, 0.3): set = set_palette_color_3
@export var palette_enable_4: bool = false: set = set_palette_enable_4
@export var palette_color_4: Color = Color(0.3, 1.0, 0.5): set = set_palette_color_4
@export var palette_enable_5: bool = false: set = set_palette_enable_5
@export var palette_color_5: Color = Color(0.2, 0.7, 1.0): set = set_palette_color_5
@export var palette_enable_6: bool = false: set = set_palette_enable_6
@export var palette_color_6: Color = Color(0.7, 0.3, 1.0): set = set_palette_color_6

var _mat: ShaderMaterial
var _budget_cooldown: float = 0.0
var _fps_samples: Array[float] = []
## Wired by VisualizationManager._register(); null when no reactor exists yet
## (e.g. in the editor) — audio modulation is simply a no-op then.
var audio_reactor: AudioReactor

func _ready() -> void:
	_ensure_material()
	_ensure_draw_pass()
	_apply_all()
	emitting = true

func _process(delta: float) -> void:
	if auto_budget:
		_budget_tick(delta)
	_apply_audio_modulation()

## Multiplies particle_brightness by (1 + level*amount) straight into the shader
## uniform, leaving the stored particle_brightness untouched. `level` is 0 whenever
## no band is selected or the reactor is off/silent — a no-op with no audio.
func _apply_audio_modulation() -> void:
	var level := 0.0
	if brightness_audio_band != AudioBand.NONE and audio_reactor != null and audio_reactor.enabled:
		match brightness_audio_band:
			AudioBand.BASS: level = audio_reactor.bass
			AudioBand.MID: level = audio_reactor.mid
			AudioBand.TREBLE: level = audio_reactor.treble
	_set_param("u_particle_brightness", particle_brightness * (1.0 + level * brightness_audio_amount))

## Same FPS-driven count scaling as PolyParticles: sample once a second over a
## 5-sample window and scale `amount` toward the target FPS.
func _budget_tick(delta: float) -> void:
	_budget_cooldown -= delta
	if _budget_cooldown > 0.0:
		return
	_budget_cooldown = 1.0
	_fps_samples.append(float(Engine.get_frames_per_second()))
	if _fps_samples.size() > 5:
		_fps_samples.pop_front()
	var avg := 0.0
	for s in _fps_samples:
		avg += s
	avg /= _fps_samples.size()
	var ratio := avg / float(budget_target_fps)
	amount = max(int(count * clampf(ratio, 0.05, 1.0)), 1)

# ---------------------------------------------------------------------------
func _ensure_material() -> void:
	if process_material is ShaderMaterial and (process_material as ShaderMaterial).shader == BOIDS_SHADER:
		_mat = process_material
	else:
		_mat = ShaderMaterial.new()
		_mat.shader = BOIDS_SHADER
		process_material = _mat

func _ensure_draw_pass() -> void:
	if draw_pass_1 == null:
		draw_pass_1 = _make_particle_mesh()

## Build the draw mesh for the current particle_shape. All meshes are unit scale;
## the shader orients + sizes them per frame.
func _make_particle_mesh() -> Mesh:
	match particle_shape:
		ParticleShape.TETRA: return _build_tetra()
		ParticleShape.SHARD: return _build_shard()
		ParticleShape.DISC:  return _build_disc()
		ParticleShape.SPARK: return _build_spark()
		ParticleShape.STREAK: return _build_streak()
		_:                   return _build_sphere()

## Shared material: unlit + double-sided so tiny geometry never shows shading artefacts.
func _particle_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _tris_to_mesh(verts: Array, faces: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in faces:
		st.add_vertex(verts[f[0]])
		st.add_vertex(verts[f[1]])
		st.add_vertex(verts[f[2]])
	var m := st.commit()
	m.surface_set_material(0, _particle_mat())
	return m

func _build_sphere() -> Mesh:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 8
	sm.rings = 5
	sm.material = _particle_mat()
	return sm

func _build_tetra() -> ArrayMesh:
	var v := [
		Vector3( 1,  1,  1), Vector3( 1, -1, -1),
		Vector3(-1,  1, -1), Vector3(-1, -1,  1),
	]
	return _tris_to_mesh(v, [[0,1,2],[0,2,3],[0,3,1],[1,3,2]])

## Elongated diamond shard, long axis along +Y — reads as an arrowhead pointing
## along the boid's heading once the shader orients it.
func _build_shard() -> ArrayMesh:
	var v := [
		Vector3( 0.00,  1.5, 0),   # top tip (heading)
		Vector3( 0.28,  0.1, 0),   # right shoulder
		Vector3( 0.00, -0.7, 0),   # tail
		Vector3(-0.28,  0.1, 0),   # left shoulder
	]
	return _tris_to_mesh(v, [[0,1,2],[0,2,3]])

func _build_disc() -> ArrayMesh:
	var verts: Array = [Vector3.ZERO]
	for i in 6:
		var a := i * TAU / 6.0
		verts.append(Vector3(cos(a), sin(a), 0.0))
	var faces: Array = []
	for i in 6:
		faces.append([0, i + 1, ((i + 1) % 6) + 1])
	return _tris_to_mesh(verts, faces)

func _build_spark() -> ArrayMesh:
	const OUTER := 1.0
	const INNER := 0.32
	var verts: Array = [Vector3.ZERO]
	for i in 8:
		var a := i * TAU / 8.0
		var r := OUTER if i % 2 == 0 else INNER
		verts.append(Vector3(cos(a) * r, sin(a) * r, 0.0))
	var faces: Array = []
	for i in 8:
		faces.append([0, i + 1, ((i + 1) % 8) + 1])
	return _tris_to_mesh(verts, faces)

func _build_streak() -> ArrayMesh:
	var hx := 0.08
	var hy := 1.6
	var hz := 0.08
	var v := [
		Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, hy, -hz), Vector3(-hx, hy, -hz),
		Vector3(-hx, -hy, hz), Vector3(hx, -hy, hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz),
	]
	var faces := [
		[4,5,6],[4,6,7], [0,2,1],[0,3,2], [0,7,3],[0,4,7],
		[1,2,6],[1,6,5], [3,7,6],[3,6,2], [0,1,5],[0,5,4],
	]
	return _tris_to_mesh(v, faces)

func _apply_all() -> void:
	amount = max(count, 1)
	lifetime = particle_lifetime
	draw_pass_1 = _make_particle_mesh()
	if not _mat:
		return
	_mat.set_shader_parameter("u_particle_size", particle_size)
	_mat.set_shader_parameter("u_size_curve", particle_size_curve)
	_mat.set_shader_parameter("u_emitter_shape", int(emitter_shape))
	_push_emitter_extents()
	_mat.set_shader_parameter("u_direction", direction)
	_mat.set_shader_parameter("u_initial_speed", initial_speed)
	_mat.set_shader_parameter("u_spread", spread)
	_mat.set_shader_parameter("u_gravity", gravity)
	_mat.set_shader_parameter("u_neighbor_radius", neighbor_radius)
	_mat.set_shader_parameter("u_separation", separation)
	_mat.set_shader_parameter("u_alignment", alignment)
	_mat.set_shader_parameter("u_cohesion", cohesion)
	_mat.set_shader_parameter("u_max_speed", max_speed)
	_mat.set_shader_parameter("u_wander_speed", wander_speed)
	_mat.set_shader_parameter("u_drag", drag)
	_mat.set_shader_parameter("u_seed", flow_seed)
	_mat.set_shader_parameter("u_color_a", color_a)
	_mat.set_shader_parameter("u_color_b", color_b)
	_apply_colormap()
	_apply_palette()
	_bake_emission_points()

func _push_emitter_extents() -> void:
	_set_param("u_emitter_extents", emitter_extents * emitter_size)

func _apply_palette() -> void:
	if not _mat:
		return
	var enables: Array[bool] = [palette_enable_1, palette_enable_2, palette_enable_3,
			palette_enable_4, palette_enable_5, palette_enable_6]
	var colors: Array[Color] = [palette_color_1, palette_color_2, palette_color_3,
			palette_color_4, palette_color_5, palette_color_6]
	var active := PackedColorArray()
	for i in 6:
		if enables[i]:
			active.append(colors[i])
	var n := active.size()
	while active.size() < 6:
		active.append(Color.BLACK)
	_mat.set_shader_parameter("u_palette", active)
	_mat.set_shader_parameter("u_palette_count", n)

func _apply_colormap() -> void:
	if not _mat:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_color_source", int(color_source))
	_mat.set_shader_parameter("u_color_range", Vector2(color_min, color_max))
	_mat.set_shader_parameter("u_particle_brightness", particle_brightness)

## Bake target mesh vertices into a 1-row RGBF texture for mesh-surface emission.
func _bake_emission_points() -> void:
	if not _mat:
		return
	if emitter_shape != EmitterShape.MESH_SURFACE or emission_source.is_empty():
		_mat.set_shader_parameter("u_point_count", 0)
		return
	var mi := get_node_or_null(emission_source) as MeshInstance3D
	if mi == null or mi.mesh == null:
		_mat.set_shader_parameter("u_point_count", 0)
		return
	var arrays: Array = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		_mat.set_shader_parameter("u_point_count", 0)
		return
	var img := Image.create(verts.size(), 1, false, Image.FORMAT_RGBF)
	for i in verts.size():
		var p := verts[i]
		img.set_pixel(i, 0, Color(p.x, p.y, p.z))
	var tex := ImageTexture.create_from_image(img)
	_mat.set_shader_parameter("emission_points", tex)
	_mat.set_shader_parameter("u_point_count", verts.size())

func _set_param(pname: String, value: Variant) -> void:
	if _mat:
		_mat.set_shader_parameter(pname, value)

# --- setters ----------------------------------------------------------------
func set_count(v: int) -> void:
	count = max(v, 1)
	if is_inside_tree():
		amount = count

func set_particle_lifetime(v: float) -> void:
	particle_lifetime = v
	if is_inside_tree():
		lifetime = v

func set_emitter_shape(v: EmitterShape) -> void:
	emitter_shape = v
	_set_param("u_emitter_shape", int(v))
	if is_inside_tree():
		_bake_emission_points()

func set_emitter_extents(v: Vector3) -> void:
	emitter_extents = v
	_push_emitter_extents()

func set_emitter_size(v: float) -> void:
	emitter_size = v
	_push_emitter_extents()

func set_emission_source(v: NodePath) -> void:
	emission_source = v
	if is_inside_tree():
		_bake_emission_points()

func set_direction(v: Vector3) -> void:
	direction = v
	_set_param("u_direction", v)

func set_initial_speed(v: float) -> void:
	initial_speed = v
	_set_param("u_initial_speed", v)

func set_spread(v: float) -> void:
	spread = v
	_set_param("u_spread", v)

func set_gravity(v: Vector3) -> void:
	gravity = v
	_set_param("u_gravity", v)

func set_neighbor_radius(v: float) -> void:
	neighbor_radius = v
	_set_param("u_neighbor_radius", v)

func set_separation(v: float) -> void:
	separation = v
	_set_param("u_separation", v)

func set_alignment(v: float) -> void:
	alignment = v
	_set_param("u_alignment", v)

func set_cohesion(v: float) -> void:
	cohesion = v
	_set_param("u_cohesion", v)

func set_max_speed(v: float) -> void:
	max_speed = v
	_set_param("u_max_speed", v)

func set_wander_speed(v: float) -> void:
	wander_speed = v
	_set_param("u_wander_speed", v)

func set_drag(v: float) -> void:
	drag = v
	_set_param("u_drag", v)

func set_flow_seed(v: float) -> void:
	flow_seed = v
	_set_param("u_seed", v)

func set_particle_shape(v: ParticleShape) -> void:
	particle_shape = v
	draw_pass_1 = _make_particle_mesh()

func set_particle_size(v: float) -> void:
	particle_size = v
	_set_param("u_particle_size", v)

func set_particle_size_curve(v: bool) -> void:
	particle_size_curve = v
	_set_param("u_size_curve", v)

func set_auto_budget(v: bool) -> void:
	auto_budget = v
	if not v:
		amount = count  # restore full count
	_fps_samples.clear()
	_budget_cooldown = 0.0

func set_color_a(v: Color) -> void:
	color_a = v
	_set_param("u_color_a", v)

func set_color_b(v: Color) -> void:
	color_b = v
	_set_param("u_color_b", v)

func set_particle_brightness(v: float) -> void:
	particle_brightness = v
	_set_param("u_particle_brightness", v)

func set_palette_enable_1(v: bool) -> void:
	palette_enable_1 = v
	_apply_palette()

func set_palette_enable_2(v: bool) -> void:
	palette_enable_2 = v
	_apply_palette()

func set_palette_enable_3(v: bool) -> void:
	palette_enable_3 = v
	_apply_palette()

func set_palette_enable_4(v: bool) -> void:
	palette_enable_4 = v
	_apply_palette()

func set_palette_enable_5(v: bool) -> void:
	palette_enable_5 = v
	_apply_palette()

func set_palette_enable_6(v: bool) -> void:
	palette_enable_6 = v
	_apply_palette()

func set_palette_color_1(v: Color) -> void:
	palette_color_1 = v
	_apply_palette()

func set_palette_color_2(v: Color) -> void:
	palette_color_2 = v
	_apply_palette()

func set_palette_color_3(v: Color) -> void:
	palette_color_3 = v
	_apply_palette()

func set_palette_color_4(v: Color) -> void:
	palette_color_4 = v
	_apply_palette()

func set_palette_color_5(v: Color) -> void:
	palette_color_5 = v
	_apply_palette()

func set_palette_color_6(v: Color) -> void:
	palette_color_6 = v
	_apply_palette()

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_colormap):
		colormap.changed.disconnect(_apply_colormap)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_colormap):
		colormap.changed.connect(_apply_colormap)
	if is_inside_tree():
		_apply_colormap()

func set_color_source(v: ColorSource) -> void:
	color_source = v
	_set_param("u_color_source", int(v))

func set_color_min(v: float) -> void:
	color_min = v
	_set_param("u_color_range", Vector2(color_min, color_max))

func set_color_max(v: float) -> void:
	color_max = v
	_set_param("u_color_range", Vector2(color_min, color_max))

## Push influence-field data into the boid shader. Attractors (+strength) gather
## the flock, predators (−strength) scatter it. Arrays are padded to the shader's
## max (8); called every frame by the InfluenceController.
func set_influences(infl_count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array,
		_speeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	if not _mat:
		return
	_mat.set_shader_parameter("u_influence_count", infl_count)
	_mat.set_shader_parameter("u_influence_pos", positions)
	_mat.set_shader_parameter("u_influence_radius", radii)
	_mat.set_shader_parameter("u_influence_strength", strengths)
	_mat.set_shader_parameter("u_influence_color", colors)

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Emission", "props": [
			{"name": "count", "type": "int", "min": 1, "max": 100000, "step": 100},
			{"name": "particle_lifetime", "type": "float", "min": 0.1, "max": 30.0, "step": 0.1},
			{"name": "emitter_shape", "type": "enum", "options": ["Point", "Sphere", "Box", "Mesh Surface"]},
			{"name": "emitter_extents", "type": "vector3"},
			{"name": "emitter_size", "type": "float", "min": 0.1, "max": 8.0, "step": 0.05},
			{"name": "particle_shape", "type": "enum", "options": ["Sphere", "Tetra", "Shard", "Disc", "Spark", "Streak"]},
			{"name": "particle_size", "type": "float", "min": 0.01, "max": 0.5, "step": 0.005},
			{"name": "particle_size_curve", "type": "bool"},
		]},
		{"title": "Initial Motion", "props": [
			{"name": "direction", "type": "vector3"},
			{"name": "initial_speed", "type": "float", "min": 0.0, "max": 20.0, "step": 0.1},
			{"name": "spread", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "gravity", "type": "vector3"},
		]},
		{"title": "Flocking", "props": [
			{"name": "neighbor_radius", "type": "float", "min": 0.2, "max": 10.0, "step": 0.05,
				"hint": "Neighbourhood scale of every steering rule (bigger = looser flocks)"},
			{"name": "separation", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Keep boids spaced apart"},
			{"name": "alignment", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Match the local group's heading"},
			{"name": "cohesion", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Steer toward the local flock centre"},
			{"name": "max_speed", "type": "float", "min": 0.5, "max": 20.0, "step": 0.1},
			{"name": "wander_speed", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "drag", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
		]},
		{"title": "Performance", "props": [
			{"name": "auto_budget", "type": "bool"},
			{"name": "budget_target_fps", "type": "int", "min": 15, "max": 120, "step": 5},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["Height", "Distance", "Age", "Velocity", "Noise"]},
			{"name": "color_min", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_max", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_a", "type": "color"},
			{"name": "color_b", "type": "color"},
			{"name": "particle_brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "brightness_audio_band", "type": "enum", "options": ["None", "Bass", "Mid", "Treble"],
				"hint": "Drive brightness from a live AudioReactor band (Global tab)"},
			{"name": "brightness_audio_amount", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Strength of the audio-driven brightness boost"},
		]},
		{"title": "Palette", "props": [
			{"name": "palette_enable_1", "type": "bool"},
			{"name": "palette_color_1", "type": "color"},
			{"name": "palette_enable_2", "type": "bool"},
			{"name": "palette_color_2", "type": "color"},
			{"name": "palette_enable_3", "type": "bool"},
			{"name": "palette_color_3", "type": "color"},
			{"name": "palette_enable_4", "type": "bool"},
			{"name": "palette_color_4", "type": "color"},
			{"name": "palette_enable_5", "type": "bool"},
			{"name": "palette_color_5", "type": "color"},
			{"name": "palette_enable_6", "type": "bool"},
			{"name": "palette_color_6", "type": "color"},
		]},
	]
