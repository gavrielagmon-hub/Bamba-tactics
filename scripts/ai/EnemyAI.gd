extends RefCounted
class_name EnemyAI
##
## Fills an AI combatant's [ActionQueue] for the PvE campaign.
##
## Deliberately simple and greedy: score every card in hand, queue the best
## affordable one, repeat until the 3 slots are full or the energy runs out.
## That is enough to feel competent, and it keeps the AI a pure function of
## (hand, board, seed) - so it is deterministic and easy to replace later with
## per-enemy behaviour scripts or an MCTS search over the same interface.
##

## Personality knobs - give each enemy type its own values when you expand.
const HEAL_THRESHOLD := 0.45      ## Below this HP fraction, healing gets urgent.
const ELEMENT_BONUS := 12.0       ## How much the AI values a super-effective hit.
const RANDOM_JITTER := 4.0        ## Keeps fights from being identical every run.


## Queues up to [constant ActionQueue.MAX_SLOTS] actions for [param ai].
## [param seed_value] makes the choice reproducible (required for replays and
## for anything that simulates a fight headlessly).
static func build_queue(ai: Combatant, target: Combatant, seed_value: int = 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	ai.queue.clear()
	while not ai.queue.is_full():
		var best: CardData = null
		var best_score := -INF
		for card in ai.deck.hand:
			if not ai.queue.can_queue(card):
				continue
			var score := _score_card(card, ai, target) + rng.randf_range(0.0, RANDOM_JITTER)
			if score > best_score:
				best_score = score
				best = card
		if best == null:
			break  ## Nothing affordable left - end the plan early.
		ai.queue.try_queue(best, target.combatant_id if best.needs_enemy_target() else ai.combatant_id)


## Rough value of playing [param card] right now. Higher is better.
## Tune the weights here to change how every AI in the game behaves.
static func _score_card(card: CardData, ai: Combatant, target: Combatant) -> float:
	var score := 0.0
	var hp_fraction := float(ai.hp) / float(maxi(1, ai.max_hp))

	match card.effect_type:
		CardData.EffectType.DAMAGE:
			var multiplier := Elements.get_multiplier(card.element, target.affinity)
			score += card.power * multiplier
			if multiplier > 1.0:
				score += ELEMENT_BONUS
			# Finishing blows outrank everything else.
			if int(card.power * multiplier) >= target.hp:
				score += 100.0

		CardData.EffectType.HEAL:
			# Worthless at full HP, top priority when nearly dead.
			var missing := ai.max_hp - ai.hp
			score += minf(card.power, missing) * (2.5 if hp_fraction < HEAL_THRESHOLD else 0.4)

		CardData.EffectType.SHIELD:
			score += card.power * (1.4 if hp_fraction < HEAL_THRESHOLD else 0.8)

		CardData.EffectType.ENERGY:
			score += card.power * 3.0

		CardData.EffectType.DRAW:
			score += card.power * 2.0

		CardData.EffectType.STATUS_ONLY:
			score += 2.0

	# Status value: don't re-apply what is already ticking.
	var fx := card.build_status()
	if fx != null:
		var victim := ai if card.target_mode == CardData.TargetMode.SELF else target
		if victim.has_status(fx.kind):
			score += 1.0
		else:
			score += fx.potency * fx.duration * 0.9
		# Freezing a healthy opponent is far better than freezing a dying one.
		if fx.kind == StatusEffect.Kind.FREEZE:
			score += 10.0

	# Mild preference for cheap cards, so the AI fits three actions in a turn
	# instead of dumping all its energy into one.
	score -= card.mana_cost * 1.5
	return score
