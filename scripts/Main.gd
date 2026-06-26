extends Node3D
## Root of the Poly-Vis application.
##
## Wires the visualization manager, camera, parameter panel, influence
## controller, and capture manager together.
class_name Main

@onready var manager: VisualizationManager = $VisualizationManager
@onready var camera: Camera3D = $Camera3D
@onready var panel: ParameterPanel = $UI/ParameterPanel
@onready var influence: InfluenceController = $InfluenceController

var capture: CaptureManager

func _ready() -> void:
	capture = CaptureManager.new()
	capture.name = "CaptureManager"
	capture.ui_layer = $UI
	add_child(capture)
	panel.setup(manager, camera, capture)
	influence.setup(manager, camera)
