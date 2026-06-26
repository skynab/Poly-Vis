extends RefCounted
## Schema-driven wrapper around the scene's Environment resource (Prompt 8.x).
##
## Exposes background color + bloom as get_param_schema() properties so they are
## editable in the ParameterPanel and serialized by CompositionIO under "scene",
## exactly like the camera. Setters push straight to the bound Environment.
class_name SceneEnvironment

var env: Environment

## Background (and ambient) color. A dark value is what makes neon particles pop.
var bg_color: Color = Color(1, 1, 1, 1): set = set_bg_color
## Master bloom toggle — glow on bright (HDR) pixels.
var bloom_enabled: bool = false: set = set_bloom_enabled
## Glow intensity; particle_brightness drives pixels above the HDR threshold.
var bloom_intensity: float = 0.8: set = set_bloom_intensity

## Adopt an existing Environment, syncing our props FROM it so the authored
## scene defaults (white background, glow off) are preserved on startup.
func bind(e: Environment) -> void:
	env = e
	if env:
		bg_color = env.background_color
		bloom_enabled = env.glow_enabled
		bloom_intensity = env.glow_intensity
	_apply()

## Restore the authored scene look (white room, no bloom). Called when loading
## a composition that carries no "scene" block so old comps don't inherit bloom.
func reset_defaults() -> void:
	bloom_enabled = false
	bloom_intensity = 0.8
	bg_color = Color(1, 1, 1, 1)

func set_bg_color(v: Color) -> void:
	bg_color = v
	_apply()

func set_bloom_enabled(v: bool) -> void:
	bloom_enabled = v
	_apply()

func set_bloom_intensity(v: float) -> void:
	bloom_intensity = v
	_apply()

func _apply() -> void:
	if env == null:
		return
	# Background color drives ambient too — a black room should read as dark,
	# leaving only the directional lights (and unlit particles) visible.
	env.background_color = bg_color
	env.ambient_light_color = bg_color
	env.glow_enabled = bloom_enabled
	env.glow_intensity = bloom_intensity
	# Tuned for neon: additive spread that picks up bright particle pixels.
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_bloom = 0.25
	env.glow_hdr_threshold = 0.7
	env.set_glow_level(1, 1.0)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.6)
	env.set_glow_level(4, 0.4)

func get_param_schema() -> Array:
	return [{
		"title": "Scene",
		"props": [
			{"name": "bg_color", "type": "color"},
			{"name": "bloom_enabled", "type": "bool"},
			{"name": "bloom_intensity", "type": "float", "min": 0.0, "max": 8.0, "step": 0.05},
		]
	}]
