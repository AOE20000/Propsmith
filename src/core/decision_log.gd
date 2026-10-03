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
## Distributed mode (set by a transport module): clients neither journal nor
## autosave — the host's journal and snapshot are the world's truth.
var journal_enabled: bool = true
var autosave_enabled: bool = true
var _autosave_timer: Timer = null
## Records seen before their applier registered (boot order): replayed once
## the first applier arrives, or on the next game_loaded — whichever is first.
var _replay_pending: bool = true


func _ready() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.timeout.connect(_autosave)
	add_child(_autosave_timer)
	Events.game_saved.connect(_on_game_saved)
	Events.game_loaded.connect(_on_game_loaded)


## The one entry point for world-changing decisions. The caller has already
## applied the change locally (live code keeps its direct path); this journals
## the record (crash-safe append) and hands it to the transport module, if any.
## Replay later re-applies it through the registered applier — the same
## factories the live path used.
func record(kind: StringName, payload: Dictionary) -> void:
	_seq += 1
	var record: Dictionary = {
		"seq": _seq,
		"kind": String(kind),
		"v": PROTOCOL_VERSION,
		"ts": Time.get_unix_time_from_system(),
		"payload": payload,
	}
	decision_applied.emit(kind, payload)
	if journal_enabled:
		_journal_append(record)
	if transport != null and transport.has_method("broadcast"):
		transport.broadcast(record)
	if autosave_enabled:
		_schedule_autosave()


## Apply one record through its registered applier — the remote-decision
## entry point (a transport delivers a peer's decision here) and the replay
## primitive.
func apply_record(record: Dictionary) -> void:
	_apply(record)


## Client mode: the host's journal and snapshot are the world's truth, so the
## local copy neither journals nor autosaves — it only applies what arrives.
func set_client_mode() -> void:
	journal_enabled = false
	autosave_enabled = false


## Back to standalone/local authority (transport stopped).
func restore_local_mode() -> void:
	journal_enabled = true
	autosave_enabled = true


## Host-side entry for a peer's decision: sequence it, journal it, apply it.
## Relaying to the other peers is the transport's job — it knows which peer
## to exclude (the originator already applied the change locally).
func ingest_remote(record: Dictionary) -> void:
	_seq = maxi(_seq, int(record.get("seq", 0)))
	_seq += 1
	record["seq"] = _seq
	_apply(record)
	if journal_enabled:
		_journal_append(record)
	decision_applied.emit(StringName(String(record.get("kind", ""))), record.get("payload", {}))
	if autosave_enabled:
		_schedule_autosave()


## Point the journal at a slot (probes use a dedicated slot so they never
## touch a real save). Emits nothing; subsequent records land in that slot's
## journal.
func use_slot(slot: String) -> void:
	_slot = slot


## The current journal (catch-up payload for late joiners).
func journal_records() -> Array:
	return _journal_read()


## The journal tail a late joiner needs: snapshot-COVERED kinds are already
## reflected in the sandbox snapshot that accompanies the catch-up, so only
## uncovered records are sent — replaying covered ones would double-apply.
func uncovered_records() -> Array:
	var retained: Array = []
	for record: Dictionary in _journal_read():
		var entry: Variant = _appliers.get(StringName(String(record.get("kind", ""))))
		var covered: bool = (entry is Dictionary) and bool((entry as Dictionary).get("covered", true))
		if not covered:
			retained.append(record)
	return retained


## Register the applier for a decision kind. The applier receives the record's
## payload and must apply it exactly as the live path does — replay calls it
## verbatim. First registration flushes any journal replay that was waiting
## for a listener (boot order: the journal may predate every applier).
func register_applier(kind: StringName, applier: Callable, snapshot_covered: bool = true) -> void:
	_appliers[kind] = {"applier": applier, "covered": snapshot_covered}
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
		var entry: Variant = _appliers.get(StringName(String(record.get("kind", ""))))
		if not (entry is Dictionary):
			skipped += 1
			continue
		var applier: Callable = (entry as Dictionary)["applier"]
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
	var entry: Variant = _appliers.get(kind)
	if not (entry is Dictionary):
		push_warning("DecisionLog: no applier for decision kind %s" % kind)
		return
	var applier: Callable = (entry as Dictionary)["applier"]
	applier.call(record.get("payload", {}))
	decision_applied.emit(kind, record.get("payload", {}))


## Compaction: after a save, every snapshot-covered decision is folded into
## the snapshot itself, so the journal keeps only the uncovered tail (state
## the snapshot cannot represent — e.g. NPC appearance overrides). Rewriting
## the file right after the snapshot was written is safe, and the retained
## records are byte-identical copies.
func _compact_journal() -> void:
	var records := _journal_read()
	if records.is_empty():
		return
	var retained: Array = []
	for record: Dictionary in records:
		var entry: Variant = _appliers.get(StringName(String(record.get("kind", ""))))
		var covered: bool = (entry is Dictionary) and bool((entry as Dictionary).get("covered", true))
		if not covered:
			retained.append(record)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOURNAL_DIR))
	var file := FileAccess.open(_journal_path(), FileAccess.WRITE)
	if file == null:
		push_error("DecisionLog: cannot compact journal %s" % _journal_path())
		return
	for record: Dictionary in retained:
		file.store_line(JSON.stringify(record))
	file.close()
	print("[decision_log] compacted: %d -> %d records (slot %s)"
		% [records.size(), retained.size(), _slot])


## Autosave: a decision debounce timer rather than a per-decision write — the
## snapshot sections are cheap to rewrite wholesale at this scale, and the
## journal has already captured every decision durably the moment it happened.
func _schedule_autosave() -> void:
	_autosave_timer.start(AUTOSAVE_DELAY)


func _autosave() -> void:
	SaveSystem.save_game(_slot)


func _on_game_saved(slot: String) -> void:
	_slot = slot
	_compact_journal()


## Loading a slot is an explicit rollback: the snapshot becomes the whole
## truth and the journal tail (decisions made after that save) is obsolete.
## The journal is emptied so a later boot never replays decisions the user
## deliberately rolled back. Crash recovery is the boot-time replay of the
## tail of the last session's journal — before any explicit load.
func _on_game_loaded(slot: String) -> void:
	_slot = slot
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(JOURNAL_DIR))
	var file := FileAccess.open(_journal_path(), FileAccess.WRITE)
	if file != null:
		file.close()
	_replay_pending = false


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
