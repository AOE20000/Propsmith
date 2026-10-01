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
	_run_section("map-agnostic mobility core", 68, _check_mobility_core)
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
	_expect(first.add_prop_factory("shared_id", func() -> Mesh: return SphereMesh.new()), "first mod could not register")
	_expect(second.add_prop_factory("shared_id", func() -> Mesh: return SphereMesh.new()), "second mod was refused its own registry entry")
	_expect(second.add_prop_factory("unique_id", func() -> Mesh: return BoxMesh.new()), "second mod could not register a unique id")

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
