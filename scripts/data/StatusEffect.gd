extends Resource
class_name StatusEffect
##
## One active status effect sitting on a combatant (burn, chill, poison, ...).
##
## Design split:
##   * [b]Kind[/b] + [b]DEFINITIONS[/b] describe *what a status is* (static data).
##   * An instance of this resource describes *one application of it* on one
##     combatant: how strong, how many turns are left, who applied it.
##
## Statuses resolve at the START of the owner's turn, before cards are drawn,
## so damage-over-time can kill before the victim gets to act.
##

enum Kind {
	NONE,
	BURN,      ## Fire  - damage over time.
	CHILL,     ## Ice   - drains energy, so fewer cards fit in the queue.
	FREEZE,    ## Ice   - hard skip: cancels the first N queued action slots.
	POISON,    ## Nature- damage over time that ignores shield.
	REGEN,     ## Nature- heal over time.
	STRENGTH,  ## Nature- outgoing damage buff.
	WEAKNESS,  ## generic debuff - outgoing damage penalty.
}

## Static description of every status. Add a row here to add a status.
##   debuff        : used by the AI and by "cleanse" style cards.
##   stacks        : true  -> re-applying adds potency & refreshes duration
##                   false -> re-applying only refreshes duration
##   icon          : path used by the HUD (swap for your own art).
const DEFINITIONS := {
	Kind.BURN:     {"label": "Burn",     "debuff": true,  "stacks": true,  "icon": "res://art/status/burn.png"},
	Kind.CHILL:    {"label": "Chill",    "debuff": true,  "stacks": true,  "icon": "res://art/status/chill.png"},
	Kind.FREEZE:   {"label": "Freeze",   "debuff": true,  "stacks": false, "icon": "res://art/status/freeze.png"},
	Kind.POISON:   {"label": "Poison",   "debuff": true,  "stacks": true,  "icon": "res://art/status/poison.png"},
	Kind.REGEN:    {"label": "Regen",    "debuff": false, "stacks": true,  "icon": "res://art/status/regen.png"},
	Kind.STRENGTH: {"label": "Strength", "debuff": false, "stacks": true,  "icon": "res://art/status/strength.png"},
	Kind.WEAKNESS: {"label": "Weakness", "debuff": true,  "stacks": true,  "icon": "res://art/status/weakness.png"},
}

@export var kind: Kind = Kind.NONE
## Meaning depends on kind: damage per turn (BURN/POISON), healing per turn
## (REGEN), energy removed (CHILL), slots cancelled (FREEZE), flat damage
## modifier (STRENGTH/WEAKNESS).
@export var potency: int = 0
## Turns remaining. Decremented once per owner turn; removed at 0.
@export var duration: int = 0
## Element that applied it - lets you write cards like "deal double damage to
## burning targets" or resistance gear later on.
@export var source_element: Elements.Element = Elements.Element.NONE

## Only meaningful for [method consumed_after_execution] statuses (Freeze).
## A status applied in the middle of a round must not expire before the victim
## has had a turn, so it stays inactive until their next turn begins.
var active := false


static func create(p_kind: Kind, p_potency: int, p_duration: int,
		p_source: Elements.Element = Elements.Element.NONE) -> StatusEffect:
	var fx := StatusEffect.new()
	fx.kind = p_kind
	fx.potency = p_potency
	fx.duration = p_duration
	fx.source_element = p_source
	return fx


func label() -> String:
	return DEFINITIONS.get(kind, {}).get("label", "Unknown")


func is_debuff() -> bool:
	return DEFINITIONS.get(kind, {}).get("debuff", false)


func stacks() -> bool:
	return DEFINITIONS.get(kind, {}).get("stacks", false)


## Freeze is the odd one out: it is consumed by [ActionQueue] during the
## execution phase, so it must still be on the combatant while the queue runs.
## Its duration therefore ticks down in [method Combatant.end_turn], not in
## [method on_turn_start] like every other status.
func consumed_after_execution() -> bool:
	return kind == Kind.FREEZE


## Merge a second application of the same kind into this one.
func absorb(other: StatusEffect) -> void:
	if stacks():
		potency += other.potency
	else:
		potency = maxi(potency, other.potency)
	duration = maxi(duration, other.duration)


## Resolves the per-turn part of the status on [param combatant].
## Returns a log line for the combat feed ("" when nothing visible happened).
## Called by Combatant.begin_turn() - never call it yourself from card code.
func on_turn_start(combatant) -> String:
	var line := ""
	match kind:
		Kind.BURN:
			combatant.take_damage(potency, Elements.Element.FIRE, false)
			line = "%s takes %d burn damage." % [combatant.display_name, potency]
		Kind.POISON:
			# Poison bypasses shield on purpose - it is Nature's "chip" tool.
			combatant.take_damage(potency, Elements.Element.NATURE, true)
			line = "%s takes %d poison damage." % [combatant.display_name, potency]
		Kind.REGEN:
			combatant.heal(potency)
			line = "%s regenerates %d HP." % [combatant.display_name, potency]
		Kind.CHILL:
			combatant.energy = maxi(0, combatant.energy - potency)
			line = "%s is chilled (-%d energy)." % [combatant.display_name, potency]
		Kind.FREEZE:
			# Handled by ActionQueue via Combatant.frozen_slots(); nothing to do
			# here except report it.
			line = "%s is frozen (%d action slot(s) lost)." % [combatant.display_name, potency]
		_:
			pass

	# Freeze keeps its duration here - Combatant.end_turn() expires it once the
	# action queue has actually lost its slots.
	if not consumed_after_execution():
		duration -= 1
	return line


## True once the effect should be dropped from the combatant.
func is_expired() -> bool:
	return duration <= 0
