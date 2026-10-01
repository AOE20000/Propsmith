extends RefCounted
class_name ScriptingRuntimes
## Detection shim for the two scripting GDExtensions this project is built to
## coexist with:
##
##   - Godot Sandbox (libriscv) — SafeGDScript / sandboxed C++ / Rust in a
##     RISC-V VM, hardened for running untrusted player code.
##   - Lua GDExtension (gilzoide) — Lua 5.4 or LuaJIT, with per-state library
##     selection so a mod state can be sandboxed.
##
## Neither is a dependency, and that is the whole point of this file: the project
## boots, plays and passes its headless tests with both absent, and gains the
## extra languages the moment one is dropped into `res://addons/`. A GDExtension
## cannot be referenced from `project.godot` without becoming load-bearing — a
## missing extension then stops the project from loading at all — so presence is
## asked for at runtime instead, through `ClassDB`.
##
## A GDExtension registers its classes when the engine loads it, which is the only
## public signal that it is actually usable. A `.gdextension` file on disk is not
## the same thing: it may have never been imported, or its per-platform binary may
## be missing. `state()` distinguishes those two cases so a mod author is told to
## enable the addon rather than to reinstall it.

const RUNTIME_SANDBOX: StringName = &"godot_sandbox"
const RUNTIME_LUA: StringName = &"lua_gdextension"

## How a runtime is recognised and what it can run. `probe_class` is the type the
## extension registers; `gdextension_paths` are the locations the official
## install instructions produce, used only to tell "not installed" from
## "installed but not loaded".
##
## Values are plain `Array`s, not `PackedStringArray`s, because a GDScript constant
## expression cannot contain a `PackedStringArray(...)` call. The accessors below
## convert, so callers still get the packed type.
const RUNTIMES: Dictionary = {
	RUNTIME_SANDBOX: {
		"display_name": "Godot Sandbox",
		"probe_class": &"Sandbox",
		# `mod.elf` first: that is the runnable artifact. `mod.sgd` is SafeGDScript
		# *source* and only loads after the Sandbox toolchain has compiled it, so a
		# directory shipping the source alone still resolves to this runtime and gets
		# told to compile it, instead of the directory being silently skipped.
		"entry_files": ["mod.elf", "mod.sgd"],
		"gdextension_paths": [
			"res://addons/godot_sandbox/godot_sandbox.gdextension",
			"res://addons/godot-sandbox/godot_sandbox.gdextension",
		],
		"source": "https://github.com/libriscv/godot-sandbox",
	},
	RUNTIME_LUA: {
		"display_name": "Lua GDExtension",
		"probe_class": &"LuaState",
		"entry_files": ["mod.lua"],
		"gdextension_paths": [
			"res://addons/lua-gdextension/lua-gdextension.gdextension",
			"res://addons/lua_gdextension/lua-gdextension.gdextension",
			"res://addons/lua-gdextension/luajit/lua-gdextension.gdextension",
		],
		"source": "https://github.com/gilzoide/lua-gdextension",
	},
}

## The filenames `ModHost` looks for inside a mod directory, in precedence order.
## `mod.gd` first so a GDScript mod always wins its own directory; among the sandbox
## entries the compiled program outranks its source.
const ENTRY_FILES: Array = ["mod.gd", "mod.elf", "mod.sgd", "mod.lua"]


## Entry candidates as a packed array; see the note on `RUNTIMES`.
static func entry_precedence() -> PackedStringArray:
	return PackedStringArray(ENTRY_FILES)


## Whether an extension's classes are registered, i.e. it can actually run code.
static func is_available(runtime: StringName) -> bool:
	var probe_class: StringName = probe_class_for(runtime)
	if probe_class == &"":
		return false
	return ClassDB.class_exists(probe_class)


## The registered class that proves the extension is loaded, or an empty name for
## an unknown runtime.
static func probe_class_for(runtime: StringName) -> StringName:
	var entry: Dictionary = RUNTIMES.get(runtime, {})
	return entry.get("probe_class", &"")


## "loaded", "installed" (files on disk but classes not registered) or "absent".
## The middle state is worth reporting separately: it means the addon is present
## but was never imported, or its binary is missing for this platform.
static func state(runtime: StringName) -> String:
	if is_available(runtime):
		return "loaded"
	for path: String in gdextension_paths_for(runtime):
		if FileAccess.file_exists(path):
			return "installed"
	return "absent"


## Which runtime runs a given entry filename, or an empty name when the file is a
## plain GDScript (or unrecognised).
static func runtime_for_entry(file_name: String) -> StringName:
	for key: Variant in RUNTIMES.keys():
		var runtime: StringName = key
		if entry_filenames(runtime).has(file_name):
			return runtime
	return &""


## The entry filenames a runtime can execute; see the note on `RUNTIMES`.
static func entry_filenames(runtime: StringName) -> PackedStringArray:
	return PackedStringArray((RUNTIMES.get(runtime, {}) as Dictionary).get("entry_files", []))


## Whether `file_name` is an entry this project can attempt to load at all.
static func is_known_entry(file_name: String) -> bool:
	return ENTRY_FILES.has(file_name)


static func display_name(runtime: StringName) -> String:
	return String((RUNTIMES.get(runtime, {}) as Dictionary).get("display_name", runtime))


static func gdextension_paths_for(runtime: StringName) -> PackedStringArray:
	return PackedStringArray(
		(RUNTIMES.get(runtime, {}) as Dictionary).get("gdextension_paths", [])
	)


## Every runtime whose classes are registered right now.
static func available() -> Array[StringName]:
	var out: Array[StringName] = []
	for key: Variant in RUNTIMES.keys():
		var runtime: StringName = key
		if is_available(runtime):
			out.append(runtime)
	return out


## One-line-per-runtime diagnostics for the debug overlay and the boot report.
## Reports all three states, because "installed but not loaded" is the failure a
## mod author is most likely to hit and the hardest to guess from behaviour alone.
static func describe() -> Array[String]:
	var lines: Array[String] = []
	for key: Variant in RUNTIMES.keys():
		var runtime: StringName = key
		var entry: Dictionary = RUNTIMES[runtime]
		lines.append("%s: %s (probe %s)" % [
			entry.get("display_name", runtime), state(runtime), entry.get("probe_class", "?"),
		])
	return lines


## Compact status for a single log line: `godot_sandbox=absent lua_gdextension=absent`.
static func summary() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for key: Variant in RUNTIMES.keys():
		var runtime: StringName = key
		parts.append("%s=%s" % [runtime, state(runtime)])
	return " ".join(parts)


## What a mod author must do to make a mod of this runtime loadable. Written to be
## pasted straight into a failure reason.
static func install_hint(runtime: StringName) -> String:
	var entry: Dictionary = RUNTIMES.get(runtime, {})
	if entry.is_empty():
		return "未知的脚本运行时 '%s'" % runtime
	var name: String = entry.get("display_name", runtime)
	match state(runtime):
		"installed":
			return "%s 的文件已在 res://addons/ 下，但引擎没有加载它的类：请在编辑器中打开一次工程让扩展被导入，并确认该平台的二进制文件存在" % name
		_:
			return "未安装 %s：%s（源码见 %s）" % [name, _install_path(runtime), entry.get("source", "")]


## Where the official install instructions put the addon, phrased as an action.
static func _install_path(runtime: StringName) -> String:
	match runtime:
		RUNTIME_SANDBOX:
			return "把它的 addons/godot_sandbox 复制到 res://addons/，再到 项目设置 → 插件 启用"
		RUNTIME_LUA:
			return "把它的 addons/lua-gdextension 复制到 res://addons/，再到 项目设置 → 插件 启用"
	return "把它的 addons/ 目录复制到 res://addons/，再到 项目设置 → 插件 启用"
