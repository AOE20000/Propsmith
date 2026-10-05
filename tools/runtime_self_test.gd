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

## Sections are declared with the exact number of assertions each must run.
##
## GDScript errors abort only the function that raised them, so `body.call()` returns
## normally even when the body died halfway — a flag set after the call cannot detect a
## truncated section, which is how a broken section once reported "all checks passed".
## Counting what actually ran catches both a hard error and a silent early `return`. The
## declared counts are intentionally exact: changing a section means updating its
## number, which is the point.
var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_run_section("scripting runtime detection", 8, _check_detection)
	_run_section("entry resolution", 10, _check_entry_resolution)
	_run_section("install diagnostics", 4, _check_diagnostics)
	_run_section("script bridge registration", 26, _check_bridge)
	_run_section("cross-mod id collision rule", 21, _check_collision_rule)
	_run_section("dependency load order", 10, _check_load_order)
	_run_section("map-agnostic mobility core", 82, _check_mobility_core)
	_run_section("mobility is an optional capability", 18, _check_mobility_readiness)
	_run_section("place table and pedestrian agent", 11, _check_place_table_and_agent)
	_run_section("sandbox props", 19, _check_prop_sandbox)
	_run_section("character appearance", 29, _check_character_appearance)
	_run_section("tool gun and constraints", 15, _check_tools_and_constraints)
	_run_section("npc citizens", 11, _check_npc_citizens)
	_run_section("scripted mod bridges", 7, _check_scripted_bridges)
	_run_section("map sources and blueprints", 14, _check_map_sources_and_blueprints)
	_run_section("map catalogue", 23, _check_map_catalog)
	_run_section("camera and wardrobe wiring", 33, _check_camera_and_wardrobe)
	_run_section("model clips sampler", 16, _check_model_clips)
	_run_section("guided tour", 10, _check_demo_tour)
	_run_section("tool wheel", 3, _check_tool_wheel)
	_run_section("save refuses a foreign map", 6, _check_save_map_identity)
	_run_section("render styles", 32, _check_render_styles)
	_run_section("map decor and look presets", 35, _check_decor_and_presets)
	_run_section("ambience", 12, _check_ambience)
	_run_section("photo mode", 9, _check_photo_mode)
	_run_section("boot summary", 4, _check_summary)

	print("")
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
	_expect(bridge.surface_kind(0.0, 0.0) == "none", "surface_kind did not degrade to 'none'")
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


## Two mods claiming one id is the failure a mod author cannot debug from behaviour: the
## loser's content simply never appears. The rule is "the first registration wins",
## matching what `ModContext` enforces inside a single mod, and the collision is
## reported. Neither half used to hold across mods — the merge let the last mod win, and
## nothing was reported, so both halves are asserted here.
##
## `ModHost.contexts` is empty in this test scene (the boot sequence is what fills it),
## which is why it can be used directly and cleared again afterwards.
func _check_collision_rule() -> void:
	var first := ModContext.new(&"selftest_first")
	var second := ModContext.new(&"selftest_second")
	_expect(first.add_prop_factory("shared_id", "first prop", func() -> RigidBody3D: return RigidBody3D.new()), "first mod could not register")
	_expect(second.add_prop_factory("shared_id", "second prop", func() -> RigidBody3D: return RigidBody3D.new()), "second mod was refused its own registry entry")
	_expect(second.add_prop_factory("unique_id", "unique prop", func() -> RigidBody3D: return RigidBody3D.new()), "second mod could not register a unique id")

	ModHost.contexts["selftest_first"] = first
	ModHost.contexts["selftest_second"] = second
	var merged: Dictionary = ModHost.content(&"prop")
	_expect(merged.size() == 2, "merge should hold 2 props, got %d" % merged.size())
	# First wins: the surviving payload must be the one registered by the first mod
	# that claimed the id, not whichever mod happened to be iterated last.
	var winner: Dictionary = merged.get("shared_id", {}) as Dictionary
	_expect(String(winner.get("owner", "")) == "selftest_first", "the first registration did not win (owner '%s')" % winner.get("owner", "?"))

	var ordered: Array[Dictionary] = ModHost.content_ordered(&"prop")
	_expect(ordered.size() == 2, "content_ordered should mirror content, got %d" % ordered.size())
	_expect(String(ordered[0].get("id", "")) < String(ordered[1].get("id", "")), "content_ordered is not sorted by id")

	# The collision must be recorded against the losing mod, because that is the author
	# who has to change something.
	ModHost.failures.clear()
	ModHost._report_cross_mod_collisions()
	_expect(ModHost.failures.has("selftest_second"), "the losing mod was not told about the collision")
	_expect(not ModHost.failures.has("selftest_first"), "the winning mod was blamed for the collision")

	ModHost.contexts.clear()
	ModHost.failures.clear()
	_expect(ModHost.content(&"prop").is_empty(), "clearing contexts did not clear the merge")

	# The rules themselves are now testable without the autoload, because they live in
	# `ModContent`. That matters for the ones the end-to-end path above cannot express:
	# terrain layering sorts by `order` before `id`, which is a *different* order from
	# every other kind and was previously covered by nothing at all.
	var layered := ModContext.new(&"selftest_layered")
	_expect(layered.add_terrain_modifier("z_high_priority", _identity_modifier, 10), "could not register a modifier")
	_expect(layered.add_terrain_modifier("a_low_priority", _identity_modifier, 50), "could not register a modifier")
	_expect(layered.add_terrain_modifier("tie_b", _identity_modifier, 100), "could not register a modifier")
	_expect(layered.add_terrain_modifier("tie_a", _identity_modifier, 100), "could not register a modifier")

	var index := ModContent.new({"selftest_layered": layered})
	var terrain: Array[Dictionary] = index.ordered(&"terrain")
	_expect(terrain.size() == 4, "expected 4 modifiers, got %d" % terrain.size())
	# `z_high_priority` sorts last by id but first by order, so this fails if the sort
	# key ever regresses to plain `id`.
	_expect(String(terrain[0].get("id", "")) == "z_high_priority", "terrain modifiers are not ordered by `order` first (got '%s')" % terrain[0].get("id", ""))
	# Equal `order` falls back to `id`, which is what makes the tie deterministic.
	_expect(String(terrain[2].get("id", "")) == "tie_a", "equal-order modifiers are not tie-broken by id")
	_expect(String(terrain[3].get("id", "")) == "tie_b", "equal-order modifiers are not tie-broken by id")

	# A standalone index sees only what it was given, which is what makes the rest of
	# this section meaningful rather than an accident of the autoload's state.
	_expect(index.of(&"prop").is_empty(), "a fresh index should carry no props")
	_expect(index.collisions().is_empty(), "distinct ids must not be reported as collisions")

	# The loader must still be the way callers reach the content: one owner for the
	# rules, one stable seam for asking.
	_expect(ModHost.content_index != null, "the loader does not own a content index")


## A terrain modifier that changes nothing, for ordering assertions only.
func _identity_modifier(_x: float, _z: float, height: float, _falloff: float) -> float:
	return height


## Load order is a documented promise: the same set of mods must load the same way every
## run, because `ModOrder`'s output is what makes a mod-reshaped world reproducible from
## its seed. Nothing asserted that before, and the algorithm's degenerate cases — a cycle,
## a chain with no bottom, a dependency that is not installed — were entirely untested.
func _check_load_order() -> void:
	_expect(ModOrder.order([]).is_empty(), "an empty graph should produce an empty order")

	# A dependency has to be resolved before the mod that needs it.
	var ordered := ModOrder.order([_candidate("a_mod", ["b_mod"]), _candidate("b_mod", [])])
	_expect(_ids(ordered) == ["b_mod", "a_mod"], "a dependency did not load first (got %s)" % str(_ids(ordered)))

	# Independent mods fall back to id order: the other half of determinism, because
	# otherwise the order would depend on directory iteration.
	var unordered := ModOrder.order([_candidate("zeta", []), _candidate("alpha", [])])
	_expect(_ids(unordered) == ["alpha", "zeta"], "independent mods are not tie-broken by id (got %s)" % str(_ids(unordered)))

	# Transitive: c depends on b depends on a.
	var chain := ModOrder.order([
		_candidate("c_mod", ["b_mod"]),
		_candidate("b_mod", ["a_mod"]),
		_candidate("a_mod", []),
	])
	_expect(_ids(chain) == ["a_mod", "b_mod", "c_mod"], "a transitive chain is not ordered (got %s)" % str(_ids(chain)))

	# A dependency that is not installed warns and is skipped — never fatal, because mods
	# are additive and a broken graph must not be able to stop the game booting.
	var orphan := ModOrder.order([_candidate("lonely", ["ghost_mod"])])
	_expect(_ids(orphan) == ["lonely"], "a missing dependency dropped its dependent (got %s)" % str(_ids(orphan)))

	# A cycle must terminate, and must yield each mod exactly once. This is where the
	# traversal used to be wrong: it only skipped *finished* mods, so a pair declaring
	# each other appended itself until the depth guard tripped — 64 entries for 2 mods.
	#
	# Typed explicitly: an untyped `Array` literal stored in a variable will not convert
	# to the `Array[Dictionary]` parameter, though the same literal passed inline will.
	var cycle: Array[Dictionary] = [_candidate("ping", ["pong"]), _candidate("pong", ["ping"])]
	var cyclic := ModOrder.order(cycle)
	_expect(cyclic.size() == 2, "a cycle must yield each mod once (got %d entries)" % cyclic.size())
	var cycle_ids := _ids(cyclic)
	cycle_ids.sort()
	_expect(cycle_ids == ["ping", "pong"], "a cycle lost a mod (got %s)" % str(_ids(cyclic)))
	# A cycle has no correct order, so the requirement is that the answer is stable.
	_expect(_ids(ModOrder.order(cycle)) == _ids(cyclic), "the order of a cyclic graph is not stable between runs")

	# A mod that depends on itself is the smallest cycle, and the same rule covers it.
	var selfish := ModOrder.order([_candidate("solo", ["solo"])])
	_expect(_ids(selfish) == ["solo"], "a self-dependency did not resolve to a single entry (got %s)" % str(_ids(selfish)))

	_expect(ModOrder.MAX_DEPENDENCY_DEPTH > 0, "the depth guard must be positive")


func _candidate(id: String, dependencies: Array) -> Dictionary:
	return {"id": id, "dependencies": PackedStringArray(dependencies)}


func _ids(entries: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	for entry: Dictionary in entries:
		out.append(String(entry["id"]))
	return out


## The mobility core is deliberately dataset-agnostic: given *any* map whose places carry
## activity labels, behaviour runs. These assertions cover the three things that makes true —
## label normalisation with a fallback ladder, destination choice from tags and distance, and
## a route cache that must never survive a map change.
func _check_mobility_core() -> void:
	# --- Labels from four different vocabularies must land on the same canonical tag ---
	_expect(ActivityTag.normalize("Kantoorfunctie") == ActivityTag.WORK, "a Dutch usage function did not normalise")
	_expect(ActivityTag.normalize("  fast-food ") == ActivityTag.FOOD, "separators and whitespace were not squashed")
	_expect(ActivityTag.normalize("公司") == ActivityTag.WORK, "a CJK label did not normalise")
	_expect(ActivityTag.normalize("Restaurant") == ActivityTag.FOOD, "case was not folded")
	_expect(ActivityTag.normalize("work") == ActivityTag.WORK, "a canonical name was not accepted directly")
	_expect(ActivityTag.normalize("zzz-unknown") == ActivityTag.OTHER, "an unknown label must degrade to `other`, never fail")
	_expect(ActivityTag.normalize("") == ActivityTag.OTHER, "an empty label must be safe")
	_expect(ActivityTag.is_canonical(ActivityTag.normalize("supermarket")), "a normalised tag must be canonical")
	_expect(ActivityTag.fallback_ladder(ActivityTag.FOOD)[0] == ActivityTag.FOOD, "a ladder must start at the tag itself")
	_expect(ActivityTag.fallback_ladder(ActivityTag.FOOD).back() == ActivityTag.OTHER, "a ladder must end at `other`")
	_expect(ActivityTag.fallback_ladder(&"never_heard_of_it").back() == ActivityTag.OTHER, "even an unknown tag needs a ladder")

	# --- The default map source is PLATEAU, whose buildings carry `bldg:usage` in Japanese.
	# These are the values that turn a real 3D city model into an activity-tagged map with no
	# trajectory data at all, so they are asserted rather than assumed.
	_expect(ActivityTag.normalize("住宅") == ActivityTag.HOME, "PLATEAU use type 住宅 did not map to home")
	_expect(ActivityTag.normalize("共同住宅") == ActivityTag.HOME, "PLATEAU use type 共同住宅 did not map to home")
	_expect(ActivityTag.normalize("事務所") == ActivityTag.WORK, "PLATEAU use type 事務所 did not map to work")
	_expect(ActivityTag.normalize("工場") == ActivityTag.WORK, "PLATEAU use type 工場 did not map to work")
	_expect(ActivityTag.normalize("飲食店") == ActivityTag.FOOD, "PLATEAU use type 飲食店 did not map to food")
	_expect(ActivityTag.normalize("店舗") == ActivityTag.SHOP, "PLATEAU use type 店舗 did not map to shop")
	_expect(ActivityTag.normalize("学校") == ActivityTag.SCHOOL, "PLATEAU use type 学校 did not map to school")
	_expect(ActivityTag.normalize("病院") == ActivityTag.SERVICE, "PLATEAU use type 病院 did not map to service")
	_expect(ActivityTag.normalize("体育館") == ActivityTag.LEISURE, "PLATEAU use type 体育館 did not map to leisure")
	_expect(ActivityTag.normalize("駅舎") == ActivityTag.TRANSIT, "PLATEAU use type 駅舎 did not map to transit")
	# Lodging is where someone stays overnight, so it belongs with home. `hotel` used to be
	# filed under food, which made an English and a Dutch label disagree about the same thing.
	_expect(ActivityTag.normalize("ホテル") == ActivityTag.HOME, "lodging must group with home")
	_expect(ActivityTag.normalize("ホテル") == ActivityTag.normalize("hotel"), "lodging label must not depend on language")
	_expect(ActivityTag.normalize("謎の用途") == ActivityTag.OTHER, "an unknown Japanese use type must degrade to `other`")

	# --- PLATEAU's `bldg:usage` is a *numeric codelist*, not a label. These codes are what real
	# data actually contains (a measured Tokyo ward carried a code on 100% of its buildings), so
	# they are the values the default map source will hand the adapter.
	_expect(ActivityTag.normalize("401") == ActivityTag.WORK, "PLATEAU 401 業務施設 must map to work")
	_expect(ActivityTag.normalize("431") == ActivityTag.WORK, "PLATEAU 431 運輸倉庫施設 must map to work")
	_expect(ActivityTag.normalize("441") == ActivityTag.WORK, "PLATEAU 441 工場 must map to work")
	_expect(ActivityTag.normalize("411") == ActivityTag.HOME, "PLATEAU 411 住宅 must map to home")
	_expect(ActivityTag.normalize("412") == ActivityTag.HOME, "PLATEAU 412 共同住宅 must map to home")
	_expect(ActivityTag.normalize("413") == ActivityTag.HOME, "PLATEAU 413 shop-with-residence must map to home")
	_expect(ActivityTag.normalize("403") == ActivityTag.HOME, "PLATEAU 403 宿泊施設 must group with home")
	_expect(ActivityTag.normalize("402") == ActivityTag.SHOP, "PLATEAU 402 商業施設 must map to shop")
	_expect(ActivityTag.normalize("404") == ActivityTag.SHOP, "PLATEAU 404 商業系複合施設 must map to shop")
	_expect(ActivityTag.normalize("421") == ActivityTag.SERVICE, "PLATEAU 421 官公庁施設 must map to service")
	_expect(ActivityTag.normalize("422") == ActivityTag.SCHOOL, "PLATEAU 422 文教厚生施設 must map to school")
	_expect(ActivityTag.normalize("454") == ActivityTag.OTHER, "PLATEAU 454 その他 carries no activity")
	_expect(ActivityTag.normalize("461") == ActivityTag.OTHER, "PLATEAU 461 不明 carries no activity")
	# A pipeline that resolves codes to names before normalising must land in the same place.
	_expect(ActivityTag.normalize("業務施設") == ActivityTag.normalize("401"), "a PLATEAU label must agree with its code")

	# --- Distance and weight are the two variables the score is built from ---
	_expect(
		DestinationChooser.score(0.0, 1.0, 1.0, 100.0) > DestinationChooser.score(500.0, 1.0, 1.0, 100.0),
		"distance must decay the score"
	)
	_expect(
		DestinationChooser.score(10.0, 2.0, 1.0, 100.0) > DestinationChooser.score(10.0, 1.0, 1.0, 100.0),
		"weight must raise the score"
	)
	_expect(DestinationChooser.score(10.0, 0.0, 1.0, 100.0) == 0.0, "a weightless place must be unselectable")

	var places: Array[Dictionary] = _stub_places()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var picked: Dictionary = DestinationChooser.choose(places, ActivityTag.FOOD, Vector3.ZERO, rng)
	_expect(StringName(picked.get("tag", &"")) == ActivityTag.FOOD, "a food step must pick a food place")

	# A map thinner than the pattern is the case this whole design exists for.
	var no_food: Array[Dictionary] = _stub_places_without(ActivityTag.FOOD)
	var fell_back: Dictionary = DestinationChooser.choose(no_food, ActivityTag.FOOD, Vector3.ZERO, rng)
	_expect(not fell_back.is_empty(), "a map with no `food` must still resolve the step")
	_expect(StringName(fell_back.get("tag", &"")) == ActivityTag.SHOP, "the ladder must be walked in order (expected shop before leisure)")

	_expect(
		DestinationChooser.choose([] as Array[Dictionary], ActivityTag.FOOD, Vector3.ZERO, rng).is_empty(),
		"an empty map must return no destination rather than crash"
	)
	var avoided: Dictionary = DestinationChooser.choose(places, ActivityTag.FOOD, Vector3.ZERO, rng, &"food_a")
	_expect(StringName(avoided.get("id", &"")) != &"food_a", "avoid_id must exclude that place")

	# Same seed, same choice — the world is supposed to be reproducible.
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 99
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 99
	var first: Dictionary = DestinationChooser.choose(places, ActivityTag.SHOP, Vector3.ZERO, rng_a)
	var second: Dictionary = DestinationChooser.choose(places, ActivityTag.SHOP, Vector3.ZERO, rng_b)
	_expect(
		StringName(first.get("id", &"")) == StringName(second.get("id", &"")),
		"the same seed must pick the same place"
	)
	# ...but different people must not all walk into the same building.
	var spread: Dictionary = {}
	for candidate_seed: int in 24:
		var person_rng := RandomNumberGenerator.new()
		person_rng.seed = candidate_seed
		spread[String(DestinationChooser.choose(places, ActivityTag.SHOP, Vector3.ZERO, person_rng).get("id", ""))] = true
	_expect(spread.size() > 1, "different seeds must spread people across candidate places")

	# --- The cache: shared, bounded, and invalid on a map change ---
	var cache := RouteCache.new()
	cache.set_map_version("map_v1")
	var computes: Array = [0]
	var counter := func(_from_key: String, _to_key: String) -> PackedVector3Array:
		computes[0] = int(computes[0]) + 1
		return PackedVector3Array([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])

	var path: PackedVector3Array = cache.get_or_compute("a", "b", counter)
	_expect(path.size() == 2, "the path finder's result must be stored as-is")
	_expect(cache.misses == 1 and cache.hits == 0, "the first lookup must be a miss")
	cache.get_or_compute("a", "b", counter)
	_expect(cache.hits == 1, "the second lookup must be a hit")
	_expect(int(computes[0]) == 1, "a cached path must not be recomputed")
	_expect(cache.has("a", "b"), "the cached route must be findable")

	# The one rule that stops agents walking through walls after a map change.
	_expect(cache.set_map_version("map_v2"), "changing the map version must report the change")
	_expect(cache.size() == 0, "a map change must drop every cached route")
	_expect(not cache.has("a", "b"), "a route from the old map must never be served")
	cache.get_or_compute("a", "b", counter)
	_expect(int(computes[0]) == 2, "after a map change the path must be recomputed")
	_expect(not cache.set_map_version("map_v2"), "setting the same version must report no change")

	# An empty result is not cached: it usually means "navigation was not ready yet", and
	# caching it would make that永久 for the session.
	var empty_cache := RouteCache.new()
	empty_cache.set_map_version("v")
	empty_cache.get_or_compute("a", "b", func(_f: String, _t: String) -> PackedVector3Array:
		return PackedVector3Array()
	)
	_expect(empty_cache.size() == 0, "an empty path must not be cached")

	var same_calls: Array = [0]
	var same_cache := RouteCache.new()
	same_cache.set_map_version("v")
	same_cache.get_or_compute("a", "a", func(_f: String, _t: String) -> PackedVector3Array:
		same_calls[0] = int(same_calls[0]) + 1
		return PackedVector3Array([Vector3.ONE])
	)
	_expect(int(same_calls[0]) == 0, "a hop to the same place must not consult the path finder")

	var bounded := RouteCache.new()
	bounded.set_map_version("v")
	bounded.max_entries = 2
	for index: int in 4:
		bounded.get_or_compute("a%d" % index, "b%d" % index, counter)
	_expect(bounded.size() == 2, "the cache must stay within max_entries (got %d)" % bounded.size())
	_expect(bounded.evictions == 2, "evictions must be counted")

	var partial := RouteCache.new()
	partial.set_map_version("v")
	partial.get_or_compute("a", "b", counter)
	partial.get_or_compute("c", "d", counter)
	_expect(partial.invalidate_touching("b") == 1, "invalidate_touching must drop exactly the routes touching that place")
	_expect(partial.has("c", "d"), "invalidate_touching must leave unrelated routes alone")

	# --- A person's route: destinations resolved at creation, paths cached, map change re-inits ---
	var route_cache := RouteCache.new()
	var route := AgentRoute.new()
	route.set_path_finder(_stub_polyline)
	route.configure(ActivityPattern.commute(), places, route_cache, "map_v1", Vector3.ZERO, 11, &"home_a")
	_expect(route.stop_count() == 3, "a commute must resolve to 3 stops (got %d)" % route.stop_count())
	_expect(route.unresolved_steps() == 0, "every step must resolve on a well-annotated map")
	_expect(route.needs_reinit("map_v2"), "a route built for another map must ask to be re-initialised")
	_expect(not route.needs_reinit("map_v1"), "the route's own map version must not trigger a re-init")
	_expect(not route.current_path().is_empty(), "the first leg must already be resolved when the route is created")
	_expect(route_cache.size() == 1, "only the first leg may be computed eagerly (got %d)" % route_cache.size())
	_expect(route.place_id_at(1) != route.place_id_at(0), "consecutive stops must not be the same place")

	_expect(route.advance(), "advancing must move to the next stop")
	_expect(route_cache.size() == 2, "advancing must resolve the leg it enters")
	_expect(route.advance(), "the last stop must still be reachable")
	_expect(not route.advance(), "advancing past the last stop must report the end")
	_expect(route.is_finished(), "the route must be finished after the last stop")

	var route_a := AgentRoute.new()
	route_a.set_path_finder(_stub_polyline)
	var route_b := AgentRoute.new()
	route_b.set_path_finder(_stub_polyline)
	route_a.configure(ActivityPattern.commute_with_lunch(), places, RouteCache.new(), "m", Vector3.ZERO, 3, &"home_a")
	route_b.configure(ActivityPattern.commute_with_lunch(), places, RouteCache.new(), "m", Vector3.ZERO, 3, &"home_a")
	var identical: bool = route_a.stop_count() == route_b.stop_count()
	for index: int in route_a.stop_count():
		if route_a.place_id_at(index) != route_b.place_id_at(index):
			identical = false
	_expect(identical, "the same seed must produce the same itinerary")

	# A thin map must degrade down the ladder, not collapse.
	var thin := AgentRoute.new()
	thin.set_path_finder(_stub_polyline)
	thin.configure(ActivityPattern.school_day(), places, RouteCache.new(), "m", Vector3.ZERO, 5, &"home_a")
	_expect(thin.unresolved_steps() == 0, "a map with no school must still resolve via the ladder")
	_expect(thin.tag_at(1) == ActivityTag.SCHOOL, "the route must still record what the pattern asked for")
	_expect(thin.resolved_tag_at(1) == ActivityTag.SERVICE, "the fallback that satisfied the step must be visible")

	var blank := AgentRoute.new()
	blank.configure(ActivityPattern.new(&"empty", [] as Array[StringName]), places, RouteCache.new(), "m", Vector3.ZERO, 1)
	_expect(blank.is_finished(), "an invalid pattern must produce a finished, empty route")

	var nowhere := AgentRoute.new()
	nowhere.configure(ActivityPattern.commute(), [] as Array[Dictionary], RouteCache.new(), "m", Vector3.ZERO, 1)
	_expect(nowhere.unresolved_steps() == 3, "a map with no places must report every step unresolved (got %d)" % nowhere.unresolved_steps())


## A small annotated place set: two homes, two workplaces, two eateries, two shops and one
## service. Deliberately has **no** school and **no** leisure place, so the fallback ladder is
## exercised by the assertions above.
func _stub_places() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append(DestinationChooser.make_candidate(&"home_a", ActivityTag.HOME, Vector3(0.0, 0.0, 0.0)))
	out.append(DestinationChooser.make_candidate(&"home_b", ActivityTag.HOME, Vector3(120.0, 0.0, 40.0)))
	out.append(DestinationChooser.make_candidate(&"work_a", ActivityTag.WORK, Vector3(300.0, 0.0, 0.0)))
	out.append(DestinationChooser.make_candidate(&"work_b", ActivityTag.WORK, Vector3(420.0, 0.0, 120.0)))
	out.append(DestinationChooser.make_candidate(&"food_a", ActivityTag.FOOD, Vector3(150.0, 0.0, 200.0)))
	out.append(DestinationChooser.make_candidate(&"food_b", ActivityTag.FOOD, Vector3(260.0, 0.0, 260.0)))
	out.append(DestinationChooser.make_candidate(&"shop_a", ActivityTag.SHOP, Vector3(80.0, 0.0, 90.0)))
	out.append(DestinationChooser.make_candidate(&"shop_b", ActivityTag.SHOP, Vector3(220.0, 0.0, 60.0)))
	out.append(DestinationChooser.make_candidate(&"service_a", ActivityTag.SERVICE, Vector3(340.0, 0.0, 210.0)))
	return out


func _stub_places_without(tag: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for place: Dictionary in _stub_places():
		if StringName(place.get("tag", ActivityTag.OTHER)) != tag:
			out.append(place)
	return out


## Stands in for a navigation mesh: a straight two-point line for any hop.
func _stub_polyline(_from_key: String, _to_key: String) -> PackedVector3Array:
	return PackedVector3Array([Vector3.ZERO, Vector3(1.0, 0.0, 0.0)])


## Tag-driven mobility is an optional feature. A map without annotations — a mod's hand-made
## map, an unlabelled dataset — must report the feature as *unavailable* rather than run it on
## empty meaning. These assertions pin the difference between "cannot run" and "will have to
## substitute", because collapsing those two is how a map ends up full of plausible-looking
## people going nowhere.
func _check_mobility_readiness() -> void:
	# Cannot run: nothing to route between.
	var empty: Dictionary = MobilityReadiness.assess([] as Array[Dictionary])
	_expect(not bool(empty["enabled"]), "a map with no places must report the feature as off")
	_expect(not String(empty["reason"]).is_empty(), "a disabled report must say why")

	# Cannot run: places exist but none is annotated. This is the mod-map case.
	var unlabelled: Array[Dictionary] = []
	for index: int in 10:
		unlabelled.append(DestinationChooser.make_candidate(StringName("b%d" % index), ActivityTag.OTHER, Vector3(index, 0, 0)))
	var bare: Dictionary = MobilityReadiness.assess(unlabelled)
	_expect(not bool(bare["enabled"]), "an unannotated map must report the feature as off")
	_expect(int(bare["tagged_count"]) == 0, "unannotated places must not count as tagged")
	_expect(String(bare["reason"]).contains("活动标签"), "the reason must name the missing annotations")

	# Cannot run: only one activity exists, so everyone would go to the same kind of place.
	var single: Array[Dictionary] = [
		DestinationChooser.make_candidate(&"h1", ActivityTag.HOME, Vector3.ZERO),
		DestinationChooser.make_candidate(&"h2", ActivityTag.HOME, Vector3(50, 0, 0)),
	]
	var one_kind: Dictionary = MobilityReadiness.assess(single)
	_expect(not bool(one_kind["enabled"]), "a single activity type must report the feature as off")

	# Runs: two activities are enough for a day to mean something.
	var mixed: Array[Dictionary] = _stub_places()
	var report: Dictionary = MobilityReadiness.assess(mixed, [ActivityTag.HOME, ActivityTag.WORK, ActivityTag.TRANSIT])
	_expect(bool(report["enabled"]), "a well-annotated map must enable the feature")
	_expect(int(report["tagged_count"]) == mixed.size(), "every stub place carries a real tag")
	_expect((report["coverage"] as Dictionary).get(ActivityTag.HOME, 0) == 2, "coverage must count per tag")

	var usable: Array = report["usable_tags"]
	_expect(not usable.has(ActivityTag.OTHER), "`other` is the absence of an annotation, not an activity")
	_expect(usable.size() >= 2, "usable tags must list the distinct activities")

	# Missing must NOT disable: the fallback ladder is the mechanism for it.
	var missing: PackedStringArray = report["missing"]
	_expect(missing.has("transit"), "a requested tag with no place must be reported missing")
	_expect(not missing.has("home"), "a requested tag that exists must not be reported missing")
	_expect(MobilityReadiness.will_substitute(report), "a report with missing tags indicates substitution")
	_expect(bool(report["enabled"]), "missing tags must not disable the feature — the ladder covers them")

	var complete: Dictionary = MobilityReadiness.assess(mixed, [ActivityTag.HOME, ActivityTag.WORK])
	_expect(not MobilityReadiness.will_substitute(complete), "nothing missing means no substitution")

	# The two reports a UI would actually show.
	_expect(String(MobilityReadiness.describe(bare)).contains("未启用"), "the disabled description must say so")
	_expect(String(MobilityReadiness.describe(report)).contains("启用"), "the enabled description must say so")


## Map identity is the thing that keeps a save made in one city from silently
## teleporting its player into another. The island era produced saves with no
## map id at all — those must be refused too, which is the "empty string" case.
func _check_save_map_identity() -> void:
	var original_id: String = GameState.map_id
	GameState.map_id = "map_running"
	var slot: String = "selftest_slot"
	var path: String = SaveSystem.slot_path(slot)

	var foreign := {"meta": {}, "state": {"map_id": "map_foreign"}, "sections": {}}
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(foreign))
	file.close()
	SaveSystem.last_error = ""
	_expect(not SaveSystem.load_game(slot), "a foreign-map save must be refused")
	_expect(SaveSystem.last_error.contains("其他地图"), "the refusal must name the map mismatch")
	_expect(GameState.map_id == "map_running", "a refused save must not touch the running state")

	var same := {"meta": {}, "state": {"map_id": "map_running", "world_seed": 7}, "sections": {}}
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(same))
	file.close()
	SaveSystem.last_error = ""
	_expect(SaveSystem.load_game(slot), "a same-map save must load")
	_expect(GameState.world_seed == 7, "a loaded save must apply its state")

	# An island-era save carries no map id — empty on read, refused for it.
	var legacy := {"meta": {}, "state": {"world_seed": 7}, "sections": {}}
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()
	SaveSystem.last_error = ""
	_expect(not SaveSystem.load_game(slot), "a save with no map id must be refused")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameState.map_id = original_id


## The place table is the bridge between an exported dataset and the mobility
## core: its parser's skip rules and its map-version round-trip are what keep a
## stale export from silently misplacing a crowd. The agent check pins the
## pipeline end to end on a synthetic fixture — no dataset required, which is
## the whole point of running this in CI.
func _check_place_table_and_agent() -> void:
	var fixture := "\n".join(PackedStringArray([
		"# plateau place table",
		"# city=fixture lod=1 map_version=plateau:fixture:1:aa",
		"# offset=1.0 0.0 2.0",
		"# id\ttag\tx\ty\tz",
		"b1\thome\t0.000\t0.000\t0.000",
		"b2\twork\t100.000\t0.000\t0.000",
		"b3\tfood\t50.000\t0.000\t40.000",
		"b4\tother\t7.000\t0.000\t7.000",
		"b5\thome\t7.000",
		"\thome\t1.000\t0.000\t1.000",
	]))
	var parsed: Dictionary = PlaceTable.parse_text(fixture)
	var candidates: Array[Dictionary] = parsed.get("candidates", [] as Array[Dictionary])
	_expect(candidates.size() == 4, "the parser must skip lines without an id or a 5-column row")
	_expect(StringName(candidates[0].get("id", &"")) == &"b1", "the first valid entry must survive in order")
	_expect(StringName(candidates[3].get("tag", &"")) == ActivityTag.OTHER, "an `other` tag must be kept so readiness can count it")
	_expect(String(parsed.get("map_version", "")) == "plateau:fixture:1:aa", "map_version must round-trip")
	_expect((parsed.get("offset", Vector3.ZERO) as Vector3) == Vector3(1.0, 0.0, 2.0), "the exported offset must round-trip")

	var report: Dictionary = MobilityReadiness.assess(candidates, [&"home", &"work", &"food", &"school"])
	_expect(bool(report["enabled"]), "a home+work+food fixture must enable mobility")
	_expect((report["missing"] as PackedStringArray).has("school"), "a requested tag with no place must be named missing")

	var agent := PedestrianAgent.new()
	add_child(agent)
	var cache := RouteCache.new()
	cache.set_map_version("fixture")
	# The home step of the fixture's commute falls back to `b4` (the only other
	# annotated place), so the position table must carry it too — a finder that
	# cannot resolve a stop returns an empty path, and this assertion exists to
	# catch exactly that.
	var positions := {
		"b1": Vector3(0, 0, 0), "b2": Vector3(100, 0, 0),
		"b3": Vector3(50, 0, 40), "b4": Vector3(7, 0, 7),
	}
	var finder := func(from_key: String, to_key: String) -> PackedVector3Array:
		if not positions.has(from_key) or not positions.has(to_key):
			return PackedVector3Array()
		return PackedVector3Array([Vector3(positions[from_key]), Vector3(positions[to_key])])
	agent.configure(ActivityPattern.commute(), candidates, cache, "fixture", Vector3(0, 0.4, 0), 5, &"b1", finder)
	_expect(agent.has_day(), "a commute must resolve on a home+work fixture")
	_expect(agent.route.stop_count() == 3, "commute is home->work->home: 3 stops (got %d)" % agent.route.stop_count())
	_expect(agent.route.current_path().size() == 2, "the first leg's straight line must have two endpoints (got %d: %s)" % [
		agent.route.current_path().size(), str(agent.route.current_path()),
	])
	_expect(agent.progress_fraction() == 0.0, "a freshly configured agent must not have progressed")
	agent.queue_free()


## The sandbox's first milestone: a prop catalogue whose factories build valid
## rigid bodies, a spawner whose spawn/undo/remove never leak or resurrect a
## node, and the belt that arbitrates the shared primary button. All exercised
## on the built-in catalogue — headless, no data, no rendering.
func _check_prop_sandbox() -> void:
	var entries: Array[Dictionary] = PropCatalog.entries()
	_expect(entries.size() >= 6, "the built-in catalogue must offer at least 6 props")
	var ids: Dictionary = {}
	for entry: Dictionary in entries:
		ids[String(entry.get("id", ""))] = true
	_expect(ids.size() == entries.size(), "prop ids must be unique across built-ins and mods")

	var definition: Dictionary = PropCatalog.find(&"crate")
	_expect(not definition.is_empty(), "crate must be in the catalogue")
	var body: Variant = (definition["factory"] as Callable).call()
	_expect(body is RigidBody3D, "a prop factory must build a RigidBody3D")
	var shape := (body as RigidBody3D).get_node_or_null("Body") as CollisionShape3D
	_expect(shape != null and shape.shape != null, "a built prop must carry a collision shape")
	_expect((body as RigidBody3D).mass > 0.0, "a built prop must have positive mass")
	(body as RigidBody3D).free()

	var container := Node3D.new()
	add_child(container)
	var spawner := PropSpawner.new()
	add_child(spawner)
	spawner.setup(container)
	var spawned: RigidBody3D = spawner.spawn(&"crate", Vector3.ZERO)
	_expect(spawned != null and spawned.get_parent() == container, "spawn must parent the prop to the bound container")
	_expect(spawner.count() == 1, "one spawn must leave one live prop")
	_expect(spawner.undo(), "undo must report a popped spawn")
	_expect(spawner.count() == 0, "undo must empty the spawner")
	_expect(spawned == null or spawned.is_queued_for_deletion(), "undo must free the spawned prop")
	_expect(not spawner.undo(), "undo on an empty stack must report nothing to do")

	var context := ModContext.new(&"selftest_props")
	_expect(
		context.add_prop_factory(&"mod_crate", "mod crate", func() -> RigidBody3D:
			return PropFactory.build_box(Vector3.ONE, Color.WHITE, 4.0),
		),
		"a rigid-body factory must register through the mod seam"
	)
	ModHost.contexts["selftest_props"] = context
	var mod_entry: Dictionary = ModHost.content(&"prop").get("mod_crate", {})
	_expect(not mod_entry.is_empty(), "the mod prop must appear in the merged catalogue view")
	ModHost.contexts.erase("selftest_props")
	context.release_all()

	var belt := ToolBelt.new()
	_expect(belt.current == &"weapon", "the belt must start on the weapon")
	belt.switch_to(&"wrench")
	_expect(belt.current == &"wrench", "switching must change the held tool")
	belt.switch_to(&"not_a_tool")
	_expect(belt.current == &"wrench", "an unknown tool id must be refused")

	# The scripted-mod bridge wraps a Mesh factory into a rigid body — the
	# low-friction path for Lua mods — and the wrapped product must be valid.
	var wrapped_context := ModContext.new(&"selftest_wrapped")
	var bridge := ScriptBridge.new(wrapped_context, &"selftest_wrapped")
	_expect(
		bridge.add_prop("wrapped_prop", func() -> Mesh: return BoxMesh.new()),
		"the bridge must accept a Mesh factory"
	)
	var wrapped_factory: Callable = (wrapped_context.prop_factories.get(&"wrapped_prop", {}) as Dictionary).get("factory", Callable())
	var wrapped: Variant = wrapped_factory.call()
	_expect(wrapped is RigidBody3D and (wrapped as RigidBody3D).get_node_or_null("Body") != null,
		"the bridge wrapper must produce a rigid body with a collider")
	wrapped_context.release_all()
	# The wrapper's product was never added to the tree, so nothing owns it:
	# freeing it here is what keeps the headless exit free of leaked geometry.
	if wrapped is Node:
		(wrapped as Node).free()


## The character look system: the catalog must produce a valid standard config
## and a fully-populated default state, the applier must drive variant
## visibility and material colour on a plain node tree (no imported model
## needed), and the save round-trip must preserve the look exactly. These run
## on hand-built meshes so the section passes with or without the `.blend`.
func _check_character_appearance() -> void:
	var config := CharacterAppearance.build_config()
	_expect(config != null and not config.options.is_empty(),
		"the appearance catalog must build a config with options")
	var ids: Dictionary = {}
	for option: OptionDefinition in config.options:
		ids[option.resource_name] = true
	_expect(ids.size() == config.options.size(),
		"appearance option ids must be unique within the config")

	var default_state := CharacterAppearance.default_state()
	_expect(default_state.values.size() == config.options.size(),
		"the default state must carry a value for every option")
	for option: OptionDefinition in config.options:
		if option is MeshSwapOption:
			var swap := option as MeshSwapOption
			var value := int(default_state.values.get(option.resource_name, -99))
			_expect(value >= 0 and value < swap.choices.size(),
				"default swap value for '%s' must index a real choice" % option.resource_name)

	# Random states must stay inside every option's value range.
	var randomized := CharacterAppearance.randomized_state()
	var in_range := true
	for option: OptionDefinition in config.options:
		if option is MeshSwapOption:
			var swap := option as MeshSwapOption
			var value := int(randomized.values.get(option.resource_name, -99))
			if value < 0 or value >= swap.choices.size():
				in_range = false
	_expect(in_range, "randomized swap values must stay inside the choice range")

	# Apply the default look to a hand-built stand-in: one hair variant visible,
	# the others hidden, base meshes untouched, optional groups closed.
	var model := Node3D.new()
	add_child(model)
	for variant: String in ["Hair_Fringe", "Hair_Layered", "Hair_Bob",
			"Shirt_T Shirt", "Pants_Long", "Shoes_Boots", "Accessories_Hat",
			"Base_Body", "Base_Eyes"]:
		var mesh := MeshInstance3D.new()
		mesh.name = variant
		mesh.mesh = BoxMesh.new()
		model.add_child(mesh)
	CharacterAppearance.apply(default_state, model)
	_expect(_mesh_visible(model, "Hair_Layered"), "the default hair variant must be visible after apply")
	_expect(not _mesh_visible(model, "Hair_Fringe") and not _mesh_visible(model, "Hair_Bob"),
		"non-selected hair variants must be hidden after apply")
	_expect(_mesh_visible(model, "Base_Body") and _mesh_visible(model, "Base_Eyes"),
		"base meshes must stay visible — the applier only touches variants")
	_expect(not _mesh_visible(model, "Accessories_Hat"),
		"the optional accessory group must hide every variant when 'none' is chosen")

	# A colour edit must land on a duplicated override material.
	var shirt := model.get_node("Shirt_T Shirt") as MeshInstance3D
	var recolored := CharacterAppearance.default_state()
	recolored.record("shirt_color", Color(1.0, 0.0, 0.0))
	CharacterAppearance.apply(recolored, model)
	var override := shirt.get_surface_override_material(0) as StandardMaterial3D
	_expect(override != null and override.albedo_color.is_equal_approx(Color(1.0, 0.0, 0.0)),
		"the shirt colour option must set an override material's albedo")

	# Save round-trip: serialize an edited look, disturb the state, restore,
	# and expect the exact swap index and colour back.
	var controller := CharacterAppearanceController.new()
	add_child(controller)
	var look := CharacterAppearance.default_state()
	look.record("hair_style", 2) # choice index of "Bob", as the panel stores it
	look.record("hair_color", Color(0.1, 0.2, 0.3))
	controller.replace_state(look)
	var snapshot: Dictionary = controller.serializable()
	controller.replace_state(CharacterAppearance.randomized_state())
	controller.restore(snapshot)
	_expect(int(controller.current_state().values.get("hair_style", -1)) == 2
		and (controller.current_state().values.get("hair_color") as Color).is_equal_approx(Color(0.1, 0.2, 0.3)),
		"the save round-trip must restore swap indices and colours exactly")

	# A partial save (missing keys) must default the rest instead of failing.
	controller.restore({"values": {"hair_style": SaveSystem.encode_variant(7)}})
	_expect(int(controller.current_state().values.get("hair_style", -1)) == 7
		and controller.current_state().values.has("shirt_style"),
		"a partial save must restore known keys and default the rest")

	_expect(not CharacterAppearance.palette("shirt_color").is_empty(),
		"the panel must be offered swatches for every colour option")

	# Body proportions drive bone *rests* on a hand-built rig (a root spine, a
	# downward leg chain, and the heel anchor the applier pins to the floor).
	var rig := Skeleton3D.new()
	model.add_child(rig)
	var spine := rig.add_bone("spine")
	rig.set_bone_rest(spine, Transform3D(Basis(), Vector3(0, 1.0, 0)))
	var spine1 := rig.add_bone("spine.001")
	rig.set_bone_parent(spine1, spine)
	rig.set_bone_rest(spine1, Transform3D(Basis(), Vector3(0, 0.12, 0)))
	var thigh := rig.add_bone("thigh.L")
	rig.set_bone_parent(thigh, spine)
	rig.set_bone_rest(thigh, Transform3D(Basis(), Vector3(0.09, -0.95, 0)))
	var shin := rig.add_bone("shin.L")
	rig.set_bone_parent(shin, thigh)
	rig.set_bone_rest(shin, Transform3D(Basis(), Vector3(0, -0.45, 0)))
	var foot := rig.add_bone("foot.L")
	rig.set_bone_parent(foot, shin)
	rig.set_bone_rest(foot, Transform3D(Basis(), Vector3(0, -0.42, 0)))
	var heel := rig.add_bone("heel.02.L")
	rig.set_bone_parent(heel, foot)
	rig.set_bone_rest(heel, Transform3D(Basis(), Vector3(0, -0.06, 0)))
	var authored_spine1_rest: Transform3D = rig.get_bone_rest(spine1)
	var base_skeleton_y: float = rig.position.y

	# Zeroed proportions must not touch the authored rests.
	CharacterAppearance.apply(default_state, model)
	_expect(rig.get_bone_rest(spine1).basis.get_scale().is_equal_approx(Vector3.ONE),
		"zeroed proportions must leave the authored bone rests untouched")

	# Full height must scale the spine rest and pin the foot back to the floor.
	var taller := CharacterAppearance.default_state()
	taller.record("body_height", 1.0)
	CharacterAppearance.apply(taller, model)
	_expect(rig.get_bone_rest(spine1).basis.get_scale().y > 1.1,
		"full height must scale the spine rest")
	_expect(rig.position.y > base_skeleton_y,
		"a lengthened body must re-anchor the skeleton so the foot stays on the floor")

	# Re-applying the same state must be a no-op — the reset pass exists so
	# panel edits can fire dozens of times without drift.
	CharacterAppearance.apply(taller, model)
	var after_first_apply: float = rig.position.y
	CharacterAppearance.apply(taller, model)
	_expect(is_equal_approx(rig.position.y, after_first_apply),
		"applying the same proportions twice must not drift the anchor")

	# Back to zero: rests and the anchor must return exactly to authored values.
	CharacterAppearance.apply(default_state, model)
	_expect(rig.get_bone_rest(spine1).basis.get_scale().is_equal_approx(Vector3.ONE)
		and is_equal_approx(rig.position.y, base_skeleton_y),
		"zeroed proportions must restore the authored rests and anchor exactly")
	_expect(authored_spine1_rest == rig.get_bone_rest(spine1),
		"the rest baseline cache must round-trip the authored transform")

	# Random proportions must stay inside the slider range.
	var random_in_range := true
	for deform_id: StringName in CharacterAppearance.DEFORM_GROUPS:
		var value := float(randomized.values.get(String(deform_id), 99.0))
		if value < -1.0 or value > 1.0:
			random_in_range = false
	_expect(random_in_range, "randomized proportion values must stay inside [-1, 1]")

	# The player-model extension point: registration, collision rule, and the
	# merged view a consumer reads.
	_expect(ModContent.KINDS.has(&"player_model"),
		"player_model must be a registered mod kind")
	var context := ModContext.new(&"test_mod")
	_expect(context.add_player_model(&"hero", "测试主角",
		func() -> Node3D: return Node3D.new()),
		"a valid player model registration must be accepted")
	_expect(not context.add_player_model(&"hero", "重复", func() -> Node3D: return null),
		"a duplicate player model id must be rejected")
	var content := ModContent.new({"test_mod": context})
	var merged := content.of(&"player_model")
	_expect(merged.has("hero") and (merged["hero"] as Dictionary)["factory"].is_valid(),
		"the merged view must expose the registered player model factory")

	controller.free()
	SaveSystem.unregister_persistent(&"player_appearance")
	model.free()


func _mesh_visible(model: Node, mesh_name: String) -> bool:
	var mesh := model.get_node_or_null(NodePath(mesh_name)) as MeshInstance3D
	return mesh != null and mesh.visible


## The tool gun and its constraints: two-shot state, the weld/rope/hinge joints
## a second click builds, automatic cleanup when a constrained body dies, the
## instant prop tools, and mod-registered tools joining the roster. Bodies are
## real (in-tree rigid bodies) so joint paths resolve the way play does.
func _check_tools_and_constraints() -> void:
	var gun := ToolGun.new()
	add_child(gun)
	Services.register(&"tool_gun", gun)
	_expect(gun.tools.size() == 7, "seven built-in tools before mods (got %d)" % gun.tools.size())
	gun.select_by_id(&"weld")
	_expect(gun.current_tool() != null and gun.current_tool().tool_id == &"weld", "select_by_id must hold the selection")

	var store := ConstraintStore.new()
	add_child(store)
	var constraint_root := Node3D.new()
	add_child(constraint_root)
	store.setup(constraint_root)
	Services.register(&"constraint_store", store)

	var body_a: RigidBody3D = PropFactory.build_box(Vector3.ONE, Color.WHITE, 5.0)
	var body_b: RigidBody3D = PropFactory.build_box(Vector3.ONE, Color.WHITE, 5.0)
	add_child(body_a)
	add_child(body_b)
	body_a.global_position = Vector3.ZERO
	body_b.global_position = Vector3(3.0, 0.0, 0.0)

	var weld := ConstraintTool.new(&"weld", "焊接", &"weld")
	weld.selected()
	weld.on_primary({"collider": body_a, "position": Vector3(0.4, 0.0, 0.0), "normal": Vector3.UP})
	_expect(store.count() == 0, "one pick must not build a joint yet")
	weld.on_primary({"collider": body_b, "position": Vector3(2.6, 0.0, 0.0), "normal": Vector3.DOWN})
	_expect(store.count() == 1, "the second pick must build the weld")
	_expect(constraint_root.get_child(0) is Generic6DOFJoint3D, "a weld must be a six-DOF joint")

	weld.on_primary({"collider": body_a, "position": Vector3.ZERO, "normal": Vector3.UP})
	weld.on_primary({"collider": body_a, "position": Vector3.ZERO, "normal": Vector3.UP})
	_expect(store.count() == 1, "picking the same body twice must build nothing")

	var rope := ConstraintTool.new(&"rope", "绳索", &"rope")
	rope.on_primary({"collider": body_a, "position": Vector3.ZERO, "normal": Vector3.UP})
	rope.on_primary({"collider": body_b, "position": Vector3(3.0, 0.0, 0.0), "normal": Vector3.UP})
	# Jolt has no DampedSpringJoint3D, so the rope is a RopeVisual link that
	# applies its own pull; what matters here is the rest length it was born with.
	var rope_link := constraint_root.get_child(constraint_root.get_child_count() - 1) as RopeVisual
	_expect(rope_link != null and absf(rope_link.length - 3.0) < 0.2,
		"the rope must rest at the clicked distance (got %.2f)" % (rope_link.length if rope_link != null else -1.0))

	# A freed constrained body must take its joints with it — the store sweeps
	# for dangling references every frame.
	body_b.free()
	store._process(0.0)
	_expect(store.count() == 0, "freeing a body must drop every constraint touching it")

	var container := Node3D.new()
	add_child(container)
	var spawner := PropSpawner.new()
	add_child(spawner)
	spawner.setup(container)
	Services.register(&"prop_spawner", spawner)

	var prop: RigidBody3D = spawner.spawn(&"crate", Vector3(10.0, 0.0, 0.0))
	var remover := PropTool.new(&"remover", "移除", &"remover")
	remover.on_primary({"collider": prop, "position": Vector3(10.0, 0.0, 0.0), "normal": Vector3.UP})
	_expect(spawner.count() == 0, "the remover must delete through the spawner")

	var source: RigidBody3D = spawner.spawn(&"crate", Vector3(10.0, 0.0, 0.0))
	var duplicator := PropTool.new(&"duplicator", "复制器", &"duplicator")
	duplicator.on_primary({"collider": source, "position": Vector3(12.0, 0.0, 0.0), "normal": Vector3.UP})
	_expect(spawner.count() == 2, "the duplicator must spawn a copy through the spawner")

	var visual := source.get_node("Visual") as MeshInstance3D
	var before: Material = visual.material_override
	var painter := PropTool.new(&"painter", "上色", &"painter")
	painter.on_primary({"collider": source, "position": Vector3.ZERO, "normal": Vector3.UP})
	_expect(visual.material_override != before, "painting must duplicate the material, not mutate the shared one")

	var mass_before: float = source.mass
	var weight_tool := PropTool.new(&"weight", "配重", &"weight")
	weight_tool.on_primary({"collider": source, "position": Vector3.ZERO, "normal": Vector3.UP})
	_expect(source.mass != mass_before, "the weight tool must walk the mass ladder")

	var context := ModContext.new(&"selftest_tool")
	var custom := ConstraintTool.new(&"custom_weld", "自定义焊", &"weld")
	_expect(context.add_tool(custom), "a SandboxTool must register through the mod seam")
	ModHost.contexts["selftest_tool"] = context
	gun._rebuild_tools()
	_expect(gun.tools.size() == 8, "a mod tool must join the roster (got %d)" % gun.tools.size())
	var found: bool = false
	for tool: SandboxTool in gun.tools:
		if tool.tool_id == &"custom_weld":
			found = true
	_expect(found, "the mod tool must be reachable by id after the rebuild")
	ModHost.contexts.erase("selftest_tool")
	context.release_all()

	spawner.clear_all()
	body_a.free()


## Citizens: menu-spawnable pedestrians who get a day plan when mobility is
## bound and wander when it is not, and who die through the regular combat
## pipeline (HealthComponent in their subtree is all the attacker sees).
func _check_npc_citizens() -> void:
	var container := Node3D.new()
	add_child(container)
	var spawner := PropSpawner.new()
	add_child(spawner)
	spawner.setup(container)

	# Without mobility bound: a wanderer, not a broken schedule.
	var wanderer: PedestrianAgent = spawner.spawn_citizen(Vector3(0.0, 1.0, 0.0), 3)
	_expect(wanderer != null and wanderer.wandering, "a citizen without mobility must wander")
	_expect(wanderer.route == null, "a wanderer carries no route")
	_expect(spawner.count() == 1, "a spawned citizen counts toward undo")
	wanderer.free()

	# With mobility bound: a seeded day. The finder needs no real navigation —
	# the stub returns straight lines, which is the seam's whole point.
	var cache := RouteCache.new()
	cache.set_map_version("npc_fixture")
	var positions := {"h1": Vector3.ZERO, "w1": Vector3(40.0, 0.0, 0.0)}
	var finder := func(a: String, b: String) -> PackedVector3Array:
		if not positions.has(a) or not positions.has(b):
			return PackedVector3Array()
		return PackedVector3Array([Vector3(positions[a]), Vector3(positions[b])])
	var candidates: Array[Dictionary] = [
		DestinationChooser.make_candidate(&"h1", &"home", Vector3.ZERO),
		DestinationChooser.make_candidate(&"w1", &"work", Vector3(40.0, 0.0, 0.0)),
	]
	spawner.bind_mobility(candidates, cache, "npc_fixture", finder, [ActivityPattern.commute()])
	var citizen: PedestrianAgent = spawner.spawn_citizen(Vector3.ZERO, 5)
	_expect(citizen != null and not citizen.wandering, "a citizen with mobility bound must walk a plan")
	_expect(citizen.has_day(), "the plan must resolve on the two-place fixture")

	# Damage: the HealthComponent lives in the citizen's subtree, so a plain
	# hitbox strike finds it without any wiring.
	var health := citizen.get_node("Health") as HealthComponent
	_expect(health != null, "a citizen must carry a HealthComponent")
	var info := DamageInfo.create(500.0, &"physical", null, citizen, Vector3.ZERO, Vector3.UP)
	_expect(health.can_receive_damage(info), "a healthy citizen can take damage")
	health.apply_damage(info)
	_expect(health.is_defeated(), "a lethal hit must defeat the citizen")
	_expect(citizen.describe().contains("dead"), "a defeated citizen must report dead")
	citizen.free()

	# Mod NPC registration joins the menu catalogue.
	var context := ModContext.new(&"selftest_npc")
	_expect(
		context.add_npc_factory(&"mod_cop", "mod 巡警", func() -> CharacterBody3D:
			return PedestrianAgent.new(),
		),
		"an npc factory must register through the mod seam"
	)
	ModHost.contexts["selftest_npc"] = context
	var ids: Dictionary = {}
	for entry: Dictionary in spawner.npc_entries():
		ids[String(entry.get("id", ""))] = true
	_expect(ids.has("citizen") and ids.has("mod_cop"), "the built-in citizen and mod npcs must both be listed")
	ModHost.contexts.erase("selftest_npc")
	context.release_all()

	spawner.clear_all()


## or the smoke test's output stops being evidence.
## The scripted-mod bridges: a callback tool rides the same roster and clicks
## as a class tool, and a Mesh NPC wraps into a walking, damageable citizen.
## These are the P3 acceptance checks — a Lua mod's registrations take exactly
## this shape through `ScriptBridge`.
func _check_scripted_bridges() -> void:
	var context := ModContext.new(&"selftest_bridge2")
	var bridge := ScriptBridge.new(context, &"selftest_bridge2")

	var fired: Array = []
	_expect(
		bridge.add_tool(&"lua_mark", "标记（Lua）", {
			"on_primary": func(_hit: Dictionary) -> void: fired.append("primary"),
			"selected": func() -> void: fired.append("selected"),
		}),
		"a callback tool must register through the bridge"
	)
	var entry: Dictionary = context.tools.get(&"lua_mark", {}) as Dictionary
	var tool: Variant = entry.get("tool")
	_expect(tool is CallbackTool, "the bridge must wrap callbacks into a CallbackTool")
	(tool as CallbackTool).selected()
	(tool as CallbackTool).on_primary({})
	_expect(fired == ["selected", "primary"], "the tool must forward lifecycle and click callbacks (got %s)" % str(fired))
	_expect(gun_roster_contains(context, &"lua_mark"), "the scripted tool must appear in the tool-gun roster")

	_expect(
		bridge.add_npc(&"lua_guard", "卫兵（Lua）", func() -> Mesh: return CapsuleMesh.new()),
		"an npc mesh factory must register through the bridge"
	)
	var npc_entry: Dictionary = context.npc_factories.get(&"lua_guard", {}) as Dictionary
	var built: Variant = (npc_entry.get("factory", Callable()) as Callable).call()
	_expect(built is PedestrianAgent, "the npc wrapper must build a PedestrianAgent")
	# Health is built in _ready, which runs when the node enters the tree — the
	# same moment the spawner adds it in play.
	add_child(built as Node)
	_expect((built as PedestrianAgent).get_node_or_null("Health") != null, "a wrapped npc must be damageable")
	(built as Node).free()

	bridge.release()
	context.release_all()


## Whether the tool-gun roster (built-ins plus the given context) contains an id.
func gun_roster_contains(context: ModContext, tool_id: StringName) -> bool:
	ModHost.contexts[context.get_mod_id()] = context
	var found: bool = false
	for entry: Dictionary in ModHost.content_ordered(&"tool"):
		if StringName(entry.get("id", &"")) == tool_id:
			found = true
			break
	ModHost.contexts.erase(context.get_mod_id())
	return found


## P4: the second map source proves the seam, and the blueprint persistence
## proves that spawned props and constraints round-trip as decisions. The
## playground builds without any dataset; the blueprint test serializes a real
## spawn+weld session, wipes it, and rebuilds it through the restore path.
func _check_map_sources_and_blueprints() -> void:
	# --- PlaygroundMapSource: a whole map from code, no dataset ---
	# The self-test scene never runs the boot sequence, so the services the
	# playground expects must be registered here. Declared at function scope:
	# GDScript variables are block-scoped, and the blueprint half of this test
	# uses the same spawner the persistence node resolves through services.
	var test_spawner: PropSpawner = null
	if not Services.has(&"surface_query"):
		Services.register(&"surface_query", SurfaceQuery.new())
	if not Services.has(&"prop_spawner"):
		test_spawner = PropSpawner.new()
		add_child(test_spawner)
		Services.register(&"prop_spawner", test_spawner)
	if test_spawner == null:
		test_spawner = Services.get_as(&"prop_spawner", &"PropSpawner") as PropSpawner
	var sandbox_container := Node3D.new()
	add_child(sandbox_container)
	test_spawner.setup(sandbox_container)
	var playground := PlaygroundMapSource.new()
	var world := Node3D.new()
	add_child(world)
	_expect(playground.build(world, 7), "the playground must build headlessly")
	# Declared identity: owner + selector + content version, no fingerprint in it.
	# A raw source resolves to `unknown` until a registrar hands it its identity —
	# which is what keeps a map from disagreeing with its own registration.
	_expect(playground.map_id() == "unknown", "an unregistered source has no declared identity")
	playground.identity_selector = "playground"
	_expect(playground.map_id() == "core:playground@1", "the playground identity must be declared")
	_expect(world.get_node_or_null("Ground") != null, "the playground must have ground")
	var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
	_expect(query != null and query.is_ready(), "the playground must publish surface queries")
	_expect(playground.find_spawn_position().y > 0.0, "the playground spawn must stand above ground")
	# Citizens degrade to wandering here — the readiness-driven report a mod
	# map without annotations would also produce.
	var wandering: bool = false
	for child: Node in world.get_node("Pedestrians").get_children():
		if child is PedestrianAgent and (child as PedestrianAgent).wandering:
			wandering = true
	_expect(wandering, "playground citizens must wander (no place table on this map)")
	playground.teardown(world)

	# --- Blueprint round-trip: the persistence node is bound to the services
	# registered above (test_spawner is that very instance), so the serialize
	# and restore see the same spawner the game would. The store may already be
	# registered by the tools section — reuse it rather than fighting the
	# register guard.
	var store: ConstraintStore = Services.get_as(&"constraint_store", &"ConstraintStore") as ConstraintStore
	if store == null:
		store = ConstraintStore.new()
		add_child(store)
		store.setup(constraint_root_for(store))
		Services.register(&"constraint_store", store)

	var crate_a: RigidBody3D = test_spawner.spawn(&"crate", Vector3(1.0, 1.0, 0.0))
	var crate_b: RigidBody3D = test_spawner.spawn(&"crate", Vector3(1.0, 2.0, 0.0))
	# The weld is built directly through the store here: the tool→store chain
	# is covered in the tools section, and this section is about persistence.
	var weld_link: Node = store.build_link(&"weld", crate_a, crate_b, {"anchor": Vector3(1.0, 1.5, 0.0)})
	store.register(weld_link, crate_a, crate_b, &"weld")
	crate_b.freeze = true
	PropFactory.set_frozen_look(crate_b, true)
	_expect(store.count() == 1, "the session to save must hold one weld")

	var persistence := SandboxPersistence.new()
	add_child(persistence)
	persistence.setup(test_spawner, store)
	var blueprint: Dictionary = persistence.serialize()
	_expect((blueprint.get("props", []) as Array).size() == 2, "the blueprint must hold both props")
	_expect((blueprint.get("constraints", []) as Array).size() == 1, "the blueprint must hold the weld")

	test_spawner.clear_all()
	store._process(0.0)
	_expect(test_spawner.count() == 0 and store.count() == 0, "the wipe must leave nothing behind")

	persistence.deserialize(blueprint)
	_expect(test_spawner.count() == 2, "the restore must rebuild both props")
	_expect(store.count() == 1, "the restore must rebuild the weld")
	var restored_frozen: bool = false
	for node: Node in test_spawner._undo_stack:
		if node is RigidBody3D and (node as RigidBody3D).freeze:
			restored_frozen = true
	_expect(restored_frozen, "the frozen flag must survive the round-trip")

	test_spawner.clear_all()


## A fresh constraint container per store, keyed by the store node so two tests
## never share one.
func constraint_root_for(_store: ConstraintStore) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	return root


## The render-style seam.
##
## Two things are being checked, and the second is the one the design exists for.
## The catalogue has to merge built-ins with mod registrations under the same rules
## every other kind uses, and a style's apply/release pair has to be a **true round
## trip** — a style that leaves the map's own look altered after you switch away
## is precisely the failure that "styles retune rather than own the environment"
## was chosen to make impossible, so it is worth an assertion rather than a hope.
func _check_render_styles() -> void:
	# --- the catalogue ---
	_expect(RenderStyleCatalog.has(&"realistic"), "写实 must be a built-in style")
	_expect(RenderStyleCatalog.has(&"toon"), "3渲2 must be a built-in style")
	_expect(not RenderStyleCatalog.has(&"no_such_style"), "an unknown style id must not resolve")
	_expect(RenderStyleCatalog.make(&"no_such_style") == null, "an unknown style id must not instantiate")
	_expect(RenderStyleCatalog.ids().size() >= 2, "the catalogue must list the built-ins")

	# --- a mod registering styles ---
	var context := ModContext.new(&"selftest_render")
	_expect(
		context.add_render_style_preset(&"selftest_style", "自测画风", {"saturation": 0.2}),
		"a data-only style registration must be accepted"
	)
	ModHost.contexts[context.get_mod_id()] = context
	_expect(RenderStyleCatalog.has(&"selftest_style"), "a registered style must appear in the catalogue")
	var made: RenderStyle = RenderStyleCatalog.make(&"selftest_style")
	_expect(
		made != null and made.style_id() == &"selftest_style",
		"a registered style must instantiate under its own id"
	)
	_expect(
		not context.add_render_style_preset(&"selftest_style", "重复", {"saturation": 0.5}),
		"a duplicate style id inside one mod must be refused"
	)
	_expect(
		not context.add_render_style_preset(&"selftest_empty", "空画风", {}),
		"a style with no overrides must be refused: it would be indistinguishable from 写实"
	)
	_expect(
		not context.add_render_style(&"selftest_nameless", "", func() -> RenderStyle: return null),
		"a style with no display name must be refused"
	)
	_expect(
		context.add_render_style(&"selftest_broken", "坏工厂", func() -> Variant: return 5),
		"a style registers even with a factory that will misbehave: the factory is only run on apply"
	)
	_expect(
		RenderStyleCatalog.make(&"selftest_broken") == null,
		"a factory that returns the wrong type must be refused at instantiation, not later"
	)
	# Across mods the first registration wins, exactly as for every other kind.
	var second := ModContext.new(&"selftest_render_2")
	second.add_render_style_preset(&"selftest_style", "抢占者", {"saturation": 0.7})
	ModHost.contexts[second.get_mod_id()] = second
	_expect(
		RenderStyleCatalog.display_name_of(&"selftest_style") == "自测画风",
		"the first registration for a style id must win across mods"
	)
	ModHost.contexts.erase(second.get_mod_id())
	context.release_all()
	_expect(not RenderStyleCatalog.has(&"selftest_style"), "release_all must remove a mod's styles")
	ModHost.contexts.erase(context.get_mod_id())

	# --- the apply/release round trip ---
	var world := Node3D.new()
	add_child(world)
	DemoLook.apply(world, &"day")
	var director := RenderDirector.new()
	add_child(director)
	# The director listens for the world rather than being handed one, so this is
	# the same path boot takes.
	Events.world_ready.emit(world)

	var world_environment := world.get_node_or_null("Environment") as WorldEnvironment
	_expect(world_environment != null, "the probe world must carry an environment")
	if world_environment == null:
		return
	var environment: Environment = world_environment.environment

	_expect(director.set_style(&"realistic"), "写实 must apply to a live world")
	_expect(not director.set_style(&"no_such_style"), "an unknown style must be refused")
	_expect(director.current_id() == &"realistic", "a refused switch must keep the current style")

	var fog_was: bool = environment.fog_enabled
	var tonemap_was: int = environment.tonemap_mode
	var saturation_was: float = environment.adjustment_saturation

	_expect(director.set_style(&"toon"), "3渲2 must apply to a live world")
	_expect(not environment.fog_enabled, "3渲2 must switch fog off")
	_expect(
		environment.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
		"3渲2 must use a flat tone curve"
	)
	_expect(
		environment.adjustment_saturation > saturation_was,
		"3渲2 must be more saturated than the map's own look"
	)
	var pass_node := director.get_node_or_null("ToonPost") as ScreenPass
	_expect(pass_node != null, "3渲2 must install its screen pass")
	_expect(
		pass_node != null and pass_node.material_override is ShaderMaterial,
		"the screen pass must carry the style's shader"
	)
	_expect(
		pass_node != null and pass_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"a full-screen pass must not cast a shadow across the whole map"
	)

	_expect(director.set_style(&"realistic"), "写实 must re-apply over 3渲2")
	_expect(environment.fog_enabled == fog_was, "switching away must restore the map's fog")
	_expect(
		environment.tonemap_mode == tonemap_was,
		"switching away must restore the map's tone curve"
	)
	# `queue_free` is deferred, so "gone" means queued: asserting `== null` here
	# would fail for a correct release and only pass for an immediate `free()`.
	var stale := director.get_node_or_null("ToonPost")
	_expect(
		stale != null and stale.is_queued_for_deletion(),
		"the previous style's pass must be released"
	)
	_expect(director.cycle(1), "cycling must move to another style")
	_expect(director.current_id() == &"toon", "cycling from 写实 must land on 3渲2")

	director.queue_free()
	world.queue_free()


## The demo map's scenery, and the map's time of day.
##
## Two things are worth asserting here. The builders have to stay inside the
## project's collision policy — decor is an obstacle, not ground, or a prop spawned
## on the lawn starts landing on top of lantern posts — and the preset switch has to
## keep the render-style seam in step, because a style's overrides are *relative* to
## the preset. The second one is the interesting assertion; the first is the one
## that would otherwise rot quietly as new scenery gets added.
func _check_decor_and_presets() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	# --- builders ---
	var tree: Node3D = Decor.tree(rng)
	add_child(tree)
	_expect(tree.name == "Tree", "a tree must be named for what it is")
	_expect(
		tree.find_children("*", "MeshInstance3D", true, false).size() >= 4,
		"a tree is a trunk under a canopy, not one ball"
	)
	var tree_body := tree.get_node_or_null("Obstacle") as StaticBody3D
	_expect(tree_body != null, "a tree must be solid")
	_expect(
		tree_body != null and (tree_body.collision_layer & SurfaceQuery.GROUND_MASK) == 0,
		"decor must stay off the surface-query mask: a trunk is an obstacle, not ground"
	)
	_expect(
		tree_body != null and (tree_body.collision_layer & 1) != 0,
		"decor must sit on the world layer, or the player walks through it"
	)

	var lantern: Node3D = Decor.lantern(rng)
	add_child(lantern)
	var glow := lantern.get_node_or_null("Glow") as OmniLight3D
	_expect(glow != null, "a lantern must carry a light")
	_expect(glow != null and not glow.shadow_enabled, "lantern shadow maps cost more than they show")
	var lamp_material: StandardMaterial3D = null
	var lamp := lantern.get_node_or_null("Lamp") as MeshInstance3D
	if lamp != null:
		lamp_material = lamp.material_override as StandardMaterial3D
	_expect(lamp_material != null and lamp_material.emission_enabled, "the lamp itself must glow")

	var bench: Node3D = Decor.bench(rng)
	add_child(bench)
	_expect(bench.get_node_or_null("Obstacle") != null, "a bench must be solid")
	_expect(
		bench.find_children("Seat*", "MeshInstance3D", true, false).size() >= 3,
		"a bench is slatted"
	)

	var flowers: Node3D = Decor.flower_cluster(rng)
	add_child(flowers)
	_expect(flowers.get_node_or_null("Obstacle") == null, "flowers must not be solid")
	_expect(
		flowers.find_children("Bloom*", "MeshInstance3D", true, false).size() >= 4,
		"a cluster is several blooms, not one"
	)

	var path_host := Node3D.new()
	add_child(path_host)
	var laid: int = Decor.stone_path(path_host, PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 6.0), Vector3(4.0, 0.0, 10.0),
	]), rng)
	_expect(laid > 0, "a polyline with a run in it must lay slabs")
	var path_node := path_host.get_node_or_null("Path")
	_expect(
		path_node != null and path_node.get_child_count() == laid,
		"the reported slab count must match what landed in the scene"
	)
	_expect(
		Decor.stone_path(path_host, PackedVector3Array([Vector3.ZERO]), rng) == 0,
		"a single point is not a path"
	)

	# --- determinism ---
	var first := RandomNumberGenerator.new()
	first.seed = 777
	var second := RandomNumberGenerator.new()
	second.seed = 777
	var tree_one: Node3D = Decor.tree(first)
	var tree_two: Node3D = Decor.tree(second)
	var canopies_one: Array[Node] = tree_one.find_children("Canopy*", "MeshInstance3D", true, false)
	var canopies_two: Array[Node] = tree_two.find_children("Canopy*", "MeshInstance3D", true, false)
	_expect(
		canopies_one.size() > 0 and canopies_one.size() == canopies_two.size()
		and (canopies_one[0] as MeshInstance3D).position == (canopies_two[0] as MeshInstance3D).position,
		"the same seed must grow the same tree — the layout is a rule, not a saved file"
	)
	tree_one.free()
	tree_two.free()

	# --- the placement sampler ---
	var zone := Rect2(-20.0, -20.0, 40.0, 40.0)
	var blocked: Array[Rect2] = [Rect2(-5.0, -5.0, 10.0, 10.0)]
	var sampler := RandomNumberGenerator.new()
	sampler.seed = 99
	var inside: int = 0
	var clear: int = 0
	var samples: int = 40
	for _attempt: int in samples:
		var spot: Vector2 = Decor.free_spot(zone, blocked, sampler, 1.0)
		if spot == Vector2.INF:
			continue
		if zone.has_point(spot):
			inside += 1
		if not blocked[0].has_point(spot):
			clear += 1
	_expect(inside == samples, "every sampled spot must be inside the zone")
	_expect(clear == samples, "no sampled spot may land in a reserved rectangle")
	_expect(
		Decor.free_spot(Rect2(-2.0, -2.0, 4.0, 4.0), [Rect2(-9.0, -9.0, 18.0, 18.0)], sampler, 0.5)
		== Vector2.INF,
		"a fully reserved zone must decline a spot rather than force one into a wall"
	)

	# --- the preset switch, with a style active ---
	var world := Node3D.new()
	add_child(world)
	DemoLook.apply(world, &"day")
	var director := RenderDirector.new()
	add_child(director)
	Events.world_ready.emit(world)
	var world_environment := world.get_node_or_null("Environment") as WorldEnvironment
	_expect(world_environment != null, "the preset test needs an environment")
	if world_environment == null:
		return
	var environment: Environment = world_environment.environment

	var day_fog: float = environment.fog_density
	_expect(director.available_presets().has("dusk"), "dusk must be offerable")
	_expect(director.set_preset(&"dusk"), "switching to dusk must be accepted")
	_expect(
		DemoLook.preset_of(world_environment) == &"dusk",
		"the world must record which preset it wears — that record is how a style knows what it deviates from"
	)
	_expect(environment.fog_density != day_fog, "dusk must actually change the fog")
	_expect(director.preset_id() == &"dusk", "the director must report the chosen preset")
	_expect(not director.set_preset(&"no_such_preset"), "an unknown preset must be refused")
	_expect(director.preset_id() == &"dusk", "a refused preset must not change the choice")

	# The integration that matters: on an active style, moving the preset has to
	# re-derive the style over it, or the frame ends up wearing two looks at once.
	_expect(director.set_style(&"toon"), "3渲2 must apply over the chosen preset")
	_expect(
		environment.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
		"3渲2 must have flattened the tone curve"
	)
	_expect(not environment.fog_enabled, "3渲2 must have switched dusk's fog off")
	_expect(director.set_preset(&"day"), "switching back to day must be accepted")
	_expect(
		environment.tonemap_mode == Environment.TONE_MAPPER_LINEAR and not environment.fog_enabled,
		"the style must survive a preset change: the preset moved, the treatment did not"
	)
	_expect(DemoLook.preset_of(world_environment) == &"day", "and the world must record the new preset")
	_expect(director.set_style(&"realistic"), "写实 must hand the frame back")
	_expect(environment.fog_enabled, "day's fog must come back with 写实")

	director.queue_free()
	world.queue_free()


## The map catalogue: what is on offer, what is the default, and the selector/save
## identity split.
##
## The subtle assertion is the last-but-one: the same source registered under two
## selectors is *two maps*, because the selector is the stable name a session asks
## for while `map_id()` is the save fingerprint — for a PLATEAU map that fingerprint
## changes every time the dataset is re-exported, and keying the catalogue on it
## would make every re-export a different map.
func _check_map_catalog() -> void:
	var catalog := MapCatalog.new()
	add_child(catalog)
	_expect(catalog.default_id() == &"playground", "the demo map must be the default")
	_expect(catalog.requested_id() == &"playground", "an unset environment must mean the default")
	var lawn: MapSource = catalog.resolve(&"playground")
	_expect(lawn != null, "the core map must resolve")
	_expect(lawn is PlaygroundMapSource, "the core map must be the demo lawn")
	# The declared identity, composed from owner + selector + content version — and
	# *not* containing any fingerprint, which is advisory.
	_expect(lawn != null and lawn.map_id() == "core:playground@1", "the core identity must be declared, not computed")
	_expect(lawn != null and lawn.identity_selector == "playground", "the selector must be the stable name")
	_expect(lawn != null and lawn.map_fingerprint() == "", "a map with no dataset has no fingerprint")
	var before: Array[String] = []
	for entry: Dictionary in catalog.list():
		before.append(String(entry["id"]))
	_expect(before.has("playground"), "the core map must be listed")
	_expect(not before.has("selftest_map"), "a map no mod registered must not be listed")
	_expect(catalog.resolve(&"selftest_map") == null, "an unregistered map must not resolve")
	_expect(
		catalog.resolve(&"shibuya") == null,
		"the city map is provided by a mod; a session without that mod must not offer it"
	)

	var context := ModContext.new(&"selftest_maps")
	_expect(
		context.add_map_source(PlaygroundMapSource.new(), &"selftest_map", "自测地图", "2"),
		"a mod must be able to register a whole map"
	)
	_expect(not context.add_map_source(null, &"bad_map"), "a null source must be refused")
	ModHost.contexts["selftest_maps"] = context
	var registered: MapSource = catalog.resolve(&"selftest_map")
	_expect(registered != null, "a mod-registered map must resolve")
	_expect(
		registered != null and registered.map_id() == "selftest_maps:selftest_map@2",
		"the declared content version must flow into the save identity"
	)
	var after: Array[String] = []
	for entry: Dictionary in catalog.list():
		after.append(String(entry["id"]))
	_expect(after.has("selftest_map"), "a mod-registered map must be listed")
	_expect(
		context.add_map_source(PlaygroundMapSource.new(), &"selftest_other"),
		"the same source under another selector is another map"
	)
	OS.set_environment("DSH_MAP_SOURCE", "selftest_map")
	_expect(catalog.requested_id() == &"selftest_map", "the environment must name the map")
	OS.set_environment("DSH_MAP_SOURCE", "")
	ModHost.contexts.erase("selftest_maps")
	_expect(catalog.resolve(&"selftest_map") == null, "removing the mod must remove its map")

	# Two mods claiming one id used to load both and let the second overwrite the
	# first in `contexts` — its registrations and its save section winning silently.
	# The gate disables the later one and names both directories instead.
	var duplicate: Array[Dictionary] = [
		{"id": &"selftest_dup", "dir": "res://mods/first", "enabled": true},
		{"id": &"selftest_dup", "dir": "res://mods/second", "enabled": true},
		{"id": &"selftest_lone", "dir": "res://mods/third", "enabled": true},
	]
	ModHost._reject_duplicate_ids(duplicate)
	_expect(duplicate[0]["enabled"] == true, "the first claimant must keep its id")
	_expect(duplicate[1]["enabled"] == false, "the later duplicate must be disabled")
	_expect(duplicate[2]["enabled"] == true, "an unrelated mod must be untouched")
	_expect(ModHost.failures.has("selftest_dup"), "the collision must be reported with a reason")
	ModHost.failures.erase("selftest_dup")


## The view controls and the wardrobe wiring.
##
## The BlendSection half guards a bug that was invisible for its whole life: the
## constructor once assigned its parameters to themselves, so the player-mode
## callbacks stayed invalid and *every manual* slider/toggle did nothing — while
## the panel's own randomize button (which routes through the controller, not
## through these callables) kept working. The symptom was "random works, manual
## does not", which reads like an apply problem rather than a wiring one.
func _check_camera_and_wardrobe() -> void:
	var seen: Array = []
	var section := BlendSection.new(null, func(option_id: String, value: Variant) -> void:
		seen.append([option_id, value]), func() -> Dictionary: return {})
	section.set_value("身高", 0.7)
	section.set_toggle("上衣", true)
	_expect(seen.size() == 2, "player-mode edits must route to the panel's write callback")
	_expect(
		seen[0][0] == "身高" and is_equal_approx(float(seen[0][1]), 0.7),
		"a slider drag must deliver its option and value"
	)
	_expect(seen[1][0] == "上衣" and bool(seen[1][1]), "a toggle must deliver its state")

	var rig := CameraRig.new()
	var arm := SpringArm3D.new()
	arm.name = "SpringArm3D"
	# Same shape as the real rig: the arm is a *direct* child — `_ready` looks it up
	# by that exact path, and the pivot it rotates is the arm's parent (the rig).
	rig.add_child(arm)
	var target := Node3D.new()
	var visual := Node3D.new()
	visual.name = "Visual"
	target.add_child(visual)
	rig.target = target
	add_child(rig)
	add_child(target)

	_expect(not rig.is_first_person(), "the camera must start in third person")
	rig.zoom_in()
	_expect(
		is_equal_approx(arm.spring_length, rig.arm_length - rig.zoom_step),
		"wheel in must shorten the arm"
	)
	for _i: int in 40:
		rig.zoom_out()
	_expect(
		is_equal_approx(arm.spring_length, rig.max_arm_length),
		"zoom must stop at the far limit instead of flying to the moon"
	)
	for _i: int in 40:
		rig.zoom_in()
	_expect(
		is_equal_approx(arm.spring_length, rig.min_arm_length),
		"zoom must stop at the near limit, which is close third person, not the eye"
	)
	rig.raise_pivot()
	_expect(rig.pivot_height > rig.min_pivot_height, "raising must move the orbit centre up")
	for _i: int in 40:
		rig.lower_pivot()
	_expect(
		is_equal_approx(rig.pivot_height, rig.min_pivot_height),
		"lowering must stop instead of driving the camera underground"
	)

	rig.set_first_person(true)
	_expect(rig.is_first_person(), "first person must turn on")
	_expect(not visual.visible, "first person must hide the body the camera sits inside")
	_expect(is_equal_approx(arm.spring_length, 0.0), "first person must put the camera on the eye")
	rig.zoom_out()
	_expect(rig.is_first_person(), "the wheel must be inert while first person is on")
	rig.set_first_person(false)
	_expect(visual.visible, "leaving first person must give the body back")
	# The wheel had last clamped the arm at the near stop, so that — not the far
	# stop — is the distance first person has to restore.
	_expect(
		is_equal_approx(arm.spring_length, rig.min_arm_length),
		"leaving first person must restore the distance the wheel had set"
	)

	# The wardrobe framing: third person from the front, body shown, panel-side
	# offset on — and everything back where it was when it ends.
	rig.set_wardrobe_framing(true)
	_expect(not rig.is_first_person(), "the wardrobe view must be third person")
	_expect(visual.visible, "the wardrobe view must show the body being adjusted")
	_expect(
		is_equal_approx(arm.spring_length, CameraRig.WARDROBE_ARM_LENGTH),
		"the wardrobe view must come in close enough to read the outfit"
	)
	_expect(absf(rig.rotation.y - PI) < 0.01, "the wardrobe view must face the character")
	rig.set_wardrobe_framing(false)
	_expect(
		is_equal_approx(arm.spring_length, rig.min_arm_length),
		"closing the wardrobe must restore the wheel distance"
	)
	_expect(not rig.is_first_person(), "closing the wardrobe must restore the view mode")

	rig.queue_free()
	target.queue_free()

	# Second rig, with a model attached: first person keeps the figure visible —
	# you can see yourself when you look down — and only the head-side meshes
	# hide, so the face never fills the lens. The capsule stays hidden in every
	# view (it is a fallback body, not a second one).
	var rig2 := CameraRig.new()
	rig2.capture_mouse_on_start = false
	var arm2 := SpringArm3D.new()
	arm2.name = "SpringArm3D"
	rig2.add_child(arm2)
	# The rig reaches for the arm's camera child when applying first person, so
	# the test needs one — the visible-layer trick is the camera's, and the
	# lookup is by name.
	var cam2 := Camera3D.new()
	cam2.name = "Camera3D"
	arm2.add_child(cam2)
	var target2 := Node3D.new()
	# A bare Node3D has no look_input_enabled property at all — the rig must
	# treat a missing property as enabled (only an explicit false turns it off).
	var visual2 := Node3D.new()
	visual2.name = "Visual"
	target2.add_child(visual2)
	var model := Node3D.new()
	model.name = "PlayerModel"
	target2.add_child(model)
	var head_mesh := MeshInstance3D.new()
	head_mesh.name = "Akane_Head"
	model.add_child(head_mesh)
	var hair_mesh := MeshInstance3D.new()
	hair_mesh.name = "Akane_Hair_Back"
	model.add_child(hair_mesh)
	var body_mesh := MeshInstance3D.new()
	body_mesh.name = "SiroinoSotai_Body"
	model.add_child(body_mesh)
	rig2.target = target2
	add_child(rig2)
	add_child(target2)

	_expect(rig2.invert_y, "vertical look must start inverted (a toggle, not a trap)")
	var free_cam := Freecam.new()
	_expect(free_cam.invert_y, "the free camera must share the inverted-look default")
	free_cam.free()
	rig2.set_first_person(true)
	_expect(model.visible, "first person must keep the figure visible so you can see yourself")
	# Hiding is view-scoped: the head meshes keep rendering for every other
	# observer (third person, photo mode), and only *this* camera culls them —
	# which is what stops a photo taken from the third-person view from
	# losing its head.
	const HEAD_BIT: int = 1 << (CameraRig.FP_HEAD_LAYER - 1)
	_expect(
		cam2.cull_mask & HEAD_BIT == 0,
		"first person must cull the head layer from its own camera"
	)
	_expect(
		head_mesh.layers & HEAD_BIT != 0 and hair_mesh.layers & HEAD_BIT != 0,
		"the head meshes must carry the layer the first-person camera hides"
	)
	_expect(
		head_mesh.visible and hair_mesh.visible,
		"other views must still see the head — hiding must not be global"
	)
	_expect(body_mesh.visible, "first person must keep the body visible")
	rig2.set_first_person(false)
	_expect(
		head_mesh.visible and hair_mesh.visible and body_mesh.visible,
		"leaving first person must restore every mesh"
	)
	_expect(not visual2.visible, "with a model the capsule stays hidden even back in third person")

	# Middle-button height drag: press, drag down raises, drag up lowers, and the
	# release ends it — a drag after release must not move the camera.
	var middle_press := InputEventMouseButton.new()
	middle_press.button_index = MOUSE_BUTTON_MIDDLE
	middle_press.pressed = true
	rig2._unhandled_input(middle_press)
	var before_drag: float = rig2.pivot_height
	var drag_down := InputEventMouseMotion.new()
	drag_down.relative = Vector2(0.0, 120.0)
	rig2._unhandled_input(drag_down)
	_expect(rig2.pivot_height > before_drag, "a downward middle-drag must raise the camera")
	var drag_up := InputEventMouseMotion.new()
	drag_up.relative = Vector2(0.0, -60.0)
	rig2._unhandled_input(drag_up)
	_expect(
		rig2.pivot_height < before_drag + 120.0 * rig2.height_drag_step,
		"an upward middle-drag must lower the camera"
	)
	var middle_release := InputEventMouseButton.new()
	middle_release.button_index = MOUSE_BUTTON_MIDDLE
	middle_release.pressed = false
	rig2._unhandled_input(middle_release)
	var after_release: float = rig2.pivot_height
	rig2._unhandled_input(drag_down)
	_expect(
		is_equal_approx(rig2.pivot_height, after_release),
		"a drag after release must not move the camera"
	)

	rig2.queue_free()
	target2.queue_free()


## The manual sampler must actually move bones: the AnimationMixer was measured
## to advance its cursor without writing any pose in this build (see the
## implementation note in `model_clips.gd`), so this component samples the clip
## itself. A one-bone rig and a two-key library check the write path end to end.
func _check_model_clips() -> void:
	var model := Node3D.new()
	var skeleton := Skeleton3D.new()
	model.add_child(skeleton)
	skeleton.add_bone("TestBone")
	var bone := skeleton.find_bone("TestBone")
	var stance := ModelStance.new()
	stance.name = "Stance"
	model.add_child(stance)
	var clips := ModelClips.new()
	model.add_child(clips)

	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 1.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var track := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(track, NodePath("Skeleton3D:TestBone"))
	anim.track_insert_key(track, 0.0, Quaternion(Vector3.UP, 0.0))
	anim.track_insert_key(track, 0.5, Quaternion(Vector3.UP, 1.0))
	anim.track_insert_key(track, 1.0, Quaternion(Vector3.UP, 0.0))
	lib.add_animation(&"spin", anim)
	# The same loop registered as the walk gear, so the hysteresis test can
	# actually switch back to WALK_CLIP — a library without it fails the
	# switch silently (has_animation is false) and the run clip lingers.
	lib.add_animation(&"walk", anim)
	lib.add_animation(&"jump", anim)
	lib.add_animation(&"fall", anim)
	var run := Animation.new()
	run.length = 0.5
	run.loop_mode = Animation.LOOP_LINEAR
	var run_track := run.add_track(Animation.TYPE_ROTATION_3D)
	run.track_set_path(run_track, NodePath("Skeleton3D:TestBone"))
	run.track_insert_key(run_track, 0.0, Quaternion(Vector3.UP, 2.0))
	run.track_insert_key(run_track, 0.25, Quaternion(Vector3.UP, 3.0))
	run.track_insert_key(run_track, 0.5, Quaternion(Vector3.UP, 2.0))
	lib.add_animation(&"run", run)
	clips.library_override = lib
	clips.setup(model)
	add_child(model)

	clips.debug_play(&"spin")
	_expect(clips._current_clip != null, "debug_play must bind the clip")
	_expect(not stance.is_processing(), "the stance must be muted while a clip owns the pose")
	# Sample a quarter in, by hand — the component's own write path.
	clips._time = 0.25
	clips._apply_sampled_pose(clips._current_clip, 0.25)
	var expected := Quaternion(Vector3.UP, 0.5)
	var got := skeleton.get_bone_pose_rotation(bone)
	_expect(got.angle_to(expected) < 0.01, "manual sampling must land on the interpolated key")
	clips._stop_clip()
	var rest := skeleton.get_bone_rest(bone)
	_expect(
		skeleton.get_bone_pose_rotation(bone).angle_to(rest.basis.get_rotation_quaternion()) < 0.01,
		"stopping must restore the rest pose"
	)

	# Gear selection: driving the brain with a sprint speed must select the run
	# clip, and the gear must hold through the hysteresis window before walking
	# returns — a speed hovering at the threshold must not flip the clip. The
	# brain is a pure function of measured speed, so the test drives it
	# directly instead of fighting the engine's own ticks over model position.
	clips._forced = &""
	clips._walking = false
	clips._running = false
	clips._speed = 0.0
	for i: int in 12:
		clips._decide_gear(1.0 / 30.0, 9.0)  # sprint
	_expect(
		clips._running and clips._current_clip == lib.get_animation(&"run"),
		"sprint speed must select the run clip"
	)
	for i: int in 4:
		clips._decide_gear(1.0 / 30.0, 5.0)  # below the threshold
	_expect(clips._running, "the run gear must hold through the hysteresis window")
	for i: int in 12:
		clips._decide_gear(1.0 / 30.0, 5.0)
	var clip_label: String = "walk" if clips._current_clip == lib.get_animation(&"walk") else "other"
	_expect(
		not clips._running and clips._current_clip == lib.get_animation(&"walk"),
		"below the threshold the walk clip must return after the hold (running=%s clip=%s speed=%.2f gear_t=%.2f)" % [
			clips._running, clip_label, clips._speed, clips._gear_time,
		]
	)

	# Stop transition: releasing the keys must blend the pose into the stance
	# over several frames — the old exit snapped every bone to rest in one
	# frame, which reads as brakes slamming. Feed zero until the walk state
	# releases (the blend window itself is shorter than that deceleration, so
	# a fixed frame count would race it).
	for i: int in 60:
		if not clips._walking:
			break
		clips._decide_gear(1.0 / 30.0, 0.0)
	_expect(clips._blend_active, "stopping must begin a pose blend, not a snap")
	for i: int in 8:
		clips._decide_gear(1.0 / 30.0, 0.0)
	_expect(not clips._blend_active, "the stop blend must finish within its window")

	# Airborne: rising selects the jump action, falling the fall loop, and
	# landing blends the pose back into the stance. Vertical speed is smoothed
	# like the horizontal one, so each phase transition is fed for a handful of
	# ticks rather than a single one.
	for i: int in 5:
		clips._decide_gear(1.0 / 30.0, 0.0, 5.0)
	_expect(
		clips._air_phase == 1 and clips._current_clip == lib.get_animation(&"jump"),
		"rising must play the jump clip"
	)
	# The leap action is shorter than the rise: once it finishes, the fall loop
	# must take over — holding its last frame is the "frozen mid-jump" report.
	for i: int in 32:
		clips._decide_gear(1.0 / 30.0, 0.0, 5.0)
	_expect(
		clips._air_phase == 2 and clips._current_clip == lib.get_animation(&"fall"),
		"a finished leap action must hand over to the fall loop"
	)
	for i: int in 8:
		clips._decide_gear(1.0 / 30.0, 0.0, -5.0)
	_expect(
		clips._air_phase == 2 and clips._current_clip == lib.get_animation(&"fall"),
		"descending must keep the fall clip"
	)
	for i: int in 10:
		clips._decide_gear(1.0 / 30.0, 0.0, 0.0)
	_expect(
		clips._air_phase == 0 and clips._blend_active,
		"landing must blend back into the stance"
	)
	# A landing must not be undone by the smoothed speed still reading negative.
	clips._decide_gear(1.0 / 30.0, 0.0, -5.0)
	_expect(clips._air_phase == 0, "the landing cooldown must hold after touchdown")

	# Cross-fade machinery: a mid-air clip switch snapshots the pose and blends
	# toward the new clip over its window — without it the switch is the
	# one-frame pose snap the jump was reported with.
	clips._start_clip(&"fall", false, true)
	_expect(clips._cross_active, "a cross-faded switch must start a fade")
	for i: int in 5:
		clips._apply_sampled_pose(clips._current_clip, 0.0, 1.0 / 30.0)
	_expect(not clips._cross_active, "the cross-fade must finish within its window")

	clips.queue_free()
	model.queue_free()


## The ambience layer: levels, looping, point sources, teardown.
##
## The load-bearing assertion is the level normalisation. The shipped beds differ
## by up to 13 dB in average level, so one gain for all of them would make the
## ambience lurch every time the sky changed — and the expected gain below is the
## *measured* level of the forest file, which is why it is a number rather than a
## note saying "should be quieter".
func _check_ambience() -> void:
	var buses_before: int = AudioServer.bus_count
	var ambience := Ambience.new()
	add_child(ambience)
	_expect(AudioServer.get_bus_index(Ambience.BUS_NAME) >= 0, "the ambience bus must exist")
	_expect(ambience.describe().contains("无"), "an ambience with no beds must say so")

	var forest: AudioStream = load("res://assets/audio/ambience_forest.ogg")
	var night: AudioStream = load("res://assets/audio/ambience_night.ogg")
	_expect(forest != null and night != null, "the shipped beds must load")
	ambience.set_beds({&"default": forest, &"dusk": night}, &"day", 0.0)
	_expect(ambience.beds_declared() == 2, "the map's beds must be declared")

	var point := ambience.attach_point(forest, Vector3(1.0, 2.0, 3.0))
	_expect(point != null, "a point source must be creatable")
	_expect(
		point != null and is_equal_approx(point.volume_db, Ambience.BED_TARGET_DB - (-24.2)),
		"a bed must be normalised by its measured level, not played raw"
	)
	_expect(
		point != null and point.global_position.is_equal_approx(Vector3(1.0, 2.0, 3.0)),
		"a point source must sit where the map asked for it"
	)
	_expect(
		forest is AudioStreamOggVorbis and (forest as AudioStreamOggVorbis).loop,
		"a bed must be turned into a loop, or the world goes quiet after 45 seconds"
	)

	var unmeasured := AudioStreamOggVorbis.new()
	var raw_point := ambience.attach_point(unmeasured, Vector3.ZERO)
	_expect(
		raw_point != null and is_zero_approx(raw_point.volume_db),
		"a stream this module has never measured must play at its own level"
	)

	var second := Ambience.new()
	add_child(second)
	_expect(AudioServer.bus_count == buses_before + 1, "a second ambience must not add a second bus")
	second.queue_free()

	Events.world_teardown_started.emit()
	_expect(ambience.beds_declared() == 0, "teardown must drop the map's beds")
	_expect(
		point != null and is_instance_valid(point) and point.is_queued_for_deletion(),
		"teardown must release the point sources it owns"
	)
	ambience.queue_free()


## The photo viewfinder: it hides everything, gives it back, and stands down when
## another mode takes over.
##
## The last two checks are the ones worth having. Photo mode is *not* a
## `GameState.Mode`, deliberately, so the only thing stopping it from leaving an
## invisible interface behind a pause menu is that it watches modes and yields —
## which is exactly the kind of behaviour that rots quietly without an assertion.
func _check_photo_mode() -> void:
	var neighbour := CanvasLayer.new()
	add_child(neighbour)
	var photo := PhotoMode.new()
	add_child(photo)

	_expect(not photo.is_active(), "photo mode must start off")
	_expect(not PhotoMode._can_capture(), "a headless run has no frame to capture")
	photo.set_active(true)
	_expect(photo.is_active(), "photo mode must turn on")
	_expect(not neighbour.visible, "photo mode must hide the interface")
	_expect(photo.get_node("PhotoHint").visible, "photo mode must keep its own hint visible")

	photo.set_active(false)
	_expect(neighbour.visible, "leaving photo mode must give the interface back")
	_expect(not photo.is_active(), "photo mode must turn off")

	var mode_was: int = GameState.mode
	photo.set_active(true)
	GameState.mode = GameState.Mode.PAUSED
	_expect(not photo.is_active(), "a pause must stand photo mode down")
	_expect(neighbour.visible, "and give the interface back before the menu opens")
	GameState.mode = mode_was

	photo.queue_free()
	neighbour.queue_free()


## The one line the boot report prints has to stay parseable and name both runtimes,
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


func _run_section(section_name: String, expected_checks: int, body: Callable) -> void:
	print("[selftest] %s" % section_name)
	var before: int = _checks
	body.call()
	var ran: int = _checks - before
	if ran != expected_checks:
		_failures.append("section '%s' declared %d checks but ran %d — it stopped early" % [
			section_name, expected_checks, ran,
		])


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


## The guided tour's spine: stops register (duplicates refused), an arrival stop
## lights on the poll while a checked one waits for its check, the mode flips,
## and every completion is a decision — so replaying the record restores the
## progress, which is exactly what a save load does.
func _check_demo_tour() -> void:
	var tour := DemoTour.new()
	add_child(tour)
	var reached: Array[bool] = [false]
	_expect(
		tour.register_stop(&"alpha", "甲", "提示", "要求", Vector3.ZERO, Callable(), 4.0),
		"a stop must register"
	)
	_expect(
		not tour.register_stop(&"alpha", "重复", "", "", Vector3.ZERO, Callable()),
		"a duplicate stop id must be refused"
	)
	_expect(
		tour.register_stop(&"beta", "乙", "", "", Vector3.ZERO,
			func() -> bool: return reached[0], 4.0),
		"a checked stop must register"
	)
	_expect(tour.stop_count() == 2, "both stops must be present")
	_expect(
		tour.completed_count() == 0 and not tour.is_completed(&"alpha"),
		"nothing is complete before it is demonstrated"
	)
	# A player is needed for the poll to run; an empty Node3D is enough (only
	# the null check and, for arrival stops, a position are used). The mode
	# must be settled too: nothing is judged while the start card is open.
	var dummy := Node3D.new()
	add_child(dummy)
	tour._player = dummy
	tour.set_mode(DemoTour.Mode.TOUR)
	tour._poll_timer = 0.0
	tour._process(0.01)
	_expect(tour.is_completed(&"alpha"), "an arrival stop must light on the poll")
	_expect(not tour.is_completed(&"beta"), "a checked stop must wait for its check")
	reached[0] = true
	tour._poll_timer = 0.0
	tour._process(0.01)
	_expect(tour.is_completed(&"beta"), "the stop must light once its check passes")
	tour.set_mode(DemoTour.Mode.SANDBOX)
	_expect(tour.mode == DemoTour.Mode.SANDBOX, "the mode must be settable")
	DecisionLog.apply_record({
		"kind": "tour_step", "payload": {"step": "gamma"}, "v": 1, "seq": 0, "ts": 0,
	})
	_expect(tour.is_completed(&"gamma"), "a replayed step record must restore progress")


## The radial picker's geometry: sector 0 sits at the top, the rest run
## clockwise, and the centre is a dead zone (releasing there commits nothing).
func _check_tool_wheel() -> void:
	_expect(
		ToolWheel.index_for_offset(Vector2(0.0, -120.0), 4) == 0,
		"the top of the wheel must be sector 0"
	)
	_expect(
		ToolWheel.index_for_offset(Vector2(120.0, 0.0), 4) == 1,
		"sectors must run clockwise from the top"
	)
	_expect(
		ToolWheel.index_for_offset(Vector2(0.0, 12.0), 4) == -1,
		"the centre must be a dead zone"
	)
