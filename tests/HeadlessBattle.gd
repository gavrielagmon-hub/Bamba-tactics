extends Node

var battle: BattleManager
var player: Combatant
var enemy: Combatant
var rounds := 0

func _ready() -> void:
	player = Combatant.new()
	player.name = "Player"
	player.display_name = "Bamba"
	player.affinity = Elements.Element.FIRE
	add_child(player)

	enemy = Combatant.new()
	enemy.name = "Enemy"
	enemy.display_name = "Thorn Beast"
	enemy.affinity = Elements.Element.NATURE
	enemy.is_ai = true
	add_child(enemy)

	battle = BattleManager.new()
	battle.action_delay = 0.0
	add_child(battle)
	battle.log_line.connect(func(t): print(t))
	battle.phase_changed.connect(_on_phase)
	battle.battle_ended.connect(func(w, _l):
		print("WINNER: ", w.display_name, " after ", rounds, " rounds")
		get_tree().quit())

	var deck := [&"fire_ember", &"fire_fireball", &"fire_fireball", &"fire_inferno",
		&"neutral_strike", &"neutral_focus", &"neutral_foresight", &"ice_barrier",
		&"nature_bloom", &"ice_frostbite"]
	var edeck := [&"nature_thorns", &"nature_thorns", &"nature_bloom", &"nature_wildgrowth",
		&"ice_bolt", &"ice_frostbite", &"neutral_strike", &"neutral_strike",
		&"ice_barrier", &"fire_ember"]
	battle.start_battle(BattleManager.Mode.PVE, player, enemy, deck, edeck, 12345)

func _on_phase(phase) -> void:
	if phase != BattleManager.Phase.PLANNING:
		return
	rounds += 1
	if rounds > 40:
		print("SAFETY STOP")
		get_tree().quit()
		return
	# queue whatever fits
	for card in player.deck.hand.duplicate():
		if player.queue.is_full():
			break
		player.queue.try_queue(card, enemy.combatant_id if card.needs_enemy_target() else player.combatant_id)
	print("[test] queued %d slots, reserved %d energy" % [player.queue.size(), player.queue.reserved_energy()])
	battle.submit_local_plan.call_deferred()
