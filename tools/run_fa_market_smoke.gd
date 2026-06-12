extends Node

# R4: 簡易FA / 自由契約市場のスモークテスト。
#  - FA宣言はレギュラー級に限定され、年間10人前後に絞られる。
#  - 新規FA権取得者は宣言しやすく、見送り回数が増えると宣言率が下がる。
#  - A/B/Cランクと金銭補償が設定され、補償率はFA回数にかかわらず固定。
#  - 自軍がFA候補と交渉でき、成否は確率で決まる。
#  - 能力・成績が良いFAほど契約成功率が低い。
#  - 未獲得FAは元チームに残留し、孤立free_agentが残らない。
#  - team_id / source_data マーカーの to_dict/from_dict 往復。

const Offseason = preload("res://services/season/offseason_service.gd")
const FaMarket = preload("res://services/season/fa_market_service.gd")

var _next_id: int = 1


func _ready() -> void:
	Rng.set_seed_value(20260605)
	var ok: bool = true

	ok = _test_regular_declaration_target() and ok
	ok = _test_fifteen_year_declaration_average() and ok
	ok = _test_fa_rank_and_money_compensation() and ok
	ok = _test_declaration_chance_and_pass_count() and ok
	ok = _test_contract_chance_inverse_to_quality() and ok
	ok = _test_user_manual_signing() and ok
	ok = _test_unsigned_returns() and ok
	ok = _test_roundtrip() and ok

	print("FA market smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


func _test_regular_declaration_target() -> bool:
	var ok: bool = true
	var teams: Array = []
	var players: Array = []
	for t in range(1, 13):
		teams.append(_team(t, 100000))
		# 各球団にFA権持ち主力2人 + 控え1人。控えは宣言対象外。
		players.append(_mark_fa_tracking(_make_player(_id(), 6, 76, 8, t), 2026, 0))
		players.append(_mark_fa_tracking(_make_player(_id(), 1, 74, 8, t), 2026, 0))
		players.append(_mark_fa_tracking(_make_player(_id(), 7, 45, 8, t), 2026, 0))
	var state: Dictionary = FaMarket.create_fa_market_state(players, teams, _season(2026), 1)
	var declared: Array = state.get("declared", []) as Array
	ok = _expect(declared.size() <= FaMarket.TARGET_DECLARATIONS, "declared capped near target (got %d)" % declared.size(), ok)
	ok = _expect(declared.size() >= 8, "enough regular-class declarations (got %d)" % declared.size(), ok)
	for row in declared:
		ok = _expect(int((row as Dictionary).get("value", 0)) >= 68, "declared player is regular-class", ok)
	return ok


func _test_fifteen_year_declaration_average() -> bool:
	var ok: bool = true
	var total_declared: int = 0
	for y in range(15):
		var teams: Array = []
		var players: Array = []
		for t in range(1, 13):
			teams.append(_team(t, 100000))
			players.append(_mark_fa_tracking(_make_player(_id(), 6, 76, 8, t), 2026 + y, 0))
			players.append(_mark_fa_tracking(_make_player(_id(), 1, 74, 8, t), 2026 + y, 0))
			players.append(_mark_fa_tracking(_make_player(_id(), 7, 45, 8, t), 2026 + y, 0))
		var state: Dictionary = FaMarket.create_fa_market_state(players, teams, _season(2026 + y), 0)
		total_declared += (state.get("declared", []) as Array).size()
	var average: float = float(total_declared) / 15.0
	ok = _expect(average >= 8.0 and average <= 12.0, "15-year FA declaration average near 10 (got %.2f)" % average, ok)
	return ok


func _test_fa_rank_and_money_compensation() -> bool:
	var ok: bool = true
	var players: Array = []
	var salaries: Array = [20000, 18000, 16000, 14000, 12000, 10000, 9000, 8000, 7000, 6000, 5000]
	for i in range(salaries.size()):
		var p: PSPlayer = _make_player(_id(), 6, 76 if i in [0, 4, 10] else 55, 8, 1)
		p.salary = int(salaries[i])
		p.source_data["fa_nissuu"] = 1000 - i
		players.append(p)
	var rank_by_id: Dictionary = FaMarket._build_fa_rank_by_player_id(players)
	ok = _expect(FaMarket._fa_rank_for_salary_rank(int(rank_by_id.get((players[0] as PSPlayer).id, 0))) == "A", "salary rank 1 is A", ok)
	ok = _expect(FaMarket._fa_rank_for_salary_rank(int(rank_by_id.get((players[4] as PSPlayer).id, 0))) == "B", "salary rank 5 is B", ok)
	ok = _expect(FaMarket._fa_rank_for_salary_rank(int(rank_by_id.get((players[10] as PSPlayer).id, 0))) == "C", "salary rank 11 is C", ok)
	ok = _expect(FaMarket._compensation_money("A", 10000) == 8000, "A rank compensation is fixed 80%", ok)
	ok = _expect(FaMarket._compensation_money("B", 10000) == 6000, "B rank compensation is fixed 60%", ok)
	ok = _expect(FaMarket._compensation_money("C", 10000) == 0, "C rank compensation is zero", ok)
	ok = _expect(FaMarket._compensation_money("A", 10000) == FaMarket._compensation_money("A", 10000), "compensation does not depend on FA move count", ok)
	return ok


func _test_declaration_chance_and_pass_count() -> bool:
	var ok: bool = true
	var new_fa: PSPlayer = _mark_fa_tracking(_make_player(_id(), 6, 76, 8, 1), 2026, 0)
	var old_fa: PSPlayer = _mark_fa_tracking(_make_player(_id(), 6, 76, 8, 1), 2024, 2)
	var new_chance: float = FaMarket._declaration_chance(new_fa, 2026)
	var old_chance: float = FaMarket._declaration_chance(old_fa, 2026)
	ok = _expect(new_chance > old_chance, "new FA eligible player has higher declaration chance", ok)

	var teams: Array = [_team(1, 100000)]
	var pass_player: PSPlayer = _make_player(_id(), 7, 45, 8, 1)
	_mark_fa_tracking(pass_player, 2026, 0)
	var players: Array = [pass_player]
	var state: Dictionary = FaMarket.create_fa_market_state(players, teams, _season(2026), 0)
	FaMarket.finalize_fa_market(state, players, _season(2026))
	ok = _expect(int(pass_player.source_data.get("fa_pass_count", 0)) == 1, "non-declared FA pass count increments", ok)
	var after_pass_chance: float = FaMarket._declaration_chance(pass_player, 2027)
	ok = _expect(after_pass_chance < new_chance, "declaration chance decreases after pass", ok)
	return ok


func _test_user_manual_signing() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000)]
	var players: Array = []
	players.append(_mark_fa_tracking(_make_player(_id(), 6, 76, 8, 1), 2026, 0))
	players.append(_mark_fa_tracking(_make_player(_id(), 1, 74, 8, 1), 2026, 0))
	players.append(_make_player(_id(), 6, 40, 3, 2))
	for pos in [2, 3, 4, 5, 7, 8, 9, 1]:
		players.append(_make_player(_id(), pos, 55, 3, 1))
		players.append(_make_player(_id(), pos, 55, 3, 2))

	var state: Dictionary = FaMarket.create_fa_market_state(players, teams, _season(2026), 2)
	var candidates: Array = FaMarket.available_user_candidates(state, players, teams)
	ok = _expect(not candidates.is_empty(), "user has FA candidates", ok)
	if candidates.is_empty():
		return ok
	var candidate_id: int = int((candidates[0] as Dictionary).get("player_id", 0))
	var result: Dictionary = FaMarket.submit_user_fa_decision(state, players, teams, _season(2026), candidate_id, "sign")
	ok = _expect(bool(result.get("ok", false)), "manual FA negotiation resolved", ok)
	var target: PSPlayer = _find(players, candidate_id)
	if bool(result.get("acquired", false)):
		ok = _expect(target != null and target.team_id == 2, "successful FA negotiation moved to user team", ok)
		ok = _expect(target != null and not bool(target.source_data.get("free_agent", false)), "free_agent flag cleared on success", ok)
		ok = _expect(target != null and int(target.source_data.get("fa_contract_salary", 0)) == target.salary, "FA contract salary recorded on success", ok)
	else:
		var failures: Array = state.get("failed_negotiations", []) as Array
		ok = _expect(not failures.is_empty(), "failed FA negotiation recorded", ok)
		ok = _expect(target != null and target.team_id == 0, "failed negotiation leaves player in FA pool until finalize", ok)
	return ok


func _test_contract_chance_inverse_to_quality() -> bool:
	var ok: bool = true
	var low: Dictionary = {
		"value": 68,
		"war": 0.0,
		"games": 90,
		"plate_appearances": 300,
		"starts": 0,
		"relief_appearances": 0,
		"outs_pitched": 0,
	}
	var high: Dictionary = {
		"value": 86,
		"war": 5.0,
		"games": 143,
		"plate_appearances": 620,
		"starts": 0,
		"relief_appearances": 0,
		"outs_pitched": 0,
	}
	var low_chance: float = FaMarket._contract_success_chance(low, 0.0, "user")
	var high_chance: float = FaMarket._contract_success_chance(high, 0.0, "user")
	ok = _expect(high_chance < low_chance, "elite FA has lower signing chance (low=%.3f high=%.3f)" % [low_chance, high_chance], ok)
	ok = _expect(high_chance >= FaMarket.FA_SIGN_CHANCE_MIN, "elite chance stays within lower clamp", ok)
	return ok


func _test_unsigned_returns() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000)]
	var players: Array = []
	var fa_player: PSPlayer = _mark_fa_tracking(_make_player(_id(), 6, 76, 8, 1), 2026, 0)
	var fa_id: int = fa_player.id
	players.append(fa_player)
	players.append(_make_player(_id(), 6, 74, 3, 2))
	for pos in [2, 3, 4, 5, 7, 8, 9, 1]:
		players.append(_make_player(_id(), pos, 55, 3, 1))
		players.append(_make_player(_id(), pos, 55, 3, 2))
	var state: Dictionary = FaMarket.create_fa_market_state(players, teams, _season(2026), 0)
	var final_result: Dictionary = FaMarket.finalize_fa_market(state, players, _season(2026))
	var found: PSPlayer = _find(players, fa_id)
	ok = _expect(found != null and found.team_id == 1, "unsigned FA returned to original team", ok)
	ok = _expect(found != null and int(found.source_data.get("fa_contract_salary", 0)) == found.salary, "FA contract salary recorded on return", ok)
	ok = _expect(int(final_result.get("returned_count", 0)) >= 1, "returned count recorded", ok)
	ok = _expect(_count_orphans(players) == 0, "no orphan free agents left", ok)
	return ok


func _test_roundtrip() -> bool:
	var ok: bool = true
	var p: PSPlayer = _make_player(_id(), 6, 70, 8, 5)
	p.source_data["fa_from_team"] = 3
	p.source_data["fa_signed_year"] = 2026
	p.source_data["fa_contract_salary"] = 4200
	p.source_data["fa_eligible_year"] = 2026
	p.source_data["fa_pass_count"] = 0
	var p2: PSPlayer = PSPlayer.from_dict(p.to_dict())
	ok = _expect(p2.team_id == 5, "team_id roundtrip", ok)
	ok = _expect(int(p2.source_data.get("fa_signed_year", 0)) == 2026, "fa_signed_year roundtrip", ok)
	ok = _expect(int(p2.source_data.get("fa_contract_salary", 0)) == 4200, "fa_contract_salary roundtrip", ok)
	ok = _expect(int(p2.source_data.get("fa_eligible_year", 0)) == 2026, "fa_eligible_year roundtrip", ok)
	ok = _expect(int(p2.source_data.get("fa_from_team", 0)) == 3, "fa_from_team roundtrip", ok)
	return ok


func _id() -> int:
	var v: int = _next_id
	_next_id += 1
	return v


func _team(id: int, funds: int) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "short_name": "T%d" % id, "league": "central", "funds": funds})


func _season(year: int) -> PSSeason:
	var s: PSSeason = PSSeason.new()
	s.year = year
	s.season_number = 1
	return s


func _make_player(player_id: int, position: int, center: int, fa_years: int, team_id: int) -> PSPlayer:
	return PSPlayer.from_dict({
		"id": player_id,
		"sensyu_num": player_id,
		"team_id": team_id,
		"name": "FA%d" % player_id,
		"age": 30,
		"years": 10,
		"position": position,
		"role": "starter" if position == 1 else "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 3000,
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"fa_eligible_years": fa_years,
		"position_aptitudes": {Offseason.POSITION_NAME_BY_ID.get(position, "first"): 100},
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, center, min(center + 8, 99)),
		"fatigue": 0,
		"injury_days": 0,
	})


func _mark_fa_tracking(player: PSPlayer, eligible_year: int, pass_count: int) -> PSPlayer:
	player.source_data["fa_eligible_year"] = eligible_year
	player.source_data["fa_pass_count"] = pass_count
	return player


func _find(players: Array, player_id: int) -> PSPlayer:
	for row in players:
		var player: PSPlayer = row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


func _count_orphans(players: Array) -> int:
	var c: int = 0
	for row in players:
		var player: PSPlayer = row as PSPlayer
		if player.team_id <= 0 or bool(player.source_data.get("free_agent", false)):
			c += 1
	return c


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[fa_market] FAIL: %s" % label)
		return false
	return running_ok
