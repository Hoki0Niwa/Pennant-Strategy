extends Node


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()
	Rng.set_seed_value(20260604)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)

	failures.append_array(_test_rotation_state_advances(season, 1))
	failures.append_array(_test_game_updates_rotation_state())

	if failures.is_empty():
		print("Rotation state smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Rotation state smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_rotation_state_advances(season: PSSeason, team_id: int) -> Array:
	var failures: Array = []
	var prepared: Dictionary = PSTeamSetupBuilder.prepare_team_setup(season, team_id)
	if not bool(prepared.get("ok", false)):
		return ["prepare failed: %s" % str(prepared.get("message", ""))]
	var starters: Array = prepared.get("starter_pitchers", []) as Array
	if starters.size() < 4:
		return ["not enough starters for rotation state smoke"]

	var ids: Array = []
	for i in range(6):
		if i >= starters.size():
			break
		ids.append((starters[i] as PSPlayerSeasonRecord).player_id)

	season.set_rotation(team_id, {
		"pitcher_ids": ids,
		"next_rotation_index": 0,
		"last_start_day_by_pitcher": {},
	})
	var team_record: PSTeamSeasonRecord = prepared.get("team_record", null) as PSTeamSeasonRecord
	var first: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starters, team_record)
	var first_pitcher: PSPlayerSeasonRecord = first.get("pitcher", null) as PSPlayerSeasonRecord
	if first_pitcher == null or first_pitcher.player_id != int(ids[0]):
		failures.append("first starter=%d expected %d" % [0 if first_pitcher == null else first_pitcher.player_id, int(ids[0])])
		return failures

	PSRotationPlanner.record_rotation_start(season, team_id, {
		"starter_pitcher": first_pitcher,
		"rotation_order_ids": first.get("order_ids", []),
		"rotation_selected_index": int(first.get("selected_index", -1)),
	}, season.current_day)
	var state: Dictionary = season.get_rotation(team_id)
	if int(state.get("next_rotation_index", -1)) != 1:
		failures.append("next_rotation_index=%d expected 1" % int(state.get("next_rotation_index", -1)))
	var last_starts: Dictionary = state.get("last_start_day_by_pitcher", {}) as Dictionary
	if int(last_starts.get(str(ids[0]), 0)) != season.current_day:
		failures.append("last_start day missing for first starter")

	season.current_day += 1
	var second_pitcher: PSPlayerSeasonRecord = starters[1] as PSPlayerSeasonRecord
	var third_pitcher: PSPlayerSeasonRecord = starters[2] as PSPlayerSeasonRecord
	second_pitcher.fatigue = PSRotationPlanner.STARTER_DANGER_FATIGUE
	var skip_fatigued: Dictionary = PSRotationPlanner.resolve_rotation_decision(season, team_id, starters, team_record)
	var skipped_pitcher: PSPlayerSeasonRecord = skip_fatigued.get("pitcher", null) as PSPlayerSeasonRecord
	if skipped_pitcher == null or skipped_pitcher.player_id != third_pitcher.player_id:
		failures.append("fatigue skip starter=%d expected %d" % [0 if skipped_pitcher == null else skipped_pitcher.player_id, third_pitcher.player_id])
	second_pitcher.fatigue = 0

	var restored: PSSeason = PSSeason.from_dict(season.to_dict())
	var restored_state: Dictionary = restored.get_rotation(team_id)
	if int(restored_state.get("next_rotation_index", -1)) != int(state.get("next_rotation_index", -2)):
		failures.append("save/load next_rotation_index did not persist")
	var restored_last: Dictionary = restored_state.get("last_start_day_by_pitcher", {}) as Dictionary
	if int(restored_last.get(str(ids[0]), 0)) != season.current_day - 1:
		failures.append("save/load last_start_day_by_pitcher did not persist")
	print("[rotation_state] advance/skip/save OK")
	return failures


func _test_game_updates_rotation_state() -> Array:
	var failures: Array = []
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, true)
	var result: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
	if not bool(result.get("ok", false)):
		return ["one-game simulate failed: %s" % str(result.get("message", ""))]
	var game: Dictionary = result.get("game", {}) as Dictionary
	var day: int = int(game.get("day", 0))
	for key in ["away_team_id", "home_team_id"]:
		var team_id: int = int(game.get(key, 0))
		var state: Dictionary = season.get_rotation(team_id)
		if state.is_empty():
			failures.append("team %d rotation state was not created" % team_id)
			continue
		var last_pitcher: int = int(state.get("last_start_pitcher_id", 0))
		if last_pitcher <= 0:
			failures.append("team %d missing last_start_pitcher_id" % team_id)
		var last_starts: Dictionary = state.get("last_start_day_by_pitcher", {}) as Dictionary
		if int(last_starts.get(str(last_pitcher), 0)) != day:
			failures.append("team %d last start day=%d expected %d" % [team_id, int(last_starts.get(str(last_pitcher), 0)), day])
		if not state.has("next_rotation_index"):
			failures.append("team %d missing next_rotation_index" % team_id)
	print("[rotation_state] game update OK")
	return failures

