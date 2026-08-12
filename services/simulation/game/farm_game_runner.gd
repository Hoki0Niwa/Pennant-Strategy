extends RefCounted
class_name PSFarmGameRunner

# 二軍 (ファーム) 戦の実行。一軍と**同じ `PSGameLoop.simulate_game`** を素通しで使い、
# 周辺処理だけを削ることでコストを抑える (成績生成の第2実装を持たない = 較正が二重にならない)。
#
# ## 一軍と違うところ
# - 延長は `PSFarmSchedule.MAX_INNINGS` (10回) で打ち切る。
# - 出場可能なのは「一軍登録の裏返し + 育成選手」。専用球団は在籍者全員。
# - **play-by-play ログ / 打順履歴 / ロスター修復 / advanced stats (守備イニング以外) を作らない。**
# - 成績は `record.farm_batter_stats` / `farm_pitcher_stats` へ入れる。
#   一軍成績は試合前の値へ復元する ([[project_postseason_stats]] と同じ snapshot-diff 方式)。
#   **疲労・怪我の変化は復元しない** — そこは一軍と共有したい値なので。
# - `advance_current_day` を呼ばない (日付の進行は一軍側が所有する)。
#
# ## 実行順
# `GameSimulator.simulate_current_day` が**一軍の処理より前**に当日の二軍戦を回す。
# 一軍側は `_apply_game_result` の中で `advance_current_day` を呼ぶため、後に回すと
# `season.current_day` が翌日へ進んだ状態で二軍のローテを解決してしまう。
# 一軍グループには一切手を触れないので、一軍の決定性は自明に保たれる。

const LEVEL_FARM: int = PSTeamSetupBuilder.LEVEL_FARM

# 二軍戦を丸ごと止めるスイッチ。**調査/較正ツール専用**で、通常プレイでは常に true。
# 二軍を足すと1試合日のコストが約2倍になるため、PA モデルの较正のように二軍が無関係な
# 作業では切って現行速度で回せるようにしてある。セーブには入れない
# (セーブに入れると「二軍の無い世界」のセーブが生まれ、昇降格や育成の前提が崩れるため)。
static var enabled: bool = true


# 1日ぶんの二軍戦。一軍とは別グループで計算し、その後メインスレッドで順に反映する。
static func simulate_day(
	season: PSSeason,
	day: int,
	rule_groups: Array[Dictionary],
	sequential: bool = false
) -> Dictionary:
	if not enabled:
		return {"ok": true, "results": [], "played_count": 0, "cancelled_count": 0}
	var indices: Array = season.farm_game_indices_on_day(day)
	if indices.is_empty():
		return {"ok": true, "results": [], "played_count": 0, "cancelled_count": 0}
	if not _prewarm_profiles(season, indices):
		return {"ok": false, "message": "二軍の成績データを読み込めませんでした"}

	var calc_results: Array = []
	calc_results.resize(indices.size())
	if sequential or indices.size() <= 1:
		for local_index in range(indices.size()):
			calc_results[local_index] = calculate(season, int(indices[local_index]), local_index, rule_groups)
	else:
		var task: Callable = _calc_task_body.bind(season, indices, calc_results, rule_groups)
		var group_id: int = WorkerThreadPool.add_group_task(task, indices.size())
		WorkerThreadPool.wait_for_group_task_completion(group_id)

	var applied: Array = []
	var cancelled: int = 0
	for local_index in range(indices.size()):
		var calc: Dictionary = calc_results[local_index] as Dictionary
		if not bool(calc.get("ok", false)):
			# 一軍が上位を抜いた残りなので、故障が重なると人数が足りず組めないことがある。
			# エラーで日進行を止めず、その試合だけ中止扱いにする (再試合は行わない)。
			_mark_cancelled(season, int(indices[local_index]), str(calc.get("message", "")))
			cancelled += 1
			continue
		applied.append(apply(season, calc))
	return {
		"ok": true,
		"results": applied,
		"played_count": applied.size(),
		"cancelled_count": cancelled,
	}


# 計算フェーズ。season/RecordStore/GameDb の共有コンテナへは書き込まない
# (排他所有が保証された PSPlayerSeasonRecord / PSPlayer への書き込みだけ行う)。
static func calculate(
	season: PSSeason,
	farm_index: int,
	lane_id: int,
	rule_groups: Array[Dictionary] = []
) -> Dictionary:
	if farm_index < 0 or farm_index >= season.farm_schedule.size():
		return {"ok": false, "message": "二軍の試合番号が不正です"}
	var game: Dictionary = season.farm_schedule[farm_index] as Dictionary
	if bool(game.get("played", false)):
		return {"ok": false, "message": "この二軍戦は消化済みです"}

	var away_team_id: int = int(game.get("away_team_id", 0))
	var home_team_id: int = int(game.get("home_team_id", 0))
	var dh_enabled: bool = bool(game.get("dh_enabled", true))
	var away_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, away_team_id, dh_enabled, false, LEVEL_FARM)
	if not bool(away_setup.get("ok", false)):
		return away_setup
	var home_setup: Dictionary = PSTeamSetupBuilder.build_team_setup(season, home_team_id, dh_enabled, false, LEVEL_FARM)
	if not bool(home_setup.get("ok", false)):
		return home_setup

	if lane_id >= 0:
		# 一軍とシード空間を分ける ("farm" タグ)。同じ試合番号でも別の乱数列になる。
		Rng.begin_game_stream(lane_id, hash([Rng.current_seed, season.year, season.season_number, "farm", farm_index]))

	var snapshots: Dictionary = _snapshot_setup_records(away_setup, home_setup)
	var result: Dictionary = PSGameLoop.simulate_game(
		away_setup, home_setup, rule_groups, PSFarmSchedule.MAX_INNINGS
	)

	if lane_id >= 0:
		Rng.end_game_stream()

	return {
		"ok": true,
		"farm_index": farm_index,
		"game": game,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_setup": away_setup,
		"home_setup": home_setup,
		"result": result,
		"snapshots": snapshots,
	}


# 状態反映フェーズ。必ずメインスレッドで (並列計算した場合は join 後に) 逐次呼ぶこと。
static func apply(season: PSSeason, calc: Dictionary) -> Dictionary:
	var farm_index: int = int(calc.get("farm_index", -1))
	var game: Dictionary = calc.get("game", {}) as Dictionary
	var away_team_id: int = int(calc.get("away_team_id", 0))
	var home_team_id: int = int(calc.get("home_team_id", 0))
	var away_setup: Dictionary = calc.get("away_setup", {}) as Dictionary
	var home_setup: Dictionary = calc.get("home_setup", {}) as Dictionary
	var result: Dictionary = calc.get("result", {}) as Dictionary
	var snapshots: Dictionary = calc.get("snapshots", {}) as Dictionary

	var away_score: int = int(result.get("away_score", 0))
	var home_score: int = int(result.get("home_score", 0))

	# 勝敗投手/セーブ/ホールドは record.pitcher_stats へ一旦入れ、下の差分回収で
	# farm_pitcher_stats へ移す (一軍側には残らない)。
	_apply_pitching_decisions(season, result, away_team_id, home_team_id)
	# 守備イニングは advanced stats を丸ごと取り込まず、この1項目だけ抜き出す。
	_collect_farm_defensive_outs(season, result)
	# 一軍成績との差分 = この試合ぶんの二軍成績。回収後に一軍成績を試合前へ戻す。
	_collect_farm_stat_deltas(snapshots)

	_apply_farm_team_result(season, away_team_id, away_score, home_score)
	_apply_farm_team_result(season, home_team_id, home_score, away_score)

	var game_day: int = int(game.get("day", season.current_day))
	PSRotationPlanner.record_rotation_start(season, away_team_id, away_setup, game_day, LEVEL_FARM)
	PSRotationPlanner.record_rotation_start(season, home_team_id, home_setup, game_day, LEVEL_FARM)

	game["away_score"] = away_score
	game["home_score"] = home_score
	game["played"] = true
	# 二軍は play-by-play ログを持たない。schedule に残すのは compact サマリのみ。
	game["result"] = season.compact_game_result(result)
	season.farm_schedule[farm_index] = game

	return {
		"ok": true,
		"game": game,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_score": away_score,
		"home_score": home_score,
	}


# ---- 内部 ------------------------------------------------------------------

static func _calc_task_body(
	local_index: int,
	season: PSSeason,
	indices: Array,
	out_results: Array,
	rule_groups: Array[Dictionary]
) -> void:
	out_results[local_index] = calculate(season, int(indices[local_index]), local_index, rule_groups)


static func _prewarm_profiles(season: PSSeason, indices: Array) -> bool:
	if not RecordStore.prepare_team_player_index():
		return false
	var loaded_batting: Dictionary = {}
	var loaded_defense: Dictionary = {}
	for index_value in indices:
		var game: Dictionary = season.farm_schedule[int(index_value)] as Dictionary
		var dh_enabled: bool = bool(game.get("dh_enabled", true))
		for team_id in [int(game.get("away_team_id", 0)), int(game.get("home_team_id", 0))]:
			var batting_key: String = "%d_%d" % [team_id, 1 if dh_enabled else 0]
			if not loaded_batting.has(batting_key):
				PSBattingOrderProfile.load_for_team(team_id, dh_enabled)
				loaded_batting[batting_key] = true
			if not loaded_defense.has(team_id):
				PSDefenseAlignmentProfile.load_for_team(team_id)
				loaded_defense[team_id] = true
	return true


# 人数不足などで組めなかった試合。実 NPB のファームも中止試合の再試合を行わないので、
# 消化済みにして順位は勝率で見る (試合数が球団間で揃わないのは織り込み済み)。
static func _mark_cancelled(season: PSSeason, farm_index: int, message: String) -> void:
	var game: Dictionary = season.farm_schedule[farm_index] as Dictionary
	game["played"] = true
	game["cancelled"] = true
	game["cancel_reason"] = message
	game["result"] = {}
	season.farm_schedule[farm_index] = game


static func _apply_farm_team_result(season: PSSeason, team_id: int, runs_scored: int, runs_allowed: int) -> void:
	if not season.farm_standings.has(team_id):
		season.farm_standings[team_id] = PSStats.new()
	PSGameDecisions.add_team_stats(season.farm_standings[team_id] as PSStats, runs_scored, runs_allowed)
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team_id, season.year, season.season_number)
	if team_record != null:
		PSGameDecisions.add_team_stats(team_record.farm_stats, runs_scored, runs_allowed)


static func _apply_pitching_decisions(
	season: PSSeason, result: Dictionary, away_team_id: int, home_team_id: int
) -> void:
	var decisions: Dictionary = PSGameDecisions.compute_pitching_decisions(
		result,
		away_team_id,
		home_team_id,
		int(result.get("away_pitcher_id", 0)),
		int(result.get("home_pitcher_id", 0))
	)
	var hold_ids: Array = decisions.get("hold_pitcher_ids", []) as Array
	result["winning_pitcher_id"] = int(decisions.get("winning_pitcher_id", 0))
	result["losing_pitcher_id"] = int(decisions.get("losing_pitcher_id", 0))
	result["save_pitcher_id"] = int(decisions.get("save_pitcher_id", 0))
	result["hold_pitcher_ids"] = hold_ids

	if not bool(result.get("draw", false)):
		for pair in [
			[int(decisions.get("winning_pitcher_id", 0)), "win"],
			[int(decisions.get("losing_pitcher_id", 0)), "loss"],
			[int(decisions.get("save_pitcher_id", 0)), "save"],
		]:
			if int(pair[0]) > 0:
				PSGameDecisions.apply_pitcher_decision(season, int(pair[0]), str(pair[1]))
	for pid_value in hold_ids:
		if int(pid_value) > 0:
			PSGameDecisions.apply_pitcher_decision(season, int(pid_value), "hold")


# advanced stats のうち **守備イニングだけ**を farm_defensive_outs_by_position へ足す。
# WAR / OAA / wRAA は二軍では算出しないが、守備イニングだけはオフの守備適性成長が
# 入力に使うため捨てられない ([[project_farm_system_design]])。
static func _collect_farm_defensive_outs(season: PSSeason, result: Dictionary) -> void:
	var advanced: Dictionary = result.get("advanced_stats", {}) as Dictionary
	var players: Dictionary = advanced.get("players", {}) as Dictionary
	for key_value in players.keys():
		var entry: Dictionary = players.get(key_value, {}) as Dictionary
		var outs_by_position: Dictionary = entry.get("defensive_outs_by_position", {}) as Dictionary
		if outs_by_position.is_empty():
			continue
		var player_id: int = int(entry.get("player_id", 0))
		if player_id == 0 and str(key_value).is_valid_int():
			player_id = int(str(key_value))
		if player_id == 0:
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
		if record == null:
			continue
		for position_key in outs_by_position.keys():
			var key: String = str(position_key)
			record.farm_defensive_outs_by_position[key] = (
				int(record.farm_defensive_outs_by_position.get(key, 0)) + int(outs_by_position[position_key])
			)


static func _snapshot_setup_records(away_setup: Dictionary, home_setup: Dictionary) -> Dictionary:
	var snapshots: Dictionary = {}
	for setup in [away_setup, home_setup]:
		for record_row in _setup_records(setup as Dictionary):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record == null or snapshots.has(record.player_id):
				continue
			# Dictionary 経由 (to_dict/from_dict) ではなくオブジェクト複製で退避する。
			# 二軍は毎日7試合 × 約40人ぶんここを通るため、Dictionary の生成/解析が
			# そのまま二軍の追加コストに乗る (ポストシーズンは年数試合なので dict でも問題なかった)。
			snapshots[record.player_id] = {
				"record": record,
				"batter_stats": GameSimulator._clone_batter_stats(record.batter_stats),
				"pitcher_stats": GameSimulator._clone_pitcher_stats(record.pitcher_stats),
			}
	return snapshots


static func _setup_records(setup: Dictionary) -> Array:
	var records: Array = []
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
		var fielder: PSPlayerSeasonRecord = (row as Dictionary).get("record", null) as PSPlayerSeasonRecord
		if fielder != null:
			records.append(fielder)
	return records


# 試合前後の差分を二軍成績へ積み、一軍成績は試合前の値へ戻す。
# **疲労・怪我・恒久的な能力低下は戻さない** — 一軍と共有したい状態なので。
static func _collect_farm_stat_deltas(snapshots: Dictionary) -> void:
	for snapshot_value in snapshots.values():
		var snapshot: Dictionary = snapshot_value as Dictionary
		var record: PSPlayerSeasonRecord = snapshot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		var before_batter: PSBatterStats = snapshot.get("batter_stats", null) as PSBatterStats
		var before_pitcher: PSPitcherStats = snapshot.get("pitcher_stats", null) as PSPitcherStats
		if before_batter == null or before_pitcher == null:
			continue
		record.farm_batter_stats.add_from(record.batter_stats.subtract_from(before_batter))
		record.farm_pitcher_stats.add_from(record.pitcher_stats.subtract_from(before_pitcher))
		record.batter_stats = before_batter
		record.pitcher_stats = before_pitcher
