extends RenderStyle
class_name RealisticRenderStyle
## The frame the game ships with: whatever mood the map source authored, untouched.
##
## An "identity" style looks like filler until you need it. It is two things at
## once: the zero point the switch measures the stylised styles against, and the
## reset target — `DemoLook.apply_to(preset)` with no overrides writes every key
## back to the authored value, so a session that has been through 3渲2 and a
## mod's noir still lands exactly on the map's own look when it comes back here.
##
## Where "写实" would go if it should mean more than "the map's own look": this is
## a data class, not a behaviour class. Turning on the physically-based aids a
## particular map can afford — screen-space reflections, a wider occlusion radius —
## is a handful of keys returned from `overrides()`, and nothing else here changes.
##
## Deliberately does not force those aids on. They are the one style knob with a
## real frame cost, and a style named "写实" that quietly halves the frame rate on
## the city map would be a worse default than one that leaves the map's own
## decisions alone.

func style_id() -> StringName:
	return &"realistic"


func display_name() -> String:
	return "写实"


## The deviations from the map's authored look. Empty by construction — see the
## class note for what belongs here if this style is ever given teeth.
func overrides() -> Dictionary:
	return {}


func apply(context: Dictionary) -> bool:
	return retune(context, overrides())
