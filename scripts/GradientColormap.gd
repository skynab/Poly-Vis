@tool
extends Resource
## Shared colormap resource (Prompt 3.1).
##
## Wraps a Godot Gradient and bakes it to a 1-row lookup texture that mesh and
## particle shaders sample. Ships presets matching the reference images. Assign
## one in the inspector, or call GradientColormap.create(preset) from code.
class_name GradientColormap

enum Preset { CUSTOM, VIRIDIS, PINK_RED_WHITE, PURPLE_YELLOW, GREEN_TEAL }

@export var preset: Preset = Preset.VIRIDIS: set = set_preset
@export var gradient: Gradient: set = set_gradient
@export_range(8, 1024) var resolution: int = 256: set = set_resolution

var _tex: GradientTexture1D

static func create(p: Preset) -> GradientColormap:
	var c := GradientColormap.new()
	c.preset = p
	c.gradient = _build_gradient(p)
	return c

func _init() -> void:
	if gradient == null:
		gradient = _build_gradient(preset if preset != Preset.CUSTOM else Preset.VIRIDIS)

func get_texture() -> Texture2D:
	if gradient == null:
		return null
	if _tex == null:
		_tex = GradientTexture1D.new()
		_tex.width = resolution
		_tex.gradient = gradient
	return _tex

func set_preset(p: Preset) -> void:
	preset = p
	if p != Preset.CUSTOM:
		set_gradient(_build_gradient(p))

func set_gradient(g: Gradient) -> void:
	gradient = g
	if _tex:
		_tex.gradient = g
	emit_changed()

func set_resolution(r: int) -> void:
	resolution = r
	if _tex:
		_tex.width = r
	emit_changed()

static func _build_gradient(p: Preset) -> Gradient:
	var g := Gradient.new()
	var offsets: PackedFloat32Array
	var colors: PackedColorArray
	match p:
		Preset.PINK_RED_WHITE:
			offsets = PackedFloat32Array([0.0, 0.5, 1.0])
			colors = PackedColorArray([
				Color(1.0, 0.30, 0.53), Color(0.82, 0.07, 0.29), Color(1.0, 1.0, 1.0)])
		Preset.PURPLE_YELLOW:
			offsets = PackedFloat32Array([0.0, 0.4, 0.8, 1.0])
			colors = PackedColorArray([
				Color(0.29, 0.0, 0.51), Color(0.48, 0.24, 1.0),
				Color(0.70, 0.55, 1.0), Color(1.0, 0.89, 0.24)])
		Preset.GREEN_TEAL:
			offsets = PackedFloat32Array([0.0, 0.5, 1.0])
			colors = PackedColorArray([
				Color(0.04, 0.43, 0.31), Color(0.12, 0.82, 0.64), Color(0.95, 1.0, 0.40)])
		_:  # VIRIDIS (also the CUSTOM fallback)
			offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
			colors = PackedColorArray([
				Color(0.267, 0.005, 0.329), Color(0.231, 0.322, 0.545),
				Color(0.129, 0.567, 0.551), Color(0.369, 0.789, 0.383),
				Color(0.993, 0.906, 0.144)])
	g.offsets = offsets
	g.colors = colors
	return g
