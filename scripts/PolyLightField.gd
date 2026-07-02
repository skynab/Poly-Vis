@tool
extends MultiMeshInstance3D
## Reactive LED pixel field (PolyLightField).
##
## A flat grid of emissive quads rendered as a single MultiMesh — the on-screen
## analogue of the physical LED wall. Each cell lights up by proximity to the
## influence field: the cell's world position and the shared u_influence_* arrays
## are read in poly_lightfield.gdshader (per cell, in the vertex stage), so there's
## no per-frame CPU work — set_influences() just pushes the uniforms. Per-instance
## custom data carries a random shimmer phase so the idle (uninfluenced) wall still
## breathes out of sync. Kept deliberately cheap for the LED wall: one MultiMesh,
## one draw, all response on the GPU.
class_name PolyLightField

const LIGHTFIELD_SHADER := preload("res://shaders/poly_lightfield.gdshader")
const MAX_INFLUENCES := 8

@export_group("Grid")
## Number of cells across (X).
@export_range(1, 200) var grid_width: int = 48: set = set_grid_width
## Number of cells down (Y).
@export_range(1, 200) var grid_height: int = 27: set = set_grid_height
## World spacing between cell centres. The lit quad fills `cell_fill` of this, so
## a gap remains between pixels (the LED-panel look).
@export_range(0.02, 2.0) var cell_size: float = 0.22: set = set_cell_size
## Fraction of a cell the lit quad covers (1 = touching, <1 = visible gaps).
@export_range(0.1, 1.0) var cell_fill: float = 0.85: set = set_cell_fill

@export_group("Response")
## How sharply a cell dims with distance from an influence — higher = tighter pools.
@export_range(0.1, 8.0) var falloff: float = 2.0: set = set_falloff
## Brightness of fully-lit cells (drives HDR bloom above the glow threshold).
@export_range(0.0, 8.0) var cell_gain: float = 2.5: set = set_cell_gain
## Baseline glow of unlit cells so the wall is never fully black.
@export_range(0.0, 2.0) var idle_brightness: float = 0.05: set = set_idle_brightness
## Depth of the idle flicker (0 = steady, 1 = pixels blink fully off and on).
@export_range(0.0, 1.0) var shimmer_amount: float = 0.5: set = set_shimmer_amount
## Idle flicker rate.
@export_range(0.0, 10.0) var shimmer_speed: float = 2.0: set = set_shimmer_speed
## How strongly lit cells adopt their influence's color (vs the colormap hue).
@export_range(0.0, 1.0) var tint_strength: float = 0.6: set = set_tint_strength

@export_group("Color")
## Colormap sampled by cell intensity (dark → cool end, bright → hot end).
@export var colormap: GradientColormap: set = set_colormap
## Fallback color when no colormap is assigned.
@export var base_color: Color = Color(0.1, 0.7, 1.0): set = set_base_color

var _mat: ShaderMaterial

func _ready() -> void:
	_ensure_material()
	rebuild()
	set_process(true)

func _process(_delta: float) -> void:
	if _mat:
		_mat.set_shader_parameter("u_time", float(Time.get_ticks_msec()) / 1000.0)

# ---------------------------------------------------------------------------
func _ensure_material() -> void:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = LIGHTFIELD_SHADER
		material_override = _mat
	if colormap == null:
		set_colormap(GradientColormap.create(GradientColormap.Preset.MAGMA))

## (Re)build the MultiMesh: one quad per cell, laid out centred on the origin in
## the XY plane, with a per-cell random shimmer phase in custom-data.x.
func rebuild() -> void:
	if not is_inside_tree():
		return
	_ensure_material()
	var cols := maxi(grid_width, 1)
	var rows := maxi(grid_height, 1)

	var quad := QuadMesh.new()
	var qs := cell_size * cell_fill
	quad.size = Vector2(qs, qs)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = cols * rows

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var x0 := -(cols - 1) * 0.5 * cell_size
	var y0 := -(rows - 1) * 0.5 * cell_size
	var basis := Basis()
	var idx := 0
	for row in rows:
		for col in cols:
			var pos := Vector3(x0 + col * cell_size, y0 + row * cell_size, 0.0)
			mm.set_instance_transform(idx, Transform3D(basis, pos))
			# custom: x = shimmer phase, yz = normalized grid coords, w = spare seed.
			mm.set_instance_custom_data(idx, Color(rng.randf(),
					float(col) / float(maxi(cols - 1, 1)),
					float(row) / float(maxi(rows - 1, 1)), rng.randf()))
			idx += 1
	multimesh = mm
	_apply_response()
	_apply_color()

func _apply_response() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("u_falloff", falloff)
	_mat.set_shader_parameter("u_cell_gain", cell_gain)
	_mat.set_shader_parameter("u_idle_brightness", idle_brightness)
	_mat.set_shader_parameter("u_shimmer_amount", shimmer_amount)
	_mat.set_shader_parameter("u_shimmer_speed", shimmer_speed)
	_mat.set_shader_parameter("u_tint_strength", tint_strength)

func _apply_color() -> void:
	if _mat == null:
		return
	var tex: Texture2D = colormap.get_texture() if colormap else null
	_mat.set_shader_parameter("u_use_colormap", tex != null)
	if tex:
		_mat.set_shader_parameter("u_colormap", tex)
	_mat.set_shader_parameter("u_base_color", base_color)

## Push influence-field data into the shader — the same fixed-size (MAX_INFLUENCES)
## arrays as the mesh/cloth shaders. Cells light up near these positions.
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

# --- setters ----------------------------------------------------------------
func set_grid_width(v: int) -> void:
	grid_width = clampi(v, 1, 200)
	rebuild()

func set_grid_height(v: int) -> void:
	grid_height = clampi(v, 1, 200)
	rebuild()

func set_cell_size(v: float) -> void:
	cell_size = v
	rebuild()

func set_cell_fill(v: float) -> void:
	cell_fill = v
	rebuild()

func set_falloff(v: float) -> void:
	falloff = v
	_apply_response()

func set_cell_gain(v: float) -> void:
	cell_gain = v
	_apply_response()

func set_idle_brightness(v: float) -> void:
	idle_brightness = v
	_apply_response()

func set_shimmer_amount(v: float) -> void:
	shimmer_amount = v
	_apply_response()

func set_shimmer_speed(v: float) -> void:
	shimmer_speed = v
	_apply_response()

func set_tint_strength(v: float) -> void:
	tint_strength = v
	_apply_response()

func set_colormap(v: GradientColormap) -> void:
	if colormap and colormap.changed.is_connected(_apply_color):
		colormap.changed.disconnect(_apply_color)
	colormap = v
	if colormap and not colormap.changed.is_connected(_apply_color):
		colormap.changed.connect(_apply_color)
	if is_inside_tree():
		_apply_color()

func set_base_color(v: Color) -> void:
	base_color = v
	_apply_color()

## Schema consumed by the ParameterPanel.
func get_param_schema() -> Array:
	return [
		{"title": "Grid", "props": [
			{"name": "grid_width", "type": "int", "min": 1, "max": 200, "step": 1},
			{"name": "grid_height", "type": "int", "min": 1, "max": 200, "step": 1},
			{"name": "cell_size", "type": "float", "min": 0.02, "max": 2.0, "step": 0.01,
				"hint": "World spacing between cell centres"},
			{"name": "cell_fill", "type": "float", "min": 0.1, "max": 1.0, "step": 0.01,
				"hint": "Quad size as a fraction of the cell (lower = wider gaps)"},
		]},
		{"title": "Response", "props": [
			{"name": "falloff", "type": "float", "min": 0.1, "max": 8.0, "step": 0.05,
				"hint": "Higher confines the glow to cells right by an influence"},
			{"name": "cell_gain", "type": "float", "min": 0.0, "max": 8.0, "step": 0.05,
				"hint": "Brightness of lit cells (push past 1 for bloom)"},
			{"name": "idle_brightness", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "shimmer_amount", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			{"name": "shimmer_speed", "type": "float", "min": 0.0, "max": 10.0, "step": 0.1},
			{"name": "tint_strength", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
		]},
		{"title": "Color", "props": [
			{"name": "colormap", "type": "colormap_preset"},
			{"name": "base_color", "type": "color"},
		]},
	]
