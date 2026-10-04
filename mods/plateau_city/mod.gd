extends ModBase
## The PLATEAU city, delivered as a mod.
##
## The city is a whole map, not content placed *in* a map, so it registers through
## `add_map_source` and is selected like any other map (`DSH_MAP_SOURCE=shibuya`).
## Being a mod is what keeps it optional: it needs the `godot-plateau` GDExtension
## and a dataset the repository does not ship, and a core that hard-depended on
## either could not run on a plain checkout. As a mod, its absence is one fewer
## entry in the map catalogue rather than a broken import.
##
## The map source itself is a plain `MapSource` subclass that happens to live in this
## directory. It keeps its `class_name` — dev tools (`tools/city_export_activity`)
## reach it by name, and Godot indexes mod scripts the same as any other script in
## the project.

const MAP_SELECTOR: StringName = &"shibuya"


func _on_register() -> void:
	display_name = "涩谷街区（PLATEAU）"
	version = "1.0.0"
	author = "Propsmith"
	# `content_version` comes from mod.json and flows into the map's save identity
	# (`plateau_city:shibuya@<version>`); the dataset fingerprint stays advisory.
	context.add_map_source(PlateauMapSource.new(), MAP_SELECTOR, "涩谷街区（PLATEAU）", content_version)
