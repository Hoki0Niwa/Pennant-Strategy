extends GdUnitTestSuite

const AppVersion = preload("res://services/app_version.gd")
const SaveContext = preload("res://services/storage/save_context.gd")
const GameLogService = preload("res://services/storage/game_log_service.gd")
const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")


func test_auto_save_is_enabled_by_default_for_release_safety() -> void:
	assert_bool(AppState.DEFAULT_AUTO_SAVE_ENABLED).is_true()


func test_new_save_folder_scopes_storage_paths() -> void:
	var old_save_id: String = SaveContext.active_save_id()

	assert_bool(SaveService.begin_new_game()).is_true()
	var new_save_id: String = SaveContext.active_save_id()
	var save_dir: String = SaveContext.active_save_dir()

	assert_bool(new_save_id.begins_with("save_")).is_true()
	assert_str(save_dir).is_equal("user://saves/%s" % new_save_id)
	assert_str(SaveContext.game_state_path()).is_equal("%s/pennant_strategy_m0.save" % save_dir)
	assert_str(SaveContext.records_path()).is_equal("%s/pennant_strategy_records_m1.json" % save_dir)
	assert_str(SQLiteStoreService.runtime_db_path()).is_equal("%s/pennant_strategy_runtime.sqlite" % save_dir)
	assert_str(GameLogService.log_root()).is_equal("%s/game_logs" % save_dir)

	SaveContext.delete_current_save_data()
	assert_str(SaveContext.game_state_path()).is_equal("")
	assert_str(SaveContext.records_path()).is_equal("")
	assert_str(SQLiteStoreService.runtime_db_path()).is_equal("")
	assert_str(GameLogService.log_root()).is_equal("")
	assert_str(SaveContext.display_path()).is_equal("未作成")
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func test_report_game_log_suppression_is_scoped_to_its_season() -> void:
	var report_season: PSSeason = PSSeason.new()
	report_season.generate_game_logs = false
	report_season.schedule = [{}]
	var normal_season: PSSeason = PSSeason.new()
	normal_season.schedule = [{}]
	var result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 3,
		"home_score": 2,
		"innings": [{"inning": 1, "away": 1, "home": 0}],
	}

	GameLogService.stage_game_log(report_season, 0, result)
	GameLogService.stage_game_log(normal_season, 0, result)

	assert_bool((report_season.schedule[0] as Dictionary).has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_false()
	assert_bool((normal_season.schedule[0] as Dictionary).has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_true()
	var restored_report_season: PSSeason = PSSeason.from_dict(report_season.to_dict())
	assert_bool(restored_report_season.generate_game_logs).is_true()


func test_save_state_records_mod_metadata() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.auto_save_enabled = true
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(SaveService.is_state_current(AppState)).is_true()

	var main_script: GDScript = load("res://ui/main.gd") as GDScript
	var main: Control = main_script.new()
	assert_str(str(main.call("_quit_request_mode"))).is_equal("quit")
	AppState.auto_trade_for_user_team = not AppState.auto_trade_for_user_team
	assert_bool(SaveService.is_state_current(AppState)).is_false()
	assert_str(str(main.call("_quit_request_mode"))).is_equal("autosave")
	AppState.auto_save_enabled = false
	assert_str(str(main.call("_quit_request_mode"))).is_equal("confirm")
	AppState.auto_save_enabled = true
	AppState.auto_trade_for_user_team = not AppState.auto_trade_for_user_team
	assert_bool(SaveService.is_state_current(AppState)).is_true()
	main.free()

	var payload: Dictionary = SaveService.load_state()
	assert_bool(payload.has("active_mods")).is_true()
	assert_str(JSON.stringify(payload.get("active_mods", []) as Array)).is_equal(JSON.stringify(ModManager.active_mods_snapshot()))
	assert_str(str(payload.get("rules_profile_id", ""))).is_equal(ModManager.rules_profile_id())
	assert_int(int(payload.get("rules_schema_version", 0))).is_equal(ModManager.rules_schema_version())
	assert_int(int(payload.get("data_schema_version", 0))).is_equal(ModManager.data_schema_version())

	_restore_app_state(old_state, test_save_id)


func test_save_round_trip_preserves_decision_inputs() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""
	var team: PSTeam = GameDb.teams[0] as PSTeam

	AppState.select_team(team.id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	team.auto_lineup = true
	var setup: Dictionary = PSTeamSetupBuilder.build_team_setup(AppState.current_season, team.id, true)
	assert_bool(bool(setup.get("ok", false))).is_true()
	var generated_base_order: Array = AppState.current_season.get_auto_batting_order(team.id, true)
	assert_int(generated_base_order.size()).is_equal(9)
	team.auto_lineup = false
	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_CONTRACT_RENEWAL
	AppState.contract_years_state = {
		"year": 2026,
		"complete": false,
		"candidates": [{"player_id": 101, "team_id": team.id, "value": 72.5, "decided": true, "years": 3, "salary": 18000}],
	}

	assert_bool(SaveService.save_state(AppState)).is_true()
	var payload: Dictionary = SaveService.load_state()
	assert_bool(payload.has("team_auto_lineup")).is_true()
	assert_bool(payload.has("contract_years_state")).is_true()

	team.auto_lineup = true
	AppState.contract_years_state = {}
	assert_bool(AppState.restore_from_save(payload)).is_true()
	team = GameDb.get_team(team.id)
	assert_bool(team.auto_lineup).is_false()
	assert_str(JSON.stringify(AppState.contract_years_state)).is_equal(JSON.stringify(payload["contract_years_state"]))
	assert_str(JSON.stringify(AppState.current_season.get_auto_batting_order(team.id, true))).is_equal(
		JSON.stringify(generated_base_order)
	)
	assert_bool(SaveService.is_state_current(AppState)).is_true()

	team.auto_lineup = true
	assert_bool(SaveService.is_state_current(AppState)).is_false()
	team.auto_lineup = false
	assert_bool(SaveService.is_state_current(AppState)).is_true()
	AppState.contract_years_state["year"] = 2027
	assert_bool(SaveService.is_state_current(AppState)).is_false()

	_restore_app_state(old_state, test_save_id)


func test_player_record_identity_refresh_preserves_season_decision_inputs() -> void:
	var player: PSPlayer = GameDb.players[0] as PSPlayer
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	record.batter_stats.hits = 88
	record.pitcher_stats.strikeouts = 91
	record.advanced_stats.plate_appearances = 321
	record.advanced_stats.oaa_by_position = {"8": 4.5}
	record.farm_batter_stats.hits = 27
	record.farm_pitcher_stats.strikeouts = 33
	record.farm_advanced_stats.plate_appearances = 144
	record.season_injury_days = 42
	record.injury_return_day = 117
	record.consecutive_appearances = 3
	record.last_pitched_team_game = 82
	record.farm_consecutive_appearances = 2
	record.farm_last_pitched_team_game = 71

	var refreshed: PSPlayerSeasonRecord = RecordStore._refreshed_player_record(record, player)

	assert_int(refreshed.batter_stats.hits).is_equal(88)
	assert_int(refreshed.pitcher_stats.strikeouts).is_equal(91)
	assert_int(refreshed.advanced_stats.plate_appearances).is_equal(321)
	assert_int(refreshed.farm_batter_stats.hits).is_equal(27)
	assert_int(refreshed.farm_pitcher_stats.strikeouts).is_equal(33)
	assert_int(refreshed.farm_advanced_stats.plate_appearances).is_equal(144)
	assert_float(float(refreshed.advanced_stats.oaa_by_position.get("8", 0.0))).is_equal(4.5)
	assert_int(refreshed.season_injury_days).is_equal(42)
	assert_int(refreshed.injury_return_day).is_equal(117)
	assert_int(refreshed.consecutive_appearances).is_equal(3)
	assert_int(refreshed.last_pitched_team_game).is_equal(82)
	assert_int(refreshed.farm_consecutive_appearances).is_equal(2)
	assert_int(refreshed.farm_last_pitched_team_game).is_equal(71)


func test_team_player_index_partitions_history_and_returns_fresh_arrays() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var players: Array = GameDb.players.slice(0, 5)
	var rows: Array = []
	var specs: Array = [
		[players[0], 2, 2026, 1],
		[players[1], 1, 2025, 1],
		[players[2], 1, 2026, 1],
		[players[3], 2, 2026, 1],
		[players[4], 1, 2026, 2],
		[players[1], 1, 2026, 1],
	]
	for spec_value in specs:
		var spec: Array = spec_value as Array
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
			spec[0] as PSPlayer,
			int(spec[2]),
			int(spec[3])
		)
		record.team_id = int(spec[1])
		rows.append(record.to_dict())
	RecordStore.load_from_dict({
		"player_records": rows,
		"team_records": [],
		"season_archives": [],
	})

	var index_ready: bool = RecordStore.prepare_team_player_index()
	var records_view_is_read_only: bool = RecordStore.player_records.is_read_only()
	var payload_before: String = JSON.stringify(RecordStore.to_dict())
	var first_query: Array = RecordStore.get_team_player_records(1, 2026, 1)
	var first_ids: Array = _player_record_ids(first_query)
	first_query.clear()
	first_query.append(null)
	var second_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(1, 2026, 1)
	)
	var team_two_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(2, 2026, 1)
	)
	var other_season_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(1, 2026, 2)
	)
	var old_year_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(1, 2025, 1)
	)
	var missing: Array = RecordStore.get_team_player_records(99, 2026, 1)
	var payload_after: String = JSON.stringify(RecordStore.to_dict())
	RecordStore.load_from_dict(original_records)

	assert_bool(index_ready).is_true()
	assert_bool(records_view_is_read_only).is_true()
	assert_array(first_ids).is_equal([
		(players[2] as PSPlayer).id,
		(players[1] as PSPlayer).id,
	])
	assert_array(second_ids).is_equal(first_ids)
	assert_array(team_two_ids).is_equal([
		(players[0] as PSPlayer).id,
		(players[3] as PSPlayer).id,
	])
	assert_array(other_season_ids).is_equal([(players[4] as PSPlayer).id])
	assert_array(old_year_ids).is_equal([(players[1] as PSPlayer).id])
	assert_array(missing).is_empty()
	assert_str(payload_after).is_equal(payload_before)


func test_season_player_index_preserves_global_order_and_unassigned_records() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var players: Array = GameDb.players.slice(0, 4)
	var rows: Array = []
	for spec_value in [
		[players[0], 2, 2026, 1],
		[players[1], 0, 2026, 1],
		[players[2], 1, 2025, 1],
		[players[3], 1, 2026, 1],
	]:
		var spec: Array = spec_value as Array
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
			spec[0] as PSPlayer, int(spec[2]), int(spec[3])
		)
		record.team_id = int(spec[1])
		rows.append(record.to_dict())
	RecordStore.load_from_dict({
		"player_records": rows,
		"team_records": [],
		"season_archives": [],
	})

	var first_query: Array = RecordStore.get_player_records_for_season(2026, 1)
	var first_ids: Array = _player_record_ids(first_query)
	first_query.clear()
	var second_ids: Array = _player_record_ids(
		RecordStore.get_player_records_for_season(2026, 1)
	)
	RecordStore.load_from_dict(original_records)

	assert_array(first_ids).is_equal([
		(players[0] as PSPlayer).id,
		(players[1] as PSPlayer).id,
		(players[3] as PSPlayer).id,
	])
	assert_array(second_ids).is_equal(first_ids)


func test_ensure_season_records_rebuilds_team_index_without_losing_history() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var target_team_id: int = (GameDb.players[0] as PSPlayer).team_id
	var team_players: Array = []
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player.team_id == target_team_id and not player.is_retired():
			team_players.append(player)
			if team_players.size() == 3:
				break
	assert_int(team_players.size()).is_equal(3)
	var active_player: PSPlayer = team_players[0] as PSPlayer
	var removed_player: PSPlayer = team_players[1] as PSPlayer
	var added_player: PSPlayer = team_players[2] as PSPlayer
	var season: PSSeason = PSSeason.new()
	season.year = 2199
	season.season_number = 2
	var historical: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		active_player,
		2198,
		1
	)
	var active_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		active_player,
		season.year,
		season.season_number
	)
	var removed_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		removed_player,
		season.year,
		season.season_number
	)
	RecordStore.load_from_dict({
		"player_records": [
			historical.to_dict(),
			active_record.to_dict(),
			removed_record.to_dict(),
		],
		"team_records": [],
		"season_archives": [],
	})

	RecordStore.ensure_season_records(
		season,
		[],
		[active_player, added_player],
		false
	)
	var current_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(
			target_team_id,
			season.year,
			season.season_number
		)
	)
	var historical_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(target_team_id, 2198, 1)
	)
	RecordStore.load_from_dict(original_records)

	assert_array(current_ids).is_equal([active_player.id, added_player.id])
	assert_array(current_ids).not_contains([removed_player.id])
	assert_array(historical_ids).is_equal([active_player.id])


# 引退選手の最終シーズン成績が ensure_season_records の erase ループで消える回帰テスト
# (docs/agent_memory/project_record_store_data_protection.md の「引退選手の最終シーズン成績が
# 消える」節)。process_retirement で source_data["retired"]=true が立った後、同オフ内で
# ensure_season_records が再度回っても当季の成績が残ることを確認する。
func test_process_retirement_marks_final_season_record_without_erasing_stats() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var team_id: int = (GameDb.players[0] as PSPlayer).team_id
	var player: PSPlayer = PSPlayer.from_dict((GameDb.players[0] as PSPlayer).to_dict())
	player.team_id = team_id
	player.source_data.erase("retired")
	# 段階的強制引退は48歳で確率によらず必ず引退するため、_should_retire を決定的にする。
	player.age = 48

	var season: PSSeason = PSSeason.new()
	season.year = 2201
	season.season_number = 1

	var current_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, season.year, season.season_number)
	current_record.batter_stats.hits = 180
	var prior_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, season.year - 1, season.season_number)
	prior_record.batter_stats.hits = 165
	RecordStore.load_from_dict({
		"player_records": [current_record.to_dict(), prior_record.to_dict()],
		"team_records": [],
		"season_archives": [],
	})

	var players: Array = [player]
	var retirement_result: Dictionary = OffseasonService.process_retirement(players, season)
	# process_retirement と同じオフ内で、他ステップが呼ぶ ensure_season_records が再度走っても
	# 当季レコードが erase されないことを確認する (これがバグ本体の再現条件)。
	RecordStore.ensure_season_records(season, [], players, false)

	var kept_current: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
	var kept_prior: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year - 1, season.season_number)
	var default_team_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(team_id, season.year, season.season_number)
	)
	var including_retired_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(team_id, season.year, season.season_number, true)
	)
	RecordStore.load_from_dict(original_records)

	assert_int(int(retirement_result.get("retired_count", 0))).is_equal(1)
	assert_bool(player.is_retired()).is_true()
	assert_object(kept_current).is_not_null()
	assert_int(kept_current.batter_stats.hits).is_equal(180)
	assert_object(kept_prior).is_not_null()
	assert_int(kept_prior.batter_stats.hits).is_equal(165)
	assert_array(default_team_ids).not_contains([player.id])
	assert_array(including_retired_ids).contains([player.id])


# ensure_season_records 単体の erase 意図確認: 引退済み (source_data["retired"]=true) の選手は
# GameDb.players に残っている限り当季レコードを保持し、GameDb.players から完全に消えた選手は
# 当季レコードが erase される。非引退選手のレコード新規作成も併せて確認する。
func test_ensure_season_records_keeps_retired_record_but_erases_fully_removed_player() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var target_team_id: int = (GameDb.players[0] as PSPlayer).team_id
	var team_players: Array = []
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player.team_id == target_team_id and not player.is_retired():
			team_players.append(player)
			if team_players.size() == 3:
				break
	assert_int(team_players.size()).is_equal(3)
	var active_player: PSPlayer = team_players[0] as PSPlayer
	var fully_removed_player: PSPlayer = team_players[1] as PSPlayer
	var newly_added_player: PSPlayer = team_players[2] as PSPlayer

	var retired_player: PSPlayer = PSPlayer.from_dict(active_player.to_dict())
	retired_player.id = active_player.id + 1000000
	retired_player.team_id = target_team_id
	retired_player.source_data["retired"] = true

	var season: PSSeason = PSSeason.new()
	season.year = 2202
	season.season_number = 1
	var retired_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(retired_player, season.year, season.season_number)
	var fully_removed_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fully_removed_player, season.year, season.season_number)
	RecordStore.load_from_dict({
		"player_records": [retired_record.to_dict(), fully_removed_record.to_dict()],
		"team_records": [],
		"season_archives": [],
	})

	# fully_removed_player はあえて players 配列に含めない (GameDb.players から完全に消えた状態)。
	RecordStore.ensure_season_records(
		season,
		[],
		[retired_player, active_player, newly_added_player],
		false
	)
	var current_ids: Array = _player_record_ids(
		RecordStore.get_team_player_records(target_team_id, season.year, season.season_number, true)
	)
	RecordStore.load_from_dict(original_records)

	assert_array(current_ids).contains([retired_player.id])
	assert_array(current_ids).contains([active_player.id])
	assert_array(current_ids).contains([newly_added_player.id])
	assert_array(current_ids).not_contains([fully_removed_player.id])


# 実プレイでの再現条件を通した回帰テスト: 引退ステップが引退を確定してオートセーブし、
# その後セーブから再開する (RecordStore.load_records → ensure_season_records の実行順) と、
# 引退選手の最終シーズン成績が正規化テーブルから消えないことを見る。
func test_retired_player_final_season_stats_survive_offseason_save_reload() -> void:
	var old_state: Dictionary = _capture_app_state()
	var old_player_rows: Array = []
	for player_value in GameDb.players:
		old_player_rows.append((player_value as PSPlayer).to_dict())
	var test_save_id: String = ""
	var team: PSTeam = GameDb.teams[0] as PSTeam
	var target_player: PSPlayer = null
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player.team_id == team.id and not player.is_retired():
			target_player = player
			break
	assert_object(target_player).is_not_null()
	var target_player_id: int = target_player.id
	# 段階的強制引退は48歳で確率1.0(確実)になる。テストの引退判定を決定的にする。
	target_player.age = 48

	AppState.select_team(team.id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = true
	for game_value in AppState.current_season.schedule:
		(game_value as Dictionary)["played"] = true
	AppState.current_postseason = null
	AppState.current_awards = null

	var season: PSSeason = AppState.current_season
	var season_record: PSPlayerSeasonRecord = RecordStore.get_player_record(target_player_id, season.year, season.season_number)
	assert_object(season_record).is_not_null()
	season_record.batter_stats.hits = 180

	# start_offseason() はFA宣言ステップ、引退判定はその次のステップ。どちらも直後に
	# auto_save_enabled を見てオートセーブする。
	var result: Dictionary = AppState.start_offseason()
	assert_bool(bool(result.get("ok", false))).is_true()
	# FA宣言した選手は同オフ引退しない仕様なので、判定を決定的にするため宣言印を外してから進める。
	target_player.source_data.erase("fa_declared_year")
	var retirement_step: Dictionary = AppState.advance_offseason()
	assert_bool(bool(retirement_step.get("ok", false))).is_true()
	assert_str(AppState.offseason_step).is_equal(AppState.OFFSEASON_STEP_RETIREMENT)
	assert_bool(target_player.is_retired()).is_true()

	# オフシーズン中にセーブから再開する経路 (RecordStore.load_records → ensure_season_records) を再現する。
	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()

	var kept_record: PSPlayerSeasonRecord = RecordStore.get_player_record(target_player_id, season.year, season.season_number)
	assert_object(kept_record).is_not_null()
	assert_int(kept_record.batter_stats.hits).is_equal(180)

	GameDb.replace_players_from_rows(old_player_rows)
	_restore_app_state(old_state, test_save_id)


func test_start_offseason_archives_season_without_postseason() -> void:
	var old_state: Dictionary = _capture_app_state()
	var old_player_rows: Array = []
	for player_value in GameDb.players:
		old_player_rows.append((player_value as PSPlayer).to_dict())
	var test_save_id: String = ""
	var team: PSTeam = GameDb.teams[0] as PSTeam

	AppState.select_team(team.id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	for game_value in AppState.current_season.schedule:
		(game_value as Dictionary)["played"] = true
	AppState.current_postseason = null
	AppState.current_awards = PSAwards.new()
	AppState.current_awards.year = AppState.current_season.year
	AppState.current_awards.season_number = AppState.current_season.season_number

	var result: Dictionary = AppState.start_offseason()
	assert_bool(bool(result.get("ok", false))).is_true()
	var matching_archive: PSSeasonArchive = null
	for archive_value in RecordStore.get_season_archives():
		var archive: PSSeasonArchive = archive_value as PSSeasonArchive
		if archive.year == AppState.current_season.year and archive.season_number == AppState.current_season.season_number:
			matching_archive = archive
			break
	assert_object(matching_archive).is_not_null()
	assert_object(matching_archive.postseason).is_null()
	assert_object(matching_archive.awards).is_not_null()
	assert_int(matching_archive.standings.size()).is_equal(GameDb.teams.size())

	GameDb.replace_players_from_rows(old_player_rows)
	_restore_app_state(old_state, test_save_id)


func test_unsaved_simulation_does_not_persist_records_or_logs() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""
	var first_game_index: int = -1

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	first_game_index = _first_unplayed_game_index(AppState.current_season)
	assert_int(first_game_index).is_greater_equal(0)
	assert_int(_played_game_count(AppState.current_season)).is_equal(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(0)

	# 進行は本番と同じ「1日ぶん」の経路で行う (UI に1試合単位の進行は存在しない)。
	var result: Dictionary = AppState.simulate_current_day()
	assert_bool(bool(result.get("ok", false))).is_true()
	var played: int = _played_game_count(AppState.current_season)
	assert_int(played).is_greater(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(played * 2)
	var unsaved_game: Dictionary = AppState.current_season.schedule[first_game_index] as Dictionary
	var compact_result: Dictionary = unsaved_game.get("result", {}) as Dictionary
	assert_bool(compact_result.has("play_events")).is_false()
	assert_bool(unsaved_game.has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_true()
	assert_bool(GameLogService.read_available_game_log(AppState.current_season, first_game_index).is_empty()).is_false()
	var serialized_schedule: Array = AppState.current_season.to_dict().get("schedule", []) as Array
	assert_bool((serialized_schedule[first_game_index] as Dictionary).has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_false()
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	assert_int(_played_game_count(AppState.current_season)).is_equal(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(0)
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()

	_restore_app_state(old_state, test_save_id)


func test_manual_save_flushes_pending_game_logs() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""
	var first_game_index: int = -1

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	first_game_index = _first_unplayed_game_index(AppState.current_season)
	var result: Dictionary = AppState.simulate_current_day()
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_true()
	assert_bool(GameLogService.read_available_game_log(AppState.current_season, first_game_index).is_empty()).is_false()

	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool((AppState.current_season.schedule[first_game_index] as Dictionary).has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_false()
	var written_log: Dictionary = GameLogService.read_game_log(AppState.current_season, first_game_index)
	assert_bool(written_log.is_empty()).is_false()
	assert_int((written_log.get("innings", []) as Array).size()).is_greater(0)

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	var restored_played: int = _played_game_count(AppState.current_season)
	assert_int(restored_played).is_greater(0)
	assert_int(_recorded_team_games(AppState.current_season)).is_equal(restored_played * 2)
	assert_bool(GameLogService.read_game_log(AppState.current_season, first_game_index).is_empty()).is_false()

	_restore_app_state(old_state, test_save_id)


func test_auto_save_flushes_compact_game_log_and_clears_pending() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.auto_save_enabled = true
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()

	var first_game_index: int = _first_unplayed_game_index(AppState.current_season)
	var result: Dictionary = AppState.simulate_current_day()
	assert_bool(bool(result.get("ok", false))).is_true()

	var game: Dictionary = AppState.current_season.schedule[first_game_index] as Dictionary
	assert_bool((game.get("result", {}) as Dictionary).has("play_events")).is_false()
	assert_bool(game.has(PSSeason.TRANSIENT_GAME_LOG_KEY)).is_false()
	var written_log: Dictionary = GameLogService.read_game_log(AppState.current_season, first_game_index)
	assert_array(written_log.get("pa_log", []) as Array).is_not_empty()
	assert_bool(SaveService.is_state_current(AppState)).is_true()

	_restore_app_state(old_state, test_save_id)


func test_unsaved_next_season_progress_does_not_persist_records() -> void:
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	AppState.offseason_active = true
	AppState.offseason_step = AppState.OFFSEASON_STEP_RETIREMENT
	AppState.offseason_results = {AppState.OFFSEASON_STEP_RETIREMENT: {"title": "引退判定", "retired": []}}
	assert_bool(SaveService.save_state(AppState)).is_true()

	var saved_season_number: int = AppState.current_season.season_number
	AppState.offseason_step = AppState.OFFSEASON_STEP_CONTRACT_RENEWAL
	assert_bool(AppState.finalize_offseason()).is_true()
	var unsaved_season: PSSeason = AppState.current_season
	assert_int(unsaved_season.season_number).is_equal(saved_season_number + 1)
	assert_int(_record_count_for_season(unsaved_season.year, unsaved_season.season_number)).is_greater(0)

	var result: Dictionary = AppState.simulate_current_day()
	assert_bool(bool(result.get("ok", false))).is_true()
	var played: int = _played_game_count(unsaved_season)
	assert_int(played).is_greater(0)
	assert_int(_recorded_team_games(unsaved_season)).is_equal(played * 2)

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	assert_bool(AppState.offseason_active).is_true()
	assert_int(AppState.current_season.season_number).is_equal(saved_season_number)
	assert_int(_record_count_for_season(unsaved_season.year, unsaved_season.season_number)).is_equal(0)

	_restore_app_state(old_state, test_save_id)


func test_player_season_stats_round_trip_through_normalized_tables() -> void:
	# 選手個人成績が save_records → load_records (正規化テーブル経由) を往復できること。
	# ここが 0 で戻ると、再開後に出場実績ベースの判定が総崩れになり支配下が激減する。
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	var target: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			target = record
			break
	assert_object(target).is_not_null()
	target.batter_stats.games = 123
	target.batter_stats.hits = 145
	target.arsenal_snapshot = [{"type": "slider", "mastery": 1.25}]
	var target_id: int = target.player_id

	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	var reloaded: PSPlayerSeasonRecord = RecordStore.get_player_record(target_id, season.year, season.season_number)
	assert_object(reloaded).is_not_null()
	assert_int(reloaded.batter_stats.games).is_equal(123)
	assert_int(reloaded.batter_stats.hits).is_equal(145)
	assert_int(reloaded.arsenal_snapshot.size()).is_equal(1)
	assert_str(str((reloaded.arsenal_snapshot[0] as Dictionary).get("type", ""))).is_equal("slider")
	assert_float(float((reloaded.arsenal_snapshot[0] as Dictionary).get("mastery", 0.0))).is_equal(1.25)
	var indexed_ids: Array = _player_record_ids(RecordStore.get_team_player_records(
		reloaded.team_id,
		season.year,
		season.season_number
	))
	var wrong_team_ids: Array = _player_record_ids(RecordStore.get_team_player_records(
		reloaded.team_id + 1000,
		season.year,
		season.season_number
	))
	assert_int(indexed_ids.count(target_id)).is_equal(1)
	assert_array(wrong_team_ids).not_contains([target_id])

	_restore_app_state(old_state, test_save_id)


func test_player_game_history_appends_in_place_and_keeps_replacements_sorted() -> void:
	var season: PSSeason = PSSeason.new()
	var player_id: int = 42
	var first_row: Dictionary = {
		"game_index": 0,
		"day": 1,
		"label": "first",
		"batter": {"hits": 1},
	}
	season.append_player_game_log(player_id, first_row)
	var stored_history: Array = season.player_game_history.get(str(player_id), []) as Array
	(first_row.get("batter", {}) as Dictionary)["hits"] = 99

	season.append_player_game_log(player_id, {"game_index": 1, "day": 1, "label": "second"})
	season.append_player_game_log(player_id, {"game_index": 6, "day": 2, "label": "third"})
	assert_int(stored_history.size()).is_equal(3)
	assert_int(int(((stored_history[0] as Dictionary).get("batter", {}) as Dictionary).get("hits", 0))).is_equal(1)

	season.append_player_game_log(player_id, {"game_index": 6, "day": 2, "label": "third-replaced"})
	season.append_player_game_log(player_id, {"game_index": 0, "day": 1, "label": "first-replaced"})
	season.append_player_game_log(player_id, {"game_index": 4, "day": 1, "label": "inserted"})
	season.append_player_game_log(player_id, {"game_index": 1, "day": 3, "label": "second-moved"})

	var logs: Array = season.get_player_game_logs(player_id)
	var expected_days: Array = [1, 1, 2, 3]
	var expected_indices: Array = [0, 4, 6, 1]
	var expected_labels: Array = ["first-replaced", "inserted", "third-replaced", "second-moved"]
	assert_int(logs.size()).is_equal(expected_indices.size())
	assert_int(stored_history.size()).is_equal(expected_indices.size())
	for index in range(logs.size()):
		var row: Dictionary = logs[index] as Dictionary
		assert_int(int(row.get("day", 0))).is_equal(int(expected_days[index]))
		assert_int(int(row.get("game_index", -1))).is_equal(int(expected_indices[index]))
		assert_str(str(row.get("label", ""))).is_equal(str(expected_labels[index]))


func test_season_history_split_saves_incrementally_and_round_trips() -> void:
	# player_game_history / player_stat_history は game_state blob から分離し、
	# season_history テーブルへ日単位で増分永続化する。
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	var pid: int = (GameDb.players[0] as PSPlayer).id
	season.current_day = 2
	season.append_player_game_log(pid, {"game_index": 0, "day": 1, "batter": {"hits": 2}})
	season.append_player_game_log(pid, {"game_index": 6, "day": 2, "batter": {"hits": 1}})
	season.append_player_stat_snapshot(pid, 1, PSBatterStats.new(), PSPitcherStats.new())
	assert_bool(SaveService.save_state(AppState)).is_true()

	# blob 側に履歴が残らないこと (SQLite 利用時のみ分離される)
	if SQLiteStoreService.is_available():
		var raw_blob: Dictionary = SQLiteStoreService.load_game_state()
		var blob_season: Dictionary = raw_blob.get("season", {}) as Dictionary
		assert_bool(blob_season.has("player_game_history")).is_false()
		assert_bool(blob_season.has("player_stat_history")).is_false()

	# 日を進めて追記 → 増分セーブ → ロードで全日分が復元される。
	# from_dict は「current_day より前の未消化試合」があると current_day を巻き戻し、
	# 履歴の hydrate も current_day までに絞られるため、進めた日数分は消化済みにしておく。
	season.current_day = 3
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if int(game.get("day", 0)) < 3:
			game["played"] = true
	# 前回保存の最終日 (day 2) に後から増えた分も書き直される (書き込みを省くのは最終日より前だけ)。
	season.append_player_game_log(pid, {"game_index": 7, "day": 2, "batter": {"hits": 4}})
	season.append_player_game_log(pid, {"game_index": 12, "day": 3, "batter": {"hits": 3}})
	assert_bool(SaveService.save_state(AppState)).is_true()

	var reloaded: Dictionary = SaveService.load_state()
	assert_bool(AppState.restore_from_save(reloaded)).is_true()
	var logs: Array = AppState.current_season.get_player_game_logs(pid)
	assert_int(logs.size()).is_equal(4)
	assert_int(int((logs[0] as Dictionary).get("day", 0))).is_equal(1)
	assert_int(int((logs[2] as Dictionary).get("game_index", 0))).is_equal(7)
	assert_int(int(((logs[2] as Dictionary).get("batter", {}) as Dictionary).get("hits", 0))).is_equal(4)
	assert_int(int((logs[3] as Dictionary).get("day", 0))).is_equal(3)
	assert_int(int(((logs[3] as Dictionary).get("batter", {}) as Dictionary).get("hits", 0))).is_equal(3)
	var snapshots: Array = AppState.current_season.player_stat_history.get(str(pid), []) as Array
	assert_int(snapshots.size()).is_equal(1)
	assert_int(int((snapshots[0] as Dictionary).get("day", 0))).is_equal(1)

	_restore_app_state(old_state, test_save_id)


func test_team_lineup_history_round_trips_and_preserves_other_seasons() -> void:
	# team_lineup_history は season_history と違い年度・シーズンをまたいで永続する
	# (これが機能の要)。他年度の行を保存しても消えないこと、ロード時に slots_json が
	# 構造化された "slots" キーへ復元されることを検証する。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	var season: PSSeason = AppState.current_season

	var other_year: int = season.year - 5
	var other_row: Dictionary = {
		"team_id": 1, "game_index": 0, "day": 1, "date": "2020-04-01",
		"opponent_id": 2, "home_away": "home", "result": GameSimulator.GAME_RESULT_WIN,
		"score_for": 5, "score_against": 2, "starter_pitcher_id": 901, "dh": false,
		"slots": [{"slot": 1, "pos": 8, "pid": 101}, {"slot": 9, "pos": 1, "pid": 901}],
	}
	assert_bool(SQLiteStoreService.save_team_lineup_history(other_year, 1, [other_row], 1)).is_true()

	var current_row: Dictionary = {
		"team_id": 1, "game_index": 0, "day": 1, "date": "2026-04-01",
		"opponent_id": 2, "home_away": "away", "result": GameSimulator.GAME_RESULT_LOSS,
		"score_for": 2, "score_against": 5, "starter_pitcher_id": 902, "dh": true,
		"slots": [
			{"slot": 1, "pos": 8, "pid": 201}, {"slot": 2, "pos": 4, "pid": 202},
			{"slot": 3, "pos": 10, "pid": 203},
		],
	}
	assert_bool(SQLiteStoreService.save_team_lineup_history(season.year, season.season_number, [current_row], season.current_day)).is_true()

	# 他年度の行はそのまま残る (season_history のような他年度 DELETE は行わない)。
	var other_loaded: Array = SQLiteStoreService.load_team_lineup_history(other_year, 1)
	assert_int(other_loaded.size()).is_equal(1)
	var other_slots: Array = (other_loaded[0] as Dictionary).get("slots", []) as Array
	assert_int(other_slots.size()).is_equal(2)
	assert_int(int((other_slots[0] as Dictionary).get("pid", 0))).is_equal(101)

	# 当季の行も往復し、slots が構造化された配列として復元される。
	var current_loaded: Array = SQLiteStoreService.load_team_lineup_history(season.year, season.season_number, 1)
	assert_int(current_loaded.size()).is_equal(1)
	var loaded_row: Dictionary = current_loaded[0] as Dictionary
	assert_int(int(loaded_row.get("starter_pitcher_id", 0))).is_equal(902)
	assert_bool(bool(loaded_row.get("dh", false))).is_true()
	var loaded_slots: Array = loaded_row.get("slots", []) as Array
	assert_int(loaded_slots.size()).is_equal(3)
	assert_int(int((loaded_slots[2] as Dictionary).get("pos", 0))).is_equal(10)

	# list_lineup_history_seasons に両年度が現れる。
	var seasons: Array = SQLiteStoreService.list_lineup_history_seasons()
	var found_other: bool = false
	var found_current: bool = false
	for row_value in seasons:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("year", 0)) == other_year and int(row.get("season_number", 0)) == 1:
			found_other = true
		if int(row.get("year", 0)) == season.year and int(row.get("season_number", 0)) == season.season_number:
			found_current = true
	assert_bool(found_other).is_true()
	assert_bool(found_current).is_true()

	# 巻き戻し防御: current_day より未来の行は次回保存で消える。
	var future_row: Dictionary = current_row.duplicate(true)
	future_row["game_index"] = 1
	future_row["day"] = 99
	assert_bool(SQLiteStoreService.save_team_lineup_history(season.year, season.season_number, [future_row], season.current_day)).is_true()
	assert_int(SQLiteStoreService.load_team_lineup_history(season.year, season.season_number, 1).size()).is_equal(2)
	assert_bool(SQLiteStoreService.save_team_lineup_history(season.year, season.season_number, [], season.current_day)).is_true()
	assert_int(SQLiteStoreService.load_team_lineup_history(season.year, season.season_number, 1).size()).is_equal(1)

	_restore_app_state(old_state, test_save_id)


func test_record_store_writes_only_changed_tables() -> void:
	# 内容が変わった選手でも、書き込むのは中身が変わったテーブル (本体行 / 一軍・二軍の打撃・投手成績) だけ。
	# 書かなかったテーブルも DB 上は前回の内容のままなので、読み直すと全部揃っている。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	var season: PSSeason = AppState.current_season

	var target: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			target = record
			break
	assert_object(target).is_not_null()
	# start_new_season の初回セーブで全テーブルを書き、テーブルごとの内容を覚えている。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(0)

	target.farm_batter_stats.hits = 5
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)

	target.fatigue = 37
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)

	target.batter_stats.hits = 9
	target.fatigue = 12
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(2)

	# 本体行の JSON 列 (能力スナップショット) だけが変わっても書くのは本体行 1 テーブルで、読み直すと今の値。
	assert_bool(target.z_abilities_snapshot.is_empty()).is_false()
	var z_key: String = str(target.z_abilities_snapshot.keys()[0])
	target.z_abilities_snapshot[z_key] = 2.25
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(1)

	# 本体行の中でも、書き直すのは変わった列グループだけ (疲労だけ → スカラー / 詳細成績も → 2 グループ)。
	# 書かなかった列 (直前に書いた能力スナップショット) は DB 上でそのまま残る。
	target.fatigue = 11
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(1)
	target.fatigue = 12
	target.advanced_stats.plate_appearances = 41
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(2)
	target.farm_advanced_stats.plate_appearances = 17
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(1)

	# 列グループで書いてきた行は、同じレコードを全列で書き直した行と一致する。
	var player_id: int = target.player_id
	var row_sql: String = "SELECT * FROM player_season_records WHERE player_id = ? AND year = ? AND season_number = ?"
	var row_bindings: Array = [player_id, season.year, season.season_number]
	var db: Object = SQLiteStoreService._open_runtime_db()
	var grouped_rows: Array = SQLiteStoreService._select_with_bindings(db, row_sql, row_bindings).duplicate(true)
	assert_bool(SQLiteStoreService._upsert_player_season_record(db, target.to_dict())).is_true()
	var full_rows: Array = SQLiteStoreService._select_with_bindings(db, row_sql, row_bindings).duplicate(true)
	SQLiteStoreService._close(db)
	assert_int(grouped_rows.size()).is_equal(1)
	assert_str(JSON.stringify(grouped_rows, "", true, true)).is_equal(JSON.stringify(full_rows, "", true, true))

	RecordStore.load_records()
	var reloaded: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, season.year, season.season_number)
	assert_object(reloaded).is_not_null()
	assert_int(reloaded.farm_batter_stats.hits).is_equal(5)
	assert_int(reloaded.fatigue).is_equal(12)
	assert_int(reloaded.batter_stats.hits).is_equal(9)
	assert_float(float(reloaded.z_abilities_snapshot.get(z_key, 0.0))).is_equal(2.25)
	assert_int(reloaded.advanced_stats.plate_appearances).is_equal(41)
	assert_int(reloaded.farm_advanced_stats.plate_appearances).is_equal(17)

	# ロード直後はテーブルごとの内容を覚えていないので、変わった選手は本体行の全列と全テーブルを書いてから覚える。
	reloaded.fatigue = 13
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1 + SQLiteStoreService.RECORD_STATS_KEYS.size())
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(SQLiteStoreService.BODY_PART_COUNT)
	reloaded.fatigue = 14
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_table_write_count).is_equal(1)
	assert_int(SQLiteStoreService.last_record_body_group_write_count).is_equal(1)

	_restore_app_state(old_state, test_save_id)


func test_player_season_body_groups_cover_every_column_once() -> void:
	# 本体行の列グループ (スカラー + BODY_JSON_GROUPS) と主キーで PLAYER_SEASON_COLUMNS をちょうど 1 回ずつ覆う。
	# 漏れた列は列グループの UPDATE で書かれなくなり、重なった列は 2 回書かれる。
	assert_int(SQLiteStoreService.BODY_PART_COUNT).is_equal(1 + SQLiteStoreService.BODY_JSON_GROUPS.size())
	var covered: Array = []
	covered.append_array(SQLiteStoreService.PLAYER_SEASON_KEY_COLUMNS)
	covered.append_array(SQLiteStoreService._body_scalar_columns())
	for group_index in range(SQLiteStoreService.BODY_JSON_GROUPS.size()):
		covered.append_array(SQLiteStoreService._json_group_columns(group_index))
	var expected: Array = SQLiteStoreService.PLAYER_SEASON_COLUMNS.duplicate()
	covered.sort()
	expected.sort()
	assert_array(covered).is_equal(expected)
	# JSON グループのキーは to_dict のキーで、スカラー側に同名の列が残らない。
	var record_keys: Array = PSPlayerSeasonRecord.new().to_dict().keys()
	for group_value in SQLiteStoreService.BODY_JSON_GROUPS:
		for key_value in group_value as Array:
			assert_bool(record_keys.has(key_value)).is_true()


func test_record_store_saves_only_changed_rows() -> void:
	# save_records はレコード内容のフィンガープリントで変更行だけを upsert する。
	# 過去年度の不変レコードや、日送り時の二重 save_records 呼び出しの2回目が
	# 全行書き込みにならないことの検証。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	var test_save_id: String = ""

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	test_save_id = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	var season: PSSeason = AppState.current_season
	# start_new_season 内の初回セーブで全行書き込み+キャッシュ確立済み。
	# 以後、変更なしの再セーブは 0 行になる。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(0)

	# 1 レコードだけ変更 → 書き込み 1 行
	var target: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			target = record
			break
	assert_object(target).is_not_null()
	target.batter_stats.hits = 77
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(1)

	# ロード直後 (フィンガープリントのシード後) の無変更セーブも 0 行
	RecordStore.load_records()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_record_upsert_count).is_equal(0)

	# メモリから消えたレコードは save で DB からも消える
	var removed_id: int = target.player_id
	RecordStore.erase_player_record(removed_id, season.year, season.season_number)
	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	assert_object(RecordStore.get_player_record(removed_id, season.year, season.season_number)).is_null()

	_restore_app_state(old_state, test_save_id)


func test_record_store_skips_serializing_unchanged_past_season_records() -> void:
	# 保存のたびに全レコードを to_dict + ハッシュするのをやめ、当季と印を付けたレコードだけを
	# 書き直す。過去シーズンのレコードは辞書化されないが、DB からも消えない。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	var season: PSSeason = AppState.current_season

	var current: PSPlayerSeasonRecord = null
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == season.year and record.season_number == season.season_number and not record.is_pitcher():
			current = record
			break
	assert_object(current).is_not_null()

	# 同じ選手の「前年」レコードを作る (過去シーズン側の代表)。
	var past_dict: Dictionary = current.to_dict()
	past_dict["year"] = season.year - 1
	var past: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(past_dict)
	past.batter_stats.hits = 100
	assert_bool(RecordStore.set_player_record(past)).is_true()
	assert_bool(SaveService.save_state(AppState)).is_true()

	# 保存後: 当季は常に書き直す対象、過去シーズンは対象外。
	assert_bool(RecordStore.is_record_persist_dirty(current)).is_true()
	assert_bool(RecordStore.is_record_persist_dirty(past)).is_false()

	# 印を付けずに過去シーズンを書き換えると保存されない。監査はその取りこぼしを検出する。
	past.batter_stats.hits = 200
	assert_array(RecordStore.audit_persist_tracking()).contains(
		["%d:%d:%d" % [past.player_id, past.year, past.season_number]]
	)
	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	var reloaded_past: PSPlayerSeasonRecord = RecordStore.get_player_record(
		past.player_id, season.year - 1, past.season_number
	)
	# 過去シーズンのレコードは (書き直されなくても) DB から消えない。
	assert_object(reloaded_past).is_not_null()
	assert_int(reloaded_past.batter_stats.hits).is_equal(100)

	# 印を付ければ書き直される。ロード直後は全件書き込みなので、1 回保存して印を消してから
	# 印の有無が効いていることを見る (でないと「ロードのせいで書かれた」を通してしまう)。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(RecordStore.is_record_persist_dirty(reloaded_past)).is_false()
	reloaded_past.batter_stats.hits = 200
	RecordStore.mark_record_dirty(reloaded_past)
	assert_bool(RecordStore.is_record_persist_dirty(reloaded_past)).is_true()
	assert_bool(SaveService.save_state(AppState)).is_true()
	RecordStore.load_records()
	assert_int(RecordStore.get_player_record(
		past.player_id, season.year - 1, past.season_number
	).batter_stats.hits).is_equal(200)
	assert_array(RecordStore.audit_persist_tracking()).is_empty()

	_restore_app_state(old_state, test_save_id)


func test_record_store_falls_back_to_full_persist_on_load_season_change_and_interval() -> void:
	# 変更点追跡が当てにならない場面の安全弁: ロード直後・シーズンの切り替わり・
	# FULL_PERSIST_SAVE_INTERVAL 回ごとは、印に関係なく全レコードを書き直す対象に戻す。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	var season: PSSeason = AppState.current_season

	var past_dict: Dictionary = (RecordStore.player_records.values()[0] as PSPlayerSeasonRecord).to_dict()
	past_dict["year"] = season.year - 1
	var past: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(past_dict)
	assert_bool(RecordStore.set_player_record(past)).is_true()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(RecordStore.is_record_persist_dirty(past)).is_false()

	# ロード直後はセッション最初の保存だけ全件を書き直す。
	RecordStore.load_records()
	var loaded_past: PSPlayerSeasonRecord = RecordStore.get_player_record(
		past.player_id, season.year - 1, past.season_number
	)
	assert_bool(RecordStore.is_record_persist_dirty(loaded_past)).is_true()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(RecordStore.is_record_persist_dirty(loaded_past)).is_false()

	# N 回ごとの全件照合。
	RecordStore._saves_since_full_persist = RecordStore.FULL_PERSIST_SAVE_INTERVAL - 1
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(RecordStore._saves_since_full_persist).is_equal(0)

	# 当季が変わったら、前のシーズンのレコードが「過去」側へ移る前に一度全件を書き直す。
	# 本番でこれを呼ぶのは ensure_season_records で、当季の判定が効いていることは
	# 上の is_record_persist_dirty(current)=true 側で見ている
	# (ここで合成シーズンを ensure_season_records に渡すと、基準分布の static キャッシュが
	# 空の母集団で作り直されて後続 suite を汚すため直接呼ぶ)。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(RecordStore.is_record_persist_dirty(loaded_past)).is_false()
	RecordStore._set_live_season(season.year + 1, season.season_number + 1)
	assert_bool(RecordStore.is_record_persist_dirty(loaded_past)).is_true()

	_restore_app_state(old_state, test_save_id)


func test_players_are_saved_as_rows_and_only_changed_players_are_written() -> void:
	# 選手は game_state blob に入れず players テーブルへ1人1行で置き、内容が変わった選手の行だけを書く。
	# 読み直すと GameDb.players と同じ並び (乱数を使う処理の反復順) で戻る。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	var old_player_rows: Array = SaveService._players_to_dicts()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false

	# start_new_season の保存で全員を書き終えているので、変更が無ければ 0 行。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(0)
	assert_bool(SQLiteStoreService.load_game_state().has("players")).is_false()

	var target: PSPlayer = GameDb.players[5] as PSPlayer
	var target_id: int = target.id
	target.salary += 123
	var expected_salary: int = target.salary
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(1)

	var expected_ids: Array = []
	for player_value in GameDb.players:
		expected_ids.append((player_value as PSPlayer).id)
	assert_bool(AppState.restore_from_save(SaveService.load_state())).is_true()
	var loaded_ids: Array = []
	var loaded_hashes: Array = []
	for player_value in GameDb.players:
		loaded_ids.append((player_value as PSPlayer).id)
		loaded_hashes.append((player_value as PSPlayer).to_dict().hash())
	assert_array(loaded_ids).is_equal(expected_ids)
	assert_int(GameDb.get_player(target_id).salary).is_equal(expected_salary)

	# ロード直後は読み込んだ内容が基準なので、何も変えずに保存すれば 0 行。読み直しても同じ内容。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(0)
	assert_bool(AppState.restore_from_save(SaveService.load_state())).is_true()
	var reloaded_hashes: Array = []
	for player_value in GameDb.players:
		reloaded_hashes.append((player_value as PSPlayer).to_dict().hash())
	assert_array(reloaded_hashes).is_equal(loaded_hashes)

	# 並びが変わった選手は内容が同じでも書き直す (読み込み順を保つ)。
	var moved: PSPlayer = GameDb.players[0] as PSPlayer
	GameDb.players.remove_at(0)
	GameDb.players.append(moved)
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(GameDb.players.size())

	GameDb.replace_players_from_rows(old_player_rows)
	_restore_app_state(old_state, test_save_id)


func test_retired_players_are_skipped_in_season_and_checked_on_safety_triggers() -> void:
	# 引退状態で保存済みの選手はシーズン中の保存で照合を飛ばす (年数とともに増えても保存が重くならない)。
	# 引退扱いから契約で戻るのはオフだけなので、オフ・丸ごと入れ替え・一定回数ごとには全員を照合する。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	var old_player_rows: Array = SaveService._players_to_dicts()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	var retired: PSPlayer = GameDb.players[10] as PSPlayer
	retired.source_data["retired"] = true
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(1)
	assert_array(SQLiteStoreService.audit_frozen_players(GameDb.players)).is_empty()

	# シーズン中: 引退選手を書き換えても照合しないので書かれず、監査がその食い違いを検出する。
	retired.source_data["retired_age"] = 40
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(0)
	assert_array(SQLiteStoreService.audit_frozen_players(GameDb.players)).contains([retired.id])

	# オフの保存は全員を照合する。
	AppState.offseason_active = true
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(1)
	assert_array(SQLiteStoreService.audit_frozen_players(GameDb.players)).is_empty()
	AppState.offseason_active = false

	# GameDb.players の丸ごと入れ替え後も全員を照合する。
	retired.source_data["retired_age"] = 41
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(0)
	GameDb.players_generation += 1
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(1)

	# 一定回数ごとの全員照合。
	retired.source_data["retired_age"] = 42
	SaveService._player_saves_since_full_check = SaveService.PLAYER_FULL_CHECK_SAVE_INTERVAL - 1
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_int(SQLiteStoreService.last_player_write_count).is_equal(1)

	GameDb.replace_players_from_rows(old_player_rows)
	_restore_app_state(old_state, test_save_id)


func test_in_season_days_do_not_modify_retired_players() -> void:
	# 上の「シーズン中は引退選手を照合しない」が成り立つ前提の確認。週次の入替・トレードを含む日送りで、
	# 引退扱いの選手 (引退済み / 戦力外市場の未契約者) の内容が変わらないこと。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	var old_player_rows: Array = SaveService._players_to_dicts()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	var season: PSSeason = AppState.current_season

	var next_id: int = 0
	for player_value in GameDb.players:
		next_id = max(next_id, (player_value as PSPlayer).id)
	for index in range(20):
		var row: Dictionary = (GameDb.players[index * 7] as PSPlayer).to_dict()
		next_id += 1
		row["id"] = next_id
		row["team_id"] = 0
		var retired: PSPlayer = PSPlayer.from_dict(row)
		retired.source_data["retired"] = true
		if index % 2 == 0:
			retired.source_data["released"] = true
		GameDb.players.append(retired)
	GameDb.rebuild_player_indices()
	assert_bool(SaveService.save_state(AppState)).is_true()

	var auto_swap_ctx: Dictionary = AppState._build_auto_swap_ctx(true)
	for day_index in range(8):
		var result: Dictionary = GameSimulator.simulate_current_day(season, false, auto_swap_ctx)
		assert_bool(bool(result.get("ok", false))).is_true()
	assert_array(SQLiteStoreService.audit_frozen_players(GameDb.players)).is_empty()

	GameDb.replace_players_from_rows(old_player_rows)
	_restore_app_state(old_state, test_save_id)


func test_load_state_rejects_save_without_player_rows() -> void:
	# 選手の行が無いセーブを読むと、GameDb が同梱の初期選手のまま進んでしまう。読めないセーブとして扱う。
	if not SQLiteStoreService.is_available():
		return
	var old_state: Dictionary = _capture_app_state()
	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.auto_save_enabled = false
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(SaveService.load_state().is_empty()).is_false()

	var db: Object = SQLiteStoreService._open_runtime_db()
	assert_bool(SQLiteStoreService._execute(db, "DELETE FROM players")).is_true()
	SQLiteStoreService._close(db)
	assert_bool(SaveService.load_state().is_empty()).is_true()

	SQLiteStoreService.reset_player_fingerprints()
	_restore_app_state(old_state, test_save_id)


func test_save_state_rebuilds_schema_when_runtime_db_recreated_at_same_path() -> void:
	# スキーマ構築はプロセス内で1回に間引かれるが、キャッシュがパスだけを見ていると
	# 「セーブを消して同じ save_id で作り直した」ときに空 DB へスキーマを張らず、
	# 以後の保存が "no such table" で SQLite 経路から落ちる。ファイルの有無も見て張り直す。
	var old_state: Dictionary = _capture_app_state()

	AppState.select_team((GameDb.teams[0] as PSTeam).id)
	AppState.auto_save_enabled = false
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(SQLiteStoreService.load_game_state().is_empty()).is_false()

	# DB ファイルだけを消す (= 同一パスに空 DB が作り直される状況)。
	var db_path: String = SQLiteStoreService.runtime_db_path()
	assert_str(db_path).is_not_empty()
	assert_int(DirAccess.remove_absolute(ProjectSettings.globalize_path(db_path))).is_equal(OK)
	assert_bool(SQLiteStoreService.runtime_db_file_exists()).is_false()

	# 保存が SQLite 経路のまま成立する (JSON fallback ではなく DB から読み戻せる)。
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(SQLiteStoreService.load_game_state().is_empty()).is_false()

	_restore_app_state(old_state, test_save_id)


func test_save_selection_list_load_delete() -> void:
	# セーブ選択機能: list_saves のメタ情報 / load_save でのアクティブ切替ロード /
	# delete_save での個別削除 (save_select 画面のバックエンド)。
	var old_state: Dictionary = _capture_app_state()

	var first_team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(first_team.id)
	AppState.start_new_season()
	var first_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()

	var second_team: PSTeam = GameDb.teams[1] as PSTeam
	AppState.select_team(second_team.id)
	AppState.start_new_season()
	var second_id: String = SaveContext.active_save_id()
	AppState.auto_save_enabled = false
	assert_bool(SaveService.save_state(AppState)).is_true()
	assert_bool(second_id != first_id).is_true()

	# 一覧: 両方が現れ、アクティブは2つ目、メタに球団名・年目が入る
	var ids: Array = []
	var first_meta: Dictionary = {}
	for row_value in SaveService.list_saves():
		var row: Dictionary = row_value as Dictionary
		var row_id: String = str(row.get("save_id", ""))
		ids.append(row_id)
		if row_id == first_id:
			first_meta = row
	assert_bool(ids.has(first_id)).is_true()
	assert_bool(ids.has(second_id)).is_true()
	assert_bool(bool(first_meta.get("is_active", true))).is_false()
	assert_str(str(first_meta.get("team_name", ""))).is_equal(first_team.name)
	assert_int(int(first_meta.get("season_number", 0))).is_equal(1)
	# 保存時のアプリ版数が記録される (セーブ一覧の「別バージョン」注意表示と不具合報告用。
	# ロード時の互換分岐には使わない)。
	assert_str(str(first_meta.get("app_version", ""))).is_equal(AppVersion.current())

	# 1つ目を選択ロード → アクティブが切り替わり、選択球団も復元される
	var payload: Dictionary = SaveService.load_save(first_id)
	assert_bool(payload.is_empty()).is_false()
	assert_bool(AppState.restore_from_save(payload)).is_true()
	assert_str(SaveContext.active_save_id()).is_equal(first_id)
	assert_int(AppState.selected_team_id).is_equal(first_team.id)

	# 2つ目 (非アクティブ) を削除 → 一覧から消え、アクティブは変わらない
	assert_bool(SaveService.delete_save(second_id)).is_true()
	var ids_after: Array = []
	for row_value in SaveService.list_saves():
		ids_after.append(str((row_value as Dictionary).get("save_id", "")))
	assert_bool(ids_after.has(second_id)).is_false()
	assert_str(SaveContext.active_save_id()).is_equal(first_id)

	# アクティブなセーブの削除はアクティブ参照もクリアする
	assert_bool(SaveService.delete_save(first_id)).is_true()
	assert_bool(SaveContext.has_active_save()).is_false()

	_restore_app_state(old_state, "")


func _capture_app_state() -> Dictionary:
	var team_runtime: Dictionary = {}
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		team_runtime[team.id] = {
			"funds": team.funds,
			"previous_rank": team.previous_rank,
			"auto_lineup": team.auto_lineup,
		}
	return {
		"selected_team_id": AppState.selected_team_id,
		"current_season": AppState.current_season,
		"current_screen": AppState.current_screen,
		"auto_save_enabled": AppState.auto_save_enabled,
		"offseason_step": AppState.offseason_step,
		"offseason_results": AppState.offseason_results.duplicate(true),
		"draft_state": AppState.draft_state.duplicate(true),
		"released_market_state": AppState.released_market_state.duplicate(true),
		"geneki_draft_state": AppState.geneki_draft_state.duplicate(true),
		"fa_state": AppState.fa_state.duplicate(true),
		"foreign_state": AppState.foreign_state.duplicate(true),
		"camp_state": AppState.camp_state.duplicate(true),
		"contract_years_state": AppState.contract_years_state.duplicate(true),
		"offseason_active": AppState.offseason_active,
		"postseason_active": AppState.postseason_active,
		"current_postseason": AppState.current_postseason,
		"current_awards": AppState.current_awards,
		"team_runtime": team_runtime,
		"active_save_id": SaveContext.active_save_id(),
		"records": RecordStore.to_dict().duplicate(true),
	}


func _restore_app_state(old_state: Dictionary, test_save_id: String) -> void:
	if not test_save_id.is_empty() and SaveContext.active_save_id() == test_save_id:
		SaveContext.delete_current_save_data()
	AppState.selected_team_id = int(old_state.get("selected_team_id", 0))
	AppState.current_season = old_state.get("current_season", null) as PSSeason
	AppState.current_screen = str(old_state.get("current_screen", "start"))
	AppState.auto_save_enabled = bool(old_state.get("auto_save_enabled", false))
	AppState.offseason_step = str(old_state.get("offseason_step", AppState.OFFSEASON_STEP_RETIREMENT))
	AppState.offseason_results = (old_state.get("offseason_results", {}) as Dictionary).duplicate(true)
	AppState.draft_state = (old_state.get("draft_state", {}) as Dictionary).duplicate(true)
	AppState.released_market_state = (old_state.get("released_market_state", {}) as Dictionary).duplicate(true)
	AppState.geneki_draft_state = (old_state.get("geneki_draft_state", {}) as Dictionary).duplicate(true)
	AppState.fa_state = (old_state.get("fa_state", {}) as Dictionary).duplicate(true)
	AppState.foreign_state = (old_state.get("foreign_state", {}) as Dictionary).duplicate(true)
	AppState.camp_state = (old_state.get("camp_state", {}) as Dictionary).duplicate(true)
	AppState.contract_years_state = (old_state.get("contract_years_state", {}) as Dictionary).duplicate(true)
	AppState.offseason_active = bool(old_state.get("offseason_active", false))
	AppState.postseason_active = bool(old_state.get("postseason_active", false))
	AppState.current_postseason = old_state.get("current_postseason", null) as PSPostseasonResult
	AppState.current_awards = old_state.get("current_awards", null) as PSAwards
	var team_runtime: Dictionary = old_state.get("team_runtime", {}) as Dictionary
	for team_key in team_runtime.keys():
		var team: PSTeam = GameDb.get_team(int(team_key))
		var runtime: Dictionary = team_runtime[team_key] as Dictionary
		if team != null:
			team.funds = int(runtime.get("funds", team.funds))
			team.previous_rank = int(runtime.get("previous_rank", team.previous_rank))
			team.auto_lineup = bool(runtime.get("auto_lineup", team.auto_lineup))
	RecordStore.load_from_dict(old_state.get("records", {}) as Dictionary)
	var old_save_id: String = str(old_state.get("active_save_id", ""))
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


func _first_unplayed_game_index(season: PSSeason) -> int:
	for index in range(season.schedule.size()):
		var game: Dictionary = season.schedule[index] as Dictionary
		if not bool(game.get("played", false)):
			return index
	return -1


func _played_game_count(season: PSSeason) -> int:
	var count: int = 0
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("played", false)):
			count += 1
	return count


func _recorded_team_games(season: PSSeason) -> int:
	var count: int = 0
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		var record: PSTeamSeasonRecord = RecordStore.get_team_record(team.id, season.year, season.season_number)
		if record != null:
			count += record.stats.games
	return count


func _record_count_for_season(year: int, season_number: int) -> int:
	var count: int = 0
	for record_value in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.year == year and record.season_number == season_number:
			count += 1
	for record_value in RecordStore.team_records.values():
		var record: PSTeamSeasonRecord = record_value as PSTeamSeasonRecord
		if record.year == year and record.season_number == season_number:
			count += 1
	return count


func _player_record_ids(records: Array) -> Array:
	var ids: Array = []
	for record_value in records:
		ids.append((record_value as PSPlayerSeasonRecord).player_id)
	return ids
