extends RefCounted
## Performance / render-scale global module.
##
## Drives the root viewport's 3D resolution scale (scaling_3d_scale) and upscale
## filter (scaling_3d_mode) so the 3D scene can render at a fraction of the window
## resolution while the 2D UI stays crisp (Godot renders 2D at full resolution
## regardless of scaling_3d_scale). This replaces the old ad-hoc "half resolution"
## hack with a proper 0.25–1.0 control plus an optional FSR upscaler.
##
## An auto mode samples FPS once per second (mirroring PolyParticles.auto_budget)
## and nudges render_scale to hold a target framerate.
##
## Unlike the other schema modules this is a *machine* preference, not part of a
## composition: it persists to user://settings.cfg and is deliberately NOT wired
## into CompositionIO, so loading a preset authored on a fast box never forces a
## render scale onto a slower one (e.g. the Mac that motivated this).
##
## Editable in the ParameterPanel under "Performance"; ticked from Main._process
## via update(delta).
class_name RenderScale

## Bilinear works everywhere; FSR 1.0 (a sharper spatial upscaler) needs the
## Forward+ or Mobile renderer — see _fsr_supported().
enum UpscaleMode { BILINEAR, FSR }

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "performance"
const MIN_SCALE := 0.25
const MAX_SCALE := 1.0

## 3D render resolution as a fraction of the window (1.0 = native). UI is unaffected.
var render_scale: float = 1.0: set = set_render_scale
var upscale_mode: UpscaleMode = UpscaleMode.BILINEAR: set = set_upscale_mode
## Auto mode: lower render_scale to hold target_fps (raises it again with headroom).
var auto_scale: bool = false: set = set_auto_scale
var target_fps: int = 60: set = set_target_fps

# FPS sampling state — same cadence/shape as PolyParticles._budget_tick.
var _cooldown: float = 0.0
var _fps_samples: Array[float] = []
# Guard so applying loaded settings doesn't immediately re-save them.
var _loading: bool = false

func _init() -> void:
	load_settings()

# --- viewport application ---------------------------------------------------
func _root_viewport() -> Viewport:
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).root
	return null

## FSR upscaling is only available on the Forward+ and Mobile renderers; the GL
## Compatibility backend (and web exports using it) has no FSR path.
func _fsr_supported() -> bool:
	var method := RenderingServer.get_current_rendering_method()
	return method == "forward_plus" or method == "mobile"

## Push render_scale + the effective upscale mode to the root viewport.
func apply() -> void:
	var vp := _root_viewport()
	if vp == null:
		return
	vp.scaling_3d_scale = clampf(render_scale, MIN_SCALE, MAX_SCALE)
	# FSR only helps when actually upscaling (scale < 1) and only where supported;
	# otherwise fall back to bilinear so the setting is always valid.
	if upscale_mode == UpscaleMode.FSR and _fsr_supported() and render_scale < 1.0:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR

# --- auto mode (mirrors PolyParticles.auto_budget FPS sampling) -------------
## Called each frame from Main._process. Samples FPS once per second over a small
## rolling window, then nudges render_scale toward holding target_fps.
func update(delta: float) -> void:
	if not auto_scale:
		return
	_cooldown -= delta
	if _cooldown > 0.0:
		return
	_cooldown = 1.0  # re-evaluate once per second, like auto_budget
	_fps_samples.append(float(Engine.get_frames_per_second()))
	if _fps_samples.size() > 5:
		_fps_samples.pop_front()
	var avg := 0.0
	for s in _fps_samples:
		avg += s
	avg /= float(_fps_samples.size())
	_apply_auto(avg)

## Hill-climb render_scale to hold target_fps. Asymmetric hysteresis (drop when
## below 0.92×, raise only above 1.12×) keeps it from oscillating between two
## levels. Kept as a pure-ish helper so it can be exercised deterministically.
func _apply_auto(avg_fps: float) -> void:
	var lower := float(target_fps) * 0.92
	var upper := float(target_fps) * 1.12
	var next := render_scale
	if avg_fps < lower:
		next = maxf(MIN_SCALE, render_scale - 0.05)
	elif avg_fps > upper and render_scale < MAX_SCALE:
		next = minf(MAX_SCALE, render_scale + 0.05)
	if not is_equal_approx(next, render_scale):
		render_scale = next  # setter applies + persists

# --- persistence (user://settings.cfg) --------------------------------------
func _save() -> void:
	if _loading:
		return
	var cfg := ConfigFile.new()
	# Preserve any other sections already in the file.
	cfg.load(SETTINGS_PATH)
	cfg.set_value(SETTINGS_SECTION, "render_scale", render_scale)
	cfg.set_value(SETTINGS_SECTION, "upscale_mode", int(upscale_mode))
	cfg.set_value(SETTINGS_SECTION, "auto_scale", auto_scale)
	cfg.set_value(SETTINGS_SECTION, "target_fps", target_fps)
	cfg.save(SETTINGS_PATH)

## Load persisted settings (if any) and apply them to the viewport. Safe when the
## file is absent — values keep their defaults.
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_loading = true
	render_scale = clampf(float(cfg.get_value(SETTINGS_SECTION, "render_scale", render_scale)), MIN_SCALE, MAX_SCALE)
	upscale_mode = int(cfg.get_value(SETTINGS_SECTION, "upscale_mode", int(upscale_mode))) as UpscaleMode
	auto_scale = bool(cfg.get_value(SETTINGS_SECTION, "auto_scale", auto_scale))
	target_fps = int(cfg.get_value(SETTINGS_SECTION, "target_fps", target_fps))
	_loading = false
	apply()

# --- setters ----------------------------------------------------------------
func set_render_scale(v: float) -> void:
	render_scale = clampf(v, MIN_SCALE, MAX_SCALE)
	apply()
	_save()

func set_upscale_mode(v: UpscaleMode) -> void:
	upscale_mode = v
	apply()
	_save()

func set_auto_scale(v: bool) -> void:
	auto_scale = v
	_fps_samples.clear()
	_cooldown = 0.0
	_save()

func set_target_fps(v: int) -> void:
	target_fps = clampi(v, 15, 240)
	_save()

# --- status readout ---------------------------------------------------------
## Live line for the panel: effective 3D render size + upscaler availability.
func scale_status() -> String:
	var vp := _root_viewport()
	var mode_txt := "FSR 1.0" if (upscale_mode == UpscaleMode.FSR and _fsr_supported() and render_scale < 1.0) else "Bilinear"
	if upscale_mode == UpscaleMode.FSR and not _fsr_supported():
		mode_txt = "Bilinear (FSR unsupported: %s)" % RenderingServer.get_current_rendering_method()
	if vp == null:
		return "%d%% · %s" % [roundi(render_scale * 100.0), mode_txt]
	var win := vp.get_visible_rect().size
	var rw := int(win.x * render_scale)
	var rh := int(win.y * render_scale)
	return "%d%% → %d×%d 3D · %s" % [roundi(render_scale * 100.0), rw, rh, mode_txt]

func get_param_schema() -> Array:
	return [{
		"title": "Performance",
		"props": [
			{"name": "render_scale", "type": "float", "min": MIN_SCALE, "max": MAX_SCALE, "step": 0.05,
				"hint": "3D render resolution as a fraction of the window. UI stays full-res; lower = faster when GPU-bound (e.g. driving a large LED wall)."},
			{"name": "upscale_mode", "type": "enum", "options": ["Bilinear", "FSR 1.0"],
				"hint": "Upscaler for the reduced 3D buffer. FSR 1.0 is sharper but needs the Forward+/Mobile renderer — it falls back to Bilinear on GL Compatibility / web."},
			{"name": "auto_scale", "type": "bool",
				"hint": "Automatically lower render scale to hold the target FPS (raises it back when there's headroom)."},
			{"name": "target_fps", "type": "int", "min": 15, "max": 240, "step": 5,
				"hint": "FPS the auto mode tries to hold."},
			{"name": "scale_status", "type": "status", "label": "Effective",
				"interval": 0.5, "hint": "Live 3D render resolution + active upscaler"},
		]
	}]

## Provided for parity with the other modules; not wired into CompositionIO on
## purpose — render scale is a machine setting persisted to user://settings.cfg,
## so it must survive preset/composition loads rather than reset with them.
func reset_defaults() -> void:
	render_scale = 1.0
	upscale_mode = UpscaleMode.BILINEAR
	auto_scale = false
	target_fps = 60
