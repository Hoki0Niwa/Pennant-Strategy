extends Node

const CampServiceRef = preload("res://services/season/camp_service.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const FieldingModelRef = preload("res://services/simulation/models/fielding_model.gd")

var _next_id: int = -970000


func _ready() -> void:
	RecordStore.clear_records()
	Rng.set_seed_value(20260613)

	var failures: Array = []
	failures.append_array(_test_candidate_generation())
	failures.append_array(_test_training_limits_and_effects())
	failures.append_array(_test_aptitude_formula())
	failures.append_array(_test_normal_pitch_learning())

	if failures.is_empty():
		print("Camp service smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("Camp service smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_candidate_generation() -> Array:
	var failures: Array = []
	var season: PSSeason = _season(2026)
	var players: Array = [
		_make_fielder(1, 3, 25, {"first": 100}),
		_make_fielder(1, 2, 26, {"catcher": 100}),
		_make_pitcher(1, 27, "starter", 78, 52, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.SLIDER, PSPitchTypes.CHANGEUP]),
		_make_pitcher(1, 28, "reliever", 32, 78, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.FORK]),
	]
	var teams: Array = [_team(1)]
	var state: Dictionary = CampServiceRef.create_camp_state(players, teams, season, 1)
	var candidates: Array = state.get("candidates", []) as Array
	if candidates.is_empty():
		failures.append("camp candidates should be generated")
	var position_candidates: int = 0
	for row in candidates:
		var c: Dictionary = row as Dictionary
		var training_type: String = str(c.get("training_type", ""))
		if training_type == "pitch_learn" or training_type.contains("pitch"):
			failures.append("pitch learning appeared as special training candidate: %s" % training_type)
		if int(c.get("target_position", 0)) == 2:
			failures.append("catcher target appeared in camp candidate: %s" % JSON.stringify(c))
		if training_type == CampServiceRef.TRAIN_POSITION_LEARN or training_type == CampServiceRef.TRAIN_POSITION_CONVERT:
			position_candidates += 1
	if position_candidates <= 0:
		failures.append("position learn/convert candidates should be generated")
	return failures


func _test_training_limits_and_effects() -> Array:
	var failures: Array = []
	var season: PSSeason = _season(2026)
	var p1: PSPlayer = _make_fielder(1, 3, 23, {"first": 100})
	var p2: PSPlayer = _make_fielder(1, 5, 24, {"third": 100})
	var p3: PSPlayer = _make_fielder(1, 7, 25, {"left": 100})
	var p4: PSPlayer = _make_fielder(1, 9, 26, {"right": 100})
	var players: Array = [p1, p2, p3, p4]
	var state: Dictionary = {"actions": [], "team_action_counts": {}, "trained_player_ids": [], "candidates": []}

	var convert_entry: Dictionary = _entry(p1, CampServiceRef.TRAIN_POSITION_CONVERT, 7, 1.0)
	CampServiceRef._apply_training(state, players, season, convert_entry, "test")
	var left_aptitude: int = int(p1.position_aptitudes.get("left", 0))
	if p1.position != 7:
		failures.append("position convert should change primary position to LF")
	if int(p1.position_aptitudes.get("first", 0)) != 100:
		failures.append("old primary aptitude should remain as sub position")
	if left_aptitude < CampServiceRef.PRIMARY_CONVERT_APTITUDE_BY_POSITION[7] - 10:
		failures.append("converted aptitude too low: %d" % left_aptitude)
	if CampServiceRef._can_apply_entry(state, _entry(p1, CampServiceRef.TRAIN_POSITION_LEARN, 9, 1.0)):
		failures.append("same player should not be trainable twice")

	CampServiceRef._apply_training(state, players, season, _entry(p2, CampServiceRef.TRAIN_POSITION_LEARN, 4, 1.0), "test")
	CampServiceRef._apply_training(state, players, season, _entry(p3, CampServiceRef.TRAIN_POSITION_LEARN, 8, 1.0), "test")
	if CampServiceRef._team_action_count(state, 1) != CampServiceRef.MAX_SPECIAL_TRAININGS_PER_TEAM:
		failures.append("team training count should reach cap")
	if CampServiceRef._can_apply_entry(state, _entry(p4, CampServiceRef.TRAIN_POSITION_LEARN, 6, 1.0)):
		failures.append("team should not be trainable after 3 special trainings")

	var fail_state: Dictionary = {"actions": [], "team_action_counts": {}, "trained_player_ids": [], "candidates": []}
	var fail_player: PSPlayer = _make_fielder(1, 3, 22, {"first": 100})
	var before_shortstop: int = int(fail_player.position_aptitudes.get("shortstop", 0))
	CampServiceRef._apply_training(fail_state, [fail_player], season, _entry(fail_player, CampServiceRef.TRAIN_POSITION_LEARN, 6, 0.0), "test")
	var fail_action: Dictionary = (fail_state.get("actions", []) as Array)[0] as Dictionary
	if bool(fail_action.get("success", true)):
		failures.append("success_chance=0 should fail")
	if int(fail_player.position_aptitudes.get("shortstop", 0)) != before_shortstop:
		failures.append("failed position learn should not add aptitude")
	return failures


func _test_aptitude_formula() -> Array:
	var failures: Array = []
	var base_order: Array = [3, 7, 9, 5, 8, 4, 6]
	var secondary_previous: int = 999
	var primary_previous: int = 999
	for position in base_order:
		var secondary_base: int = int(CampServiceRef.SECONDARY_READY_APTITUDE_BY_POSITION[position])
		var primary_base: int = int(CampServiceRef.PRIMARY_CONVERT_APTITUDE_BY_POSITION[position])
		if secondary_base >= secondary_previous:
			failures.append("secondary base aptitude order is broken at %d" % position)
		if primary_base >= primary_previous:
			failures.append("primary base aptitude order is broken at %d" % position)
		secondary_previous = secondary_base
		primary_previous = primary_base

	var player: PSPlayer = _make_fielder(1, 3, 24, {"first": 100})
	player.z_abilities["IF_Reach"] = 1.8
	player.z_abilities["IF_Secure"] = 1.4
	player.z_abilities["IF_ThrowPower"] = 1.2
	player.z_abilities["IF_ThrowAccuracy"] = 1.0
	player.z_abilities["IF_Exchange"] = 1.1
	player.z_abilities["IF_PositionFit"] = 1.3
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 2026, 1)
	var target_position: int = 6
	var diff: float = FieldingModelRef.fielding_score_for_position(record, target_position) - FieldingModelRef.position_average_ability_score(target_position)
	var expected_bonus: int = clampi(int(round(diff * 6.0)), -10, 10)
	var expected_aptitude: int = clampi(int(CampServiceRef.SECONDARY_READY_APTITUDE_BY_POSITION[target_position]) + expected_bonus, 1, 100)
	var actual_aptitude: int = CampServiceRef._target_aptitude(record, target_position, false)
	if actual_aptitude != expected_aptitude:
		failures.append("ability bonus formula mismatch: expected %d got %d" % [expected_aptitude, actual_aptitude])
	return failures


func _test_normal_pitch_learning() -> Array:
	var failures: Array = []
	var starter: PSPlayer = _make_pitcher(1, 22, "starter", 82, 58, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.SLIDER])
	var reliever: PSPlayer = _make_pitcher(1, 22, "reliever", 28, 84, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.FORK])
	var trained: PSPlayer = _make_pitcher(1, 22, "starter", 82, 58, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.CURVE])
	var six_pitch: PSPlayer = _make_pitcher(1, 22, "starter", 82, 58, [
		PSPitchTypes.FOUR_SEAM, PSPitchTypes.TWO_SEAM, PSPitchTypes.SINKER,
		PSPitchTypes.CUTTER, PSPitchTypes.SLIDER, PSPitchTypes.CURVE,
	])
	var injured: PSPlayer = _make_pitcher(1, 22, "starter", 82, 58, [PSPitchTypes.FOUR_SEAM, PSPitchTypes.CHANGEUP])
	injured.injury_days = 30
	var trained_ids: Dictionary = {trained.id: true}
	var learned: Array = CampServiceRef.process_normal_pitch_learning(
		[starter, reliever, trained, six_pitch, injured],
		_season(2026),
		trained_ids,
		{},
		1.0
	)
	if learned.size() != 1:
		failures.append("normal camp pitch learning should affect only one eligible starter, got %d" % learned.size())
	else:
		var entry: Dictionary = learned[0] as Dictionary
		if int(entry.get("player_id", 0)) != starter.id:
			failures.append("normal pitch learning picked wrong player: %s" % JSON.stringify(entry))
	if starter.arsenal.size() != 3:
		failures.append("starter should add exactly one pitch, arsenal=%d" % starter.arsenal.size())
	if reliever.arsenal.size() != 2:
		failures.append("reliever should not learn a normal camp pitch")
	if trained.arsenal.size() != 2:
		failures.append("special-trained pitcher should be excluded from normal pitch learning")
	if six_pitch.arsenal.size() != 6:
		failures.append("six-pitch starter should be excluded")
	if injured.arsenal.size() != 2:
		failures.append("injured starter should be excluded")
	return failures


func _entry(player: PSPlayer, training_type: String, target_position: int, success_chance: float) -> Dictionary:
	return {
		"team_id": player.team_id,
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"training_type": training_type,
		"training_label": CampServiceRef.training_label(training_type),
		"success_chance": success_chance,
		"target_position": target_position,
		"target_position_name": PSPlayer.POSITION_NAMES.get(target_position, ""),
		"reason": "smoke",
	}


func _make_fielder(team_id: int, position: int, age: int, aptitudes: Dictionary) -> PSPlayer:
	var player: PSPlayer = PSPlayer.from_dict({
		"id": _id(),
		"sensyu_num": _next_id,
		"team_id": team_id,
		"name": "CampF%d" % abs(_next_id),
		"age": age,
		"years": 2,
		"height": 180,
		"weight": 82,
		"position": position,
		"role": "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 1200,
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"position_aptitudes": aptitudes.duplicate(true),
		"position_experience": aptitudes.duplicate(true),
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, 62, 86),
		"fatigue": 0,
		"injury_days": 0,
	})
	return player


func _make_pitcher(team_id: int, age: int, role: String, stamina_display: int, k_display: int, arsenal: Array) -> PSPlayer:
	var z: Dictionary = Offseason.generated_z_abilities(1, 60, 90)
	z["Pit_Stamina"] = PSAbilityScale.display_to_z(stamina_display)
	z["Pit_FatigueResist"] = PSAbilityScale.display_to_z(stamina_display)
	z["Pit_Efficiency"] = PSAbilityScale.display_to_z(66 if role == "starter" else 48)
	z["Pit_KCreate"] = PSAbilityScale.display_to_z(k_display)
	z["Pit_EdgeRate"] = PSAbilityScale.display_to_z(k_display)
	var entries: Array = []
	for i in range(arsenal.size()):
		entries.append({"type": str(arsenal[i]), "mastery": 1.2 - float(i) * 0.25})
	return PSPlayer.from_dict({
		"id": _id(),
		"sensyu_num": _next_id,
		"team_id": team_id,
		"name": "CampP%d" % abs(_next_id),
		"age": age,
		"years": 2,
		"height": 183,
		"weight": 86,
		"position": 1,
		"role": role,
		"throws": "R",
		"bats": "R",
		"salary": 1500,
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"position_aptitudes": {},
		"source_data": {},
		"z_abilities": z,
		"arsenal": entries,
		"fatigue": 0,
		"injury_days": 0,
	})


func _team(id: int) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "short_name": "T%d" % id, "league": "central", "funds": 200000})


func _season(year: int) -> PSSeason:
	var s: PSSeason = PSSeason.new()
	s.year = year
	s.season_number = 1
	return s


func _id() -> int:
	var value: int = _next_id
	_next_id += 1
	return value
