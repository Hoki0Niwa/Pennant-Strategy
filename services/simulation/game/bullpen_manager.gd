extends RefCounted
class_name PSBullpenManager


static func mark_games_started(setup: Dictionary) -> void:
	var pitcher: PSPlayerSeasonRecord = setup["pitcher"] as PSPlayerSeasonRecord
	pitcher.pitcher_stats.games += 1
	pitcher.pitcher_stats.starts += 1
	mark_pitcher_used(setup, pitcher)
	pitcher_usage_for(setup, pitcher, PSPitcherUsageModel.ROLE_STARTER)
	var fielder_ids: Dictionary = _fielder_ids_for_setup(setup)
	var batters: Array = setup["batters"] as Array
	for batter_row in batters:
		var batter: PSPlayerSeasonRecord = batter_row as PSPlayerSeasonRecord
		if batter == null or batter.is_pitcher():
			continue
		batter.batter_stats.games += 1
		var is_fielder: bool = fielder_ids.has(batter.player_id)
		var fatigue_gain: int = GameSimulator.FIELDER_START_FATIGUE_GAIN if is_fielder else GameSimulator.DH_START_FATIGUE_GAIN
		var exposure: float = 1.0 if is_fielder else 0.65
		batter.fatigue = int(min(GameSimulator.FATIGUE_MAX, batter.fatigue + fatigue_gain))
		PSScoringHelpers.maybe_injure(batter, false, exposure)


static func substitute_reliever(setup: Dictionary, inning: int, game_result: Dictionary = {}) -> void:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if current == null:
		return
	var already_relieved: bool = bool(setup.get("starter_relieved", false))
	var usage: Dictionary = pitcher_usage_for(setup, current, PSPitcherUsageModel.ROLE_STARTER if current == starter else "")
	var should_pull: bool = PSPitcherUsageModel.should_pull_for_next_half(
		current,
		usage,
		inning,
		int(setup.get("game_runs_allowed", 0))
	)
	if already_relieved and starter != null and current == starter:
		should_pull = true

	if not should_pull:
		return

	var prefer_long: bool = current == starter and inning < GameSimulator.STARTER_EXTEND_START_INNING
	var reliever: PSPlayerSeasonRecord = pick_reliever_for_context(setup, inning, game_result, prefer_long)
	if reliever == null:
		return
	if setup.get("pitcher", null) == reliever:
		return
	if not already_relieved and starter != null and current == starter:
		mark_starter_relieved(setup)
	setup["pitcher"] = reliever
	var role: String = _outing_role_for_reliever(setup, reliever, prefer_long)
	mark_reliever_appeared(setup, reliever, int(setup.get("team_games_played_before", 0)), role)


static func substitute_reliever_mid_inning(
	setup: Dictionary,
	inning: int,
	outs: int,
	bases: Array,
	current_half_runs: int,
	game_result: Dictionary = {}
) -> bool:
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
	var current: PSPlayerSeasonRecord = setup.get("pitcher", null) as PSPlayerSeasonRecord
	if current == null:
		return false
	var usage: Dictionary = pitcher_usage_for(setup, current, PSPitcherUsageModel.ROLE_STARTER if current == starter else "")
	var runs_allowed: int = int(setup.get("game_runs_allowed", 0)) + current_half_runs
	var defense_lead: int = score_margin_for_setup(setup, game_result) - current_half_runs
	if not PSPitcherUsageModel.should_pull_after_plate_appearance(current, usage, inning, outs, bases, runs_allowed, defense_lead):
		return false

	var prefer_long: bool = current == starter and inning < GameSimulator.STARTER_EXTEND_START_INNING
	var reliever: PSPlayerSeasonRecord = pick_reliever_for_context(setup, inning, game_result, prefer_long)
	if reliever == null or reliever == current:
		return false
	if starter != null and current == starter:
		mark_starter_relieved(setup, int(setup.get("game_outs", 0)) + outs, runs_allowed)
	setup["pitcher"] = reliever
	var role: String = _outing_role_for_reliever(setup, reliever, prefer_long)
	mark_reliever_appeared(setup, reliever, int(setup.get("team_games_played_before", 0)), role)
	return true


static func mark_reliever_appeared(setup: Dictionary, reliever: PSPlayerSeasonRecord, team_games_played_before: int, role: String) -> void:
	reliever.pitcher_stats.games += 1
	reliever.pitcher_stats.relief_appearances += 1

	var consecutive_count: int = 0
	if reliever.last_pitched_team_game == team_games_played_before and team_games_played_before > 0:
		consecutive_count = reliever.consecutive_appearances
	else:
		reliever.consecutive_appearances = 0
	reliever.consecutive_appearances = consecutive_count + 1
	reliever.last_pitched_team_game = team_games_played_before + 1
	mark_pitcher_used(setup, reliever)
	var usage: Dictionary = pitcher_usage_for(setup, reliever, role)
	usage["consecutive_count"] = consecutive_count


static func pick_reliever_for_context(setup: Dictionary, inning: int, game_result: Dictionary = {}, prefer_long: bool = false) -> PSPlayerSeasonRecord:
	var relievers: Array = setup.get("relievers", []) as Array
	if relievers.is_empty():
		return null
	var used_ids: Dictionary = setup.get("used_pitcher_ids", {}) as Dictionary
	var close_game: bool = is_close_game_for_setup(setup, game_result)
	var game_day: int = int(setup.get("game_day", 0))
	var team_games_played_before: int = int(setup.get("team_games_played_before", 0))
	var candidates: Array = []
	for allow_tired in [false, true]:
		candidates.clear()
		for reliever_row in relievers:
			var reliever: PSPlayerSeasonRecord = reliever_row as PSPlayerSeasonRecord
			if reliever == null:
				continue
			if used_ids.has(reliever.player_id):
				continue
			if not PSPitcherUsageModel.is_reliever_available(reliever, bool(allow_tired), game_day, team_games_played_before):
				continue
			candidates.append(reliever)
		if not candidates.is_empty():
			break
	if candidates.is_empty():
		return null
	candidates.sort_custom(func(a, b) -> bool:
		var pitcher_a: PSPlayerSeasonRecord = a as PSPlayerSeasonRecord
		var pitcher_b: PSPlayerSeasonRecord = b as PSPlayerSeasonRecord
		return reliever_selection_score_for_setup(setup, pitcher_a, prefer_long, inning, close_game, game_day, team_games_played_before) > reliever_selection_score_for_setup(setup, pitcher_b, prefer_long, inning, close_game, game_day, team_games_played_before)
	)
	return candidates[0] as PSPlayerSeasonRecord


static func reliever_selection_score_for_setup(
	setup: Dictionary,
	reliever: PSPlayerSeasonRecord,
	prefer_long: bool,
	inning: int,
	close_game: bool,
	game_day: int,
	team_games_played_before: int
) -> float:
	var score: float = PSPitcherUsageModel.reliever_selection_score(reliever, prefer_long, inning, close_game, game_day, team_games_played_before)
	var role_by_pitcher: Dictionary = setup.get("relief_role_by_pitcher", {}) as Dictionary
	var role: String = str(role_by_pitcher.get(reliever.player_id, role_by_pitcher.get(str(reliever.player_id), "")))
	return score + relief_role_context_bonus(role, prefer_long, inning, close_game)


static func relief_role_context_bonus(role: String, prefer_long: bool, inning: int, close_game: bool) -> float:
	match role:
		PSRotationPlanner.RELIEF_ROLE_CLOSER:
			if prefer_long:
				return -160.0
			if close_game and inning >= 9:
				return 180.0
			if close_game and inning >= 8:
				return 80.0
			return -35.0
		PSRotationPlanner.RELIEF_ROLE_SETUP:
			if prefer_long:
				return -85.0
			if close_game and inning >= 7 and inning <= 8:
				return 130.0
			if close_game and inning == 6:
				return 60.0
			if close_game and inning >= 9:
				return -20.0
			return 12.0
		PSRotationPlanner.RELIEF_ROLE_MIDDLE:
			if prefer_long:
				return -30.0
			if close_game and inning >= 9:
				return -45.0
			if inning <= 7 or not close_game:
				return 45.0
			return 0.0
		PSRotationPlanner.RELIEF_ROLE_LONG:
			if prefer_long:
				return 170.0
			if inning <= 5:
				return 70.0
			if close_game and inning >= 7:
				return -120.0
			return -20.0
		_:
			return 0.0


static func is_close_game_for_setup(setup: Dictionary, game_result: Dictionary) -> bool:
	if game_result.is_empty():
		return false
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if team_id == away_team_id:
		return abs(away_score - home_score) <= 3
	if team_id == home_team_id:
		return abs(home_score - away_score) <= 3
	return false


static func score_margin_for_setup(setup: Dictionary, game_result: Dictionary) -> int:
	if game_result.is_empty():
		return 0
	var team_id: int = int(setup.get("team_id", 0))
	var away_team_id: int = int(game_result.get("away_team_id", 0))
	var home_team_id: int = int(game_result.get("home_team_id", 0))
	var away_score: int = int(game_result.get("away_score", 0))
	var home_score: int = int(game_result.get("home_score", 0))
	if team_id == away_team_id:
		return away_score - home_score
	if team_id == home_team_id:
		return home_score - away_score
	return 0


static func _outing_role_for_reliever(setup: Dictionary, reliever: PSPlayerSeasonRecord, prefer_long: bool) -> String:
	if reliever == null:
		return PSPitcherUsageModel.ROLE_SHORT_RELIEF
	var role_by_pitcher: Dictionary = setup.get("relief_role_by_pitcher", {}) as Dictionary
	var assigned_role: String = str(role_by_pitcher.get(reliever.player_id, role_by_pitcher.get(str(reliever.player_id), "")))
	if assigned_role == PSRotationPlanner.RELIEF_ROLE_LONG:
		return PSPitcherUsageModel.ROLE_LONG_RELIEF
	return PSPitcherUsageModel.ROLE_LONG_RELIEF if prefer_long else PSPitcherUsageModel.ROLE_SHORT_RELIEF


static func pitcher_usage_for(setup: Dictionary, pitcher: PSPlayerSeasonRecord, role: String = "") -> Dictionary:
	if pitcher == null:
		return {}
	var usage_by_id: Dictionary = setup.get("pitcher_usage", {}) as Dictionary
	var key: String = str(pitcher.player_id)
	if not usage_by_id.has(key):
		var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", null) as PSPlayerSeasonRecord
		var resolved_role: String = role
		if resolved_role.is_empty():
			resolved_role = PSPitcherUsageModel.ROLE_STARTER if starter != null and starter.player_id == pitcher.player_id else PSPitcherUsageModel.ROLE_SHORT_RELIEF
		usage_by_id[key] = PSPitcherUsageModel.create_outing(pitcher, resolved_role)
		setup["pitcher_usage"] = usage_by_id
	return usage_by_id[key] as Dictionary


static func mark_pitcher_used(setup: Dictionary, pitcher: PSPlayerSeasonRecord) -> void:
	if pitcher == null:
		return
	var used_ids: Dictionary = setup.get("used_pitcher_ids", {}) as Dictionary
	used_ids[pitcher.player_id] = true
	setup["used_pitcher_ids"] = used_ids


static func finalize_pitcher_usage(setup: Dictionary) -> void:
	var usage_by_id: Dictionary = setup.get("pitcher_usage", {}) as Dictionary
	for usage_value in usage_by_id.values():
		var usage: Dictionary = usage_value as Dictionary
		var pitcher: PSPlayerSeasonRecord = usage.get("record", null) as PSPlayerSeasonRecord
		if pitcher == null:
			continue
		var fatigue_gain: int = PSPitcherUsageModel.post_game_fatigue_gain(pitcher, usage)
		if fatigue_gain <= 0:
			continue
		pitcher.fatigue = int(min(GameSimulator.FATIGUE_MAX, pitcher.fatigue + fatigue_gain))
		PSScoringHelpers.maybe_injure(pitcher, true)


static func mark_starter_relieved(setup: Dictionary, current_outs: int = -1, current_runs: int = -1) -> void:
	if int(setup.get("starter_outs", -1)) < 0:
		setup["starter_outs"] = int(setup.get("game_outs", 0)) if current_outs < 0 else current_outs
		setup["starter_runs"] = int(setup.get("game_runs_allowed", 0)) if current_runs < 0 else current_runs
	setup["starter_relieved"] = true


static func _fielder_ids_for_setup(setup: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	var fielders: Array = setup.get("fielders", []) as Array
	for assignment_row in fielders:
		var assignment: Dictionary = assignment_row as Dictionary
		var record: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if record != null:
			ids[record.player_id] = true
	return ids
