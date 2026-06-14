extends GdUnitTestSuite

# ドラフトの2フェーズ分割 (本指名=支配下 / 育成ドラフト=育成) を検証する。
# 本指名は支配下空き (70−在籍) と MAIN_DRAFT_MAX_PICKS で 5〜9 程度、育成は 0〜3。

const DraftService = preload("res://services/season/draft_service.gd")


func test_main_and_development_segments_split() -> void:
	# capacity 15 (在籍55) の球団は本指名上限9まで、capacity 2 (在籍68) の球団は2まで。
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
	_fill_team(players, 4, 68)

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

	# 本指名: capacity 十分な3球団は上限9、capacity 2 の球団は2。すべて MAIN 上限以下。
	assert_int(int(main_by_team.get(1, 0))).is_equal(9)
	assert_int(int(main_by_team.get(2, 0))).is_equal(9)
	assert_int(int(main_by_team.get(3, 0))).is_equal(9)
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


func test_draft_target_scales_with_roster_need() -> void:
	# 戦力外が多く在籍が少ない球団は大量指名 (上限9)、キーパーが多く在籍が多い球団は最小。
	var teams: Array = [_team(1, "central", 1), _team(2, "pacific", 2)]
	var players: Array = []
	_fill_team(players, 1, 56)  # 大量放出後 → 空きが多い
	_fill_team(players, 2, 65)  # ほぼ維持 → 空きが少ない
	var state: Dictionary = DraftService.create_draft_state(players, teams, null, 0)
	var targets: Dictionary = state.get("team_main_targets", {}) as Dictionary
	assert_int(int(targets.get("1", 0))).is_equal(DraftService.MAIN_DRAFT_MAX_PICKS)
	assert_int(int(targets.get("2", 0))).is_equal(DraftService.MAIN_DRAFT_MIN_PICKS)
	assert_int(int(targets.get("1", 0))).is_greater(int(targets.get("2", 0)))


func test_draft_target_accounts_for_promotions() -> void:
	# 昇格見込みの育成が多い球団はその分ドラフトを控える。
	var teams: Array = [_team(1, "central", 1)]
	var base_players: Array = []
	_fill_team(base_players, 1, 58)
	var base_state: Dictionary = DraftService.create_draft_state(base_players, teams, null, 0)
	var base_target: int = int((base_state.get("team_main_targets", {}) as Dictionary).get("1", 0))

	var promo_players: Array = []
	_fill_team(promo_players, 1, 58)
	_add_dev(promo_players, 1, 4)  # 昇格水準の育成4人 (value>=昇格閾値)
	var promo_state: Dictionary = DraftService.create_draft_state(promo_players, teams, null, 0)
	var promo_target: int = int((promo_state.get("team_main_targets", {}) as Dictionary).get("1", 0))

	assert_int(promo_target).is_less(base_target)


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
