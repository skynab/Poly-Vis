@tool
extends MeshInstance3D
## Raymarched metaball visualization: blobs seeded from the active influences.
##
## A proxy box carries a raymarching SDF shader (poly_metaballs.gdshader). Each
## active InfluenceObject becomes one sphere in a smooth-minimum union, so as two
## influences move together their blobs bulge and merge into a single surface.
## The SDF is evaluated in a fragment shader (no CPU mesh rebuild) for LED-wall
## performance; `quality` caps the per-pixel sphere-tracing steps. Color reuses
## the shared GradientColormap plus the posterize / rim / influence-tint
## conventions from polymesh_deform.gdshader.
##
## Influences arrive in world space via set_influences() (the same fixed-size
## arrays the mesh/cloth shaders use), so the blobs track influence motion
## regardless of this node's own transform — the box (`bounds`) just has to stay
## big enough to contain them.
class_name PolyMetaballs

## Colormap driver, mirroring the mesh's first three sources.
enum ColorSource { WORLD_HEIGHT, DISTANCE, NORMAL }

const METABALL_SHADER := preload("res://shaders/poly_metaballs.gdshader")
const MAX_INFLUENCES := 8

@export_group("Field")
## Side length of the proxy box the shader marches inside. Must be large enough to
## contain every blob — influences that stray outside get clipped at the box face.
@export_range(2.0, 40.0) var bounds: float = 12.0: set = set_bounds
## Base blob radius, scaled per-influence by its own radius (radius / 2), so a
## default influence (radius 2) yields a blob of exactly this size.
@export_range(0.05, 6.0) var blob_radius: float = 1.0: set = set_blob_radius
## Smooth-min blend width. 0 = hard spheres; higher fuses nearby blobs into
## rounder, more liquid merges.
@export_range(0.0, 4.0) var smoothness: float = 0.6: set = set_smoothness
## Stretch each blob backward along its influence's recent motion (from the shared
## trajectory history in InfluenceController) for a comet / smear tail. 0 = round
## blobs; higher = longer tails. No-op on a still influence (zero motion).
@export_range(0.0, 4.0) var motion_stretch: float = 0.0: set = set_motion_stretch

@export_group("Quality")
## Max sphere-tracing steps per pixel — the primary GPU cost. Sphere tracing leaps
## across empty space, so this is a ceiling; lower it if the LED wall struggles.
@export_range(16, 256) var quality: int = 96: set = set_quality
## Surface hit threshold + normal epsilon. Larger = cheaper but rounder/softer.
@export_range(0.001, 0.1) var surface_eps: float = 0.01: set = set_surface_eps

@export_group("Color")
@export var colormap: GradientColormap: set = set_colormap
@export var color_source: ColorSource = ColorSource.DISTANCE: set = set_color_source
@export var color_min: float = -2.0: set = set_color_min
@export var color_max: float = 2.0: set = set_color_max
@export var base_color: Color = Color(0.85, 0.2, 0.45): set = set_base_color
@export var posterize: bool = false: set = set_posterize
@export_range(1.0, 32.0) var posterize_steps: float = 5.0: set = set_posterize_steps
@export_range(0.0, 2.0) var contrast: float = 1.0: set = set_contrast
@export_range(0.0, 4.0) var brightness: float = 1.0: set = set_brightness

@export_group("Rendering")
@export_range(0.0, 1.0) var surface_roughness: float = 0.4: set = set_surface_roughness
@export_range(0.0, 1.0) var surface_metallic: float = 0.0: set = set_surface_metallic

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.0: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color
@export_range(0.0, 1.0) var translucency: float = 0.0: set = set_translucency

var _mat: ShaderMaterial

func _ready() -> void:
	_ensure_setup()

func _ensure_setup() -> void:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = METABALL_SHADER
		material_override = _mat
	if mesh == null:
		mesh = BoxMesh.new()
	_apply_bounds()
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.VIRIDIS))
	_apply_field()
	_apply_color_and_polish()

# --- parameter push ---------------------------------------------------------
func _apply_bounds() -> void:
	if mesh is BoxMesh:
		(mesh as BoxMesh).size = Vector3.ONE * bounds
	if _mat:
		_mat.set_shader_parameter("u_max_dist", bounds * 6.0)

func _apply_field() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("u_blob_radius", blob_radius)
	_mat.set_shader_parameter("u_smoothness", smoothness)
	_mat.set_shader_parameter("u_max_steps", quality)
	_mat.set_shader_parameter("u_surface_eps", surface_eps)
	_mat.set_shader_parameter("u_motion_stretch", motion_stretch)

func _apply_color_and_polish() -> void:
	if _mat == null:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_base_color", base_color)
	_mat.set_shader_parameter("u_color_source", int(color_source))
	_mat.set_shader_parameter("u_color_range", Vector2(color_min, color_max))
	_mat.set_shader_parameter("u_posterize", posterize)
	_mat.set_shader_parameter("u_posterize_steps", posterize_steps)
	_mat.set_shader_parameter("u_contrast", contrast)
	_mat.set_shader_parameter("u_brightness", brightness)
	_mat.set_shader_parameter("u_roughness", surface_roughness)
	_mat.set_shader_parameter("u_metallic", surface_metallic)
	_mat.set_shader_parameter("u_rim_strength", rim_strength)
	_mat.set_shader_parameter("u_rim_power", rim_power)
	_mat.set_shader_parameter("u_rim_color", rim_color)
	_mat.set_shader_parameter("u_translucency", translucency)

## Push influence-field data into the shader — the same fixed-size (MAX_INFLUENCES)
## arrays as the mesh/cloth shaders. Each active influence seeds one blob.
func set_influences(count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array,
		_speeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("u_influence_count", count)
	_mat.set_shader_parameter("u_influence_pos", positions)
	_mat.set_shader_parameter("u_influence_radius", radii)
	_mat.set_shader_parameter("u_influence_strength", strengths)
	_mat.set_shader_parameter("u_influence_color", colors)

## Per-active-influence recent-motion vectors (oldest→newest displacement of each
## influence's trajectory), pushed each frame by InfluenceController alongside
## set_influences(). The shader elongates each blob backward along these, scaled by
## motion_stretch, for the comet/smear effect. Same fixed-size (MAX_INFLUENCES)
## ordering as the influence arrays.
func set_influence_motion(motion: PackedVector3Array) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("u_influence_motion", motion)

# --- setters ----------------------------------------------------------------
func set_bounds(v: float) -> void:
	bounds = v
	if is_inside_tree():
		_apply_bounds()

func set_blob_radius(v: float) -> void:
	blob_radius = v
	_apply_field()

func set_smoothness(v: float) -> void:
	smoothness = v
	_apply_field()

func set_motion_stretch(v: float) -> void:
	motion_stretch = v
	if _mat:
		_mat.set_shader_parameter("u_motion_stretch", v)

func set_quality(v: int) -> void:
	quality = v
	_apply_field()

func set_surface_eps(v: float) -> void:
	surface_eps = v
	_apply_field()

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.disconnect(_apply_color_and_polish)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.connect(_apply_color_and_polish)
	if is_inside_tree():
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

func set_base_color(v: Color) -> void:
	base_color = v
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

func set_surface_roughness(v: float) -> void:
	surface_roughness = v
	_apply_color_and_polish()

func set_surface_metallic(v: float) -> void:
	surface_metallic = v
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

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Field", "props": [
			{"name": "bounds", "type": "float", "min": 2.0, "max": 40.0, "step": 0.5,
				"hint": "Size of the raymarch box; must contain the blobs or they clip at the faces"},
			{"name": "blob_radius", "type": "float", "min": 0.05, "max": 6.0, "step": 0.05},
			{"name": "smoothness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Merge blend — higher fuses nearby blobs into rounder, more liquid joins"},
			{"name": "motion_stretch", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05,
				"hint": "Elongate each blob along its influence's recent path (comet tail); 0 = round"},
		]},
		{"title": "Quality", "props": [
			{"name": "quality", "type": "int", "min": 16, "max": 256, "step": 8,
				"hint": "Max raymarch steps/pixel — the main GPU cost. Lower it if the LED wall drops frames"},
			{"name": "surface_eps", "type": "float", "min": 0.001, "max": 0.1, "step": 0.001,
				"hint": "Hit threshold; larger is cheaper but softens fine detail"},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "color_source", "type": "enum", "options": ["World Height", "Distance", "Normal"]},
			{"name": "color_min", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "color_max", "type": "float", "min": -10.0, "max": 10.0, "step": 0.05},
			{"name": "base_color", "type": "color"},
			{"name": "posterize", "type": "bool"},
			{"name": "posterize_steps", "type": "float", "min": 1.0, "max": 32.0, "step": 1.0},
			{"name": "contrast", "type": "float", "min": 0.0, "max": 2.0, "step": 0.05},
			{"name": "brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
		]},
		{"title": "Rendering", "props": [
			{"name": "surface_roughness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "surface_metallic", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Material Polish", "props": [
			{"name": "rim_strength", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "rim_power", "type": "float", "min": 0.5, "max": 8.0, "step": 0.1},
			{"name": "rim_color", "type": "color"},
			{"name": "translucency", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
	]
