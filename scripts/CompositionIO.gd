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
		scene: Object = null, hud: Object = null, gizmo: Object = null,
		wall: Object = null, audio: Object = null, influence_ctrl: Object = null,
		postfx: Object = null, skel_bind: Object = null) -> Dictionary:
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
	if wall and wall.has_method("get_param_schema"):
		result["wall"] = _schema_to_dict(wall)
	if audio and audio.has_method("get_param_schema"):
		result["audio"] = _schema_to_dict(audio)
	if influence_ctrl and influence_ctrl.has_method("get_param_schema"):
		result["auto_bind"] = _schema_to_dict(influence_ctrl)
	if postfx and postfx.has_method("get_param_schema"):
		result["postfx"] = _schema_to_dict(postfx)
	if skel_bind and skel_bind.has_method("get_param_schema"):
		result["skeleton_bind"] = _schema_to_dict(skel_bind)
	return result

## Encode every schema property of a single object into a flat Dictionary.
static func _schema_to_dict(obj: Object) -> Dictionary:
	var d := {}
	if obj and obj.has_method("get_param_schema"):
		for section in obj.get_param_schema():
			for prop in section["props"]:
				if prop["type"] == "action" or prop["type"] == "status":
					continue  # buttons / status readouts carry no value to serialize
				if not prop.get("serialize", true):
					continue  # session-only preference (e.g. lock_background)
				d[prop["name"]] = _encode(prop["type"], obj.get(prop["name"]))
	return d

## Decode a flat Dictionary back onto a single object's schema properties.
static func _dict_to_schema(obj: Object, d: Dictionary) -> void:
	if obj == null or not obj.has_method("get_param_schema"):
		return
	for section in obj.get_param_schema():
		for prop in section["props"]:
			if prop["type"] == "action" or prop["type"] == "status":
				continue
			if not prop.get("serialize", true):
				continue  # session-only preference (e.g. lock_background)
			var pn: String = prop["name"]
			if d.has(pn):
				obj.set(pn, _decode(prop["type"], d[pn]))

static func serialize_object(obj: Node3D, type_label: String) -> Dictionary:
	var params := {}
	if obj.has_method("get_param_schema"):
		for section in obj.get_param_schema():
			for prop in section["props"]:
				if prop["type"] == "action" or prop["type"] == "status":
					continue
				var pn: String = prop["name"]
				params[pn] = _encode(prop["type"], obj.get(pn))
	# Rotation is stored in degrees (Euler) for readable hand-authored presets.
	return {"type": type_label, "position": _v3(obj.position),
			"rotation": _v3(obj.rotation_degrees), "params": params}

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
		scene: Object = null, hud: Object = null, gizmo: Object = null,
		wall: Object = null, audio: Object = null, influence_ctrl: Object = null,
		postfx: Object = null, skel_bind: Object = null) -> void:
	manager.clear_all()
	for od in data.get("objects", []):
		create_object(od, manager)
	_dict_to_schema(camera, data.get("camera", {}))
	if scene and not scene.get("lock_background"):
		# Reset first so a composition with no "scene" block restores the
		# default white room instead of inheriting the previous bloom/bg.
		# Skipped entirely when lock_background is on, so the current backdrop
		# carries across preset/composition loads.
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
	if wall:
		# Wall config is installation hardware, not part of a visual — presets carry
		# no "wall" block, so loading one resets to the default wall dimensions.
		if wall.has_method("reset_defaults"):
			wall.reset_defaults()
		_dict_to_schema(wall, data.get("wall", {}))
	if audio:
		# Same pattern: presets carry no "audio" block, so a live mic/beat tap
		# from a previous session never survives a preset/composition load.
		if audio.has_method("reset_defaults"):
			audio.reset_defaults()
		_dict_to_schema(audio, data.get("audio", {}))
	if influence_ctrl:
		# Same pattern: presets carry no "auto_bind" block, so auto-bind resets
		# off on load (objects were already cleared above, taking any
		# auto-spawned influences with them).
		if influence_ctrl.has_method("reset_defaults"):
			influence_ctrl.reset_defaults()
		_dict_to_schema(influence_ctrl, data.get("auto_bind", {}))
	if postfx:
		# Same pattern: presets carry no "postfx" block, so a previous session's
		# vignette/grain/grade never survives a preset/composition load.
		if postfx.has_method("reset_defaults"):
			postfx.reset_defaults()
		_dict_to_schema(postfx, data.get("postfx", {}))
	if skel_bind:
		# Same pattern: presets carry no "skeleton_bind" block, so skeleton auto-bind
		# resets off on load (objects were already cleared above, taking any
		# auto-spawned bone influences with them).
		if skel_bind.has_method("reset_defaults"):
			skel_bind.reset_defaults()
		_dict_to_schema(skel_bind, data.get("skeleton_bind", {}))
	if not manager.objects.is_empty():
		manager.select(manager.objects[0])

static func create_object(data: Dictionary, manager: VisualizationManager) -> Node3D:
	var obj: Node3D = null
	# Undo-free spawns: loading/duplicating a composition must not flood the undo
	# history with a per-object add step (and recreation during undo/redo of a
	# single add/remove must not nest a new action).
	match String(data.get("type", "")):
		"PolyMesh":
			obj = manager.spawn_mesh()
		"PolyParticles":
			obj = manager.spawn_particles()
		"PolyCloth":
			obj = manager.spawn_cloth()
		"PolyTrails":
			obj = manager.spawn_trails()
		"PolyMetaballs":
			obj = manager.spawn_metaballs()
		"PolyStrands":
			obj = manager.spawn_strands()
		"PolyBoids":
			obj = manager.spawn_boids()
		"Influence":
			obj = manager.spawn_influence()
		_:
			return null
	var p = data.get("position", null)
	if p != null:
		obj.position = Vector3(p[0], p[1], p[2])
	var r = data.get("rotation", null)  # Euler degrees; absent on older comps
	if r != null:
		obj.rotation_degrees = Vector3(r[0], r[1], r[2])
	_apply_params(obj, data.get("params", {}))
	return obj

static func _apply_params(obj: Node3D, params: Dictionary) -> void:
	if not obj.has_method("get_param_schema"):
		return
	for section in obj.get_param_schema():
		for prop in section["props"]:
			if prop["type"] == "action" or prop["type"] == "status":
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
		"int", "int_field", "enum":
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
