extends RefCounted
class_name Deck
##
## Draw pile / hand / discard pile for one combatant.
##
## [b]Determinism matters here.[/b] In PvP both peers simulate the same round
## locally, so both must shuffle identically. That is why the deck never uses
## the global RNG: it uses a [RandomNumberGenerator] whose seed the host sends
## at match start (see [NetworkManager.start_match]).
##

var draw_pile: Array[CardData] = []
var hand: Array[CardData] = []
var discard_pile: Array[CardData] = []

var _rng := RandomNumberGenerator.new()


## [param cards] is the full deck list; it is copied, not referenced.
## [param seed_value] must be identical on every peer in a PvP match.
func setup(cards: Array[CardData], seed_value: int = 0) -> void:
	draw_pile = cards.duplicate()
	hand.clear()
	discard_pile.clear()
	_rng.seed = seed_value
	_shuffle(draw_pile)


## Draws [param count] cards, reshuffling the discard pile when the draw pile
## runs dry. Returns the cards that were actually drawn.
func draw(count: int) -> Array[CardData]:
	var drawn: Array[CardData] = []
	for _i in count:
		if draw_pile.is_empty():
			if discard_pile.is_empty():
				break  # Deck is genuinely exhausted this turn.
			draw_pile = discard_pile.duplicate()
			discard_pile.clear()
			_shuffle(draw_pile)
		var card: CardData = draw_pile.pop_back()
		hand.append(card)
		drawn.append(card)
	return drawn


## Moves one card from the hand to the discard pile (called when a queued card
## resolves). Silently ignores cards that are not in hand.
func discard_card(card: CardData) -> void:
	var idx := hand.find(card)
	if idx == -1:
		return
	hand.remove_at(idx)
	discard_pile.append(card)


## End-of-turn cleanup: everything still in hand goes to the discard pile.
func discard_hand() -> void:
	discard_pile.append_array(hand)
	hand.clear()


func total_cards() -> int:
	return draw_pile.size() + hand.size() + discard_pile.size()


## Fisher-Yates using the seeded RNG (Array.shuffle() would use the global one).
func _shuffle(pile: Array[CardData]) -> void:
	for i in range(pile.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp := pile[i]
		pile[i] = pile[j]
		pile[j] = tmp
