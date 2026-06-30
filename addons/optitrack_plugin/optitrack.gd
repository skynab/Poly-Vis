@tool
extends Node
## Portable OptiTrack autoload.
##
## The NatNet/Motive GDExtension only ships a Windows binary, so its native
## `MotiveClient` class isn't registered on macOS / Linux (or in a Windows export
## without the DLL). GDScript resolves `extends MotiveClient` at *parse* time, so a
## script that inherits it fails to even compile off-Windows:
##     Error at (1, 9): Could not find base class "MotiveClient".
## An `if OS.get_name() == ...` guard can't fix that — `extends` is compile-time,
## and the script never compiles far enough to reach any runtime check.
##
## So instead of *inheriting* MotiveClient this autoload *composes* it: it extends
## Node and creates a MotiveClient instance only when the class actually exists
## (ClassDB.class_exists). Every method Poly-Vis and the editor sub-plugins call is
## forwarded to that instance, returning a safe default when it's absent. Result:
## identical behaviour everywhere — full tracking on Windows, graceful no-op on
## Mac / Ubuntu and in DLL-less exports, with no parse error.

var settings : OptiTrackSettings
# MotiveClient instance on Windows (when the GDExtension is loaded), else null.
# Left untyped so the forwarded `_client.<method>()` calls dispatch dynamically and
# the script still compiles on platforms where MotiveClient doesn't exist.
var _client = null

func _init() -> void:
	if ClassDB.class_exists("MotiveClient"):
		_client = ClassDB.instantiate("MotiveClient")
	settings = ResourceLoader.load("res://addons/optitrack_plugin/optitrack_settings.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	# Without the native client there's nothing to connect to — bail out cleanly.
	if _client == null:
		return

	# load settings from settings resource
	set_server_address(settings.server_address)
	set_client_address(settings.client_address)
	set_multicast(settings.multicast)

	# Inside the editor the OptiTrack control-panel dock drives the connection (as
	# the original non-tool autoload did — its _init never ran in-editor). Only
	# auto-connect at runtime.
	if Engine.is_editor_hint():
		return

	connect_to_motive()

	# fetch data descriptions, important so skeletons animate
	get_skeleton_assets()

# --- forwarded MotiveClient API --------------------------------------------
# Each call hits the native client on Windows, or returns a harmless default when
# the GDExtension isn't present. The conditional expression short-circuits, so the
# `_client.<method>()` side is never evaluated while _client is null.

func is_connected_to_motive() -> bool:
	return _client.is_connected_to_motive() if _client != null else false

func connect_to_motive() -> void:
	if _client != null:
		_client.connect_to_motive()

func disconnect_from_motive() -> void:
	if _client != null:
		_client.disconnect_from_motive()

func set_server_address(address: String) -> void:
	if _client != null:
		_client.set_server_address(address)

func get_server_address() -> String:
	return _client.get_server_address() if _client != null else ""

func set_client_address(address: String) -> void:
	if _client != null:
		_client.set_client_address(address)

func get_client_address() -> String:
	return _client.get_client_address() if _client != null else ""

func set_multicast(enabled: bool) -> void:
	if _client != null:
		_client.set_multicast(enabled)

func get_multicast() -> bool:
	return _client.get_multicast() if _client != null else false

func get_rigid_body_pos(asset_id: int) -> Vector3:
	return _client.get_rigid_body_pos(asset_id) if _client != null else Vector3.ZERO

func get_rigid_body_rot(asset_id: int) -> Quaternion:
	return _client.get_rigid_body_rot(asset_id) if _client != null else Quaternion.IDENTITY

func get_rigid_body_assets() -> Dictionary:
	return _client.get_rigid_body_assets() if _client != null else {}

func get_skeleton_assets() -> Dictionary:
	return _client.get_skeleton_assets() if _client != null else {}

func get_skeleton_bone_data(asset_id: int):
	return _client.get_skeleton_bone_data(asset_id) if _client != null else {}

func timeline_play() -> void:
	if _client != null:
		_client.timeline_play()

func timeline_stop() -> void:
	if _client != null:
		_client.timeline_stop()
