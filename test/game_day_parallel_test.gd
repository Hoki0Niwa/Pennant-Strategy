extends GdUnitTestSuite

# 1日分の試合並列化(WorkerThreadPool)の決定性検証。
# 同一seed・同一初期状態から、逐次実行(force_sequential=true)と並列実行(force_sequential=false)
# が完全に同一の結果を生むことを確認する。1回のPASSでは競合状態の不在を証明できないため、
# 複数回繰り返して間欠的なレースを検出する。

const TRIAL_COUNT: int = 20
const FIXED_SEED: int = 424242


func test_parallel_day_matches_sequential_day_deterministically() -> void:
	for trial in range(TRIAL_COUNT):
		var seq_signature: String = _run_one_day(true)
		var par_signature: String = _run_one_day(false)
		assert_bool(par_signature == seq_signature).is_true()


# UI向け非同期経路(simulate_current_day_async)がネイティブGUIの目視確認なしでも自動検証できる
# よう、実際に await して呼び出し、同期並列経路と同一の結果になることと、進捗コールバックが
# 呼ばれることを確認する。
func test_async_day_matches_parallel_day_deterministically() -> void:
	var sync_signature: String = _run_one_day(false)
	var async_signature: String = await _run_one_day_async()
	assert_bool(async_signature == sync_signature).is_true()


func _run_one_day_async() -> String:
	GameDb.load_initial_data()
	Rng.set_seed_value(FIXED_SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var progress_calls: Array = []
	var progress_cb: Callable = func(done: int, total: int, label: String) -> void:
		progress_calls.append([done, total, label])
	var day_result: Dictionary = await GameSimulator.simulate_current_day_async(
		season, false, {}, get_tree(), progress_cb, {}
	)
	assert_bool(bool(day_result.get("ok", false))).is_true()
	assert_bool(progress_calls.is_empty()).is_false()
	return _day_signature(day_result)


# 同一seed・同一(再構築した)選手プールから1日分を実行し、結果のシグネチャ文字列を返す。
# GameDb.load_initial_data() で毎回選手プールを再構築するのは、稀に発生する怪我の恒久的能力
# 低下 (services/simulation/models/injury_model.gd) のような PSPlayer(永続オブジェクト)への
# 副作用が、前回実行の痕跡として次の実行に持ち越されないようにするため。
func _run_one_day(force_sequential: bool) -> String:
	GameDb.load_initial_data()
	Rng.set_seed_value(FIXED_SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, {}, force_sequential)
	assert_bool(bool(day_result.get("ok", false))).is_true()
	return _day_signature(day_result)


# 各試合の得点・play_events全体のハッシュを連結した短いシグネチャを返す。
# JSON全文をそのまま比較すると GdUnit4 の文字列diffツールが巨大文字列でクラッシュするため、
# 内容の完全性は保ったままハッシュ値(短い文字列)に落とし込んで比較する。
func _day_signature(day_result: Dictionary) -> String:
	var results: Array = day_result.get("results", []) as Array
	var parts: Array = []
	for result_value in results:
		var applied: Dictionary = result_value as Dictionary
		var game: Dictionary = applied.get("game", {}) as Dictionary
		var result: Dictionary = applied.get("result", {}) as Dictionary
		var play_events_json: String = JSON.stringify(result.get("play_events", []))
		parts.append("%d-%d:%d-%d:%d:%d" % [
			int(game.get("away_team_id", 0)),
			int(game.get("home_team_id", 0)),
			int(game.get("away_score", 0)),
			int(game.get("home_score", 0)),
			play_events_json.length(),
			play_events_json.hash(),
		])
	return "|".join(parts)
