@tool
extends EditorScript
## One-shot generator: load the sample VRM in the editor context (where the
## godot-vrm loader is registered) and save the instantiated avatar as a plain
## `.tscn` the game can load at runtime — runtime Godot has no VRM loader, so
## the scene is the bridge. Run with:
##   godot --headless --editor --path . --script res://tools/generate_vrm_scene.gd


func _run() -> void:
	var source: String = "res://vrm_samples/Godette_vrm_v4.vrm"
	var target: String = "res://vrm_samples/godette_scene.tscn"
	var packed := load(source) as PackedScene
	if packed == null:
		printerr("[vrmgen] FAIL: could not load ", source)
		return
	var model := packed.instantiate() as Node3D
	if model == null:
		printerr("[vrmgen] FAIL: instantiate returned null")
		return
	var scene := PackedScene.new()
	var error := scene.pack(model)
	if error != OK:
		printerr("[vrmgen] FAIL: pack error ", error)
		return
	error = ResourceSaver.save(scene, target)
	if error != OK:
		printerr("[vrmgen] FAIL: save error ", error)
		return
	print("[vrmgen] wrote ", target)
