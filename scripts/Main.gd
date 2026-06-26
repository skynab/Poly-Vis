extends Node3D
## Root of the Poly-Vis application.
##
## Instantiates and wires all runtime systems: visualization manager, camera,
## parameter panel, influence controller, capture manager, undo history,
## selection gizmo, and keyboard input manager.
class_name Main

@onready var manager: VisualizationManager = $VisualizationManager
@onready var camera: Camera3D = $Camera3D
@onready var panel: ParameterPanel = $UI/ParameterPanel
@onready var influence: InfluenceController = $InfluenceController
@onready var world_env: WorldEnvironment = $WorldEnvironment

var capture: CaptureManager
var undo: UndoHistory
var gizmo: SelectionGizmo
var input_mgr: InputManager
var scene_env: SceneEnvironment
var _fps_label: Label

func _ready() -> void:
	# Capture manager — hides the UI layer during still screenshots.
	capture = CaptureManager.new()
	capture.name = "CaptureManager"
	capture.ui_layer = $UI
	add_child(capture)

	# Undo/redo history — shared by the panel and the input manager.
	undo = UndoHistory.new()
	undo.history_changed.connect(func(): panel.show_object(manager.selected))

	# Selection gizmo — lives in the 3D world alongside visualized objects.
	gizmo = SelectionGizmo.new()
	gizmo.name = "SelectionGizmo"
	$VisualizationManager.add_child(gizmo)
	manager.selection_changed.connect(gizmo.select)

	# Keyboard shortcut handler.
	input_mgr = InputManager.new()
	input_mgr.name = "InputManager"
	add_child(input_mgr)

	# FPS counter — top-left corner of viewport.
	_fps_label = Label.new()
	_fps_label.position = Vector2(10, 10)
	_fps_label.add_theme_font_size_override("font_size", 12)
	_fps_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.6))
	$UI.add_child(_fps_label)

	# Scene environment wrapper — schema-driven bg color + bloom, serialized
	# alongside the camera so presets can ship a dark room for neon visuals.
	scene_env = SceneEnvironment.new()
	scene_env.bind(world_env.environment)

	panel.setup(manager, camera, capture, undo, scene_env)
	influence.setup(manager, camera)
	input_mgr.setup(manager, camera, panel, undo)

func _process(_delta: float) -> void:
	_fps_label.text = "FPS  %d" % Engine.get_frames_per_second()
