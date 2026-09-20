extends Node

var battle: BattleManager
var me: Combatant
var them: Combatant
var tag := "?"
var rounds := 0

const DECK_A := [&"fire_ember", &"fire_fireball", &"fire_fireball", &"fire_inferno",
	&"neutral_strike", &"neutral_focus", &"neutral_foresight", &"ice_barrier",
	&"nature_bloom", &"ice_frostbite"]
const DECK_B := [&"nature_thorns", &"nature_thorns", &"nature_bloom", &"nature_wildgrowth",
	&"ice_bolt", &"ice_frostbite", &"neutral_strike", &"neutral_strike",
	&"ice_barrier", &"fire_ember"]

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	tag = args[0] if args.size() > 0 else "host"
	NetworkManager.opponent_connected.connect(_on_opp)
	NetworkManager.match_started.connect(_on_match)
	NetworkManager.connection_failed.connect(func(r): print("[%s] FAIL %s" % [tag, r]); get_tree().quit(1))
	if tag == "host":
		print("[host] hosting: ", NetworkManager.host_game())
	else:
		await get_tree().create_timer(1.0).timeout
		print("[client] joining: ", NetworkManager.join_game("127.0.0.1"))

func _on_opp(pid: int) -> void:
	print("[%s] opponent connected: %d" % [tag, pid])
	if NetworkManager.is_authority():
		NetworkManager.start_match()

func _on_match(seed_value: int, is_host: bool) -> void:
	print("[%s] match started seed=%d host=%s" % [tag, seed_value, is_host])
	me = Combatant.new(); me.name = "Player"; me.display_name = "P-" + tag
	me.affinity = Elements.Element.FIRE if is_host else Elements.Element.ICE
	add_child(me)
	them = Combatant.new(); them.name = "Opponent"; them.display_name = "O-" + tag
	them.affinity = Elements.Element.ICE if is_host else Elements.Element.FIRE
	add_child(them)
	me.owner_peer_id = NetworkManager.local_peer_id()
	them.owner_peer_id = NetworkManager.opponent_peer_id

	battle = BattleManager.new(); battle.action_delay = 0.0; add_child(battle)
	battle.log_line.connect(func(t): print("[%s] %s" % [tag, t]))
	battle.phase_changed.connect(_on_phase)
	battle.battle_ended.connect(func(w, local_won):
		print("[%s] RESULT winner=%s local_won=%s hp=%d/%d" % [tag, w.display_name, local_won, me.hp, them.hp])
		get_tree().quit())
	battle.start_battle(BattleManager.Mode.PVP, me, them,
		DECK_A if is_host else DECK_B, DECK_B if is_host else DECK_A, seed_value)

func _on_phase(phase) -> void:
	if phase != BattleManager.Phase.PLANNING:
		return
	rounds += 1
	if rounds > 30:
		print("[%s] SAFETY STOP" % tag); get_tree().quit(1); return
	for card in me.deck.hand.duplicate():
		if me.queue.is_full(): break
		me.queue.try_queue(card, them.combatant_id if card.needs_enemy_target() else me.combatant_id)
	battle.submit_local_plan.call_deferred()
