class_name OptiTrackSkeletonUtil
## Static helper for resolving a named bone's world-space position from the
## Dictionary returned by OptiTrack.get_skeleton_bone_data(asset_id): bone_name
## -> [id, parent_id, position, rotation] (see
## addons/optitrack_plugin/optitrack_skeleton/optitrack_skeleton.gd, which
## consumes the same Dictionary). Only the root bone's position/rotation is in
## world space — every other bone's is relative to its parent — so getting a
## specific joint's world position means walking the hierarchy from the root
## down and composing transforms, mirroring how OptiTrackSkeleton.update_pose()
## feeds this same per-bone data into Skeleton3D's own parent-relative poses.

const _MAX_CHAIN_DEPTH := 64

## Returns the world-space position of `bone_name`, or Vector3.ZERO if the
## dictionary is empty or doesn't contain that bone. Callers should already be
## checking `bones.has(bone_name)` before falling back to a held position, so
## the zero-vector case here is only a defensive floor.
static func bone_world_position(bones: Dictionary, bone_name: String) -> Vector3:
	if bones.is_empty() or not bones.has(bone_name):
		return Vector3.ZERO

	# Walk from the target bone up to the root, collecting the chain, then
	# compose transforms root -> ... -> target.
	var chain: Array[String] = []
	var current: String = bone_name
	var guard := 0
	while current != "" and bones.has(current) and guard < _MAX_CHAIN_DEPTH:
		chain.append(current)
		var parent_id: int = bones[current].get(1)
		current = ""
		if parent_id != -1:
			for name in bones:
				if bones[name].get(0) == parent_id:
					current = name
					break
		guard += 1
	chain.reverse()

	var xform := Transform3D.IDENTITY
	for name in chain:
		var pos: Vector3 = bones[name].get(2)
		var rot: Quaternion = bones[name].get(3)
		xform = xform * Transform3D(Basis(rot), pos)
	return xform.origin
