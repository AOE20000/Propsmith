extends ModBase
class_name ScriptedMod
## Hosts one mod written in a language other than GDScript — Lua through Lua
## GDExtension, or SafeGDScript / sandboxed C++ / Rust through Godot Sandbox.
##
## It exists so that a scripted mod is not a second-class citizen: `ModHost`
## creates it through the same path as a GDScript mod, gives it the same
## `ModContext`, and the loader's id-collision, ordering, unload and persistence
## rules apply unchanged. The only difference is where the registration calls come
## from.
##
## Runtime classes are instantiated by name through `ClassDB`, never named as
## types. That is the same trick the terrain backend uses for Terrain3D and it is
## load-bearing here: a script that mentions `LuaState` or `Sandbox` as a type
## fails to *parse* when the extension is not installed, which would turn an
## optional integration into a hard dependency on both.
##
## Entry contract, deliberately identical for both runtimes:
##   - the mod's code is run once, with `game` (a `ScriptBridge`) already in scope;
##   - it registers content immediately, or from an exported `on_register(game)`;
##   - it subscribes to lifecycle hooks through `game:on("world_populate", fn)`,
##     because a scripted mod cannot override a GDScript method.
##
## `ModHost` only constructs this class after confirming the runtime's classes are
## registered, so the checks below are defects rather than user error and are
## reported as such.

## Which `ScriptingRuntimes` runtime this mod runs on.
var runtime: StringName = &""
## Path of the entry file inside the mod directory (`mod.lua`, `mod.sgd`, ...).
var source_path: String = ""
## Entry filename, kept for diagnostics.
var entry_file: String = ""
## The API surface handed to the mod. Held as a strong reference for the mod's
## whole lifetime: the bridged signal connections point into it.
var bridge: ScriptBridge = null

var _instance: Object = null
var _started: bool = false
var _start_error: String = ""


## Called by `ModHost` before `_on_register`.
func configure(mod_runtime: StringName, mod_source_path: String, mod_entry_file: String) -> void:
	runtime = mod_runtime
	source_path = mod_source_path
	entry_file = mod_entry_file


func is_started() -> bool:
	return _started


## Non-empty when the runtime was present but the mod could not be run.
func start_error() -> String:
	return _start_error


func _on_register() -> void:
	bridge = ScriptBridge.new(context, runtime)
	match runtime:
		ScriptingRuntimes.RUNTIME_LUA:
			_started = _start_lua()
		ScriptingRuntimes.RUNTIME_SANDBOX:
			_started = _start_sandbox()
		_:
			_started = false
			_start_error = "未知的脚本运行时 '%s'" % runtime
	if not _started and _start_error.is_empty():
		_start_error = "%s 没有成功启动" % ScriptingRuntimes.display_name(runtime)
	if not _started:
		push_error("[ModHost] %s: %s" % [mod_id, _start_error])
		return
	log_message("已通过 %s 启动 (%s)" % [
		ScriptingRuntimes.display_name(runtime), entry_file,
	])


## Lifecycle forwarding. Every hook is funnelled through the bridge's single
## handler list, so the Lua and the sandbox path need no runtime-specific code
## here.
func _on_world_generate(world: Node3D) -> void:
	_invoke(&"world_generate", [world])


func _on_world_populate(world: Node3D) -> void:
	_invoke(&"world_populate", [world])


func _on_player_spawn(player: Node3D) -> void:
	_invoke(&"player_spawn", [player])


func _on_tick(delta: float) -> void:
	_invoke(&"tick", [delta])


func _on_unload() -> void:
	_invoke(&"unload", [])
	if bridge != null:
		bridge.release()


## The instance driving the mod, for diagnostics and tests.
func runtime_instance() -> Object:
	return _instance


func _invoke(hook_name: StringName, args: Array) -> void:
	if bridge == null or not _started:
		return
	bridge.invoke_hook(String(hook_name), args)


## Lua path: create the state, expose `game`, then run the file. Registration is
## expected to happen while the file executes, which is the idiomatic Lua shape and
## avoids the host having to call back into a table it has not seen yet.
func _start_lua() -> bool:
	var state: Object = ClassDB.instantiate(&"LuaState")
	if state == null:
		_start_error = "LuaState 实例化失败 — 扩展可能没有为该平台提供二进制文件"
		return false
	_instance = state

	# Opened with the extension's own defaults. Note what this is and is not: the
	# *Godot* side of the integration is deliberately absent — nothing here opens the
	# extension's `godot` library — so a Lua mod cannot reach engine classes and the
	# bridge stays its only door. The plain Lua libraries are a different matter:
	# `open_libraries()` with no argument opens the extension's default set, which
	# may include `io`/`os`. A host that wants a mod confined to the bridge should
	# pass an explicit subset of `LuaLibrary` values here. That requires the
	# extension to be installed to name the enum, which is why it is left as the
	# documented default rather than guessed at.
	if state.has_method("open_libraries"):
		state.call("open_libraries")

	var globals: Variant = state.get("globals")
	if globals == null or not (globals is Object):
		_start_error = "LuaState.globals 不可用，无法把 game 暴露给 mod"
		return false

	# `game` is the mod's only door into the host. Everything it can do is a method
	# on ScriptBridge, which is why the bridge is the compatibility contract rather
	# than a convenience.
	(globals as Object)["game"] = bridge

	if not state.has_method("do_file"):
		_start_error = "LuaState 缺少 do_file，无法运行 %s" % entry_file
		return false
	var result: Variant = state.call("do_file", source_path)
	if _is_lua_error(result):
		_start_error = "Lua 运行 %s 失败: %s" % [entry_file, str(result)]
		return false

	# Optional explicit entry point, for mods that prefer a function over top-level
	# statements. Absent is the normal case, not an error.
	var entry: Variant = (globals as Object)["on_register"]
	if entry != null and (entry is Callable):
		(entry as Callable).call(bridge)
	elif entry != null and entry is Object and (entry as Object).has_method("call"):
		(entry as Object).call("call", bridge)
	return true


## Sandboxed path: load the program into a VM, then call its exported
## `on_register(game)`. `vmcallable` doubles as the existence check, so a program
## that exports no entry point is reported rather than raising from inside the VM.
func _start_sandbox() -> bool:
	var sandbox: Object = ClassDB.instantiate(&"Sandbox")
	if sandbox == null:
		_start_error = "Sandbox 实例化失败 — 扩展可能没有为该平台提供二进制文件"
		return false
	_instance = sandbox

	# A Sandbox is a Node; giving it a home in the tree is what keeps its lifetime
	# tied to the session instead of to this RefCounted.
	if sandbox is Node:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree != null:
			tree.root.add_child(sandbox as Node)

	var file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		_start_error = "无法读取 %s (%s)" % [source_path, error_string(FileAccess.get_open_error())]
		return false
	var program: PackedByteArray = file.get_buffer(file.get_length())
	file.close()

	# A `.sgd` is source, not bytecode: the Sandbox toolchain compiles it into an ELF
	# program first. Checked here rather than left to the VM, because handing raw text
	# to `load()` produces a failure that says nothing about what to do next.
	if not looks_like_elf(program):
		_start_error = (
			"%s 不是已编译的程序（缺少 ELF 头）。Godot Sandbox 运行的是编译产物："
			+ "请先用它的工具链把 SafeGDScript / C++ / Rust 源码编译成 ELF，"
			+ "并把产物命名为 mod.elf 放进本 mod 目录"
		) % entry_file
		return false

	if not sandbox.has_method("load"):
		_start_error = "Sandbox 缺少 load，无法载入 %s" % entry_file
		return false
	# An empty argument list: the program receives nothing but Variants the host
	# later hands it, which is the whole point of the sandbox.
	sandbox.call("load", program, [])

	if not sandbox.has_method("vmcallable"):
		_start_error = "Sandbox 缺少 vmcallable，无法查找 on_register"
		return false
	var entry: Variant = sandbox.call("vmcallable", "on_register")
	if not (entry is Callable) or not (entry as Callable).is_valid():
		_start_error = "%s 没有导出 on_register(game)" % entry_file
		return false
	(entry as Callable).call(bridge)
	return true


## Lua GDExtension returns errors in-band as a `LuaError` value. Matching on the
## class name keeps this file free of a type that only exists when the extension
## is loaded.
func _is_lua_error(value: Variant) -> bool:
	if not (value is Object):
		return false
	return String((value as Object).get_class()) == "LuaError"


## ELF magic (`\x7FELF`). A four-byte check is enough to tell a compiled program
## from the SafeGDScript source it was compiled from. Public so the compatibility
## self test can assert it without instantiating a sandbox.
static func looks_like_elf(program: PackedByteArray) -> bool:
	if program.size() < 4:
		return false
	return program[0] == 0x7F and program[1] == 0x45 and program[2] == 0x4C and program[3] == 0x46


func _to_string() -> String:
	return "ScriptedMod(%s v%s via %s)" % [mod_id, version, runtime]
