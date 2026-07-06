extends RefCounted
class_name GameSimulator

const GameLogService = preload("res://services/storage/game_log_service.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

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

static var _profile_enabled: bool = false
static var _profile_totals_usec: Dictionary = {}


static func reset_profile(enabled: bool = true) -> void:
	_profile_enabled = enabled
	_profile_totals_usec = {}


static func profile_totals_msec() -> Dictionary:
	var out: Dictionary = {}
	for key_value in _profile_totals_usec.keys():
		out[str(key_value)] = float(_profile_totals_usec[key_value]) / 1000.0
	return out


static func _profile_add(label: String, elapsed_usec: int) -> void:
	if not _profile_enabled:
		return
	_profile_totals_usec[label] = int(_profile_totals_usec.get(label, 0)) + elapsed_usec


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
				_persist_simulation_outputs(season)
			return game_result
		results.append(game_result)

	if results.is_empty():
		return simulate_next_unplayed_game(season, persist, auto_swap_ctx)

	if not auto_swap_ctx.is_empty():
		_run_periodic_roster_swap_hook(season, day, auto_swap_ctx)

	if persist:
		_persist_simulation_outputs(season)
	var last_result: Dictionary = results[results.size() - 1] as Dictionary
	return {
		"ok": true,
		"results": results,
		"message": "%s の%d試合を消化しました。%s" % [
			SeasonCalendar.day_status_label(season, day), results.size(), str(last_result.get("message", ""))
		],
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
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
	if simulated_games == 0:
		return {"ok": false, "message": "進行できる試合がありません"}
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"message": "%d日分、%d試合を消化しました。%s から %s。%s" % [
			min(days, season.current_day - start_day),
			simulated_games,
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
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
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
	if simulated_games == 0:
		return {"ok": false, "message": "次の自軍試合は本日です。または未消化試合がありません"}
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"message": "自軍試合日(%s)まで進めました。%s から %s、%d試合消化。%s" % [
			SeasonCalendar.day_status_label(season, season.current_day),
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
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
	# シーズン中トレード (交換期限まで週次・低頻度)。成立時は players の team_id が動くので
	# インデックスを再構築する。自軍もCPU自動管理のとき (オートプレイ/自動入替ON) は
	# 自軍宛て提案を作らず、自軍もCPU間マッチングに参加させる。
	var trade_user_id: int = 0 if include_user else user_team_id
	var trade_result: Dictionary = TradeService.run_periodic_trade_check(season, GameDb.players, GameDb.teams, day, trade_user_id)
	if not (trade_result.get("executed", []) as Array).is_empty():
		GameDb.rebuild_player_indices()


static func _persist_simulation_outputs(season: PSSeason) -> void:
	GameLogService.write_pending_game_logs(season)
	PSGameDecisions.persist_records()


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
				_persist_simulation_outputs(season)
			return game_result
		last_result = game_result
		simulated_count += 1
		if not auto_swap_ctx.is_empty() and season.current_day != pre_day:
			_run_periodic_roster_swap_hook(season, pre_day, auto_swap_ctx)

	if persist:
		_persist_simulation_outputs(season)
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
				_persist_simulation_outputs(season)
			return game_result
		results.append(game_result)
		if progress_cb.is_valid():
			progress_cb.call(progress_baseline + results.size(), progress_total, SeasonCalendar.day_status_label(season, day))
		if tree != null:
			await tree.process_frame

	if results.is_empty():
		return simulate_next_unplayed_game(season, persist, auto_swap_ctx)

	if not auto_swap_ctx.is_empty():
		_run_periodic_roster_swap_hook(season, day, auto_swap_ctx)

	if persist:
		_persist_simulation_outputs(season)
	var last_result: Dictionary = results[results.size() - 1] as Dictionary
	return {
		"ok": true,
		"results": results,
		"cancelled": _is_cancelled(cancel_token),
		"message": "%s の%d試合を消化しました。%s" % [
			SeasonCalendar.day_status_label(season, day), results.size(), str(last_result.get("message", ""))
		],
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
				_persist_simulation_outputs(season)
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
		_persist_simulation_outputs(season)
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
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
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
		"message": "%s。%s から %s。%s" % [
			prefix,
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
			str(last_result.get("message", ""))
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
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
	var cancelled: bool = _is_cancelled(cancel_token)
	if simulated_games == 0:
		return {"ok": false, "cancelled": cancelled, "message": "次の自軍試合は本日です。または未消化試合がありません"}
	var prefix: String = "自軍試合日(%s)まで進めました" % SeasonCalendar.day_status_label(season, season.current_day)
	if cancelled:
		prefix = "%s でキャンセルされました" % SeasonCalendar.day_status_label(season, season.current_day)
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"cancelled": cancelled,
		"message": "%s。%s から %s、%d試合消化。%s" % [
			prefix,
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
			simulated_games,
			str(last_result.get("message", ""))
		],
	}


# end_day (season day, inclusive) 以前の未消化試合をすべて消化する。
# 翌月送りなど「特定日まで」の消化に使う。day はカレンダー日offsetと1:1なので境界判定に使える。
static func simulate_until_day(season: PSSeason, end_day: int, persist: bool = true, auto_swap_ctx: Dictionary = {}) -> Dictionary:
	var start_day: int = season.current_day
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		var idx: int = _next_unplayed_game_index(season)
		if idx < 0:
			break
		if int((season.schedule[idx] as Dictionary).get("day", 0)) > end_day:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = simulate_current_day(season, false, auto_swap_ctx)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
	if simulated_games == 0:
		return {"ok": false, "message": "消化できる試合がありません"}
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"message": "%d試合を消化しました。%s から %s。%s" % [
			simulated_games,
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
			str(last_result.get("message", "")),
		],
	}


static func simulate_until_day_async(
	season: PSSeason,
	end_day: int,
	persist: bool,
	auto_swap_ctx: Dictionary,
	tree: SceneTree,
	progress_cb: Callable,
	cancel_token: Dictionary
) -> Dictionary:
	var start_day: int = season.current_day
	var simulated_games: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	var total_games: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			continue
		var d: int = int(game.get("day", 0))
		if d >= start_day and d <= end_day:
			total_games += 1
	while guard > 0:
		guard -= 1
		if _is_cancelled(cancel_token):
			break
		var idx: int = _next_unplayed_game_index(season)
		if idx < 0:
			break
		if int((season.schedule[idx] as Dictionary).get("day", 0)) > end_day:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = await simulate_current_day_async(
			season, false, auto_swap_ctx, tree, progress_cb, cancel_token,
			simulated_games, total_games
		)
		if not bool(day_result.get("ok", false)):
			if simulated_games > 0 and persist:
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		simulated_games += (day_result.get("results", []) as Array).size()
		if season.current_day == prev_day:
			break
	if persist:
		_persist_simulation_outputs(season)
	var cancelled: bool = _is_cancelled(cancel_token)
	if simulated_games == 0:
		return {"ok": false, "cancelled": cancelled, "message": "消化できる試合がありません"}
	var prefix: String = "%d試合を消化しました" % simulated_games
	if cancelled:
		prefix = "%d試合まで進めてキャンセルされました" % simulated_games
	return {
		"ok": true,
		"simulated_count": simulated_games,
		"cancelled": cancelled,
		"message": "%s。%s から %s。%s" % [
			prefix,
			SeasonCalendar.day_status_label(season, start_day),
			SeasonCalendar.day_status_label(season, season.current_day),
			str(last_result.get("message", "")),
		],
	}


static func simulate_game_at_index(season: PSSeason, game_index: int, persist: bool = true) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if _profile_enabled else 0
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
	if _profile_enabled:
		var now_setup: int = Time.get_ticks_usec()
		_profile_add("setup", now_setup - profile_start)
		profile_start = now_setup
	var pre_player_stats: Dictionary = _snapshot_game_player_stats(season, away_setup, home_setup)
	if _profile_enabled:
		var now_snapshot: int = Time.get_ticks_usec()
		_profile_add("snapshot", now_snapshot - profile_start)
		profile_start = now_snapshot

	var result: Dictionary = PSGameLoop.simulate_game(away_setup, home_setup)
	if _profile_enabled:
		var now_loop: int = Time.get_ticks_usec()
		_profile_add("loop", now_loop - profile_start)
		profile_start = now_loop
	game["away_score"] = int(result.get("away_score", 0))
	game["home_score"] = int(result.get("home_score", 0))
	game["played"] = true
	game["innings"] = result.get("innings", [])
	game["result"] = result
	season.schedule[game_index] = game

	PSGameDecisions.apply_game_decisions(season, away_team_id, home_team_id, result)
	if _profile_enabled:
		var now_decisions: int = Time.get_ticks_usec()
		_profile_add("decisions", now_decisions - profile_start)
		profile_start = now_decisions
	_record_player_game_logs(season, game_index, game, result, pre_player_stats)
	if _profile_enabled:
		var now_logs: int = Time.get_ticks_usec()
		_profile_add("game_logs", now_logs - profile_start)
		profile_start = now_logs
	var injury_repair_team_ids: Dictionary = _injury_repair_team_ids(result, away_team_id, home_team_id)
	for repair_team_id in injury_repair_team_ids.keys():
		TeamAutoAI.repair_active_roster_injuries(season, int(repair_team_id), season.current_day)
	if _profile_enabled:
		var now_roster_repair: int = Time.get_ticks_usec()
		_profile_add("roster_repair", now_roster_repair - profile_start)
		profile_start = now_roster_repair
	var game_day: int = int(game.get("day", season.current_day))
	PSRotationPlanner.record_rotation_start(season, away_team_id, away_setup, game_day)
	PSRotationPlanner.record_rotation_start(season, home_team_id, home_setup, game_day)
	PSGameDecisions.advance_current_day(season)
	if _profile_enabled:
		var now_after_day: int = Time.get_ticks_usec()
		_profile_add("after_day", now_after_day - profile_start)
		profile_start = now_after_day
	if persist:
		_persist_simulation_outputs(season)
	if _profile_enabled:
		var now_persist: int = Time.get_ticks_usec()
		_profile_add("persist", now_persist - profile_start)

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


static func _injury_repair_team_ids(result: Dictionary, away_team_id: int, home_team_id: int) -> Dictionary:
	var out: Dictionary = {}
	var events: Array = result.get("injury_events", []) as Array
	for event_value in events:
		var event: Dictionary = event_value as Dictionary
		var team_id: int = int(event.get("team_id", 0))
		if team_id == away_team_id or team_id == home_team_id:
			out[team_id] = true
	return out


static func _result_summary(away_team_id: int, home_team_id: int, result: Dictionary) -> String:
	var away_name: String = _team_name(away_team_id)
	var home_name: String = _team_name(home_team_id)
	return "%s %d - %d %s" % [away_name, int(result.get("away_score", 0)), int(result.get("home_score", 0)), home_name]


static func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "Team %d" % team_id
	return team.short_name


static func _snapshot_game_player_stats(season: PSSeason, away_setup: Dictionary, home_setup: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if season == null:
		return out
	_snapshot_setup_player_stats(out, away_setup)
	_snapshot_setup_player_stats(out, home_setup)
	return out


static func _snapshot_setup_player_stats(out: Dictionary, setup: Dictionary) -> void:
	if setup.is_empty():
		return
	var team_id: int = int(setup.get("team_id", 0))
	_snapshot_player_record_stats(out, setup.get("pitcher", null) as PSPlayerSeasonRecord, team_id)
	_snapshot_player_record_stats(out, setup.get("starter_pitcher", null) as PSPlayerSeasonRecord, team_id)
	for key in ["batters", "bench", "relievers"]:
		for record_value in (setup.get(key, []) as Array):
			_snapshot_player_record_stats(out, record_value as PSPlayerSeasonRecord, team_id)
	for assignment_value in (setup.get("fielders", []) as Array):
		var assignment: Dictionary = assignment_value as Dictionary
		_snapshot_player_record_stats(out, assignment.get("record", null) as PSPlayerSeasonRecord, team_id)


static func _snapshot_player_record_stats(out: Dictionary, record: PSPlayerSeasonRecord, team_id: int) -> void:
	if record == null or record.player_id <= 0:
		return
	var key: String = str(record.player_id)
	if out.has(key):
		return
	out[key] = {
		"team_id": team_id,
		"batter": _clone_batter_stats(record.batter_stats),
		"pitcher": _clone_pitcher_stats(record.pitcher_stats),
	}


static func _clone_batter_stats(stats: PSBatterStats) -> PSBatterStats:
	var copy: PSBatterStats = PSBatterStats.new()
	if stats == null:
		return copy
	copy.games = stats.games
	copy.plate_appearances = stats.plate_appearances
	copy.at_bats = stats.at_bats
	copy.hits = stats.hits
	copy.doubles = stats.doubles
	copy.triples = stats.triples
	copy.home_runs = stats.home_runs
	copy.runs_batted_in = stats.runs_batted_in
	copy.runs = stats.runs
	copy.walks = stats.walks
	copy.hit_by_pitches = stats.hit_by_pitches
	copy.strikeouts = stats.strikeouts
	copy.pitches_seen = stats.pitches_seen
	copy.stolen_base_attempts = stats.stolen_base_attempts
	copy.stolen_bases = stats.stolen_bases
	copy.sacrifices = stats.sacrifices
	copy.sacrifice_flies = stats.sacrifice_flies
	copy.double_plays = stats.double_plays
	copy.errors = stats.errors
	return copy


static func _clone_pitcher_stats(stats: PSPitcherStats) -> PSPitcherStats:
	var copy: PSPitcherStats = PSPitcherStats.new()
	if stats == null:
		return copy
	copy.games = stats.games
	copy.starts = stats.starts
	copy.relief_appearances = stats.relief_appearances
	copy.wins = stats.wins
	copy.losses = stats.losses
	copy.holds = stats.holds
	copy.saves = stats.saves
	copy.outs_pitched = stats.outs_pitched
	copy.batters_faced = stats.batters_faced
	copy.pitches_thrown = stats.pitches_thrown
	copy.hits_allowed = stats.hits_allowed
	copy.home_runs_allowed = stats.home_runs_allowed
	copy.walks = stats.walks
	copy.hit_batters = stats.hit_batters
	copy.strikeouts = stats.strikeouts
	copy.runs_allowed = stats.runs_allowed
	copy.earned_runs = stats.earned_runs
	copy.complete_games = stats.complete_games
	copy.shutouts = stats.shutouts
	copy.quality_starts = stats.quality_starts
	return copy


static func _record_player_game_logs(season: PSSeason, game_index: int, game: Dictionary, result: Dictionary, pre_player_stats: Dictionary) -> void:
	if season == null or pre_player_stats.is_empty():
		return
	var away_team_id: int = int(game.get("away_team_id", result.get("away_team_id", 0)))
	var home_team_id: int = int(game.get("home_team_id", result.get("home_team_id", 0)))
	var away_score: int = int(result.get("away_score", game.get("away_score", 0)))
	var home_score: int = int(result.get("home_score", game.get("home_score", 0)))
	for id_value in _player_game_log_candidate_ids(result, pre_player_stats):
		var player_id: int = int(id_value)
		if player_id <= 0:
			continue
		var key_value: String = str(player_id)
		if not pre_player_stats.has(key_value):
			continue
		var before: Dictionary = pre_player_stats[key_value] as Dictionary
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
		if record == null:
			continue
		var before_batter: PSBatterStats = before.get("batter", null) as PSBatterStats
		var before_pitcher: PSPitcherStats = before.get("pitcher", null) as PSPitcherStats
		if before_batter == null:
			before_batter = PSBatterStats.new()
		if before_pitcher == null:
			before_pitcher = PSPitcherStats.new()
		var batter_delta: PSBatterStats = record.batter_stats.subtract_from(before_batter)
		var pitcher_delta: PSPitcherStats = record.pitcher_stats.subtract_from(before_pitcher)
		var batter_dict: Dictionary = batter_delta.to_dict()
		var pitcher_dict: Dictionary = pitcher_delta.to_dict()
		if not _stats_dict_has_any(batter_dict) and not _stats_dict_has_any(pitcher_dict):
			continue
		var team_id: int = int(before.get("team_id", record.team_id))
		var opponent_id: int = home_team_id if team_id == away_team_id else away_team_id
		var score_for: int = away_score if team_id == away_team_id else home_score
		var score_against: int = home_score if team_id == away_team_id else away_score
		season.append_player_game_log(player_id, {
			"game_index": game_index,
			"day": int(game.get("day", season.current_day)),
			"date": str(game.get("date", "")),
			"team_id": team_id,
			"opponent_id": opponent_id,
			"home_away": "away" if team_id == away_team_id else "home",
			"appearance": _player_appearance_label(result, player_id, team_id, batter_delta, pitcher_delta),
			"result": _team_result_label(score_for, score_against),
			"score_for": score_for,
			"score_against": score_against,
			"batter": batter_dict,
			"pitcher": pitcher_dict,
		})


static func _player_game_log_candidate_ids(result: Dictionary, pre_player_stats: Dictionary) -> Array:
	var ids: Dictionary = {}
	_collect_lineup_player_ids(ids, result)
	_collect_substitution_player_ids(ids, result)
	_collect_pitcher_outing_ids(ids, result)
	_collect_advanced_stat_player_ids(ids, result)
	_add_player_id(ids, int(result.get("winning_pitcher_id", 0)))
	_add_player_id(ids, int(result.get("losing_pitcher_id", 0)))
	_add_player_id(ids, int(result.get("save_pitcher_id", 0)))
	for pid_value in (result.get("hold_pitcher_ids", []) as Array):
		_add_player_id(ids, int(pid_value))
	if ids.is_empty():
		var fallback: Array = []
		for key_value in pre_player_stats.keys():
			fallback.append(int(str(key_value)))
		return fallback
	return ids.keys()


static func _collect_lineup_player_ids(ids: Dictionary, result: Dictionary) -> void:
	var lineups: Dictionary = result.get("lineups", {}) as Dictionary
	for key in ["away", "home"]:
		var lineup: Dictionary = lineups.get(key, {}) as Dictionary
		for slot_value in (lineup.get("slots", []) as Array):
			var slot: Dictionary = slot_value as Dictionary
			_add_player_id(ids, int(slot.get("player_id", 0)))


static func _collect_substitution_player_ids(ids: Dictionary, result: Dictionary) -> void:
	for sub_value in (result.get("substitutions", []) as Array):
		var sub: Dictionary = sub_value as Dictionary
		_add_player_id(ids, int(sub.get("in_id", 0)))
		_add_player_id(ids, int(sub.get("out_id", 0)))


static func _collect_pitcher_outing_ids(ids: Dictionary, result: Dictionary) -> void:
	_add_player_id(ids, int(result.get("away_pitcher_id", 0)))
	_add_player_id(ids, int(result.get("home_pitcher_id", 0)))
	for outing_value in (result.get("pitcher_outings", []) as Array):
		var outing: Dictionary = outing_value as Dictionary
		_add_player_id(ids, int(outing.get("pitcher_id", 0)))


static func _collect_advanced_stat_player_ids(ids: Dictionary, result: Dictionary) -> void:
	var advanced_stats: Dictionary = result.get("advanced_stats", {}) as Dictionary
	for bucket_name in ["players", "pitchers"]:
		var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		for key_value in bucket.keys():
			var entry: Dictionary = bucket.get(key_value, {}) as Dictionary
			var player_id: int = int(entry.get("player_id", 0))
			var key: String = str(key_value)
			if player_id <= 0 and key.is_valid_int():
				player_id = int(key)
			_add_player_id(ids, player_id)


static func _add_player_id(ids: Dictionary, player_id: int) -> void:
	if player_id > 0:
		ids[player_id] = true


static func _stats_dict_has_any(stats: Dictionary) -> bool:
	for value in stats.values():
		if int(value) != 0:
			return true
	return false


static func _team_result_label(score_for: int, score_against: int) -> String:
	if score_for > score_against:
		return "勝"
	if score_for < score_against:
		return "敗"
	return "分"


static func _player_appearance_label(result: Dictionary, player_id: int, team_id: int, batter_stats: PSBatterStats, pitcher_stats: PSPitcherStats) -> String:
	if pitcher_stats.starts > 0:
		return "先発"
	if pitcher_stats.relief_appearances > 0:
		return "救援"
	var started: bool = _player_started_for_team(result, player_id, team_id)
	var sub_kinds: Dictionary = _substitution_kinds_for_player(result, player_id, team_id)
	if started:
		return "スタメン"
	var pinch_hit: bool = bool(sub_kinds.get("pinch_hit", false))
	var defense: bool = bool(sub_kinds.get("defense", false))
	if pinch_hit and defense:
		return "代打→守備"
	if pinch_hit:
		return "代打"
	if defense:
		return "守備"
	if batter_stats.plate_appearances > 0 or batter_stats.games > 0:
		return "途中"
	return "-"


static func _player_started_for_team(result: Dictionary, player_id: int, team_id: int) -> bool:
	var lineups: Dictionary = result.get("lineups", {}) as Dictionary
	for key in ["away", "home"]:
		var lineup: Dictionary = lineups.get(key, {}) as Dictionary
		if int(lineup.get("team_id", 0)) != team_id:
			continue
		for slot_value in (lineup.get("slots", []) as Array):
			var slot: Dictionary = slot_value as Dictionary
			if int(slot.get("player_id", 0)) == player_id:
				return true
	return false


static func _substitution_kinds_for_player(result: Dictionary, player_id: int, team_id: int) -> Dictionary:
	var kinds: Dictionary = {}
	for sub_value in (result.get("substitutions", []) as Array):
		var sub: Dictionary = sub_value as Dictionary
		if int(sub.get("team_id", 0)) == team_id and int(sub.get("in_id", 0)) == player_id:
			kinds[str(sub.get("kind", ""))] = true
	return kinds
