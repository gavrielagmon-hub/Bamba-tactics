extends Node
##
## Autoload: everything networking, for the 1v1 PvP mode.
##
## Registered in project.godot as the autoload "NetworkManager", so any script
## can call NetworkManager.host_game() without a node reference.
##
## [b]Architecture: authoritative host, lockstep rounds.[/b]
##   1. Host creates a [WebSocketMultiplayerPeer] server, client joins it.
##   2. Host rolls one [member match_seed] and broadcasts it - both peers then
##      shuffle their decks identically ([Deck] uses that seed), so no card
##      order ever has to travel over the wire.
##   3. Each round, both peers send their 3-slot plan as a tiny array of card
##      ids. The host holds them until both have arrived, then broadcasts the
##      pair. Neither player can see the other's plan early.
##   4. Both peers replay the round locally from the same inputs and the same
##      seed, so they reach the same state without streaming every hit.
##   5. The host then pushes an authoritative snapshot, which corrects any
##      drift and is the value a cheating client cannot talk its way around.
##
## [b]Transport: WebSocketMultiplayerPeer.[/b] Chosen over ENet specifically so
## a browser (web export) build can play - ENet does not run in a web export
## at all, while WebSocket does on every platform Godot targets. Nothing in
## this file's public API (host_game/join_game) or in [BattleManager] cares
## which MultiplayerPeer implementation is underneath; they only see the
## MultiplayerPeer interface.
##
## [b]One real limit this brings:[/b] a browser tab cannot open a listening
## socket, so [method host_game] does not work from a web export - only
## [method join_game] does. Hosting a PvP match therefore has to be a native
## (desktop) build; web-exported players join that host as clients. A pure
## PvE web build needs neither call.
##

signal hosting_started(port: int)
signal join_started(address: String, port: int)
signal connection_failed(reason: String)
## Client-side only: the handshake with the host succeeded.
signal connected_to_host()
signal opponent_connected(peer_id: int)
signal opponent_disconnected(peer_id: int)
signal disconnected_from_host()

## Fired on both peers once the host starts the match.
signal match_started(seed_value: int, local_is_host: bool)
## Fired on both peers once both plans for [param round_index] are in.
## [param plans] maps peer_id -> ActionQueue payload.
signal round_plans_ready(plans: Dictionary, round_index: int)
## Authoritative post-round state from the host.
signal state_synced(snapshots: Array)

const DEFAULT_PORT := 7654
const MAX_PLAYERS := 2
const HOST_PEER_ID := 1

## Peer id of the other player, 0 while nobody is connected.
var opponent_peer_id := 0
## Shared RNG seed for the current match; 0 until the host starts one.
var match_seed := 0

## Host-side buffer: round_index -> { peer_id: payload }.
var _plan_buffer: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --------------------------------------------------------------------------
# Lobby: host / join / leave
# --------------------------------------------------------------------------

## Opens a 2-player WebSocket server on [param port]. Returns OK, or an error
## code (and emits [signal connection_failed]) when the port cannot be opened -
## including on a web export, where opening a listening socket from inside a
## browser tab is not possible at all.
func host_game(port: int = DEFAULT_PORT) -> Error:
	if OS.has_feature("web"):
		connection_failed.emit("A browser tab cannot host a match - run a native build to host, and join it from the browser.")
		return ERR_UNAVAILABLE
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		connection_failed.emit("Could not open port %d (error %d)." % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	hosting_started.emit(port)
	return OK


## Connects to a host. [param address] is an IP or hostname (no scheme, no
## port - e.g. "192.168.1.20", not "ws://192.168.1.20:7654"). Works from a
## native build or a web export alike.
func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	# wss:// (TLS) is required if the page itself is served over https:// -
	# browsers block a plain ws:// connection from a secure page ("mixed
	# content"). Match your deployment: swap this to "wss://" and terminate
	# TLS in front of the game server if you serve the web build over https.
	var url := "ws://%s:%d" % [address, port]
	var err := peer.create_client(url)
	if err != OK:
		connection_failed.emit("Could not reach %s (error %d)." % [url, err])
		return err
	multiplayer.multiplayer_peer = peer
	join_started.emit(address, port)
	return OK


## Tears the session down and returns to offline/PvE state.
func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	opponent_peer_id = 0
	match_seed = 0
	_plan_buffer.clear()


## True on the host - the peer whose word is final.
func is_authority() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func is_online() -> bool:
	return multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func local_peer_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.multiplayer_peer != null else 0


# --------------------------------------------------------------------------
# Match start
# --------------------------------------------------------------------------

## Host only: rolls the shared seed and tells everyone to start.
func start_match() -> void:
	if not is_authority():
		push_warning("NetworkManager: only the host can start the match.")
		return
	if opponent_peer_id == 0:
		push_warning("NetworkManager: nobody has joined yet.")
		return
	_plan_buffer.clear()
	_begin_match.rpc(randi())


## Runs on every peer (call_local) so the host starts at the same moment.
@rpc("authority", "call_local", "reliable")
func _begin_match(seed_value: int) -> void:
	match_seed = seed_value
	match_started.emit(match_seed, is_authority())


# --------------------------------------------------------------------------
# Per-round plan exchange
# --------------------------------------------------------------------------

## Called by [BattleManager] when the local player presses "End Turn".
## [param payload] comes from [ActionQueue.to_payload] - ids only, never cards.
func submit_action_queue(payload: Array, round_index: int) -> void:
	if not is_online():
		push_warning("NetworkManager: submit_action_queue() called while offline.")
		return
	if is_authority():
		# The host is a player too; skip the round trip to itself.
		_store_plan(HOST_PEER_ID, payload, round_index)
	else:
		_receive_action_queue.rpc_id(HOST_PEER_ID, payload, round_index)


## Runs on the host only. "any_peer" because the client is the caller; the
## sender id comes from the multiplayer API, never from the payload, so a
## client cannot submit a plan on its opponent's behalf.
@rpc("any_peer", "call_remote", "reliable")
func _receive_action_queue(payload: Array, round_index: int) -> void:
	if not is_authority():
		return
	_store_plan(multiplayer.get_remote_sender_id(), payload, round_index)


## Host-side buffering: hold plans until both players have committed, then
## release them together. This is what keeps plans secret until execution.
func _store_plan(peer_id: int, payload: Array, round_index: int) -> void:
	if typeof(payload) != TYPE_ARRAY:
		return
	var round_plans: Dictionary = _plan_buffer.get(round_index, {})
	round_plans[peer_id] = payload
	_plan_buffer[round_index] = round_plans

	if round_plans.size() >= MAX_PLAYERS:
		_plan_buffer.erase(round_index)
		_release_plans.rpc(round_plans, round_index)


## Both plans, delivered to both peers at once (call_local includes the host).
@rpc("authority", "call_local", "reliable")
func _release_plans(plans: Dictionary, round_index: int) -> void:
	round_plans_ready.emit(plans, round_index)


# --------------------------------------------------------------------------
# Authoritative state sync
# --------------------------------------------------------------------------

## Host only: publishes the true state after a round so clients can correct
## any divergence. Cheap - two small dictionaries per round.
func push_state_snapshot(snapshots: Array) -> void:
	if not is_authority():
		return
	_receive_state_snapshot.rpc(snapshots)


@rpc("authority", "call_remote", "reliable")
func _receive_state_snapshot(snapshots: Array) -> void:
	# Only clients apply it; the host already holds the authoritative values.
	state_synced.emit(snapshots)


# --------------------------------------------------------------------------
# Multiplayer API callbacks
# --------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	opponent_peer_id = peer_id
	opponent_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id == opponent_peer_id:
		opponent_peer_id = 0
	opponent_disconnected.emit(peer_id)


func _on_connected_to_server() -> void:
	# Godot also emits peer_connected(1) on the client, and that is where
	# opponent_connected comes from - emitting it here too would double-fire.
	opponent_peer_id = HOST_PEER_ID
	connected_to_host.emit()


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit("The host did not answer.")


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	opponent_peer_id = 0
	disconnected_from_host.emit()
	opponent_disconnected.emit(HOST_PEER_ID)
