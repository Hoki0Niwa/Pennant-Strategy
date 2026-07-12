extends RefCounted
class_name TradeService

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

# シーズン中トレード v1 (R4 Step4)。「余剰と不足の交換」を最小構成で成立させる。
# - 交換期限 (7/31) までの試合日に、週次で CPU 間トレードと CPU→自軍提案を低頻度判定する。
# - ユーザーはトレード画面から提案を作成でき、CPU は同じ評価軸 (future_value + 需要) で受諾判定する。
# - 対象は支配下の健康な日本人非新人のみ (外国人 / 育成 / 怪我人 / FA宣言中 / 入団初年は対象外)。
# - 成立時は player.team_id / 当季 record.team_id / 両軍一軍ロスター / FA日数台帳を更新する。
# 状態は season.trade_state に集約 (成立ログ / 自軍宛て提案 / 週次チェック日 / 球団別成立数)。

# 交換期限 (NPB は 7/31)。カレンダー日付で判定し、日付が引けない場合は day ベースで代用する。
const TRADE_DEADLINE_MONTH: int = 7
const TRADE_DEADLINE_DAY: int = 31
const TRADE_WINDOW_FALLBACK_LAST_DAY: int = 130

# 週次チェックの間隔と発生率。CPU間は期限までの約17回チェック × 0.22 ≈ リーグ年3〜4件、
# 自軍宛て提案は × 0.10 ≈ 年1〜2件を狙う (実NPBのシーズン中トレードは年数件〜10件程度)。
const CHECK_INTERVAL_DAYS: int = 7
const CPU_TRADE_CHANCE_PER_CHECK: float = 0.22
const USER_OFFER_CHANCE_PER_CHECK: float = 0.10

const OFFER_EXPIRY_DAYS: int = 14
const MAX_PENDING_USER_OFFERS: int = 2
# 球団ごとの年間成立上限。CPU が同じ余剰を毎週吐き出して回転寿司にならないための蓋。
const MAX_TRADES_PER_TEAM: int = 2

# 1:1 マッチングの成立条件。future_value 差がこの範囲内で、双方の需要フィットが最低値以上。
const VALUE_DIFF_TOLERANCE: float = 6.0
const MIN_NEED_FIT: float = 2.0
# ペアスコア = 双方の需要フィット合計 − 価値差ペナルティ。
const VALUE_DIFF_SCORE_PENALTY: float = 0.4

# ユーザー提案の CPU 受諾判定: (受取価値+需要ボーナス) − (放出価値+放出側需要ペナルティ) が
# この値以上なら受諾。0 だと等価交換を全部飲むので、わずかに CPU 有利を要求する。
const CPU_ACCEPT_MIN_GAIN: float = 1.5
const NEED_FIT_VALUE_WEIGHT: float = 0.35
# 提案の人数制約 (v1 は 1〜2人 対 1〜2人)。
const MAX_PLAYERS_PER_SIDE: int = 2

# 余剰判定: 本職で上位2人 (捕手は3人) / 先発7番手以降 / 救援9番手以降を出せる駒とみなす。
const SURPLUS_KEEP_FIELDERS: int = 2
const SURPLUS_KEEP_CATCHERS: int = 3
const SURPLUS_KEEP_STARTERS: int = 6
const SURPLUS_KEEP_RELIEVERS: int = 8

const SLOT_STARTER: String = "starter"
const SLOT_RELIEVER: String = "reliever"


# ---- 週次エントリ (game_simulator の日次フックから呼ばれる) -------------------

# 戻り値 { "executed": Array, "user_offers_added": int }。トレードが成立した場合、
# 呼び出し側で GameDb.rebuild_player_indices() を行うこと (players の team_id が動く)。
static func run_periodic_trade_check(season: PSSeason, players: Array, teams: Array, day: int, user_team_id: int) -> Dictionary:
	var result: Dictionary = {"executed": [], "user_offers_added": 0}
	if season == null or players.is_empty() or teams.is_empty():
		return result
	var state: Dictionary = trade_state(season)
	prune_expired_offers(season, day)
	var last_check: int = int(state.get("last_check_day", 0))
	if last_check > 0 and day - last_check < CHECK_INTERVAL_DAYS:
		return result
	state["last_check_day"] = day
	if not is_trade_window_open(season):
		return result

	if Rng.roll_float() <= CPU_TRADE_CHANCE_PER_CHECK:
		var pair: Dictionary = _best_cpu_trade_pair(season, players, teams, user_team_id)
		if not pair.is_empty():
			var team_a_id: int = int(pair.get("team_a", 0))
			var team_b_id: int = int(pair.get("team_b", 0))
			var a_ids: Array = [int(pair.get("player_a", 0))]
			var b_ids: Array = [int(pair.get("player_b", 0))]
			# 1:1 固定なので枠は常に釣り合うが、予算は _best_pair_between が考慮していないため
			# ここで再検証する (超過側が絡む組み合わせはスキップ)。
			var validation: Dictionary = _validate_trade_sides(players, teams, team_a_id, a_ids, team_b_id, b_ids)
			if bool(validation.get("ok", false)):
				var entry: Dictionary = execute_trade(season, players, team_a_id, a_ids, team_b_id, b_ids, "cpu")
				if not entry.is_empty():
					(result["executed"] as Array).append(entry)

	if user_team_id > 0 and Rng.roll_float() <= USER_OFFER_CHANCE_PER_CHECK:
		if pending_user_offers(season).size() < MAX_PENDING_USER_OFFERS:
			var offer: Dictionary = _generate_user_offer(season, players, teams, user_team_id, day)
			if not offer.is_empty():
				result["user_offers_added"] = 1
	return result


# ---- 期限・状態 ---------------------------------------------------------------

static func is_trade_window_open(season: PSSeason) -> bool:
	if season == null:
		return false
	if str(season.calendar_start_date).is_empty():
		return season.current_day <= TRADE_WINDOW_FALLBACK_LAST_DAY
	var date_text: String = SeasonCalendar.date_for_day(season.calendar_start_date, season.current_day)
	if date_text.is_empty():
		return season.current_day <= TRADE_WINDOW_FALLBACK_LAST_DAY
	var deadline: String = "%04d-%02d-%02d" % [season.year, TRADE_DEADLINE_MONTH, TRADE_DEADLINE_DAY]
	return date_text <= deadline


# season.trade_state を既定スキーマ込みで返す (参照を返すので変更はそのまま永続する)。
static func trade_state(season: PSSeason) -> Dictionary:
	var state: Dictionary = season.trade_state
	if not state.has("executed"):
		state["executed"] = []
	if not state.has("user_offers"):
		state["user_offers"] = []
	if not state.has("trades_by_team"):
		state["trades_by_team"] = {}
	if not state.has("next_offer_id"):
		state["next_offer_id"] = 1
	season.trade_state = state
	return state


static func executed_trades(season: PSSeason) -> Array:
	return trade_state(season).get("executed", []) as Array


static func pending_user_offers(season: PSSeason) -> Array:
	var pending: Array = []
	for offer_value in trade_state(season).get("user_offers", []) as Array:
		var offer: Dictionary = offer_value as Dictionary
		if str(offer.get("status", "pending")) == "pending":
			pending.append(offer)
	return pending


static func trades_count_for_team(season: PSSeason, team_id: int) -> int:
	return int((trade_state(season).get("trades_by_team", {}) as Dictionary).get(str(team_id), 0))


static func prune_expired_offers(season: PSSeason, day: int) -> void:
	var state: Dictionary = trade_state(season)
	for offer_value in state.get("user_offers", []) as Array:
		var offer: Dictionary = offer_value as Dictionary
		if str(offer.get("status", "pending")) != "pending":
			continue
		if day > int(offer.get("expires_day", 0)):
			offer["status"] = "expired"


# ---- 対象判定・評価 -----------------------------------------------------------

static func is_tradeable(player: PSPlayer) -> bool:
	if player == null or player.team_id <= 0 or player.is_retired():
		return false
	if player.foreign_player or player.development_player:
		return false
	if player.injury_days > 0:
		return false
	if bool(player.source_data.get("free_agent", false)):
		return false
	# NPB 同様、入団初年 (ドラフト当年) はトレード対象外。
	if bool(player.source_data.get("rookie_year", false)) and player.years <= 1:
		return false
	return true


static func trade_value(player: PSPlayer) -> float:
	return OffseasonService.future_value_score(player)


# 受け手球団にとっての需要フィット (need マップの該当スロット値)。
static func need_fit(player: PSPlayer, team_need: Dictionary) -> float:
	if player == null:
		return 0.0
	if player.is_pitcher():
		var slot: String = SLOT_STARTER if player.is_starter_pitcher() else SLOT_RELIEVER
		return float(team_need.get(slot, 0.0))
	return float(team_need.get(player.position, 0.0))


# 需要マップ: { team_id: { 2..9: gap, "starter": gap, "reliever": gap } }。
# 野手はポジション最高値のリーグ平均比 (FA市場と同じ発想)、投手は役割別デプス
# (先発上位6 / 救援上位8 の平均値) のリーグ平均比。gap が大きいほど補強が必要。
static func build_team_needs(players: Array, teams: Array) -> Dictionary:
	var best_by_team: Dictionary = {}
	var starter_values: Dictionary = {}
	var reliever_values: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		best_by_team[team.id] = {}
		starter_values[team.id] = []
		reliever_values[team.id] = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0 or player.is_retired() or player.development_player:
			continue
		if not best_by_team.has(player.team_id):
			continue
		var value: int = OffseasonService.player_value_score(player)
		if player.is_pitcher():
			if player.is_starter_pitcher():
				(starter_values[player.team_id] as Array).append(value)
			else:
				(reliever_values[player.team_id] as Array).append(value)
			continue
		var pos_map: Dictionary = best_by_team[player.team_id] as Dictionary
		if value > int(pos_map.get(player.position, 0)):
			pos_map[player.position] = value

	var depth_by_team: Dictionary = {}
	for team_id in best_by_team.keys():
		depth_by_team[team_id] = {
			SLOT_STARTER: _top_average(starter_values[team_id] as Array, SURPLUS_KEEP_STARTERS),
			SLOT_RELIEVER: _top_average(reliever_values[team_id] as Array, SURPLUS_KEEP_RELIEVERS),
		}

	var need: Dictionary = {}
	var team_count: int = maxi(1, best_by_team.size())
	for team_id in best_by_team.keys():
		need[team_id] = {}
	for pos in range(2, 10):
		var total: float = 0.0
		for team_id in best_by_team.keys():
			total += float((best_by_team[team_id] as Dictionary).get(pos, 0))
		var league_avg: float = total / float(team_count)
		for team_id in best_by_team.keys():
			(need[team_id] as Dictionary)[pos] = max(0.0, league_avg - float((best_by_team[team_id] as Dictionary).get(pos, 0)))
	for slot in [SLOT_STARTER, SLOT_RELIEVER]:
		var total: float = 0.0
		for team_id in depth_by_team.keys():
			total += float((depth_by_team[team_id] as Dictionary).get(slot, 0.0))
		var league_avg: float = total / float(team_count)
		for team_id in depth_by_team.keys():
			(need[team_id] as Dictionary)[slot] = max(0.0, league_avg - float((depth_by_team[team_id] as Dictionary).get(slot, 0.0)))
	return need


# 出せる駒 (余剰) の一覧。本職の上位 SURPLUS_KEEP_* 人は残す。
static func build_surplus_candidates(players: Array, team_id: int) -> Array:
	var fielders_by_pos: Dictionary = {}
	var starters: Array = []
	var relievers: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired() or player.development_player:
			continue
		if player.is_pitcher():
			if player.is_starter_pitcher():
				starters.append(player)
			else:
				relievers.append(player)
			continue
		var pos_list: Array = fielders_by_pos.get(player.position, []) as Array
		pos_list.append(player)
		fielders_by_pos[player.position] = pos_list

	var surplus: Array = []
	for pos in fielders_by_pos.keys():
		var pos_list: Array = fielders_by_pos[pos] as Array
		pos_list.sort_custom(_by_value_desc)
		var keep: int = SURPLUS_KEEP_CATCHERS if int(pos) == 2 else SURPLUS_KEEP_FIELDERS
		for i in range(keep, pos_list.size()):
			if is_tradeable(pos_list[i] as PSPlayer):
				surplus.append(pos_list[i])
	starters.sort_custom(_by_value_desc)
	for i in range(SURPLUS_KEEP_STARTERS, starters.size()):
		if is_tradeable(starters[i] as PSPlayer):
			surplus.append(starters[i])
	relievers.sort_custom(_by_value_desc)
	for i in range(SURPLUS_KEEP_RELIEVERS, relievers.size()):
		if is_tradeable(relievers[i] as PSPlayer):
			surplus.append(relievers[i])
	return surplus


# ---- CPU 間マッチング -----------------------------------------------------------

# 全 CPU 球団ペアから最良の 1:1 交換を探す。見つからなければ {}。
static func _best_cpu_trade_pair(season: PSSeason, players: Array, teams: Array, user_team_id: int) -> Dictionary:
	var need: Dictionary = build_team_needs(players, teams)
	var surplus_by_team: Dictionary = {}
	var team_ids: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == user_team_id:
			continue
		if trades_count_for_team(season, team.id) >= MAX_TRADES_PER_TEAM:
			continue
		team_ids.append(team.id)
		surplus_by_team[team.id] = build_surplus_candidates(players, team.id)

	var best: Dictionary = {}
	var best_score: float = 0.0
	for i in range(team_ids.size()):
		for j in range(i + 1, team_ids.size()):
			var team_a: int = int(team_ids[i])
			var team_b: int = int(team_ids[j])
			var candidate: Dictionary = _best_pair_between(
				surplus_by_team[team_a] as Array, surplus_by_team[team_b] as Array,
				need.get(team_a, {}) as Dictionary, need.get(team_b, {}) as Dictionary
			)
			if candidate.is_empty():
				continue
			if float(candidate.get("score", 0.0)) > best_score:
				best_score = float(candidate.get("score", 0.0))
				best = {
					"team_a": team_a,
					"team_b": team_b,
					"player_a": (candidate.get("player_a", null) as PSPlayer).id,
					"player_b": (candidate.get("player_b", null) as PSPlayer).id,
					"score": best_score,
				}
	return best


# A の余剰×B の余剰から、双方の需要フィットが最低値以上かつ価値差が許容内の最良ペア。
static func _best_pair_between(surplus_a: Array, surplus_b: Array, need_a: Dictionary, need_b: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = 0.0
	for a_row in surplus_a:
		var player_a: PSPlayer = a_row as PSPlayer
		var fit_for_b: float = need_fit(player_a, need_b)
		if fit_for_b < MIN_NEED_FIT:
			continue
		var value_a: float = trade_value(player_a)
		for b_row in surplus_b:
			var player_b: PSPlayer = b_row as PSPlayer
			var fit_for_a: float = need_fit(player_b, need_a)
			if fit_for_a < MIN_NEED_FIT:
				continue
			var value_diff: float = absf(value_a - trade_value(player_b))
			if value_diff > VALUE_DIFF_TOLERANCE:
				continue
			var score: float = fit_for_a + fit_for_b - value_diff * VALUE_DIFF_SCORE_PENALTY
			if score > best_score:
				best_score = score
				best = {"player_a": player_a, "player_b": player_b, "score": score}
	return best


# ---- CPU→自軍 提案 -------------------------------------------------------------

# CPU 球団が自軍の余剰を欲しがり、自軍の需要に合う駒を差し出す 1:1 提案を生成して保存する。
static func _generate_user_offer(season: PSSeason, players: Array, teams: Array, user_team_id: int, day: int) -> Dictionary:
	var need: Dictionary = build_team_needs(players, teams)
	var user_surplus: Array = build_surplus_candidates(players, user_team_id)
	if user_surplus.is_empty():
		return {}
	var user_need: Dictionary = need.get(user_team_id, {}) as Dictionary

	var best: Dictionary = {}
	var best_score: float = 0.0
	var best_cpu_team: int = 0
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == user_team_id:
			continue
		if trades_count_for_team(season, team.id) >= MAX_TRADES_PER_TEAM:
			continue
		var candidate: Dictionary = _best_pair_between(
			build_surplus_candidates(players, team.id), user_surplus,
			need.get(team.id, {}) as Dictionary, user_need
		)
		if candidate.is_empty():
			continue
		if float(candidate.get("score", 0.0)) > best_score:
			best_score = float(candidate.get("score", 0.0))
			best = candidate
			best_cpu_team = team.id
	if best.is_empty():
		return {}

	var cpu_player: PSPlayer = best.get("player_a", null) as PSPlayer
	var user_player: PSPlayer = best.get("player_b", null) as PSPlayer
	var state: Dictionary = trade_state(season)
	var offer_id: int = int(state.get("next_offer_id", 1))
	state["next_offer_id"] = offer_id + 1
	var offer: Dictionary = {
		"id": offer_id,
		"status": "pending",
		"day": day,
		"expires_day": day + OFFER_EXPIRY_DAYS,
		"cpu_team_id": best_cpu_team,
		"cpu_player_ids": [cpu_player.id],
		"user_player_ids": [user_player.id],
		"cpu_player_names": [cpu_player.name],
		"user_player_names": [user_player.name],
	}
	(state["user_offers"] as Array).append(offer)
	return offer


static func accept_user_offer(season: PSSeason, players: Array, teams: Array, offer_id: int, user_team_id: int) -> Dictionary:
	var offer: Dictionary = _pending_offer_by_id(season, offer_id)
	if offer.is_empty():
		return {"ok": false, "message": "その提案は有効ではありません。"}
	if not is_trade_window_open(season):
		offer["status"] = "expired"
		return {"ok": false, "message": "交換期限を過ぎています。"}
	var cpu_team_id: int = int(offer.get("cpu_team_id", 0))
	# 提案生成時点では CPU 側の上限しか見ていない (自軍側は _generate_user_offer が未チェック)。
	# 生成後に他のトレードで両球団の成立数が変わりうるため、受諾時にも改めて双方を確認する。
	if trades_count_for_team(season, cpu_team_id) >= MAX_TRADES_PER_TEAM or trades_count_for_team(season, user_team_id) >= MAX_TRADES_PER_TEAM:
		offer["status"] = "invalid"
		return {"ok": false, "message": "今季のトレード成立上限に達しているため受諾できません。"}
	var validation: Dictionary = _validate_trade_sides(
		players, teams, cpu_team_id, offer.get("cpu_player_ids", []) as Array,
		user_team_id, offer.get("user_player_ids", []) as Array
	)
	if not bool(validation.get("ok", false)):
		offer["status"] = "invalid"
		return {"ok": false, "message": str(validation.get("message", "提案が成立条件を満たしません。"))}
	var entry: Dictionary = execute_trade(
		season, players,
		cpu_team_id, offer.get("cpu_player_ids", []) as Array,
		user_team_id, offer.get("user_player_ids", []) as Array,
		"user_offer"
	)
	if entry.is_empty():
		return {"ok": false, "message": "トレードを実行できませんでした。"}
	offer["status"] = "accepted"
	return {"ok": true, "trade": entry}


static func decline_user_offer(season: PSSeason, offer_id: int) -> Dictionary:
	var offer: Dictionary = _pending_offer_by_id(season, offer_id)
	if offer.is_empty():
		return {"ok": false, "message": "その提案は有効ではありません。"}
	offer["status"] = "declined"
	return {"ok": true}


static func _pending_offer_by_id(season: PSSeason, offer_id: int) -> Dictionary:
	for offer_value in trade_state(season).get("user_offers", []) as Array:
		var offer: Dictionary = offer_value as Dictionary
		if int(offer.get("id", 0)) == offer_id and str(offer.get("status", "pending")) == "pending":
			return offer
	return {}


# ---- ユーザー提案 ---------------------------------------------------------------

# 自軍 give_ids ↔ 相手球団 receive_ids の提案を CPU 視点で評価する (実行はしない)。
# 戻り値 { ok, accepted, cpu_gain, message }。
static func evaluate_user_proposal(season: PSSeason, players: Array, teams: Array, user_team_id: int, give_ids: Array, receive_ids: Array) -> Dictionary:
	if not is_trade_window_open(season):
		return {"ok": false, "accepted": false, "message": "交換期限を過ぎています。"}
	if give_ids.is_empty() or receive_ids.is_empty() \
			or give_ids.size() > MAX_PLAYERS_PER_SIDE or receive_ids.size() > MAX_PLAYERS_PER_SIDE:
		return {"ok": false, "accepted": false, "message": "トレードは各球団1〜%d人で提案してください。" % MAX_PLAYERS_PER_SIDE}
	var cpu_team_id: int = _owner_team_of(players, receive_ids)
	if cpu_team_id <= 0 or cpu_team_id == user_team_id:
		return {"ok": false, "accepted": false, "message": "相手選手は同一の他球団に所属している必要があります。"}
	var validation: Dictionary = _validate_trade_sides(players, teams, user_team_id, give_ids, cpu_team_id, receive_ids)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "accepted": false, "message": str(validation.get("message", ""))}
	# 自軍も CPU 間トレードと同じ球団別年間上限 (MAX_TRADES_PER_TEAM) の対象とする。
	# 従来は cpu_team_id 側しか見ておらず、自軍だけこの上限を回避できてしまっていた。
	if trades_count_for_team(season, cpu_team_id) >= MAX_TRADES_PER_TEAM:
		return {"ok": true, "accepted": false, "cpu_gain": 0.0, "message": "相手球団は今季のトレードに消極的です。"}
	if trades_count_for_team(season, user_team_id) >= MAX_TRADES_PER_TEAM:
		return {"ok": true, "accepted": false, "cpu_gain": 0.0, "message": "自球団は今季のトレード成立上限に達しています。"}

	var need: Dictionary = build_team_needs(players, teams)
	var cpu_need: Dictionary = need.get(cpu_team_id, {}) as Dictionary
	var cpu_gain: float = 0.0
	for id_value in give_ids:
		var incoming: PSPlayer = _find_player_by_id(players, int(id_value))
		cpu_gain += trade_value(incoming) + need_fit(incoming, cpu_need) * NEED_FIT_VALUE_WEIGHT
	for id_value in receive_ids:
		var outgoing: PSPlayer = _find_player_by_id(players, int(id_value))
		cpu_gain -= trade_value(outgoing) + need_fit(outgoing, cpu_need) * NEED_FIT_VALUE_WEIGHT
	var accepted: bool = cpu_gain >= CPU_ACCEPT_MIN_GAIN
	return {
		"ok": true,
		"accepted": accepted,
		"cpu_gain": cpu_gain,
		"cpu_team_id": cpu_team_id,
		"message": "" if accepted else "交渉はまとまりませんでした (相手の評価が見合いません)。",
	}


# 提案を評価し、受諾なら実行までまとめて行う。
static func submit_user_proposal(season: PSSeason, players: Array, teams: Array, user_team_id: int, give_ids: Array, receive_ids: Array) -> Dictionary:
	var evaluated: Dictionary = evaluate_user_proposal(season, players, teams, user_team_id, give_ids, receive_ids)
	if not bool(evaluated.get("ok", false)) or not bool(evaluated.get("accepted", false)):
		return evaluated
	var entry: Dictionary = execute_trade(
		season, players,
		user_team_id, give_ids,
		int(evaluated.get("cpu_team_id", 0)), receive_ids,
		"user_proposal"
	)
	if entry.is_empty():
		return {"ok": false, "accepted": false, "message": "トレードを実行できませんでした。"}
	evaluated["trade"] = entry
	return evaluated


# ---- 成立処理 -------------------------------------------------------------------

# 双方の選手を入れ替える。呼び出し前に対象妥当性を検証しておくこと
# (run_periodic_trade_check / accept_user_offer / submit_user_proposal 経由なら検証済み)。
static func execute_trade(season: PSSeason, players: Array, team_a_id: int, a_out_ids: Array, team_b_id: int, b_out_ids: Array, source: String) -> Dictionary:
	if season == null or team_a_id <= 0 or team_b_id <= 0 or team_a_id == team_b_id:
		return {}
	var a_players: Array = _players_for_ids(players, a_out_ids)
	var b_players: Array = _players_for_ids(players, b_out_ids)
	if a_players.size() != a_out_ids.size() or b_players.size() != b_out_ids.size():
		return {}

	_move_players(season, a_players, team_a_id, team_b_id)
	_move_players(season, b_players, team_b_id, team_a_id)
	_swap_active_roster_members(season, team_a_id, a_out_ids, b_players)
	_swap_active_roster_members(season, team_b_id, b_out_ids, a_players)

	var state: Dictionary = trade_state(season)
	var trades_by_team: Dictionary = state.get("trades_by_team", {}) as Dictionary
	trades_by_team[str(team_a_id)] = int(trades_by_team.get(str(team_a_id), 0)) + 1
	trades_by_team[str(team_b_id)] = int(trades_by_team.get(str(team_b_id), 0)) + 1
	var entry: Dictionary = {
		"day": season.current_day,
		"year": season.year,
		"source": source,
		"team_a": team_a_id,
		"team_b": team_b_id,
		"a_player_ids": a_out_ids.duplicate(),
		"b_player_ids": b_out_ids.duplicate(),
		"a_player_names": _names_of(a_players),
		"b_player_names": _names_of(b_players),
	}
	(state["executed"] as Array).append(entry)
	return entry


static func _move_players(season: PSSeason, moving: Array, from_team_id: int, to_team_id: int) -> void:
	for player_row in moving:
		var player: PSPlayer = player_row as PSPlayer
		season.transfer_active_roster_days(from_team_id, to_team_id, player.id)
		player.team_id = to_team_id
		player.source_data["traded_year"] = season.year
		player.source_data["traded_from_team"] = from_team_id
		PSCareerLog.log_trade(player, season.year, from_team_id, to_team_id)
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			record.team_id = to_team_id


# 一軍ロスターの出場枠を入れ替える: 出て行った選手を外し、空いた枠に来た選手を
# 価値順で詰める (枠上限 TeamAutoAI.TARGET_TOTAL 厳守)。二軍同士の交換ならロスターは動かない。
static func _swap_active_roster_members(season: PSSeason, team_id: int, out_ids: Array, incoming_players: Array) -> void:
	var roster: Dictionary = season.get_active_roster(team_id)
	if roster.is_empty():
		return
	var new_roster: Dictionary = roster.duplicate(true)
	var ids: Array = []
	for id_value in new_roster.get("player_ids", []) as Array:
		if not out_ids.has(int(id_value)) and not out_ids.has(id_value):
			ids.append(int(id_value))
	var sorted_incoming: Array = incoming_players.duplicate()
	sorted_incoming.sort_custom(_by_value_desc)
	for player_row in sorted_incoming:
		var player: PSPlayer = player_row as PSPlayer
		if ids.size() >= TeamAutoAI.TARGET_TOTAL:
			break
		if not ids.has(player.id):
			ids.append(player.id)
	new_roster["player_ids"] = ids
	season.set_active_roster(team_id, new_roster)


# ---- 内部ヘルパ -----------------------------------------------------------------

# 両サイドの選手が指定球団に所属し、全員トレード可能かを確認する。
# 人数不均等な提案 (例: 2対1) で受け側の支配下が70枠を超えないことも合わせて検証する
# (1:1 固定の CPU間マッチングは常に人数が釣り合うため対象外だが、ユーザー提案は
# MAX_PLAYERS_PER_SIDE まで非対称にできるため、ここでチェックしないと70枠を超過しうる)。
# teams は年俸総額が増える側の予算ゲート (trade_payroll_ok) に使う。
static func _validate_trade_sides(players: Array, teams: Array, team_a_id: int, a_ids: Array, team_b_id: int, b_ids: Array) -> Dictionary:
	for pair in [[team_a_id, a_ids], [team_b_id, b_ids]]:
		var team_id: int = int((pair as Array)[0])
		for id_value in (pair as Array)[1] as Array:
			var player: PSPlayer = _find_player_by_id(players, int(id_value))
			if player == null or player.team_id != team_id:
				return {"ok": false, "message": "対象選手が既に移籍または退団しています。"}
			if not is_tradeable(player):
				return {"ok": false, "message": "%s はトレード対象にできません (外国人/育成/怪我/新人)。" % player.name}
	if not _capacity_ok_after_trade(players, team_a_id, a_ids, b_ids):
		return {"ok": false, "message": "自軍の支配下枠(70人)を超えるためこのトレードは成立できません。"}
	if not _capacity_ok_after_trade(players, team_b_id, b_ids, a_ids):
		return {"ok": false, "message": "相手球団の支配下枠(70人)を超えるためこのトレードは成立できません。"}
	var salary_a_out: int = _salary_total(players, a_ids)
	var salary_b_out: int = _salary_total(players, b_ids)
	var team_a: PSTeam = _find_team_by_id(teams, team_a_id)
	var team_b: PSTeam = _find_team_by_id(teams, team_b_id)
	if not TeamFinance.trade_payroll_ok(players, team_a, salary_a_out, salary_b_out):
		return {"ok": false, "message": "自軍の年俸総額が予算を超えるためこのトレードは成立できません。"}
	if not TeamFinance.trade_payroll_ok(players, team_b, salary_b_out, salary_a_out):
		return {"ok": false, "message": "相手球団の予算を超えるためこのトレードは成立できません。"}
	return {"ok": true}


# team_id が out_ids を放出し in_ids を受け取った後の支配下人数が70枠に収まるか。
# トレード対象は is_tradeable (育成除外) 済みなので、入出とも支配下枠を1人ずつ増減させる。
static func _capacity_ok_after_trade(players: Array, team_id: int, out_ids: Array, in_ids: Array) -> bool:
	var projected: int = TeamFinance.shienka_count(players, team_id) - out_ids.size() + in_ids.size()
	return projected <= TeamFinance.SHIENKA_LIMIT


static func _salary_total(players: Array, ids: Array) -> int:
	var total: int = 0
	for id_value in ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		if player != null:
			total += player.salary
	return total


static func _owner_team_of(players: Array, ids: Array) -> int:
	var owner: int = 0
	for id_value in ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		if player == null:
			return 0
		if owner == 0:
			owner = player.team_id
		elif owner != player.team_id:
			return 0
	return owner


static func _players_for_ids(players: Array, ids: Array) -> Array:
	var out: Array = []
	for id_value in ids:
		var player: PSPlayer = _find_player_by_id(players, int(id_value))
		if player != null:
			out.append(player)
	return out


static func _find_player_by_id(players: Array, player_id: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.id == player_id:
			return player
	return null


static func _find_team_by_id(teams: Array, team_id: int) -> PSTeam:
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.id == team_id:
			return team
	return null


static func _names_of(moving: Array) -> Array:
	var names: Array = []
	for player_row in moving:
		names.append((player_row as PSPlayer).name)
	return names


static func _by_value_desc(a, b) -> bool:
	return OffseasonService.player_value_score(a as PSPlayer) > OffseasonService.player_value_score(b as PSPlayer)


static func _top_average(values: Array, count: int) -> float:
	if values.is_empty() or count <= 0:
		return 0.0
	var sorted_values: Array = values.duplicate()
	sorted_values.sort()
	sorted_values.reverse()
	var take: int = mini(count, sorted_values.size())
	var total: float = 0.0
	for i in range(take):
		total += float(sorted_values[i])
	# 頭数が規定に満たない場合は不足分を 0 扱いで平均する (デプス不足自体を需要として表す)。
	return total / float(count)
