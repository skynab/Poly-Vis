extends Node
## Global keyboard shortcut handler (Prompt 7.2).
##
## Shortcuts (all require focus outside a text field):
##   Ctrl+Z / Ctrl+Shift+Z  undo / redo
##   Ctrl+Y                 redo (Windows alias)
##   Delete / Backspace     remove selected object
##   Ctrl+D                 duplicate selected object
##   Ctrl+S                 save composition
##   Tab                    cycle object selection
##   H                      hide / show parameter panel
##   F11                    fullscreen clean view (hide all options)
##   Space                  toggle animate on selected PolyMesh
##   F                      focus camera on selected object
##   1–9                    select object by index
class_name InputManager

var _manager: VisualizationManager
var _camera: Node
var _panel: ParameterPanel
var _undo: UndoHistory

func setup(manager: VisualizationManager, camera: Node,
		panel: ParameterPanel, undo: UndoHistory) -> void:
	_manager = manager
	_camera = camera
	_panel = panel
	_undo = undo

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var e := event as InputEventKey
	if not e.pressed:
		return

	if e.ctrl_pressed:
		match e.keycode:
			KEY_Z:
				if e.shift_pressed:
					_undo.redo()
				else:
					_undo.undo()
			KEY_Y:
				_undo.redo()
			KEY_D:
				_panel.duplicate_selected()
			KEY_S:
				_panel.trigger_save()
		return

	match e.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			_manager.remove_selected()
		KEY_TAB:
			_cycle_selection()
		KEY_H:
			_panel.visible = not _panel.visible
		KEY_F11:
			_panel.toggle_fullscreen()
		KEY_SPACE:
			_toggle_animation()
		KEY_F:
			_focus_camera()
		KEY_1: _select_index(0)
		KEY_2: _select_index(1)
		KEY_3: _select_index(2)
		KEY_4: _select_index(3)
		KEY_5: _select_index(4)
		KEY_6: _select_index(5)
		KEY_7: _select_index(6)
		KEY_8: _select_index(7)
		KEY_9: _select_index(8)

func _cycle_selection() -> void:
	if _manager.objects.is_empty():
		return
	var idx := _manager.objects.find(_manager.selected)
	_manager.select(_manager.objects[(idx + 1) % _manager.objects.size()])

func _select_index(idx: int) -> void:
	if idx < _manager.objects.size():
		_manager.select(_manager.objects[idx])

func _toggle_animation() -> void:
	var obj := _manager.selected
	if obj is PolyMesh:
		var mesh := obj as PolyMesh
		mesh.animate = not mesh.animate
		_panel.show_object(mesh)

func _focus_camera() -> void:
	if _manager.selected == null:
		return
	if _camera.has_method("get_param_schema"):
		_camera.set("target", _manager.selected.global_position)
