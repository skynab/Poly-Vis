extends Node3D
## Root of the Poly-Vis application.
##
## Wires the visualization manager, camera, and parameter panel together.
class_name Main

@onready var manager: VisualizationManager = $VisualizationManager
@onready var camera: Node = $Camera3D
@onready var panel: ParameterPanel = $UI/ParameterPanel

func _ready() -> void:
	panel.setup(manager, camera)
