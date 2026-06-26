extends Node
## Screenshot export and image-sequence recorder (Prompt 6.2).
##
## Attach to Main. Set ui_layer so the panel hides during still captures.
## capture() defers one frame so the 3D scene is fully rendered before grab.
## start_recording() writes numbered PNGs to user://sequence_TIMESTAMP/.
class_name CaptureManager

signal screenshot_saved(path: String)
signal recording_started(dir: String)
signal recording_stopped(frame_count: int, dir: String)

var ui_layer: CanvasLayer = null

var _recording := false
var _frame := 0
var _fps := 24
var _dir := ""
var _accum := 0.0

# ---------------------------------------------------------------------------
func capture(scale: int = 1) -> void:
	_set_ui(false)
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	_set_ui(true)
	if scale > 1:
		img.resize(img.get_width() * scale, img.get_height() * scale,
				Image.INTERPOLATE_LANCZOS)
	var ts := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "user://screenshot_%s.png" % ts
	img.save_png(path)
	screenshot_saved.emit(path)

# ---------------------------------------------------------------------------
func start_recording(fps: int = 24) -> String:
	if _recording:
		stop_recording()
	_fps = fps
	_frame = 0
	_accum = 0.0
	var ts := Time.get_datetime_string_from_system().replace(":", "-")
	_dir = "user://sequence_%s" % ts
	DirAccess.make_dir_absolute(_dir)
	_recording = true
	recording_started.emit(_dir)
	return _dir

func stop_recording() -> void:
	if not _recording:
		return
	_recording = false
	recording_stopped.emit(_frame, _dir)

func is_recording() -> bool:
	return _recording

func frame_count() -> int:
	return _frame

# ---------------------------------------------------------------------------
func _set_ui(visible: bool) -> void:
	if ui_layer:
		ui_layer.visible = visible

func _process(delta: float) -> void:
	if not _recording:
		return
	_accum += delta
	var interval := 1.0 / _fps
	while _accum >= interval:
		_accum -= interval
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/frame_%05d.png" % [_dir, _frame])
		_frame += 1
