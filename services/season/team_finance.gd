extends RefCounted
class_name TeamFinance

# チーム予算の会計ヘルパー。
# funds は年間予算キャップ、payroll は所属アクティブ選手の年俸合計、room は funds - payroll。
# 予算超過は is_over_budget で検出するが、現状は警告に留めて契約更新や補強を直接ブロックしない。

# 育成選手制度を含むロスター計数の単一ソース。
#  - 支配下 (development_player == false) のみが SHIENKA_LIMIT(70) 枠を消費する。
#  - 育成選手 (development_player == true) は枠外で **人数無制限** (NPB 育成同様)。むやみな抱え込みは
#    枠数ではなく獲得/放出ロジック (素材保持型のみ降格・26歳以上整理・失敗プロスペクト整理) で抑制する。
# FA/ドラフト/外国人/戦力外/昇降格/UI はここを参照し、枠判定を一元化する。
const SHIENKA_LIMIT: int = 70
# 育成昇格などの自動内部補充はこのソフト目標で止め、
# SHIENKA_LIMIT(70) との差をシーズン中の育成昇格/再昇格・故障補充用に空けておく。
# ドラフト後の戦力外獲得/FA/外国人補強は draft_service が予約した hard 枠を使う。
const SHIENKA_SOFT_TARGET: int = 67


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


# 支配下登録 (昇格) の空きがあるか (hard 上限 70)。手動の支配下登録/復帰はこちらを使う。
static func has_shienka_room(players: Array, team_id: int) -> bool:
	return shienka_count(players, team_id) < SHIENKA_LIMIT


# オフシーズンの自動補強用の空きがあるか (soft 目標 67)。70 との差をシーズン中用に空ける。
static func has_shienka_soft_room(players: Array, team_id: int) -> bool:
	return shienka_count(players, team_id) < SHIENKA_SOFT_TARGET


# 育成枠の空きがあるか。育成は人数無制限なので常に true (降格/育成指名は枠数でなく各ロジックで判断)。
# `players` は将来の拡張余地のため残す (現状は未使用)。
static func has_development_room(_players: Array, _team_id: int) -> bool:
	return true


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
