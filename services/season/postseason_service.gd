extends RefCounted
class_name PostseasonService

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const CS1_WIN_TARGET: int = 2  # 3戦先勝(2勝)
const CS2_WIN_TARGET: int = 4  # 6戦中4勝(1位は1勝アドバンテージ)
const CS2_ADVANTAGE: int = 1
# 2026年規定の加算アドバンテージ。1位とファースト勝者のゲーム差が CS2_EXTENDED_GAME_GAP 以上、
# またはファースト勝者の勝率が CS2_EXTENDED_WIN_RATE 未満のとき、CSファイナルは
# 7戦中5勝 (1位に2勝アドバンテージ) になる。
const CS2_EXTENDED_WIN_TARGET: int = 5
const CS2_EXTENDED_ADVANTAGE: int = 2
const CS2_EXTENDED_GAME_GAP: float = 10.0
const CS2_EXTENDED_WIN_RATE: float = 0.5
# CSファイナルの日程枠は常に最大試合数 (2勝アドバンテージ時の7) を確保する。
# 1勝アドバンテージなら規定6試合で打ち切られ、7枠目は使われない。
const CS2_SCHEDULE_SLOTS: int = 7
const JS_WIN_TARGET: int = 4   # BO7
const MAX_SAFETY_GAMES: int = 15  # 引き分け連続でも無限ループ防止
const POSTSEASON_STATS_VERSION: int = 1
const POSTSEASON_SCHEDULE_VERSION: int = 2
const POSTSEASON_MONTH: int = 10
const WEEKDAY_WEDNESDAY: int = 3
const WEEKDAY_SATURDAY: int = 6
const FIRST_LEAGUE: String = "league1"
const SECOND_LEAGUE: String = "league2"
const HOME_SIDE_TOP: String = "top"
const HOME_SIDE_CHALLENGER: String = "challenger"


static func build_initial_state(season: PSSeason, teams: Array, cs_advantage_rule: String = PSPostseasonResult.CS_ADVANTAGE_RULE_NPB2026) -> PSPostseasonResult:
	var result: PSPostseasonResult = PSPostseasonResult.new()
	result.year = season.year
	result.season_number = season.season_number
	result.cs_advantage_rule = PSPostseasonResult.normalize_cs_advantage_rule(cs_advantage_rule)

	var by_league: Dictionary = _league_standings(season, teams)
	var league1_ranked: Array = by_league.get("league1", []) as Array
	var league2_ranked: Array = by_league.get("league2", []) as Array

	if league1_ranked.size() >= 3:
		var c2: PSTeam = league1_ranked[1] as PSTeam
		var c3: PSTeam = league1_ranked[2] as PSTeam
		result.cs1_league1 = PSPostseasonResult.make_pending_series(c2.id, c3.id, CS1_WIN_TARGET, 0)
	if league2_ranked.size() >= 3:
		var p2: PSTeam = league2_ranked[1] as PSTeam
		var p3: PSTeam = league2_ranked[2] as PSTeam
		result.cs1_league2 = PSPostseasonResult.make_pending_series(p2.id, p3.id, CS1_WIN_TARGET, 0)
	# CSファイナルの勝敗条件は挑戦者 (ファースト勝者) が決まってから確定する。ここでは通常規定
	# (1勝アドバンテージ/4勝先取) で作り、_apply_cs_final_terms が充填時に上書きする。
	if league1_ranked.size() >= 1:
		var c1: PSTeam = league1_ranked[0] as PSTeam
		result.cs2_league1 = PSPostseasonResult.make_pending_series(c1.id, 0, CS2_WIN_TARGET, CS2_ADVANTAGE)
	if league2_ranked.size() >= 1:
		var p1: PSTeam = league2_ranked[0] as PSTeam
		result.cs2_league2 = PSPostseasonResult.make_pending_series(p1.id, 0, CS2_WIN_TARGET, CS2_ADVANTAGE)
	var japan_series: Dictionary = PSPostseasonResult.make_pending_series(0, 0, JS_WIN_TARGET, 0)
	# 日本シリーズは規定試合数で打ち切らず、決着するまで延長戦を行う (引き分けでの上位勝ち抜けはしない)。
	japan_series["extension"] = true
	result.japan_series = japan_series
	_apply_postseason_schedule(result, season)
	return result


# ============================================================ CSファイナルのアドバンテージ規定
#
# 2026年規定 (npb2026): 通常は1勝アドバンテージ・6試合・4勝先取。ただし
#   (a) リーグ1位とファースト勝者のゲーム差が10以上、または
#   (b) ファースト勝者のレギュラーシーズン勝率が5割未満
# のいずれかなら 2勝アドバンテージ・7試合・5勝先取へ引き上げる。
# 旧規定 (legacy): 条件によらず常に1勝アドバンテージ・6試合・4勝先取。
# 判定はレギュラーシーズンの成績 (season.standings) で行うため、CSファースト勝者が
# 確定した時点で一度だけ評価すればよい。
static func cs_final_terms(season: PSSeason, top_id: int, challenger_id: int, rule: String) -> Dictionary:
	var standard: Dictionary = {
		"win_target": CS2_WIN_TARGET,
		"advantage_wins": CS2_ADVANTAGE,
		"extended": false,
		"reason": "",
	}
	if PSPostseasonResult.normalize_cs_advantage_rule(rule) != PSPostseasonResult.CS_ADVANTAGE_RULE_NPB2026:
		return standard
	if season == null or top_id <= 0 or challenger_id <= 0:
		return standard
	var top_stats: PSStats = season.standings.get(top_id, null) as PSStats
	var challenger_stats: PSStats = season.standings.get(challenger_id, null) as PSStats
	if top_stats == null or challenger_stats == null:
		return standard

	var extended: Dictionary = {
		"win_target": CS2_EXTENDED_WIN_TARGET,
		"advantage_wins": CS2_EXTENDED_ADVANTAGE,
		"extended": true,
		"reason": "",
	}
	var game_gap: float = cs_final_game_gap(top_stats, challenger_stats)
	if game_gap >= CS2_EXTENDED_GAME_GAP:
		extended["reason"] = "ゲーム差%.1f" % game_gap
		return extended
	var challenger_win_rate: float = challenger_stats.win_rate()
	if challenger_win_rate < CS2_EXTENDED_WIN_RATE:
		extended["reason"] = "挑戦者の勝率%.3f" % challenger_win_rate
		return extended
	return standard


# ゲーム差 = ((上位の勝 - 下位の勝) + (下位の負 - 上位の負)) / 2。順位表の「差」列と同じ式。
static func cs_final_game_gap(top_stats: PSStats, challenger_stats: PSStats) -> float:
	if top_stats == null or challenger_stats == null:
		return 0.0
	return float((top_stats.wins - challenger_stats.wins) + (challenger_stats.losses - top_stats.losses)) / 2.0


# 挑戦者が確定した CSファイナルへ規定を適用する。まだ1試合も消化していない前提で、
# アドバンテージ分を top_wins の初期値に入れ直す。
static func _apply_cs_final_terms(postseason: PSPostseasonResult, series: Dictionary, season: PSSeason) -> void:
	if series.is_empty() or bool(series.get("cs_terms_applied", false)):
		return
	var top_id: int = int(series.get("top_id", 0))
	var challenger_id: int = int(series.get("challenger_id", 0))
	if top_id <= 0 or challenger_id <= 0:
		return
	var rule: String = PSPostseasonResult.CS_ADVANTAGE_RULE_NPB2026 if postseason == null else postseason.cs_advantage_rule
	var terms: Dictionary = cs_final_terms(season, top_id, challenger_id, rule)
	series["win_target"] = int(terms["win_target"])
	series["advantage_wins"] = int(terms["advantage_wins"])
	series["advantage_extended"] = bool(terms["extended"])
	series["advantage_reason"] = str(terms["reason"])
	series["cs_terms_applied"] = true
	if (series.get("games", []) as Array).is_empty():
		series["top_wins"] = int(terms["advantage_wins"])


static func advance_stage(postseason: PSPostseasonResult, stage_key: String, season: PSSeason) -> Dictionary:
	var s: Dictionary = postseason.stage_dict(stage_key)
	if s.is_empty():
		return {"ok": false, "message": "ステージが存在しません"}
	if bool(s.get("completed", false)):
		return {"ok": false, "message": "既に完了しています"}

	# CS2 / JS は前段の勝者を充填
	if stage_key == "cs2_league1":
		var w: int = int(postseason.cs1_league1.get("winner_id", 0))
		if w == 0:
			return {"ok": false, "message": "CS1 第1リーグが未消化です"}
		s["challenger_id"] = w
		_apply_cs_final_terms(postseason, s, season)
	elif stage_key == "cs2_league2":
		var w2: int = int(postseason.cs1_league2.get("winner_id", 0))
		if w2 == 0:
			return {"ok": false, "message": "CS1 第2リーグが未消化です"}
		s["challenger_id"] = w2
		_apply_cs_final_terms(postseason, s, season)
	elif stage_key == "japan_series":
		var c: int = int(postseason.cs2_league1.get("winner_id", 0))
		var p: int = int(postseason.cs2_league2.get("winner_id", 0))
		if c == 0 or p == 0:
			return {"ok": false, "message": "CS2が未消化です"}
		if str(s.get("first_home_league", _japan_series_first_home_league(postseason.season_number))) == FIRST_LEAGUE:
			s["top_id"] = c
			s["challenger_id"] = p
		else:
			s["top_id"] = p
			s["challenger_id"] = c

	var sim: Dictionary = _simulate_series(season, s)
	for key in sim.keys():
		s[key] = sim[key]
	s["completed"] = true
	postseason.set_stage(stage_key, s)

	if stage_key == "japan_series":
		postseason.champion_team_id = int(s.get("winner_id", 0))

	return {"ok": true, "stage": stage_key, "series": s}


static func is_complete(postseason: PSPostseasonResult) -> bool:
	if postseason == null:
		return false
	return postseason.is_complete()


# ============================================================ 日単位消化 (game-by-game)
#
# ホーム画面を踏襲した運用 UI 向けに、シリーズ一括ではなく「1日 = 進行中グループの全シリーズを
# 1 試合ずつ」消化する。CS ファースト(第1/第2リーグ) → CS ファイナル → 日本シリーズ の順に
# グループが進み、各グループ内の 2 シリーズは並行して 1 日 1 試合ずつ消化される。

# 進行中グループ(まだ完了していない最初のグループ)の index。全消化済みなら STAGE_GROUPS.size()。
static func active_group_index(postseason: PSPostseasonResult) -> int:
	if postseason == null:
		return 0
	var groups: Array = PSPostseasonResult.STAGE_GROUPS
	for gi in range(groups.size()):
		for key in (groups[gi] as Array):
			var s: Dictionary = postseason.stage_dict(str(key))
			if s.is_empty():
				continue
			if not bool(s.get("completed", false)):
				return gi
	return groups.size()


# 進行中グループのステージキー配列 (空 = 全消化済み)。
static func active_group_keys(postseason: PSPostseasonResult) -> Array:
	var gi: int = active_group_index(postseason)
	var groups: Array = PSPostseasonResult.STAGE_GROUPS
	if gi >= groups.size():
		return []
	return (groups[gi] as Array).duplicate()


static func _ensure_postseason_schedule(postseason: PSPostseasonResult, season: PSSeason) -> void:
	if postseason == null or season == null:
		return
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var series: Dictionary = postseason.stage_dict(str(stage_key))
		if series.is_empty():
			continue
		if not series.has("scheduled_days") or (series.get("scheduled_days", []) as Array).is_empty():
			_apply_postseason_schedule(postseason, season)
			return
		if int(series.get("schedule_version", 0)) != POSTSEASON_SCHEDULE_VERSION:
			_apply_postseason_schedule(postseason, season)
			return


static func _apply_postseason_schedule(postseason: PSPostseasonResult, season: PSSeason) -> void:
	if postseason == null or season == null:
		return
	var cs1_start: String = SeasonCalendar.nth_weekday_of_month(season.year, POSTSEASON_MONTH, WEEKDAY_SATURDAY, 2)
	var cs2_start: String = SeasonCalendar.first_weekday_on_or_after(SeasonCalendar.add_days(cs1_start, 3), WEEKDAY_WEDNESDAY)
	var js_start: String = SeasonCalendar.add_days(cs2_start, 10)
	var first_home_league: String = _japan_series_first_home_league(season.season_number)
	var second_home_league: String = SECOND_LEAGUE if first_home_league == FIRST_LEAGUE else FIRST_LEAGUE

	_set_series_schedule(
		postseason.cs1_league1,
		_dates_from_offsets(cs1_start, [0, 1, 2]),
		[HOME_SIDE_TOP, HOME_SIDE_TOP, HOME_SIDE_TOP],
		season
	)
	_set_series_schedule(
		postseason.cs1_league2,
		_dates_from_offsets(cs1_start, [0, 1, 2]),
		[HOME_SIDE_TOP, HOME_SIDE_TOP, HOME_SIDE_TOP],
		season
	)
	# CSファイナルは全試合が1位球団の本拠地開催。枠は常に7試合分用意し、規定試合数を超えた
	# 分は消化されない (1勝アドバンテージなら6試合で打ち切り)。
	var cs2_offsets: Array = []
	var cs2_home_sides: Array = []
	for i in range(CS2_SCHEDULE_SLOTS):
		cs2_offsets.append(i)
		cs2_home_sides.append(HOME_SIDE_TOP)
	_set_series_schedule(postseason.cs2_league1, _dates_from_offsets(cs2_start, cs2_offsets), cs2_home_sides, season)
	_set_series_schedule(postseason.cs2_league2, _dates_from_offsets(cs2_start, cs2_offsets), cs2_home_sides, season)
	_set_series_schedule(
		postseason.japan_series,
		_dates_from_offsets(js_start, [0, 1, 3, 4, 5, 7, 8]),
		[
			HOME_SIDE_TOP,
			HOME_SIDE_TOP,
			HOME_SIDE_CHALLENGER,
			HOME_SIDE_CHALLENGER,
			HOME_SIDE_CHALLENGER,
			HOME_SIDE_TOP,
			HOME_SIDE_TOP,
		],
		season
	)
	postseason.japan_series["first_home_league"] = first_home_league
	postseason.japan_series["second_home_league"] = second_home_league


static func _dates_from_offsets(start_date: String, offsets: Array) -> Array:
	var out: Array = []
	for offset_value in offsets:
		out.append(SeasonCalendar.add_days(start_date, int(offset_value)))
	return out


static func _set_series_schedule(series: Dictionary, dates: Array, home_sides: Array, season: PSSeason) -> void:
	if series.is_empty() or season == null:
		return
	var days: Array = []
	for date_value in dates:
		days.append(SeasonCalendar.season_day_for_date(season, str(date_value)))
	series["schedule_version"] = POSTSEASON_SCHEDULE_VERSION
	series["scheduled_dates"] = dates.duplicate()
	series["scheduled_days"] = days
	series["home_sides"] = home_sides.duplicate()


static func _japan_series_first_home_league(season_number: int) -> String:
	return FIRST_LEAGUE if season_number % 2 == 1 else SECOND_LEAGUE


static func _next_scheduled_day(postseason: PSPostseasonResult, season: PSSeason) -> int:
	var best: int = 0
	for key_value in active_group_keys(postseason):
		var stage_key: String = str(key_value)
		var series: Dictionary = postseason.stage_dict(stage_key)
		if series.is_empty() or bool(series.get("completed", false)):
			continue
		if not _ensure_series_ready(postseason, stage_key, series, season):
			continue
		postseason.set_stage(stage_key, series)
		var game_num: int = (series.get("games", []) as Array).size() + 1
		var day: int = _series_next_game_day(series, season, game_num)
		if day <= 0:
			continue
		if best == 0 or day < best:
			best = day
	return best


static func _series_next_game_day(series: Dictionary, _season: PSSeason, game_num: int) -> int:
	if game_num <= 0:
		return 0
	var days: Array = series.get("scheduled_days", []) as Array
	var index: int = game_num - 1
	if index >= 0 and index < days.size():
		return int(days[index])
	if not bool(series.get("extension", false)) or days.is_empty():
		return 0
	return int(days[days.size() - 1]) + (index - days.size() + 1)


static func _series_date_for_game(series: Dictionary, season: PSSeason, game_num: int, season_day: int) -> String:
	var dates: Array = series.get("scheduled_dates", []) as Array
	var index: int = game_num - 1
	if index >= 0 and index < dates.size():
		return str(dates[index])
	if season != null and season_day > 0:
		return SeasonCalendar.date_for_season_day(season, season_day)
	return ""


static func next_home_side_for_series(series: Dictionary, game_num: int) -> String:
	if game_num <= 0:
		return HOME_SIDE_TOP
	var sides: Array = series.get("home_sides", []) as Array
	var index: int = game_num - 1
	if index >= 0 and index < sides.size():
		return str(sides[index])
	if bool(series.get("extension", false)) and not sides.is_empty():
		var last_side: String = str(sides[sides.size() - 1])
		var extra_index: int = index - sides.size()
		if extra_index % 2 == 0:
			return HOME_SIDE_CHALLENGER if last_side == HOME_SIDE_TOP else HOME_SIDE_TOP
		return last_side
	return HOME_SIDE_TOP if (game_num <= 2 or game_num >= 6) else HOME_SIDE_CHALLENGER


static func _move_season_to_day(season: PSSeason, target_day: int) -> int:
	if season == null or target_day <= 0 or season.current_day >= target_day:
		return 0
	var elapsed_days: int = target_day - season.current_day
	season.current_day = target_day
	PSGameDecisions.recover_after_day(season, elapsed_days)
	return elapsed_days


static func _advance_to_next_postseason_day_or_after_finish(postseason: PSPostseasonResult, season: PSSeason) -> int:
	var next_day: int = _next_scheduled_day(postseason, season)
	if next_day > 0:
		return _move_season_to_day(season, next_day)
	return _move_season_to_day(season, season.current_day + 1)


static func _team_games_played_before_by_team(postseason: PSPostseasonResult, season: PSSeason) -> Dictionary:
	var out: Dictionary = {}
	if season == null:
		return out
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var stats: PSStats = season.standings.get(team.id, null) as PSStats
		out[team.id] = 0 if stats == null else stats.games
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var series: Dictionary = postseason.stage_dict(str(stage_key))
		for game_value in (series.get("games", []) as Array):
			var game: Dictionary = game_value as Dictionary
			var away_id: int = int(game.get("away_id", 0))
			var home_id: int = int(game.get("home_id", 0))
			if away_id > 0:
				out[away_id] = int(out.get(away_id, out.get(str(away_id), 0))) + 1
			if home_id > 0:
				out[home_id] = int(out.get(home_id, out.get(str(home_id), 0))) + 1
	return out


static func _team_games_before(team_games_before_by_team: Dictionary, team_id: int, fallback: int) -> int:
	if team_games_before_by_team.has(team_id):
		return int(team_games_before_by_team.get(team_id, fallback))
	if team_games_before_by_team.has(str(team_id)):
		return int(team_games_before_by_team.get(str(team_id), fallback))
	return fallback


static func sync_to_next_postseason_day(postseason: PSPostseasonResult, season: PSSeason) -> Dictionary:
	if postseason == null or season == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	_ensure_postseason_schedule(postseason, season)
	var target_day: int = _next_scheduled_day(postseason, season)
	if target_day <= 0:
		return {"ok": false, "completed": is_complete(postseason), "message": "未消化のポストシーズン日程がありません"}
	var recovery_days: int = _move_season_to_day(season, target_day)
	return {
		"ok": true,
		"completed": is_complete(postseason),
		"season_day": target_day,
		"date": SeasonCalendar.date_for_season_day(season, target_day),
		"recovery_days": recovery_days,
	}


# 1日進める: 次のポストシーズン試合日まで season.current_day を進め、その日にある試合を消化する。
static func advance_one_day(postseason: PSPostseasonResult, season: PSSeason, persist: bool = true) -> Dictionary:
	if postseason == null or season == null:
		return {"ok": false, "message": "ポストシーズンが開始されていません"}
	_ensure_postseason_schedule(postseason, season)
	var keys: Array = active_group_keys(postseason)
	if keys.is_empty():
		return {"ok": false, "completed": true, "message": "ポストシーズンは終了しています"}
	var target_day: int = _next_scheduled_day(postseason, season)
	if target_day <= 0:
		return {"ok": false, "completed": is_complete(postseason), "message": "消化できるポストシーズン日程がありません"}
	var recovery_before: int = _move_season_to_day(season, target_day)
	postseason.current_day += 1
	var play_day: int = postseason.current_day
	var played: Array = []
	var team_games_before: Dictionary = _team_games_played_before_by_team(postseason, season)
	for key_value in keys:
		var stage_key: String = str(key_value)
		var s: Dictionary = postseason.stage_dict(stage_key)
		if s.is_empty() or bool(s.get("completed", false)):
			continue
		if not _ensure_series_ready(postseason, stage_key, s, season):
			continue
		var next_game_day: int = _series_next_game_day(s, season, int((s.get("games", []) as Array).size()) + 1)
		if next_game_day != target_day:
			continue
		var r: Dictionary = play_series_game(season, s, play_day, team_games_before)
		postseason.set_stage(stage_key, s)
		if bool(r.get("ok", false)):
			var game_entry: Dictionary = r.get("game", {}) as Dictionary
			if persist:
				_write_postseason_game_log(season, stage_key, game_entry)
			played.append({"stage": stage_key, "game": game_entry})
		if stage_key == "japan_series" and bool(s.get("completed", false)):
			postseason.champion_team_id = int(s.get("winner_id", 0))
	var recovery_after: int = _advance_to_next_postseason_day_or_after_finish(postseason, season)
	if persist:
		PSGameDecisions.persist_records()
	return {
		"ok": true,
		"completed": is_complete(postseason),
		"day": play_day,
		"season_day": target_day,
		"date": SeasonCalendar.date_for_season_day(season, target_day),
		"recovery_days": recovery_before + recovery_after,
		"played": played,
	}


# CS2 / 日本シリーズの対戦カードを前段の勝者で充填する。両者が確定したら true。
# CSファイナルは挑戦者が入った時点でアドバンテージ規定 (勝敗条件) も確定させる。
static func _ensure_series_ready(postseason: PSPostseasonResult, stage_key: String, s: Dictionary, season: PSSeason = null) -> bool:
	match stage_key:
		"cs2_league1":
			if int(s.get("challenger_id", 0)) == 0:
				s["challenger_id"] = int(postseason.cs1_league1.get("winner_id", 0))
			_apply_cs_final_terms(postseason, s, season)
		"cs2_league2":
			if int(s.get("challenger_id", 0)) == 0:
				s["challenger_id"] = int(postseason.cs1_league2.get("winner_id", 0))
			_apply_cs_final_terms(postseason, s, season)
		"japan_series":
			var league1_winner: int = int(postseason.cs2_league1.get("winner_id", 0))
			var league2_winner: int = int(postseason.cs2_league2.get("winner_id", 0))
			var first_home_league: String = str(s.get("first_home_league", _japan_series_first_home_league(postseason.season_number)))
			if first_home_league == FIRST_LEAGUE:
				if int(s.get("top_id", 0)) == 0:
					s["top_id"] = league1_winner
				if int(s.get("challenger_id", 0)) == 0:
					s["challenger_id"] = league2_winner
			else:
				if int(s.get("top_id", 0)) == 0:
					s["top_id"] = league2_winner
				if int(s.get("challenger_id", 0)) == 0:
					s["challenger_id"] = league1_winner
	return int(s.get("top_id", 0)) > 0 and int(s.get("challenger_id", 0)) > 0


# シリーズで 1 試合だけ消化し、結果を series へ反映する。series は in-place で更新される。
static func play_series_game(season: PSSeason, series: Dictionary, day: int, team_games_before_by_team: Dictionary = {}) -> Dictionary:
	var top_id: int = int(series.get("top_id", 0))
	var challenger_id: int = int(series.get("challenger_id", 0))
	if top_id <= 0 or challenger_id <= 0:
		return {"ok": false, "message": "対戦カードが未確定です"}
	var advantage: int = int(series.get("advantage_wins", 0))
	var top_wins: int = int(series.get("top_wins", advantage))
	var challenger_wins: int = int(series.get("challenger_wins", 0))
	var games: Array = series.get("games", []) as Array
	if _series_decided(series, top_wins, challenger_wins, games.size()):
		_finalize_series(series, top_id, challenger_id, top_wins, challenger_wins)
		return {"ok": false, "completed": true}
	var postseason_stats: Dictionary = _normalized_postseason_stats(series.get("postseason_stats", {}) as Dictionary)
	var game_num: int = games.size() + 1
	var home_is_top: bool = next_home_side_for_series(series, game_num) != HOME_SIDE_CHALLENGER
	var home_id: int = top_id if home_is_top else challenger_id
	var away_id: int = challenger_id if home_is_top else top_id
	var season_day: int = _series_next_game_day(series, season, game_num)
	var date_text: String = _series_date_for_game(series, season, game_num, season_day)

	var outcome: Dictionary = _simulate_one_postseason_game(season, away_id, home_id, postseason_stats, season_day, team_games_before_by_team)
	var winner_id: int = int(outcome.get("winning_team_id", 0))
	var is_draw: bool = bool(outcome.get("draw", false))
	if not is_draw:
		if winner_id == top_id:
			top_wins += 1
		elif winner_id == challenger_id:
			challenger_wins += 1

	var game_entry: Dictionary = {
		"game_num": game_num,
		"day": day,
		"season_day": season_day,
		"date": date_text,
		"away_id": away_id,
		"home_id": home_id,
		"away_score": int(outcome.get("away_score", 0)),
		"home_score": int(outcome.get("home_score", 0)),
		"winner_id": winner_id,
		"draw": is_draw,
		"result": outcome,
	}
	games.append(game_entry)
	series["games"] = games
	series["top_wins"] = top_wins
	series["challenger_wins"] = challenger_wins
	series["postseason_stats"] = postseason_stats

	var completed: bool = _series_decided(series, top_wins, challenger_wins, games.size())
	if completed:
		_finalize_series(series, top_id, challenger_id, top_wins, challenger_wins)
	return {"ok": true, "completed": completed, "game": game_entry}


# シリーズの規定試合数 (= 最大試合数)。アドバンテージ分だけ試合数が減る。
#   CSファースト: 2*2-0-1=3 / CSファイナル: 2*4-1-1=6 (2勝アドバンテージなら 2*5-2-1=7)。
# 日本シリーズ (extension=true) は打ち切らず決着まで延長戦。MAX_SAFETY_GAMES は無限ループ防止の保険。
static func series_max_games(series: Dictionary) -> int:
	if bool(series.get("extension", false)):
		return MAX_SAFETY_GAMES
	return 2 * int(series.get("win_target", 4)) - int(series.get("advantage_wins", 0)) - 1


# シリーズの勝ち抜けが確定したか。先勝到達・規定試合数消化に加え、引き分けを挟んで
# 残り試合では結果が覆らなくなった時点でも終了する (同勝数なら上位が勝ち抜けるため、
# 下位が上位を「上回れない」ことが確定した時点で残り試合は行わない)。
# 日本シリーズ (extension=true) は同勝数での勝ち抜けがないのでこの判定を行わない。
static func _series_decided(series: Dictionary, top_wins: int, challenger_wins: int, games_played: int) -> bool:
	var win_target: int = int(series.get("win_target", 4))
	if top_wins >= win_target or challenger_wins >= win_target:
		return true
	if bool(series.get("extension", false)):
		return false
	var remaining: int = series_max_games(series) - games_played
	if remaining <= 0:
		return true
	return challenger_wins + remaining <= top_wins or challenger_wins > top_wins + remaining


# シリーズを完了扱いにし、勝者を確定する。先勝に届いていないイーブン時 (引き分けで規定試合数に到達)は
# 勝ち星の多い方、同数なら上位 (top = ペナント上位/1位) が勝ち抜ける。
static func _finalize_series(series: Dictionary, top_id: int, challenger_id: int, top_wins: int, challenger_wins: int) -> void:
	series["completed"] = true
	series["winner_id"] = top_id if top_wins >= challenger_wins else challenger_id
	series["top_wins_final"] = top_wins
	series["challenger_wins_final"] = challenger_wins


static func _write_postseason_game_log(season: PSSeason, stage_key: String, game_entry: Dictionary) -> void:
	var result: Dictionary = game_entry.get("result", {}) as Dictionary
	if result.is_empty():
		return
	PSGameLogService.write_postseason_game_log(season, stage_key, int(game_entry.get("game_num", 0)), result)


static func _league_standings(season: PSSeason, teams: Array) -> Dictionary:
	var by_league: Dictionary = {"league1": [], "league2": []}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if not by_league.has(team.league):
			continue
		if not season.standings.has(team.id):
			continue
		by_league[team.league].append({"team": team, "stats": season.standings[team.id]})

	for key in by_league.keys():
		var rows: Array = by_league[key] as Array
		rows.sort_custom(func(a, b) -> bool:
			var stats_a: PSStats = (a as Dictionary)["stats"] as PSStats
			var stats_b: PSStats = (b as Dictionary)["stats"] as PSStats
			if stats_a.win_rate() == stats_b.win_rate():
				return stats_a.wins > stats_b.wins
			return stats_a.win_rate() > stats_b.win_rate()
		)
		var team_list: Array = []
		for row in rows:
			team_list.append((row as Dictionary)["team"])
		by_league[key] = team_list
	return by_league


static func _simulate_series(season: PSSeason, series: Dictionary) -> Dictionary:
	var top_id: int = int(series.get("top_id", 0))
	var challenger_id: int = int(series.get("challenger_id", 0))
	var win_target: int = int(series.get("win_target", 4))
	var advantage: int = int(series.get("advantage_wins", 0))
	var top_wins: int = advantage
	var challenger_wins: int = 0
	var games: Array = []
	var postseason_stats: Dictionary = _normalized_postseason_stats(series.get("postseason_stats", {}) as Dictionary)

	while top_wins < win_target and challenger_wins < win_target:
		if games.size() >= MAX_SAFETY_GAMES:
			break
		var game_num: int = games.size() + 1
		var home_is_top: bool = next_home_side_for_series(series, game_num) != HOME_SIDE_CHALLENGER
		var home_id: int = top_id if home_is_top else challenger_id
		var away_id: int = challenger_id if home_is_top else top_id

		var game_outcome: Dictionary = _simulate_one_postseason_game(season, away_id, home_id, postseason_stats)
		var winner_id: int = int(game_outcome.get("winning_team_id", 0))
		var is_draw: bool = bool(game_outcome.get("draw", false))
		games.append({
			"game_num": game_num,
			"away_id": away_id,
			"home_id": home_id,
			"away_score": int(game_outcome.get("away_score", 0)),
			"home_score": int(game_outcome.get("home_score", 0)),
			"winner_id": winner_id,
			"draw": is_draw,
		})
		if is_draw:
			continue
		if winner_id == top_id:
			top_wins += 1
		elif winner_id == challenger_id:
			challenger_wins += 1

	var final_winner: int = 0
	if top_wins >= win_target:
		final_winner = top_id
	elif challenger_wins >= win_target:
		final_winner = challenger_id

	return {
		"games": games,
		"winner_id": final_winner,
		"top_wins_final": top_wins,
		"challenger_wins_final": challenger_wins,
		"postseason_stats": postseason_stats,
	}


static func _simulate_one_postseason_game(
	season: PSSeason,
	away_id: int,
	home_id: int,
	postseason_stats: Dictionary = {},
	game_day: int = 0,
	team_games_before_by_team: Dictionary = {}
) -> Dictionary:
	# postseason=true で短期決戦用のローテ判断 (序列上位のみ・中5日/中4日を通常運用) に切り替える。
	# 打線はペナントと同じく相手先発の左右で組む (away の 1 回目は右投手を仮定し、
	# home の先発が左なら組み直す)。
	var away_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(
		season, away_id, true, true, PSTeamSetupBuilder.LEVEL_FIRST, PSPlatoonMatchup.DEFAULT_PITCHER_HAND
	)
	var home_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(
		season, home_id, true, true, PSTeamSetupBuilder.LEVEL_FIRST, GameSimulator.starter_hand(away_setup)
	)
	if not bool(away_setup.get("ok", false)) or not bool(home_setup.get("ok", false)):
		return {"away_score": 0, "home_score": 0, "draw": true, "winning_team_id": 0}
	if GameSimulator.starter_hand(home_setup) == PSPlatoonMatchup.HAND_LEFT:
		var away_vs_left: Dictionary = PSTeamSetupBuilder.build_team_setup(
			season, away_id, true, true, PSTeamSetupBuilder.LEVEL_FIRST, PSPlatoonMatchup.HAND_LEFT
		)
		if bool(away_vs_left.get("ok", false)):
			away_setup = away_vs_left
	_apply_postseason_setup_overrides(away_setup, away_id, team_games_before_by_team)
	_apply_postseason_setup_overrides(home_setup, home_id, team_games_before_by_team)
	var snapshots: Dictionary = _snapshot_setup_records(away_setup, home_setup)
	var result: Dictionary = PSGameLoop.simulate_game(away_setup, home_setup)
	if postseason_stats.is_empty():
		postseason_stats.merge(_empty_postseason_stats(), true)
	_apply_postseason_pitching_decisions(season, result, away_id, home_id, away_setup, home_setup)
	_collect_postseason_stat_deltas(snapshots, postseason_stats)
	if game_day > 0:
		PSRotationPlanner.record_rotation_start(season, away_id, away_setup, game_day)
		PSRotationPlanner.record_rotation_start(season, home_id, home_setup, game_day)
	return result


static func _apply_postseason_setup_overrides(setup: Dictionary, team_id: int, team_games_before_by_team: Dictionary) -> void:
	var fallback: int = int(setup.get("team_games_played_before", 0))
	setup["team_games_played_before"] = _team_games_before(team_games_before_by_team, team_id, fallback)


static func _empty_postseason_stats() -> Dictionary:
	return {
		"version": POSTSEASON_STATS_VERSION,
		"players": {},
	}


static func _normalized_postseason_stats(data: Dictionary) -> Dictionary:
	var out: Dictionary = data.duplicate(true)
	out["version"] = int(out.get("version", POSTSEASON_STATS_VERSION))
	if not out.has("players") or typeof(out.get("players")) != TYPE_DICTIONARY:
		out["players"] = {}
	return out


static func _snapshot_setup_records(away_setup: Dictionary, home_setup: Dictionary) -> Dictionary:
	var records: Array = []
	_append_setup_records(records, away_setup)
	_append_setup_records(records, home_setup)
	var snapshots: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or snapshots.has(record.player_id):
			continue
		snapshots[record.player_id] = {
			"record": record,
			"batter_stats": record.batter_stats.to_dict(),
			"pitcher_stats": record.pitcher_stats.to_dict(),
			"advanced_stats": record.advanced_stats.to_dict() if record.advanced_stats != null else {},
		}
	return snapshots


static func _append_setup_records(records: Array, setup: Dictionary) -> void:
	for key in ["pitcher", "starter_pitcher"]:
		var pitcher: PSPlayerSeasonRecord = setup.get(key, null) as PSPlayerSeasonRecord
		if pitcher != null:
			records.append(pitcher)
	for key in ["batters", "bench", "relievers"]:
		for row in (setup.get(key, []) as Array):
			var record: PSPlayerSeasonRecord = row as PSPlayerSeasonRecord
			if record != null:
				records.append(record)
	for row in (setup.get("fielders", []) as Array):
		var assignment: Dictionary = row as Dictionary
		var fielder: PSPlayerSeasonRecord = assignment.get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			records.append(fielder)


static func _collect_postseason_stat_deltas(snapshots: Dictionary, postseason_stats: Dictionary) -> void:
	if not postseason_stats.has("players"):
		postseason_stats["players"] = {}
	for snapshot_value in snapshots.values():
		var snapshot: Dictionary = snapshot_value as Dictionary
		var record: PSPlayerSeasonRecord = snapshot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		var before_batter: PSBatterStats = PSBatterStats.from_dict(snapshot.get("batter_stats", {}) as Dictionary)
		var before_pitcher: PSPitcherStats = PSPitcherStats.from_dict(snapshot.get("pitcher_stats", {}) as Dictionary)
		var batter_delta: PSBatterStats = record.batter_stats.subtract_from(before_batter)
		var pitcher_delta: PSPitcherStats = record.pitcher_stats.subtract_from(before_pitcher)
		if _batter_stats_nonzero(batter_delta) or _pitcher_stats_nonzero(pitcher_delta):
			_merge_postseason_player_delta(postseason_stats, record, batter_delta, pitcher_delta)
		record.batter_stats = before_batter
		record.pitcher_stats = before_pitcher
		var advanced_payload: Dictionary = snapshot.get("advanced_stats", {}) as Dictionary
		var restored_advanced: PSAdvancedStats = PSAdvancedStats.new()
		restored_advanced.load_from_dict(advanced_payload)
		if restored_advanced.player_id == 0:
			restored_advanced.player_id = record.player_id
		record.advanced_stats = restored_advanced


static func _merge_postseason_player_delta(
	postseason_stats: Dictionary,
	record: PSPlayerSeasonRecord,
	batter_delta: PSBatterStats,
	pitcher_delta: PSPitcherStats
) -> void:
	var players: Dictionary = postseason_stats.get("players", {}) as Dictionary
	var key: String = str(record.player_id)
	var row: Dictionary = (players.get(key, {}) as Dictionary).duplicate(true)
	if row.is_empty():
		row = {
			"player_id": record.player_id,
			"name": record.name,
			"team_id": record.team_id,
			"position": record.position,
			"batter_stats": {},
			"pitcher_stats": {},
		}
	var batter_total: PSBatterStats = PSBatterStats.from_dict(row.get("batter_stats", {}) as Dictionary)
	var pitcher_total: PSPitcherStats = PSPitcherStats.from_dict(row.get("pitcher_stats", {}) as Dictionary)
	batter_total.add_from(batter_delta)
	pitcher_total.add_from(pitcher_delta)
	row["team_id"] = record.team_id
	row["batter_stats"] = batter_total.to_dict()
	row["pitcher_stats"] = pitcher_total.to_dict()
	players[key] = row
	postseason_stats["players"] = players


static func _apply_postseason_pitching_decisions(
	season: PSSeason,
	result: Dictionary,
	away_id: int,
	home_id: int,
	away_setup: Dictionary,
	home_setup: Dictionary
) -> void:
	if bool(result.get("draw", false)):
		return
	var away_starter: PSPlayerSeasonRecord = away_setup.get("starter_pitcher", away_setup.get("pitcher", null)) as PSPlayerSeasonRecord
	var home_starter: PSPlayerSeasonRecord = home_setup.get("starter_pitcher", home_setup.get("pitcher", null)) as PSPlayerSeasonRecord
	var away_starter_id: int = away_starter.player_id if away_starter != null else int(result.get("away_pitcher_id", 0))
	var home_starter_id: int = home_starter.player_id if home_starter != null else int(result.get("home_pitcher_id", 0))
	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(result, away_id, home_id, away_starter_id, home_starter_id)
	result["winning_pitcher_id"] = int(decisions.get("winning_pitcher_id", 0))
	result["losing_pitcher_id"] = int(decisions.get("losing_pitcher_id", 0))
	result["save_pitcher_id"] = int(decisions.get("save_pitcher_id", 0))
	result["hold_pitcher_ids"] = decisions.get("hold_pitcher_ids", []) as Array
	if result["winning_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["winning_pitcher_id"], "win")
	if result["losing_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["losing_pitcher_id"], "loss")
	if result["save_pitcher_id"] > 0:
		_apply_postseason_pitcher_decision(season, result["save_pitcher_id"], "save")
	for pid_value in (result.get("hold_pitcher_ids", []) as Array):
		var pid: int = int(pid_value)
		if pid > 0:
			_apply_postseason_pitcher_decision(season, pid, "hold")


static func _apply_postseason_pitcher_decision(season: PSSeason, player_id: int, kind: String) -> void:
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
	if record == null:
		return
	match kind:
		"win":
			record.pitcher_stats.wins += 1
		"loss":
			record.pitcher_stats.losses += 1
		"save":
			record.pitcher_stats.saves += 1
		"hold":
			record.pitcher_stats.holds += 1


static func _batter_stats_nonzero(stats: PSBatterStats) -> bool:
	for value in stats.to_dict().values():
		if int(value) != 0:
			return true
	return false


static func _pitcher_stats_nonzero(stats: PSPitcherStats) -> bool:
	for value in stats.to_dict().values():
		if int(value) != 0:
			return true
	return false
