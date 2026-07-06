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


func test_execute_trade_moves_players_rosters_and_fa_days() -> void:
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var season: PSSeason = _season(1)
	var player_a: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	var player_b: PSPlayer = _player_with_z(21, 2, 6, false, 1.5)
	var players: Array = [player_a, player_b]
	RecordStore.load_from_dict({
		"player_records": [
			PSPlayerSeasonRecord.from_player(player_a, season.year, season.season_number).to_dict(),
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
	RecordStore.load_from_dict(original_records)

	assert_bool(entry.is_empty()).is_false()
	assert_int(player_a.team_id).is_equal(2)
	assert_int(player_b.team_id).is_equal(1)
	assert_int(record_a.team_id).is_equal(2)
	assert_int(record_b.team_id).is_equal(1)
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


func test_accept_and_decline_user_offer() -> void:
	var season: PSSeason = _season(10)
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

	var accepted: Dictionary = TradeService.accept_user_offer(season, players, 1, 1)
	assert_bool(bool(accepted.get("ok", false))).is_true()
	assert_int(user_player.team_id).is_equal(2)
	assert_int(cpu_player.team_id).is_equal(1)
	assert_int(TradeService.pending_user_offers(season).size()).is_equal(0)

	# 同じ提案は再受諾できない。
	var replay: Dictionary = TradeService.accept_user_offer(season, players, 1, 1)
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
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "league": "central"})


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
