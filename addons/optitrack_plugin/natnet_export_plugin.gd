@tool
extends EditorExportPlugin
## Force-bundles NatNetLib.dll alongside the exported Windows binary.
##
## NatNetLib.dll is a load-time dependency of OptiTrack-plugin.windows...dll (the
## GDExtension). Godot's built-in GDExtension dependency copy (the [dependencies]
## block in optitrack-plugin.gdextension) is unreliable on Windows and was leaving
## the DLL out of exports, so the extension failed to load and OptiTrack tracking
## was unavailable in the exported build. This plugin copies it explicitly via
## add_shared_object(), which on desktop places the file next to the .exe.
##
## Registered by optitrack_plugin.gd's _enter_tree (add_export_plugin) and removed
## in _exit_tree.

const NATNET_DLL := "res://addons/optitrack_plugin/bin/NatNetLib.dll"

func _get_name() -> String:
	return "OptiTrackNatNetDependency"

func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	# Only Windows builds need the NatNet runtime DLL.
	if not features.has("windows"):
		return
	if not FileAccess.file_exists(NATNET_DLL):
		push_warning("NatNetLib.dll not found at %s — OptiTrack will not work in this export." % NATNET_DLL)
		return
	# Empty target_path: on desktop the shared object is placed in the same
	# directory as the exported executable.
	add_shared_object(NATNET_DLL, [], "")
