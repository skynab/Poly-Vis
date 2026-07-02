extends Node3D
## Root of the Poly-Vis application.
##
## Instantiates and wires all runtime systems: visualization manager, camera,
## parameter panel, influence controller, capture manager, undo history,
## selection gizmo, and keyboard input manager.
class_name Main

@onready var manager: VisualizationManager = $VisualizationManager
@onready var camera: Camera3D = $Camera3D
@onready var panel: ParameterPanel = $UI/ParameterPanel
@onready var influence: InfluenceController = $InfluenceController
@onready var world_env: WorldEnvironment = $WorldEnvironment

var capture: CaptureManager
var undo: UndoHistory
var gizmo: SelectionGizmo
var input_mgr: InputManager
var scene_env: SceneEnvironment
var hud_logo: HudLogo
var wall: WallConfig
var audio: AudioReactor
var postfx: PostFX
var render_scale: RenderScale
var skel_bind: SkeletonAutoBind
var _fps_label: Label
## Active preset/composition transition tween (see apply_composition). Kept so a
## new load can cancel a still-running glide instead of fighting it.
var _transition_tween: Tween

func _ready() -> void:
	# Capture manager — hides the UI layer during still screenshots.
	capture = CaptureManager.new()
	capture.name = "CaptureManager"
	capture.ui_layer = $UI
	add_child(capture)

	# Undo/redo history — shared by the panel and the input manager.
	undo = UndoHistory.new()
	undo.history_changed.connect(func(): panel.show_object(manager.selected))
	# Route the manager's user-facing add_*/remove_selected through the history so
	# object add/remove is undoable (the undo-free spawn_*/remove() stay untouched).
	manager.undo = undo

	# Selection gizmo — lives in the 3D world alongside visualized objects.
	gizmo = SelectionGizmo.new()
	gizmo.name = "SelectionGizmo"
	$VisualizationManager.add_child(gizmo)
	manager.selection_changed.connect(gizmo.select)

	# Keyboard shortcut handler.
	input_mgr = InputManager.new()
	input_mgr.name = "InputManager"
	add_child(input_mgr)

	# FPS counter — top-left corner of viewport.
	_fps_label = Label.new()
	_fps_label.position = Vector2(10, 10)
	_fps_label.add_theme_font_size_override("font_size", 12)
	_fps_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.6))
	$UI.add_child(_fps_label)

	# Scene environment wrapper — schema-driven bg color + bloom, serialized
	# alongside the camera so presets can ship a dark room for neon visuals.
	scene_env = SceneEnvironment.new()
	scene_env.bind(world_env.environment, self)

	# Post-processing pass — its own CanvasLayer above the 3D view, below the UI.
	# Bound BEFORE the HUD logo so the effect processes the 3D render and the logo
	# overlays on top un-graded. Like HudLogo it stays visible during capture.
	postfx = PostFX.new()
	postfx.bind(self)

	# HUD logo overlay — its own CanvasLayer (kept visible during capture, so the
	# logo watermarks screenshots/recordings). Added to Main, not $UI.
	hud_logo = HudLogo.new()
	hud_logo.name = "HudLogo"
	add_child(hud_logo)

	# LED wall description — physical size + resolution for real-world mapping.
	wall = WallConfig.new()

	# Render-scale / performance — drives the viewport's 3D scaling so the scene
	# can render below native res while the UI stays crisp. A machine preference
	# persisted to user://settings.cfg (loaded in _init) and re-applied here.
	render_scale = RenderScale.new()
	render_scale.apply()

	# Audio reactivity — spectrum-analyzer bands feed opt-in modulated params
	# (e.g. PolyParticles.brightness_audio_band). Off by default.
	audio = AudioReactor.new()
	audio.bind(self)
	manager.audio_reactor = audio

	# Skeleton auto-bind — one influence per named OptiTrack skeleton bone, the
	# skeleton counterpart to InfluenceController.auto_bind_rigid_bodies. Off by
	# default; ticked each frame in _process.
	skel_bind = SkeletonAutoBind.new()
	skel_bind.setup(manager)

	panel.setup(manager, camera, capture, undo, scene_env, hud_logo, gizmo, wall, audio, influence, self, postfx, render_scale, skel_bind)
	influence.setup(manager, camera, wall)
	input_mgr.setup(manager, camera, panel, undo)

func _process(delta: float) -> void:
	_fps_label.text = "FPS  %d" % Engine.get_frames_per_second()
	audio.update(delta)
	render_scale.update(delta)
	skel_bind.update()

# ---------------------------------------------------------------------------
# Composition loading with an optional animated transition
# ---------------------------------------------------------------------------
## Load a full composition (a built-in preset or a saved file), gliding the
## camera framing, background, and any *surviving* object params from their
## current values to the loaded ones over scene_env.transition_duration. The
## ParameterPanel routes its preset dropdown / Load button through here.
##
## Robustness contract:
##   - Object add/remove is always instant — CompositionIO.apply rebuilds the
##     object list up front, and only per-slot params that exist on both the old
##     and new object (same type, same tweenable prop) are interpolated, so
##     switching between presets with different object counts never errors.
##   - Only floats / colors / vector3s tween; ints, enums, bools, strings, and
##     colormaps are structural or non-continuous, so they snap at apply time.
##   - lock_background is respected: the background is neither captured nor
##     tweened while locked (apply already leaves it untouched).
##   - At duration 0 this is a plain instant apply — the original behavior.
func apply_composition(data: Dictionary) -> void:
	var dur: float = scene_env.transition_duration
	if dur <= 0.0:
		CompositionIO.apply(data, manager, camera, scene_env, hud_logo, gizmo, wall, audio, influence, postfx, skel_bind)
		return
	var snap := _capture_transition_state()
	CompositionIO.apply(data, manager, camera, scene_env, hud_logo, gizmo, wall, audio, influence, postfx, skel_bind)
	_run_transition(snap, dur)

## Snapshot the interpolatable state (camera framing, background, and each
## object's float/color/vector params) *before* apply swaps everything out, so
## _run_transition can tween from here to the freshly-loaded values.
func _capture_transition_state() -> Dictionary:
	var snap := {
		"cam_target": camera.target,
		"cam_distance": camera.distance,
		"objects": [],
	}
	# Only snapshot the background when it will actually change — skip while
	# locked so we don't tween toward stale values apply left in place.
	if not scene_env.lock_background:
		snap["bg_color"] = scene_env.bg_color
		snap["bg_color2"] = scene_env.bg_color2
		snap["bloom_intensity"] = scene_env.bloom_intensity
	for o in manager.objects:
		snap["objects"].append({
			"type": manager._type_label(o),
			"params": _tweenable_params(o),
		})
	return snap

## Current values of an object's interpolatable schema params (float / color /
## vector3 only) keyed by name.
func _tweenable_params(obj: Object) -> Dictionary:
	var out := {}
	if obj == null or not obj.has_method("get_param_schema"):
		return out
	for section in obj.get_param_schema():
		for prop in section["props"]:
			if _is_tweenable_type(prop["type"]):
				out[prop["name"]] = obj.get(prop["name"])
	return out

func _is_tweenable_type(t: String) -> bool:
	return t == "float" or t == "color" or t == "vector3"

## Tween everything captured in `snap` from its old value to the object's
## current (post-apply) value over `dur` seconds, on a single parallel tween
## owned by Main.
func _run_transition(snap: Dictionary, dur: float) -> void:
	if _transition_tween and _transition_tween.is_valid():
		_transition_tween.kill()
	var tw := create_tween()  # bound to Main → processes for as long as we live
	_transition_tween = tw
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_SINE)
	tw.set_ease(Tween.EASE_IN_OUT)

	_tween_from(tw, camera, "target", snap["cam_target"], dur)
	_tween_from(tw, camera, "distance", snap["cam_distance"], dur)

	# Background only if we captured it (i.e. not locked); re-check the lock in
	# case it was toggled during apply.
	if snap.has("bg_color") and not scene_env.lock_background:
		_tween_from(tw, scene_env, "bg_color", snap["bg_color"], dur)
		_tween_from(tw, scene_env, "bg_color2", snap["bg_color2"], dur)
		_tween_from(tw, scene_env, "bloom_intensity", snap["bloom_intensity"], dur)

	# Surviving object params: match old→new by slot index + type, tween only the
	# props present on both sides. Mismatched slots (add/remove, type change) just
	# keep the freshly-applied values.
	var old_objs: Array = snap["objects"]
	for i in mini(old_objs.size(), manager.objects.size()):
		var obj := manager.objects[i]
		var old: Dictionary = old_objs[i]
		if manager._type_label(obj) != old["type"]:
			continue
		var new_params := _tweenable_params(obj)
		for pn in old["params"]:
			if new_params.has(pn):
				_tween_from(tw, obj, pn, old["params"][pn], dur)

## Add one property tween: from `from_value` to the object's current value.
func _tween_from(tw: Tween, obj: Object, prop: String, from_value: Variant, dur: float) -> void:
	tw.tween_property(obj, prop, obj.get(prop), dur).from(from_value)
