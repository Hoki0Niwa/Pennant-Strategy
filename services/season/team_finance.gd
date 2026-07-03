extends RefCounted
class_name TeamFinance

# チーム予算の会計ヘルパー。
# funds は年間予算キャップ、payroll は所属アクティブ選手の年俸合計、room は funds - payroll。
# 予算超過は is_over_budget で検出するが、現状は警告に留めて契約更新や補強を直接ブロックしない。

# 育成選手制度を含むロスター計数の単一ソース。
#  - 支配下 (development_player == false) のみが SHIENKA_LIMIT(70) 枠を消費する。
#  - 育成選手 (development_player == true) は NPB 同様に法的な人数上限はないが、ゲーム内では
#    自然増を防ぐため DEVELOPMENT_ROSTER_LIMIT で運用上のソフト上限を設ける (2026-07-02)。
# FA/ドラフト/外国人/戦力外/昇降格/UI はここを参照し、枠判定を一元化する。
const SHIENKA_LIMIT: int = 70
# 育成昇格などの自動内部補充はこのソフト目標で止め、
# SHIENKA_LIMIT(70) との差をシーズン中の育成昇格/再昇格・故障補充用に空けておく。
# ドラフト後の戦力外獲得/FA/外国人補強は draft_service が予約した hard 枠を使う。
const SHIENKA_SOFT_TARGET: int = 67
# 来季開幕時の支配下目標。オフの編成は「この人数へ寄せる」計画ベースで動く (2026-07-03):
#  - 戦力外数 = 現在籍 + 見込み補強 (ドラフト/外国人/補強予約/育成昇格) − この目標 (offseason_service)
#  - ドラフト指名数 = この目標 − 戦力外後の在籍 − 補強予約 (draft_service)
# 両者が同じ収支で連動するため、リーグ全体の人数が構造的に安定し、戦力外を再実行しても
# 目標到達済みなら追加カットが出ない (冪等)。NPB の実運用 (開幕支配下 65〜70) に対応する。
const OPENING_ROSTER_TARGET: int = 68
# 育成選手の運用上限。これを超える新規降格/育成ドラフト指名/戦力外獲得(育成track)は行わない。
# 既存の余剰は昇格 (process_development_promotions) と育成整理 (process_development_releases) で
# 自然に解消される想定。
const DEVELOPMENT_ROSTER_LIMIT: int = 10


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


# 育成枠の空きがあるか (運用上限 DEVELOPMENT_ROSTER_LIMIT 未満)。
static func has_development_room(players: Array, team_id: int) -> bool:
	return development_count(players, team_id) < DEVELOPMENT_ROSTER_LIMIT


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
