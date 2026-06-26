extends PanelContainer
## Dockable side panel exposing all parameters of the selected visualization plus
## the camera, with live controls in collapsible sections (Prompt 4.1).
## Phase 6 adds IO toolbar (presets/save/load/duplicate) and export controls
## (screenshot and image-sequence recording).
##
## Controls are generated from each object's get_param_schema(), so every
## parameter is covered without hand-wiring. Binding is two-way: control changes
## call obj.set(name, value); selecting an object rebuilds controls from obj.get().
class_name ParameterPanel

const PRESET_NAMES := ["Viridis", "Pink-Red-White", "Purple-Yellow", "Green-Teal"]
var PRESET_VALUES := [
	GradientColormap.Preset.VIRIDIS,
	GradientColormap.Preset.PINK_RED_WHITE,
	GradientColormap.Preset.PURPLE_YELLOW,
	GradientColormap.Preset.GREEN_TEAL,
]

var _manager: VisualizationManager
var _camera: Node
var _capture: CaptureManager
var _obj_selector: OptionButton
var _object_host: VBoxContainer
var _status_label: Label
var _rec_button: Button
var _fps_spin: SpinBox
var _save_dlg: FileDialog
var _load_dlg: FileDialog
var _built := false

func setup(manager: VisualizationManager, camera: Node,
		capture: CaptureManager = null) -> void:
	_manager = manager
	_camera = camera
	_capture = capture
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
	custom_minimum_size = Vector2(340, 0)
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -340

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	# Title
	var title := Label.new()
	title.text = "Poly-Vis"
	title.add_theme_font_size_override("font_size", 20)
	root.add_child(title)

	# Object selector
	var bar := HBoxContainer.new()
	root.add_child(bar)
	_obj_selector = OptionButton.new()
	_obj_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_obj_selector.item_selected.connect(_on_object_selected)
	bar.add_child(_obj_selector)

	# Add / Remove toolbar
	var bar2 := HBoxContainer.new()
	root.add_child(bar2)
	_add_button(bar2, "+ Mesh", func(): _manager.add_mesh())
	_add_button(bar2, "+ Pts", func(): _manager.add_particles())
	_add_button(bar2, "+ Inf", func(): _manager.add_influence())
	_add_button(bar2, "Remove", func(): _manager.remove_selected())

	# IO toolbar: presets | save | load | duplicate
	var io_bar := HBoxContainer.new()
	root.add_child(io_bar)
	var preset_opt := OptionButton.new()
	preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_opt.add_item("Presets…")
	for pname in BuiltInPresets.PRESETS:
		preset_opt.add_item(pname)
	preset_opt.item_selected.connect(_on_preset_selected)
	io_bar.add_child(preset_opt)
	_add_button(io_bar, "Save", func(): _open_save())
	_add_button(io_bar, "Load", func(): _open_load())
	_add_button(io_bar, "Dup", func(): _duplicate_selected())

	# Export toolbar: screenshot | 2x | record | fps
	var ex_bar := HBoxContainer.new()
	root.add_child(ex_bar)
	_add_button(ex_bar, "Capture", func(): _do_screenshot(1))
	_add_button(ex_bar, "2×", func(): _do_screenshot(2))
	_rec_button = Button.new()
	_rec_button.text = "● Rec"
	_rec_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rec_button.pressed.connect(_toggle_recording)
	ex_bar.add_child(_rec_button)
	_fps_spin = SpinBox.new()
	_fps_spin.min_value = 1
	_fps_spin.max_value = 60
	_fps_spin.value = 24
	_fps_spin.suffix = "fps"
	_fps_spin.custom_minimum_size = Vector2(72, 0)
	ex_bar.add_child(_fps_spin)

	# Status label (shows save/load/capture feedback)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 14)
	root.add_child(_status_label)

	root.add_child(HSeparator.new())

	# Scrollable parameter area
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 4)
	scroll.add_child(content)

	if _camera and _camera.has_method("get_param_schema"):
		_populate(content, _camera, _camera.get_param_schema())
	_object_host = VBoxContainer.new()
	_object_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_object_host)

func _add_button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)

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

func _on_object_selected(index: int) -> void:
	if index >= 0 and index < _manager.objects.size():
		_manager.select(_manager.objects[index])

func show_object(obj: Node3D) -> void:
	if _object_host == null:
		return
	for c in _object_host.get_children():
		c.queue_free()
	if obj and obj.has_method("get_param_schema"):
		_populate(_object_host, obj, obj.get_param_schema())
	var idx := _manager.objects.find(obj)
	if idx >= 0 and _obj_selector and _obj_selector.selected != idx:
		_obj_selector.select(idx)

# ---------------------------------------------------------------------------
# IO actions
# ---------------------------------------------------------------------------
func _on_preset_selected(idx: int) -> void:
	if idx == 0:
		return
	var names := BuiltInPresets.PRESETS.keys()
	var data: Dictionary = BuiltInPresets.PRESETS[names[idx - 1]]
	CompositionIO.apply(data, _manager, _camera)
	_show_status("Loaded preset: " + names[idx - 1])

func _open_save() -> void:
	_ensure_dialogs()
	_save_dlg.popup_centered()

func _open_load() -> void:
	_ensure_dialogs()
	_load_dlg.popup_centered()

func _do_save(path: String) -> void:
	var data := CompositionIO.serialize(_manager, _camera)
	var err := CompositionIO.save_json(path, data)
	_show_status("Saved: " + path.get_file() if err == OK else "Save failed (%d)" % err)

func _do_load(path: String) -> void:
	var data := CompositionIO.load_json(path)
	if data.is_empty():
		_show_status("Load failed: empty or invalid file")
		return
	CompositionIO.apply(data, _manager, _camera)
	_show_status("Loaded: " + path.get_file())

func _duplicate_selected() -> void:
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
func _do_screenshot(scale: int) -> void:
	if _capture == null:
		_show_status("No capture manager connected")
		return
	_capture.capture(scale)

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
	var type: String = prop["type"]
	match type:
		"float", "int":
			_add_number(body, obj, prop)
		"bool":
			_add_bool(body, obj, prop)
		"color":
			_add_color(body, obj, prop)
		"enum":
			_add_enum(body, obj, prop)
		"vector3":
			_add_vector3(body, obj, prop)
		"colormap_preset":
			_add_colormap(body, obj, prop)

func _row(body: VBoxContainer, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120, 0)
	row.add_child(label)
	body.add_child(row)
	return row

func _add_number(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var is_int: bool = prop["type"] == "int"
	var row := _row(body, pname.capitalize())
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
	slider.value_changed.connect(func(v: float):
		var out: Variant = int(round(v)) if is_int else v
		obj.set(pname, out)
		readout.text = _fmt(out, is_int))

func _add_bool(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize())
	var cb := CheckButton.new()
	cb.button_pressed = obj.get(pname)
	row.add_child(cb)
	cb.toggled.connect(func(p: bool): obj.set(pname, p))

func _add_color(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize())
	var picker := ColorPickerButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color = obj.get(pname)
	row.add_child(picker)
	picker.color_changed.connect(func(c: Color): obj.set(pname, c))

func _add_enum(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize())
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for o in prop["options"]:
		opt.add_item(o)
	opt.selected = int(obj.get(pname))
	row.add_child(opt)
	opt.item_selected.connect(func(i: int): obj.set(pname, i))

func _add_vector3(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var pname: String = prop["name"]
	var row := _row(body, pname.capitalize())
	var current: Vector3 = obj.get(pname)
	var spins: Array[SpinBox] = []
	for axis in 3:
		var sb := SpinBox.new()
		sb.min_value = -100.0
		sb.max_value = 100.0
		sb.step = 0.05
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.value = current[axis]
		row.add_child(sb)
		spins.append(sb)
	for axis in 3:
		spins[axis].value_changed.connect(func(_v: float):
			obj.set(pname, Vector3(spins[0].value, spins[1].value, spins[2].value)))

func _add_colormap(body: VBoxContainer, obj: Object, prop: Dictionary) -> void:
	var row := _row(body, "Colormap")
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
