extends Node
## Discovers and runs this project's content mods from `res://mods`, autoloaded as
## `ModHost`.
##
## A mod is a directory containing an entry script (extends `ModBase`) and an
## optional `mod.json` manifest:
##
##     res://mods/example/
##         mod.gd      # entry: GDScript (or `mod.lua` / `mod.sgd`, see below)
##         mod.json    # optional: { "id", "name", "version", "author",
##                     #             "enabled", "dependencies": [] }
##
## The entry may also be written in a language provided by an optional GDExtension:
## `mod.lua` through Lua GDExtension, or `mod.sgd` / `mod.elf` through Godot
## Sandbox. Neither extension is required — `mod.gd` is tried first and a scripted
## entry is only reached when there is no GDScript — and a scripted mod whose
## runtime is missing is reported as a failed mod with instructions rather than
## crashing the scan. See `ScriptingRuntimes` and `ScriptedMod`.
##
## Load order is dependency-aware and deterministic: dependencies first, ties
## broken by id, so two runs of the same build behave identically. A mod that
## cannot be scanned, parsed, or instantiated is disabled for the session while
## every other mod keeps working: mods are additive by contract, never
## load-bearing.
##
## Not to be confused with the `ModLoader` autoload vendored from
## GodotModding/godot-mod-loader, which loads `.zip` mod packages from
## `res://mods` and unpacked trees from `res://mods-unpacked/`. The two do not
## collide because they key on different manifest filenames — `mod.json` here,
## `manifest.json` there.

const MODS_ROOT: String = "res://mods"
const ENTRY_SCRIPT: String = "mod.gd"
const MANIFEST_FILE: String = "mod.json"

## Loaded mods in execution order.
var mods: Array[ModBase] = []
## mod id -> ModContext, for mods that registered successfully.
var contexts: Dictionary = {}
## mod id -> reason, for the settings screen and diagnostics.
var failures: Dictionary = {}

## The merged view of everything mods registered, and the home of the ordering and
## collision rules. Built once: it holds `contexts` by reference, so a registration made
## later is visible without anything having to refresh it.
var content_index: ModContent = null


func _init() -> void:
	content_index = ModContent.new(contexts)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SaveSystem.register_persistent(&"mods", serialize_mods, deserialize_mods)


func _process(delta: float) -> void:
	if mods.is_empty():
		return
	for mod: ModBase in mods:
		mod._on_tick(delta)


## Scan, order, register, and activate every enabled mod. Call `unload_all()`
## first to reload.
func load_all() -> void:
	unload_all()
	failures.clear()

	for candidate: Dictionary in _order_by_dependencies(_scan()):
		if not bool(candidate.get("enabled", true)):
			continue
		var mod: ModBase = _instantiate(candidate)
		if mod == null:
			continue
		mod.context = ModContext.new(mod.mod_id)
		mod._on_register()
		# A scripted mod whose runtime was present but whose code failed to start
		# has registered nothing, so it is dropped exactly like a mod that never
		# instantiated — but with its own reason, which the UI shows.
		if mod is ScriptedMod and not (mod as ScriptedMod).is_started():
			var scripted: ScriptedMod = mod
			_record(scripted.mod_id, scripted.start_error())
			mod.context.release_all()
			mod._on_unload()
			continue
		mods.append(mod)
		contexts[String(mod.mod_id)] = mod.context
		Events.mod_loaded.emit(mod.mod_id, mod.display_name)
		print("[ModHost] loaded %s (%s) v%s" % [mod.display_name, mod.mod_id, mod.version])

	# Cross-mod collisions are a property of the whole loaded set, so they can only be
	# judged once every mod has registered.
	_report_cross_mod_collisions()

	Events.mods_loaded.emit(active_ids())


## Broadcast world generation to mods once the terrain exists.
func notify_world_generate(world: Node3D) -> void:
	for mod: ModBase in mods:
		mod._on_world_generate(world)


## Broadcast population, after core props and POIs are placed.
func notify_world_populate(world: Node3D) -> void:
	for mod: ModBase in mods:
		mod._on_world_populate(world)


func notify_player_spawn(player: Node3D) -> void:
	for mod: ModBase in mods:
		mod._on_player_spawn(player)


func active_ids() -> PackedStringArray:
	var ids: PackedStringArray = []
	for mod: ModBase in mods:
		ids.append(String(mod.mod_id))
	return ids


## Human-readable status lines for the settings screen and the debug overlay.
func describe() -> Array[String]:
	var lines: Array[String] = []
	for mod: ModBase in mods:
		lines.append("%s v%s (%s)" % [mod.display_name, mod.version, mod.mod_id])
	for failed_id: String in failures:
		lines.append("%s [failed: %s]" % [failed_id, failures[failed_id]])
	return lines


## Persistence bridge: every loaded mod contributes one section keyed by mod id,
## so a mod only implements `serialize`/`deserialize` and never touches JSON.
func serialize_mods() -> Dictionary:
	var sections: Dictionary = {}
	for mod: ModBase in mods:
		var section: Dictionary = mod.serialize()
		if not section.is_empty():
			sections[String(mod.mod_id)] = section
	return sections


func deserialize_mods(data: Dictionary) -> void:
	for mod: ModBase in mods:
		var key: String = String(mod.mod_id)
		if data.has(key) and data[key] is Dictionary:
			mod.deserialize(data[key])


## Tear down in reverse load order so a mod that depends on another unloads first.
func unload_all() -> void:
	for index: int in range(mods.size() - 1, -1, -1):
		var mod: ModBase = mods[index]
		mod._on_unload()
		if mod.context != null:
			mod.context.release_all()
	mods.clear()
	contexts.clear()


## Everything registered under one kind across mods, as id -> payload.
##
## The rules — ordering, "first registration for an id wins", and naming collisions — live
## in `ModContent`. This is the loader's stable public seam, so callers keep asking
## `ModHost` rather than reaching for the index; it is also why those rules have a single
## owner instead of being re-derived at each call site.
func content(kind: StringName) -> Dictionary:
	return content_index.of(kind)


## The same registrations, deterministically ordered. Prefer this over `content()` in any
## consumer that iterates: world generation reads it during `build()`, and mod content
## must land in the same order every run for the seed to mean anything.
func content_ordered(kind: StringName) -> Array[Dictionary]:
	return content_index.ordered(kind)


## Attach every cross-mod id collision to the mod that lost it.
##
## `ModContent` detects; the loader records, because the failure list belongs to the
## loader. Without this the collision is invisible: the loser's content simply never
## appears and its author has nothing to go on. Runs once per load, so it costs nothing
## in the paths that call `content()`.
func _report_cross_mod_collisions() -> void:
	for finding: Dictionary in content_index.collisions():
		var reason: String = "%s id '%s' is already claimed by mod '%s' — this registration is ignored" % [
			finding["kind"], finding["id"], finding["winner"],
		]
		push_warning("[ModHost] mod '%s': %s" % [finding["loser"], reason])
		failures[String(finding["loser"])] = reason


## Enumerate candidate mods under MODS_ROOT.
func _scan() -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var dir: DirAccess = DirAccess.open(MODS_ROOT)
	if dir == null:
		# No mods directory is the normal case for a plain checkout.
		return candidates

	for directory_name: String in dir.get_directories():
		var mod_dir: String = "%s/%s" % [MODS_ROOT, directory_name]
		var entry_file: String = _resolve_entry_file(mod_dir)
		if entry_file.is_empty():
			# A directory with no entry script is ignored rather than reported: it
			# may be shared assets or documentation.
			continue

		var manifest: Dictionary = _read_manifest("%s/%s" % [mod_dir, MANIFEST_FILE])
		candidates.append({
			"id": StringName(String(manifest.get("id", directory_name))),
			"display_name": String(manifest.get("name", directory_name)),
			"version": String(manifest.get("version", "1.0.0")),
			"author": String(manifest.get("author", "")),
			"enabled": bool(manifest.get("enabled", true)),
			"dependencies": _string_list(manifest.get("dependencies", [])),
			"dir": mod_dir,
			"entry": "%s/%s" % [mod_dir, entry_file],
			"entry_file": entry_file,
		})
	return candidates


## Which entry script a mod directory provides, in precedence order. `mod.gd`
## wins, so a mod can carry a GDScript shim next to the Lua or sandboxed source it
## is migrating away from.
##
## Presence is tested with `FileAccess` rather than `ResourceLoader`: nobody loads
## `.lua` while Lua GDExtension is absent, so a resource check would silently skip
## the mod and lose the very diagnostic that tells the author what to install.
func _resolve_entry_file(mod_dir: String) -> String:
	for candidate: String in ScriptingRuntimes.entry_precedence():
		if FileAccess.file_exists("%s/%s" % [mod_dir, candidate]):
			return candidate
	return ""


func _string_list(raw: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if raw is Array:
		for entry: Variant in raw:
			out.append(String(entry))
	return out


func _read_manifest(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	push_warning("[ModHost] %s is not valid JSON; using directory defaults" % path)
	return {}


func _instantiate(candidate: Dictionary) -> ModBase:
	var mod_id: StringName = candidate["id"]
	var entry_file: String = String(candidate.get("entry_file", ENTRY_SCRIPT))
	var runtime: StringName = ScriptingRuntimes.runtime_for_entry(entry_file)
	if runtime != &"":
		return _instantiate_scripted(mod_id, candidate, runtime)

	var script_resource: Resource = load(String(candidate["entry"]))
	if script_resource == null or not (script_resource is GDScript):
		_fail(mod_id, "mod.gd is not a loadable GDScript")
		return null

	var instance: Object = (script_resource as GDScript).new()
	if not (instance is ModBase):
		_fail(mod_id, "mod.gd must extend ModBase")
		return null

	var mod: ModBase = instance
	_apply_metadata(mod, candidate)
	return mod


## Build a mod whose entry is a scripted language. The runtime is verified before
## anything is constructed, so a missing GDExtension surfaces as an ordinary mod
## failure carrying the install instructions, instead of a parse error from deep
## inside the loader.
func _instantiate_scripted(mod_id: StringName, candidate: Dictionary, runtime: StringName) -> ModBase:
	if not ScriptingRuntimes.is_available(runtime):
		_fail(mod_id, ScriptingRuntimes.install_hint(runtime))
		return null

	var mod := ScriptedMod.new()
	_apply_metadata(mod, candidate)
	mod.configure(runtime, String(candidate["entry"]), String(candidate.get("entry_file", "")))
	return mod


## Manifest values are copied onto the mod instance the same way for every entry
## language, so `mod.json` behaves identically for a Lua mod and a GDScript one.
func _apply_metadata(mod: ModBase, candidate: Dictionary) -> void:
	mod.mod_id = candidate["id"]
	mod.display_name = String(candidate.get("display_name", mod.mod_id))
	mod.version = String(candidate.get("version", "1.0.0"))
	mod.author = String(candidate.get("author", ""))
	mod.dependencies = candidate.get("dependencies", PackedStringArray())


func _fail(mod_id: StringName, reason: String) -> void:
	_record(mod_id, reason)
	push_error("[ModHost] %s: %s" % [mod_id, reason])


## Record a failure for the mod list and the `mod_failed` signal, without raising a
## second engine error: used when the module that owns the failure already logged it.
func _record(mod_id: StringName, reason: String) -> void:
	failures[String(mod_id)] = reason
	Events.mod_failed.emit(mod_id, reason)


## Depth-first ordering where a mod always follows the mods it depends on. The algorithm
## and its degenerate-case rules live in `ModOrder`.
func _order_by_dependencies(candidates: Array[Dictionary]) -> Array[Dictionary]:
	return ModOrder.order(candidates)