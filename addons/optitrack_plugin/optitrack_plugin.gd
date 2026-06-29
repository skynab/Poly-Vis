@tool
extends EditorPlugin

const AUTOLOAD_NAME = "OptiTrack"
const PLUGIN_FOLDER = "optitrack_plugin"

func _enable_plugin() -> void:
	# Add autoloads here.
	add_autoload_singleton(AUTOLOAD_NAME, "optitrack.gd")
	
	# Enable sub-plugins
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_control_panel", true)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_rigid_body", true)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_rigid_body_inspector", true)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_skeleton", true)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_skeleton_inspector", true)


func _disable_plugin() -> void:
	# Disable sub-plugins
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_control_panel", false)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_rigid_body", false)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_rigid_body_inspector", false)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_skeleton", false)
	EditorInterface.set_plugin_enabled(PLUGIN_FOLDER + "/optitrack_skeleton_inspector", false)
	
	# Remove autoloads here.
	remove_autoload_singleton(AUTOLOAD_NAME)

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	# Force-bundle NatNetLib.dll with Windows exports (Godot's GDExtension
	# dependency copy drops it, breaking OptiTrack in exported builds).
	_export_plugin = preload("res://addons/optitrack_plugin/natnet_export_plugin.gd").new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
