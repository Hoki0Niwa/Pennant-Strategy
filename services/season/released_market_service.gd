class_name ReleasedMarketService

# 戦力外獲得市場。
# 戦力外通告済みの team_id=0 / retired 扱い選手を、ドラフト後FA前に再契約できる。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const MAX_SIGNINGS_PER_TEAM: int = 2
const MIN_NEED_TO_SIGN: float = 0.5
const OVER_BUDGET_SCORE_FACTOR: float = 0.7


static func process_released_market(players: Array, teams: Array, season: PSSeason, release_result: Dictionary, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_released_market_state(players, teams, season, release_result, user_team_id)
	complete_released_market_automatically(state, players, teams, season, user_team_id)
	return finalize_released_market(state)


static func create_released_market_state(players: Array, _teams: Array, season: PSSeason, release_result: Dictionary, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var released: Array = release_result.get("released", []) as Array
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var candidates: Array = []
	var seen: Dictionary = {}
	for row in released:
		var release_row: Dictionary = row as Dictionary
		var player_id: int = int(release_row.get("player_id", 0))
		if player_id <= 0 or seen.has(player_id):
			continue
		seen[player_id] = true
		var player: PSPlayer = _find_player_by_id(players, player_id)
		if player == null:
			continue
		if not _is_released_market_player(player):
			continue
		var from_team: int = int(release_row.get("team_id", 0))
		if from_team <= 0:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		candidates.append(_candidate_entry(player, record, from_team, league_ctx))
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) == int(db.get("value", 0)):
			return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
		return int(da.get("value", 0)) > int(db.get("value", 0))
	)
	return {
		"version": 1,
		"year": year,
		"user_team_id": user_team_id,
		"complete": candidates.is_empty(),
		"finalized": false,
		"candidates": candidates,
		"signings": [],
	}


static func submit_user_released_decision(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "戦力外獲得市場は既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var entry: Dictionary = _state_entry_by_player_id(state, candidate_id)
	if entry.is_empty() or not bool(entry.get("available", true)):
		return {"ok": false, "message": "その自由契約候補は選択できません。", "state": state}
	if action == "sign" and not _can_sign_entry(players, entry):
		entry["available"] = false
		return {"ok": false, "message": "引退済み選手は戦力外獲得できません。", "state": state}
	if int(entry.get("from_team", 0)) == user_team_id:
		return {"ok": false, "message": "自球団が戦力外にした選手は今オフ再獲得できません。", "state": state}

	if action == "skip":
		entry["user_skipped"] = true
		_advance_released_state_if_done(state, players, teams, season)
		return {"ok": true, "state": state}
	if action != "sign":
		return {"ok": false, "message": "不正な戦力外獲得操作です。", "state": state}
	if _signings_for_team(state, user_team_id) >= MAX_SIGNINGS_PER_TEAM:
		return {"ok": false, "message": "今オフの戦力外獲得上限に達しています。", "state": state}
	if not _can_team_accept_candidate(players, user_team_id):
		return {"ok": false, "message": "支配下枠が不足しています。", "state": state}
	_apply_signing(state, players, season, entry, user_team_id, "user")
	_advance_released_state_if_done(state, players, teams, season)
	return {"ok": true, "acquired": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var candidates: Array = available_user_candidates(state, players, teams)
	if candidates.is_empty():
		complete_released_market_automatically(state, players, teams, season, user_team_id)
		return {"ok": true, "state": state}
	return submit_user_released_decision(state, players, teams, season, int((candidates[0] as Dictionary).get("player_id", 0)), "sign")


static func complete_released_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var need: Dictionary = _build_position_need(players, teams)
	var candidates: Array = state.get("candidates", []) as Array
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) == int(db.get("value", 0)):
			return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
		return int(da.get("value", 0)) > int(db.get("value", 0))
	)
	for row in candidates:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		if not _can_sign_entry(players, entry):
			entry["available"] = false
			continue
		var best_team_id: int = 0
		var best_score: float = -999999.0
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			if team.id == int(entry.get("from_team", 0)):
				continue
			if team.id == user_team_id and bool(entry.get("user_skipped", false)):
				continue
			if _signings_for_team(state, team.id) >= MAX_SIGNINGS_PER_TEAM:
				continue
			if not _can_team_accept_candidate(players, team.id):
				continue
			var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
			if team_need < MIN_NEED_TO_SIGN:
				continue
			var score: float = _signing_score(entry, team_need, players, teams, team.id)
			if score > best_score:
				best_score = score
				best_team_id = team.id
		if best_team_id > 0:
			_apply_signing(state, players, season, entry, best_team_id, "cpu")
	state["complete"] = true
	return {"ok": true, "state": state}


static func finalize_released_market(state: Dictionary) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var signings: Array = (state.get("signings", []) as Array).duplicate(true)
	signings.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	var candidates_summary: Array = []
	var remaining_count: int = 0
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if bool(entry.get("available", true)):
			remaining_count += 1
		candidates_summary.append({
			"player_id": int(entry.get("player_id", 0)),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"position": int(entry.get("position", 0)),
			"from_team": int(entry.get("from_team", 0)),
			"value": int(entry.get("value", 0)),
			"war": float(entry.get("war", 0.0)),
		})
	var result: Dictionary = {
		"candidates": candidates_summary,
		"candidates_count": candidates_summary.size(),
		"signings": signings,
		"signed_count": signings.size(),
		"remaining_count": remaining_count,
	}
	state["finalized"] = true
	state["complete"] = true
	state["final_result"] = result
	return result


static func available_user_candidates(state: Dictionary, players: Array, teams: Array) -> Array:
	var rows: Array = []
	var user_team_id: int = int(state.get("user_team_id", 0))
	var need: Dictionary = _build_position_need(players, teams)
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		if not _can_sign_entry(players, entry):
			entry["available"] = false
			continue
		if int(entry.get("from_team", 0)) == user_team_id:
			continue
		if bool(entry.get("user_skipped", false)):
			continue
		var pos: int = int(entry.get("position", 0))
		var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(pos, 0.0))
		var copy: Dictionary = entry.duplicate(true)
		copy["need"] = team_need
		copy["can_sign"] = _can_team_accept_candidate(players, user_team_id)
		rows.append(copy)
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		return _signing_score(da, float(da.get("need", 0.0)), players, teams, user_team_id) > _signing_score(db, float(db.get("need", 0.0)), players, teams, user_team_id)
	)
	return rows


static func _candidate_entry(player: PSPlayer, record: PSPlayerSeasonRecord, from_team: int, league_ctx: Dictionary) -> Dictionary:
	var games: int = 0
	var pa: int = 0
	var starts: int = 0
	var relief: int = 0
	var outs: int = 0
	if record != null:
		if record.is_pitcher():
			games = record.pitcher_stats.games
			starts = record.pitcher_stats.starts
			relief = record.pitcher_stats.relief_appearances
			outs = record.pitcher_stats.outs_pitched
		else:
			games = record.batter_stats.games
			pa = record.batter_stats.plate_appearances
	var war: float = _record_war(record, league_ctx)
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"from_team": from_team,
		"salary": player.salary,
		"value": OffseasonService.player_value_score(player),
		"war": snapped(war, 0.01),
		"games": games,
		"plate_appearances": pa,
		"starts": starts,
		"relief_appearances": relief,
		"outs_pitched": outs,
		"available": true,
	}


static func _apply_signing(state: Dictionary, players: Array, season: PSSeason, entry: Dictionary, to_team_id: int, method: String) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if not _is_released_market_player(player):
		return
	var year: int = season.year if season != null else int(state.get("year", 0))
	player.team_id = to_team_id
	player.source_data.erase("released")
	player.source_data.erase("retired")
	player.source_data.erase("retired_age")
	player.source_data["released_signed_year"] = year
	player.source_data["released_from_team"] = int(entry.get("from_team", 0))
	entry["available"] = false
	entry["signed"] = true
	entry["to_team"] = to_team_id
	var signings: Array = state.get("signings", []) as Array
	signings.append({
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"from_team": int(entry.get("from_team", 0)),
		"to_team": to_team_id,
		"salary": player.salary,
		"value": int(entry.get("value", 0)),
		"war": float(entry.get("war", 0.0)),
		"method": method,
	})
	state["signings"] = signings


static func _advance_released_state_if_done(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if bool(entry.get("available", true)) and not bool(entry.get("user_skipped", false)):
			return
	complete_released_market_automatically(state, players, teams, season, int(state.get("user_team_id", 0)))


static func _state_entry_by_player_id(state: Dictionary, player_id: int) -> Dictionary:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("player_id", 0)) == player_id:
			return entry
	return {}


static func _signings_for_team(state: Dictionary, team_id: int) -> int:
	var count: int = 0
	for row in state.get("signings", []) as Array:
		if int((row as Dictionary).get("to_team", 0)) == team_id:
			count += 1
	return count


static func _can_team_accept_candidate(players: Array, team_id: int) -> bool:
	# オフの補強は soft 目標 (67) で止め、シーズン中の昇格用に枠を残す (hard 上限 70 は別途保証)。
	return _active_count_for_team(players, team_id) < TeamFinance.SHIENKA_SOFT_TARGET


static func _can_sign_entry(players: Array, entry: Dictionary) -> bool:
	return _is_released_market_player(_find_player_by_id(players, int(entry.get("player_id", 0))))


static func _is_released_market_player(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.team_id != 0:
		return false
	# 引退ステップの本物の引退者は retired のみ。戦力外は市場に出すため released も持つ。
	if player.is_retired() and not bool(player.source_data.get("released", false)):
		return false
	return bool(player.source_data.get("released", false))


static func _signing_score(entry: Dictionary, team_need: float, players: Array, teams: Array, team_id: int) -> float:
	var score: float = float(entry.get("value", 0)) * (1.0 + team_need / 16.0)
	score += float(entry.get("war", 0.0)) * 5.0
	var team: PSTeam = _find_team_by_id(teams, team_id)
	if team != null:
		var room: int = team.funds - TeamFinance.team_payroll(players, team_id) - int(entry.get("salary", 0))
		if room < 0:
			score *= OVER_BUDGET_SCORE_FACTOR
	return score


static func _build_position_need(players: Array, teams: Array) -> Dictionary:
	var best_by_team: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			best_by_team[team.id] = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired():
			continue
		if not best_by_team.has(player.team_id):
			continue
		var pos_map: Dictionary = best_by_team[player.team_id] as Dictionary
		var overall: int = OffseasonService.player_value_score(player)
		if overall > int(pos_map.get(player.position, 0)):
			pos_map[player.position] = overall
	var league_avg: Dictionary = {}
	for pos in range(1, 10):
		var total: float = 0.0
		var count: int = 0
		for team_id in best_by_team.keys():
			total += float((best_by_team[team_id] as Dictionary).get(pos, 0))
			count += 1
		league_avg[pos] = total / float(maxi(1, count))
	var need: Dictionary = {}
	for team_id in best_by_team.keys():
		var pos_need: Dictionary = {}
		var pos_map: Dictionary = best_by_team[team_id] as Dictionary
		for pos in range(1, 10):
			pos_need[pos] = max(0.0, float(league_avg[pos]) - float(pos_map.get(pos, 0)))
		need[team_id] = pos_need
	return need


static func _record_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	return float(WarCalculator.season_war(record, league_ctx).get("war", 0.0))


# roadmap #3: 支配下枠 (育成除外) の人数。計数の単一ソースは TeamFinance。
static func _active_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.shienka_count(players, team_id)


static func _find_player_by_id(players: Array, player_id: int) -> PSPlayer:
	for row in players:
		var player: PSPlayer = row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


static func _find_team_by_id(teams: Array, team_id: int) -> PSTeam:
	for row in teams:
		var team: PSTeam = row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null
