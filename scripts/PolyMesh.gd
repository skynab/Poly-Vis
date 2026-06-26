@tool
extends MeshInstance3D
## Procedural low-poly visualization primitive.
##
## Builds a noise-displaced icosphere with flat (per-face) normals so it reads
## faceted like the reference images (Prompt 1.1). Supports solid / wireframe /
## solid+wireframe rendering with silver edge-tubes and vertex nodes (Prompt 1.2),
## and optional GPU-side animated deformation via a shader uniform (Prompt 1.3).
##
## The CPU geometry carries a static noise displacement (seed/amplitude/frequency).
## The shader's animated displacement rides on top of that and only affects the
## SOLID surface — the wireframe lattice reflects the static base geometry.
class_name PolyMesh

enum RenderMode { SOLID, WIREFRAME, SOLID_WIREFRAME }
## Value driving the colormap lookup. NORMAL uses the object-space radial
## direction (camera-stable); DISPLACEMENT/NOISE use the deformation field.
enum ColorSource { WORLD_HEIGHT, DISTANCE, NORMAL, DISPLACEMENT, NOISE }

const DEFORM_SHADER := preload("res://shaders/polymesh_deform.gdshader")

@export_group("Geometry")
## Icosphere subdivision level. Each step quadruples the triangle count.
@export_range(0, 6) var subdivisions: int = 3: set = set_subdivisions
@export_range(0.1, 10.0) var radius: float = 1.5: set = set_radius
@export_range(0.0, 2.0) var noise_amplitude: float = 0.35: set = set_noise_amplitude
@export_range(0.05, 5.0) var noise_frequency: float = 0.8: set = set_noise_frequency
@export var seed: int = 0: set = set_seed

@export_group("Rendering")
@export var render_mode: RenderMode = RenderMode.SOLID: set = set_render_mode
@export var base_color: Color = Color(0.85, 0.2, 0.45): set = set_base_color
@export_range(0.0, 1.0) var surface_roughness: float = 0.7: set = set_surface_roughness
@export_range(0.0, 1.0) var surface_metallic: float = 0.0: set = set_surface_metallic

@export_group("Color")
## Shared colormap (Prompt 3.1). When null, falls back to base_color.
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.WORLD_HEIGHT: set = set_color_source
@export var color_min: float = -1.8: set = set_color_min
@export var color_max: float = 1.8: set = set_color_max
@export var posterize: bool = false: set = set_posterize
@export_range(1.0, 32.0) var posterize_steps: float = 5.0: set = set_posterize_steps

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.0: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color
@export_range(0.0, 1.0) var translucency: float = 0.0: set = set_translucency

@export_group("Wireframe / Lattice")
@export_range(0.001, 0.1) var edge_radius: float = 0.012: set = set_edge_radius
@export_range(0.001, 0.2) var node_radius: float = 0.03: set = set_node_radius
@export var lattice_color: Color = Color(0.75, 0.76, 0.8): set = set_lattice_color

@export_group("Animation")
## Animate the solid surface with flowing displacement (Prompt 1.3).
@export var animate: bool = false: set = set_animate
@export_range(0.0, 2.0) var anim_amplitude: float = 0.25: set = set_anim_amplitude
@export_range(0.05, 5.0) var anim_frequency: float = 1.2: set = set_anim_frequency
@export_range(0.0, 5.0) var anim_speed: float = 0.6: set = set_anim_speed

# --- internal state --------------------------------------------------------
var _unit_verts: PackedVector3Array      # deduplicated unit-sphere directions
var _faces: PackedInt32Array              # triangle indices into _unit_verts
var _displaced: PackedVector3Array        # static noise-displaced positions
var _surface_mat: ShaderMaterial
var _edge_mmi: MultiMeshInstance3D
var _node_mmi: MultiMeshInstance3D
var _lattice_mat: StandardMaterial3D

func _ready() -> void:
	_ensure_children()
	rebuild()
	set_process(true)

func _process(_delta: float) -> void:
	if _surface_mat:
		_surface_mat.set_shader_parameter("u_time", float(Time.get_ticks_msec()) / 1000.0)

# ---------------------------------------------------------------------------
# Build pipeline
# ---------------------------------------------------------------------------
func rebuild() -> void:
	if not is_inside_tree():
		return
	_ensure_children()
	_generate_icosphere()
	_displace_vertices()
	_build_solid_surface()
	_build_lattice()
	_apply_render_mode()

func _ensure_children() -> void:
	if not _surface_mat:
		_surface_mat = ShaderMaterial.new()
		_surface_mat.shader = DEFORM_SHADER
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.PINK_RED_WHITE))
	if not is_instance_valid(_edge_mmi):
		_edge_mmi = MultiMeshInstance3D.new()
		_edge_mmi.name = "EdgeLattice"
		add_child(_edge_mmi)
	if not is_instance_valid(_node_mmi):
		_node_mmi = MultiMeshInstance3D.new()
		_node_mmi.name = "VertexNodes"
		add_child(_node_mmi)
	if not _lattice_mat:
		_lattice_mat = StandardMaterial3D.new()
		_lattice_mat.metallic = 0.9
		_lattice_mat.roughness = 0.25

func _generate_icosphere() -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var base := PackedVector3Array([
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	])
	var verts: Array[Vector3] = []
	for v in base:
		verts.append(v.normalized())
	var faces := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])

	for _i in range(subdivisions):
		var midpoint_cache := {}
		var new_faces := PackedInt32Array()
		for f in range(0, faces.size(), 3):
			var a := faces[f]
			var b := faces[f + 1]
			var c := faces[f + 2]
			var ab := _midpoint(a, b, verts, midpoint_cache)
			var bc := _midpoint(b, c, verts, midpoint_cache)
			var ca := _midpoint(c, a, verts, midpoint_cache)
			new_faces.append_array(PackedInt32Array([a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]))
		faces = new_faces

	_unit_verts = PackedVector3Array(verts)
	_faces = faces

func _midpoint(i: int, j: int, verts: Array[Vector3], cache: Dictionary) -> int:
	var key := Vector2i(min(i, j), max(i, j))
	if cache.has(key):
		return cache[key]
	var mid := ((verts[i] + verts[j]) * 0.5).normalized()
	var idx := verts.size()
	verts.append(mid)
	cache[key] = idx
	return idx

func _displace_vertices() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed
	noise.frequency = noise_frequency
	_displaced = PackedVector3Array()
	_displaced.resize(_unit_verts.size())
	for i in _unit_verts.size():
		var dir := _unit_verts[i]
		var n := noise.get_noise_3dv(dir * radius)
		_displaced[i] = dir * (radius + n * noise_amplitude)

func _build_solid_surface() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Emit unique vertices per face -> flat normals after generate_normals().
	for f in range(0, _faces.size(), 3):
		var p0 := _displaced[_faces[f]]
		var p1 := _displaced[_faces[f + 1]]
		var p2 := _displaced[_faces[f + 2]]
		st.add_vertex(p0)
		st.add_vertex(p1)
		st.add_vertex(p2)
	st.generate_normals()
	mesh = st.commit()
	_surface_mat.set_shader_parameter("u_base_color", base_color)
	_surface_mat.set_shader_parameter("u_roughness", surface_roughness)
	_surface_mat.set_shader_parameter("u_metallic", surface_metallic)
	_update_anim_uniforms()
	_apply_color_and_polish()
	material_override = _surface_mat

func _build_lattice() -> void:
	_lattice_mat.albedo_color = lattice_color

	# Unique edges from the triangle list.
	var edge_set := {}
	for f in range(0, _faces.size(), 3):
		var idx := [_faces[f], _faces[f + 1], _faces[f + 2]]
		for e in 3:
			var a: int = idx[e]
			var b: int = idx[(e + 1) % 3]
			edge_set[Vector2i(min(a, b), max(a, b))] = true
	var edges := edge_set.keys()

	# Edge tubes via MultiMesh of unit cylinders.
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 6
	cyl.rings = 0
	cyl.material = _lattice_mat
	var edge_mm := MultiMesh.new()
	edge_mm.transform_format = MultiMesh.TRANSFORM_3D
	edge_mm.mesh = cyl
	edge_mm.instance_count = edges.size()
	for i in edges.size():
		var key: Vector2i = edges[i]
		edge_mm.set_instance_transform(i, _edge_transform(_displaced[key.x], _displaced[key.y]))
	_edge_mmi.multimesh = edge_mm

	# Vertex nodes via MultiMesh of small spheres.
	var sph := SphereMesh.new()
	sph.radius = 1.0
	sph.height = 2.0
	sph.radial_segments = 8
	sph.rings = 4
	sph.material = _lattice_mat
	var node_mm := MultiMesh.new()
	node_mm.transform_format = MultiMesh.TRANSFORM_3D
	node_mm.mesh = sph
	node_mm.instance_count = _displaced.size()
	var node_basis := Basis().scaled(Vector3.ONE * node_radius)
	for i in _displaced.size():
		node_mm.set_instance_transform(i, Transform3D(node_basis, _displaced[i]))
	_node_mmi.multimesh = node_mm

func _edge_transform(a: Vector3, b: Vector3) -> Transform3D:
	var axis := b - a
	var length := axis.length()
	if length < 0.00001:
		return Transform3D(Basis().scaled(Vector3(edge_radius, 0.0001, edge_radius)), a)
	var y := axis / length
	var up := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := up.cross(y).normalized()
	var z := x.cross(y)
	var basis := Basis(x * edge_radius, y * length, z * edge_radius)
	return Transform3D(basis, (a + b) * 0.5)

func _apply_render_mode() -> void:
	var show_solid := render_mode != RenderMode.WIREFRAME
	var show_wire := render_mode != RenderMode.SOLID
	# This node IS the solid surface, and visibility propagates to children, so we
	# can't just hide self. Detach the mesh to hide the surface; rebuild() restores it.
	if not show_solid:
		mesh = null
	if is_instance_valid(_edge_mmi):
		_edge_mmi.visible = show_wire
	if is_instance_valid(_node_mmi):
		_node_mmi.visible = show_wire

func _update_anim_uniforms() -> void:
	if not _surface_mat:
		return
	_surface_mat.set_shader_parameter("u_anim_amplitude", anim_amplitude if animate else 0.0)
	_surface_mat.set_shader_parameter("u_anim_frequency", anim_frequency)
	_surface_mat.set_shader_parameter("u_anim_speed", anim_speed)

func _apply_color_and_polish() -> void:
	if not _surface_mat:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_surface_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_surface_mat.set_shader_parameter("u_colormap", tex)
	_surface_mat.set_shader_parameter("u_color_source", int(color_source))
	_surface_mat.set_shader_parameter("u_color_range", Vector2(color_min, color_max))
	_surface_mat.set_shader_parameter("u_posterize", posterize)
	_surface_mat.set_shader_parameter("u_posterize_steps", posterize_steps)
	_surface_mat.set_shader_parameter("u_rim_strength", rim_strength)
	_surface_mat.set_shader_parameter("u_rim_power", rim_power)
	_surface_mat.set_shader_parameter("u_rim_color", rim_color)
	_surface_mat.set_shader_parameter("u_translucency", translucency)

# ---------------------------------------------------------------------------
# Setters — regenerate or update uniforms as cheaply as possible
# ---------------------------------------------------------------------------
func set_subdivisions(v: int) -> void:
	subdivisions = clampi(v, 0, 6)
	rebuild()

func set_radius(v: float) -> void:
	radius = v
	rebuild()

func set_noise_amplitude(v: float) -> void:
	noise_amplitude = v
	rebuild()

func set_noise_frequency(v: float) -> void:
	noise_frequency = v
	rebuild()

func set_seed(v: int) -> void:
	seed = v
	rebuild()

func set_render_mode(v: RenderMode) -> void:
	render_mode = v
	if is_inside_tree():
		# Mode change may need to rebuild the surface if it was nulled.
		rebuild()

func set_base_color(v: Color) -> void:
	base_color = v
	if _surface_mat:
		_surface_mat.set_shader_parameter("u_base_color", v)

func set_surface_roughness(v: float) -> void:
	surface_roughness = v
	if _surface_mat:
		_surface_mat.set_shader_parameter("u_roughness", v)

func set_surface_metallic(v: float) -> void:
	surface_metallic = v
	if _surface_mat:
		_surface_mat.set_shader_parameter("u_metallic", v)

func set_edge_radius(v: float) -> void:
	edge_radius = v
	if is_inside_tree():
		_build_lattice()

func set_node_radius(v: float) -> void:
	node_radius = v
	if is_inside_tree():
		_build_lattice()

func set_lattice_color(v: Color) -> void:
	lattice_color = v
	if _lattice_mat:
		_lattice_mat.albedo_color = v

func set_animate(v: bool) -> void:
	animate = v
	_update_anim_uniforms()

func set_anim_amplitude(v: float) -> void:
	anim_amplitude = v
	_update_anim_uniforms()

func set_anim_frequency(v: float) -> void:
	anim_frequency = v
	_update_anim_uniforms()

func set_anim_speed(v: float) -> void:
	anim_speed = v
	_update_anim_uniforms()

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.disconnect(_apply_color_and_polish)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.connect(_apply_color_and_polish)
	_apply_color_and_polish()

func set_color_source(v: ColorSource) -> void:
	color_source = v
	_apply_color_and_polish()

func set_color_min(v: float) -> void:
	color_min = v
	_apply_color_and_polish()

func set_color_max(v: float) -> void:
	color_max = v
	_apply_color_and_polish()

func set_posterize(v: bool) -> void:
	posterize = v
	_apply_color_and_polish()

func set_posterize_steps(v: float) -> void:
	posterize_steps = v
	_apply_color_and_polish()

func set_rim_strength(v: float) -> void:
	rim_strength = v
	_apply_color_and_polish()

func set_rim_power(v: float) -> void:
	rim_power = v
	_apply_color_and_polish()

func set_rim_color(v: Color) -> void:
	rim_color = v
	_apply_color_and_polish()

func set_translucency(v: float) -> void:
	translucency = v
	_apply_color_and_polish()
