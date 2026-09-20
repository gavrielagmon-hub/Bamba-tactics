extends Node
class_name Combatant
##
## One fighter: the player, an AI enemy, or the remote opponent in PvP.
##
## Holds the mutable battle state (HP, energy, shield, statuses, deck) and owns
## an [ActionQueue] child. It deliberately knows nothing about turn order or
## networking - [BattleManager] drives it, [NetworkManager] only ever ships
## snapshots of it.
##

signal hp_changed(current: int, maximum: int)
signal energy_changed(current: int, maximum: int)
signal shield_changed(current: int)
signal statuses_changed(statuses: Array)
signal died(combatant: Combatant)

enum Team { PLAYER, OPPONENT }

@export var display_name: String = "Fighter"
@export var team: Team = Team.PLAYER
@export var max_hp: int = 40
@export var max_energy: int = 4
## Defensive affinity: the element attacks are compared against in the weakness
## matrix. Leave NONE for a "colourless" fighter that takes flat damage.
@export var affinity: Elements.Element = Elements.Element.NONE
## Cards drawn at the start of each of this combatant's turns.
@export var hand_size: int = 5
## Set true for AI-controlled fighters; [BattleManager] then asks [EnemyAI] to
## fill the queue instead of waiting for UI input.
@export var is_ai: bool = false
## Peer id that controls this combatant in PvP (1 = host). 0 means local/AI.
@export var owner_peer_id: int = 0

var hp: int = 40
var energy: int = 4
var shield: int = 0
var statuses: Array[StatusEffect] = []
var deck := Deck.new()
var queue: ActionQueue

## Stable key used in network payloads, targeting and state snapshots.
##
## It must mean the same thing on both peers, so it cannot be the node name:
## the fighter the host calls "Player" is the one the client calls "Opponent".
## In PvP it is therefore derived from the controlling peer id; offline it
## falls back to the node name, which is unique within the local battle.
var combatant_id: StringName:
	get:
		if owner_peer_id > 0:
			return StringName("peer_%d" % owner_peer_id)
		return StringName(name)


func _ready() -> void:
	# Create the queue as a child so it shows up in the remote scene tree and
	# can be inspected while debugging.
	if queue == null:
		queue = ActionQueue.new()
		queue.name = "ActionQueue"
		add_child(queue)
	queue.owner_combatant = self


## Call once before the first turn. [param deck_ids] is a list of card ids;
## [param seed_value] must match across peers in PvP.
func setup(deck_ids: Array, seed_value: int = 0) -> void:
	hp = max_hp
	energy = max_energy
	shield = 0
	statuses.clear()
	deck.setup(CardLibrary.build_deck(deck_ids), seed_value)
	queue.clear()
	hp_changed.emit(hp, max_hp)
	energy_changed.emit(energy, max_energy)
	statuses_changed.emit(statuses)


# --------------------------------------------------------------------------
# Turn lifecycle
# --------------------------------------------------------------------------

## Start of this combatant's planning phase: shield expires, statuses tick,
## energy refills, a fresh hand is drawn.
## Returns log lines for the combat feed.
func begin_turn() -> Array[String]:
	var log_lines: Array[String] = []

	# Shield is temporary by design - it must be re-applied every turn, which
	# is what makes queuing a defensive slot a real decision.
	shield = 0
	shield_changed.emit(shield)

	# Statuses resolve before anything else so DoT can be lethal.
	var survivors: Array[StatusEffect] = []
	for fx in statuses:
		# Freeze applied during the previous round's execution only bites now.
		fx.active = true
		var line := fx.on_turn_start(self)
		if not line.is_empty():
			log_lines.append(line)
		if not fx.is_expired():
			survivors.append(fx)
	statuses = survivors
	statuses_changed.emit(statuses)

	if not is_alive():
		return log_lines

	# Refill energy, then subtract any chill that landed this turn. Chill is
	# applied inside on_turn_start() above, so re-apply it after the refill.
	energy = max_energy
	for fx in statuses:
		if fx.kind == StatusEffect.Kind.CHILL:
			energy = maxi(0, energy - fx.potency)
	energy_changed.emit(energy, max_energy)

	queue.clear()
	deck.discard_hand()
	deck.draw(hand_size)
	return log_lines


## End of this combatant's turn: statuses the action queue consumes (Freeze)
## expire now that the queue has run, and leftover cards go to the discard pile.
func end_turn() -> void:
	var survivors: Array[StatusEffect] = []
	for fx in statuses:
		if fx.consumed_after_execution() and fx.active:
			fx.duration -= 1
			if fx.is_expired():
				continue
		survivors.append(fx)
	statuses = survivors
	statuses_changed.emit(statuses)

	deck.discard_hand()
	queue.clear()


# --------------------------------------------------------------------------
# Damage / healing / resources
# --------------------------------------------------------------------------

## Applies damage after the elemental matrix and shield.
## [param ignore_shield] is used by Poison.
## Returns the damage actually dealt (useful for floating numbers and the AI).
func take_damage(amount: int, source_element: Elements.Element = Elements.Element.NONE,
		ignore_shield: bool = false) -> int:
	if amount <= 0:
		return 0
	var multiplier := Elements.get_multiplier(source_element, affinity)
	var incoming := int(round(amount * multiplier))

	if not ignore_shield and shield > 0:
		var absorbed := mini(shield, incoming)
		shield -= absorbed
		incoming -= absorbed
		shield_changed.emit(shield)

	hp = maxi(0, hp - incoming)
	hp_changed.emit(hp, max_hp)
	if hp == 0:
		died.emit(self)
	return incoming


func heal(amount: int) -> int:
	var before := hp
	hp = mini(max_hp, hp + maxi(0, amount))
	hp_changed.emit(hp, max_hp)
	return hp - before


func add_shield(amount: int) -> void:
	shield += maxi(0, amount)
	shield_changed.emit(shield)


func gain_energy(amount: int) -> void:
	energy = maxi(0, energy + amount)
	energy_changed.emit(energy, max_energy)


func spend_energy(amount: int) -> bool:
	if amount > energy:
		return false
	energy -= amount
	energy_changed.emit(energy, max_energy)
	return true


func is_alive() -> bool:
	return hp > 0


# --------------------------------------------------------------------------
# Statuses
# --------------------------------------------------------------------------

## Adds a status, merging with an existing one of the same kind.
func add_status(fx: StatusEffect) -> void:
	if fx == null:
		return
	for existing in statuses:
		if existing.kind == fx.kind:
			existing.absorb(fx)
			statuses_changed.emit(statuses)
			return
	statuses.append(fx)
	statuses_changed.emit(statuses)


func get_status(kind: StatusEffect.Kind) -> StatusEffect:
	for fx in statuses:
		if fx.kind == kind:
			return fx
	return null


func has_status(kind: StatusEffect.Kind) -> bool:
	return get_status(kind) != null


## How many of the three action slots Freeze cancels this turn.
## [ActionQueue] asks for this before executing.
func frozen_slots() -> int:
	var fx := get_status(StatusEffect.Kind.FREEZE)
	return fx.potency if fx != null else 0


## Flat modifier added to outgoing damage (Strength up, Weakness down).
func damage_modifier() -> int:
	var modifier := 0
	for fx in statuses:
		if fx.kind == StatusEffect.Kind.STRENGTH:
			modifier += fx.potency
		elif fx.kind == StatusEffect.Kind.WEAKNESS:
			modifier -= fx.potency
	return modifier


func clear_debuffs() -> void:
	var kept: Array[StatusEffect] = []
	for fx in statuses:
		if not fx.is_debuff():
			kept.append(fx)
	statuses = kept
	statuses_changed.emit(statuses)


# --------------------------------------------------------------------------
# Network snapshots
# --------------------------------------------------------------------------

## Compact, RPC-safe picture of this combatant. The host sends one of these
## per combatant at the end of every round so clients can correct any drift.
func to_snapshot() -> Dictionary:
	var fx_list: Array = []
	for fx in statuses:
		fx_list.append({"k": int(fx.kind), "p": fx.potency, "d": fx.duration,
			"e": int(fx.source_element), "a": fx.active})
	return {
		"id": String(combatant_id),
		"hp": hp,
		"energy": energy,
		"shield": shield,
		"fx": fx_list,
	}


## Applies a snapshot received from the authority. Deliberately does not touch
## the deck: card order is reproduced locally from the shared seed.
func apply_snapshot(snapshot: Dictionary) -> void:
	hp = int(snapshot.get("hp", hp))
	energy = int(snapshot.get("energy", energy))
	shield = int(snapshot.get("shield", shield))
	statuses.clear()
	for entry in snapshot.get("fx", []):
		var fx := StatusEffect.create(
			int(entry.get("k", 0)) as StatusEffect.Kind,
			int(entry.get("p", 0)),
			int(entry.get("d", 0)),
			int(entry.get("e", 0)) as Elements.Element)
		fx.active = bool(entry.get("a", false))
		statuses.append(fx)
	hp_changed.emit(hp, max_hp)
	energy_changed.emit(energy, max_energy)
	shield_changed.emit(shield)
	statuses_changed.emit(statuses)
