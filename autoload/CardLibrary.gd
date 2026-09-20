extends Node
##
## Autoload: the single source of truth for card definitions.
##
## Every CardData in [constant CARD_DIR] is loaded once at boot and indexed by
## [member CardData.id]. Decks, save files and network packets all refer to
## cards by that id, so:
##   * packets stay small (a turn is 3 short strings),
##   * a client cannot inject a card the host does not know about,
##   * rebalancing a card updates every deck at once.
##
## Registered in project.godot as the autoload "CardLibrary".
##

const CARD_DIR := "res://resources/cards"

var _cards: Dictionary = {}  ## StringName -> CardData


func _ready() -> void:
	reload()


## Rescans the card directory. Safe to call at runtime (handy while designing).
func reload() -> void:
	_cards.clear()
	var dir := DirAccess.open(CARD_DIR)
	if dir == null:
		push_warning("CardLibrary: '%s' not found - no cards loaded." % CARD_DIR)
		return
	for file_name in dir.get_files():
		# Exported projects rename .tres -> .tres.remap, so strip that first.
		var clean := file_name.trim_suffix(".remap")
		if not clean.ends_with(".tres") and not clean.ends_with(".res"):
			continue
		var card := load(CARD_DIR.path_join(clean)) as CardData
		if card == null:
			continue
		if card.id.is_empty():
			push_warning("CardLibrary: '%s' has an empty id, skipped." % clean)
			continue
		if _cards.has(card.id):
			push_warning("CardLibrary: duplicate card id '%s'." % card.id)
		_cards[card.id] = card
	print("CardLibrary: %d cards loaded." % _cards.size())


## Returns the shared definition for [param id], or null when unknown.
## Callers must NOT mutate the returned resource - use [method instance] when
## the card needs per-run state (upgrades, temporary buffs).
func get_card(id: StringName) -> CardData:
	return _cards.get(id, null)


## A private copy of the card, safe to upgrade or modify per run.
func instance(id: StringName) -> CardData:
	var card := get_card(id)
	return card.duplicate(true) as CardData if card != null else null


func has_card(id: StringName) -> bool:
	return _cards.has(id)


func all_ids() -> Array:
	return _cards.keys()


## Every card of one element - used by loot tables and the shop.
func ids_of_element(element: Elements.Element) -> Array:
	var out: Array = []
	for id in _cards:
		if (_cards[id] as CardData).element == element:
			out.append(id)
	return out


## Builds a deck: one [b]unique[/b] CardData instance per entry, so a deck
## holding three Fireballs holds three distinct objects. That matters because
## the hand, the queue and the discard pile all track cards by identity - with
## shared instances, discarding one copy would discard all of them.
func build_deck(ids: Array) -> Array[CardData]:
	var out: Array[CardData] = []
	for id in ids:
		var card := instance(StringName(id))
		if card == null:
			push_warning("CardLibrary: unknown card id '%s' left out of the deck." % str(id))
			continue
		out.append(card)
	return out


## Turns a list of ids into the shared definitions, dropping (and reporting)
## unknown ones. Use it for read-only lookups; use [method build_deck] when the
## cards will live in someone's deck.
func resolve_ids(ids: Array) -> Array[CardData]:
	var out: Array[CardData] = []
	for id in ids:
		var card := get_card(StringName(id))
		if card == null:
			push_warning("CardLibrary: unknown card id '%s' ignored." % str(id))
			continue
		out.append(card)
	return out
