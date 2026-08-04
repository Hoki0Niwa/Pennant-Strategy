extends RefCounted
class_name TeamFinance

# チーム予算の会計ヘルパー。
# funds は全球団共通の固定額 (FIXED_BUDGET、年次改定なし)、
# payroll は所属アクティブ選手の年俸合計、room は funds - payroll。
# 予算超過中は can_afford_addition / trade_payroll_ok が補強・年俸増トレードをブロックする
# (契約更改・ドラフト・育成昇格・キャンプは対象外、常に実行する)。

# 育成選手制度を含むロスター計数の単一ソース。
#  - 支配下 (development_player == false) のみが SHIENKA_LIMIT(70) 枠を消費する。
#  - 育成選手 (development_player == true) は NPB 同様に**人数上限なし** (2026-08-02、
#    旧 DEVELOPMENT_ROSTER_LIMIT=10 を撤廃)。抱え込みは枠でも目標人数でもなく
#    **育成契約の年数上限** (OffseasonService.DEV_CONTRACT_MAX_SEASONS) で止める:
#    保有数 ≒ 年間の育成指名数 × 契約年数 で自然に頭打ちになる。
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

# --- 固定予算 (2026-08-04、順位連動の年次改定を廃止) ---
# 旧・年次予算キャップ (2026-07-12〜) は毎オフ順位ボーナス等で funds を再計算していたが、
# 年を追うごとに予算が変わり続ける挙動になっていたため廃止した。全球団同額・毎年不変。
# 単位: 万円。値は廃止時点のアクティブセーブで最も年俸総額が高かった球団 (約42.09億) を
# 上回る 43億に設定 (この球団が導入直後から超過扱いにならないよう切り上げ)。
const FIXED_BUDGET: int = 430000

# AI の補強評価。年俸 AI_SALARY_COST_PER_SCORE 万円につき評価を1点下げる。
# 小さくすると安さを重視し、大きくすると能力を優先する。
const AI_SALARY_COST_PER_SCORE: float = 1000.0
# 戦力外市場では、後続のFAで主力級1人へ提示できる額を先に残す。
const AI_FA_BUDGET_RESERVE: int = 12000
# 外国人不足1枠につき、格安帯の上限額を残す。候補獲得後も残り枠分を再計算する。
const FOREIGN_HELD_TARGET: int = 4
const AI_FOREIGN_BUDGET_RESERVE_PER_SLOT: int = 6000


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


# チームが保有する非引退外国人数。支配下/育成のどちらも保有枠として数える。
static func foreign_player_count(players: Array, team_id: int) -> int:
	var count: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.foreign_player:
			count += 1
	return count


# 予算残枠 (負なら超過)。
static func budget_room(funds: int, payroll: int) -> int:
	return funds - payroll


# 年俸総額が予算を超えているか。
static func is_over_budget(funds: int, payroll: int) -> bool:
	return payroll > funds


# リーグ内最終順位 {team_id: rank(1始まり)}。win_rate 降順、同率は wins 降順で順位付け
# (standings_screen._build_league_rows と同一基準)。リーグは team.league ("league1"/"league2") で分ける。
static func final_ranks(season: PSSeason, teams: Array) -> Dictionary:
	var by_league: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if not by_league.has(team.league):
			by_league[team.league] = []
		(by_league[team.league] as Array).append(team)

	var ranks: Dictionary = {}
	for league_key in by_league.keys():
		var league_teams: Array = by_league[league_key] as Array
		league_teams.sort_custom(func(a, b) -> bool:
			var ta: PSTeam = a as PSTeam
			var tb: PSTeam = b as PSTeam
			var sa: PSStats = season.standings.get(ta.id, null) as PSStats
			var sb: PSStats = season.standings.get(tb.id, null) as PSStats
			var wa: float = sa.win_rate() if sa != null else 0.0
			var wb: float = sb.win_rate() if sb != null else 0.0
			if is_equal_approx(wa, wb):
				var winsa: int = sa.wins if sa != null else 0
				var winsb: int = sb.wins if sb != null else 0
				return winsa > winsb
			return wa > wb
		)
		var rank: int = 1
		for team_row in league_teams:
			ranks[(team_row as PSTeam).id] = rank
			rank += 1
	return ranks


# 前年順位だけを更新する (毎オフ start_offseason で1回呼ぶ)。予算は固定 (FIXED_BUDGET) のため
# funds には触れない。previous_rank は draft_service のフォールバック並び替え・
# team_select_screen の表示にのみ使う。
static func update_previous_ranks(teams: Array, season: PSSeason) -> void:
	var ranks: Dictionary = final_ranks(season, teams)
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		team.previous_rank = int(ranks.get(team.id, team.previous_rank))


# 固定予算に対する残額サマリー (検証レポート用)。funds は変更しない。
# 戻り値: {"team_budgets": [{team_id, name, funds, payroll, room, over_budget}, ...],
#   "over_budget_count": int}
static func budget_summary(players: Array, teams: Array) -> Dictionary:
	var team_budgets: Array = []
	var over_budget_count: int = 0
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var payroll: int = team_payroll(players, team.id)
		var room: int = budget_room(team.funds, payroll)
		var over: bool = is_over_budget(team.funds, payroll)
		if over:
			over_budget_count += 1
		team_budgets.append({
			"team_id": team.id, "name": team.name,
			"funds": team.funds, "payroll": payroll, "room": room, "over_budget": over,
		})
	return {"team_budgets": team_budgets, "over_budget_count": over_budget_count}


# 補強ゲート: 追加コスト (年俸 + FA補償金等) を払っても現行 payroll+cost が funds に収まるか。
static func can_afford_addition(players: Array, team: PSTeam, added_cost: int) -> bool:
	if team == null:
		return false
	var payroll: int = team_payroll(players, team.id)
	return payroll + added_cost <= team.funds


# AI用補強ゲート。獲得費に加えて、後続市場へ残す reserve も予算内に確保する。
static func can_afford_ai_addition(players: Array, team: PSTeam, added_cost: int, reserve: int) -> bool:
	if team == null:
		return false
	var payroll: int = team_payroll(players, team.id)
	return payroll + maxi(0, added_cost) + maxi(0, reserve) <= team.funds


# オフの残り市場向け予算。additional_foreign は今回の獲得で埋まる外国人枠数。
static func ai_offseason_budget_reserve(
	players: Array,
	team_id: int,
	reserve_fa: bool,
	reserve_foreign: bool,
	additional_foreign: int = 0
) -> int:
	var reserve: int = AI_FA_BUDGET_RESERVE if reserve_fa else 0
	if reserve_foreign:
		var held_after_addition: int = foreign_player_count(players, team_id) + maxi(0, additional_foreign)
		var open_slots: int = maxi(0, FOREIGN_HELD_TARGET - held_after_addition)
		reserve += open_slots * AI_FOREIGN_BUDGET_RESERVE_PER_SLOT
	return reserve


# 能力・需要スコアから差し引く補強コスト。FAは提示年俸と補償金の合計を渡す。
static func ai_acquisition_cost_penalty(cost: int) -> float:
	return float(maxi(0, cost)) / AI_SALARY_COST_PER_SCORE


# トレードゲート: 年俸総額が増えない (out >= in) 交換は予算に関わらず常に許可する。
# 増える交換は、増加後の payroll が funds に収まる場合のみ許可する。
static func trade_payroll_ok(players: Array, team: PSTeam, out_salary_total: int, in_salary_total: int) -> bool:
	if team == null:
		return false
	if in_salary_total <= out_salary_total:
		return true
	var payroll: int = team_payroll(players, team.id)
	var new_payroll: int = payroll - out_salary_total + in_salary_total
	return new_payroll <= team.funds
