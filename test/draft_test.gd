extends GdUnitTestSuite

# ドラフトの2フェーズ分割 (本指名=支配下 / 育成ドラフト=育成) を検証する。
# 本指名は6人を基本線に支配下状況で 4〜9 程度、育成は 0〜3。

const DraftService = preload("res://services/season/draft_service.gd")


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
