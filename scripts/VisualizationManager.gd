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
	return node is PolyMesh or node is PolyParticles or node is InfluenceObject

func add_mesh() -> Node3D:
	return _register(PolyMesh.new())

func add_particles() -> Node3D:
	return _register(PolyParticles.new())

func add_influence() -> Node3D:
	var inf := _register(InfluenceObject.new())
	# Influences start in front of the origin rather than offset down the X row.
	inf.position = Vector3(0.0, 0.0, 2.5)
	return inf

func _register(obj: Node3D) -> Node3D:
	_spawn_counter += 1
	obj.name = "%s_%d" % [_type_label(obj), _spawn_counter]
	# Offset each new object so they don't stack on the origin.
	obj.position = Vector3(float(objects.size()) * 3.5, 0.0, 0.0)
	add_child(obj)
	objects.append(obj)
	objects_changed.emit()
	select(obj)
	return obj

func _type_label(obj: Node) -> String:
	if obj is PolyMesh:
		return "PolyMesh"
	if obj is PolyParticles:
		return "PolyParticles"
	if obj is InfluenceObject:
		return "Influence"
	return "Object"

func remove_selected() -> void:
	if selected == null:
		return
	var idx := objects.find(selected)
	objects.erase(selected)
	selected.queue_free()
	selected = null
	objects_changed.emit()
	if not objects.is_empty():
		select(objects[clampi(idx, 0, objects.size() - 1)])
	else:
		selection_changed.emit(null)

func select(obj: Node3D) -> void:
	selected = obj
	selection_changed.emit(obj)

func display_name(obj: Node3D) -> String:
	return "%s  (%s)" % [obj.name, _type_label(obj)]
