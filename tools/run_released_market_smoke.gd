extends Node

# 戦力外獲得市場のスモークテスト。
#  - 戦力外結果から候補を生成し、自軍が切った選手は自軍候補から除外。
#  - ユーザー獲得で team_id を戻し、retired/released を解除。
#  - 引退ステップの本物の引退者は、戦力外結果に混ざっても獲得候補にしない。
#  - CPU自動獲得は70人枠を超えず、未獲得者は引退扱いのまま残る。

const Offseason = preload("res://services/season/offseason_service.gd")
const ReleasedMarket = preload("res://services/season/released_market_service.gd")

var _next_id: int = 1


func _ready() -> void:
	Rng.set_seed_value(20260610)
	var ok: bool = true

	ok = _test_user_candidates_and_signing() and ok
	ok = _test_true_retired_players_are_not_candidates() and ok
	ok = _test_cpu_auto_and_roster_limit() and ok
	ok = _test_finalize_leaves_unsigned_retired() and ok

	print("Released market smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


func _test_user_candidates_and_signing() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000), _team(3, 100000)]
	var players: Array = []
	var own_cut: PSPlayer = _released_player(_id(), 6, 60, 1)
	var other_cut: PSPlayer = _released_player(_id(), 1, 66, 2)
	players.append(own_cut)
	players.append(other_cut)
	_add_roster(players, 1, 20, 52)
	_add_roster(players, 2, 20, 52)
	_add_roster(players, 3, 20, 52)
	var release_result: Dictionary = {"released": [
		_release_row(own_cut, 1),
		_release_row(other_cut, 2),
	]}
	var state: Dictionary = ReleasedMarket.create_released_market_state(players, teams, _season(2026), release_result, 1)
	var candidates: Array = ReleasedMarket.available_user_candidates(state, players, teams)
	ok = _expect(candidates.size() == 1, "user can only see other-team released player (got %d)" % candidates.size(), ok)
	if candidates.is_empty():
		return ok
	var candidate_id: int = int((candidates[0] as Dictionary).get("player_id", 0))
	var result: Dictionary = ReleasedMarket.submit_user_released_decision(state, players, teams, _season(2026), candidate_id, "sign")
	ok = _expect(bool(result.get("ok", false)), "manual released signing succeeds", ok)
	ok = _expect(other_cut.team_id == 1, "signed released player moved to user team", ok)
	ok = _expect(not other_cut.is_retired(), "signed released player is no longer retired", ok)
	ok = _expect(not bool(other_cut.source_data.get("released", false)), "released flag cleared on signing", ok)
	ok = _expect(own_cut.team_id == 0 and own_cut.is_retired(), "own released player remains unsigned/retired", ok)
	return ok


func _test_true_retired_players_are_not_candidates() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000), _team(3, 100000)]
	var players: Array = []
	var real_retired: PSPlayer = _retired_player(_id(), 6, 61)
	var actual_cut: PSPlayer = _released_player(_id(), 7, 62, 2)
	players.append(real_retired)
	players.append(actual_cut)
	_add_roster(players, 1, 20, 52)
	_add_roster(players, 2, 20, 52)
	_add_roster(players, 3, 20, 52)
	var release_result: Dictionary = {"released": [
		_release_row(real_retired, 2),
		_release_row(actual_cut, 2),
	]}
	var state: Dictionary = ReleasedMarket.create_released_market_state(players, teams, _season(2026), release_result, 1)
	var candidates: Array = state.get("candidates", []) as Array
	ok = _expect(candidates.size() == 1, "true retired player excluded from market candidates (got %d)" % candidates.size(), ok)
	if not candidates.is_empty():
		ok = _expect(int((candidates[0] as Dictionary).get("player_id", 0)) == actual_cut.id, "only actual released player remains candidate", ok)

	var stale_state: Dictionary = {
		"version": 1,
		"year": 2026,
		"user_team_id": 1,
		"complete": false,
		"finalized": false,
		"candidates": [{
			"player_id": real_retired.id,
			"name": real_retired.name,
			"age": real_retired.age,
			"position": real_retired.position,
			"from_team": 2,
			"salary": real_retired.salary,
			"value": Offseason.player_value_score(real_retired),
			"war": 0.0,
			"available": true,
		}],
		"signings": [],
	}
	var result: Dictionary = ReleasedMarket.submit_user_released_decision(stale_state, players, teams, _season(2026), real_retired.id, "sign")
	ok = _expect(not bool(result.get("ok", false)), "stale state cannot sign true retired player", ok)
	ok = _expect(real_retired.team_id == 0 and real_retired.is_retired(), "true retired player remains retired after rejected signing", ok)
	ReleasedMarket.complete_released_market_automatically(stale_state, players, teams, _season(2026), 1)
	ok = _expect((stale_state.get("signings", []) as Array).is_empty(), "CPU auto does not sign true retired player from stale state", ok)
	return ok


func _test_cpu_auto_and_roster_limit() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000), _team(3, 100000)]
	var players: Array = []
	var cut_a: PSPlayer = _released_player(_id(), 6, 70, 1)
	var cut_b: PSPlayer = _released_player(_id(), 2, 68, 2)
	players.append(cut_a)
	players.append(cut_b)
	_add_roster(players, 1, ReleasedMarket.ROSTER_LIMIT, 50)
	_add_roster(players, 2, 65, 50)
	_add_roster(players, 3, 65, 50)
	var release_result: Dictionary = {"released": [
		_release_row(cut_a, 1),
		_release_row(cut_b, 2),
	]}
	var state: Dictionary = ReleasedMarket.create_released_market_state(players, teams, _season(2026), release_result, 0)
	var result: Dictionary = ReleasedMarket.complete_released_market_automatically(state, players, teams, _season(2026), 0)
	ok = _expect(bool(result.get("ok", false)), "CPU released market completes", ok)
	ok = _expect(_active_count(players, 1) <= ReleasedMarket.ROSTER_LIMIT, "full team did not exceed roster limit", ok)
	for row in state.get("signings", []) as Array:
		ok = _expect(int((row as Dictionary).get("to_team", 0)) != 1, "CPU did not sign into full roster", ok)
	return ok


func _test_finalize_leaves_unsigned_retired() -> bool:
	var ok: bool = true
	var teams: Array = [_team(1, 100000), _team(2, 100000)]
	var players: Array = []
	var cut: PSPlayer = _released_player(_id(), 7, 45, 2)
	players.append(cut)
	_add_roster(players, 1, ReleasedMarket.ROSTER_LIMIT, 50)
	_add_roster(players, 2, ReleasedMarket.ROSTER_LIMIT, 50)
	var release_result: Dictionary = {"released": [_release_row(cut, 2)]}
	var state: Dictionary = ReleasedMarket.create_released_market_state(players, teams, _season(2026), release_result, 1)
	var result: Dictionary = ReleasedMarket.finalize_released_market(state)
	ok = _expect(int(result.get("remaining_count", 0)) == 1, "unsigned remaining count recorded", ok)
	ok = _expect(cut.team_id == 0 and cut.is_retired(), "unsigned released player remains retired", ok)
	return ok


func _team(id: int, funds: int) -> PSTeam:
	return PSTeam.from_dict({"id": id, "name": "T%d" % id, "short_name": "T%d" % id, "league": "central", "funds": funds})


func _season(year: int) -> PSSeason:
	var s: PSSeason = PSSeason.new()
	s.year = year
	s.season_number = 1
	return s


func _released_player(player_id: int, position: int, center: int, from_team: int) -> PSPlayer:
	var p: PSPlayer = _player(player_id, position, center, 0)
	p.source_data["released"] = true
	p.source_data["retired"] = true
	p.source_data["retired_age"] = p.age
	p.source_data["released_from_team"] = from_team
	return p


func _retired_player(player_id: int, position: int, center: int) -> PSPlayer:
	var p: PSPlayer = _player(player_id, position, center, 0)
	p.source_data["retired"] = true
	p.source_data["retired_age"] = p.age
	return p


func _player(player_id: int, position: int, center: int, team_id: int) -> PSPlayer:
	return PSPlayer.from_dict({
		"id": player_id,
		"sensyu_num": player_id,
		"team_id": team_id,
		"name": "R%d" % player_id,
		"age": 30,
		"years": 8,
		"position": position,
		"role": "starter" if position == 1 else "fielder",
		"throws": "R",
		"bats": "R",
		"salary": 1500,
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": false,
		"fa_eligible_years": 8,
		"position_aptitudes": {Offseason.POSITION_NAME_BY_ID.get(position, "first"): 100},
		"source_data": {},
		"z_abilities": Offseason.generated_z_abilities(position, center, min(center + 8, 99)),
		"fatigue": 0,
		"injury_days": 0,
	})


func _add_roster(players: Array, team_id: int, count: int, center: int) -> void:
	for i in range(count):
		var position: int = 1 if i % 5 == 0 else 2 + (i % 8)
		players.append(_player(_id(), position, center, team_id))


func _release_row(player: PSPlayer, from_team: int) -> Dictionary:
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"team_id": from_team,
		"position": player.position,
		"overall": Offseason.player_value_score(player),
		"years": player.years,
		"salary": player.salary,
	}


func _active_count(players: Array, team_id: int) -> int:
	var count: int = 0
	for row in players:
		var p: PSPlayer = row as PSPlayer
		if p != null and p.team_id == team_id and not p.is_retired() and not p.is_manager_candidate():
			count += 1
	return count


func _id() -> int:
	var v: int = _next_id
	_next_id += 1
	return v


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[released_market] FAIL: %s" % label)
		return false
	return running_ok
