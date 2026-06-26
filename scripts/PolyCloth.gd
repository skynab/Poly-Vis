@tool
extends MeshInstance3D
## Procedural low-poly crumpled-cloth visualization (Prompt 9.x).
##
## Where PolyMesh is a displaced icosphere (a centered blob), PolyCloth is a
## heavily domain-warped subdivided plane — a sprawling draped sheet that folds,
## overhangs, and leaves gaps, filling the frame like the crumpled-tissue
## reference. The static crumple is baked on the CPU here; polycloth.gdshader
## handles flat shading, the warm/cool facet split, rim, and influence dents.
class_name PolyCloth

## Value driving the colormap lookup. NORMAL gives the pink-vs-periwinkle facet
## split; FOLD/NOISE expose the deformation fields baked into UV2.
enum ColorSource { WORLD_HEIGHT, DISTANCE, NORMAL, FOLD, NOISE }

const CLOTH_SHADER := preload("res://shaders/polycloth.gdshader")

@export_group("Geometry")
## Half-size of the sheet; the plane spans [-extent, extent] in X and Z.
@export_range(1.0, 20.0) var extent: float = 7.0: set = set_extent
## Grid divisions per side. Triangle count scales as O(resolution^2).
@export_range(8, 200) var resolution: int = 72: set = set_resolution
## Vertical crumple height. Large values fold the sheet back over itself.
@export_range(0.0, 8.0) var amplitude: float = 3.5: set = set_amplitude
@export_range(0.02, 2.0) var frequency: float = 0.18: set = set_frequency
## Domain-warp strength — bunches folds together for the crumpled-paper look.
@export_range(0.0, 3.0) var warp: float = 1.2: set = set_warp
## Lateral (XZ) displacement that curls folds into overhangs.
@export_range(0.0, 2.0) var fold: float = 0.6: set = set_fold
@export var noise_seed: int = 0: set = set_noise_seed

@export_group("Rendering")
@export_range(0.0, 1.0) var surface_roughness: float = 0.85: set = set_surface_roughness
@export_range(0.0, 1.0) var surface_metallic: float = 0.0: set = set_surface_metallic

@export_group("Color")
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.NORMAL: set = set_color_source
@export var color_min: float = -1.0: set = set_color_min
@export var color_max: float = 1.0: set = set_color_max
@export var posterize: bool = false: set = set_posterize
@export_range(1.0, 32.0) var posterize_steps: float = 5.0: set = set_posterize_steps
@export_range(0.0, 2.0) var contrast: float = 1.0: set = set_contrast
@export_range(0.0, 4.0) var brightness: float = 1.0: set = set_brightness
## Cool tint blended onto facets facing cool_dir — the periwinkle highlights.
@export var cool_color: Color = Color(0.62, 0.66, 0.98): set = set_cool_color
@export_range(0.0, 1.0) var cool_strength: float = 0.7: set = set_cool_strength
@export var cool_dir: Vector3 = Vector3(0.3, 1.0, 0.2): set = set_cool_dir

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.3: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color
@export_range(0.0, 1.0) var translucency: float = 0.0: set = set_translucency

@export_group("Animation")
@export var animate: bool = false: set = set_animate
@export_range(0.0, 2.0) var anim_amplitude: float = 0.15: set = set_anim_amplitude
@export_range(0.02, 2.0) var anim_frequency: float = 0.6: set = set_anim_frequency
@export_range(0.0, 5.0) var anim_speed: float = 0.4: set = set_anim_speed

# --- internal state --------------------------------------------------------
var _surface_mat: ShaderMaterial

func _ready() -> void:
	_ensure_material()
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
	_ensure_material()
	_build_surface()

func _ensure_material() -> void:
	if not _surface_mat:
		_surface_mat = ShaderMaterial.new()
		_surface_mat.shader = CLOTH_SHADER
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.PINK_RED_WHITE))

## Bake the crumpled grid: domain-warped fractal height along Y plus lateral
## fold offsets along X/Z, then emit unique verts per triangle for flat normals.
func _build_surface() -> void:
	var height := FastNoiseLite.new()
	height.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	height.seed = noise_seed
	height.frequency = frequency
	height.fractal_type = FastNoiseLite.FRACTAL_FBM
	height.fractal_octaves = 4
	height.domain_warp_enabled = warp > 0.001
	height.domain_warp_amplitude = warp * 30.0
	height.domain_warp_frequency = frequency * 0.5

	var lateral := FastNoiseLite.new()
	lateral.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	lateral.seed = noise_seed + 1337
	lateral.frequency = frequency * 1.7

	# Sample a (res+1)^2 grid of crumpled positions, plus the per-vertex height
	# noise and fold magnitude (packed into aux for the shader's color sources).
	var n := resolution + 1
	var step := (extent * 2.0) / float(resolution)
	var pts := PackedVector3Array()
	var aux := PackedVector2Array()
	pts.resize(n * n)
	aux.resize(n * n)
	for gz in n:
		for gx in n:
			var x := -extent + gx * step
			var z := -extent + gz * step
			var hn := height.get_noise_2d(x, z)
			var fx := lateral.get_noise_2d(x + 100.0, z) * fold * amplitude
			var fz := lateral.get_noise_2d(x, z + 100.0) * fold * amplitude
			var idx := gz * n + gx
			pts[idx] = Vector3(x + fx, hn * amplitude, z + fz)
			aux[idx] = Vector2(hn, sqrt(fx * fx + fz * fz))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Two triangles per quad, unique verts -> flat per-face normals.
	for gz in resolution:
		for gx in resolution:
			var i00 := gz * n + gx
			var i10 := gz * n + gx + 1
			var i01 := (gz + 1) * n + gx
			var i11 := (gz + 1) * n + gx + 1
			_emit_tri(st, pts, aux, i00, i01, i11)
			_emit_tri(st, pts, aux, i00, i11, i10)
	st.generate_normals()
	mesh = st.commit()

	_surface_mat.set_shader_parameter("u_roughness", surface_roughness)
	_surface_mat.set_shader_parameter("u_metallic", surface_metallic)
	_update_anim_uniforms()
	_apply_color_and_polish()
	material_override = _surface_mat

func _emit_tri(st: SurfaceTool, pts: PackedVector3Array, aux: PackedVector2Array,
		a: int, b: int, c: int) -> void:
	st.set_uv2(aux[a]); st.add_vertex(pts[a])
	st.set_uv2(aux[b]); st.add_vertex(pts[b])
	st.set_uv2(aux[c]); st.add_vertex(pts[c])

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
	_surface_mat.set_shader_parameter("u_cool_color", cool_color)
	_surface_mat.set_shader_parameter("u_cool_strength", cool_strength)
	_surface_mat.set_shader_parameter("u_cool_dir", cool_dir)
	_surface_mat.set_shader_parameter("u_rim_strength", rim_strength)
	_surface_mat.set_shader_parameter("u_rim_power", rim_power)
	_surface_mat.set_shader_parameter("u_rim_color", rim_color)
	_surface_mat.set_shader_parameter("u_translucency", translucency)

# ---------------------------------------------------------------------------
# Setters
# ---------------------------------------------------------------------------
func set_extent(v: float) -> void:
	extent = v
	rebuild()

func set_resolution(v: int) -> void:
	resolution = clampi(v, 8, 200)
	rebuild()

func set_amplitude(v: float) -> void:
	amplitude = v
	rebuild()

func set_frequency(v: float) -> void:
	frequency = v
	rebuild()

func set_warp(v: float) -> void:
	warp = v
	rebuild()

func set_fold(v: float) -> void:
	fold = v
	rebuild()

func set_noise_seed(v: int) -> void:
	noise_seed = v
	rebuild()

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

func set_cool_color(v: Color) -> void:
	cool_color = v
	_apply_color_and_polish()

func set_cool_strength(v: float) -> void:
	cool_strength = v
	_apply_color_and_polish()

func set_cool_dir(v: Vector3) -> void:
	cool_dir = v
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

## Push influence-field data into the surface shader. Called every frame by the
## InfluenceController; arrays are padded to the shader's max (8).
func set_influences(count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array) -> void:
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
			{"name": "extent", "type": "float", "min": 1.0, "max": 20.0, "step": 0.1},
			{"name": "resolution", "type": "int", "min": 8, "max": 200, "step": 1},
			{"name": "amplitude", "type": "float", "min": 0.0, "max": 8.0, "step": 0.05},
			{"name": "frequency", "type": "float", "min": 0.02, "max": 2.0, "step": 0.01},
			{"name": "warp", "type": "float", "min": 0.0, "max": 3.0, "step": 0.05},
			{"name": "fold", "type": "float", "min": 0.0, "max": 2.0, "step": 0.02},
			{"name": "noise_seed", "type": "int", "min": 0, "max": 9999, "step": 1},
		]},
		{"title": "Rendering", "props": [
			{"name": "surface_roughness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "surface_metallic", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["World Height", "Distance", "Normal", "Fold", "Noise"]},
			{"name": "color_min", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_max", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "posterize", "type": "bool"},
			{"name": "posterize_steps", "type": "float", "min": 1.0, "max": 32.0, "step": 1.0},
			{"name": "contrast", "type": "float", "min": 0.0, "max": 2.0, "step": 0.05},
			{"name": "brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "cool_color", "type": "color"},
			{"name": "cool_strength", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "cool_dir", "type": "vector3"},
		]},
		{"title": "Material Polish", "props": [
			{"name": "rim_strength", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "rim_power", "type": "float", "min": 0.5, "max": 8.0, "step": 0.1},
			{"name": "rim_color", "type": "color"},
			{"name": "translucency", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Animation", "props": [
			{"name": "animate", "type": "bool"},
			{"name": "anim_amplitude", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "anim_frequency", "type": "float", "min": 0.02, "max": 2.0, "step": 0.01},
			{"name": "anim_speed", "type": "float", "min": 0.0, "max": 5.0, "step": 0.05},
		]},
	]
