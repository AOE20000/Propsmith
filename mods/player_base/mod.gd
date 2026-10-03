extends ModBase
## The game's own base humanoid, registered as the default `player_model`.
##
## Asset: `assets/characters/base_female.vrm` — the SiroinoSotai 素体 wearing the
## 茜犬 (Akane) head. Both are **CC0 1.0** (public domain dedication, no
## attribution required, commercial use and redistribution allowed), so this is
## the one body in the project with no licensing caveat. It ships **enabled**:
## it is the built-in player model, not an optional skin.
##
## It is a mod rather than a hard-coded default because the mod system already
## has the override slot (`player_model`), because a broken contribution then
## costs the player their custom look instead of the game, and because keeping
## the switch here leaves the Configura body reachable — flip `enabled` to false
## in mod.json and the built-in appearance system takes over again.
##
## It carries no animation, which used to be the reason a VRM body sat disabled:
## a T-posed player is worse than a placeholder. `PlayerScene` now covers that
## with a procedural stance (`ModelStance`, attached automatically to any player
## model that has no usable clip), so the missing animation no longer blocks the
## switch. When real clips are retargeted onto the VRM the stance steps aside on
## its own, because it is only attached to unanimated bodies.
##
## Regenerating the model (see docs/local/akane_akayama.md):
##   D:/workbuddy/blender-4.2.23/blender-4.2.23-windows-x64/blender.exe \
##       --background --python tools/models/export_akane_vrm.py
## then copy vendor/models/build/base_female.vrm over the asset below and let
## Godot re-import.

const MODEL_PATH: String = "res://assets/characters/base_female.vrm"


func _on_register() -> void:
	display_name = "基础玩家模型"
	version = "1.0.0"
	author = "propsmith"

	if not ResourceLoader.exists(MODEL_PATH, "PackedScene"):
		push_warning("[mod:player_base] 基准 VRM 未导入或缺失：%s（用 tools/models/export_akane_vrm.py 重新生成）" % MODEL_PATH)
		return
	context.add_player_model(&"base_female", "基础人形（CC0）", _make_model)


func _make_model() -> Node3D:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		push_warning("[mod:player_base] 无法加载 %s" % MODEL_PATH)
		return null
	return packed.instantiate() as Node3D
