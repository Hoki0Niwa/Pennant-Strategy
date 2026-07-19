extends RefCounted
class_name ForeignPlayerService

# R4: 外国人選手雇用。
# FAと同じく state 型にし、自軍だけ手動で複数獲得できるようにする。完全自動の
# process_foreign_market は長期検証/CPU用ラッパーとして維持する。

const NamePoolRef = preload("res://services/data/name_pool.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")
const ForeignActiveRosterRules = preload("res://services/simulation/game/foreign_active_roster_rules.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")
const ReleaseValueProjectorRef = preload("res://services/season/release_value_projector.gd")
const TeamAutoAIRef = preload("res://services/season/team_auto_ai.gd")

const FOREIGN_FA_YEARS: int = 7
const SCOUT_CANDIDATES_PER_REQUEST: int = 4
const MAX_CPU_REQUESTS_PER_TEAM: int = 4
const MAX_FOREIGN_HELD_PER_TEAM: int = TeamFinance.FOREIGN_HELD_TARGET
const FOREIGN_SLOT_FILL_BONUS: float = 10.0
# 保有外国人の投手・野手差1人ごとに、不足している種別のスカウト需要へ加える。
const CPU_FOREIGN_TYPE_BALANCE_BONUS: float = 8.0
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

# --- 外国人契約市場 (残留/引き抜き、スカウトの前段) ---
# 契約が切れた在籍外国人を一括オークション形式で解決する。新規スカウト (上記) は常に単年、
# 実績を積んだ外国人が複数年契約を得るのはこの市場だけ (NPB実態: 新規来日は単年、残留/移籍時に
# 複数年が付く)。市場入りの条件・解決手順は create_foreign_market_state / resolve_foreign_contract_market
# を参照。
# 元球団の複数年提示: value がこの水準以上なら CPU_FOREIGN_MULTI_YEAR_CHANCE の確率で2年、
# 3年目提示ラインを超えればさらに同確率で3年 (どちらも max_years でクランプ)。
const CPU_FOREIGN_MULTI_YEAR_VALUE: int = 70
const CPU_FOREIGN_MULTI_YEAR_VALUE_3Y: int = 78
const CPU_FOREIGN_MULTI_YEAR_CHANCE: float = 0.4
# 他球団の引き抜き: 外国人保有4人未満・支配下70枠と予算に余裕がある球団だけが対象。
const CPU_FOREIGN_POACH_CHANCE: float = 0.25
const CPU_FOREIGN_POACH_MAX_PER_TEAM: int = 1
# 引き抜き提示は市場年俸に上乗せする (残留より高く払わないと動かない)。
const FOREIGN_POACH_SALARY_MULT: float = 1.1
# 元球団は同条件の提示なら選手に有利 (残留を選びやすい)。offer_score にだけ掛かる。
const FOREIGN_STAY_LOYALTY: float = 1.15
# 提示年俸そのものへの複数年プレミアム (1年ごと)。
const FOREIGN_MULTI_YEAR_PREMIUM: float = 0.05
# 採択スコアの年数ボーナス (1年ごと)。長期保証を選手側が評価する想定。
const CONTRACT_OFFER_YEARS_SCORE_BONUS: float = 0.10


static func process_foreign_market(players: Array, teams: Array, season: PSSeason, user_team_id: int = 0) -> Dictionary:
	var state: Dictionary = create_foreign_market_state(players, teams, season, user_team_id)
	complete_foreign_market_automatically(state, players, teams, season, user_team_id)
	return finalize_foreign_market(state)


static func create_foreign_market_state(players: Array, teams: Array, season: PSSeason, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var contract_entries: Array = _build_contract_market_entries(players, teams, season)
	return {
		"version": 4,
		"phase": "contract" if not contract_entries.is_empty() else "scout",
		"year": year,
		"user_team_id": user_team_id,
		"complete": false,
		"finalized": false,
		"contract_entries": contract_entries,
		"contract_signings": [],
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


# v3→v4: 契約市場フェーズを追加。移行時点で進行中だった v3 セーブは、対象選手の再判定をせず
# scout フェーズへ直接復帰する (中断していた手動スカウトの継続を優先し、遡って契約市場を
# 割り込ませない)。
static func _ensure_state_v4(state: Dictionary) -> void:
	_ensure_state_v3(state)
	if int(state.get("version", 0)) >= 4:
		if not state.has("phase"):
			state["phase"] = "scout"
		if not state.has("contract_entries"):
			state["contract_entries"] = []
		if not state.has("contract_signings"):
			state["contract_signings"] = []
		return
	state["version"] = 4
	state["phase"] = "scout"
	state["contract_entries"] = []
	state["contract_signings"] = []


# スカウト操作 (configure_user_scout_request / submit_user_foreign_decision / auto_pick_for_user) の
# 共通フェーズガード。phase が "scout" 以外 (契約市場が未確定/結果表示中、またはスカウト結果表示中) なら
# 空でない {ok:false, message, state} を返す。呼び出し元はこれが空なら処理を継続してよい。
static func _scout_phase_guard(state: Dictionary) -> Dictionary:
	var phase: String = str(state.get("phase", "scout"))
	if phase == "contract" or phase == "contract_result":
		return {"ok": false, "message": "先に外国人契約市場を確定してください。", "state": state}
	if phase == "scout_result":
		return {"ok": false, "message": "外国人補強のスカウトは既に終了しています。", "state": state}
	return {}


static func configure_user_scout_request(state: Dictionary, position: String, archetype: String, budget_band: String) -> Dictionary:
	_ensure_state_v4(state)
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "外国人補強は既に完了しています。", "state": state}
	var phase_block: Dictionary = _scout_phase_guard(state)
	if not phase_block.is_empty():
		return phase_block
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
	_ensure_state_v4(state)
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "外国人補強は既に完了しています。", "state": state}
	var phase_block: Dictionary = _scout_phase_guard(state)
	if not phase_block.is_empty():
		return phase_block
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
	_ensure_state_v4(state)
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var phase_block: Dictionary = _scout_phase_guard(state)
	if not phase_block.is_empty():
		return phase_block
	var best_id: int = 0
	var best_score: float = -999999.0
	var need: Dictionary = FaMarketService._build_position_need(players, teams)
	for row in available_user_candidates(state, players, teams):
		var candidate: Dictionary = row as Dictionary
		if not bool(candidate.get("available", true)):
			continue
		if not _can_team_sign_foreign(players, state, user_team_id):
			break
		if not _cpu_scout_candidate_viable(candidate, players, user_team_id, season):
			continue
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


# show_result=true (「補強を終了」button) は自軍スカウトを打ち切った後 phase を "scout_result" に
# 留め、専用の結果パネル ("次へ" 操作) を経てから complete を立てる。show_result=false (CPU自動経路/
# レポーター/「すべてAIに任せる」) は結果パネルで止まらず即 complete=true にする。
static func complete_foreign_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0, show_result: bool = false) -> Dictionary:
	_ensure_state_v4(state)
	# 契約市場 (残留/引き抜き) が未解決なら、スカウトへ進む前に自動解決する。この経路は常に全自動
	# (auto_user_team=true) かつ結果パネルなし (show_result=false) で契約市場を通過する。
	if str(state.get("phase", "scout")) == "contract":
		resolve_foreign_contract_market(state, players, teams, season, user_team_id, true, false)
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
				if not _cpu_scout_candidate_viable(candidate, players, team.id, season):
					continue
				if not _can_team_afford_foreign(players, teams, team.id, candidate):
					continue
				var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(candidate.get("position", 0)), 0.0))
				var score: float = _signing_score(candidate, team_need, players, teams, team.id)
				if score > best_score:
					best_score = score
					best = candidate
			if best.is_empty():
				_close_request_candidates(state, _candidate_ids(shortlist), true)
				# 1回の候補群に適格者がいなくても、残りの検索回数は別候補へ使う。
				# ここで打ち切ると、残留を見送って空けた枠を新外国人で補充しない球団が
				# 生じるため、MAX_CPU_REQUESTS_PER_TEAM の範囲では探索を継続する。
				continue
			_apply_signing(state, players, teams, season, best, team.id, "cpu")
			_close_request_candidates(state, _candidate_ids(shortlist), false)
	if show_result:
		state["phase"] = "scout_result"
	else:
		state["complete"] = true
	return {"ok": true, "state": state}


static func complete_all_foreign_market_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	_ensure_state_v4(state)
	# 手動検索中の候補を閉じてから、自球団を除外せず全チームを同じAIロジックへ流す。
	_close_request_candidates(state, state.get("user_candidate_ids", []) as Array, true)
	state["user_request"] = {}
	state["user_candidate_ids"] = []
	return complete_foreign_market_automatically(state, players, teams, season, 0)


static func finalize_foreign_market(state: Dictionary) -> Dictionary:
	_ensure_state_v4(state)
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var signings: Array = (state.get("signings", []) as Array).duplicate(true)
	signings.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	var contract_signings: Array = (state.get("contract_signings", []) as Array).duplicate(true)
	var contract_retained: int = 0
	var contract_poached: int = 0
	var contract_departed: int = 0
	var contract_multi_year: int = 0
	for row in contract_signings:
		var entry: Dictionary = row as Dictionary
		match str(entry.get("outcome", "")):
			"retained":
				contract_retained += 1
			"poached":
				contract_poached += 1
			"departed":
				contract_departed += 1
		if int(entry.get("years", 0)) > 1:
			contract_multi_year += 1
	var result: Dictionary = {
		"candidates_count": (state.get("candidates", []) as Array).size(),
		"signings": signings,
		"signed_count": signings.size(),
		"contract_signings": contract_signings,
		"contract_retained_count": contract_retained,
		"contract_poached_count": contract_poached,
		"contract_departed_count": contract_departed,
		"contract_multi_year_count": contract_multi_year,
	}
	state["finalized"] = true
	state["complete"] = true
	state["final_result"] = result
	return result


static func available_user_candidates(state: Dictionary, players: Array, teams: Array) -> Array:
	_ensure_state_v4(state)
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
	var year: int = _season.year if _season != null else int(state.get("year", 0))
	# 新規スカウト獲得は常に単年契約。実績を積んでからの複数年は外国人契約市場 (残留/引き抜き) のみ。
	var source: Dictionary = data.get("source_data", {}) as Dictionary
	source["contract_end_year"] = year + 1
	source["contract_total_years"] = 1
	source["contract_signed_year"] = year
	data["source_data"] = source
	var player: PSPlayer = PSPlayer.from_dict(data)
	PSCareerLog.log_foreign_join(player, year, team_id, player.salary)
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


# ============================================================ 外国人契約市場 (残留/引き抜き)

# 市場入りの対象: 在籍中 (非引退) の外国人で、複数年契約中でない者
# (契約キー欠落の旧セーブ/初期シード外国人は contract_end_year=0 なので全員対象になる=意図した移行挙動)。
static func _build_contract_market_entries(players: Array, teams: Array, season: PSSeason) -> Array:
	var year: int = season.year if season != null else 0
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var regular_ids_by_team: Dictionary = {}
	var entries: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or not player.foreign_player or player.is_retired() or player.team_id <= 0:
			continue
		if player.is_multi_year_locked_offseason(year):
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var war: float = _contract_record_war(record, league_ctx)
		if not regular_ids_by_team.has(player.team_id):
			regular_ids_by_team[player.team_id] = _cpu_regular_role_ids(
				players, player.team_id, season, league_ctx
			)
		entries.append({
			"player_id": player.id,
			"from_team_id": player.team_id,
			"name": player.name,
			"age": player.age,
			"position": player.position,
			"role": player.role,
			"value": OffseasonService.player_value_score(player),
			"projected_value": ReleaseValueProjectorRef.projected_value(player, record),
			"cpu_release_candidate": OffseasonService.would_release_player_for_team(
				players, player.team_id, player, season
			),
			"cpu_regular_candidate": (regular_ids_by_team[player.team_id] as Dictionary).has(player.id),
			"market_salary": OffseasonService.foreign_market_salary(player, record, war),
			"max_years": FaMarketService.fa_offer_max_years(player.age),
			"user_offer": {},
			"resolved": false,
			"winner_team_id": 0,
			"winner_years": 0,
			"winner_salary": 0,
		})
	entries.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	return entries


static func _contract_record_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	return float(WarCalculator.season_war(record, league_ctx).get("war", 0.0))


static func _contract_performance_score(player: PSPlayer, record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null:
		return ReleaseValueProjectorRef.projected_value(player, null)
	return TeamAutoAIRef.perf_score(record, null, null, _contract_record_war(record, league_ctx))


static func _sort_contract_performance_rows(rows: Array) -> void:
	rows.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if not is_equal_approx(float(da.get("score", 0.0)), float(db.get("score", 0.0))):
			return float(da.get("score", 0.0)) > float(db.get("score", 0.0))
		return int(da.get("player_id", 0)) < int(db.get("player_id", 0))
	)


# 当年成績を含む連続スコアで、野手は各位置の1番手+DH、投手は一軍の先発・救援枠を選ぶ。
# 絶対的な率/出場数足切りを置かず、球団内の役割デプスでレギュラー級かを判定する。
static func _cpu_regular_role_ids(players: Array, team_id: int, season: PSSeason, league_ctx: Dictionary = {}) -> Dictionary:
	var ctx: Dictionary = league_ctx
	if ctx.is_empty() and season != null:
		ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var groups: Dictionary = {}
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or player.development_player:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var role_key: String
		if player.is_pitcher():
			role_key = "pitcher:starter" if player.role == "starter" else "pitcher:reliever"
		else:
			role_key = "fielder:%d" % player.position
		if not groups.has(role_key):
			groups[role_key] = []
		(groups[role_key] as Array).append({
			"player_id": player.id,
			"score": _contract_performance_score(player, record, ctx),
		})

	var regular_ids: Dictionary = {}
	var dh_candidates: Array = []
	for position in range(2, 10):
		var fielders: Array = groups.get("fielder:%d" % position, []) as Array
		_sort_contract_performance_rows(fielders)
		if not fielders.is_empty():
			regular_ids[int((fielders[0] as Dictionary).get("player_id", 0))] = true
		for i in range(1, fielders.size()):
			dh_candidates.append(fielders[i])
	_sort_contract_performance_rows(dh_candidates)
	if not dh_candidates.is_empty():
		regular_ids[int((dh_candidates[0] as Dictionary).get("player_id", 0))] = true

	var starters: Array = groups.get("pitcher:starter", []) as Array
	_sort_contract_performance_rows(starters)
	for i in range(mini(starters.size(), TeamAutoAIRef.TARGET_STARTERS)):
		regular_ids[int((starters[i] as Dictionary).get("player_id", 0))] = true
	var relievers: Array = groups.get("pitcher:reliever", []) as Array
	_sort_contract_performance_rows(relievers)
	var relief_slots: int = maxi(1, TeamAutoAIRef.TARGET_PITCHERS - TeamAutoAIRef.TARGET_STARTERS)
	for i in range(mini(relievers.size(), relief_slots)):
		regular_ids[int((relievers[i] as Dictionary).get("player_id", 0))] = true
	return regular_ids


static func _would_be_cpu_regular_for_team(players: Array, team_id: int, candidate: PSPlayer, season: PSSeason) -> bool:
	if candidate == null or team_id <= 0:
		return false
	var evaluation_players: Array = players
	if candidate.team_id != team_id or candidate.is_retired():
		evaluation_players = players.duplicate()
		var hypothetical: PSPlayer = PSPlayer.from_dict(candidate.to_dict())
		hypothetical.team_id = team_id
		hypothetical.source_data.erase("retired")
		evaluation_players.append(hypothetical)
	return _cpu_regular_role_ids(evaluation_players, team_id, season).has(candidate.id)


static func _contract_entry_by_player_id(state: Dictionary, player_id: int) -> Dictionary:
	for row in state.get("contract_entries", []) as Array:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("player_id", 0)) == player_id:
			return entry
	return {}


# 契約市場を作成済みのセーブにはCPU評価が無い場合があるため、解決直前に共通戦力外・レギュラー評価を補う。
static func _ensure_cpu_contract_evaluations(entries: Array, players: Array, season: PSSeason) -> void:
	var regular_ids_by_team: Dictionary = {}
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
		var team_id: int = int(entry.get("from_team_id", 0))
		if not entry.has("cpu_release_candidate"):
			entry["cpu_release_candidate"] = OffseasonService.would_release_player_for_team(
				players, team_id, player, season
			)
		if not entry.has("cpu_regular_candidate"):
			if not regular_ids_by_team.has(team_id):
				regular_ids_by_team[team_id] = _cpu_regular_role_ids(players, team_id, season)
			entry["cpu_regular_candidate"] = (regular_ids_by_team[team_id] as Dictionary).has(
				int(entry.get("player_id", 0))
			)


# 提示年俸 = ベース年俸 × (1 + FOREIGN_MULTI_YEAR_PREMIUM × (年数-1))。有効数字2桁へ丸める。
static func _offer_salary(base_salary: int, years: int) -> int:
	var raw: int = int(round(float(base_salary) * (1.0 + FOREIGN_MULTI_YEAR_PREMIUM * float(maxi(1, years) - 1))))
	return OffseasonService.round_salary_2sig(raw)


# 採択スコア = 年俸 × (1 + 0.10×(年数-1)) × (元球団なら FOREIGN_STAY_LOYALTY)。
static func _contract_offer_score(salary: int, years: int, is_home: bool) -> float:
	var score: float = float(salary) * (1.0 + CONTRACT_OFFER_YEARS_SCORE_BONUS * float(maxi(1, years) - 1))
	if is_home:
		score *= FOREIGN_STAY_LOYALTY
	return score


# CPU の複数年提示年数: 既定1年、value がしきい値を超えるたびに確率で+1年 (max_years でクランプ)。
static func _cpu_retain_years(value: int, max_years: int) -> int:
	var years: int = 1
	if value >= CPU_FOREIGN_MULTI_YEAR_VALUE and Rng.roll_float() <= CPU_FOREIGN_MULTI_YEAR_CHANCE:
		years = 2
		if value >= CPU_FOREIGN_MULTI_YEAR_VALUE_3Y and Rng.roll_float() <= CPU_FOREIGN_MULTI_YEAR_CHANCE:
			years = 3
	return clampi(years, 1, maxi(1, max_years))


# 元球団の残留提示。共通戦力外評価の対象、レギュラー枠外、または増額分を払えない場合は提示しない。
static func _cpu_retain_offer(entry: Dictionary, players: Array, teams: Array) -> Dictionary:
	var value: int = int(entry.get("value", 0))
	if bool(entry.get("cpu_release_candidate", false)) or not bool(entry.get("cpu_regular_candidate", true)):
		return {}
	var team: PSTeam = _find_team_by_id(teams, int(entry.get("from_team_id", 0)))
	if team == null:
		return {}
	var years: int = _cpu_retain_years(value, int(entry.get("max_years", 1)))
	var salary: int = _offer_salary(int(entry.get("market_salary", 0)), years)
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	var current_salary: int = player.salary if player != null else salary
	var delta: int = maxi(0, salary - current_salary)
	if not TeamFinance.can_afford_addition(players, team, delta):
		return {}
	return {"source": "retain", "team_id": team.id, "years": years, "salary": salary, "is_home": true}


# 1エントリ分の提示一覧を組む。ユーザー提示 (submit_user_contract_offer で設定済み) があれば
# その球団分のCPU自動提示 (残留 or 引き抜き) を差し替える。poach_counts は解決ループ全体で
# 共有し、1球団あたりの引き抜き件数 (CPU_FOREIGN_POACH_MAX_PER_TEAM) を跨エントリで制限する。
# ユーザー球団 (user_team_id) が home_team かつ user_offer が無い場合、auto_user_team=false なら
# CPU残留提示を生成しない (=「契約市場を確定して次へ」はユーザーの明示提示のみを扱う)。
# auto_user_team=true (「すべてAIに任せる」/CPU自動経路) なら他球団と同じ基準で残留提示を生成する。
static func _build_contract_offers(entry: Dictionary, players: Array, teams: Array, poach_counts: Dictionary, user_team_id: int = 0, auto_user_team: bool = false, season: PSSeason = null) -> Array:
	var offers: Array = []
	var home_team_id: int = int(entry.get("from_team_id", 0))
	var user_offer: Dictionary = entry.get("user_offer", {}) as Dictionary
	var user_offer_team: int = int(user_offer.get("team_id", 0)) if not user_offer.is_empty() else 0

	if not user_offer.is_empty() and user_offer_team == home_team_id:
		offers.append(user_offer.duplicate())
	elif home_team_id == user_team_id and not auto_user_team:
		pass
	else:
		var retain: Dictionary = _cpu_retain_offer(entry, players, teams)
		if not retain.is_empty():
			offers.append(retain)

	if not user_offer.is_empty() and user_offer_team != home_team_id:
		offers.append(user_offer.duplicate())

	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player != null:
		var max_years: int = int(entry.get("max_years", 1))
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null or team.id == home_team_id or team.id == user_offer_team:
				continue
			if int(poach_counts.get(team.id, 0)) >= CPU_FOREIGN_POACH_MAX_PER_TEAM:
				continue
			if _foreign_count_for_team(players, team.id) >= MAX_FOREIGN_HELD_PER_TEAM:
				continue
			if Rng.roll_float() > CPU_FOREIGN_POACH_CHANCE:
				continue
			var years: int = clampi(Rng.range_int(1, mini(3, max_years)), 1, max_years)
			var salary: int = _offer_salary(int(round(float(entry.get("market_salary", 0)) * FOREIGN_POACH_SALARY_MULT)), years)
			var evaluated_player: PSPlayer = PSPlayer.from_dict(player.to_dict())
			evaluated_player.salary = salary
			if OffseasonService.would_release_player_for_team(players, team.id, evaluated_player, season):
				continue
			if not _would_be_cpu_regular_for_team(players, team.id, evaluated_player, season):
				continue
			offers.append({"source": "poach", "team_id": team.id, "years": years, "salary": salary, "is_home": false})
			poach_counts[team.id] = int(poach_counts.get(team.id, 0)) + 1
	return offers


# 最高スコアの提示から順に枠/予算を確認して採択する (通らなければ次点)。誰も採択できなければ退団。
static func _apply_best_contract_offer(players: Array, teams: Array, entry: Dictionary, offers: Array, year: int) -> Dictionary:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		return {}
	var home_team_id: int = int(entry.get("from_team_id", 0))
	var ranked: Array = offers.duplicate()
	ranked.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		return _contract_offer_score(int(da.get("salary", 0)), int(da.get("years", 1)), bool(da.get("is_home", false))) \
				> _contract_offer_score(int(db.get("salary", 0)), int(db.get("years", 1)), bool(db.get("is_home", false)))
	)
	for offer_value in ranked:
		var offer: Dictionary = offer_value as Dictionary
		var team_id: int = int(offer.get("team_id", 0))
		var team: PSTeam = _find_team_by_id(teams, team_id)
		if team == null:
			continue
		var is_home: bool = bool(offer.get("is_home", false))
		var salary: int = int(offer.get("salary", 0))
		var years: int = int(offer.get("years", 1))
		if is_home:
			var delta: int = maxi(0, salary - player.salary)
			if not TeamFinance.can_afford_addition(players, team, delta):
				continue
		else:
			if not _can_team_sign_foreign(players, {}, team_id):
				continue
			if not TeamFinance.can_afford_addition(players, team, salary):
				continue
		var from_team: int = player.team_id
		_apply_contract_result(player, team_id, is_home, years, salary, year)
		return {
			"player_id": player.id, "name": player.name, "age": player.age, "position": player.position,
			"role": player.role, "from_team": from_team, "to_team": team_id, "salary": salary, "years": years,
			"value": int(entry.get("value", 0)), "outcome": "retained" if is_home else "poached",
		}
	_apply_contract_departure(player, home_team_id, year)
	return {
		"player_id": player.id, "name": player.name, "age": player.age, "position": player.position,
		"role": player.role, "from_team": home_team_id, "to_team": 0, "salary": 0, "years": 0,
		"value": int(entry.get("value", 0)), "outcome": "departed",
	}


static func _apply_contract_result(player: PSPlayer, team_id: int, is_home: bool, years: int, salary: int, year: int) -> void:
	var from_team: int = player.team_id
	player.team_id = team_id
	player.salary = salary
	player.source_data["contract_end_year"] = year + years
	player.source_data["contract_total_years"] = years
	player.source_data["contract_signed_year"] = year
	if is_home:
		PSCareerLog.log_foreign_stay(player, year, team_id, salary)
	else:
		PSCareerLog.log_foreign_move(player, year, from_team, team_id, salary)


# 退団 (帰国) 扱い: retired のみ立て released は立てない。戦力外獲得市場は released を条件に
# 候補を拾うため、これにより退団外国人はそちらへ供給されない。
static func _apply_contract_departure(player: PSPlayer, team_id: int, year: int) -> void:
	PSCareerLog.log_foreign_depart(player, year, team_id)
	player.source_data["retired"] = true
	player.source_data["retired_age"] = player.age
	player.team_id = 0


# 契約市場を一括解決する (エントリを value 降順に1件ずつ、残留/引き抜き/退団を決めていく)。
# 逐次処理にすることで、枠/予算/引き抜き上限を先に解決したエントリの結果に正しく追従させる。
# auto_user_team=false (既定、「契約市場を確定して次へ」) はユーザー球団の未提示エントリへ
# CPU残留提示を生成しない (=明示提示のみ扱う)。auto_user_team=true (「すべてAIに任せる」/
# CPU自動経路) は他球団と同じ基準でユーザー球団にも自動残留判断を適用する。
# show_result=true (既定) は解決後 phase を "contract_result" に留め、専用結果パネル ("次へ") を
# 経てから "scout" へ進む。show_result=false (CPU自動経路/「すべてAIに任せる」) は結果パネルを
# 経由せず直接 "scout" へ進む。対象が最初から無ければ create_foreign_market_state の時点で
# 既に "scout" になっており、この関数は何もしない。
static func resolve_foreign_contract_market(state: Dictionary, players: Array, teams: Array, season: PSSeason, user_team_id: int = 0, auto_user_team: bool = false, show_result: bool = true) -> Dictionary:
	_ensure_state_v4(state)
	if str(state.get("phase", "contract")) != "contract":
		return {"ok": true, "state": state}
	var year: int = int(state.get("year", season.year if season != null else 0))
	var entries: Array = state.get("contract_entries", []) as Array
	_ensure_cpu_contract_evaluations(entries, players, season)
	var poach_counts: Dictionary = {}
	var contract_signings: Array = state.get("contract_signings", []) as Array
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		if bool(entry.get("resolved", false)):
			continue
		var offers: Array = _build_contract_offers(entry, players, teams, poach_counts, user_team_id, auto_user_team, season)
		var applied: Dictionary = _apply_best_contract_offer(players, teams, entry, offers, year)
		entry["resolved"] = true
		if not applied.is_empty():
			entry["winner_team_id"] = int(applied.get("to_team", 0))
			entry["winner_years"] = int(applied.get("years", 0))
			entry["winner_salary"] = int(applied.get("salary", 0))
			contract_signings.append(applied)
	state["contract_entries"] = entries
	state["contract_signings"] = contract_signings
	state["phase"] = "contract_result" if show_result else "scout"
	return {"ok": true, "state": state}


# 契約市場の結果パネル ("次へ") から呼ばれ、phase を "contract_result" → "scout" へ進める。
static func advance_foreign_contract_result(state: Dictionary) -> Dictionary:
	_ensure_state_v4(state)
	if str(state.get("phase", "")) != "contract_result":
		return {"ok": false, "message": "外国人契約市場の結果は表示されていません。", "state": state}
	state["phase"] = "scout"
	return {"ok": true, "state": state}


# 外国人スカウトの結果パネル ("次へ") から呼ばれ、phase "scout_result" を経て complete を立てる。
static func advance_foreign_scout_result(state: Dictionary) -> Dictionary:
	_ensure_state_v4(state)
	if str(state.get("phase", "")) != "scout_result":
		return {"ok": false, "message": "外国人補強の結果は表示されていません。", "state": state}
	state["complete"] = true
	return {"ok": true, "state": state}


# ユーザーの契約提示 (自軍満了者への残留提示、または他球団満了者への引き抜き提示)。
# 予算/枠は速報チェックのみで、最終確認は resolve_foreign_contract_market の採択時に再度行う。
static func submit_user_contract_offer(state: Dictionary, players: Array, teams: Array, _season: PSSeason, player_id: int, years: int) -> Dictionary:
	_ensure_state_v4(state)
	if str(state.get("phase", "contract")) != "contract":
		return {"ok": false, "message": "外国人契約市場は既に終了しています。", "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if user_team_id <= 0:
		return {"ok": false, "message": "自球団が選択されていません。", "state": state}
	var entry: Dictionary = _contract_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は外国人契約市場の対象ではありません。", "state": state}
	if bool(entry.get("resolved", false)):
		return {"ok": false, "message": "その選手の契約市場は既に解決済みです。", "state": state}
	var home_team_id: int = int(entry.get("from_team_id", 0))
	var is_home: bool = home_team_id == user_team_id
	if not is_home:
		if _foreign_count_for_team(players, user_team_id) >= MAX_FOREIGN_HELD_PER_TEAM:
			return {"ok": false, "message": "外国人保有枠が不足しています。", "state": state}
		if _active_count_for_team(players, user_team_id) >= TeamFinance.SHIENKA_LIMIT:
			return {"ok": false, "message": "支配下枠が不足しています。", "state": state}
	var max_years: int = int(entry.get("max_years", 1))
	var clamped_years: int = clampi(years, 1, maxi(1, max_years))
	var base_salary: int = int(entry.get("market_salary", 0))
	if not is_home:
		base_salary = int(round(float(base_salary) * FOREIGN_POACH_SALARY_MULT))
	var salary: int = _offer_salary(base_salary, clamped_years)
	var team: PSTeam = _find_team_by_id(teams, user_team_id)
	var cost: int = salary
	if is_home:
		var player: PSPlayer = _find_player_by_id(players, player_id)
		cost = maxi(0, salary - (player.salary if player != null else 0))
	if not TeamFinance.can_afford_addition(players, team, cost):
		return {"ok": false, "message": "予算が不足しているため提示できません。", "state": state}
	entry["user_offer"] = {"team_id": user_team_id, "years": clamped_years, "salary": salary, "is_home": is_home}
	return {"ok": true, "state": state}


static func withdraw_user_contract_offer(state: Dictionary, player_id: int) -> Dictionary:
	_ensure_state_v4(state)
	var entry: Dictionary = _contract_entry_by_player_id(state, player_id)
	if entry.is_empty():
		return {"ok": false, "message": "その選手は外国人契約市場の対象ではありません。", "state": state}
	entry["user_offer"] = {}
	return {"ok": true, "state": state}


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


static func _scouted_candidate_projection_player(candidate: Dictionary) -> PSPlayer:
	var data: Dictionary = candidate.get("display_player_data", {}) as Dictionary
	if data.is_empty():
		data = candidate.get("player_data", {}) as Dictionary
	if data.is_empty():
		return null
	var evaluation_data: Dictionary = data.duplicate(true)
	evaluation_data["salary"] = int(candidate.get("salary", evaluation_data.get("salary", 0)))
	return PSPlayer.from_dict(evaluation_data)


static func _cpu_scout_candidate_viable(candidate: Dictionary, players: Array, team_id: int, season: PSSeason) -> bool:
	var evaluation_player: PSPlayer = _scouted_candidate_projection_player(candidate)
	return not OffseasonService.would_release_player_for_team(
		players, team_id, evaluation_player, season
	)


static func _signing_score(candidate: Dictionary, team_need: float, players: Array, _teams: Array, team_id: int) -> float:
	var held: int = _foreign_count_for_team(players, team_id)
	var open_slots: int = max(0, MAX_FOREIGN_HELD_PER_TEAM - held)
	# CPUもプレイヤーと同じスカウト情報だけを使い、実能力を透視しない。
	var evaluation_player: PSPlayer = _scouted_candidate_projection_player(candidate)
	var projection: float = ReleaseValueProjectorRef.projected_value(evaluation_player, null) \
		if evaluation_player != null else float(candidate.get("estimated_value", candidate.get("value", 0))) \
		- TeamFinance.ai_acquisition_cost_penalty(int(candidate.get("salary", 0)))
	var score: float = projection * (1.0 + team_need / 20.0)
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
	var salary: int = OffseasonService.round_salary_2sig(Rng.range_int(int(band.get("salary_min", 6000)), int(band.get("salary_max", 12000))))
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
	var desired_fielder_position: int = 2
	var highest_fielder_need: float = -999999.0
	for position_value in range(2, 10):
		var position_need: float = float(team_need.get(position_value, 0.0))
		if position_need > highest_fielder_need:
			highest_fielder_need = position_need
			desired_fielder_position = position_value
	var foreign_types: Dictionary = _foreign_type_counts_for_team(players, team.id)
	var foreign_pitchers: int = int(foreign_types.get("pitchers", 0))
	var foreign_fielders: int = int(foreign_types.get("fielders", 0))
	var pitcher_need: float = float(team_need.get(1, 0.0)) \
		+ float(maxi(0, foreign_fielders - foreign_pitchers)) * CPU_FOREIGN_TYPE_BALANCE_BONUS
	var fielder_need: float = highest_fielder_need \
		+ float(maxi(0, foreign_pitchers - foreign_fielders)) * CPU_FOREIGN_TYPE_BALANCE_BONUS
	var desired_position: int = 1 if pitcher_need >= fielder_need else desired_fielder_position
	# 同一種別の4人目は一軍登録できないため、空いている種別を優先する。
	if foreign_fielders >= ForeignActiveRosterRules.TYPE_MAX:
		desired_position = 1
	elif foreign_pitchers >= ForeignActiveRosterRules.TYPE_MAX:
		desired_position = desired_fielder_position
	var position_key: String = _request_key_for_position(players, team.id, desired_position)
	var archetype: String = _weakest_archetype(players, team.id, position_key)
	var room: int = TeamFinance.budget_room(team.funds, TeamFinance.team_payroll(players, team.id))
	var open_slots: int = maxi(1, MAX_FOREIGN_HELD_PER_TEAM - _foreign_count_for_team(players, team.id))
	var budget_band: String = _cpu_budget_band(room, open_slots)
	return {
		"team_id": team.id,
		"position": position_key,
		"archetype": archetype,
		"budget_band": budget_band,
		"method": "cpu",
	}


# 残予算を未充足枠へ均等配分し、各枠の予算で候補帯の上限まで払える最高帯を選ぶ。
# 先に高額選手1人へ使い切って残り枠を補充できなくなることを防ぐ。
static func _cpu_budget_band(room: int, open_slots: int) -> String:
	var per_slot: int = floori(float(maxi(0, room)) / float(maxi(1, open_slots)))
	for band_name in ["star", "core", "standard", "bargain"]:
		var band: Dictionary = BUDGET_BANDS[band_name] as Dictionary
		if per_slot >= int(band.get("salary_max", 0)):
			return band_name
	return "bargain"


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
	return TeamFinance.foreign_player_count(players, team_id)


static func _foreign_type_counts_for_team(players: Array, team_id: int) -> Dictionary:
	var pitchers: int = 0
	var fielders: int = 0
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or not player.foreign_player:
			continue
		if player.is_pitcher():
			pitchers += 1
		else:
			fielders += 1
	return {"pitchers": pitchers, "fielders": fielders}


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


static func _find_player_by_id(players: Array, player_id: int) -> PSPlayer:
	for row in players:
		var player: PSPlayer = row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null
