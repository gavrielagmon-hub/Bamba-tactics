extends RefCounted
class_name Elements
##
## Central definition of the elemental affinity system.
##
## Everything that needs to reason about elements (cards, status effects,
## damage calculation, AI card scoring, UI tinting) goes through this file so
## the matrix lives in exactly one place.
##
## Weakness matrix (as designed):
##     FIRE   beats NATURE
##     NATURE beats ICE
##     ICE    beats FIRE
##
## Usage:
##     var mult := Elements.get_multiplier(Elements.Element.FIRE, Elements.Element.NATURE)
##     # -> 1.5  (strong)
##

## The three playable elements. NONE is for neutral/physical cards that should
## never take part in the weakness triangle (basic attacks, shields, potions...).
enum Element { NONE, FIRE, ICE, NATURE }

## Damage multipliers. Tune these two numbers to rebalance the whole game.
const STRONG_MULTIPLIER := 1.5   ## attacker's element beats defender's
const WEAK_MULTIPLIER := 0.75    ## attacker's element loses to defender's
const NEUTRAL_MULTIPLIER := 1.0  ## no relationship

## "X beats Y" lookup. Keeping it as a dictionary (instead of if/elif chains)
## means adding a 4th element later is a one-line change.
const BEATS := {
	Element.FIRE: Element.NATURE,
	Element.NATURE: Element.ICE,
	Element.ICE: Element.FIRE,
}

## Display colours, handy for card frames / damage numbers in the UI layer.
const COLORS := {
	Element.NONE: Color(0.78, 0.78, 0.82),
	Element.FIRE: Color(0.95, 0.35, 0.18),
	Element.ICE: Color(0.36, 0.72, 0.96),
	Element.NATURE: Color(0.40, 0.80, 0.35),
}


## Returns the damage multiplier for an attack of [param attacker] element
## landing on a defender whose affinity is [param defender].
static func get_multiplier(attacker: Element, defender: Element) -> float:
	if attacker == Element.NONE or defender == Element.NONE:
		return NEUTRAL_MULTIPLIER
	if BEATS.get(attacker, Element.NONE) == defender:
		return STRONG_MULTIPLIER
	if BEATS.get(defender, Element.NONE) == attacker:
		return WEAK_MULTIPLIER
	return NEUTRAL_MULTIPLIER


## True when [param attacker] sits on the winning side of the triangle.
static func is_strong_against(attacker: Element, defender: Element) -> bool:
	return BEATS.get(attacker, Element.NONE) == defender


## Human readable name, used by the combat log and tooltips.
static func element_name(element: Element) -> String:
	return Element.keys()[element].capitalize()


## The status effect an element applies "by default". Cards can override this,
## but it keeps the sample content consistent with the design:
##     Fire -> Burn, Ice -> Chill, Nature -> Poison (offensive) / Regen (support)
static func default_status(element: Element) -> int:
	match element:
		Element.FIRE:
			return StatusEffect.Kind.BURN
		Element.ICE:
			return StatusEffect.Kind.CHILL
		Element.NATURE:
			return StatusEffect.Kind.POISON
		_:
			return StatusEffect.Kind.NONE
