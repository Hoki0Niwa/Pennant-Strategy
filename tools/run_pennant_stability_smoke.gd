extends Node

const SEED: int = 20260604
const REGULAR_FIELDER_GAMES: int = 100
const FATIGUE_STUCK_LINE: int = 180


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	AppState.selected_team_id = 1
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026)
	RecordStore.ensure_season_records(AppState.current_season, GameDb.teams, GameDb.players, true)

	var season: PSSeason = AppState.current_season
	var inspected_games: int = 0
	var started_at: int = Time.get_ticks_msec()
	while true:
		var game_index: int = _next_unplayed_game_index(season)
		if game_index < 0:
			break
		var game: Dictionary = season.schedule[game_index] as Dictionary
		var dh_enabled: bool = bool(game.get("dh_enabled", false))
		var away_team_id: int = int(game.get("away_team_id", 0))
		var home_team_id: int = int(game.get("home_team_id", 0))
		for team_id in [away_team_id, home_team_id]:
			var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, int(team_id), dh_enabled)
			if not bool(setup.get("ok", false)):
				failures.append("setup failed day=%d team=%d: %s" % [int(game.get("day", 0)), int(team_id), str(setup.get("message", ""))])
				break
			failures.append_array(_injured_setup_failures(int(game.get("day", 0)), int(team_id), setup))
		if not failures.is_empty():
			break
		var result: Dictionary = GameSimulator.simulate_game_at_index(season, game_index, false)
		if not bool(result.get("ok", false)):
			failures.append("simulate failed game_index=%d: %s" % [game_index, str(result.get("message", ""))])
			break
		inspected_games += 1

	PSGameDecisions.persist_records()
	var fatigue_summary: Dictionary = _fielder_fatigue_summary(season)
	var regulars: int = int(fatigue_summary.get("regulars", 0))
	var stuck_180: int = int(fatigue_summary.get("stuck_180", 0))
	var p90: int = int(fatigue_summary.get("p90", 0))
	if regulars <= 0:
		failures.append("fatigue: no regular fielders found")
	elif p90 >= FATIGUE_STUCK_LINE:
		failures.append("fatigue: regular fielder p90=%d expected <%d" % [p90, FATIGUE_STUCK_LINE])
	elif stuck_180 > 0:
		failures.append("fatigue: %d regular fielders reached >=%d" % [stuck_180, FATIGUE_STUCK_LINE])

	var elapsed_ms: int = Time.get_ticks_msec() - started_at
	print("Pennant stability smoke: games=%d elapsed_ms=%d fatigue=%s" % [
		inspected_games,
		elapsed_ms,
		JSON.stringify(fatigue_summary),
	])
	if failures.is_empty():
		print("Pennant stability smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Pennant stability smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _next_unplayed_game_index(season: PSSeason) -> int:
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			return index
	return -1


func _injured_setup_failures(day: int, team_id: int, setup: Dictionary) -> Array:
	var failures: Array = []
	for key in ["pitcher", "starter_pitcher"]:
		var pitcher: PSPlayerSeasonRecord = setup.get(key, null) as PSPlayerSeasonRecord
		if pitcher != null and pitcher.injury_days > 0:
			failures.append("day=%d team=%d setup %s injured player=%d" % [day, team_id, key, pitcher.player_id])
	for list_key in ["batters", "bench", "relievers"]:
		var records: Array = setup.get(list_key, []) as Array
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null and record.injury_days > 0:
				failures.append("day=%d team=%d setup %s injured player=%d" % [day, team_id, list_key, record.player_id])
				break
	var fielders: Array = setup.get("fielders", []) as Array
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var fielder: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if fielder != null and fielder.injury_days > 0:
			failures.append("day=%d team=%d setup fielders injured player=%d" % [day, team_id, fielder.player_id])
			break
	return failures


func _fielder_fatigue_summary(season: PSSeason) -> Dictionary:
	var values: Array = []
	var stuck: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
		for record_row in records:
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record == null or record.is_pitcher():
				continue
			if record.batter_stats.games < REGULAR_FIELDER_GAMES:
				continue
			values.append(record.fatigue)
			if record.fatigue >= FATIGUE_STUCK_LINE:
				stuck += 1
	values.sort()
	var total: int = 0
	for value in values:
		total += int(value)
	var regulars: int = values.size()
	var max_value: int = int(values[regulars - 1]) if regulars > 0 else 0
	var p90_index: int = int(floor(float(max(0, regulars - 1)) * 0.9))
	var p90: int = int(values[p90_index]) if regulars > 0 else 0
	var average: float = float(total) / float(regulars) if regulars > 0 else 0.0
	return {
		"regulars": regulars,
		"average": snapped(average, 0.01),
		"p90": p90,
		"max": max_value,
		"stuck_180": stuck,
	}
