extends RefCounted
class_name PSReferencePopulation

# 調査ツールが共有する「一軍相当の母集団」。GameDb.teams (12球団) からのみ測る。
# 専用球団は GameDb.farm_clubs 側なので構造的に混ざらない
# ([[project_farm_system_design]] の pool_snapshot 汚染と同じ罠を避ける)。
#
# 母集団は**ゲーム自身の選出ロジック**で決める。独自ランキング (打撃 z 上位9人など) で採ると
# 守備込みで選ばれる捕手・二遊間が落ちて打者側だけ強く出る (実測: OPS .929 / BABIP .412)。
# 打線 = select_defensive_starters + DH、守備も同じ9人。投手は pitcher_order_score 上位
# = 6ローテ + 主力救援5 ≒ 一軍イニングの大半を投げる層。
#
# run_pa_response_surface と run_platoon_probe が同じ母集団を見るための単一ソース。
# 片方だけ抽出条件が変わると、傾き (前者) と左右差 (後者) を突き合わせられなくなる。

const DEFAULT_YEAR: int = 2026
const DEFAULT_SEASON_NUMBER: int = 1
const DEFAULT_PITCHERS_PER_TEAM: int = 11

# 能力水準を測る「質」の能力キー。スタイル軸 (Bat_Spray/Bat_Aggression/Bat_Platoon/
# Pit_EdgeRate) と守備・走塁は水準に含めない。
const BATTER_LEVEL_KEYS: Array[String] = [
	"Bat_Barrel", "Bat_Impact", "Bat_Loft", "Bat_BBCreate", "Bat_KAvoid",
]
const PITCHER_LEVEL_KEYS: Array[String] = [
	"Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_LoftControl",
	"Pit_BarrelDeny", "Pit_Efficiency", "Pit_Stamina", "Pit_FatigueResist",
]


static func build(pitchers_per_team: int = DEFAULT_PITCHERS_PER_TEAM) -> Dictionary:
	var lineups: Array = []          # 球団ごとの打順 (9人)
	var fielding_slots: Array = []   # 球団ごとの守備スロット
	var pitchers: Array = []         # 全球団の一軍主力投手をフラットに
	var all_batters: Array = []
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		if team == null:
			continue
		var team_fielders: Array = []
		var team_pitchers: Array = []
		for player_value in GameDb.get_players_for_team(team.id):
			var player: PSPlayer = player_value as PSPlayer
			if player == null or player.is_retired() or player.development_player:
				continue
			var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, DEFAULT_YEAR, DEFAULT_SEASON_NUMBER)
			if record.is_pitcher():
				team_pitchers.append(record)
			else:
				team_fielders.append(record)

		# 打線と守備はゲーム自身の選出ロジックで決める (season は不要 = null で呼べる)。
		var slots: Array = PSTeamSetupBuilder.select_defensive_starters(null, team.id, team_fielders)
		if slots.is_empty() or team_pitchers.is_empty():
			continue
		var order: Array = PSTeamSetupBuilder.records_from_fielding_slots(slots)
		var designated_hitter: PSPlayerSeasonRecord = PSTeamSetupBuilder.select_designated_hitter(team_fielders, slots)
		if designated_hitter != null:
			order.append(designated_hitter)
		PSTeamSetupBuilder.sort_batting_order(order)
		lineups.append(order)
		fielding_slots.append(slots)
		all_batters.append_array(order)

		team_pitchers.sort_custom(func(a, b) -> bool:
			return PSScoringHelpers.pitcher_order_score(a as PSPlayerSeasonRecord) > PSScoringHelpers.pitcher_order_score(b as PSPlayerSeasonRecord)
		)
		for index in range(min(pitchers_per_team, team_pitchers.size())):
			pitchers.append(team_pitchers[index])

	if lineups.is_empty() or pitchers.is_empty():
		return {"ok": false, "message": "一軍相当の選手を抽出できませんでした"}

	var batter_profile: Dictionary = mean_z_by_key(all_batters, BATTER_LEVEL_KEYS)
	var pitcher_profile: Dictionary = mean_z_by_key(pitchers, PITCHER_LEVEL_KEYS)
	return {
		"ok": true,
		"lineups": lineups,
		"fielding_slots": fielding_slots,
		"pitchers": pitchers,
		"teams": lineups.size(),
		"batter_sample": all_batters.size(),
		"pitcher_sample": pitchers.size(),
		"batter_profile": batter_profile,
		"pitcher_profile": pitcher_profile,
		# run_farm_report の usage_levels と直接比べる値 (一軍は 打者 +1.60 / 投手 +1.75 付近)。
		"batter_level": _round_float(mean_of_values(batter_profile), 3),
		"pitcher_level": _round_float(mean_of_values(pitcher_profile), 3),
	}


static func mean_z_by_key(records: Array, keys: Array[String]) -> Dictionary:
	var means: Dictionary = {}
	if records.is_empty():
		return means
	for key in keys:
		var total: float = 0.0
		for record_value in records:
			total += (record_value as PSPlayerSeasonRecord).z_ability(key, 0.0)
		means[key] = _round_float(total / float(records.size()), 4)
	return means


static func _round_float(value: float, digits: int) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor


static func mean_of_values(values: Dictionary) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for key in values.keys():
		total += float(values[key])
	return total / float(values.size())


# 打者の水準 (質キー5本の平均 z)。テール圧縮の効き方が水準で変わるので、
# 左右差を水準帯ごとに見るときの軸に使う。
static func batter_level_z(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	var total: float = 0.0
	for key in BATTER_LEVEL_KEYS:
		total += record.z_ability(key, 0.0)
	return total / float(BATTER_LEVEL_KEYS.size())
