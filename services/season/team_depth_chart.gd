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
# - `holder_count` / `avg_age` / `aging_count`: 人数と年齢構成。
#
# ## 将来 (FUTURE_HORIZON_YEARS 年後) の見通し
# 現在値と**同じ形**の指標をもう1組持つ。母数は支配下 + 育成の全員で、各人の値は
# `OffseasonService.projected_value_after` = (現在値 + 年齢別の成長/衰え期待) × 現役でいる確率。
# - `future_value`: 将来の一軍枠の質 (現在値でいう first_team_value)。リーグ差が `future_need`。
# - `future_line` : 将来の当落線 (現在値でいう first_team_line)。**「そのスロットの数年後の枠を
#   誰が埋めているか」の水準**で、獲得候補の将来性はこれと比べて判定する。
# ⚠️ 「24歳以下の上位2人の平均」という旧 prospect_value は 2026-08-05 に廃止した。年齢の閾値だけで
#   区切ると (a) 38歳のレギュラーが居座るスロットが「将来安泰」に見え、(b) 25歳の主力が将来性に
#   数えられない、という2つの誤りが出る。現在の方式は加齢を能力の衰えと引退確率の両方で効かせる。
#
# ## 候補の評価
# `evaluate_candidate` が「そのスロットに入れたとき即戦力か / 将来に賭ける価値があるか」を返す。
# **どちらでもない選手は獲らない**、という厳しい基準を各補強AIが共有する。
# 将来性は `future_line` との比較なので、**既にトップ級のプロスペクトが居るスロットは自動的に閉じる**
# (その選手が将来の当落線を押し上げるため)。逆にベテランだけのスロットは線が下がり後継を求める。

const PROSPECT_MAX_AGE: int = 24
const AGING_AGE: int = 32

# 将来を何年先で測るか。ドラフト/育成の投資が一軍戦力として回収され始めるまでの目安。
# 短くすると若手の伸びしろが効かず現在値とほぼ同じになり、長くすると誰の予測も不確かになる。
# 5年 = 高卒選手が主力になり、30代半ばの主力が衰え・引退で入れ替わる区切り。
const FUTURE_HORIZON_YEARS: int = 5

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


static func _build_team_slots(players: Array, team_id: int) -> Dictionary:
	var holders_by_slot: Dictionary = {}
	var future_by_slot: Dictionary = {}
	for slot_key in all_slot_keys():
		holders_by_slot[slot_key] = []
		future_by_slot[slot_key] = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or player.is_retired():
			continue
		var slot_key: String = slot_key_for(player)
		if not holders_by_slot.has(slot_key):
			continue
		# 将来側は**育成も含む全員**が母数 (数年後には支配下に上がっているため)。
		# holders (現在値・支配下のみ) とは別配列に積む — 混ぜると first_team_line / depth_value が
		# 動いて補強AIの較正済み閾値が全系統ずれる。
		# `value` は並べ替えに使う軸 (将来側は予測値)、`overall` は**現在の総合評価**で共通。
		# 表示側が主力と有望株を同じ形で出せるよう、どちらの配列も同じキーを持たせる。
		var overall: float = float(OffseasonService.player_value_score(player))
		(future_by_slot[slot_key] as Array).append({
			"player_id": player.id,
			"value": OffseasonService.projected_value_after(player, FUTURE_HORIZON_YEARS),
			"overall": overall,
			"age": player.age,
			"development": player.development_player,
		})
		if player.development_player:
			continue
		(holders_by_slot[slot_key] as Array).append({
			"player_id": player.id,
			"value": overall,
			"overall": overall,
			"age": player.age,
			"development": false,
		})

	var slots: Dictionary = {}
	for slot_key_value in holders_by_slot.keys():
		var slot_key: String = str(slot_key_value)
		var holders: Array = holders_by_slot[slot_key] as Array
		var future_holders: Array = future_by_slot[slot_key] as Array
		_sort_by_value_desc(holders)
		_sort_by_value_desc(future_holders)
		slots[slot_key] = _slot_metrics(slot_key, holders, future_holders)
	return {"team_id": team_id, "slots": slots}


# value 降順 (同値は player_id 昇順で安定化)。
static func _sort_by_value_desc(rows: Array) -> void:
	rows.sort_custom(func(a, b) -> bool:
		var va: float = float((a as Dictionary)["value"])
		var vb: float = float((b as Dictionary)["value"])
		if is_equal_approx(va, vb):
			return int((a as Dictionary)["player_id"]) < int((b as Dictionary)["player_id"])
		return va > vb
	)


static func _slot_metrics(slot_key: String, holders: Array, future_holders: Array = []) -> Dictionary:
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
		# FUTURE_HORIZON_YEARS 年後の見通し (育成込み・成長/衰え/引退確率を織り込んだ予測値)。
		# 現在値の first_team_value / first_team_line と同じ形で、同じ尺度で比較できる。
		"future_holders": future_holders,
		"future_value": _top_mean(future_holders, first_team_slots),
		"future_line": float((future_holders[first_team_slots - 1] as Dictionary)["value"]) \
			if future_holders.size() >= first_team_slots else -1.0,
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
		var future_total: float = 0.0
		var line_total: float = 0.0
		var line_count: int = 0
		var future_line_total: float = 0.0
		var future_line_count: int = 0
		for team_id in charts.keys():
			var slot: Dictionary = _slot_of(charts[team_id] as Dictionary, slot_key)
			depth_total += float(slot.get("depth_value", 0.0))
			first_team_total += float(slot.get("first_team_value", 0.0))
			future_total += float(slot.get("future_value", 0.0))
			var line: float = float(slot.get("first_team_line", -1.0))
			if line >= 0.0:
				line_total += line
				line_count += 1
			var future_line: float = float(slot.get("future_line", -1.0))
			if future_line >= 0.0:
				future_line_total += future_line
				future_line_count += 1
		var league_depth: float = depth_total / float(charts.size())
		var league_first_team: float = first_team_total / float(charts.size())
		var league_future: float = future_total / float(charts.size())
		var league_line: float = line_total / float(maxi(1, line_count))
		var league_future_line: float = future_line_total / float(maxi(1, future_line_count))
		for team_id in charts.keys():
			var slot: Dictionary = _slot_of(charts[team_id] as Dictionary, slot_key)
			slot["league_depth_value"] = league_depth
			slot["league_first_team_value"] = league_first_team
			slot["league_future_value"] = league_future
			slot["league_first_team_line"] = league_line
			slot["league_future_line"] = league_future_line
			# `need` = 支配下の厚み (快適人数ぶんの平均) のリーグ差。層の薄さを測る。
			slot["need"] = maxf(0.0, league_depth - float(slot.get("depth_value", 0.0)))
			# `first_team_need` = **一軍で使う枠の質**のリーグ差。野手は「そのポジションのレギュラー」、
			# 投手は「ローテ/ブルペンの主力平均」の差になり、旧 position_need と同じ value 尺度になる。
			# 補強AIの閾値 (FA の MIN_NEED_TO_SIGN 等) はこの尺度で較正されているのでこちらを公開する。
			slot["first_team_need"] = maxf(0.0, league_first_team - float(slot.get("first_team_value", 0.0)))
			# `future_need` = 数年後の一軍枠の質のリーグ差。**現在は足りていても後継が居なければ立つ**
			# ので、ドラフトのように回収まで時間がかかる補強はこちらを見る。
			slot["future_need"] = maxf(0.0, league_future - float(slot.get("future_value", 0.0)))
			if float(slot.get("first_team_line", -1.0)) < 0.0:
				# 人数が一軍枠に満たないスロットは、リーグ水準を当落線として使う
				# (「人が居ないから誰でも即戦力」を防ぐ)。
				slot["first_team_line"] = league_line
			if float(slot.get("future_line", -1.0)) < 0.0:
				slot["future_line"] = league_future_line


static func _slot_of(chart: Dictionary, slot_key: String) -> Dictionary:
	return (chart.get("slots", {}) as Dictionary).get(slot_key, {}) as Dictionary


const FIELDER_SLOT_LABELS: Dictionary = {
	2: "捕手", 3: "一塁", 4: "二塁", 5: "三塁", 6: "遊撃", 7: "左翼", 8: "中堅", 9: "右翼",
}


# スロットの表示名。UI 側で名前を作り直さないための単一ソース。
static func slot_label(slot_key: String) -> String:
	if slot_key == SLOT_STARTER:
		return "先発"
	if slot_key == SLOT_RELIEVER:
		return "救援"
	return str(FIELDER_SLOT_LABELS.get(slot_position(slot_key), slot_key))


# スロットの守備位置番号 (投手スロットは 1)。ポジション色の解決に使う。
static func slot_position(slot_key: String) -> int:
	if not slot_key.begins_with("fielder:"):
		return 1
	return int(slot_key.get_slice(":", 1))


static func slot_for_player(chart: Dictionary, player: PSPlayer) -> Dictionary:
	return _slot_of(chart, slot_key_for(player))


# そのスロットの補強需要 (一軍枠の質のリーグ差)。補強AIが直接引く公開アクセサ。
static func slot_need(chart: Dictionary, slot_key: String) -> float:
	return float(_slot_of(chart, slot_key).get("first_team_need", 0.0))


# そのスロットの**将来**の補強需要 (数年後の一軍枠の質のリーグ差)。現在は足りていても
# 主力が高齢で後継が居なければ立つ。ドラフトのように回収まで時間がかかる補強が見る。
static func slot_future_need(chart: Dictionary, slot_key: String) -> float:
	return float(_slot_of(chart, slot_key).get("future_need", 0.0))


# 候補選手を自軍チャートに照らして評価する。
# 戻り値: {slot, slot_need, is_weakness, first_team_line, future_line, value, projected_value,
#          immediate, future, fit}
#  - is_weakness: そのスロットがリーグ平均を下回る = **自軍の弱点**
#  - immediate  : そのスロットの一軍当落線を `upgrade_margin` 以上上回る = **今すぐ一軍で使える**
#  - future     : 数年後の予測値がそのスロットの**将来の当落線**を上回る = 後継として計算できる
#  - fit        : **弱点スロット** かつ (immediate or future) = 獲得を検討してよい選手
# 「弱点であること」を必須にしているのが要点 — 埋まっているスロットに上積みするだけの獲得はしない。
#
# `future` の判定を future_line (将来の当落線) との比較にしてあるので、**既に将来を託せる選手が
# 居るスロットは自動的に閉じる** (その選手が線を押し上げる)。逆に主力が高齢なだけのスロットは
# 線が下がって後継を求める。旧実装は「24歳以下 ∧ 成長の楽観側が現在の当落線に届く ∧ 若手が0人」
# だったが、年齢だけで区切ると素通しになりやすく、当落線も現在値だったため後継の要否を測れなかった。
#
# `upgrade_margin` は「当落線をどれだけ明確に上回れば戦力とみなすか」の余裕幅 (value 単位、
# 既定 0 = 1点でも上回れば可)。**is_weakness (need > 0) はリーグ平均との比較なので構造的に
# 全球団の約半数・約半分のスロットが該当する**ゆるいゲートで、これ単独では獲得数を絞れない
# (毎年12球団すべてが上限まで獲る)。margin は投打で同じ value 尺度なので、旧 MIN_NEED_TO_SIGN の
# ようにリーグ相対 need へ閾値を置いたとき投手側だけ need が立たず野手偏重になる問題も起きない。
static func evaluate_candidate(chart: Dictionary, candidate: PSPlayer, upgrade_margin: float = 0.0) -> Dictionary:
	if chart.is_empty() or candidate == null:
		return {"immediate": false, "future": false, "fit": false}
	var slot: Dictionary = slot_for_player(chart, candidate)
	var value: float = float(OffseasonService.player_value_score(candidate))
	var projected: float = OffseasonService.projected_value_after(candidate, FUTURE_HORIZON_YEARS)
	var line: float = float(slot.get("first_team_line", 0.0))
	var future_line: float = float(slot.get("future_line", 0.0))
	var need: float = float(slot.get("need", 0.0))
	var is_weakness: bool = need > 0.0
	var immediate: bool = value >= line + upgrade_margin
	var future: bool = projected >= future_line + upgrade_margin
	return {
		"slot": str(slot.get("slot", "")),
		"slot_need": need,
		"is_weakness": is_weakness,
		"first_team_line": line,
		"future_line": future_line,
		"value": value,
		"projected_value": projected,
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


# 1球団ぶんの表示用ビュー (all_slot_keys の順に1行ずつ)。**読み取り専用で補強AIは使わない** —
# プレイヤーが獲得判断のために「どの枠が弱いか / 後継が居るか」を見るためのもの。
# 各行の2つの軸:
#  - current = `first_team_value` (今の一軍枠の質)
#  - future  = `future_value`     (FUTURE_HORIZON_YEARS 年後の一軍枠の質)
# **生値は12球団が団子になって読めない**ので、同じスロットの全球団を母集団にした
# S〜E グレード ([[StrengthGrade]]) と順位 (*_rank、1 が最良) を主役にし、
# 生値と最大値比 (*_ratio、バーの伸び) は補助として添える。
static func display_rows(charts: Dictionary, team_id: int) -> Array:
	var chart: Dictionary = charts.get(team_id, {}) as Dictionary
	if chart.is_empty():
		return []
	var rows: Array = []
	for slot_key in all_slot_keys():
		var slot: Dictionary = _slot_of(chart, slot_key)
		var holders: Array = slot.get("holders", []) as Array
		var future_holders: Array = slot.get("future_holders", []) as Array
		var current: Dictionary = _league_standing(charts, slot_key, "first_team_value", team_id)
		var future: Dictionary = _league_standing(charts, slot_key, "future_value", team_id)
		rows.append({
			"slot": slot_key,
			"label": slot_label(slot_key),
			"position": slot_position(slot_key),
			"holder_count": int(slot.get("holder_count", 0)),
			"first_team_slots": int(slot.get("first_team_slots", 1)),
			"avg_age": float(slot.get("avg_age", 0.0)),
			"aging_count": int(slot.get("aging_count", 0)),
			"young_count": int(slot.get("young_count", 0)),
			"current": float(slot.get("first_team_value", 0.0)),
			"current_rank": int(current["rank"]),
			"current_ratio": float(current["ratio"]),
			"current_grade": str(current["grade"]),
			"future": float(slot.get("future_value", 0.0)),
			"future_rank": int(future["rank"]),
			"future_ratio": float(future["ratio"]),
			"future_grade": str(future["grade"]),
			"team_count": charts.size(),
			# 代表選手 (主力 = 今の一軍枠の筆頭 / 後継 = 将来予測の筆頭で PROSPECT_MAX_AGE 以下)。
			"top_holder": (holders[0] as Dictionary) if not holders.is_empty() else {},
			"top_prospect": _top_young(future_holders),
		})
	return rows


# 将来予測が最も高い若手 (PROSPECT_MAX_AGE 以下)。future_holders は予測値降順なので先頭一致で足りる。
static func _top_young(future_holders: Array) -> Dictionary:
	for row in future_holders:
		var entry: Dictionary = row as Dictionary
		if int(entry.get("age", 99)) <= PROSPECT_MAX_AGE:
			return entry
	return {}


# 指定スロット・指定指標での自軍の立ち位置。rank は 1 起点 (同値は同順)、
# grade / ratio は同スロット全球団を母集団にした S〜E とバーの伸び ([[StrengthGrade]])。
static func _league_standing(charts: Dictionary, slot_key: String, metric_key: String, team_id: int) -> Dictionary:
	var mine: float = float(_slot_of(charts.get(team_id, {}) as Dictionary, slot_key).get(metric_key, 0.0))
	var sample: Array = []
	var better: int = 0
	for other_id in charts.keys():
		var value: float = float(_slot_of(charts[other_id] as Dictionary, slot_key).get(metric_key, 0.0))
		sample.append(value)
		if int(other_id) != team_id and value > mine:
			better += 1
	return {
		"rank": better + 1,
		"grade": StrengthGrade.from_sample(mine, sample),
		"ratio": StrengthGrade.fill_ratio(mine, sample),
	}


# 球団全体の戦力 {current_grade, future_grade, current_rank, future_rank}。各スロットの値の合計を
# 球団の総戦力とし、全球団を母集団にしてグレード化する (スロット単位のグレードの平均ではない —
# 平均は中央に寄って差が出ない)。
static func team_grades(charts: Dictionary, team_id: int) -> Dictionary:
	var current_sample: Array = []
	var future_sample: Array = []
	var current_mine: float = 0.0
	var future_mine: float = 0.0
	for other_id in charts.keys():
		var chart: Dictionary = charts[other_id] as Dictionary
		var current_total: float = 0.0
		var future_total: float = 0.0
		for slot_key in all_slot_keys():
			var slot: Dictionary = _slot_of(chart, slot_key)
			current_total += float(slot.get("first_team_value", 0.0))
			future_total += float(slot.get("future_value", 0.0))
		current_sample.append(current_total)
		future_sample.append(future_total)
		if int(other_id) == team_id:
			current_mine = current_total
			future_mine = future_total
	var current_better: int = 0
	var future_better: int = 0
	for index in range(current_sample.size()):
		if float(current_sample[index]) > current_mine:
			current_better += 1
		if float(future_sample[index]) > future_mine:
			future_better += 1
	return {
		"current_grade": StrengthGrade.from_sample(current_mine, current_sample),
		"future_grade": StrengthGrade.from_sample(future_mine, future_sample),
		"current_rank": current_better + 1,
		"future_rank": future_better + 1,
	}
