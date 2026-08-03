extends RefCounted
class_name TeamDepthChart

# 球団の戦力と弱点を「年齢・ポジション・能力」で1枚に表したデプスチャート。
# 戦力外 / ドラフト / FA / 外国人 / 戦力外獲得 / 現役ドラフト / トレードの補強AIが**共有する単一ソース**
# (2026-08-03 新設。従来は position_need / _build_team_position_need / build_team_needs /
#  release_depth_chart_evaluations と、同じ「需要」の実装が4箇所に散っていた)。
#
# ## スロット
# 役割スロット = 先発 / 救援 / 守備位置2〜9。`slot_key_for(player)` が単一ソース。
# スロットごとに「一軍で実際に使う枠数 (FIRST_TEAM_SLOTS)」と「支配下で抱える快適人数 (COMFORT)」の
# 2段を持つ。前者は**即戦力かどうかの当落線**、後者は**余剰かどうか**の判定に使う。
#
# ## 指標 (スロットごと)
# - `first_team_line`: 一軍枠の最後の選手の value = **これを上回れば即戦力**。空きスロットは
#   リーグ水準 (league_first_team_avg) を代用し、「人が居ないから誰でも即戦力」を防ぐ。
# - `depth_value`: 快適人数ぶんの上位平均 = そのスロットの総合的な厚み。リーグ平均との差が `need`。
# - `holder_count` / `avg_age` / `aging_count`: 人数と年齢構成。将来の空き (future_opening) を測る。
#
# ## 候補の評価
# `evaluate_candidate` が「そのスロットに入れたとき即戦力か / 将来に賭ける価値があるか」を返す。
# **どちらでもない選手は獲らない**、という厳しい基準を各補強AIが共有する。

const PROSPECT_MAX_AGE: int = 24
const AGING_AGE: int = 32

const SLOT_STARTER: String = "starter"
const SLOT_RELIEVER: String = "reliever"

# 一軍で実際に使う枠数。即戦力の当落線 (first_team_line) をこの順位の選手で引く。
# 先発5 = ローテの中心、救援6 = ブルペンの主力、野手1 = そのポジションのレギュラー。
# **ここを深くすると「即戦力」の基準が緩くなる** — 8番手救援まで見ると二軍相当の選手が
# 当落線になり、戦力外市場の獲得が上限に張り付いた (実測 先発6/救援8 で 1.53人/球団)。
const FIRST_TEAM_SLOTS: Dictionary = {SLOT_STARTER: 5, SLOT_RELIEVER: 6}
const FIRST_TEAM_SLOTS_FIELDER: int = 1

# 支配下で抱える快適人数 (余剰判定用)。OffseasonService の戦力外スロット予算と同じ水準。
const COMFORT: Dictionary = {SLOT_STARTER: 13, SLOT_RELIEVER: 19}
const COMFORT_FIELDER: Dictionary = {2: 5, 3: 3, 4: 4, 5: 4, 6: 4, 7: 3, 8: 3, 9: 3}


# 選手が属する役割スロット。投手は先発/救援、野手は守備位置。
static func slot_key_for(player: PSPlayer) -> String:
	if player == null:
		return ""
	if player.is_pitcher():
		return SLOT_STARTER if player.is_starter_pitcher() else SLOT_RELIEVER
	return "fielder:%d" % player.position


static func fielder_slot_key(position: int) -> String:
	return "fielder:%d" % position


static func all_slot_keys() -> Array:
	var keys: Array = [SLOT_STARTER, SLOT_RELIEVER]
	for position in range(2, 10):
		keys.append(fielder_slot_key(position))
	return keys


static func first_team_slots_for(slot_key: String) -> int:
	return int(FIRST_TEAM_SLOTS.get(slot_key, FIRST_TEAM_SLOTS_FIELDER))


static func comfort_for(slot_key: String) -> int:
	if COMFORT.has(slot_key):
		return int(COMFORT[slot_key])
	var position: int = int(slot_key.get_slice(":", 1)) if slot_key.begins_with("fielder:") else 0
	return int(COMFORT_FIELDER.get(position, 3))


# リーグ全球団のデプスチャートを1度に構築する ({team_id: chart})。
# need はリーグ平均との差で決まるため、**必ずリーグ単位で作る** (1球団だけでは need が出せない)。
# 支配下のみを数える (育成は別枠。[[project_development_player_system]])。
static func build_league(players: Array, teams: Array) -> Dictionary:
	var charts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		charts[team.id] = _build_team_slots(players, team.id)
	_apply_league_baselines(charts)
	return charts


# 単一球団ぶんのチャート。need をリーグ相対で出すため teams も要る。
static func build_for_team(players: Array, teams: Array, team_id: int) -> Dictionary:
	var charts: Dictionary = build_league(players, teams)
	return charts.get(team_id, {}) as Dictionary


static func _build_team_slots(players: Array, team_id: int) -> Dictionary:
	var holders_by_slot: Dictionary = {}
	for slot_key in all_slot_keys():
		holders_by_slot[slot_key] = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired() or player.development_player:
			continue
		var slot_key: String = slot_key_for(player)
		if not holders_by_slot.has(slot_key):
			continue
		(holders_by_slot[slot_key] as Array).append({
			"player_id": player.id,
			"value": float(OffseasonService.player_value_score(player)),
			"age": player.age,
		})

	var slots: Dictionary = {}
	for slot_key_value in holders_by_slot.keys():
		var slot_key: String = str(slot_key_value)
		var holders: Array = holders_by_slot[slot_key] as Array
		holders.sort_custom(func(a, b) -> bool:
			var va: float = float((a as Dictionary)["value"])
			var vb: float = float((b as Dictionary)["value"])
			if is_equal_approx(va, vb):
				return int((a as Dictionary)["player_id"]) < int((b as Dictionary)["player_id"])
			return va > vb
		)
		slots[slot_key] = _slot_metrics(slot_key, holders)
	return {"team_id": team_id, "slots": slots}


static func _slot_metrics(slot_key: String, holders: Array) -> Dictionary:
	var first_team_slots: int = first_team_slots_for(slot_key)
	var comfort: int = comfort_for(slot_key)
	var age_total: int = 0
	var aging_count: int = 0
	var young_count: int = 0
	for row in holders:
		var data: Dictionary = row as Dictionary
		var age: int = int(data["age"])
		age_total += age
		if age >= AGING_AGE:
			aging_count += 1
		if age <= PROSPECT_MAX_AGE:
			young_count += 1
	return {
		"slot": slot_key,
		"holders": holders,
		"holder_count": holders.size(),
		"first_team_slots": first_team_slots,
		"comfort": comfort,
		# 一軍枠の最後の選手の value。人数が足りないスロットは -1 (リーグ水準で補う)。
		"first_team_line": float((holders[first_team_slots - 1] as Dictionary)["value"]) \
			if holders.size() >= first_team_slots else -1.0,
		"top_value": float((holders[0] as Dictionary)["value"]) if not holders.is_empty() else 0.0,
		"depth_value": _top_mean(holders, comfort),
		"first_team_value": _top_mean(holders, first_team_slots),
		"avg_age": float(age_total) / float(maxi(1, holders.size())),
		"aging_count": aging_count,
		"young_count": young_count,
	}


static func _top_mean(holders: Array, count: int) -> float:
	if holders.is_empty() or count <= 0:
		return 0.0
	var total: float = 0.0
	var used: int = mini(count, holders.size())
	for index in range(used):
		total += float((holders[index] as Dictionary)["value"])
	# 人数が枠に満たないぶんは 0 で埋める (薄いスロットの厚みを過大評価しない)。
	return total / float(count)


# リーグ平均を各チャートへ書き戻し、need (= リーグ平均 − 自軍) と、
# 空きスロット用の first_team_line の代用値を確定させる。
static func _apply_league_baselines(charts: Dictionary) -> void:
	if charts.is_empty():
		return
	for slot_key in all_slot_keys():
		var depth_total: float = 0.0
		var first_team_total: float = 0.0
		var line_total: float = 0.0
		var line_count: int = 0
		for team_id in charts.keys():
			var slot: Dictionary = _slot_of(charts[team_id] as Dictionary, slot_key)
			depth_total += float(slot.get("depth_value", 0.0))
			first_team_total += float(slot.get("first_team_value", 0.0))
			var line: float = float(slot.get("first_team_line", -1.0))
			if line >= 0.0:
				line_total += line
				line_count += 1
		var league_depth: float = depth_total / float(charts.size())
		var league_first_team: float = first_team_total / float(charts.size())
		var league_line: float = line_total / float(maxi(1, line_count))
		for team_id in charts.keys():
			var slot: Dictionary = _slot_of(charts[team_id] as Dictionary, slot_key)
			slot["league_depth_value"] = league_depth
			slot["league_first_team_value"] = league_first_team
			slot["league_first_team_line"] = league_line
			# `need` = 支配下の厚み (快適人数ぶんの平均) のリーグ差。層の薄さを測る。
			slot["need"] = maxf(0.0, league_depth - float(slot.get("depth_value", 0.0)))
			# `first_team_need` = **一軍で使う枠の質**のリーグ差。野手は「そのポジションのレギュラー」、
			# 投手は「ローテ/ブルペンの主力平均」の差になり、旧 position_need と同じ value 尺度になる。
			# 補強AIの閾値 (FA の MIN_NEED_TO_SIGN 等) はこの尺度で較正されているのでこちらを公開する。
			slot["first_team_need"] = maxf(0.0, league_first_team - float(slot.get("first_team_value", 0.0)))
			if float(slot.get("first_team_line", -1.0)) < 0.0:
				# 人数が一軍枠に満たないスロットは、リーグ水準を当落線として使う
				# (「人が居ないから誰でも即戦力」を防ぐ)。
				slot["first_team_line"] = league_line


static func _slot_of(chart: Dictionary, slot_key: String) -> Dictionary:
	return (chart.get("slots", {}) as Dictionary).get(slot_key, {}) as Dictionary


static func slot_for_player(chart: Dictionary, player: PSPlayer) -> Dictionary:
	return _slot_of(chart, slot_key_for(player))


# そのスロットの補強需要 (一軍枠の質のリーグ差)。補強AIが直接引く公開アクセサ。
static func slot_need(chart: Dictionary, slot_key: String) -> float:
	return float(_slot_of(chart, slot_key).get("first_team_need", 0.0))


# そのスロットに「将来を託す相手が居ない」か。将来に賭ける価値の判定に使う。
# **後継の若手が既に居るスロットは対象外** — 高齢者が1人でも居れば空くとみなす緩い判定にすると、
# ほぼ全スロットが該当してしまい「将来性」が素通しの条件になる (実測で獲得が減らなかった)。
static func has_future_opening(slot: Dictionary) -> bool:
	if slot.is_empty():
		return true
	if int(slot.get("holder_count", 0)) < int(slot.get("first_team_slots", 1)):
		return true
	return int(slot.get("young_count", 0)) == 0


# 候補選手を自軍チャートに照らして評価する。
# 戻り値: {slot, slot_need, is_weakness, first_team_line, value, projected_ceiling, immediate, future, fit}
#  - is_weakness: そのスロットがリーグ平均を下回る = **自軍の弱点**
#  - immediate  : そのスロットの一軍当落線を上回る = **今すぐ一軍で使える**
#  - future     : 素材年齢で、成長の楽観側なら当落線に届き、かつ後継の若手が居ない
#  - fit        : **弱点スロット** かつ (immediate or future) = 獲得を検討してよい選手
# 「弱点であること」を必須にしているのが要点 — 埋まっているスロットに上積みするだけの獲得はしない。
# これで「今年は獲得0人」という球団が普通に出る (旧基準は自軍最弱を超えれば獲得で、
# 全球団が毎年上限まで埋めていた)。
static func evaluate_candidate(chart: Dictionary, candidate: PSPlayer) -> Dictionary:
	if chart.is_empty() or candidate == null:
		return {"immediate": false, "future": false, "fit": false}
	var slot: Dictionary = slot_for_player(chart, candidate)
	var value: float = float(OffseasonService.player_value_score(candidate))
	var ceiling: float = OffseasonService.development_projected_ceiling(candidate)
	var line: float = float(slot.get("first_team_line", 0.0))
	var need: float = float(slot.get("need", 0.0))
	var is_weakness: bool = need > 0.0
	var immediate: bool = value > line
	var future: bool = candidate.age <= PROSPECT_MAX_AGE \
		and ceiling > line \
		and has_future_opening(slot)
	return {
		"slot": str(slot.get("slot", "")),
		"slot_need": need,
		"is_weakness": is_weakness,
		"first_team_line": line,
		"value": value,
		"projected_ceiling": ceiling,
		"immediate": immediate,
		"future": future,
		"fit": is_weakness and (immediate or future),
	}


# 球団×ポジションの補強需要 {team_id: {1..9: need}}。旧 OffseasonService.position_need の互換ビュー。
# **`first_team_need` (一軍枠の質のリーグ差) を返す** — 旧実装が野手「最良1人」・投手「上位K枚平均」を
# リーグ平均と比べていたのと同じ value 尺度で、補強AIの閾値はこの尺度で較正されている。
# 投手 (position 1) は先発/救援スロットの need の大きい方 = より手薄な役割を返す。
static func position_need_view(charts: Dictionary) -> Dictionary:
	var need: Dictionary = {}
	for team_id in charts.keys():
		var chart: Dictionary = charts[team_id] as Dictionary
		var team_need: Dictionary = {}
		team_need[1] = maxf(
			float(_slot_of(chart, SLOT_STARTER).get("first_team_need", 0.0)),
			float(_slot_of(chart, SLOT_RELIEVER).get("first_team_need", 0.0))
		)
		for position in range(2, 10):
			team_need[position] = float(_slot_of(chart, fielder_slot_key(position)).get("first_team_need", 0.0))
		need[team_id] = team_need
	return need
