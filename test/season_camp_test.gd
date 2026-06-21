extends GdUnitTestSuite

const CampServiceRef = preload("res://services/season/camp_service.gd")


func test_pitcher_options_follow_current_role() -> void:
	var starter: PSPlayer = _player({
		"id": 101,
		"name": "Starter",
		"team_id": 1,
		"position": 1,
		"role": "starter",
	})
	var reliever: PSPlayer = _player({
		"id": 102,
		"name": "Reliever",
		"team_id": 1,
		"position": 1,
		"role": "reliever",
	})
	var state: Dictionary = _camp_state()
	var starter_types: Array = _option_types(CampServiceRef.user_training_options_for_player(state, [starter, reliever], null, starter.id))
	var reliever_types: Array = _option_types(CampServiceRef.user_training_options_for_player(state, [starter, reliever], null, reliever.id))

	assert_array(starter_types).contains(CampServiceRef.TRAIN_RELIEVER)
	assert_array(starter_types).not_contains(CampServiceRef.TRAIN_STARTER)
	assert_array(reliever_types).contains(CampServiceRef.TRAIN_STARTER)
	assert_array(reliever_types).not_contains(CampServiceRef.TRAIN_RELIEVER)


func test_fielder_convert_is_limited_to_existing_secondary_positions() -> void:
	var fielder: PSPlayer = _player({
		"id": 201,
		"name": "Fielder",
		"team_id": 1,
		"position": 5,
		"role": "fielder",
		"position_aptitudes": {
			"third": 100,
			"first": 62,
		},
	})
	var options: Array = CampServiceRef.user_training_options_for_player(_camp_state(), [fielder], null, fielder.id)
	var convert_targets: Array = _targets_for_type(options, CampServiceRef.TRAIN_POSITION_CONVERT)
	var learn_targets: Array = _targets_for_type(options, CampServiceRef.TRAIN_POSITION_LEARN)

	assert_array(convert_targets).contains(3)
	assert_array(convert_targets).not_contains(4)
	assert_array(learn_targets).contains(4)
	assert_array(learn_targets).not_contains(3)


func test_user_can_submit_player_selected_position_training_without_candidate_row() -> void:
	var fielder: PSPlayer = _player({
		"id": 301,
		"name": "Choice",
		"team_id": 1,
		"position": 7,
		"role": "fielder",
		"position_aptitudes": {
			"left": 100,
		},
	})
	var state: Dictionary = _camp_state()
	state["candidates"] = []
	var result: Dictionary = CampServiceRef.submit_user_player_training(
		state,
		[fielder],
		[_team(1)],
		null,
		fielder.id,
		CampServiceRef.TRAIN_POSITION_LEARN,
		6
	)

	assert_bool(result.get("ok", false)).is_true()
	assert_array(state.get("trained_player_ids", []) as Array).contains(fielder.id)
	var actions: Array = state.get("actions", []) as Array
	assert_array(actions).has_size(1)
	assert_str(str((actions[0] as Dictionary).get("training_type", ""))).is_equal(CampServiceRef.TRAIN_POSITION_LEARN)
	assert_int(int((actions[0] as Dictionary).get("target_position", 0))).is_equal(6)


func test_role_conversion_is_unlimited_and_always_succeeds() -> void:
	var pitchers: Array = []
	for i in range(5):
		pitchers.append(_player({
			"id": 500 + i,
			"name": "Starter %d" % i,
			"team_id": 1,
			"position": 1,
			"role": "starter",
		}))
	var state: Dictionary = _camp_state()
	var teams: Array = [_team(1)]

	# 上限 (3) を超えて5人全員を中継へ転向できる。すべて成功する。
	for pitcher_row in pitchers:
		var pitcher: PSPlayer = pitcher_row as PSPlayer
		var result: Dictionary = CampServiceRef.submit_user_player_training(
			state, pitchers, teams, null, pitcher.id, CampServiceRef.TRAIN_RELIEVER, 0)
		assert_bool(result.get("ok", false)).is_true()

	for pitcher_row in pitchers:
		assert_str((pitcher_row as PSPlayer).role).is_equal("reliever")
	# 役割転向は特別練習上限を消費しない (無制限)。
	assert_int(int((state.get("team_action_counts", {}) as Dictionary).get("1", 0))).is_equal(0)


func test_fielder_position_training_still_capped_at_three() -> void:
	var fielders: Array = []
	for i in range(4):
		fielders.append(_player({
			"id": 600 + i,
			"name": "Fielder %d" % i,
			"team_id": 1,
			"position": 7,
			"role": "fielder",
			"position_aptitudes": {"left": 100},
		}))
	var state: Dictionary = _camp_state()
	var teams: Array = [_team(1)]

	var ok_count: int = 0
	for fielder_row in fielders:
		var fielder: PSPlayer = fielder_row as PSPlayer
		var result: Dictionary = CampServiceRef.submit_user_player_training(
			state, fielders, teams, null, fielder.id, CampServiceRef.TRAIN_POSITION_LEARN, 6)
		if bool(result.get("ok", false)):
			ok_count += 1
	# 野手の位置習得/本職変更は従来どおり1チーム3人まで。4人目は上限で弾かれる。
	assert_int(ok_count).is_equal(3)
	assert_int(int((state.get("team_action_counts", {}) as Dictionary).get("1", 0))).is_equal(3)


func test_camp_conversion_targets_two_to_three_ratio() -> void:
	var starter: PSPlayer = _player({"id": 700, "team_id": 1, "position": 1, "role": "starter"})
	var reliever: PSPlayer = _player({"id": 701, "team_id": 1, "position": 1, "role": "reliever"})

	# 先発過多 (先発6/中継4 → 目標先発4, 余剰2): 先発に中継転向を提案、中継には提案なし。
	var surplus: Dictionary = {"starters": 6, "relievers": 4}
	assert_array(_option_types(CampServiceRef._pitcher_candidates(starter, surplus, null))).contains(CampServiceRef.TRAIN_RELIEVER)
	assert_array(_option_types(CampServiceRef._pitcher_candidates(reliever, surplus, null))).is_empty()

	# 先発不足 (先発2/中継8 → 目標先発4, 不足2): 中継に先発転向を提案、先発には提案なし。
	var deficit: Dictionary = {"starters": 2, "relievers": 8}
	assert_array(_option_types(CampServiceRef._pitcher_candidates(reliever, deficit, null))).contains(CampServiceRef.TRAIN_STARTER)
	assert_array(_option_types(CampServiceRef._pitcher_candidates(starter, deficit, null))).is_empty()

	# 目標どおり 2:3 (先発4/中継6): どちらにも提案なし。
	var balanced: Dictionary = {"starters": 4, "relievers": 6}
	assert_array(_option_types(CampServiceRef._pitcher_candidates(starter, balanced, null))).is_empty()
	assert_array(_option_types(CampServiceRef._pitcher_candidates(reliever, balanced, null))).is_empty()


func test_idle_fraction_prioritizes_unused_pitchers() -> void:
	# 出場していない先発は idle=1、主力ローテ先発は idle=0。転向 expected の重みに効く。
	var idle_starter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	idle_starter.position = 1
	idle_starter.role = "starter"
	idle_starter.pitcher_stats.starts = 0
	var regular_starter: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	regular_starter.position = 1
	regular_starter.role = "starter"
	regular_starter.pitcher_stats.starts = 25

	assert_float(CampServiceRef._idle_fraction(idle_starter)).is_equal(1.0)
	assert_float(CampServiceRef._idle_fraction(regular_starter)).is_equal(0.0)

	# 中継ぎは登板数 (games) で測る。
	var idle_reliever: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	idle_reliever.position = 1
	idle_reliever.role = "reliever"
	idle_reliever.pitcher_stats.games = 2
	assert_float(CampServiceRef._idle_fraction(idle_reliever)).is_greater(0.5)


func _camp_state() -> Dictionary:
	return {
		"complete": false,
		"user_team_id": 1,
		"actions": [],
		"team_action_counts": {},
		"trained_player_ids": [],
		"candidates": [],
	}


func _player(data: Dictionary) -> PSPlayer:
	var payload: Dictionary = {
		"age": 24,
		"years": 3,
		"height": 180,
		"weight": 80,
		"throws": "R",
		"bats": "R",
		"z_abilities": {},
		"raw_abilities": {},
	}
	for key in data.keys():
		payload[key] = data[key]
	return PSPlayer.from_dict(payload)


func _team(team_id: int) -> PSTeam:
	return PSTeam.from_dict({
		"id": team_id,
		"name": "Team %d" % team_id,
		"short_name": "T%d" % team_id,
		"league": "central",
	})


func _option_types(options: Array) -> Array:
	var rows: Array = []
	for option_row in options:
		rows.append(str((option_row as Dictionary).get("training_type", "")))
	return rows


func _targets_for_type(options: Array, training_type: String) -> Array:
	var rows: Array = []
	for option_row in options:
		var option: Dictionary = option_row as Dictionary
		if str(option.get("training_type", "")) == training_type:
			rows.append(int(option.get("target_position", 0)))
	return rows
