extends RefCounted
class_name GameSimulator

const REGULATION_INNINGS: int = 9
const MAX_INNINGS: int = 12
const STARTER_EXTEND_START_INNING: int = 7   # 続投判定を始める回 (= 6回終了後)
const FIELDER_START_FATIGUE_GAIN: int = 6
const DH_START_FATIGUE_GAIN: int = 3
const PINCH_HITTER_FATIGUE_GAIN: int = 2
const DEFENSIVE_SUB_FATIGUE_GAIN: int = 3
const FATIGUE_MAX: int = 200
const DEFENSIVE_ASSIGNMENT_ORDER: Array[int] = [2, 6, 8, 4, 5, 3, 7, 9]
const PINCH_HIT_START_INNING: int = 7
const DEFENSIVE_REPLACEMENT_START_INNING: int = 8
const LOW_BATTER_SCORE: int = 44
const SOLID_BATTER_SCORE: int = 62
const IMPORTANT_PINCH_HIT_CHANCE_SCORE: int = 8
const PINCH_HIT_MIN_GAIN: int = 8
const PINCH_HIT_LATE_SCORE_MARGIN: int = 5
const PINCH_HIT_IMPORTANT_SCORE_MARGIN: int = 5
const DEFENSIVE_REPLACEMENT_MIN_GAIN: int = 34
const FINAL_DEFENSE_MAX_LEAD: int = 5
const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher",
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}


# プレビュー系 (UI から呼ばれる) は PSTeamSetupBuilder へ委譲。
static func preview_lineup(season: PSSeason, team_id: int, dh_enabled: bool) -> Dictionary:
	return PSTeamSetupBuilder.preview_lineup(season, team_id, dh_enabled)


static func preview_rotation(season: PSSeason, team_id: int) -> Dictionary:
	return PSTeamSetupBuilder.preview_rotation(season, team_id)


static func resolve_rotation_order(season: PSSeason, team_id: int) -> Array:
	return PSTeamSetupBuilder.resolve_rotation_order(season, team_id)


static func preview_active_roster(season: PSSeason, team_id: int) -> Dictionary:
	return PSTeamSetupBuilder.preview_active_roster(season, team_id)


static func summarize_active_roster_ids(player_ids: Array, records: Array) -> Dictionary:
	return PSTeamSetupBuilder.summarize_active_roster_ids(player_ids, records)


static func simulate_next_unplayed_game(season: PSSeason, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	var game_index: int = _next_unplayed_game_index(season)
	if game_index < 0:
		return {"ok": false, "message": "未消化の試合がありません"}
	var prev_day: int = season.current_day
	var result: Dictionary = simulate_game_at_index(season, game_index, persist)
	if bool(result.get("ok", false)) and not auto_swap_ctx.is_empty() and season.current_day != prev_day:
		_run_periodic_roster_swap_hook(season, prev_day, auto_swap_ctx)
	return result


static func simulate_current_day(season: PSSeason, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	var day: int = season.current_day
	var results: Array = []
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != day:
			continue
		var game_result: Dictionary = simulate_game_at_index(season, index, false)
		if not bool(game_result.get("ok", false)):
			if not results.is_empty() and persist:
				PSGameDecisions.persist_records()
			return game_result
		results.append(game_result)

	if results.is_empty():
		return simulate_next_unplayed_game(season, persist, auto_swap_ctx)

	if not auto_swap_ctx.is_empty():
		_run_periodic_roster_swap_hook(season, day, auto_swap_ctx)

	if persist:
		PSGameDecisions.persist_records()
	var last_result: Dictionary = results[results.size() - 1] as Dictionary
	return {
		"ok": true,
		"results": results,
		"message": "%d日目の%d試合を消化しました。%s" % [day, results.size(), str(last_result.get("message", ""))],
	}


static func simulate_days(season: PSSeason, days: int, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	if days <= 0:
		return {"ok": false, "message": "日数は1以上を指定してください"}
	var start_day: int = season.current_day
	var target_day: int = start_day + days
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		if season.current_day >= target_day:
			break
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = simulate_current_day(season, false, auto_swap_ctx)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				PSGameDecisions.persist_records()
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		PSGameDecisions.persist_records()
	if simulated_games == 0:
		return {"ok": false, "message": "進行できる試合がありません"}
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"message": "%d日分、%d試合を消化しました。Day %d から Day %d。%s" % [
			min(days, season.current_day - start_day),
			simulated_games,
			start_day,
			season.current_day,
			str(last_result.get("message", "")),
		],
	}


static func simulate_until_team_game(season: PSSeason, team_id: int, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	if team_id <= 0:
		return {"ok": false, "message": "チームが指定されていません"}
	var start_day: int = season.current_day
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		if _team_has_unplayed_game_today(season, team_id):
			break
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = simulate_current_day(season, false, auto_swap_ctx)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				PSGameDecisions.persist_records()
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		PSGameDecisions.persist_records()
	if simulated_games == 0:
		return {"ok": false, "message": "次の自軍試合は本日です。または未消化試合がありません"}
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"message": "自軍試合日(Day %d)まで進めました。Day %d から Day %d、%d試合消化。%s" % [
			season.current_day,
			start_day,
			season.current_day,
			simulated_games,
			str(last_result.get("message", "")),
		],
	}


# 各試合日終了後に呼ばれる自動入替フック。
# ctx = { "user_team_id": int, "include_user_team": bool }
static func _run_periodic_roster_swap_hook(season: PSSeason, day: int, ctx: Dictionary) -> void:
	var user_team_id: int = int(ctx.get("user_team_id", 0))
	var include_user: bool = bool(ctx.get("include_user_team", false))
	TeamAutoAI.run_periodic_roster_swaps(season, GameDb.teams, day, user_team_id, include_user)


static func _team_has_unplayed_game_today(season: PSSeason, team_id: int) -> bool:
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != season.current_day:
			continue
		if int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id:
			return true
	return false


static func simulate_remaining_season(season: PSSeason, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	var simulated_count: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		var game_index: int = _next_unplayed_game_index(season)
		if game_index < 0:
			break
		var pre_day: int = season.current_day
		var game_result: Dictionary = simulate_game_at_index(season, game_index, false)
		if not bool(game_result.get("ok", false)):
			if simulated_count > 0 and persist:
				PSGameDecisions.persist_records()
			return game_result
		last_result = game_result
		simulated_count += 1
		if not auto_swap_ctx.is_empty() and season.current_day != pre_day:
			_run_periodic_roster_swap_hook(season, pre_day, auto_swap_ctx)

	if persist:
		PSGameDecisions.persist_records()
	if simulated_count == 0:
		return {"ok": false, "message": "未消化の試合がありません"}
	return {
		"ok": true,
		"results": [],
		"simulated_count": simulated_count,
		"message": "残り%d試合をすべて消化しました。%s" % [simulated_count, str(last_result.get("message", ""))],
	}


# --- async 版 (UI フリーズ対策) ---

static func _count_unplayed_games(season: PSSeason) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("played", false)):
			count += 1
	return count


static func _is_cancelled(cancel_token: Dictionary) -> bool:
	return not cancel_token.is_empty() and bool(cancel_token.get("cancelled", false))


static func simulate_current_day_async(
	season: PSSeason,
	persist: bool,
	auto_swap_ctx: Dictionary,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary,
	progress_baseline: int = 0,
	progress_total: int = 0
) -> Dictionary:
	var day: int = season.current_day
	var results: Array = []
	for index in range(season.schedule.size()):
		if _is_cancelled(cancel_token):
			break
		var game: Dictionary = season.schedule[index] as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != day:
			continue
		var game_result: Dictionary = simulate_game_at_index(season, index, false)
		if not bool(game_result.get("ok", false)):
			if not results.is_empty() and persist:
				PSGameDecisions.persist_records()
			return game_result
		results.append(game_result)
		if progress_cb.is_valid():
			progress_cb.call(progress_baseline + results.size(), progress_total, "Day %d" % day)
		if tree != null:
			await tree.process_frame

	if results.is_empty():
		return simulate_next_unplayed_game(season, persist, auto_swap_ctx)

	if not auto_swap_ctx.is_empty():
		_run_periodic_roster_swap_hook(season, day, auto_swap_ctx)

	if persist:
		PSGameDecisions.persist_records()
	var last_result: Dictionary = results[results.size() - 1] as Dictionary
	return {
		"ok": true,
		"results": results,
		"cancelled": _is_cancelled(cancel_token),
		"message": "%d日目の%d試合を消化しました。%s" % [day, results.size(), str(last_result.get("message", ""))],
	}


static func simulate_remaining_season_async(
	season: PSSeason,
	persist: bool,
	auto_swap_ctx: Dictionary,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary
) -> Dictionary:
	var simulated_count: int = 0
	var total_games: int = _count_unplayed_games(season)
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		if _is_cancelled(cancel_token):
			break
		var game_index: int = _next_unplayed_game_index(season)
		if game_index < 0:
			break
		var pre_day: int = season.current_day
		var game_result: Dictionary = simulate_game_at_index(season, game_index, false)
		if not bool(game_result.get("ok", false)):
			if simulated_count > 0 and persist:
				PSGameDecisions.persist_records()
			return game_result
		last_result = game_result
		simulated_count += 1
		if not auto_swap_ctx.is_empty() and season.current_day != pre_day:
			_run_periodic_roster_swap_hook(season, pre_day, auto_swap_ctx)
		if progress_cb.is_valid():
			progress_cb.call(simulated_count, total_games, "残り全試合")
		if tree != null:
			await tree.process_frame

	if persist:
		PSGameDecisions.persist_records()
	var cancelled: bool = _is_cancelled(cancel_token)
	if simulated_count == 0:
		return {"ok": false, "cancelled": cancelled, "message": "未消化の試合がありません"}
	var message: String
	if cancelled:
		message = "%d試合まで進めてキャンセルされました。%s" % [simulated_count, str(last_result.get("message", ""))]
	else:
		message = "残り%d試合をすべて消化しました。%s" % [simulated_count, str(last_result.get("message", ""))]
	return {
		"ok": true,
		"results": [],
		"simulated_count": simulated_count,
		"cancelled": cancelled,
		"message": message,
	}


static func simulate_days_async(
	season: PSSeason,
	days: int,
	persist: bool,
	auto_swap_ctx: Dictionary,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary
) -> Dictionary:
	if days <= 0:
		return {"ok": false, "message": "日数は1以上を指定してください"}
	var start_day: int = season.current_day
	var target_day: int = start_day + days
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	var total_games: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		var d: int = int(game.get("day", 0))
		if d >= start_day and d < target_day:
			total_games += 1
	while guard > 0:
		guard -= 1
		if _is_cancelled(cancel_token):
			break
		if season.current_day >= target_day:
			break
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = await simulate_current_day_async(
			season, false, auto_swap_ctx, tree, progress_cb, cancel_token,
			simulated_games, total_games
		)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				PSGameDecisions.persist_records()
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		PSGameDecisions.persist_records()
	var cancelled: bool = _is_cancelled(cancel_token)
	if simulated_games == 0:
		return {"ok": false, "cancelled": cancelled, "message": "進行できる試合がありません"}
	var elapsed_days: int = min(days, season.current_day - start_day)
	var prefix: String = "%d日分、%d試合を消化しました" % [elapsed_days, simulated_games]
	if cancelled:
		prefix = "%d試合まで進めてキャンセルされました" % simulated_games
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"cancelled": cancelled,
		"message": "%s。Day %d から Day %d。%s" % [
			prefix, start_day, season.current_day, str(last_result.get("message", ""))
		],
	}


static func simulate_until_team_game_async(
	season: PSSeason,
	team_id: int,
	persist: bool,
	auto_swap_ctx: Dictionary,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary
) -> Dictionary:
	if team_id <= 0:
		return {"ok": false, "message": "チームが指定されていません"}
	var start_day: int = season.current_day
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	var total_games: int = _count_unplayed_games(season)
	while guard > 0:
		guard -= 1
		if _is_cancelled(cancel_token):
			break
		if _team_has_unplayed_game_today(season, team_id):
			break
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = await simulate_current_day_async(
			season, false, auto_swap_ctx, tree, progress_cb, cancel_token,
			simulated_games, total_games
		)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				PSGameDecisions.persist_records()
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		PSGameDecisions.persist_records()
	var cancelled: bool = _is_cancelled(cancel_token)
	if simulated_games == 0:
		return {"ok": false, "cancelled": cancelled, "message": "次の自軍試合は本日です。または未消化試合がありません"}
	var prefix: String = "自軍試合日(Day %d)まで進めました" % season.current_day
	if cancelled:
		prefix = "Day %d でキャンセルされました" % season.current_day
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"cancelled": cancelled,
		"message": "%s。Day %d から Day %d、%d試合消化。%s" % [
			prefix, start_day, season.current_day, simulated_games, str(last_result.get("message", ""))
		],
	}


static func simulate_game_at_index(season: PSSeason, game_index: int, persist: bool = true) -> Dictionary:
	if game_index < 0 or game_index >= season.schedule.size():
		return {"ok": false, "message": "試合番号が不正です"}

	var game: Dictionary = season.schedule[game_index] as Dictionary
	if bool(game.get("played", false)):
		return {"ok": false, "message": "この試合は消化済みです"}

	var away_team_id: int = int(game.get("away_team_id", 0))
	var home_team_id: int = int(game.get("home_team_id", 0))
	var dh_enabled: bool = bool(game.get("dh_enabled", false))
	var away_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, away_team_id, dh_enabled)
	var home_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, home_team_id, dh_enabled)
	if not bool(away_setup.get("ok", false)):
		return away_setup
	if not bool(home_setup.get("ok", false)):
		return home_setup

	var result: Dictionary = PSGameLoop.simulate_game(away_setup, home_setup)
	game["away_score"] = int(result.get("away_score", 0))
	game["home_score"] = int(result.get("home_score", 0))
	game["played"] = true
	game["innings"] = result.get("innings", [])
	game["result"] = result
	season.schedule[game_index] = game

	PSGameDecisions.apply_game_decisions(season, away_team_id, home_team_id, result)
	var game_day: int = int(game.get("day", season.current_day))
	PSRotationPlanner.record_rotation_start(season, away_team_id, away_setup, game_day)
	PSRotationPlanner.record_rotation_start(season, home_team_id, home_setup, game_day)
	PSGameDecisions.advance_current_day(season)
	if persist:
		PSGameDecisions.persist_records()

	var summary: String = _result_summary(away_team_id, home_team_id, result)
	return {
		"ok": true,
		"game": game,
		"result": result,
		"message": summary,
	}


static func _next_unplayed_game_index(season: PSSeason) -> int:
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			return index
	return -1


static func _result_summary(away_team_id: int, home_team_id: int, result: Dictionary) -> String:
	var away_name: String = _team_name(away_team_id)
	var home_name: String = _team_name(home_team_id)
	return "%s %d - %d %s" % [away_name, int(result.get("away_score", 0)), int(result.get("home_score", 0)), home_name]


static func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "Team %d" % team_id
	return team.short_name
