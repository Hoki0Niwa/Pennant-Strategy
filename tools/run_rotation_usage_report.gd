extends Node

# 先発ローテの使われ方を1シーズン通しで実測するレポート。
# PSRotationPlanner は「月曜始まりの週で序列順」に回すので、次の3点を確認するために使う:
#   - 序列ごとの登板数 (1番手が規定投球回に届く程度に回っているか、6番手が痩せすぎないか)
#   - 登板間隔の分布 (中6日が主で、中5日・中4日が例外に留まっているか)
#   - 序列1番手の登板曜日 (曜日が固定されているか)
# 実行: godot --headless res://tools/run_rotation_usage_report.tscn -- --seasons=1

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const WEEKDAY_LABELS: Array = ["日", "月", "火", "水", "木", "金", "土"]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var starts: Array = []
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# 実プレイと同じ日次フック (一軍入替・トレード・期限昇格) を通す。これを省くと二軍との
		# 入れ替えが起きず、「1チームが使う先発の人数」が実際より少なく出る。
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
				var game_result: Dictionary = result_value as Dictionary
				_collect_starts(season, day, game_result.get("result", {}) as Dictionary, season_index, starts)
		_resolve_slots(season, season_index, starts)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _summary(starts)
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["errors"] = errors
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


func _collect_starts(season: PSSeason, day: int, result: Dictionary, season_index: int, starts: Array) -> void:
	var date_text: String = SeasonCalendar.date_for_season_day(season, day)
	var outings: Array = result.get("pitcher_outings", []) as Array
	for team_id in [int(result.get("away_team_id", 0)), int(result.get("home_team_id", 0))]:
		for outing_value in outings:
			var outing: Dictionary = outing_value as Dictionary
			if int(outing.get("team_id", 0)) != team_id:
				continue
			if str(outing.get("role", "")) != PSPitcherUsageModel.ROLE_STARTER:
				continue
			starts.append({
				"season_index": season_index,
				"team_id": team_id,
				"pitcher_id": int(outing.get("pitcher_id", 0)),
				"day": day,
				"weekday": SeasonCalendar.weekday_for_date(date_text),
				"slot": -1,
			})
			break


# 序列 (保存されたローテ順) は最初の試合で確定するので、シーズン終了後にまとめて解決する。
func _resolve_slots(season: PSSeason, season_index: int, starts: Array) -> void:
	var order_by_team: Dictionary = {}
	for team_row in GameDb.teams:
		var team_id: int = (team_row as PSTeam).id
		order_by_team[team_id] = (season.get_rotation(team_id).get("pitcher_ids", []) as Array)
	for start_value in starts:
		var start: Dictionary = start_value as Dictionary
		if int(start.get("season_index", -1)) != season_index:
			continue
		var order: Array = order_by_team.get(int(start.get("team_id", 0)), []) as Array
		start["slot"] = order.find(int(start.get("pitcher_id", 0)))


func _summary(starts: Array) -> Dictionary:
	var starts_by_slot: Dictionary = {}
	var starts_by_pitcher: Dictionary = {}
	var last_day_by_pitcher: Dictionary = {}
	var gap_hist: Dictionary = {}
	var ace_weekday: Dictionary = {}
	var pitchers_by_team_season: Dictionary = {}
	var off_rotation: int = 0

	for start_value in starts:
		var start: Dictionary = start_value as Dictionary
		var slot: int = int(start.get("slot", -1))
		var key: String = "slot%d" % (slot + 1) if slot >= 0 else "off_rotation"
		starts_by_slot[key] = int(starts_by_slot.get(key, 0)) + 1
		if slot < 0:
			off_rotation += 1

		var pitcher_key: String = "%d:%d" % [int(start.get("season_index", 0)), int(start.get("pitcher_id", 0))]
		starts_by_pitcher[pitcher_key] = int(starts_by_pitcher.get(pitcher_key, 0)) + 1

		# 「1チームが1シーズンに何人の先発を使ったか」= NPB の実運用(二軍からの穴埋め含む)との比較用。
		var team_key: String = "%d:%d" % [int(start.get("season_index", 0)), int(start.get("team_id", 0))]
		var team_pitchers: Dictionary = pitchers_by_team_season.get(team_key, {}) as Dictionary
		team_pitchers[int(start.get("pitcher_id", 0))] = true
		pitchers_by_team_season[team_key] = team_pitchers

		var day: int = int(start.get("day", 0))
		if last_day_by_pitcher.has(pitcher_key):
			var gap: int = day - int(last_day_by_pitcher[pitcher_key])
			var gap_key: String = "gap%d" % gap if gap <= 10 else "gap11plus"
			gap_hist[gap_key] = int(gap_hist.get(gap_key, 0)) + 1
		last_day_by_pitcher[pitcher_key] = day

		if slot == 0:
			var weekday_key: String = str(WEEKDAY_LABELS[int(start.get("weekday", 0))])
			ace_weekday[weekday_key] = int(ace_weekday.get(weekday_key, 0)) + 1

	var slot_means: Dictionary = {}
	var team_season_count: float = float(max(1, GameDb.teams.size()))
	for key in starts_by_slot.keys():
		slot_means[key] = round(float(starts_by_slot[key]) / team_season_count * 10.0) / 10.0

	var distinct_counts: Array = []
	for team_pitchers_value in pitchers_by_team_season.values():
		distinct_counts.append((team_pitchers_value as Dictionary).size())
	distinct_counts.sort()

	return {
		"total_starts": starts.size(),
		"distinct_starters_per_team": {
			"min": 0 if distinct_counts.is_empty() else int(distinct_counts[0]),
			"mean": _mean(distinct_counts),
			"max": 0 if distinct_counts.is_empty() else int(distinct_counts[distinct_counts.size() - 1]),
		},
		"starts_by_slot": starts_by_slot,
		"mean_starts_per_team_by_slot": slot_means,
		"off_rotation_starts": off_rotation,
		"rest_gap_histogram": gap_hist,
		"ace_weekday_histogram": ace_weekday,
		"max_starts_by_one_pitcher": _max_value(starts_by_pitcher),
	}


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return round(total / float(values.size()) * 10.0) / 10.0


func _max_value(counts: Dictionary) -> int:
	var best: int = 0
	for value in counts.values():
		best = max(best, int(value))
	return best


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
