extends GdUnitTestSuite

# シーズン中トレード v1: 対象判定、交換期限、成立時の状態遷移 (team_id / 当季record /
# 一軍ロスター / FA日数台帳の移管)、CPU受諾判定、trade_state のセーブ round-trip を検証する。

const ALL_Z_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Spray", "Bat_Aggression", "Bat_Platoon",
	"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
	"Run_Speed", "Run_Judgment", "Run_Steal",
]


func test_trade_window_respects_deadline() -> void:
	var season: PSSeason = _season(10)
	assert_bool(TradeService.is_trade_window_open(season)).is_true()
	# 3/27 開幕の day140 は 8月中旬 → 期限 (7/31) 超過。
	season.current_day = 140
	assert_bool(TradeService.is_trade_window_open(season)).is_false()
	# カレンダー無しはフォールバック day 判定。
	season.calendar_start_date = ""
	season.current_day = TradeService.TRADE_WINDOW_FALLBACK_LAST_DAY
	assert_bool(TradeService.is_trade_window_open(season)).is_true()
	season.current_day = TradeService.TRADE_WINDOW_FALLBACK_LAST_DAY + 1
	assert_bool(TradeService.is_trade_window_open(season)).is_false()


# 支配下登録期限 (7/31) の最終試合日判定。**カレンダー上の 7/31 ではなく「次の試合日」で見る** —
# 7/31 が試合の無い日だと日次フックがその day で呼ばれず、単純な翌日判定では年によって取りこぼす。
func test_is_last_window_game_day_uses_next_game_day() -> void:
	var season: PSSeason = _season(1)
	# 3/27 開幕なので day127 = 7/31、day128 = 8/1。
	assert_bool(TradeService.is_window_open_on_day(season, 127)).is_true()
	assert_bool(TradeService.is_window_open_on_day(season, 128)).is_false()
	# 期限日に試合がある年: その日が最終試合日。
	assert_bool(TradeService.is_last_window_game_day(season, 127, 128)).is_true()
	assert_bool(TradeService.is_last_window_game_day(season, 126, 127)).is_false()
	# 7/31 が試合の無い日で、次の試合が 8/2 の年: 7/30 が最終試合日になる。
	assert_bool(TradeService.is_last_window_game_day(season, 126, 129)).is_true()
	# 期限を過ぎた日はどう呼ばれても false。
	assert_bool(TradeService.is_last_window_game_day(season, 128, 129)).is_false()
	# 以降試合なし (-1) はシーズン終端なので最終日扱い。
	assert_bool(TradeService.is_last_window_game_day(season, 120, -1)).is_true()


func test_is_tradeable_excludes_foreign_development_injured_rookie() -> void:
	assert_bool(TradeService.is_tradeable(_player({"id": 1, "team_id": 1}))).is_true()
	assert_bool(TradeService.is_tradeable(_player({"id": 2, "team_id": 1, "foreign_player": true}))).is_false()
	assert_bool(TradeService.is_tradeable(_player({"id": 3, "team_id": 1, "development_player": true}))).is_false()
	assert_bool(TradeService.is_tradeable(_player({"id": 4, "team_id": 1, "injury_days": 5}))).is_false()
	var rookie: PSPlayer = _player({"id": 5, "team_id": 1, "years": 1})
	rookie.source_data["rookie_year"] = true
	assert_bool(TradeService.is_tradeable(rookie)).is_false()
	var free_agent: PSPlayer = _player({"id": 6, "team_id": 1})
	free_agent.source_data["free_agent"] = true
	assert_bool(TradeService.is_tradeable(free_agent)).is_false()


func test_is_tradeable_respects_multi_year_contract_lock() -> void:
	var locked_this_year: PSPlayer = _player({"id": 7, "team_id": 1, "source_data": {"contract_end_year": 2026}})
	assert_bool(TradeService.is_tradeable(locked_this_year, 2026)).is_false()
	var expired_contract: PSPlayer = _player({"id": 8, "team_id": 1, "source_data": {"contract_end_year": 2025}})
	assert_bool(TradeService.is_tradeable(expired_contract, 2026)).is_true()
	# season_year 省略時 (0) はロック判定をスキップする (呼び出し元互換)。
	var locked_no_year_arg: PSPlayer = _player({"id": 9, "team_id": 1, "source_data": {"contract_end_year": 2099}})
	assert_bool(TradeService.is_tradeable(locked_no_year_arg)).is_true()


func test_trade_value_accounts_for_salary_at_equal_future_value() -> void:
	var cheap: PSPlayer = _player_with_z(7, 1, 3, false, 1.0)
	var costly: PSPlayer = _player_with_z(8, 1, 3, false, 1.0)
	cheap.salary = 1000
	costly.salary = 31000
	assert_float(TradeService.trade_value(cheap)).is_greater(TradeService.trade_value(costly))


func test_execute_trade_moves_players_rosters_and_fa_days() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = _season(1)
	var player_a: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	var player_b: PSPlayer = _player_with_z(21, 2, 6, false, 1.5)
	var player_a_peer: PSPlayer = _player_with_z(12, 1, 4, false, 0.5)
	var player_b_peer: PSPlayer = _player_with_z(22, 2, 5, false, 0.5)
	var players: Array = [player_a, player_b]
	RecordStore.load_from_dict({
		"player_records": [
			PSPlayerSeasonRecord.from_player(player_a, season.year, season.season_number).to_dict(),
			PSPlayerSeasonRecord.from_player(player_b_peer, season.year, season.season_number).to_dict(),
			PSPlayerSeasonRecord.from_player(player_a_peer, season.year, season.season_number).to_dict(),
			PSPlayerSeasonRecord.from_player(player_b, season.year, season.season_number).to_dict(),
		],
		"team_records": [],
		"season_archives": [],
	})
	season.set_active_roster(1, {"player_ids": [11]})
	season.set_active_roster(2, {"player_ids": [21]})
	season.current_day = 30

	var entry: Dictionary = TradeService.execute_trade(season, players, 1, [11], 2, [21], "cpu")
	var record_a: PSPlayerSeasonRecord = RecordStore.get_player_record(11, season.year, season.season_number)
	var record_b: PSPlayerSeasonRecord = RecordStore.get_player_record(21, season.year, season.season_number)
	var roster_1: Array = season.get_active_roster(1).get("player_ids", []) as Array
	var roster_2: Array = season.get_active_roster(2).get("player_ids", []) as Array
	var moved_days_a: int = season.get_active_roster_days(2, 11)
	var moved_days_b: int = season.get_active_roster_days(1, 21)
	var indexed_team_1_ids: Array = _record_ids(
		RecordStore.get_team_player_records(1, season.year, season.season_number)
	)
	var indexed_team_2_ids: Array = _record_ids(
		RecordStore.get_team_player_records(2, season.year, season.season_number)
	)
	RecordStore.load_from_dict(original_records)

	assert_bool(entry.is_empty()).is_false()
	assert_int(player_a.team_id).is_equal(2)
	assert_int(player_b.team_id).is_equal(1)
	assert_int(record_a.team_id).is_equal(2)
	assert_int(record_b.team_id).is_equal(1)
	assert_array(indexed_team_1_ids).is_equal([12, 21])
	assert_array(indexed_team_2_ids).is_equal([11, 22])
	assert_array(roster_1).contains([21])
	assert_array(roster_1).not_contains([11])
	assert_array(roster_2).contains([11])
	assert_array(roster_2).not_contains([21])
	# day1 → day30 の29日分が移籍先台帳へ移管される (移籍元で消え、二重計上しない)。
	assert_int(moved_days_a).is_equal(29)
	assert_int(moved_days_b).is_equal(29)
	assert_int(season.get_active_roster_days(1, 11)).is_equal(0)
	assert_int(season.get_active_roster_days(2, 21)).is_equal(0)
	assert_int(TradeService.executed_trades(season).size()).is_equal(1)
	assert_int(TradeService.trades_count_for_team(season, 1)).is_equal(1)
	assert_int(TradeService.trades_count_for_team(season, 2)).is_equal(1)
	assert_int(int(player_a.source_data.get("traded_from_team", 0))).is_equal(1)


func test_evaluate_user_proposal_accepts_favorable_rejects_unfavorable() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = [_team(1), _team(2)]
	# 自軍(1)の強打者 と 相手(2)の控え。相手に差し出すなら受諾、逆なら拒否。
	var strong: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	var weak: PSPlayer = _player_with_z(21, 2, 6, false, -1.0)
	var players: Array = [strong, weak]

	var favorable: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
	assert_bool(bool(favorable.get("ok", false))).is_true()
	assert_bool(bool(favorable.get("accepted", false))).is_true()

	# 逆方向 (相手のスターを控えで要求) は拒否される。
	var strong_cpu: PSPlayer = _player_with_z(22, 2, 3, false, 2.0)
	var weak_user: PSPlayer = _player_with_z(12, 1, 6, false, -1.0)
	var players_2: Array = [strong_cpu, weak_user]
	var unfavorable: Dictionary = TradeService.evaluate_user_proposal(season, players_2, teams, 1, [12], [22])
	assert_bool(bool(unfavorable.get("ok", false))).is_true()
	assert_bool(bool(unfavorable.get("accepted", false))).is_false()

	# 期限後は提案不可。
	season.current_day = 140
	var closed: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
	assert_bool(bool(closed.get("ok", false))).is_false()


func test_evaluate_user_proposal_rejects_invalid_sides() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = [_team(1), _team(2), _team(3)]
	var mine: PSPlayer = _player_with_z(11, 1, 3, false, 1.0)
	var theirs_a: PSPlayer = _player_with_z(21, 2, 6, false, 1.0)
	var theirs_b: PSPlayer = _player_with_z(31, 3, 6, false, 1.0)
	var foreign: PSPlayer = _player({"id": 22, "team_id": 2, "foreign_player": true})
	var players: Array = [mine, theirs_a, theirs_b, foreign]

	# 相手側が複数球団にまたがる提案は不可。
	var mixed: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21, 31])
	assert_bool(bool(mixed.get("ok", false))).is_false()
	# トレード対象外 (外国人) を含む提案は不可。
	var with_foreign: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [22])
	assert_bool(bool(with_foreign.get("ok", false))).is_false()


# 人数不均等な提案 (2対1) で受け側の支配下が70枠を超える場合は不可 (2026-07-10 修正)。
# 自軍がちょうど70人(givenの1人含む)の状態で1人放出・2人受け取りなら71人になり超過する。
func test_evaluate_user_proposal_rejects_when_capacity_exceeded() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = [_team(1), _team(2)]
	var players: Array = []
	for i in range(TeamFinance.CONTROLLED_LIMIT - 1):
		players.append(_player({"id": 100 + i, "team_id": 1}))
	var give: PSPlayer = _player_with_z(11, 1, 3, false, -1.0)
	var receive_a: PSPlayer = _player_with_z(21, 2, 6, false, 1.0)
	var receive_b: PSPlayer = _player_with_z(22, 2, 4, false, 1.0)
	players.append(give)
	players.append(receive_a)
	players.append(receive_b)
	assert_int(TeamFinance.controlled_count(players, 1)).is_equal(TeamFinance.CONTROLLED_LIMIT)

	var result: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21, 22])
	assert_bool(bool(result.get("ok", false))).is_false()


# 自軍も CPU 間トレードと同じ球団別年間上限 (MAX_TRADES_PER_TEAM) の対象であること
# (2026-07-10 修正: 従来は相手球団の上限しか見ておらず自軍だけ無制限に成立できた)。
func test_evaluate_user_proposal_rejects_when_user_team_over_trade_limit() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = [_team(1), _team(2)]
	var strong: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	var weak: PSPlayer = _player_with_z(21, 2, 6, false, -1.0)
	var players: Array = [strong, weak]
	var state: Dictionary = TradeService.trade_state(season)
	(state["trades_by_team"] as Dictionary)[str(1)] = TradeService.MAX_TRADES_PER_TEAM

	var result: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(result.get("accepted", false))).is_false()


func test_accept_and_decline_user_offer() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = [_team(1), _team(2)]
	var user_player: PSPlayer = _player_with_z(11, 1, 3, false, 1.0)
	var cpu_player: PSPlayer = _player_with_z(21, 2, 6, false, 1.0)
	var players: Array = [user_player, cpu_player]
	season.set_active_roster(1, {"player_ids": [11]})
	season.set_active_roster(2, {"player_ids": [21]})
	var state: Dictionary = TradeService.trade_state(season)
	(state["user_offers"] as Array).append_array([
		{"id": 1, "status": "pending", "day": 10, "expires_day": 24, "cpu_team_id": 2, "cpu_player_ids": [21], "user_player_ids": [11]},
		{"id": 2, "status": "pending", "day": 10, "expires_day": 24, "cpu_team_id": 2, "cpu_player_ids": [21], "user_player_ids": [11]},
	])

	var declined: Dictionary = TradeService.decline_user_offer(season, 2)
	assert_bool(bool(declined.get("ok", false))).is_true()
	assert_int(TradeService.pending_user_offers(season).size()).is_equal(1)

	var accepted: Dictionary = TradeService.accept_user_offer(season, players, teams, 1, 1)
	assert_bool(bool(accepted.get("ok", false))).is_true()
	assert_int(user_player.team_id).is_equal(2)
	assert_int(cpu_player.team_id).is_equal(1)
	assert_int(TradeService.pending_user_offers(season).size()).is_equal(0)

	# 同じ提案は再受諾できない。
	var replay: Dictionary = TradeService.accept_user_offer(season, players, teams, 1, 1)
	assert_bool(bool(replay.get("ok", false))).is_false()


func test_offer_expiry_and_check_interval_gate() -> void:
	var season: PSSeason = _season(10)
	var state: Dictionary = TradeService.trade_state(season)
	(state["user_offers"] as Array).append({
		"id": 1, "status": "pending", "day": 1, "expires_day": 8, "cpu_team_id": 2, "cpu_player_ids": [21], "user_player_ids": [11],
	})
	TradeService.prune_expired_offers(season, 9)
	assert_int(TradeService.pending_user_offers(season).size()).is_equal(0)

	# 週次ゲート: 前回チェックから CHECK_INTERVAL_DAYS 未満なら last_check_day を更新しない。
	state["last_check_day"] = 10
	TradeService.run_periodic_trade_check(season, [_player({"id": 1, "team_id": 1})], [_team(1)], 12, 0)
	assert_int(int(TradeService.trade_state(season).get("last_check_day", 0))).is_equal(10)
	TradeService.run_periodic_trade_check(season, [_player({"id": 1, "team_id": 1})], [_team(1)], 17, 0)
	assert_int(int(TradeService.trade_state(season).get("last_check_day", 0))).is_equal(17)


func test_trade_state_survives_save_round_trip() -> void:
	var season: PSSeason = _season(1)
	var player_a: PSPlayer = _player_with_z(11, 1, 3, false, 1.0)
	var player_b: PSPlayer = _player_with_z(21, 2, 6, false, 1.0)
	season.set_active_roster(1, {"player_ids": [11]})
	season.set_active_roster(2, {"player_ids": [21]})
	TradeService.execute_trade(season, [player_a, player_b], 1, [11], 2, [21], "cpu")

	var restored: PSSeason = PSSeason.from_dict(season.to_dict())
	assert_int(TradeService.executed_trades(restored).size()).is_equal(1)
	assert_int(TradeService.trades_count_for_team(restored, 1)).is_equal(1)
	var entry: Dictionary = TradeService.executed_trades(restored)[0] as Dictionary
	assert_str(str(entry.get("source", ""))).is_equal("cpu")


# auto_trade_for_user_team はスキップ中/自動入替とは独立に自軍をCPU間トレードマッチングへ
# 含める (include_user_trade)。一二軍自動入替 (include_user_team) が無効でも、
# トレードだけ自動委任できることを AppState 側の ctx 組み立てで確認する。
func test_build_auto_swap_ctx_includes_trade_flag_independently() -> void:
	var old_swap: bool = AppState.auto_roster_swap_for_user_team
	var old_trade: bool = AppState.auto_trade_for_user_team
	AppState.auto_roster_swap_for_user_team = false
	AppState.auto_trade_for_user_team = true
	var ctx: Dictionary = AppState.call("_build_auto_swap_ctx", false)
	assert_bool(bool(ctx.get("include_user_team", true))).is_false()
	assert_bool(bool(ctx.get("include_user_trade", false))).is_true()

	AppState.auto_trade_for_user_team = false
	var ctx_off: Dictionary = AppState.call("_build_auto_swap_ctx", false)
	assert_bool(bool(ctx_off.get("include_user_trade", true))).is_false()

	AppState.auto_roster_swap_for_user_team = old_swap
	AppState.auto_trade_for_user_team = old_trade


func test_surplus_keeps_position_leaders() -> void:
	# 一塁に3人 (値差あり): 上位2人は余剰にならず、3番手だけが出せる駒になる。
	var players: Array = [
		_player_with_z(11, 1, 3, false, 2.0),
		_player_with_z(12, 1, 3, false, 1.0),
		_player_with_z(13, 1, 3, false, 0.0),
	]
	var surplus: Array = TradeService.build_surplus_candidates(players, 1)
	assert_int(surplus.size()).is_equal(1)
	assert_int((surplus[0] as PSPlayer).id).is_equal(13)


# ---- helpers -------------------------------------------------------------------

func _season(day: int) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = 2099
	season.season_number = 1
	season.current_day = day
	season.calendar_start_date = "2099-03-27"
	return season


func _team(id: int) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "league": "league1"})


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


func _record_ids(records: Array) -> Array:
	var ids: Array = []
	for record_value in records:
		ids.append((record_value as PSPlayerSeasonRecord).player_id)
	return ids
