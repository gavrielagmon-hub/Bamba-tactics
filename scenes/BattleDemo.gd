extends Control
##
## Runnable demo that wires every piece together. It is deliberately ugly -
## its job is to prove the architecture runs, and to show the four calls your
## real UI has to make. Replace it, don't build on it.
##
## What it demonstrates:
##   * PvE: player vs an [EnemyAI] opponent, locally.
##   * PvP: host / join on 127.0.0.1 (run two copies of the game), sharing the
##     same [BattleManager] code path.
##   * The only four things a UI must do:
##       1. read combatant.deck.hand           -> draw the hand
##       2. combatant.queue.try_queue(card, t) -> player picks a slot
##       3. battle.submit_local_plan()         -> the "End Turn" button
##       4. listen to battle.log_line / phase_changed -> feedback
##

const PLAYER_DECK := [
	&"fire_ember", &"fire_fireball", &"fire_fireball", &"fire_inferno",
	&"neutral_strike", &"neutral_strike", &"neutral_focus", &"neutral_foresight",
	&"ice_barrier", &"nature_bloom",
]
const ENEMY_DECK := [
	&"nature_thorns", &"nature_thorns", &"nature_bloom", &"nature_wildgrowth",
	&"ice_bolt", &"ice_frostbite", &"neutral_strike", &"neutral_strike",
	&"ice_barrier", &"fire_ember",
]

var battle: BattleManager
var player: Combatant
var enemy: Combatant

var _log: RichTextLabel
var _status: Label
var _queue_box: HBoxContainer
var _hand_box: HBoxContainer
var _end_turn_button: Button


func _ready() -> void:
	_build_ui()

	NetworkManager.opponent_connected.connect(_on_opponent_connected)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.connection_failed.connect(func(reason: String) -> void: _status.text = reason)
	NetworkManager.state_synced.connect(_on_state_synced)


# --------------------------------------------------------------------------
# Starting battles
# --------------------------------------------------------------------------

func _start_pve() -> void:
	_prepare_battle(BattleManager.Mode.PVE, 0)
	enemy.is_ai = true
	battle.start_battle(BattleManager.Mode.PVE, player, enemy, PLAYER_DECK, ENEMY_DECK, randi())


func _host_pvp() -> void:
	if NetworkManager.host_game() == OK:
		_status.text = "Hosting on port %d - waiting for a player." % NetworkManager.DEFAULT_PORT


func _join_pvp() -> void:
	if NetworkManager.join_game("127.0.0.1") == OK:
		_status.text = "Connecting..."


func _on_opponent_connected(peer_id: int) -> void:
	_status.text = "Opponent connected (peer %d)." % peer_id
	# Only the host decides when the match begins.
	if NetworkManager.is_authority():
		NetworkManager.start_match()


func _on_match_started(seed_value: int, local_is_host: bool) -> void:
	_prepare_battle(BattleManager.Mode.PVP, seed_value)
	# Both peers must agree on which Combatant is whose, hence the peer ids.
	player.owner_peer_id = NetworkManager.local_peer_id()
	enemy.owner_peer_id = NetworkManager.opponent_peer_id
	enemy.is_ai = false
	enemy.display_name = "Opponent"
	_status.text = "PvP match started (%s)." % ("host" if local_is_host else "client")

	# The decks are swapped on the client so each player fights with "their"
	# deck while both simulations stay identical.
	var mine := PLAYER_DECK if local_is_host else ENEMY_DECK
	var theirs := ENEMY_DECK if local_is_host else PLAYER_DECK
	battle.start_battle(BattleManager.Mode.PVP, player, enemy, mine, theirs, seed_value)


## Creates a fresh BattleManager and two combatants for a new fight.
func _prepare_battle(_mode: BattleManager.Mode, _seed_value: int) -> void:
	for child in [battle, player, enemy]:
		if child != null:
			child.queue_free()

	player = Combatant.new()
	player.name = "Player"
	player.display_name = "Bamba"
	player.team = Combatant.Team.PLAYER
	player.affinity = Elements.Element.FIRE
	player.max_hp = 40
	player.max_energy = 4
	add_child(player)

	enemy = Combatant.new()
	enemy.name = "Enemy"
	enemy.display_name = "Thorn Beast"
	enemy.team = Combatant.Team.OPPONENT
	enemy.affinity = Elements.Element.NATURE  ## weak to the player's Fire
	enemy.max_hp = 38
	enemy.max_energy = 4
	add_child(enemy)

	battle = BattleManager.new()
	battle.name = "BattleManager"
	add_child(battle)
	battle.log_line.connect(_append_log)
	battle.phase_changed.connect(_on_phase_changed)
	battle.round_started.connect(func(_r: int) -> void: _refresh())
	battle.action_played.connect(func(_a, _e, _t) -> void: _refresh())
	battle.battle_ended.connect(func(winner: Combatant, local_won: bool) -> void:
		_status.text = "%s wins - %s." % [winner.display_name, "you win" if local_won else "you lose"])


# --------------------------------------------------------------------------
# UI reactions
# --------------------------------------------------------------------------

func _on_phase_changed(phase: BattleManager.Phase) -> void:
	_end_turn_button.disabled = phase != BattleManager.Phase.PLANNING
	match phase:
		BattleManager.Phase.PLANNING: _status.text = "Round %d - pick 3 actions." % battle.round_index
		BattleManager.Phase.WAITING_FOR_PEER: _status.text = "Waiting for the opponent..."
		BattleManager.Phase.EXECUTION: _status.text = "Executing..."
		BattleManager.Phase.FINISHED: _status.text = "Battle over."
		_: pass
	_refresh()


func _on_state_synced(snapshots: Array) -> void:
	# Clients trust the host's numbers over their own simulation.
	for snapshot in snapshots:
		for combatant in [player, enemy]:
			if String(combatant.combatant_id) == snapshot.get("id", ""):
				combatant.apply_snapshot(snapshot)
	_refresh()


func _on_card_pressed(card: CardData) -> void:
	player.queue.try_queue(card, enemy.combatant_id if card.needs_enemy_target() else player.combatant_id)
	_refresh()


func _on_slot_pressed(index: int) -> void:
	player.queue.remove_at(index)
	_refresh()


func _append_log(text: String) -> void:
	_log.append_text(text + "\n")


## Redraws hand, queue and the two HP readouts from scratch. Fine for a demo;
## a real UI should react to the combatant signals instead.
func _refresh() -> void:
	if player == null:
		return
	for child in _hand_box.get_children():
		child.queue_free()
	for card in player.deck.hand:
		var button := Button.new()
		button.text = "%s\n%d energy" % [card.display_name, card.mana_cost]
		button.tooltip_text = card.summary()
		button.disabled = not player.queue.can_queue(card) or battle.phase != BattleManager.Phase.PLANNING
		button.pressed.connect(_on_card_pressed.bind(card))
		_hand_box.add_child(button)

	for child in _queue_box.get_children():
		child.queue_free()
	for i in ActionQueue.MAX_SLOTS:
		var entry := player.queue.get_slot(i)
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(130, 44)
		slot.text = "%d. %s" % [i + 1, entry.card.display_name if entry != null else "(empty)"]
		slot.disabled = entry == null
		slot.pressed.connect(_on_slot_pressed.bind(i))
		_queue_box.add_child(slot)

	_end_turn_button.text = "End Turn  -  %s %d/%d HP  vs  %s %d/%d HP  (energy %d)" % [
		player.display_name, player.hp, player.max_hp,
		enemy.display_name, enemy.hp, enemy.max_hp,
		player.queue.available_energy()]


# --------------------------------------------------------------------------
# Throwaway UI construction
# --------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)
	top.add_child(_make_button("Play PvE", _start_pve))
	top.add_child(_make_button("Host PvP", _host_pvp))
	top.add_child(_make_button("Join 127.0.0.1", _join_pvp))
	_status = Label.new()
	_status.text = "Pick a mode."
	top.add_child(_status)

	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	root.add_child(_log)

	_queue_box = HBoxContainer.new()
	root.add_child(_queue_box)
	_hand_box = HBoxContainer.new()
	root.add_child(_hand_box)

	_end_turn_button = Button.new()
	_end_turn_button.text = "End Turn"
	_end_turn_button.disabled = true
	_end_turn_button.pressed.connect(func() -> void: battle.submit_local_plan())
	root.add_child(_end_turn_button)


func _make_button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	return button
