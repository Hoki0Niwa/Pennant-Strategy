extends RefCounted
class_name TeamFinance

# R4 Step1: チーム予算の会計ヘルパー。
# funds = 年間予算キャップ (PSTeam.funds, セーブに永続化)。
# payroll = 所属アクティブ選手の年俸 (salary) 合計。
# 残枠 (room) = funds - payroll。超過は is_over_budget で判定するが、Step1 では
# ソフト警告のみで契約更新/補強をブロックしない (硬い上限は Step2 以降)。
#
# 収入モデル (funds の年次変動) は R5 へ先送り。funds は毎年のベースライン予算として維持し、
# 多年で枯渇させない。

# roadmap #3 育成選手制度: ロスター計数の単一ソース。
#  - 支配下 (development_player == false) のみが SHIENKA_LIMIT(70) 枠を消費する。
#  - 育成選手 (development_player == true) は枠外で、DEVELOPMENT_LIMIT までソフト制限する。
# FA/ドラフト/外国人/戦力外/昇降格/UI はここを参照し、枠判定を一元化する。
const SHIENKA_LIMIT: int = 70
const DEVELOPMENT_LIMIT: int = 15


# 支配下選手数 (team_id 一致 ∧ 非引退 ∧ 非マネージャー ∧ 非育成)。70 枠の母数。
static func shienka_count(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.development_player:
			continue
		count += 1
	return count


# 育成選手数 (team_id 一致 ∧ 非引退 ∧ 非マネージャー ∧ 育成)。
static func development_count(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.development_player:
			count += 1
	return count


# 支配下登録 (昇格) の空きがあるか。
static func has_shienka_room(players: Array, team_id: int) -> bool:
	return shienka_count(players, team_id) < SHIENKA_LIMIT


# 育成枠の空きがあるか (育成降格/育成指名の可否)。
static func has_development_room(players: Array, team_id: int) -> bool:
	return development_count(players, team_id) < DEVELOPMENT_LIMIT


# チーム所属 (team_id 一致) のアクティブ選手 (引退/マネージャー候補を除く) の年俸合計。
static func team_payroll(players: Array, team_id: int) -> int:
	var total: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null:
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		total += player.salary
	return total


# 予算残枠 (負なら超過)。
static func budget_room(funds: int, payroll: int) -> int:
	return funds - payroll


# 年俸総額が予算を超えているか。
static func is_over_budget(funds: int, payroll: int) -> bool:
	return payroll > funds


# 全球団の {team_id: {funds, payroll, room, over_budget}} サマリ。
