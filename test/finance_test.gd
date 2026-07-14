extends GdUnitTestSuite

# 年俸・予算経済オーバーホール (2026-07-12): 年次予算キャップの算定式・ハードゲート
# (FA/外国人/戦力外獲得/トレード)・FA金銭補償の資金移動を検証する。


func test_final_ranks_orders_by_win_rate_then_wins() -> void:
	var teams: Array = [_team(1, "central"), _team(2, "central"), _team(3, "pacific"), _team(4, "pacific")]
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


func test_recompute_annual_budgets_formula() -> void:
	var teams: Array = [_team(1, "central", 999999), _team(2, "central", 999999)]
	var season: PSSeason = _season()
	season.standings[1] = _stats(80, 40)
	season.standings[2] = _stats(40, 80)
	var players: Array = []
	var result: Dictionary = TeamFinance.recompute_annual_budgets(players, teams, season, 1)
	var t1: PSTeam = teams[0] as PSTeam
	var t2: PSTeam = teams[1] as PSTeam
	# 繰越なし: 旧 funds (999999) は完全に上書きされる。
	assert_int(t1.funds).is_equal(TeamFinance.BUDGET_BASE + int(TeamFinance.BUDGET_RANK_BONUS[1]) + TeamFinance.BUDGET_LEAGUE_CHAMPION_BONUS + TeamFinance.BUDGET_JAPAN_CHAMPION_BONUS)
	assert_int(t1.previous_rank).is_equal(1)
	assert_int(t2.funds).is_equal(TeamFinance.BUDGET_BASE + int(TeamFinance.BUDGET_RANK_BONUS[2]))
	assert_int(t2.previous_rank).is_equal(2)
	assert_int(int(result.get("over_budget_count", -1))).is_equal(0)


func test_recompute_reports_over_budget() -> void:
	var teams: Array = [_team(1, "central"), _team(2, "central")]
	var season: PSSeason = _season()
	season.standings[1] = _stats(50, 50)
	season.standings[2] = _stats(40, 60)
	var rank2_funds: int = TeamFinance.BUDGET_BASE + int(TeamFinance.BUDGET_RANK_BONUS[2])
	var players: Array = [_player({"id": 1, "team_id": 2, "salary": rank2_funds + 1})]
	var result: Dictionary = TeamFinance.recompute_annual_budgets(players, teams, season, 0)
	assert_int(int(result.get("over_budget_count", 0))).is_equal(1)
	var team2: PSTeam = teams[1] as PSTeam
	assert_bool(TeamFinance.is_over_budget(team2.funds, TeamFinance.team_payroll(players, 2))).is_true()


func test_can_afford_addition_boundary() -> void:
	var team: PSTeam = _team(1, "central", 10000)
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
	var team1: PSTeam = _team(1, "central", 25000)
	var team2: PSTeam = _team(2, "central", 400000)
	var players: Array = []
	# 外国人枠は充足済みなので、後続FA用の予約額だけが必要になる。
	for i in range(TeamFinance.FOREIGN_HELD_TARGET):
		players.append(_player({"id": 10 + i, "team_id": 1, "position": 1, "salary": 1000, "foreign_player": true}))
	# team1に一塁手がいないため補強needを作る。元球団team2は再獲得不可。
	players.append(_player({"id": 20, "team_id": 2, "position": 3, "salary": 1000}))
	var released: PSPlayer = _player({"id": 50, "team_id": 0, "position": 3, "salary": 10000})
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
	var team: PSTeam = _team(1, "central", 28000)
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
	var over_team: PSTeam = _team(1, "central", 10000)
	var over_players: Array = [_player({"id": 1, "team_id": 1, "salary": 10500})]
	# 予算超過中でも年俸総額が減る (or 変わらない) 交換は常に許可。
	assert_bool(TeamFinance.trade_payroll_ok(over_players, over_team, 600, 400)).is_true()
	# 予算超過中に年俸総額が増える交換は不可。
	assert_bool(TeamFinance.trade_payroll_ok(over_players, over_team, 400, 600)).is_false()

	var team: PSTeam = _team(2, "central", 10000)
	var players: Array = [_player({"id": 2, "team_id": 2, "salary": 9000})]
	# 増える交換でも、上限内に収まるなら許可。
	assert_bool(TeamFinance.trade_payroll_ok(players, team, 100, 900)).is_true()
	# 上限を超えるなら不可。
	assert_bool(TeamFinance.trade_payroll_ok(players, team, 100, 1200)).is_false()


func test_fa_user_sign_blocked_when_over_budget() -> void:
	var teams: Array = [_team(1, "central", 10000), _team(2, "central", 10000)]
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
	var teams: Array = [_team(1, "central", 5000), _team(2, "central", 200000), _team(3, "central", 200000)]
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
	var signer: PSTeam = _team(1, "central", 100000)
	var former: PSTeam = _team(2, "central", 100000)
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


func test_fa_stay_ignores_budget() -> void:
	var from_team: PSTeam = _team(2, "central", 100)
	var declarer: PSPlayer = _player({"id": 99, "team_id": 0, "salary": 8000})
	var players: Array = [declarer]
	var entry: Dictionary = {
		"player_id": 99, "from_team": 2, "available": true, "offer_salary": 50000, "compensation_money": 0,
	}
	var state: Dictionary = {"declared": [entry], "signings": [], "failed_negotiations": []}
	var season: PSSeason = _season()
	FaMarketService.finalize_fa_market(state, players, season)
	assert_int(declarer.team_id).is_equal(2)
	assert_int(declarer.salary).is_equal(50000)
	# 残留は予算ゲート対象外: 予算100のまま提示年俸50000が通っても資金は動かない。
	assert_int(from_team.funds).is_equal(100)
	assert_bool(TeamFinance.is_over_budget(from_team.funds, TeamFinance.team_payroll(players, 2))).is_true()


func test_foreign_user_sign_blocked_when_over_budget() -> void:
	var teams: Array = [_team(1, "central", 5000)]
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
	var teams: Array = [_team(1, "central", 5000)]
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
	var user_team: PSTeam = _team(1, "central", 5000)
	var cpu_team: PSTeam = _team(2, "central", 100000)
	var teams: Array = [user_team, cpu_team]
	var give: PSPlayer = _player({"id": 11, "team_id": 1, "salary": 3000})
	var receive: PSPlayer = _player({"id": 21, "team_id": 2, "salary": 9000})
	var players: Array = [give, receive]
	var result: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
	assert_bool(bool(result.get("ok", true))).is_false()
	assert_str(str(result.get("message", ""))).contains("予算")

	# 相手球団が超過方向: 相手球団の残額が小さい。
	var rich_user: PSTeam = _team(3, "central", 5000)
	var poor_cpu: PSTeam = _team(4, "central", 800)
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


func _team(id: int, league: String = "central", funds: int = 400000) -> PSTeam:
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
