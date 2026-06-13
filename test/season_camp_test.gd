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
