extends Node3D
## Root of the Poly-Vis application.
##
## Wires the visualization manager, camera, and parameter panel together.
class_name Main

@onready var manager: VisualizationManager = $VisualizationManager
@onready var camera: Camera3D = $Camera3D
@onready var panel: ParameterPanel = $UI/ParameterPanel
@onready var influence: InfluenceController = $InfluenceController

func _ready() -> void:
	panel.setup(manager, camera)
	influence.setup(manager, camera)
