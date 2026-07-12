extends RefCounted
class_name FaMarketService

# R4: 簡易FA / 自由契約市場。
# 自軍だけ手動選択できるよう、ドラフトと同じ「state生成 -> 自軍選択 -> 残り自動 -> 確定」
# の形にする。process_fa_market は長期検証/CPU用の完全自動ラッパーとして残す。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const TARGET_DECLARATIONS: int = 10
const MAX_DECLARE_PER_TEAM: int = 2
const MAX_SIGNINGS_PER_TEAM: int = 3
const FA_RESIGN_COOLDOWN_YEARS: int = 3
const MIN_NEED_TO_SIGN: float = 1.0
const USER_NEGOTIATION_BONUS: float = 0.08
const CPU_NEGOTIATION_BONUS: float = 0.0
const FA_SIGN_CHANCE_MIN: float = 0.06
const FA_SIGN_CHANCE_MAX: float = 0.88
const FA_SIGN_CHANCE_BASE: float = 0.82
const FA_SIGN_VALUE_PENALTY: float = 0.012
const FA_SIGN_WAR_PENALTY: float = 0.055
const FA_SIGN_USAGE_PENALTY: float = 0.16
const FA_SIGN_NEED_BONUS: float = 0.015
# 現実のNPB宣言率(2022-24年、資格保有者の6.6-8.1%のみが実際に宣言)に合わせた低確率。
# 新規FA権保持者へのボーナス込みでも初年度2割程度に留め、TARGET_DECLARATIONS の
# 上限に毎年機械的に張り付かない(=年によって0人に近い年もあれば上限に届く年もある)ようにする。
const BASE_DECLARE_CHANCE: float = 0.10
const NEW_FA_DECLARE_BONUS: float = 0.12
const PASS_DECAY_1: float = 0.04
const PASS_DECAY_PER_YEAR: float = 0.02
const MIN_DECLARE_CHANCE: float = 0.02
const MAX_DECLARE_CHANCE: float = 0.30
const FA_RANK_A_COMPENSATION_RATE: float = 0.80
const FA_RANK_B_COMPENSATION_RATE: float = 0.60
const FA_RANK_A_OFFER_MULT: float = 1.25
const FA_RANK_B_OFFER_MULT: float = 1.15
const FA_RANK_C_OFFER_MULT: float = 1.05

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
		player.source_data["fa_eligible_year"] = int(entry.get("fa_eligible_year", year))
		player.team_id = 0

	return {
		"version": 3,
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
	if not _can_team_afford_candidate(players, teams, user_team_id, entry):
		var team: PSTeam = _find_team_by_id(teams, user_team_id)
		var room: int = TeamFinance.budget_room(team.funds, TeamFinance.team_payroll(players, user_team_id)) if team != null else 0
		return {"ok": false, "message": "予算が不足しているためFA獲得できません(残額 %d万円 / 必要額 %d万円)。" % [room, _fa_cost(entry)], "state": state}
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
		if not _can_team_afford_candidate(players, teams, user_team_id, entry):
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
			if not _can_team_afford_candidate(players, teams, team.id, entry):
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
	var declared_ids: Dictionary = {}
	for row in state.get("declared", []) as Array:
		var entry: Dictionary = row as Dictionary
		declared_ids[int(entry.get("player_id", 0))] = true
		if not bool(entry.get("available", true)):
			continue
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if player == null:
			continue
		player.team_id = int(entry.get("from_team", 0))
		player.salary = int(entry.get("offer_salary", player.salary))
		player.source_data.erase("free_agent")
		player.source_data["fa_signed_year"] = year
		player.source_data["fa_contract_salary"] = player.salary
		player.source_data["fa_pass_count"] = 0
		if not player.source_data.has("fa_eligible_year"):
			player.source_data["fa_eligible_year"] = int(entry.get("fa_eligible_year", year))
		PSCareerLog.log_fa_stay(player, year, player.team_id, player.salary)
		entry["available"] = false
		entry["returned"] = true
		returned_count += 1

	var passed_count: int = _increment_non_declared_fa_passes(players, year, declared_ids)
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
			"role": str(entry.get("role", "")),
			"from_team": int(entry.get("from_team", 0)),
			"reason": str(entry.get("reason", "regular")),
			"value": int(entry.get("value", 0)),
			"war": float(entry.get("war", 0.0)),
			"fa_rank": str(entry.get("fa_rank", "C")),
			"offer_salary": int(entry.get("offer_salary", entry.get("salary", 0))),
			"compensation_money": int(entry.get("compensation_money", 0)),
			"fa_eligible_year": int(entry.get("fa_eligible_year", year)),
			"fa_pass_count": int(entry.get("fa_pass_count", 0)),
			"fa_nissuu": int(entry.get("fa_nissuu", 0)),
			"declaration_chance": float(entry.get("declaration_chance", 0.0)),
		})
	var result: Dictionary = {
		"declared": declared_summary,
		"declared_count": declared_summary.size(),
		"signings": signings,
		"moved_count": signings.size(),
		"failed_negotiations": (state.get("failed_negotiations", []) as Array).duplicate(true),
		"returned_count": returned_count,
		"passed_count": passed_count,
	}
	state["returned_count"] = returned_count
	state["passed_count"] = passed_count
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
		copy["can_sign"] = _can_team_accept_candidate(players, state, user_team_id, entry) and _can_team_afford_candidate(players, teams, user_team_id, entry)
		copy["success_chance"] = _contract_success_chance(entry, team_need, "user")
		rows.append(copy)
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		return _signing_score(da, float(da.get("need", 0.0)), players, teams, user_team_id) > _signing_score(db, float(db.get("need", 0.0)), players, teams, user_team_id)
	)
	return rows


static func _select_declarers(players: Array, _teams: Array, season: PSSeason, year: int) -> Array:
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var rank_by_player_id: Dictionary = _build_fa_rank_by_player_id(players)
	var candidates: Array = []
	var by_team_count: Dictionary = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired() or player.foreign_player:
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
		var declaration_chance: float = _declaration_chance(player, year)
		if Rng.roll_float() > declaration_chance:
			continue
		candidates.append(_declaration_entry(player, record, value, war, rank_by_player_id, year, declaration_chance))
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


static func _declaration_entry(
	player: PSPlayer,
	record: PSPlayerSeasonRecord,
	value: int,
	war: float,
	rank_by_player_id: Dictionary,
	year: int,
	declaration_chance: float
) -> Dictionary:
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
	var salary_rank: int = int(rank_by_player_id.get(player.id, 99))
	var fa_rank: String = _fa_rank_for_salary_rank(salary_rank)
	var market_salary_base: int = _market_salary_base(player, record, war)
	var offer_salary: int = _offer_salary(player.salary, market_salary_base, fa_rank)
	var compensation_money: int = _compensation_money(fa_rank, player.salary)
	var fa_eligible_year: int = _fa_eligible_year(player, year)
	var fa_pass_count: int = _fa_pass_count(player, year)
	var fa_nissuu: int = player.fa_service_days()
	var base_score: float = float(value) + war * 8.0 + float(games) * 0.03 + float(pa) * 0.01 + float(starts) * 0.5 + float(relief) * 0.12
	var score: float = base_score * declaration_chance + float(offer_salary - player.salary) * 0.002
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"role": player.role,
		"from_team": player.team_id,
		"salary": player.salary,
		"fa_rank": fa_rank,
		"salary_rank": salary_rank,
		"market_salary_base": market_salary_base,
		"offer_salary": offer_salary,
		"compensation_money": compensation_money,
		"fa_eligible_year": fa_eligible_year,
		"fa_pass_count": fa_pass_count,
		"fa_nissuu": fa_nissuu,
		"fa_required_days": player.fa_service_days_required(),
		"declaration_chance": declaration_chance,
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


static func _is_regular_class(_player: PSPlayer, record: PSPlayerSeasonRecord, value: int, war: float) -> bool:
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


static func _build_fa_rank_by_player_id(players: Array) -> Dictionary:
	var by_team: Dictionary = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired() or player.foreign_player:
			continue
		if not by_team.has(player.team_id):
			by_team[player.team_id] = []
		(by_team[player.team_id] as Array).append(player)
	var rank_by_player_id: Dictionary = {}
	for team_id in by_team.keys():
		var roster: Array = by_team[team_id] as Array
		roster.sort_custom(func(a, b) -> bool:
			var pa: PSPlayer = a as PSPlayer
			var pb: PSPlayer = b as PSPlayer
			if pa.salary != pb.salary:
				return pa.salary > pb.salary
			var fa_a: int = int(pa.source_data.get("fa_nissuu", 0))
			var fa_b: int = int(pb.source_data.get("fa_nissuu", 0))
			if fa_a != fa_b:
				return fa_a > fa_b
			if pa.years != pb.years:
				return pa.years > pb.years
			if pa.age != pb.age:
				return pa.age < pb.age
			return pa.id < pb.id
		)
		for i in range(roster.size()):
			var player: PSPlayer = roster[i] as PSPlayer
			if player != null:
				rank_by_player_id[player.id] = i + 1
	return rank_by_player_id


static func _fa_rank_for_salary_rank(salary_rank: int) -> String:
	if salary_rank >= 1 and salary_rank <= 3:
		return "A"
	if salary_rank >= 4 and salary_rank <= 10:
		return "B"
	return "C"


static func _compensation_money(fa_rank: String, salary: int) -> int:
	match fa_rank:
		"A":
			return int(round(float(salary) * FA_RANK_A_COMPENSATION_RATE))
		"B":
			return int(round(float(salary) * FA_RANK_B_COMPENSATION_RATE))
		_:
			return 0


static func _offer_salary(current_salary: int, market_salary_base: int, fa_rank: String) -> int:
	var mult: float = FA_RANK_C_OFFER_MULT
	if fa_rank == "A":
		mult = FA_RANK_A_OFFER_MULT
	elif fa_rank == "B":
		mult = FA_RANK_B_OFFER_MULT
	return clampi(maxi(current_salary, int(round(float(market_salary_base) * mult))), OffseasonService.SALARY_MIN, OffseasonService.SALARY_MAX)


static func _market_salary_base(player: PSPlayer, record: PSPlayerSeasonRecord, war: float) -> int:
	return maxi(player.salary, OffseasonService._season_market_value(record, war, player.foreign_player))


static func _fa_eligible_year(player: PSPlayer, year: int) -> int:
	if player.source_data.has("fa_eligible_year"):
		return int(player.source_data.get("fa_eligible_year", year))
	var years_since_eligible: int = int(floor(float(maxi(0, player.fa_service_days() - player.fa_service_days_required())) / float(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))
	return year - years_since_eligible


static func _fa_pass_count(player: PSPlayer, year: int) -> int:
	if player.source_data.has("fa_pass_count"):
		return maxi(0, int(player.source_data.get("fa_pass_count", 0)))
	return maxi(0, year - _fa_eligible_year(player, year))


static func _declaration_chance(player: PSPlayer, year: int) -> float:
	var pass_count: int = _fa_pass_count(player, year)
	var chance: float = BASE_DECLARE_CHANCE
	if pass_count == 0:
		chance += NEW_FA_DECLARE_BONUS
	if pass_count >= 1:
		chance -= PASS_DECAY_1
	if pass_count >= 2:
		chance -= float(pass_count - 1) * PASS_DECAY_PER_YEAR
	return clampf(chance, MIN_DECLARE_CHANCE, MAX_DECLARE_CHANCE)


static func _is_fa_tracking_candidate(player: PSPlayer, year: int) -> bool:
	if player == null or player.team_id <= 0:
		return false
	if player.is_retired() or player.foreign_player:
		return false
	if bool(player.source_data.get("free_agent", false)):
		return false
	return player.is_fa_eligible() and not _on_cooldown(player, year)


static func _increment_non_declared_fa_passes(players: Array, year: int, declared_ids: Dictionary) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not _is_fa_tracking_candidate(player, year):
			continue
		if declared_ids.has(player.id):
			continue
		if not player.source_data.has("fa_eligible_year"):
			player.source_data["fa_eligible_year"] = _fa_eligible_year(player, year)
		player.source_data["fa_pass_count"] = _fa_pass_count(player, year) + 1
		count += 1
	return count


static func _apply_signing(state: Dictionary, players: Array, teams: Array, season: PSSeason, entry: Dictionary, to_team_id: int, method: String, success_chance: float = 1.0) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		return
	var year: int = season.year if season != null else int(state.get("year", 0))
	player.team_id = to_team_id
	player.salary = int(entry.get("offer_salary", player.salary))
	player.source_data.erase("free_agent")
	player.source_data["fa_signed_year"] = year
	player.source_data["fa_contract_salary"] = player.salary
	player.source_data["fa_pass_count"] = 0
	if not player.source_data.has("fa_eligible_year"):
		player.source_data["fa_eligible_year"] = int(entry.get("fa_eligible_year", year))
	PSCareerLog.log_fa_move(player, year, int(entry.get("from_team", 0)), to_team_id, player.salary)
	entry["available"] = false
	entry["signed"] = true
	entry["to_team"] = to_team_id
	# 金銭補償 (A80%/B60%) を当オフの予算調整として実際に移動する。獲得球団が負担し元球団が受け取る。
	var comp: int = int(entry.get("compensation_money", 0))
	var comp_from_team: int = int(entry.get("from_team", 0))
	if comp > 0 and comp_from_team != to_team_id:
		var signing_team: PSTeam = _find_team_by_id(teams, to_team_id)
		var former_team: PSTeam = _find_team_by_id(teams, comp_from_team)
		if signing_team != null:
			signing_team.funds -= comp
		if former_team != null:
			former_team.funds += comp
	var signing: Dictionary = {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"role": player.role,
		"from_team": int(entry.get("from_team", 0)),
		"to_team": to_team_id,
		"salary": player.salary,
		"fa_rank": str(entry.get("fa_rank", "C")),
		"offer_salary": player.salary,
		"compensation_money": int(entry.get("compensation_money", 0)),
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
		"salary": int(entry.get("offer_salary", entry.get("salary", 0))),
		"fa_rank": str(entry.get("fa_rank", "C")),
		"offer_salary": int(entry.get("offer_salary", entry.get("salary", 0))),
		"compensation_money": int(entry.get("compensation_money", 0)),
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
	# ドラフトが後段補強用に残した hard 枠を使う。FA残留/獲得予約も含めて70枠を超えない。
	return _active_count_for_team(players, team_id) + reserved < TeamFinance.SHIENKA_LIMIT


# FA獲得コスト = 提示年俸 + 移籍元へ支払う金銭補償 (A/Bランクのみ、獲得側の負担)。
static func _fa_cost(entry: Dictionary) -> int:
	return int(entry.get("offer_salary", entry.get("salary", 0))) + int(entry.get("compensation_money", 0))


# 予算ゲート: 補強コストを払っても予算内に収まるか。
static func _can_team_afford_candidate(players: Array, teams: Array, team_id: int, entry: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	return TeamFinance.can_afford_addition(players, team, _fa_cost(entry))


static func _signing_score(entry: Dictionary, team_need: float, _players: Array, _teams: Array, _team_id: int) -> float:
	var score: float = float(entry.get("value", 0)) * (1.0 + team_need / 20.0)
	score += float(entry.get("war", 0.0)) * 6.0
	score += float(int(entry.get("offer_salary", entry.get("salary", 0))) - int(entry.get("salary", 0))) * 0.001
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
	chance += min(0.10, max(0.0, float(int(entry.get("offer_salary", entry.get("salary", 0))) - int(entry.get("salary", 0))) / 50000.0))
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


static func _on_cooldown(player: PSPlayer, year: int) -> bool:
	if not player.source_data.has("fa_signed_year"):
		return false
	var signed: int = int(player.source_data.get("fa_signed_year", 0))
	return year > 0 and (year - signed) < FA_RESIGN_COOLDOWN_YEARS


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
