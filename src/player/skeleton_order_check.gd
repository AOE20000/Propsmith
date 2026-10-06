extends RefCounted
class_name SkeletonOrderCheck
## Whether a skeleton honours Godot's bone-ordering contract.
##
## ## The contract
##
## `Skeleton3D.get_bone_parent`'s own documentation states it: *"The parent bone
## returned will always be less than bone_idx."* Every engine path that resolves
## a bone's global transform relies on that ordering — most explicitly the
## nested-set rewrite in [PR #97538], whose comment says *"The order also
## ensures, that parent bone poses are calculated before child bone poses"* and
## whose author noted that for imported scenes the nesting *"seems to be the same
## as the bone index. **Presumably** bones are already ordered this way."*
##
## That presumption is false for VRM imports. A VRM's node hierarchy and its
## joint list are authored separately, and Godot's importer builds the bone list
## by walking the node tree — so `Root` can land *after* `Hips` even though it is
## the parent. The consequence is not a crash: rotations still read correctly (a
## reversed link does not change an axis), but *translations get scaled by the
## wrong accumulated rest*, because the nested-set span a bone belongs to no
## longer covers the chain it is actually in.
##
## ## Measured on the shipped figure
##
## A bone-local offset of `(0, −0.1, 0)` written on the hips landed **0.32 m**
## below in world space — the right direction, three times too far. The same
## write on a foot, whose chain is ordered, landed exactly 0.1 m. A pelvis
## compensation sized at 0.12 m therefore did nothing to the body while growing
## every frame, which is what the playtest saw as the figure sinking and its legs
## trailing behind.
##
## ## What this class does
##
## Reports the disorder and names the affected bones, so a model can be checked
## at load and reported rather than silently misbehaving. It does **not**
## reorder anything: `Skeleton3D` exposes no supported way to renumber a bone
## list, and rebuilding the skeleton is a bigger decision than this component
## should make on its own.

## Bones whose parent index is greater than their own — the ones whose world
## translation cannot be trusted.
var reversed: PackedInt32Array = PackedInt32Array()
## Total bones inspected.
var bone_count: int = 0
## Bones on correctly ordered chains. Everything except `reversed`.
var well_ordered: int = 0
## Bone names, captured at inspection so the report can name bones without
## holding a reference to the skeleton (which may be freed under us).
var names: PackedStringArray = PackedStringArray()
## Parent index per bone, captured alongside the names for the same reason.
var parents: PackedInt32Array = PackedInt32Array()


func _init(skeleton: Skeleton3D = null) -> void:
	if skeleton != null:
		inspect(skeleton)


## Scan `skeleton` and record every reversed parent link.
func inspect(skeleton: Skeleton3D) -> void:
	reversed = PackedInt32Array()
	names = PackedStringArray()
	parents = PackedInt32Array()
	bone_count = skeleton.get_bone_count()
	well_ordered = 0
	for i: int in bone_count:
		names.append(skeleton.get_bone_name(i))
		parents.append(skeleton.get_bone_parent(i))
	for i: int in bone_count:
		var parent: int = parents[i]
		if parent >= 0 and parent > i:
			reversed.append(i)
		else:
			well_ordered += 1


## Whether the skeleton satisfies the contract. A true result means every
## bone's global translation can be read and written as world space.
func is_valid() -> bool:
	return reversed.is_empty()


## A one-line description naming the affected bones — for a log line, and enough
## to tell one rig's disorder from another's.
func describe() -> String:
	if is_valid():
		return "SkeletonOrderCheck: %d bones, all correctly ordered" % bone_count
	var parts: Array[String] = []
	for i: int in mini(reversed.size(), 6):
		parts.append("%s(%d) -> %s(%d)" % [
			name_of(reversed[i]), reversed[i],
			name_of(parents[reversed[i]]), parents[reversed[i]],
		])
	var more := "" if reversed.size() <= 6 else ", +%d more" % (reversed.size() - 6)
	return "SkeletonOrderCheck: %d of %d bones have a reversed parent link: %s%s" % [
		reversed.size(), bone_count, ", ".join(parts), more,
	]


func name_of(index: int) -> String:
	if index < 0:
		return "<root>"
	if index < names.size():
		return names[index]
	return "bone#%d" % index