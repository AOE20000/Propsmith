extends Node
## Typed publish/subscribe bus for cross-module events, autoloaded as `Events`.
##
## Modules must not hold references to each other to react to gameplay facts.
## They emit here and subscribe here, which is what keeps a module removable and
## what lets mods observe or extend behaviour without patching core scripts.

## World lifecycle.
signal world_generation_started(seed_value: int)
signal world_generation_progress(step: String, ratio: float)
signal world_ready(world_root: Node3D)
signal world_teardown_started()

## Player lifecycle.
signal player_spawned(player: Node3D)
signal player_died(player: Node3D)
signal player_respawned(player: Node3D)
signal player_stamina_changed(current: float, maximum: float)

## Vehicles. Broadcast, never required: a session with no vehicle system never
## emits these and nothing breaks, which is what keeps the module removable.
signal vehicle_entered(vehicle: Node3D, driver: Node3D)
signal vehicle_exited(vehicle: Node3D, driver: Node3D)
signal vehicle_spawned(vehicle: Node3D, vehicle_id: StringName)

## Exploration.
signal poi_discovered(poi_id: StringName, display_name: String, world_position: Vector3)
signal collectible_picked_up(item_id: StringName, amount: int)
signal interactable_focused(interactable: Node, prompt: String)
signal interactable_unfocused(interactable: Node)
signal region_entered(region_id: StringName, region_name: String)

## Combat extension points. The core only broadcasts; the `combat` module and
## any mod may answer. Systems that need no combat simply never subscribe.
signal damage_requested(info: Resource)
signal damage_applied(info: Resource, target: Node)
signal combatant_died(combatant: Node, killer: Node)
signal attack_started(attacker: Node, attack: Resource)
signal attack_finished(attacker: Node, attack: Resource)

## Mod-to-mod channel. Listeners filter on `mod_id`; the core never emits here.
signal mod_signal(mod_id: StringName, signal_name: StringName, payload: Variant)
signal mod_loaded(mod_id: StringName, display_name: String)
signal mod_failed(mod_id: StringName, reason: String)

## Session and settings.
signal game_mode_changed(previous: int, current: int)
signal game_saved(slot: String)
signal game_loaded(slot: String)
signal notification_posted(text: String, level: int)
signal mods_loaded(mod_ids: PackedStringArray)

enum NotifyLevel { INFO, SUCCESS, WARNING }


## Fire-and-forget notification for the HUD, safe to call with no listener.
func notify(text: String, level: NotifyLevel = NotifyLevel.INFO) -> void:
	notification_posted.emit(text, int(level))


## Await the next occurrence of a lifecycle signal. Handy in the boot sequence:
## `await Events.once(Events.world_ready)`.
func once(event: Signal) -> Variant:
	return await event
