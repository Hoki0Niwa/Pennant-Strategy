extends RefCounted
class_name FaMarketService

# R4: 簡易FA / 自由契約市場。
# 自軍だけ手動選択できるよう、ドラフトと同じ「state生成 -> 自軍選択 -> 残り自動 -> 確定」
# の形にする。process_fa_market は長期検証/CPU用の完全自動ラッパーとして残す。

const OffseasonService = preload("res://services/season/offseason_service.gd")
const TeamFinance = preload("res://services/season/team_finance.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const ROSTER_LIMIT: int = 70
const TARGET_DECLARATIONS: int = 10
const MAX_DECLARE_PER_TEAM: int = 2
const MAX_SIGNINGS_PER_TEAM: int = 3
const FA_RESIGN_COOLDOWN_YEARS: int = 3
const MIN_NEED_TO_SIGN: float = 1.0
const OVER_BUDGET_SCORE_FACTOR: float = 0.6
const USER_NEGOTIATION_BONUS: float = 0.08
const CPU_NEGOTIATION_BONUS: float = 0.0
const FA_SIGN_CHANCE_MIN: float = 0.06
const FA_SIGN_CHANCE_MAX: float = 0.88
const FA_SIGN_CHANCE_BASE: float = 0.82
const FA_SIGN_VALUE_PENALTY: float = 0.012
const FA_SIGN_WAR_PENALTY: float = 0.055
const FA_SIGN_USAGE_PENALTY: float = 0.16
const FA_SIGN_NEED_BONUS: float = 0.015

# FA宣言は「レギュラー級」に限定する。控え/余剰の移動は将来の自由契約市場に寄せる。
const REGULAR_BATTER_PA: int = 300
const REGULAR_BATTER_GAMES: int = 90
const REGULAR_PITCHER_STARTS: int = 12
const REGULAR_RELIEF_APPEARANCES: int = 35
const REGULAR_PITCHER_OUTS: int = 150
const REGULAR_WAR: float = 1.0
const REGULAR_OVERALL: int = 68


static func process_fa_market(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_fa_market_state(players, teams, season, user_team_id)
	complete_fa_market_automatically(state, players, teams, season, user_team_id)
	return finalize_fa_market(state, players, season)


static func create_fa_market_state(players: Array, teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var declared: Array = _select_declarers(players, teams, season, year)
	for row in declared:
		var entry: Dictionary = row as Dictionary
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if player == null:
			continue
		player.source_data["fa_from_team"] = player.team_id
		player.source_data["free_agent"] = true
		player.team_id = 0

	return {
		"version": 2,
		"year": year,
		"user_team_id": user_team_id,
		"complete": declared.is_empty(),
		"finalized": false,
		"declared": declared,
		"signings": [],
		"returned_count": 0,
	}


static func submit_user_fa_decision(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "FA市場は既に完了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var entry: Dictionary = _state_entry_by_player_id(state, candidate_id)
	if entry.is_empty() or not bool(entry.get("available", true)):
		return {"ok": false, "message": "そのFA候補は選択できません。", "state": state}
	if int(entry.get("from_team", 0)) == user_team_id:
		return {"ok": false, "message": "自球団から宣言したFAは獲得対象にできません。", "state": state}

	if action == "skip":
		entry["user_skipped"] = true
		_advance_fa_state_if_done(state, players, teams, season)
		return {"ok": true, "state": state}

	if action != "sign":
		return {"ok": false, "message": "不正なFA操作です。", "state": state}
	if _signings_for_team(state, user_team_id) >= MAX_SIGNINGS_PER_TEAM:
		return {"ok": false, "message": "今オフのFA獲得上限に達しています。", "state": state}
	if not _can_team_accept_candidate(players, state, user_team_id, entry):
		return {"ok": false, "message": "支配下枠が不足しています。", "state": state}
	var need: Dictionary = _build_position_need(players, teams)
	var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
	var success_chance: float = _contract_success_chance(entry, team_need, "user")
	entry["last_user_success_chance"] = success_chance
	if Rng.roll_float() <= success_chance:
		_apply_signing(state, players, teams, season, entry, user_team_id, "user", success_chance)
	else:
		entry["user_skipped"] = true
		entry["failed_for_user"] = true
		_add_failed_negotiation(state, entry, user_team_id, "user", success_chance)
		_advance_fa_state_if_done(state, players, teams, season)
		return {"ok": true, "acquired": false, "message": "交渉はまとまりませんでした。", "state": state}
	_advance_fa_state_if_done(state, players, teams, season)
	return {"ok": true, "acquired": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var best_id: int = 0
	var best_score: float = -999999.0
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		if int(entry.get("from_team", 0)) == user_team_id:
			continue
		if bool(entry.get("user_skipped", false)):
			continue
		if not _can_team_accept_candidate(players, state, user_team_id, entry):
			continue
		var need: Dictionary = _build_position_need(players, teams)
		var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
		var score: float = _signing_score(entry, team_need, players, teams, user_team_id)
		if score > best_score:
			best_score = score
			best_id = int(entry.get("player_id", 0))
	if best_id <= 0:
		complete_fa_market_automatically(state, players, teams, season, user_team_id)
		return {"ok": true, "state": state}
	return submit_user_fa_decision(state, players, teams, season, best_id, "sign")


static func complete_fa_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var need: Dictionary = _build_position_need(players, teams)
	var declared: Array = state.get("declared", []) as Array
	declared.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da.get("value", 0)) == int(db.get("value", 0)):
			return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
		return int(da.get("value", 0)) > int(db.get("value", 0))
	)
	for row in declared:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
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
			if not _can_team_accept_candidate(players, state, team.id, entry):
				continue
			var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
			if team_need < MIN_NEED_TO_SIGN:
				continue
			var score: float = _signing_score(entry, team_need, players, teams, team.id)
			if score > best_score:
				best_score = score
				best_team_id = team.id
				entry["best_team_need"] = team_need
		if best_team_id > 0:
			var best_need: float = float(entry.get("best_team_need", 0.0))
			var success_chance: float = _contract_success_chance(entry, best_need, "cpu")
			if Rng.roll_float() <= success_chance:
				_apply_signing(state, players, teams, season, entry, best_team_id, "cpu", success_chance)
			else:
				_add_failed_negotiation(state, entry, best_team_id, "cpu", success_chance)
			entry.erase("best_team_need")
	state["complete"] = true
	return {"ok": true, "state": state}


static func finalize_fa_market(state: Dictionary, players: Array, season: PSSeason) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var year: int = season.year if season != null else int(state.get("year", 0))
	var returned_count: int = 0
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if player == null:
			continue
		player.team_id = int(entry.get("from_team", 0))
		player.source_data.erase("free_agent")
		player.source_data["fa_signed_year"] = year
		entry["available"] = false
		entry["returned"] = true
		returned_count += 1

	var signings: Array = (state.get("signings", []) as Array).duplicate(true)
	signings.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	var declared_summary: Array = []
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		declared_summary.append({
			"player_id": int(entry.get("player_id", 0)),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"position": int(entry.get("position", 0)),
			"from_team": int(entry.get("from_team", 0)),
			"reason": str(entry.get("reason", "regular")),
			"value": int(entry.get("value", 0)),
			"war": float(entry.get("war", 0.0)),
		})
	var result: Dictionary = {
		"declared": declared_summary,
		"declared_count": declared_summary.size(),
		"signings": signings,
		"moved_count": signings.size(),
		"failed_negotiations": (state.get("failed_negotiations", []) as Array).duplicate(true),
		"returned_count": returned_count,
	}
	state["returned_count"] = returned_count
	state["finalized"] = true
	state["complete"] = true
	state["final_result"] = result
	return result


static func available_user_candidates(state: Dictionary, players: Array, teams: Array) -> Array:
	var rows: Array = []
	var user_team_id: int = int(state.get("user_team_id", 0))
	var need: Dictionary = _build_position_need(players, teams)
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		if int(entry.get("from_team", 0)) == user_team_id:
			continue
		if bool(entry.get("user_skipped", false)):
			continue
		var pos: int = int(entry.get("position", 0))
		var team_need: float = float((need.get(user_team_id, {}) as Dictionary).get(pos, 0.0))
		var copy: Dictionary = entry.duplicate(true)
		copy["need"] = team_need
		copy["can_sign"] = _can_team_accept_candidate(players, state, user_team_id, entry)
		copy["success_chance"] = _contract_success_chance(entry, team_need, "user")
		rows.append(copy)
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		return _signing_score(da, float(da.get("need", 0.0)), players, teams, user_team_id) > _signing_score(db, float(db.get("need", 0.0)), players, teams, user_team_id)
	)
	return rows


static func _select_declarers(players: Array, teams: Array, season: PSSeason, year: int) -> Array:
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var candidates: Array = []
	var by_team_count: Dictionary = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired() or player.is_manager_candidate() or player.foreign_player:
			continue
		if not player.is_fa_eligible() or _on_cooldown(player, year):
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var war: float = _record_war(record, league_ctx)
		var value: int = OffseasonService.player_value_score(player)
		if not _is_regular_class(player, record, value, war):
			continue
		candidates.append(_declaration_entry(player, record, value, war))
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if float(da.get("declare_score", 0.0)) == float(db.get("declare_score", 0.0)):
			return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
		return float(da.get("declare_score", 0.0)) > float(db.get("declare_score", 0.0))
	)
	var declared: Array = []
	for row in candidates:
		if declared.size() >= TARGET_DECLARATIONS:
			break
		var entry: Dictionary = row as Dictionary
		var team_id: int = int(entry.get("from_team", 0))
		if int(by_team_count.get(team_id, 0)) >= MAX_DECLARE_PER_TEAM:
			continue
		entry.erase("declare_score")
		entry["available"] = true
		declared.append(entry)
		by_team_count[team_id] = int(by_team_count.get(team_id, 0)) + 1
	return declared


static func _declaration_entry(player: PSPlayer, record: PSPlayerSeasonRecord, value: int, war: float) -> Dictionary:
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
	var score: float = float(value) + war * 8.0 + float(games) * 0.03 + float(pa) * 0.01 + float(starts) * 0.5 + float(relief) * 0.12
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"from_team": player.team_id,
		"salary": player.salary,
		"value": value,
		"war": snapped(war, 0.01),
		"games": games,
		"plate_appearances": pa,
		"starts": starts,
		"relief_appearances": relief,
		"outs_pitched": outs,
		"reason": "regular",
		"declare_score": score,
	}


static func _is_regular_class(player: PSPlayer, record: PSPlayerSeasonRecord, value: int, war: float) -> bool:
	if value >= REGULAR_OVERALL and war >= 0.0:
		return true
	if war >= REGULAR_WAR:
		return true
	if record == null:
		return false
	if record.is_pitcher():
		if record.pitcher_stats.starts >= REGULAR_PITCHER_STARTS:
			return true
		if record.pitcher_stats.relief_appearances >= REGULAR_RELIEF_APPEARANCES:
			return true
		return record.pitcher_stats.outs_pitched >= REGULAR_PITCHER_OUTS
	return record.batter_stats.plate_appearances >= REGULAR_BATTER_PA or record.batter_stats.games >= REGULAR_BATTER_GAMES


static func _record_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	return float(WarCalculator.season_war(record, league_ctx).get("war", 0.0))


static func _apply_signing(state: Dictionary, players: Array, teams: Array, season: PSSeason, entry: Dictionary, to_team_id: int, method: String, success_chance: float = 1.0) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		return
	var year: int = season.year if season != null else int(state.get("year", 0))
	player.team_id = to_team_id
	player.source_data.erase("free_agent")
	player.source_data["fa_signed_year"] = year
	entry["available"] = false
	entry["signed"] = true
	entry["to_team"] = to_team_id
	var signing: Dictionary = {
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
		"success_chance": success_chance,
	}
	var signings: Array = state.get("signings", []) as Array
	signings.append(signing)
	state["signings"] = signings


static func _add_failed_negotiation(state: Dictionary, entry: Dictionary, team_id: int, method: String, success_chance: float) -> void:
	var failures: Array = state.get("failed_negotiations", []) as Array
	failures.append({
		"player_id": int(entry.get("player_id", 0)),
		"name": str(entry.get("name", "")),
		"age": int(entry.get("age", 0)),
		"position": int(entry.get("position", 0)),
		"from_team": int(entry.get("from_team", 0)),
		"to_team": team_id,
		"salary": int(entry.get("salary", 0)),
		"value": int(entry.get("value", 0)),
		"war": float(entry.get("war", 0.0)),
		"method": method,
		"success_chance": success_chance,
	})
	state["failed_negotiations"] = failures


static func _advance_fa_state_if_done(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> void:
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		if bool(entry.get("available", true)) and not bool(entry.get("user_skipped", false)):
			return
	complete_fa_market_automatically(state, players, teams, season, int(state.get("user_team_id", 0)))


static func _state_entry_by_player_id(state: Dictionary, player_id: int) -> Dictionary:
	for row in state.get("declared", []) as Array:
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


static func _can_team_accept_candidate(players: Array, state: Dictionary, team_id: int, candidate: Dictionary) -> bool:
	var reserved: int = 0
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)):
			continue
		if int(entry.get("from_team", 0)) == team_id and int(entry.get("player_id", 0)) != int(candidate.get("player_id", 0)):
			reserved += 1
	return _active_count_for_team(players, team_id) + reserved < ROSTER_LIMIT


static func _signing_score(entry: Dictionary, team_need: float, players: Array, teams: Array, team_id: int) -> float:
	var score: float = float(entry.get("value", 0)) * (1.0 + team_need / 20.0)
	score += float(entry.get("war", 0.0)) * 6.0
	var team: PSTeam = _find_team_by_id(teams, team_id)
	if team != null:
		var room: int = team.funds - TeamFinance.team_payroll(players, team_id) - int(entry.get("salary", 0))
		if room < 0:
			score *= OVER_BUDGET_SCORE_FACTOR
	return score


static func _contract_success_chance(entry: Dictionary, team_need: float, method: String = "cpu") -> float:
	var value: int = int(entry.get("value", 0))
	var war: float = max(0.0, float(entry.get("war", 0.0)))
	var usage_score: float = _regular_usage_score(entry)
	var chance: float = FA_SIGN_CHANCE_BASE
	chance -= max(0.0, float(value - 60)) * FA_SIGN_VALUE_PENALTY
	chance -= war * FA_SIGN_WAR_PENALTY
	chance -= usage_score * FA_SIGN_USAGE_PENALTY
	chance += min(10.0, max(0.0, team_need)) * FA_SIGN_NEED_BONUS
	chance += USER_NEGOTIATION_BONUS if method == "user" else CPU_NEGOTIATION_BONUS
	return clampf(chance, FA_SIGN_CHANCE_MIN, FA_SIGN_CHANCE_MAX)


static func _regular_usage_score(entry: Dictionary) -> float:
	var batter_usage: float = maxf(
		float(entry.get("plate_appearances", 0)) / 500.0,
		float(entry.get("games", 0)) / 120.0
	)
	var pitcher_usage: float = maxf(
		maxf(float(entry.get("starts", 0)) / 24.0, float(entry.get("relief_appearances", 0)) / 55.0),
		float(entry.get("outs_pitched", 0)) / 450.0
	)
	return clampf(maxf(batter_usage, pitcher_usage), 0.0, 1.0)


# 球団×ポジションの需要 = max(0, リーグ平均ベスト overall - 自軍ベスト overall)。
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
		if player.is_retired() or player.is_manager_candidate():
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


static func _on_cooldown(player: PSPlayer, year: int) -> bool:
	if not player.source_data.has("fa_signed_year"):
		return false
	var signed: int = int(player.source_data.get("fa_signed_year", 0))
	return year > 0 and (year - signed) < FA_RESIGN_COOLDOWN_YEARS


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
