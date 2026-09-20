@tool
extends Resource
class_name CardData
##
## A single card / ability. Pure data - a card never touches the scene tree.
##
## Because it is a [Resource] you can author cards in the Inspector:
##   FileSystem -> right click -> New Resource -> CardData -> save as
##   res://resources/cards/fire_fireball.tres
##
## [b]Networking note:[/b] never send a CardData over RPC. Send [member id]
## (a short String) and let the peer look it up in [CardLibrary]. That keeps
## packets tiny and stops a modified client from inventing a 999-damage card.
##

## What the card actually does when it resolves.
enum EffectType {
	DAMAGE,        ## Deal [member power] damage, scaled by the elemental matrix.
	HEAL,          ## Restore [member power] HP.
	SHIELD,        ## Add [member power] temporary shield to the target.
	STATUS_ONLY,   ## No direct number, only applies [member status_kind].
	ENERGY,        ## Refund / grant [member power] energy.
	DRAW,          ## Draw [member power] extra cards.
}

## Who the card is allowed to point at. The UI uses this to decide whether to
## ask the player for a target; the AI uses it to score the card.
enum TargetMode { ENEMY, SELF, ALL_ENEMIES }

@export_group("Identity")
## Stable, unique, lowercase key. This is what travels over the network and
## what save files store, so never rename an id once players have decks.
@export var id: StringName = &""
@export var display_name: String = "New Card"
@export_multiline var description: String = ""
## Path to the card art. Kept as a String (not a Texture2D) so the data stays
## light and can be hot-swapped; use [method get_icon] to load it.
@export_file("*.png", "*.svg") var icon_path: String = ""

@export_group("Cost & Element")
@export var element: Elements.Element = Elements.Element.NONE
## Energy/mana spent when the card is queued. The [ActionQueue] refuses a card
## whose cost does not fit in the energy left after the already-queued slots.
@export_range(0, 10) var mana_cost: int = 1

@export_group("Effect")
@export var effect_type: EffectType = EffectType.DAMAGE
@export var target_mode: TargetMode = TargetMode.ENEMY
## Damage / healing / shield / energy amount, depending on [member effect_type].
@export_range(0, 999) var power: int = 5

@export_group("Status applied")
@export var status_kind: StatusEffect.Kind = StatusEffect.Kind.NONE
@export_range(0, 99) var status_potency: int = 0
@export_range(0, 20) var status_duration: int = 0

@export_group("Progression")
## Shops raise this; [method upgraded] produces the improved copy.
@export_range(0, 5) var upgrade_level: int = 0
@export_range(1, 5) var rarity: int = 1

var _cached_icon: Texture2D = null


## Lazily loads and caches the card art. Returns null when [member icon_path]
## is empty or missing, so the UI should fall back to a placeholder.
func get_icon() -> Texture2D:
	if _cached_icon != null:
		return _cached_icon
	if icon_path.is_empty() or not ResourceLoader.exists(icon_path):
		return null
	_cached_icon = load(icon_path) as Texture2D
	return _cached_icon


## True when the card wants an enemy target chosen by the player.
func needs_enemy_target() -> bool:
	return target_mode != TargetMode.SELF


## Builds the [StatusEffect] instance this card applies, or null if it applies
## none. A fresh instance is returned every time so two targets never share
## the same resource.
func build_status() -> StatusEffect:
	if status_kind == StatusEffect.Kind.NONE or status_duration <= 0:
		return null
	return StatusEffect.create(status_kind, status_potency, status_duration, element)


## Returns an upgraded copy (shops / loot). Tweak the curve here in one place.
func upgraded() -> CardData:
	var copy: CardData = duplicate(true)
	copy.upgrade_level = upgrade_level + 1
	copy.power = int(round(power * 1.25)) + 1
	copy.status_potency = status_potency + (1 if status_potency > 0 else 0)
	copy.display_name = "%s+%d" % [display_name.get_slice("+", 0), copy.upgrade_level]
	return copy


## One-line tooltip text, generated so card text never drifts from card stats.
func summary() -> String:
	var parts: Array[String] = []
	match effect_type:
		EffectType.DAMAGE: parts.append("Deal %d %s damage" % [power, Elements.element_name(element)])
		EffectType.HEAL: parts.append("Restore %d HP" % power)
		EffectType.SHIELD: parts.append("Gain %d shield" % power)
		EffectType.ENERGY: parts.append("Gain %d energy" % power)
		EffectType.DRAW: parts.append("Draw %d card(s)" % power)
		EffectType.STATUS_ONLY: pass
	var fx := build_status()
	if fx != null:
		parts.append("apply %s %d for %d turn(s)" % [fx.label(), fx.potency, fx.duration])
	return ", ".join(parts) + "."
