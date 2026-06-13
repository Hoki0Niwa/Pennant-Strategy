extends RefCounted
class_name ForeignPlayerService

# R4: 外国人選手雇用。
# FAと同じく state 型にし、自軍だけ手動で複数獲得できるようにする。完全自動の
# process_foreign_market は長期検証/CPU用ラッパーとして維持する。

const NamePoolRef = preload("res://services/data/name_pool.gd")

const ROSTER_LIMIT: int = 70
const FOREIGN_FA_YEARS: int = 7
const NUM_CANDIDATES: int = 54
const MAX_FOREIGN_HELD_PER_TEAM: int = 4
const MIN_NEED_TO_SIGN: float = 1.0
const OVER_BUDGET_SCORE_FACTOR: float = 0.6
const FOREIGN_SLOT_FILL_BONUS: float = 10.0
const CANDIDATE_MIN_AGE: int = 24
const CANDIDATE_MAX_AGE: int = 32
const FOREIGN_MIDDLE_INFIELDER_CENTER_PENALTY: int = 6
const FOREIGN_CATCHER_CENTER_PENALTY: int = 10
const POSITION_WEIGHTS: Array = [
	{"position": 1, "weight": 45},
	{"position": 2, "weight": 2},
	{"position": 3, "weight": 12},
	{"position": 4, "weight": 4},
	{"position": 5, "weight": 10},
	{"position": 6, "weight": 4},
	{"position": 7, "weight": 12},
	{"position": 8, "weight": 6},
	{"position": 9, "weight": 12},
]
const QUALITY_TIERS: Array = [
	{"roll": 8, "center": 72, "label": "ace", "salary": 18000},
	{"roll": 30, "center": 64, "label": "good", "salary": 10000},
	{"roll": 68, "center": 56, "label": "average", "salary": 6500},
	{"roll": 100, "center": 46, "label": "bust", "salary": 3500},
]
const SALARY_VARIANCE: float = 0.2


static func process_foreign_market(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_foreign_market_state(players, teams, season, user_team_id)
	complete_foreign_market_automatically(state, players, teams, season, user_team_id)
	return finalize_foreign_market(state)


static func create_foreign_market_state(players: Array, _teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var candidates: Array = []
	for i in range(NUM_CANDIDATES):
		candidates.append(_generate_candidate(i + 1, year))
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) == int(db.get("value", 0)):
			return int(da.get("candidate_id", 0)) < int(db.get("candidate_id", 0))
		return int(da.get("value", 0)) > int(db.get("value", 0))
	)
	return {
		"version": 2,
		"year": year,
		"user_team_id": user_team_id,
		"complete": candidates.is_empty(),
		"finalized": false,
		"next_player_id": _max_player_id(players) + 1,
		"candidates": candidates,
		"signings": [],
	}


static func submit_user_foreign_decision(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "外国人補強は既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var candidate: Dictionary = _state_candidate_by_id(state, candidate_id)
	if candidate.is_empty() or not bool(candidate.get("available", true)):
		return {"ok": false, "message": "その外国人候補は選択できません。", "state": state}
	if action == "skip":
		candidate["user_skipped"] = true
		_advance_foreign_state_if_done(state, players, teams, season)
		return {"ok": true, "state": state}
	if action != "sign":
		return {"ok": false, "message": "不正な外国人補強操作です。", "state": state}
	if not _can_team_sign_foreign(players, state, user_team_id):
		return {"ok": false, "message": "支配下枠または外国人枠が不足しています。", "state": state}
	_apply_signing(state, players, teams, season, candidate, user_team_id, "user")
	_advance_foreign_state_if_done(state, players, teams, season)
	return {"ok": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var best_id: int = 0
	var best_score: float = -999999.0
	var need: Dictionary = FaMarketService._build_position_need(players, teams)
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if not bool(candidate.get("available", true)):
			continue
		if not _can_team_sign_foreign(players, state, user_team_id):
			break
		var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(int(candidate.get("position", 0)), 0.0))
		var score: float = _signing_score(candidate, team_need, players, teams, user_team_id)
		if score > best_score:
			best_score = score
			best_id = int(candidate.get("candidate_id", 0))
	if best_id <= 0:
		complete_foreign_market_automatically(state, players, teams, season, user_team_id)
		return {"ok": true, "state": state}
	return submit_user_foreign_decision(state, players, teams, season, best_id, "sign")


static func complete_foreign_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var need: Dictionary = FaMarketService._build_position_need(players, teams)
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if not bool(candidate.get("available", true)):
			continue
		var best_team_id: int = 0
		var best_score: float = -999999.0
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			if team.id == user_team_id and bool(candidate.get("user_skipped", false)):
				continue
			if not _can_team_sign_foreign(players, state, team.id):
				continue
			var held: int = _foreign_count_for_team(players, team.id)
			var open_slots: int = max(0, MAX_FOREIGN_HELD_PER_TEAM - held)
			var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(candidate.get("position", 0)), 0.0))
			if team_need < MIN_NEED_TO_SIGN and open_slots <= 0:
				continue
			var score: float = _signing_score(candidate, team_need, players, teams, team.id)
			if score > best_score:
				best_score = score
				best_team_id = team.id
		if best_team_id > 0:
			_apply_signing(state, players, teams, season, candidate, best_team_id, "cpu")
	state["complete"] = true
	return {"ok": true, "state": state}


static func finalize_foreign_market(state: Dictionary) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var signings: Array = (state.get("signings", []) as Array).duplicate(true)
	signings.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	var result: Dictionary = {
		"candidates_count": (state.get("candidates", []) as Array).size(),
		"signings": signings,
		"signed_count": signings.size(),
	}
	state["finalized"] = true
	state["complete"] = true
	state["final_result"] = result
	return result


static func available_user_candidates(state: Dictionary, players: Array, teams: Array) -> Array:
	var rows: Array = []
	var user_team_id: int = int(state.get("user_team_id", 0))
	var need: Dictionary = FaMarketService._build_position_need(players, teams)
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if not bool(candidate.get("available", true)):
			continue
		var copy: Dictionary = candidate.duplicate(true)
		var pos: int = int(candidate.get("position", 0))
		copy["need"] = float((need.get(user_team_id, {}) as Dictionary).get(pos, 0.0))
		copy["can_sign"] = _can_team_sign_foreign(players, state, user_team_id)
		rows.append(copy)
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		return _signing_score(da, float(da.get("need", 0.0)), players, teams, user_team_id) > _signing_score(db, float(db.get("need", 0.0)), players, teams, user_team_id)
	)
	return rows


static func _apply_signing(state: Dictionary, players: Array, _teams: Array, _season: PSSeason, candidate: Dictionary, team_id: int, method: String) -> void:
	var data: Dictionary = (candidate.get("player_data", {}) as Dictionary).duplicate(true)
	var player_id: int = int(state.get("next_player_id", _max_player_id(players) + 1))
	state["next_player_id"] = player_id + 1
	data["id"] = player_id
	data["sensyu_num"] = player_id
	data["team_id"] = team_id
	var player: PSPlayer = PSPlayer.from_dict(data)
	players.append(player)
	candidate["available"] = false
	candidate["signed"] = true
	candidate["to_team"] = team_id
	var signings: Array = state.get("signings", []) as Array
	signings.append({
		"player_id": player.id,
		"candidate_id": int(candidate.get("candidate_id", 0)),
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"to_team": team_id,
		"salary": player.salary,
		"tier": str(candidate.get("tier", "")),
		"value": int(candidate.get("value", 0)),
		"method": method,
	})
	state["signings"] = signings


static func _advance_foreign_state_if_done(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	if _can_team_sign_foreign(players, state, int(state.get("user_team_id", 0))):
		for row in state.get("candidates", []) as Array:
			var candidate: Dictionary = row as Dictionary
			if bool(candidate.get("available", true)) and not bool(candidate.get("user_skipped", false)):
				return
	complete_foreign_market_automatically(state, players, teams, season, int(state.get("user_team_id", 0)))


static func _can_team_sign_foreign(players: Array, _state: Dictionary, team_id: int) -> bool:
	if team_id <= 0:
		return false
	var active: int = _active_count_for_team(players, team_id)
	if active >= ROSTER_LIMIT:
		return false
	var foreign_total: int = _foreign_count_for_team(players, team_id)
	return foreign_total < MAX_FOREIGN_HELD_PER_TEAM


static func _signing_score(candidate: Dictionary, team_need: float, players: Array, teams: Array, team_id: int) -> float:
	var held: int = _foreign_count_for_team(players, team_id)
	var open_slots: int = max(0, MAX_FOREIGN_HELD_PER_TEAM - held)
	var score: float = float(candidate.get("value", 0)) * (1.0 + team_need / 20.0)
	score += float(open_slots) * FOREIGN_SLOT_FILL_BONUS
	var team: PSTeam = _find_team_by_id(teams, team_id)
	if team != null:
		var room: int = team.funds - TeamFinance.team_payroll(players, team_id) - int(candidate.get("salary", 0))
		if room < 0:
			score *= OVER_BUDGET_SCORE_FACTOR
	return score


static func _generate_candidate(candidate_id: int, year: int) -> Dictionary:
	var position: int = _candidate_position()
	var tier: Dictionary = _roll_quality_tier()
	var center: int = _adjusted_center_for_position(int(tier["center"]), position)
	var age: int = Rng.range_int(CANDIDATE_MIN_AGE, CANDIDATE_MAX_AGE)
	var role: String = "fielder"
	if position == 1:
		role = "reliever" if Rng.roll_percent() <= 40 else "starter"
	var z_abilities: Dictionary = OffseasonService.generated_z_abilities(position, center, min(center + 10, 99))
	var base_salary: float = float(int(tier.get("salary", 5000)))
	var variance_factor: float = 1.0 + (Rng.roll_float() * 2.0 - 1.0) * SALARY_VARIANCE
	var salary: int = int(round(base_salary * variance_factor))
	var data: Dictionary = {
		"id": 0,
		"sensyu_num": 0,
		"jersey_number": 0,
		"development_player": false,
		"team_id": 0,
		"name": NamePoolRef.pick_foreign_name(),
		"age": age,
		# 署名直後はオフシーズン中なので 0 年目。翌シーズン開始時の一括加算で 1 年目になる。
		"years": 0,
		"height": Rng.range_int(178, 200),
		"weight": Rng.range_int(80, 110),
		"position": position,
		"role": role,
		"throws": "L" if Rng.roll_percent() <= 30 else "R",
		"bats": "L" if Rng.roll_percent() <= 40 else "R",
		"salary": salary,
		"draft_round": 0,
		"hometown": "",
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": true,
		"fa_eligible_years": FOREIGN_FA_YEARS,
		"position_aptitudes": _candidate_aptitudes(position),
		"source_data": {"foreign_scout": true, "foreign_signed_year": year, "quality_tier": str(tier["label"])},
		"fatigue": 0,
		"injury_days": 0,
		"z_abilities": z_abilities,
		"raw_abilities": OffseasonService.generated_raw_abilities(position, z_abilities),
		"arsenal": OffseasonService.generated_arsenal(position, z_abilities),
	}
	var player: PSPlayer = PSPlayer.from_dict(data)
	return {
		"candidate_id": candidate_id,
		"name": player.name,
		"age": age,
		"position": position,
		"salary": salary,
		"tier": str(tier["label"]),
		"value": OffseasonService.player_value_score(player),
		"available": true,
		"player_data": data,
	}


static func _candidate_position() -> int:
	var total: int = 0
	for row in POSITION_WEIGHTS:
		total += int((row as Dictionary).get("weight", 0))
	var roll: int = Rng.range_int(1, maxi(1, total))
	var cumulative: int = 0
	for row in POSITION_WEIGHTS:
		var data: Dictionary = row as Dictionary
		cumulative += int(data.get("weight", 0))
		if roll <= cumulative:
			return int(data.get("position", 1))
	return 1


static func _adjusted_center_for_position(base_center: int, position: int) -> int:
	var penalty: int = 0
	if position == 2:
		penalty = FOREIGN_CATCHER_CENTER_PENALTY
	elif position == 4 or position == 6:
		penalty = FOREIGN_MIDDLE_INFIELDER_CENTER_PENALTY
	return clampi(base_center - penalty, 35, 99)


static func _roll_quality_tier() -> Dictionary:
	var roll: int = Rng.roll_percent()
	for tier_row in QUALITY_TIERS:
		var tier: Dictionary = tier_row as Dictionary
		if roll <= int(tier["roll"]):
			return tier
	return QUALITY_TIERS[QUALITY_TIERS.size() - 1] as Dictionary


static func _candidate_aptitudes(position: int) -> Dictionary:
	var aptitudes: Dictionary = {
		"catcher": 0, "first": 0, "second": 0, "third": 0,
		"shortstop": 0, "left": 0, "center": 0, "right": 0,
	}
	if position == 1:
		return aptitudes
	var primary_key: String = str(OffseasonService.POSITION_NAME_BY_ID.get(position, ""))
	if not primary_key.is_empty():
		aptitudes[primary_key] = Rng.range_int(85, 100)
	return aptitudes


static func _state_candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if int(candidate.get("candidate_id", 0)) == candidate_id:
			return candidate
	return {}


static func _active_count_for_team(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or player.is_manager_candidate():
			continue
		count += 1
	return count


static func _foreign_count_for_team(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or player.is_manager_candidate():
			continue
		if player.foreign_player:
			count += 1
	return count


static func _max_player_id(players: Array) -> int:
	var max_id: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.id > max_id:
			max_id = player.id
	return max_id


static func _find_team_by_id(teams: Array, team_id: int) -> PSTeam:
	for row in teams:
		var team: PSTeam = row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null
