extends RefCounted
class_name TeamDirection

# 球団の編成方針を 1 つの数値 (stance) で表す。+1 = 今季を勝ちに行く (即戦力重視)、
# -1 = 数年後に備える (将来重視)、0 = どちらでもない。
# 補強AIが「同じ選手でも球団によって欲しさが違う」ことを表すために使う (現状はトレード)。
#
# stance は 2 つの材料の加重和:
# - 順位: リーグの CS 圏 (上位 CONTENTION_SPOTS) の最下位からのゲーム差。
# - 戦力: 一軍枠の質 (TeamDepthChart の first_team_value) のリーグ内偏差。
# 開幕直後は順位に意味が無いので戦力だけで決まり、試合を消化するほど順位が効く。

# CS に進める順位。ここまでの球団は「圏内」として扱う。
const CONTENTION_SPOTS: int = 3
# CS 圏の最下位から何ゲーム後ろまでを「まだ届く」とみなすか。この差の球団が順位面で中立 (0) になり、
# 圏内最下位の球団はそのぶんだけ即戦力重視に寄る。上げると売り手に回る球団が減る。
const STANDINGS_BUBBLE_GAMES: float = 2.0
# 順位面の stance が ±1 に張り付くまでのゲーム差 (中立点からの距離)。下げると少しの差で方針が振れる。
const STANDINGS_SWING_GAMES: float = 6.0
# 順位を最大限信用する消化試合数と、そのときの順位の重み (残りは戦力)。
# 重みを 1.0 にしないのは、戦力はあるのに出遅れただけの球団をすぐ売り手にしないため。
const STANDINGS_TRUST_GAMES: float = 60.0
const STANDINGS_MAX_WEIGHT: float = 0.8
# 戦力面の stance が ±1 に張り付くリーグ内偏差 (標準偏差の何倍か)。
const STRENGTH_SWING_SD: float = 1.5

# 表示ラベルの境界。|stance| がこれ未満なら「バランス」。
const LABEL_THRESHOLD: float = 0.35

const KIND_WIN_NOW: String = "win_now"
const KIND_BALANCED: String = "balanced"
const KIND_FUTURE: String = "future"


# 全球団の stance を返す ({team_id: float, -1..+1})。charts は TeamDepthChart.build_league の戻り値
# (現在戦力だけで足りるので include_future=false のチャートでよい)。
static func build_league(season: PSSeason, teams: Array, charts: Dictionary) -> Dictionary:
	var by_league: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if not by_league.has(team.league):
			by_league[team.league] = []
		(by_league[team.league] as Array).append(team.id)

	var stances: Dictionary = {}
	for league_key in by_league.keys():
		var team_ids: Array = by_league[league_key] as Array
		var strength: Dictionary = _strength_stances(team_ids, charts)
		var standings: Dictionary = _standings_stances(season, team_ids)
		for team_id in team_ids:
			var weight: float = _standings_weight(season, int(team_id))
			stances[team_id] = clampf(
				lerpf(float(strength.get(team_id, 0.0)), float(standings.get(team_id, 0.0)), weight),
				-1.0, 1.0
			)
	return stances


static func kind_for(stance: float) -> String:
	if stance >= LABEL_THRESHOLD:
		return KIND_WIN_NOW
	if stance <= -LABEL_THRESHOLD:
		return KIND_FUTURE
	return KIND_BALANCED


static func label_for(stance: float) -> String:
	return Loc.t("team_direction.%s" % kind_for(stance))


# 一軍枠の質の合計 (スロットの枠数で重み付け) をリーグ内で標準化する。
static func _strength_stances(team_ids: Array, charts: Dictionary) -> Dictionary:
	var totals: Dictionary = {}
	var sum: float = 0.0
	for team_id in team_ids:
		var total: float = 0.0
		var slots: Dictionary = (charts.get(team_id, {}) as Dictionary).get("slots", {}) as Dictionary
		for slot_value in slots.values():
			var slot: Dictionary = slot_value as Dictionary
			total += float(slot.get("first_team_value", 0.0)) * float(slot.get("first_team_slots", 1))
		totals[team_id] = total
		sum += total
	var out: Dictionary = {}
	if team_ids.size() < 2:
		for team_id in team_ids:
			out[team_id] = 0.0
		return out
	var mean: float = sum / float(team_ids.size())
	var variance: float = 0.0
	for team_id in team_ids:
		variance += pow(float(totals[team_id]) - mean, 2.0)
	var sd: float = sqrt(variance / float(team_ids.size()))
	for team_id in team_ids:
		out[team_id] = 0.0 if sd <= 0.0001 else clampf((float(totals[team_id]) - mean) / (sd * STRENGTH_SWING_SD), -1.0, 1.0)
	return out


# CS 圏の最下位 (CONTENTION_SPOTS 位) の貯金との差をゲーム差に直し、中立点 (STANDINGS_BUBBLE_GAMES 後ろ)
# からの距離で -1..+1 にする。圏が成り立たない小さなリーグ (球団数 <= CONTENTION_SPOTS) は全球団 0。
static func _standings_stances(season: PSSeason, team_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	var balances: Array = []
	for team_id in team_ids:
		out[team_id] = 0.0
		balances.append(_balance(season, int(team_id)))
	if team_ids.size() <= CONTENTION_SPOTS:
		return out
	var sorted_balances: Array = balances.duplicate()
	sorted_balances.sort()
	sorted_balances.reverse()
	var line: float = float(sorted_balances[CONTENTION_SPOTS - 1])
	for index in range(team_ids.size()):
		var games_from_line: float = (float(balances[index]) - line) * 0.5
		out[team_ids[index]] = clampf((games_from_line + STANDINGS_BUBBLE_GAMES) / STANDINGS_SWING_GAMES, -1.0, 1.0)
	return out


static func _standings_weight(season: PSSeason, team_id: int) -> float:
	var stats: PSStats = _stats(season, team_id)
	if stats == null:
		return 0.0
	return clampf(float(stats.wins + stats.losses + stats.draws) / STANDINGS_TRUST_GAMES, 0.0, 1.0) * STANDINGS_MAX_WEIGHT


static func _balance(season: PSSeason, team_id: int) -> int:
	var stats: PSStats = _stats(season, team_id)
	return stats.wins - stats.losses if stats != null else 0


static func _stats(season: PSSeason, team_id: int) -> PSStats:
	if season == null:
		return null
	return season.standings.get(team_id) as PSStats
