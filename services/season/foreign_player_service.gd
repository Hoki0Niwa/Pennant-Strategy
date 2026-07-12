extends RefCounted
class_name ForeignPlayerService

# R4: 外国人選手雇用。
# FAと同じく state 型にし、自軍だけ手動で複数獲得できるようにする。完全自動の
# process_foreign_market は長期検証/CPU用ラッパーとして維持する。

const NamePoolRef = preload("res://services/data/name_pool.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")

const FOREIGN_FA_YEARS: int = 7
const SCOUT_CANDIDATES_PER_REQUEST: int = 4
const MAX_CPU_REQUESTS_PER_TEAM: int = 4
const MAX_FOREIGN_HELD_PER_TEAM: int = 4
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
const REQUEST_POSITIONS: Array = ["any", "starter", "reliever", "catcher", "first", "second", "third", "shortstop", "outfield", "dh"]
const FIELDER_ARCHETYPES: Array = ["balanced", "power", "contact", "discipline", "speed_defense", "defense"]
const PITCHER_ARCHETYPES: Array = ["balanced", "strikeout", "control", "groundball", "stamina"]
const BUDGET_BANDS: Dictionary = {
	"bargain": {"salary_min": 3000, "salary_max": 6000, "centers": [46, 56], "candidate_count": 4, "estimate_downside": 5, "estimate_upside": 5},
	"standard": {"salary_min": 6000, "salary_max": 12000, "centers": [52, 56, 64], "candidate_count": 3, "estimate_downside": 7, "estimate_upside": 3},
	"core": {"salary_min": 12000, "salary_max": 20000, "centers": [60, 64, 72], "candidate_count": 2, "estimate_downside": 12, "estimate_upside": 0},
	"star": {"salary_min": 20000, "salary_max": 40000, "centers": [68, 72, 76], "candidate_count": 1, "estimate_downside": 15, "estimate_upside": 0},
}


static func process_foreign_market(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_foreign_market_state(players, teams, season, user_team_id)
	complete_foreign_market_automatically(state, players, teams, season, user_team_id)
	return finalize_foreign_market(state)


static func create_foreign_market_state(players: Array, _teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	return {
		"version": 3,
		"year": year,
		"user_team_id": user_team_id,
		"complete": false,
		"finalized": false,
		"next_player_id": _max_player_id(players) + 1,
		"next_candidate_id": 1,
		"next_request_id": 1,
		"candidates": [],
		"signings": [],
		"requests": [],
		"user_request": {},
		"user_candidate_ids": [],
	}


static func _ensure_state_v3(state: Dictionary) -> void:
	var max_candidate_id: int = 0
	for candidate_value in state.get("candidates", []) as Array:
		max_candidate_id = maxi(max_candidate_id, int((candidate_value as Dictionary).get("candidate_id", 0)))
	if int(state.get("version", 0)) >= 3:
		# 壊れた/手動編集されたセーブでも、生成先の配列だけは安全に復元する。
		if not state.has("next_candidate_id"):
			state["next_candidate_id"] = max_candidate_id + 1
		if not state.has("next_request_id"):
			state["next_request_id"] = 1
		if not state.has("requests"):
			state["requests"] = []
		if not state.has("user_request"):
			state["user_request"] = {}
		if not state.has("user_candidate_ids"):
			state["user_candidate_ids"] = []
		return
	state["version"] = 3
	state["next_candidate_id"] = max_candidate_id + 1
	state["next_request_id"] = 1
	state["requests"] = []
	state["user_request"] = {}
	state["user_candidate_ids"] = []


static func configure_user_scout_request(state: Dictionary, position: String, archetype: String, budget_band: String) -> Dictionary:
	_ensure_state_v3(state)
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "外国人補強は既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var validation: Dictionary = _validated_request(position, archetype, budget_band)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "message": str(validation.get("message", "スカウト条件が不正です。")), "state": state}
	_close_request_candidates(state, state.get("user_candidate_ids", []) as Array, true)
	var request: Dictionary = {
		"team_id": user_team_id,
		"position": position,
		"archetype": archetype,
		"budget_band": budget_band,
		"method": "user",
	}
	var candidates: Array = _generate_shortlist(state, request)
	var ids: Array = []
	for candidate_value in candidates:
		ids.append(int((candidate_value as Dictionary).get("candidate_id", 0)))
	state["user_request"] = request
	state["user_candidate_ids"] = ids
	return {"ok": true, "state": state, "candidates": candidates}


static func submit_user_foreign_decision(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "外国人補強は既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var candidate: Dictionary = _state_candidate_by_id(state, candidate_id)
	if candidate.is_empty() or not bool(candidate.get("available", true)):
		return {"ok": false, "message": "その外国人候補は選択できません。", "state": state}
	if int(candidate.get("request_team_id", user_team_id)) != user_team_id:
		return {"ok": false, "message": "その候補は他球団向けのスカウト候補です。", "state": state}
	if action == "skip":
		candidate["user_skipped"] = true
		candidate["available"] = false
		_close_user_request_if_done(state)
		return {"ok": true, "state": state}
	if action != "sign":
		return {"ok": false, "message": "不正な外国人補強操作です。", "state": state}
	if not _can_team_sign_foreign(players, state, user_team_id):
		return {"ok": false, "message": "支配下枠または外国人枠が不足しています。", "state": state}
	if not _can_team_afford_foreign(players, teams, user_team_id, candidate):
		var team: PSTeam = _find_team_by_id(teams, user_team_id)
		var room: int = TeamFinance.budget_room(team.funds, TeamFinance.team_payroll(players, user_team_id)) if team != null else 0
		return {"ok": false, "message": "予算が不足しているため外国人選手を獲得できません(残額 %d万円 / 年俸 %d万円)。" % [room, int(candidate.get("salary", 0))], "state": state}
	_apply_signing(state, players, teams, season, candidate, user_team_id, "user")
	_close_request_candidates(state, state.get("user_candidate_ids", []) as Array, false)
	state["user_request"] = {}
	state["user_candidate_ids"] = []
	if not _can_team_sign_foreign(players, state, user_team_id):
		complete_foreign_market_automatically(state, players, teams, season, user_team_id)
	return {"ok": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var best_id: int = 0
	var best_score: float = -999999.0
	var need: Dictionary = FaMarketService._build_position_need(players, teams)
	for row in available_user_candidates(state, players, teams):
		var candidate: Dictionary = row as Dictionary
		if not bool(candidate.get("available", true)):
			continue
		if not _can_team_sign_foreign(players, state, user_team_id):
			break
		if not _can_team_afford_foreign(players, teams, user_team_id, candidate):
			continue
		var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(int(candidate.get("position", 0)), 0.0))
		var score: float = _signing_score(candidate, team_need, players, teams, user_team_id)
		if score > best_score:
			best_score = score
			best_id = int(candidate.get("candidate_id", 0))
	if best_id <= 0:
		return {"ok": false, "message": "現在のスカウト候補に契約可能な選手がいません。", "state": state}
	return submit_user_foreign_decision(state, players, teams, season, best_id, "sign")


static func complete_foreign_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	_ensure_state_v3(state)
	# ユーザーが「補強を終了」した場合、表示中だった候補を市場に残さない。
	if user_team_id > 0:
		_close_request_candidates(state, state.get("user_candidate_ids", []) as Array, true)
		state["user_request"] = {}
		state["user_candidate_ids"] = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == user_team_id:
			continue
		for _request_index in range(MAX_CPU_REQUESTS_PER_TEAM):
			if not _can_team_sign_foreign(players, state, team.id):
				break
			# 直前の獲得を反映し、同じ穴だけを繰り返し補強しないよう毎回再計算する。
			var need: Dictionary = FaMarketService._build_position_need(players, teams)
			var request: Dictionary = _cpu_scout_request(players, team, need)
			var shortlist: Array = _generate_shortlist(state, request)
			var best: Dictionary = {}
			var best_score: float = -999999.0
			for candidate_value in shortlist:
				var candidate: Dictionary = candidate_value as Dictionary
				if not _can_team_afford_foreign(players, teams, team.id, candidate):
					continue
				var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(candidate.get("position", 0)), 0.0))
				var score: float = _signing_score(candidate, team_need, players, teams, team.id)
				if score > best_score:
					best_score = score
					best = candidate
			if best.is_empty():
				_close_request_candidates(state, _candidate_ids(shortlist), true)
				break
			_apply_signing(state, players, teams, season, best, team.id, "cpu")
			_close_request_candidates(state, _candidate_ids(shortlist), false)
	state["complete"] = true
	return {"ok": true, "state": state}


static func complete_all_foreign_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	_ensure_state_v3(state)
	# 手動検索中の候補を閉じてから、自球団を除外せず全チームを同じAIロジックへ流す。
	_close_request_candidates(state, state.get("user_candidate_ids", []) as Array, true)
	state["user_request"] = {}
	state["user_candidate_ids"] = []
	return complete_foreign_market_automatically(state, players, teams, season, 0)


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
	var allowed_ids: Array = state.get("user_candidate_ids", []) as Array
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if not allowed_ids.has(int(candidate.get("candidate_id", 0))):
			continue
		if not bool(candidate.get("available", true)):
			continue
		var copy: Dictionary = candidate.duplicate(true)
		var pos: int = int(candidate.get("position", 0))
		copy["need"] = float((need.get(user_team_id, {}) as Dictionary).get(pos, 0.0))
		copy["can_sign"] = _can_team_sign_foreign(players, state, user_team_id) and _can_team_afford_foreign(players, teams, user_team_id, candidate)
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
	PSCareerLog.log_foreign_join(player, _season.year if _season != null else int(state.get("year", 0)), team_id, player.salary)
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
		"role": player.role,
		"to_team": team_id,
		"salary": player.salary,
		"tier": str(candidate.get("tier", "")),
		"scout_position": str(candidate.get("scout_position", "any")),
		"archetype": str(candidate.get("archetype", "balanced")),
		"budget_band": str(candidate.get("budget_band", "standard")),
		"value": int(candidate.get("value", 0)),
		"method": method,
	})
	state["signings"] = signings


static func _can_team_sign_foreign(players: Array, _state: Dictionary, team_id: int) -> bool:
	if team_id <= 0:
		return false
	var active: int = _active_count_for_team(players, team_id)
	# ドラフトが後段補強用に残した hard 枠を使う。70枠はここで保証する。
	if active >= TeamFinance.SHIENKA_LIMIT:
		return false
	var foreign_total: int = _foreign_count_for_team(players, team_id)
	return foreign_total < MAX_FOREIGN_HELD_PER_TEAM


# 予算ゲート: 年俸を払っても予算内に収まるか。
static func _can_team_afford_foreign(players: Array, teams: Array, team_id: int, candidate: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	return TeamFinance.can_afford_addition(players, team, int(candidate.get("salary", 0)))


static func _signing_score(candidate: Dictionary, team_need: float, players: Array, _teams: Array, team_id: int) -> float:
	var held: int = _foreign_count_for_team(players, team_id)
	var open_slots: int = max(0, MAX_FOREIGN_HELD_PER_TEAM - held)
	# CPUもプレイヤーと同じスカウト情報だけを使い、実能力を透視しない。
	var score: float = float(candidate.get("estimated_value", candidate.get("value", 0))) * (1.0 + team_need / 20.0)
	score += float(open_slots) * FOREIGN_SLOT_FILL_BONUS
	return score


static func _generate_candidate(candidate_id: int, year: int, request: Dictionary = {}) -> Dictionary:
	var scout_position: String = str(request.get("position", "any"))
	var archetype: String = str(request.get("archetype", "balanced"))
	var budget_band: String = str(request.get("budget_band", "standard"))
	var position: int = int(request.get("resolved_position", 0))
	if position <= 0:
		position = _position_for_request(scout_position)
	var tier: Dictionary = _tier_for_budget(budget_band)
	var center: int = _adjusted_center_for_position(int(tier["center"]), position)
	var age: int = Rng.range_int(CANDIDATE_MIN_AGE, CANDIDATE_MAX_AGE)
	var z_abilities: Dictionary = OffseasonService.generated_z_abilities(position, center, min(center + 10, 99))
	_apply_archetype(z_abilities, position, archetype)
	var arsenal: Array = OffseasonService.generated_arsenal(position, z_abilities)
	var band: Dictionary = BUDGET_BANDS.get(budget_band, BUDGET_BANDS["standard"]) as Dictionary
	var salary: int = Rng.range_int(int(band.get("salary_min", 6000)), int(band.get("salary_max", 12000)))
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
		"role": "" if position == 1 else "fielder",
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
		"source_data": {
			"foreign_scout": true,
			"foreign_signed_year": year,
			"quality_tier": str(tier["label"]),
			"scout_position": scout_position,
			"foreign_archetype": archetype,
			"foreign_budget_band": budget_band,
		},
		"fatigue": 0,
		"injury_days": 0,
		"z_abilities": z_abilities,
		"raw_abilities": OffseasonService.generated_raw_abilities(position, z_abilities),
		"arsenal": arsenal,
	}
	if position == 1:
		data["role"] = scout_position if scout_position == "starter" or scout_position == "reliever" else _initial_pitcher_role(data)
	var player: PSPlayer = PSPlayer.from_dict(data)
	var actual_value: int = OffseasonService.player_value_score(player)
	var estimate_downside: int = int(band.get("estimate_downside", 7))
	var estimate_upside: int = int(band.get("estimate_upside", 3))
	var display_data: Dictionary = _scouted_player_data(data, estimate_downside, estimate_upside)
	var estimated_value: int = OffseasonService.player_value_score(PSPlayer.from_dict(display_data))
	return {
		"candidate_id": candidate_id,
		"name": player.name,
		"age": age,
		"position": position,
		"role": player.role,
		"salary": salary,
		"tier": str(tier["label"]),
		"value": actual_value,
		"estimated_value": estimated_value,
		"estimate_min": maxi(1, estimated_value - estimate_downside),
		"estimate_max": mini(99, estimated_value + estimate_upside),
		"estimate_downside": estimate_downside,
		"estimate_upside": estimate_upside,
		"uncertainty": maxi(estimate_downside, estimate_upside),
		"scout_position": scout_position,
		"archetype": archetype,
		"budget_band": budget_band,
		"scout_comment": _scout_comment(position, archetype, estimate_downside, estimate_upside),
		"request_team_id": int(request.get("team_id", 0)),
		"request_id": int(request.get("request_id", 0)),
		"available": true,
		"player_data": data,
		"display_player_data": display_data,
	}


static func _generate_shortlist(state: Dictionary, request_value: Dictionary) -> Array:
	var request: Dictionary = request_value.duplicate(true)
	# おまかせでも1回の依頼内は同じ守備区分に揃え、候補表の能力列を統一する。
	if str(request.get("position", "any")) == "any":
		request["resolved_position"] = _candidate_position()
	var request_id: int = int(state.get("next_request_id", 1))
	state["next_request_id"] = request_id + 1
	request["request_id"] = request_id
	var shortlist: Array = []
	for _i in range(scout_candidate_count(str(request.get("budget_band", "standard")))):
		var candidate_id: int = int(state.get("next_candidate_id", 1))
		state["next_candidate_id"] = candidate_id + 1
		var candidate: Dictionary = _generate_candidate(candidate_id, int(state.get("year", 0)), request)
		shortlist.append(candidate)
		(state.get("candidates", []) as Array).append(candidate)
	var request_log: Dictionary = request.duplicate(true)
	request_log["candidate_ids"] = _candidate_ids(shortlist)
	(state.get("requests", []) as Array).append(request_log)
	return shortlist


static func scout_candidate_count(budget_band: String) -> int:
	var band: Dictionary = BUDGET_BANDS.get(budget_band, BUDGET_BANDS["standard"]) as Dictionary
	return clampi(int(band.get("candidate_count", SCOUT_CANDIDATES_PER_REQUEST)), 1, SCOUT_CANDIDATES_PER_REQUEST)


static func _validated_request(position: String, archetype: String, budget_band: String) -> Dictionary:
	if not REQUEST_POSITIONS.has(position):
		return {"ok": false, "message": "希望ポジションが不正です。"}
	if not BUDGET_BANDS.has(budget_band):
		return {"ok": false, "message": "予算帯が不正です。"}
	var pitcher_request: bool = position == "starter" or position == "reliever"
	if pitcher_request and not PITCHER_ARCHETYPES.has(archetype):
		return {"ok": false, "message": "投手向けの選手タイプを選択してください。"}
	if not pitcher_request and position != "any" and not FIELDER_ARCHETYPES.has(archetype):
		return {"ok": false, "message": "野手向けの選手タイプを選択してください。"}
	if position == "any" and archetype != "balanced":
		return {"ok": false, "message": "おまかせ検索ではバランス型を選択してください。"}
	return {"ok": true}


static func _cpu_scout_request(players: Array, team: PSTeam, need: Dictionary) -> Dictionary:
	var team_need: Dictionary = need.get(team.id, {}) as Dictionary
	var desired_position: int = 1
	var highest_need: float = -999999.0
	for position_value in range(1, 10):
		var position_need: float = float(team_need.get(position_value, 0.0))
		if position_need > highest_need:
			highest_need = position_need
			desired_position = position_value
	var position_key: String = _request_key_for_position(players, team.id, desired_position)
	var archetype: String = _weakest_archetype(players, team.id, position_key)
	var room: int = TeamFinance.budget_room(team.funds, TeamFinance.team_payroll(players, team.id))
	var budget_band: String = "bargain"
	# 帯の上限まで払える場合だけ上位帯へ進み、抽選結果だけで全員予算超過になるのを避ける。
	if room >= 40000:
		budget_band = "star"
	elif room >= 20000:
		budget_band = "core"
	elif room >= 12000:
		budget_band = "standard"
	return {
		"team_id": team.id,
		"position": position_key,
		"archetype": archetype,
		"budget_band": budget_band,
		"method": "cpu",
	}


static func _request_key_for_position(players: Array, team_id: int, position: int) -> String:
	if position == 1:
		var starters: int = 0
		var relievers: int = 0
		for player_value in players:
			var player: PSPlayer = player_value as PSPlayer
			if player == null or player.team_id != team_id or player.is_retired() or not player.is_pitcher():
				continue
			if player.role == "starter":
				starters += 1
			else:
				relievers += 1
		return "starter" if starters < 6 or starters * 2 < relievers else "reliever"
	match position:
		2: return "catcher"
		3: return "first"
		4: return "second"
		5: return "third"
		6: return "shortstop"
		_: return "outfield"


static func _weakest_archetype(players: Array, team_id: int, position_key: String) -> String:
	if position_key == "starter" or position_key == "reliever":
		var pitcher_scores: Dictionary = {
			"strikeout": _team_ability_average(players, team_id, ["Pit_KCreate"], true),
			"control": _team_ability_average(players, team_id, ["Pit_BBPrevent", "Pit_EdgeRate"], true),
			"groundball": _team_ability_average(players, team_id, ["Pit_LoftControl", "Pit_BarrelDeny"], true),
			"stamina": _team_ability_average(players, team_id, ["Pit_Stamina", "Pit_FatigueResist"], true),
		}
		return _lowest_score_key(pitcher_scores)
	var fielder_scores: Dictionary = {
		"power": _team_ability_average(players, team_id, ["Bat_Impact", "Bat_Loft"], false),
		"contact": _team_ability_average(players, team_id, ["Bat_KAvoid", "Bat_Barrel"], false),
		"discipline": _team_ability_average(players, team_id, ["Bat_BBCreate"], false),
		"speed_defense": _team_ability_average(players, team_id, ["Run_Speed", "Run_Judgment", "IF_Reach", "OF_Reach"], false),
		"defense": _team_ability_average(players, team_id, ["IF_Secure", "OF_Secure", "C_FieldSecure"], false),
	}
	return _lowest_score_key(fielder_scores)


static func _team_ability_average(players: Array, team_id: int, keys: Array, pitchers: bool) -> float:
	var total: float = 0.0
	var count: int = 0
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or player.development_player:
			continue
		if player.is_pitcher() != pitchers:
			continue
		for key_value in keys:
			var key: String = str(key_value)
			if player.z_abilities.has(key):
				total += float(player.z_abilities[key])
				count += 1
	return total / float(count) if count > 0 else 0.0


static func _lowest_score_key(scores: Dictionary) -> String:
	var best_key: String = "balanced"
	var best_value: float = INF
	for key_value in scores.keys():
		var value: float = float(scores[key_value])
		if value < best_value:
			best_value = value
			best_key = str(key_value)
	return best_key


static func _position_for_request(position_key: String) -> int:
	match position_key:
		"starter", "reliever": return 1
		"catcher": return 2
		"first", "dh": return 3
		"second": return 4
		"third": return 5
		"shortstop": return 6
		"outfield": return [7, 8, 9][Rng.range_int(0, 2)]
		_: return _candidate_position()


static func _tier_for_budget(budget_band: String) -> Dictionary:
	var band: Dictionary = BUDGET_BANDS.get(budget_band, BUDGET_BANDS["standard"]) as Dictionary
	var centers: Array = band.get("centers", [56]) as Array
	var center: int = int(centers[Rng.range_int(0, centers.size() - 1)])
	var label: String = "bust" if center < 52 else "average" if center < 60 else "good" if center < 68 else "ace"
	return {"center": center, "label": label}


static func _apply_archetype(z: Dictionary, _position: int, archetype: String) -> void:
	var bonuses: Dictionary = {}
	match archetype:
		"power": bonuses = {"Bat_Impact": 0.9, "Bat_Loft": 0.55, "Bat_KAvoid": -0.2}
		"contact": bonuses = {"Bat_KAvoid": 0.8, "Bat_Barrel": 0.5, "Bat_Impact": -0.15}
		"discipline": bonuses = {"Bat_BBCreate": 0.9, "Bat_KAvoid": 0.25}
		"speed_defense": bonuses = {"Run_Speed": 0.75, "Run_Judgment": 0.45, "IF_Reach": 0.45, "OF_Reach": 0.45, "Bat_Impact": -0.2}
		"defense": bonuses = {"C_FieldSecure": 0.65, "C_Framing": 0.65, "IF_Secure": 0.65, "IF_Reach": 0.45, "OF_Secure": 0.65, "OF_Route": 0.55, "Bat_Impact": -0.2}
		"strikeout": bonuses = {"Pit_KCreate": 0.85, "Pit_BarrelDeny": 0.25}
		"control": bonuses = {"Pit_BBPrevent": 0.85, "Pit_EdgeRate": 0.6}
		"groundball": bonuses = {"Pit_LoftControl": 0.85, "Pit_BarrelDeny": 0.4}
		"stamina": bonuses = {"Pit_Stamina": 0.85, "Pit_FatigueResist": 0.55, "Pit_Efficiency": 0.25}
	for key_value in bonuses.keys():
		var key: String = str(key_value)
		if z.has(key):
			z[key] = clampf(float(z[key]) + float(bonuses[key]), -3.5, 4.0)
	# 捕手・内野・外野で存在しない守備群のボーナスは無視される。


static func _scouted_player_data(data: Dictionary, estimate_downside: int, estimate_upside: int) -> Dictionary:
	var display: Dictionary = data.duplicate(true)
	var source_z: Dictionary = data.get("z_abilities", {}) as Dictionary
	var noisy_z: Dictionary = source_z.duplicate(true)
	var z_downside: float = float(estimate_downside) / PSAbilityScale.DISPLAY_STDEV
	var z_upside: float = float(estimate_upside) / PSAbilityScale.DISPLAY_STDEV
	for key_value in noisy_z.keys():
		var key: String = str(key_value)
		# 表示値−真値を [-upside, downside] に置く。高額帯は downside のみなので表示が天井になる。
		var display_shift: float = -z_upside + Rng.roll_float() * (z_downside + z_upside)
		noisy_z[key] = clampf(float(noisy_z[key]) + display_shift, -3.5, 4.0)
	display["z_abilities"] = noisy_z
	display["raw_abilities"] = OffseasonService.generated_raw_abilities(int(data.get("position", 1)), noisy_z)
	return display


static func _scout_comment(position: int, archetype: String, estimate_downside: int, estimate_upside: int) -> String:
	var type_text: Dictionary = {
		"balanced": "総合力型", "power": "長打力重視", "contact": "コンタクト重視",
		"discipline": "選球眼重視", "speed_defense": "走守重視", "defense": "守備重視",
		"strikeout": "奪三振力重視", "control": "制球力重視", "groundball": "ゴロを打たせるタイプ", "stamina": "持久力重視",
	}
	var range_text: String = "表示値から-%d〜+%d" % [estimate_downside, estimate_upside]
	if estimate_upside <= 0:
		range_text = "表示値を上限に0〜-%d" % estimate_downside
	return "%s。評価幅は%s。%s候補。" % [str(type_text.get(archetype, "バランス型")), range_text, "投手" if position == 1 else "野手"]


static func _candidate_ids(candidates: Array) -> Array:
	var ids: Array = []
	for candidate_value in candidates:
		ids.append(int((candidate_value as Dictionary).get("candidate_id", 0)))
	return ids


static func _close_request_candidates(state: Dictionary, ids: Array, skipped: bool) -> void:
	for id_value in ids:
		var candidate: Dictionary = _state_candidate_by_id(state, int(id_value))
		if candidate.is_empty() or bool(candidate.get("signed", false)):
			continue
		candidate["available"] = false
		if skipped:
			candidate["user_skipped"] = true


static func _close_user_request_if_done(state: Dictionary) -> void:
	for id_value in state.get("user_candidate_ids", []) as Array:
		var candidate: Dictionary = _state_candidate_by_id(state, int(id_value))
		if not candidate.is_empty() and bool(candidate.get("available", false)):
			return
	state["user_request"] = {}
	state["user_candidate_ids"] = []


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


static func _initial_pitcher_role(player_data: Dictionary) -> String:
	var neutral_data: Dictionary = player_data.duplicate(true)
	neutral_data["role"] = ""
	return PitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral_data))


static func _state_candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var candidate: Dictionary = row as Dictionary
		if int(candidate.get("candidate_id", 0)) == candidate_id:
			return candidate
	return {}


# roadmap #3: 支配下枠 (育成除外) の人数。計数の単一ソースは TeamFinance。
static func _active_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.shienka_count(players, team_id)


static func _foreign_count_for_team(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
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
