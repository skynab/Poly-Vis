extends RefCounted
## Schema-driven wrapper around the scene's Environment resource (Prompt 8.x).
##
## Exposes the background + bloom as get_param_schema() properties so they are
## editable in the ParameterPanel and serialized by CompositionIO under "scene",
## exactly like the camera. Setters push straight to the bound Environment.
##
## Background modes (BackgroundMode):
##   COLOR  — flat color (the classic white room).
##   NOISE  — animated fractal-noise sky blending bg_color ↔ bg_color2
##            (background_noise.gdshader, driven by the sky's own TIME).
##   SKYBOX — a panorama image loaded from skybox_path (equirectangular).
##   AURORA — animated aurora-borealis curtains over bg_color, tinted bg_color2
##            (aurora_sky.gdshader). Reuses the noise_* props as its
##            scale / speed / intensity controls.
class_name SceneEnvironment

enum BackgroundMode { COLOR, NOISE, SKYBOX, AURORA }

const NOISE_SKY_SHADER := preload("res://shaders/background_noise.gdshader")
const AURORA_SKY_SHADER := preload("res://shaders/aurora_sky.gdshader")

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
## Master volumetric-fog toggle — a light-scattering haze filling the scene
## (Forward+ only). Reads best on the dark LED-wall backdrops. Off by default.
var fog_enabled: bool = false: set = set_fog_enabled
## Fog density — how thick the haze is (higher = murkier). Effect scales with length.
var fog_density: float = 0.03: set = set_fog_density
## Base fog color (how it tints light passing through it).
var fog_albedo: Color = Color(1, 1, 1): set = set_fog_albedo
## Self-lit fog color — glows on its own without a light, so the haze reads on an
## otherwise black backdrop. Black (default) = no emission.
var fog_emission: Color = Color(0, 0, 0): set = set_fog_emission
## How far the fog volume extends from the camera (world units).
var fog_length: float = 64.0: set = set_fog_length
## How much scene GI bleeds into the fog (0 = none).
var fog_gi_inject: float = 0.0: set = set_fog_gi_inject
## When true the current background is kept across preset/composition loads — the
## preset's stored "scene" block is ignored — so switching presets isn't a jarring
## backdrop change. A live session preference (not serialized, not reset by
## reset_defaults); CompositionIO.apply reads it to gate the scene restore.
var lock_background: bool = false
## Seconds over which a preset/composition load glides the camera + background +
## surviving object params from their old values to the new ones (see
## Main.apply_composition). 0 = instant snap (the original behavior). Like
## lock_background it's a live session preference — not serialized, not reset by
## reset_defaults — so it persists across preset switches within a session.
var transition_duration: float = 0.8

# Lazily created sky resources, reused across mode switches.
var _sky: Sky
var _noise_mat: ShaderMaterial
var _aurora_mat: ShaderMaterial
var _pano_mat: PanoramaSkyMaterial
var _skybox_loaded_path: String = ""  # cache so _apply() doesn't reload from disk
var _host: Node          # scene-tree node that hosts the skybox FileDialog
var _file_dlg: FileDialog

## Adopt an existing Environment, syncing our props FROM it so the authored
## scene defaults (white background, glow off) are preserved on startup. `host` is
## a scene-tree node used to parent the skybox file-browser dialog (we are
## RefCounted and can't add it to the tree ourselves).
func bind(e: Environment, host: Node = null) -> void:
	env = e
	_host = host
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
	fog_enabled = false
	fog_density = 0.03
	fog_albedo = Color(1, 1, 1)
	fog_emission = Color(0, 0, 0)
	fog_length = 64.0
	fog_gi_inject = 0.0
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

func set_fog_enabled(v: bool) -> void:
	fog_enabled = v
	_apply()

func set_fog_density(v: float) -> void:
	fog_density = v
	_apply()

func set_fog_albedo(v: Color) -> void:
	fog_albedo = v
	_apply()

func set_fog_emission(v: Color) -> void:
	fog_emission = v
	_apply()

func set_fog_length(v: float) -> void:
	fog_length = v
	_apply()

func set_fog_gi_inject(v: float) -> void:
	fog_gi_inject = v
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
		BackgroundMode.AURORA:
			if _aurora_mat == null:
				_aurora_mat = ShaderMaterial.new()
				_aurora_mat.shader = AURORA_SKY_SHADER
			# Reuse the noise_* props as the aurora's scale / speed / intensity.
			_aurora_mat.set_shader_parameter("u_sky_color", bg_color)
			_aurora_mat.set_shader_parameter("u_color", bg_color2)
			_aurora_mat.set_shader_parameter("u_scale", noise_scale)
			_aurora_mat.set_shader_parameter("u_speed", noise_speed)
			_aurora_mat.set_shader_parameter("u_intensity", noise_contrast)
			_ensure_sky()
			# Realtime so the TIME-driven shader re-renders every frame and animates.
			_sky.process_mode = Sky.PROCESS_MODE_REALTIME
			_sky.sky_material = _aurora_mat
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

	# Volumetric fog — composites underneath glow (fog scatters the scene, then
	# glow blooms the bright/emissive pixels the fog leaves behind), so it stacks
	# cleanly with the neon bloom above. Forward+ only; a no-op on other renderers.
	env.volumetric_fog_enabled = fog_enabled
	env.volumetric_fog_density = fog_density
	env.volumetric_fog_albedo = fog_albedo
	env.volumetric_fog_emission = fog_emission
	env.volumetric_fog_length = fog_length
	env.volumetric_fog_gi_inject = fog_gi_inject

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

## Action button: open a file browser to pick a panorama image, then switch the
## background to SKYBOX. Needs a host node (set in bind) to parent the dialog.
func import_skybox() -> void:
	if _host == null or not _host.is_inside_tree():
		return
	if not is_instance_valid(_file_dlg):
		_file_dlg = FileDialog.new()
		_file_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dlg.access = FileDialog.ACCESS_FILESYSTEM
		_file_dlg.filters = PackedStringArray([
			"*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga, *.hdr, *.exr ; Panorama Images"])
		_file_dlg.title = "Load Skybox Panorama"
		_file_dlg.size = Vector2i(640, 460)
		_file_dlg.file_selected.connect(_on_skybox_picked)
		_host.add_child(_file_dlg)
	_file_dlg.popup_centered()

func _on_skybox_picked(path: String) -> void:
	# Setters each run _apply(); the mode switch is what triggers the load.
	skybox_path = path
	background_mode = BackgroundMode.SKYBOX

func get_param_schema() -> Array:
	return [{
		"title": "Scene",
		"props": [
			{"name": "lock_background", "type": "bool", "serialize": false,
				"hint": "Keep this background when switching presets (ignore the preset's stored background)"},
			{"name": "transition_duration", "type": "float", "min": 0.0, "max": 3.0, "step": 0.05,
				"serialize": false,
				"hint": "Seconds to glide the camera/background/params on preset & composition loads (0 = instant)"},
			{"name": "background_mode", "type": "enum", "options": ["Color", "Noise", "Skybox", "Aurora"]},
			{"name": "bg_color", "type": "color"},
			{"name": "bg_color2", "type": "color", "hint": "Second noise color (Noise mode)"},
			{"name": "noise_scale", "type": "float", "min": 0.2, "max": 12.0, "step": 0.1},
			{"name": "noise_speed", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
			{"name": "noise_contrast", "type": "float", "min": 0.2, "max": 4.0, "step": 0.05},
			{"name": "skybox_path", "type": "string", "hint": "Panorama image path (Skybox mode)"},
			{"name": "import_skybox", "type": "action", "label": "Load Skybox…",
				"hint": "Browse for a panorama image and switch to Skybox mode"},
			{"name": "bloom_enabled", "type": "bool"},
			{"name": "bloom_intensity", "type": "float", "min": 0.0, "max": 8.0, "step": 0.05},
		]
	}, {
		"title": "Fog",
		"props": [
			{"name": "fog_enabled", "type": "bool",
				"hint": "Volumetric fog (Forward+ only); reads best on dark scenes"},
			{"name": "fog_density", "type": "float", "min": 0.0, "max": 1.0, "step": 0.005},
			{"name": "fog_albedo", "type": "color", "hint": "Base fog color"},
			{"name": "fog_emission", "type": "color",
				"hint": "Self-lit fog color — glows on a dark backdrop (black = off)"},
			{"name": "fog_length", "type": "float", "min": 1.0, "max": 1024.0, "step": 1.0,
				"hint": "How far the fog extends from the camera (world units)"},
			{"name": "fog_gi_inject", "type": "float", "min": 0.0, "max": 16.0, "step": 0.1,
				"hint": "How much scene GI bleeds into the fog"},
		]
	}]
