extends RefCounted
class_name PSSchedule

const PENNANT_GAMES_PER_TEAM: int = 143
const ROUNDS_PER_CYCLE: int = 5
const PHASE1_CYCLES: int = 9
const PHASE3_CYCLES: int = 16
const INTERLEAGUE_CARDS: int = 6
const INTERLEAGUE_GAMES_PER_CARD: int = 3
const INTRALEAGUE_REST_DAYS_BETWEEN_CYCLES: int = 1
const INTERLEAGUE_REST_DAYS_BETWEEN_CARDS: int = 1
const PHASE_BREAK_REST_DAYS: int = 2


static func generate_pennant_schedule(teams: Array, games_per_team: int = PENNANT_GAMES_PER_TEAM, dh_by_league: Dictionary = {}) -> Array:
	if games_per_team != PENNANT_GAMES_PER_TEAM:
		push_warning("games_per_team override is ignored in NPB-style schedule.")

	var team_rows: Array = teams.duplicate()
	team_rows.sort_custom(func(a, b) -> bool:
		var team_a: PSTeam = a as PSTeam
		var team_b: PSTeam = b as PSTeam
		return team_a.id < team_b.id
	)

	var centrals: Array = []
	var pacifics: Array = []
	var leagues_by_team_id: Dictionary = {}
	for team_row in team_rows:
		var team: PSTeam = team_row as PSTeam
		leagues_by_team_id[team.id] = team.league
		if team.league == "central":
			centrals.append(team.id)
		else:
			pacifics.append(team.id)

	if centrals.size() != 6 or pacifics.size() != 6:
		push_warning("Pennant schedule requires 6 central + 6 pacific teams.")
		return []

	var games: Array = []
	var day: int = 1
	var cycle: int = 1

	var phase1: Dictionary = _generate_intraleague_phase(centrals, pacifics, leagues_by_team_id, dh_by_league, day, cycle, PHASE1_CYCLES)
	games.append_array(phase1.get("games", []) as Array)
	day = int(phase1.get("next_day", day))
	cycle = int(phase1.get("next_cycle", cycle))
	day += PHASE_BREAK_REST_DAYS

	var phase2: Dictionary = _generate_interleague_phase(centrals, pacifics, leagues_by_team_id, dh_by_league, day)
	games.append_array(phase2.get("games", []) as Array)
	day = int(phase2.get("next_day", day))
	day += PHASE_BREAK_REST_DAYS

	var phase3: Dictionary = _generate_intraleague_phase(centrals, pacifics, leagues_by_team_id, dh_by_league, day, cycle, PHASE3_CYCLES)
	games.append_array(phase3.get("games", []) as Array)

	return games


static func _generate_intraleague_phase(
	centrals: Array,
	pacifics: Array,
	leagues_by_team_id: Dictionary,
	dh_by_league: Dictionary,
	start_day: int,
	start_cycle: int,
	cycle_count: int
) -> Dictionary:
	var games: Array = []
	var day: int = start_day
	var cycle: int = start_cycle

	for cycle_index in range(cycle_count):
		var central_rot: Array = centrals.duplicate()
		var pacific_rot: Array = pacifics.duplicate()
		for _round_index in range(ROUNDS_PER_CYCLE):
			for pair_index in range(3):
				var c_a: int = int(central_rot[pair_index])
				var c_b: int = int(central_rot[central_rot.size() - 1 - pair_index])
				var c_ha: Array = _intraleague_home_pair(c_a, c_b, cycle)
				games.append(_make_game(day, int(c_ha[1]), int(c_ha[0]), leagues_by_team_id, dh_by_league, false, -1, -1, cycle))
			for pair_index in range(3):
				var p_a: int = int(pacific_rot[pair_index])
				var p_b: int = int(pacific_rot[pacific_rot.size() - 1 - pair_index])
				var p_ha: Array = _intraleague_home_pair(p_a, p_b, cycle)
				games.append(_make_game(day, int(p_ha[1]), int(p_ha[0]), leagues_by_team_id, dh_by_league, false, -1, -1, cycle))
			day += 1
			central_rot = _rotated_round_robin(central_rot)
			pacific_rot = _rotated_round_robin(pacific_rot)
		if cycle_index < cycle_count - 1:
			day += INTRALEAGUE_REST_DAYS_BETWEEN_CYCLES
		cycle += 1

	return {"games": games, "next_day": day, "next_cycle": cycle}


static func _generate_interleague_phase(
	centrals: Array,
	pacifics: Array,
	leagues_by_team_id: Dictionary,
	dh_by_league: Dictionary,
	start_day: int
) -> Dictionary:
	var games: Array = []
	var day: int = start_day

	for card_index in range(INTERLEAGUE_CARDS):
		var pairs: Array = []
		for i in range(6):
			var c_id: int = int(centrals[i])
			var p_id: int = int(pacifics[(i + card_index) % 6])
			pairs.append([c_id, p_id])

		for game_no in range(1, INTERLEAGUE_GAMES_PER_CARD + 1):
			for pair in pairs:
				var c_id_a: int = int(pair[0])
				var p_id_a: int = int(pair[1])
				var ha: Array = _interleague_home_pair(c_id_a, p_id_a, card_index)
				games.append(_make_game(day, int(ha[1]), int(ha[0]), leagues_by_team_id, dh_by_league, true, card_index, game_no, -1))
			day += 1
		if card_index < INTERLEAGUE_CARDS - 1:
			day += INTERLEAGUE_REST_DAYS_BETWEEN_CARDS

	return {"games": games, "next_day": day}


static func _intraleague_home_pair(team_a: int, team_b: int, cycle_number: int) -> Array:
	var small_id: int = min(team_a, team_b)
	var large_id: int = max(team_a, team_b)
	if cycle_number % 2 == 1:
		return [small_id, large_id]
	return [large_id, small_id]


static func _interleague_home_pair(central_id: int, pacific_id: int, card_index: int) -> Array:
	if card_index == 1 or card_index == 4 or card_index == 5:
		return [pacific_id, central_id]
	return [central_id, pacific_id]


static func _make_game(
	day: int,
	away_team_id: int,
	home_team_id: int,
	leagues_by_team_id: Dictionary,
	dh_by_league: Dictionary,
	is_interleague: bool,
	card_index: int,
	card_game_no: int,
	cycle_number: int
) -> Dictionary:
	var home_league: String = str(leagues_by_team_id.get(home_team_id, "central"))
	var dh_enabled: bool = bool(dh_by_league.get(home_league, true))
	return {
		"day": day,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_score": 0,
		"home_score": 0,
		"played": false,
		"dh_enabled": dh_enabled,
		"innings": [],
		"result": {},
		"is_interleague": is_interleague,
		"card_index": card_index,
		"card_game_no": card_game_no,
		"cycle_number": cycle_number,
	}


static func _rotated_round_robin(team_ids: Array) -> Array:
	var rotated: Array = [team_ids[0], team_ids[team_ids.size() - 1]]
	for index in range(1, team_ids.size() - 1):
		rotated.append(team_ids[index])
	return rotated
