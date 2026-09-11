extends Node

# 雨天中止・降雨コールド・ノーゲームを1シーズン通しで実測するプローブ。
# `PSRainoutService.FEEL_SCALE` / `MONTHLY_RAIN_RATE` / `NATIONAL_RAIN_*` / `INTERRUPTION_WEIGHTS` を触る前後で
# 回して、次を確認する:
#   - 中止 / コールド / ノーゲームの件数 … NPB 公式ボックススコアの実測 (2023-2025) は
#     26.7 / 5.7 / 2.0 per season。FEEL_SCALE=1.0 でこの水準 (地方球場開催が無いぶん中止はやや少ない)。
#   - 月別の中止 … 4〜5 月が最多、6・7・9 月が少ないのが実データの形 (台風期の 8 月が次点)。
#   - コールドの成立回の分布 … 実測は 5回 8 / 6回 5 / 7回 3 / 8回 1、**4回はゼロ**。
#   - 振替先の内訳 … 移動日 (シーズン中) / 予備日 (最終試合日より後) の比率と、遅延日数。
#   - 全143試合を消化し切れているか (振替先の枯渇が無いか)。
#   - 消化試合数のばらつき (game_spread) … リーグ内の最多-最少と、最終戦の日付の差。
#   - 同じ日に流れる試合の重なり (same_day) … 実測は 2 件以上の日に起きた割合 52%、同じ日に 2 か所
#     流れる組が独立の場合の 4.9 倍 (別の地方どうしは 3.9 倍。本作の屋外球場は全て別の地方)。
#   - リーグ内の消化試合数のばらつき (game_spread) … NPB 公式の試合結果 (2023-2025、リーグ平均) は
#     7/1・8/1・9/1・9/15 時点の最多-最少が 3.8 / 4.5 / 4.8 / 4.3 試合、最初と最後の球団の最終戦が
#     3.8 日差、最初の球団が終えた時点で他球団の残りが最大 3.0 試合。中止を足し戻した当初の日程でも
#     3.8 試合ばらついていて、本作の日程生成は全球団共通のカード枠なのでこの成分がほぼ 0。
# 実行: godot --headless res://tools/run_rainout_probe.tscn -- --seasons=3
#       雨の重なりだけなら試合を回さず速い: -- --same_day_only --seasons=30

const SeasonCalendar = preload("res://services/season/season_calendar.gd")
const JapaneseHolidays = preload("res://services/season/japanese_holidays.gd")

# 消化試合数のばらつきを比べる日付 (MM-DD)。その日の試合の前 = 前日までの消化数で数える。
const SPREAD_CHECKPOINTS: Array[String] = ["07-01", "08-01", "09-01", "09-15"]


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))
	var output_path: String = str(args.get("output", ""))
	# 雨の重なり (same_day) だけを数えて試合は回さない。判定は純粋関数なので日程を作るだけで足り、
	# NATIONAL_RAIN_* の較正を多シーズンで速く回せる。
	var same_day_only: bool = args.has("same_day_only")

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
		# 雨の重なりは試合を回す前の日程で数える (回すと振替で日付が動く)。
		var same_day: Dictionary = _same_day_clustering(season)
		if same_day_only:
			season_reports.append({"same_day": same_day})
			continue
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
		var season_report: Dictionary = _summarize_season(season, season_index, scheduled_last_day)
		season_report["same_day"] = same_day
		season_reports.append(season_report)

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var report: Dictionary = {"same_day": _aggregate_same_day(season_reports)} if same_day_only else _aggregate(season_reports)
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
		"game_spread": _game_count_spread(season),
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
		"game_spread": _aggregate_spread(season_reports),
		"same_day": _aggregate_same_day(season_reports),
	}


# リーグ内の消化試合数のばらつき。全試合を消化し終えた日程 (振替後の日付) から後付けで数える。
# NPB 公式の試合結果ページから数えるのと同じ定義にしてあるので、実測とそのまま突き合わせられる。
#   - spread_before: チェックポイントの日の試合前時点での、リーグ内の最多消化 - 最少消化
#   - finish_spread_days: リーグで最初に全日程を終えた球団と最後の球団の日数差
#   - remaining_when_first_finished: 最初の球団が終えた日の終了時点で、他球団が残している最多試合数
#   - weekday_monday_games: 平日の月曜に組まれた試合。元の日程には無いので全て振替
func _game_count_spread(season: PSSeason) -> Dictionary:
	var dates_by_team: Dictionary = {}
	var weekday_monday_games: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var date_text: String = str(game.get("date", ""))
		for team_id in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			if not dates_by_team.has(team_id):
				dates_by_team[team_id] = []
			(dates_by_team[team_id] as Array).append(date_text)
		if SeasonCalendar.weekday_for_date(date_text) == 1 and not JapaneseHolidays.is_holiday(date_text):
			weekday_monday_games += 1

	var team_ids_by_league: Dictionary = {}
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if not team_ids_by_league.has(team.league):
			team_ids_by_league[team.league] = []
		(team_ids_by_league[team.league] as Array).append(team.id)

	var by_league: Dictionary = {}
	for league_key in team_ids_by_league.keys():
		var team_ids: Array = team_ids_by_league[league_key] as Array
		var spread_before: Dictionary = {}
		for checkpoint in SPREAD_CHECKPOINTS:
			var checkpoint_date: String = "%04d-%s" % [season.year, checkpoint]
			var fewest: int = 999
			var most: int = 0
			for team_id in team_ids:
				var played: int = _count_dates_before(dates_by_team.get(team_id, []) as Array, checkpoint_date)
				fewest = min(fewest, played)
				most = max(most, played)
			spread_before[checkpoint] = most - fewest
		var first_finish: String = ""
		var last_finish: String = ""
		for team_id in team_ids:
			var finish: String = _latest_date(dates_by_team.get(team_id, []) as Array)
			if first_finish.is_empty() or finish < first_finish:
				first_finish = finish
			if last_finish.is_empty() or finish > last_finish:
				last_finish = finish
		var remaining_max: int = 0
		var day_after_first_finish: String = SeasonCalendar.add_days(first_finish, 1)
		for team_id in team_ids:
			var dates: Array = dates_by_team.get(team_id, []) as Array
			remaining_max = max(remaining_max, dates.size() - _count_dates_before(dates, day_after_first_finish))
		by_league[league_key] = {
			"spread_before": spread_before,
			"first_finish": first_finish,
			"last_finish": last_finish,
			"finish_spread_days": SeasonCalendar.days_between(first_finish, last_finish),
			"remaining_when_first_finished": remaining_max,
			"by_team": _team_progress(season, team_ids, dates_by_team),
		}
	return {"by_league": by_league, "weekday_monday_games": weekday_monday_games}


# 球団ごとの消化試合数 (各チェックポイントの試合前) と最終戦の日付。どの球団が遅れているかを見る用。
func _team_progress(season: PSSeason, team_ids: Array, dates_by_team: Dictionary) -> Dictionary:
	var by_team: Dictionary = {}
	for team_id in team_ids:
		var dates: Array = dates_by_team.get(team_id, []) as Array
		var played_before: Dictionary = {}
		for checkpoint in SPREAD_CHECKPOINTS:
			played_before[checkpoint] = _count_dates_before(dates, "%04d-%s" % [season.year, checkpoint])
		var team: PSTeam = GameDb.get_team(int(team_id))
		by_team[team.short_name if team != null else str(team_id)] = {
			"played_before": played_before,
			"finish": _latest_date(dates),
			"open_air": team != null and not team.has_dome(),
		}
	return by_team


func _count_dates_before(dates: Array, date_text: String) -> int:
	var count: int = 0
	for value in dates:
		if str(value) < date_text:
			count += 1
	return count


func _latest_date(dates: Array) -> String:
	var latest: String = ""
	for value in dates:
		if str(value) > latest:
			latest = str(value)
	return latest


# 消化試合数のばらつきをシーズン × リーグで平均する。
func _aggregate_spread(season_reports: Array) -> Dictionary:
	var spread_totals: Dictionary = {}
	var finish_days_total: int = 0
	var remaining_total: int = 0
	var remaining_max: int = 0
	var monday_total: int = 0
	var samples: int = 0
	for report_value in season_reports:
		var spread: Dictionary = (report_value as Dictionary).get("game_spread", {}) as Dictionary
		monday_total += int(spread.get("weekday_monday_games", 0))
		for league_value in (spread.get("by_league", {}) as Dictionary).values():
			var league: Dictionary = league_value as Dictionary
			samples += 1
			finish_days_total += int(league.get("finish_spread_days", 0))
			remaining_total += int(league.get("remaining_when_first_finished", 0))
			remaining_max = max(remaining_max, int(league.get("remaining_when_first_finished", 0)))
			var spread_before: Dictionary = league.get("spread_before", {}) as Dictionary
			for checkpoint in SPREAD_CHECKPOINTS:
				spread_totals[checkpoint] = int(spread_totals.get(checkpoint, 0)) + int(spread_before.get(checkpoint, 0))
	var league_samples: float = float(max(1, samples))
	var spread_avg: Dictionary = {}
	for checkpoint in SPREAD_CHECKPOINTS:
		spread_avg[checkpoint] = snappedf(float(spread_totals.get(checkpoint, 0)) / league_samples, 0.1)
	return {
		"spread_before_avg": spread_avg,
		"finish_spread_days_avg": snappedf(float(finish_days_total) / league_samples, 0.1),
		"remaining_when_first_finished_avg": snappedf(float(remaining_total) / league_samples, 0.1),
		"remaining_when_first_finished_max": remaining_max,
		"weekday_monday_games_per_season": snappedf(float(monday_total) / float(max(1, season_reports.size())), 0.1),
	}


# 同じ日に雨が重なる度合い。日程生成直後の全試合に雨の判定だけを当てて数える (判定は純粋関数なので
# 試合を回さなくてよい)。数え方は NPB 公式の日程・結果ページの集計と同じで、屋外球場の試合のうち
# 中止とノーゲーム (後日やり直す試合) を「流れた試合」とする。
#   - days_by_count: 流れた試合が 1 / 2 / 3 件以上あった日の数
#   - observed_pairs / expected_pairs: 同じ日に流れた 2 試合の組の数と、月別の率で独立に抽選した場合の期待値
func _same_day_clustering(season: PSSeason) -> Dictionary:
	var games_by_day: Dictionary = {}
	var washed_by_day: Dictionary = {}
	var month_by_day: Dictionary = {}
	var games_by_month: Dictionary = {}
	var washed_by_month: Dictionary = {}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
		if home == null or home.has_dome():
			continue
		var day: int = int(game.get("day", 0))
		var month: int = int(str(game.get("date", "")).substr(5, 2))
		month_by_day[day] = month
		games_by_day[day] = int(games_by_day.get(day, 0)) + 1
		games_by_month[month] = int(games_by_month.get(month, 0)) + 1
		var kind: String = str(PSRainoutService.rain_outcome(season, game).get("kind", ""))
		if kind == PSRainoutService.OUTCOME_CANCEL or kind == PSRainoutService.OUTCOME_NO_GAME:
			washed_by_day[day] = int(washed_by_day.get(day, 0)) + 1
			washed_by_month[month] = int(washed_by_month.get(month, 0)) + 1

	var days_by_count: Dictionary = {}
	var observed_pairs: int = 0
	var expected_pairs: float = 0.0
	var washed_total: int = 0
	var washed_on_multi_days: int = 0
	for day in games_by_day.keys():
		var games: int = int(games_by_day[day])
		var washed: int = int(washed_by_day.get(day, 0))
		var month: int = int(month_by_day[day])
		var rate: float = float(washed_by_month.get(month, 0)) / float(max(1, int(games_by_month.get(month, 0))))
		@warning_ignore("integer_division")
		observed_pairs += washed * (washed - 1) / 2
		expected_pairs += float(games * (games - 1)) / 2.0 * rate * rate
		washed_total += washed
		if washed >= 2:
			washed_on_multi_days += washed
		if washed > 0:
			var key: String = "3+" if washed >= 3 else str(washed)
			days_by_count[key] = int(days_by_count.get(key, 0)) + 1
	return {
		"days_by_count": days_by_count,
		"observed_pairs": observed_pairs,
		"expected_pairs": expected_pairs,
		"washed": washed_total,
		"washed_on_multi_days": washed_on_multi_days,
	}


# 同じ日の重なりを全シーズンぶん足し合わせる。
func _aggregate_same_day(season_reports: Array) -> Dictionary:
	var days_by_count: Dictionary = {}
	var observed: int = 0
	var expected: float = 0.0
	var washed: int = 0
	var on_multi: int = 0
	for report_value in season_reports:
		var same_day: Dictionary = (report_value as Dictionary).get("same_day", {}) as Dictionary
		observed += int(same_day.get("observed_pairs", 0))
		expected += float(same_day.get("expected_pairs", 0.0))
		washed += int(same_day.get("washed", 0))
		on_multi += int(same_day.get("washed_on_multi_days", 0))
		var counts: Dictionary = same_day.get("days_by_count", {}) as Dictionary
		for key in counts.keys():
			days_by_count[key] = int(days_by_count.get(key, 0)) + int(counts[key])
	return {
		"days_by_count": days_by_count,
		"share_on_multi_days": snappedf(float(on_multi) / float(max(1, washed)), 0.01),
		"pair_ratio": snappedf(float(observed) / expected, 0.1) if expected > 0.0 else 0.0,
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
