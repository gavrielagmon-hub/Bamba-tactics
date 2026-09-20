extends Node
class_name BattleManager
##
## Drives one battle from start to finish, in both PvE and PvP.
##
## The turn structure is identical in both modes, which is the whole point of
## this design - only [i]where the opponent's plan comes from[/i] changes:
##
##     PLANNING   both sides fill their 3-slot ActionQueue
##                  PvE : player via UI, enemy via EnemyAI (instant)
##                  PvP : player via UI, opponent via NetworkManager
##     EXECUTION  queue A resolves slot by slot, then queue B
##     ROUND_END  end-of-turn cleanup, win/loss check, next round
##
## [BattleManager] is also the [i]resolver[/i] passed to [ActionQueue.execute]:
## it owns all combat maths, so damage rules live in exactly one function.
##

signal phase_changed(phase: Phase)
signal round_started(round_index: int)
signal log_line(text: String)
signal action_played(actor: Combatant, entry: ActionQueue.QueuedAction, target: Combatant)
signal battle_ended(winner: Combatant, local_player_won: bool)
signal waiting_for_opponent()

enum Mode {
	PVE,  ## Local AI opponent, no networking involved.
	PVP,  ## Networked 1v1. The host is the authority.
}

enum Phase {
	SETUP,
	PLANNING,           ## Waiting for the local player to lock in 3 actions.
	WAITING_FOR_PEER,   ## PvP only: our plan is sent, the opponent is still choosing.
	EXECUTION,          ## Queues are resolving.
	ROUND_END,
	FINISHED,
}

## Pause between two resolving actions, so the player can read what happened.
## Set to 0.0 in unit tests / AI simulations to make battles instant.
@export var action_delay := 0.45

var mode: Mode = Mode.PVE
var phase: Phase = Phase.SETUP
var round_index := 0

## The fighter this client controls. In PvE this is always the player.
var local_player: Combatant
## The other side: AI in PvE, the remote player in PvP.
var opponent: Combatant

var _match_seed := 0
## PvP: plans collected for the current round, keyed by peer id.
var _pending_plans: Dictionary = {}


func _ready() -> void:
	# PvP wiring is optional: a pure PvE build can delete these two lines.
	if NetworkManager != null:
		NetworkManager.round_plans_ready.connect(_on_round_plans_ready)
		NetworkManager.opponent_disconnected.connect(_on_opponent_disconnected)


# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

## Starts a battle. [param seed_value] must be identical on both peers in PvP -
## it is what keeps the two local simulations in lockstep (see [Deck]).
func start_battle(p_mode: Mode, p_local: Combatant, p_opponent: Combatant,
		local_deck_ids: Array, opponent_deck_ids: Array, seed_value: int = 0) -> void:
	mode = p_mode
	local_player = p_local
	opponent = p_opponent
	_match_seed = seed_value if seed_value != 0 else randi()
	round_index = 0

	# Each side gets its own deterministic shuffle stream. Set owner_peer_id on
	# both combatants BEFORE calling this in PvP - the seeds depend on it.
	local_player.setup(local_deck_ids, _seed_for(local_player))
	opponent.setup(opponent_deck_ids, _seed_for(opponent))

	local_player.died.connect(_on_combatant_died)
	opponent.died.connect(_on_combatant_died)

	_emit_log("Battle start: %s vs %s." % [local_player.display_name, opponent.display_name])
	_start_round()


# --------------------------------------------------------------------------
# Round flow
# --------------------------------------------------------------------------

func _start_round() -> void:
	round_index += 1
	_pending_plans.clear()
	round_started.emit(round_index)
	_emit_log("--- Round %d ---" % round_index)

	# Both sides refresh at the same time: statuses tick, energy refills, hands
	# are drawn. Doing it simultaneously (rather than per side) is what makes
	# the simultaneous-plan / sequential-resolve structure feel fair.
	for line in local_player.begin_turn():
		_emit_log(line)
	for line in opponent.begin_turn():
		_emit_log(line)

	if _check_battle_over():
		return

	_set_phase(Phase.PLANNING)

	# In PvE the AI commits its plan immediately; it stays hidden until the
	# execution phase, so the player is still planning blind.
	if mode == Mode.PVE and opponent.is_ai:
		EnemyAI.build_queue(opponent, local_player, _match_seed + round_index)


## Called by the UI's "End Turn" / "Execute" button.
func submit_local_plan() -> void:
	if phase != Phase.PLANNING:
		return

	if mode == Mode.PVE:
		_execute_round()
		return

	# PvP: ship the plan and wait. NetworkManager fires round_plans_ready once
	# both peers have submitted for this round.
	_set_phase(Phase.WAITING_FOR_PEER)
	waiting_for_opponent.emit()
	NetworkManager.submit_action_queue(local_player.queue.to_payload(), round_index)


## PvP: both plans have arrived. Rebuild them locally and resolve.
func _on_round_plans_ready(plans: Dictionary, plan_round: int) -> void:
	if mode != Mode.PVP or plan_round != round_index:
		return
	# Our own queue is already built locally; only the opponent's needs
	# rebuilding - and from_payload() re-validates it before trusting it.
	var opponent_payload: Array = plans.get(opponent.owner_peer_id, [])
	if not opponent.queue.from_payload(opponent_payload):
		push_warning("BattleManager: opponent's plan was partially rejected.")
	_execute_round()


func _execute_round() -> void:
	_set_phase(Phase.EXECUTION)
	# Deterministic initiative: in PvP the host's fighter always resolves
	# first, so both peers replay the round in the same order. Swap this for
	# a speed stat or alternating initiative if you prefer.
	for actor in _initiative_order():
		if _check_battle_over():
			break
		_emit_log("%s executes their plan." % actor.display_name)
		await actor.queue.execute(self)
	_end_round()


## Shuffle seed for one fighter.
##
## Both peers must derive the same seed for the same fighter, so it may only
## depend on values both sides agree on: the match seed plus who owns the
## fighter - the peer id in PvP, the team offline. Deriving it from "is this my
## combatant?" would give the two peers different decks for the same player.
func _seed_for(combatant: Combatant) -> int:
	var salt := combatant.owner_peer_id if combatant.owner_peer_id > 0 else int(combatant.team) + 1
	return _match_seed ^ (salt * 0x9E3779B1)


func _initiative_order() -> Array[Combatant]:
	var order: Array[Combatant] = []
	# PvE: the player always leads. PvP: the lower peer id leads, so both
	# peers replay the round in the same order without extra messages.
	if mode == Mode.PVP and opponent.owner_peer_id < local_player.owner_peer_id:
		order.append(opponent)
		order.append(local_player)
	else:
		order.append(local_player)
		order.append(opponent)
	return order


func _end_round() -> void:
	_set_phase(Phase.ROUND_END)
	local_player.end_turn()
	opponent.end_turn()

	# The host is authoritative: it publishes the true post-round state so any
	# client drift (a rounding difference, a rejected card) is corrected.
	if mode == Mode.PVP and NetworkManager.is_authority():
		NetworkManager.push_state_snapshot([local_player.to_snapshot(), opponent.to_snapshot()])

	if _check_battle_over():
		return
	_start_round()


# --------------------------------------------------------------------------
# Resolver interface - called by ActionQueue.execute()
# --------------------------------------------------------------------------

## Applies one queued card. This is the single place where combat maths lives:
## change the damage formula here and every mode, card and AI follows.
func resolve_action(actor: Combatant, entry: ActionQueue.QueuedAction) -> void:
	var card := entry.card
	var target := _resolve_target(actor, entry)

	match card.effect_type:
		CardData.EffectType.DAMAGE:
			var raw := card.power + actor.damage_modifier()
			var dealt := target.take_damage(raw, card.element)
			var multiplier := Elements.get_multiplier(card.element, target.affinity)
			var note := ""
			if multiplier > 1.0:
				note = "  (super effective!)"
			elif multiplier < 1.0:
				note = "  (resisted)"
			_emit_log("%s -> %s for %d damage.%s" % [card.display_name, target.display_name, dealt, note])

		CardData.EffectType.HEAL:
			var healed := target.heal(card.power)
			_emit_log("%s restores %d HP to %s." % [card.display_name, healed, target.display_name])

		CardData.EffectType.SHIELD:
			target.add_shield(card.power)
			_emit_log("%s gains %d shield." % [target.display_name, card.power])

		CardData.EffectType.ENERGY:
			actor.gain_energy(card.power)
			_emit_log("%s gains %d energy." % [actor.display_name, card.power])

		CardData.EffectType.DRAW:
			actor.deck.draw(card.power)
			_emit_log("%s draws %d card(s)." % [actor.display_name, card.power])

		CardData.EffectType.STATUS_ONLY:
			pass  ## The status block below is the entire effect.

	# Statuses land after the direct effect, so a killing blow does not also
	# apply a pointless burn.
	var fx := card.build_status()
	if fx != null and target.is_alive():
		target.add_status(fx)
		_emit_log("%s is afflicted with %s (%d, %d turns)." % [target.display_name, fx.label(), fx.potency, fx.duration])

	action_played.emit(actor, entry, target)

	# Breathing room for animations. Always awaits something so this function
	# stays a coroutine - ActionQueue.execute() awaits it unconditionally.
	if action_delay > 0.0:
		await get_tree().create_timer(action_delay).timeout
	else:
		await get_tree().process_frame


## Part of the resolver interface: lets [ActionQueue] stop mid-plan once
## someone has already been defeated.
func is_battle_over() -> bool:
	return phase == Phase.FINISHED or not local_player.is_alive() or not opponent.is_alive()


## Picks the target for a queued card: the explicit choice when it is still
## valid, otherwise the sensible default for the card's target mode.
func _resolve_target(actor: Combatant, entry: ActionQueue.QueuedAction) -> Combatant:
	if entry.card.target_mode == CardData.TargetMode.SELF:
		return actor
	var other := opponent if actor == local_player else local_player
	if entry.target_id.is_empty():
		return other
	for candidate in [local_player, opponent]:
		if candidate.combatant_id == entry.target_id:
			return candidate
	return other


# --------------------------------------------------------------------------
# Win / loss
# --------------------------------------------------------------------------

func _check_battle_over() -> bool:
	if phase == Phase.FINISHED:
		return true  ## Already resolved - never emit battle_ended twice.
	if local_player.is_alive() and opponent.is_alive():
		return false
	var winner: Combatant = local_player if local_player.is_alive() else opponent
	_set_phase(Phase.FINISHED)
	_emit_log("%s wins!" % winner.display_name)
	battle_ended.emit(winner, winner == local_player)
	return true


func _on_combatant_died(combatant: Combatant) -> void:
	_emit_log("%s is defeated." % combatant.display_name)


## A disconnect mid-match is a win by forfeit. Replace with a reconnect window
## if you add ranked play.
func _on_opponent_disconnected(_peer_id: int) -> void:
	if mode != Mode.PVP or phase == Phase.FINISHED:
		return
	_set_phase(Phase.FINISHED)
	_emit_log("The opponent left the match.")
	battle_ended.emit(local_player, true)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

func _set_phase(new_phase: Phase) -> void:
	if phase == new_phase:
		return
	phase = new_phase
	phase_changed.emit(phase)


func _emit_log(text: String) -> void:
	log_line.emit(text)
