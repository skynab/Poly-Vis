@tool
extends GPUParticles3D
## Configurable GPU particle system for flow-field visualizations.
##
## Prompt 2.1: exposes count / lifetime / initial velocity / gravity / spread and
## an emitter shape (point / sphere / box / mesh-surface), drawing small faceted
## low-poly bits so particles match the polygon aesthetic.
## Prompt 2.2: uses a custom `shader_type particles` process shader (curl-noise
## flow) instead of a ParticleProcessMaterial.
class_name PolyParticles

enum EmitterShape { POINT, SPHERE, BOX, MESH_SURFACE }
## Value driving the colormap lookup (points have no normal, so 2 == age).
enum ColorSource { HEIGHT, DISTANCE, AGE, VELOCITY, NOISE }

const FLOW_SHADER := preload("res://shaders/particle_flow.gdshader")

@export_group("Emission")
@export var count: int = 4000: set = set_count
@export_range(0.1, 30.0) var particle_lifetime: float = 6.0: set = set_particle_lifetime
@export var emitter_shape: EmitterShape = EmitterShape.SPHERE: set = set_emitter_shape
@export var emitter_extents: Vector3 = Vector3(1.5, 1.5, 1.5): set = set_emitter_extents
## When emitter_shape is MESH_SURFACE, vertices of this MeshInstance3D are used.
@export var emission_source: NodePath: set = set_emission_source

@export_group("Initial Motion")
@export var direction: Vector3 = Vector3(0.0, 1.0, 0.0): set = set_direction
@export_range(0.0, 20.0) var initial_speed: float = 1.0: set = set_initial_speed
@export_range(0.0, 1.0) var spread: float = 0.3: set = set_spread
@export var gravity: Vector3 = Vector3(0.0, -0.5, 0.0): set = set_gravity

@export_group("Flow Field")
@export_range(0.05, 4.0) var flow_scale: float = 0.6: set = set_flow_scale
@export_range(0.0, 4.0) var flow_speed: float = 0.4: set = set_flow_speed
@export_range(0.0, 10.0) var turbulence: float = 2.0: set = set_turbulence
@export_range(0.0, 4.0) var drag: float = 0.4: set = set_drag
@export var flow_seed: float = 0.0: set = set_flow_seed

@export_group("Color")
## Shared colormap (Prompt 3.1). When null, falls back to color_a/color_b lerp.
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.VELOCITY: set = set_color_source
@export var color_min: float = 0.0: set = set_color_min
@export var color_max: float = 3.0: set = set_color_max
@export var color_a: Color = Color(0.1, 0.8, 0.7): set = set_color_a
@export var color_b: Color = Color(0.95, 0.95, 0.2): set = set_color_b

var _mat: ShaderMaterial

func _ready() -> void:
	_ensure_material()
	_ensure_draw_pass()
	_apply_all()
	emitting = true

# ---------------------------------------------------------------------------
func _ensure_material() -> void:
	if process_material is ShaderMaterial and (process_material as ShaderMaterial).shader == FLOW_SHADER:
		_mat = process_material
	else:
		_mat = ShaderMaterial.new()
		_mat.shader = FLOW_SHADER
		process_material = _mat

func _ensure_draw_pass() -> void:
	if draw_pass_1 == null:
		draw_pass_1 = _make_particle_mesh()

## Small flat-shaded tetrahedron so each particle reads as a low-poly chip.
func _make_particle_mesh() -> ArrayMesh:
	var s := 0.04
	var v := [
		Vector3(1, 1, 1) * s, Vector3(1, -1, -1) * s,
		Vector3(-1, 1, -1) * s, Vector3(-1, -1, 1) * s,
	]
	var faces := [[0, 1, 2], [0, 2, 3], [0, 3, 1], [1, 3, 2]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in faces:
		st.add_vertex(v[f[0]])
		st.add_vertex(v[f[1]])
		st.add_vertex(v[f[2]])
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # tiny tris; winding-agnostic
	mat.roughness = 0.6
	mesh.surface_set_material(0, mat)
	return mesh

func _apply_all() -> void:
	amount = max(count, 1)
	lifetime = particle_lifetime
	if not _mat:
		return
	_mat.set_shader_parameter("u_emitter_shape", int(emitter_shape))
	_mat.set_shader_parameter("u_emitter_extents", emitter_extents)
	_mat.set_shader_parameter("u_direction", direction)
	_mat.set_shader_parameter("u_initial_speed", initial_speed)
	_mat.set_shader_parameter("u_spread", spread)
	_mat.set_shader_parameter("u_gravity", gravity)
	_mat.set_shader_parameter("u_flow_scale", flow_scale)
	_mat.set_shader_parameter("u_flow_speed", flow_speed)
	_mat.set_shader_parameter("u_turbulence", turbulence)
	_mat.set_shader_parameter("u_drag", drag)
	_mat.set_shader_parameter("u_seed", flow_seed)
	_mat.set_shader_parameter("u_color_a", color_a)
	_mat.set_shader_parameter("u_color_b", color_b)
	_apply_colormap()
	_bake_emission_points()

func _apply_colormap() -> void:
	if not _mat:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_color_source", int(color_source))
	_mat.set_shader_parameter("u_color_range", Vector2(color_min, color_max))

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
	_set_param("u_emitter_extents", v)

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

func set_flow_scale(v: float) -> void:
	flow_scale = v
	_set_param("u_flow_scale", v)

func set_flow_speed(v: float) -> void:
	flow_speed = v
	_set_param("u_flow_speed", v)

func set_turbulence(v: float) -> void:
	turbulence = v
	_set_param("u_turbulence", v)

func set_drag(v: float) -> void:
	drag = v
	_set_param("u_drag", v)

func set_flow_seed(v: float) -> void:
	flow_seed = v
	_set_param("u_seed", v)

func set_color_a(v: Color) -> void:
	color_a = v
	_set_param("u_color_a", v)

func set_color_b(v: Color) -> void:
	color_b = v
	_set_param("u_color_b", v)

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

## Schema consumed by the ParameterPanel (Prompt 4.1).
func get_param_schema() -> Array:
	return [
		{"title": "Emission", "props": [
			{"name": "count", "type": "int", "min": 1, "max": 100000, "step": 100},
			{"name": "particle_lifetime", "type": "float", "min": 0.1, "max": 30.0, "step": 0.1},
			{"name": "emitter_shape", "type": "enum", "options": ["Point", "Sphere", "Box", "Mesh Surface"]},
			{"name": "emitter_extents", "type": "vector3"},
		]},
		{"title": "Initial Motion", "props": [
			{"name": "direction", "type": "vector3"},
			{"name": "initial_speed", "type": "float", "min": 0.0, "max": 20.0, "step": 0.1},
			{"name": "spread", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "gravity", "type": "vector3"},
		]},
		{"title": "Flow Field", "props": [
			{"name": "flow_scale", "type": "float", "min": 0.05, "max": 4.0, "step": 0.05},
			{"name": "flow_speed", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "turbulence", "type": "float", "min": 0.0, "max": 10.0, "step": 0.1},
			{"name": "drag", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["Height", "Distance", "Age", "Velocity", "Noise"]},
			{"name": "color_min", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_max", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_a", "type": "color"},
			{"name": "color_b", "type": "color"},
		]},
	]
