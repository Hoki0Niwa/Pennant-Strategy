extends GdUnitTestSuite

# 記録・履歴基盤: 選手経歴ログ (PSCareerLog) の記録・整形・永続化と、
# 各イベント発生箇所 (トレード/戦力外/引退) からの配線、初期世界の開始前の履歴
# (PSSeedHistoryIo) の書き出し・読み込みと、それを使う評価側の参照を検証する。

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


# ---- 初期世界の開始前の履歴 (PSSeedHistoryIo) ------------------------------------

# 1 選手 × 1 季の行が CSV を往復し、年のずらしと season_number の付け直しを経て、
# その季の所属・年齢・成績・能力スナップショット・高度指標を保ったレコードに戻ること。
func test_seed_history_record_round_trips_through_csv() -> void:
	var player: PSPlayer = _player_with_z(501, 3, 6, 1.0)
	player.name = "履歴 太郎"
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2031, 6)
	record.team_id = 4
	record.age = 27
	record.years = 5
	record.position_aptitudes_snapshot = {"second": 75, "shortstop": 82}
	record.batter_stats.games = 138
	record.batter_stats.plate_appearances = 590
	record.batter_stats.hits = 160
	record.batter_stats.home_runs = 25
	record.farm_batter_stats.games = 3
	record.advanced_stats.plate_appearances = 590
	record.advanced_stats.woba_numerator = 210.5
	record.advanced_stats.woba_denominator = 560
	record.advanced_stats.fielding_chances_by_position = {"6": 400}
	record.advanced_stats.uzr_by_position = {"6": 4.5}
	var path: String = "user://test_seed_history_records.csv"
	assert_bool(PSSeedHistoryIo.write_records(path, [PSSeedHistoryIo.record_row(record)])).is_true()
	var rows: Array = PSSeedHistoryIo.read_records(path)
	DirAccess.remove_absolute(path)
	assert_int(rows.size()).is_equal(1)

	var shifted: Array = PSSeedHistoryIo.shift_record_rows(rows, 10, 2026)
	var built: Array = PSSeedHistoryIo.build_records(shifted, {player.id: player}, 2026)
	assert_int(built.size()).is_equal(1)
	var restored: PSPlayerSeasonRecord = built[0] as PSPlayerSeasonRecord
	assert_int(restored.year).is_equal(2021)
	assert_int(restored.season_number).is_equal(2021 - 2026 + 1)
	assert_int(restored.team_id).is_equal(4)
	assert_int(restored.age).is_equal(27)
	assert_int(restored.years).is_equal(5)
	assert_int(restored.batter_stats.games).is_equal(138)
	assert_int(restored.batter_stats.hits).is_equal(160)
	assert_int(restored.batter_stats.home_runs).is_equal(25)
	assert_int(restored.farm_batter_stats.games).is_equal(3)
	assert_int(restored.pitcher_stats.games).is_equal(0)
	assert_float(restored.advanced_stats.woba_numerator).is_equal_approx(210.5, 0.001)
	assert_int(restored.advanced_stats.woba_denominator).is_equal(560)
	assert_int(int(restored.advanced_stats.fielding_chances_by_position.get("6", 0))).is_equal(400)
	assert_float(float(restored.advanced_stats.uzr_by_position.get("6", 0.0))).is_equal_approx(4.5, 0.001)
	assert_float(restored.z_ability("Bat_Impact")).is_equal_approx(1.0, 0.0001)
	assert_int(int(restored.position_aptitudes_snapshot.get("shortstop", 0))).is_equal(82)
	assert_int(restored.advanced_stats.player_id).is_equal(player.id)
	# 経歴ログなど選手側が持つ情報は年度レコードへ複製しない。
	assert_bool(restored.source_data.is_empty()).is_true()

	# 開始年以降の季 (ずらす前の年のまま) と、名前の食い違う選手には付かない。
	assert_int(PSSeedHistoryIo.build_records(rows, {player.id: player}, 2026).size()).is_equal(0)
	var stranger: PSPlayer = _player_with_z(501, 3, 6, 1.0)
	stranger.name = "別人 次郎"
	assert_int(PSSeedHistoryIo.build_records(shifted, {stranger.id: stranger}, 2026).size()).is_equal(0)


# 季の履歴は JSON を往復し、年をずらすと球団成績と WAR 文脈の年も揃って動くこと。
# 基準分布の守備位置別平均は JSON で文字列キーになるので、正規化で整数キーへ戻ること。
func test_seed_history_season_entries_shift_and_restore_int_keys() -> void:
	var team: PSTeam = PSTeam.from_dict({"id": 2, "name": "テスト球団", "league": "league1"})
	var team_row: Dictionary = PSTeamSeasonRecord.from_team(team, 2064, 39).to_dict()
	var references: Dictionary = {
		PSSeedHistoryIo.reference_level_key(PSPerformanceReference.LEVEL_FIRST): {
			"regulars": {"mean": 1.0, "spread": 0.4, "by_position": {2: 0.7, 6: 1.2}},
		},
	}
	var entry: Dictionary = PSSeedHistoryIo.season_entry(
		2064, 39, [team_row], {"year": 2064, "season_number": 39, "rpw": 10.0}, references
	)
	var path: String = "user://test_seed_history_seasons.json"
	assert_bool(PSSeedHistoryIo.write_seasons(path, [entry])).is_true()
	var read_back: Array = PSSeedHistoryIo.read_seasons(path)
	DirAccess.remove_absolute(path)

	var shifted: Array = PSSeedHistoryIo.shift_season_entries(read_back, 40, 2026)
	var normalized: Array = PSSeedHistoryIo.normalize_season_entries(shifted, 2026)
	assert_int(normalized.size()).is_equal(1)
	var season: Dictionary = normalized[0] as Dictionary
	assert_int(int(season["year"])).is_equal(2024)
	assert_int(int(season["season_number"])).is_equal(-1)
	var team_record: Dictionary = (season[PSSeedHistoryIo.SEASON_KEY_TEAM_RECORDS] as Array)[0] as Dictionary
	assert_int(int(team_record["year"])).is_equal(2024)
	assert_int(int(team_record["season_number"])).is_equal(-1)
	var war_context: Dictionary = season[PSSeedHistoryIo.SEASON_KEY_WAR_CONTEXT] as Dictionary
	assert_int(int(war_context["year"])).is_equal(2024)
	assert_float(float(war_context["rpw"])).is_equal(10.0)
	var reference: Dictionary = (season[PSSeedHistoryIo.SEASON_KEY_REFERENCES] as Dictionary)[
		PSSeedHistoryIo.reference_level_key(PSPerformanceReference.LEVEL_FIRST)
	] as Dictionary
	var by_position: Dictionary = (reference["regulars"] as Dictionary)["by_position"] as Dictionary
	assert_bool(by_position.has(2)).is_true()
	assert_float(float(by_position[6])).is_equal_approx(1.2, 0.000001)
	# 開始年以降の季は「開始前」として置けないので落とす。
	assert_int(PSSeedHistoryIo.normalize_season_entries(read_back, 2026).size()).is_equal(0)


# 開始前の季は、生き残った選手だけの母集団から測り直さず、持ち込んだ文脈を使うこと
# (測り直すと WAR プールを少ない打席で割って WAR が膨らむ)。文脈の無い季は従来どおり測る。
func test_seeded_season_context_overrides_war_and_reference() -> void:
	RecordStore.clear_records()
	var player: PSPlayer = _player_with_z(601, (GameDb.teams[0] as PSTeam).id, 6, 0.5)
	var past: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2025, 0)
	past.advanced_stats.plate_appearances = 500
	# 文脈は実物と同じ形 (空の季を測った既定値) に目印の値を入れる。
	var first_key: String = PSSeedHistoryIo.reference_level_key(PSPerformanceReference.LEVEL_FIRST)
	var marker_reference: Dictionary = PSPerformanceReference.measure_completed_season(2025, 0)[first_key] as Dictionary
	(marker_reference["regulars"] as Dictionary)["mean"] = 0.777
	var war_context: Dictionary = PSWarCalculator.build_league_context(2025, 0)
	war_context["replacement_runs_per_pa"] = 0.5
	var entry: Dictionary = PSSeedHistoryIo.season_entry(2025, 0, [], war_context, {first_key: marker_reference})
	RecordStore.seed_initial_history([past], PSSeedHistoryIo.normalize_season_entries([entry], 2026))

	assert_float(float(PSWarCalculator.build_league_context(2025, 0).get("replacement_runs_per_pa", 0.0))).is_equal(0.5)
	assert_float(float(PSWarCalculator.build_league_context(2024, -1).get("replacement_runs_per_pa", 0.0))).is_equal(0.0)
	PSPerformanceReference.reset_cache()
	var reference: Dictionary = PSPerformanceReference.for_season(2025, 0)
	assert_float(float((reference["regulars"] as Dictionary)["mean"])).is_equal(0.777)
	# 二軍の基準は持ち込んでいないので測る (既定値へ落ちる)。
	var farm_reference: Dictionary = PSPerformanceReference.for_season(2025, 0, PSPerformanceReference.LEVEL_FARM)
	assert_float(float((farm_reference["regulars"] as Dictionary)["mean"])).is_not_equal(0.777)

	RecordStore.clear_records()
	PSPerformanceReference.reset_cache()


# 過去成績を遡る評価 (編成判断の roster_rating_delta) が、season_number が 0 以下の開始前の季まで
# 届くこと。以前は season_number <= 0 で打ち切っていたため、1 年目は誰も過去成績を持たなかった。
func test_form_lookback_reaches_seeded_seasons() -> void:
	RecordStore.clear_records()
	PSPerformanceReference.reset_cache()
	var player: PSPlayer = _player_with_z(701, (GameDb.teams[0] as PSTeam).id, 7, 0.0)
	var current: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	var without_history: float = PSBatterForm.roster_rating_delta(current)

	var past: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2025, 0)
	past.batter_stats.games = 140
	past.batter_stats.plate_appearances = 600
	past.batter_stats.at_bats = 500
	past.batter_stats.hits = 200
	past.batter_stats.doubles = 40
	past.batter_stats.home_runs = 50
	past.batter_stats.walks = 100
	RecordStore.seed_initial_history([past], [])
	PSPerformanceReference.reset_cache()
	var with_history: float = PSBatterForm.roster_rating_delta(current)

	assert_float(without_history).is_equal(0.0)
	assert_float(with_history).is_greater(0.0)

	RecordStore.clear_records()
	PSPerformanceReference.reset_cache()


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
