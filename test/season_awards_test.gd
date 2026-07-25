extends GdUnitTestSuite

# 表彰 (AwardsService / PSAwards) の回帰検証。ベストナイン・ゴールデングラブの選出構造と
# 直列化を確認する。打撃/投手タイトルや MVP は awards_screen 経由で startup_test が担う。

const GameSimulator = preload("res://services/simulation/game_simulator.gd")
const SaveContext = preload("res://services/storage/save_context.gd")


func test_awards_serialization_roundtrip() -> void:
	var awards: PSAwards = PSAwards.new()
	awards.year = 2030
	awards.season_number = 5
	awards.best_nine = {
		"central": [{"pid": 11, "value": "1.001"}, {"pid": 0, "value": ""}],
		"pacific": [{"pid": 22, "value": ".950"}],
	}
	awards.golden_glove = {
		"central": [{"pid": 33, "value": "+4.2"}],
		"pacific": [{"pid": 44, "value": "-1.0"}],
	}
	var restored: PSAwards = PSAwards.from_dict(awards.to_dict())
	assert_int(int((restored.best_nine["central"][0] as Dictionary).get("pid", 0))).is_equal(11)
	assert_str(str((restored.best_nine["central"][0] as Dictionary).get("value", ""))).is_equal("1.001")
	assert_str(str((restored.best_nine["pacific"][0] as Dictionary).get("value", ""))).is_equal(".950")
	assert_str(str((restored.golden_glove["central"][0] as Dictionary).get("value", ""))).is_equal("+4.2")
	assert_int(int((restored.golden_glove["pacific"][0] as Dictionary).get("pid", 0))).is_equal(44)


func test_calculate_populates_best_nine_and_golden_glove() -> void:
	var old_team_id: int = AppState.selected_team_id
	var old_season: PSSeason = AppState.current_season
	var old_dh: Dictionary = AppState.league_dh_enabled.duplicate(true)
	var old_save_id: String = SaveContext.active_save_id()

	var team: PSTeam = GameDb.teams[0] as PSTeam
	AppState.select_team(team.id)
	AppState.start_new_season()
	var test_save_id: String = SaveContext.active_save_id()

	# 20日分消化して規定到達者を作る (advanced_stats が RecordStore に蓄積される)。
	GameSimulator.simulate_days(AppState.current_season, 20, false)

	# DH は第1リーグ有効・第2リーグ無効にして、DH 枠がリーグ設定に従うことを検証する。
	AppState.league_dh_enabled["central"] = true
	AppState.league_dh_enabled["pacific"] = false

	var awards: PSAwards = AwardsService.calculate(AppState.current_season, GameDb.teams)
	var year: int = AppState.current_season.year
	var season_number: int = AppState.current_season.season_number

	for league_key in ["central", "pacific"]:
		assert_bool(awards.best_nine.has(league_key)).is_true()
		assert_bool(awards.golden_glove.has(league_key)).is_true()
		assert_int((awards.best_nine[league_key] as Array).size()).is_equal(PSAwards.BEST_NINE_SLOT_POSITIONS.size())
		assert_int((awards.golden_glove[league_key] as Array).size()).is_equal(PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS.size())

	# DH 無効リーグの DH 枠 (最終スロット) は必ず空。
	var pacific_bn: Array = awards.best_nine["pacific"] as Array
	assert_int(int((pacific_bn[pacific_bn.size() - 1] as Dictionary).get("pid", 0))).is_equal(0)

	# 役割整合: 投手枠は投手、捕手枠 (埋まっていれば) は野手。
	_assert_slot_role(awards.best_nine["central"] as Array, 0, true, year, season_number)
	_assert_slot_role(awards.golden_glove["central"] as Array, 0, true, year, season_number)
	_assert_slot_role(awards.best_nine["central"] as Array, 1, false, year, season_number)
	_assert_slot_role(awards.golden_glove["pacific"] as Array, 1, false, year, season_number)

	# 少なくとも一方のリーグでベストナイン守備位置枠がいくつか埋まっている (集計経路の健全性)。
	var filled: int = 0
	for cell_value in (awards.best_nine["central"] as Array):
		if int((cell_value as Dictionary).get("pid", 0)) > 0:
			filled += 1
	assert_int(filled).is_greater(0)

	AppState.league_dh_enabled = old_dh
	AppState.selected_team_id = old_team_id
	AppState.current_season = old_season
	if not test_save_id.is_empty() and test_save_id != old_save_id:
		SaveContext.delete_current_save_data()
	if old_save_id.is_empty():
		SaveContext.clear_active_save()
	else:
		SaveContext.activate_save_id(old_save_id)


# 新人王は外国人選手を除外する。強打の外国人新人と控えめな国内新人を並べ、国内選手が選ばれることを確認。
func test_rookie_excludes_foreign_players() -> void:
	var foreign_rookie: PSPlayerSeasonRecord = _make_rookie_batter(901, 0.400, 200, true)
	var domestic_rookie: PSPlayerSeasonRecord = _make_rookie_batter(902, 0.330, 120, false)
	var picked: int = AwardsService._pick_rookie([foreign_rookie, domestic_rookie], {})
	assert_int(picked).is_equal(902)

	# 国内新人がいなければ外国人が勝っていても該当なし(0)になる。
	var only_foreign: int = AwardsService._pick_rookie([foreign_rookie], {})
	assert_int(only_foreign).is_equal(0)


func _make_rookie_batter(pid: int, woba: float, pa: int, foreign: bool) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = pid
	record.name = "R%d" % pid
	record.years = 1
	record.foreign_player = foreign
	record.position = 7
	record.role = "fielder"
	record.batter_stats.plate_appearances = pa
	record.batter_stats.at_bats = pa
	record.advanced_stats.player_id = pid
	record.advanced_stats.plate_appearances = pa
	record.advanced_stats.woba_denominator = pa
	record.advanced_stats.woba_numerator = woba * float(pa)
	return record


func _assert_slot_role(slots: Array, index: int, want_pitcher: bool, year: int, season_number: int) -> void:
	var pid: int = int((slots[index] as Dictionary).get("pid", 0))
	if pid <= 0:
		return
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, year, season_number)
	if record == null:
		return
	assert_bool(record.is_pitcher()).is_equal(want_pitcher)
