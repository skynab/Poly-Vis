extends RefCounted
## Thin wrapper around Godot's UndoRedo that the ParameterPanel uses to record
## property changes with drag-debouncing (Prompt 7.2).
##
## record_property() is called AFTER the value is already applied to the object,
## so commit_action(false) is used — the "do" step is skipped on first commit
## but replayed on redo.
##
## history_changed fires after every undo/redo so the panel can refresh controls.
class_name UndoHistory

signal history_changed

var _ur := UndoRedo.new()

# ---------------------------------------------------------------------------
func record_property(obj: Object, prop: String, old_val: Variant, new_val: Variant) -> void:
	if old_val == new_val:
		return
	_ur.create_action("Set %s" % prop.replace("_", " ").capitalize())
	_ur.add_do_property(obj, prop, new_val)
	_ur.add_undo_property(obj, prop, old_val)
	_ur.commit_action(false)  # value already set; skip re-executing "do"

func undo() -> void:
	if _ur.get_history_count() > 0:
		_ur.undo()
		history_changed.emit()

func redo() -> void:
	_ur.redo()
	history_changed.emit()

func can_undo() -> bool:
	return _ur.get_history_count() > 0

func current_action() -> String:
	return _ur.get_current_action_name()
