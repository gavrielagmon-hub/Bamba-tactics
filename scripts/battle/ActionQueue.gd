extends Node
class_name ActionQueue
##
## The 3-slot action queue - the heart of the turn.
##
## Responsibilities (and nothing else):
##   1. Hold up to [constant MAX_SLOTS] queued cards, in order.
##   2. Validate energy/mana cost before a card is allowed in.
##   3. Play the slots back sequentially, honouring Freeze skips.
##   4. Serialise itself to / from a tiny network payload.
##
## It does NOT know what a Fireball does. Applying effects is the resolver's
## job ([BattleManager]), which keeps combat maths in one place and lets you
## unit-test the queue on its own.
##
## Energy model: queuing a card [i]reserves[/i] its cost (so the UI can grey out
## unaffordable cards and the player can freely re-order), and the energy is
## actually spent when the slot executes. Removing a card refunds instantly.
##

## One filled slot. Kept as a class (not a Dictionary) so mistyped keys are
## caught at parse time rather than at 2am during a playtest.
class QueuedAction extends RefCounted:
	var card: CardData
	var target_id: StringName  ## Combatant.combatant_id of the chosen target.

	func _init(p_card: CardData, p_target_id: StringName = &"") -> void:
		card = p_card
		target_id = p_target_id

	func to_dict() -> Dictionary:
		return {"c": String(card.id), "t": String(target_id)}


signal slot_queued(index: int, entry: QueuedAction)
signal slot_removed(index: int)
signal queue_cleared()
signal queue_rejected(card: CardData, reason: String)

signal execution_started()
signal action_started(index: int, entry: QueuedAction)
signal action_resolved(index: int, entry: QueuedAction)
signal action_skipped(index: int, entry: QueuedAction, reason: String)
signal execution_finished()

## The design's "3 actions per turn". Raising this is safe; the UI reads it.
const MAX_SLOTS := 3


## The combatant this queue belongs to. Set by [Combatant._ready].
var owner_combatant: Combatant

var _slots: Array[QueuedAction] = []
var _executing := false


# --------------------------------------------------------------------------
# Queue building (called by the UI in PvE/PvP, by EnemyAI for AI fighters)
# --------------------------------------------------------------------------

func size() -> int:
	return _slots.size()


func is_full() -> bool:
	return _slots.size() >= MAX_SLOTS


func is_empty() -> bool:
	return _slots.is_empty()


func get_slots() -> Array[QueuedAction]:
	return _slots.duplicate()


func get_slot(index: int) -> QueuedAction:
	return _slots[index] if index >= 0 and index < _slots.size() else null


## Energy already promised to queued cards.
func reserved_energy() -> int:
	var total := 0
	for entry in _slots:
		total += entry.card.mana_cost
	return total


## Energy still free for another card this turn.
func available_energy() -> int:
	if owner_combatant == null:
		return 0
	return owner_combatant.energy - reserved_energy()


## Non-mutating check - use it to grey out cards in the hand UI.
## [param reason] is filled in by [method try_queue] for the rejection signal.
func can_queue(card: CardData) -> bool:
	return _rejection_reason(card).is_empty()


func _rejection_reason(card: CardData) -> String:
	if _executing:
		return "The queue is already executing."
	if card == null:
		return "No card."
	if is_full():
		return "All %d action slots are full." % MAX_SLOTS
	if is_queued(card):
		# One card in hand is one physical card: it cannot fill two slots.
		# Queue a second copy from the hand instead.
		return "%s is already queued." % card.display_name
	if card.mana_cost > available_energy():
		return "Not enough energy (%d needed, %d free)." % [card.mana_cost, available_energy()]
	return ""


## True when this exact card object already occupies a slot. Compared by
## identity, not by id, so two copies of Fireball in hand are independent.
func is_queued(card: CardData) -> bool:
	for entry in _slots:
		if entry.card == card:
			return true
	return false


## Finds an unqueued card with [param card_id] in the owner's hand.
## Used when rebuilding a plan that arrived over the network: the peer names a
## card id, and we bind it to a real card in the hand we simulated locally.
func _take_from_hand(card_id: StringName) -> CardData:
	if owner_combatant == null:
		return null
	for card in owner_combatant.deck.hand:
		if card.id == card_id and not is_queued(card):
			return card
	return null


## Appends [param card] to the next free slot.
## Returns true on success; on failure emits [signal queue_rejected] so the UI
## can shake the card / play a buzz without duplicating the rules.
func try_queue(card: CardData, target_id: StringName = &"") -> bool:
	var reason := _rejection_reason(card)
	if not reason.is_empty():
		queue_rejected.emit(card, reason)
		return false
	var entry := QueuedAction.new(card, target_id)
	_slots.append(entry)
	slot_queued.emit(_slots.size() - 1, entry)
	return true


## Removes one slot (player changed their mind). Later slots shift down, which
## is what players expect from a 3-step plan.
func remove_at(index: int) -> void:
	if _executing or index < 0 or index >= _slots.size():
		return
	_slots.remove_at(index)
	slot_removed.emit(index)


## Swaps two slots - lets the player re-order the plan without re-picking.
func swap(a: int, b: int) -> void:
	if _executing:
		return
	if a < 0 or b < 0 or a >= _slots.size() or b >= _slots.size():
		return
	var tmp := _slots[a]
	_slots[a] = _slots[b]
	_slots[b] = tmp


func clear() -> void:
	_slots.clear()
	queue_cleared.emit()


# --------------------------------------------------------------------------
# Networking
# --------------------------------------------------------------------------

## Compact, RPC-safe form: [{"c": "fire_fireball", "t": "Opponent"}, ...]
## Only ids travel - never CardData itself. See [CardLibrary].
func to_payload() -> Array:
	var out: Array = []
	for entry in _slots:
		out.append(entry.to_dict())
	return out


## Rebuilds the queue from a payload received over the network.
##
## [b]This is a trust boundary.[/b] Everything is re-validated here: unknown
## card ids, over-long queues and unaffordable plans are dropped rather than
## trusted, so a modified client cannot queue 6 free Fireballs.
## Returns true when the payload was accepted in full.
func from_payload(payload: Array) -> bool:
	clear()
	var fully_valid := payload.size() <= MAX_SLOTS
	for raw in payload.slice(0, MAX_SLOTS):
		if typeof(raw) != TYPE_DICTIONARY:
			fully_valid = false
			continue
		var card_id := StringName(raw.get("c", ""))
		# Prefer the real card from the locally simulated hand; fall back to
		# the shared definition if the hands have drifted (see README).
		var card := _take_from_hand(card_id)
		if card == null:
			card = CardLibrary.instance(card_id)
			if card != null:
				push_warning("ActionQueue: '%s' was not in the simulated hand; using a fresh copy." % String(card_id))
		if card == null:
			push_warning("ActionQueue: rejected unknown card id '%s'." % String(card_id))
			fully_valid = false
			continue
		if not try_queue(card, StringName(raw.get("t", ""))):
			fully_valid = false
	return fully_valid


# --------------------------------------------------------------------------
# Execution
# --------------------------------------------------------------------------

## Plays the queue back slot by slot.
##
## [param resolver] is intentionally untyped (duck typing) - any object exposing:
##     resolve_action(actor: Combatant, entry: QueuedAction) -> void   (may await)
##     is_battle_over() -> bool
## [BattleManager] implements both. Passing it in (rather than referencing it
## directly) keeps the queue testable and reusable for AI simulation.
func execute(resolver) -> void:
	if _executing:
		return
	_executing = true
	execution_started.emit()

	# Freeze cancels whole slots, starting from the first - so a frozen player
	# loses their opener, which is the scariest part of the effect.
	var slots_to_skip := owner_combatant.frozen_slots() if owner_combatant != null else 0

	for index in _slots.size():
		var entry := _slots[index]

		if owner_combatant != null and not owner_combatant.is_alive():
			action_skipped.emit(index, entry, "defeated")
			continue
		if resolver.is_battle_over():
			action_skipped.emit(index, entry, "battle over")
			continue
		if slots_to_skip > 0:
			slots_to_skip -= 1
			action_skipped.emit(index, entry, "frozen")
			owner_combatant.deck.discard_card(entry.card)
			continue
		# Energy is spent now, not at queue time. Chill landing mid-round can
		# therefore still cut a planned action short - intentional.
		if owner_combatant != null and not owner_combatant.spend_energy(entry.card.mana_cost):
			action_skipped.emit(index, entry, "not enough energy")
			owner_combatant.deck.discard_card(entry.card)
			continue

		action_started.emit(index, entry)
		await resolver.resolve_action(owner_combatant, entry)
		if owner_combatant != null:
			owner_combatant.deck.discard_card(entry.card)
		action_resolved.emit(index, entry)

	_executing = false
	execution_finished.emit()
