# Bamba Tactics

**Play it:** https://gavrielagmon-hub.github.io/bamba-tactics/ (PvE works
straight from a browser or phone; hosting a PvP match needs a desktop build -
see *PvP: how it works* below.)

This repo holds both the Godot 4 project (open it with the editor to keep
building) and the exported web build in `docs/`, which GitHub Pages serves at
the link above. `docs/` is a build output, not hand-written - regenerate it
with the export command in *Web export* below rather than editing it directly.

---

## Base architecture

Godot 4 (GDScript) skeleton for a 2D turn-based tactical card RPG: a 3-slot
action queue, a three-element weakness triangle with status effects, a PvE AI,
and 1v1 online PvP over WebSocket (works from a native build and from a browser/web export).

Clone this repo and open its folder with the Godot 4 project manager (Import),
then press Play. The demo scene lets you start a PvE fight, or host/join a PvP match.

---

## File map

| File | What it is |
|---|---|
| `scripts/data/CardData.gd` | **Card resource.** id, name, element, mana cost, effect, status, icon path. Authorable in the Inspector. |
| `scripts/battle/ActionQueue.gd` | **The 3-slot queue.** Validates cost, holds order, replays it sequentially, serialises to/from a network payload. |
| `scripts/battle/BattleManager.gd` | **Turn phases + all combat maths.** Drives PvE and PvP through the same code path. |
| `autoload/NetworkManager.gd` | **Multiplayer singleton.** WebSocket host/join, per-round plan exchange, authoritative state sync. |
| `scripts/data/Elements.gd` | The weakness matrix and damage multipliers, in one place. |
| `scripts/data/StatusEffect.gd` | Burn / Chill / Freeze / Poison / Regen / Strength / Weakness. |
| `scripts/battle/Combatant.gd` | One fighter: HP, energy, shield, statuses, deck, and its own ActionQueue. |
| `scripts/battle/Deck.gd` | Draw pile / hand / discard, with a **seeded** shuffle (this is what keeps PvP in sync). |
| `scripts/ai/EnemyAI.gd` | Greedy card scorer that fills an AI fighter's queue. |
| `autoload/CardLibrary.gd` | Loads every `.tres` card at boot and indexes it by id. |
| `scenes/BattleDemo.gd` | Throwaway runnable demo. Replace it — it exists to prove the wiring. |
| `resources/cards/*.tres` | 12 sample cards: 3 Fire, 3 Ice, 3 Nature, 3 neutral. |
| `tests/` | Two headless smoke tests (see *Verifying it still works*). |

---

## Turn flow

The structure is identical in PvE and PvP — only *where the opponent's plan
comes from* changes.

```
ROUND START   shield expires, statuses tick, energy refills, hands are drawn
     |
PLANNING      both sides fill 3 slots
              PvE : you via the UI, the enemy via EnemyAI (instantly, hidden)
              PvP : you via the UI, the opponent via NetworkManager
     |
EXECUTION     first fighter's queue resolves slot by slot, then the other's
     |
ROUND END     leftover cards discarded, host publishes the authoritative state,
              win/loss check, next round
```

Initiative is deterministic: in PvE you always lead; in PvP the lower peer id
(the host) leads, so both peers replay the round in the same order.

## The four calls your UI has to make

Everything else is internal. `scenes/BattleDemo.gd` does exactly this:

```gdscript
# 1. draw the hand
for card in player.deck.hand:
    ...

# 2. player picks a card for the next free slot
player.queue.try_queue(card, enemy.combatant_id)

# 3. the "End Turn" / "Execute" button
battle.submit_local_plan()

# 4. feedback
battle.log_line.connect(_append_log)
battle.phase_changed.connect(_on_phase_changed)
```

`ActionQueue.can_queue(card)` tells you whether to grey a card out, and
`queue_rejected(card, reason)` gives you the reason to show.

---

## Elements and statuses

Fire beats Nature · Nature beats Ice · Ice beats Fire.
A winning matchup deals ×1.5, a losing one ×0.75 — both constants live at the
top of `Elements.gd`.

| Element | Status | Effect |
|---|---|---|
| Fire | Burn | Damage at the start of each of the victim's turns. |
| Ice | Chill | Removes energy on refill, so fewer cards fit in the queue. |
| Ice | Freeze | Cancels the first N queued slots outright. |
| Nature | Poison | Damage over time that **ignores shield**. |
| Nature | Regen / Strength | Healing over time / +damage on everything you play. |

Freeze is the one status that ticks down in `Combatant.end_turn()` rather than
at turn start — it has to still be present while the queue runs, or it would
expire before it could cancel anything.

## Adding a card

Right-click in `resources/cards/` → New Resource → `CardData` → fill it in →
save as `<element>_<name>.tres`. `CardLibrary` picks it up on the next run; no
code change. Give it a unique `id` and never rename that id afterwards — it is
what decks, save files and network packets refer to.

---

## PvP: how it works

Authoritative host, lockstep rounds:

1. Host opens a `WebSocketMultiplayerPeer` server; the client joins.
2. Host rolls **one match seed** and broadcasts it. Both peers shuffle from it,
   so no card order ever travels over the wire.
3. Each round both peers send their plan as three short card ids. The host
   holds both until they have arrived, then releases them together — so neither
   player can see the other's plan early.
4. Both peers replay the round locally from the same inputs, so they reach the
   same state without streaming every hit.
5. The host then pushes an authoritative HP/energy/status snapshot, which
   corrects any drift.

`ActionQueue.from_payload()` is the trust boundary: unknown card ids, over-long
queues and unaffordable plans are rejected rather than trusted.

**Testing it locally:** run two copies of the game, press *Host PvP* in one and
*Join 127.0.0.1* in the other.

**Web export:** already wired up — `NetworkManager` uses `WebSocketMultiplayerPeer`,
which is the one transport Godot supports inside a browser tab. One real limit
this brings: a browser tab cannot open a listening socket, so *Host PvP* only
works from a native (desktop) build; a web-exported build can *Join* a native
host but can't host one itself. A pure PvE web build needs neither call. If you
serve the web build over `https://`, switch the `"ws://"` in
`NetworkManager.join_game()` to `"wss://"` and terminate TLS in front of
whatever machine is hosting — browsers block plain `ws://` from a secure page.

**Important:** set `owner_peer_id` on both combatants *before* calling
`start_battle()` in PvP. Both the deck seeds and the target ids are derived
from it, because a node name means different things on the two peers.

---

## Defaults I picked

Where your brief left a fork, these are the choices — all easy to change:

- **WebSocket rather than ENet.** You named ENet, and it's the lower-friction
  choice for a desktop-only game — but it cannot run inside a browser at all,
  and a web-playable build was the very next ask, so I used
  `WebSocketMultiplayerPeer` from the start. It works identically on desktop.
- **Authoritative host with lockstep replay** rather than streaming every hit.
  Small packets and no desync in practice, at the cost of both peers running
  the same simulation.
- **Simultaneous planning, sequential resolution.** Both sides plan at once,
  then queues resolve one after the other. It keeps PvE and PvP on one code
  path and makes hidden plans meaningful.
- **Shield expires every round**, so a defensive slot is a read on what is
  coming rather than a permanent wall.
- **Energy is reserved when you queue a card and spent when the slot fires**,
  so re-ordering and un-queueing are free, and a mid-round Chill can still cut
  a plan short.
- **12 sample cards, 3 per element plus 3 neutral**, enough to play a real
  fight without being a content pass.

## Verifying it still works

Two headless smoke tests are included. Point `run/main_scene` at one and run
with `--headless`:

```bash
# first run only: build Godot's class cache (opening the project in the
# editor does this for you)
godot --headless --path . --import

# a full PvE battle, start to finish
godot --headless --path . tests/HeadlessBattle.tscn

# PvP: run both, in two terminals
godot --headless --path . tests/HeadlessPvP.tscn -- host
godot --headless --path . tests/HeadlessPvP.tscn -- client
```

Both were run against Godot 4.3 while building this. The PvP test passes when
the two logs mirror each other exactly — same damage numbers, same statuses,
same winner — with no "not in the simulated hand" warnings.

## Web export (playing it in a browser / on a phone)

`docs/` in this repo **is** the exported web build, and GitHub Pages serves it
at https://gavrielagmon-hub.github.io/bamba-tactics/ once Pages is switched on
for this repo (one-time step, see below - I can push code but can't flip that
setting myself). It was built with:

```bash
# one-time: fetch and install the matching export templates
# (godotengine.org/download -> the .tpz for your Godot version)

godot --headless --path . --export-release "Web" docs/index.html
```

Re-run that command and commit `docs/` again whenever the game itself changes
- `docs/` is a build output, never hand-edit it.

The export preset (`export_presets.cfg`) turns **thread support off**. Godot's
threaded web builds need `Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-
Policy` response headers, which GitHub Pages (and most simple static hosts)
doesn't set — the game would show a blank canvas without them. Non-threaded
costs a little performance, not correctness; fine for a turn-based card game.

I checked it actually runs, not just that it exports: served locally and
loaded in a real headless Chromium, Godot boots, all 12 cards load, and
clicking *Play PvE* draws a hand and starts a battle.

**One-time setup to turn the link on:** the GitHub token I push with isn't an
admin on this repo, so I can't flip the Pages switch myself. In this repo's
**Settings → Pages**, under *Build and deployment* set **Source: Deploy from a
branch**, **Branch: `main`**, folder **`/docs`**, then **Save**. GitHub builds
it in a minute or two and the link above goes live - direct link to that
settings page: https://github.com/gavrielagmon-hub/bamba-tactics/settings/pages

**Playing on a phone with no internet involved at all:** on the same Wi-Fi as
a computer, run `python3 -m http.server 8000` inside `docs/` on that computer,
find its local IP (`ipconfig` / `ifconfig`), and open `http://<that-ip>:8000`
in the phone's browser.

---

## Not built yet

The **campaign map** (node-based board, chests, shops, rest stops) is not in
here — your task list asked for the four combat/network files, so that is what
this is. The pieces it needs are ready for it: `CardData.upgraded()` is the
shop's card upgrade, `CardLibrary.ids_of_element()` is a loot table, and
`BattleManager.battle_ended` is the signal a map node would listen to. Say the
word and it's the next piece.
