extends Node


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))
	var include_rows: bool = _bool_arg(args.get("include_rows", false))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var rows: Array = []
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# 実プレイと同じ日次フック (谷間昇格・週次入替・二軍戦) を通す。`simulate_game_at_index`
		# を直に回すとどちらも走らず、**先発の顔ぶれとローテの固定度が実際と別物になる**
		# (2026-08-28: 先発起用が 15.3人/球団 → 8.6人/球団 に化けていた)。
		var ctx: Dictionary = {"user_team_id": 0, "include_user_team": true}
		while _has_unplayed_game(season):
			var day: int = season.current_day
			var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, ctx)
			if not bool(day_result.get("ok", false)):
				errors.append({
					"season_index": season_index,
					"day": day,
					"message": str(day_result.get("message", "day simulation failed")),
				})
				break
			for result_value in day_result.get("results", []) as Array:
				_collect_starter_outings((result_value as Dictionary).get("result", {}) as Dictionary, rows)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _summary(rows)
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["errors"] = errors
	if include_rows:
		report["rows"] = rows
	if not output_path.is_empty():
		var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print(JSON.stringify(report, "\t"))
	get_tree().quit(0 if errors.is_empty() else 1)


func _has_unplayed_game(season: PSSeason) -> bool:
	for game_value in season.schedule:
		if not bool((game_value as Dictionary).get("played", false)):
			return true
	return false


func _collect_starter_outings(result: Dictionary, rows: Array) -> void:
	var outings: Array = result.get("pitcher_outings", []) as Array
	var team_ids: Array = [int(result.get("away_team_id", 0)), int(result.get("home_team_id", 0))]
	for team_id in team_ids:
		var starter_outing: Dictionary = {}
		for outing_value in outings:
			var outing: Dictionary = outing_value as Dictionary
			if int(outing.get("team_id", 0)) == team_id and str(outing.get("role", "")) == PSPitcherUsageModel.ROLE_STARTER:
				starter_outing = outing
				break
		if starter_outing.is_empty():
			continue
		var outs: int = int(starter_outing.get("outs", 0))
		rows.append({
			"team_id": team_id,
			"pitcher_id": int(starter_outing.get("pitcher_id", 0)),
			"outs": outs,
			"ip": _outs_to_ip_float(outs),
			"pitches": int(starter_outing.get("pitches", 0)),
			"batters_faced": int(starter_outing.get("batters_faced", 0)),
			"runs": int(starter_outing.get("runs", 0)),
			"earned_runs": int(starter_outing.get("earned_runs", 0)),
			"complete_game_candidate": _team_pitcher_count(outings, team_id) == 1,
		})


func _team_pitcher_count(outings: Array, team_id: int) -> int:
	var count: int = 0
	for outing_value in outings:
		var outing: Dictionary = outing_value as Dictionary
		if int(outing.get("team_id", 0)) == team_id:
			count += 1
	return count


func _summary(rows: Array) -> Dictionary:
	var outs_values: Array = []
	var pitches: Array = []
	var complete_like: int = 0
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var outs: int = int(row.get("outs", 0))
		outs_values.append(outs)
		pitches.append(int(row.get("pitches", 0)))
		if bool(row.get("complete_game_candidate", false)) and outs >= 24:
			complete_like += 1
	return {
		"starts": rows.size(),
		"mean_ip": _round_float(_safe_div(_sum_int(outs_values), 3.0 * rows.size()), 2),
		"mean_pitches": _round_float(_safe_div(_sum_int(pitches), pitches.size()), 1),
		"pitches": _distribution(pitches, 1),
		"outs": _distribution(outs_values, 1),
		"buckets": _ip_buckets(outs_values),
		"complete_game_like": complete_like,
		"complete_game_like_rate": _round_float(_safe_div(complete_like, rows.size()), 4),
	}


func _ip_buckets(outs_values: Array) -> Dictionary:
	var specs: Array = [
		{"key": "lt4", "label": "<4.0", "min": -999, "max": 11},
		{"key": "4", "label": "4.x", "min": 12, "max": 14},
		{"key": "5", "label": "5.x", "min": 15, "max": 17},
		{"key": "6", "label": "6.x", "min": 18, "max": 20},
		{"key": "7", "label": "7.x", "min": 21, "max": 23},
		{"key": "8", "label": "8.x", "min": 24, "max": 26},
		{"key": "9plus", "label": "9.0+", "min": 27, "max": 999},
	]
	var out: Dictionary = {}
	var total: int = outs_values.size()
	for spec_value in specs:
		var spec: Dictionary = spec_value as Dictionary
		var count: int = 0
		for outs_value in outs_values:
			var outs: int = int(outs_value)
			if outs >= int(spec.get("min", 0)) and outs <= int(spec.get("max", 0)):
				count += 1
		out[str(spec.get("key", ""))] = {
			"label": str(spec.get("label", "")),
			"count": count,
			"pct": _round_float(_safe_div(count * 100.0, total), 1),
		}
	return out


func _distribution(values: Array, digits: int) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	return {
		"count": sorted.size(),
		"mean": _round_float(_safe_div(_sum_int(sorted), sorted.size()), digits),
		"min": int(sorted[0]),
		"p10": _percentile(sorted, 0.10),
		"p25": _percentile(sorted, 0.25),
		"median": _percentile(sorted, 0.50),
		"p75": _percentile(sorted, 0.75),
		"p90": _percentile(sorted, 0.90),
		"max": int(sorted[sorted.size() - 1]),
	}


func _percentile(values: Array, p: float) -> int:
	if values.is_empty():
		return 0
	var index: int = int(round(clamp(p, 0.0, 1.0) * float(values.size() - 1)))
	return int(values[index])


func _sum_int(values: Array) -> float:
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total


func _outs_to_ip_float(outs: int) -> float:
	var full_innings: int = int(floor(float(outs) / 3.0))
	return _round_float(float(full_innings) + float(outs % 3) / 10.0, 1)


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


func _bool_arg(value: Variant) -> bool:
	if value is bool:
		return bool(value)
	var text: String = str(value).strip_edges().to_lower()
	return text in ["1", "true", "yes", "on"]
