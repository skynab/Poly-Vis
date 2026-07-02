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
@export var noise_seed: int = 0: set = set_noise_seed

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
## Gamma-style remap applied to the colormap lookup coordinate.  1.0 = identity.
@export_range(0.0, 2.0) var contrast: float = 1.0: set = set_contrast
## Scalar multiplied against the final albedo.  >1 punches through without touching the colormap.
@export_range(0.0, 4.0) var brightness: float = 1.0: set = set_brightness

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.0: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color
@export_range(0.0, 1.0) var translucency: float = 0.0: set = set_translucency

@export_group("Wireframe / Lattice")
@export_range(0.001, 0.1) var edge_radius: float = 0.012: set = set_edge_radius
@export_range(0.001, 0.2) var node_radius: float = 0.03: set = set_node_radius
@export var edge_color: Color = Color(0.75, 0.76, 0.8): set = set_edge_color
@export var node_color: Color = Color(0.92, 0.96, 1.0): set = set_node_color
## Emissive glow strength on vertex nodes so they pop against the surface.
@export_range(0.0, 3.0) var node_glow: float = 0.8: set = set_node_glow
## Alpha for the entire lattice — lets the wireframe float over the solid.
@export_range(0.0, 1.0) var lattice_opacity: float = 1.0: set = set_lattice_opacity
## Radial segments on the edge cylinders; 4 = square cross-section (low-poly match).
@export_range(3, 8) var edge_facets: int = 4: set = set_edge_facets

@export_group("Animation")
## Animate the solid surface with flowing displacement (Prompt 1.3).
@export var animate: bool = false: set = set_animate
@export_range(0.0, 2.0) var anim_amplitude: float = 0.25: set = set_anim_amplitude
@export_range(0.05, 5.0) var anim_frequency: float = 1.2: set = set_anim_frequency
@export_range(0.0, 5.0) var anim_speed: float = 0.6: set = set_anim_speed
## Also animate the wireframe/lattice so it tracks the surface (CPU-side, matching
## the GPU noise). Off = static lattice over an animated surface. Heavier at high
## subdivisions since lattice transforms are recomputed each frame.
@export var animate_lattice: bool = false

@export_group("LOD")
## Drop 1 subdivision level beyond lod_dist1, 2 levels beyond lod_dist2.
@export var lod_enabled: bool = false: set = set_lod_enabled
@export_range(1.0, 50.0) var lod_dist1: float = 10.0
@export_range(5.0, 100.0) var lod_dist2: float = 25.0

# --- internal state --------------------------------------------------------
var _unit_verts: PackedVector3Array      # deduplicated unit-sphere directions
var _faces: PackedInt32Array              # triangle indices into _unit_verts
var _displaced: PackedVector3Array        # static noise-displaced positions
var _surface_mat: ShaderMaterial
var _edge_mmi: MultiMeshInstance3D
var _node_mmi: MultiMeshInstance3D
var _edge_mat: StandardMaterial3D
var _node_mat: StandardMaterial3D
var _effective_subdivisions: int = 3     # actual level used (may be < subdivisions when LOD kicks in)
var _lod_level: int = -1                 # -1 forces rebuild on first check
var _edge_list: Array = []               # cached deduped edges (Vector2i) for per-frame lattice anim
var _lattice_animating: bool = false     # tracks when to restore static lattice
var _anim_buf: PackedVector3Array = PackedVector3Array()  # reused animated-position scratch

func _ready() -> void:
	_ensure_children()
	rebuild()
	set_process(true)

func _process(_delta: float) -> void:
	var t := float(Time.get_ticks_msec()) / 1000.0
	if _surface_mat:
		_surface_mat.set_shader_parameter("u_time", t)
	if lod_enabled:
		_update_lod()
	# Lattice animation: only when the lattice is visible and the toggle is on.
	var want_lattice_anim := animate and animate_lattice and render_mode != RenderMode.SOLID
	if want_lattice_anim:
		_update_lattice_anim(t)
		_lattice_animating = true
	elif _lattice_animating:
		_build_lattice()  # restore the static lattice once when animation stops
		_lattice_animating = false

# ---------------------------------------------------------------------------
# Build pipeline
# ---------------------------------------------------------------------------
func rebuild() -> void:
	if not is_inside_tree():
		return
	_effective_subdivisions = subdivisions
	_lod_level = -1  # force re-check next frame
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
	if not _edge_mat:
		_edge_mat = StandardMaterial3D.new()
		_edge_mat.metallic = 0.5
		_edge_mat.roughness = 0.4
	if not _node_mat:
		_node_mat = StandardMaterial3D.new()
		_node_mat.metallic = 0.3
		_node_mat.roughness = 0.3
		_node_mat.emission_enabled = true

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

	for _i in range(_effective_subdivisions):
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
	noise.seed = noise_seed
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
	_apply_lattice_materials()

	# Deduplicated edge list.
	var edge_set := {}
	for f in range(0, _faces.size(), 3):
		var tri := [_faces[f], _faces[f + 1], _faces[f + 2]]
		for e in 3:
			var a: int = tri[e]
			var b: int = tri[(e + 1) % 3]
			edge_set[Vector2i(min(a, b), max(a, b))] = true
	var edges: Array = edge_set.keys()
	_edge_list = edges  # cache for per-frame lattice animation

	# Edge tubes — low-poly cylinder with configurable radial facets.
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = edge_facets
	cyl.rings = 0
	cyl.material = _edge_mat
	var edge_mm := MultiMesh.new()
	edge_mm.transform_format = MultiMesh.TRANSFORM_3D
	edge_mm.mesh = cyl
	edge_mm.instance_count = edges.size()
	for i in edges.size():
		var key: Vector2i = edges[i]
		var pa := _wire_push(_displaced[key.x])
		var pb := _wire_push(_displaced[key.y])
		edge_mm.set_instance_transform(i, _edge_transform(pa, pb))
	_edge_mmi.multimesh = edge_mm

	# Vertex nodes — low-poly sphere with emissive node material.
	var sph := SphereMesh.new()
	sph.radius = 1.0
	sph.height = 2.0
	sph.radial_segments = 6
	sph.rings = 3
	sph.material = _node_mat
	var node_mm := MultiMesh.new()
	node_mm.transform_format = MultiMesh.TRANSFORM_3D
	node_mm.mesh = sph
	node_mm.instance_count = _displaced.size()
	var node_basis := Basis().scaled(Vector3.ONE * node_radius)
	for i in _displaced.size():
		var pos := _wire_push(_displaced[i])
		node_mm.set_instance_transform(i, Transform3D(node_basis, pos))
	_node_mmi.multimesh = node_mm

## Animated position of a static vertex — mirrors polymesh_deform.gdshader's
## vertex animation (displace along the radial direction by simplex noise) so the
## lattice tracks the GPU-animated surface.
func _anim_offset(base: Vector3, t: float) -> Vector3:
	var n := AshimaNoise.snoise3(base * anim_frequency + Vector3(0.0, t * anim_speed, 0.0))
	return base + base.normalized() * (n * anim_amplitude)

## Recompute the lattice MultiMesh transforms from animated vertex positions.
## Updates instance transforms in place (no mesh/MultiMesh rebuild).
func _update_lattice_anim(t: float) -> void:
	if not is_instance_valid(_edge_mmi) or _edge_mmi.multimesh == null:
		return
	if not is_instance_valid(_node_mmi) or _node_mmi.multimesh == null:
		return
	var count := _displaced.size()
	if _anim_buf.size() != count:
		_anim_buf.resize(count)
	for i in count:
		_anim_buf[i] = _anim_offset(_displaced[i], t)
	var node_mm := _node_mmi.multimesh
	var node_basis := Basis().scaled(Vector3.ONE * node_radius)
	for i in count:
		node_mm.set_instance_transform(i, Transform3D(node_basis, _wire_push(_anim_buf[i])))
	var edge_mm := _edge_mmi.multimesh
	for i in _edge_list.size():
		var key: Vector2i = _edge_list[i]
		edge_mm.set_instance_transform(i, _edge_transform(_wire_push(_anim_buf[key.x]), _wire_push(_anim_buf[key.y])))

## Push a lattice vertex slightly outward to clear the solid surface in SOLID_WIREFRAME.
## Uses the radial direction (valid for icosphere-derived meshes).
func _wire_push(pos: Vector3) -> Vector3:
	if render_mode != RenderMode.SOLID_WIREFRAME:
		return pos
	var plen := pos.length()
	if plen < 0.0001:
		return pos
	return pos + (pos / plen) * (edge_radius * 1.5)

## Update material colors, transparency, and emission without rebuilding geometry.
func _apply_lattice_materials() -> void:
	if not _edge_mat or not _node_mat:
		return
	var use_alpha := lattice_opacity < 0.999
	var trans := BaseMaterial3D.TRANSPARENCY_ALPHA if use_alpha else BaseMaterial3D.TRANSPARENCY_DISABLED
	_edge_mat.transparency = trans
	_edge_mat.albedo_color = Color(edge_color.r, edge_color.g, edge_color.b, lattice_opacity)
	_node_mat.transparency = trans
	_node_mat.albedo_color = Color(node_color.r, node_color.g, node_color.b, lattice_opacity)
	_node_mat.emission = node_color
	_node_mat.emission_energy_multiplier = node_glow

func _edge_transform(a: Vector3, b: Vector3) -> Transform3D:
	var axis := b - a
	var length := axis.length()
	if length < 0.00001:
		return Transform3D(Basis().scaled(Vector3(edge_radius, 0.0001, edge_radius)), a)
	var y := axis / length
	var up := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := up.cross(y).normalized()
	var z := x.cross(y)
	var edge_basis := Basis(x * edge_radius, y * length, z * edge_radius)
	return Transform3D(edge_basis, (a + b) * 0.5)

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
	_surface_mat.set_shader_parameter("u_contrast", contrast)
	_surface_mat.set_shader_parameter("u_brightness", brightness)
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

func set_noise_seed(v: int) -> void:
	noise_seed = v
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

func set_edge_color(v: Color) -> void:
	edge_color = v
	_apply_lattice_materials()

func set_node_color(v: Color) -> void:
	node_color = v
	_apply_lattice_materials()

func set_node_glow(v: float) -> void:
	node_glow = v
	_apply_lattice_materials()

func set_lattice_opacity(v: float) -> void:
	lattice_opacity = v
	_apply_lattice_materials()

func set_edge_facets(v: int) -> void:
	edge_facets = clampi(v, 3, 8)
	if is_inside_tree():
		_build_lattice()

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

func set_lod_enabled(v: bool) -> void:
	lod_enabled = v
	if not v:
		# Restore full-res geometry if LOD had downgraded it.
		if _effective_subdivisions != subdivisions:
			rebuild()

func _update_lod() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var dist := global_position.distance_to(cam.global_position)
	var new_level := 0
	if dist > lod_dist2:
		new_level = 2
	elif dist > lod_dist1:
		new_level = 1
	if new_level == _lod_level:
		return
	_lod_level = new_level
	var target: int = max(0, subdivisions - new_level)
	if target == _effective_subdivisions:
		return
	_effective_subdivisions = target
	_generate_icosphere()
	_displace_vertices()
	_build_solid_surface()
	_build_lattice()
	_apply_render_mode()

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

func set_contrast(v: float) -> void:
	contrast = v
	_apply_color_and_polish()

func set_brightness(v: float) -> void:
	brightness = v
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

## Push influence-field data into the surface shader (Prompt 5.3). Called every
## frame by the InfluenceController. Arrays are padded to the shader's max (8).
func set_influences(count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array,
		_speeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	if not _surface_mat:
		return
	_surface_mat.set_shader_parameter("u_influence_count", count)
	_surface_mat.set_shader_parameter("u_influence_pos", positions)
	_surface_mat.set_shader_parameter("u_influence_radius", radii)
	_surface_mat.set_shader_parameter("u_influence_strength", strengths)
	_surface_mat.set_shader_parameter("u_influence_color", colors)

## Schema consumed by the ParameterPanel (Prompt 4.1).
func get_param_schema() -> Array:
	return [
		{"title": "Geometry", "props": [
			{"name": "subdivisions", "type": "int", "min": 0, "max": 6, "step": 1},
			{"name": "radius", "type": "float", "min": 0.1, "max": 10.0, "step": 0.05},
			{"name": "noise_amplitude", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "noise_frequency", "type": "float", "min": 0.05, "max": 5.0, "step": 0.05},
			{"name": "noise_seed", "type": "int", "min": 0, "max": 9999, "step": 1},
		]},
		{"title": "Rendering", "props": [
			{"name": "render_mode", "type": "enum", "options": ["Solid", "Wireframe", "Solid + Wireframe"]},
			{"name": "base_color", "type": "color"},
			{"name": "surface_roughness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "surface_metallic", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["World Height", "Distance", "Normal", "Displacement", "Noise"]},
			{"name": "color_min", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_max", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "posterize", "type": "bool"},
			{"name": "posterize_steps", "type": "float", "min": 1.0, "max": 32.0, "step": 1.0},
			{"name": "contrast", "type": "float", "min": 0.0, "max": 2.0, "step": 0.05},
			{"name": "brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
		]},
		{"title": "Material Polish", "props": [
			{"name": "rim_strength", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "rim_power", "type": "float", "min": 0.5, "max": 8.0, "step": 0.1},
			{"name": "rim_color", "type": "color"},
			{"name": "translucency", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Wireframe / Lattice", "props": [
			{"name": "edge_radius", "type": "float", "min": 0.001, "max": 0.1, "step": 0.001},
			{"name": "node_radius", "type": "float", "min": 0.001, "max": 0.2, "step": 0.001},
			{"name": "edge_color", "type": "color"},
			{"name": "node_color", "type": "color"},
			{"name": "node_glow", "type": "float", "min": 0.0, "max": 3.0, "step": 0.05},
			{"name": "lattice_opacity", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "edge_facets", "type": "int", "min": 3, "max": 8, "step": 1},
		]},
		{"title": "Animation", "props": [
			{"name": "animate", "type": "bool"},
			{"name": "animate_lattice", "type": "bool"},
			{"name": "anim_amplitude", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "anim_frequency", "type": "float", "min": 0.05, "max": 5.0, "step": 0.05},
			{"name": "anim_speed", "type": "float", "min": 0.0, "max": 5.0, "step": 0.05},
		]},
		{"title": "LOD", "props": [
			{"name": "lod_enabled", "type": "bool"},
			{"name": "lod_dist1", "type": "float", "min": 1.0, "max": 50.0, "step": 0.5},
			{"name": "lod_dist2", "type": "float", "min": 5.0, "max": 100.0, "step": 1.0},
		]},
	]
