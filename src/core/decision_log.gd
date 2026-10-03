extends Node
## The single exit for world-changing decisions: apply, journal, broadcast.
##
## Every discrete change to the world (spawn, paint, appearance override,
## blueprint) is *emitted* here as a self-contained record instead of being
## applied ad hoc. The service then:
##   1. applies it through the registered applier for that kind,
##   2. appends the record to the slot's JSONL journal (crash-safe: a killed
##      process never corrupts earlier lines), and
##   3. hands the record to the transport module, if one is active — the
##      multiplayer seam.
## Loading a slot = restore the snapshot sections, then replay that slot's
## journal through the *same* appliers. Continuous state (positions, physics)
## never enters the journal — it belongs to the state-sync layer.
##
## Both ends are pluggable by design:
##   * transport — a module with `broadcast(record)`; none in single-player.
##     Mods can register Nakama / Steam / WebRTC transports without touching
##     this file.
##   * journal backend — currently JSONL per save slot; the decision-log
##     format is the contract, not the file.
##
## Hard rules (violating any breaks replay):
##   * a decision's payload must be self-contained — no references to state
##     that only existed when it was emitted;
##   * replay runs the *same* appliers as live play — never a second
##     "load-time" implementation;
##   * every record carries a protocol version; unknown kinds are skipped
##     silently on replay (a removed mod), warned about live.

const JOURNAL_DIR: String = "user://journal"
const AUTOSAVE_DELAY: float = 5.0
const PROTOCOL_VERSION: int = 1

## Fired after a decision has been applied locally (replay included), so UIs
## can refresh from world state without knowing who changed it.
signal decision_applied(kind: StringName, payload: Dictionary)

## The active transport module, if any. Contract: `broadcast(record: Dictionary)`.
## Set by a networking module (or mod) at runtime; never serialised.
var transport: Object = null

var _appliers: Dictionary = {}
var _seq: int = 0
var _slot: String = "slot1"
var _autosave_timer: Timer = null
## Records seen before their applier registered (boot order): replayed once
## the first applier arrives, or on the next game_loaded — whichever is first.
var _replay_pending: bool = true


func _ready() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.timeout.connect(_autosave)
	add_child(_autosave_timer)
	Events.game_saved.connect(_on_slot_changed)
	Events.game_loaded.connect(_on_slot_changed)


## The one entry point for world-changing decisions. Applies locally, journals
## (crash-safe append), then hands the record to the transport module.
func emit(kind: StringName, payload: Dictionary) -> void:
	_seq += 1
	var record: Dictionary = {
		"seq": _seq,
		"kind": String(kind),
		"v": PROTOCOL_VERSION,
		"ts": Time.get_unix_time_from_system(),
		"payload": payload,
	}
	_apply(record)
	_journal_append(record)
	if transport != null and transport.has_method("broadcast"):
		transport.broadcast(record)
	_schedule_autosave()


## Register the applier for a decision kind. The applier receives the record's
## payload and must apply it exactly as the live path does — replay calls it
## verbatim. First registration flushes any journal replay that was waiting
## for a listener (boot order: the journal may predate every applier).
func register_applier(kind: StringName, applier: Callable) -> void:
	_appliers[kind] = applier
	if _replay_pending:
		_replay_pending = false
		replay_journal()


## Replay this slot's journal through the registered appliers. Unknown kinds
## are counted and skipped — a journal written while a mod was installed must
## still load after the mod is gone.
func replay_journal() -> void:
	var records := _journal_read()
	var skipped := 0
	for record: Dictionary in records:
		_seq = maxi(_seq, int(record.get("seq", 0)))
		var applier: Callable = _appliers.get(StringName(String(record.get("kind", ""))), Callable())
		if not applier.is_valid():
			skipped += 1
			continue
		applier.call(record.get("payload", {}))
		decision_applied.emit(StringName(String(record.get("kind", ""))), record.get("payload", {}))
	if skipped > 0:
		push_warning("DecisionLog: replay skipped %d records with no applier" % skipped)
	print("[decision_log] journal replayed: %d records (slot %s)" % [records.size(), _slot])


## 落地状态自检（探针用）：已注册的 applier 种类。
func registered_kinds() -> PackedStringArray:
	var kinds := PackedStringArray()
	for kind: StringName in _appliers:
		kinds.append(String(kind))
	return kinds


func _apply(record: Dictionary) -> void:
	var kind := StringName(String(record.get("kind", "")))
	var applier: Callable = _appliers.get(kind, Callable())
	if not applier.is_valid():
		push_warning("DecisionLog: no applier for decision kind %s" % kind)
		return
	applier.call(record.get("payload", {}))
	decision_applied.emit(kind, record.get("payload", {}))


## Autosave: a decision debounce timer rather than a per-decision write — the
## snapshot sections are cheap to rewrite wholesale at this scale, and the
## journal has already captured every decision durably the moment it happened.
func _schedule_autosave() -> void:
	_autosave_timer.start(AUTOSAVE_DELAY)


func _autosave() -> void:
	SaveSystem.save_game(_slot)


func _on_slot_changed(slot: String) -> void:
	_slot = slot
	# A different slot's journal may hold decisions this session has not seen;
	# replay it as soon as (or again once) appliers are registered.
	if _appliers.size() > 0:
		replay_journal()
	else:
		_replay_pending = true


## --- JSONL journal backend ---------------------------------------------------
## One record per line, appended on emit. Crash-safe by construction: earlier
## lines are never rewritten, so a killed process loses at most the decision
## it was writing — never the file.

func _journal_path() -> String:
	return "%s/%s.jsonl" % [JOURNAL_DIR, _slot]


func _journal_append(record: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOURNAL_DIR))
	var path := _journal_path()
	var file := FileAccess.open(path, FileAccess.READ_WRITE) \
		if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("DecisionLog: cannot open journal %s" % path)
		return
	file.seek_end()
	file.store_line(JSON.stringify(record))
	file.close()


func _journal_read() -> Array:
	var path := _journal_path()
	if not FileAccess.file_exists(path):
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var records: Array = []
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			records.append(parsed)
	file.close()
	return records
