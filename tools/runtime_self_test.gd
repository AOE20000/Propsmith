extends Node
## Headless self-test for the two optional scripting integrations.
##
## Why this exists as its own entry point: `smoke_test.ps1` proves the game boots and
## `check_scripts.ps1` proves every file parses, but neither can show that the
## *compatibility layer* answers correctly when the GDExtensions are absent — which
## is the configuration this repository ships in, and the one where a wrong answer is
## silent. Here the answers are asserted instead of assumed.
##
## Why a scene rather than `--script res://tools/runtime_self_test.gd`: Godot does not
## register autoload identifiers in the compilation scope of a `--script` entry
## point. `ScriptBridge` references `Services` and `Events` on purpose, so under
## `--script` it fails to *compile* and the global class becomes unusable — the same
## false positive `check_scripts.ps1` documents. Running as a scene loads the
## autoloads normally, so the bridge is exercised in the configuration the game
## actually uses.
##
## Run with:
##   godot --headless --path . res://tools/runtime_self_test.tscn
## or `pwsh -File tools/check_runtimes.ps1`, which also classifies shutdown noise.
##
## Exits non-zero when a check fails, so it can gate a build.

## Sections are tracked rather than trusted. GDScript has no exceptions, so a hard
## engine error inside a section silently abandons the rest of that section's
## assertions — which would otherwise be reported as a pass. A section only counts as
## run when its body returned normally.
var _sections: Dictionary = {}
var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_run_section("scripting runtime detection", _check_detection)
	_run_section("entry resolution", _check_entry_resolution)
	_run_section("install diagnostics", _check_diagnostics)
	_run_section("script bridge registration", _check_bridge)
	_run_section("boot summary", _check_summary)

	print("")
	for section_name: String in _sections:
		if not bool(_sections[section_name]):
			_failures.append("section '%s' did not run to completion" % section_name)

	if _failures.is_empty():
		print("[selftest] %d checks passed" % _checks)
		get_tree().quit(0)
		return
	for failure: String in _failures:
		printerr("[selftest] FAIL: " + failure)
	print("[selftest] %d checks, %d failed" % [_checks, _failures.size()])
	get_tree().quit(1)


## Detection must answer for both runtimes, must agree with `ClassDB`, and must never
## claim a runtime is loaded when its classes are not registered.
func _check_detection() -> void:
	for key: Variant in ScriptingRuntimes.RUNTIMES.keys():
		var runtime: StringName = key
		var probe: StringName = ScriptingRuntimes.probe_class_for(runtime)
		_expect(probe != &"", "runtime '%s' has no probe class" % runtime)

		var reported: bool = ScriptingRuntimes.is_available(runtime)
		_expect(reported == ClassDB.class_exists(probe), "is_available('%s') disagreed with ClassDB" % runtime)

		var state: String = ScriptingRuntimes.state(runtime)
		_expect(
			state == "loaded" or state == "installed" or state == "absent",
			"state('%s') returned an unknown value '%s'" % [runtime, state]
		)
		# The states must be exclusive in the obvious direction, or a mod author gets
		# told to install something that is already there.
		if reported:
			_expect(state == "loaded", "state('%s') should be 'loaded' when available" % runtime)
		else:
			_expect(state != "loaded", "state('%s') claimed loaded while unavailable" % runtime)
		print("[selftest]   %s -> %s (probe %s)" % [runtime, state, probe])


## A `.lua` entry must map to the Lua runtime and a `.sgd` entry to the sandbox,
## otherwise `ModHost` would try them as GDScript and report a parse error instead of
## the actionable "install this extension" message.
func _check_entry_resolution() -> void:
	_expect(
		ScriptingRuntimes.runtime_for_entry("mod.lua") == ScriptingRuntimes.RUNTIME_LUA,
		"mod.lua did not resolve to the Lua runtime"
	)
	_expect(
		ScriptingRuntimes.runtime_for_entry("mod.sgd") == ScriptingRuntimes.RUNTIME_SANDBOX,
		"mod.sgd did not resolve to the sandbox runtime"
	)
	_expect(ScriptingRuntimes.runtime_for_entry("mod.gd") == &"", "mod.gd must not claim a scripted runtime")
	_expect(ScriptingRuntimes.is_known_entry("mod.gd"), "mod.gd must be a known entry")
	_expect(not ScriptingRuntimes.is_known_entry("mod.cs"), "an unknown entry must not be accepted")

	# `mod.gd` first is a contract a mod relies on while migrating off a scripted
	# language: shipping both must keep the GDScript entry authoritative.
	var precedence: PackedStringArray = ScriptingRuntimes.entry_precedence()
	_expect(precedence[0] == "mod.gd", "mod.gd must be the first entry candidate")
	_expect(precedence.size() == ScriptingRuntimes.ENTRY_FILES.size(), "entry_precedence() lost entries")
	print("[selftest]   precedence: %s" % ", ".join(precedence))

	# The sandbox runs compiled programs, so source has to be told apart from a
	# compiled artifact rather than handed to the VM and failing opaquely.
	_expect(
		ScriptedMod.looks_like_elf(PackedByteArray([0x7F, 0x45, 0x4C, 0x46])),
		"ELF magic was not recognised"
	)
	_expect(
		not ScriptedMod.looks_like_elf("func on_register(game): pass".to_utf8_buffer()),
		"SafeGDScript source was mistaken for a compiled program"
	)
	_expect(not ScriptedMod.looks_like_elf(PackedByteArray()), "an empty program was accepted")


## The failure a mod author actually sees must name the extension and say where to
## put it, not merely report that loading failed.
func _check_diagnostics() -> void:
	for key: Variant in ScriptingRuntimes.RUNTIMES.keys():
		var runtime: StringName = key
		var hint: String = ScriptingRuntimes.install_hint(runtime)
		_expect(
			hint.contains(ScriptingRuntimes.display_name(runtime)),
			"install hint for '%s' does not name it" % runtime
		)
		_expect(hint.contains("res://addons/"), "install hint for '%s' does not say where to put it" % runtime)
		if not ScriptingRuntimes.is_available(runtime):
			print("[selftest]   hint: %s" % hint)


## The bridge is the contract a Lua or sandboxed mod is written against, so it is
## exercised through the calls such a mod would make: register content, attach a
## lifecycle hook, query the world, release, and confirm the content left with the
## owner. Registration goes to a throwaway `ModContext`, so nothing here reaches the
## running game.
func _check_bridge() -> void:
	var context := ModContext.new(&"selftest")
	var bridge := ScriptBridge.new(context, &"selftest")
	_expect(bridge.mod_id() == "selftest", "bridge reported the wrong mod id")

	_expect(bridge.add_prop("selftest_prop", func() -> Mesh: return SphereMesh.new()), "add_prop was refused")
	_expect(bridge.add_item("selftest_item", {"display_name": "自检道具"}), "add_item was refused")
	_expect(
		bridge.add_vehicle("selftest_vehicle", func() -> Node: return VehicleScene.build("selftest")),
		"add_vehicle was refused"
	)
	_expect(
		bridge.add_terrain_modifier("selftest_terrain", func(_x: float, _z: float, height: float, _f: float) -> float: return height),
		"add_terrain_modifier was refused"
	)
	_expect(
		bridge.add_poi("selftest_poi", "自检地标", func() -> Node3D: return Node3D.new()),
		"add_poi was refused"
	)
	# Duplicate ids are refused rather than silently overwriting, the same rule the
	# GDScript path follows.
	_expect(
		not bridge.add_prop("selftest_prop", func() -> Mesh: return SphereMesh.new()),
		"a duplicate prop id was accepted"
	)

	# Unknown events and hooks are refused, which is what stops a sandboxed mod from
	# subscribing to a signal the host never chose to publish.
	_expect(not bridge.watch("player_died_secretly", func(_args: Array) -> void: pass), "an unpublished event was accepted")
	_expect(bridge.watch("poi_discovered", func(_id: Variant, _name: Variant, _pos: Variant) -> void: pass), "a published event was refused")
	_expect(not bridge.on("before_frame", func() -> void: pass), "an unknown hook was accepted")
	_expect(bridge.on("tick", func(_delta: float) -> void: pass), "a known hook was refused")
	_expect(bridge.has_hook("tick"), "the tick hook was not recorded")
	_expect(bridge.hook_names().has("tick"), "hook_names() omitted a registered hook")

	# Hook arguments must arrive positionally and intact — the same shape a ModBase
	# override receives, which is the whole point of the trampolines.
	var seen: Array = []
	bridge.on("world_populate", func(world: Node3D) -> void: seen.append(world == null))
	bridge.invoke_hook("world_populate", [null])
	_expect(seen == [true], "hook arguments were not forwarded positionally (got %s)" % str(seen))

	# And the signal trampolines must preserve arity as well, since that is the path
	# a mod's event handler travels.
	#
	# Observation goes through an `Array` on purpose. A GDScript lambda captures its
	# local environment *by value*, so a handler that assigns to a captured `String`
	# or `int` writes to its own copy and the assertion would fail while the bridge
	# works perfectly — a mistake that costs an afternoon if the comment is missing.
	var watched: Array = []
	bridge.watch("game_saved", func(slot: String) -> void: watched.append(slot))
	Events.game_saved.emit("selftest_slot")
	_expect(watched == ["selftest_slot"], "a watched event did not reach its handler (got %s)" % str(watched))

	# Read-only queries must degrade instead of raising when nothing is ready.
	_expect(bridge.terrain_height(0.0, 0.0) == 0.0, "terrain_height did not degrade to 0.0")
	_expect(bridge.island_falloff(0.0, 0.0) == 0.0, "island_falloff did not degrade to 0.0")
	_expect(
		bridge.watchable_events().size() == ScriptBridge.WATCHABLE.size(),
		"watchable_events() does not match the published table"
	)

	# Registration reached the owning context, which is the point of the bridge.
	_expect(context.item_definitions.has(&"selftest_item"), "bridge registration never reached ModContext")
	_expect(context.vehicle_factories.has(&"selftest_vehicle"), "add_vehicle never reached ModContext")

	bridge.release()
	_expect(not bridge.has_hook("tick"), "release() left a hook attached")

	# Unloading the owner takes everything back out, exactly as for a GDScript mod.
	context.release_all()
	_expect(context.item_definitions.is_empty(), "release_all did not clear the context")
	_expect(context.vehicle_factories.is_empty(), "release_all did not clear vehicle factories")
	_expect(context.terrain_modifiers.is_empty(), "release_all did not clear terrain modifiers")

	_expect(not ScriptBridge.HOOKS.is_empty(), "the hook list is empty")
	_expect(not ScriptBridge.WATCHABLE.is_empty(), "the watchable event list is empty")


## The one line the boot report prints has to stay parseable and name both runtimes,
## or the smoke test's output stops being evidence.
func _check_summary() -> void:
	var summary: String = ScriptingRuntimes.summary()
	for key: Variant in ScriptingRuntimes.RUNTIMES.keys():
		_expect(summary.contains(String(key)), "summary is missing '%s'" % key)
	_expect(summary.contains("="), "summary has no key=value pairs")
	_expect(
		ScriptingRuntimes.describe().size() == ScriptingRuntimes.RUNTIMES.size(),
		"describe() line count does not match the runtime table"
	)
	print("[selftest]   %s" % summary)


func _run_section(section_name: String, body: Callable) -> void:
	print("[selftest] %s" % section_name)
	_sections[section_name] = false
	body.call()
	_sections[section_name] = true


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
