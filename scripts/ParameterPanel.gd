extends PanelContainer
## Dockable side panel exposing all parameters of the selected visualization plus
## the camera, with live controls in collapsible sections (Prompt 4.1).
## Phase 6 adds IO toolbar (presets/save/load/duplicate) and export controls.
## Phase 7 adds undo/redo integration, button tooltips, and an FPS readout.
##
## Controls are generated from each object's get_param_schema(), so every
## parameter is covered without hand-wiring. Slider changes record an undo step
## only on drag_ended so dragging doesn't flood the history.
class_name ParameterPanel

const PRESET_NAMES := ["Viridis", "Pink-Red-White", "Purple-Yellow", "Green-Teal",
	"Magma", "Ice", "Sunset", "Grayscale", "Rainbow"]
var PRESET_VALUES := [
	GradientColormap.Preset.VIRIDIS,
	GradientColormap.Preset.PINK_RED_WHITE,
	GradientColormap.Preset.PURPLE_YELLOW,
	GradientColormap.Preset.GREEN_TEAL,
	GradientColormap.Preset.MAGMA,
	GradientColormap.Preset.ICE,
	GradientColormap.Preset.SUNSET,
	GradientColormap.Preset.GRAYSCALE,
	GradientColormap.Preset.RAINBOW,
]

var _manager: VisualizationManager
var _camera: Node
var _scene: Object  # SceneEnvironment — bg color + bloom, rendered after camera
var _audio: Object  # AudioReactor — spectrum bands/beat, rendered after scene
var _hud: Object    # HudLogo — overlay logo, rendered after audio
var _gizmo: Object  # SelectionGizmo — selection ring toggle, rendered after hud
var _wall: Object   # WallConfig — LED wall dimensions/resolution, rendered after gizmo
var _influence_ctrl: Object  # InfluenceController — auto-bind toggle, rendered after wall
var _main: Node     # Main — routes preset/composition loads through its animated transition
var _capture: CaptureManager
var _undo: UndoHistory
var _obj_selector: OptionButton
var _object_host: VBoxContainer
var _status_label: Label
var _rec_button: Button
var _fps_spin: SpinBox
var _save_dlg: FileDialog
var _load_dlg: FileDialog
var _built := false

const _PANEL_WIDTH := 384          # expanded width of the dock
var _panel_body: VBoxContainer     # everything below the top bar (all the options)
var _title_label: Label            # "Poly-Vis" — hidden in fullscreen to shrink the chip
var _fs_button: Button             # the fullscreen / hide-options toggle
var _fullscreen := false

func setup(manager: VisualizationManager, camera: Node,
		capture: CaptureManager = null, undo: UndoHistory = null,
		scene: Object = null, hud: Object = null, gizmo: Object = null,
		wall: Object = null, audio: Object = null, influence_ctrl: Object = null,
		main: Node = null) -> void:
	_manager = manager
	_camera = camera
	_scene = scene
	_hud = hud
	_gizmo = gizmo
	_wall = wall
	_audio = audio
	_influence_ctrl = influence_ctrl
	_main = main
	_capture = capture
	_undo = undo
	if not _built:
		_build_base()
	if not _manager.objects_changed.is_connected(_refresh_object_list):
		_manager.objects_changed.connect(_refresh_object_list)
	if not _manager.selection_changed.is_connected(show_object):
		_manager.selection_changed.connect(show_object)
	if _capture:
		if not _capture.screenshot_saved.is_connected(_on_screenshot_saved):
			_capture.screenshot_saved.connect(_on_screenshot_saved)
		if not _capture.recording_stopped.is_connected(_on_recording_stopped):
			_capture.recording_stopped.connect(_on_recording_stopped)
	_refresh_object_list()
	show_object(_manager.selected)

# ---------------------------------------------------------------------------
func _build_base() -> void:
	_built = true
	custom_minimum_size = Vector2(_PANEL_WIDTH, 0)
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -float(_PANEL_WIDTH)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	# Top bar: title + fullscreen / hide-options toggle. Stays visible even when the
	# rest of the panel is hidden, so it can always be toggled back off.
	var top_bar := HBoxContainer.new()
	root.add_child(top_bar)
	_title_label = Label.new()
	_title_label.text = "Poly-Vis"
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(_title_label)
	_fs_button = Button.new()
	_fs_button.toggle_mode = true
	_fs_button.text = "⛶"
	_fs_button.tooltip_text = "Fullscreen — hide all options for a clean view  [F11]"
	_fs_button.toggled.connect(func(p: bool): _set_fullscreen(p))
	top_bar.add_child(_fs_button)

	# Everything below the top bar — hidden in fullscreen mode.
	_panel_body = VBoxContainer.new()
	_panel_body.add_theme_constant_override("separation", 6)
	_panel_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_panel_body)

	# Object selector
	var bar := HBoxContainer.new()
	_panel_body.add_child(bar)
	_obj_selector = OptionButton.new()
	_obj_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_obj_selector.tooltip_text = "Select the active object"
	_obj_selector.item_selected.connect(_on_object_selected)
	bar.add_child(_obj_selector)

	# Add / Remove toolbar
	var bar2 := HBoxContainer.new()
	_panel_body.add_child(bar2)
	_btn(bar2, "+ Mesh", "Add a new PolyMesh", func(): _manager.add_mesh())
	_btn(bar2, "+ Pts",  "Add a new particle system", func(): _manager.add_particles())
	_btn(bar2, "+ Cloth", "Add a new crumpled-cloth surface", func(): _manager.add_cloth())
	_btn(bar2, "+ Inf",  "Add a new influence sphere", func(): _manager.add_influence())
	_btn(bar2, "Remove", "Delete the selected object  [Delete]", func(): _manager.remove_selected())

	# IO toolbar: presets | save | load | duplicate
	var io_bar := HBoxContainer.new()
	_panel_body.add_child(io_bar)
	var preset_opt := OptionButton.new()
	preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_opt.tooltip_text = "Load a built-in preset composition"
	preset_opt.add_item("Presets…")
	for pname in BuiltInPresets.PRESETS:
		preset_opt.add_item(pname)
	preset_opt.item_selected.connect(_on_preset_selected)
	io_bar.add_child(preset_opt)
	_btn(io_bar, "Save", "Save composition to a JSON file  [Ctrl+S]", func(): _open_save())
	_btn(io_bar, "Load", "Load composition from a JSON file", func(): _open_load())
	_btn(io_bar, "Dup",  "Duplicate selected object  [Ctrl+D]", func(): duplicate_selected())

	# Export toolbar: screenshot | 2x | record | fps
	var ex_bar := HBoxContainer.new()
	_panel_body.add_child(ex_bar)
	_btn(ex_bar, "Capture", "Screenshot (UI hidden, saved to user://)", func(): _do_screenshot(1))
	_btn(ex_bar, "2×",      "2× upscaled screenshot", func(): _do_screenshot(2))
	_rec_button = Button.new()
	_rec_button.text = "● Rec"
	_rec_button.tooltip_text = "Start/stop image-sequence recording to user://"
	_rec_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rec_button.pressed.connect(_toggle_recording)
	ex_bar.add_child(_rec_button)
	_fps_spin = SpinBox.new()
	_fps_spin.min_value = 1
	_fps_spin.max_value = 60
	_fps_spin.value = 24
	_fps_spin.suffix = "fps"
	_fps_spin.tooltip_text = "Recording frame rate"
	_fps_spin.custom_minimum_size = Vector2(72, 0)
	ex_bar.add_child(_fps_spin)

	# Status / hint line
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 14)
	_panel_body.add_child(_status_label)

	_panel_body.add_child(HSeparator.new())

	# Shortcut reminder
	var hint := Label.new()
	hint.text = "Tab cycle · H panel · F11 fullscreen · Del remove · F focus · Space anim"
	hint.add_theme_font_size_override("font_size", 9)
	hint.modulate = Color(1, 1, 1, 0.45)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_body.add_child(hint)

	_panel_body.add_child(HSeparator.new())

	# Parameters split into two tabs so it's clear which settings are global
	# (camera / scene / HUD / ring / wall) versus tied to the selected object.
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_body.add_child(tabs)

	# --- Global tab: camera / scene / audio / hud / gizmo / wall / auto-bind ---
	var global_content := _make_scroll_tab(tabs, "Global")
	if _camera and _camera.has_method("get_param_schema"):
		_populate(global_content, _camera, _camera.get_param_schema())
	if _scene and _scene.has_method("get_param_schema"):
		_populate(global_content, _scene, _scene.get_param_schema())
	if _audio and _audio.has_method("get_param_schema"):
		_populate(global_content, _audio, _audio.get_param_schema())
	if _hud and _hud.has_method("get_param_schema"):
		_populate(global_content, _hud, _hud.get_param_schema())
	if _gizmo and _gizmo.has_method("get_param_schema"):
		_populate(global_content, _gizmo, _gizmo.get_param_schema())
	if _wall and _wall.has_method("get_param_schema"):
		_populate(global_content, _wall, _wall.get_param_schema())
	if _influence_ctrl and _influence_ctrl.has_method("get_param_schema"):
		_populate(global_content, _influence_ctrl, _influence_ctrl.get_param_schema())

	# --- Selection tab: just the selected object's controls (show_object fills it) ---
	_object_host = _make_scroll_tab(tabs, "Selection")

## Build a scrollable tab page in `tabs` titled `title`, returning its content
## VBox to populate. The TabContainer uses the page node's name as the tab label.
func _make_scroll_tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 4)
	scroll.add_child(content)
	return content

func _btn(parent: Node, text: String, tip: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)

# ---------------------------------------------------------------------------
# Fullscreen / clean-view mode
# ---------------------------------------------------------------------------
## Enter (or leave) the clean presentation view: the OS window goes fullscreen and
## every option below the top bar is hidden, collapsing the dock to a small chip in
## the corner that holds only the toggle. Idempotent and safe to drive from either
## the panel button or the F11 shortcut (keeps the button's pressed state in sync).
func _set_fullscreen(on: bool) -> void:
	_fullscreen = on
	if _panel_body:
		_panel_body.visible = not on
	if _title_label:
		_title_label.visible = not on
	if _fs_button and _fs_button.button_pressed != on:
		_fs_button.button_pressed = on
	# Collapse the dock to a small top-right chip (just the toggle) so it stops
	# covering the view; restore the full-height dock when leaving fullscreen.
	if on:
		custom_minimum_size.x = 0.0  # the 340 floor would otherwise keep it full-width
		offset_left = -56.0
		anchor_bottom = 0.0
		offset_bottom = 48.0
	else:
		custom_minimum_size.x = _PANEL_WIDTH
		offset_left = -float(_PANEL_WIDTH)
		anchor_bottom = 1.0
		offset_bottom = 0.0
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)

## Public entry point for the F11 keyboard shortcut (InputManager).
func toggle_fullscreen() -> void:
	_set_fullscreen(not _fullscreen)

# ---------------------------------------------------------------------------
# Object list
# ---------------------------------------------------------------------------
func _refresh_object_list() -> void:
	if _obj_selector == null:
		return
	_obj_selector.clear()
	for obj in _manager.objects:
		_obj_selector.add_item(_manager.display_name(obj))
	var idx := _manager.objects.find(_manager.selected)
	if idx >= 0:
		_obj_selector.select(idx)

## A Transform section (Position XYZ) shown above the selected object's schema
## controls. Edits the node's `position` directly — position is serialized by
## CompositionIO on its own (not via any object's param schema), so it isn't part
## of get_param_schema(); rendering it here gives every managed object a manual
## XYZ field. The wide range covers off-origin layouts.
func _add_transform_section(host: VBoxContainer, obj: Node3D) -> void:
	var body := _add_section(host, "Transform")
	_add_vector3(body, obj, {"name": "position", "min": -1000.0, "max": 1000.0,
		"step": 0.05, "hint": "World XYZ position"})

func _on_object_selected(index: int) -> void:
	if index >= 0 and index < _manager.objects.size():
		_manager.select(_manager.objects[index])

func show_object(obj: Node3D) -> void:
	if _object_host == null:
		return
	for c in _object_host.get_children():
		c.queue_free()
	if obj:
		_add_transform_section(_object_host, obj)
	if obj and obj.has_method("get_param_schema"):
		_populate(_object_host, obj, obj.get_param_schema())
	var idx := _manager.objects.find(obj)
	if idx >= 0 and _obj_selector and _obj_selector.selected != idx:
		_obj_selector.select(idx)

# ---------------------------------------------------------------------------
# IO actions (some are public for InputManager)
# ---------------------------------------------------------------------------
func _on_preset_selected(idx: int) -> void:
	if idx == 0:
		return
	var names := BuiltInPresets.PRESETS.keys()
	var data: Dictionary = BuiltInPresets.PRESETS[names[idx - 1]]
	_apply_composition(data)
	_show_status("Loaded preset: " + names[idx - 1])

## Route a full-composition load through Main's animated transition (camera +
## background + surviving params glide over scene.transition_duration). Falls
## back to an instant CompositionIO.apply if Main wasn't wired in.
func _apply_composition(data: Dictionary) -> void:
	if _main and _main.has_method("apply_composition"):
		_main.apply_composition(data)
	else:
		CompositionIO.apply(data, _manager, _camera, _scene, _hud, _gizmo, _wall, _audio, _influence_ctrl)

func _open_save() -> void:
	_ensure_dialogs()
	_save_dlg.popup_centered()

func _open_load() -> void:
	_ensure_dialogs()
	_load_dlg.popup_centered()

func trigger_save() -> void:
	_open_save()

func _do_save(path: String) -> void:
	var data := CompositionIO.serialize(_manager, _camera, _scene, _hud, _gizmo, _wall, _audio, _influence_ctrl)
	var err := CompositionIO.save_json(path, data)
	_show_status("Saved: " + path.get_file() if err == OK else "Save failed (%d)" % err)

func _do_load(path: String) -> void:
	var data := CompositionIO.load_json(path)
	if data.is_empty():
		_show_status("Load failed: empty or invalid file")
		return
	_apply_composition(data)
	_show_status("Loaded: " + path.get_file())

func duplicate_selected() -> void:
	if _manager.selected == null:
		return
	var type := _manager._type_label(_manager.selected)
	var data := CompositionIO.serialize_object(_manager.selected, type)
	var obj := CompositionIO.create_object(data, _manager)
	if obj:
		obj.position = _manager.selected.position + Vector3(3.5, 0.0, 0.0)
	_show_status("Duplicated " + type)

func _ensure_dialogs() -> void:
	if _save_dlg:
		return
	_save_dlg = FileDialog.new()
	_save_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_save_dlg.filters = PackedStringArray(["*.json ; JSON Composition"])
	_save_dlg.size = Vector2i(640, 460)
	_save_dlg.title = "Save Composition"
	_save_dlg.file_selected.connect(_do_save)
	get_tree().root.add_child(_save_dlg)

	_load_dlg = FileDialog.new()
	_load_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_load_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_load_dlg.filters = PackedStringArray(["*.json ; JSON Composition"])
	_load_dlg.size = Vector2i(640, 460)
	_load_dlg.title = "Load Composition"
	_load_dlg.file_selected.connect(_do_load)
	get_tree().root.add_child(_load_dlg)

# ---------------------------------------------------------------------------
# Export actions
# ---------------------------------------------------------------------------
func _do_screenshot(capture_scale: int) -> void:
	if _capture == null:
		_show_status("No capture manager connected")
		return
	_capture.capture(capture_scale)

func _toggle_recording() -> void:
	if _capture == null:
		_show_status("No capture manager connected")
		return
	if _capture.is_recording():
		_capture.stop_recording()
		_rec_button.text = "● Rec"
	else:
		var dir := _capture.start_recording(int(_fps_spin.value))
		_rec_button.text = "■ Stop"
		_show_status("Recording → " + dir.get_file())

func _on_screenshot_saved(path: String) -> void:
	_show_status("Saved: " + path.get_file())

func _on_recording_stopped(frames: int, dir: String) -> void:
	_show_status("%d frames → %s" % [frames, dir.get_file()])

func _show_status(msg: String) -> void:
	if not _status_label:
		return
	_status_label.text = msg
	get_tree().create_timer(5.0).timeout.connect(func():
		if _status_label and _status_label.text == msg:
			_status_label.text = "")

# ---------------------------------------------------------------------------
# Schema -> controls
# ---------------------------------------------------------------------------
func _populate(host: VBoxContainer, obj: Object, schema: Array) -> void:
	for section in schema:
		var body := _add_section(host, section["title"])
		for prop in section["props"]:
			_add_control(body, obj, prop)

func _add_section(host: VBoxContainer, title: String) -> VBoxContainer:
	var sec := VBoxContainer.new()
	host.add_child(sec)
	var header := Button.new()
	header.toggle_mode = true
	header.button_pressed = true
	header.text = "▼  " + title
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	sec.add_child(header)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	sec.add_child(body)
	header.toggled.connect(func(pressed: bool):
		body.visible = pressed
		header.text = ("▼  " if pressed else "▶  ") + title)
	return body

func _add_control(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	match prop["type"]:
		"float", "int":   _add_number(body, obj, prop)
		"int_field":      _add_int_field(body, obj, prop)
		"string":         _add_string(body, obj, prop)
		"bool":           _add_bool(body, obj, prop)
		"color":          _add_color(body, obj, prop)
		"enum":           _add_enum(body, obj, prop)
		"vector3":        _add_vector3(body, obj, prop)
		"colormap_preset": _add_colormap(body, obj, prop)
		"action":         _add_action(body, obj, prop)
		"status":         _add_status(body, obj, prop)

func _row(body: VBoxContainer, label_text: String, tip: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	# Narrow-ish fixed column so the value-side controls (sliders, readouts, the
	# three vector3 spin boxes) keep room and don't clip off the right edge.
	label.custom_minimum_size = Vector2(108, 0)
	label.clip_text = true
	if tip:
		label.tooltip_text = tip
	row.add_child(label)
	body.add_child(row)
	return row

## A button that invokes a named method on the object (not a stored value).
## CompositionIO skips "action" props, so nothing is serialized. For a managed
## object we rebuild its controls afterward so changed properties show their new
## values (e.g. randomized seeds). Global modules (camera/scene/hud) live in the
## static section and aren't refreshed — their setters keep the view in sync.
func _add_action(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var method: String = prop["name"]
	var btn := Button.new()
	btn.text = prop.get("label", method.capitalize())
	btn.tooltip_text = prop.get("hint", "")
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		if obj.has_method(method):
			obj.call(method)
		if _manager and obj in _manager.objects:
			show_object(obj))
	body.add_child(btn)

## Read-only live status readout. Calls the named method on the object for its
## current string and re-polls a few times a second so a connection that comes up
## (or drops) while the panel is open updates without reselecting. Carries no
## stored value — CompositionIO skips "status" props like it does "action".
func _add_status(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var method: String = prop["name"]
	var row := _row(body, prop.get("label", "Status"), prop.get("hint", ""))
	var value := Label.new()
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(value)
	var refresh := func():
		if is_instance_valid(obj) and obj.has_method(method):
			value.text = str(obj.call(method))
	refresh.call()
	# Poll on a timer parented to the label, so it's freed when the controls rebuild.
	var timer := Timer.new()
	timer.wait_time = prop.get("interval", 0.5)
	timer.autostart = true
	timer.timeout.connect(func(): refresh.call())
	value.add_child(timer)

func _add_number(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var is_int: bool = prop["type"] == "int"
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var slider := HSlider.new()
	slider.min_value = prop.get("min", 0.0)
	slider.max_value = prop.get("max", 1.0)
	slider.step = prop.get("step", 0.01)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value = obj.get(pname)
	row.add_child(slider)
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(48, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.text = _fmt(obj.get(pname), is_int)
	row.add_child(readout)

	# Capture value before drag so undo records the before/after pair. A one-slot
	# array is shared by reference across the lambdas — plain locals are captured
	# by value, so a write in one lambda wouldn't be visible to another.
	var drag_start: Array = [null]
	slider.drag_started.connect(func():
		drag_start[0] = obj.get(pname))
	slider.value_changed.connect(func(v: float):
		var out: Variant
		if is_int:
			out = int(round(v))
		else:
			out = v
		obj.set(pname, out)
		readout.text = _fmt(out, is_int))
	slider.drag_ended.connect(func(changed: bool):
		if changed and _undo != null and drag_start[0] != null:
			_undo.record_property(obj, pname, drag_start[0], obj.get(pname)))

## Integer entry as a SpinBox (typed/stepped number field) rather than a slider —
## for values you want to set exactly, like an OptiTrack rigid-body asset ID.
func _add_int_field(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var sb := SpinBox.new()
	sb.min_value = prop.get("min", 0)
	sb.max_value = prop.get("max", 9999)
	sb.step = prop.get("step", 1)
	sb.rounded = true
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value = obj.get(pname)
	row.add_child(sb)
	var before: Array = [int(obj.get(pname))]
	sb.value_changed.connect(func(v: float):
		var iv := int(round(v))
		if iv == before[0]:
			return
		obj.set(pname, iv)
		if _undo:
			_undo.record_property(obj, pname, before[0], iv)
		before[0] = iv)

## Single-line text field (e.g. an IP address). Commits on Enter or focus loss and
## records one undo step per edit session (the value at focus-in vs focus-out).
func _add_string(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var edit := LineEdit.new()
	edit.text = str(obj.get(pname))
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	var before: Array = [str(obj.get(pname))]
	edit.focus_entered.connect(func(): before[0] = str(obj.get(pname)))
	var commit := func(t: String):
		if t == before[0]:
			return
		obj.set(pname, t)
		if _undo:
			_undo.record_property(obj, pname, before[0], t)
		before[0] = t
	edit.text_submitted.connect(func(t: String): commit.call(t))
	edit.focus_exited.connect(func(): commit.call(edit.text))

func _add_bool(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var cb := CheckButton.new()
	cb.button_pressed = obj.get(pname)
	row.add_child(cb)
	cb.toggled.connect(func(p: bool):
		var old: Variant = obj.get(pname)
		obj.set(pname, p)
		if _undo:
			_undo.record_property(obj, pname, old, p))

func _add_color(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var picker := ColorPickerButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color = obj.get(pname)
	row.add_child(picker)
	# One-slot array shared by reference across lambdas (see _add_number). pressed
	# fires before the popup appears — snapshot the pre-edit color for undo.
	var color_before: Array = [Color()]
	picker.pressed.connect(func():
		color_before[0] = obj.get(pname))
	picker.color_changed.connect(func(c: Color):
		obj.set(pname, c))
	picker.popup_closed.connect(func():
		if _undo:
			_undo.record_property(obj, pname, color_before[0], obj.get(pname)))

func _add_enum(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for o in prop["options"]:
		opt.add_item(o)
	opt.selected = int(obj.get(pname))
	row.add_child(opt)
	opt.item_selected.connect(func(i: int):
		var old: Variant = obj.get(pname)
		obj.set(pname, i)
		if _undo:
			_undo.record_property(obj, pname, old, i))

func _add_vector3(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize(), prop.get("hint", ""))
	var current: Vector3 = obj.get(pname)
	var spins: Array[SpinBox] = []
	for axis in 3:
		var sb := SpinBox.new()
		sb.min_value = prop.get("min", -100.0)
		sb.max_value = prop.get("max", 100.0)
		sb.step = prop.get("step", 0.05)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.value = current[axis]
		row.add_child(sb)
		spins.append(sb)
	for axis in 3:
		spins[axis].value_changed.connect(func(_v: float):
			obj.set(pname, Vector3(spins[0].value, spins[1].value, spins[2].value)))

func _add_colormap(body: VBoxContainer, obj: Object, _prop: Dictionary) -> void:
	var row := _row(body, "Colormap", "Gradient used to color this object")
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for n in PRESET_NAMES:
		opt.add_item(n)
	var cm: GradientColormap = obj.get("colormap")
	if cm:
		var idx := PRESET_VALUES.find(cm.preset)
		if idx >= 0:
			opt.selected = idx
	row.add_child(opt)
	opt.item_selected.connect(func(i: int):
		obj.set("colormap", GradientColormap.create(PRESET_VALUES[i])))

func _fmt(v: Variant, is_int: bool) -> String:
	return ("%d" % int(v)) if is_int else ("%.2f" % float(v))
