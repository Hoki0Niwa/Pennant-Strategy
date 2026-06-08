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


# チーム所属 (team_id 一致) のアクティブ選手 (引退/マネージャー候補を除く) の年俸合計。
static func team_payroll(players: Array, team_id: int) -> int:
	var total: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null:
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired() or player.is_manager_candidate():
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
