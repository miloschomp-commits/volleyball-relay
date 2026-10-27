extends SceneTree
# =============================================================================
#  Volleyball relay: the little server that online play goes through. It runs
#  on Godot with no window, so it needs nothing but Godot (and this file):
#      godot --headless --script relay.gd          (PORT, or -- --port=N, sets the port; default 8910)
#
#  What it looks after:
#    PARTIES   A player HOSTS a party and gets a 4-letter code; up to 3 friends JOIN
#              with it. A party stays together between matches. Its leader (seat 0)
#              picks what it plays: Custom (a match among the party), Casual or a Tourney.
#    CASUAL    Players (or a party of two) ask for a match with some rules: 1 v 1 or
#              2 v 2, the mode, the points. Once enough want the same, they're put in a GAME.
#    TOURNEYS  Teams (one player; a party of two; or two strangers paired up) wait until
#              BRACKET teams are in, then play a knockout. The server starts each match,
#              hears who won, and tells everyone where they finished (rank points).
#
#  Matches run on one player's computer (the host); this server only passes their
#  messages on, and never reads them:
#      host  -> everyone else in the room   (the court, ~30 times a second)
#      other -> the host                    (their buttons, with their seat number in front)
#  A GAME is a room the server makes (Casual, Tourney; the host is seat 0). A Custom match
#  uses the party as its room (the leader hosts). Requests and replies are small JSON texts.
#  ONLINE.md says how to put this on a free host so friends anywhere can reach it.
# =============================================================================

const PARTY_MAX := 4
const BRACKET := 4              # teams in a tourney (4, 8, 16...): 4 = two semi-finals, then the final
const TOURNEY_RULES := {"mode": "Classic", "points": 11, "strict": true}     # strict: net touch, no double touches
# Casual: the fun modes and courts a match may ask for (the game's Game.MODES and Game.SCENES)
const MODES := ["Classic", "Big Ball", "Windy", "Spin Madness", "Rally Rush", "Hot Potato", "Heavy Ball", "Ghost Ball",
	"Chaos", "Mega Chaos"]
const SCENES := ["Beach", "Grass", "Sky"]
const GRACE := 45.0             # how long a tourney match waits for players still reading their last Game Over
const LETTERS := "ABCDEFGHJKMNPQRSTUVWXYZ"     # no I, L or O: they look like 1 and 0
const NAME_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "

var server := TCPServer.new()
var peers: Array = []           # everyone connected: see _accept
var parties := {}               # code -> {"members": {seat: peer}}   (seat 0 leads)
var games := {}                 # id -> {"host": peer, "guests": {seat: peer}, "kind", "tourney", "match", "done"}
var queues := {}                # "casual|1 v 1|Classic|7|Basic", "tourney|solo", "tourney|duo" -> [group, ...]
var tourneys := {}              # id -> see _start_tourney
var next_id := 1
var clock := 0.0
var lag := 0.0                  # testing: hold game bytes back this long (-- --lag=ms), like a slow connection
var held_back: Array = []       # [when to send, peer, bytes]


func _initialize() -> void:
	var port := 8910
	if OS.get_environment("PORT") != "":
		port = int(OS.get_environment("PORT"))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
		if arg.begins_with("--lag="):
			lag = int(arg.trim_prefix("--lag=")) / 1000.0
	Engine.max_fps = 120                         # plenty, without spinning the CPU
	var err := server.listen(port, "*")
	print("Volleyball relay %s on port %d" % ["listening" if err == OK else "FAILED (%d)" % err, port])


func _process(delta: float) -> bool:
	clock += delta
	while server.is_connection_available():
		_accept(server.take_connection())
	for p: Dictionary in peers.duplicate():
		var ws: WebSocketPeer = p.ws
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var data := ws.get_packet()
				if ws.was_string_packet():
					_request(p, data.get_string_from_utf8())
				else:
					_pass_on(p, data)
		elif state == WebSocketPeer.STATE_CLOSED:
			_gone(p)
			peers.erase(p)
	for t: Dictionary in tourneys.values():
		_tourney_step(t)
	while not held_back.is_empty() and held_back[0][0] <= clock:
		var late: Array = held_back.pop_front()
		_send_now(late[1], late[2])
	return false


func _accept(stream: StreamPeerTCP) -> void:
	var ws := WebSocketPeer.new()
	ws.inbound_buffer_size = 1 << 20
	ws.outbound_buffer_size = 1 << 20
	ws.set("heartbeat_interval", 20.0)           # free hosts drop quiet connections
	ws.accept_stream(stream)
	peers.append({
		"id": next_id, "ws": ws, "open": true,
		"name": "Player", "look": {},            # from their "hello"
		"party": "", "pseat": -1,                # their party's code, their seat in it
		"game": 0, "gseat": -1,                  # the game they're in, their seat in it
		"queue": "",                             # what they're looking for (a key of queues)
		"tourney": 0,                            # the tourney they're in (until they leave its screen)
	})
	next_id += 1


func _send(p: Dictionary, msg: Dictionary) -> void:
	if p.open and (p.ws as WebSocketPeer).get_ready_state() == WebSocketPeer.STATE_OPEN:
		(p.ws as WebSocketPeer).send_text(JSON.stringify(msg))


func _send_bytes(p: Dictionary, data: PackedByteArray) -> void:
	if lag > 0.0:
		held_back.append([clock + lag, p, data])
	else:
		_send_now(p, data)


func _send_now(p: Dictionary, data: PackedByteArray) -> void:
	if p.open and (p.ws as WebSocketPeer).get_ready_state() == WebSocketPeer.STATE_OPEN:
		(p.ws as WebSocketPeer).send(data)


func _error(p: Dictionary, why: String) -> void:
	_send(p, {"type": "error", "why": why})


## Game bytes. In a game: the host's go to everyone, the others' to the host (seat first).
## Otherwise the party is the room (a Custom match): the leader's to everyone, the others' to the leader.
func _pass_on(p: Dictionary, data: PackedByteArray) -> void:
	if p.game != 0:
		var g: Dictionary = games.get(p.game, {})
		if g.is_empty():
			return
		if g.host == p:
			for m: Dictionary in g.guests.values():
				_send_bytes(m, data)
		else:
			_send_bytes(g.host, _with_seat(p.gseat, data))
	elif p.party != "":
		var members: Dictionary = parties.get(p.party, {}).get("members", {})
		var leader = members.get(0)
		if leader == null:
			return
		if leader == p:
			for m: Dictionary in members.values():
				if m != p and m.game == 0:
					_send_bytes(m, data)
		elif leader.game == 0:
			_send_bytes(leader, _with_seat(p.pseat, data))


static func _with_seat(seat: int, data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([seat])
	out.append_array(data)
	return out


func _request(p: Dictionary, text: String) -> void:
	var msg = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	match str(msg.get("type", "")):
		"hello":
			p.name = _clean_name(msg.get("name", ""))
			p.look = _clean_look(msg.get("look", {}))
			if p.party != "":
				_party_update(p.party)
		"host":
			_host(p)
		"join":
			_join(p, str(msg.get("code", "")).strip_edges().to_upper())
		"leave_party":
			_leave_party(p)
		"say":
			if p.party != "" and p.pseat == 0:
				for m: Dictionary in parties[p.party].members.values():
					if m != p:
						_send(m, {"type": "said", "text": str(msg.get("text", "")).left(80)})
		"casual":
			_casual(p, msg)
		"tourney":
			_tourney_entry(p, str(msg.get("how", "solo")))
		"cancel":
			_cancel(p, "Search cancelled.")
		"leave_game":
			_leave_game(p)
		"leave_tourney":
			_leave_tourney(p)
		"result":
			_result(p, msg)


## A name of letters, numbers and spaces, 20 at most; a look of short words.
static func _clean_name(raw) -> String:
	var out := ""
	for c in str(raw).left(20):
		if NAME_CHARS.contains(c):
			out += c
	out = out.strip_edges()
	return out if out != "" and not _rude(out) else "Player"


static func _clean_look(raw) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for key in ["color", "pants"]:
			if raw.has(key):
				out[key] = str(raw[key]).left(16)
	return out


## Busy: in a game, looking for one, or still in the running in a tourney.
func _busy(p: Dictionary) -> bool:
	if p.game != 0 or p.queue != "":
		return true
	var t: Dictionary = tourneys.get(p.tourney, {})
	return not t.is_empty() and not t.done and not t.out.has(p.id)


## Who goes along when this player picks something: their party, or just them.
func _group(p: Dictionary) -> Array:
	if p.party == "":
		return [p]
	var members: Dictionary = parties[p.party].members
	var seats := members.keys()
	seats.sort()
	return seats.map(func(s): return members[s])


# --- parties ----------------------------------------------------------------------

func _host(p: Dictionary) -> void:
	if _busy(p):
		_error(p, "Finish what you're doing first.")
		return
	_leave_party(p)
	var code := ""
	while code == "" or parties.has(code):
		code = ""
		for i in 4:
			code += LETTERS[randi() % LETTERS.length()]
	parties[code] = {"members": {0: p}}
	p.party = code
	p.pseat = 0
	_party_update(code)


func _join(p: Dictionary, code: String) -> void:
	var party: Dictionary = parties.get(code, {})
	if party.is_empty():
		_error(p, "No party with the code %s." % code)
		return
	if p.party == code:
		_party_update(code)
		return
	if party.members.size() >= PARTY_MAX:
		_error(p, "That party is full.")
		return
	for m: Dictionary in party.members.values():
		if m.queue != "":
			_error(p, "That party is looking for a match: try again in a moment.")
			return
	if _busy(p):
		_error(p, "Finish what you're doing first.")
		return
	_leave_party(p)
	var seat := 1
	while party.members.has(seat):
		seat += 1
	party.members[seat] = p
	p.party = code
	p.pseat = seat
	_party_update(code)


## Everyone in the party hears who's in it (and their own seat).
func _party_update(code: String) -> void:
	var members: Dictionary = parties[code].members
	var list: Array = []
	for m: Dictionary in _group(members[members.keys()[0]]):
		list.append({"seat": m.pseat, "name": m.name, "look": m.look})
	for m: Dictionary in members.values():
		_send(m, {"type": "party", "code": code, "seat": m.pseat, "members": list})


## Out of the party. If the leader goes, the party closes.
func _leave_party(p: Dictionary) -> void:
	if p.party == "":
		return
	_cancel(p, "A player left the party, so the search stopped.")
	var code: String = p.party
	var members: Dictionary = parties[code].members
	members.erase(p.pseat)
	var was_leader: bool = p.pseat == 0
	p.party = ""
	p.pseat = -1
	if was_leader or members.is_empty():
		for m: Dictionary in members.values():
			m.party = ""
			m.pseat = -1
			_send(m, {"type": "party_closed", "why": "The party leader left, so the party closed."})
		parties.erase(code)
	else:
		_party_update(code)


# --- looking for a match -----------------------------------------------------------

func _casual(p: Dictionary, msg: Dictionary) -> void:
	if p.pseat > 0:
		_error(p, "Only the party leader picks what to play.")
		return
	var format := "2 v 2" if str(msg.get("format", "")) == "2 v 2" else "1 v 1"
	var mode := str(msg.get("mode", ""))
	if not mode in MODES:
		mode = "Classic"
	var scene := str(msg.get("scene", ""))
	if not scene in SCENES:
		scene = "Beach"
	var points := clampi(int(msg.get("points", 7)), 3, 21)
	var group := _group(p)
	if group.size() > (2 if format == "2 v 2" else 1):
		_error(p, "Your party is too big for %s." % format)
		return
	if group.any(func(m): return _busy(m)):
		_error(p, "Someone in your party is busy.")
		return
	var key := "casual|%s|%s|%d|%s" % [format, mode, points, scene]
	_enqueue(key, group)
	var found := _form_teams(queues[key], 2 if format == "2 v 2" else 1, 2)
	if not found.is_empty():
		_dequeue(key, found.used)
		_start_game(found.teams, "casual", {"mode": mode, "points": points, "scene": scene}, 0, -1,
				2 if format == "2 v 2" else 1)


func _tourney_entry(p: Dictionary, how: String) -> void:
	if p.pseat > 0:
		_error(p, "Only the party leader picks what to play.")
		return
	var group := _group(p)
	if how == "partner" and group.size() != 2:
		_error(p, "With a partner: be in a party of two.")
		return
	if how != "partner" and group.size() != 1:
		_error(p, "Solo and random partner are for one player: leave the party first.")
		return
	if group.any(func(m): return _busy(m)):
		_error(p, "Someone in your party is busy.")
		return
	for m: Dictionary in group:
		_leave_tourney(m)                   # done looking at the last one
	var key := "tourney|solo" if how == "solo" else "tourney|duo"
	var per_team := 1 if how == "solo" else 2
	_enqueue(key, group)
	var found := _form_teams(queues[key], per_team, BRACKET)
	if not found.is_empty():
		_dequeue(key, found.used)
		_start_tourney(found.teams, per_team)


func _enqueue(key: String, group: Array) -> void:
	if not queues.has(key):
		queues[key] = []
	queues[key].append(group)
	for m: Dictionary in group:
		m.queue = key
	_queue_update(key)


func _dequeue(key: String, groups: Array) -> void:
	for g: Array in groups:
		queues[key].erase(g)
		for m: Dictionary in g:
			m.queue = ""
	_queue_update(key)


## Teams from the groups waiting, oldest first: a group of the right size is a team;
## for teams of two, players on their own are paired up. Empty until there are `want` teams.
static func _form_teams(waiting: Array, per_team: int, want: int) -> Dictionary:
	var teams: Array = []
	var used: Array = []
	var spare = null
	for g: Array in waiting:
		if g.size() == per_team:
			teams.append(g.duplicate())
			used.append(g)
		elif per_team == 2 and g.size() == 1:
			if spare == null:
				spare = g
			else:
				teams.append(spare + g)
				used.append(spare)
				used.append(g)
				spare = null
		if teams.size() == want:
			return {"teams": teams, "used": used}
	return {}


## Everyone waiting hears how many are waiting (and, for a tourney, how many teams that makes).
func _queue_update(key: String) -> void:
	var waiting: Array = queues.get(key, [])
	if waiting.is_empty():
		queues.erase(key)
		return
	var players := 0
	var teams := 0
	var solos := 0
	for g: Array in waiting:
		players += g.size()
		if g.size() == 2 or key == "tourney|solo":
			teams += 1
		else:
			solos += 1
	teams += solos / 2
	var msg := {"type": "searching", "what": key.get_slice("|", 0), "key": key, "players": players}
	if key.begins_with("tourney"):
		msg.teams = teams
		msg.need = BRACKET
	for g: Array in waiting:
		for m: Dictionary in g:
			_send(m, msg)


## Stop looking: the player's whole group comes out of the queue.
func _cancel(p: Dictionary, why: String) -> void:
	var key: String = p.queue
	if key == "":
		return
	for g: Array in queues.get(key, []):
		if g.has(p):
			_dequeue(key, [g])
			for m: Dictionary in g:
				_send(m, {"type": "cancelled", "why": why})
			return
	p.queue = ""


# --- games ----------------------------------------------------------------------

## A game for two teams. Seats: the first team 0 and 2 (the left), the other 1 and 3;
## seat 0 hosts. Missing places on a team of two are played by a bot (a partner who left).
func _start_game(teams: Array, kind: String, rules: Dictionary, tourney_id: int, match_index: int, size: int) -> int:
	var id := next_id
	next_id += 1
	var g := {"id": id, "host": null, "guests": {}, "kind": kind, "tourney": tourney_id, "match": match_index,
		"done": false}
	var lineup := {"left": [], "right": []}
	var looks := {}
	var names := {}
	var team_names: Array = []
	for side in 2:
		var who: Array = lineup.left if side == 0 else lineup.right
		var called: Array = []
		for k in (teams[side] as Array).size():
			var m: Dictionary = teams[side][k]
			if m.game != 0:
				_leave_game(m)               # still on the last match's Game Over
			var seat := side + 2 * k
			m.game = id
			m.gseat = seat
			if seat == 0:
				g.host = m
			else:
				g.guests[seat] = m
			var label := "P%d" % (seat + 1)
			who.append(label)
			looks[label] = m.look
			names[label] = m.name
			called.append(m.name)
		while who.size() < size:
			who.append("Bot")
		team_names.append(" & ".join(called))
	games[id] = g
	for m: Dictionary in [g.host] + g.guests.values():
		_send(m, {"type": "game", "id": id, "seat": m.gseat, "kind": kind, "lineup": lineup, "looks": looks,
			"names": names, "teams": team_names, "rules": rules})
	return id


## Out of a game (back from its Game Over, or gone). If the host goes, the game is over
## for everyone; in a tourney match that wasn't finished, the host's team loses.
func _leave_game(p: Dictionary) -> void:
	var g: Dictionary = games.get(p.game, {})
	var seat: int = p.gseat
	p.game = 0
	p.gseat = -1
	if g.is_empty():
		return
	if g.host == p:
		for m: Dictionary in g.guests.values():
			if m.game == g.id:
				m.game = 0
				m.gseat = -1
				_send(m, {"type": "game_closed"})
		games.erase(g.id)
		var t: Dictionary = tourneys.get(g.tourney, {})
		if not g.done and not t.is_empty() and t.games.get(g.match, 0) == g.id:
			_tourney_win(t, g.match, _pairs(t, t.round)[g.match][1])
	else:
		g.guests.erase(seat)
		_send(g.host, {"type": "game_left", "seat": seat})


## The host says who won (0: the left team, 1: the right).
func _result(p: Dictionary, msg: Dictionary) -> void:
	var g: Dictionary = games.get(p.game, {})
	if g.is_empty() or g.host != p or g.done:
		return
	g.done = true
	var t: Dictionary = tourneys.get(g.tourney, {})
	if not t.is_empty() and t.games.get(g.match, 0) == g.id:
		_tourney_win(t, g.match, _pairs(t, t.round)[g.match][clampi(int(msg.get("winner", 0)), 0, 1)])


# --- tourneys ---------------------------------------------------------------------
# Teams are numbered in bracket order: round 0 is 0 v 1, 2 v 3, ...; each later
# match is between the winners of two matches before it. results[round][match] is
# the winning team, -1 until it's played.

func _start_tourney(teams: Array, per_team: int) -> void:
	var t := {"id": next_id, "teams": teams, "size": per_team, "names": [], "results": [[]], "round": 0,
		"games": {}, "since": {}, "out": {}, "done": false}      # out: player id -> where they finished
	next_id += 1
	for team: Array in teams:
		t.names.append(" & ".join(team.map(func(m): return m.name)))
		for m: Dictionary in team:
			m.tourney = t.id
	for i in BRACKET / 2:
		t.results[0].append(-1)
		t.since[i] = clock
	tourneys[t.id] = t
	_send_bracket(t)


## The matches of a round, as [team, team] (-1: not known yet).
static func _pairs(t: Dictionary, r: int) -> Array:
	var out: Array = []
	if r == 0:
		for i in range(0, (t.teams as Array).size(), 2):
			out.append([i, i + 1])
	else:
		var before: Array = t.results[r - 1]
		for i in range(0, before.size(), 2):
			out.append([before[i], before[i + 1]])
	return out


## A team's players still in the tourney.
func _present(t: Dictionary, team: int) -> Array:
	if team < 0:
		return []
	return (t.teams[team] as Array).filter(func(m): return m.open and m.tourney == t.id)


## Starts each match of the round once its players are free (or have had GRACE to get
## ready); a team with nobody left loses without playing.
func _tourney_step(t: Dictionary) -> void:
	if t.done:
		if not peers.any(func(m): return m.tourney == t.id):
			tourneys.erase(t.id)             # nobody's looking at it any more
		return
	var r: int = t.round
	var pairs := _pairs(t, r)
	for i in pairs.size():
		if t.results[r][i] != -1 or t.games.has(i) or t.round != r:
			continue
		var a := _present(t, pairs[i][0])
		var b := _present(t, pairs[i][1])
		if a.is_empty() or b.is_empty():
			_tourney_win(t, i, pairs[i][1] if a.is_empty() else pairs[i][0])
			continue
		var busy := (a + b).any(func(m): return m.game != 0)
		if busy and clock - float(t.since.get(i, clock)) < GRACE:
			continue
		t.games[i] = _start_game([a, b], "tourney", TOURNEY_RULES, t.id, i, t.size)


func _tourney_win(t: Dictionary, i: int, winner: int) -> void:
	var r: int = t.round
	var pair: Array = _pairs(t, r)[i]
	t.results[r][i] = winner
	t.games.erase(i)
	var loser: int = pair[1] if winner == pair[0] else pair[0]
	_placed(t, loser, (BRACKET >> (r + 1)) + 1)       # out in the final: 2nd; in the semis: 3rd...
	if not (t.results[r] as Array).has(-1):
		if (t.results[r] as Array).size() == 1:
			_placed(t, winner, 1)
			t.done = true
		else:
			t.round = r + 1
			t.results.append([])
			t.since = {}
			for k in (t.results[r] as Array).size() / 2:
				t.results[r + 1].append(-1)
				t.since[k] = clock
	_send_bracket(t)


func _placed(t: Dictionary, team: int, place: int) -> void:
	if team < 0:
		return
	for m: Dictionary in t.teams[team]:
		t.out[m.id] = place
	for m: Dictionary in _present(t, team):
		_send(m, {"type": "placed", "place": place, "of": BRACKET})


## Everyone in the tourney sees the bracket: the teams, each round's matches and winners.
func _send_bracket(t: Dictionary) -> void:
	var rounds: Array = []
	for r in (t.results as Array).size():
		var pairs := _pairs(t, r)
		var row: Array = []
		for i in pairs.size():
			row.append([pairs[i][0], pairs[i][1], t.results[r][i]])
		rounds.append(row)
	for k in (t.teams as Array).size():
		for m: Dictionary in _present(t, k):
			_send(m, {"type": "bracket", "names": t.names, "rounds": rounds, "you": k, "round": t.round,
				"size": BRACKET, "done": t.done})


func _leave_tourney(p: Dictionary) -> void:
	var t: Dictionary = tourneys.get(p.tourney, {})
	if not t.is_empty() and p.game != 0 and games.get(p.game, {}).get("tourney", 0) == t.id:
		_leave_game(p)
	p.tourney = 0


## Gone: out of everything (the queue first, so their group hears why).
func _gone(p: Dictionary) -> void:
	p.open = false
	_cancel(p, "A player left, so the search stopped.")
	_leave_game(p)
	_leave_tourney(p)
	_leave_party(p)
# --- names: the same check as scripts/NameFilter.gd (a changed word list goes in both) ---

const LEET := {"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "@": "a", "$": "s", "!": "i"}
# rude anywhere in a name, and rude only as a whole word (they're inside ordinary words)
const ANYWHERE := "ZnVja3xmdWt8ZmNrfHNoaXR8Yml0Y2h8YnRjaHxjdW50fGRpY2t8Y29ja3xwdXNzeXxwZW5pc3x2YWdpbmF8d2hvcmV8c2x1dHxmYWd8bmlnZ2VyfG5pZ2dhfG5pZ2F8cmV0YXJkfHJhcGV8cmFwaXN0fG5heml8aGl0bGVyfHBvcm58c2V4fGJvb2J8YmFzdGFyZHx3YW5rfHR3YXR8a2trfHBpc3N8aml6enxkaWxkb3xob3JueXxraWxseW91cnNlbGZ8c3VpY2lkZXxtb2xlc3R8Y2hpbmt8a2lrZXx3ZXRiYWNrfHRyYW5ueXxnb29rfG1vdGhlcmZ8YXNzaG9sZXxhcnNlaG9sZXxkdW1iYXNzfGphY2thc3N8Ym9sbG9ja3x0ZXN0aWNsZXxvcmdhc218c2VtZW58bnVkZXxuYWtlZHxzdGZ1fHd0ZnxtaWxm"
const WHOLE := "YXNzfGFyc2V8ZGFtbnxoZWxsfGNyYXB8dGl0fHRpdHN8Y3VtfGFuYWx8aG9lfGhvZXN8cHJpY2t8ZHlrZXxjb29ufHNwaWN8cGVkb3xiZWFuZXJ8a3lzfHNsYWd8dHVyZHxwb29wfHBlZQ=="
const ALLOWED := ["peacock", "cockatoo", "cockatiel", "hancock", "shuttlecock", "grape", "drape", "scrape",
	"trapeze", "therapist", "spice", "spicy", "scunthorpe", "sussex", "essex", "dickens"]


static func _rude(name: String) -> bool:
	# the words of the name: split at spaces, - and _, and where a capital starts a word (BigWord)
	var spaced := ""
	for i in name.length():
		var c := name[i]
		if i > 0 and c != c.to_lower() and name[i - 1] == name[i - 1].to_lower() and name[i - 1] != " ":
			spaced += " "
		spaced += c
	var all := _plain(name)
	for ok: String in ALLOWED:
		all = all.replace(ok, "")
	if _patterns(ANYWHERE, false).search(all) != null:
		return true
	var whole := _patterns(WHOLE, true)
	for w in spaced.replace("-", " ").replace("_", " ").split(" ", false):
		if whole.search(_plain(w)) != null:
			return true
	return false


static func _plain(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		c = LEET.get(c, c)
		if c >= "a" and c <= "z":
			out += c
	return out


static func _patterns(encoded: String, whole: bool) -> RegEx:
	var parts: Array = []
	for w: String in Marshalls.base64_to_utf8(encoded).split("|"):
		var p := ""
		for c in w:
			p += c + "+"
		parts.append(p)
	var r := RegEx.new()
	r.compile(("^(%s)$" if whole else "(%s)") % "|".join(parts))
	return r
