extends RefCounted
class_name CampService

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const MAX_SPECIAL_TRAININGS_PER_TEAM: int = 3
const MAX_SPECIAL_TRAININGS_PER_PLAYER: int = 1
const MAX_PITCH_TYPES: int = 6
const NORMAL_CAMP_NEW_PITCH_CHANCE: float = 0.02
const NORMAL_CAMP_YOUNG_BONUS: float = 0.01
const NORMAL_CAMP_VETERAN_PENALTY: float = 0.01
const FAILURE_PENALTY_CHANCE: float = 0.65
# CPU/自動が特別練習を行う最低 expected。これ未満は「やる価値が薄い」とみなし実施しない。
# 高めに設定することで、明確な需要のある球団だけが (需要分だけ) 練習し、不要な球団は0件になる。
# 25 だと _position_need_score の holder_shortage だけ (控え0人で最大24) でほぼ全球団が
# 毎年 MAX_SPECIAL_TRAININGS_PER_TEAM に機械的に張り付いてしまうため、holder_shortage 単独では
# 届かず ability_bonus/top_shortage 等の追加要因が伴う場合だけ実施される水準まで上げる。
const MIN_AI_EXPECTED_VALUE: float = 45.0

# CPU/自動のキャンプ転向が目指す球団全体の先発比率 (先発:中継 = 2:3 = 先発 40%)。
const STARTER_TARGET_RATIO: float = 0.4
# 目標比率からの乖離 (人数) 1 あたりの need。乖離が大きいほど expected_value が上がり優先転向される。
const ROLE_BALANCE_NEED_WEIGHT: float = 14.0
# 前年「主力相応」とみなす出場ライン。これ以上出場していれば idle=0 (転向対象から外す)。
const IDLE_REGULAR_STARTS: int = 16
const IDLE_REGULAR_RELIEF: int = 30

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
# 転向方向の判定用の守備難易度 (大きいほど難しい)。POSITION_DIFFICULTY_PENALTY + 捕手。
# 守備実績由来の転向圧力は「現本職より易しい位置」へのみ働く。
const POSITION_CONVERT_DIFFICULTY: Dictionary = {
	2: 0.12,
	6: 0.10,
	4: 0.08,
	8: 0.08,
	5: 0.05,
	9: 0.03,
	7: 0.02,
	3: 0.00,
}
# 守備実績によるコンバート圧力: 前季の本職での実績 OAA (rating 換算) が
# DEFENSE_PRESSURE_MIN_RATING_DELTA を下回った分に比例して expected_value を押し上げる。
# rating -6 (配置AIの崩壊ライン) で 30+36=66 となり MIN_AI_EXPECTED_VALUE(45) を超える。
const DEFENSE_PRESSURE_MIN_RATING_DELTA: float = -4.0
const DEFENSE_PRESSURE_BASE: float = 30.0
const DEFENSE_PRESSURE_WEIGHT: float = 18.0
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
		"team_pitcher_balance": _initial_pitcher_balance(profiles),
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
	_teams: Array,
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
		# 役割転向は球団が 2:3 目標へ達した時点で打ち切る (件数を需要連動にする)。
		if _is_role_conversion(entry) and not _role_conversion_still_needed(state, entry):
			entry["available"] = false
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
		if player.is_retired() or player.injury_days > 0:
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
	if user_team_id <= 0:
		return rows
	var player: PSPlayer = _find_player_by_id(players, player_id)
	if player == null or player.team_id != user_team_id:
		return rows
	if not _player_can_train(player):
		return rows
	if _trained_player_set(state).has(player.id):
		return rows
	var options: Array = _user_training_options(player, season)
	# 役割転向 (先発⇄中継) は無制限。上限到達後は役割転向のみ残し、位置習得/本職変更は不可。
	if _team_action_count(state, user_team_id) >= MAX_SPECIAL_TRAININGS_PER_TEAM:
		var role_only: Array = []
		for option_row in options:
			if _is_role_conversion(option_row as Dictionary):
				role_only.append(option_row)
		return role_only
	return options


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
	_apply_training(state, players, season, entry, "user_manual")
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
		# 2:3 目標に達した方向の役割転向は「おまかせ/候補」には出さない (手動指定は別経路で無制限)。
		if _is_role_conversion(entry) and not _role_conversion_still_needed(state, entry):
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
		if player.is_retired() or player.injury_days > 0:
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
	var total: int = starter_count + reliever_count
	if total <= 0:
		return rows
	# 球団全体で 先発:中継 = 2:3 (先発 40%) を目標にし、乖離している方向だけ転向を提案する。
	# CPU は1チーム年3件まで (cap) なので、目標へは複数年かけて緩やかに収束する。
	var target_starters: int = int(round(float(total) * STARTER_TARGET_RATIO))
	var starter_surplus: int = starter_count - target_starters
	var value: float = float(OffseasonService.player_value_score(player))
	# 「能力が高い割に前年あまり出場できていない」投手ほど優先して転向させる。
	# blocked = (能力 + 乖離need) × idle。主力(idle≈0)は ~0 になり MIN_AI を割って転向対象から外れる。
	var idle: float = _idle_fraction(record)
	if PSPitcherRoleModel.is_starter_record(record):
		# 先発過多のときだけ、出場の少ない高能力先発を救援適性順に中継へ。
		if starter_surplus > 0:
			var relief_advantage: float = PSPitcherRoleModel.reliever_advantage(record)
			var blocked: float = (value * 0.5 + 20.0 + float(starter_surplus) * ROLE_BALANCE_NEED_WEIGHT) * idle
			var expected_relief: float = blocked + relief_advantage * 8.0
			rows.append(_candidate_base(player, TRAIN_RELIEVER, expected_relief, _reliever_success_chance(record), "中継不足(先発過多 %d) / 出場不足 %.0f%% / 救援適性差 %.2f" % [starter_surplus, idle * 100.0, relief_advantage]))
	else:
		# 先発不足のときだけ、出場の少ない高能力中継を先発適性順に先発へ。
		if starter_surplus < 0:
			var advantage: float = PSPitcherRoleModel.starter_advantage(record)
			var deficit: int = -starter_surplus
			var blocked_s: float = (value * 0.5 + 20.0 + float(deficit) * ROLE_BALANCE_NEED_WEIGHT) * idle
			var expected: float = blocked_s + advantage * 8.0
			rows.append(_candidate_base(player, TRAIN_STARTER, expected, _starter_success_chance(record), "先発不足 %d / 出場不足 %.0f%% / 先発適性差 %.2f" % [deficit, idle * 100.0, advantage]))
	return rows


# 前年「主力相応に出場できていない」度合い (0=主力相応, 1=ほぼ未出場)。現役割の出場で測る。
# キャンプ転向で「能力が高い割に出場できていない」投手を優先するための重み。
static func _idle_fraction(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 1.0
	if PSPitcherRoleModel.is_starter_record(record):
		return clampf(1.0 - float(record.pitcher_stats.starts) / float(IDLE_REGULAR_STARTS), 0.0, 1.0)
	return clampf(1.0 - float(record.pitcher_stats.games) / float(IDLE_REGULAR_RELIEF), 0.0, 1.0)


static func _fielder_candidates(player: PSPlayer, profile: Dictionary, season: PSSeason) -> Array:
	var rows: Array = []
	var record: PSPlayerSeasonRecord = _record_for_player(player, season)
	# 前季の本職での守備実績 (OAA) が悪い選手は、より易しい位置への転向/習得を優先候補にする。
	var primary_pressure: float = _primary_defense_pressure(record, player.position)
	for position in DEFENSIVE_POSITIONS:
		if position == player.position:
			continue
		var easier_than_primary: bool = _is_easier_position(position, player.position)
		var pressure: float = primary_pressure if easier_than_primary else 0.0
		var current_aptitude: int = _player_position_aptitude(player, position)
		var ability_bonus: int = _position_ability_bonus(record, position)
		var position_need: float = _position_need_score(profile, position)
		# 既に本職が飽和している位置への転向/習得は抑制する (1B/LF へ一方通行で溜まるのを防ぐ)。
		var surplus_penalty: float = _primary_surplus_penalty(profile, position)
		if current_aptitude <= 0:
			var expected: float = position_need + pressure * 0.5 - surplus_penalty * 0.5 + float(ability_bonus) * 1.8 + float(OffseasonService.player_value_score(player)) * 0.04
			if position_need > 0.0 or ability_bonus >= 2 or pressure > 0.0:
				var entry: Dictionary = _candidate_base(player, TRAIN_POSITION_LEARN, expected, _position_learn_success_chance(record, position, ability_bonus), "守備可人数不足 %.1f / 適性補正 %+d / 守備実績圧力 %.0f" % [position_need, ability_bonus, pressure * 0.5])
				entry["target_position"] = position
				entry["target_position_name"] = _position_label(position)
				entry["projected_aptitude"] = _target_aptitude(record, position, false)
				rows.append(entry)
		elif current_aptitude >= 55:
			var convert_need: float = _primary_need_score(profile, position) + position_need * 0.5
			var expected_convert: float = convert_need + pressure - surplus_penalty + float(current_aptitude - 55) * 0.18 + float(ability_bonus) * 1.2
			if convert_need > 0.0 or current_aptitude >= 82 or pressure > 0.0:
				var convert_entry: Dictionary = _candidate_base(player, TRAIN_POSITION_CONVERT, expected_convert, _position_convert_success_chance(record, position, current_aptitude, ability_bonus), "本職不足 %.1f / 現適性 %d / 適性補正 %+d / 守備実績圧力 %.0f" % [convert_need, current_aptitude, ability_bonus, pressure])
				convert_entry["target_position"] = position
				convert_entry["target_position_name"] = _position_label(position)
				convert_entry["projected_aptitude"] = _target_aptitude(record, position, true)
				rows.append(convert_entry)
	return rows


# 前季の本職守備実績によるコンバート圧力。realized_fielding_rating_delta が
# DEFENSE_PRESSURE_MIN_RATING_DELTA を下回るほど大きくなる (下回らなければ 0)。
static func _primary_defense_pressure(record: PSPlayerSeasonRecord, primary_position: int) -> float:
	if record == null or primary_position < 2 or primary_position > 9:
		return 0.0
	var delta: float = PlayerValueEvaluator.realized_fielding_rating_delta(record, primary_position)
	if delta >= DEFENSE_PRESSURE_MIN_RATING_DELTA:
		return 0.0
	return DEFENSE_PRESSURE_BASE + (DEFENSE_PRESSURE_MIN_RATING_DELTA - delta) * DEFENSE_PRESSURE_WEIGHT


static func _is_easier_position(target_position: int, primary_position: int) -> bool:
	return float(POSITION_CONVERT_DIFFICULTY.get(target_position, 0.0)) < float(POSITION_CONVERT_DIFFICULTY.get(primary_position, 0.0))


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
		var convert_entry: Dictionary = _candidate_base(
			player,
			TRAIN_POSITION_CONVERT,
			0.0,
			_position_convert_success_chance(record, target_position, current_aptitude, ability_bonus),
			"選手指定: 既存サブポジから本職変更"
		)
		convert_entry["target_position"] = target_position
		convert_entry["target_position_name"] = _position_label(target_position)
		convert_entry["projected_aptitude"] = _target_aptitude(record, target_position, true)
		return convert_entry
	return {}


static func _candidate_base(player: PSPlayer, training_type: String, expected_value: float, success_chance: float, reason: String) -> Dictionary:
	return {
		"team_id": player.team_id,
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"role": player.role,
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
	var before_ratings: Dictionary = OffseasonService._capture_display_ratings(player)
	var before_pitch_values: Array = OffseasonService._capture_pitch_mastery_values(player) if player.is_pitcher() else []
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
		"is_pitcher": player.is_pitcher(),
		"arsenal": player.arsenal.duplicate(true),
		"aptitudes": player.position_aptitudes.duplicate(true),
		"pitch_changes": OffseasonService._build_pitch_mastery_changes(before_pitch_values, OffseasonService._capture_pitch_mastery_values(player)) if player.is_pitcher() else [],
		# 基本能力の前後変化 (成長結果と同形式)。特別練習は基本能力をほぼ変えないため大半は ±0。
		"abilities": OffseasonService._build_ability_changes(before_ratings, OffseasonService._capture_display_ratings(player)),
	}
	var actions: Array = state.get("actions", []) as Array
	actions.append(action)
	state["actions"] = actions
	# 役割転向 (AI/手動とも) は上限を消費しない。野手の位置練習だけ上限を1消費する。
	if not _is_role_conversion(entry):
		_increment_team_action_count(state, player.team_id)
	# 役割転向はライブ比率を更新し、2:3 到達後の不要な転向を止める判定に使う。
	if _is_role_conversion(entry):
		_apply_pitcher_balance_shift(state, player.team_id, str(entry.get("training_type", "")))
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
		if player.is_retired():
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


# 本職在籍が快適水準 (一塁3 / それ以外4) を超えている位置への転向抑制ペナルティ。
const CONVERT_POSITION_COMFORT: Dictionary = {3: 3}
const CONVERT_SURPLUS_PENALTY_WEIGHT: float = 12.0


static func _primary_surplus_penalty(profile: Dictionary, position: int) -> float:
	var primary: Dictionary = profile.get("position_primary_count", {}) as Dictionary
	var comfort: int = int(CONVERT_POSITION_COMFORT.get(position, 4))
	var surplus: int = int(primary.get(position, 0)) - comfort
	if surplus <= 0:
		return 0.0
	return float(surplus) * CONVERT_SURPLUS_PENALTY_WEIGHT


# 先発⇄中継の役割転向は「必ず成功」(能力に依らず 100%)。役割の付け替えは失敗する性質のものではない。
static func _starter_success_chance(_record: PSPlayerSeasonRecord) -> float:
	return 1.0


static func _reliever_success_chance(_record: PSPlayerSeasonRecord) -> float:
	return 1.0


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


static func _is_role_conversion(entry: Dictionary) -> bool:
	var training_type: String = str(entry.get("training_type", ""))
	return training_type == TRAIN_STARTER or training_type == TRAIN_RELIEVER


# 役割転向 (先発⇄中継) は AI/手動とも特別練習上限の対象外 (無制限)。
# CPU の転向は上限ではなく 2:3 目標 (_role_conversion_still_needed) で止まる。
# 野手の位置習得/本職変更だけが MAX_SPECIAL_TRAININGS_PER_TEAM の上限に従う。
static func _can_apply_entry(state: Dictionary, entry: Dictionary) -> bool:
	var player_id: int = int(entry.get("player_id", 0))
	if _trained_player_set(state).has(player_id):
		return false
	if _is_role_conversion(entry):
		return true
	return _team_action_count(state, int(entry.get("team_id", 0))) < MAX_SPECIAL_TRAININGS_PER_TEAM


static func _initial_pitcher_balance(profiles: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for team_id in profiles.keys():
		var profile: Dictionary = profiles[team_id] as Dictionary
		out[str(team_id)] = {
			"starters": int(profile.get("starters", 0)),
			"relievers": int(profile.get("relievers", 0)),
		}
	return out


# CPU/自動の役割転向は、球団が 2:3 目標に達したら止める (ライブ再計算)。
# これで転向件数が「目標からの乖離」に連動し、均衡している球団は0件になる。手動は対象外 (無制限)。
static func _role_conversion_still_needed(state: Dictionary, entry: Dictionary) -> bool:
	var balance: Dictionary = state.get("team_pitcher_balance", {}) as Dictionary
	var tb: Dictionary = balance.get(str(int(entry.get("team_id", 0))), {}) as Dictionary
	if tb.is_empty():
		return true
	var starters: int = int(tb.get("starters", 0))
	var total: int = starters + int(tb.get("relievers", 0))
	if total <= 0:
		return true
	var target: int = int(round(float(total) * STARTER_TARGET_RATIO))
	match str(entry.get("training_type", "")):
		TRAIN_RELIEVER:
			return starters > target
		TRAIN_STARTER:
			return starters < target
	return true


static func _apply_pitcher_balance_shift(state: Dictionary, team_id: int, training_type: String) -> void:
	var balance: Dictionary = state.get("team_pitcher_balance", {}) as Dictionary
	var key: String = str(team_id)
	if not balance.has(key):
		return
	var tb: Dictionary = balance[key] as Dictionary
	if training_type == TRAIN_RELIEVER:
		tb["starters"] = max(0, int(tb.get("starters", 0)) - 1)
		tb["relievers"] = int(tb.get("relievers", 0)) + 1
	elif training_type == TRAIN_STARTER:
		tb["relievers"] = max(0, int(tb.get("relievers", 0)) - 1)
		tb["starters"] = int(tb.get("starters", 0)) + 1
	balance[key] = tb
	state["team_pitcher_balance"] = balance


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
	if player.is_retired() or player.injury_days > 0:
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
