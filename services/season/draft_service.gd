extends RefCounted
class_name DraftService

const Offseason = preload("res://services/season/offseason_service.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")

# ドラフト指名は候補の素点に、球団ごとの不足ポジション補正を加えて決める。
# need は [[TeamDepthChart]] の `first_team_need` (= 一軍枠の質のリーグ差、value 単位) で、
# 現有戦力が弱いポジションほど候補評価を押し上げる。
# ⚠️ **2026-08-03 に単位が WAR (0〜2程度) から value (0〜15程度) へ変わったため、重みを約1/7へ下げた。**
# 投手も野手と同じ重みを使う (グロスの投手/野手比は _bucket_balance_score が別途担保する)。
const POSITION_NEED_WEIGHT_ROUND1: float = 0.2
const POSITION_NEED_WEIGHT_LATER: float = 0.45

# ポジション別適性保持者の確保。各守備位置で最低 POSITION_DEPTH_TARGET 人の適性保持者を
# 揃えるようドラフトを誘導する。保持者が少ない位置の候補を優先指名するが、その位置に
# 健在の主力 (overall >= STRONG_STARTER_OVERALL) がいる場合は優先度を下げる
# (= STRONG_STARTER_DAMPEN を乗じて指名順位を落とす)。一二軍入替の最低保持者確保
# (team_auto_ai._swap_one_team の守備カバレッジガード) と組で、各位置の人材枯渇を防ぐ。
const POSITION_DEPTH_TARGET: int = 4
const POSITION_APT_NEED_WEIGHT_ROUND1: float = 1.0
const POSITION_APT_NEED_WEIGHT_LATER: float = 4.0
const STRONG_STARTER_OVERALL: int = 60
const STRONG_STARTER_DAMPEN: float = 0.3

# 本職 (primary position) の最低確保数。球団全体で各守備位置に本職 2 人以上、捕手は 6 人以上を
# 維持するようドラフトで強く補強し、戦力外でも下回らないよう保護する
# (offseason_service の release 保護と対)。捕手枯渇は守備不能に直結するため特に厚く確保。
const FIELD_PRIMARY_MIN: int = 2
const CATCHER_PRIMARY_MIN: int = 6
const PRIMARY_NEED_WEIGHT_ROUND1: float = 3.0
const PRIMARY_NEED_WEIGHT_LATER: float = 7.0

# 複数のサブポジション適性を持つユーティリティ選手をわずかに高評価する重み。
const UTILITY_SUBPOS_WEIGHT: float = 0.6

const ROSTER_LIMIT: int = 70
# ドラフトは本指名(支配下)のあと育成ドラフトへ進む2フェーズ制。
# AppState では別ステップとして表示するが、レポート/テスト用の直接実行では通しで処理できる。
# **本指名数は固定の指名枠** (2026-08-03 ユーザー方針)。現実のドラフトは「支配下の空き数」から
# 逆算するのではなく、毎年おおむね6〜7人を指名し、**誰を取るか**を年齢・ポジション・能力の
# デプスチャート need で決める運用。人数の帳尻は戦力外側 (offseason_service._release_plan_count が
# 在籍+見込み流入−開幕目標の「余り」で決める) が合わせる。
# 旧方式 (2026-07-03〜2026-08-03) は指名数自体を 開幕目標−在籍−補強予約 の差分で決めていたため、
# 「毎年必ず2人補強する」前提の予約枠が指名数を直接押し下げていた。
const MAIN_DRAFT_TARGET_MIN: int = 6
const MAIN_DRAFT_TARGET_MAX: int = 7
# hard 70枠に対する安全弁 (指名枠より優先)。枠が残り僅かな球団はここで縮む。
const MAIN_DRAFT_MAX_PICKS: int = 10
const MAIN_DRAFT_MIN_PICKS: int = 4
# 外国人は4人保有を目標に、不足人数分の支配下枠を本指名で埋め切らず予約する。
const FOREIGN_ROSTER_RESERVE_TARGET: int = 4
# ※ 旧 DRAFT_PROMO_RESERVE_CAP / DRAFT_PROMO_TARGET_REDUCTION_CAP (育成昇格見込みで指名数を控える)
#   は 2026-08-03 に撤廃。指名枠を固定にしたため「見込みで枠を削る」概念自体が無くなった。
#   そもそもノブとしてもほぼ効いていなかった (即戦力基準を満たす育成は球団あたり0〜1人しかおらず、
#   上限2に張り付く球団が出ない。2→1 を試して 73.0→73.2人/年と無変化だった)。
# 育成ドラフト: 1球団あたりの指名上限 (実際は 0〜この値の一様乱数)。**育成人数を決める唯一のノブ** —
# 保有数 ≒ 平均指名数 (上限の半分) × 育成契約年数 (OffseasonService.DEV_CONTRACT_MAX_SEASONS) で
# 決まる。NPB は年間 45〜50人/12球団 (≈4/球団) だが、単一球団が10人超を指名するような編成は
# ゲームの方針として作らない ([[roadmap_feature_candidates]])。
const DEV_DRAFT_MAX_PICKS: int = 6
const MAX_TOTAL_PICKS: int = 200
const CANDIDATE_POOL_SIZE: int = 320
const ROOKIE_MIN_AGE: int = 18
const ROOKIE_MAX_AGE: int = 26

const POSITION_NAME_BY_ID: Dictionary = {
	1: "pitcher", 2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

const GROUP_TARGETS: Dictionary = {
	"pitcher": 36,
	"catcher": 6,
	"infield": 17,
	"outfield": 11,
}


static func create_draft_state(players: Array, teams: Array, season: PSSeason, user_team_id: int, allow_development_segment: bool = true, full_waiver: bool = false) -> Dictionary:
	var team_profiles: Dictionary = _build_team_profiles(players, teams)
	var reverse_order: Array = _draft_reverse_order(teams, season)
	var forward_order: Array = reverse_order.duplicate()
	forward_order.reverse()

	# 球団別のポジション補強需要 (デプスチャート由来。成績レコードに依存しない)。
	var team_position_need: Dictionary = _build_team_position_need(players, teams)

	var state: Dictionary = {
		"version": 1,
		"year": season.year if season != null else 0,
		"user_team_id": user_team_id,
		# segment: "main" (本指名=支配下) → "development" (育成ドラフト)。
		"segment": "main",
		"allow_development_segment": allow_development_segment,
		# order_mode: "snake" (通常) は1巡目のみ入札/抽選を行い、2巡目以降は偶数巡reverse/
		# 奇数巡forwardのスネーク。"waiver" (完全ウェーバー制) は入札/抽選を行わず、本指名の
		# 全巡を reverse 固定 (下位球団から順) で指名する (_order_for_round で分岐)。
		"order_mode": "waiver" if full_waiver else "snake",
		"stage": "later_rounds" if full_waiver else "first_round_bid",
		"round": 1,
		"round_position": 0,
		"current_team_id": user_team_id,
		"complete": false,
		"finalized": false,
		"priority_league": _priority_league(season.year if season != null else 0),
		"teams_order_reverse": reverse_order,
		"teams_order_forward": forward_order,
		"team_profiles": team_profiles,
		"team_position_need": team_position_need,
		# 本指名の球団別目標指名数 (need-driven)。_team_can_pick (本指名) の上限に使う。
		"team_main_targets": _compute_main_draft_targets(players, team_profiles),
		"team_pick_counts": _empty_team_counts(teams),
		# 育成ドラフトの指名数と、segment ごとに「もう指名しない」球団の集合 (segment 開始でリセット)。
		"team_dev_pick_counts": _empty_team_counts(teams),
		"team_dev_targets": {},
		"teams_done": {},
		"first_round_bids": {},
		"first_round_unresolved": [] if full_waiver else reverse_order.duplicate(),
		"first_round_wave": 1,
		# 1巡目入札の対話フロー用スナップショット (公開/結果段階でのみ中身を持つ)。
		# {wave, bids(team_id_str->candidate_id), resolved, winners(candidate_id_str->team_id), loser_team_ids}
		"first_round_reveal": {},
		"candidate_pool": _generate_candidate_pool(CANDIDATE_POOL_SIZE),
		"picks": [],
		"logs": [],
	}
	return advance_until_user_turn_or_complete(state)


# 全チームのポジション別 補強需要を集計する。**実体は [[TeamDepthChart]]** (2026-08-03 統合)。
# 戻り値: {team_id_str: {position: need}} (position 1 = 先発/救援スロットの need の大きい方)。
# 旧実装は直近シーズンの WAR (`WarCalculator.team_position_war` + 上位K枚平均) で測っていたが、
# 需要の実装が4箇所に散る原因になっていたためデプスチャートへ寄せた。副次的な利点:
#  - 先発と救援を別スロットで測れる (旧実装は全投手が position=1 の1バケツだった)。
#  - **シーズン未完了・成績レコード不在でも need が出る** (旧実装は WAR が全0になり need も全0だった)。
# ⚠️ 単位が WAR (0〜2程度) から value (0〜15程度) へ変わるため、重み (POSITION_NEED_WEIGHT_*) も
#   同じ比率で下げてある。ここを触るときは long_autoplay の draft の投手比を必ず見ること。
static func _build_team_position_need(players: Array, teams: Array) -> Dictionary:
	var charts: Dictionary = TeamDepthChart.build_league(players, teams)
	var need: Dictionary = {}
	for team_id in charts.keys():
		var chart: Dictionary = charts[team_id] as Dictionary
		var team_need: Dictionary = {}
		team_need[1] = maxf(
			TeamDepthChart.slot_need(chart, TeamDepthChart.SLOT_STARTER),
			TeamDepthChart.slot_need(chart, TeamDepthChart.SLOT_RELIEVER)
		)
		for position in range(2, 10):
			team_need[position] = TeamDepthChart.slot_need(chart, TeamDepthChart.fielder_slot_key(position))
		need[str(team_id)] = team_need
	return need


static func submit_user_candidate(state: Dictionary, candidate_id: int) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": false, "message": "ドラフトは既に完了しています。", "state": state}
	if not _is_candidate_available(state, candidate_id):
		return {"ok": false, "message": "その候補は指名できません。", "state": state}

	var user_team_id: int = int(state.get("user_team_id", 0))
	var stage: String = str(state.get("stage", ""))
	if stage == "first_round_bid":
		if not _team_can_pick(state, user_team_id):
			_resolve_first_round(state)
			advance_until_user_turn_or_complete(state)
			return {"ok": true, "state": state}
		var first_round_bids: Dictionary = state.get("first_round_bids", {}) as Dictionary
		first_round_bids[str(user_team_id)] = candidate_id
		state["first_round_bids"] = first_round_bids
		_prepare_first_round_reveal(state)
		return {"ok": true, "state": state}

	if stage == "user_pick":
		var current_team_id: int = int(state.get("current_team_id", 0))
		if current_team_id != user_team_id:
			return {"ok": false, "message": "現在は自球団の指名順ではありません。", "state": state}
		_make_pick(state, user_team_id, candidate_id, int(state.get("round", 2)), "user", false)
		_consume_current_slot(state)
		advance_until_user_turn_or_complete(state)
		return {"ok": true, "state": state}

	return {"ok": false, "message": "ドラフトは指名待ちではありません。", "state": state}


static func auto_pick_for_user(state: Dictionary) -> Dictionary:
	var user_team_id: int = int(state.get("user_team_id", 0))
	if bool(state.get("complete", false)):
		return {"ok": true, "state": state}
	# 入札公開/結果確認の対話段階は、専用の resolve_first_round_reveal / continue_first_round
	# で進める。ここで指名させると二重指名になるため no-op で返す。
	var stage_now: String = str(state.get("stage", ""))
	if stage_now == "first_round_reveal" or stage_now == "first_round_result":
		return {"ok": true, "state": state}
	if not _team_can_pick(state, user_team_id):
		advance_until_user_turn_or_complete(state)
		return {"ok": true, "state": state}
	var candidate_id: int = _choose_cpu_candidate(state, user_team_id, int(state.get("round", 1)), true)
	if candidate_id <= 0:
		_mark_team_done(state, user_team_id)
		advance_until_user_turn_or_complete(state)
		return {"ok": true, "state": state}
	return submit_user_candidate(state, candidate_id)


# ユーザーが現在の指名を見送る (主に育成ドラフトで「指名なし」を選ぶ)。
# 当該 segment ではこれ以上指名しない (teams_done に入れる) ため、以後の巡で自軍はスキップされる。
static func skip_user_pick(state: Dictionary) -> Dictionary:
	if bool(state.get("complete", false)):
		return {"ok": true, "state": state}
	var user_team_id: int = int(state.get("user_team_id", 0))
	if str(state.get("stage", "")) != "user_pick" or int(state.get("current_team_id", 0)) != user_team_id:
		return {"ok": false, "message": "現在は自球団の指名順ではありません。", "state": state}
	_mark_team_done(state, user_team_id)
	_consume_current_slot(state)
	advance_until_user_turn_or_complete(state)
	return {"ok": true, "state": state}


static func complete_automatically(state: Dictionary) -> Dictionary:
	var guard: int = 0
	while not bool(state.get("complete", false)) and guard < 2000:
		guard += 1
		var stage: String = str(state.get("stage", ""))
		if stage == "first_round_bid" or stage == "user_pick":
			auto_pick_for_user(state)
		elif stage == "first_round_reveal":
			resolve_first_round_reveal(state)
		elif stage == "first_round_result":
			continue_first_round(state)
		else:
			advance_until_user_turn_or_complete(state)
	return {"ok": bool(state.get("complete", false)), "state": state}


static func begin_development_draft(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return state
	if str(state.get("segment", "main")) == "development":
		if not bool(state.get("complete", false)):
			return advance_until_user_turn_or_complete(state)
		return state
	if not bool(state.get("complete", false)):
		return state
	state["complete"] = false
	state["allow_development_segment"] = true
	_begin_development_segment(state)
	return advance_until_user_turn_or_complete(state)


static func advance_until_user_turn_or_complete(state: Dictionary) -> Dictionary:
	if bool(state.get("complete", false)):
		return state
	# 入札公開/結果確認の対話段階では round はまだ 1 のまま止まっている。ここでガードせずに
	# 下の通常巡ループへ落ちると、1巡目が未確定なのに次の指名順を回してしまい二重指名になる。
	# この段階の進行は resolve_first_round_reveal / continue_first_round に委ねる。
	var stage_guard: String = str(state.get("stage", ""))
	if stage_guard == "first_round_reveal" or stage_guard == "first_round_result":
		return state

	var user_team_id: int = int(state.get("user_team_id", 0))
	if str(state.get("stage", "")) == "first_round_bid":
		if _team_can_pick(state, user_team_id):
			state["current_team_id"] = user_team_id
			return state
		_resolve_first_round(state)

	var guard: int = 0
	while guard < 2000:
		guard += 1
		if _segment_should_end(state):
			if _enter_next_segment_or_complete(state):
				return state
			continue

		var next_team_id: int = _next_selecting_team(state)
		if next_team_id <= 0:
			if _enter_next_segment_or_complete(state):
				return state
			continue

		state["current_team_id"] = next_team_id
		if next_team_id == user_team_id:
			state["stage"] = "user_pick"
			return state

		var candidate_id: int = _choose_cpu_candidate(state, next_team_id, int(state.get("round", 2)), false)
		if candidate_id <= 0:
			_mark_team_done(state, next_team_id)
			_consume_current_slot(state)
			continue
		_make_pick(state, next_team_id, candidate_id, int(state.get("round", 2)), "cpu", false)
		_consume_current_slot(state)

	_complete_draft(state)
	return state


# 現 segment が終わったとき、本指名なら育成ドラフトへ移行 (false を返す=継続)、
# 育成ドラフトなら全工程完了 (true を返す=呼び出し側は return)。
static func _enter_next_segment_or_complete(state: Dictionary) -> bool:
	if str(state.get("segment", "main")) == "main" and bool(state.get("allow_development_segment", true)):
		_begin_development_segment(state)
		return false
	_complete_draft(state)
	return true


# 本指名→育成ドラフトの切替。入札 (1巡目抽選) は本指名のみ。育成はスネーク順のみ。
static func _begin_development_segment(state: Dictionary) -> void:
	state["segment"] = "development"
	state["stage"] = "later_rounds"
	state["round"] = 1
	state["round_position"] = 0
	state["current_team_id"] = 0
	state["complete"] = false
	state["teams_done"] = {}
	state["team_dev_targets"] = _compute_dev_targets(state)
	(state.get("logs", []) as Array).append({"type": "segment", "segment": "development"})


# 育成ドラフトの球団別 appetite (0〜DEV_DRAFT_MAX_PICKS の一様乱数)。育成は人数無制限だが、
# **育成契約に年数上限がある** (OffseasonService.DEV_CONTRACT_MAX_SEASONS) ので保有数は
# 「年間指名数 × 契約年数」で自然に頭打ちになる。目標人数を持たせる必要はない (2026-08-02)。
# CPU は 0 (指名なし) もあり得る。ユーザーは手動 (見送りで打ち切り) のため上限のみ与える。
static func _compute_dev_targets(state: Dictionary) -> Dictionary:
	var targets: Dictionary = {}
	var user_team_id: int = int(state.get("user_team_id", 0))
	for team_id_value in state.get("teams_order_reverse", []) as Array:
		var tid: int = int(team_id_value)
		if tid == user_team_id:
			targets[str(tid)] = DEV_DRAFT_MAX_PICKS
		else:
			targets[str(tid)] = Rng.range_int(0, DEV_DRAFT_MAX_PICKS)
	return targets


static func finalize_draft(state: Dictionary, players: Array) -> Dictionary:
	if bool(state.get("finalized", false)):
		return state.get("final_result", {}) as Dictionary

	var max_id: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.id > max_id:
			max_id = player.id
	var next_id: int = max_id + 1

	var rookies: Array = []
	var picks: Array = state.get("picks", []) as Array
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		var candidate: Dictionary = _candidate_by_id(state, int(pick.get("candidate_id", 0)))
		if candidate.is_empty():
			continue
		var round_no: int = int(pick.get("round", 0))
		var player_data: Dictionary = _player_data_from_candidate(candidate, next_id, int(pick.get("team_id", 0)), round_no, pick, int(state.get("year", 0)))
		next_id += 1
		var rookie: PSPlayer = PSPlayer.from_dict(player_data)
		players.append(rookie)
		rookies.append({
			"player_id": rookie.id,
			"name": rookie.name,
			"age": rookie.age,
			"team_id": rookie.team_id,
			"position": rookie.position,
			"role": rookie.role,
			"overall": Offseason.player_value_score(rookie),
			"draft_round": round_no,
			"overall_pick": int(pick.get("overall_pick", 0)),
			"source_type": str(candidate.get("source_type", "")),
			"development_player": rookie.development_player,
		})

	state["finalized"] = true
	var result: Dictionary = {
		"draft_complete": true,
		"draft_picks": picks.duplicate(true),
		"rookies": rookies,
		"rookies_count": rookies.size(),
		"logs": (state.get("logs", []) as Array).duplicate(true),
		"priority_league": str(state.get("priority_league", "")),
	}
	state["final_result"] = result
	return result


static func available_candidates(state: Dictionary, limit: int = 120) -> Array:
	return available_candidates_for_bucket(state, "", limit)


static func available_candidates_for_bucket(state: Dictionary, bucket: String, limit: int = 120) -> Array:
	var rows: Array = []
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if bool(candidate.get("picked", false)):
			continue
		if not bucket.is_empty() and str(candidate.get("draft_bucket", "")) != bucket:
			continue
		rows.append(candidate)
	rows.sort_custom(func(a, b) -> bool:
		var ca: Dictionary = a as Dictionary
		var cb: Dictionary = b as Dictionary
		var rank_a: int = int(ca.get("bucket_rank", 999))
		var rank_b: int = int(cb.get("bucket_rank", 999))
		if rank_a != rank_b:
			return rank_a < rank_b
		if str(ca.get("draft_bucket", "")) != str(cb.get("draft_bucket", "")):
			return str(ca.get("draft_bucket", "")) < str(cb.get("draft_bucket", ""))
		return float(ca.get("draft_grade", 0.0)) > float(cb.get("draft_grade", 0.0))
	)
	if limit > 0 and rows.size() > limit:
		return rows.slice(0, limit)
	return rows


static func _resolve_first_round(state: Dictionary) -> void:
	if str(state.get("stage", "")) != "first_round_bid":
		return

	var user_team_id: int = int(state.get("user_team_id", 0))
	var guard: int = 0
	while guard < 200:
		guard += 1
		var unresolved: Array = _active_first_round_unresolved(state)
		if unresolved.is_empty():
			break
		if unresolved.has(user_team_id):
			var first_round_bids: Dictionary = state.get("first_round_bids", {}) as Dictionary
			var bid_candidate_id: int = int(first_round_bids.get(str(user_team_id), 0))
			if bid_candidate_id <= 0 or not _is_candidate_available(state, bid_candidate_id):
				_wait_for_first_round_user_bid(state, unresolved, int(state.get("first_round_wave", 1)))
				return
		_collect_cpu_first_round_bids(state, unresolved)
		_resolve_first_round_wave(state)
		var next_unresolved: Array = _active_first_round_unresolved(state)
		if next_unresolved.has(user_team_id):
			_wait_for_first_round_user_bid(state, next_unresolved, int(state.get("first_round_wave", 1)))
			return

	_finish_first_round(state)


# unresolved の各 CPU 球団に、まだ有効な入札 (_is_candidate_available) が無ければ
# _choose_cpu_candidate で決めて first_round_bids に確定保存する。ユーザー球団の
# エントリ (既にユーザーが submit_user_candidate で入れた入札) には触れない。
# 公開 (reveal) 段階で UI に見せる bids はここで確定した値そのものになる。
static func _collect_cpu_first_round_bids(state: Dictionary, unresolved: Array) -> void:
	var user_team_id: int = int(state.get("user_team_id", 0))
	var first_round_bids: Dictionary = state.get("first_round_bids", {}) as Dictionary
	for team_id_value in unresolved:
		var team_id: int = int(team_id_value)
		if team_id == user_team_id:
			continue
		var bid_candidate_id: int = int(first_round_bids.get(str(team_id), 0))
		if bid_candidate_id > 0 and _is_candidate_available(state, bid_candidate_id):
			continue
		bid_candidate_id = _choose_cpu_candidate(state, team_id, 1, false)
		if bid_candidate_id > 0:
			first_round_bids[str(team_id)] = bid_candidate_id
	state["first_round_bids"] = first_round_bids


# first_round_bids (全球団確定済み前提) から候補ごとに入札球団を集計し、単独入札は
# 即決、競合は抽選 (lottery ログを logs に append) で当選球団を決めて _make_pick する。
# 戻り値は次 wave に持ち越す未解決球団 (今回の抽選で外れた球団のうち、まだ指名余地がある球団)。
# 呼び出し後、state の first_round_bids / first_round_unresolved / first_round_wave を更新する。
static func _resolve_first_round_wave(state: Dictionary) -> Array:
	var bid_wave: int = int(state.get("first_round_wave", 1))
	var unresolved: Array = _active_first_round_unresolved(state)
	var first_round_bids: Dictionary = state.get("first_round_bids", {}) as Dictionary

	var bids_by_candidate: Dictionary = {}
	for team_id_value in unresolved:
		var team_id: int = int(team_id_value)
		var bid_candidate_id: int = int(first_round_bids.get(str(team_id), 0))
		if bid_candidate_id <= 0:
			continue
		var key: String = str(bid_candidate_id)
		if not bids_by_candidate.has(key):
			bids_by_candidate[key] = []
		(bids_by_candidate[key] as Array).append(team_id)

	var winners: Array = []
	var next_unresolved: Array = []
	for candidate_key in bids_by_candidate.keys():
		var candidate_id: int = int(candidate_key)
		var teams_for_candidate: Array = bids_by_candidate[candidate_key] as Array
		if teams_for_candidate.size() == 1:
			winners.append({
				"team_id": int(teams_for_candidate[0]),
				"candidate_id": candidate_id,
				"method": "single_bid" if bid_wave == 1 else "rebid_single",
				"lottery": false,
			})
			continue

		var winner_team_id: int = int(teams_for_candidate[Rng.range_int(0, teams_for_candidate.size() - 1)])
		var losers: Array = []
		for team_id_value in teams_for_candidate:
			var team_id: int = int(team_id_value)
			if team_id == winner_team_id:
				continue
			losers.append(team_id)
			next_unresolved.append(team_id)
		winners.append({
			"team_id": winner_team_id,
			"candidate_id": candidate_id,
			"method": "lottery",
			"lottery": true,
		})
		var candidate: Dictionary = _candidate_by_id(state, candidate_id)
		(state.get("logs", []) as Array).append({
			"type": "lottery",
			"wave": bid_wave,
			"candidate_id": candidate_id,
			"candidate_name": str(candidate.get("name", "")),
			"teams": teams_for_candidate.duplicate(),
			"winner_team_id": winner_team_id,
			"loser_team_ids": losers,
		})

	winners.sort_custom(func(a, b) -> bool:
		var wa: Dictionary = a as Dictionary
		var wb: Dictionary = b as Dictionary
		var order: Array = state.get("teams_order_reverse", []) as Array
		return _order_index(order, int(wa.get("team_id", 0))) < _order_index(order, int(wb.get("team_id", 0)))
	)
	for winner_row in winners:
		var winner: Dictionary = winner_row as Dictionary
		if _is_candidate_available(state, int(winner.get("candidate_id", 0))):
			_make_pick(state, int(winner.get("team_id", 0)), int(winner.get("candidate_id", 0)), 1, str(winner.get("method", "bid")), bool(winner.get("lottery", false)))

	var resolved_next_unresolved: Array = []
	for team_id_value in next_unresolved:
		var team_id: int = int(team_id_value)
		if _team_can_pick(state, team_id) and not _team_has_round_pick(state, team_id, 1):
			resolved_next_unresolved.append(team_id)

	state["first_round_bids"] = {}
	state["first_round_unresolved"] = resolved_next_unresolved.duplicate()
	bid_wave += 1
	state["first_round_wave"] = bid_wave
	return resolved_next_unresolved


# 1巡目の後始末。stage を later_rounds/round=2 に進め、入札関連の一時状態をクリアする。
# first_round_wave は「何 wave で決着したか」の記録として維持する。
static func _finish_first_round(state: Dictionary) -> void:
	state["stage"] = "later_rounds"
	state["round"] = 2
	state["round_position"] = 0
	state["current_team_id"] = 0
	state["first_round_bids"] = {}
	state["first_round_unresolved"] = []
	state["first_round_reveal"] = {}


static func _active_first_round_unresolved(state: Dictionary) -> Array:
	var stored: Array = state.get("first_round_unresolved", []) as Array
	var source: Array = stored if not stored.is_empty() else state.get("teams_order_reverse", []) as Array
	var rows: Array = []
	for team_id_value in source:
		var team_id: int = int(team_id_value)
		if not _team_can_pick(state, team_id):
			continue
		if _team_has_round_pick(state, team_id, 1):
			continue
		rows.append(team_id)
	return rows


static func _wait_for_first_round_user_bid(state: Dictionary, unresolved: Array, bid_wave: int) -> void:
	state["stage"] = "first_round_bid"
	state["round"] = 1
	state["round_position"] = 0
	state["current_team_id"] = int(state.get("user_team_id", 0))
	state["first_round_unresolved"] = unresolved.duplicate()
	state["first_round_wave"] = bid_wave
	state["first_round_bids"] = {}


# ユーザーが入札した直後に呼ぶ。残り (CPU) 球団の入札を確定させ、入札公開 (reveal) 段階へ進める。
# 全球団の入札が first_round_bids に確定した状態で state["first_round_reveal"] にスナップショットを
# 残すため、UI は「どの球団がどの候補に入札したか」を抽選前に一覧表示できる。
# 入札が1件も無い (対象球団が既にいない等) 場合は、公開する内容が無いのでそのまま1巡目を締めて進行する。
static func _prepare_first_round_reveal(state: Dictionary) -> void:
	var unresolved: Array = _active_first_round_unresolved(state)
	_collect_cpu_first_round_bids(state, unresolved)
	var first_round_bids: Dictionary = state.get("first_round_bids", {}) as Dictionary
	if first_round_bids.is_empty():
		_finish_first_round(state)
		advance_until_user_turn_or_complete(state)
		return
	state["first_round_reveal"] = {
		"wave": int(state.get("first_round_wave", 1)),
		"bids": first_round_bids.duplicate(),
		"resolved": false,
		"winners": {},
		"loser_team_ids": [],
	}
	state["stage"] = "first_round_reveal"
	state["current_team_id"] = 0


# 「抽選へ」。公開済みの入札 (first_round_bids) を1 wave 分だけ解決し、結果確認 (result) 段階へ進める。
# 単独入札は確定、競合は抽選 (_resolve_first_round_wave が logs に lottery エントリを積む) で決まる。
static func resolve_first_round_reveal(state: Dictionary) -> Dictionary:
	if str(state.get("stage", "")) != "first_round_reveal":
		return {"ok": false, "message": "現在は入札公開の段階ではありません。", "state": state}

	var picks: Array = state.get("picks", []) as Array
	var picks_before: int = picks.size()
	var next_unresolved: Array = _resolve_first_round_wave(state)

	var winners: Dictionary = {}
	for i in range(picks_before, picks.size()):
		var pick: Dictionary = picks[i] as Dictionary
		if int(pick.get("round", 0)) != 1:
			continue
		winners[str(pick.get("candidate_id", 0))] = int(pick.get("team_id", 0))

	var reveal: Dictionary = state.get("first_round_reveal", {}) as Dictionary
	reveal["winners"] = winners
	reveal["loser_team_ids"] = next_unresolved.duplicate()
	reveal["resolved"] = true
	state["first_round_reveal"] = reveal
	state["stage"] = "first_round_result"
	return {"ok": true, "state": state}


# 「次へ」。抽選で外れて再入札が必要な球団があればユーザーの入札待ちへ (ユーザーが含まれる場合) か
# CPU のみの再入札を公開 (含まれない場合) へ進む。誰も残っていなければ1巡目を締めて次の巡へ進む。
static func continue_first_round(state: Dictionary) -> Dictionary:
	if str(state.get("stage", "")) != "first_round_result":
		return {"ok": false, "message": "現在は結果確認の段階ではありません。", "state": state}

	var user_team_id: int = int(state.get("user_team_id", 0))
	var unresolved: Array = _active_first_round_unresolved(state)
	if unresolved.is_empty():
		_finish_first_round(state)
		advance_until_user_turn_or_complete(state)
		return {"ok": true, "state": state}

	if unresolved.has(user_team_id):
		_wait_for_first_round_user_bid(state, unresolved, int(state.get("first_round_wave", 1)))
		state["first_round_reveal"] = {}
		return {"ok": true, "state": state}

	_prepare_first_round_reveal(state)
	return {"ok": true, "state": state}


static func _make_pick(state: Dictionary, team_id: int, candidate_id: int, round_no: int, method: String, lottery: bool) -> void:
	var candidate: Dictionary = _candidate_by_id(state, candidate_id)
	if candidate.is_empty():
		return
	candidate["picked"] = true
	candidate["picked_by_team_id"] = team_id

	var is_dev: bool = str(state.get("segment", "main")) == "development"
	var pick: Dictionary = {
		"overall_pick": (state.get("picks", []) as Array).size() + 1,
		"round": round_no,
		"team_id": team_id,
		"candidate_id": candidate_id,
		"name": str(candidate.get("name", "")),
		"age": int(candidate.get("age", 0)),
		"position": int(candidate.get("position", 0)),
		"role": str((candidate.get("player_template", {}) as Dictionary).get("role", "")),
		"overall": int(candidate.get("overall", 0)),
		"potential": int(candidate.get("potential", 0)),
		"future_value": int(candidate.get("future_value", candidate.get("potential", 0))),
		"growth_expectation": float(candidate.get("growth_expectation", 0.0)),
		"source_type": str(candidate.get("source_type", "")),
		"method": method,
		"lottery": lottery,
		# 育成ドラフト指名は development=true。本指名は false。finalize_draft で支配下/育成を決める。
		"development": is_dev,
	}
	(state.get("picks", []) as Array).append(pick)

	if is_dev:
		var dev_counts: Dictionary = state.get("team_dev_pick_counts", {}) as Dictionary
		dev_counts[str(team_id)] = int(dev_counts.get(str(team_id), 0)) + 1
	else:
		var counts: Dictionary = state.get("team_pick_counts", {}) as Dictionary
		counts[str(team_id)] = int(counts.get(str(team_id), 0)) + 1
	var profiles: Dictionary = state.get("team_profiles", {}) as Dictionary
	var profile: Dictionary = profiles.get(str(team_id), {}) as Dictionary
	var group: String = _candidate_group(candidate)
	profile[group] = int(profile.get(group, 0)) + 1
	profile["total"] = int(profile.get("total", 0)) + 1
	profiles[str(team_id)] = profile


static func _next_selecting_team(state: Dictionary) -> int:
	var guard: int = 0
	while guard < 300:
		guard += 1
		var round_no: int = int(state.get("round", 2))
		var order: Array = _order_for_round(state, round_no)
		var pos: int = int(state.get("round_position", 0))
		if pos >= order.size():
			state["round"] = round_no + 1
			state["round_position"] = 0
			continue
		var team_id: int = int(order[pos])
		if _team_can_pick(state, team_id):
			return team_id
		state["round_position"] = pos + 1
	return 0


static func _consume_current_slot(state: Dictionary) -> void:
	state["round_position"] = int(state.get("round_position", 0)) + 1
	state["current_team_id"] = 0
	state["stage"] = "later_rounds"


static func _order_for_round(state: Dictionary, round_no: int) -> Array:
	# 完全ウェーバー制の本指名は全巡 reverse 固定 (スネークなし)。育成ドラフトは
	# order_mode によらず現行のスネークを維持する (segment=="main" 限定の分岐)。
	if str(state.get("order_mode", "snake")) == "waiver" and str(state.get("segment", "main")) == "main":
		return state.get("teams_order_reverse", []) as Array
	if round_no % 2 == 0:
		return state.get("teams_order_reverse", []) as Array
	return state.get("teams_order_forward", []) as Array


static func _team_can_pick(state: Dictionary, team_id: int) -> bool:
	if team_id <= 0:
		return false
	if (state.get("picks", []) as Array).size() >= MAX_TOTAL_PICKS:
		return false
	# segment ごとに「もう指名しない」と決めた球団は対象外。
	if (state.get("teams_done", {}) as Dictionary).has(str(team_id)):
		return false
	var profiles: Dictionary = state.get("team_profiles", {}) as Dictionary
	var profile: Dictionary = profiles.get(str(team_id), {}) as Dictionary
	if str(state.get("segment", "main")) == "development":
		# 育成ドラフト: 育成の人数上限は無い (2026-08-02 撤廃) ので、球団ごとの appetite
		# (team_dev_targets、保有目安との差で決まる) と1球団あたりの上限だけで止める。
		var dev_counts: Dictionary = state.get("team_dev_pick_counts", {}) as Dictionary
		var dev_picked: int = int(dev_counts.get(str(team_id), 0))
		var targets: Dictionary = state.get("team_dev_targets", {}) as Dictionary
		var target: int = int(targets.get(str(team_id), DEV_DRAFT_MAX_PICKS))
		return dev_picked < target and dev_picked < DEV_DRAFT_MAX_PICKS
	# 本指名: 支配下 hard 空き (70 − 在籍支配下) と need-driven 目標 (team_main_targets) で制限。
	# ドラフトは年1回の主補強なので soft 67 では止めず、3人程度で終わる年を避ける。
	var counts: Dictionary = state.get("team_pick_counts", {}) as Dictionary
	var picked_count: int = int(counts.get(str(team_id), 0))
	var capacity: int = max(0, ROSTER_LIMIT - int(profile.get("initial_total", profile.get("total", 0))))
	var targets: Dictionary = state.get("team_main_targets", {}) as Dictionary
	var target: int = int(targets.get(str(team_id), MAIN_DRAFT_MAX_PICKS))
	return picked_count < target and picked_count < capacity


static func _team_has_round_pick(state: Dictionary, team_id: int, round_no: int) -> bool:
	for pick_row in state.get("picks", []) as Array:
		var pick: Dictionary = pick_row as Dictionary
		if int(pick.get("team_id", 0)) == team_id and int(pick.get("round", 0)) == round_no:
			return true
	return false


# 現 segment で当該球団を打ち切る (これ以上指名しない)。segment 開始で teams_done はリセットされる。
static func _mark_team_done(state: Dictionary, team_id: int) -> void:
	var done: Dictionary = state.get("teams_done", {}) as Dictionary
	done[str(team_id)] = true
	state["teams_done"] = done


# 現 segment (本指名 or 育成) の指名が出尽くしたか。_team_can_pick が segment を見るので両用。
static func _segment_should_end(state: Dictionary) -> bool:
	if (state.get("picks", []) as Array).size() >= MAX_TOTAL_PICKS:
		return true
	if available_candidates(state, 1).is_empty():
		return true
	for team_id_value in state.get("teams_order_reverse", []) as Array:
		if _team_can_pick(state, int(team_id_value)):
			return false
	return true


static func _complete_draft(state: Dictionary) -> void:
	state["complete"] = true
	state["stage"] = "complete"
	state["current_team_id"] = 0


static func _choose_cpu_candidate(state: Dictionary, team_id: int, round_no: int, user_team: bool) -> int:
	var best_id: int = 0
	var best_score: float = -999999.0
	var scan_limit: int = 80 if round_no <= 2 else 120
	var candidates: Array
	# 1巡目の入札 (バケット選択) は本指名のみ。育成ドラフトは全候補からスネーク指名。
	if round_no == 1 and str(state.get("segment", "main")) == "main":
		var bucket: String = _choose_first_round_bucket(state, team_id)
		candidates = available_candidates_for_bucket(state, bucket, 40)
		if candidates.is_empty():
			candidates = available_candidates_for_bucket(state, "fielder" if bucket == "pitcher" else "pitcher", 40)
	else:
		candidates = available_candidates(state, scan_limit)
	for candidate_row in candidates:
		var candidate: Dictionary = candidate_row as Dictionary
		var score: float = _team_candidate_score(state, team_id, candidate, round_no, user_team)
		if score > best_score:
			best_score = score
			best_id = int(candidate.get("candidate_id", 0))
	return best_id


static func _choose_first_round_bucket(state: Dictionary, team_id: int) -> String:
	var profiles: Dictionary = state.get("team_profiles", {}) as Dictionary
	var profile: Dictionary = profiles.get(str(team_id), {}) as Dictionary
	var pitchers: int = int(profile.get("pitcher", 0))
	var fielders: int = int(profile.get("catcher", 0)) + int(profile.get("infield", 0)) + int(profile.get("outfield", 0))
	var total: int = max(1, pitchers + fielders)
	var pitcher_share: float = float(pitchers) / float(total)
	var pitcher_chance: float = 0.63 + clamp(0.52 - pitcher_share, -0.12, 0.16) * 2.2
	pitcher_chance += (Rng.roll_float() - 0.5) * 0.24
	pitcher_chance = clamp(pitcher_chance, 0.34, 0.82)
	return "pitcher" if Rng.roll_float() <= pitcher_chance else "fielder"


static func _team_candidate_score(state: Dictionary, team_id: int, candidate: Dictionary, round_no: int, user_team: bool) -> float:
	var score: float = float(candidate.get("bucket_grade", candidate.get("draft_grade", 0.0)))
	var profiles: Dictionary = state.get("team_profiles", {}) as Dictionary
	var profile: Dictionary = profiles.get(str(team_id), {}) as Dictionary
	var group: String = _candidate_group(candidate)
	var target: int = int(GROUP_TARGETS.get(group, 10))
	var current: int = int(profile.get(group, 0))
	var shortage: int = max(0, target - current)
	var need_weight: float = 1.2 if round_no == 1 else 3.2
	score += float(shortage) * need_weight
	score += _bucket_balance_score(profile, str(candidate.get("draft_bucket", "")), round_no)
	# ポジション別 WAR 不足を補強需要として加算 (Phase C)。
	# 候補のポジションが「チームのそのポジションの WAR がリーグ平均を下回る」場合に
	# 候補スコアを押し上げ、CPU が穴ポジションを優先的に補強しやすくする。
	score += _position_need_bonus(state, team_id, candidate, round_no)
	# 守備位置別の適性保持者が薄い位置を優先補強 (主力健在なら順位を下げる)。
	score += _position_aptitude_need_bonus(profile, candidate, round_no)
	# 本職が最低数 (野手2/捕手6) を下回る位置を強く優先補強。
	score += _primary_position_need_bonus(profile, candidate, round_no)
	# 複数サブポジ適性を持つユーティリティ選手をわずかに高評価。
	score += _utility_bonus(candidate)
	if round_no == 1:
		score += float(candidate.get("future_value", candidate.get("potential", 0))) * 0.08
		score += float(candidate.get("growth_expectation", 0.0)) * 0.8
	else:
		score += float(candidate.get("overall", 0)) * 0.04
		score += float(candidate.get("future_value", candidate.get("potential", 0))) * 0.02
	if user_team:
		score += 0.5
	score += Rng.roll_float() * (4.0 if round_no == 1 else 8.0)
	return score


# デプスチャート由来のポジション別補強ボーナス ([[TeamDepthChart]] の `first_team_need`)。
# 候補のポジションが「そのスロットの一軍枠の質がリーグ平均を下回る」ほど候補スコアを押し上げ、
# CPU が穴ポジションを優先的に補強しやすくする。投手 (position 1) は先発/救援の need の大きい方。
static func _position_need_bonus(state: Dictionary, team_id: int, candidate: Dictionary, round_no: int) -> float:
	var need: Dictionary = state.get("team_position_need", {}) as Dictionary
	if need.is_empty():
		return 0.0
	var team_need: Dictionary = need.get(str(team_id), {}) as Dictionary
	if team_need.is_empty():
		return 0.0
	var position: int = int(candidate.get("position", 0))
	if position <= 0:
		return 0.0
	var deficit: float = float(team_need.get(position, 0.0))
	if deficit <= 0.0:
		return 0.0
	return deficit * (POSITION_NEED_WEIGHT_ROUND1 if round_no == 1 else POSITION_NEED_WEIGHT_LATER)


# 守備位置別の適性保持者数に基づく補強需要。
# 候補の本職ポジションの保持者が POSITION_DEPTH_TARGET 未満なら、その不足分に応じて
# 候補スコアを押し上げる。ただしその位置に健在の主力 (top_overall >= STRONG_STARTER_OVERALL)
# がいる場合は STRONG_STARTER_DAMPEN を乗じて優先度を下げる (depth 補充は後の指名で十分)。
static func _position_aptitude_need_bonus(profile: Dictionary, candidate: Dictionary, round_no: int) -> float:
	var position: int = int(candidate.get("position", 0))
	if position < 2 or position > 9:
		return 0.0
	var holders_map: Dictionary = profile.get("position_holders", {}) as Dictionary
	var holders: int = int(holders_map.get(position, 0))
	var shortage: int = POSITION_DEPTH_TARGET - holders
	if shortage <= 0:
		return 0.0
	var weight: float = POSITION_APT_NEED_WEIGHT_ROUND1 if round_no == 1 else POSITION_APT_NEED_WEIGHT_LATER
	var bonus: float = float(shortage) * weight
	var top_overall_map: Dictionary = profile.get("position_top_overall", {}) as Dictionary
	if int(top_overall_map.get(position, 0)) >= STRONG_STARTER_OVERALL:
		bonus *= STRONG_STARTER_DAMPEN
	return bonus


# 本職 (primary position) が最低数を下回る位置を強く優先補強する。
# 野手は各位置 2 人、捕手は 6 人を下限とし、不足分 × 重みで加点。適性保持者の
# 需要 (_position_aptitude_need_bonus) より強い重みにして、本職の枯渇を確実に防ぐ。
static func _primary_position_need_bonus(profile: Dictionary, candidate: Dictionary, round_no: int) -> float:
	var position: int = int(candidate.get("position", 0))
	if position < 2 or position > 9:
		return 0.0
	var primary_map: Dictionary = profile.get("position_primary_count", {}) as Dictionary
	var minimum: int = CATCHER_PRIMARY_MIN if position == 2 else FIELD_PRIMARY_MIN
	var shortage: int = minimum - int(primary_map.get(position, 0))
	if shortage <= 0:
		return 0.0
	var weight: float = PRIMARY_NEED_WEIGHT_ROUND1 if round_no == 1 else PRIMARY_NEED_WEIGHT_LATER
	return float(shortage) * weight


# 複数のサブポジション適性を持つユーティリティ選手をわずかに高評価する。
# 本職以外で適性 > 0 の守備位置数 × UTILITY_SUBPOS_WEIGHT。
static func _utility_bonus(candidate: Dictionary) -> float:
	var template: Dictionary = candidate.get("player_template", {}) as Dictionary
	var aptitudes: Dictionary = template.get("position_aptitudes", {}) as Dictionary
	if aptitudes.is_empty():
		return 0.0
	var primary_key: String = str(POSITION_NAME_BY_ID.get(int(candidate.get("position", 0)), ""))
	var sub_count: int = 0
	for key in aptitudes.keys():
		if str(key) == primary_key:
			continue
		if int(aptitudes.get(key, 0)) > 0:
			sub_count += 1
	return float(sub_count) * UTILITY_SUBPOS_WEIGHT


static func _bucket_balance_score(profile: Dictionary, bucket: String, round_no: int) -> float:
	var pitchers: int = int(profile.get("pitcher", 0))
	var fielders: int = int(profile.get("catcher", 0)) + int(profile.get("infield", 0)) + int(profile.get("outfield", 0))
	var total: int = max(1, pitchers + fielders)
	var pitcher_share: float = float(pitchers) / float(total)
	if bucket == "pitcher":
		return clamp(0.52 - pitcher_share, -0.18, 0.24) * (34.0 if round_no == 1 else 48.0)
	return clamp(pitcher_share - 0.48, -0.18, 0.22) * (30.0 if round_no == 1 else 42.0)


# 本指名の球団別目標指名数。**人数は毎年6〜7人の固定枠**で、在籍数・昇格見込み・後段補強の
# いずれからも引かない (2026-08-03 ユーザー方針)。現実のドラフトは空き枠の逆算ではなく
# 「毎年この人数を指名し、**誰を取るか**を年齢・ポジション・能力の need で決める」運用のため。
# 人数の帳尻は戦力外側 (`OffseasonService._release_plan_count` が余りで決める) が合わせる。
# hard 70枠 (+外国人枠の確保) だけが安全弁として枠を縮められる。
# profiles は _build_team_profiles 済み (initial_total = 戦力外後の在籍支配下)。
static func _compute_main_draft_targets(_players: Array, profiles: Dictionary) -> Dictionary:
	var targets: Dictionary = {}
	for key in profiles.keys():
		var profile: Dictionary = profiles[key] as Dictionary
		var current: int = int(profile.get("initial_total", profile.get("total", 0)))
		# 指名枠は固定 (6〜7人)。**在籍数からも昇格見込みからも引かない** — 人数の帳尻は
		# 戦力外側が余りで合わせる (2026-08-03)。hard 70枠の安全弁だけが枠を縮められる。
		var target: int = Rng.range_int(MAIN_DRAFT_TARGET_MIN, MAIN_DRAFT_TARGET_MAX)
		targets[key] = clampi(min(target, _main_draft_capacity(current, profile)), 0, MAIN_DRAFT_MAX_PICKS)
	return targets


static func _main_draft_capacity(current_shienka: int, profile: Dictionary) -> int:
	var hard_capacity: int = max(0, ROSTER_LIMIT - current_shienka)
	var reserve: int = _main_draft_signing_reserve(profile)
	var reserved_capacity: int = max(0, hard_capacity - reserve)
	if hard_capacity <= MAIN_DRAFT_MIN_PICKS:
		return hard_capacity
	return max(MAIN_DRAFT_MIN_PICKS, reserved_capacity)


# 本指名で埋め切らずに残す hard 枠。**外国人の不足分だけ**を予約する — 外国人4人保有は編成の前提で
# 枠を確保しないと成立しないため。FA/戦力外獲得のための一般予約 (旧 DRAFT_SIGNING_RESERVE=2) は
# 2026-08-03 に撤廃した: 「毎年必ず2人補強する」前提は現実と乖離しており (誰も獲らない年が普通)、
# その予約が指名枠と戦力外数の両方を押し下げていた。
static func _main_draft_signing_reserve(profile: Dictionary) -> int:
	var foreign_count: int = int(profile.get("foreign", 0))
	return max(0, FOREIGN_ROSTER_RESERVE_TARGET - foreign_count)


static func _build_team_profiles(players: Array, teams: Array) -> Dictionary:
	var profiles: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		profiles[str(team.id)] = {
			"total": 0,
			"initial_total": 0,
			"initial_development_total": 0,
			"pitcher": 0,
			"catcher": 0,
			"infield": 0,
			"outfield": 0,
			"foreign": 0,
			# 守備位置別の適性保持者数と、その位置の最強保持者 overall (主力健在判定用)。
			"position_holders": {2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
			"position_top_overall": {2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
			# 本職 (primary position) 別の人数。本職 2 人以上 / 捕手 6 人以上の確保に使う。
			"position_primary_count": {2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0, 9: 0},
		}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		# roadmap #3: 育成選手は支配下70枠の外。容量(initial_total)・需要(position_*)から除外するが、
		# 育成ドラフトの appetite (保有目安との差) を出すため initial_development_total を別途集計する。
		if player.development_player:
			var key_dev: String = str(player.team_id)
			if profiles.has(key_dev):
				var profile_dev: Dictionary = profiles[key_dev] as Dictionary
				profile_dev["initial_development_total"] = int(profile_dev.get("initial_development_total", 0)) + 1
			continue
		var key: String = str(player.team_id)
		if not profiles.has(key):
			continue
		var profile: Dictionary = profiles[key] as Dictionary
		var group: String = _position_group(player.position)
		profile["total"] = int(profile.get("total", 0)) + 1
		profile["initial_total"] = int(profile.get("initial_total", 0)) + 1
		profile[group] = int(profile.get(group, 0)) + 1
		if player.foreign_player:
			profile["foreign"] = int(profile.get("foreign", 0)) + 1
		if not player.is_pitcher():
			var holders: Dictionary = profile["position_holders"] as Dictionary
			var top_overall: Dictionary = profile["position_top_overall"] as Dictionary
			var primary_count: Dictionary = profile["position_primary_count"] as Dictionary
			var overall: int = Offseason.player_value_score(player)
			if primary_count.has(player.position):
				primary_count[player.position] = int(primary_count.get(player.position, 0)) + 1
			for position in range(2, 10):
				if _player_position_aptitude(player, position) > 0:
					holders[position] = int(holders.get(position, 0)) + 1
					if overall > int(top_overall.get(position, 0)):
						top_overall[position] = overall
	return profiles


# 既存選手の守備位置 position(2-9) の適性値。PlayerValueEvaluator.position_aptitude と同じ規約:
# position_aptitudes が空なら本職のみ 100 とみなす。
static func _player_position_aptitude(player: PSPlayer, position: int) -> int:
	if player == null or player.is_pitcher():
		return 0
	var key: String = str(POSITION_NAME_BY_ID.get(position, ""))
	if key.is_empty():
		return 0
	var aptitudes: Dictionary = player.position_aptitudes
	if aptitudes.is_empty():
		return 100 if player.position == position else 0
	return int(aptitudes.get(key, 0))


static func _empty_team_counts(teams: Array) -> Dictionary:
	var counts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		counts[str(team.id)] = 0
	return counts


static func _draft_reverse_order(teams: Array, season: PSSeason) -> Array:
	var by_league: Dictionary = {
		"league1": [],
		"league2": [],
	}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if by_league.has(team.league):
			(by_league[team.league] as Array).append(team)

	for league in by_league.keys():
		var league_teams: Array = by_league[league] as Array
		league_teams.sort_custom(func(a, b) -> bool:
			return _team_rank_cmp(a as PSTeam, b as PSTeam, season)
		)

	var priority: String = _priority_league(season.year if season != null else 0)
	var other: String = "league2" if priority == "league1" else "league1"
	var priority_teams: Array = by_league[priority] as Array
	var other_teams: Array = by_league[other] as Array
	var order: Array = []
	var max_size: int = max(priority_teams.size(), other_teams.size())
	for offset in range(max_size):
		var idx_priority: int = priority_teams.size() - 1 - offset
		if idx_priority >= 0:
			order.append((priority_teams[idx_priority] as PSTeam).id)
		var idx_other: int = other_teams.size() - 1 - offset
		if idx_other >= 0:
			order.append((other_teams[idx_other] as PSTeam).id)
	return order


static func _team_rank_cmp(a: PSTeam, b: PSTeam, season: PSSeason) -> bool:
	var stats_a: PSStats = null
	var stats_b: PSStats = null
	if season != null:
		stats_a = season.standings.get(a.id) as PSStats
		stats_b = season.standings.get(b.id) as PSStats
	var rate_a: float = stats_a.win_rate() if stats_a != null else float(7 - a.previous_rank)
	var rate_b: float = stats_b.win_rate() if stats_b != null else float(7 - b.previous_rank)
	if not is_equal_approx(rate_a, rate_b):
		return rate_a > rate_b
	var wins_a: int = stats_a.wins if stats_a != null else 0
	var wins_b: int = stats_b.wins if stats_b != null else 0
	if wins_a != wins_b:
		return wins_a > wins_b
	var diff_a: int = (stats_a.runs_scored - stats_a.runs_allowed) if stats_a != null else 0
	var diff_b: int = (stats_b.runs_scored - stats_b.runs_allowed) if stats_b != null else 0
	if diff_a != diff_b:
		return diff_a > diff_b
	return a.id < b.id


static func _priority_league(year: int) -> String:
	return "league1" if year % 2 == 1 else "league2"


static func _generate_candidate_pool(count: int) -> Array:
	var rows: Array = []
	for i in range(count):
		var candidate: Dictionary = _generate_candidate(i + 1)
		rows.append(candidate)
	_apply_bucket_grades(rows)
	rows.sort_custom(func(a, b) -> bool:
		var ca: Dictionary = a as Dictionary
		var cb: Dictionary = b as Dictionary
		if str(ca.get("draft_bucket", "")) == str(cb.get("draft_bucket", "")):
			return int(ca.get("bucket_rank", 999)) < int(cb.get("bucket_rank", 999))
		return str(ca.get("draft_bucket", "")) < str(cb.get("draft_bucket", ""))
	)
	for i in range(rows.size()):
		(rows[i] as Dictionary)["pre_draft_rank"] = i + 1
	return rows


static func _generate_candidate(candidate_id: int) -> Dictionary:
	var source_type: String = _candidate_source_type()
	var position: int = _candidate_position()
	var is_foreign: bool = false
	var name: String = NamePool.pick_japanese_name()
	var age: int = _age_for_source(source_type)
	var quality: Dictionary = _candidate_quality(source_type, age)
	var player_data: Dictionary = _candidate_player_data(candidate_id, name, age, position, source_type, is_foreign, quality)
	var probe_player: PSPlayer = PSPlayer.from_dict(player_data)
	var overall: int = Offseason.player_value_score(probe_player)
	var growth_expectation: float = Offseason.expected_development_score_bonus(age, 6, position)
	var future_value: int = int(clamp(round(
		float(overall)
		+ growth_expectation
		+ float(quality.get("potential_bonus", 10)) * 0.45
		+ float(Rng.range_int(-3, 5))
	), 35.0, 99.0))
	var potential: int = max(overall, future_value)
	# ボードの並び順 (bucket_rank) を決める評価値。
	# overall + 年齢ベースの成長期待 (growth_expectation) のみで構成し、
	# potential や乱数ジッターは入れない。これにより「同一年齢 (= growth_expectation が同一)
	# の中では総合が高い順 = 上位」になり、ノイズによる逆転表示をなくす。
	# 年齢が違う場合のみ若手のアップサイドで順位が上がる (= 意図したドラフト挙動)。
	# CPU の指名採点は bucket_grade を使うため、ここを乱数フリーにしても多様性は保たれる。
	var draft_grade: float = float(overall) * 0.7 + growth_expectation * 1.0
	var bucket: String = _draft_bucket_for_position(position)
	return {
		"candidate_id": candidate_id,
		"name": name,
		"age": age,
		"position": position,
		"draft_bucket": bucket,
		"source_type": source_type,
		"foreign_player": is_foreign,
		"overall": overall,
		"potential": potential,
		"future_value": future_value,
		"growth_expectation": growth_expectation,
		"draft_grade": draft_grade,
		"bucket_grade": draft_grade,
		"bucket_rank": 999,
		"picked": false,
		"picked_by_team_id": 0,
		"player_template": player_data,
	}


static func _apply_bucket_grades(rows: Array) -> void:
	_apply_one_bucket_grade(rows, "pitcher")
	_apply_one_bucket_grade(rows, "fielder")


static func _apply_one_bucket_grade(rows: Array, bucket: String) -> void:
	var bucket_rows: Array = []
	for row in rows:
		var candidate: Dictionary = row as Dictionary
		if str(candidate.get("draft_bucket", "")) == bucket:
			bucket_rows.append(candidate)
	bucket_rows.sort_custom(func(a, b) -> bool:
		var ca: Dictionary = a as Dictionary
		var cb: Dictionary = b as Dictionary
		return float(ca.get("draft_grade", 0.0)) > float(cb.get("draft_grade", 0.0))
	)
	var count: int = max(1, bucket_rows.size())
	for i in range(bucket_rows.size()):
		var candidate: Dictionary = bucket_rows[i] as Dictionary
		var percentile: float = 1.0 - (float(i) / float(count))
		candidate["bucket_rank"] = i + 1
		candidate["bucket_grade"] = 45.0 + percentile * 55.0


static func _candidate_player_data(candidate_id: int, name: String, age: int, position: int, source_type: String, is_foreign: bool, quality: Dictionary) -> Dictionary:
	var center: int = int(quality.get("center", 55))
	var ability_variance: int = int(quality.get("ability_variance", 12))
	var z_abilities: Dictionary = Offseason.generated_z_abilities(position, center, 70, ability_variance)
	_tune_draft_generated_z_abilities(z_abilities, position)
	var raw_abilities: Dictionary = Offseason.generated_raw_abilities(position, z_abilities)
	var arsenal: Array = Offseason.generated_arsenal(position, z_abilities)
	var data: Dictionary = {
		"id": candidate_id,
		"sensyu_num": candidate_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": 0,
		"name": name,
		"age": age,
		"years": 0,
		"height": Rng.range_int(170, 193),
		"weight": Rng.range_int(70, 100),
		"position": position,
		"role": "" if position == 1 else "fielder",
		"throws": "L" if Rng.roll_percent() <= 25 else "R",
		"bats": "L" if Rng.roll_percent() <= 35 else "R",
		"salary": 1000,
		"draft_round": 0,
		"hometown": "",
		"registered_roster": "支配下",
		"contract_status": "通常",
		"foreign_player": is_foreign,
		"position_aptitudes": _candidate_position_aptitudes(position),
		"source_data": {
			"draft_candidate": true,
			"draft_source": source_type,
		},
		"fatigue": 0,
		"injury_days": 0,
		"z_abilities": z_abilities,
		"raw_abilities": raw_abilities,
		"arsenal": arsenal,
	}
	if position == 1:
		data["role"] = _initial_pitcher_role(data)
	return data


static func _initial_pitcher_role(player_data: Dictionary) -> String:
	var neutral_data: Dictionary = player_data.duplicate(true)
	neutral_data["role"] = ""
	return PitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral_data))


static func _tune_draft_generated_z_abilities(z: Dictionary, position: int) -> void:
	if position == 1:
		return

	for key in ["Bat_KAvoid", "Bat_BBCreate", "Bat_Barrel", "Bat_Spray"]:
		_shift_z(z, key, -0.24, -2.4, 3.2)
	for key in ["Run_Speed", "Run_Judgment", "Run_Steal"]:
		_shift_z(z, key, -0.16, -2.4, 3.2)
	for key in [
		"C_Framing", "C_Blocking", "C_Throw", "C_GameCall", "C_FieldSecure",
		"IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit",
		"OF_Reach", "OF_Route", "OF_Secure", "OF_ArmPower", "OF_ArmAccuracy", "OF_Release", "OF_PositionFit",
	]:
		_shift_z(z, key, -0.24, -2.4, 3.2)

	var impact: float = _z_value(z, "Bat_Impact")
	var loft: float = _z_value(z, "Bat_Loft")
	var power_center: float = impact * 0.62 + loft * 0.38
	var roll: int = Rng.roll_percent()
	if roll <= 22:
		power_center += _rng_delta_z(6, 13)
		_set_z(z, "Bat_Impact", power_center + _rng_delta_z(0, 5), -2.0, 3.36)
		_set_z(z, "Bat_Loft", power_center + _rng_delta_z(-2, 5), -2.0, 3.36)
		_shift_z(z, "Bat_KAvoid", -0.24, -2.4, 3.2)
		_shift_z(z, "Run_Speed", -0.16, -2.4, 3.2)
	elif roll <= 70:
		power_center += _rng_delta_z(0, 5)
		_set_z(z, "Bat_Impact", power_center + _rng_delta_z(-2, 3), -2.0, 3.2)
		_set_z(z, "Bat_Loft", power_center + _rng_delta_z(-3, 3), -2.0, 3.2)
	else:
		power_center -= _rng_delta_z(9, 17)
		_set_z(z, "Bat_Impact", power_center + _rng_delta_z(-4, 2), -2.4, 2.72)
		_set_z(z, "Bat_Loft", power_center + _rng_delta_z(-5, 1), -2.4, 2.72)
		_shift_z(z, "Bat_Barrel", 0.16, -2.4, 3.2)
		_shift_z(z, "Run_Speed", 0.16, -2.4, 3.2)

	_apply_position_ability_bias(z, position)
	# 打撃再ロール後にも C/SS の打撃テール上限 (守備スペクトラム制約) を保証する。
	Offseason.apply_fielder_bat_spectrum_cap(z, position)


# ポジション別の打撃/守備傾向バイアス (ユーザー要件)。
# 守備型ポジ(捕手・二塁・遊撃・中堅)は打撃を下げ守備を上げ、打撃型ポジ(一塁・左翼)は
# 打撃を上げ守備を下げる。ただし総合評価値 (player_value_score) はポジション間で
# 差が出ないようにする = 「打撃を動かした分を守備で相殺する」。
# 総合は打撃を重く評価する (offense_weight≈0.68-0.84) ため、相殺に必要な守備の振り幅は
# 打撃の振り幅より大きくなる (= 守備型は守備を大きく+、打撃型は守備を大きく-)。
# 振り幅は no-bias 時の本職ポジ別 mean overall (≒39) に各ポジが戻るよう実測で較正。
# 三塁(5)・右翼(9) はユーザーの 2 リストに無いため中庸 (バイアス無し)。
# 旧 1-100 点デルタを z 換算 (÷12.5)。bat ±2→±0.16、def は 22/18/24/13/-32/-20 → ÷12.5。
const POSITION_ABILITY_BIAS: Dictionary = {
	2: {"bat": -0.16, "def": 1.76},   # 捕手 (守備型)
	4: {"bat": -0.16, "def": 1.44},   # 二塁 (守備型)
	6: {"bat": -0.16, "def": 1.92},   # 遊撃 (守備型)
	8: {"bat": -0.16, "def": 1.04},   # 中堅 (守備型)
	3: {"bat": 0.16, "def": -2.56},   # 一塁 (打撃型)
	7: {"bat": 0.16, "def": -1.60},   # 左翼 (打撃型)
}


static func _apply_position_ability_bias(z: Dictionary, position: int) -> void:
	if not POSITION_ABILITY_BIAS.has(position):
		return
	var cfg: Dictionary = POSITION_ABILITY_BIAS[position] as Dictionary
	var bat_shift: float = float(cfg.get("bat", 0.0))
	var def_shift: float = float(cfg.get("def", 0.0))
	if not is_zero_approx(bat_shift):
		for key in ["Bat_KAvoid", "Bat_BBCreate", "Bat_Barrel", "Bat_Spray", "Bat_Impact", "Bat_Loft"]:
			_shift_z(z, key, bat_shift, -2.4, 3.36)
	if not is_zero_approx(def_shift):
		for key in _defense_keys_for_position(position):
			_shift_z(z, key, def_shift, -2.4, 3.36)


static func _defense_keys_for_position(position: int) -> Array:
	if position == 2:
		return ["C_Framing", "C_Blocking", "C_Throw", "C_GameCall", "C_FieldSecure"]
	if position >= 3 and position <= 6:
		return ["IF_Reach", "IF_Secure", "IF_ThrowPower", "IF_ThrowAccuracy", "IF_Exchange", "IF_PositionFit"]
	return ["OF_Reach", "OF_Route", "OF_Secure", "OF_ArmPower", "OF_ArmAccuracy", "OF_Release", "OF_PositionFit"]


static func _z_value(z: Dictionary, key: String) -> float:
	return float(z.get(key, 0.0))


static func _shift_z(z: Dictionary, key: String, delta_z: float, min_z: float, max_z: float) -> void:
	_set_z(z, key, _z_value(z, key) + delta_z, min_z, max_z)


static func _set_z(z: Dictionary, key: String, z_value: float, min_z: float, max_z: float) -> void:
	z[key] = clampf(z_value, min_z, max_z)


# 旧 Rng.range_int(lo, hi) (1-100 点) を z 換算した乱数デルタ。整数抽選の挙動は保ちつつ z で扱う。
static func _rng_delta_z(lo: int, hi: int) -> float:
	return float(Rng.range_int(lo, hi)) / PSAbilityScale.DISPLAY_STDEV


static func _player_data_from_candidate(candidate: Dictionary, player_id: int, team_id: int, round_no: int, pick: Dictionary, draft_year: int) -> Dictionary:
	var data: Dictionary = (candidate.get("player_template", {}) as Dictionary).duplicate(true)
	# 支配下/育成は segment ベースの pick["development"] で決める (旧 round>=7 判定は撤廃)。
	var is_dev: bool = bool(pick.get("development", false))
	data["id"] = player_id
	data["sensyu_num"] = player_id
	data["team_id"] = team_id
	data["salary"] = DEV_DRAFT_SALARY if is_dev else _salary_for_round(round_no)
	data["draft_round"] = round_no
	data["development_player"] = is_dev
	data["registered_roster"] = "育成" if is_dev else "支配下"
	var source: Dictionary = (data.get("source_data", {}) as Dictionary).duplicate(true)
	source["rookie_year"] = true
	source["draft_year"] = draft_year
	source["draft_round"] = round_no
	source["draft_overall_pick"] = int(pick.get("overall_pick", 0))
	source["draft_candidate_id"] = int(candidate.get("candidate_id", 0))
	source["draft_method"] = str(pick.get("method", ""))
	source["draft_lottery"] = bool(pick.get("lottery", false))
	if is_dev:
		# 育成契約の年数カウンタの起点 (PSPlayer.development_seasons_completed)。
		source["development_since_year"] = draft_year
	PSCareerLog.seed_draft_entry(source, draft_year, team_id, round_no, is_dev)
	data["source_data"] = source
	return data


static func _candidate_quality(_source_type: String, age: int) -> Dictionary:
	var roll: int = Rng.roll_percent()
	var center: int = 50
	var potential_bonus: int = 12
	if roll <= 4:
		center = Rng.range_int(58, 64)
		potential_bonus = Rng.range_int(16, 24)
	elif roll <= 15:
		center = Rng.range_int(54, 61)
		potential_bonus = Rng.range_int(12, 20)
	elif roll <= 40:
		center = Rng.range_int(50, 58)
		potential_bonus = Rng.range_int(8, 16)
	elif roll <= 78:
		center = Rng.range_int(46, 54)
		potential_bonus = Rng.range_int(5, 13)
	else:
		center = Rng.range_int(42, 51)
		potential_bonus = Rng.range_int(3, 10)

	var volatility: int = _entry_age_volatility(age)
	if volatility > 0:
		center += Rng.range_int(-volatility, volatility)
		potential_bonus += Rng.range_int(-volatility, volatility)
	center += _entry_age_maturity_bonus(age)

	return {
		"center": int(clamp(center, 35, 68)),
		"potential_bonus": int(clamp(potential_bonus, 2, 28)),
		"ability_variance": int(clamp(10 + volatility, 8, 18)),
	}


static func _entry_age_volatility(age: int) -> int:
	if age <= 18:
		return 6
	if age == 19:
		return 5
	if age == 20:
		return 4
	if age == 21:
		return 3
	if age == 22:
		return 2
	if age == 23:
		return 1
	return 0


static func _entry_age_maturity_bonus(age: int) -> int:
	if age <= 18:
		return -1 if Rng.roll_percent() <= 50 else 0
	if age == 19:
		return -1 if Rng.roll_percent() <= 75 else 0
	if age == 20:
		return -1 if Rng.roll_percent() <= 50 else 0
	if age == 21:
		return -1 if Rng.roll_percent() <= 25 else 0
	if age == 22:
		return 1 if Rng.roll_percent() <= 60 else 0
	if age == 23:
		return 1 if Rng.roll_percent() <= 60 else 0
	if age == 24:
		return 1 if Rng.roll_percent() <= 70 else 0
	if age == 25:
		return 1 if Rng.roll_percent() <= 80 else 0
	return 1


static func _candidate_source_type() -> String:
	var roll: int = Rng.roll_percent()
	if roll <= 35:
		return "high_school"
	if roll <= 70:
		return "university"
	if roll <= 87:
		return "industrial"
	return "independent"


static func _age_for_source(source_type: String) -> int:
	match source_type:
		"high_school":
			return 18
		"university":
			return Rng.range_int(21, 22)
		"industrial":
			return Rng.range_int(22, ROOKIE_MAX_AGE)
		"independent":
			return Rng.range_int(19, ROOKIE_MAX_AGE)
		_:
			return Rng.range_int(ROOKIE_MIN_AGE, 22)


# ドラフト候補の守備位置分布。投手54% / 捕手8% は従来どおり、野手は up-the-middle 偏重にする。
# 現実のドラフトはアマの主戦ポジ (遊撃/中堅/捕手) が大半で、一塁/左翼の指名は稀
# (プロ入り後にコンバートで下るのが通常方向)。旧実装の内野一様/外野一様は 1B/LF を
# 過剰供給し、リーグのポジション構成が現実 (SS/CF 厚め・コーナー薄め) と逆転していた。
static func _candidate_position() -> int:
	var roll: int = Rng.roll_percent()
	if roll <= 54:
		return 1
	if roll <= 62:
		return 2   # 捕手 8%
	if roll <= 70:
		return 6   # 遊撃 8%
	if roll <= 75:
		return 4   # 二塁 5%
	if roll <= 80:
		return 5   # 三塁 5%
	if roll <= 82:
		return 3   # 一塁 2%
	if roll <= 90:
		return 8   # 中堅 8%
	if roll <= 96:
		return 9   # 右翼 6%
	return 7       # 左翼 4%


# サブ守備適性のポジション別付与ルール (2026-06-02 の動的守備適性仕様に対応)。
# 本職適性は 70-100。サブ適性は本職適性 (primary) の一定割合で、本職を超えない。
# - 一塁: 左翼のみ取得し得る。
# - 二塁・遊撃: 捕手以外すべて取得し得る (遊撃の方がサブ適性が高め)。
# - 三塁: 捕手・遊撃・中堅は取得しない (= first/second/left/right のみ)。
# - 外野: 本職でない外野 2 ポジを必ず両方持つ (中堅は高め、本左翼/右翼の中堅サブは低め)。
#   加えて内野は一塁・三塁限定で稀に取得する (本左翼は三塁を取らない)。
static func _candidate_position_aptitudes(position: int) -> Dictionary:
	var aptitudes: Dictionary = {
		"catcher": 0, "first": 0, "second": 0, "third": 0,
		"shortstop": 0, "left": 0, "center": 0, "right": 0,
	}
	if position == 1:
		return aptitudes
	var primary_key: String = str(POSITION_NAME_BY_ID.get(position, ""))
	if primary_key.is_empty():
		return aptitudes
	var primary: int = Rng.range_int(70, 100)
	aptitudes[primary_key] = primary
	var infield: Array = ["first", "second", "third", "shortstop"]
	match position:
		2:
			pass  # 捕手は本職のみ
		3:  # 一塁: 左翼のみ取得し得る
			if Rng.roll_percent() <= 30:
				aptitudes["left"] = _sub_aptitude(primary, 0.60, 0.80)
		4:  # 二塁: 捕手以外すべて (内野70% / 外野40%)
			for key in ["first", "second", "third", "shortstop", "left", "center", "right"]:
				if key == primary_key:
					continue
				if key in infield:
					if Rng.roll_percent() <= 70:
						aptitudes[key] = _sub_aptitude(primary, 0.65, 0.90)
				elif Rng.roll_percent() <= 40:
					aptitudes[key] = _sub_aptitude(primary, 0.55, 0.75)
		6:  # 遊撃: 捕手以外すべて。サブ適性は二塁より高め (内野88% / 外野50%)
			for key in ["first", "second", "third", "shortstop", "left", "center", "right"]:
				if key == primary_key:
					continue
				if key in infield:
					if Rng.roll_percent() <= 88:
						aptitudes[key] = _sub_aptitude(primary, 0.75, 1.00)
				elif Rng.roll_percent() <= 50:
					aptitudes[key] = _sub_aptitude(primary, 0.65, 0.90)
		5:  # 三塁: 捕手・遊撃・中堅を除く
			for key in ["first", "second", "left", "right"]:
				if Rng.roll_percent() <= 35:
					aptitudes[key] = _sub_aptitude(primary, 0.65, 0.90)
		7, 8, 9:  # 外野: 他 2 外野を必ず付与 + 内野は一塁/三塁限定で稀に
			for key in ["left", "center", "right"]:
				if key == primary_key:
					continue
				var band: Array = _outfield_sub_factor(position, key)
				aptitudes[key] = _sub_aptitude(primary, float(band[0]), float(band[1]))
			if Rng.roll_percent() <= 20:
				aptitudes["first"] = _sub_aptitude(primary, 0.55, 0.75)
			if position != 7 and Rng.roll_percent() <= 15:  # 本左翼は三塁を取らない
				aptitudes["third"] = _sub_aptitude(primary, 0.55, 0.75)
	return aptitudes


# サブ適性値 = 本職適性 primary の factor 倍 (帯内ランダム)。本職を超えない。
static func _sub_aptitude(primary: int, factor_min: float, factor_max: float) -> int:
	var factor: float = factor_min + Rng.roll_float() * (factor_max - factor_min)
	return clampi(int(round(float(primary) * factor)), 1, primary)


# 外野サブ適性の本職比 [min, max]。中堅サブは高め、本左翼/右翼の中堅サブは低め (左翼が特に低い)。
static func _outfield_sub_factor(primary_position: int, key: String) -> Array:
	if primary_position == 8:  # 本中堅: 両翼サブが高い
		return [0.85, 1.00]
	if key == "center":
		if primary_position == 7:  # 本左翼の中堅は特に低い
			return [0.45, 0.65]
		return [0.55, 0.75]  # 本右翼の中堅は低め
	return [0.75, 0.95]  # 本左翼⇔右翼 (両翼間) は高め


# 育成ドラフト指名の初期年俸 (支配下の本指名より低い。NPB 育成契約相当)。
const DEV_DRAFT_SALARY: int = Offseason.DEVELOPMENT_CONTRACT_SALARY


static func _salary_for_round(round_no: int) -> int:
	match round_no:
		1:
			return 1500
		2:
			return 1200
		3:
			return 1000
		4:
			return 850
		5:
			return 700
		6:
			return 600
		_:
			return 500


static func _position_group(position: int) -> String:
	if position == 1:
		return "pitcher"
	if position == 2:
		return "catcher"
	if position >= 3 and position <= 6:
		return "infield"
	return "outfield"


static func _draft_bucket_for_position(position: int) -> String:
	return "pitcher" if position == 1 else "fielder"


static func _candidate_group(candidate: Dictionary) -> String:
	return _position_group(int(candidate.get("position", 0)))


static func _candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if int(candidate.get("candidate_id", 0)) == candidate_id:
			return candidate
	return {}


static func _is_candidate_available(state: Dictionary, candidate_id: int) -> bool:
	var candidate: Dictionary = _candidate_by_id(state, candidate_id)
	return not candidate.is_empty() and not bool(candidate.get("picked", false))


static func _order_index(order: Array, team_id: int) -> int:
	for i in range(order.size()):
		if int(order[i]) == team_id:
			return i
	return 999
