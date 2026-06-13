extends RefCounted
class_name CampService

const FieldingModel = preload("res://services/simulation/models/fielding_model.gd")
const OffseasonService = preload("res://services/season/offseason_service.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const MAX_SPECIAL_TRAININGS_PER_TEAM: int = 3
const MAX_SPECIAL_TRAININGS_PER_PLAYER: int = 1
const MAX_PITCH_TYPES: int = 6
const NORMAL_CAMP_NEW_PITCH_CHANCE: float = 0.02
const NORMAL_CAMP_YOUNG_BONUS: float = 0.01
const NORMAL_CAMP_VETERAN_PENALTY: float = 0.01
const FAILURE_PENALTY_CHANCE: float = 0.65
const MIN_AI_EXPECTED_VALUE: float = 18.0

const TRAIN_STARTER: String = "starter_conversion"
const TRAIN_RELIEVER: String = "reliever_conversion"
const TRAIN_POSITION_LEARN: String = "position_learn"
const TRAIN_POSITION_CONVERT: String = "position_convert"

const DEFENSIVE_POSITIONS: Array[int] = [3, 7, 9, 5, 8, 4, 6]
const POSITION_KEY_BY_ID: Dictionary = {
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}
const SECONDARY_READY_APTITUDE_BY_POSITION: Dictionary = {
	3: 86,
	7: 82,
	9: 80,
	5: 76,
	8: 74,
	4: 72,
	6: 68,
}
const PRIMARY_CONVERT_APTITUDE_BY_POSITION: Dictionary = {
	3: 96,
	7: 94,
	9: 92,
	5: 90,
	8: 88,
	4: 86,
	6: 84,
}
const POSITION_DIFFICULTY_PENALTY: Dictionary = {
	3: 0.00,
	7: 0.02,
	9: 0.03,
	5: 0.05,
	8: 0.08,
	4: 0.08,
	6: 0.10,
}
const POSITION_LABELS: Dictionary = {
	1: "投手",
	2: "捕手",
	3: "一塁",
	4: "二塁",
	5: "三塁",
	6: "遊撃",
	7: "左翼",
	8: "中堅",
	9: "右翼",
}


static func process_camp(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_camp_state(players, teams, season, user_team_id)
	complete_camp_automatically(state, players, teams, season, user_team_id, true)
	return finalize_camp(state, players, season)


static func create_camp_state(players: Array, teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var injury_carryover: Dictionary = OffseasonService.process_injury_carryover(players, season)
	var profiles: Dictionary = _build_team_profiles(players, teams, season)
	var start_starter_ids: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.team_id > 0 and player.is_pitcher() and PSPitcherRoleModel.is_starter_player(player):
			start_starter_ids.append(player.id)
	var candidates: Array = _build_candidates(players, profiles, season)
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if is_equal_approx(float(da.get("expected_value", 0.0)), float(db.get("expected_value", 0.0))):
			return int(da.get("candidate_id", 0)) < int(db.get("candidate_id", 0))
		return float(da.get("expected_value", 0.0)) > float(db.get("expected_value", 0.0))
	)
	var has_user_choices: bool = user_team_id > 0 and _has_user_trainable_players(players, season, user_team_id)
	return {
		"version": 1,
		"year": year,
		"user_team_id": user_team_id,
		"complete": candidates.is_empty() and not has_user_choices,
		"finalized": false,
		"candidates": candidates,
		"actions": [],
		"team_action_counts": {},
		"trained_player_ids": [],
		"user_finished": false,
		"injury_carryover": injury_carryover,
		"start_starter_ids": start_starter_ids,
		"normal_pitch_learning": [],
	}


static func submit_user_camp_action(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "キャンプは既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var entry: Dictionary = _state_candidate_by_id(state, candidate_id)
	if entry.is_empty() or not bool(entry.get("available", true)):
		return {"ok": false, "message": "その特別練習は選択できません。", "state": state}
	if int(entry.get("team_id", 0)) != user_team_id:
		return {"ok": false, "message": "自球団の候補ではありません。", "state": state}

	if action == "skip":
		entry["user_skipped"] = true
		_advance_user_state_if_done(state, players, teams, season)
		return {"ok": true, "state": state}
	if action != "train":
		return {"ok": false, "message": "不正なキャンプ操作です。", "state": state}
	if not _can_apply_entry(state, entry):
		entry["available"] = false
		return {"ok": false, "message": "この球団または選手は今オフの特別練習上限に達しています。", "state": state}
	_apply_training(state, players, season, entry, "user")
	_advance_user_state_if_done(state, players, teams, season)
	return {"ok": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	while _team_action_count(state, user_team_id) < MAX_SPECIAL_TRAININGS_PER_TEAM:
		var candidates: Array = available_user_candidates(state)
		if candidates.is_empty():
			break
		var entry: Dictionary = candidates[0] as Dictionary
		if float(entry.get("expected_value", 0.0)) < MIN_AI_EXPECTED_VALUE:
			break
		var result: Dictionary = submit_user_camp_action(state, players, teams, season, int(entry.get("candidate_id", 0)), "train")
		if not bool(result.get("ok", false)) or bool(state.get("complete", false)):
			return result
	state["user_finished"] = true
	complete_camp_automatically(state, players, teams, season, user_team_id, false)
	return {"ok": true, "state": state}


static func complete_camp_automatically(
	state: Dictionary,
	players: Array,
	teams: Array,
	season: PSSeason,
	user_team_id: int = 0,
	include_user_team: bool = false
) -> Dictionary:
	var candidates: Array = state.get("candidates", []) as Array
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		var va: float = float(da.get("expected_value", 0.0))
		var vb: float = float(db.get("expected_value", 0.0))
		if is_equal_approx(va, vb):
			return int(da.get("candidate_id", 0)) < int(db.get("candidate_id", 0))
		return va > vb
	)
	for row in candidates:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		var team_id: int = int(entry.get("team_id", 0))
		if team_id == user_team_id and not include_user_team:
			continue
		if team_id == user_team_id and bool(entry.get("user_skipped", false)):
			continue
		if float(entry.get("expected_value", 0.0)) < MIN_AI_EXPECTED_VALUE:
			continue
		if not _can_apply_entry(state, entry):
			entry["available"] = false
			continue
		_apply_training(state, players, season, entry, "ai")
	state["complete"] = true
	return {"ok": true, "state": state}


static func finalize_camp(state: Dictionary, players: Array, season: PSSeason) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var trained_ids: Dictionary = {}
	for id_value in state.get("trained_player_ids", []) as Array:
		trained_ids[int(id_value)] = true
	var starter_ids: Dictionary = {}
	for id_value in state.get("start_starter_ids", []) as Array:
		starter_ids[int(id_value)] = true
	var normal_pitch: Array = process_normal_pitch_learning(players, season, trained_ids, starter_ids)
	state["normal_pitch_learning"] = normal_pitch
	var actions: Array = (state.get("actions", []) as Array).duplicate(true)
	actions.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("team_id", 0)) == int(db.get("team_id", 0)):
			return str(da.get("name", "")) < str(db.get("name", ""))
		return int(da.get("team_id", 0)) < int(db.get("team_id", 0))
	)
	var success_count: int = 0
	for row in actions:
		if bool((row as Dictionary).get("success", false)):
			success_count += 1
	var result: Dictionary = {
		"actions": actions,
		"actions_count": actions.size(),
		"success_count": success_count,
		"failed_count": actions.size() - success_count,
		"normal_pitch_learning": normal_pitch,
		"normal_pitch_learning_count": normal_pitch.size(),
		"injury_carryover": state.get("injury_carryover", {}),
	}
	state["finalized"] = true
	state["complete"] = true
	state["final_result"] = result
	return result


static func process_normal_pitch_learning(
	players: Array,
	season: PSSeason,
	trained_player_ids: Dictionary = {},
	start_starter_ids: Dictionary = {},
	chance_override: float = -1.0
) -> Array:
	var year: int = season.year if season != null else 0
	var learned: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0 or not player.is_pitcher():
			continue
		if player.is_retired() or player.is_manager_candidate() or player.injury_days > 0:
			continue
		if trained_player_ids.has(player.id):
			continue
		if not start_starter_ids.is_empty() and not start_starter_ids.has(player.id):
			continue
		if start_starter_ids.is_empty() and not PSPitcherRoleModel.is_starter_player(player):
			continue
		var arsenal: Array = _player_arsenal_or_derived(player, year)
		if arsenal.size() >= MAX_PITCH_TYPES:
			continue
		var chance: float = chance_override if chance_override >= 0.0 else _normal_pitch_learning_chance(player)
		if Rng.roll_float() > chance:
			continue
		var pitch_type: String = _choose_new_pitch_type(player, arsenal)
		if pitch_type.is_empty():
			continue
		var mastery: float = -0.9 + Rng.roll_float() * 0.6
		arsenal.append({"type": pitch_type, "mastery": mastery})
		player.arsenal = arsenal
		learned.append({
			"team_id": player.team_id,
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"pitch_type": pitch_type,
			"pitch_name": PSPitchTypes.display_name(pitch_type),
			"mastery": mastery,
			"mastery_grade": PSPitchTypes.mastery_grade(mastery),
			"chance": chance,
		})
	return learned


static func user_training_options_for_player(state: Dictionary, players: Array, season: PSSeason, player_id: int) -> Array:
	var rows: Array = []
	if bool(state.get("complete", false)):
		return rows
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0 or _team_action_count(state, user_team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM:
		return rows
	var player: PSPlayer = _find_player_by_id(players, player_id)
	if player == null or player.team_id != user_team_id:
		return rows
	if not _player_can_train(player):
		return rows
	if _trained_player_set(state).has(player.id):
		return rows
	return _user_training_options(player, season)


static func submit_user_player_training(
	state: Dictionary,
	players: Array,
	teams: Array,
	season: PSSeason,
	player_id: int,
	training_type: String,
	target_position: int = 0
) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "キャンプは既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var player: PSPlayer = _find_player_by_id(players, player_id)
	if player == null or player.team_id != user_team_id:
		return {"ok": false, "message": "自球団の選手を選択してください。", "state": state}
	if not _player_can_train(player):
		return {"ok": false, "message": "この選手は今オフの特別練習を選択できません。", "state": state}
	var entry: Dictionary = _build_user_training_entry(player, season, training_type, target_position)
	if entry.is_empty():
		return {"ok": false, "message": "この選手には選択できない特別練習です。", "state": state}
	if not _can_apply_entry(state, entry):
		return {"ok": false, "message": "この球団または選手は今オフの特別練習上限に達しています。", "state": state}
	_apply_training(state, players, season, entry, "user")
	_advance_user_training_state_if_done(state, players, teams, season)
	return {"ok": true, "state": state}


static func available_user_candidates(state: Dictionary) -> Array:
	var user_team_id: int = int(state.get("user_team_id", 0))
	var rows: Array = []
	if user_team_id <= 0 or _team_action_count(state, user_team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM:
		return rows
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("team_id", 0)) != user_team_id:
			continue
		if not bool(entry.get("available", true)) or bool(entry.get("user_skipped", false)):
			continue
		if _trained_player_set(state).has(int(entry.get("player_id", 0))):
			continue
		rows.append(entry.duplicate(true))
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		var va: float = float(da.get("expected_value", 0.0))
		var vb: float = float(db.get("expected_value", 0.0))
		if is_equal_approx(va, vb):
			return int(da.get("candidate_id", 0)) < int(db.get("candidate_id", 0))
		return va > vb
	)
	return rows


static func finish_user_camp(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	state["user_finished"] = true
	complete_camp_automatically(state, players, teams, season, int(state.get("user_team_id", 0)), false)
	return {"ok": true, "state": state}


static func _build_candidates(players: Array, profiles: Dictionary, season: PSSeason) -> Array:
	var candidates: Array = []
	var next_id: int = 1
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired() or player.is_manager_candidate() or player.injury_days > 0:
			continue
		var profile: Dictionary = profiles.get(player.team_id, {}) as Dictionary
		if player.is_pitcher():
			for entry in _pitcher_candidates(player, profile, season):
				var candidate: Dictionary = entry as Dictionary
				candidate["candidate_id"] = next_id
				next_id += 1
				candidates.append(candidate)
		else:
			for entry in _fielder_candidates(player, profile, season):
				var candidate_f: Dictionary = entry as Dictionary
				candidate_f["candidate_id"] = next_id
				next_id += 1
				candidates.append(candidate_f)
	return candidates


static func _pitcher_candidates(player: PSPlayer, profile: Dictionary, season: PSSeason) -> Array:
	var record: PSPlayerSeasonRecord = _record_for_player(player, season)
	var rows: Array = []
	var starter_count: int = int(profile.get("starters", 0))
	var reliever_count: int = int(profile.get("relievers", 0))
	if not PSPitcherRoleModel.is_starter_record(record):
		var need: float = max(0.0, float(6 - starter_count)) * 16.0 + max(0.0, float(reliever_count - 9)) * 4.0
		var advantage: float = PSPitcherRoleModel.starter_advantage(record)
		var expected: float = need + advantage * 8.0 + float(OffseasonService.player_value_score(player)) * 0.08
		if need > 0.0 or advantage > -0.4:
			rows.append(_candidate_base(player, TRAIN_STARTER, expected, _starter_success_chance(record), "先発不足 %.1f / 先発適性差 %.2f" % [need, advantage]))
	if PSPitcherRoleModel.is_starter_record(record):
		var relief_need: float = max(0.0, float(9 - reliever_count)) * 12.0 + max(0.0, float(starter_count - 7)) * 5.0
		var relief_advantage: float = PSPitcherRoleModel.reliever_advantage(record)
		var expected_relief: float = relief_need + relief_advantage * 8.0 + float(OffseasonService.player_value_score(player)) * 0.06
		if relief_need > 0.0 or relief_advantage > -0.3:
			rows.append(_candidate_base(player, TRAIN_RELIEVER, expected_relief, _reliever_success_chance(record), "救援不足 %.1f / 救援適性差 %.2f" % [relief_need, relief_advantage]))
	return rows


static func _fielder_candidates(player: PSPlayer, profile: Dictionary, season: PSSeason) -> Array:
	var rows: Array = []
	var record: PSPlayerSeasonRecord = _record_for_player(player, season)
	for position in DEFENSIVE_POSITIONS:
		if position == player.position:
			continue
		var current_aptitude: int = _player_position_aptitude(player, position)
		var ability_bonus: int = _position_ability_bonus(record, position)
		var position_need: float = _position_need_score(profile, position)
		if current_aptitude <= 0:
			var expected: float = position_need + float(ability_bonus) * 1.8 + float(OffseasonService.player_value_score(player)) * 0.04
			if position_need > 0.0 or ability_bonus >= 2:
				var entry: Dictionary = _candidate_base(player, TRAIN_POSITION_LEARN, expected, _position_learn_success_chance(record, position, ability_bonus), "守備可人数不足 %.1f / 適性補正 %+d" % [position_need, ability_bonus])
				entry["target_position"] = position
				entry["target_position_name"] = _position_label(position)
				entry["projected_aptitude"] = _target_aptitude(record, position, false)
				rows.append(entry)
		elif current_aptitude >= 55:
			var convert_need: float = _primary_need_score(profile, position) + position_need * 0.5
			var expected_convert: float = convert_need + float(current_aptitude - 55) * 0.18 + float(ability_bonus) * 1.2
			if convert_need > 0.0 or current_aptitude >= 82:
				var convert: Dictionary = _candidate_base(player, TRAIN_POSITION_CONVERT, expected_convert, _position_convert_success_chance(record, position, current_aptitude, ability_bonus), "本職不足 %.1f / 現適性 %d / 適性補正 %+d" % [convert_need, current_aptitude, ability_bonus])
				convert["target_position"] = position
				convert["target_position_name"] = _position_label(position)
				convert["projected_aptitude"] = _target_aptitude(record, position, true)
				rows.append(convert)
	return rows


static func _user_training_options(player: PSPlayer, season: PSSeason) -> Array:
	var rows: Array = []
	if not _player_can_train(player):
		return rows
	if player.is_pitcher():
		var record: PSPlayerSeasonRecord = _record_for_player(player, season)
		var training_type: String = TRAIN_RELIEVER if PSPitcherRoleModel.is_starter_record(record) else TRAIN_STARTER
		var pitcher_entry: Dictionary = _build_user_training_entry(player, season, training_type, 0)
		if not pitcher_entry.is_empty():
			rows.append(pitcher_entry)
		return rows

	for position in DEFENSIVE_POSITIONS:
		if position == player.position:
			continue
		if _player_position_aptitude(player, position) > 0:
			var convert_entry: Dictionary = _build_user_training_entry(player, season, TRAIN_POSITION_CONVERT, position)
			if not convert_entry.is_empty():
				rows.append(convert_entry)

	for position in DEFENSIVE_POSITIONS:
		if position == player.position:
			continue
		if _player_position_aptitude(player, position) <= 0:
			var learn_entry: Dictionary = _build_user_training_entry(player, season, TRAIN_POSITION_LEARN, position)
			if not learn_entry.is_empty():
				rows.append(learn_entry)
	return rows


static func _build_user_training_entry(player: PSPlayer, season: PSSeason, training_type: String, target_position: int) -> Dictionary:
	if player == null:
		return {}
	var record: PSPlayerSeasonRecord = _record_for_player(player, season)
	if player.is_pitcher():
		var is_starter: bool = PSPitcherRoleModel.is_starter_record(record)
		if training_type == TRAIN_STARTER:
			if is_starter:
				return {}
			return _candidate_base(player, TRAIN_STARTER, 0.0, _starter_success_chance(record), "選手指定: 先発転向")
		if training_type == TRAIN_RELIEVER:
			if not is_starter:
				return {}
			return _candidate_base(player, TRAIN_RELIEVER, 0.0, _reliever_success_chance(record), "選手指定: リリーフ転向")
		return {}

	if target_position < 3 or target_position > 9 or not DEFENSIVE_POSITIONS.has(target_position):
		return {}
	if target_position == player.position:
		return {}
	var current_aptitude: int = _player_position_aptitude(player, target_position)
	var ability_bonus: int = _position_ability_bonus(record, target_position)
	if training_type == TRAIN_POSITION_LEARN:
		if current_aptitude > 0:
			return {}
		var learn: Dictionary = _candidate_base(
			player,
			TRAIN_POSITION_LEARN,
			0.0,
			_position_learn_success_chance(record, target_position, ability_bonus),
			"選手指定: 守備位置獲得"
		)
		learn["target_position"] = target_position
		learn["target_position_name"] = _position_label(target_position)
		learn["projected_aptitude"] = _target_aptitude(record, target_position, false)
		return learn
	if training_type == TRAIN_POSITION_CONVERT:
		if current_aptitude <= 0:
			return {}
		var convert: Dictionary = _candidate_base(
			player,
			TRAIN_POSITION_CONVERT,
			0.0,
			_position_convert_success_chance(record, target_position, current_aptitude, ability_bonus),
			"選手指定: 既存サブポジから本職変更"
		)
		convert["target_position"] = target_position
		convert["target_position_name"] = _position_label(target_position)
		convert["projected_aptitude"] = _target_aptitude(record, target_position, true)
		return convert
	return {}


static func _candidate_base(player: PSPlayer, training_type: String, expected_value: float, success_chance: float, reason: String) -> Dictionary:
	return {
		"team_id": player.team_id,
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"training_type": training_type,
		"training_label": training_label(training_type),
		"success_chance": success_chance,
		"risk_label": "中",
		"expected_value": expected_value,
		"need_score": max(0.0, expected_value),
		"reason": reason,
		"available": true,
	}


static func training_label(training_type: String) -> String:
	match training_type:
		TRAIN_STARTER:
			return "先発転向"
		TRAIN_RELIEVER:
			return "リリーフ転向"
		TRAIN_POSITION_LEARN:
			return "新守備位置習得"
		TRAIN_POSITION_CONVERT:
			return "本職変更"
		_:
			return training_type


static func _apply_training(state: Dictionary, players: Array, season: PSSeason, entry: Dictionary, method: String) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		entry["available"] = false
		return
	var before_value: int = OffseasonService.player_value_score(player)
	var old_position: int = player.position
	var old_role: String = player.role
	var target_position: int = int(entry.get("target_position", 0))
	var aptitude_before: int = _player_position_aptitude(player, target_position) if target_position > 0 else 0
	var success_chance: float = float(entry.get("success_chance", 0.0))
	var success: bool = Rng.roll_float() <= success_chance
	var penalty: bool = false
	if success:
		_apply_training_success(player, season, entry)
	else:
		penalty = _maybe_apply_failure_penalty(player, entry)
	var aptitude_after: int = _player_position_aptitude(player, target_position) if target_position > 0 else 0
	var action: Dictionary = {
		"team_id": player.team_id,
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"training_type": str(entry.get("training_type", "")),
		"training_label": str(entry.get("training_label", "")),
		"success": success,
		"penalty": penalty,
		"method": method,
		"success_chance": success_chance,
		"reason": str(entry.get("reason", "")),
		"before": before_value,
		"after": OffseasonService.player_value_score(player),
		"old_position": old_position,
		"new_position": player.position,
		"old_role": old_role,
		"new_role": player.role,
		"target_position": target_position,
		"target_position_name": str(entry.get("target_position_name", "")),
		"aptitude_before": aptitude_before,
		"aptitude_after": aptitude_after,
	}
	var actions: Array = state.get("actions", []) as Array
	actions.append(action)
	state["actions"] = actions
	_increment_team_action_count(state, player.team_id)
	var trained: Array = state.get("trained_player_ids", []) as Array
	if not trained.has(player.id):
		trained.append(player.id)
	state["trained_player_ids"] = trained
	_mark_player_candidates_unavailable(state, player.id)


static func _apply_training_success(player: PSPlayer, season: PSSeason, entry: Dictionary) -> void:
	var training_type: String = str(entry.get("training_type", ""))
	match training_type:
		TRAIN_STARTER:
			player.role = "starter"
			_add_z(player, "Pit_Stamina", 0.22)
			_add_z(player, "Pit_FatigueResist", 0.16)
			_add_z(player, "Pit_Efficiency", 0.10)
		TRAIN_RELIEVER:
			player.role = "reliever"
			_add_z(player, "Pit_KCreate", 0.10)
			_add_z(player, "Pit_EdgeRate", 0.14)
			_add_top_pitch_mastery(player, 0.18, season)
			_add_z(player, "Pit_Stamina", -0.10)
		TRAIN_POSITION_LEARN:
			_apply_position_aptitude(player, season, int(entry.get("target_position", 0)), false)
		TRAIN_POSITION_CONVERT:
			var target_position: int = int(entry.get("target_position", 0))
			_apply_position_aptitude(player, season, target_position, true)
			if target_position >= 3 and target_position <= 9:
				player.position = target_position


static func _maybe_apply_failure_penalty(player: PSPlayer, entry: Dictionary) -> bool:
	if Rng.roll_float() > FAILURE_PENALTY_CHANCE:
		return false
	match str(entry.get("training_type", "")):
		TRAIN_STARTER:
			_add_z(player, "Pit_Stamina", -0.08)
		TRAIN_RELIEVER:
			_add_z(player, "Pit_EdgeRate", -0.06)
		TRAIN_POSITION_LEARN, TRAIN_POSITION_CONVERT:
			var target_position: int = int(entry.get("target_position", 0))
			var key: String = _fielding_penalty_key(target_position)
			if not key.is_empty():
				_add_z(player, key, -0.06)
		_:
			return false
	return true


static func _apply_position_aptitude(player: PSPlayer, season: PSSeason, target_position: int, primary: bool) -> void:
	if target_position < 3 or target_position > 9:
		return
	var record: PSPlayerSeasonRecord = _record_for_player(player, season)
	var target: int = _target_aptitude(record, target_position, primary)
	var key: String = str(POSITION_KEY_BY_ID.get(target_position, ""))
	if key.is_empty():
		return
	_ensure_position_maps(player)
	player.position_aptitudes[key] = maxi(int(player.position_aptitudes.get(key, 0)), target)
	player.position_experience[key] = maxi(int(player.position_experience.get(key, 0)), target)


static func _target_aptitude(record: PSPlayerSeasonRecord, target_position: int, primary: bool) -> int:
	var base_map: Dictionary = PRIMARY_CONVERT_APTITUDE_BY_POSITION if primary else SECONDARY_READY_APTITUDE_BY_POSITION
	var base: int = int(base_map.get(target_position, 0))
	if base <= 0:
		return 0
	return clampi(base + _position_ability_bonus(record, target_position), 1, 100)


static func _position_ability_bonus(record: PSPlayerSeasonRecord, target_position: int) -> int:
	if record == null:
		return 0
	var diff: float = FieldingModel.fielding_score_for_position(record, target_position) - FieldingModel.position_average_ability_score(target_position)
	return clampi(int(round(diff * 6.0)), -10, 10)


static func _add_top_pitch_mastery(player: PSPlayer, delta: float, season: PSSeason) -> void:
	var arsenal: Array = _player_arsenal_or_derived(player, season.year if season != null else 0)
	if arsenal.is_empty():
		return
	var best_index: int = 0
	var best_mastery: float = -999.0
	for i in range(arsenal.size()):
		var mastery: float = float((arsenal[i] as Dictionary).get("mastery", 0.0))
		if mastery > best_mastery:
			best_mastery = mastery
			best_index = i
	var entry: Dictionary = arsenal[best_index] as Dictionary
	entry["mastery"] = clampf(float(entry.get("mastery", 0.0)) + delta, -2.0, 2.8)
	arsenal[best_index] = entry
	player.arsenal = arsenal


static func _add_z(player: PSPlayer, key: String, delta: float) -> void:
	player.z_abilities[key] = clampf(float(player.z_abilities.get(key, 0.0)) + delta, OffseasonService.Z_ABILITY_MIN, OffseasonService.Z_ABILITY_MAX)


static func _build_team_profiles(players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var profiles: Dictionary = {}
	var war_landscape: Dictionary = {}
	if season != null:
		war_landscape = WarCalculator.build_position_war_landscape(season.year, season.season_number, teams)
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		profiles[team.id] = {
			"starters": 0,
			"relievers": 0,
			"position_holders": {3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
			"position_primary_count": {3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
			"position_top_overall": {3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
			"war_deficit": _team_war_deficit(war_landscape, team.id),
		}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0 or not profiles.has(player.team_id):
			continue
		if player.is_retired() or player.is_manager_candidate():
			continue
		var profile: Dictionary = profiles[player.team_id] as Dictionary
		if player.is_pitcher():
			if PSPitcherRoleModel.is_starter_player(player):
				profile["starters"] = int(profile.get("starters", 0)) + 1
			else:
				profile["relievers"] = int(profile.get("relievers", 0)) + 1
			continue
		var overall: int = OffseasonService.player_value_score(player)
		var primary: Dictionary = profile.get("position_primary_count", {}) as Dictionary
		if primary.has(player.position):
			primary[player.position] = int(primary.get(player.position, 0)) + 1
		var holders: Dictionary = profile.get("position_holders", {}) as Dictionary
		var top: Dictionary = profile.get("position_top_overall", {}) as Dictionary
		for position in DEFENSIVE_POSITIONS:
			if _player_position_aptitude(player, position) > 0:
				holders[position] = int(holders.get(position, 0)) + 1
				if overall > int(top.get(position, 0)):
					top[position] = overall
	return profiles


static func _team_war_deficit(landscape: Dictionary, team_id: int) -> Dictionary:
	var out: Dictionary = {}
	var teams_map: Dictionary = landscape.get("teams", {}) as Dictionary
	var team: Dictionary = teams_map.get(team_id, teams_map.get(str(team_id), {})) as Dictionary
	var positions: Dictionary = team.get("positions", {}) as Dictionary
	for position in DEFENSIVE_POSITIONS:
		var bucket: Dictionary = positions.get(position, positions.get(str(position), {})) as Dictionary
		out[position] = float(bucket.get("deficit", 0.0))
	return out


static func _position_need_score(profile: Dictionary, position: int) -> float:
	var holders: Dictionary = profile.get("position_holders", {}) as Dictionary
	var top: Dictionary = profile.get("position_top_overall", {}) as Dictionary
	var war_deficit: Dictionary = profile.get("war_deficit", {}) as Dictionary
	var holder_shortage: int = max(0, 2 - int(holders.get(position, 0)))
	var top_shortage: float = max(0.0, 62.0 - float(top.get(position, 0))) / 4.0
	return float(holder_shortage) * 12.0 + top_shortage + float(war_deficit.get(position, 0.0)) * 8.0


static func _primary_need_score(profile: Dictionary, position: int) -> float:
	var primary: Dictionary = profile.get("position_primary_count", {}) as Dictionary
	var shortage: int = max(0, 2 - int(primary.get(position, 0)))
	var war_deficit: Dictionary = profile.get("war_deficit", {}) as Dictionary
	return float(shortage) * 16.0 + float(war_deficit.get(position, 0.0)) * 10.0


static func _starter_success_chance(record: PSPlayerSeasonRecord) -> float:
	var chance: float = 0.50 + PSPitcherRoleModel.starter_advantage(record) * 0.08
	chance += _age_training_bonus(record.age)
	return clampf(chance, 0.18, 0.78)


static func _reliever_success_chance(record: PSPlayerSeasonRecord) -> float:
	var chance: float = 0.56 + PSPitcherRoleModel.reliever_advantage(record) * 0.08
	chance += _age_training_bonus(record.age) * 0.5
	return clampf(chance, 0.20, 0.82)


static func _position_learn_success_chance(record: PSPlayerSeasonRecord, target_position: int, ability_bonus: int) -> float:
	var chance: float = 0.48 + float(ability_bonus) * 0.025 - float(POSITION_DIFFICULTY_PENALTY.get(target_position, 0.0))
	chance += _age_training_bonus(record.age)
	return clampf(chance, 0.20, 0.76)


static func _position_convert_success_chance(record: PSPlayerSeasonRecord, target_position: int, current_aptitude: int, ability_bonus: int) -> float:
	var chance: float = 0.36 + float(current_aptitude) * 0.003 + float(ability_bonus) * 0.020
	chance -= float(POSITION_DIFFICULTY_PENALTY.get(target_position, 0.0))
	chance += _age_training_bonus(record.age) * 0.5
	return clampf(chance, 0.18, 0.74)


static func _age_training_bonus(age: int) -> float:
	if age <= 23:
		return 0.06
	if age <= 27:
		return 0.03
	if age >= 34:
		return -0.08
	if age >= 31:
		return -0.04
	return 0.0


static func _normal_pitch_learning_chance(player: PSPlayer) -> float:
	var chance: float = NORMAL_CAMP_NEW_PITCH_CHANCE
	if player.age <= 23:
		chance += NORMAL_CAMP_YOUNG_BONUS
	elif player.age >= 32:
		chance -= NORMAL_CAMP_VETERAN_PENALTY
	return clampf(chance, 0.002, 0.04)


static func _choose_new_pitch_type(player: PSPlayer, arsenal: Array) -> String:
	var current: Dictionary = {}
	for entry_value in arsenal:
		var entry: Dictionary = entry_value as Dictionary
		current[str(entry.get("type", ""))] = true
	var lean: float = float(player.z_abilities.get("Pit_KCreate", 0.0)) - float(player.z_abilities.get("Pit_LoftControl", 0.0))
	var candidates: Array
	if lean >= 0.2:
		candidates = [PSPitchTypes.SLIDER, PSPitchTypes.FORK, PSPitchTypes.CURVE, PSPitchTypes.CUTTER, PSPitchTypes.CHANGEUP, PSPitchTypes.TWO_SEAM, PSPitchTypes.SINKER]
	elif lean <= -0.2:
		candidates = [PSPitchTypes.TWO_SEAM, PSPitchTypes.SINKER, PSPitchTypes.CHANGEUP, PSPitchTypes.CURVE, PSPitchTypes.CUTTER, PSPitchTypes.SLIDER, PSPitchTypes.FORK]
	else:
		candidates = [PSPitchTypes.SLIDER, PSPitchTypes.CHANGEUP, PSPitchTypes.CURVE, PSPitchTypes.CUTTER, PSPitchTypes.FORK, PSPitchTypes.TWO_SEAM, PSPitchTypes.SINKER]
	var offset: int = absi(hash(player.id)) % candidates.size()
	candidates = candidates.slice(offset) + candidates.slice(0, offset)
	for type_value in candidates:
		var type_key: String = str(type_value)
		if not current.has(type_key):
			return type_key
	return ""


static func _player_arsenal_or_derived(player: PSPlayer, year: int) -> Array:
	if player.arsenal != null and not player.arsenal.is_empty():
		return player.arsenal.duplicate(true)
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, year, 0)
	return record.arsenal_or_derived().duplicate(true)


static func _record_for_player(player: PSPlayer, season: PSSeason) -> PSPlayerSeasonRecord:
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			return record
	return PSPlayerSeasonRecord.from_player(player, 0, 0)


static func _player_position_aptitude(player: PSPlayer, position: int) -> int:
	if player == null or player.is_pitcher() or position < 3 or position > 9:
		return 0
	var key: String = str(POSITION_KEY_BY_ID.get(position, ""))
	if key.is_empty():
		return 0
	if player.position_aptitudes.is_empty():
		return 100 if player.position == position else 0
	return int(player.position_aptitudes.get(key, 0))


static func _fielding_penalty_key(position: int) -> String:
	match position:
		3, 4, 5, 6:
			return "IF_PositionFit"
		7, 8, 9:
			return "OF_PositionFit"
		_:
			return ""


static func _ensure_position_maps(player: PSPlayer) -> void:
	for key_value in POSITION_KEY_BY_ID.values():
		var key: String = str(key_value)
		if not player.position_aptitudes.has(key):
			player.position_aptitudes[key] = 0
		if not player.position_experience.has(key):
			player.position_experience[key] = int(player.position_aptitudes.get(key, 0))


static func _state_candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("candidate_id", 0)) == candidate_id:
			return entry
	return {}


static func _can_apply_entry(state: Dictionary, entry: Dictionary) -> bool:
	var team_id: int = int(entry.get("team_id", 0))
	if _team_action_count(state, team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM:
		return false
	var player_id: int = int(entry.get("player_id", 0))
	return not _trained_player_set(state).has(player_id)


static func _team_action_count(state: Dictionary, team_id: int) -> int:
	var counts: Dictionary = state.get("team_action_counts", {}) as Dictionary
	return int(counts.get(str(team_id), counts.get(team_id, 0)))


static func _increment_team_action_count(state: Dictionary, team_id: int) -> void:
	var counts: Dictionary = state.get("team_action_counts", {}) as Dictionary
	counts[str(team_id)] = int(counts.get(str(team_id), 0)) + 1
	state["team_action_counts"] = counts


static func _trained_player_set(state: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for id_value in state.get("trained_player_ids", []) as Array:
		out[int(id_value)] = true
	return out


static func _mark_player_candidates_unavailable(state: Dictionary, player_id: int) -> void:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("player_id", 0)) == player_id:
			entry["available"] = false


static func _advance_user_state_if_done(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if available_user_candidates(state).is_empty() and not _has_available_user_training_options(state, players, season, user_team_id):
		state["user_finished"] = true
		complete_camp_automatically(state, players, teams, season, int(state.get("user_team_id", 0)), false)


static func _advance_user_training_state_if_done(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if _team_action_count(state, user_team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM or not _has_available_user_training_options(state, players, season, user_team_id):
		state["user_finished"] = true
		complete_camp_automatically(state, players, teams, season, user_team_id, false)


static func _has_user_trainable_players(players: Array, season: PSSeason, user_team_id: int) -> bool:
	if user_team_id <= 0:
		return false
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.team_id == user_team_id and not _user_training_options(player, season).is_empty():
			return true
	return false


static func _has_available_user_training_options(state: Dictionary, players: Array, season: PSSeason, user_team_id: int) -> bool:
	if user_team_id <= 0 or _team_action_count(state, user_team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM:
		return false
	var trained: Dictionary = _trained_player_set(state)
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != user_team_id:
			continue
		if trained.has(player.id):
			continue
		if not _user_training_options(player, season).is_empty():
			return true
	return false


static func _player_can_train(player: PSPlayer) -> bool:
	if player == null or player.team_id <= 0:
		return false
	if player.is_retired() or player.is_manager_candidate() or player.injury_days > 0:
		return false
	return true


static func _find_player_by_id(players: Array, player_id: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


static func _position_label(position: int) -> String:
	return str(POSITION_LABELS.get(position, "?"))
