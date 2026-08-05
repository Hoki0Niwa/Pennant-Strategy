extends GdUnitTestSuite

# 年俸・予算経済オーバーホール (2026-07-12、2026-08-04に固定予算へ移行): 予算 (全球団固定額)・
# ハードゲート (FA/外国人/戦力外獲得/トレード)・FA金銭補償の資金移動を検証する。


func test_final_ranks_orders_by_win_rate_then_wins() -> void:
	var teams: Array = [_team(1, "league1"), _team(2, "league1"), _team(3, "league2"), _team(4, "league2")]
	var season: PSSeason = _season()
	season.standings[1] = _stats(70, 50)   # .583
	season.standings[2] = _stats(60, 60)   # .500
	season.standings[3] = _stats(50, 50)   # .500, wins 50
	season.standings[4] = _stats(55, 55)   # .500, wins 55 -> 同率は wins 上位が上位順位
	var ranks: Dictionary = TeamFinance.final_ranks(season, teams)
	assert_int(int(ranks[1])).is_equal(1)
	assert_int(int(ranks[2])).is_equal(2)
	assert_int(int(ranks[4])).is_equal(1)
	assert_int(int(ranks[3])).is_equal(2)


func test_update_previous_ranks_does_not_touch_funds() -> void:
	var teams: Array = [_team(1, "league1", 999999), _team(2, "league1", 999999)]
	var season: PSSeason = _season()
	season.standings[1] = _stats(80, 40)
	season.standings[2] = _stats(40, 80)
	TeamFinance.update_previous_ranks(teams, season)
	var t1: PSTeam = teams[0] as PSTeam
	var t2: PSTeam = teams[1] as PSTeam
	# 予算は固定 (FIXED_BUDGET) のため順位更新では funds は一切変わらない。
	# シード/セーブ由来のバラバラな funds は apply_fixed_budget が揃える (下のテスト)。
	assert_int(t1.funds).is_equal(999999)
	assert_int(t1.previous_rank).is_equal(1)
	assert_int(t2.funds).is_equal(999999)
	assert_int(t2.previous_rank).is_equal(2)


# 予算の単一ソースは FIXED_BUDGET。シード CSV / 旧セーブがどんな funds を持っていても、
# ロード時に apply_fixed_budget が全球団を固定額へ揃える (変動予算制の名残が復活しない保証)。
func test_apply_fixed_budget_levels_every_team() -> void:
	var teams: Array = [_team(1, "league1", 416500), _team(2, "league1", 467600), _team(3, "league2", TeamFinance.FIXED_BUDGET)]
	# 既に固定額の球団は書き換え対象に数えない。
	assert_int(TeamFinance.apply_fixed_budget(teams)).is_equal(2)
	for team_row in teams:
		assert_int((team_row as PSTeam).funds).is_equal(TeamFinance.FIXED_BUDGET)
	assert_int(TeamFinance.apply_fixed_budget(teams)).is_equal(0)


# シード CSV の funds 列も固定額で揃っていること (進化後ワールドを書き出すとバラバラな値が入る)。
func test_initial_teams_csv_funds_are_all_fixed_budget() -> void:
	for row in PSPlayerCsvIo.read_teams("res://data/initial_teams.csv"):
		assert_int(int((row as Dictionary).get("funds", 0))).is_equal(TeamFinance.FIXED_BUDGET)


func test_budget_summary_reports_over_budget() -> void:
	var teams: Array = [_team(1, "league1", TeamFinance.FIXED_BUDGET), _team(2, "league1", TeamFinance.FIXED_BUDGET)]
	var players: Array = [_player({"id": 1, "team_id": 2, "salary": TeamFinance.FIXED_BUDGET + 1})]
	var result: Dictionary = TeamFinance.budget_summary(players, teams)
	assert_int(int(result.get("over_budget_count", 0))).is_equal(1)
	var team2: PSTeam = teams[1] as PSTeam
	assert_bool(TeamFinance.is_over_budget(team2.funds, TeamFinance.team_payroll(players, 2))).is_true()


# 予算ゲートが「来季 payroll」に対して正確に効くための前提: 契約更改 (全選手の年俸再査定) は
# 補強市場より前に走る。ここを最終ステップへ戻すと、ゲート通過後に payroll だけが上振れして
# 翌季を予算超過で開始する構造に逆戻りする。
func test_contract_renewal_precedes_reinforcement_markets() -> void:
	var order: Array = AppState.OFFSEASON_STEP_ORDER
	var renewal_index: int = order.find(AppState.OFFSEASON_STEP_CONTRACT_RENEWAL)
	assert_int(renewal_index).is_greater(order.find(AppState.OFFSEASON_STEP_RETIREMENT))
	assert_int(renewal_index).is_less(order.find(AppState.OFFSEASON_STEP_FA_MARKET))
	assert_int(renewal_index).is_less(order.find(AppState.OFFSEASON_STEP_CONTRACT_YEARS))
	assert_int(renewal_index).is_less(order.find(AppState.OFFSEASON_STEP_FOREIGN_MARKET))


func test_can_afford_addition_boundary() -> void:
	var team: PSTeam = _team(1, "league1", 10000)
	var players: Array = [_player({"id": 1, "team_id": 1, "salary": 9000})]
	assert_bool(TeamFinance.can_afford_addition(players, team, 1000)).is_true()
	assert_bool(TeamFinance.can_afford_addition(players, team, 1001)).is_false()


func test_ai_offseason_reserve_tracks_later_markets() -> void:
	var players: Array = [
		_player({"id": 1, "team_id": 1, "foreign_player": true}),
		_player({"id": 2, "team_id": 1, "foreign_player": true}),
	]
	var full_reserve: int = TeamFinance.ai_offseason_budget_reserve(players, 1, true, true)
	assert_int(full_reserve).is_equal(
		TeamFinance.AI_FA_BUDGET_RESERVE
		+ 2 * TeamFinance.AI_FOREIGN_BUDGET_RESERVE_PER_SLOT
	)
	# 今回の獲得で外国人枠を1つ埋める場合は、残り1枠分だけを予約する。
	var after_foreign_signing: int = TeamFinance.ai_offseason_budget_reserve(players, 1, true, true, 1)
	assert_int(after_foreign_signing).is_equal(
		TeamFinance.AI_FA_BUDGET_RESERVE
		+ TeamFinance.AI_FOREIGN_BUDGET_RESERVE_PER_SLOT
	)


func test_released_cpu_preserves_budget_for_fa() -> void:
	var team1: PSTeam = _team(1, "league1", 25000)
	var team2: PSTeam = _team(2, "league1", 400000)
	var players: Array = []
	# 外国人枠は充足済みなので、後続FA用の予約額だけが必要になる。
	for i in range(TeamFinance.FOREIGN_HELD_TARGET):
		players.append(_player({"id": 10 + i, "team_id": 1, "position": 1, "salary": 1000, "foreign_player": true}))
	# team1に一塁手がいないため補強needを作る。元球団team2は再獲得不可。
	players.append(_player({"id": 20, "team_id": 2, "position": 3, "salary": 1000}))
	# 市場処理は候補の契約額を元年俸から減額提示 (_released_contract_salary) で再同期するため、
	# 減額後がちょうど 10000 (=1000+45000*0.2) になる元年俸を与える。
	var released: PSPlayer = _player({"id": 50, "team_id": 0, "position": 3, "salary": 46000})
	released.source_data["released"] = true
	players.append(released)
	var entry: Dictionary = {
		"player_id": 50, "from_team": 2, "available": true,
		"salary": 10000, "position": 3, "track": "支配下", "value": 70, "war": 2.0,
	}
	var state: Dictionary = {"complete": false, "user_team_id": 0, "candidates": [entry], "signings": []}
	assert_bool(ReleasedMarketService._can_team_afford_release(players, [team1, team2], 1, entry)).is_true()
	assert_bool(ReleasedMarketService._can_ai_afford_release(players, [team1, team2], 1, entry)).is_false()
	ReleasedMarketService.complete_released_market_automatically(state, players, [team1, team2], _season(), 0)
	assert_array(state.get("signings", []) as Array).is_empty()
	assert_int(released.team_id).is_equal(0)


func test_fa_ai_preserves_budget_for_foreign_slots() -> void:
	var team: PSTeam = _team(1, "league1", 28000)
	var players: Array = [
		_player({"id": 1, "team_id": 1, "salary": 1000, "foreign_player": true}),
		_player({"id": 2, "team_id": 1, "salary": 1000, "foreign_player": true}),
	]
	var entry: Dictionary = {"offer_salary": 12000, "compensation_money": 3000, "salary": 8000}
	assert_bool(FaMarketService._can_team_afford_candidate(players, [team], 1, entry)).is_true()
	assert_bool(FaMarketService._can_ai_afford_candidate(players, [team], 1, entry)).is_false()


func test_acquisition_scores_prefer_lower_cost_at_equal_value() -> void:
	var released_cheap: Dictionary = {"value": 65, "war": 1.0, "salary": 1000}
	var released_costly: Dictionary = {"value": 65, "war": 1.0, "salary": 21000}
	assert_float(ReleasedMarketService._signing_score(released_cheap, 5.0, [], [], 1)).is_greater(
		ReleasedMarketService._signing_score(released_costly, 5.0, [], [], 1)
	)
	var fa_cheap: Dictionary = {"value": 72, "war": 2.0, "salary": 8000, "offer_salary": 10000, "compensation_money": 0}
	var fa_costly: Dictionary = {"value": 72, "war": 2.0, "salary": 8000, "offer_salary": 25000, "compensation_money": 10000}
	assert_float(FaMarketService._signing_score(fa_cheap, 5.0, [], [], 1)).is_greater(
		FaMarketService._signing_score(fa_costly, 5.0, [], [], 1)
	)


func test_trade_payroll_ok_decreasing_allowed_increasing_blocked() -> void:
	var over_team: PSTeam = _team(1, "league1", 10000)
	var over_players: Array = [_player({"id": 1, "team_id": 1, "salary": 10500})]
	# 予算超過中でも年俸総額が減る (or 変わらない) 交換は常に許可。
	assert_bool(TeamFinance.trade_payroll_ok(over_players, over_team, 600, 400)).is_true()
	# 予算超過中に年俸総額が増える交換は不可。
	assert_bool(TeamFinance.trade_payroll_ok(over_players, over_team, 400, 600)).is_false()

	var team: PSTeam = _team(2, "league1", 10000)
	var players: Array = [_player({"id": 2, "team_id": 2, "salary": 9000})]
	# 増える交換でも、上限内に収まるなら許可。
	assert_bool(TeamFinance.trade_payroll_ok(players, team, 100, 900)).is_true()
	# 上限を超えるなら不可。
	assert_bool(TeamFinance.trade_payroll_ok(players, team, 100, 1200)).is_false()


func test_fa_user_sign_blocked_when_over_budget() -> void:
	var teams: Array = [_team(1, "league1", 10000), _team(2, "league1", 10000)]
	var players: Array = [_player({"id": 1, "team_id": 1, "salary": 5000})]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "available": true,
		"offer_salary": 50000, "compensation_money": 0,
		"position": 3, "war": 1.0, "value": 70, "salary": 8000,
	}
	var state: Dictionary = {"complete": false, "user_team_id": 1, "declared": [entry], "signings": []}
	var season: PSSeason = _season()
	var result: Dictionary = FaMarketService.submit_user_fa_decision(state, players, teams, season, 99, "sign")
	assert_bool(bool(result.get("ok", true))).is_false()
	assert_str(str(result.get("message", ""))).contains("予算が不足")
	assert_bool(bool(entry.get("available", true))).is_true()


func test_fa_cpu_never_signs_over_budget_team() -> void:
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	# team3 (from_team) にポジション3の在籍選手を置き、リーグ平均needを正にして
	# 貧乏球団(team1)以外が獲得へ動くようにする。
	var incumbent: PSPlayer = _player({"id": 50, "team_id": 3, "position": 3, "salary": 6000})
	var players: Array = [declarer, incumbent]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 3, "available": true,
		"offer_salary": 50000, "compensation_money": 0,
		"position": 3, "war": 1.0, "value": 70, "salary": 8000,
	}
	var teams: Array = [_team(1, "league1", 5000), _team(2, "league1", 200000), _team(3, "league1", 200000)]
	var state: Dictionary = {"complete": false, "user_team_id": 0, "declared": [entry], "signings": []}
	var season: PSSeason = _season()
	# CPU受諾は確率判定 (_contract_success_chance) を経る。予算ゲート自体は決定的だが、
	# 成立/不成立のRngロールを固定して再現性を確保する。
	Rng.set_seed_value(20260712)
	FaMarketService.complete_fa_market_automatically(state, players, teams, season, 0)
	var signings: Array = state.get("signings", []) as Array
	assert_int(signings.size()).is_equal(1)
	assert_int(int((signings[0] as Dictionary).get("to_team", 0))).is_equal(2)


func test_fa_compensation_transfers_funds() -> void:
	var signer: PSTeam = _team(1, "league1", 100000)
	var former: PSTeam = _team(2, "league1", 100000)
	var teams: Array = [signer, former]
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "offer_salary": 20000, "compensation_money": 5000, "fa_rank": "A",
	}
	var state: Dictionary = {"signings": []}
	var season: PSSeason = _season()
	FaMarketService._apply_signing(state, players, teams, season, entry, 1, "user", 1.0)
	assert_int(signer.funds).is_equal(100000 - 5000)
	assert_int(former.funds).is_equal(100000 + 5000)
	assert_int(declarer.salary).is_equal(20000)


# FA宣言したが引き取り手がなかった選手は元球団へ戻るが、**市場提示額は適用されない** —
# 年俸は直前の契約更改で査定済みの額 (= player.salary) のまま。予算ゲートを通らない残留経路で
# payroll が跳ねるのを防ぐと同時に、「他球団の関心が無かったのに市場プレミアムが付く」不整合も消える。
func test_fa_stay_keeps_renewal_salary_instead_of_offer() -> void:
	var from_team: PSTeam = _team(2, "league1", 100000)
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "available": true, "offer_salary": 50000, "compensation_money": 0,
	}
	var state: Dictionary = {"declared": [entry], "signings": [], "failed_negotiations": []}
	var season: PSSeason = _season()
	FaMarketService.finalize_fa_market(state, players, season)
	assert_int(declarer.team_id).is_equal(2)
	assert_int(declarer.salary).is_equal(8000)
	# 残留自体は資金移動を伴わない (補償金が発生するのは移籍のみ)。
	assert_int(from_team.funds).is_equal(100000)


# --- 複数年契約 (FA複数年オファー, 2026-07-17 Step2a) ------------------------

func test_fa_signing_sets_multi_year_contract_keys() -> void:
	var signer: PSTeam = _team(1, "league1", 100000)
	var former: PSTeam = _team(2, "league1", 100000)
	var teams: Array = [signer, former]
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "offer_salary": 20000, "compensation_money": 0, "fa_rank": "A", "offer_years": 3,
	}
	var state: Dictionary = {"signings": []}
	var season: PSSeason = _season()
	season.year = 2030
	FaMarketService._apply_signing(state, players, teams, season, entry, 1, "user", 1.0)
	assert_int(int(declarer.source_data.get("contract_end_year", 0))).is_equal(2033)
	assert_int(int(declarer.source_data.get("contract_total_years", 0))).is_equal(3)
	assert_int(int(declarer.source_data.get("contract_signed_year", 0))).is_equal(2030)
	var signing: Dictionary = (state.get("signings", []) as Array)[0] as Dictionary
	assert_int(int(signing.get("contract_years", 0))).is_equal(3)


# 引き取り手がなく元球団へ戻る宣言者には**契約年数を付けない**。
# 直後の契約年数ステップが決めるため、その目印 (fa_returned_year) だけを立てる。
func test_fa_stay_defers_contract_years_to_contract_years_step() -> void:
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "available": true, "offer_salary": 50000, "compensation_money": 0, "offer_years": 2,
	}
	var state: Dictionary = {"declared": [entry], "signings": [], "failed_negotiations": []}
	var season: PSSeason = _season()
	season.year = 2030
	FaMarketService.finalize_fa_market(state, players, season)
	assert_int(declarer.team_id).is_equal(2)
	assert_int(declarer.salary).is_equal(8000)
	assert_int(int(declarer.source_data.get("fa_returned_year", 0))).is_equal(2030)
	assert_bool(declarer.source_data.has("contract_end_year")).is_false()
	assert_bool(declarer.source_data.has("contract_total_years")).is_false()
	# FA権行使済みの履歴 (現役ドラフト対象外の判定などが参照する) は残る。
	assert_int(int(declarer.source_data.get("fa_signed_year", 0))).is_equal(2030)


func test_fa_offer_max_years_age_boundaries() -> void:
	assert_int(FaMarketService.fa_offer_max_years(29)).is_equal(4)
	assert_int(FaMarketService.fa_offer_max_years(30)).is_equal(3)
	assert_int(FaMarketService.fa_offer_max_years(32)).is_equal(3)
	assert_int(FaMarketService.fa_offer_max_years(33)).is_equal(2)
	assert_int(FaMarketService.fa_offer_max_years(35)).is_equal(2)
	assert_int(FaMarketService.fa_offer_max_years(36)).is_equal(1)
	assert_int(FaMarketService.fa_offer_max_years(45)).is_equal(1)


func test_fa_success_chance_increases_with_offer_years() -> void:
	# value/war にペナルティを持たせて基準成立率を下げ、年数ボーナス加算後も
	# FA_SIGN_CHANCE_MAX (0.88) の天井に当たらないようにする。
	var short_entry: Dictionary = {"value": 70, "war": 1.0, "salary": 8000, "offer_salary": 8000, "offer_years": 1}
	var long_entry: Dictionary = short_entry.duplicate()
	long_entry["offer_years"] = 4
	var short_chance: float = FaMarketService._contract_success_chance(short_entry, 0.0, "cpu")
	var long_chance: float = FaMarketService._contract_success_chance(long_entry, 0.0, "cpu")
	assert_float(long_chance).is_greater(short_chance)
	assert_float(long_chance - short_chance).is_equal_approx(FaMarketService.FA_SIGN_YEARS_BONUS_MAX, 0.0001)


func test_fa_user_offer_years_clamped_to_age_limit() -> void:
	var teams: Array = [_team(1, "league1", 999999), _team(2, "league1", 100000)]
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 5000, "age": 37})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "available": true,
		"offer_salary": 8000, "compensation_money": 0,
		"position": 3, "war": 0.0, "value": 50, "salary": 5000, "age": 37, "offer_years": 1,
	}
	var state: Dictionary = {"complete": false, "user_team_id": 1, "declared": [entry], "signings": []}
	var season: PSSeason = _season()
	# 提示4年 (37歳の上限=1年) を要求しても、成立可否に関わらず entry は上限クランプ後の値になる。
	FaMarketService.submit_user_fa_decision(state, players, teams, season, 99, "sign", 4)
	var updated_entry: Dictionary = (state.get("declared", []) as Array)[0] as Dictionary
	assert_int(int(updated_entry.get("offer_years", 0))).is_equal(FaMarketService.fa_offer_max_years(37))


func test_foreign_user_sign_blocked_when_over_budget() -> void:
	var teams: Array = [_team(1, "league1", 5000)]
	var players: Array = [_player({"id": 1, "team_id": 1, "salary": 4000})]
	var candidate: Dictionary = {
		"candidate_id": 1, "available": true, "salary": 2000, "position": 3,
		"player_data": {
			"id": 500, "team_id": 0, "name": "Foreign X", "age": 27, "position": 3, "role": "fielder",
			"z_abilities": {}, "raw_abilities": {}, "foreign_player": true,
		},
		"tier": "average", "value": 60,
	}
	var state: Dictionary = {"complete": false, "user_team_id": 1, "candidates": [candidate], "signings": [], "next_player_id": 999}
	var season: PSSeason = _season()
	var result: Dictionary = ForeignPlayerService.submit_user_foreign_decision(state, players, teams, season, 1, "sign")
	assert_bool(bool(result.get("ok", true))).is_false()
	assert_str(str(result.get("message", ""))).contains("予算が不足")


func test_released_user_sign_blocked_when_over_budget() -> void:
	var teams: Array = [_team(1, "league1", 5000)]
	var candidate_player: PSPlayer = _player({"id": 50, "team_id": 0, "salary": 2000, "position": 3})
	candidate_player.source_data["released"] = true
	var players: Array = [_player({"id": 1, "team_id": 1, "salary": 4000}), candidate_player]
	var entry: Dictionary = {
		"player_id": 50, "from_team": 2, "available": true, "salary": 2000, "position": 3, "track": "支配下",
	}
	var state: Dictionary = {"complete": false, "user_team_id": 1, "candidates": [entry], "signings": []}
	var season: PSSeason = _season()
	var result: Dictionary = ReleasedMarketService.submit_user_released_decision(state, players, teams, season, 50, "sign")
	assert_bool(bool(result.get("ok", true))).is_false()
	assert_str(str(result.get("message", ""))).contains("予算が不足")


func test_trade_validation_blocks_payroll_increase_over_budget() -> void:
	var season: PSSeason = _season()

	# 自軍が超過方向: user_team の残額が小さく、受け取り年俸が放出年俸を大きく上回る。
	var user_team: PSTeam = _team(1, "league1", 5000)
	var cpu_team: PSTeam = _team(2, "league1", 100000)
	var teams: Array = [user_team, cpu_team]
	var give: PSPlayer = _player({"id": 11, "team_id": 1, "salary": 3000})
	var receive: PSPlayer = _player({"id": 21, "team_id": 2, "salary": 9000})
	var players: Array = [give, receive]
	var result: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
	assert_bool(bool(result.get("ok", true))).is_false()
	assert_str(str(result.get("message", ""))).contains("予算")

	# 相手球団が超過方向: 相手球団の残額が小さい。
	var rich_user: PSTeam = _team(3, "league1", 5000)
	var poor_cpu: PSTeam = _team(4, "league1", 800)
	var teams2: Array = [rich_user, poor_cpu]
	var give2: PSPlayer = _player({"id": 12, "team_id": 3, "salary": 1000})
	var receive2: PSPlayer = _player({"id": 31, "team_id": 4, "salary": 500})
	var players2: Array = [give2, receive2]
	var result2: Dictionary = TradeService.evaluate_user_proposal(season, players2, teams2, 3, [12], [31])
	assert_bool(bool(result2.get("ok", true))).is_false()
	assert_str(str(result2.get("message", ""))).contains("予算")


# ---- helpers -------------------------------------------------------------------

func _season(day: int = 100) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = day
	season.calendar_start_date = "2099-03-27"
	return season


func _stats(wins: int, losses: int) -> PSStats:
	var stats: PSStats = PSStats.new()
	stats.wins = wins
	stats.losses = losses
	stats.games = wins + losses
	return stats


func _team(id: int, league: String = "league1", funds: int = 400000) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "short_name": "T%d" % id, "league": league, "funds": funds})


func _player(data: Dictionary) -> PSPlayer:
	var payload: Dictionary = {
		"age": 26,
		"years": 5,
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
