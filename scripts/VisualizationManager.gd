extends Node3D
## Holds the active visualization objects and the current selection (Prompt 4.2).
##
## Visualization objects (PolyMesh / PolyParticles) live as direct children.
## Existing children are adopted on ready; add/remove spawn or free them. The
## ParameterPanel listens to the signals below to route its controls.
class_name VisualizationManager

signal objects_changed
signal selection_changed(obj: Node3D)

var objects: Array[Node3D] = []
var selected: Node3D = null
var _spawn_counter: int = 0
## Set by Main after construction. Wired into every new PolyParticles so its
## audio-reactive params (brightness_audio_band, etc.) can read live levels.
var audio_reactor: AudioReactor = null
## Set by Main after construction. When present, the user-facing add_*/
## remove_selected route through it so each add/remove is a single undo step.
## The undo-free spawn_*/remove() primitives never touch it, so composition
## loads, preset applies, duplication, and auto-bind stay out of the history.
var undo: UndoHistory = null

func _ready() -> void:
	_scan_children()

func _scan_children() -> void:
	objects.clear()
	for c in get_children():
		if is_managed(c):
			objects.append(c)
			_spawn_counter += 1
	objects_changed.emit()
	if selected == null and not objects.is_empty():
		select(objects[0])

func is_managed(node: Node) -> bool:
	return node is PolyMesh or node is PolyParticles or node is PolyCloth \
		or node is PolyTrails or node is PolyMetaballs or node is PolyStrands \
		or node is InfluenceObject

# --- undo-free spawn primitives --------------------------------------------
# These add an object without recording an undo step. Used by CompositionIO
# (load / preset / duplicate) and InfluenceController's auto-bind, where a batch
# of objects appears without meaning a user "add" action.
func spawn_mesh() -> Node3D:
	return _register(PolyMesh.new())

func spawn_particles() -> Node3D:
	return _register(PolyParticles.new())

func spawn_cloth() -> Node3D:
	return _register(PolyCloth.new())

func spawn_trails() -> Node3D:
	return _register(PolyTrails.new())

func spawn_metaballs() -> Node3D:
	return _register(PolyMetaballs.new())

func spawn_strands() -> Node3D:
	return _register(PolyStrands.new())

## `select_after` is false for influences spawned silently by
## InfluenceController's auto-bind (so a newly-streamed rigid body doesn't
## steal the panel's selection away from whatever the user is editing).
func spawn_influence(select_after: bool = true) -> Node3D:
	var inf := _register(InfluenceObject.new(), select_after)
	# Influences start in front of the origin rather than offset down the X row.
	inf.position = Vector3(0.0, 0.0, 2.5)
	return inf

# --- user-facing adds (undoable) -------------------------------------------
# Each spawns via the primitive above, then records a single add step so Ctrl+Z
# removes the object and redo brings it back. No-op on undo when `undo` is unset.
func add_mesh() -> Node3D:
	return _record_add(spawn_mesh())

func add_particles() -> Node3D:
	return _record_add(spawn_particles())

func add_cloth() -> Node3D:
	return _record_add(spawn_cloth())

func add_trails() -> Node3D:
	return _record_add(spawn_trails())

func add_metaballs() -> Node3D:
	return _record_add(spawn_metaballs())

func add_strands() -> Node3D:
	return _record_add(spawn_strands())

func add_influence(select_after: bool = true) -> Node3D:
	return _record_add(spawn_influence(select_after))

func _record_add(obj: Node3D) -> Node3D:
	if undo != null and obj != null:
		undo.record_object_add(self, obj)
	return obj

func _register(obj: Node3D, select_after: bool = true) -> Node3D:
	_spawn_counter += 1
	obj.name = "%s_%d" % [_type_label(obj), _spawn_counter]
	# Offset each new object so they don't stack on the origin.
	obj.position = Vector3(float(objects.size()) * 3.5, 0.0, 0.0)
	if obj is PolyParticles and audio_reactor:
		obj.audio_reactor = audio_reactor
	add_child(obj)
	objects.append(obj)
	objects_changed.emit()
	if select_after:
		select(obj)
	return obj

func _type_label(obj: Node) -> String:
	if obj is PolyMesh:
		return "PolyMesh"
	if obj is PolyParticles:
		return "PolyParticles"
	if obj is PolyCloth:
		return "PolyCloth"
	if obj is PolyTrails:
		return "PolyTrails"
	if obj is PolyMetaballs:
		return "PolyMetaballs"
	if obj is PolyStrands:
		return "PolyStrands"
	if obj is InfluenceObject:
		return "Influence"
	return "Object"

## User-facing delete of the current selection. When an undo history is present,
## the removal is performed *through* the recorded action (so redo replays it and
## undo restores the object from a full CompositionIO snapshot); otherwise it's a
## plain immediate remove.
func remove_selected() -> void:
	if selected == null:
		return
	if undo != null:
		undo.record_object_remove(self, selected)
	else:
		remove(selected)

## Free a specific managed object. Unlike remove_selected(), this leaves the
## current selection alone when `obj` isn't the selected one — used by
## InfluenceController's auto-bind to despawn an influence whose rigid body
## stopped streaming without disturbing whatever the user has selected.
func remove(obj: Node3D) -> void:
	if obj == null or not objects.has(obj):
		return
	var idx := objects.find(obj)
	var was_selected := obj == selected
	objects.erase(obj)
	obj.queue_free()
	objects_changed.emit()
	if was_selected:
		selected = null
		if not objects.is_empty():
			select(objects[clampi(idx, 0, objects.size() - 1)])
		else:
			selection_changed.emit(null)

func clear_all() -> void:
	for obj in objects.duplicate():
		obj.queue_free()
	objects.clear()
	selected = null
	_spawn_counter = 0
	objects_changed.emit()
	selection_changed.emit(null)

func select(obj: Node3D) -> void:
	selected = obj
	selection_changed.emit(obj)

func display_name(obj: Node3D) -> String:
	return "%s  (%s)" % [obj.name, _type_label(obj)]
