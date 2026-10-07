extends GdUnitTestSuite

# シーズン中トレード: 対象判定、交換期限、成立時の状態遷移 (team_id / 当季record /
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

	# 相手側が複数球団にまたがる提案は不可。理由まで固定する (ok=false は別の理由でも立つため)。
	var mixed: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21, 31])
	assert_bool(bool(mixed.get("ok", false))).is_false()
	assert_str(str(mixed.get("message", ""))).contains("同一の他球団")
	# トレード対象外 (外国人) を含む提案は不可。
	var with_foreign: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [22])
	assert_bool(bool(with_foreign.get("ok", false))).is_false()
	assert_str(str(with_foreign.get("message", ""))).contains("トレード対象にできません")


# 人数不均等な提案 (2対1) で受け側の支配下が70枠を超える場合は不可。
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
	# **理由まで固定する**。ok=false だけだと、枠チェックを外しても予算チェックが同じ提案を
	# 弾いてもテストが通ってしまい、70枠の検証にならない。
	assert_str(str(result.get("message", ""))).contains("支配下枠")


# 自軍も CPU 間トレードと同じ球団別年間上限 (MAX_TRADES_PER_TEAM) の対象であること
# (相手球団の上限しか見ないと、自軍だけ無制限にトレードを成立させられる)。
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


# 自軍を CPU 間のトレードマッチングへ含めるか (include_user_trade) は、トレード用の 2 つのトグルだけで
# 決まる: auto_trade_for_user_team (常時) と auto_trade_during_skip (スキップ中のみ)。
# 一二軍の自動入替トグルはトレードを巻き込まない (スキップしただけで自軍の選手が出て行かない)。
func test_build_auto_swap_ctx_includes_trade_flag_independently() -> void:
	var old_swap: bool = AppState.auto_roster_swap_for_user_team
	var old_swap_skip: bool = AppState.auto_roster_swap_during_skip
	var old_trade: bool = AppState.auto_trade_for_user_team
	var old_trade_skip: bool = AppState.auto_trade_during_skip
	AppState.auto_roster_swap_for_user_team = false
	AppState.auto_trade_during_skip = false
	AppState.auto_trade_for_user_team = true
	var ctx: Dictionary = AppState.call("_build_auto_swap_ctx", false)
	assert_bool(bool(ctx.get("include_user_team", true))).is_false()
	assert_bool(bool(ctx.get("include_user_trade", false))).is_true()

	AppState.auto_trade_for_user_team = false
	var ctx_off: Dictionary = AppState.call("_build_auto_swap_ctx", false)
	assert_bool(bool(ctx_off.get("include_user_trade", true))).is_false()

	# 入替トグルが有効でも、トレードのトグルが無効なら自軍はマッチングに入らない。
	AppState.auto_roster_swap_for_user_team = true
	AppState.auto_roster_swap_during_skip = true
	assert_bool(bool((AppState.call("_build_auto_swap_ctx", false) as Dictionary).get("include_user_trade", true))).is_false()
	var ctx_skip_off: Dictionary = AppState.call("_build_auto_swap_ctx", true)
	assert_bool(bool(ctx_skip_off.get("include_user_team", false))).is_true()
	assert_bool(bool(ctx_skip_off.get("include_user_trade", true))).is_false()

	# スキップ中のみ許可: スキップの ctx だけ自軍を含める。
	AppState.auto_trade_during_skip = true
	assert_bool(bool((AppState.call("_build_auto_swap_ctx", true) as Dictionary).get("include_user_trade", false))).is_true()
	assert_bool(bool((AppState.call("_build_auto_swap_ctx", false) as Dictionary).get("include_user_trade", true))).is_false()

	AppState.auto_roster_swap_for_user_team = old_swap
	AppState.auto_roster_swap_during_skip = old_swap_skip
	AppState.auto_trade_for_user_team = old_trade
	AppState.auto_trade_during_skip = old_trade_skip


# 通知に使う件数: 返事待ち (pending) だけを数え、交換期限を過ぎたら保留が残っていても 0。
# 数えるだけで trade_state に既定キーを書き足さない (画面を開いただけで未保存の変更にしない)。
func test_actionable_user_offer_count_counts_pending_within_window() -> void:
	var season: PSSeason = _season(10)
	assert_int(TradeService.actionable_user_offer_count(season)).is_equal(0)
	assert_bool(season.trade_state.is_empty()).is_true()
	assert_int(TradeService.actionable_user_offer_count(null)).is_equal(0)

	season.trade_state = {"user_offers": [
		{"id": 1, "status": "pending", "expires_day": 24},
		{"id": 2, "status": "declined", "expires_day": 24},
		{"id": 3, "status": "pending", "expires_day": 24},
	]}
	assert_int(TradeService.actionable_user_offer_count(season)).is_equal(2)
	season.current_day = 140
	assert_int(TradeService.actionable_user_offer_count(season)).is_equal(0)


# 週次判定の結果から自軍に関わるものだけを拾い、消化結果の message の先頭に通知を載せる。
# 載せたら数え直しになる (次の消化に持ち越さない)。
func test_trade_check_results_become_status_notice_once() -> void:
	var old_team_id: int = AppState.selected_team_id
	AppState.selected_team_id = 1
	var ctx: Dictionary = AppState.call("_build_auto_swap_ctx", false)
	var on_trade_check: Callable = ctx.get("on_trade_check", Callable()) as Callable
	assert_bool(on_trade_check.is_valid()).is_true()

	# 他球団同士の成立と、提案なしの判定は通知にならない。
	on_trade_check.call({"executed": [{"team_a": 2, "team_b": 3}], "user_offers_added": 0})
	var quiet: Dictionary = {"message": "消化しました"}
	assert_str(str(AppState.call("_attach_trade_notice", quiet))).is_equal("消化しました")

	on_trade_check.call({"executed": [{"team_a": 2, "team_b": 1}, {"team_a": 4, "team_b": 5}], "user_offers_added": 1})
	var result: Dictionary = {"message": "消化しました"}
	var message: String = str(AppState.call("_attach_trade_notice", result))
	assert_str(message).contains(Loc.t("trade.notice.offer_arrived", {"count": 1}))
	assert_str(message).contains(Loc.t("trade.notice.auto_executed", {"count": 1}))
	assert_str(message).ends_with("消化しました")
	assert_str(str(result.get("message", ""))).is_equal(message)

	var after: Dictionary = {"message": "次の日"}
	assert_str(str(AppState.call("_attach_trade_notice", after))).is_equal("次の日")
	AppState.selected_team_id = old_team_id


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


func test_trade_needs_match_full_depth_chart_current_values() -> void:
	var teams: Array = [_team(3), _team(1), _team(2), _team(4)]
	var players: Array = []
	for team_id in [1, 2, 3]:
		for position in range(2, 10):
			players.append(_player_with_z(team_id * 100 + position, team_id, position, false, float(team_id - 2)))
		for index in range(8):
			players.append(_player({
				"id": team_id * 100 + 20 + index,
				"team_id": team_id,
				"position": 1,
				"role": "starter" if index < team_id + 1 else "reliever",
				"z_abilities": {"Pit_KCreate": float(index) / 3.0, "Pit_BBPrevent": float(team_id)},
			}))
	var prospect: PSPlayer = _player_with_z(500, 1, 3, true, 3.0)
	players.append(prospect)
	var retired: PSPlayer = _player_with_z(501, 2, 3, false, 4.0)
	retired.source_data["retired"] = true
	players.append(retired)
	var full_charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var expected: Dictionary = {}
	for team in teams:
		var team_need: Dictionary = {}
		for position in range(2, 10):
			team_need[position] = TeamDepthChart.slot_need(full_charts[team.id], TeamDepthChart.fielder_slot_key(position))
		team_need[TradeService.SLOT_STARTER] = TeamDepthChart.slot_need(full_charts[team.id], TeamDepthChart.SLOT_STARTER)
		team_need[TradeService.SLOT_RELIEVER] = TeamDepthChart.slot_need(full_charts[team.id], TeamDepthChart.SLOT_RELIEVER)
		expected[team.id] = team_need
	assert_dict(TradeService.build_team_needs(players, teams)).is_equal(expected)
	assert_float(float((expected[4] as Dictionary)[3])).is_greater(0.0)
	# 次の探索では、移籍後の所属で需要を測る。
	(players[0] as PSPlayer).team_id = 4
	assert_dict(TradeService.build_team_needs(players, teams)).is_not_equal(expected)


func test_surplus_protects_current_leaders_before_tradeability_filter() -> void:
	var foreign_leader: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	foreign_leader.foreign_player = true
	var expensive_leader: PSPlayer = _player_with_z(12, 1, 3, false, 1.0)
	expensive_leader.salary = 100000
	var cheap_reserve: PSPlayer = _player_with_z(13, 1, 3, false, 0.0)
	cheap_reserve.salary = 1000
	var players: Array = [foreign_leader, expensive_leader, cheap_reserve]
	assert_float(TradeService.trade_value(cheap_reserve)).is_greater(TradeService.trade_value(expensive_leader))
	assert_array(TradeService.build_surplus_candidates(players, 1)).is_equal([cheap_reserve])
	# 能力が変わった後の呼び出しに、前回の保護順位を持ち越さない。
	for key in ALL_Z_KEYS:
		cheap_reserve.z_abilities[key] = 3.0
	assert_array(TradeService.build_surplus_candidates(players, 1)).is_equal([expensive_leader])


func test_trade_pair_keeps_first_tie_and_rechecks_values_between_searches() -> void:
	var first_a: PSPlayer = _player_with_z(12, 1, 3, false, 1.0)
	var next_a: PSPlayer = _player_with_z(11, 1, 3, false, 1.0)
	var first_b: PSPlayer = _player_with_z(22, 2, 3, false, 1.0)
	var next_b: PSPlayer = _player_with_z(21, 2, 3, false, 1.0)
	var surplus_a: Array = [first_a, next_a]
	var surplus_b: Array = [first_b, next_b]
	var need: Dictionary = {3: 5.0}
	var pair: Dictionary = TradeService._best_pair_between(surplus_a, surplus_b, need, need)
	assert_object(pair.get("player_a")).is_same(first_a)
	assert_object(pair.get("player_b")).is_same(first_b)
	assert_float(float(pair.get("score", 0.0))).is_equal(10.0)
	first_b.salary = 100000
	var next_pair: Dictionary = TradeService._best_pair_between(surplus_a, surplus_b, need, need)
	assert_object(next_pair.get("player_b")).is_same(next_b)
	next_b.salary = 100000
	assert_dict(TradeService._best_pair_between(surplus_a, surplus_b, need, need)).is_empty()


func test_trade_pair_matches_exhaustive_search() -> void:
	# 需要フィットの足切り・価値差の許容・同点時の先着を、全組み合わせを素直に回した結果と比べる。
	# 位置ごとに需要を変え、能力と年俸をずらして価値差の境界の両側に来る駒を混ぜる。
	var surplus_a: Array = []
	var surplus_b: Array = []
	var positions: Array = [2, 3, 4, 6, 8]
	for i in range(10):
		var player_a: PSPlayer = _player_with_z(100 + i, 1, int(positions[i % positions.size()]), false, -1.0 + 0.3 * float(i % 7))
		player_a.salary = 1000 + 3000 * (i % 4)
		surplus_a.append(player_a)
		var player_b: PSPlayer = _player_with_z(200 + i, 2, int(positions[(i + 2) % positions.size()]), false, -0.8 + 0.25 * float(i % 5))
		player_b.salary = 1500 + 2500 * (i % 3)
		surplus_b.append(player_b)
	var needs: Array = [
		[{2: 3.0, 3: 1.0, 4: 2.5, 6: 4.0, 8: 2.0}, {2: 2.0, 3: 5.0, 4: 1.5, 6: 2.0, 8: 3.5}],
		[{3: 2.0}, {6: 2.0, 8: 2.0}],
		[{2: 1.0}, {3: 6.0}],
	]
	for need_pair in needs:
		var need_a: Dictionary = need_pair[0] as Dictionary
		var need_b: Dictionary = need_pair[1] as Dictionary
		var expected: Dictionary = _exhaustive_best_pair(surplus_a, surplus_b, need_a, need_b)
		var actual: Dictionary = TradeService._best_pair_between(surplus_a, surplus_b, need_a, need_b)
		assert_object(actual.get("player_a")).is_same(expected.get("player_a"))
		assert_object(actual.get("player_b")).is_same(expected.get("player_b"))
		assert_float(float(actual.get("score", 0.0))).is_equal(float(expected.get("score", 0.0)))
	assert_bool(_exhaustive_best_pair(surplus_a, surplus_b, needs[0][0], needs[0][1]).is_empty()).is_false()
	assert_bool(_exhaustive_best_pair(surplus_a, surplus_b, needs[2][0], needs[2][1]).is_empty()).is_true()


# 球団方針: 開幕直後は戦力のリーグ内偏差だけで決まり、試合を消化すると順位 (CS 圏からのゲーム差) が効く。
func test_team_direction_uses_strength_early_then_standings() -> void:
	var season: PSSeason = _season(10)
	var teams: Array = []
	var charts: Dictionary = {}
	for team_id in range(1, 7):
		teams.append(_team(team_id))
		# 球団 1 が最弱、6 が最強。
		charts[team_id] = {"slots": {"fielder:3": {"first_team_value": 50.0 + float(team_id) * 4.0, "first_team_slots": 1}}}
		season.standings[team_id] = PSStats.new()

	var early: Dictionary = TeamDirection.build_league(season, teams, charts)
	assert_float(float(early[6])).is_greater(0.0)
	assert_float(float(early[1])).is_less(0.0)
	assert_float(float(early[6])).is_equal_approx(-float(early[1]), 0.0001)

	# 最弱の球団 1 が独走、最強の球団 6 が大きく負け越す。順位が戦力の見立てを上書きする。
	var records: Dictionary = {1: [45, 20], 2: [36, 29], 3: [33, 32], 4: [31, 34], 5: [28, 37], 6: [22, 43]}
	for team_id in records.keys():
		var stats: PSStats = season.standings[team_id] as PSStats
		stats.wins = int((records[team_id] as Array)[0])
		stats.losses = int((records[team_id] as Array)[1])
	var mid: Dictionary = TeamDirection.build_league(season, teams, charts)
	assert_str(TeamDirection.kind_for(float(mid[1]))).is_equal(TeamDirection.KIND_WIN_NOW)
	assert_str(TeamDirection.kind_for(float(mid[6]))).is_equal(TeamDirection.KIND_FUTURE)
	# CS 圏の最下位 (3位) は圏内なので、中立より即戦力重視に寄る。
	assert_float(float(mid[3])).is_greater(float(mid[4]))
	assert_float(float(mid[3])).is_greater(0.0)

	# CS 圏が成り立たない小さなリーグと、成績の無い球団は順位を使わない。
	var small: Dictionary = TeamDirection.build_league(season, [_team(1), _team(6)], charts)
	assert_float(float(small[6])).is_greater(0.0)
	assert_float(float(small[1])).is_less(0.0)


# 方針は成長期待の重みを振る: 即戦力重視はベテランを高く・若手を低く見て、将来重視はその逆。
func test_stance_trade_value_tilts_growth_component() -> void:
	var veteran: PSPlayer = _player({"id": 1, "team_id": 1, "age": 34})
	var prospect: PSPlayer = _player({"id": 2, "team_id": 1, "age": 21})
	assert_float(TradeService.growth_value(veteran)).is_less(0.0)
	assert_float(TradeService.growth_value(prospect)).is_greater(0.0)
	assert_float(TradeService.stance_trade_value(veteran, 0.0)).is_equal(TradeService.trade_value(veteran))
	assert_float(TradeService.stance_trade_value(veteran, 1.0)).is_greater(TradeService.trade_value(veteran))
	assert_float(TradeService.stance_trade_value(veteran, -1.0)).is_less(TradeService.trade_value(veteran))
	assert_float(TradeService.stance_trade_value(prospect, 1.0)).is_less(TradeService.trade_value(prospect))
	assert_float(TradeService.stance_trade_value(prospect, -1.0)).is_greater(TradeService.trade_value(prospect))


# ポジションの需要が無くても、即戦力重視の球団が若手を出して将来重視の球団のベテランを取る交換は成立する。
# 方針が逆向き (即戦力重視が若手を取る側) や中立同士では成立しない。
func test_trade_pair_stance_enables_veteran_for_prospect_swap() -> void:
	var prospect: PSPlayer = _player_with_z(11, 1, 3, false, 0.0)
	prospect.age = 21
	var veteran: PSPlayer = _player_with_z(21, 2, 3, false, 0.0)
	veteran.age = 34
	# 同じ能力だと成長期待のぶん若手の価値が高い。年俸負担で価値差を許容内に揃える。
	var gap: float = TradeService.trade_value(prospect) - TradeService.trade_value(veteran)
	assert_float(gap).is_greater(TradeService.VALUE_DIFF_TOLERANCE)
	prospect.salary += int(round(gap * TeamFinance.AI_SALARY_COST_PER_SCORE))
	assert_float(absf(TradeService.trade_value(prospect) - TradeService.trade_value(veteran))).is_less(0.01)

	var no_need: Dictionary = {}
	assert_dict(TradeService._best_pair_between([prospect], [veteran], no_need, no_need)).is_empty()
	var swap: Dictionary = TradeService._best_pair_between([prospect], [veteran], no_need, no_need, {}, 1.0, -1.0)
	assert_object(swap.get("player_a")).is_same(prospect)
	assert_object(swap.get("player_b")).is_same(veteran)
	assert_dict(TradeService._best_pair_between([prospect], [veteran], no_need, no_need, {}, -1.0, 1.0)).is_empty()
	# 片方だけが乗り気でも成立しない (相手に動機が無い)。
	assert_dict(TradeService._best_pair_between([prospect], [veteran], no_need, no_need, {}, 1.0, 0.0)).is_empty()


# 将来重視の球団は主力でもベテランを売りに出し、残す枠は若い選手で埋める。
func test_surplus_sells_veteran_leaders_when_future_oriented() -> void:
	var veteran_leader: PSPlayer = _player_with_z(11, 1, 3, false, 2.0)
	veteran_leader.age = 33
	var second: PSPlayer = _player_with_z(12, 1, 3, false, 1.0)
	var third: PSPlayer = _player_with_z(13, 1, 3, false, 0.0)
	var players: Array = [veteran_leader, second, third]
	assert_array(TradeService.build_surplus_candidates(players, 1)).is_equal([third])
	assert_array(TradeService.build_surplus_candidates(players, 1, 0, {}, TradeService.SELL_VETERAN_STANCE)).is_equal([veteran_leader])
	assert_array(TradeService.build_surplus_candidates(players, 1, 0, {}, 1.0)).is_equal([third])


# ユーザー提案の受諾判定も相手の方針で変わる: 同じ「若手を出してベテランを貰う」提案でも、
# 相手が下位 (将来重視) のときのほうが相手の得が大きい。
func test_evaluate_user_proposal_reflects_partner_direction() -> void:
	var teams: Array = [_team(1), _team(2), _team(3), _team(4)]
	var prospect: PSPlayer = _player_with_z(11, 1, 3, false, 0.0)
	prospect.age = 21
	var veteran: PSPlayer = _player_with_z(21, 2, 3, false, 0.0)
	veteran.age = 34
	var players: Array = [prospect, veteran]

	var gains: Dictionary = {}
	for partner_wins in [50, 15]:
		var season: PSSeason = _season(10)
		for team_id in range(1, 5):
			var stats: PSStats = PSStats.new()
			stats.wins = 32
			stats.losses = 33
			season.standings[team_id] = stats
		(season.standings[2] as PSStats).wins = partner_wins
		(season.standings[2] as PSStats).losses = 65 - partner_wins
		var result: Dictionary = TradeService.evaluate_user_proposal(season, players, teams, 1, [11], [21])
		assert_bool(bool(result.get("ok", false))).is_true()
		gains[partner_wins] = result
	assert_float(float((gains[50] as Dictionary)["cpu_stance"])).is_greater(0.0)
	assert_float(float((gains[15] as Dictionary)["cpu_stance"])).is_less(0.0)
	assert_float(float((gains[15] as Dictionary)["cpu_gain"])).is_greater(float((gains[50] as Dictionary)["cpu_gain"]))


# ---- helpers -------------------------------------------------------------------

func _exhaustive_best_pair(surplus_a: Array, surplus_b: Array, need_a: Dictionary, need_b: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = 0.0
	for a_row in surplus_a:
		var player_a: PSPlayer = a_row as PSPlayer
		for b_row in surplus_b:
			var player_b: PSPlayer = b_row as PSPlayer
			var fit_for_b: float = TradeService.need_fit(player_a, need_b)
			var fit_for_a: float = TradeService.need_fit(player_b, need_a)
			if fit_for_b < TradeService.MIN_NEED_FIT or fit_for_a < TradeService.MIN_NEED_FIT:
				continue
			var value_diff: float = absf(TradeService.trade_value(player_a) - TradeService.trade_value(player_b))
			if value_diff > TradeService.VALUE_DIFF_TOLERANCE:
				continue
			var score: float = fit_for_a + fit_for_b - value_diff * TradeService.VALUE_DIFF_SCORE_PENALTY
			if score > best_score:
				best_score = score
				best = {"player_a": player_a, "player_b": player_b, "score": score}
	return best


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
