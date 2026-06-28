extends RefCounted
## Schema-driven wrapper around the scene's Environment resource (Prompt 8.x).
##
## Exposes the background + bloom as get_param_schema() properties so they are
## editable in the ParameterPanel and serialized by CompositionIO under "scene",
## exactly like the camera. Setters push straight to the bound Environment.
##
## Three background modes (BackgroundMode):
##   COLOR  — flat color (the classic white room).
##   NOISE  — animated fractal-noise sky blending bg_color ↔ bg_color2
##            (background_noise.gdshader, driven by the sky's own TIME).
##   SKYBOX — a panorama image loaded from skybox_path (equirectangular).
class_name SceneEnvironment

enum BackgroundMode { COLOR, NOISE, SKYBOX }

const NOISE_SKY_SHADER := preload("res://shaders/background_noise.gdshader")

var env: Environment

## Background style. COLOR keeps the old flat-color room; NOISE and SKYBOX swap in
## an Environment sky (see _apply).
var background_mode: BackgroundMode = BackgroundMode.COLOR: set = set_background_mode
## Background (and ambient) color. A dark value is what makes neon particles pop.
## In NOISE mode this is the first of the two blended colors.
var bg_color: Color = Color(1, 1, 1, 1): set = set_bg_color
## Second color blended by the noise field in NOISE mode.
var bg_color2: Color = Color(0.62, 0.66, 0.98): set = set_bg_color2
## Spatial frequency of the noise background.
var noise_scale: float = 2.5: set = set_noise_scale
## Animation rate of the noise background (0 = frozen).
var noise_speed: float = 0.08: set = set_noise_speed
## Pushes the noise blend toward one color or the other (higher = harder edges).
var noise_contrast: float = 1.2: set = set_noise_contrast
## Path to a panorama image for SKYBOX mode. res:// or user:// load through the
## resource loader; any other path is read as an OS file at runtime.
var skybox_path: String = "": set = set_skybox_path
## Master bloom toggle — glow on bright (HDR) pixels.
var bloom_enabled: bool = false: set = set_bloom_enabled
## Glow intensity; particle_brightness drives pixels above the HDR threshold.
var bloom_intensity: float = 0.8: set = set_bloom_intensity

# Lazily created sky resources, reused across mode switches.
var _sky: Sky
var _noise_mat: ShaderMaterial
var _pano_mat: PanoramaSkyMaterial
var _skybox_loaded_path: String = ""  # cache so _apply() doesn't reload from disk

## Adopt an existing Environment, syncing our props FROM it so the authored
## scene defaults (white background, glow off) are preserved on startup.
func bind(e: Environment) -> void:
	env = e
	if env:
		bg_color = env.background_color
		bloom_enabled = env.glow_enabled
		bloom_intensity = env.glow_intensity
	_apply()

## Restore the authored scene look (white room, no bloom, no sky). Called when
## loading a composition that carries no "scene" block so old comps don't inherit
## a sky/bloom from the previous scene.
func reset_defaults() -> void:
	bloom_enabled = false
	bloom_intensity = 0.8
	background_mode = BackgroundMode.COLOR
	bg_color2 = Color(0.62, 0.66, 0.98)
	noise_scale = 2.5
	noise_speed = 0.08
	noise_contrast = 1.2
	skybox_path = ""
	bg_color = Color(1, 1, 1, 1)

func set_background_mode(v: BackgroundMode) -> void:
	background_mode = v
	_apply()

func set_bg_color(v: Color) -> void:
	bg_color = v
	_apply()

func set_bg_color2(v: Color) -> void:
	bg_color2 = v
	_apply()

func set_noise_scale(v: float) -> void:
	noise_scale = v
	_apply()

func set_noise_speed(v: float) -> void:
	noise_speed = v
	_apply()

func set_noise_contrast(v: float) -> void:
	noise_contrast = v
	_apply()

func set_skybox_path(v: String) -> void:
	skybox_path = v
	_apply()

func set_bloom_enabled(v: bool) -> void:
	bloom_enabled = v
	_apply()

func set_bloom_intensity(v: float) -> void:
	bloom_intensity = v
	_apply()

func _ensure_sky() -> void:
	if _sky == null:
		_sky = Sky.new()
	if env.sky != _sky:
		env.sky = _sky

func _apply() -> void:
	if env == null:
		return
	# Resolve the background mode. SKYBOX silently falls back to COLOR when no
	# valid image is loaded, so an empty path never leaves a black void.
	var mode := background_mode
	if mode == BackgroundMode.SKYBOX and not _load_skybox():
		mode = BackgroundMode.COLOR

	match mode:
		BackgroundMode.NOISE:
			if _noise_mat == null:
				_noise_mat = ShaderMaterial.new()
				_noise_mat.shader = NOISE_SKY_SHADER
			_noise_mat.set_shader_parameter("color_a", bg_color)
			_noise_mat.set_shader_parameter("color_b", bg_color2)
			_noise_mat.set_shader_parameter("noise_scale", noise_scale)
			_noise_mat.set_shader_parameter("noise_speed", noise_speed)
			_noise_mat.set_shader_parameter("contrast", noise_contrast)
			_ensure_sky()
			# Realtime so the TIME-driven shader re-renders every frame and animates.
			_sky.process_mode = Sky.PROCESS_MODE_REALTIME
			_sky.sky_material = _noise_mat
			env.background_mode = Environment.BG_SKY
		BackgroundMode.SKYBOX:
			_ensure_sky()
			# Static image — render at higher quality instead of per-frame.
			_sky.process_mode = Sky.PROCESS_MODE_QUALITY
			_sky.sky_material = _pano_mat
			env.background_mode = Environment.BG_SKY
		_:
			env.background_mode = Environment.BG_COLOR

	# Background color still drives ambient (a dark room reads as dark, leaving the
	# directional lights and unlit particles to carry the image). Kept in every
	# mode so object lighting stays predictable regardless of the backdrop.
	env.background_color = bg_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
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

## Load the panorama for SKYBOX mode into _pano_mat. Returns false (→ fall back to
## color) when the path is empty or the image can't be loaded. Mirrors HudLogo's
## external-image handling: res://, user:// go through the loader, OS paths are read
## as raw images.
func _load_skybox() -> bool:
	if skybox_path.is_empty():
		return false
	# Already loaded this exact path — skip the disk read on repeated _apply() calls.
	if _pano_mat != null and _pano_mat.panorama != null and _skybox_loaded_path == skybox_path:
		return true
	var tex: Texture2D = null
	if skybox_path.begins_with("res://") or skybox_path.begins_with("user://"):
		var res := load(skybox_path)
		tex = res if res is Texture2D else null
	else:
		var img := Image.load_from_file(skybox_path)
		if img != null:
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		return false
	if _pano_mat == null:
		_pano_mat = PanoramaSkyMaterial.new()
	_pano_mat.panorama = tex
	_skybox_loaded_path = skybox_path
	return true

func get_param_schema() -> Array:
	return [{
		"title": "Scene",
		"props": [
			{"name": "background_mode", "type": "enum", "options": ["Color", "Noise", "Skybox"]},
			{"name": "bg_color", "type": "color"},
			{"name": "bg_color2", "type": "color", "hint": "Second noise color (Noise mode)"},
			{"name": "noise_scale", "type": "float", "min": 0.2, "max": 12.0, "step": 0.1},
			{"name": "noise_speed", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "noise_contrast", "type": "float", "min": 0.2, "max": 4.0, "step": 0.05},
			{"name": "skybox_path", "type": "string", "hint": "Panorama image path (Skybox mode)"},
			{"name": "bloom_enabled", "type": "bool"},
			{"name": "bloom_intensity", "type": "float", "min": 0.0, "max": 8.0, "step": 0.05},
		]
	}]
