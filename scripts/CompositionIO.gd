extends RefCounted
## Serializes a full composition (all managed objects + their parameters +
## colormaps + camera) to a JSON-friendly Dictionary and back (Prompt 6.1).
##
## Encoding is driven by each object's get_param_schema(), so any parameter that
## shows in the panel is also saved. Colormaps store their preset and gradient
## stops; colors and vectors become plain arrays.
class_name CompositionIO

# --- serialize -------------------------------------------------------------
static func serialize(manager: VisualizationManager, camera: Node,
		scene: Object = null, hud: Object = null, gizmo: Object = null) -> Dictionary:
	var objs: Array = []
	for o in manager.objects:
		objs.append(serialize_object(o, manager._type_label(o)))
	var result := {"version": 1, "objects": objs, "camera": _schema_to_dict(camera)}
	if scene and scene.has_method("get_param_schema"):
		result["scene"] = _schema_to_dict(scene)
	if hud and hud.has_method("get_param_schema"):
		result["hud"] = _schema_to_dict(hud)
	if gizmo and gizmo.has_method("get_param_schema"):
		result["gizmo"] = _schema_to_dict(gizmo)
	return result

## Encode every schema property of a single object into a flat Dictionary.
static func _schema_to_dict(obj: Object) -> Dictionary:
	var d := {}
	if obj and obj.has_method("get_param_schema"):
		for section in obj.get_param_schema():
			for prop in section["props"]:
				if prop["type"] == "action":
					continue  # buttons carry no value to serialize
				d[prop["name"]] = _encode(prop["type"], obj.get(prop["name"]))
	return d

## Decode a flat Dictionary back onto a single object's schema properties.
static func _dict_to_schema(obj: Object, d: Dictionary) -> void:
	if obj == null or not obj.has_method("get_param_schema"):
		return
	for section in obj.get_param_schema():
		for prop in section["props"]:
			if prop["type"] == "action":
				continue
			var pn: String = prop["name"]
			if d.has(pn):
				obj.set(pn, _decode(prop["type"], d[pn]))

static func serialize_object(obj: Node3D, type_label: String) -> Dictionary:
	var params := {}
	if obj.has_method("get_param_schema"):
		for section in obj.get_param_schema():
			for prop in section["props"]:
				if prop["type"] == "action":
					continue
				var pn: String = prop["name"]
				params[pn] = _encode(prop["type"], obj.get(pn))
	return {"type": type_label, "position": _v3(obj.position), "params": params}

static func _encode(type: String, value: Variant) -> Variant:
	match type:
		"color":
			return [value.r, value.g, value.b, value.a]
		"vector3":
			return _v3(value)
		"colormap_preset":
			return _encode_colormap(value)
		_:
			return value

static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

static func _encode_colormap(cm: GradientColormap) -> Variant:
	if cm == null:
		return null
	var offs: Array = []
	var cols: Array = []
	if cm.gradient:
		for i in cm.gradient.get_point_count():
			offs.append(cm.gradient.get_offset(i))
			var c: Color = cm.gradient.get_color(i)
			cols.append([c.r, c.g, c.b, c.a])
	return {"preset": int(cm.preset), "offsets": offs, "colors": cols}

# --- deserialize -----------------------------------------------------------
static func apply(data: Dictionary, manager: VisualizationManager, camera: Node,
		scene: Object = null, hud: Object = null, gizmo: Object = null) -> void:
	manager.clear_all()
	for od in data.get("objects", []):
		create_object(od, manager)
	_dict_to_schema(camera, data.get("camera", {}))
	if scene:
		# Reset first so a composition with no "scene" block restores the
		# default white room instead of inheriting the previous bloom/bg.
		if scene.has_method("reset_defaults"):
			scene.reset_defaults()
		_dict_to_schema(scene, data.get("scene", {}))
	if hud:
		# Same pattern: a comp with no "hud" block clears any prior logo.
		if hud.has_method("reset_defaults"):
			hud.reset_defaults()
		_dict_to_schema(hud, data.get("hud", {}))
	if gizmo:
		# Same pattern: presets carry no "gizmo" block, so the selection ring
		# resets to off — off by default on every preset.
		if gizmo.has_method("reset_defaults"):
			gizmo.reset_defaults()
		_dict_to_schema(gizmo, data.get("gizmo", {}))
	if not manager.objects.is_empty():
		manager.select(manager.objects[0])

static func create_object(data: Dictionary, manager: VisualizationManager) -> Node3D:
	var obj: Node3D = null
	match String(data.get("type", "")):
		"PolyMesh":
			obj = manager.add_mesh()
		"PolyParticles":
			obj = manager.add_particles()
		"PolyCloth":
			obj = manager.add_cloth()
		"Influence":
			obj = manager.add_influence()
		_:
			return null
	var p = data.get("position", null)
	if p != null:
		obj.position = Vector3(p[0], p[1], p[2])
	_apply_params(obj, data.get("params", {}))
	return obj

static func _apply_params(obj: Node3D, params: Dictionary) -> void:
	if not obj.has_method("get_param_schema"):
		return
	for section in obj.get_param_schema():
		for prop in section["props"]:
			if prop["type"] == "action":
				continue
			var pn: String = prop["name"]
			if params.has(pn):
				obj.set(pn, _decode(prop["type"], params[pn]))

static func _decode(type: String, raw: Variant) -> Variant:
	match type:
		"color":
			return Color(raw[0], raw[1], raw[2], raw[3])
		"vector3":
			return Vector3(raw[0], raw[1], raw[2])
		"int", "enum":
			return int(raw)
		"colormap_preset":
			return _decode_colormap(raw)
		_:
			return raw

static func _decode_colormap(raw: Variant) -> Variant:
	if raw == null:
		return null
	var cm := GradientColormap.new()
	cm.preset = int(raw.get("preset", 0)) as GradientColormap.Preset
	var offs: Array = raw.get("offsets", [])
	var cols: Array = raw.get("colors", [])
	if offs.size() > 0 and offs.size() == cols.size():
		var g := Gradient.new()
		var po := PackedFloat32Array()
		var pc := PackedColorArray()
		for i in offs.size():
			po.append(offs[i])
			var c: Array = cols[i]
			pc.append(Color(c[0], c[1], c[2], c[3]))
		g.offsets = po
		g.colors = pc
		cm.gradient = g
	return cm

# --- file IO ---------------------------------------------------------------
static func save_json(path: String, data: Dictionary) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK

static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var res = JSON.parse_string(txt)
	return res if res is Dictionary else {}
