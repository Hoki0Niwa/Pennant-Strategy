extends GdUnitTestSuite

# 1日分の試合並列化(WorkerThreadPool)の決定性検証。
# 同一seed・同一初期状態から、逐次実行(force_sequential=true)と並列実行(force_sequential=false)
# が完全に同一の結果を生むことを確認する。1回のPASSでは競合状態の不在を証明できないため、
# 複数回繰り返して間欠的なレースを検出する。

const TRIAL_COUNT: int = 20
const FIXED_SEED: int = 424242
const REMAINING_TEST_DAY_COUNT: int = 2
const GameLogService = preload("res://services/storage/game_log_service.gd")


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


func test_remaining_season_paths_complete_and_match_sequential_days() -> void:
	var sequential: Dictionary = _run_short_remaining_season_sync(true)
	var parallel: Dictionary = _run_short_remaining_season_sync(false)
	var async_parallel: Dictionary = await _run_short_remaining_season_async({})

	assert_int(int(parallel.get("simulated_count", 0))).is_equal(int(sequential.get("simulated_count", 0)))
	assert_int(int(async_parallel.get("simulated_count", 0))).is_equal(int(sequential.get("simulated_count", 0)))
	assert_str(str(parallel.get("signature", ""))).is_equal(str(sequential.get("signature", "")))
	assert_str(str(async_parallel.get("signature", ""))).is_equal(str(sequential.get("signature", "")))


func test_remaining_season_async_cancels_at_day_boundary_and_resumes_cleanly() -> void:
	var uninterrupted: Dictionary = _run_short_remaining_season_sync(false)
	var season: PSSeason = _new_short_season()
	var first_day: int = season.current_day
	var total_games: int = season.schedule.size()
	var first_day_games: int = _game_count_for_day(season, first_day)
	var cancel_token: Dictionary = {"cancelled": false}
	var progress_calls: Array = []
	var progress_cb: Callable = func(done: int, total: int, label: String) -> void:
		progress_calls.append([done, total, label])
		if progress_calls.size() == 1:
			cancel_token["cancelled"] = true

	var partial_result: Dictionary = await GameSimulator.simulate_remaining_season_async(
		season, false, {}, get_tree(), progress_cb, cancel_token
	)
	assert_bool(bool(partial_result.get("ok", false))).is_true()
	assert_bool(bool(partial_result.get("cancelled", false))).is_true()
	assert_int(int(partial_result.get("simulated_count", 0))).is_equal(first_day_games)
	assert_int(_played_game_count_for_day(season, first_day)).is_equal(first_day_games)
	assert_int(_played_game_count(season)).is_equal(first_day_games)
	assert_int(progress_calls.size()).is_equal(first_day_games)
	var last_progress: Array = progress_calls[progress_calls.size() - 1] as Array
	assert_int(int(last_progress[0])).is_equal(first_day_games)
	assert_int(int(last_progress[1])).is_equal(total_games)

	cancel_token["cancelled"] = false
	var resumed_result: Dictionary = await GameSimulator.simulate_remaining_season_async(
		season, false, {}, get_tree(), Callable(), cancel_token
	)
	assert_bool(bool(resumed_result.get("ok", false))).is_true()
	assert_bool(bool(resumed_result.get("cancelled", false))).is_false()
	assert_int(int(resumed_result.get("simulated_count", 0))).is_equal(total_games - first_day_games)
	assert_int(_played_game_count(season)).is_equal(total_games)
	assert_str(_simulation_state_signature(season)).is_equal(str(uninterrupted.get("signature", "")))


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


func _run_short_remaining_season_sync(force_sequential: bool) -> Dictionary:
	var season: PSSeason = _new_short_season()
	var expected_count: int = season.schedule.size()
	var result: Dictionary = GameSimulator.simulate_remaining_season(
		season, false, {}, force_sequential
	)
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_int(int(result.get("simulated_count", 0))).is_equal(expected_count)
	assert_int(_played_game_count(season)).is_equal(expected_count)
	return {
		"simulated_count": int(result.get("simulated_count", 0)),
		"signature": _simulation_state_signature(season),
	}


func _run_short_remaining_season_async(cancel_token: Dictionary) -> Dictionary:
	var season: PSSeason = _new_short_season()
	var expected_count: int = season.schedule.size()
	var result: Dictionary = await GameSimulator.simulate_remaining_season_async(
		season, false, {}, get_tree(), Callable(), cancel_token
	)
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(result.get("cancelled", false))).is_false()
	assert_int(int(result.get("simulated_count", 0))).is_equal(expected_count)
	assert_int(_played_game_count(season)).is_equal(expected_count)
	return {
		"simulated_count": int(result.get("simulated_count", 0)),
		"signature": _simulation_state_signature(season),
	}


func _new_short_season() -> PSSeason:
	GameDb.load_initial_data()
	Rng.set_seed_value(FIXED_SEED)
	RecordStore.clear_records()
	PSBattingOrderProfile.reset_cache()
	PSDefenseAlignmentProfile.reset_cache()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
	_keep_first_schedule_days(season, REMAINING_TEST_DAY_COUNT)
	return season


func _keep_first_schedule_days(season: PSSeason, day_count: int) -> void:
	var selected_days: Array = []
	var short_schedule: Array = []
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var day: int = int(game.get("day", 0))
		if not selected_days.has(day):
			if selected_days.size() >= day_count:
				continue
			selected_days.append(day)
		if selected_days.has(day):
			short_schedule.append(game)
	season.schedule = short_schedule
	season.current_day = int(selected_days[0])


func _game_count_for_day(season: PSSeason, day: int) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) == day:
			count += 1
	return count


func _played_game_count_for_day(season: PSSeason, day: int) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) == day and bool(game.get("played", false)):
			count += 1
	return count


func _played_game_count(season: PSSeason) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			count += 1
	return count


func _simulation_state_signature(season: PSSeason) -> String:
	var event_parts: Array = []
	for game_index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[game_index] as Dictionary
		# schedule.result は消化直後に軽量化されるため、未保存の compact log を含む
		# read_available_game_log 経由で PA・交代・投手起用の決定性を比較する。
		var available_log: Dictionary = GameLogService.read_available_game_log(season, game_index)
		var events_json: String = JSON.stringify(available_log)
		event_parts.append("%d:%d:%d:%d:%d:%d" % [
			int(game.get("away_team_id", 0)),
			int(game.get("home_team_id", 0)),
			int(game.get("away_score", 0)),
			int(game.get("home_score", 0)),
			events_json.length(),
			events_json.hash(),
		])
	var season_json: String = JSON.stringify(season.to_dict())
	var records_json: String = JSON.stringify(RecordStore.to_dict())
	var player_rows: Array = []
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player != null:
			player_rows.append(player.to_dict())
	var players_json: String = JSON.stringify(player_rows)
	return "%d:%d|%d:%d|%d:%d|%s" % [
		season_json.length(),
		season_json.hash(),
		records_json.length(),
		records_json.hash(),
		players_json.length(),
		players_json.hash(),
		"|".join(event_parts),
	]


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
