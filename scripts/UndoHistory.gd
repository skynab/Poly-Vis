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

# ---------------------------------------------------------------------------
# Object add / remove (Prompt 7.x)
#
# Adding and removing a managed object is undoable by serializing it to a
# CompositionIO snapshot and re-materializing it on the reverse step. Because an
# undone-then-freed object can't be referenced again, the do/undo callables share
# a one-slot `holder` carrying the live instance and a one-slot `snapshot`
# carrying its serialized state — re-captured on every destroy so edits made
# between an add and a later undo survive the round trip.
# ---------------------------------------------------------------------------

## Record an already-performed add: the caller just spawned `obj` (it's live), so
## the "do" (recreate) is skipped on commit and only replays on redo; undo frees it.
func record_object_add(manager: VisualizationManager, obj: Node3D) -> void:
	_record_object(manager, obj, true)

## Record a removal of the still-live `obj`. commit_action(true) runs the "do"
## (destroy) now, performing the actual removal; undo recreates it from the snapshot.
func record_object_remove(manager: VisualizationManager, obj: Node3D) -> void:
	_record_object(manager, obj, false)

func _record_object(manager: VisualizationManager, obj: Node3D, is_add: bool) -> void:
	if obj == null:
		return
	var type: String = manager._type_label(obj)
	var holder: Array = [obj]
	var snapshot: Array = [CompositionIO.serialize_object(obj, type)]
	var destroy := func() -> void:
		if is_instance_valid(holder[0]):
			snapshot[0] = CompositionIO.serialize_object(holder[0], type)  # capture latest edits
			manager.remove(holder[0])  # undo-free primitive — no nested action
			holder[0] = null
	var create := func() -> void:
		holder[0] = CompositionIO.create_object(snapshot[0], manager)
	_ur.create_action(("Add " if is_add else "Remove ") + type)
	if is_add:
		_ur.add_do_method(create)     # redo re-adds
		_ur.add_undo_method(destroy)  # undo removes
		_ur.commit_action(false)      # object already added by the caller
	else:
		_ur.add_do_method(destroy)    # redo removes
		_ur.add_undo_method(create)   # undo restores
		_ur.commit_action(true)       # perform the removal now

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
