class_name ReleasedMarketService

# 戦力外獲得市場。
# 戦力外通告済みの team_id=0 / retired 扱い選手を、ドラフト後FA前に再契約できる。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const MAX_SIGNINGS_PER_TEAM: int = 2
# 0.5 だと大半の球団がどこかのポジションで僅かでも need を持ち毎年上限の2人まで埋まってしまうため、
# 「明確な穴」だけが対象になる水準まで上げる (=球団によって0人の年もあれば2人埋める年もある)。
const MIN_NEED_TO_SIGN: float = 4.0
# 能力・実績・需要から年俸負担を引いた後も、この水準を満たす候補だけをAIが獲得する。
const MIN_AI_SIGNING_SCORE: float = 35.0
# 野手が systematically 高 value な分を相殺する投手 score parity (NPB実績の投打バランス較正用ノブ)。
const PITCHER_ACQUISITION_PARITY: float = 2.0

# 元年俸が1000万円を超える戦力外選手は、1000万円と超過分の20%を再契約年俸にする。
# 1000万円以下は支配下・育成とも元年俸を維持する。
const SALARY_KEEP_THRESHOLD: int = 1000
const SALARY_EXCESS_RATE: float = 0.20

# 支配下/育成は「誰を獲得するか決めてから振り分ける」のではなく、候補ごとに別判定する。
# 年齢が上がるほど「今すぐ支配下で通用するか」を疑われ育成寄りになり、能力(value)が高い
# 選手は年齢が高くても支配下に残りやすい(実績組は年齢だけで即戦力性を疑われない)。
# 育成判定は支配下枠(SHIENKA_LIMIT)を消費しない。
# 基準(30歳・value50=典型的な戦力外候補)で五分五分になるよう調整。Web調査した実績
# (2023-24年16支配下/12育成、2024-25年9支配下/13育成)の支配下/育成比率(概ね半々)に
# 揃えている。
const TRACK_SHIENKA: String = "支配下"
const TRACK_DEVELOPMENT: String = "育成"
const DEV_TRACK_BASE_CHANCE: float = 0.45
const DEV_TRACK_AGE_PIVOT: int = 30
const DEV_TRACK_AGE_CHANCE_PER_YEAR: float = 0.05
const DEV_TRACK_VALUE_PIVOT: int = 50
const DEV_TRACK_VALUE_OFFSET: float = 0.012
const DEV_TRACK_CHANCE_MIN: float = 0.05
const DEV_TRACK_CHANCE_MAX: float = 0.90


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
	_sync_available_contract_salaries(state, players)
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
	if not _can_team_accept_candidate(players, user_team_id, entry):
		return {"ok": false, "message": "支配下枠または外国人枠が不足しています。", "state": state}
	if not _can_team_afford_release(players, teams, user_team_id, entry):
		var team: PSTeam = _find_team_by_id(teams, user_team_id)
		var room: int = TeamFinance.budget_room(team.funds, TeamFinance.team_payroll(players, user_team_id)) if team != null else 0
		return {"ok": false, "message": "予算が不足しているため戦力外選手を獲得できません(残額 %d万円 / 年俸 %d万円)。" % [room, int(entry.get("salary", 0))], "state": state}
	_apply_signing(state, players, season, entry, user_team_id, "user")
	_advance_released_state_if_done(state, players, teams, season)
	return {"ok": true, "acquired": true, "state": state}


static func auto_pick_for_user(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var candidates: Array = available_user_candidates(state, players, teams)
	# デプスチャートは1度だけ作って使い回す (候補ごとに作り直すと O(n^2) になる)。
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var best_id: int = 0
	var best_score: float = -INF
	for row in candidates:
		var entry: Dictionary = row as Dictionary
		if not _can_ai_afford_release(players, teams, user_team_id, entry):
			continue
		var team_need: float = float(entry.get("need", 0.0))
		if not _team_wants_candidate(players, charts, user_team_id, entry):
			continue
		var score: float = _signing_score(entry, team_need, players, teams, user_team_id)
		if score < MIN_AI_SIGNING_SCORE:
			continue
		if score > best_score:
			best_score = score
			best_id = int(entry.get("player_id", 0))
	if best_id <= 0:
		complete_released_market_automatically(state, players, teams, season, user_team_id)
		return {"ok": true, "state": state}
	return submit_user_released_decision(state, players, teams, season, best_id, "sign")


static func complete_released_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	_sync_available_contract_salaries(state, players)
	# 需要とデプスチャートは1パスにつき1度だけ構築する (候補×球団で作り直すと O(n^2))。
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var need: Dictionary = TeamDepthChart.position_need_view(charts)
	var candidates: Array = state.get("candidates", []) as Array
	candidates.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		var score_a: float = _signing_score(da, 0.0, players, teams, 0)
		var score_b: float = _signing_score(db, 0.0, players, teams, 0)
		if is_equal_approx(score_a, score_b):
			return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
		return score_a > score_b
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
			if not _can_team_accept_candidate(players, team.id, entry):
				continue
			if not _can_ai_afford_release(players, teams, team.id, entry):
				continue
			var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
			if not _team_wants_candidate(players, charts, team.id, entry):
				continue
			var score: float = _signing_score(entry, team_need, players, teams, team.id)
			if score < MIN_AI_SIGNING_SCORE:
				continue
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
			"role": str(entry.get("role", "")),
			"from_team": int(entry.get("from_team", 0)),
			"value": int(entry.get("value", 0)),
			"war": float(entry.get("war", 0.0)),
			"track": str(entry.get("track", TRACK_SHIENKA)),
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
	_sync_available_contract_salaries(state, players)
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
		copy["can_sign"] = _can_team_accept_candidate(players, user_team_id, entry) and _can_team_afford_release(players, teams, user_team_id, entry)
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
	var value: int = OffseasonService.player_value_score(player)
	var track: String = _determine_track(player.age, value)
	return {
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"role": player.role,
		"from_team": from_team,
		"foreign_player": player.foreign_player,
		"salary": _released_contract_salary(player.salary),
		"value": value,
		"war": snapped(war, 0.01),
		"games": games,
		"plate_appearances": pa,
		"starts": starts,
		"relief_appearances": relief,
		"outs_pitched": outs,
		"available": true,
		"track": track,
	}


static func _released_contract_salary(current_salary: int) -> int:
	if current_salary <= SALARY_KEEP_THRESHOLD:
		return current_salary
	var raw: int = int(round(float(SALARY_KEEP_THRESHOLD) + float(current_salary - SALARY_KEEP_THRESHOLD) * SALARY_EXCESS_RATE))
	return OffseasonService.round_salary_2sig(raw)


# 候補の契約額は獲得前の元年俸から同期し、市場途中の保存・再開でも現行の算定額を使う。
static func _sync_available_contract_salaries(state: Dictionary, players: Array) -> void:
	for row in state.get("candidates", []) as Array:
		var entry: Dictionary = row as Dictionary
		if not bool(entry.get("available", true)) or bool(entry.get("signed", false)):
			continue
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		if not _is_released_market_player(player):
			continue
		entry["salary"] = _released_contract_salary(player.salary)


# 年齢が上がるほど育成寄りになる確率を計算し、候補作成時に一度だけ支配下/育成の
# 獲得track を決める(成立後に振り分けるのではなく、獲得可否の判定自体をtrackごとに行う)。
static func _development_track_chance(age: int, value: int) -> float:
	var chance: float = DEV_TRACK_BASE_CHANCE + float(age - DEV_TRACK_AGE_PIVOT) * DEV_TRACK_AGE_CHANCE_PER_YEAR
	chance -= float(value - DEV_TRACK_VALUE_PIVOT) * DEV_TRACK_VALUE_OFFSET
	return clampf(chance, DEV_TRACK_CHANCE_MIN, DEV_TRACK_CHANCE_MAX)


static func _determine_track(age: int, value: int) -> String:
	return TRACK_DEVELOPMENT if Rng.roll_float() <= _development_track_chance(age, value) else TRACK_SHIENKA


static func _apply_signing(state: Dictionary, players: Array, season: PSSeason, entry: Dictionary, to_team_id: int, method: String) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if not _is_released_market_player(player):
		return
	var year: int = season.year if season != null else int(state.get("year", 0))
	var track: String = str(entry.get("track", TRACK_SHIENKA))
	player.team_id = to_team_id
	player.source_data.erase("released")
	player.source_data.erase("retired")
	player.source_data.erase("retired_age")
	player.source_data["released_signed_year"] = year
	player.source_data["released_from_team"] = int(entry.get("from_team", 0))
	# 戦力外になった時点で支配下だったか (= 育成契約を結ぶなら「支配下経験者」扱いで契約1年)。
	# development_player を track で上書きする前に読む必要がある。
	var was_shienka: bool = not player.development_player
	player.development_player = track == TRACK_DEVELOPMENT
	player.registered_roster = track
	player.salary = int(entry.get(
		"salary",
		OffseasonService.DEVELOPMENT_CONTRACT_SALARY if player.development_player else player.salary
	))
	player.source_data["released_contract_salary"] = player.salary
	PSCareerLog.log_released_signed(player, year, int(entry.get("from_team", 0)), to_team_id, player.development_player)
	if player.development_player:
		# 獲得した同オフの育成整理 (成長ステップ内) で即放出されないよう1オフ分保持する。
		# フラグは OffseasonService.process_development_releases が読んで消費する (育成降格と同じ機構)。
		# 中堅以上はここから1年、翌オフの昇格ステップで支配下に戻れなければ放出される。
		player.source_data["dev_demote_hold"] = true
		# 育成契約の年数カウンタもここから数え直す (新しい育成契約なので)。
		player.source_data["development_since_year"] = year
		# 支配下から戦力外になった選手の育成契約は1年 (元から育成だった選手は新規と同じ3年)。
		if was_shienka:
			player.source_data["dev_from_shienka"] = true
		else:
			player.source_data.erase("dev_from_shienka")
	else:
		player.source_data.erase("development_since_year")
		player.source_data.erase("dev_from_shienka")
	entry["available"] = false
	entry["signed"] = true
	entry["to_team"] = to_team_id
	var signings: Array = state.get("signings", []) as Array
	signings.append({
		"player_id": player.id,
		"name": player.name,
		"age": player.age,
		"position": player.position,
		"role": player.role,
		"from_team": int(entry.get("from_team", 0)),
		"to_team": to_team_id,
		"foreign_player": player.foreign_player,
		"salary": player.salary,
		"value": int(entry.get("value", 0)),
		"war": float(entry.get("war", 0.0)),
		"method": method,
		"track": track,
		"development_player": track == TRACK_DEVELOPMENT,
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


static func _can_team_accept_candidate(players: Array, team_id: int, entry: Dictionary = {}) -> bool:
	if bool(entry.get("foreign_player", false)):
		if _foreign_count_for_team(players, team_id) >= ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM:
			return false
	# 育成track は支配下枠(SHIENKA_LIMIT)を消費せず、育成側にも人数上限は無い (2026-08-02)。
	# 獲得数は MAX_SIGNINGS_PER_TEAM と獲得スコアの側で抑える。
	if str(entry.get("track", TRACK_SHIENKA)) == TRACK_DEVELOPMENT:
		return true
	# ドラフトが後段補強用に残した hard 枠を使う。70枠はここで保証する。
	return _active_count_for_team(players, team_id) < TeamFinance.SHIENKA_LIMIT


static func _can_sign_entry(players: Array, entry: Dictionary) -> bool:
	return _is_released_market_player(_find_player_by_id(players, int(entry.get("player_id", 0))))


# 予算ゲート: 年俸を払っても予算内に収まるか。
static func _can_team_afford_release(players: Array, teams: Array, team_id: int, entry: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	return TeamFinance.can_afford_addition(players, team, int(entry.get("salary", 0)))


# 戦力外市場のAIは、今回の年俸に加えて後続のFA・外国人補強費も残す。
static func _can_ai_afford_release(players: Array, teams: Array, team_id: int, entry: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	var incoming_foreign: int = 1 if bool(entry.get("foreign_player", false)) else 0
	var reserve: int = TeamFinance.ai_offseason_budget_reserve(players, team_id, true, true, incoming_foreign)
	return TeamFinance.can_afford_ai_addition(players, team, int(entry.get("salary", 0)), reserve)


static func _is_released_market_player(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.team_id != 0:
		return false
	# 引退ステップの本物の引退者は retired のみ。戦力外は市場に出すため released も持つ。
	if player.is_retired() and not bool(player.source_data.get("released", false)):
		return false
	return bool(player.source_data.get("released", false))


# AIがその候補を獲得対象にするか。投手・野手を対称に「その球団の同一役割の最弱選手を上回る (=戦力
# アップグレードになる)」で判断する。投手はその球団の最弱投手、野手は同ポジションの最弱選手が基準。
# 旧実装は野手=リーグ相対 positional need / 投手=depth-fit と非対称で、投手 need が構造的に立たず
# 戦力外獲得が極端な野手偏重 (実測 投:野 ≈ 23:84) になっていた。役割数の偏り (投手は深く常に埋まる) と
# 野手が systematically 高 value な分は `_signing_score` の投手 parity で相殺する。
# 獲得基準 (2026-08-03 厳格化、ユーザー方針「戦力外はとりあえず取る枠ではない」)。
# **自軍のデプスチャート ([[TeamDepthChart]]) に照らして、即戦力 or 将来に賭ける価値がある選手だけ**を獲る:
#   - 即戦力 = その役割スロットの**一軍当落線** (先発6番手/救援8番手/そのポジションのレギュラー) を上回る
#   - 将来性 = 24歳以下で、成長の楽観側なら当落線に届き、かつそのスロットが将来空く
# どちらでもなければ獲らない = **0人で終わるオフが普通に起きる**。
# 旧基準は「自軍の同役割**最弱**選手を上回れば獲得」で、68人ロスターの最下位を超えれば通るため
# 事実上ほぼ全候補が該当し、全球団が毎年上限2人まで獲っていた (実測 1.95人/球団/年)。
static func _team_wants_candidate(players: Array, charts: Dictionary, team_id: int, entry: Dictionary) -> bool:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		return false
	var evaluation: Dictionary = TeamDepthChart.evaluate_candidate(charts.get(team_id, {}) as Dictionary, player)
	return bool(evaluation.get("fit", false))


# 獲得スコア = 能力 value + WAR + 投手 parity − 年俸負担。旧実装のポジション need 乗算は撤去
# (need は野手だけ立つため野手の score を過大にし、獲得枠を野手が独占していた)。投手 parity は野手が
# systematically 高 value (実測 p90 82 vs 78) な分を相殺し、獲得を NPB 実績どおり投打バランスさせる。
static func _signing_score(entry: Dictionary, _team_need: float, _players: Array, _teams: Array, _team_id: int) -> float:
	var score: float = float(entry.get("value", 0))
	score += float(entry.get("war", 0.0)) * 5.0
	score -= TeamFinance.ai_acquisition_cost_penalty(int(entry.get("salary", 0)))
	if int(entry.get("position", 0)) == 1:
		score += PITCHER_ACQUISITION_PARITY
	return score


# 投手 depth を反映する需要の単一ソースは OffseasonService.position_need
# ([[project_offseason_roster_mechanics]])。投手を「エース1枚」でなく上位K枚平均で測る。
static func _build_position_need(players: Array, teams: Array) -> Dictionary:
	return OffseasonService.position_need(players, teams)


static func _record_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	return float(WarCalculator.season_war(record, league_ctx).get("war", 0.0))


# roadmap #3: 支配下枠 (育成除外) の人数。計数の単一ソースは TeamFinance。
static func _active_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.shienka_count(players, team_id)


static func _foreign_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.foreign_player_count(players, team_id)


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
