extends GdUnitTestSuite

# R7 記録・履歴基盤: 選手経歴ログ (PSCareerLog) の記録・整形・永続化と、
# 各イベント発生箇所 (トレード/戦力外/引退) からの配線を検証する。

const Offseason = preload("res://services/season/offseason_service.gd")

const ALL_Z_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Spray", "Bat_Aggression", "Bat_Platoon",
	"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
	"Run_Speed", "Run_Judgment", "Run_Steal",
]


func test_career_log_append_and_describe() -> void:
	var player: PSPlayer = _player({"id": 1, "team_id": 1})
	PSCareerLog.log_trade(player, 2027, 1, 2)
	PSCareerLog.log_salary(player, 2027, 12000)
	PSCareerLog.log_injury(player, 2028, 45, "右肘の張り")
	# 閾値未満の軽傷は記録しない。
	PSCareerLog.log_injury(player, 2028, 10, "軽い張り")

	var entries: Array = PSCareerLog.entries(player)
	assert_int(entries.size()).is_equal(3)
	var trade_desc: Dictionary = PSCareerLog.describe(entries[0] as Dictionary)
	assert_str(str(trade_desc.get("year", ""))).is_equal("2027年")
	assert_str(str(trade_desc.get("label", ""))).is_equal("トレード移籍")
	var salary_desc: Dictionary = PSCareerLog.describe(entries[1] as Dictionary)
	assert_str(str(salary_desc.get("detail", ""))).is_equal("1億2000万円")
	var injury_desc: Dictionary = PSCareerLog.describe(entries[2] as Dictionary)
	assert_str(str(injury_desc.get("detail", ""))).contains("右肘の張り")
	assert_str(str(injury_desc.get("detail", ""))).contains("45日")


func test_career_log_survives_player_round_trip() -> void:
	var player: PSPlayer = _player({"id": 2, "team_id": 1})
	PSCareerLog.log_fa_move(player, 2030, 1, 4, 25000)
	var restored: PSPlayer = PSPlayer.from_dict(player.to_dict())
	var entries: Array = PSCareerLog.entries(restored)
	assert_int(entries.size()).is_equal(1)
	assert_str(str((entries[0] as Dictionary).get("t", ""))).is_equal(PSCareerLog.TYPE_FA_MOVE)


func test_trade_logs_career_entries_for_both_players() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = 10
	season.calendar_start_date = "2099-03-27"
	var player_a: PSPlayer = _player_with_z(11, 1, 3, 1.0)
	var player_b: PSPlayer = _player_with_z(21, 2, 6, 1.0)
	season.set_active_roster(1, {"player_ids": [11]})
	season.set_active_roster(2, {"player_ids": [21]})
	TradeService.execute_trade(season, [player_a, player_b], 1, [11], 2, [21], "cpu")

	var entries_a: Array = PSCareerLog.entries(player_a)
	assert_int(entries_a.size()).is_equal(1)
	var entry: Dictionary = entries_a[0] as Dictionary
	assert_str(str(entry.get("t", ""))).is_equal(PSCareerLog.TYPE_TRADE)
	assert_int(int(entry.get("f", 0))).is_equal(1)
	assert_int(int(entry.get("o", 0))).is_equal(2)
	assert_int(PSCareerLog.entries(player_b).size()).is_equal(1)


func test_release_logs_career_entry_with_original_team() -> void:
	var player: PSPlayer = _player({"id": 31, "team_id": 5, "age": 33})
	var result: Dictionary = Offseason.process_release([player], 5, [31], 2101)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	var entries: Array = PSCareerLog.entries(player)
	assert_int(entries.size()).is_equal(1)
	var entry: Dictionary = entries[0] as Dictionary
	assert_str(str(entry.get("t", ""))).is_equal(PSCareerLog.TYPE_RELEASED)
	# team_id クリア前の所属が記録される。
	assert_int(int(entry.get("f", 0))).is_equal(5)
	assert_int(int(entry.get("y", 0))).is_equal(2101)


func test_seed_draft_entry_lands_in_player_source_data() -> void:
	var source: Dictionary = {}
	PSCareerLog.seed_draft_entry(source, 2105, 3, 2, false)
	var player: PSPlayer = _player({"id": 41, "team_id": 3, "source_data": source})
	var entries: Array = PSCareerLog.entries(player)
	assert_int(entries.size()).is_equal(1)
	var described: Dictionary = PSCareerLog.describe(entries[0] as Dictionary)
	assert_str(str(described.get("label", ""))).is_equal("ドラフト入団")
	assert_str(str(described.get("detail", ""))).contains("2位")


# ---- helpers -------------------------------------------------------------------

func _player(data: Dictionary) -> PSPlayer:
	var payload: Dictionary = {
		"age": 24,
		"years": 3,
		"position": 3,
		"role": "fielder",
		"throws": "R",
		"bats": "R",
		"z_abilities": {},
		"raw_abilities": {},
	}
	for key in data.keys():
		payload[key] = data[key]
	return PSPlayer.from_dict(payload)


func _player_with_z(id: int, team_id: int, position: int, z_value: float) -> PSPlayer:
	var z: Dictionary = {}
	for key in ALL_Z_KEYS:
		z[key] = z_value
	return _player({
		"id": id,
		"team_id": team_id,
		"position": position,
		"z_abilities": z,
	})
