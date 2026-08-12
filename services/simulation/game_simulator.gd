extends RefCounted
class_name GameSimulator

const GameLogService = preload("res://services/storage/game_log_service.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const REGULATION_INNINGS: int = 9
const MAX_INNINGS: int = 12
const FIELDER_START_FATIGUE_GAIN: int = 6
const DH_START_FATIGUE_GAIN: int = 3
const PINCH_HITTER_FATIGUE_GAIN: int = 2
const DEFENSIVE_SUB_FATIGUE_GAIN: int = 3
const FATIGUE_MAX: int = 200
const DEFENSIVE_ASSIGNMENT_ORDER: Array[int] = [2, 6, 8, 4, 5, 3, 7, 9]
const PINCH_HIT_START_INNING: int = 7
const DEFENSIVE_REPLACEMENT_START_INNING: int = 8
# 代打/守備固めの打力ライン。**母集団相対** — その年の支配下野手の打撃スコア分布から
# mean + sigma*spread を引く (絶対値だとリーグ水準が動いただけで代打の出方が変わる)。
# 実測 (1シーズン): 打撃スコア mean 71.95 / spread 12.21 で、旧・絶対値 44 は -2.29σ、
# 62 は -0.82σ に相当した。絶対値は母集団が取れないときのフォールバックとして残す。
const LOW_BATTER_SIGMA: float = -2.29
const SOLID_BATTER_SIGMA: float = -0.82
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
static var _profile_mutex: Mutex = Mutex.new()


static func reset_profile(enabled: bool = true) -> void:
	_profile_enabled = enabled
	_profile_mutex.lock()
	_profile_totals_usec = {}
	_profile_mutex.unlock()


static func profile_totals_msec() -> Dictionary:
	_profile_mutex.lock()
	var snapshot: Dictionary = _profile_totals_usec.duplicate()
	_profile_mutex.unlock()
	var out: Dictionary = {}
	for key_value in snapshot.keys():
		out[str(key_value)] = float(snapshot[key_value]) / 1000.0
	return out


# 並列実行される試合計算スレッドから呼ばれうるため Mutex で保護する
# (プロファイル計測は1試合あたり数回のみで頻度が低く、ロックのオーバーヘッドは無視できる)。
static func _profile_add(label: String, elapsed_usec: int) -> void:
	if not _profile_enabled:
		return
	_profile_mutex.lock()
	_profile_totals_usec[label] = int(_profile_totals_usec.get(label, 0)) + elapsed_usec
	_profile_mutex.unlock()


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


# force_sequential=true は決定性テスト/比較用の逐次経路。標準的な1日は必ず全チームが稼働する
# (セ・パ各3試合=6試合)ため、通常はチームが完全に排反な複数試合を WorkerThreadPool で並列計算する。
static func simulate_current_day(season: PSSeason, persist: bool = true, auto_swap_ctx: Dictionary = {}, force_sequential: bool = false) -> Dictionary:
	var day: int = season.current_day
	var today_indices: Array = []
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != day:
			continue
		today_indices.append(index)

	if today_indices.is_empty():
		var single_result: Dictionary = simulate_next_unplayed_game(season, false, {})
		if not bool(single_result.get("ok", false)):
			return single_result
		_finish_single_game_day_fallback(season, single_result, persist, auto_swap_ctx)
		return {
			"ok": true,
			"results": [single_result],
			"message": str(single_result.get("message", "")),
		}

	# 順序が重要: スポット昇格 → 二軍戦 → 一軍戦。
	# 昇格を先にしないと、その日一軍で先発する投手が二軍戦にも出てしまう (同日二重出場)。
	# 二軍戦を一軍より先にするのは、一軍の `_apply_game_result` が `advance_current_day` を
	# 呼ぶため — 後に回すと season.current_day が翌日へ進んだ状態で二軍のローテを解決してしまう。
	# 一軍のグループ自体には手を触れないので、一軍側の決定性は自明に保たれる。
	_run_spot_starter_callups(season, day, auto_swap_ctx)
	_simulate_farm_day(season, day, force_sequential)

	var day_result: Dictionary = _simulate_day_games(season, today_indices, persist, force_sequential or today_indices.size() <= 1)
	if not bool(day_result.get("ok", false)):
		return day_result
	var results: Array = day_result.get("results", []) as Array

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


# 谷間の先発 (二軍から1試合限定の昇格) と、登板を終えたスポット昇格の抹消。
# 試合の計算より前にメインスレッドで行う (ロスターが確定していないと setup が組めない)。
# auto_swap_ctx が空 (ツール/ベンチ/テスト) のときは全球団へ適用する。
static func _run_spot_starter_callups(season: PSSeason, day: int, auto_swap_ctx: Dictionary) -> void:
	if season.farm_schedule.is_empty():
		return
	var user_team_id: int = int(auto_swap_ctx.get("user_team_id", 0))
	var include_user: bool = auto_swap_ctx.is_empty() or bool(auto_swap_ctx.get("include_user_team", false))
	TeamAutoAI.run_spot_starter_callups(season, GameDb.teams, day, user_team_id, include_user)


# 当日の二軍戦を消化する。一軍とは別の WorkerThreadPool グループで回す。
# Phase 0 の実測では「一軍と同一グループにまとめる」案との速度差は3%しかなく、別グループの
# 方が実装がはるかに単純 (一軍のレーンID割当も seed 空間も一切変えずに済む)。
static func _simulate_farm_day(season: PSSeason, day: int, force_sequential: bool) -> void:
	if season.farm_schedule.is_empty():
		return
	var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()
	PSFarmGameRunner.simulate_day(season, day, rule_groups, force_sequential)


# today_indices の試合を計算する。sequential=true でも各試合には並列時と同じレーンID
# (today_indices内の相対位置)を割り当てて逐次実行し、Rngのシードストリームを完全に一致させる
# (これにより並列/逐次のどちらで実行しても同一試合が同一結果になることをテストで比較できる)。
# sequential=false は WorkerThreadPool で並列計算し、完了後にメインスレッドで schedule順
# (=today_indices順、逐次実行と同じ順序)に状態反映フェーズを適用する。
# 途中の試合が失敗した場合、それ以前に反映済みの試合は persist しつつ失敗dictを返す
# (逐次実装の「最初の失敗で打ち切り」挙動を踏襲。ただし失敗した試合以降の計算フェーズは
# 並列時は既に終わっている場合があり、計算中に更新された選手状態はrollbackされない)。
static func _simulate_day_games(season: PSSeason, today_indices: Array, persist: bool, sequential: bool) -> Dictionary:
	if not _prewarm_day_profiles(season, today_indices):
		return {"ok": false, "message": "成績データを読み込めませんでした"}
	var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()
	var calc_results: Array = []
	calc_results.resize(today_indices.size())
	if sequential:
		for local_index in range(today_indices.size()):
			calc_results[local_index] = _simulate_game_calculation(
				season,
				int(today_indices[local_index]),
				local_index,
				rule_groups
			)
	else:
		# 並列中は選手評価キャッシュを凍結し、worker からの遅延書き込みを封じる
		# (プリウォーム漏れがあっても結果は変わらず、その回だけ計算し直しになる)。
		PSPerformanceReference.set_frozen(true)
		var task: Callable = _calc_task_body.bind(season, today_indices, calc_results, rule_groups)
		var group_id: int = WorkerThreadPool.add_group_task(task, today_indices.size())
		WorkerThreadPool.wait_for_group_task_completion(group_id)
		PSPerformanceReference.set_frozen(false)

	var applied_results: Array = []
	for local_index in range(today_indices.size()):
		var calc: Dictionary = calc_results[local_index] as Dictionary
		if not bool(calc.get("ok", false)):
			if not applied_results.is_empty() and persist:
				_persist_simulation_outputs(season)
			return {"ok": false, "message": str(calc.get("message", ""))}
		applied_results.append(_apply_game_result(season, calc, false))
	return {"ok": true, "results": applied_results}


# WorkerThreadPool.add_group_task のコールバック本体。local_index がそのままレーンIDになる
# (同一インデックスは同時に2つ動かないため排他は自明)。
static func _calc_task_body(
	local_index: int,
	season: PSSeason,
	indices: Array,
	out_results: Array,
	rule_groups: Array[Dictionary]
) -> void:
	out_results[local_index] = _simulate_game_calculation(
		season,
		int(indices[local_index]),
		local_index,
		rule_groups
	)


static func _prewarm_day_profiles(season: PSSeason, game_indices: Array) -> bool:
	# team別RecordStore indexの再構築が必要なら、worker起動前のmain threadで完了させる。
	if not RecordStore.prepare_team_player_index():
		return false
	# 選手評価の基準分布も同様。worker から初回参照されると複数スレッドが同じ静的 Dictionary を
	# 同時に埋めにかかる (PSPerformanceReference 冒頭のレース制約)。キャッシュ済みなら
	# シーズンぶんの Dictionary 参照だけで済むので毎日呼んで良い。
	PSPerformanceReference.prewarm(season.year, season.season_number)
	var loaded_batting_profiles: Dictionary = {}
	var loaded_defense_profiles: Dictionary = {}
	var loaded_form_teams: Dictionary = {}
	for index_value in game_indices:
		var game: Dictionary = season.schedule[int(index_value)] as Dictionary
		var dh_enabled: bool = bool(game.get("dh_enabled", false))
		for team_id in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			if team_id > 0 and not loaded_form_teams.has(team_id):
				var records: Array = RecordStore.get_team_player_records(
					team_id, season.year, season.season_number
				)
				PSBatterForm.prewarm_past_samples(records)
				PSPitcherForm.prewarm_past_samples(records)
				loaded_form_teams[team_id] = true
			var batting_key: String = "%d_%d" % [team_id, 1 if dh_enabled else 0]
			if not loaded_batting_profiles.has(batting_key):
				PSBattingOrderProfile.load_for_team(team_id, dh_enabled)
				loaded_batting_profiles[batting_key] = true
			var defense_key: String = str(team_id)
			if not loaded_defense_profiles.has(defense_key):
				PSDefenseAlignmentProfile.load_for_team(team_id)
				loaded_defense_profiles[defense_key] = true
	return true


static func _finish_single_game_day_fallback(
	season: PSSeason,
	single_result: Dictionary,
	persist: bool,
	auto_swap_ctx: Dictionary
) -> int:
	var game: Dictionary = single_result.get("game", {}) as Dictionary
	var game_day: int = int(game.get("day", season.current_day))
	if not auto_swap_ctx.is_empty() and season.current_day != game_day:
		_run_periodic_roster_swap_hook(season, game_day, auto_swap_ctx)
	if persist:
		_persist_simulation_outputs(season)
	return game_day


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
# ctx = { "user_team_id": int, "include_user_team": bool, "include_user_trade": bool }
static func _run_periodic_roster_swap_hook(season: PSSeason, day: int, ctx: Dictionary) -> void:
	var user_team_id: int = int(ctx.get("user_team_id", 0))
	var include_user: bool = bool(ctx.get("include_user_team", false))
	# 支配下登録期限 (7/31、交換期限と同日) の最終試合日: オフで 67 止まりにして空けておいた枠を
	# 育成の即戦力で 70 まで埋める。期限後は FA/外国人/トレードが無く、残した枠が死に枠になるため。
	# 入替より先に走らせて、昇格したその日から一軍候補に入れる。
	# 外側の is_window_open_on_day は「期限を過ぎた日は日程走査を省く」ための安いガード。
	if TradeService.is_window_open_on_day(season, day) \
			and TradeService.is_last_window_game_day(season, day, _next_scheduled_day_after(season, day)):
		var promotions: Dictionary = OffseasonService.process_registration_deadline_promotions(
			GameDb.players, GameDb.teams, 0 if include_user else user_team_id, season
		)
		if int(promotions.get("promoted_count", 0)) > 0:
			GameDb.rebuild_player_indices()
	TeamAutoAI.run_periodic_roster_swaps(season, GameDb.teams, day, user_team_id, include_user)
	# シーズン中トレード (交換期限まで週次・低頻度)。成立時は players の team_id が動くので
	# インデックスを再構築する。自軍もCPU自動管理のとき (オートプレイ/自動入替ON/自動トレードON) は
	# 自軍宛て提案を作らず、自軍もCPU間マッチングに参加させる。include_user_trade 未指定の呼び出し元
	# (long_autoplay_reporter 等) は include_user_team のみで判定する従来挙動にフォールバックする。
	var include_user_trade: bool = bool(ctx.get("include_user_trade", include_user))
	var trade_user_id: int = 0 if include_user_trade else user_team_id
	var trade_result: Dictionary = TradeService.run_periodic_trade_check(season, GameDb.players, GameDb.teams, day, trade_user_id)
	if not (trade_result.get("executed", []) as Array).is_empty():
		GameDb.rebuild_player_indices()


# day より後に試合が組まれている最も早い日 (無ければ -1)。日次フックの「期限内の最終試合日」判定用。
static func _next_scheduled_day_after(season: PSSeason, day: int) -> int:
	var next_day: int = -1
	for game_row in season.schedule:
		var game_day: int = int((game_row as Dictionary).get("day", 0))
		if game_day <= day:
			continue
		if next_day < 0 or game_day < next_day:
			next_day = game_day
	return next_day


static func _persist_simulation_outputs(season: PSSeason) -> void:
	# 詳細ログを失った状態でRecordStoreだけを先へ進めると、次回ロード時に
	# season本体と選手記録が食い違う。ログ失敗時はpendingを残し、後続SaveServiceで再試行する。
	if not GameLogService.write_pending_game_logs(season):
		push_error("Could not flush pending game logs before persisting simulation records.")
		return
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


static func simulate_remaining_season(
	season: PSSeason,
	persist: bool = true,
	auto_swap_ctx: Dictionary = {},
	force_sequential: bool = false
) -> Dictionary:
	var simulated_count: int = 0
	var last_result: Dictionary = {}
	var guard: int = season.schedule.size() + 1
	while guard > 0:
		guard -= 1
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = simulate_current_day(season, false, auto_swap_ctx, force_sequential)
		if not bool(day_result.get("ok", false)):
			if simulated_count > 0 and persist:
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		var day_results: Array = day_result.get("results", []) as Array
		if day_results.is_empty():
			if simulated_count > 0 and persist:
				_persist_simulation_outputs(season)
			return {"ok": false, "message": "試合日の消化結果が空です"}
		simulated_count += day_results.size()
		if season.current_day == prev_day:
			break

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
	if _is_cancelled(cancel_token):
		return {"ok": false, "cancelled": true, "message": "シミュレーションはキャンセルされました"}
	var day: int = season.current_day
	var today_indices: Array = []
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if bool(game.get("played", false)):
			continue
		if int(game.get("day", 0)) != day:
			continue
		today_indices.append(index)

	# 計算フェーズをWorkerThreadPoolで並列起動し、完了をポーリングしながらUIのフレームを解放する。
	# 計算中に選手成績・疲労・怪我も更新されるため、開始済みの日は全試合を必ず状態へ反映する。
	# キャンセルは呼び出し側が次の日を開始する前に判定する。
	var results: Array = []
	if not today_indices.is_empty():
		if not _prewarm_day_profiles(season, today_indices):
			return {"ok": false, "message": "成績データを読み込めませんでした"}
		# 同期版と同じ順序 (スポット昇格 → 二軍戦 → 一軍戦)。同期/非同期で結果が一致する
		# 必要があるので **両方の経路に必ず入れる** — 片方だけだと決定性テストが落ちる。
		_run_spot_starter_callups(season, day, auto_swap_ctx)
		_simulate_farm_day(season, day, false)
		var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()
		var calc_results: Array = []
		calc_results.resize(today_indices.size())
		var task: Callable = _calc_task_body.bind(season, today_indices, calc_results, rule_groups)
		PSPerformanceReference.set_frozen(true)
		var group_id: int = WorkerThreadPool.add_group_task(task, today_indices.size())
		while not WorkerThreadPool.is_group_task_completed(group_id):
			if tree == null:
				break
			await tree.process_frame
		WorkerThreadPool.wait_for_group_task_completion(group_id)
		PSPerformanceReference.set_frozen(false)

		for local_index in range(today_indices.size()):
			var calc: Dictionary = calc_results[local_index] as Dictionary
			if not bool(calc.get("ok", false)):
				if not results.is_empty() and persist:
					_persist_simulation_outputs(season)
				return calc
			results.append(_apply_game_result(season, calc, false))
			if progress_cb.is_valid():
				progress_cb.call(progress_baseline + results.size(), progress_total, SeasonCalendar.day_status_label(season, day))
		if tree != null:
			await tree.process_frame

	if results.is_empty():
		if _is_cancelled(cancel_token):
			return {"ok": false, "cancelled": true, "message": "シミュレーションはキャンセルされました"}
		var single_result: Dictionary = simulate_next_unplayed_game(season, false, {})
		if not bool(single_result.get("ok", false)):
			return single_result
		var game_day: int = _finish_single_game_day_fallback(season, single_result, persist, auto_swap_ctx)
		results.append(single_result)
		if progress_cb.is_valid():
			progress_cb.call(progress_baseline + 1, progress_total, SeasonCalendar.day_status_label(season, game_day))
		if tree != null:
			await tree.process_frame
		return {
			"ok": true,
			"results": results,
			"cancelled": _is_cancelled(cancel_token),
			"message": str(single_result.get("message", "")),
		}

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
		if _next_unplayed_game_index(season) < 0:
			break
		var prev_day: int = season.current_day
		var day_result: Dictionary = await simulate_current_day_async(
			season, false, auto_swap_ctx, tree, progress_cb, cancel_token,
			simulated_count, total_games
		)
		if not bool(day_result.get("ok", false)):
			if simulated_count > 0 and persist:
				_persist_simulation_outputs(season)
			return day_result
		last_result = day_result
		var day_results: Array = day_result.get("results", []) as Array
		if day_results.is_empty():
			if simulated_count > 0 and persist:
				_persist_simulation_outputs(season)
			return {"ok": false, "cancelled": _is_cancelled(cancel_token), "message": "試合日の消化結果が空です"}
		simulated_count += day_results.size()
		if bool(day_result.get("cancelled", false)):
			break
		if season.current_day == prev_day:
			break

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
	# lane_id=-1: レーン機構を使わない(Rngは従来の共有generatorへフォールバック)。
	# 逐次呼び出し(postseason/単発デバッグツール/このラッパー自身)の挙動は一切変わらない。
	var rule_groups: Array[Dictionary] = ModManager.hot_rule_groups_snapshot()
	var calc: Dictionary = _simulate_game_calculation(season, game_index, -1, rule_groups)
	if not bool(calc.get("ok", false)):
		return calc
	return _apply_game_result(season, calc, persist)


# 1試合の計算フェーズ。setup構築とPSGameLoop.simulate_gameのみを行い、season/RecordStore/GameDb
# の共有コンテナへは(排他所有が保証されたPSPlayerSeasonRecord/PSPlayer以外は)書き込まない。
# 1日分の試合はチームが完全に排反なので、WorkerThreadPoolで複数試合を並列に呼んでも安全。
# lane_id >= 0 のときだけ Rng のレーンストリームを開始/終了する(-1 は従来の共有generatorのまま)。
static func _simulate_game_calculation(
	season: PSSeason,
	game_index: int,
	lane_id: int,
	rule_groups: Array[Dictionary] = []
) -> Dictionary:
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

	if lane_id >= 0:
		var seed_key: int = hash([Rng.current_seed, season.year, season.season_number, game_index])
		Rng.begin_game_stream(lane_id, seed_key)

	if _profile_enabled:
		var now_setup: int = Time.get_ticks_usec()
		_profile_add("setup", now_setup - profile_start)
		profile_start = now_setup
	var pre_player_stats: Dictionary = _snapshot_game_player_stats(season, away_setup, home_setup)
	if _profile_enabled:
		var now_snapshot: int = Time.get_ticks_usec()
		_profile_add("snapshot", now_snapshot - profile_start)
		profile_start = now_snapshot

	var result: Dictionary = PSGameLoop.simulate_game(away_setup, home_setup, rule_groups)
	if _profile_enabled:
		var now_loop: int = Time.get_ticks_usec()
		_profile_add("loop", now_loop - profile_start)

	if lane_id >= 0:
		Rng.end_game_stream()

	return {
		"ok": true,
		"game_index": game_index,
		"game": game,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_setup": away_setup,
		"home_setup": home_setup,
		"result": result,
		"pre_player_stats": pre_player_stats,
	}


# 状態反映フェーズ。season/RecordStore/GameDbへの書き込みを行うため、必ずメインスレッドで
# (並列計算した試合であれば全試合の計算完了=join後に)逐次呼ぶこと。
static func _apply_game_result(season: PSSeason, calc: Dictionary, persist: bool) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if _profile_enabled else 0
	var game_index: int = int(calc.get("game_index", -1))
	var game: Dictionary = calc.get("game", {}) as Dictionary
	var away_team_id: int = int(calc.get("away_team_id", 0))
	var home_team_id: int = int(calc.get("home_team_id", 0))
	var away_setup: Dictionary = calc.get("away_setup", {}) as Dictionary
	var home_setup: Dictionary = calc.get("home_setup", {}) as Dictionary
	var result: Dictionary = calc.get("result", {}) as Dictionary
	var pre_player_stats: Dictionary = calc.get("pre_player_stats", {}) as Dictionary

	game["away_score"] = int(result.get("away_score", 0))
	game["home_score"] = int(result.get("home_score", 0))
	game["played"] = true
	game["result"] = result
	season.schedule[game_index] = game

	PSGameDecisions.apply_game_decisions(season, away_team_id, home_team_id, result)
	if _profile_enabled:
		var now_decisions: int = Time.get_ticks_usec()
		_profile_add("decisions", now_decisions - profile_start)
		profile_start = now_decisions
	_record_player_game_logs(season, game_index, game, result, pre_player_stats)
	_record_team_lineups(season, game_index, game, result)
	# 後段レポートに必要な値をシーズン単位へ集約し、画面用の compact ログを作ってから、
	# schedule から play_events / advanced_stats 等の完全結果を外す。呼び出し結果の result は
	# 完全版のまま返すため、単発プローブや当日結果コールバックの契約は維持される。
	season.accumulate_game_report_data(result)
	GameLogService.stage_game_log(season, game_index, result)
	game = season.schedule[game_index] as Dictionary
	game["result"] = season.compact_game_result(result)
	season.schedule[game_index] = game
	if _profile_enabled:
		var now_logs: int = Time.get_ticks_usec()
		_profile_add("game_logs", now_logs - profile_start)
		profile_start = now_logs
	_log_long_injuries_to_career(season, result)
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


# 長期離脱 (PSCareerLog.INJURY_LOG_MIN_DAYS 以上) だけ選手経歴へ記録する (R7)。
static func _log_long_injuries_to_career(season: PSSeason, result: Dictionary) -> void:
	for event_value in result.get("injury_events", []) as Array:
		var event: Dictionary = event_value as Dictionary
		var days: int = int(event.get("days", event.get("injury_days", 0)))
		if days < PSCareerLog.INJURY_LOG_MIN_DAYS:
			continue
		var player: PSPlayer = GameDb.get_player(int(event.get("player_id", 0)))
		PSCareerLog.log_injury(player, season.year, days, str(event.get("label", "故障")))


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


# 表示・エラーメッセージ用の球団名。ファーム専用球団も引けるよう get_any_team を使う
# (判定ロジックではなく表示なので、二軍の文脈を混ぜても一軍系の集計には影響しない)。
static func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_any_team(team_id)
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


# 両チームのスタメン(打順/守備位置)を season.team_lineup_history へ記録する。
# _apply_game_result は状態反映フェーズであり必ずメインスレッドで逐次呼ばれるため
# (計算フェーズの並列化とは別区間)、season.append_team_lineup への書き込みはスレッド安全。
static func _record_team_lineups(season: PSSeason, game_index: int, game: Dictionary, result: Dictionary) -> void:
	if season == null:
		return
	var lineups: Dictionary = result.get("lineups", {}) as Dictionary
	var away_team_id: int = int(game.get("away_team_id", result.get("away_team_id", 0)))
	var home_team_id: int = int(game.get("home_team_id", result.get("home_team_id", 0)))
	var away_score: int = int(result.get("away_score", game.get("away_score", 0)))
	var home_score: int = int(result.get("home_score", game.get("home_score", 0)))
	var day: int = int(game.get("day", season.current_day))
	var date: String = str(game.get("date", ""))

	var away_lineup: Dictionary = lineups.get("away", {}) as Dictionary
	var home_lineup: Dictionary = lineups.get("home", {}) as Dictionary
	if not away_lineup.is_empty():
		season.append_team_lineup(_team_lineup_row(
			season, game_index, day, date, away_team_id, home_team_id, "away",
			away_score, home_score, int(result.get("away_pitcher_id", 0)), away_lineup,
		))
	if not home_lineup.is_empty():
		season.append_team_lineup(_team_lineup_row(
			season, game_index, day, date, home_team_id, away_team_id, "home",
			home_score, away_score, int(result.get("home_pitcher_id", 0)), home_lineup,
		))


# SQLiteStore.load_team_lineup_history() が返す行と同じキー集合を持たせる (year/season_number
# 込み) ことで、当季 (season.team_lineup_history 由来) と過去季 (SQLite 由来) を
# PSLineupHistory 側が分岐なしで扱える。
static func _team_lineup_row(
	season: PSSeason,
	game_index: int,
	day: int,
	date: String,
	team_id: int,
	opponent_id: int,
	home_away: String,
	score_for: int,
	score_against: int,
	starter_pitcher_id: int,
	lineup: Dictionary,
) -> Dictionary:
	var slots: Array = []
	for slot_value in (lineup.get("slots", []) as Array):
		var slot: Dictionary = slot_value as Dictionary
		slots.append({
			"slot": int(slot.get("slot", 0)),
			"pos": int(slot.get("position", 0)),
			"pid": int(slot.get("player_id", 0)),
		})
	return {
		"year": season.year,
		"season_number": season.season_number,
		"team_id": team_id,
		"game_index": game_index,
		"day": day,
		"date": date,
		"opponent_id": opponent_id,
		"home_away": home_away,
		"result": _team_result_label(score_for, score_against),
		"score_for": score_for,
		"score_against": score_against,
		"starter_pitcher_id": starter_pitcher_id,
		"dh": bool(lineup.get("dh", false)),
		"slots": slots,
	}


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
