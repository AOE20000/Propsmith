extends RefCounted
class_name UILayers
## The CanvasLayer every UI surface sits on, and the rule for who pauses what.
##
## One table because "which panel is on top" was previously spread across seven
## files, and two of them had quietly agreed on the same number (45) — harmless
## while the two never show at once, and a latent ordering bug the day one opens
## over the other. A panel that needs to sit above another names that panel's
## constant here, so the relationship survives either file being reordered.
##
## ## The pause rule (受影响范围)
##
## A surface pauses the tree **only if it owns the whole screen**: the pause menu,
## the wardrobe, the building panel — menus whose state is meaningless while the
## world keeps moving. Overlays (HUD, minimap, the photo hint) never pause; the
## photo shutter in particular must work exactly when a menu is open, because that
## is when a player reaches for it.
##
## The flip side is scope: anything that must keep running under a menu declares
## `PROCESS_MODE_ALWAYS` for itself — photo mode, the free camera, the mod host,
## the ambience module (a wardrobe that silences the world reads as a crash), and
## the probes, whose whole job is photographing a paused screen. Everything else
## inherits the pause and is expected to stop.

## In-world readouts: health, hints, the minimap. Never pauses, never modal.
const HUD: int = 10
## The pause menu: the lowest of the modal surfaces, so any panel that opens *from*
## it (none yet) would sit above without renumbering.
const PAUSE_MENU: int = 20
## The guided tour's hint card and progress badge: above the HUD (whose corner it
## shares), below the spawn wheel and the wardrobe — the tour never covers a panel
## the player deliberately opened.
const TOUR: int = 35
## The prop spawn wheel: modal while held, but it does not cover the whole screen.
const SPAWN_MENU: int = 40
## The wardrobe. Sits above the spawn wheel because both can be open during an
## edit, and the wardrobe is the one that owns the mouse.
const CHARACTER_PANEL: int = 45
## The building panel: same modal family as the wardrobe, one step above it so the
## two never tie (they used to share 45).
const BUILDING_PANEL: int = 46
## The photo mode hint. Above every gameplay panel so "how do I shoot" survives an
## open menu; below the loading screen so boot covers everything.
const PHOTO_HINT: int = 60
## The loading screen: above all, because it is the thing that hides the boot.
const LOADING_SCREEN: int = 100
