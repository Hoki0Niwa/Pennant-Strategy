class_name ReleasedMarketService

# 戦力外獲得市場。
# 戦力外通告済みの team_id=0 / retired 扱い選手を、ドラフト後FA前に再契約できる。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

# 1球団が1オフに獲得できる上限。**支配下契約だけを数える** — 育成は戦力外にするのも
# 戦力外から獲得するのも無制限で、人数の制限は支配下にだけ掛かる。
# 育成契約は CONTROLLED_LIMIT(70) も消費しないので、育成 track の獲得は人数上限を一切持たない
# (質のゲートは _team_fit_evaluation / MIN_AI_SIGNING_SCORE / 予算のみ)。
const MAX_CONTROLLED_SIGNINGS_PER_TEAM: int = 2
# 一軍当落線をこれだけ上回る候補だけをAIが「今すぐ使える戦力」とみなす (value 単位)。
# ※ 絞り込みは need ではなく**当落線からの上積み幅**で行う。need>0 (リーグ平均未満) は全球団の
#   約半数×約半分のスロットが常に該当するゆるいゲートで、これだけでは 12球団×2人=24 の上限に
#   毎年張り付く。かといって need 側へ閾値を置くと投手は need が構造的に立たず野手偏重になる
#   ([[project_released_market]])。0 にすると 1点でも上回れば獲得する。
const MIN_UPGRADE_MARGIN: float = 1.0
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
# 育成判定は支配下枠(CONTROLLED_LIMIT)を消費しない。
# 基準(30歳・value50=典型的な戦力外候補)で五分五分になるよう調整。Web調査した実績
# (2023-24年16支配下/12育成、2024-25年9支配下/13育成)の支配下/育成比率(概ね半々)に
# 揃えている。
const TRACK_CONTROLLED: String = "支配下"
const TRACK_DEVELOPMENT: String = "育成"
const DEV_TRACK_BASE_CHANCE: float = 0.45
const DEV_TRACK_AGE_PIVOT: int = 30
const DEV_TRACK_AGE_CHANCE_PER_YEAR: float = 0.05
const DEV_TRACK_VALUE_PIVOT: int = 50
const DEV_TRACK_VALUE_OFFSET: float = 0.012
const DEV_TRACK_CHANCE_MIN: float = 0.05
const DEV_TRACK_CHANCE_MAX: float = 0.90
# **育成契約になる理由は2つあり、年齢に対して単調ではない**:
#   ① 高齢 = 「今すぐ支配下で通用するか怪しい」→ 上の年齢項が拾う
#   ② 素材年齢 = 「今はまだ足りないが伸びしろに賭ける」→ この項が拾う
# 年齢項だけの単調式にすると ② の経路がほぼ閉じ (22歳の育成率が5〜10%)、育成契約が高齢者
# だけになる。素材年齢から1歳若いごとに育成寄りへ振る。
const DEV_TRACK_PROSPECT_MAX_AGE: int = TeamDepthChart.PROSPECT_MAX_AGE
const DEV_TRACK_PROSPECT_CHANCE_PER_YEAR: float = 0.10

# --- 育成契約での獲得基準 ---
# 育成契約は「今の実力を買う」のではなく「伸びしろに賭ける」もの。基準は
# `development_projected_ceiling >= その球団の一軍下位水準 (first_team_ready_threshold)` を土台に、
# 年齢で要求水準を動かす:
#   - `DEV_SIGN_AGE_PIVOT` を超えた1歳ごとに `DEV_SIGN_AGE_PENALTY_PER_YEAR` だけ要求を上げる。
#     ceiling は30代だと成長期待がゼロ clamp されて現在能力そのものになるため、これが無いと
#     「そこそこ使えるベテラン」が無条件で通り、育成枠が高齢者で埋まる。
#   - 逆に素材年齢 (`TeamDepthChart.PROSPECT_MAX_AGE` 以下) は若いほど要求を下げ、
#     **今は一軍水準に届かない若手を将来性で拾う**経路を明示的に残す。
# 結果として要求水準は年齢に対して V 字 (若い/高齢の両端で緩急が付く) になる。
# 上げ下げの単位は value (overall スケール) と同じ。
# 監視値は long_autoplay の `released_signed_development_avg_age` で、**放出全体の
# `released_average_age` より低いこと**が合否の目安。傾斜が緩いと高齢ペナルティが実質効かず、
# 20代後半の「そこそこ使える選手」が素通りして育成獲得の平均年齢が放出全体より高くなる。
const DEV_SIGN_AGE_PIVOT: int = 26
# **総数を動かす主ノブはこちら**。候補の大半が 26〜33歳に居るので、素材年齢側の割引
# (DEV_SIGN_PROSPECT_DISCOUNT_PER_YEAR) をいじっても動く母数はほとんど無い。
# 上げるほど高齢が弾かれて若返るが総数は減る (2.5 で 19.0→7.5人/年)。2.0 は候補の主たる帯
# (26〜30歳) の要求を1歳あたり0.5点ぶん緩めて総数を保つ位置。
const DEV_SIGN_AGE_PENALTY_PER_YEAR: float = 2.0
const DEV_SIGN_PROSPECT_DISCOUNT_PER_YEAR: float = 2.5


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


# `track` に TRACK_CONTROLLED / TRACK_DEVELOPMENT を渡すと、その候補を**どちらの契約で獲るかを
# ユーザーが選べる**。空文字なら候補生成時に決まった track (CPU/おまかせ用の既定) をそのまま使う。
# 支配下と育成では枠の消費 (CONTROLLED_LIMIT / MAX_CONTROLLED_SIGNINGS_PER_TEAM) が違うので、
# 上限チェックより前に確定させる必要がある。
static func submit_user_released_decision(state: Dictionary, players: Array, teams: Array, season: PSSeason, candidate_id: int, action: String, track: String = "") -> Dictionary:
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
	if track == TRACK_CONTROLLED or track == TRACK_DEVELOPMENT:
		entry["track"] = track
	elif not track.is_empty():
		return {"ok": false, "message": "不正な契約区分です。", "state": state}
	if _controlled_track_limit_reached(state, user_team_id, entry):
		return {"ok": false, "message": "今オフの支配下での戦力外獲得上限に達しています。", "state": state}
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
	# デプスチャートと即戦力基準は1度だけ作って使い回す (候補ごとに作り直すと O(n^2) になる)。
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var ready_thresholds: Dictionary = _build_ready_thresholds(players, teams)
	var best_id: int = 0
	var best_score: float = -INF
	for row in candidates:
		var entry: Dictionary = row as Dictionary
		if not _can_ai_afford_release(players, teams, user_team_id, entry):
			continue
		var team_need: float = float(entry.get("need", 0.0))
		if _team_fit_evaluation(players, charts, ready_thresholds, user_team_id, entry).is_empty():
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
	# 需要とデプスチャートは候補×球団のループの外で構築する (中で作り直すと O(n^2))。
	# 作り直すのはループ末尾の1箇所だけ (成立のたび = 候補数を超えない)。
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var need: Dictionary = TeamDepthChart.position_need_view(charts)
	var ready_thresholds: Dictionary = _build_ready_thresholds(players, teams)
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
		var best_preference: float = -999999.0
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			if team.id == int(entry.get("from_team", 0)):
				continue
			if team.id == user_team_id and bool(entry.get("user_skipped", false)):
				continue
			if _controlled_track_limit_reached(state, team.id, entry):
				continue
			if not _can_team_accept_candidate(players, team.id, entry):
				continue
			if not _can_ai_afford_release(players, teams, team.id, entry):
				continue
			var team_need: float = float((need.get(team.id, {}) as Dictionary).get(int(entry.get("position", 0)), 0.0))
			var evaluation: Dictionary = _team_fit_evaluation(players, charts, ready_thresholds, team.id, entry)
			if evaluation.is_empty():
				continue
			if _signing_score(entry, team_need, players, teams, team.id) < MIN_AI_SIGNING_SCORE:
				continue
			# 獲得先は「その候補を最も必要としている球団」。_signing_score は候補側の属性だけで
			# 決まり球団間で同値になるため、これで比べると常に teams 配列の先頭球団が勝ってしまう。
			var preference: float = _team_preference(evaluation)
			if preference > best_preference:
				best_preference = preference
				best_team_id = team.id
		if best_team_id > 0:
			_apply_signing(state, players, season, entry, best_team_id, "cpu")
			# 獲得でその球団のスロットは埋まる。作り直さないと同じ弱点を根拠に2人目を獲ってしまう。
			charts = TeamDepthChart.build_league(players, teams)
			need = TeamDepthChart.position_need_view(charts)
			ready_thresholds = _build_ready_thresholds(players, teams)
	state["complete"] = true
	return {"ok": true, "state": state}


static func finalize_released_market(state: Dictionary) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary
	var signings: Array = (state.get("signings", []) as Array).duplicate(true)
	signings.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("value", 0)) > int((b as Dictionary).get("value", 0))
	)
	var development_signed: int = 0
	var development_age_total: int = 0
	var controlled_age_total: int = 0
	for row in signings:
		var signing: Dictionary = row as Dictionary
		if bool(signing.get("development_player", false)):
			development_signed += 1
			development_age_total += int(signing.get("age", 0))
		else:
			controlled_age_total += int(signing.get("age", 0))
	var controlled_signed: int = signings.size() - development_signed
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
			"track": str(entry.get("track", TRACK_CONTROLLED)),
		})
	var result: Dictionary = {
		"candidates": candidates_summary,
		"candidates_count": candidates_summary.size(),
		"signings": signings,
		"signed_count": signings.size(),
		# 人数上限が効くのは支配下だけなので、内訳を分けて出す (育成は上限なし)。
		"signed_development_count": development_signed,
		"signed_controlled_count": controlled_signed,
		# 育成獲得の年齢ペナルティ / 若手枠が効いているかの監視用 (0 = 該当者なし)。
		"signed_development_avg_age": snapped(float(development_age_total) / float(maxi(1, development_signed)), 0.01),
		"signed_controlled_avg_age": snapped(float(controlled_age_total) / float(maxi(1, controlled_signed)), 0.01),
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
		# 獲得球団の外国人枠を1人ぶん埋めるか。日本人扱いの外国人は枠を消費しない。
		"foreign_slot": player.counts_toward_foreign_slot(),
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
	# 素材年齢は「伸びしろに賭ける育成契約」の側へ振り戻す (年齢に対して U 字になる)。
	chance += float(maxi(0, DEV_TRACK_PROSPECT_MAX_AGE - age)) * DEV_TRACK_PROSPECT_CHANCE_PER_YEAR
	return clampf(chance, DEV_TRACK_CHANCE_MIN, DEV_TRACK_CHANCE_MAX)


static func _determine_track(age: int, value: int) -> String:
	return TRACK_DEVELOPMENT if Rng.roll_float() <= _development_track_chance(age, value) else TRACK_CONTROLLED


static func _apply_signing(state: Dictionary, players: Array, season: PSSeason, entry: Dictionary, to_team_id: int, method: String) -> void:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if not _is_released_market_player(player):
		return
	var year: int = season.year if season != null else int(state.get("year", 0))
	var track: String = str(entry.get("track", TRACK_CONTROLLED))
	player.team_id = to_team_id
	player.source_data.erase("released")
	player.source_data.erase("retired")
	player.source_data.erase("retired_age")
	player.source_data["released_signed_year"] = year
	player.source_data["released_from_team"] = int(entry.get("from_team", 0))
	# 戦力外になった時点で支配下だったか (= 育成契約を結ぶなら「支配下経験者」扱いで契約1年)。
	# development_player を track で上書きする前に読む必要がある。
	var was_controlled: bool = not player.development_player
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
		if was_controlled:
			player.source_data["dev_from_controlled"] = true
		else:
			player.source_data.erase("dev_from_controlled")
	else:
		player.source_data.erase("development_since_year")
		player.source_data.erase("dev_from_controlled")
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


# その球団が今オフに成立させた**支配下契約**の数 (育成契約は数えない)。
static func _controlled_signings_for_team(state: Dictionary, team_id: int) -> int:
	var count: int = 0
	for row in state.get("signings", []) as Array:
		var signing: Dictionary = row as Dictionary
		if int(signing.get("to_team", 0)) != team_id:
			continue
		if str(signing.get("track", TRACK_CONTROLLED)) == TRACK_DEVELOPMENT:
			continue
		count += 1
	return count


# 人数上限に当たるのは支配下 track の候補だけ。育成 track は何人でも獲得できる。
static func _controlled_track_limit_reached(state: Dictionary, team_id: int, entry: Dictionary) -> bool:
	if str(entry.get("track", TRACK_CONTROLLED)) == TRACK_DEVELOPMENT:
		return false
	return _controlled_signings_for_team(state, team_id) >= MAX_CONTROLLED_SIGNINGS_PER_TEAM


static func _can_team_accept_candidate(players: Array, team_id: int, entry: Dictionary = {}) -> bool:
	if bool(entry.get("foreign_slot", entry.get("foreign_player", false))):
		if _foreign_count_for_team(players, team_id) >= ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM:
			return false
	# 育成track は支配下枠(CONTROLLED_LIMIT)も獲得人数上限も消費しない。
	# 質のゲート (_team_fit_evaluation / MIN_AI_SIGNING_SCORE / 予算) だけが効く。
	if str(entry.get("track", TRACK_CONTROLLED)) == TRACK_DEVELOPMENT:
		return true
	# ドラフトが後段補強用に残した hard 枠を使う。70枠はここで保証する。
	return _active_count_for_team(players, team_id) < TeamFinance.CONTROLLED_LIMIT


static func _can_sign_entry(players: Array, entry: Dictionary) -> bool:
	return _is_released_market_player(_find_player_by_id(players, int(entry.get("player_id", 0))))


# 予算ゲート: 年俸を払っても予算内に収まるか。
static func _can_team_afford_release(players: Array, teams: Array, team_id: int, entry: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	return TeamFinance.can_afford_addition(players, team, int(entry.get("salary", 0)))


# 戦力外市場のAIは、今回の年俸に加えて後続のFA・外国人補強費も残す。
static func _can_ai_afford_release(players: Array, teams: Array, team_id: int, entry: Dictionary) -> bool:
	var team: PSTeam = _find_team_by_id(teams, team_id)
	var incoming_foreign: int = 1 if bool(entry.get("foreign_slot", entry.get("foreign_player", false))) else 0
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
# 投打で判定を非対称 (野手=リーグ相対 need / 投手=depth-fit) にすると投手 need が構造的に立たず、
# 獲得が極端な野手偏重 (投:野 ≈ 23:84) になる。役割数の偏り (投手は深く常に埋まる) と
# 野手が systematically 高 value な分は `_signing_score` の投手 parity で相殺する。
# 獲得基準は「とりあえず取る枠ではない」水準に置く:
# **自軍のデプスチャート ([[TeamDepthChart]]) に照らして、即戦力 or 将来に賭ける価値がある選手だけ**を獲る:
#   - 即戦力 = その役割スロットの**一軍当落線** (先発5番手/救援6番手/そのポジションのレギュラー) を
#     MIN_UPGRADE_MARGIN 以上上回る
#   - 将来性 = 24歳以下で、成長の楽観側なら当落線 + margin に届き、かつそのスロットが将来空く
# どちらでもなければ獲らない = **0人で終わるオフが普通に起きる**。
# 基準を「自軍の同役割**最弱**選手を上回れば獲得」にすると、68人ロスターの最下位を超えれば
# 通るので事実上ほぼ全候補が該当し、全球団が毎年上限2人まで獲る (1.95人/球団/年)。
# 該当しなければ **空** を返す (呼び出し元は獲得先の優先順位付けに評価結果をそのまま使う)。
static func _team_fit_evaluation(
	players: Array, charts: Dictionary, ready_thresholds: Dictionary, team_id: int, entry: Dictionary
) -> Dictionary:
	var player: PSPlayer = _find_player_by_id(players, int(entry.get("player_id", 0)))
	if player == null:
		return {}
	var chart: Dictionary = charts.get(team_id, {}) as Dictionary
	if str(entry.get("track", TRACK_CONTROLLED)) == TRACK_DEVELOPMENT:
		# 育成契約は支配下枠も獲得人数上限も消費しないので、「一軍当落線を上回るか」を要求しない。
		# 代わりに **その球団が育成選手を保持し続ける基準と同じ物差し** を使う:
		# 成長の楽観側 (development_projected_ceiling) がその球団の一軍下位水準に届くか
		# (= 翌オフの育成整理で即放出されない選手か)。昇格・育成整理と同一基準。
		var ceiling: float = OffseasonService.development_projected_ceiling(player)
		if ceiling < development_signing_threshold(float(ready_thresholds.get(team_id, INF)), player.age):
			return {}
		var dev_evaluation: Dictionary = TeamDepthChart.evaluate_candidate(chart, player)
		dev_evaluation["fit"] = true
		return dev_evaluation
	var evaluation: Dictionary = TeamDepthChart.evaluate_candidate(chart, player, MIN_UPGRADE_MARGIN)
	return evaluation if bool(evaluation.get("fit", false)) else {}


# 育成契約で獲得するために ceiling が超えるべき水準。球団の一軍下位水準を土台に、
# 年齢で要求を上下させる (高齢ほど厳しく、素材年齢は緩く)。ready_threshold が INF (球団不明) の
# ときはそのまま INF を返して不成立にする。
static func development_signing_threshold(ready_threshold: float, age: int) -> float:
	if not is_finite(ready_threshold):
		return ready_threshold
	var threshold: float = ready_threshold
	threshold += float(maxi(0, age - DEV_SIGN_AGE_PIVOT)) * DEV_SIGN_AGE_PENALTY_PER_YEAR
	# 素材年齢は若いほど大きく割り引く (24歳 −2.5 / 22歳 −7.5 / 20歳 −12.5)。
	threshold -= float(maxi(0, TeamDepthChart.PROSPECT_MAX_AGE - age + 1)) * DEV_SIGN_PROSPECT_DISCOUNT_PER_YEAR
	return threshold


# 球団ごとの即戦力基準 (育成 track の獲得判定用)。選手ごとに引くと O(n^2) になるので1パス1回。
static func _build_ready_thresholds(players: Array, teams: Array) -> Dictionary:
	var thresholds: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		thresholds[team.id] = OffseasonService.first_team_ready_threshold(players, team.id)
	return thresholds


# 同じ候補を複数球団が獲得できるときの優先順位。当落線からの上積み幅 + スロットの弱さ。
static func _team_preference(evaluation: Dictionary) -> float:
	var upgrade: float = float(evaluation.get("value", 0.0)) - float(evaluation.get("first_team_line", 0.0))
	return upgrade + float(evaluation.get("slot_need", 0.0))


# 獲得スコア = 能力 value + WAR + 投手 parity − 年俸負担。**ポジション need は掛けない** —
# need は野手だけ立つため、掛けると野手の score が過大になり獲得枠を野手が独占する。投手 parity は野手が
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


# 支配下枠 (育成除外) の人数。計数の単一ソースは TeamFinance。
static func _active_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.controlled_count(players, team_id)


static func _foreign_count_for_team(players: Array, team_id: int) -> int:
	return TeamFinance.foreign_slot_count(players, team_id)


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
