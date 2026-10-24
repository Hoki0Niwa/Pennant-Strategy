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

func test_review_and_draft_class_payloads_are_detached() -> void:
	var payload: Dictionary = {"year": 2031, "season_number": 6,
		"teams": [{"team_id": 1, "controlled_count": 0, "development_count": 0}],
		"picks": [{"player_id": 7, "name": "Same", "development": false}],
		"player_facts": [{"player_id": 7, "total": {"war": 1.25}}]}
	var review: PSSeasonReview = PSSeasonReview.from_dict(payload)
	var draft_class: PSDraftClass = PSDraftClass.from_dict(payload)
	payload["picks"][0]["name"] = "Changed"
	payload["player_facts"][0]["total"]["war"] = 999.0
	var exported: Dictionary = review.to_dict()
	exported["player_facts"][0]["total"]["war"] = 0.0
	var facts: Array = review.player_facts
	facts[0]["total"]["war"] = -3.0
	var picks: Array = draft_class.picks
	picks[0]["name"] = "Reader changed"
	assert_float(float(review.player_facts[0]["total"]["war"])).is_equal(1.25)
	assert_str(str(draft_class.picks[0]["name"])).is_equal("Same")
	assert_int(int(draft_class.teams[0]["controlled_count"])).is_equal(0)
	var restored: PSDraftClass = PSDraftClass.from_dict(JSON.parse_string(JSON.stringify(draft_class.to_dict())) as Dictionary)
	assert_int(restored.year).is_equal(2031)
	assert_int(int(restored.picks[0]["player_id"])).is_equal(7)


func test_season_review_freezes_first_team_counts_and_return_stints() -> void:
	RecordStore.clear_records()
	var season: PSSeason = PSSeason.new()
	season.year = 2031
	season.season_number = 6
	var team_a: PSTeam = PSTeam.from_dict({"id": 1, "name": "A", "league": "league1"})
	var team_b: PSTeam = PSTeam.from_dict({"id": 2, "name": "B", "league": "league1"})
	season.standings = {1: PSStats.from_dict({"wins": 80, "losses": 60, "runs_scored": 500}),
		2: PSStats.from_dict({"wins": 60, "losses": 80, "runs_scored": 400})}
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(_player({"id": 801, "team_id": 1, "name": "Original"}), 2031, 6)
	record.batter_stats.games = 2
	record.batter_stats.at_bats = 8
	record.batter_stats.hits = 3
	record.close_team_stint(10)
	record.team_id = 2
	record.batter_stats.games = 5
	record.batter_stats.at_bats = 20
	record.batter_stats.hits = 8
	record.close_team_stint(20)
	record.team_id = 1
	record.batter_stats.games = 6
	record.batter_stats.at_bats = 24
	record.batter_stats.hits = 10
	record.batter_stats.stolen_base_attempts = 4
	record.pitcher_stats.relief_appearances = 2
	record.pitcher_stats.quality_starts = 1
	var farm_only: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(_player({"id": 802, "team_id": 1}), 2031, 6)
	farm_only.farm_batter_stats.games = 30
	RecordStore.seed_initial_history([record, farm_only], [])
	var original: Dictionary = record.to_dict().duplicate(true)
	var input_teams: Array = [team_b, team_a]
	var review: PSSeasonReview = PSSeasonReviewService.build(season, input_teams)
	assert_int((input_teams[0] as PSTeam).id).is_equal(2)
	assert_bool(record.to_dict() == original).is_true()
	assert_int(review.player_facts.size()).is_equal(1)
	var fact: Dictionary = review.player_facts[0] as Dictionary
	assert_int(int(fact["total"]["batter_stats"]["hits"])).is_equal(10)
	assert_int(int(fact["total"]["batter_stats"]["stolen_base_attempts"])).is_equal(4)
	assert_int(int(fact["total"]["pitcher_stats"]["relief_appearances"])).is_equal(2)
	assert_int(int(fact["total"]["pitcher_stats"]["quality_starts"])).is_equal(1)
	assert_int(int(fact["teams"]["1"]["batter_stats"]["hits"])).is_equal(5)
	assert_int(int(fact["teams"]["2"]["batter_stats"]["hits"])).is_equal(5)
	var context: Dictionary = PSWarCalculator.build_league_context(2031, 6)
	assert_float(float(fact["total"]["war"])).is_equal(float(PSWarCalculator.season_war(record, context)["war"]))
	assert_float(float(fact["teams"]["1"]["war"])).is_equal(float(PSWarCalculator.season_war(record.stats_view_for_teams([1]), context)["war"]))
	record.name = "Changed"
	record.role = "pitcher"
	record.batter_stats.hits = 999
	team_a.name = "Renamed"
	season.standings[1].wins = 999
	assert_str(str(review.player_facts[0]["name"])).is_equal("Original")
	assert_int(int(review.player_facts[0]["total"]["batter_stats"]["hits"])).is_equal(10)
	assert_str(review.completion_kind).is_equal("regular_season")
	assert_int(int(review.teams[1]["rank"])).is_equal(1)
	assert_int(int(review.teams[1]["standings"]["wins"])).is_equal(80)
	assert_bool((review.teams[1]["previous_delta"] as Dictionary).is_empty()).is_true()
	RecordStore.clear_records()


func test_season_review_uses_postseason_rank_and_only_adjacent_previous_season() -> void:
	RecordStore.clear_records()
	var season: PSSeason = PSSeason.new()
	season.year = 2032
	season.season_number = 7
	var team_a: PSTeam = PSTeam.from_dict({"id": 1, "name": "A", "league": "league1"})
	var team_b: PSTeam = PSTeam.from_dict({"id": 2, "name": "B", "league": "league1"})
	var teams: Array = [team_b, team_a]
	season.standings = {1: PSStats.from_dict({"wins": 80, "losses": 60, "runs_scored": 500, "runs_allowed": 450}),
		2: PSStats.from_dict({"wins": 40, "losses": 30})}
	var previous: PSSeasonReview = PSSeasonReview.from_dict({"year": 2031, "season_number": 6,
		"teams": [{"team_id": 1, "league": "league1", "rank": 2, "win_rate": 0.5, "war": 3.0,
			"standings": {"wins": 70, "losses": 70, "draws": 3, "runs_scored": 460, "runs_allowed": 470}}]})
	var review: PSSeasonReview = PSSeasonReviewService.build(season, teams, previous)
	var ranked: Array = PostseasonService.league_standings(season, teams)["league1"] as Array
	for row: Dictionary in review.teams:
		assert_int(int(row["rank"])).is_equal(1 if (ranked[0] as PSTeam).id == int(row["team_id"]) else 2)
	var row_a: Dictionary = review.teams[1] as Dictionary
	assert_int(int(row_a["previous_delta"]["wins"])).is_equal(10)
	assert_int(int(row_a["previous_delta"]["rank"])).is_equal(-1)
	assert_int(int(row_a["previous_delta"]["run_difference"])).is_equal(60)
	assert_float(float(row_a["previous_delta"]["war"])).is_equal(-3.0)
	assert_int(int(row_a["run_difference"])).is_equal(50)
	var detached: Dictionary = previous.to_dict()
	detached["season_number"] = 5
	var nonadjacent: PSSeasonReview = PSSeasonReviewService.build(season, teams, PSSeasonReview.from_dict(detached))
	assert_bool((nonadjacent.teams[1]["previous_delta"] as Dictionary).is_empty()).is_true()
	assert_int((teams[0] as PSTeam).id).is_equal(2)
	RecordStore.clear_records()


func test_review_contributors_are_stable_limited_and_preserve_negative_war() -> void:
	var candidates: Array = []
	for id in [5, 3, 2, 1, 4]:
		candidates.append({"player_id": id, "role": "fielder", "war": -1.0,
			"stats": {"batter_stats": {"plate_appearances": 20 if id == 5 else 10}}})
	var candidates_snapshot: Array = candidates.duplicate(true)
	var selected: Array = PSSeasonReviewService._select_contributors(candidates, false)
	assert_int(selected.size()).is_equal(3)
	assert_int(int(selected[0]["player_id"])).is_equal(5)
	assert_int(int(selected[1]["player_id"])).is_equal(1)
	assert_int(int(selected[2]["player_id"])).is_equal(2)
	assert_float(float(selected[0]["war"])).is_equal(-1.0)
	assert_bool(candidates == candidates_snapshot).is_true()
	assert_int(PSSeasonReviewService._select_contributors(candidates, true).size()).is_equal(0)
	var pitchers: Array = []
	for role: String in ["starter", "reliever", "closer"]:
		pitchers.append({"player_id": pitchers.size() + 1, "role": role, "position": 1, "war": 0.0,
			"stats": {"pitcher_stats": {"outs_pitched": pitchers.size() * 3}}})
	var selected_pitchers: Array = PSSeasonReviewService._select_contributors(pitchers, true)
	assert_int(selected_pitchers.size()).is_equal(3)
	assert_int(int(selected_pitchers[0]["player_id"])).is_equal(3)
	assert_int(PSSeasonReviewService._select_contributors(pitchers, false).size()).is_equal(0)
	var position_pitcher: Dictionary = pitchers[0].duplicate(true)
	position_pitcher["role"] = "fielder"
	assert_int(PSSeasonReviewService._select_contributors([position_pitcher], true).size()).is_equal(1)


func test_review_metrics_comparison_uses_rates_and_missing_denominators() -> void:
	RecordStore.clear_records()
	var season: PSSeason = PSSeason.new()
	season.year = 2032
	season.season_number = 7
	var team: PSTeam = PSTeam.from_dict({"id": 1, "name": "A", "league": "league2"})
	season.standings = {1: PSStats.from_dict({"games": 100, "wins": 60, "losses": 40, "runs_scored": 400, "runs_allowed": 300})}
	var previous: PSSeasonReview = PSSeasonReview.from_dict({"year": 2031, "season_number": 6,
		"teams": [{"team_id": 1, "league": "league1", "rank": 2, "standings": {"games": 80, "wins": 40, "losses": 40, "runs_scored": 320, "runs_allowed": 320}}]})
	var review: PSSeasonReview = PSSeasonReviewService.build(season, [team], previous)
	var delta: Dictionary = review.teams[0]["previous_delta"] as Dictionary
	assert_bool(delta.has("rank")).is_false()
	assert_float(float(delta["win_rate"])).is_equal_approx(0.1, 0.000001)
	assert_float(float(delta["runs_scored_per_game"])).is_equal(0.0)
	assert_float(float(delta["runs_allowed_per_game"])).is_equal(-1.0)
	assert_str(str(review.teams[0]["comparison_fact"]["key"])).is_equal("season_review.fact.comparison")
	team.league = "league1"
	var same_league: PSSeasonReview = PSSeasonReviewService.build(season, [team], previous)
	var comparison: Dictionary = same_league.teams[0]["comparison_fact"] as Dictionary
	assert_str(str(comparison["key"])).is_equal("season_review.fact.comparison_rank")
	assert_str(str(comparison["params"]["rank"])).is_equal("-1")
	assert_str(str(same_league.teams[0]["facts"][1]["key"])).is_equal("season_review.fact.comparison_rank")
	var positive_rank: Dictionary = comparison.duplicate(true)
	positive_rank["params"]["rank"] = "+1"
	assert_str(PSSeasonReviewService._render(positive_rank)).contains("順位+1")
	var empty: Dictionary = PSSeasonReviewService._metrics({}, 0.0)
	assert_bool(empty["win_rate"] == null).is_true()
	assert_bool(empty["runs_scored_per_game"] == null).is_true()
	assert_bool(empty["runs_allowed_per_game"] == null).is_true()
	assert_str(PSSeasonReviewService.team_view(review, 1)["postseason_text"]).is_equal(Loc.t("season_review.postseason.unavailable"))
	RecordStore.clear_records()


func test_review_view_renders_saved_facts_with_current_templates_only() -> void:
	var row: Dictionary = {"team_id": 9, "team_name": "Frozen", "rank": 1,
		"standings": {"wins": 60, "losses": 40, "draws": 0},
		"metrics": {"runs_scored_per_game": 4.0, "runs_allowed_per_game": 3.0, "run_difference": 100},
		"previous_delta": {"win_rate": 0.1, "runs_scored_per_game": 0.5, "runs_allowed_per_game": -0.2},
		"contributors_pitcher": [{"player_id": 901, "name": "Saved", "role": "starter", "position": 1, "war": -0.5,
			"stats": {"pitcher_stats": {"games": 2, "outs_pitched": 9}, "war": -0.5}}],
		"contributors_fielder": [{"name": "Other", "war": 1.0}],
		"awards": [{"name": "Saved", "label_key": "season_review.award.mvp", "player_id": 901}]}
	row["facts"] = PSSeasonReviewService._sentence_facts(row)
	assert_int((row["facts"] as Array).size()).is_equal(4)
	assert_str(str(row["facts"][1]["key"])).is_equal("season_review.fact.comparison")
	assert_str(str(row["facts"][2]["key"])).is_equal("season_review.fact.contributors")
	assert_str(str(row["facts"][3]["key"])).is_equal("season_review.fact.awards")
	row["contributors_fielder"] = []
	row["facts"] = PSSeasonReviewService._sentence_facts(row)
	var review: PSSeasonReview = PSSeasonReview.from_dict({"teams": [row]})
	var frozen: Dictionary = review.to_dict()
	var table: Dictionary = (Loc.get("_table") as Dictionary).duplicate(true)
	var replacement: Dictionary = table.duplicate(true)
	replacement["season_review.fact.contributor_pitcher"] = "Changed {name} / {war}"
	Loc.set("_table", replacement)
	var view: Dictionary = PSSeasonReviewService.team_view(review, 9)
	Loc.set("_table", table)
	assert_str(str(view["sentences"][2])).is_equal("Changed Saved / -0.5")
	assert_str(str(view["sentences"][3])).contains("Saved")
	assert_str(str(view["contributors_pitcher"][0]["entry"]["team_name"])).is_equal("Frozen")
	assert_str(str(view["contributors_pitcher"][0]["presentation"])).is_equal("historical")
	assert_int((view["contributors_pitcher"][0]["record"] as PSPlayerSeasonRecord).pitcher_stats.outs_pitched).is_equal(9)
	assert_bool(review.to_dict() == frozen).is_true()
	assert_bool(PSSeasonReviewService.team_view(review, 88).is_empty()).is_true()
	var restored: PSSeasonReview = PSSeasonReview.from_dict(JSON.parse_string(JSON.stringify(review.to_dict())) as Dictionary)
	var restored_view: Dictionary = PSSeasonReviewService.team_view(restored, 9)
	var expected_record: String = Loc.t("season_review.fact.record", {"team": "Frozen", "wins": 60, "losses": 40, "draws": 0, "rank": 1})
	assert_str(str(restored_view["sentences"][0])).is_equal(expected_record)
	assert_str(str(restored_view["sentences"][3])).is_equal(Loc.t("season_review.fact.awards", {"names": "Saved", "count": 1}))
	assert_bool(restored_view["sentences"] == PSSeasonReviewService.team_view(review, 9)["sentences"]).is_true()
	restored_view["team"]["contributors_pitcher"][0]["name"] = "Reader changed"
	restored_view["team"]["facts"][0]["params"]["wins"] = 999
	assert_bool(review.to_dict() == frozen).is_true()
	assert_str(str(PSSeasonReviewService.team_view(restored, 9)["sentences"][0])).is_equal(expected_record)


func test_review_awards_and_postseason_are_detached_at_capture() -> void:
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.awards = PSAwards.from_dict({"mvp_league1_player_id": 901, "rookie_league1_player_id": 901,
		"batting_titles": {"league1": {"home_runs": 901}}, "best_nine": {"league1": [{"pid": 901}]},
		"golden_glove": {"league1": [{"pid": 901}]}})
	archive.postseason = PSPostseasonResult.from_dict({"champion_team_id": 1,
		"japan_series": {"top_id": 1, "challenger_id": 2, "winner_id": 1, "completed": true}})
	var team: PSTeam = PSTeam.from_dict({"id": 1, "name": "Then", "league": "league1"})
	var facts: Array = [{"player_id": 901, "name": "Original", "team_id": 1}]
	var awards: Array = PSSeasonReviewService._awards(archive, team, facts)
	var post: Dictionary = PSSeasonReviewService._postseason_fact(archive, 1)
	archive.awards.mvp_league1_player_id = 0
	archive.postseason.japan_series["winner_id"] = 2
	facts[0]["name"] = "Changed"
	team.name = "Now"
	assert_int(awards.size()).is_equal(5)
	assert_str(str(awards[0]["name"])).is_equal("Original")
	assert_str(str(awards[0]["team_name"])).is_equal("Then")
	assert_int(int(awards[0]["team_id"])).is_equal(1)
	assert_str(str(post["key"])).is_equal("season_review.postseason.champion")
	assert_int(int(post["stages"][0]["winner_id"])).is_equal(1)


func test_draft_retrospective_uses_frozen_period_and_team_totals() -> void:
	var draft_class: PSDraftClass = PSDraftClass.from_dict({"year": 2030, "season_number": 5,
		"teams": [{"team_id": 1, "team_name": "Frozen"}], "picks": [
			{"player_id": 3, "team_id": 1, "name": "Same", "round": 1, "development": true},
			{"player_id": 2, "team_id": 1, "name": "Same", "round": 2, "development": false},
			{"player_id": 1, "team_id": 1, "name": "Return", "round": 1, "development": false},
			{"player_id": 4, "team_id": 2, "name": "Other", "round": 1, "development": false}]})
	# 往復移籍の指名球団分は、全所属合計と異なる凍結値を持つ。
	var review: PSSeasonReview = PSSeasonReview.from_dict({"year": 2031, "season_number": 6,
		"player_facts": [{"player_id": 1, "name": "Renamed", "total": {
			"batter_stats": {"games": 6, "at_bats": 24, "hits": 10},
			"pitcher_stats": {"games": 2, "outs_pitched": 9}, "war": -0.75},
			"teams": {"1": {"batter_stats": {"games": 3, "at_bats": 12, "hits": 5}, "war": -0.25},
				"2": {"batter_stats": {"games": 3, "at_bats": 12, "hits": 5}, "war": 8.0}}},
			{"player_id": 2, "total": {"batter_stats": {"games": 1, "at_bats": 0}, "war": 1.5}, "teams": {}},
			{"player_id": 4, "total": {"batter_stats": {"games": 100}, "war": 999.0}}]})
	var old: PSSeasonReview = PSSeasonReview.from_dict({"year": 2030, "season_number": 5,
		"player_facts": [{"player_id": 1, "total": {"war": 100.0}}]})
	var future: PSSeasonReview = PSSeasonReview.from_dict({"year": 2033, "season_number": 8,
		"player_facts": [{"player_id": 1, "total": {"war": 100.0}}]})
	var next: PSSeasonReview = PSSeasonReview.from_dict({"year": 2032, "season_number": 7,
		"player_facts": [{"player_id": 1, "total": {"pitcher_stats": {"games": 1, "outs_pitched": 6}, "war": 2.0},
			"teams": {"1": {"pitcher_stats": {"games": 1, "outs_pitched": 6}, "war": 0.5}}}]})
	var future_year: PSSeasonReview = PSSeasonReview.from_dict({"year": 2034, "season_number": 7,
		"player_facts": [{"player_id": 1, "total": {"war": 100.0}}]})
	var before_year: PSSeasonReview = PSSeasonReview.from_dict({"year": 2030, "season_number": 6,
		"player_facts": [{"player_id": 1, "total": {"war": 100.0}}]})
	var future_number: PSSeasonReview = PSSeasonReview.from_dict({"year": 2032, "season_number": 9,
		"player_facts": [{"player_id": 1, "total": {"war": 100.0}}]})
	var reviews: Array = [future, review, old, next, review, future_year, before_year, future_number]
	var draft_snapshot: Dictionary = draft_class.to_dict()
	var review_snapshot: Dictionary = review.to_dict()
	var result: Dictionary = PSDraftRetrospectiveService.build(draft_class, reviews, 2032, 7, 1)
	assert_int(int(result["completed_seasons"])).is_equal(2)
	assert_bool(bool(result["has_completed_season"])).is_true()
	assert_int((result["missing_seasons"] as Array).size()).is_equal(0)
	assert_str(str(result["team_name"])).is_equal("Frozen")
	assert_int(int(result["summary"]["main_count"])).is_equal(2)
	assert_int(int(result["summary"]["development_count"])).is_equal(1)
	assert_int(int(result["summary"]["appeared_count"])).is_equal(2)
	assert_float(float(result["summary"]["war"])).is_equal(2.75)
	assert_float(float(result["summary"]["team_war"])).is_equal(0.25)
	var players: Array = result["players"] as Array
	assert_int(players.size()).is_equal(3)
	assert_int(int(players[0]["identity"]["player_id"])).is_equal(1)
	assert_int(int(players[1]["identity"]["player_id"])).is_equal(2)
	assert_int(int(players[2]["identity"]["player_id"])).is_equal(3)
	assert_int(int(players[0]["all"]["batter_stats"]["hits"])).is_equal(10)
	assert_int(int(players[0]["team"]["batter_stats"]["hits"])).is_equal(5)
	assert_int(int(players[0]["all"]["pitcher_stats"]["outs_pitched"])).is_equal(15)
	assert_int(int(players[0]["years"][0]["season_number"])).is_equal(6)
	assert_int(int(players[0]["years"][1]["season_number"])).is_equal(7)
	assert_int(int(players[1]["all"]["batter_stats"]["at_bats"])).is_equal(0)
	assert_int(int(players[1]["team"]["batter_stats"]["games"])).is_equal(0)
	assert_int(int(players[2]["all"]["batter_stats"]["games"])).is_equal(0)
	assert_int((players[2]["years"] as Array).size()).is_equal(2)
	var restored_reviews: Array = []
	for saved_review: PSSeasonReview in reviews:
		restored_reviews.append(PSSeasonReview.from_dict(JSON.parse_string(JSON.stringify(saved_review.to_dict())) as Dictionary))
	var restored_class: PSDraftClass = PSDraftClass.from_dict(JSON.parse_string(JSON.stringify(draft_class.to_dict())) as Dictionary)
	var restored: Dictionary = PSDraftRetrospectiveService.build(restored_class, restored_reviews, 2032, 7, 1)
	assert_bool(JSON.parse_string(JSON.stringify(restored)) == JSON.parse_string(JSON.stringify(result))).is_true()
	players[0]["identity"]["name"] = "Reader changed"
	players[0]["years"][0]["all"]["war"] = 500.0
	assert_bool(draft_class.to_dict() == draft_snapshot).is_true()
	assert_bool(review.to_dict() == review_snapshot).is_true()
	assert_float(float(players[0]["all"]["war"])).is_equal(1.25)


func test_draft_retrospective_distinguishes_missing_seasons_from_no_appearance() -> void:
	var draft_class: PSDraftClass = PSDraftClass.from_dict({"year": 2030, "season_number": 5,
		"picks": [{"player_id": 12, "team_id": 1, "round": 1, "development": false}]})
	var complete: PSSeasonReview = PSSeasonReview.from_dict({"year": 2031, "season_number": 6,
		"player_facts": [{"player_id": 12, "total": {"farm_batter_stats": {"games": 30, "hits": 40}}}]})
	var immediately: Dictionary = PSDraftRetrospectiveService.build(draft_class, [complete], 2030, 5, 1)
	assert_bool(bool(immediately["has_completed_season"])).is_false()
	assert_int((immediately["players"] as Array).size()).is_equal(1)
	assert_int((immediately["players"][0]["years"] as Array).size()).is_equal(0)
	var result: Dictionary = PSDraftRetrospectiveService.build(draft_class, [complete], 2033, 8, 1)
	assert_int(int(result["completed_seasons"])).is_equal(1)
	assert_int((result["missing_seasons"] as Array).size()).is_equal(2)
	assert_int(int(result["missing_seasons"][0]["year"])).is_equal(2032)
	assert_int(int(result["missing_seasons"][0]["season_number"])).is_equal(7)
	assert_int(int(result["players"][0]["years"][0]["all"]["batter_stats"]["games"])).is_equal(0)
	assert_int(int(result["summary"]["appeared_count"])).is_equal(0)
	var no_picks: Dictionary = PSDraftRetrospectiveService.build(draft_class, [complete], 2031, 6, 2)
	assert_int((no_picks["players"] as Array).size()).is_equal(0)
	assert_bool(bool(no_picks["has_completed_season"])).is_true()


func test_draft_retrospective_pick_ties_use_order_then_identity() -> void:
	var picks: Array = []
	for id: int in [3, 2, 1]:
		picks.append({"player_id": id, "team_id": 1, "round": 1, "pick_order": 2 if id == 3 else 1})
	var draft_class: PSDraftClass = PSDraftClass.from_dict({"picks": picks})
	var result: Dictionary = PSDraftRetrospectiveService.build(draft_class, [], 0, 1, 1)
	for index in 3:
		assert_int(int(result["players"][index]["identity"]["player_id"])).is_equal(index + 1)


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
