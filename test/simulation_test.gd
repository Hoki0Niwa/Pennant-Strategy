extends GdUnitTestSuite


func test_closer_role_is_preferred_in_ninth_close_game() -> void:
	var closer: PSPlayerSeasonRecord = _pitcher(101, "Closer", 0.0)
	var middle: PSPlayerSeasonRecord = _pitcher(102, "Middle", 0.6)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [middle, closer],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			closer.player_id: PSRotationPlanner.RELIEF_ROLE_CLOSER,
			middle.player_id: PSRotationPlanner.RELIEF_ROLE_MIDDLE,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}
	var game_result: Dictionary = {
		"away_team_id": 1,
		"home_team_id": 2,
		"away_score": 3,
		"home_score": 2,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 9, game_result, false)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(closer.player_id)


func test_long_role_is_preferred_when_starter_exits_early() -> void:
	var long_reliever: PSPlayerSeasonRecord = _pitcher(201, "Long", 0.0)
	var short_reliever: PSPlayerSeasonRecord = _pitcher(202, "Short", 0.6)
	var setup: Dictionary = {
		"team_id": 1,
		"relievers": [short_reliever, long_reliever],
		"used_pitcher_ids": {},
		"relief_role_by_pitcher": {
			long_reliever.player_id: PSRotationPlanner.RELIEF_ROLE_LONG,
			short_reliever.player_id: PSRotationPlanner.RELIEF_ROLE_SETUP,
		},
		"game_day": 12,
		"team_games_played_before": 10,
	}

	var picked: PSPlayerSeasonRecord = PSBullpenManager.pick_reliever_for_context(setup, 4, {}, true)

	assert_object(picked).is_not_null()
	assert_int(picked.player_id).is_equal(long_reliever.player_id)


func test_saved_relief_roles_are_kept_in_reliever_pool() -> void:
	var top: PSPlayerSeasonRecord = _pitcher(301, "Top", 1.2)
	var role_pick: PSPlayerSeasonRecord = _pitcher(302, "Role Pick", -0.4)
	var others: Array = []
	for i in range(6):
		others.append(_pitcher(310 + i, "Other %d" % i, 0.8 - float(i) * 0.05))
	var pool: Array = [top]
	pool.append_array(others)
	pool.append(role_pick)
	var saved: Dictionary = {
		"relief_roles": {
			"closer_id": role_pick.player_id,
			"setup_ids": [],
			"middle_ids": [],
			"long_id": 0,
		},
	}

	var selected: Array = PSRotationPlanner.select_relievers_for_innings(pool, [], 0, saved)
	var ids: Array = []
	for record_value in selected:
		ids.append((record_value as PSPlayerSeasonRecord).player_id)

	assert_array(ids).contains(role_pick.player_id)
	assert_int(int(ids[0])).is_equal(role_pick.player_id)


func _pitcher(player_id: int, player_name: String, z: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.name = player_name
	record.position = 1
	record.role = "reliever"
	record.age = 27
	record.fatigue = 0
	record.injury_days = 0
	record.z_abilities_snapshot = {
		"Pit_KCreate": z,
		"Pit_EdgeRate": z,
		"Pit_BBPrevent": z,
		"Pit_BarrelDeny": z,
		"Pit_ImpactLimit": z,
		"Pit_LoftControl": z,
		"Pit_Efficiency": z,
		"Pit_FatigueResist": z,
		"Pit_Stamina": z,
		"Pit_HoldRunner": z,
	}
	record.raw_abilities_snapshot = {"max_velocity": 150 + int(round(z * 3.0))}
	record.arsenal_snapshot = [
		{"type": "four_seam", "mastery": z},
		{"type": "slider", "mastery": z - 0.1},
	]
	return record
