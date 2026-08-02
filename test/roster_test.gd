extends GdUnitTestSuite

# roadmap #3 育成選手制度: 支配下/育成の計数、昇格/降格、一軍出場不可、永続化を検証する。

const Offseason = preload("res://services/season/offseason_service.gd")
const ReleasedMarket = preload("res://services/season/released_market_service.gd")
const TeamSetupBuilder = preload("res://services/simulation/game/team_setup_builder.gd")
const TeamAutoAIRef = preload("res://services/season/team_auto_ai.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")
const ReleaseValueProjector = preload("res://services/season/release_value_projector.gd")

const ALL_Z_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Spray", "Bat_Aggression", "Bat_Platoon",
	"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
	"Run_Speed", "Run_Judgment", "Run_Steal",
]


# --- 計数 -------------------------------------------------------------------

func test_shienka_count_excludes_development() -> void:
	var players: Array = [
		_player({"id": 1, "team_id": 1}),
		_player({"id": 2, "team_id": 1}),
		_player({"id": 3, "team_id": 1, "development_player": true}),
		_player({"id": 4, "team_id": 2}),
	]
	assert_int(TeamFinance.shienka_count(players, 1)).is_equal(2)
	assert_int(TeamFinance.development_count(players, 1)).is_equal(1)
	assert_int(TeamFinance.shienka_count(players, 2)).is_equal(1)


func test_room_helpers_track_limits() -> void:
	var players: Array = _support_players(1, TeamFinance.SHIENKA_LIMIT)
	assert_bool(TeamFinance.has_shienka_room(players, 1)).is_false()
	players.append(_player({"id": 999, "team_id": 1, "development_player": true}))
	# 育成を足しても支配下枠には影響しない。
	assert_bool(TeamFinance.has_shienka_room(players, 1)).is_false()
	assert_bool(TeamFinance.has_development_room(players, 1)).is_true()


# --- 条件指定型外国人スカウト ----------------------------------------------

func test_foreign_scout_request_generates_matching_pitcher_candidates() -> void:
	Rng.set_seed_value(20260712)
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state([], [_team(1)], null, 1)
	var result: Dictionary = ForeignPlayerService.configure_user_scout_request(state, "starter", "control", "core")
	assert_bool(bool(result.get("ok", false))).is_true()
	var candidates: Array = ForeignPlayerService.available_user_candidates(state, [], [_team(1)])
	assert_int(candidates.size()).is_equal(ForeignPlayerService.scout_candidate_count("core"))
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value as Dictionary
		assert_int(int(candidate.get("request_team_id", 0))).is_equal(1)
		assert_str(str(candidate.get("scout_position", ""))).is_equal("starter")
		assert_str(str(candidate.get("archetype", ""))).is_equal("control")
		assert_str(str(candidate.get("budget_band", ""))).is_equal("core")
		assert_int(int(candidate.get("position", 0))).is_equal(1)
		assert_str(str(candidate.get("role", ""))).is_equal("starter")
		assert_int(int(candidate.get("salary", 0))).is_between(12000, 20000)
		assert_bool((candidate.get("display_player_data", {}) as Dictionary).is_empty()).is_false()
		var ratings: Dictionary = PSPlayerVisibleRatings.ratings_for_player_data(candidate.get("display_player_data", {}) as Dictionary)
		assert_str(str(ratings.get("kind", ""))).is_equal("pitcher")
		assert_int((ratings.get("display_ratings", []) as Array).size()).is_equal(4)
		assert_int(int(candidate.get("estimate_min", 0))).is_less_equal(int(candidate.get("estimated_value", 0)))
		assert_int(int(candidate.get("estimate_max", 0))).is_equal(int(candidate.get("estimated_value", 0)))
		assert_int(int(candidate.get("estimate_downside", 0))).is_equal(12)
		assert_int(int(candidate.get("estimate_upside", -1))).is_equal(0)
		assert_int(int(candidate.get("uncertainty", 0))).is_greater(0)


func test_foreign_higher_budget_returns_fewer_candidates() -> void:
	assert_int(ForeignPlayerService.scout_candidate_count("bargain")).is_equal(4)
	assert_int(ForeignPlayerService.scout_candidate_count("standard")).is_equal(3)
	assert_int(ForeignPlayerService.scout_candidate_count("core")).is_equal(2)
	assert_int(ForeignPlayerService.scout_candidate_count("star")).is_equal(1)
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state([], [_team(1)], null, 1)
	ForeignPlayerService.configure_user_scout_request(state, "first", "power", "star")
	var star: Dictionary = (ForeignPlayerService.available_user_candidates(state, [], [_team(1)])[0] as Dictionary)
	assert_int(int(star.get("estimate_downside", 0))).is_equal(15)
	assert_int(int(star.get("estimate_upside", -1))).is_equal(0)
	assert_int(int(star.get("estimate_max", 0))).is_equal(int(star.get("estimated_value", 0)))


func test_foreign_cpu_splits_room_across_all_open_slots() -> void:
	# 4枠を埋めるときは残額を4等分して候補帯を選び、1人目に使い切らない。
	assert_str(ForeignPlayerService._cpu_budget_band(40000, 4)).is_equal("bargain")
	assert_str(ForeignPlayerService._cpu_budget_band(48000, 4)).is_equal("standard")
	assert_str(ForeignPlayerService._cpu_budget_band(80000, 4)).is_equal("core")
	assert_str(ForeignPlayerService._cpu_budget_band(160000, 4)).is_equal("star")


func test_foreign_cpu_avoids_unusable_fourth_player_of_same_type() -> void:
	var team: PSTeam = _team(1)
	var foreign_fielders: Array = []
	for i in range(ForeignActiveRosterRules.TYPE_MAX):
		foreign_fielders.append(_player({
			"id": 300 + i, "team_id": 1, "position": 3, "foreign_player": true,
		}))
	var fielder_heavy_need: Dictionary = {1: {
		1: 0.0, 2: 0.0, 3: 100.0, 4: 0.0, 5: 0.0, 6: 0.0, 7: 0.0, 8: 0.0, 9: 0.0,
	}}
	var pitcher_request: Dictionary = ForeignPlayerService._cpu_scout_request(foreign_fielders, team, fielder_heavy_need)
	assert_bool(["starter", "reliever"].has(str(pitcher_request.get("position", "")))).is_true()

	var foreign_pitchers: Array = []
	for i in range(ForeignActiveRosterRules.TYPE_MAX):
		foreign_pitchers.append(_player({
			"id": 400 + i, "team_id": 1, "position": 1, "role": "reliever", "foreign_player": true,
		}))
	var pitcher_heavy_need: Dictionary = {1: {
		1: 100.0, 2: 0.0, 3: 1.0, 4: 0.0, 5: 0.0, 6: 0.0, 7: 0.0, 8: 0.0, 9: 0.0,
	}}
	var fielder_request: Dictionary = ForeignPlayerService._cpu_scout_request(foreign_pitchers, team, pitcher_heavy_need)
	assert_bool(["starter", "reliever"].has(str(fielder_request.get("position", "")))).is_false()


func test_foreign_signing_score_prefers_lower_salary_at_equal_estimate() -> void:
	var cheap: Dictionary = {"estimated_value": 65, "salary": 6000}
	var costly: Dictionary = {"estimated_value": 65, "salary": 18000}
	assert_float(ForeignPlayerService._signing_score(cheap, 5.0, [], [], 1)).is_greater(
		ForeignPlayerService._signing_score(costly, 5.0, [], [], 1)
	)


func test_foreign_any_request_keeps_one_position_group_per_shortlist() -> void:
	Rng.set_seed_value(20260716)
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state([], [_team(1)], null, 1)
	ForeignPlayerService.configure_user_scout_request(state, "any", "balanced", "bargain")
	var candidates: Array = ForeignPlayerService.available_user_candidates(state, [], [_team(1)])
	assert_int(candidates.size()).is_equal(4)
	var first_position: int = int((candidates[0] as Dictionary).get("position", 0))
	for candidate_value in candidates:
		assert_int(int((candidate_value as Dictionary).get("position", 0))).is_equal(first_position)


func test_foreign_cpu_uses_same_request_shortlist_engine() -> void:
	Rng.set_seed_value(20260713)
	var team: PSTeam = _team(1)
	var players: Array = []
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [team], null, 0)
	ForeignPlayerService.complete_foreign_market_automatically(state, players, [team], null, 0)
	assert_bool(bool(state.get("complete", false))).is_true()
	assert_int((state.get("signings", []) as Array).size()).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)
	assert_int((state.get("requests", []) as Array).size()).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)
	var generated_count: int = 0
	for request_value in state.get("requests", []) as Array:
		var request: Dictionary = request_value as Dictionary
		assert_str(str(request.get("method", ""))).is_equal("cpu")
		var request_count: int = ForeignPlayerService.scout_candidate_count(str(request.get("budget_band", "standard")))
		assert_int((request.get("candidate_ids", []) as Array).size()).is_equal(request_count)
		generated_count += request_count
	assert_int((state.get("candidates", []) as Array).size()).is_equal(generated_count)
	assert_int(players.size()).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)
	for player_value in players:
		assert_bool((player_value as PSPlayer).foreign_player).is_true()


func test_foreign_all_ai_includes_user_team_and_closes_manual_shortlist() -> void:
	Rng.set_seed_value(20260717)
	var team: PSTeam = _team(1)
	var players: Array = []
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [team], null, 1)
	ForeignPlayerService.configure_user_scout_request(state, "starter", "control", "standard")
	var manual_ids: Array = (state.get("user_candidate_ids", []) as Array).duplicate()
	var result: Dictionary = ForeignPlayerService.complete_all_foreign_market_automatically(state, players, [team], null)
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(state.get("complete", false))).is_true()
	assert_int(players.size()).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		assert_int(player.team_id).is_equal(1)
		assert_bool(player.foreign_player).is_true()
	for candidate_id in manual_ids:
		var manual_candidate: Dictionary = {}
		for candidate_value in state.get("candidates", []) as Array:
			var candidate: Dictionary = candidate_value as Dictionary
			if int(candidate.get("candidate_id", 0)) == int(candidate_id):
				manual_candidate = candidate
				break
		assert_bool(bool(manual_candidate.get("available", true))).is_false()


func test_foreign_user_can_sign_then_issue_another_request() -> void:
	Rng.set_seed_value(20260714)
	var team: PSTeam = _team(1)
	var teams: Array = [team]
	var players: Array = []
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, teams, null, 1)
	ForeignPlayerService.configure_user_scout_request(state, "first", "power", "standard")
	var first_candidates: Array = ForeignPlayerService.available_user_candidates(state, players, teams)
	var first_id: int = int((first_candidates[0] as Dictionary).get("candidate_id", 0))
	var signing: Dictionary = ForeignPlayerService.submit_user_foreign_decision(state, players, teams, null, first_id, "sign")
	assert_bool(bool(signing.get("ok", false))).is_true()
	assert_int(players.size()).is_equal(1)
	assert_int((state.get("user_candidate_ids", []) as Array).size()).is_equal(0)
	assert_bool((state.get("user_request", {}) as Dictionary).is_empty()).is_true()
	assert_bool(bool(state.get("complete", false))).is_false()

	var second: Dictionary = ForeignPlayerService.configure_user_scout_request(state, "reliever", "strikeout", "bargain")
	assert_bool(bool(second.get("ok", false))).is_true()
	var second_candidates: Array = ForeignPlayerService.available_user_candidates(state, players, teams)
	assert_int(second_candidates.size()).is_equal(ForeignPlayerService.scout_candidate_count("bargain"))
	for candidate_value in second_candidates:
		var candidate: Dictionary = candidate_value as Dictionary
		assert_str(str(candidate.get("scout_position", ""))).is_equal("reliever")
		assert_str(str(candidate.get("archetype", ""))).is_equal("strikeout")

	# 候補IDは state.next_candidate_id で採番するので、リクエストをまたいでも衝突しない。
	var seen_ids: Dictionary = {}
	for candidate_value in state.get("candidates", []) as Array:
		var candidate_id: int = int((candidate_value as Dictionary).get("candidate_id", 0))
		assert_bool(seen_ids.has(candidate_id)).is_false()
		seen_ids[candidate_id] = true


# --- FA日数 -------------------------------------------------------------------

# NPB は1年で最大145日(FA_SERVICE_DAYS_PER_YEAR)しか一軍登録日数を積めない。
# フルシーズン在籍(≈190日超)でも145日/年キャップで加算されること
# (2026-07-10 修正: 上限が無いとフル出場選手のFA権取得が現実より1.5〜2年早まっていた)。
func test_fa_service_days_capped_at_145_per_season() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.calendar_start_date = "2099-03-27"
	season.current_day = 1
	var player: PSPlayer = _player({"id": 1, "team_id": 1, "years": 1})
	season.set_active_roster(1, {"player_ids": [1]})
	season.current_day = 200
	season.accrue_active_roster_days(1, season.current_day)

	Offseason._apply_fa_service_days(player, null, season)

	assert_int(int(player.source_data.get("fa_active_days_last_season", 0))).is_equal(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)
	assert_int(int(player.source_data.get("fa_nissuu", 0))).is_equal(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)


# --- 初期シードCSVの未来年正規化 --------------------------------------------
# 進化後ワールドからエクスポートされた initial_players.csv は draft_year / traded_year に
# 開始年より未来の値を含み得る (services/season/geneki_draft_service.gd の現役ドラフト適格判定
# 「当年ドラフト新人」「当年トレード獲得」の当年比較が initial_year 相当と誤って一致/超過してしまう)。

func test_normalize_initial_seed_player_rebases_future_draft_year() -> void:
	var row: Dictionary = {
		"years": 5,
		"source_data": {"draft_year": 2044},
	}
	var out: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var source: Dictionary = out["source_data"] as Dictionary
	assert_int(int(source.get("draft_year", 0))).is_equal(2026 - 5)


func test_normalize_initial_seed_player_keeps_past_draft_year() -> void:
	var row: Dictionary = {
		"years": 5,
		"source_data": {"draft_year": 2020},
	}
	var out: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var source: Dictionary = out["source_data"] as Dictionary
	assert_int(int(source.get("draft_year", 0))).is_equal(2020)


func test_normalize_initial_seed_player_drops_future_or_current_traded_year() -> void:
	var row: Dictionary = {
		"years": 5,
		"source_data": {"traded_year": 2026, "traded_from_team": 3},
	}
	var out: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var source: Dictionary = out["source_data"] as Dictionary
	assert_bool(source.has("traded_year")).is_false()
	assert_bool(source.has("traded_from_team")).is_false()


func test_normalize_initial_seed_player_keeps_past_traded_year() -> void:
	var row: Dictionary = {
		"years": 5,
		"source_data": {"traded_year": 2024, "traded_from_team": 3},
	}
	var out: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var source: Dictionary = out["source_data"] as Dictionary
	assert_int(int(source.get("traded_year", 0))).is_equal(2024)
	assert_int(int(source.get("traded_from_team", 0))).is_equal(3)


# career_log の未来年は世界共通オフセット (最大 y → initial_year - 1) で一括シフトされる。
# ドラフト入団エントリのシフト後の年は draft_year のリベース値 (initial_year - years) と
# 一致し、最終オフに記録が無い選手も同じオフセットでずれないこと。
func test_normalize_initial_seed_players_shifts_career_log_by_world_offset() -> void:
	var rows: Array = [
		{
			"years": 17,
			"source_data": {"draft_year": 2029, "career_log": [
				{"y": 2029, "t": "draft", "o": 3, "v": 1},
				{"y": 2045, "t": "salary", "v": 12000},
			]},
		},
		{
			"years": 5,
			"source_data": {"draft_year": 2041, "career_log": [
				{"y": 2041, "t": "draft", "o": 2, "v": 2},
				{"y": 2043, "t": "salary", "v": 3000},
			]},
		},
	]
	var out: Array = PSPlayerCsvIo.normalize_initial_seed_players(rows, 2026)
	var log_a: Array = ((out[0] as Dictionary)["source_data"] as Dictionary)["career_log"] as Array
	assert_int(int((log_a[0] as Dictionary).get("y", 0))).is_equal(2026 - 17)
	assert_int(int((log_a[0] as Dictionary).get("y", 0))).is_equal(int(((out[0] as Dictionary)["source_data"] as Dictionary).get("draft_year", 0)))
	assert_int(int((log_a[1] as Dictionary).get("y", 0))).is_equal(2025)
	var log_b: Array = ((out[1] as Dictionary)["source_data"] as Dictionary)["career_log"] as Array
	assert_int(int((log_b[0] as Dictionary).get("y", 0))).is_equal(2026 - 5)
	assert_int(int((log_b[0] as Dictionary).get("y", 0))).is_equal(int(((out[1] as Dictionary)["source_data"] as Dictionary).get("draft_year", 0)))
	assert_int(int((log_b[1] as Dictionary).get("y", 0))).is_equal(2023)


# 正規化済み (未来年なし) の career_log はオフセット 0 で再正規化しても変化しない (冪等)。
func test_normalize_initial_seed_players_career_log_shift_is_idempotent() -> void:
	var rows: Array = [
		{
			"years": 17,
			"source_data": {"draft_year": 2029, "career_log": [
				{"y": 2029, "t": "draft", "o": 3, "v": 1},
				{"y": 2045, "t": "salary", "v": 12000},
			]},
		},
	]
	var once: Array = PSPlayerCsvIo.normalize_initial_seed_players(rows, 2026)
	var twice: Array = PSPlayerCsvIo.normalize_initial_seed_players(once, 2026)
	var log_once: Array = ((once[0] as Dictionary)["source_data"] as Dictionary)["career_log"] as Array
	var log_twice: Array = ((twice[0] as Dictionary)["source_data"] as Dictionary)["career_log"] as Array
	assert_array(log_twice).is_equal(log_once)


# オフセット不明の単独呼び出し (career_year_offset 省略) では、シフトで救えない未来年
# エントリだけ落ち、過去年と年不明 (y=0) は残ること。
func test_normalize_initial_seed_player_drops_unshiftable_future_career_entries() -> void:
	var row: Dictionary = {
		"years": 5,
		"source_data": {"career_log": [
			{"y": 2020, "t": "draft", "o": 3, "v": 1},
			{"y": 0, "t": "released", "f": 2},
			{"y": 2044, "t": "salary", "v": 3000},
		]},
	}
	var out: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var log: Array = (out["source_data"] as Dictionary)["career_log"] as Array
	assert_int(log.size()).is_equal(2)
	assert_str(str((log[0] as Dictionary).get("t", ""))).is_equal("draft")
	assert_str(str((log[1] as Dictionary).get("t", ""))).is_equal("released")


# 実CSVを正規化した直後の全選手で career_log に開始年以降の年が残っていないこと。経歴タブに
# 未来年が出る回帰の検出用 (全球団対象者ゼロバグと同根のデータ起因)。GameDb.players を見ないのは
# 共有状態のため他 suite のシーズン進行で開始年以降の正当なエントリが追記されるから (CSVから直接読む)。
func test_initial_seed_csv_career_log_has_no_future_years() -> void:
	var start_year: int = SeasonService.DEFAULT_START_YEAR
	var rows: Array = PSPlayerCsvIo.normalize_initial_seed_players(
		PSPlayerCsvIo.read_players(GameDb.CSV_PLAYER_PATH), start_year
	)
	var dated_entries: int = 0
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var source: Dictionary = row.get("source_data", {}) as Dictionary
		for entry_value in source.get(PSCareerLog.KEY, []) as Array:
			var entry_year: int = int((entry_value as Dictionary).get("y", 0))
			dated_entries += 1 if entry_year > 0 else 0
			assert_bool(entry_year < start_year).override_failure_message(
				"選手 %s の経歴に開始年以降の年 %d が残っています" % [str(row.get("name", "?")), entry_year]
			).is_true()
	assert_int(dated_entries).is_greater(0)


# --- 初期シード投手の変化球アーセナル ----------------------------------------
# 旧シード CSV には arsenal 列が無く、初期選手だけ変化球の実データを持たなかった
# (z 派生表示に頼るため球種構成に個性が無く、生成投手とも扱いが違った)。

func test_initial_seed_csv_pitchers_all_have_arsenal() -> void:
	var rows: Array = PSPlayerCsvIo.normalize_initial_seed_players(
		PSPlayerCsvIo.read_players(GameDb.CSV_PLAYER_PATH), SeasonService.DEFAULT_START_YEAR
	)
	var pitchers: int = 0
	var distinct_lines: Dictionary = {}
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("position", 0)) != 1:
			assert_array(row.get("arsenal", []) as Array).override_failure_message(
				"野手 %s に変化球が付いています" % str(row.get("name", "?"))
			).is_empty()
			continue
		pitchers += 1
		var arsenal: Array = row.get("arsenal", []) as Array
		assert_int(arsenal.size()).override_failure_message(
			"投手 %s の変化球が空です" % str(row.get("name", "?"))
		).is_greater_equal(PSPitchTypes.GENERATED_COUNT_MIN)
		var straight_count: int = 0
		for entry_value in arsenal:
			if str((entry_value as Dictionary).get("type", "")) == PSPitchTypes.FOUR_SEAM:
				straight_count += 1
		assert_int(straight_count).override_failure_message(
			"投手 %s の直球(ストレート)が %d 本です (全投手ちょうど1本)" % [str(row.get("name", "?")), straight_count]
		).is_equal(1)
		distinct_lines[PSPitchTypes.arsenal_line(arsenal)] = true
	assert_int(pitchers).is_greater(0)
	# 派生 (z から一意) と違い個性が出ること: 球種構成+グレードの組み合わせが十分に散る。
	assert_int(distinct_lines.size()).is_greater(int(float(pitchers) * 0.25))


# backfill は選手 ID 決定論。起動ごと/読み込み経路ごとにブレず、再正規化でも上書きしない (冪等)。
func test_initial_seed_arsenal_backfill_is_deterministic_and_idempotent() -> void:
	var row: Dictionary = {
		"id": 4242,
		"position": 1,
		"z_abilities": {"Pit_KCreate": 0.8, "Pit_LoftControl": -0.2, "Pit_BarrelDeny": 0.5, "Pit_EdgeRate": 0.3, "Pit_Stamina": 1.1},
	}
	var once: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	var again: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(row, 2026)
	assert_array(again.get("arsenal", []) as Array).is_equal(once.get("arsenal", []) as Array)
	var twice: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(once, 2026)
	assert_array(twice.get("arsenal", []) as Array).is_equal(once.get("arsenal", []) as Array)
	# 別 ID なら別のアーセナルになりうる (ID 依存であることの確認)。
	var other_row: Dictionary = row.duplicate(true)
	other_row["id"] = 4243
	var other: Dictionary = PSPlayerCsvIo.normalize_initial_seed_player(other_row, 2026)
	assert_int((other.get("arsenal", []) as Array).size()).is_greater(0)


# CSV は arsenal を JSON 1 セルで往復する。ここが落ちると世界エクスポートで変化球が消える。
func test_player_csv_roundtrip_preserves_arsenal() -> void:
	var path: String = "user://test_arsenal_roundtrip.csv"
	var arsenal: Array = [
		{"type": PSPitchTypes.FOUR_SEAM, "mastery": 1.25},
		{"type": PSPitchTypes.FORK, "mastery": -0.5},
	]
	var rows: Array = [{
		"id": 991, "name": "変化球 太郎", "position": 1, "team_id": 1,
		"z_abilities": {"Pit_KCreate": 0.4}, "source_data": {"draft_year": 2020},
		"arsenal": arsenal,
	}, {
		"id": 992, "name": "野手 次郎", "position": 5, "team_id": 1,
		"z_abilities": {"Bat_Impact": 0.4}, "source_data": {},
	}]
	assert_bool(PSPlayerCsvIo.write_players(path, rows)).is_true()
	var back: Array = PSPlayerCsvIo.read_players(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_int(back.size()).is_equal(2)
	var pitcher: Dictionary = back[0] as Dictionary
	assert_int((pitcher.get("arsenal", []) as Array).size()).is_equal(2)
	assert_str(str(((pitcher["arsenal"] as Array)[1] as Dictionary).get("type", ""))).is_equal(PSPitchTypes.FORK)
	assert_float(float(((pitcher["arsenal"] as Array)[0] as Dictionary).get("mastery", 0.0))).is_equal_approx(1.25, 0.0001)
	assert_array((back[1] as Dictionary).get("arsenal", []) as Array).is_empty()


func test_released_market_respects_foreign_held_cap() -> void:
	var open_team_players: Array = _released_market_foreign_cap_players(3)
	var open_result: Dictionary = ReleasedMarket.process_released_market(
		open_team_players,
		[_team(1), _team(2)],
		null,
		{"released": [{"player_id": 9100, "team_id": 1}]},
		0
	)
	assert_int(int(open_result.get("signed_count", 0))).is_equal(1)
	assert_int((open_team_players[open_team_players.size() - 1] as PSPlayer).team_id).is_equal(2)

	var capped_team_players: Array = _released_market_foreign_cap_players(4)
	var capped_result: Dictionary = ReleasedMarket.process_released_market(
		capped_team_players,
		[_team(1), _team(2)],
		null,
		{"released": [{"player_id": 9100, "team_id": 1}]},
		0
	)
	assert_int(int(capped_result.get("signed_count", 0))).is_equal(0)
	assert_int((capped_team_players[capped_team_players.size() - 1] as PSPlayer).team_id).is_equal(0)


func test_released_market_development_track_chance_rises_with_age_and_falls_with_value() -> void:
	# 年齢が上がるほど育成寄りになり、能力(value)が高いほど支配下側に戻る。
	var young: float = ReleasedMarket._development_track_chance(24, 55)
	var prime: float = ReleasedMarket._development_track_chance(29, 55)
	var old: float = ReleasedMarket._development_track_chance(38, 55)
	assert_float(young).is_less_equal(prime)
	assert_float(prime).is_less(old)
	var old_high_value: float = ReleasedMarket._development_track_chance(38, 90)
	assert_float(old_high_value).is_less(old)


func test_released_market_development_track_bypasses_shienka_limit() -> void:
	# 育成track の候補は支配下枠(70)が埋まっていても獲得でき、支配下枠を消費しない。
	var players: Array = _support_players(1, TeamFinance.SHIENKA_LIMIT)
	var released: PSPlayer = _player({"id": 9300, "team_id": 0, "age": 40, "source_data": {"released": true}})
	players.append(released)
	var entry: Dictionary = {
		"player_id": 9300,
		"foreign_player": false,
		"track": ReleasedMarket.TRACK_DEVELOPMENT,
	}
	assert_bool(ReleasedMarket._can_team_accept_candidate(players, 1, entry)).is_true()
	entry["track"] = ReleasedMarket.TRACK_SHIENKA
	assert_bool(ReleasedMarket._can_team_accept_candidate(players, 1, entry)).is_false()


func test_released_market_apply_signing_sets_development_flags_from_track() -> void:
	var players: Array = [_player({"id": 9301, "team_id": 0, "age": 40, "source_data": {"released": true}})]
	var state: Dictionary = {"signings": []}
	var entry: Dictionary = {"player_id": 9301, "track": ReleasedMarket.TRACK_DEVELOPMENT, "value": 40}
	ReleasedMarket._apply_signing(state, players, null, entry, 2, "cpu")
	var signed: PSPlayer = players[0] as PSPlayer
	assert_int(signed.team_id).is_equal(2)
	assert_bool(signed.development_player).is_true()
	assert_str(signed.registered_roster).is_equal("育成")
	assert_int(signed.salary).is_equal(Offseason.DEVELOPMENT_CONTRACT_SALARY)


func test_released_market_contract_salary_keeps_cheap_players_and_cuts_high_salary() -> void:
	for salary in [350, 800, 1000]:
		assert_int(ReleasedMarket._released_contract_salary(salary)).is_equal(salary)

	assert_int(ReleasedMarket._released_contract_salary(2000)).is_equal(1200)
	assert_int(ReleasedMarket._released_contract_salary(3000)).is_equal(1400)
	assert_int(ReleasedMarket._released_contract_salary(10000)).is_equal(2800)
	assert_int(ReleasedMarket._released_contract_salary(30000)).is_equal(6800)
	assert_int(ReleasedMarket._released_contract_salary(1003)).is_equal(1000)


func test_released_market_available_candidates_refresh_new_contract_salary() -> void:
	var released: PSPlayer = _player({"id": 9303, "team_id": 0, "salary": 10000, "source_data": {"released": true}})
	var stale_entry: Dictionary = {
		"player_id": released.id,
		"from_team": 1,
		"position": released.position,
		"foreign_player": false,
		"track": ReleasedMarket.TRACK_SHIENKA,
		"salary": released.salary,
		"available": true,
	}
	var state: Dictionary = {"user_team_id": 2, "candidates": [stale_entry], "signings": []}
	var candidates: Array = ReleasedMarket.available_user_candidates(state, [released], [_team(1), _team(2)])

	assert_int(candidates.size()).is_equal(1)
	assert_int(int((candidates[0] as Dictionary).get("salary", 0))).is_equal(2800)
	assert_int(int(stale_entry.get("salary", 0))).is_equal(2800)


func test_released_market_signing_salary_is_locked_until_next_offseason() -> void:
	var signed: PSPlayer = _player({"id": 9302, "team_id": 0, "salary": 10000, "source_data": {"released": true}})
	var entry: Dictionary = {
		"player_id": signed.id,
		"from_team": 1,
		"track": ReleasedMarket.TRACK_SHIENKA,
		"salary": ReleasedMarket._released_contract_salary(signed.salary),
		"value": 60,
	}
	ReleasedMarket._apply_signing({"year": 2026, "signings": []}, [signed], null, entry, 2, "cpu")

	assert_int(signed.salary).is_equal(2800)
	assert_int(int(signed.source_data.get("released_contract_salary", 0))).is_equal(2800)
	assert_bool(Offseason._contract_salary_is_locked(signed, 2026)).is_true()
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var contract_result: Dictionary = Offseason.process_contract_renewal([signed], [], season)
	assert_int(signed.salary).is_equal(2800)
	assert_int(int(contract_result.get("raises_count", -1))).is_equal(0)
	assert_int(int(contract_result.get("cuts_count", -1))).is_equal(0)
	assert_bool(Offseason._contract_salary_is_locked(signed, 2027)).is_false()


# 今オフ指名したドラフト新人は指名時の年俸のまま来季を迎える。前年の成績を持たないため
# 査定を通すと市場価値 floor まで落ち、1試合も出ないうちに減額されてしまう。
func test_contract_renewal_keeps_draft_rookie_salary() -> void:
	var rookie: PSPlayer = _player({
		"id": 9304, "team_id": 1, "salary": 1500, "years": 1, "age": 18,
		"source_data": {"draft_year": 2026, "draft_round": 1, "rookie_year": true},
	})
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	assert_bool(Offseason._contract_salary_is_locked(rookie, 2026)).is_true()
	var contract_result: Dictionary = Offseason.process_contract_renewal([rookie], [], season)
	assert_int(rookie.salary).is_equal(1500)
	assert_int(int(contract_result.get("cuts_count", -1))).is_equal(0)
	# 翌オフ (1年目の成績が付いた後) からは通常の査定へ戻る。
	assert_bool(Offseason._contract_salary_is_locked(rookie, 2027)).is_false()


# --- 複数年契約ロック (契約基盤 Step1) ---------------------------------------

func test_contract_renewal_skips_salary_reassessment_while_multi_year_locked() -> void:
	var locked: PSPlayer = _player({
		"id": 9420, "team_id": 1, "salary": 300, "years": 3,
		"source_data": {"contract_end_year": 2028, "contract_signed_year": 2026, "contract_total_years": 3},
	})
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	Offseason.process_contract_renewal([locked], [], season)
	assert_int(locked.salary).is_equal(300)
	assert_bool(locked.is_multi_year_locked_offseason(2026)).is_true()

	# 契約最終年 (2028) のオフは契約満了扱いでロックが外れ、再査定が走る。
	season.year = 2028
	Offseason.process_contract_renewal([locked], [], season)
	assert_bool(locked.is_multi_year_locked_offseason(2028)).is_false()
	assert_int(locked.salary).is_not_equal(300)


func test_is_multi_year_locked_in_season_covers_final_contract_year() -> void:
	var player: PSPlayer = _player({"id": 9421, "team_id": 1, "source_data": {"contract_end_year": 2028}})
	assert_bool(player.is_multi_year_locked_in_season(2027)).is_true()
	# シーズン中は契約最終年もロック対象 (>=)。オフの判定 (>) より1年長い。
	assert_bool(player.is_multi_year_locked_in_season(2028)).is_true()
	assert_bool(player.is_multi_year_locked_in_season(2029)).is_false()
	assert_bool(player.is_multi_year_locked_offseason(2027)).is_true()
	assert_bool(player.is_multi_year_locked_offseason(2028)).is_false()
	assert_int(player.contract_years_remaining(2026)).is_equal(2)
	assert_int(player.contract_years_remaining(2028)).is_equal(0)
	assert_int(player.contract_years_remaining(2030)).is_equal(0)


func test_compute_release_candidates_excludes_multi_year_locked_player() -> void:
	var players: Array = []
	var locked: PSPlayer = _player_with_z(9430, 1, 6, false, 0.0)
	locked.age = 33
	locked.source_data["contract_end_year"] = 2027
	players.append(locked)
	for i in range(5):
		var stronger: PSPlayer = _player_with_z(9440 + i, 1, 6, false, 1.0)
		stronger.age = 28
		players.append(stronger)
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, 1, season)
	assert_array(cut_ids).not_contains(locked.id)


func test_reject_locked_release_or_demote_blocks_locked_player_only() -> void:
	var locked: PSPlayer = _player({"id": 9450, "team_id": 1, "source_data": {"contract_end_year": 2028}})
	var free_player: PSPlayer = _player({"id": 9451, "team_id": 1})
	var players: Array = [locked, free_player]

	var blocked_release: Dictionary = Offseason.reject_locked_release_or_demote(players, [locked.id], [], 2026)
	assert_bool(bool(blocked_release.get("ok", true))).is_false()
	assert_str(str(blocked_release.get("message", ""))).contains("複数年契約")

	var blocked_demote: Dictionary = Offseason.reject_locked_release_or_demote(players, [], [locked.id], 2026)
	assert_bool(bool(blocked_demote.get("ok", true))).is_false()

	var allowed: Dictionary = Offseason.reject_locked_release_or_demote(players, [free_player.id], [free_player.id], 2026)
	assert_bool(bool(allowed.get("ok", false))).is_true()

	# 契約最終年のオフはロック対象外なので拒否されない。
	var allowed_final_year: Dictionary = Offseason.reject_locked_release_or_demote(players, [locked.id], [], 2028)
	assert_bool(bool(allowed_final_year.get("ok", false))).is_true()


# --- 外国人契約市場 (残留/引き抜き/退団) -------------------------------------

func test_foreign_contract_market_entries_exclude_locked_players() -> void:
	var locked: PSPlayer = _player_with_z(9460, 1, 3, false, -1.0)
	locked.foreign_player = true
	locked.age = 30
	locked.source_data["contract_end_year"] = 2027
	var open_player: PSPlayer = _player_with_z(9461, 1, 4, false, -1.0)
	open_player.foreign_player = true
	open_player.age = 30
	var players: Array = [locked, open_player]
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [_team(1)], season, 1)
	assert_str(str(state.get("phase", ""))).is_equal("contract")
	var entry_ids: Array = []
	for row in state.get("contract_entries", []) as Array:
		entry_ids.append(int((row as Dictionary).get("player_id", 0)))
	assert_array(entry_ids).not_contains(locked.id)
	assert_array(entry_ids).contains(open_player.id)


func test_foreign_contract_market_skips_contract_phase_when_no_entries() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state([], [_team(1)], season, 1)
	assert_str(str(state.get("phase", ""))).is_equal("scout")


func test_foreign_scout_signing_sets_single_year_contract_keys() -> void:
	Rng.set_seed_value(20260717)
	var team: PSTeam = _team(1)
	var players: Array = []
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [team], season, 1)
	assert_str(str(state.get("phase", ""))).is_equal("scout")
	ForeignPlayerService.configure_user_scout_request(state, "first", "power", "standard")
	var candidates: Array = ForeignPlayerService.available_user_candidates(state, players, [team])
	var candidate_id: int = int((candidates[0] as Dictionary).get("candidate_id", 0))
	var result: Dictionary = ForeignPlayerService.submit_user_foreign_decision(state, players, [team], season, candidate_id, "sign")
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_int(players.size()).is_equal(1)
	var signed: PSPlayer = players[0] as PSPlayer
	assert_int(int(signed.source_data.get("contract_end_year", 0))).is_equal(2027)
	assert_int(int(signed.source_data.get("contract_total_years", 0))).is_equal(1)
	assert_int(int(signed.source_data.get("contract_signed_year", 0))).is_equal(2026)


func test_foreign_contract_cpu_retain_offer_uses_shared_release_decision() -> void:
	var team: PSTeam = _team(1)
	var players: Array = [
		_player({"id": 1, "team_id": 1, "salary": 5000}),
		_player({"id": 2, "team_id": 1, "salary": 5000}),
	]
	var release_entry: Dictionary = {
		"player_id": 1, "from_team_id": 1,
		"value": 80, "cpu_release_candidate": true, "cpu_regular_candidate": true,
		"market_salary": 5000, "max_years": 3,
	}
	var keep_entry: Dictionary = {
		"player_id": 2, "from_team_id": 1,
		"value": 40, "cpu_release_candidate": false, "cpu_regular_candidate": true,
		"market_salary": 5000, "max_years": 3,
	}
	var bench_entry: Dictionary = keep_entry.duplicate(true)
	bench_entry["cpu_regular_candidate"] = false
	assert_bool(ForeignPlayerService._cpu_retain_offer(release_entry, players, [team]).is_empty()).is_true()
	assert_bool(ForeignPlayerService._cpu_retain_offer(keep_entry, players, [team]).is_empty()).is_false()
	assert_bool(ForeignPlayerService._cpu_retain_offer(bench_entry, players, [team]).is_empty()).is_true()


func test_foreign_contract_regular_depth_uses_relative_season_performance() -> void:
	var top: PSPlayer = _player_with_z(3010, 1, 3, false, 0.8)
	var dh: PSPlayer = _player_with_z(3011, 1, 3, false, 0.8)
	var bench: PSPlayer = _player_with_z(3012, 1, 3, false, 0.8)
	for player in [top, dh, bench]:
		(player as PSPlayer).foreign_player = true
		(player as PSPlayer).age = 28
	var players: Array = [top, dh, bench]
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	var records: Array = []
	var top_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(top, season.year, season.season_number)
	top_record.batter_stats = PSBatterStats.from_dict({
		"games": 140, "plate_appearances": 600, "at_bats": 520, "hits": 155,
		"doubles": 30, "home_runs": 25, "walks": 65, "runs_batted_in": 90,
	})
	records.append(top_record)
	var dh_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(dh, season.year, season.season_number)
	dh_record.batter_stats = PSBatterStats.from_dict({
		"games": 120, "plate_appearances": 480, "at_bats": 420, "hits": 110,
		"doubles": 20, "home_runs": 15, "walks": 45, "runs_batted_in": 60,
	})
	records.append(dh_record)
	var bench_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(bench, season.year, season.season_number)
	bench_record.batter_stats = PSBatterStats.from_dict({
		"games": 90, "plate_appearances": 320, "at_bats": 290, "hits": 58,
		"doubles": 8, "home_runs": 4, "walks": 20, "runs_batted_in": 25,
	})
	records.append(bench_record)

	var previous_records: Dictionary = {}
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		var key: String = "%d:%d:%d" % [record.player_id, season.year, season.season_number]
		previous_records[key] = RecordStore.player_records.get(key, null)
		RecordStore.set_player_record(record, key)

	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [_team(1)], season, 0)
	var regular_by_id: Dictionary = {}
	for entry_value in state.get("contract_entries", []) as Array:
		var entry: Dictionary = entry_value as Dictionary
		regular_by_id[int(entry.get("player_id", 0))] = bool(entry.get("cpu_regular_candidate", false))
	assert_bool(bool(regular_by_id.get(top.id, false))).is_true()
	assert_bool(bool(regular_by_id.get(dh.id, false))).is_true()
	assert_bool(bool(regular_by_id.get(bench.id, true))).is_false()
	assert_bool(Offseason.would_release_player_for_team(players, 1, bench, season)).is_false()

	for key_value in previous_records.keys():
		var key: String = str(key_value)
		var previous: Variant = previous_records[key]
		if previous == null:
			RecordStore.erase_player_record_by_key(key)
		else:
			RecordStore.set_player_record(previous as PSPlayerSeasonRecord, key)


func test_foreign_contract_cpu_replaces_shared_release_candidate_through_scouting() -> void:
	Rng.set_seed_value(20260719)
	var player: PSPlayer = _player_with_z(3025, 1, 3, false, -1.5)
	player.foreign_player = true
	player.age = 35
	player.salary = 5000
	var players: Array = [player]
	for i in range(4):
		var depth_player: PSPlayer = _player_with_z(3030 + i, 1, 3, false, 2.0)
		depth_player.age = 28
		players.append(depth_player)
	var team: PSTeam = _team(1)
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, season.year, season.season_number)
	var record_key: String = "%d:%d:%d" % [player.id, season.year, season.season_number]
	var previous_record: Variant = RecordStore.player_records.get(record_key, null)
	RecordStore.set_player_record(record, record_key)

	var state: Dictionary = ForeignPlayerService.create_foreign_market_state(players, [team], season, 0)
	var entry: Dictionary = (state.get("contract_entries", []) as Array)[0] as Dictionary
	assert_bool(Offseason.would_release_player_for_team(players, team.id, player, season)).is_true()
	assert_bool(bool(entry.get("cpu_release_candidate", false))).is_true()
	ForeignPlayerService.complete_foreign_market_automatically(state, players, [team], season, 0)

	var contract_results: Array = state.get("contract_signings", []) as Array
	assert_str(str((contract_results[0] as Dictionary).get("outcome", ""))).is_equal("departed")
	assert_int((state.get("signings", []) as Array).size()).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)
	assert_int(TeamFinance.foreign_player_count(players, team.id)).is_equal(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM)

	if previous_record == null:
		RecordStore.erase_player_record_by_key(record_key)
	else:
		RecordStore.set_player_record(previous_record as PSPlayerSeasonRecord, record_key)


func test_foreign_cpu_scout_uses_shared_release_decision_for_candidates() -> void:
	var players: Array = []
	for i in range(4):
		var depth_player: PSPlayer = _player_with_z(3060 + i, 1, 3, false, 2.0)
		depth_player.age = 28
		players.append(depth_player)
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	var weak: PSPlayer = _player_with_z(3070, 0, 3, false, -2.0)
	weak.foreign_player = true
	weak.age = 35
	weak.salary = 40000
	var weak_candidate: Dictionary = {
		"salary": weak.salary,
		"display_player_data": weak.to_dict(),
	}
	assert_bool(Offseason.would_release_player_for_team(players, 1, weak, season)).is_true()
	assert_bool(ForeignPlayerService._cpu_scout_candidate_viable(weak_candidate, players, 1, season)).is_false()

	var strong: PSPlayer = _player_with_z(3071, 0, 3, false, 2.0)
	strong.foreign_player = true
	strong.age = 28
	strong.salary = 5000
	var strong_candidate: Dictionary = {
		"salary": strong.salary,
		"display_player_data": strong.to_dict(),
	}
	assert_bool(Offseason.would_release_player_for_team(players, 1, strong, season)).is_false()
	assert_bool(ForeignPlayerService._cpu_scout_candidate_viable(strong_candidate, players, 1, season)).is_true()


func test_foreign_contract_resolution_home_wins_tie_via_loyalty() -> void:
	var player: PSPlayer = _player({"id": 3001, "team_id": 1, "salary": 5000, "age": 30, "foreign_player": true})
	var players: Array = [player]
	var teams: Array = [_team(1), _team(2)]
	var entry: Dictionary = {"player_id": 3001, "from_team_id": 1, "value": 60, "market_salary": 8000, "max_years": 3}
	var offers: Array = [
		{"source": "retain", "team_id": 1, "years": 1, "salary": 8000, "is_home": true},
		{"source": "poach", "team_id": 2, "years": 1, "salary": 8000, "is_home": false},
	]
	var applied: Dictionary = ForeignPlayerService._apply_best_contract_offer(players, teams, entry, offers, 2026)
	assert_str(str(applied.get("outcome", ""))).is_equal("retained")
	assert_int(player.team_id).is_equal(1)


func test_foreign_contract_resolution_poach_moves_team_and_contract_keys() -> void:
	var player: PSPlayer = _player({"id": 3002, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = [player]
	var teams: Array = [_team(1), _team(2)]
	var entry: Dictionary = {"player_id": 3002, "from_team_id": 1, "value": 70, "market_salary": 8000, "max_years": 3}
	var offers: Array = [
		{"source": "retain", "team_id": 1, "years": 1, "salary": 8000, "is_home": true},
		{"source": "poach", "team_id": 2, "years": 2, "salary": 20000, "is_home": false},
	]
	var applied: Dictionary = ForeignPlayerService._apply_best_contract_offer(players, teams, entry, offers, 2026)
	assert_str(str(applied.get("outcome", ""))).is_equal("poached")
	assert_int(player.team_id).is_equal(2)
	assert_int(int(player.source_data.get("contract_end_year", 0))).is_equal(2028)
	assert_int(int(player.source_data.get("contract_total_years", 0))).is_equal(2)


func test_foreign_contract_poach_blocked_by_foreign_slot_cap() -> void:
	var player: PSPlayer = _player({"id": 3003, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = [player]
	for i in range(ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM):
		players.append(_player({"id": 3100 + i, "team_id": 2, "foreign_player": true}))
	var teams: Array = [_team(1), _team(2)]
	var entry: Dictionary = {"player_id": 3003, "from_team_id": 1, "value": 70, "market_salary": 8000, "max_years": 3}
	var offers: Array = [
		{"source": "poach", "team_id": 2, "years": 1, "salary": 20000, "is_home": false},
	]
	var applied: Dictionary = ForeignPlayerService._apply_best_contract_offer(players, teams, entry, offers, 2026)
	assert_str(str(applied.get("outcome", ""))).is_equal("departed")
	assert_int(player.team_id).is_equal(0)


func test_foreign_contract_poach_blocked_by_shienka_limit() -> void:
	var player: PSPlayer = _player({"id": 3004, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = _support_players(2, TeamFinance.SHIENKA_LIMIT)
	players.append(player)
	var teams: Array = [_team(1), _team(2)]
	var entry: Dictionary = {"player_id": 3004, "from_team_id": 1, "value": 70, "market_salary": 8000, "max_years": 3}
	var offers: Array = [
		{"source": "poach", "team_id": 2, "years": 1, "salary": 20000, "is_home": false},
	]
	var applied: Dictionary = ForeignPlayerService._apply_best_contract_offer(players, teams, entry, offers, 2026)
	assert_str(str(applied.get("outcome", ""))).is_equal("departed")


func test_foreign_contract_poach_blocked_by_budget() -> void:
	var player: PSPlayer = _player({"id": 3005, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = [player]
	var poor_team: PSTeam = PSTeam.from_dict({"id": 2, "name": "Team 2", "short_name": "T2", "league": "league1", "funds": 1000})
	var teams: Array = [_team(1), poor_team]
	var entry: Dictionary = {"player_id": 3005, "from_team_id": 1, "value": 70, "market_salary": 8000, "max_years": 3}
	var offers: Array = [
		{"source": "poach", "team_id": 2, "years": 1, "salary": 20000, "is_home": false},
	]
	var applied: Dictionary = ForeignPlayerService._apply_best_contract_offer(players, teams, entry, offers, 2026)
	assert_str(str(applied.get("outcome", ""))).is_equal("departed")


func test_foreign_contract_departed_player_excluded_from_released_market() -> void:
	var player: PSPlayer = _player({"id": 3006, "team_id": 1, "salary": 5000, "age": 34, "foreign_player": true})
	ForeignPlayerService._apply_contract_departure(player, 1, 2026)
	assert_bool(player.is_retired()).is_true()
	assert_bool(ReleasedMarket._is_released_market_player(player)).is_false()


func test_foreign_contract_apply_result_sets_multi_year_keys() -> void:
	var player: PSPlayer = _player({"id": 3007, "team_id": 1, "salary": 5000, "foreign_player": true})
	ForeignPlayerService._apply_contract_result(player, 1, true, 3, 12000, 2026)
	assert_int(int(player.source_data.get("contract_end_year", 0))).is_equal(2029)
	assert_int(int(player.source_data.get("contract_total_years", 0))).is_equal(3)
	assert_int(int(player.source_data.get("contract_signed_year", 0))).is_equal(2026)
	assert_int(player.salary).is_equal(12000)


# auto_user_team=false (「契約市場を確定して次へ」既定) はユーザー球団の未提示エントリへ
# CPU残留提示を生成しない (=他球団に引き抜かれない限り退団)。auto_user_team=true
# (「すべてAIに任せる」) は他球団と同じ基準 (_cpu_retain_offer) で残留提示を生成する。
func test_build_contract_offers_skips_user_retain_unless_auto_user_team() -> void:
	var team: PSTeam = _team(1)
	var players: Array = [_player({"id": 4001, "team_id": 1, "salary": 5000, "foreign_player": true})]
	var entry: Dictionary = {
		"player_id": 4001, "from_team_id": 1, "value": 60,
		"market_salary": 8000, "max_years": 3, "user_offer": {},
	}
	var offers_default: Array = ForeignPlayerService._build_contract_offers(entry, players, [team], {}, 1, false)
	assert_int(offers_default.size()).is_equal(0)
	var offers_auto: Array = ForeignPlayerService._build_contract_offers(entry, players, [team], {}, 1, true)
	assert_int(offers_auto.size()).is_equal(1)
	assert_str(str((offers_auto[0] as Dictionary).get("source", ""))).is_equal("retain")
	# 他球団 (home != user_team_id) は auto_user_team に関係なく従来どおり自動残留提示が出る。
	var cpu_entry: Dictionary = entry.duplicate(true)
	cpu_entry["player_id"] = 4001
	var cpu_offers: Array = ForeignPlayerService._build_contract_offers(cpu_entry, players, [team], {}, 2, false)
	assert_int(cpu_offers.size()).is_equal(1)


# resolve_foreign_contract_market を auto_user_team=false/true で通した end-to-end 確認。
# false: 未提示の自軍満了者は残留提示が無く退団する。true: CPUと同じ基準で残留する。
func test_resolve_foreign_contract_market_auto_user_team_flag_changes_outcome() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1

	var player_a: PSPlayer = _player({"id": 3020, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var state_a: Dictionary = {
		"version": 4, "phase": "contract", "year": 2026, "user_team_id": 1, "complete": false,
		"contract_entries": [{
			"player_id": 3020, "from_team_id": 1, "value": 60,
			"market_salary": 8000, "max_years": 3, "user_offer": {}, "resolved": false,
		}],
		"contract_signings": [],
	}
	var result_a: Dictionary = ForeignPlayerService.resolve_foreign_contract_market(state_a, [player_a], [_team(1)], season, 1, false, false)
	assert_bool(bool(result_a.get("ok", false))).is_true()
	var signings_a: Array = state_a.get("contract_signings", []) as Array
	assert_int(signings_a.size()).is_equal(1)
	assert_str(str((signings_a[0] as Dictionary).get("outcome", ""))).is_equal("departed")
	assert_bool(player_a.is_retired()).is_true()

	var player_b: PSPlayer = _player({"id": 3021, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var state_b: Dictionary = {
		"version": 4, "phase": "contract", "year": 2026, "user_team_id": 1, "complete": false,
		"contract_entries": [{
			"player_id": 3021, "from_team_id": 1, "value": 60,
			"market_salary": 8000, "max_years": 3, "user_offer": {}, "resolved": false,
		}],
		"contract_signings": [],
	}
	var result_b: Dictionary = ForeignPlayerService.resolve_foreign_contract_market(state_b, [player_b], [_team(1)], season, 1, true, false)
	assert_bool(bool(result_b.get("ok", false))).is_true()
	var signings_b: Array = state_b.get("contract_signings", []) as Array
	assert_int(signings_b.size()).is_equal(1)
	assert_str(str((signings_b[0] as Dictionary).get("outcome", ""))).is_equal("retained")
	assert_int(player_b.team_id).is_equal(1)


# 契約市場の4段フェーズ ("contract"→"contract_result"→"scout"→"scout_result") を
# resolve_foreign_contract_market / advance_foreign_contract_result /
# complete_foreign_market_automatically(show_result) / advance_foreign_scout_result で
# 順に遷移させ、結果パネル ("次へ") を経てから complete が立つことを確認する。
func test_foreign_market_four_phase_transition_via_result_panels() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var player: PSPlayer = _player({"id": 3030, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = [player]
	var teams: Array = [_team(1)]
	var state: Dictionary = {
		"version": 4, "phase": "contract", "year": 2026, "user_team_id": 1, "complete": false,
		"contract_entries": [{
			"player_id": 3030, "from_team_id": 1, "value": 60,
			"market_salary": 8000, "max_years": 3, "user_offer": {}, "resolved": false,
		}],
		"contract_signings": [],
		"next_player_id": 9000, "next_candidate_id": 1, "next_request_id": 1,
		"candidates": [], "signings": [], "requests": [], "user_request": {}, "user_candidate_ids": [],
	}

	# 1. contract -> contract_result (show_result 既定 true)。
	var resolve_result: Dictionary = ForeignPlayerService.resolve_foreign_contract_market(state, players, teams, season, 1, true)
	assert_bool(bool(resolve_result.get("ok", false))).is_true()
	assert_str(str(state.get("phase", ""))).is_equal("contract_result")
	assert_bool(bool(state.get("complete", false))).is_false()

	# 2. contract_result -> scout ("次へ")。
	var advance_contract: Dictionary = ForeignPlayerService.advance_foreign_contract_result(state)
	assert_bool(bool(advance_contract.get("ok", false))).is_true()
	assert_str(str(state.get("phase", ""))).is_equal("scout")

	# 3. scout -> scout_result (「補強を終了」相当、show_result=true)。
	var complete_result: Dictionary = ForeignPlayerService.complete_foreign_market_automatically(state, players, teams, season, 1, true)
	assert_bool(bool(complete_result.get("ok", false))).is_true()
	assert_str(str(state.get("phase", ""))).is_equal("scout_result")
	assert_bool(bool(state.get("complete", false))).is_false()

	# 4. scout_result -> complete ("次へ")。
	var advance_scout: Dictionary = ForeignPlayerService.advance_foreign_scout_result(state)
	assert_bool(bool(advance_scout.get("ok", false))).is_true()
	assert_bool(bool(state.get("complete", false))).is_true()


# 「すべてAIに任せる」相当 (show_result=false) は結果パネルに止まらず直接 scout/complete へ進む。
func test_foreign_market_show_result_false_skips_result_phases() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var player: PSPlayer = _player({"id": 3031, "team_id": 1, "salary": 5000, "age": 28, "foreign_player": true})
	var players: Array = [player]
	var teams: Array = [_team(1)]
	var state: Dictionary = {
		"version": 4, "phase": "contract", "year": 2026, "user_team_id": 1, "complete": false,
		"contract_entries": [{
			"player_id": 3031, "from_team_id": 1, "value": 60,
			"market_salary": 8000, "max_years": 3, "user_offer": {}, "resolved": false,
		}],
		"contract_signings": [],
		"next_player_id": 9000, "next_candidate_id": 1, "next_request_id": 1,
		"candidates": [], "signings": [], "requests": [], "user_request": {}, "user_candidate_ids": [],
	}
	ForeignPlayerService.resolve_foreign_contract_market(state, players, teams, season, 1, true, false)
	assert_str(str(state.get("phase", ""))).is_equal("scout")
	ForeignPlayerService.complete_foreign_market_automatically(state, players, teams, season, 0, false)
	assert_str(str(state.get("phase", ""))).is_equal("scout")
	assert_bool(bool(state.get("complete", false))).is_true()


# 対象ゼロ (満了外国人なし) なら契約市場フェーズを両方スキップし、最初から scout で始まる
# (create_foreign_market_state 時点で判定、resolve/contract_result を経由しない)。
func test_foreign_market_skips_both_contract_phases_when_no_entries() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var state: Dictionary = ForeignPlayerService.create_foreign_market_state([], [_team(1)], season, 1)
	assert_str(str(state.get("phase", ""))).is_equal("scout")
	# scout フェーズ以外からの遷移関数は対象が無いので no-op (ok:false) を返す。
	var advance_contract: Dictionary = ForeignPlayerService.advance_foreign_contract_result(state)
	assert_bool(bool(advance_contract.get("ok", true))).is_false()


# --- 契約年数の決定 (FA市場の直後) ------------------------------------------

# 対象は ①今オフFA権を新規取得して宣言しなかった選手 ②複数年契約が今オフ満了した選手
# ③FA宣言したが引き取り手がなく残留した選手 の3種。
func _contract_years_player(id: int, team_id: int, z_value: float, age: int = 24) -> PSPlayer:
	var p: PSPlayer = _player_with_z(id, team_id, 3, false, z_value)
	p.age = age
	p.source_data["fa_eligible_year"] = 2026
	return p


func test_contract_years_pool_covers_new_fa_contract_end_and_fa_returned() -> void:
	var new_fa: PSPlayer = _contract_years_player(9500, 1, 2.5, 27)

	var contract_end: PSPlayer = _player_with_z(9501, 1, 3, false, 2.5)
	contract_end.source_data["contract_total_years"] = 3
	contract_end.source_data["contract_end_year"] = 2026

	var fa_returned: PSPlayer = _player_with_z(9502, 1, 3, false, 2.5)
	fa_returned.source_data["fa_declared_year"] = 2026
	fa_returned.source_data["fa_returned_year"] = 2026
	fa_returned.source_data["fa_contract_salary"] = 12000

	# FA権未取得 (今オフ何も起きていない) は自動的に単年なので対象外。
	var untouched: PSPlayer = _player_with_z(9503, 1, 3, false, 2.5)

	# 宣言して他球団と契約した選手は交渉時に年数が決まっているので対象外。
	var declared_moved: PSPlayer = _contract_years_player(9504, 1, 2.5)
	declared_moved.source_data["fa_declared_year"] = 2026

	# 複数年契約が継続中 (満了年ではない) の選手も対象外。
	var still_locked: PSPlayer = _contract_years_player(9505, 1, 2.5)
	still_locked.source_data["contract_total_years"] = 3
	still_locked.source_data["contract_end_year"] = 2028

	var foreign: PSPlayer = _contract_years_player(9506, 1, 2.5)
	foreign.foreign_player = true

	var dev: PSPlayer = _player_with_z(9507, 1, 3, true, 2.5)
	dev.source_data["fa_eligible_year"] = 2026

	var players: Array = [new_fa, contract_end, fa_returned, untouched, declared_moved, still_locked, foreign, dev]
	var pool: Array = Offseason._build_contract_years_pool(players, 2026)
	var ids: Array = []
	var reasons: Array = []
	for row in pool:
		ids.append(int((row as Dictionary).get("player_id", 0)))
		reasons.append(str((row as Dictionary).get("reason", "")))
	assert_array(ids).contains_exactly_in_any_order([9500, 9501, 9502])
	assert_array(reasons).contains_exactly_in_any_order(["new_fa", "contract_end", "fa_returned"])


# 年齢上限が1年 (36歳以上) の選手は選べる年数が単年しかないので、プールに入れずその場で確定する。
# 満了した複数年契約のキーもここで消え、翌オフに「契約満了」で再検出されない。
func test_contract_years_pool_auto_resolves_age_capped_player_to_single_year() -> void:
	var old_player: PSPlayer = _player_with_z(9510, 1, 12, false, 2.5)
	old_player.age = 38
	old_player.source_data["contract_total_years"] = 3
	old_player.source_data["contract_end_year"] = 2026

	var pool: Array = Offseason._build_contract_years_pool([old_player], 2026)
	assert_array(pool).is_empty()
	assert_bool(old_player.source_data.has("contract_end_year")).is_false()
	assert_bool(old_player.source_data.has("contract_total_years")).is_false()
	var pool_next_year: Array = Offseason._build_contract_years_pool([old_player], 2027)
	assert_array(pool_next_year).is_empty()


func test_round_salary_2sig_boundaries() -> void:
	assert_int(Offseason.round_salary_2sig(18602)).is_equal(19000)
	assert_int(Offseason.round_salary_2sig(9242)).is_equal(9200)
	assert_int(Offseason.round_salary_2sig(4383)).is_equal(4400)
	assert_int(Offseason.round_salary_2sig(12347)).is_equal(12000)
	assert_int(Offseason.round_salary_2sig(440)).is_equal(440)
	assert_int(Offseason.round_salary_2sig(350)).is_equal(350)
	assert_int(Offseason.round_salary_2sig(99)).is_equal(99)
	assert_int(Offseason.round_salary_2sig(100)).is_equal(100)
	assert_int(Offseason.round_salary_2sig(0)).is_equal(0)


# _compute_new_salary は裁定移動+減額制限+clampの最終値を2桁有効数字へ丸める。
# 昇給方向 (target > old) で丸めが効く代表ケースを確認する。
func test_compute_new_salary_rounds_to_2_significant_figures() -> void:
	var player: PSPlayer = _player_with_z(9700, 1, 3, false, 2.0)
	player.salary = 4383
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	var new_salary: int = Offseason._compute_new_salary(player, record, 0.0)
	assert_int(new_salary).is_equal(Offseason.round_salary_2sig(new_salary))


# FA提示年俸 (_offer_salary) は市場価値×ランク倍率(1.05/1.15/1.25)を2桁有効数字へ丸めた値になる。
# 丸め前の生値 (12347*1.05=12964.35→12964) と異なることも確認し、実際に丸めが効いていることを示す。
func test_fa_offer_salary_rounds_to_2_significant_figures() -> void:
	var offer: int = FaMarketService._offer_salary(4000, 12347, "C")
	assert_int(offer).is_equal(Offseason.round_salary_2sig(offer))
	assert_int(offer).is_not_equal(12964)
	assert_int(offer).is_equal(13000)


# 外国人契約市場の提示年俸 (_offer_salary) も複数年プレミアム適用後に2桁有効数字へ丸める。
# base=9242, 3年 (premium 0.05*2=0.10) -> raw 9242*1.10=10166.2→round 10166 -> 2桁丸め 10000。
func test_foreign_offer_salary_rounds_to_2_significant_figures() -> void:
	var offer: int = ForeignPlayerService._offer_salary(9242, 3)
	assert_int(offer).is_equal(Offseason.round_salary_2sig(offer))
	assert_int(offer).is_not_equal(10166)
	assert_int(offer).is_equal(10000)


func test_contract_years_salary_applies_multi_year_premium() -> void:
	assert_int(Offseason._contract_years_salary(10000, 1)).is_equal(10000)
	assert_int(Offseason._contract_years_salary(10000, 3)).is_equal(11000)


# CPUの年数は value のティアで決まり、年齢上限でクランプされる。
func test_cpu_contract_years_uses_value_tiers_and_age_cap() -> void:
	var team: PSTeam = PSTeam.from_dict({"id": 1, "name": "T1", "short_name": "T1", "league": "league1", "funds": 500000})
	var star: Dictionary = {"value": 80, "max_years": 4, "base_salary": 10000, "current_salary": 10000}
	assert_int(Offseason._cpu_contract_years(star, [], team)).is_equal(4)
	var mid: Dictionary = {"value": 64, "max_years": 4, "base_salary": 10000, "current_salary": 10000}
	assert_int(Offseason._cpu_contract_years(mid, [], team)).is_equal(2)
	var fringe: Dictionary = {"value": 50, "max_years": 4, "base_salary": 10000, "current_salary": 10000}
	assert_int(Offseason._cpu_contract_years(fringe, [], team)).is_equal(1)
	# 年齢上限 (33-35歳=2年) がティアより短ければそちらが効く。
	var old_star: Dictionary = {"value": 80, "max_years": 2, "base_salary": 10000, "current_salary": 10000}
	assert_int(Offseason._cpu_contract_years(old_star, [], team)).is_equal(2)


# 予算に収まらない年数は1年ずつ削られ、最終的に単年へ落ちる。
# 増額分 (提示額 - 現年俸) が判定対象なので、大幅昇給になる候補で確かめる。
func test_cpu_contract_years_falls_back_to_single_year_when_over_budget() -> void:
	var star: Dictionary = {"value": 80, "max_years": 4, "base_salary": 10000, "current_salary": 5000}
	var rich: PSTeam = PSTeam.from_dict({"id": 1, "name": "T1", "short_name": "T1", "league": "league1", "funds": 500000})
	assert_int(Offseason._cpu_contract_years(star, [], rich)).is_equal(4)
	# どの年数の増額分 (最短の2年でも +5000) も賄えない予算では単年になる。
	var broke: PSTeam = PSTeam.from_dict({"id": 1, "name": "T1", "short_name": "T1", "league": "league1", "funds": 4000})
	assert_int(Offseason._cpu_contract_years(star, [], broke)).is_equal(1)


func test_apply_contract_years_sets_keys_and_single_year_erases_them() -> void:
	var player: PSPlayer = _player({"id": 9530, "team_id": 1, "salary": 5000})
	Offseason._apply_contract_years(player, 3, 12000, 2026)
	assert_int(int(player.source_data.get("contract_end_year", 0))).is_equal(2029)
	assert_int(int(player.source_data.get("contract_total_years", 0))).is_equal(3)
	assert_int(int(player.source_data.get("contract_signed_year", 0))).is_equal(2026)
	assert_int(player.salary).is_equal(12000)
	assert_bool(Offseason._contract_salary_is_locked(player, 2026)).is_true()
	assert_bool(Offseason._contract_salary_is_locked(player, 2028)).is_true()
	assert_bool(Offseason._contract_salary_is_locked(player, 2029)).is_false()

	# 単年は契約キーを消すだけで年俸は触らない (契約更改の査定に委ねる)。
	Offseason._apply_contract_years(player, 1, 99999, 2029)
	assert_bool(player.source_data.has("contract_end_year")).is_false()
	assert_int(player.salary).is_equal(12000)


func test_contract_years_state_auto_completes_without_candidates() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var players: Array = [_player({"id": 9540, "team_id": 1, "salary": 5000})]
	var state: Dictionary = Offseason.create_contract_years_state(players, [_team(1)], season, 1)
	assert_bool(bool(state.get("complete", false))).is_true()
	assert_int(int((state.get("final_result", {}) as Dictionary).get("decided_count", -1))).is_equal(0)


# 決めた年数は必ず成立する (受諾判定は無い)。CPU球団の未決定分は確定時にまとめて決まる。
func test_finalize_contract_years_applies_every_decision() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var team: PSTeam = _team(1)
	var user_player: PSPlayer = _contract_years_player(9541, 1, 2.5, 26)
	var cpu_player: PSPlayer = _contract_years_player(9542, 2, 2.5, 26)
	var players: Array = [user_player, cpu_player]
	var state: Dictionary = Offseason.create_contract_years_state(players, [team, _team(2)], season, 1)
	assert_int((state.get("candidates", []) as Array).size()).is_equal(2)
	assert_bool(bool(state.get("complete", false))).is_false()
	assert_int(Offseason.pending_contract_years_count(state, 1)).is_equal(1)

	assert_bool(bool(Offseason.submit_contract_years(state, players, [team, _team(2)], 1, user_player.id, 3).get("ok", false))).is_true()
	assert_int(Offseason.pending_contract_years_count(state, 1)).is_equal(0)

	var result: Dictionary = Offseason.finalize_contract_years(state, players, [team, _team(2)])
	assert_bool(bool(state.get("complete", false))).is_true()
	assert_int(int(user_player.source_data.get("contract_end_year", 0))).is_equal(2029)
	assert_int(int(result.get("decided_count", 0))).is_equal(2)
	# CPU球団の候補も同時に決まる (単年なら契約キーは付かない)。
	assert_bool((cpu_player.source_data.get("contract_total_years", 0) as int) >= 2 or not cpu_player.source_data.has("contract_end_year")).is_true()


func test_submit_contract_years_clamps_years_and_requires_own_team() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var player: PSPlayer = _contract_years_player(9580, 1, 2.5, 26)
	var players: Array = [player]
	var team: PSTeam = _team(1)
	var state: Dictionary = Offseason.create_contract_years_state(players, [team], season, 1)
	assert_bool(bool(state.get("complete", false))).is_false()

	# 他球団扱い (user_team_id=2) では決められない。
	var other_team_result: Dictionary = Offseason.submit_contract_years(state, players, [team], 2, player.id, 3)
	assert_bool(bool(other_team_result.get("ok", true))).is_false()

	var max_years: int = FaMarketService.fa_offer_max_years(player.age)
	var result: Dictionary = Offseason.submit_contract_years(state, players, [team], 1, player.id, max_years + 5)
	assert_bool(bool(result.get("ok", false))).is_true()
	var entry: Dictionary = Offseason._contract_years_entry_by_player_id(state, player.id)
	assert_int(int(entry.get("years", 0))).is_equal(max_years)

	# 取り消すと未決定に戻る。
	assert_bool(bool(Offseason.withdraw_contract_years(state, player.id).get("ok", false))).is_true()
	assert_int(Offseason.pending_contract_years_count(state, 1)).is_equal(1)


# 今オフFA権を新規取得した選手と、今オフFA宣言した選手は戦力外/育成降格にできない。
func test_release_block_reason_covers_new_fa_holder_and_declared() -> void:
	var new_fa: PSPlayer = _player({"id": 9590, "team_id": 1, "source_data": {"fa_eligible_year": 2026}})
	var declared: PSPlayer = _player({"id": 9591, "team_id": 1, "source_data": {"fa_declared_year": 2026}})
	var normal: PSPlayer = _player({"id": 9592, "team_id": 1})
	assert_str(Offseason.release_block_reason(new_fa, 2026)).is_not_empty()
	assert_str(Offseason.release_block_reason(declared, 2026)).is_not_empty()
	assert_str(Offseason.release_block_reason(normal, 2026)).is_empty()
	# 翌オフには保護が外れる。
	assert_str(Offseason.release_block_reason(new_fa, 2027)).is_empty()

	assert_bool(bool(Offseason.reject_locked_release_or_demote([new_fa], [9590], [], 2026).get("ok", true))).is_false()
	assert_bool(bool(Offseason.reject_locked_release_or_demote([declared], [], [9591], 2026).get("ok", true))).is_false()
	assert_bool(bool(Offseason.reject_locked_release_or_demote([normal], [9592], [], 2026).get("ok", false))).is_true()


func test_fa_declare_excludes_multi_year_locked_player() -> void:
	var locked: PSPlayer = _player_with_z(9470, 1, 3, false, 3.0)
	locked.age = 30
	locked.years = 10
	locked.salary = 20000
	locked.source_data["fa_nissuu"] = PSPlayer.FA_SERVICE_DAYS_PER_YEAR * 10
	locked.source_data["contract_end_year"] = 2027
	assert_bool(locked.is_fa_eligible()).is_true()

	var declared: Array = FaMarketService._select_declarers([locked], [], null, 2026)
	assert_array(declared).is_empty()
	assert_bool(FaMarketService._is_fa_tracking_candidate(locked, 2026)).is_false()


func test_fa_pass_count_not_incremented_for_multi_year_locked_player() -> void:
	var locked: PSPlayer = _player_with_z(9480, 1, 3, false, 0.0)
	locked.age = 30
	locked.years = 10
	locked.source_data["fa_nissuu"] = PSPlayer.FA_SERVICE_DAYS_PER_YEAR * 10
	locked.source_data["contract_end_year"] = 2027
	locked.source_data["fa_eligible_year"] = 2025
	locked.source_data["fa_pass_count"] = 1

	FaMarketService._increment_non_declared_fa_passes([locked], 2026, {})
	assert_int(int(locked.source_data.get("fa_pass_count", -1))).is_equal(1)


# --- 戦力外選定 (projection × デプスチャート) -------------------------------
# 外国人0・育成0では見込み流入13人、放出後目標55人として役割予算を比例配分する。

func _plan_team(team_id: int, count: int, base_id: int, z_value: float, age: int = 29) -> Array:
	var players: Array = []
	for i in range(count):
		var p: PSPlayer = _player_with_z(base_id + i, team_id, 3, false, z_value + float(i) * 0.01)
		p.age = age
		players.append(p)
	return players


func test_release_plan_counts_scale_with_roster_size() -> void:
	var deep_team: Array = _plan_team(1, 70, 9500, -1.0)
	var lean_team: Array = _plan_team(2, 60, 9600, -1.0)
	var all_players: Array = deep_team + lean_team
	var deep_cut: Array = Offseason.compute_release_candidates_for_team(all_players, 1, null)
	var lean_cut: Array = Offseason.compute_release_candidates_for_team(all_players, 2, null)
	assert_int(deep_cut.size()).is_equal(Offseason.RELEASE_PLAN_MAX_PER_TEAM)
	assert_int(lean_cut.size()).is_equal(7)
	assert_int(deep_cut.size()).is_greater(lean_cut.size())
	# 上限超過時は projection の低い側だけを残し、戻り値も昇順にする。
	assert_int(int(deep_cut[0])).is_equal(9500)
	assert_int(int(deep_cut[-1])).is_equal(9514)


func test_release_targets_opening_roster_and_is_idempotent() -> void:
	var players: Array = _plan_team(1, 70, 9700, -1.0)
	var first_cut: Array = Offseason.compute_release_candidates_for_team(players, 1, null)
	var remaining: int = players.size() - first_cut.size()
	assert_int(remaining).is_equal(55)
	for pid_value in first_cut:
		var player: PSPlayer = null
		for row in players:
			if (row as PSPlayer).id == int(pid_value):
				player = row as PSPlayer
				break
		Offseason._apply_release_mutation(player)
	var second_cut: Array = Offseason.compute_release_candidates_for_team(players, 1, null)
	assert_int(second_cut.size()).is_less_equal(Offseason.RECONCILE_UPPER_SLACK)


func test_release_plan_bounded_even_when_stats_missing() -> void:
	var players: Array = _plan_team(1, 66, 9750, 0.0, 32)
	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, 1, null)
	assert_int(cut_ids.size()).is_equal(13)
	assert_int(players.size() - cut_ids.size()).is_equal(53)


func test_release_cuts_surplus_noshow_thirties_fielder() -> void:
	var players: Array = []
	var noshow: PSPlayer = _player_with_z(9220, 1, 6, false, 0.0)
	noshow.age = 33
	players.append(noshow)
	for i in range(5):
		var stronger: PSPlayer = _player_with_z(9230 + i, 1, 6, false, 1.0)
		stronger.age = 28
		players.append(stronger)
	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, 1, null)
	assert_array(cut_ids).contains(noshow.id)


func test_release_keeps_low_value_catcher_within_slot_budget() -> void:
	var players: Array = []
	for i in range(4):
		var catcher: PSPlayer = _player_with_z(9770 + i, 1, 2, false, -3.0)
		catcher.age = 35
		players.append(catcher)
	assert_int(int(Offseason._release_slot_budgets(players, 1)["fielder:2"])).is_equal(4)
	assert_array(Offseason.compute_release_candidates_for_team(players, 1, null)).is_empty()


func test_release_slot_rejects_unexcused_noshow_thirties_player() -> void:
	var player: PSPlayer = _player_with_z(9776, 1, 7, false, -2.0)
	player.age = 33
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2099, 1)
	assert_float(ReleaseValueProjector.projected_value(player, record)).is_less(Offseason.RELEASE_REPLACEMENT_VALUE)
	assert_array(_release_candidates_with_records([player], [record])).contains(player.id)


func test_release_keeps_active_regular_that_ranks_inside_slot() -> void:
	var players: Array = []
	var records: Array = []
	var regular: PSPlayer = _player_with_z(9780, 1, 3, false, 0.0)
	regular.age = 35
	players.append(regular)
	var regular_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(regular, 2099, 1)
	regular_record.batter_stats.games = 100
	records.append(regular_record)
	for i in range(5):
		var reserve: PSPlayer = _player_with_z(9781 + i, 1, 3, false, -3.0)
		reserve.age = 35
		players.append(reserve)
		records.append(PSPlayerSeasonRecord.from_player(reserve, 2099, 1))
	assert_float(ReleaseValueProjector.projected_value(regular, regular_record)).is_less(Offseason.RELEASE_REPLACEMENT_VALUE)
	var cut_ids: Array = _release_candidates_with_records(players, records)
	assert_array(cut_ids).not_contains(regular.id)
	assert_int(cut_ids.size()).is_greater(0)


func test_release_keeps_long_injured_high_ability_surplus_player() -> void:
	var players: Array = []
	var records: Array = []
	var injured: PSPlayer = _player_with_z(9790, 1, 3, false, 1.0)
	injured.age = 30
	players.append(injured)
	var injured_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(injured, 2099, 1)
	injured_record.season_injury_days = ReleaseValueProjector.INJURY_EXCUSE_FULL_DAYS
	records.append(injured_record)
	for i in range(5):
		var stronger: PSPlayer = _player_with_z(9791 + i, 1, 3, false, 2.0)
		stronger.age = 28
		players.append(stronger)
		records.append(PSPlayerSeasonRecord.from_player(stronger, 2099, 1))
	assert_float(ReleaseValueProjector.projected_value(injured, injured_record)).is_greater_equal(Offseason.RELEASE_REPLACEMENT_VALUE)
	assert_array(_release_candidates_with_records(players, records)).not_contains(injured.id)


func test_compute_release_candidates_returns_empty_when_all_protected() -> void:
	var players: Array = []
	for i in range(60):
		var p: PSPlayer = _player_with_z(9700 + i, 1, 3, false, -2.0)
		p.age = 30
		p.years = 1
		p.source_data["draft_year"] = 2025
		players.append(p)
	for i in range(4):
		players.append(_player_with_z(9800 + i, 1, 3, false, -3.0))
		(players[-1] as PSPlayer).foreign_player = true
	var cut_ids: Array = Offseason.compute_release_candidates_for_team(players, 1, null)
	assert_array(cut_ids).is_empty()


# --- 降格 (支配下 → 育成) ----------------------------------------------------

func test_process_demotion_marks_development_and_frees_slot() -> void:
	var players: Array = [
		_player({"id": 10, "team_id": 1}),
		_player({"id": 11, "team_id": 1}),
	]
	var before: int = TeamFinance.shienka_count(players, 1)
	var result: Dictionary = Offseason.process_demotion(players, 1, [10])
	assert_int(int(result.get("demoted_count", 0))).is_equal(1)
	var demoted: PSPlayer = players[0] as PSPlayer
	assert_bool(demoted.development_player).is_true()
	assert_str(demoted.registered_roster).is_equal("育成")
	assert_bool(demoted.is_retired()).is_false()  # release と違い org に残る
	assert_int(demoted.team_id).is_equal(1)
	assert_int(TeamFinance.shienka_count(players, 1)).is_equal(before - 1)


func test_demotion_not_blocked_by_development_count() -> void:
	# 育成は人数無制限: 既に多数の育成が居ても支配下→育成 降格は通る。
	var players: Array = _support_players(1, 3)
	for i in range(20):
		players.append(_player({"id": 5000 + i, "team_id": 1, "development_player": true}))
	var support_id: int = (players[0] as PSPlayer).id
	var result: Dictionary = Offseason.process_demotion(players, 1, [support_id])
	assert_int(int(result.get("demoted_count", 0))).is_equal(1)
	assert_bool((players[0] as PSPlayer).development_player).is_true()


# --- 昇格 (育成 → 支配下) ----------------------------------------------------

func test_promotion_moves_strong_dev_to_shienka() -> void:
	var strong_dev: PSPlayer = _player_with_z(20, 1, 3, true, 2.5)
	var players: Array = [strong_dev, _player({"id": 21, "team_id": 1})]
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(1)
	assert_bool(strong_dev.development_player).is_false()
	assert_str(strong_dev.registered_roster).is_equal("支配下")


func test_promotion_skips_weak_dev() -> void:
	var weak_dev: PSPlayer = _player_with_z(30, 1, 3, true, -3.0)
	var players: Array = [weak_dev]
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(weak_dev.development_player).is_true()


func test_promotion_blocked_when_no_shienka_room() -> void:
	var players: Array = _support_players(1, TeamFinance.SHIENKA_LIMIT)
	var strong_dev: PSPlayer = _player_with_z(40, 1, 3, true, 2.5)
	players.append(strong_dev)
	var result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(strong_dev.development_player).is_true()


func test_promotion_excludes_user_team() -> void:
	var strong_dev: PSPlayer = _player_with_z(50, 1, 3, true, 2.5)
	var result: Dictionary = Offseason.process_development_promotions([strong_dev], [_team(1)], 1)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(strong_dev.development_player).is_true()


# --- 怪我の越冬回復と長期故障の育成降格 ---------------------------------------
# player.injury_days を書き換えるのは process_injury_carryover だけで、シーズン中は record 側しか
# 動かない。この関数をオフ冒頭 (引退判定) で走らせないと、戦力外/育成降格が読む player.injury_days が
# 1年前の値のままになり、今季シーズン絶望の大怪我が判定に一切乗らない (2026-08-02 まで実際にそうなっていた)。
func test_injury_carryover_feeds_long_injury_demotion() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	# 今季にシーズン絶望級 (300日) を負った若手。player 側はシーズン中ずっと 0 のまま。
	var injured: PSPlayer = _player_with_z(9720, 1, 3, false, 0.8)
	injured.age = 24
	injured.injury_days = 0
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(injured, season.year, season.season_number)
	record.injury_days = 300
	var record_key: String = "%d:%d:%d" % [injured.id, season.year, season.season_number]
	var previous_record: Variant = RecordStore.player_records.get(record_key, null)
	RecordStore.set_player_record(record, record_key)

	# 越冬回復前は判定材料が無く、降格対象にならない (これが旧実装の状態)。
	assert_bool(Offseason._should_demote_to_development(injured)).is_false()

	var carryover: Dictionary = Offseason.process_injury_carryover([injured], season)
	assert_int(injured.injury_days).is_equal(300 - Offseason.OFFSEASON_RECOVERY_DAYS)
	assert_int(int(carryover.get("carried", 0))).is_equal(1)
	# 越冬しても 120日以上残る = 来季も長期離脱 → release ではなく育成降格へ回る。
	assert_bool(Offseason._should_demote_to_development(injured)).is_true()

	# 冪等: record から計算するので、同じオフに複数回呼んでも二重に回復しない。
	Offseason.process_injury_carryover([injured], season)
	assert_int(injured.injury_days).is_equal(300 - Offseason.OFFSEASON_RECOVERY_DAYS)

	if previous_record == null:
		RecordStore.erase_player_record_by_key(record_key)
	else:
		RecordStore.set_player_record(previous_record as PSPlayerSeasonRecord, record_key)


# 開幕に間に合う程度の離脱 (越冬回復で 120日を切る) は降格対象にしない。
func test_injury_carryover_keeps_short_absence_out_of_demotion() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var injured: PSPlayer = _player_with_z(9721, 1, 3, false, 0.8)
	injured.age = 24
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(injured, season.year, season.season_number)
	record.injury_days = 140
	var record_key: String = "%d:%d:%d" % [injured.id, season.year, season.season_number]
	var previous_record: Variant = RecordStore.player_records.get(record_key, null)
	RecordStore.set_player_record(record, record_key)

	Offseason.process_injury_carryover([injured], season)
	assert_int(injured.injury_days).is_equal(140 - Offseason.OFFSEASON_RECOVERY_DAYS)
	assert_bool(Offseason._should_demote_to_development(injured)).is_false()

	if previous_record == null:
		RecordStore.erase_player_record_by_key(record_key)
	else:
		RecordStore.set_player_record(previous_record as PSPlayerSeasonRecord, record_key)


# 長期故障の育成降格は**戦力外候補かどうかと独立**に走る。怪我人は戦力外候補にならないよう
# 保護されている (_can_claim_release_slot / ReleaseValueProjector の怪我 excuse) ので、
# 「候補の中から降格へ振り分ける」旧実装では一度も発火しなかった (2026-08-02 修正)。
func test_long_injury_demotion_runs_independently_of_release_candidates() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	# 戦力外候補が出ない健全なロスター (若く能力のある支配下) に、長期故障者を1人置く。
	var players: Array = []
	for i in range(30):
		var healthy: PSPlayer = _player_with_z(9730 + i, 1, 3, false, 1.5)
		healthy.age = 26
		players.append(healthy)
	var injured: PSPlayer = _player_with_z(9790, 1, 3, false, 1.5)
	injured.age = 25
	injured.injury_days = Offseason.DEMOTE_INJURY_DAYS_LONG + 60
	players.append(injured)

	# 戦力外候補には入らない (怪我の有無に関わらずロスターに余剰が無い)。
	assert_array(Offseason.compute_release_candidates_for_team(players, 1, season)).not_contains([injured.id])
	# それでも独立経路が拾う。
	assert_array(Offseason.compute_long_injury_demotion_candidates_for_team(players, 1, season.year)).contains([injured.id])

	var result: Dictionary = Offseason.process_cpu_releases(players, [_team(1)], 0, season)
	assert_int(int(result.get("demoted_count", 0))).is_equal(1)
	assert_bool(injured.development_player).is_true()
	assert_int(injured.team_id).is_equal(1)


# 複数年契約中など放出できない選手は降格もできない (release_block_reason が単一ソース)。
func test_long_injury_demotion_respects_release_block_reason() -> void:
	var locked: PSPlayer = _player_with_z(9795, 1, 3, false, 1.5)
	locked.age = 25
	locked.injury_days = Offseason.DEMOTE_INJURY_DAYS_LONG + 60
	locked.source_data["contract_total_years"] = 3
	locked.source_data["contract_end_year"] = 2028
	assert_bool(Offseason._should_demote_to_development(locked)).is_true()
	assert_array(Offseason.compute_long_injury_demotion_candidates_for_team([locked], 1, 2026)).is_empty()


# --- 支配下登録期限 (7/31) の昇格 ---------------------------------------------
# オフの自動昇格は soft 目標 (67) で止まり、残り3枠は期限昇格が使い切る。期限を過ぎると
# FA/外国人/トレードが無いので、ここで埋めないと翌オフまで死に枠になる。
func test_registration_deadline_promotion_fills_up_to_hard_limit() -> void:
	var players: Array = _support_players(1, TeamFinance.SHIENKA_SOFT_TARGET)
	var ready_devs: Array = []
	for i in range(5):
		var dev: PSPlayer = _player_with_z(9700 + i, 1, 3, true, 2.5)
		ready_devs.append(dev)
		players.append(dev)

	# オフの昇格は soft 目標に達しているので1人も上げない。
	var offseason_result: Dictionary = Offseason.process_development_promotions(players, [_team(1)], 0)
	assert_int(int(offseason_result.get("promoted_count", 0))).is_equal(0)

	# 期限昇格は hard 上限 (70) まで = 残り3枠ぶんだけ昇格する。
	var deadline_result: Dictionary = Offseason.process_registration_deadline_promotions(players, [_team(1)], 0, null)
	assert_int(int(deadline_result.get("promoted_count", 0))).is_equal(
		TeamFinance.SHIENKA_LIMIT - TeamFinance.SHIENKA_SOFT_TARGET
	)
	assert_int(TeamFinance.shienka_count(players, 1)).is_equal(TeamFinance.SHIENKA_LIMIT)


# 枠が空いていても即戦力基準に届かない育成は上げない (枠を埋めること自体は目的にしない)。
func test_registration_deadline_promotion_skips_unready_dev() -> void:
	var weak_dev: PSPlayer = _player_with_z(9710, 1, 3, true, -3.0)
	var players: Array = [weak_dev, _player({"id": 9711, "team_id": 1})]
	var result: Dictionary = Offseason.process_registration_deadline_promotions(players, [_team(1)], 0, null)
	assert_int(int(result.get("promoted_count", 0))).is_equal(0)
	assert_bool(weak_dev.development_player).is_true()


# --- 即戦力基準は球団相対 --------------------------------------------------

func test_first_team_ready_threshold_is_relative() -> void:
	# 弱い一軍 (低能力支配下31人) は基準が floor、強い一軍 (高能力31人) は ceiling。
	var weak: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		weak.append(_player_with_z(3000 + i, 1, 3, false, -2.0))
	var strong: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		strong.append(_player_with_z(4000 + i, 2, 3, false, 2.5))
	var weak_threshold: float = Offseason.first_team_ready_threshold(weak, 1)
	var strong_threshold: float = Offseason.first_team_ready_threshold(strong, 2)
	assert_float(weak_threshold).is_less(strong_threshold)
	assert_float(weak_threshold).is_equal(Offseason.PROMOTE_READY_FLOOR)
	assert_float(strong_threshold).is_equal(Offseason.PROMOTE_READY_CEILING)


func test_promotion_respects_relative_threshold() -> void:
	# 同能力の中堅育成が、弱い一軍の球団では即戦力(昇格)、強い一軍の球団では基準未満(据え置き)。
	var players: Array = []
	for i in range(Offseason.FIRST_TEAM_SIZE):
		players.append(_player_with_z(5000 + i, 1, 3, false, -2.0))  # team1: 弱い支配下
	for i in range(Offseason.FIRST_TEAM_SIZE):
		players.append(_player_with_z(6000 + i, 2, 3, false, 2.5))   # team2: 強い支配下
	var dev_weak_team: PSPlayer = _player_with_z(7001, 1, 3, true, 0.4)
	var dev_strong_team: PSPlayer = _player_with_z(7002, 2, 3, true, 0.4)
	players.append(dev_weak_team)
	players.append(dev_strong_team)
	Offseason.process_development_promotions(players, [_team(1), _team(2)], 0)
	assert_bool(dev_weak_team.development_player).is_false()  # 弱い球団 → 昇格
	assert_bool(dev_strong_team.development_player).is_true()  # 強い球団 → 据え置き


# --- 育成整理 (pipeline 循環) ------------------------------------------------

func test_development_release_cuts_failed_prospect_keeps_viable_young() -> void:
	# 若く将来価値のある素材 (viable) は猶予を過ぎても保持。
	var young_viable: PSPlayer = _player_with_z(80, 1, 3, true, 0.6)
	young_viable.age = 20
	young_viable.years = 5
	# 在籍年数が出身別猶予を超え、昇格見込みも無い (非 viable) 失敗プロスペクトは放出。
	var aged_weak: PSPlayer = _player_with_z(81, 1, 3, true, -2.0)
	aged_weak.age = 30
	aged_weak.years = 3
	var players: Array = [young_viable, aged_weak]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(young_viable.is_retired()).is_false()
	assert_bool(young_viable.development_player).is_true()
	assert_bool(aged_weak.is_retired()).is_true()


func test_development_release_keeps_first_year() -> void:
	# 1年目 (years<=1) の育成は将来価値が低くても原則保持。
	var first_year: PSPlayer = _player_with_z(82, 1, 3, true, -2.0)
	first_year.age = 24
	first_year.years = 1
	var tenured: PSPlayer = _player_with_z(83, 1, 3, true, -2.0)
	tenured.age = 24
	tenured.years = 5  # 猶予 (大社3) を超え昇格見込み無し → 放出
	var players: Array = [first_year, tenured]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_bool(first_year.is_retired()).is_false()
	assert_bool(tenured.is_retired()).is_true()


func test_development_release_high_school_longer_grace() -> void:
	# 同条件 (非 viable・在籍3年) でも高卒は猶予4年で保持、大社は猶予3年で放出。
	var hs: PSPlayer = _player_with_z(84, 1, 3, true, -2.0)
	hs.age = 21
	hs.years = 3
	hs.source_data = {"draft_source": "high_school"}
	var college: PSPlayer = _player_with_z(85, 1, 3, true, -2.0)
	college.age = 21
	college.years = 3
	college.source_data = {"draft_source": "university"}
	var players: Array = [hs, college]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(hs.is_retired()).is_false()
	assert_bool(college.is_retired()).is_true()


# --- 統一スコア future_value_score / 故障リスク -------------------------------

func test_future_value_score_rewards_youth() -> void:
	var young: PSPlayer = _player_with_z(90, 1, 3, false, 0.0)
	young.age = 20
	var old: PSPlayer = _player_with_z(91, 1, 3, false, 0.0)
	old.age = 31
	assert_float(Offseason.future_value_score(young)).is_greater(Offseason.future_value_score(old))


func test_injury_value_penalty_scales_and_caps() -> void:
	var healthy: PSPlayer = _player({"id": 92, "team_id": 1})
	var hurt: PSPlayer = _player({"id": 93, "team_id": 1, "injury_days": 60})
	var wrecked: PSPlayer = _player({"id": 94, "team_id": 1, "injury_days": 300})
	assert_float(Offseason.injury_value_penalty(healthy)).is_equal(0.0)
	assert_float(Offseason.injury_value_penalty(hurt)).is_equal(2.0)
	assert_float(Offseason.injury_value_penalty(wrecked)).is_equal(Offseason.INJURY_PENALTY_CAP)


# --- 支配下→育成 降格の3類型 -------------------------------------------------

func test_should_demote_only_for_long_injury() -> void:
	# CPU の育成降格は長期故障のリハビリ型のみ (2026-07-03 ユーザー方針
	# 「怪我以外での育成落ちはなくす」。旧・素材保持型/ベテラン確率型は撤廃)。
	# 健康な若手素材は降格しない (戦力外候補なら release へ)。
	var healthy_prospect: PSPlayer = _player_with_z(95, 1, 3, false, 0.5)
	healthy_prospect.age = 22
	assert_bool(Offseason._should_demote_to_development(healthy_prospect)).is_false()
	# 健康なベテランも降格しない。
	var healthy_veteran: PSPlayer = _player_with_z(96, 1, 3, false, 0.3)
	healthy_veteran.age = 33
	assert_bool(Offseason._should_demote_to_development(healthy_veteran)).is_false()
	# 長期故障/再調整型: 復帰すれば戦力 → 降格。年齢を問わない。
	var injured: PSPlayer = _player_with_z(97, 1, 3, false, 0.5)
	injured.age = 29
	injured.injury_days = 150
	assert_bool(Offseason._should_demote_to_development(injured)).is_true()
	var injured_old: PSPlayer = _player_with_z(98, 1, 3, false, 1.0)
	injured_old.age = 34
	injured_old.injury_days = 150
	assert_bool(Offseason._should_demote_to_development(injured_old)).is_true()
	# 長期故障でも将来価値が残らない選手は降格せず戦力外のまま。
	var injured_washed: PSPlayer = _player_with_z(99, 1, 3, false, -2.5)
	injured_washed.age = 36
	injured_washed.injury_days = 150
	assert_bool(Offseason._should_demote_to_development(injured_washed)).is_false()


func test_development_release_cuts_faded_prospect_keeps_ready_and_rehab() -> void:
	# 猶予明け・健康・昇格見込みなし (projected_ceiling が即戦力基準未満) → 優先放出
	var aged_failed: PSPlayer = _player_with_z(103, 1, 3, true, -1.0)
	aged_failed.age = 27
	aged_failed.years = 3
	# 素材年齢 (<=26) の即戦力は満枠で昇格できなかっただけなので保持
	# (27歳以上は1年ルールで保持されない → test_development_release_one_year_rule_for_midcareer)
	var aged_ready: PSPlayer = _player_with_z(105, 1, 3, true, 2.5)
	aged_ready.age = 25
	aged_ready.years = 3
	# 故障リハビリ中は保持 (故障回復待ち)
	var rehab: PSPlayer = _player_with_z(104, 1, 3, true, 0.6)
	rehab.age = 27
	rehab.years = 3
	rehab.injury_days = 150
	var players: Array = [aged_failed, aged_ready, rehab]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(aged_failed.is_retired()).is_true()
	assert_bool(aged_ready.is_retired()).is_false()
	assert_bool(rehab.is_retired()).is_false()
	assert_bool(rehab.development_player).is_true()


func test_development_release_keeps_many_viable_young() -> void:
	# 育成は人数無制限: 大量の若い viable 育成は全員保持 (枠超過放出は無し)。
	var players: Array = []
	for i in range(20):
		var dev: PSPlayer = _player_with_z(2000 + i, 1, 3, true, 0.5)
		dev.age = 20
		players.append(dev)
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(0)
	assert_int(TeamFinance.development_count(players, 1)).is_equal(20)


func test_development_release_uses_growth_projection_not_fixed_age() -> void:
	# 現在能力が同じでも、成長期待(年齢とともに縮む)を加味した projected_ceiling が
	# 即戦力基準に届くかどうかで昇格見込みを判定する(2026-07-02、固定26歳カットオフを撤廃し
	# 成長予測ベースに変更)。猶予(大社3年)は在籍4年で超えているので3人とも projection で判定される。
	# 同じ現在能力(z=0.0)でも22-24歳は成長期待でギリギリ即戦力基準を上回り保持、25歳は下回り放出。
	var young: PSPlayer = _player_with_z(9800, 1, 3, true, 0.0)
	young.age = 22
	young.years = 4
	var still_ok: PSPlayer = _player_with_z(9801, 1, 3, true, 0.0)
	still_ok.age = 24
	still_ok.years = 4
	var faded: PSPlayer = _player_with_z(9802, 1, 3, true, 0.0)
	faded.age = 25
	faded.years = 4
	var players: Array = [young, still_ok, faded]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(young.is_retired()).is_false()
	assert_bool(still_ok.is_retired()).is_false()
	assert_bool(faded.is_retired()).is_true()


func test_development_release_one_year_rule_for_midcareer() -> void:
	# 中堅以上 (>DEMOTE_PROSPECT_MAX_AGE=26) の育成は「再調整は1年」: 昇格ステップで支配下に
	# 戻れなければ、即戦力水準の能力があっても放出される (2026-07-02 ユーザー要望。
	# 旧実装は「即戦力は満枠待ちで保持」が年齢無制限で、降格ベテランが育成に何年も居座れた)。
	var midcareer_ready: PSPlayer = _player_with_z(9600, 1, 3, true, 2.5)
	midcareer_ready.age = 30
	midcareer_ready.years = 8
	# 同じ即戦力級でも素材年齢 (<=26) は満枠待ちとして保持される。
	var prospect_ready: PSPlayer = _player_with_z(9601, 1, 3, true, 2.5)
	prospect_ready.age = 26
	prospect_ready.years = 5
	var players: Array = [midcareer_ready, prospect_ready]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(result.get("released_count", 0))).is_equal(1)
	assert_bool(midcareer_ready.is_retired()).is_true()
	assert_bool(prospect_ready.is_retired()).is_false()


func test_released_market_dev_track_signing_gets_one_offseason_hold() -> void:
	# 戦力外獲得の育成track署名は dev_demote_hold が付き、獲得した同オフの育成整理
	# (成長ステップ内) で即放出されない。翌オフは中堅1年ルールで、昇格が無ければ放出される。
	var veteran: PSPlayer = _player_with_z(9610, 0, 3, false, 0.5)
	veteran.age = 31
	veteran.years = 9
	veteran.source_data = {"released": true}
	var players: Array = [veteran]
	var entry: Dictionary = {"player_id": 9610, "track": ReleasedMarket.TRACK_DEVELOPMENT, "value": 50}
	ReleasedMarket._apply_signing({"signings": []}, players, null, entry, 1, "cpu")
	assert_bool(veteran.development_player).is_true()
	assert_bool(bool(veteran.source_data.get("dev_demote_hold", false))).is_true()
	# 獲得同オフ: hold を消費して保持。
	var first_result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(first_result.get("released_count", 0))).is_equal(0)
	assert_bool(veteran.is_retired()).is_false()
	# 翌オフ (昇格されなかった): 中堅1年ルールで放出。
	var second_result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(second_result.get("released_count", 0))).is_equal(1)
	assert_bool(veteran.is_retired()).is_true()


func test_compute_development_release_candidates_for_user_team_recommendation() -> void:
	# 自軍は process_development_releases から除外されるため、戦力外エディタの推奨が
	# この候補列挙を合流させる (2026-07-02、「条件を満たす初期育成選手が自軍で戦力外に
	# ならない」報告の修正)。CPU の育成整理と同じ基準・非破壊 (hold は消費しない)。
	var midcareer: PSPlayer = _player_with_z(9620, 1, 3, true, 0.5)
	midcareer.age = 30
	midcareer.years = 6
	var held: PSPlayer = _player_with_z(9621, 1, 3, true, 0.5)
	held.age = 30
	held.years = 6
	held.source_data["dev_demote_hold"] = true
	var young_viable: PSPlayer = _player_with_z(9622, 1, 3, true, 0.6)
	young_viable.age = 20
	young_viable.years = 2
	var players: Array = [midcareer, held, young_viable]
	var ids: Array = Offseason.compute_development_release_candidates_for_team(players, 1)
	assert_array(ids).contains(9620)
	assert_array(ids).not_contains(9621)
	assert_array(ids).not_contains(9622)
	# 非破壊: hold は消費されず、選手状態も変わらない。
	assert_bool(bool(held.source_data.get("dev_demote_hold", false))).is_true()
	assert_bool(midcareer.is_retired()).is_false()


func test_process_development_releases_consumes_hold_for_excluded_team() -> void:
	# 自軍 (excluded_team_id) は放出されないが hold は消費される。消費しないと自軍の
	# 降格/育成track獲得選手が翌オフ以降も hold で保持され続け、1年ルールが効かない。
	var held: PSPlayer = _player_with_z(9630, 1, 3, true, 0.5)
	held.age = 30
	held.years = 6
	held.source_data["dev_demote_hold"] = true
	var players: Array = [held]
	var result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 1)
	assert_int(int(result.get("released_count", 0))).is_equal(0)
	assert_bool(held.is_retired()).is_false()
	assert_bool(bool(held.source_data.get("dev_demote_hold", false))).is_false()
	# 消費後 (=翌オフ相当) は推奨候補に入る。
	var ids: Array = Offseason.compute_development_release_candidates_for_team(players, 1)
	assert_array(ids).contains(9630)


func test_development_release_holds_the_offseason_a_player_was_demoted() -> void:
	# 支配下→育成に降格した選手は、その同じオフの育成整理では即放出されない
	# (dev_demote_hold、2026-07-02)。翌年以降は通常の projection 判定に戻る。
	var demoted: PSPlayer = _player_with_z(9803, 1, 3, false, -2.0)
	demoted.age = 30
	demoted.years = 5
	Offseason._apply_demotion_to_development(demoted)
	assert_bool(bool(demoted.source_data.get("dev_demote_hold", false))).is_true()
	var players: Array = [demoted]
	var first_result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(first_result.get("released_count", 0))).is_equal(0)
	assert_bool(demoted.is_retired()).is_false()
	assert_bool(bool(demoted.source_data.get("dev_demote_hold", false))).is_false()
	# 翌年 (フラグ消費済み): 見込みが無ければ通常通り放出される。
	var second_result: Dictionary = Offseason.process_development_releases(players, [_team(1)], 0)
	assert_int(int(second_result.get("released_count", 0))).is_equal(1)
	assert_bool(demoted.is_retired()).is_true()


# --- 一軍出場不可 ------------------------------------------------------------

func test_foreign_active_roster_limits_pitchers_and_fielders_to_three() -> void:
	var pitcher_counts: Dictionary = ForeignActiveRosterRules.empty_counts()
	var fielder_counts: Dictionary = ForeignActiveRosterRules.empty_counts()
	for i in range(ForeignActiveRosterRules.TYPE_MAX):
		var pitcher: PSPlayer = _player({
			"id": 600 + i,
			"team_id": 1,
			"position": 1,
			"role": "reliever",
			"foreign_player": true,
		})
		ForeignActiveRosterRules.add_record(pitcher_counts, PSPlayerSeasonRecord.from_player(pitcher, 2099, 1))
		var fielder: PSPlayer = _player({
			"id": 700 + i,
			"team_id": 1,
			"position": 3,
			"foreign_player": true,
		})
		ForeignActiveRosterRules.add_record(fielder_counts, PSPlayerSeasonRecord.from_player(fielder, 2099, 1))

	var fourth_pitcher: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(_player({
		"id": 699, "team_id": 1, "position": 1, "role": "reliever", "foreign_player": true,
	}), 2099, 1)
	var fourth_fielder: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(_player({
		"id": 799, "team_id": 1, "position": 3, "foreign_player": true,
	}), 2099, 1)

	assert_bool(ForeignActiveRosterRules.can_add_record(pitcher_counts, fourth_pitcher)).is_false()
	assert_bool(ForeignActiveRosterRules.can_add_record(fielder_counts, fourth_fielder)).is_false()
	assert_bool(ForeignActiveRosterRules.is_within_limits(pitcher_counts)).is_true()
	assert_bool(ForeignActiveRosterRules.is_within_limits(fielder_counts)).is_true()


func test_active_roster_summary_reports_foreign_type_counts() -> void:
	var records: Array = [
		PSPlayerSeasonRecord.from_player(_player({
			"id": 801, "team_id": 1, "position": 1, "role": "starter", "foreign_player": true,
		}), 2099, 1),
		PSPlayerSeasonRecord.from_player(_player({
			"id": 802, "team_id": 1, "position": 3, "foreign_player": true,
		}), 2099, 1),
		PSPlayerSeasonRecord.from_player(_player({
			"id": 803, "team_id": 1, "position": 4,
		}), 2099, 1),
	]
	var summary: Dictionary = TeamSetupBuilder.summarize_active_roster_ids([801, 802, 803], records)

	assert_int(int(summary.get("foreigners", 0))).is_equal(2)
	assert_int(int(summary.get("foreign_pitchers", 0))).is_equal(1)
	assert_int(int(summary.get("foreign_fielders", 0))).is_equal(1)


func test_auto_active_roster_does_not_select_four_foreign_fielders() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	var records: Array = []
	var player_id: int = 820
	for i in range(6):
		var starter: PSPlayer = _player({
			"id": player_id, "team_id": 1, "position": 1, "role": "starter",
		})
		records.append(PSPlayerSeasonRecord.from_player(starter, season.year, season.season_number).to_dict())
		player_id += 1
	for i in range(9):
		var reliever: PSPlayer = _player({
			"id": player_id, "team_id": 1, "position": 1, "role": "reliever",
		})
		records.append(PSPlayerSeasonRecord.from_player(reliever, season.year, season.season_number).to_dict())
		player_id += 1
	var positions: Array = [2, 3, 4, 5, 6, 7, 8, 9]
	for i in range(17):
		var fielder: PSPlayer = _player_with_z(player_id, 1, int(positions[i % positions.size()]), false, 2.0 if i < 4 else -1.0)
		fielder.foreign_player = i < 4
		records.append(PSPlayerSeasonRecord.from_player(fielder, season.year, season.season_number).to_dict())
		player_id += 1

	RecordStore.load_from_dict({
		"player_records": records,
		"team_records": [],
		"season_archives": [],
	})
	var preview: Dictionary = TeamAutoAIRef.preview_perf_based_active_roster(season, 1)
	var all_records: Array = RecordStore.get_team_player_records(1, season.year, season.season_number)
	var summary: Dictionary = TeamSetupBuilder.summarize_active_roster_ids(preview.get("player_ids", []) as Array, all_records)
	RecordStore.load_from_dict(original_records)

	assert_bool(bool(preview.get("ok", false))).is_true()
	assert_int(int(summary.get("foreign_fielders", 0))).is_equal(ForeignActiveRosterRules.TYPE_MAX)
	assert_int(int(summary.get("total", 0))).is_equal(TeamAutoAIRef.TARGET_TOTAL)


func test_eligible_or_fallback_excludes_development() -> void:
	var support: PSPlayer = _player({"id": 60, "team_id": 1})
	var dev: PSPlayer = _player({"id": 61, "team_id": 1, "development_player": true})
	var records: Array = [
		PSPlayerSeasonRecord.from_player(support, 0, 0),
		PSPlayerSeasonRecord.from_player(dev, 0, 0),
	]
	var eligible: Array = TeamSetupBuilder.eligible_or_fallback(records, 1)
	var ids: Array = []
	for row in eligible:
		ids.append((row as PSPlayerSeasonRecord).player_id)
	assert_array(ids).contains(60)
	assert_array(ids).not_contains(61)


func test_high_fatigue_record_is_not_auto_demotion_candidate() -> void:
	var player: PSPlayer = _player_with_z(62, 1, 3, false, 0.4)
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	record.fatigue = TeamAutoAIRef.DEMOTION_FATIGUE_PROTECT_THRESHOLD
	record.batter_stats.plate_appearances = 0

	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 1.0, 100, 70.0, 70.0, 70.0)).is_false()

	record.fatigue = TeamAutoAIRef.DEMOTION_FATIGUE_PROTECT_THRESHOLD - 1
	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 1.0, 100, 70.0, 70.0, 70.0)).is_true()


func test_underperforming_regular_batter_becomes_auto_demotion_candidate() -> void:
	var player: PSPlayer = _player_with_z(63, 1, 3, false, 0.4)
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	record.batter_stats.plate_appearances = 100

	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 54.0, 100, 70.0, 70.0, 70.0)).is_true()
	assert_bool(TeamAutoAIRef._is_demotion_candidate(record, 55.0, 100, 70.0, 70.0, 70.0)).is_false()


# FA日数台帳: 入替時に get_active_roster の複製 (古い台帳入り) を渡しても、set_active_roster 内で
# accrue した区間が巻き戻らないこと。週次入替のたびに直前区間が消え、長期で FA権取得者が
# 全くいなくなる回帰 (2026-07-06 の15年検証で fa_declared 全ゼロ) の再発防止。
func test_active_roster_fa_days_survive_swap_with_stale_ledger_copy() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = 1
	season.set_active_roster(1, {"player_ids": [10, 11]})

	# 週次入替を模す: 日を進め、古い台帳の入った複製を編集して保存し直す (team_auto_ai と同じ形)
	season.current_day = 8
	var stale: Dictionary = season.get_active_roster(1).duplicate(true)
	stale["player_ids"] = [10, 12]
	season.set_active_roster(1, stale)

	assert_int(season.get_active_roster_days(1, 10)).is_equal(7)
	assert_int(season.get_active_roster_days(1, 11)).is_equal(7)
	assert_int(season.get_active_roster_days(1, 12)).is_equal(0)

	# シーズン末フラッシュ (契約更新時の accrue_all 相当) で残り区間も積算される
	season.current_day = 15
	season.accrue_all_active_roster_days([1], season.current_day)
	assert_int(season.get_active_roster_days(1, 10)).is_equal(14)
	assert_int(season.get_active_roster_days(1, 11)).is_equal(7)
	assert_int(season.get_active_roster_days(1, 12)).is_equal(7)


func test_repair_active_roster_injuries_demotes_and_promotes_replacement() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = 42
	var active_ids: Array = []
	var player_records: Array = []
	var positions: Array = [2, 3, 4, 5, 6, 7, 8, 9]
	var injured_id: int = 1005
	for i in range(TeamAutoAIRef.TARGET_TOTAL):
		var position: int = int(positions[i % positions.size()])
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
			_player_with_z(1000 + i, 1, position, false, 0.2),
			season.year,
			season.season_number
		)
		if record.player_id == injured_id:
			record.injury_days = TeamAutoAIRef.INJURY_SHORT_ABSENCE_STASH_DAYS + 1
		active_ids.append(record.player_id)
		player_records.append(record.to_dict())

	var replacement: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		_player_with_z(2000, 1, 3, false, 2.0),
		season.year,
		season.season_number
	)
	player_records.append(replacement.to_dict())
	var development_reserve: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		_player_with_z(2001, 1, 3, true, 3.0),
		season.year,
		season.season_number
	)
	player_records.append(development_reserve.to_dict())

	RecordStore.load_from_dict({
		"player_records": player_records,
		"team_records": [],
		"season_archives": [],
	})
	season.set_active_roster(1, {"player_ids": active_ids})

	var result: Dictionary = TeamAutoAIRef.repair_active_roster_injuries(season, 1, season.current_day)
	var roster_ids: Array = (season.get_active_roster(1).get("player_ids", []) as Array).duplicate()
	var demotion_days: Dictionary = season.get_demotion_days(1).duplicate(true)
	RecordStore.load_from_dict(original_records)

	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(result.get("changed", false))).is_true()
	assert_array(roster_ids).not_contains(injured_id)
	assert_array(roster_ids).contains(2000)
	assert_array(roster_ids).not_contains(2001)
	assert_int(roster_ids.size()).is_equal(TeamAutoAIRef.TARGET_TOTAL)
	assert_int(int(demotion_days.get(str(injured_id), 0))).is_equal(season.current_day)


func test_repair_active_roster_injuries_keeps_short_absence_active() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = 43
	var active_ids: Array = []
	var player_records: Array = []
	var positions: Array = [2, 3, 4, 5, 6, 7, 8, 9]
	var injured_id: int = 1012
	for i in range(TeamAutoAIRef.TARGET_TOTAL):
		var position: int = int(positions[i % positions.size()])
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
			_player_with_z(1000 + i, 1, position, false, 0.2),
			season.year,
			season.season_number
		)
		if record.player_id == injured_id:
			record.injury_days = TeamAutoAIRef.INJURY_SHORT_ABSENCE_STASH_DAYS
		active_ids.append(record.player_id)
		player_records.append(record.to_dict())

	var replacement: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		_player_with_z(2000, 1, 3, false, 2.0),
		season.year,
		season.season_number
	)
	player_records.append(replacement.to_dict())

	RecordStore.load_from_dict({
		"player_records": player_records,
		"team_records": [],
		"season_archives": [],
	})
	season.set_active_roster(1, {"player_ids": active_ids})

	var result: Dictionary = TeamAutoAIRef.repair_active_roster_injuries(season, 1, season.current_day)
	var roster_ids: Array = (season.get_active_roster(1).get("player_ids", []) as Array).duplicate()
	var demotion_days: Dictionary = season.get_demotion_days(1).duplicate(true)
	RecordStore.load_from_dict(original_records)

	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(result.get("changed", true))).is_false()
	assert_array(roster_ids).contains(injured_id)
	assert_array(roster_ids).not_contains(2000)
	assert_int(roster_ids.size()).is_equal(TeamAutoAIRef.TARGET_TOTAL)
	assert_bool(demotion_days.has(str(injured_id))).is_false()
	assert_array(result.get("short_injury_stashes", []) as Array).contains(injured_id)


func test_repair_active_roster_injuries_keeps_core_player_until_max_stash_days() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = 44
	var active_ids: Array = []
	var player_records: Array = []
	var positions: Array = [2, 3, 4, 5, 6, 7, 8, 9]
	var injured_id: int = 1020
	for i in range(TeamAutoAIRef.TARGET_TOTAL):
		var position: int = int(positions[i % positions.size()])
		var z_value: float = 2.8 if 1000 + i == injured_id else 0.0
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
			_player_with_z(1000 + i, 1, position, false, z_value),
			season.year,
			season.season_number
		)
		if record.player_id == injured_id:
			record.injury_days = TeamAutoAIRef.INJURY_MAINSTAY_STASH_MAX_DAYS
		active_ids.append(record.player_id)
		player_records.append(record.to_dict())

	var replacement: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		_player_with_z(2000, 1, 3, false, 2.0),
		season.year,
		season.season_number
	)
	player_records.append(replacement.to_dict())

	RecordStore.load_from_dict({
		"player_records": player_records,
		"team_records": [],
		"season_archives": [],
	})
	season.set_active_roster(1, {"player_ids": active_ids})

	var result: Dictionary = TeamAutoAIRef.repair_active_roster_injuries(season, 1, season.current_day)
	var roster_ids: Array = (season.get_active_roster(1).get("player_ids", []) as Array).duplicate()
	var demotion_days: Dictionary = season.get_demotion_days(1).duplicate(true)
	RecordStore.load_from_dict(original_records)

	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(result.get("changed", true))).is_false()
	assert_array(roster_ids).contains(injured_id)
	assert_array(roster_ids).not_contains(2000)
	assert_int(roster_ids.size()).is_equal(TeamAutoAIRef.TARGET_TOTAL)
	assert_bool(demotion_days.has(str(injured_id))).is_false()
	assert_array(result.get("short_injury_stashes", []) as Array).contains(injured_id)


# --- 永続化 ------------------------------------------------------------------

func test_development_fields_round_trip() -> void:
	var player: PSPlayer = _player({"id": 70, "team_id": 1, "development_player": true, "registered_roster": "育成"})
	var restored: PSPlayer = PSPlayer.from_dict(player.to_dict())
	assert_bool(restored.development_player).is_true()
	assert_str(restored.registered_roster).is_equal("育成")


func test_development_contract_salary_uses_separate_scale() -> void:
	var rookie: PSPlayer = _player({
		"id": 71,
		"team_id": 1,
		"years": 1,
		"salary": 350,
		"development_player": true,
		"registered_roster": "育成",
	})
	assert_int(Offseason._compute_new_salary(rookie, null, 0.0)).is_equal(350)

	# 育成のまま更新する限り、在籍年数や一軍査定による自動増減は行わない。
	var continuing: PSPlayer = _player({
		"id": 72,
		"team_id": 1,
		"years": 8,
		"salary": 420,
		"development_player": true,
		"registered_roster": "育成",
	})
	assert_int(Offseason._compute_new_salary(continuing, null, 5.0)).is_equal(420)

	# 支配下から育成へ切り替える時点では、新しい育成契約額へ再設定する。
	var demoted: PSPlayer = _player({"id": 73, "team_id": 1, "years": 8, "salary": 10000})
	Offseason._apply_demotion_to_development(demoted)
	assert_int(demoted.salary).is_equal(Offseason.DEVELOPMENT_CONTRACT_SALARY)

	# 昇格時に支配下最低年俸を保証し、以降は従来の支配下スケールへ戻る。
	Offseason._apply_promotion_to_shienka(demoted)
	assert_int(demoted.salary).is_equal(Offseason.SALARY_MIN)
	assert_int(Offseason._compute_new_salary(demoted, null, 0.0)).is_greater_equal(Offseason.SALARY_MIN)


# --- 戦力外 projection 軸 -----------------------------------------------------

func test_release_projection_prefers_young_at_equal_ability() -> void:
	# 同能力・同出場 (0) ・同年俸なら growth 項だけが差になり、若い方が明確に高く出る。
	var young: PSPlayer = _player_with_z(9601, 1, 3, false, 0.5)
	young.age = 21
	var old: PSPlayer = _player_with_z(9602, 1, 3, false, 0.5)
	old.age = 33
	var young_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(young, 0, 0)
	var old_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(old, 0, 0)
	var young_value: float = ReleaseValueProjector.projected_value(young, young_record)
	var old_value: float = ReleaseValueProjector.projected_value(old, old_record)
	assert_float(young_value - old_value).is_greater(15.0)


func test_release_projection_usage_is_continuous() -> void:
	# 出場割引の飽和点 (80試合) をまたいでも崖を作らない。
	var fielder: PSPlayer = _player_with_z(9603, 1, 3, false, 0.3)
	fielder.age = 26
	var record_79: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fielder, 0, 0)
	record_79.batter_stats.games = 79
	var record_80: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fielder, 0, 0)
	record_80.batter_stats.games = 80
	var value_79: float = ReleaseValueProjector.projected_value(fielder, record_79)
	var value_80: float = ReleaseValueProjector.projected_value(fielder, record_80)
	assert_float(absf(value_80 - value_79)).is_less(1.0)

	# ゼロ出場は current の USAGE_ZERO_DISCOUNT 分だけ割り引かれ、フル出場と明確な差が出る。
	var record_0: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fielder, 0, 0)
	record_0.batter_stats.games = 0
	var value_0: float = ReleaseValueProjector.projected_value(fielder, record_0)
	assert_float(value_80 - value_0).is_greater(10.0)


func test_release_projection_zero_usage_discount_scales_with_ability() -> void:
	# 出場割引は加点ではなく current への乗算: 能力が高いのにゼロ出場の選手ほど
	# 絶対値で大きく疑われる (「高能力を主張しているのに使われていない」ベイズ的証拠)。
	var strong: PSPlayer = _player_with_z(9606, 1, 3, false, 1.5)
	strong.age = 28
	var weak: PSPlayer = _player_with_z(9607, 1, 3, false, -1.5)
	weak.age = 28
	var strong_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(strong, 0, 0)
	strong_record.batter_stats.games = 0
	var weak_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(weak, 0, 0)
	weak_record.batter_stats.games = 0
	var strong_components: Dictionary = ReleaseValueProjector.projected_value_components(strong, strong_record)
	var weak_components: Dictionary = ReleaseValueProjector.projected_value_components(weak, weak_record)
	assert_float(float(strong_components["current"])).is_greater(float(weak_components["current"]))
	assert_float(float(strong_components["usage_evidence"])).is_less(0.0)
	# 割引デルタ (負値) は高能力側の方が大きい。
	assert_float(float(strong_components["usage_evidence"])).is_less(float(weak_components["usage_evidence"]))


func test_release_projection_excuses_usage_lost_to_long_injury() -> void:
	var player: PSPlayer = _player_with_z(9608, 1, 3, false, 1.5)
	player.age = 28
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	record.batter_stats.games = 0
	record.season_injury_days = ReleaseValueProjector.INJURY_EXCUSE_FULL_DAYS
	var components: Dictionary = ReleaseValueProjector.projected_value_components(player, record)
	assert_float(float(components["usage_evidence"])).is_equal_approx(0.0, 0.001)


func test_release_projection_components_sum() -> void:
	var player: PSPlayer = _player_with_z(9604, 1, 1, false, 0.1)
	player.age = 29
	player.role = "starter"
	player.salary = 8000
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	record.pitcher_stats.starts = 10
	var components: Dictionary = ReleaseValueProjector.projected_value_components(player, record)
	var expected_total: float = float(components["current"]) + float(components["growth"]) \
		+ float(components["usage_evidence"]) - float(components["injury_penalty"]) - float(components["salary_penalty"])
	assert_float(float(components["total"])).is_equal_approx(expected_total, 0.001)
	assert_float(ReleaseValueProjector.projected_value(player, record)).is_equal_approx(float(components["total"]), 0.001)


func test_release_projection_null_record_falls_back_to_player_ability() -> void:
	var player: PSPlayer = _player_with_z(9605, 1, 3, false, 0.4)
	player.age = 25
	var components: Dictionary = ReleaseValueProjector.projected_value_components(player, null)
	assert_float(float(components["current"])).is_greater(0.0)


# 補強需要は投手をエース1枚でなく上位K枚平均 (depth) で測る。投手が手薄な球団は position 1 に
# 需要が立ち、エースが同等でも投手 depth の差が need に出る (旧「最良1枚」実装だとゼロだった)。
# これが直らないと戦力外獲得・現役ドラフトで投手がほとんど移動しない。
func test_position_need_reflects_pitcher_depth_not_just_ace() -> void:
	var teams: Array = [_team(1), _team(2)]
	var players: Array = []
	# 両球団に同等の野手 (position 2〜9) → 野手 need はほぼ0。
	for team_id in [1, 2]:
		for pos in range(2, 10):
			players.append(_pitcher_or_fielder(9300 + team_id * 100 + pos, team_id, pos, "", 0.0))
	# team1: 投手12枚すべて強い (depth 厚い)。
	for i in range(12):
		players.append(_pitcher_or_fielder(9400 + i, 1, 1, "starter" if i < 6 else "reliever", 1.2))
	# team2: エース1枚だけ team1 と同等、残り11枚は弱い (depth 薄い)。
	players.append(_pitcher_or_fielder(9500, 2, 1, "starter", 1.2))
	for i in range(11):
		players.append(_pitcher_or_fielder(9501 + i, 2, 1, "starter" if i < 5 else "reliever", -1.5))
	var need: Dictionary = Offseason.position_need(players, teams)
	var thin_need: float = float((need.get(2, {}) as Dictionary).get(1, 0.0))
	var deep_need: float = float((need.get(1, {}) as Dictionary).get(1, 0.0))
	# 投手が手薄な team2 に明確な投手需要が立つ (旧「最良1枚」実装ではゼロだった)。
	assert_float(thin_need).is_greater(3.0)
	# depth が厚い team1 より team2 の方が投手需要が高い。
	assert_float(thin_need).is_greater(deep_need)


# 戦力外獲得のAIは投手を「リーグ相対の positional need」では獲得できない (投手層は深く均一で
# pos1 need が全球団 <MIN_NEED_TO_SIGN)。投手だけは depth-chart fit (would_release_player_for_team)
# で判定し、その球団の枠を勝ち取る投手を獲得する。実シードで 放出→戦力外獲得 を回し、AIが
# 投手を1人以上獲得することを保証する (修正前は投手獲得=0)。
func test_released_market_ai_signs_pitchers_via_depth_fit() -> void:
	Rng.set_seed_value(20260721)
	var players: Array = []
	for row in GameDb.players:
		var p: PSPlayer = row as PSPlayer
		if p != null:
			players.append(PSPlayer.from_dict(p.to_dict()))
	var season: PSSeason = PSSeason.new()
	season.year = 2026
	season.season_number = 1
	var release_result: Dictionary = Offseason.process_cpu_releases(players, GameDb.teams, 0, season)
	var market: Dictionary = ReleasedMarketService.process_released_market(players, GameDb.teams, season, release_result, 0)
	var signed_pitchers: int = 0
	for row in market.get("signings", []) as Array:
		if int((row as Dictionary).get("position", 0)) == 1:
			signed_pitchers += 1
	assert_int(signed_pitchers).override_failure_message(
		"戦力外獲得で投手が1人も獲得されていません (depth-fit ゲートの回帰)"
	).is_greater(0)


# --- helpers -----------------------------------------------------------------

# position=1 は投手 (role 指定・投手 z を付与)、それ以外は野手として z 一律の選手を作る
# (need の depth 検証用)。ALL_Z_KEYS は野手系のみなので投手値が動くよう Pit_ 系も一律で入れる。
const PITCHER_Z_KEYS: Array = [
	"Pit_KCreate", "Pit_Stamina", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_BarrelDeny",
	"Pit_LoftControl", "Pit_Efficiency", "Pit_EdgeRate", "Pit_FatigueResist", "Pit_HoldRunner",
]

func _pitcher_or_fielder(id: int, team_id: int, position: int, role: String, z_value: float) -> PSPlayer:
	var z: Dictionary = {}
	var keys: Array = PITCHER_Z_KEYS if position == 1 else ALL_Z_KEYS
	for key in keys:
		z[key] = z_value
	return _player({
		"id": id,
		"team_id": team_id,
		"position": position,
		"role": role if position == 1 else "fielder",
		"z_abilities": z,
	})


func _release_candidates_with_records(players: Array, records: Array) -> Array:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var record_dicts: Array = []
	for record_row in records:
		record_dicts.append((record_row as PSPlayerSeasonRecord).to_dict())
	RecordStore.load_from_dict({
		"player_records": record_dicts,
		"team_records": [],
		"season_archives": [],
	})
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	var result: Array = Offseason.compute_release_candidates_for_team(players, 1, season)
	RecordStore.load_from_dict(original_records)
	return result


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


func _player_with_z(id: int, team_id: int, position: int, dev: bool, z_value: float) -> PSPlayer:
	var z: Dictionary = {}
	for key in ALL_Z_KEYS:
		z[key] = z_value
	return _player({
		"id": id,
		"team_id": team_id,
		"position": position,
		"role": "fielder",
		"development_player": dev,
		"z_abilities": z,
	})


# team_id の支配下選手を count 人作る (id は 1000 番台)。
func _support_players(team_id: int, count: int) -> Array:
	var players: Array = []
	for i in range(count):
		players.append(_player({"id": 1000 + i, "team_id": team_id}))
	return players


func _released_market_foreign_cap_players(team2_foreign_count: int) -> Array:
	var players: Array = []
	# team1 の強い一塁手で team2 に明確な補強ニーズを作る。
	players.append(_player_with_z(9001, 1, 3, false, 2.5))
	players.append(_player_with_z(9002, 2, 3, false, -2.0))
	for i in range(team2_foreign_count):
		players.append(_player({
			"id": 9050 + i,
			"team_id": 2,
			"position": 1 + (i % 9),
			"foreign_player": true,
		}))
	var released_foreign: PSPlayer = _player_with_z(9100, 0, 3, false, 2.5)
	released_foreign.foreign_player = true
	released_foreign.source_data = {"released": true}
	players.append(released_foreign)
	return players


func _team(team_id: int) -> PSTeam:
	return PSTeam.from_dict({
		"id": team_id,
		"name": "Team %d" % team_id,
		"short_name": "T%d" % team_id,
		"league": "league1",
		# 予算ゲート導入 (2026-07-12) 後もこのファイルの既存テストは支配下枠/年齢等の判定が
		# 主眼なので、年俸で誤ブロックしないよう十分大きな既定予算を持たせる。
		"funds": 400000,
	})
