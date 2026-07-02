@tool
extends MeshInstance3D
## Fractured Voronoi icosphere (PolyVoronoi).
##
## A noise-displaced icosphere (PolyMesh's base form) whose surface is split into
## Voronoi cells: random seed directions on the sphere, each triangle assigned to
## its nearest seed. Every triangle bakes its cell's object-space centroid into
## CUSTOM0.xyz and a per-cell id into CUSTOM0.w; poly_voronoi.gdshader then pushes
## each cell outward as a rigid chunk by proximity to the influence field, so the
## shell cracks open where an influence is near. Reuses PolyMesh's icosphere +
## simplex-displacement math and the shared colormap / posterize / rim / influence
## uniform conventions; adds a "Cell" color source for a flat per-cell mosaic.
class_name PolyVoronoi

## Value driving the colormap lookup. CELL flat-colors each cell (the mosaic look);
## SHATTER lights cells by how far they've cracked open.
enum ColorSource { WORLD_HEIGHT, DISTANCE, NORMAL, CELL, SHATTER }

const VORONOI_SHADER := preload("res://shaders/poly_voronoi.gdshader")

@export_group("Geometry")
## Icosphere subdivision level. Each step quadruples the triangle count.
@export_range(0, 6) var subdivisions: int = 3: set = set_subdivisions
@export_range(0.1, 10.0) var radius: float = 1.5: set = set_radius
@export_range(0.0, 2.0) var noise_amplitude: float = 0.25: set = set_noise_amplitude
@export_range(0.05, 5.0) var noise_frequency: float = 0.8: set = set_noise_frequency
@export var noise_seed: int = 0: set = set_noise_seed
## Relative Voronoi cell size: larger = fewer, bigger shards; smaller = a fine
## mosaic of many shards. Cell count is capped to the triangle budget so every
## cell keeps a couple of faces.
@export_range(0.05, 1.0) var cell_size: float = 0.3: set = set_cell_size

@export_group("Fracture")
## World distance a cell is pushed outward per unit of influence proximity.
@export_range(0.0, 4.0) var shatter_amount: float = 0.6: set = set_shatter_amount
## Sharpness of the crack edge — higher confines the opening to cells very close to
## an influence; lower cracks a broader region open.
@export_range(0.1, 8.0) var gap_falloff: float = 2.0: set = set_gap_falloff

@export_group("Rendering")
@export var base_color: Color = Color(0.85, 0.2, 0.45): set = set_base_color
@export_range(0.0, 1.0) var surface_roughness: float = 0.6: set = set_surface_roughness
@export_range(0.0, 1.0) var surface_metallic: float = 0.0: set = set_surface_metallic

@export_group("Color")
## Shared colormap. When null, falls back to base_color.
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.CELL: set = set_color_source
@export var color_min: float = 0.0: set = set_color_min
@export var color_max: float = 1.0: set = set_color_max
@export var posterize: bool = false: set = set_posterize
@export_range(1.0, 32.0) var posterize_steps: float = 5.0: set = set_posterize_steps
@export_range(0.0, 2.0) var contrast: float = 1.0: set = set_contrast
@export_range(0.0, 4.0) var brightness: float = 1.0: set = set_brightness

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.0: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color
@export_range(0.0, 1.0) var translucency: float = 0.0: set = set_translucency

# --- internal state --------------------------------------------------------
var _unit_verts: PackedVector3Array      # deduplicated unit-sphere directions
var _faces: PackedInt32Array              # triangle indices into _unit_verts
var _displaced: PackedVector3Array        # static noise-displaced positions
var _tri_centroid: PackedVector3Array     # per-triangle cell centroid (object space)
var _tri_cellid: PackedFloat32Array       # per-triangle cell id fraction [0,1]
var _surface_mat: ShaderMaterial

func _ready() -> void:
	_ensure_material()
	rebuild()

# ---------------------------------------------------------------------------
# Build pipeline
# ---------------------------------------------------------------------------
func rebuild() -> void:
	if not is_inside_tree():
		return
	_ensure_material()
	_generate_icosphere()
	_displace_vertices()
	_assign_cells()
	_build_fractured_surface()

func _ensure_material() -> void:
	if not _surface_mat:
		_surface_mat = ShaderMaterial.new()
		_surface_mat.shader = VORONOI_SHADER
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.RAINBOW))

# --- icosphere + displacement (reused from PolyMesh) -----------------------
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
	noise.seed = noise_seed
	noise.frequency = noise_frequency
	_displaced = PackedVector3Array()
	_displaced.resize(_unit_verts.size())
	for i in _unit_verts.size():
		var dir := _unit_verts[i]
		var n := noise.get_noise_3dv(dir * radius)
		_displaced[i] = dir * (radius + n * noise_amplitude)

# --- Voronoi cell partition ------------------------------------------------
## Scatter seed directions on the sphere, assign each triangle to its nearest seed,
## then bake per-cell centroids + ids. Cell count derives from cell_size but is
## capped so cells keep at least ~2 triangles each. Deterministic from noise_seed.
func _assign_cells() -> void:
	var tri_count := _faces.size() / 3
	var target := int(round(6.0 + (1.0 - clampf(cell_size, 0.05, 1.0)) * 260.0))
	var num_cells := clampi(target, 6, max(6, tri_count / 2))

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(noise_seed)
	var seeds := PackedVector3Array()
	var cell_ids := PackedFloat32Array()
	for c in num_cells:
		var d := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		if d.length() < 0.0001:
			d = Vector3.UP
		seeds.append(d.normalized())
		cell_ids.append(rng.randf())            # scattered id so colors don't band

	# Nearest-seed assignment per triangle (by centroid direction) + centroid accum.
	var tri_cell := PackedInt32Array()
	tri_cell.resize(tri_count)
	var sum_pos := PackedVector3Array()
	sum_pos.resize(num_cells)
	var counts := PackedInt32Array()
	counts.resize(num_cells)
	for ti in tri_count:
		var f := ti * 3
		var i0 := _faces[f]
		var i1 := _faces[f + 1]
		var i2 := _faces[f + 2]
		var cdir := (_unit_verts[i0] + _unit_verts[i1] + _unit_verts[i2]).normalized()
		var best := 0
		var best_dot := -2.0
		for c in num_cells:
			var dp := cdir.dot(seeds[c])
			if dp > best_dot:
				best_dot = dp
				best = c
		tri_cell[ti] = best
		var tri_center := (_displaced[i0] + _displaced[i1] + _displaced[i2]) / 3.0
		sum_pos[best] += tri_center
		counts[best] += 1

	# Per-cell centroid; fan out to per-triangle arrays the surface builder reads.
	var centroids := PackedVector3Array()
	centroids.resize(num_cells)
	for c in num_cells:
		centroids[c] = sum_pos[c] / float(counts[c]) if counts[c] > 0 else seeds[c] * radius
	_tri_centroid = PackedVector3Array()
	_tri_centroid.resize(tri_count)
	_tri_cellid = PackedFloat32Array()
	_tri_cellid.resize(tri_count)
	for ti in tri_count:
		var c := tri_cell[ti]
		_tri_centroid[ti] = centroids[c]
		_tri_cellid[ti] = cell_ids[c]

## Emit unique verts per triangle (flat normals) carrying the cell centroid + id in
## CUSTOM0, so the shader can rigidly push each cell along its outward direction.
func _build_fractured_surface() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	for ti in _faces.size() / 3:
		var f := ti * 3
		var cc := _tri_centroid[ti]
		var custom := Color(cc.x, cc.y, cc.z, _tri_cellid[ti])
		for k in 3:
			st.set_custom(0, custom)
			st.add_vertex(_displaced[_faces[f + k]])
	st.generate_normals()
	mesh = st.commit()

	_surface_mat.set_shader_parameter("u_base_color", base_color)
	_surface_mat.set_shader_parameter("u_roughness", surface_roughness)
	_surface_mat.set_shader_parameter("u_metallic", surface_metallic)
	_push_fracture()
	_apply_color_and_polish()
	material_override = _surface_mat

func _push_fracture() -> void:
	if not _surface_mat:
		return
	_surface_mat.set_shader_parameter("u_shatter_amount", shatter_amount)
	_surface_mat.set_shader_parameter("u_gap_falloff", gap_falloff)

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
# Setters — geometry/cell params rebuild; fracture/color params push uniforms.
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

func set_cell_size(v: float) -> void:
	cell_size = v
	rebuild()

func set_shatter_amount(v: float) -> void:
	shatter_amount = v
	_push_fracture()

func set_gap_falloff(v: float) -> void:
	gap_falloff = v
	_push_fracture()

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

## Push influence-field data into the surface shader. Called every frame by the
## InfluenceController; arrays are padded to the shader's max (8).
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

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Geometry", "props": [
			{"name": "subdivisions", "type": "int", "min": 0, "max": 6, "step": 1},
			{"name": "radius", "type": "float", "min": 0.1, "max": 10.0, "step": 0.05},
			{"name": "noise_amplitude", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "noise_frequency", "type": "float", "min": 0.05, "max": 5.0, "step": 0.05},
			{"name": "noise_seed", "type": "int", "min": 0, "max": 9999, "step": 1},
			{"name": "cell_size", "type": "float", "min": 0.05, "max": 1.0, "step": 0.01,
				"hint": "Larger = fewer, bigger shards; smaller = a fine mosaic"},
		]},
		{"title": "Fracture", "props": [
			{"name": "shatter_amount", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "How far cells push outward near an influence"},
			{"name": "gap_falloff", "type": "float", "min": 0.1, "max": 8.0, "step": 0.05,
				"hint": "Higher confines the cracks to cells right by the influence"},
		]},
		{"title": "Rendering", "props": [
			{"name": "base_color", "type": "color"},
			{"name": "surface_roughness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "surface_metallic", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["World Height", "Distance", "Normal", "Cell", "Shatter"]},
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
	]
