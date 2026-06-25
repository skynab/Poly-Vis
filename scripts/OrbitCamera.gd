@tool
extends Camera3D
## Orbit / pan / zoom camera controller for inspecting visualizations.
##
## Controls:
##   - Middle mouse drag      : orbit around the target
##   - Shift + middle drag     : pan the target
##   - Mouse wheel            : zoom (dolly toward/away from target)
class_name OrbitCamera

@export var target: Vector3 = Vector3.ZERO
@export_range(0.5, 100.0) var distance: float = 6.0
@export_range(0.01, 5.0) var orbit_speed: float = 0.01
@export_range(0.001, 1.0) var pan_speed: float = 0.005
@export_range(1.01, 2.0) var zoom_step: float = 1.1
@export_range(0.5, 50.0) var min_distance: float = 1.0
@export_range(1.0, 500.0) var max_distance: float = 100.0

# Spherical coordinates (radians) around the target.
var _yaw: float = 0.6
var _pitch: float = 0.5
const PITCH_LIMIT := 1.55  # just under PI/2 to avoid gimbal flip

func _ready() -> void:
	_update_transform()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		if Input.is_key_pressed(KEY_SHIFT):
			_pan(event.relative)
		else:
			_orbit(event.relative)
		_update_transform()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance / zoom_step, min_distance, max_distance)
			_update_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * zoom_step, min_distance, max_distance)
			_update_transform()

func _orbit(delta: Vector2) -> void:
	_yaw -= delta.x * orbit_speed
	_pitch = clampf(_pitch - delta.y * orbit_speed, -PITCH_LIMIT, PITCH_LIMIT)

func _pan(delta: Vector2) -> void:
	# Pan relative to the camera's current orientation, scaled by distance.
	var right := global_transform.basis.x
	var up := global_transform.basis.y
	target += (-right * delta.x + up * delta.y) * pan_speed * distance

func _update_transform() -> void:
	var offset := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw)
	) * distance
	global_position = target + offset
	look_at(target, Vector3.UP)
