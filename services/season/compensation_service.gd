extends RefCounted
class_name CompensationService

# FA の人的補償 (プロテクト28人)。FA市場の直後に独立ステップとして走る。
#
# 進行は NPB の実手順に合わせてケース単位で回す:
#   1. 獲得球団がプロテクト28人を提出する
#   2. 元球団が非プロテクト選手を見て「人的補償」か「金銭補償のみ」を選ぶ
#   3. 人的補償なら非プロテクトから1人を指名し、その場で移籍させる
#
# 補償金は FA成立時 (FaMarketService._apply_signing) に「金銭のみ」の額 (A80%/B60%) を既に
# 動かしてある。人的補償を選んだケースだけ、差額 (A→50% / B→40% へ減額) を獲得球団へ払い戻す。
#
# **複数年契約中の選手も対象**にする (NPB実準拠)。他の経路 (FA宣言/戦力外/トレード/現役ドラフト)
# は is_multi_year_locked_offseason でロックしているが、あれは「球団が自分の意思で選手を動かす/
# 年俸を査定し直す」のを止めるためのガードで、人的補償は他球団に強制的に取られる経路なので
# ここだけロックを見ない。契約 (contract_end_year 等) は source_data ごと選手について移籍先へ移る。

const STATE_VERSION: int = 1

# プロテクト枠。自動保護 (外国人/育成/当年新人/当オフFA加入) はこの枠を消費しない。
const PROTECT_SIZE: int = 28

# 人的補償を選んだ場合の金銭補償率 (金銭のみは FaMarketService の A80%/B60%)。
const RANK_A_PLAYER_COMPENSATION_RATE: float = 0.50
const RANK_B_PLAYER_COMPENSATION_RATE: float = 0.40

# --- CPU のプロテクト選定 ---
# 保護の軸は OffseasonService.future_value_score (現在能力 + 成長期待 − 故障リスク)。
# 「今リーグ最強か」ではなく「今後も戦力か」で守るので、若手有望株が自然に残る。
# 捕手は代替が効かないので係数で優先し、それでも枠から漏れる場合は下記の最低人数を保証する。
const PROTECT_CATCHER_WEIGHT: float = 1.06
const PROTECT_CATCHER_MIN: int = 2

# --- CPU の指名判断 ---
# 候補の足切りスコア。スコアは value 尺度 (支配下平均 ≒ 69) に need と将来性のボーナスを足し、
# 年齢係数を掛けたもの。**人的/金銭の分岐を実際に決めているのはこの値ではなく
# cpu_pick_player_id の 2 条件 (depth chart の fit / 予算)** — 理由はそちらのコメント。
const PICK_MIN_SCORE: float = 62.0
# 補強需要 (TeamDepthChart の first_team_need、単位は value) の加算率。
const PICK_NEED_WEIGHT: float = 0.5
const PICK_NEED_MAX: float = 8.0
# 将来価値 (future_value_score − player_value_score) の加算率。素材型を拾いに行く度合い。
const PICK_FUTURE_WEIGHT: float = 0.4
# 年齢係数。プロテクト側は future_value_score (年齢で割り引く) で守るので、非プロテクトには
# 「能力は高いが高齢」が大量に残る。指名側を素の value だけで判断させると毎回そこから
# 34〜36歳を取っていく (2026-09-05 の実測: 4件すべて33〜36歳) ため、指名側にも年齢を効かせる。
const PICK_PRIME_MAX_AGE: int = 30
const PICK_AGE_DECAY: float = 0.045
const PICK_AGE_FLOOR: float = 0.70


static func create_compensation_state(players: Array, teams: Array, season: PSSeason, fa_state: Dictionary, user_team_id: int) -> Dictionary:
	var year: int = season.year if season != null else 0
	var state: Dictionary = {
		"version": STATE_VERSION,
		"year": year,
		"user_team_id": user_team_id,
		"phase": "done",
		"complete": false,
		"finalized": false,
		"waiting_user": false,
		"index": 0,
		"cases": [],
		"logs": [],
	}
	var cases: Array = []
	for signing_row in fa_state.get("signings", []) as Array:
		var signing: Dictionary = signing_row as Dictionary
		var case: Dictionary = _build_case(signing)
		if not case.is_empty():
			cases.append(case)
	state["cases"] = cases
	return _advance_until_user_or_complete(state, players, teams, season, user_team_id <= 0)


# 補償対象になる FA 移籍 1 件から case を組む。対象外 (Cランク/残留/元球団不明) なら空 dict。
static func _build_case(signing: Dictionary) -> Dictionary:
	var fa_rank: String = str(signing.get("fa_rank", "C"))
	if fa_rank != "A" and fa_rank != "B":
		return {}
	var from_team: int = int(signing.get("from_team", 0))
	var to_team: int = int(signing.get("to_team", 0))
	if from_team <= 0 or to_team <= 0 or from_team == to_team:
		return {}
	var money_only: int = int(signing.get("compensation_money", 0))
	var former_salary: int = int(signing.get("former_salary", 0))
	var money_with_player: int = _player_compensation_money(fa_rank, former_salary)
	return {
		"player_id": int(signing.get("player_id", 0)),
		"name": str(signing.get("name", "")),
		"fa_rank": fa_rank,
		"from_team": from_team,
		"to_team": to_team,
		"former_salary": former_salary,
		"money_only": money_only,
		"money_with_player": money_with_player,
		# プールはケースが自分の番になった時点で組む (_ensure_case_pool)。生成時に一括で
		# スナップショットすると、同じ球団が絡む先行ケースで動いた選手が残ってしまう。
		"eligible_ids": [],
		"locked_ids": [],
		"pool_built": false,
		"protect_ids": [],
		"protect_submitted": false,
		"decision": "",
		"picked_player_id": 0,
		"forced_reason": "",
		"resolved": false,
	}


# ケースが処理対象になった時点で、獲得球団のプロテクト対象を組む。
# 人的補償が成立しない条件 (forced_reason) もここで確定させる。
static func _ensure_case_pool(players: Array, case: Dictionary, year: int) -> void:
	if bool(case.get("pool_built", false)):
		return
	var pool: Dictionary = protectable_pool(players, int(case.get("to_team", 0)), year)
	var eligible_ids: Array = pool.get("eligible_ids", []) as Array
	case["eligible_ids"] = eligible_ids
	case["locked_ids"] = pool.get("locked_ids", []) as Array
	case["pool_built"] = true
	# 選べる選手が枠に満たない (= 全員自動プロテクト) / 元球団に支配下枠が無い場合は金銭のみ。
	if eligible_ids.size() <= PROTECT_SIZE:
		case["forced_reason"] = "protect_covers_all"
	elif TeamFinance.controlled_count(players, int(case.get("from_team", 0))) >= TeamFinance.CONTROLLED_LIMIT:
		case["forced_reason"] = "roster_full"


static func _player_compensation_money(fa_rank: String, former_salary: int) -> int:
	var rate: float = RANK_B_PLAYER_COMPENSATION_RATE if fa_rank == "B" else RANK_A_PLAYER_COMPENSATION_RATE
	return int(round(float(former_salary) * rate))


# ============================================================ プロテクト対象

# 獲得球団のロースターを「プロテクト枠で選べる選手」と「自動保護 (枠を消費しない)」に分ける。
# 自動保護: 育成選手 / 外国人選手 / 当年ドラフト入団の新人 / 当オフに FA・人的補償で加入した選手。
# 当該FA選手本人は fa_signed_year が当年なのでここに含まれる。
static func protectable_pool(players: Array, team_id: int, year: int) -> Dictionary:
	var eligible_ids: Array = []
	var locked_ids: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired():
			continue
		if player.development_player:
			continue
		if is_auto_protected(player, year):
			locked_ids.append(player.id)
		else:
			eligible_ids.append(player.id)
	return {"eligible_ids": eligible_ids, "locked_ids": locked_ids}


static func is_auto_protected(player: PSPlayer, year: int) -> bool:
	if player == null:
		return true
	if player.foreign_player:
		return true
	if year > 0 and int(player.source_data.get("draft_year", 0)) == year:
		return true
	if player.years <= 0 and bool(player.source_data.get("rookie_year", false)):
		return true
	if year > 0 and int(player.source_data.get("fa_signed_year", 0)) == year:
		return true
	if year > 0 and int(player.source_data.get("compensation_year", 0)) == year:
		return true
	return false


static func auto_protected_reason(player: PSPlayer, year: int) -> String:
	if player == null:
		return ""
	if player.foreign_player:
		return "外国人"
	if year > 0 and int(player.source_data.get("draft_year", 0)) == year:
		return "新人"
	if player.years <= 0 and bool(player.source_data.get("rookie_year", false)):
		return "新人"
	if year > 0 and int(player.source_data.get("fa_signed_year", 0)) == year:
		return "FA加入"
	if year > 0 and int(player.source_data.get("compensation_year", 0)) == year:
		return "補償加入"
	return ""


# そのケースで実際に必要なプロテクト人数 (適格者が枠より少ない縮小ワールド向けのクランプ)。
static func required_protect_size(case: Dictionary) -> int:
	return mini(PROTECT_SIZE, (case.get("eligible_ids", []) as Array).size())


# ============================================================ CPU 判断

# CPU のプロテクト選定。future_value_score 降順で枠を埋め、捕手の最低人数だけ後から保証する。
static func cpu_protect_ids(players: Array, case: Dictionary) -> Array:
	var rows: Array = []
	for id_value in case.get("eligible_ids", []) as Array:
		var player: PSPlayer = _find_player(players, int(id_value))
		if player == null:
			continue
		var score: float = OffseasonService.future_value_score(player)
		if player.position == 2:
			score *= PROTECT_CATCHER_WEIGHT
		rows.append({"player_id": player.id, "score": score, "position": player.position})
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float((a as Dictionary).get("score", 0.0)) > float((b as Dictionary).get("score", 0.0))
	)
	var limit: int = required_protect_size(case)
	var selected: Array = []
	for row_value in rows:
		if selected.size() >= limit:
			break
		selected.append(row_value)
	_ensure_catcher_floor(selected, rows, limit)
	var ids: Array = []
	for row_value in selected:
		ids.append(int((row_value as Dictionary).get("player_id", 0)))
	return ids


# 枠内の捕手が PROTECT_CATCHER_MIN に満たないとき、枠内最下位の野手と枠外最上位の捕手を入れ替える。
# 捕手を晒すと即座に取られて一軍が回らなくなるため、スコア順だけに任せない。
static func _ensure_catcher_floor(selected: Array, rows: Array, limit: int) -> void:
	if limit <= PROTECT_CATCHER_MIN:
		return
	var selected_ids: Dictionary = {}
	for row_value in selected:
		selected_ids[int((row_value as Dictionary).get("player_id", 0))] = true
	while _count_catchers(selected) < PROTECT_CATCHER_MIN:
		var best_outside: Dictionary = {}
		for row_value in rows:
			var row: Dictionary = row_value as Dictionary
			if int(row.get("position", 0)) != 2 or selected_ids.has(int(row.get("player_id", 0))):
				continue
			best_outside = row
			break
		if best_outside.is_empty():
			return
		var worst_index: int = -1
		for i in range(selected.size()):
			var row: Dictionary = selected[i] as Dictionary
			if int(row.get("position", 0)) == 2:
				continue
			if worst_index < 0 or float(row.get("score", 0.0)) < float((selected[worst_index] as Dictionary).get("score", 0.0)):
				worst_index = i
		if worst_index < 0:
			return
		selected_ids.erase(int((selected[worst_index] as Dictionary).get("player_id", 0)))
		selected[worst_index] = best_outside
		selected_ids[int(best_outside.get("player_id", 0))] = true


static func _count_catchers(rows: Array) -> int:
	var count: int = 0
	for row_value in rows:
		if int((row_value as Dictionary).get("position", 0)) == 2:
			count += 1
	return count


# 非プロテクト選手の獲得価値。value を基準に、補強需要と将来価値を上乗せする。
static func pick_score(player: PSPlayer, team_id: int, charts: Dictionary) -> float:
	if player == null:
		return 0.0
	var value: float = float(OffseasonService.player_value_score(player))
	var future_gain: float = maxf(0.0, OffseasonService.future_value_score(player) - value)
	var need: float = 0.0
	var chart: Dictionary = charts.get(team_id, {}) as Dictionary
	if not chart.is_empty():
		var evaluation: Dictionary = TeamDepthChart.evaluate_candidate(chart, player)
		need = clampf(float(evaluation.get("slot_need", 0.0)), 0.0, PICK_NEED_MAX)
	return (value + need * PICK_NEED_WEIGHT + future_gain * PICK_FUTURE_WEIGHT) * _pick_age_factor(player.age)


# 30歳までは等倍、以降は1歳ごとに逓減 (下限 PICK_AGE_FLOOR)。
static func _pick_age_factor(age: int) -> float:
	if age <= PICK_PRIME_MAX_AGE:
		return 1.0
	return maxf(PICK_AGE_FLOOR, 1.0 - float(age - PICK_PRIME_MAX_AGE) * PICK_AGE_DECAY)


# 元球団の CPU 判断。指名する選手 (0 = 金銭補償のみ) を返す。
#
# ⚠️ **スコアの足切りだけでは「金銭のみ」が一度も選ばれない。** 28人プロテクト後の非プロテクトは
# 常に35人前後残り、その最良は実測で score 71.6〜80.0 (中央値 74.5) に収まる = どこに閾値を置いても
# 全ケース同じ側に倒れる ([[feedback_cap_saturation_pattern]] と同じ形)。そこで判断を2条件にする:
#   1. **補強として意味があるか** — depth chart の `fit` (弱点スロット かつ 一軍/将来ラインを超える)。
#      FA・戦力外獲得・現役ドラフトと同じ基準なので、球団ごとの弱点の有無で自然にばらつく。
#   2. **来季 payroll に収まるか** — 補償選手の年俸は恒久コストで、金銭補償と違い毎年効く。
#      人的を選ぶと補償金が減る (差額を返す) ので、その分も予算から引いて判定する。
static func cpu_pick_player_id(players: Array, teams: Array, case: Dictionary, charts: Dictionary) -> int:
	if not str(case.get("forced_reason", "")).is_empty():
		return 0
	var team_id: int = int(case.get("from_team", 0))
	var team: PSTeam = _find_team(teams, team_id)
	var chart: Dictionary = charts.get(team_id, {}) as Dictionary
	var refund: int = maxi(0, int(case.get("money_only", 0)) - int(case.get("money_with_player", 0)))
	var best_id: int = 0
	var best_score: float = 0.0
	for id_value in exposed_ids(case):
		var player: PSPlayer = _find_player(players, int(id_value))
		if player == null:
			continue
		if team != null and not TeamFinance.can_afford_addition(players, team, player.salary + refund):
			continue
		if not chart.is_empty() and not bool(TeamDepthChart.evaluate_candidate(chart, player).get("fit", false)):
			continue
		var score: float = pick_score(player, team_id, charts)
		if best_id <= 0 or score > best_score:
			best_id = player.id
			best_score = score
	if best_id <= 0 or best_score < PICK_MIN_SCORE:
		return 0
	return best_id


# プロテクトから漏れた (= 指名できる) 選手 id。
static func exposed_ids(case: Dictionary) -> Array:
	var protect: Dictionary = {}
	for id_value in case.get("protect_ids", []) as Array:
		protect[int(id_value)] = true
	var ids: Array = []
	for id_value in case.get("eligible_ids", []) as Array:
		if not protect.has(int(id_value)):
			ids.append(int(id_value))
	return ids


# ============================================================ 進行

static func current_case(state: Dictionary) -> Dictionary:
	var cases: Array = state.get("cases", []) as Array
	var index: int = int(state.get("index", 0))
	if index < 0 or index >= cases.size():
		return {}
	return cases[index] as Dictionary


static func _advance_until_user_or_complete(state: Dictionary, players: Array, teams: Array, season: PSSeason, auto_user: bool) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	var year: int = int(state.get("year", 0))
	var charts: Dictionary = {}
	# ケースごとに「プロテクト提出 → 指名判断 → 次へ」の3遷移なので、これで必ず末尾へ到達する
	# (無限ループ防御。ここを抜けた場合も下の done 処理で完了扱いにする)。
	var guard: int = (state.get("cases", []) as Array).size() * 3 + 8
	while guard > 0:
		guard -= 1
		var case: Dictionary = current_case(state)
		if case.is_empty():
			break
		_ensure_case_pool(players, case, year)
		# 人的補償が成立しないケースは、プロテクトの提出も指名の選択も意味がないので素通しする。
		if not str(case.get("forced_reason", "")).is_empty():
			if not bool(case.get("protect_submitted", false)):
				case["protect_ids"] = (case.get("eligible_ids", []) as Array).duplicate()
				case["protect_submitted"] = true
			if str(case.get("decision", "")).is_empty():
				_resolve_case(state, players, teams, season, case, 0)
			state["index"] = int(state.get("index", 0)) + 1
			continue
		if not bool(case.get("protect_submitted", false)):
			if int(case.get("to_team", 0)) == user_team_id and not auto_user:
				state["phase"] = "protect"
				state["waiting_user"] = true
				return state
			case["protect_ids"] = cpu_protect_ids(players, case)
			case["protect_submitted"] = true
			continue
		if str(case.get("decision", "")).is_empty():
			if int(case.get("from_team", 0)) == user_team_id and not auto_user and str(case.get("forced_reason", "")).is_empty():
				state["phase"] = "pick"
				state["waiting_user"] = true
				return state
			if charts.is_empty():
				charts = TeamDepthChart.build_league(players, teams)
			var picked_id: int = cpu_pick_player_id(players, teams, case, charts)
			_resolve_case(state, players, teams, season, case, picked_id)
			continue
		state["index"] = int(state.get("index", 0)) + 1
	state["phase"] = "done"
	state["waiting_user"] = false
	state["complete"] = true
	return state


# ケースを確定させる。picked_player_id > 0 なら人的補償 (その場で移籍)、0 なら金銭補償のみ。
static func _resolve_case(state: Dictionary, players: Array, teams: Array, season: PSSeason, case: Dictionary, picked_player_id: int) -> void:
	var year: int = int(state.get("year", 0))
	var from_team: int = int(case.get("from_team", 0))
	var to_team: int = int(case.get("to_team", 0))
	var picked: PSPlayer = _find_player(players, picked_player_id) if picked_player_id > 0 else null
	# 状態と所属がずれている (外部で動かされた) 場合は金銭補償へ落とす。
	if picked != null and picked.team_id != to_team:
		picked = null
	if picked == null:
		case["decision"] = "money"
		case["picked_player_id"] = 0
		case["compensation_money"] = int(case.get("money_only", 0))
		_log(state, "%s (%sランク): %s は金銭補償のみを選択" % [
			str(case.get("name", "")), str(case.get("fa_rank", "")), _team_name(teams, from_team),
		])
	else:
		case["decision"] = "player"
		case["picked_player_id"] = picked.id
		case["picked_name"] = picked.name
		case["picked_position"] = picked.position
		case["picked_role"] = picked.role
		case["picked_age"] = picked.age
		case["picked_salary"] = picked.salary
		case["compensation_money"] = int(case.get("money_with_player", 0))
		if season != null:
			season.transfer_active_roster_days(to_team, from_team, picked.id)
		picked.team_id = from_team
		picked.source_data["compensation_year"] = year
		PSCareerLog.log_compensation(picked, year, to_team, from_team)
		_refund_money_difference(teams, case)
		_log(state, "%s (%sランク): %s が %s から %s を人的補償で獲得" % [
			str(case.get("name", "")), str(case.get("fa_rank", "")),
			_team_name(teams, from_team), _team_name(teams, to_team), picked.name,
		])
	case["resolved"] = true


# 人的補償を選んだ分だけ補償金が減る。FA成立時に「金銭のみ」の額を動かしてあるので差額を戻す。
static func _refund_money_difference(teams: Array, case: Dictionary) -> void:
	var refund: int = int(case.get("money_only", 0)) - int(case.get("money_with_player", 0))
	if refund <= 0:
		return
	var signing_team: PSTeam = _find_team(teams, int(case.get("to_team", 0)))
	var former_team: PSTeam = _find_team(teams, int(case.get("from_team", 0)))
	if signing_team != null:
		signing_team.funds += refund
	if former_team != null:
		former_team.funds -= refund


# ============================================================ ユーザー操作

static func submit_protect_list(state: Dictionary, players: Array, teams: Array, season: PSSeason, player_ids: Array) -> Dictionary:
	if str(state.get("phase", "")) != "protect" or not bool(state.get("waiting_user", false)):
		return {"ok": false, "message": "プロテクトリスト提出の段階ではありません", "state": state}
	var case: Dictionary = current_case(state)
	if case.is_empty():
		return {"ok": false, "message": "対象の補償がありません", "state": state}
	var eligible: Dictionary = {}
	for id_value in case.get("eligible_ids", []) as Array:
		eligible[int(id_value)] = true
	var unique_ids: Array = []
	var seen: Dictionary = {}
	for id_value in player_ids:
		var pid: int = int(id_value)
		if not eligible.has(pid):
			return {"ok": false, "message": "プロテクト対象外の選手が含まれています (id=%d)" % pid, "state": state}
		if seen.has(pid):
			continue
		seen[pid] = true
		unique_ids.append(pid)
	var required: int = required_protect_size(case)
	if unique_ids.size() != required:
		return {"ok": false, "message": "プロテクトはちょうど%d人選んでください (現在%d人)" % [required, unique_ids.size()], "state": state}
	case["protect_ids"] = unique_ids
	case["protect_submitted"] = true
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# 自軍のプロテクト枠を CPU と同じ基準で埋める (「推奨リストにする」)。提出はしない。
static func recommended_protect_ids(state: Dictionary, players: Array) -> Array:
	var case: Dictionary = current_case(state)
	if case.is_empty():
		return []
	return cpu_protect_ids(players, case)


static func submit_pick(state: Dictionary, players: Array, teams: Array, season: PSSeason, player_id: int) -> Dictionary:
	if str(state.get("phase", "")) != "pick" or not bool(state.get("waiting_user", false)):
		return {"ok": false, "message": "人的補償の選択段階ではありません", "state": state}
	var case: Dictionary = current_case(state)
	if case.is_empty():
		return {"ok": false, "message": "対象の補償がありません", "state": state}
	if not exposed_ids(case).has(player_id):
		return {"ok": false, "message": "プロテクトされている選手は指名できません", "state": state}
	_resolve_case(state, players, teams, season, case, player_id)
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


static func submit_money_only(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	if str(state.get("phase", "")) != "pick" or not bool(state.get("waiting_user", false)):
		return {"ok": false, "message": "人的補償の選択段階ではありません", "state": state}
	var case: Dictionary = current_case(state)
	if case.is_empty():
		return {"ok": false, "message": "対象の補償がありません", "state": state}
	_resolve_case(state, players, teams, season, case, 0)
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


# 現在のケースだけ AI に任せる。
static func auto_current_case(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var case: Dictionary = current_case(state)
	if case.is_empty():
		return {"ok": false, "message": "対象の補償がありません", "state": state}
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	if not bool(case.get("protect_submitted", false)):
		case["protect_ids"] = cpu_protect_ids(players, case)
		case["protect_submitted"] = true
	if str(case.get("decision", "")).is_empty():
		_resolve_case(state, players, teams, season, case, cpu_pick_player_id(players, teams, case, charts))
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, false)}


static func complete_automatically(state: Dictionary, players: Array, teams: Array, season: PSSeason) -> Dictionary:
	return {"ok": true, "state": _advance_until_user_or_complete(state, players, teams, season, true)}


# ============================================================ 確定

static func finalize_compensation(state: Dictionary) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {"title": "人的補償", "moves": []}) as Dictionary
	var user_team_id: int = int(state.get("user_team_id", 0))
	var moves: Array = []
	var cases_view: Array = []
	var money_only_count: int = 0
	var user_gained: int = 0
	var user_lost: int = 0
	for case_row in state.get("cases", []) as Array:
		var case: Dictionary = case_row as Dictionary
		var from_team: int = int(case.get("from_team", 0))
		var to_team: int = int(case.get("to_team", 0))
		var decision: String = str(case.get("decision", ""))
		cases_view.append({
			"player_id": int(case.get("player_id", 0)),
			"name": str(case.get("name", "")),
			"fa_rank": str(case.get("fa_rank", "")),
			"from_team": from_team,
			"to_team": to_team,
			"decision": decision,
			"compensation_money": int(case.get("compensation_money", case.get("money_only", 0))),
			"picked_player_id": int(case.get("picked_player_id", 0)),
			"picked_name": str(case.get("picked_name", "")),
			"forced_reason": str(case.get("forced_reason", "")),
		})
		if decision != "player":
			money_only_count += 1
			continue
		# from_team/to_team は結果表 (team_mode "move") の慣習に合わせ、補償選手自身の移動方向で入れる。
		moves.append({
			"player_id": int(case.get("picked_player_id", 0)),
			"name": str(case.get("picked_name", "")),
			"position": int(case.get("picked_position", 0)),
			"role": str(case.get("picked_role", "")),
			"age": int(case.get("picked_age", 0)),
			"salary": int(case.get("picked_salary", 0)),
			"from_team": to_team,
			"to_team": from_team,
			"fa_player_name": str(case.get("name", "")),
			"fa_rank": str(case.get("fa_rank", "")),
		})
		if from_team == user_team_id:
			user_gained += 1
		if to_team == user_team_id:
			user_lost += 1
	var result: Dictionary = {
		"title": "人的補償",
		"cases": cases_view,
		"moves": moves,
		"case_count": cases_view.size(),
		"moved_count": moves.size(),
		"money_only_count": money_only_count,
		"user_gained": user_gained,
		"user_lost": user_lost,
		"logs": (state.get("logs", []) as Array).duplicate(true),
	}
	state["finalized"] = true
	state["final_result"] = result
	return result


# ============================================================ 共通ヘルパー

static func _find_player(players: Array, player_id: int) -> PSPlayer:
	if player_id <= 0:
		return null
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


static func _find_team(teams: Array, team_id: int) -> PSTeam:
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null


static func _team_name(teams: Array, team_id: int) -> String:
	var team: PSTeam = _find_team(teams, team_id)
	return team.name if team != null else "球団%d" % team_id


static func _log(state: Dictionary, text: String) -> void:
	(state["logs"] as Array).append(text)
