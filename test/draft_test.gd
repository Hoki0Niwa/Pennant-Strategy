extends GdUnitTestSuite

# ドラフトの2フェーズ分割 (本指名=支配下 / 育成ドラフト=育成) を検証する。
# 本指名は6人を基本線に支配下状況で 4〜9 程度、育成は 0〜3。

const DraftService = preload("res://services/season/draft_service.gd")


# ドラフト候補の野手位置分布は up-the-middle (遊撃/中堅) 偏重で、一塁/左翼は稀。
# 旧実装 (内野一様/外野一様) は 1B/LF を過剰供給し、リーグ構成が現実と逆転していた。
func test_candidate_positions_favor_up_the_middle() -> void:
	Rng.set_seed_value(20260706)
	var counts: Dictionary = {}
	for _i in range(4000):
		var pos: int = DraftService._candidate_position()
		counts[pos] = int(counts.get(pos, 0)) + 1
	assert_int(int(counts.get(6, 0))).is_greater(int(counts.get(3, 0)))  # SS > 1B
	assert_int(int(counts.get(8, 0))).is_greater(int(counts.get(7, 0)))  # CF > LF
	assert_int(int(counts.get(6, 0))).is_greater(int(counts.get(7, 0)))  # SS > LF
	assert_int(int(counts.get(1, 0))).is_between(1900, 2450)  # 投手 ~54%


func test_pitcher_candidates_get_initial_role_from_aptitude() -> void:
	Rng.set_seed_value(20260615)
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var pitchers: int = 0
	var starters: int = 0
	var relievers: int = 0
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if int(candidate.get("position", 0)) != 1:
			continue
		pitchers += 1
		var template: Dictionary = candidate.get("player_template", {}) as Dictionary
		var neutral_template: Dictionary = template.duplicate(true)
		neutral_template["role"] = ""
		var expected_role: String = PSPitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral_template))
		assert_str(str(template.get("role", ""))).is_equal(expected_role)
		if expected_role == "starter":
			starters += 1
		elif expected_role == "reliever":
			relievers += 1

	assert_int(pitchers).is_greater(0)
	# 生成は概ね均衡 (やや中継寄り)。どちらの役割も全体の 3 割以上で、極端に偏らないこと。
	assert_int(starters).is_greater_equal(int(round(float(pitchers) * 0.30)))
	assert_int(relievers).is_greater_equal(int(round(float(pitchers) * 0.30)))


# 生成投手の先発比率は概ね均衡 (やや中継寄り)。STARTER_DECISION_MARGIN の較正ガード。
func test_generation_role_ratio_roughly_balanced() -> void:
	Rng.set_seed_value(20260621)
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2), _team(3, "central", 3), _team(4, "pacific", 4)]
	var players: Array = []
	for tid in [1, 2, 3, 4]:
		_fill_team(players, tid, 58)
	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var n: int = 0
	var starters: int = 0
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if int(candidate.get("position", 0)) != 1:
			continue
		n += 1
		var template: Dictionary = (candidate.get("player_template", {}) as Dictionary).duplicate(true)
		template["role"] = ""
		if PSPitcherRoleModel.role_for_player(PSPlayer.from_dict(template)) == PSPitcherRoleModel.ROLE_STARTER:
			starters += 1
	var frac: float = float(starters) / float(max(1, n))
	print("ROLEADV n=%d starters=%d (%.0f%%) margin=%.2f" % [n, starters, 100.0 * frac, PSPitcherRoleModel.STARTER_DECISION_MARGIN])
	assert_int(n).is_greater(0)
	# 先発 35〜55% (中継がやや多めで均衡)。極端な偏りや先発過多が再発したら検知する。
	assert_float(frac).is_between(0.35, 0.55)


func test_main_and_development_segments_split() -> void:
	# 在籍55 (外国人0) の球団: gap = 目標68−55−予約(2+外国人不足4) = 7。在籍68の球団は hard 空き2まで。
	var teams: Array = [
		_team(1, "central", 1),
		_team(2, "central", 2),
		_team(3, "pacific", 3),
		_team(4, "pacific", 4),
	]
	var players: Array = []
	_fill_team(players, 1, 55)
	_fill_team(players, 2, 55)
	_fill_team(players, 3, 55)
	_fill_team(players, 4, 68)  # hard 上限70まで残り2

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1)
	DraftService.complete_automatically(state)
	assert_bool(bool(state.get("complete", false))).is_true()

	var result: Dictionary = DraftService.finalize_draft(state, players)
	var rookies: Array = result.get("rookies", []) as Array
	assert_int(rookies.size()).is_greater(0)

	var main_by_team: Dictionary = {}
	var dev_by_team: Dictionary = {}
	for rookie_row in rookies:
		var rookie: Dictionary = rookie_row as Dictionary
		var tid: int = int(rookie.get("team_id", 0))
		if bool(rookie.get("development_player", false)):
			dev_by_team[tid] = int(dev_by_team.get(tid, 0)) + 1
		else:
			main_by_team[tid] = int(main_by_team.get(tid, 0)) + 1

	# 本指名: 在籍55の3球団は gap=7、在籍68の球団は hard 空き2。すべて MAIN 上限以下。
	assert_int(int(main_by_team.get(1, 0))).is_equal(7)
	assert_int(int(main_by_team.get(2, 0))).is_equal(7)
	assert_int(int(main_by_team.get(3, 0))).is_equal(7)
	assert_int(int(main_by_team.get(4, 0))).is_equal(2)

	# 育成: 各球団 0〜3。
	for tid in [1, 2, 3, 4]:
		assert_int(int(dev_by_team.get(tid, 0))).is_between(0, DraftService.DEV_DRAFT_MAX_PICKS)


func test_segments_are_sequential_and_flagged() -> void:
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	DraftService.complete_automatically(state)

	# 全ての本指名 (development=false) は全ての育成指名 (development=true) より前に行われる。
	var last_main_pick: int = 0
	var first_dev_pick: int = 1 << 30
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		var overall_pick: int = int(pick.get("overall_pick", 0))
		if bool(pick.get("development", false)):
			first_dev_pick = min(first_dev_pick, overall_pick)
		else:
			last_main_pick = max(last_main_pick, overall_pick)
	if first_dev_pick != (1 << 30):
		assert_int(last_main_pick).is_less(first_dev_pick)

	# finalize 後: 育成 rookie は registered_roster=育成 / 支配下 rookie は支配下。
	var result: Dictionary = DraftService.finalize_draft(state, players)
	for rookie_row in result.get("rookies", []) as Array:
		var rookie: Dictionary = rookie_row as Dictionary
		var player: PSPlayer = _find_player(players, int(rookie.get("player_id", 0)))
		assert_object(player).is_not_null()
		if bool(rookie.get("development_player", false)):
			assert_str(player.registered_roster).is_equal("育成")
			assert_int(player.salary).is_equal(DraftService.DEV_DRAFT_SALARY)
		else:
			assert_str(player.registered_roster).is_equal("支配下")


func test_development_step_result_filters_out_main_draft_rows() -> void:
	var picks: Array = [
		{"team_id": 1, "round": 1, "overall_pick": 1, "development": false},
		{"team_id": 2, "round": 1, "overall_pick": 2, "development": false},
		{"team_id": 1, "round": 1, "overall_pick": 3, "development": true},
		{"team_id": 2, "round": 2, "overall_pick": 4, "development": true},
	]
	var rookies: Array = [
		{"team_id": 1, "draft_round": 1, "development_player": false},
		{"team_id": 2, "draft_round": 1, "development_player": false},
		{"team_id": 1, "draft_round": 1, "development_player": true},
		{"team_id": 2, "draft_round": 2, "development_player": true},
	]

	var dev_picks: Array = AppState._filter_development_picks(picks)
	var dev_rookies: Array = AppState._filter_development_rookies(rookies)

	assert_array(dev_picks).has_size(2)
	assert_array(dev_rookies).has_size(2)
	for pick_row in dev_picks:
		assert_bool(bool((pick_row as Dictionary).get("development", false))).is_true()
	for rookie_row in dev_rookies:
		assert_bool(bool((rookie_row as Dictionary).get("development_player", false))).is_true()


func test_user_skip_ends_development_participation() -> void:
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	# 自軍=1。本指名を自動で終わらせ、育成ドラフトの自軍指名待ちまで進める。
	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1)
	var guard: int = 0
	while not bool(state.get("complete", false)) and guard < 500:
		guard += 1
		var stage: String = str(state.get("stage", ""))
		var is_user_turn: bool = stage == "user_pick" or stage == "first_round_bid"
		if str(state.get("segment", "main")) == "development" and stage == "user_pick":
			break
		if is_user_turn:
			DraftService.auto_pick_for_user(state)
		elif stage == "first_round_reveal":
			DraftService.resolve_first_round_reveal(state)
		elif stage == "first_round_result":
			DraftService.continue_first_round(state)
		else:
			DraftService.advance_until_user_turn_or_complete(state)

	# 育成ドラフトの自軍指名待ちで見送る → 自軍は teams_done に入り、以後指名されない。
	if str(state.get("segment", "main")) == "development" and str(state.get("stage", "")) == "user_pick":
		var dev_before: int = int((state.get("team_dev_pick_counts", {}) as Dictionary).get("1", 0))
		DraftService.skip_user_pick(state)
		DraftService.complete_automatically(state)
		var dev_after: int = int((state.get("team_dev_pick_counts", {}) as Dictionary).get("1", 0))
		assert_int(dev_after).is_equal(dev_before)
	assert_bool(bool(state.get("complete", false))).is_true()


func test_main_draft_can_complete_before_development_step() -> void:
	Rng.set_seed_value(20260616)
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1, false)
	var guard: int = 0
	while not bool(state.get("complete", false)) and guard < 500:
		guard += 1
		var stage: String = str(state.get("stage", ""))
		if str(state.get("segment", "main")) == "main" and stage == "user_pick":
			break
		if stage == "first_round_bid" or stage == "user_pick":
			DraftService.auto_pick_for_user(state)
		elif stage == "first_round_reveal":
			DraftService.resolve_first_round_reveal(state)
		elif stage == "first_round_result":
			DraftService.continue_first_round(state)
		else:
			DraftService.advance_until_user_turn_or_complete(state)

	assert_str(str(state.get("segment", ""))).is_equal("main")
	assert_str(str(state.get("stage", ""))).is_equal("user_pick")

	var user_main_before: int = _pick_count(state, 1, false)
	var other_main_before: int = _pick_count(state, 2, false)
	var result: Dictionary = DraftService.skip_user_pick(state)
	assert_bool(bool(result.get("ok", false))).is_true()

	assert_bool(bool(state.get("complete", false))).is_true()
	assert_str(str(state.get("segment", ""))).is_equal("main")
	assert_int(_pick_count(state, 1, false)).is_equal(user_main_before)
	assert_int(_pick_count(state, 2, false)).is_greater(other_main_before)

	var pool_size_before: int = (state.get("candidate_pool", []) as Array).size()
	DraftService.begin_development_draft(state)
	assert_bool(bool(state.get("complete", false))).is_false()
	assert_str(str(state.get("segment", ""))).is_equal("development")
	assert_int((state.get("candidate_pool", []) as Array).size()).is_equal(pool_size_before)


func test_draft_target_scales_with_roster_need() -> void:
	# 編成計画: 指名数 = 開幕目標68 − 在籍 − 補強予約2 (外国人4人充足時)。
	# 戦力外で在籍が減った球団ほど多く指名し、目標との差分がそのまま指名数になる。
	var teams: Array = [
		_team(1, "central", 1),
		_team(2, "pacific", 2),
		_team(3, "central", 3),
		_team(4, "pacific", 4),
	]
	var players: Array = []
	_fill_team(players, 1, 56)  # gap = 68-56-2 = 10
	_fill_team(players, 2, 58)  # gap = 68-58-2 = 8
	_fill_team(players, 3, 60)  # gap = 68-60-2 = 6
	_fill_team(players, 4, 62)  # gap = 68-62-2 = 4
	for tid in [1, 2, 3, 4]:
		_mark_foreign(players, tid, DraftService.FOREIGN_ROSTER_RESERVE_TARGET)
	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var targets: Dictionary = state.get("team_main_targets", {}) as Dictionary
	assert_int(int(targets.get("1", 0))).is_equal(DraftService.MAIN_DRAFT_MAX_PICKS)
	assert_int(int(targets.get("2", 0))).is_equal(8)
	assert_int(int(targets.get("3", 0))).is_equal(6)
	assert_int(int(targets.get("4", 0))).is_equal(DraftService.MAIN_DRAFT_MIN_PICKS)
	assert_int(int(targets.get("1", 0))).is_greater(int(targets.get("2", 0)))


func test_draft_reserves_slots_for_foreign_roster_shortage() -> void:
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2), _team(3, "central", 3)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)
	_fill_team(players, 3, 58)
	_mark_foreign(players, 1, 4)
	_mark_foreign(players, 2, 1)
	_mark_foreign(players, 3, 0)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var targets: Dictionary = state.get("team_main_targets", {}) as Dictionary

	# 在籍58 → gap = 68−58−予約。外国人が足りない球団ほど予約が増え指名が減る (2/5/6)。
	assert_int(int(targets.get("1", 0))).is_equal(8)
	assert_int(int(targets.get("2", 0))).is_equal(5)
	assert_int(int(targets.get("3", 0))).is_equal(4)


# 1巡目の「入札→公開(reveal)→結果確認(result)」対話フローを一通り検証する。
# ユーザーが入札するたびに reveal で1 wave 分だけ抽選が公開され、result で次へ進む。
# 全球団の1巡目が確定するまでこのループを繰り返しても取りこぼしが無いことを見る。
func test_first_round_two_stage_flow_for_user() -> void:
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1, false)
	assert_str(str(state.get("stage", ""))).is_equal("first_round_bid")

	var candidate_id: int = int((DraftService.available_candidates(state)[0] as Dictionary).get("candidate_id", 0))
	DraftService.submit_user_candidate(state, candidate_id)
	assert_str(str(state.get("stage", ""))).is_equal("first_round_reveal")

	var reveal: Dictionary = state.get("first_round_reveal", {}) as Dictionary
	var bids: Dictionary = reveal.get("bids", {}) as Dictionary
	assert_bool(bids.is_empty()).is_false()
	assert_bool(bids.has(str(1))).is_true()
	assert_bool(bool(reveal.get("resolved", true))).is_false()
	assert_int(_round_pick_count(state, 1)).is_equal(0)

	DraftService.resolve_first_round_reveal(state)
	assert_str(str(state.get("stage", ""))).is_equal("first_round_result")
	reveal = state.get("first_round_reveal", {}) as Dictionary
	assert_bool(bool(reveal.get("resolved", false))).is_true()
	assert_int(_round_pick_count(state, 1)).is_greater_equal(1)

	# 抽選で外れた球団が残っていれば再入札 (bid) → 公開 (reveal) → 結果 (result) を繰り返す。
	var guard: int = 0
	while guard < 200:
		guard += 1
		var stage: String = str(state.get("stage", ""))
		if stage == "first_round_bid":
			DraftService.auto_pick_for_user(state)
		elif stage == "first_round_reveal":
			DraftService.resolve_first_round_reveal(state)
		elif stage == "first_round_result":
			DraftService.continue_first_round(state)
		else:
			break
	assert_int(guard).is_less(200)

	# 指名可能だった全球団 (両球団とも新規58人在籍で本指名可能) に1巡目の pick がちょうど1件ずつ。
	for tid in [1, 2]:
		assert_int(_team_round_pick_count(state, tid, 1)).is_equal(1)


# 同一候補への競合入札は抽選 (lottery) で1球団だけ確定し、敗者は次 wave に持ち越される。
# 乱数依存で flaky にならないよう、勝者が「どちらの球団か」までは断定しない。
func test_first_round_rebid_wave_lottery() -> void:
	Rng.set_seed_value(20260710)
	var teams: Array = [_team(5, "central", 1), _team(6, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 5, 58)
	_fill_team(players, 6, 58)

	# user_team_id=0 (存在しない) だと create_draft_state 内でサイレント一括解決され最後まで
	# 進んでしまうため、create 後に1巡目入札待ちの状態へ state を手動でリセットしてから
	# _resolve_first_round_wave を直接検証する。profile の initial_total 等は capacity 判定にのみ
	# 使われ _resolve_first_round_wave 自体には影響しないため、picks/logs/カウンタのみ戻せば十分。
	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0, false)
	state["complete"] = false
	state["segment"] = "main"
	state["stage"] = "first_round_bid"
	state["round"] = 1
	state["round_position"] = 0
	state["picks"] = []
	state["logs"] = []
	state["teams_done"] = {}
	state["team_pick_counts"] = {"5": 0, "6": 0}
	state["first_round_wave"] = 1
	state["first_round_reveal"] = {}

	var available: Array = DraftService.available_candidates(state)
	assert_bool(available.is_empty()).is_false()
	var shared_candidate_id: int = int((available[0] as Dictionary).get("candidate_id", 0))

	# 2球団が同一候補に入札した状態を手で注入する。
	state["first_round_unresolved"] = [5, 6]
	state["first_round_bids"] = {"5": shared_candidate_id, "6": shared_candidate_id}

	var next_unresolved: Array = DraftService._resolve_first_round_wave(state)

	var lottery_logs: Array = []
	for log_row in state.get("logs", []) as Array:
		if str((log_row as Dictionary).get("type", "")) == "lottery":
			lottery_logs.append(log_row)
	assert_array(lottery_logs).has_size(1)

	var lottery: Dictionary = lottery_logs[0] as Dictionary
	var lottery_teams: Array = lottery.get("teams", []) as Array
	assert_int(lottery_teams.size()).is_equal(2)
	var winner_team_id: int = int(lottery.get("winner_team_id", 0))
	assert_bool(winner_team_id == 5 or winner_team_id == 6).is_true()
	var loser_team_ids: Array = lottery.get("loser_team_ids", []) as Array
	assert_array(loser_team_ids).has_size(1)
	var loser_team_id: int = int(loser_team_ids[0])
	assert_bool(loser_team_id != winner_team_id).is_true()

	# 戻り値の次 wave 未解決には敗者のみ含まれ、勝者は含まれない。
	assert_array(next_unresolved).has_size(1)
	assert_int(int(next_unresolved[0])).is_equal(loser_team_id)
	assert_bool(next_unresolved.has(winner_team_id)).is_false()

	# 勝者には1巡目の pick が1件、method/lottery フラグも抽選由来であることを確認。
	assert_int(_team_round_pick_count(state, winner_team_id, 1)).is_equal(1)
	var winner_pick: Dictionary = _find_pick(state, winner_team_id, 1)
	assert_object(winner_pick).is_not_null()
	assert_bool(bool(winner_pick.get("lottery", false))).is_true()
	assert_str(str(winner_pick.get("method", ""))).is_equal("lottery")
	assert_int(_team_round_pick_count(state, loser_team_id, 1)).is_equal(0)


# complete_automatically は reveal/result の対話段階でも止まらず完走する。
func test_complete_automatically_not_stuck_at_reveal() -> void:
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 58)
	_fill_team(players, 2, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1, false)
	var candidate_id: int = int((DraftService.available_candidates(state)[0] as Dictionary).get("candidate_id", 0))
	DraftService.submit_user_candidate(state, candidate_id)
	assert_str(str(state.get("stage", ""))).is_equal("first_round_reveal")

	var result: Dictionary = DraftService.complete_automatically(state)
	assert_bool(bool(result.get("ok", false))).is_true()
	assert_bool(bool(state.get("complete", false))).is_true()
	for tid in [1, 2]:
		assert_int(_team_round_pick_count(state, tid, 1)).is_equal(1)


# ユーザーが指名に参加しない (user_team_id が存在しない) 場合は create_draft_state 内で
# 1巡目がサイレントに一括解決され、reveal/result の対話段階を経ずに先へ進む (回帰保護)。
func test_headless_create_resolves_first_round_silently() -> void:
	var teams: Array = [_team(5, "central", 1), _team(6, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 5, 58)
	_fill_team(players, 6, 58)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var stage: String = str(state.get("stage", ""))
	assert_bool(stage == "first_round_bid" or stage == "first_round_reveal" or stage == "first_round_result").is_false()
	assert_int(_round_pick_count(state, 1)).is_greater(0)


func test_draft_target_accounts_for_promotions() -> void:
	# 昇格見込みの育成が多い球団は目標から最大2人控える。capacity にマスクされないよう
	# 在籍58 (capacity 10) で比較する (在籍63だと capacity=5 で縮小が見えない)。
	var teams: Array = [_team(1, "central", 1)]
	var base_players: Array = []
	_fill_team(base_players, 1, 58)
	_mark_foreign(base_players, 1, DraftService.FOREIGN_ROSTER_RESERVE_TARGET)
	var base_state: Dictionary = DraftService.create_draft_state(base_players, teams, null, 0)
	var base_target: int = int((base_state.get("team_main_targets", {}) as Dictionary).get("1", 0))

	var promo_players: Array = []
	_fill_team(promo_players, 1, 58)
	_mark_foreign(promo_players, 1, DraftService.FOREIGN_ROSTER_RESERVE_TARGET)
	_add_dev(promo_players, 1, 4)  # 昇格水準の育成4人 (value>=昇格閾値)
	var promo_state: Dictionary = DraftService.create_draft_state(promo_players, teams, null, 0)
	var promo_target: int = int((promo_state.get("team_main_targets", {}) as Dictionary).get("1", 0))

	# 在籍58・外国人4 → gap = 68−58−2 = 8。昇格見込みで −DRAFT_PROMO_TARGET_REDUCTION_CAP。
	assert_int(base_target).is_equal(8)
	assert_int(promo_target).is_equal(base_target - DraftService.DRAFT_PROMO_TARGET_REDUCTION_CAP)


# --- helpers -----------------------------------------------------------------

func _team(id: int, league: String, prev_rank: int) -> PSTeam:
	return PSTeam.from_dict({
		"id": id,
		"name": "Team %d" % id,
		"short_name": "T%d" % id,
		"league": league,
		"previous_rank": prev_rank,
	})


func _fill_team(players: Array, team_id: int, count: int) -> void:
	var base: int = team_id * 10000
	for i in range(count):
		players.append(PSPlayer.from_dict({
			"id": base + i,
			"team_id": team_id,
			"age": 26,
			"years": 5,
			"position": 1 + (i % 9),
			"role": "starter" if (i % 9) == 0 else "fielder",
			"throws": "R",
			"bats": "R",
			"z_abilities": {},
			"raw_abilities": {},
		}))


func _mark_foreign(players: Array, team_id: int, count: int) -> void:
	var marked: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id:
			continue
		player.foreign_player = marked < count
		marked += 1


const DEV_Z_KEYS: Array = [
	"Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Spray",
	"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
	"Run_Speed", "Run_Judgment", "Run_Steal",
]


func _add_dev(players: Array, team_id: int, count: int) -> void:
	var base: int = team_id * 10000 + 9000
	# 昇格水準 (value>=PROMOTE_TO_SHIENKA_MIN_VALUE) に届く z で育成選手を作る。
	var z: Dictionary = {}
	for key in DEV_Z_KEYS:
		z[key] = 1.2
	for i in range(count):
		players.append(PSPlayer.from_dict({
			"id": base + i,
			"team_id": team_id,
			"age": 22,
			"years": 2,
			"position": 3,
			"role": "fielder",
			"throws": "R",
			"bats": "R",
			"development_player": true,
			"registered_roster": "育成",
			"z_abilities": z,
			"raw_abilities": {},
		}))


func _find_player(players: Array, pid: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.id == pid:
			return player
	return null


func _pick_count(state: Dictionary, team_id: int, development: bool) -> int:
	var count: int = 0
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if int(pick.get("team_id", 0)) == team_id and bool(pick.get("development", false)) == development:
			count += 1
	return count


func _round_pick_count(state: Dictionary, round_no: int) -> int:
	var count: int = 0
	for pick_row in state.get("picks", []) as Array:
		if int((pick_row as Dictionary).get("round", 0)) == round_no:
			count += 1
	return count


func _team_round_pick_count(state: Dictionary, team_id: int, round_no: int) -> int:
	var count: int = 0
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if int(pick.get("team_id", 0)) == team_id and int(pick.get("round", 0)) == round_no:
			count += 1
	return count


func _find_pick(state: Dictionary, team_id: int, round_no: int) -> Dictionary:
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if int(pick.get("team_id", 0)) == team_id and int(pick.get("round", 0)) == round_no:
			return pick
	return {}


# 完全ウェーバー制 (full_waiver=true): 1巡目も入札/抽選を行わず、本指名は全巡 reverse 固定。
# 育成ドラフトは現行のスネーク (奇数巡=forward) を維持することも合わせて確認する。
func test_full_waiver_order_and_no_lottery() -> void:
	var teams: Array = [
		_team(1, "central", 1),
		_team(2, "central", 2),
		_team(3, "pacific", 3),
		_team(4, "pacific", 4),
	]
	var players: Array = []
	_fill_team(players, 1, 55)
	_fill_team(players, 2, 55)
	_fill_team(players, 3, 55)
	_fill_team(players, 4, 55)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0, true, true)
	DraftService.complete_automatically(state)
	assert_bool(bool(state.get("complete", false))).is_true()

	for log_row in state.get("logs", []) as Array:
		assert_str(str((log_row as Dictionary).get("type", ""))).is_not_equal("lottery")

	var picks: Array = state.get("picks", []) as Array
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		if bool(pick.get("development", false)):
			continue
		assert_bool(bool(pick.get("lottery", false))).is_false()
		var method: String = str(pick.get("method", ""))
		assert_bool(method == "single_bid" or method == "rebid_single" or method == "lottery").is_false()

	var reverse_order: Array = state.get("teams_order_reverse", []) as Array
	var forward_order: Array = state.get("teams_order_forward", []) as Array

	for round_no in [1, 2]:
		var round_teams: Array = []
		var round_picks: Array = []
		for pick_row in picks:
			var pick: Dictionary = pick_row as Dictionary
			if bool(pick.get("development", false)):
				continue
			if int(pick.get("round", 0)) == round_no:
				round_picks.append(pick)
		round_picks.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary).get("overall_pick", 0)) < int((b as Dictionary).get("overall_pick", 0))
		)
		for pick_row in round_picks:
			round_teams.append(int((pick_row as Dictionary).get("team_id", 0)))
		var expected_subsequence: Array = []
		for team_id_value in reverse_order:
			if round_teams.has(int(team_id_value)):
				expected_subsequence.append(int(team_id_value))
		assert_array(round_teams).is_equal(expected_subsequence)

	# 育成ドラフト1巡目は現行のスネーク (奇数巡=forward) を維持する。
	var dev_round1_teams: Array = []
	var dev_round1_picks: Array = []
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		if bool(pick.get("development", false)) and int(pick.get("round", 0)) == 1:
			dev_round1_picks.append(pick)
	dev_round1_picks.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("overall_pick", 0)) < int((b as Dictionary).get("overall_pick", 0))
	)
	for pick_row in dev_round1_picks:
		dev_round1_teams.append(int((pick_row as Dictionary).get("team_id", 0)))
	var expected_dev_subsequence: Array = []
	for team_id_value in forward_order:
		if dev_round1_teams.has(int(team_id_value)):
			expected_dev_subsequence.append(int(team_id_value))
	assert_array(dev_round1_teams).is_equal(expected_dev_subsequence)


# 完全ウェーバー制でユーザーが参加する場合、1巡目から入札段階を経ずに user_pick 待ちになり、
# 通常通り submit_user_candidate で指名できる (method=="user"、抽選なし)。
func test_full_waiver_user_gets_user_pick_stage_round1() -> void:
	# season=null のとき _priority_league は year=0 扱いで "pacific" が優先リーグになり、
	# reverse_order は優先リーグの最下位球団から始まる。自軍 (team_id=1) を優先リーグ
	# (pacific) の最下位 previous_rank に置いて先頭に来るようにする。
	var teams: Array = [
		_team(1, "pacific", 6),
		_team(2, "pacific", 1),
		_team(3, "central", 6),
		_team(4, "central", 1),
	]
	var players: Array = []
	_fill_team(players, 1, 55)
	_fill_team(players, 2, 55)
	_fill_team(players, 3, 55)
	_fill_team(players, 4, 55)

	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 1, true, true)
	var reverse_order: Array = state.get("teams_order_reverse", []) as Array
	assert_int(int(reverse_order[0])).is_equal(1)

	assert_str(str(state.get("stage", ""))).is_equal("user_pick")
	assert_int(int(state.get("round", 0))).is_equal(1)
	assert_int(int(state.get("current_team_id", 0))).is_equal(1)

	var candidate_id: int = int((DraftService.available_candidates(state)[0] as Dictionary).get("candidate_id", 0))
	var result: Dictionary = DraftService.submit_user_candidate(state, candidate_id)
	assert_bool(bool(result.get("ok", false))).is_true()

	var pick: Dictionary = _find_pick(state, 1, 1)
	assert_object(pick).is_not_null()
	assert_str(str(pick.get("method", ""))).is_equal("user")
	assert_bool(bool(pick.get("lottery", false))).is_false()
