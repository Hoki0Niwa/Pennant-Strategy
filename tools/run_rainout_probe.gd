extends Node

# 雨天中止・降雨コールド・ノーゲームを1シーズン通しで実測するプローブ。
# `PSRainoutService.FEEL_SCALE` / `MONTHLY_RAIN_RATE` / `INTERRUPTION_WEIGHTS` を触る前後で
# 回して、次を確認する:
#   - 中止 / コールド / ノーゲームの件数 … NPB 公式ボックススコアの実測 (2023-2025) は
#     26.7 / 5.7 / 2.0 per season。本作は FEEL_SCALE=0.5 なのでその半分前後が目標。
#   - 月別の中止 … 4〜5 月が最多、6・7・9 月が少ないのが実データの形 (台風期の 8 月が次点)。
#   - コールドの成立回の分布 … 実測は 5回 8 / 6回 5 / 7回 3 / 8回 1、**4回はゼロ**。
#   - 振替先の内訳 … 移動日 (シーズン中) / 予備日 (最終試合日より後) の比率と、遅延日数。
#   - 全143試合を消化し切れているか (振替先の枯渇が無いか)。
# 実行: godot --headless res://tools/run_rainout_probe.tscn -- --seasons=3

const SeasonCalendar = preload("res://services/season/season_calendar.gd")


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

	var season_reports: Array = []
	var errors: Array = []
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		var scheduled_last_day: int = _last_scheduled_day(season)
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
		season_reports.append(_summarize_season(season, season_index, scheduled_last_day))

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = _aggregate(season_reports)
	report["seed"] = seed_value
	report["seasons"] = seasons
	report["feel_scale"] = PSRainoutService.FEEL_SCALE
	report["reserve_days"] = PSRescheduleService.RESERVE_DAYS
	report["per_season"] = season_reports
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


# 日程生成直後の最終試合日。振替が「予備日 (これより後)」へ回ったかの判定に使う。
func _last_scheduled_day(season: PSSeason) -> int:
	var last_day: int = 0
	for game_value in season.schedule:
		last_day = max(last_day, int((game_value as Dictionary).get("day", 0)))
	return last_day


func _summarize_season(season: PSSeason, season_index: int, scheduled_last_day: int) -> Dictionary:
	var by_month: Dictionary = {}
	var by_home_team: Dictionary = {}
	var by_kind: Dictionary = {}
	var to_reserve: int = 0
	var delay_total: int = 0
	var delay_max: int = 0
	for entry_value in season.rainouts:
		var entry: Dictionary = entry_value as Dictionary
		var kind: String = str(entry.get("kind", PSRainoutService.OUTCOME_CANCEL))
		by_kind[kind] = int(by_kind.get(kind, 0)) + 1
		var month_key: String = str(entry.get("date", "")).substr(5, 2)
		by_month[month_key] = int(by_month.get(month_key, 0)) + 1
		var home_id: int = int(entry.get("home_team_id", 0))
		var home: PSTeam = GameDb.get_team(home_id)
		var team_key: String = home.short_name if home != null else str(home_id)
		by_home_team[team_key] = int(by_home_team.get(team_key, 0)) + 1
		var delay: int = int(entry.get("makeup_day", 0)) - int(entry.get("day", 0))
		delay_total += delay
		delay_max = max(delay_max, delay)
		if int(entry.get("makeup_day", 0)) > scheduled_last_day:
			to_reserve += 1

	var games_by_team: Dictionary = {}
	var unplayed: int = 0
	var called_innings: Dictionary = {}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("played", false)):
			unplayed += 1
		# 降雨コールドで成立した試合は打ち切られた回を持つ。実測の分布と突き合わせる。
		var called_after: int = int(game.get("called_after_inning", 0))
		if called_after > 0:
			var key: String = "%d回" % called_after
			called_innings[key] = int(called_innings.get(key, 0)) + 1
		for team_id in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			games_by_team[team_id] = int(games_by_team.get(team_id, 0)) + 1
	var min_games: int = 999
	var max_games: int = 0
	for count_value in games_by_team.values():
		min_games = min(min_games, int(count_value))
		max_games = max(max_games, int(count_value))

	var count: int = season.rainouts.size()
	return {
		"season_index": season_index,
		"postponed": count,
		"cancelled": int(by_kind.get(PSRainoutService.OUTCOME_CANCEL, 0)),
		"no_game": int(by_kind.get(PSRainoutService.OUTCOME_NO_GAME, 0)),
		"called_games": _sum_values(called_innings),
		"called_innings": called_innings,
		"by_month": by_month,
		"by_home_team": by_home_team,
		"to_move_day": count - to_reserve,
		"to_reserve_day": to_reserve,
		"delay_days_avg": (float(delay_total) / float(count)) if count > 0 else 0.0,
		"delay_days_max": delay_max,
		"scheduled_last_day": scheduled_last_day,
		"final_last_day": _last_scheduled_day(season),
		"games_per_team_min": min_games,
		"games_per_team_max": max_games,
		"unplayed_games": unplayed,
	}


func _sum_values(counts: Dictionary) -> int:
	var total: int = 0
	for value in counts.values():
		total += int(value)
	return total


func _aggregate(season_reports: Array) -> Dictionary:
	if season_reports.is_empty():
		return {}
	var total: int = 0
	var reserve: int = 0
	var cancelled: int = 0
	var no_game: int = 0
	var called: int = 0
	var called_innings: Dictionary = {}
	var by_month: Dictionary = {}
	var by_home_team: Dictionary = {}
	var worst_unplayed: int = 0
	var min_games: int = 999
	var max_games: int = 0
	for report_value in season_reports:
		var report: Dictionary = report_value as Dictionary
		total += int(report.get("postponed", 0))
		reserve += int(report.get("to_reserve_day", 0))
		cancelled += int(report.get("cancelled", 0))
		no_game += int(report.get("no_game", 0))
		called += int(report.get("called_games", 0))
		for inning_key in (report.get("called_innings", {}) as Dictionary).keys():
			called_innings[inning_key] = int(called_innings.get(inning_key, 0)) \
				+ int((report["called_innings"] as Dictionary)[inning_key])
		worst_unplayed = max(worst_unplayed, int(report.get("unplayed_games", 0)))
		min_games = min(min_games, int(report.get("games_per_team_min", 0)))
		max_games = max(max_games, int(report.get("games_per_team_max", 0)))
		for month_key in (report.get("by_month", {}) as Dictionary).keys():
			by_month[month_key] = int(by_month.get(month_key, 0)) + int((report["by_month"] as Dictionary)[month_key])
		for team_key in (report.get("by_home_team", {}) as Dictionary).keys():
			by_home_team[team_key] = int(by_home_team.get(team_key, 0)) + int((report["by_home_team"] as Dictionary)[team_key])

	var seasons: float = float(season_reports.size())
	var per_season_month: Dictionary = {}
	for month_key in by_month.keys():
		per_season_month[month_key] = snappedf(float(by_month[month_key]) / seasons, 0.1)
	var per_season_team: Dictionary = {}
	for team_key in by_home_team.keys():
		per_season_team[team_key] = snappedf(float(by_home_team[team_key]) / seasons, 0.1)

	var per_season_innings: Dictionary = {}
	for inning_key in called_innings.keys():
		per_season_innings[inning_key] = snappedf(float(called_innings[inning_key]) / seasons, 0.1)

	# NPB 公式ボックススコア実測 (2023-2025) は 中止 26.7 / コールド 5.7 / ノーゲーム 2.0。
	return {
		"postponed_per_season": snappedf(float(total) / seasons, 0.1),
		"cancelled_per_season": snappedf(float(cancelled) / seasons, 0.1),
		"called_games_per_season": snappedf(float(called) / seasons, 0.1),
		"no_game_per_season": snappedf(float(no_game) / seasons, 0.1),
		"called_innings_per_season": per_season_innings,
		"reserve_share": snappedf(float(reserve) / float(max(1, total)), 0.01),
		"postponed_per_season_by_month": per_season_month,
		"postponed_per_season_by_home_team": per_season_team,
		"games_per_team_min": min_games,
		"games_per_team_max": max_games,
		"worst_unplayed_games": worst_unplayed,
	}


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
