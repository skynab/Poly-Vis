extends RefCounted
## Physical/pixel description of the LED wall the visualization is displayed on.
##
## The app is meant to render onto an LED wall while a real object (tracked by
## OptiTrack) moves in front of it. To place the influence where the object
## physically is on the wall, we need the wall's real size (metres) and its pixel
## resolution. This schema-driven global module (like SceneEnvironment / HudLogo)
## holds those numbers, applies the resolution to the window, and converts a
## physical position to a normalized screen coordinate.
##
## Editable in the ParameterPanel and serialized by CompositionIO under "wall".
class_name WallConfig

## Physical wall size in metres.
var physical_width: float = 3.0
var physical_height: float = 2.0
## Native pixel resolution of the wall (the app should render at this size).
var pixel_width: int = 1920
var pixel_height: int = 1080
## Physical centre of the wall in OptiTrack/world metres — the tracked object's
## position is measured relative to this when mapping onto the wall.
var origin: Vector3 = Vector3.ZERO

func reset_defaults() -> void:
	physical_width = 3.0
	physical_height = 2.0
	pixel_width = 1920
	pixel_height = 1080
	origin = Vector3.ZERO

## Action: resize the app window to the wall's native pixel resolution so the
## render maps 1:1 to the LED panels. (Combine with F11 fullscreen on the wall's
## display for a borderless output.)
func apply_resolution() -> void:
	if pixel_width > 0 and pixel_height > 0:
		DisplayServer.window_set_size(Vector2i(pixel_width, pixel_height))

## Map a physical position (metres, OptiTrack/world space) to a normalized screen
## coordinate [0,1] across the wall: X → horizontal, Y → vertical (Y measured up,
## screen V flipped). Used by InfluenceController to place a tracked influence at
## the object's real spot on the rendered wall.
func physical_to_uv(world_metres: Vector3) -> Vector2:
	var local := world_metres - origin
	var u := 0.5 + local.x / maxf(physical_width, 0.0001)
	var v := 0.5 - local.y / maxf(physical_height, 0.0001)
	return Vector2(u, v)

## Pixel aspect ratio (width / height), e.g. for matching the camera framing.
func aspect() -> float:
	return float(pixel_width) / float(pixel_height) if pixel_height != 0 else 1.0

func get_param_schema() -> Array:
	return [{
		"title": "LED Wall",
		"props": [
			{"name": "physical_width", "type": "float", "min": 0.1, "max": 50.0, "step": 0.05,
				"hint": "Wall width in metres"},
			{"name": "physical_height", "type": "float", "min": 0.1, "max": 50.0, "step": 0.05,
				"hint": "Wall height in metres"},
			{"name": "pixel_width", "type": "int_field", "min": 1, "max": 16384, "step": 1,
				"hint": "Wall horizontal resolution"},
			{"name": "pixel_height", "type": "int_field", "min": 1, "max": 16384, "step": 1,
				"hint": "Wall vertical resolution"},
			{"name": "origin", "type": "vector3", "hint": "Physical wall centre (metres)"},
			{"name": "apply_resolution", "type": "action", "label": "Apply Resolution to Window",
				"hint": "Resize the window to the wall's pixel resolution"},
		]
	}]
