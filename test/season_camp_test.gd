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


# 前季の本職 (遊撃) で守備実績 OAA が崩壊した野手には、より易しい既存サブポジ (三塁) への
# 本職変更が「守備実績圧力」で AI 実施水準 (MIN_AI_EXPECTED_VALUE) を超えて提案される。
func test_bad_primary_defense_creates_convert_pressure_candidate() -> void:
	var season: PSSeason = PSSeason.new()
	season.year = 9000
	season.season_number = 0
	var fielder: PSPlayer = _player({
		"id": 801,
		"name": "BadGlove",
		"team_id": 1,
		"position": 6,
		"role": "fielder",
		"position_aptitudes": {"shortstop": 100, "third": 70},
	})
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fielder, 9000, 0)
	record.advanced_stats.fielding_chances_by_position = {"6": 300}
	record.advanced_stats.oaa_by_position = {"6": -15.0}
	var key: String = "801:9000:0"
	RecordStore.player_records[key] = record

	# 補強需要はゼロに飽和させ、守備実績圧力だけで提案されることを確認する。
	var profile: Dictionary = _saturated_profile()
	var rows: Array = CampServiceRef._fielder_candidates(fielder, profile, season)
	RecordStore.player_records.erase(key)

	var convert_expected: float = -1.0
	var harder_pressure_found: bool = false
	for row in rows:
		var entry: Dictionary = row as Dictionary
		if str(entry.get("training_type", "")) != CampServiceRef.TRAIN_POSITION_CONVERT:
			continue
		var target: int = int(entry.get("target_position", 0))
		if target == 5:
			convert_expected = max(convert_expected, float(entry.get("expected_value", 0.0)))
		elif not CampServiceRef._is_easier_position(target, 6) and float(entry.get("expected_value", 0.0)) >= CampServiceRef.MIN_AI_EXPECTED_VALUE:
			harder_pressure_found = true
	assert_float(convert_expected).is_greater_equal(CampServiceRef.MIN_AI_EXPECTED_VALUE)
	assert_bool(harder_pressure_found).is_false()

	# 実績が普通なら圧力ゼロ → 需要ゼロ環境では三塁転向は提案されない。
	var ok_record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(fielder, 9000, 0)
	ok_record.advanced_stats.fielding_chances_by_position = {"6": 300}
	ok_record.advanced_stats.oaa_by_position = {"6": 1.0}
	RecordStore.player_records[key] = ok_record
	var ok_rows: Array = CampServiceRef._fielder_candidates(fielder, profile, season)
	RecordStore.player_records.erase(key)
	for row in ok_rows:
		var entry: Dictionary = row as Dictionary
		if str(entry.get("training_type", "")) == CampServiceRef.TRAIN_POSITION_CONVERT:
			assert_int(int(entry.get("target_position", 0))).is_not_equal(5)


# 本職が飽和している位置 (一塁は快適水準3) への転向は surplus penalty で抑制される。
func test_convert_surplus_penalty_suppresses_saturated_positions() -> void:
	var profile: Dictionary = {"position_primary_count": {3: 6, 6: 2}}
	assert_float(CampServiceRef._primary_surplus_penalty(profile, 3)).is_equal(36.0)
	assert_float(CampServiceRef._primary_surplus_penalty(profile, 6)).is_equal(0.0)


func _saturated_profile() -> Dictionary:
	var holders: Dictionary = {}
	var primary: Dictionary = {}
	var top: Dictionary = {}
	var deficit: Dictionary = {}
	for pos_row in CampServiceRef.DEFENSIVE_POSITIONS:
		var pos: int = int(pos_row)
		holders[pos] = 5
		primary[pos] = 5
		top[pos] = 99
		deficit[pos] = 0.0
	return {
		"position_holders": holders,
		"position_primary_count": primary,
		"position_top_overall": top,
		"war_deficit": deficit,
	}


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
		"league": "league1",
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
