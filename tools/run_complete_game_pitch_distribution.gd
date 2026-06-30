extends Node


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var pitch_counts: Array = []
	var rows: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		for game_index in range(season.schedule.size()):
			var game_result: Dictionary = GameSimulator.simulate_game_at_index(season, game_index, false)
			if not bool(game_result.get("ok", false)):
				push_error(str(game_result.get("message", "game simulation failed")))
				continue
			_collect_complete_games(game_result.get("result", {}) as Dictionary, pitch_counts, rows)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var summary: Dictionary = _summary(pitch_counts)
	summary["seed"] = seed_value
	summary["seasons"] = seasons
	summary["rows"] = rows
	print(JSON.stringify(summary, "\t"))
	get_tree().quit(0)


func _collect_complete_games(result: Dictionary, pitch_counts: Array, rows: Array) -> void:
	var outings: Array = result.get("pitcher_outings", []) as Array
	var team_ids: Array = [int(result.get("away_team_id", 0)), int(result.get("home_team_id", 0))]
	for team_id in team_ids:
		var team_outings: Array = []
		for outing_value in outings:
			var outing: Dictionary = outing_value as Dictionary
			if int(outing.get("team_id", 0)) == team_id:
				team_outings.append(outing)
		if team_outings.size() != 1:
			continue
		var starter_outing: Dictionary = team_outings[0] as Dictionary
		var outs: int = int(starter_outing.get("outs", 0))
		if outs < 24:
			continue
		var pitches: int = int(starter_outing.get("pitches", 0))
		pitch_counts.append(pitches)
		rows.append({
			"team_id": team_id,
			"pitcher_id": int(starter_outing.get("pitcher_id", 0)),
			"pitches": pitches,
			"outs": outs,
			"runs": int(starter_outing.get("runs", 0)),
		})


func _summary(values: Array) -> Dictionary:
	values.sort()
	var n: int = values.size()
	var buckets: Dictionary = {
		"lt_100": 0,
		"100_109": 0,
		"110_119": 0,
		"120_129": 0,
		"gte_130": 0,
	}
	var total: int = 0
	for value in values:
		var pitches: int = int(value)
		total += pitches
		if pitches < 100:
			buckets["lt_100"] += 1
		elif pitches < 110:
			buckets["100_109"] += 1
		elif pitches < 120:
			buckets["110_119"] += 1
		elif pitches < 130:
			buckets["120_129"] += 1
		else:
			buckets["gte_130"] += 1
	return {
		"count": n,
		"mean": _round_float(_safe_div(total, n), 1),
		"min": 0 if n == 0 else int(values[0]),
		"p10": _percentile(values, 0.10),
		"p25": _percentile(values, 0.25),
		"median": _percentile(values, 0.50),
		"p75": _percentile(values, 0.75),
		"p90": _percentile(values, 0.90),
		"max": 0 if n == 0 else int(values[n - 1]),
		"buckets": buckets,
	}


func _percentile(values: Array, p: float) -> int:
	if values.is_empty():
		return 0
	var index: int = int(round(clamp(p, 0.0, 1.0) * float(values.size() - 1)))
	return int(values[index])


func _safe_div(a: float, b: float) -> float:
	return 0.0 if b == 0.0 else a / b


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, digits)
	return round(value * scale) / scale


func _parse_args() -> Dictionary:
	var parsed: Dictionary = {}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg in args:
		var text: String = str(arg)
		if not text.begins_with("--"):
			continue
		var body: String = text.substr(2)
		var eq: int = body.find("=")
		if eq >= 0:
			parsed[body.substr(0, eq)] = body.substr(eq + 1)
		else:
			parsed[body] = true
	return parsed
