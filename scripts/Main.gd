extends Node3D
## Root of the Poly-Vis application.
##
## Phase 0 scaffold: holds the camera rig, lighting, and environment.
## Later phases will add the visualization manager, parameter UI, and
## the proximity interaction system here.
class_name Main

func _ready() -> void:
	print("Poly-Vis ready — Phase 0 scaffold.")
