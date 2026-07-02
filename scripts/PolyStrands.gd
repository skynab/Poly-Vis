@tool
extends MeshInstance3D
## Dense field of instanced blades/strands over a ground plane (PolyStrands).
##
## Where PolyCloth is a single draped sheet, PolyStrands is a meadow: `density`
## thin tapered blades standing on the y=0 plane, each a short vertical strip. The
## static field (positions, heights, orientations) is baked once on the CPU here
## via `_build_field()`; poly_strands.gdshader does the per-frame motion — an idle
## wind sway plus influence "combing" (attract influences bend blades toward them,
## repel push them away, with falloff over u_influence_radius). Reuses the
## u_influence_* / colormap / posterize / rim conventions of the mesh/cloth shaders.
class_name PolyStrands

const STRANDS_SHADER := preload("res://shaders/poly_strands.gdshader")

## Vertical segments per blade — more bend smoothly, but multiply the vertex count.
const SEGMENTS := 5

@export_group("Field")
## Number of blades in the field. Vertex cost scales linearly (each blade is a
## SEGMENTS-segment strip), so rebuilds only on change, not per frame.
@export_range(50, 20000) var density: int = 3000: set = set_density
## Half-size of the ground plane; blades scatter across [-extent, extent] in X/Z.
@export_range(1.0, 40.0) var extent: float = 8.0: set = set_extent
## World height of a blade (before the per-blade height variation). Also scales how
## far the sway/comb bend reaches, so blades and their motion stay in proportion.
@export_range(0.1, 8.0) var blade_length: float = 1.2: set = set_blade_length
## Width of a blade at its base (tapers to a point at the tip), as a fraction of
## blade_length.
@export_range(0.01, 0.5) var blade_width: float = 0.08: set = set_blade_width
## Random seed for blade placement, orientation and height variation.
@export var seed: int = 0: set = set_seed

@export_group("Motion")
## How strongly a blade resists bending — higher stands the field up stiffer under
## both wind and influences (shader-only, no rebuild).
@export_range(0.05, 8.0) var stiffness: float = 1.0: set = set_stiffness
## Idle wind strength — how far blades drift when no influence is near.
@export_range(0.0, 2.0) var sway_amount: float = 0.3: set = set_sway_amount
## Idle wind rate.
@export_range(0.0, 4.0) var sway_speed: float = 0.6: set = set_sway_speed

@export_group("Rendering")
@export_range(0.0, 1.0) var surface_roughness: float = 0.9: set = set_surface_roughness
@export_range(0.0, 1.0) var surface_metallic: float = 0.0: set = set_surface_metallic

@export_group("Color")
@export var colormap: GradientColormap: set = set_colormap
## Blade-root color (fallback gradient bottom, used when no colormap is assigned).
@export var base_color: Color = Color(0.10, 0.35, 0.12): set = set_base_color
## Blade-tip color (fallback gradient top, used when no colormap is assigned).
@export var tip_color: Color = Color(0.55, 0.85, 0.30): set = set_tip_color
@export_range(0.0, 4.0) var brightness: float = 1.0: set = set_brightness
@export_range(0.0, 2.0) var contrast: float = 1.0: set = set_contrast
@export var posterize: bool = false: set = set_posterize
@export_range(1.0, 32.0) var posterize_steps: float = 5.0: set = set_posterize_steps

@export_group("Material Polish")
@export_range(0.0, 2.0) var rim_strength: float = 0.3: set = set_rim_strength
@export_range(0.5, 8.0) var rim_power: float = 2.5: set = set_rim_power
@export var rim_color: Color = Color.WHITE: set = set_rim_color

# --- internal state --------------------------------------------------------
var _mat: ShaderMaterial

func _ready() -> void:
	_ensure_material()
	rebuild()
	set_process(true)

func _process(_delta: float) -> void:
	if _mat:
		_mat.set_shader_parameter("u_time", float(Time.get_ticks_msec()) / 1000.0)

# ---------------------------------------------------------------------------
# Build pipeline
# ---------------------------------------------------------------------------
func rebuild() -> void:
	if not is_inside_tree():
		return
	_ensure_material()
	_build_field()

func _ensure_material() -> void:
	if not _mat:
		_mat = ShaderMaterial.new()
		_mat.shader = STRANDS_SHADER
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.GREEN_TEAL))

## Bake the whole field into one mesh: a base ground quad (t=0 → base color / stays
## put) plus `density` tapered blades scattered across the plane. Each vertex carries
## its normalized height in UV.y (the shader's bend + color param) and its blade root
## XZ in UV2 (so the shader can sample influences/sway per blade), with a flat baked
## normal for lighting.
func _build_field() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Ground plane: two triangles at y=0. UV.y=0 keeps it in the base color and,
	# since the shader's bend/sway scale with height (t^2), perfectly still.
	_emit_ground(st)

	for _b in density:
		var bx := rng.randf_range(-extent, extent)
		var bz := rng.randf_range(-extent, extent)
		var base := Vector3(bx, 0.0, bz)
		var ang := rng.randf_range(0.0, TAU)
		var w := Vector3(-sin(ang), 0.0, cos(ang))     # horizontal width axis
		var n := Vector3(cos(ang), 0.0, sin(ang))      # flat face normal
		var h := blade_length * rng.randf_range(0.75, 1.05)
		var half := blade_width * blade_length * 0.5
		_emit_blade(st, base, w, n, h, half)

	mesh = st.commit()
	_push_motion()
	_apply_color_and_polish()
	material_override = _mat

## One blade: a vertical strip of SEGMENTS quads, tapering from `half` width at the
## base to a point at the tip. Verts carry UV=(side, t), UV2=root XZ, normal=n.
func _emit_blade(st: SurfaceTool, base: Vector3, w: Vector3, n: Vector3, h: float,
		half: float) -> void:
	var uv2 := Vector2(base.x, base.z)
	# Build the two rails of vertices first, then stitch quads between rows.
	var lefts: Array[Vector3] = []
	var rights: Array[Vector3] = []
	for s in SEGMENTS + 1:
		var t := float(s) / float(SEGMENTS)
		var hw := half * (1.0 - t)                     # taper to a point
		var y := Vector3(0.0, t * h, 0.0)
		lefts.append(base + w * -hw + y)
		rights.append(base + w * hw + y)
	for s in SEGMENTS:
		var t0 := float(s) / float(SEGMENTS)
		var t1 := float(s + 1) / float(SEGMENTS)
		var l0 := lefts[s]
		var r0 := rights[s]
		var l1 := lefts[s + 1]
		var r1 := rights[s + 1]
		# Quad (l0, r0, r1, l1) as two triangles; cull_disabled so winding is moot.
		_v(st, n, 0.0, t0, uv2, l0)
		_v(st, n, 1.0, t0, uv2, r0)
		_v(st, n, 1.0, t1, uv2, r1)
		_v(st, n, 0.0, t0, uv2, l0)
		_v(st, n, 1.0, t1, uv2, r1)
		_v(st, n, 0.0, t1, uv2, l1)

## Flat ground quad across the plane (t=0 → base color, no motion).
func _emit_ground(st: SurfaceTool) -> void:
	var e := extent
	var up := Vector3.UP
	var c00 := Vector3(-e, 0.0, -e)
	var c10 := Vector3(e, 0.0, -e)
	var c01 := Vector3(-e, 0.0, e)
	var c11 := Vector3(e, 0.0, e)
	_v(st, up, 0.0, 0.0, Vector2(c00.x, c00.z), c00)
	_v(st, up, 1.0, 0.0, Vector2(c10.x, c10.z), c10)
	_v(st, up, 1.0, 0.0, Vector2(c11.x, c11.z), c11)
	_v(st, up, 0.0, 0.0, Vector2(c00.x, c00.z), c00)
	_v(st, up, 1.0, 0.0, Vector2(c11.x, c11.z), c11)
	_v(st, up, 0.0, 0.0, Vector2(c01.x, c01.z), c01)

func _v(st: SurfaceTool, n: Vector3, uvx: float, t: float, uv2: Vector2, p: Vector3) -> void:
	st.set_normal(n)
	st.set_uv(Vector2(uvx, t))
	st.set_uv2(uv2)
	st.add_vertex(p)

# ---------------------------------------------------------------------------
# Shader parameter pushes
# ---------------------------------------------------------------------------
func _push_motion() -> void:
	if not _mat:
		return
	_mat.set_shader_parameter("u_blade_length", blade_length)
	_mat.set_shader_parameter("u_stiffness", stiffness)
	_mat.set_shader_parameter("u_sway_amount", sway_amount)
	_mat.set_shader_parameter("u_sway_speed", sway_speed)

func _apply_color_and_polish() -> void:
	if not _mat:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_base_color", base_color)
	_mat.set_shader_parameter("u_tip_color", tip_color)
	_mat.set_shader_parameter("u_brightness", brightness)
	_mat.set_shader_parameter("u_contrast", contrast)
	_mat.set_shader_parameter("u_posterize", posterize)
	_mat.set_shader_parameter("u_posterize_steps", posterize_steps)
	_mat.set_shader_parameter("u_roughness", surface_roughness)
	_mat.set_shader_parameter("u_metallic", surface_metallic)
	_mat.set_shader_parameter("u_rim_strength", rim_strength)
	_mat.set_shader_parameter("u_rim_power", rim_power)
	_mat.set_shader_parameter("u_rim_color", rim_color)

## Push influence-field data into the shader. Called every frame by the
## InfluenceController; arrays are padded to the shader's max (8).
func set_influences(count: int, positions: PackedVector3Array, radii: PackedFloat32Array,
		strengths: PackedFloat32Array, colors: PackedVector3Array,
		_speeds: PackedFloat32Array = PackedFloat32Array()) -> void:
	if not _mat:
		return
	_mat.set_shader_parameter("u_influence_count", count)
	_mat.set_shader_parameter("u_influence_pos", positions)
	_mat.set_shader_parameter("u_influence_radius", radii)
	_mat.set_shader_parameter("u_influence_strength", strengths)
	_mat.set_shader_parameter("u_influence_color", colors)

# ---------------------------------------------------------------------------
# Setters — geometry params rebuild, everything else is a cheap uniform push.
# ---------------------------------------------------------------------------
func set_density(v: int) -> void:
	density = clampi(v, 50, 20000)
	rebuild()

func set_extent(v: float) -> void:
	extent = v
	rebuild()

func set_blade_length(v: float) -> void:
	blade_length = v
	rebuild()

func set_blade_width(v: float) -> void:
	blade_width = v
	rebuild()

func set_seed(v: int) -> void:
	seed = v
	rebuild()

func set_stiffness(v: float) -> void:
	stiffness = v
	_push_motion()

func set_sway_amount(v: float) -> void:
	sway_amount = v
	_push_motion()

func set_sway_speed(v: float) -> void:
	sway_speed = v
	_push_motion()

func set_surface_roughness(v: float) -> void:
	surface_roughness = v
	_apply_color_and_polish()

func set_surface_metallic(v: float) -> void:
	surface_metallic = v
	_apply_color_and_polish()

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.disconnect(_apply_color_and_polish)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_color_and_polish):
		colormap.changed.connect(_apply_color_and_polish)
	_apply_color_and_polish()

func set_base_color(v: Color) -> void:
	base_color = v
	_apply_color_and_polish()

func set_tip_color(v: Color) -> void:
	tip_color = v
	_apply_color_and_polish()

func set_brightness(v: float) -> void:
	brightness = v
	_apply_color_and_polish()

func set_contrast(v: float) -> void:
	contrast = v
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

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Field", "props": [
			{"name": "density", "type": "int", "min": 50, "max": 20000, "step": 50,
				"hint": "Number of blades (vertex cost scales linearly)"},
			{"name": "extent", "type": "float", "min": 1.0, "max": 40.0, "step": 0.5},
			{"name": "blade_length", "type": "float", "min": 0.1, "max": 8.0, "step": 0.05},
			{"name": "blade_width", "type": "float", "min": 0.01, "max": 0.5, "step": 0.005},
			{"name": "seed", "type": "int", "min": 0, "max": 9999, "step": 1},
		]},
		{"title": "Motion", "props": [
			{"name": "stiffness", "type": "float", "min": 0.05, "max": 8.0, "step": 0.05,
				"hint": "Higher resists bending from wind and influences"},
			{"name": "sway_amount", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "sway_speed", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
		]},
		{"title": "Rendering", "props": [
			{"name": "surface_roughness", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "surface_metallic", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "base_color", "type": "color", "hint": "Blade root (fallback gradient bottom)"},
			{"name": "tip_color", "type": "color", "hint": "Blade tip (fallback gradient top)"},
			{"name": "brightness", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
			{"name": "contrast", "type": "float", "min": 0.0, "max": 2.0, "step": 0.05},
			{"name": "posterize", "type": "bool"},
			{"name": "posterize_steps", "type": "float", "min": 1.0, "max": 32.0, "step": 1.0},
		]},
		{"title": "Material Polish", "props": [
			{"name": "rim_strength", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "rim_power", "type": "float", "min": 0.5, "max": 8.0, "step": 0.1},
			{"name": "rim_color", "type": "color"},
		]},
	]
