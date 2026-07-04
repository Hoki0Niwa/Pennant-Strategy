extends RefCounted
class_name PSAbilityReference

# PA シミュレーションが「平均的な能力」として扱う固定リファレンス母平均。
# リーグ平均との差し替えはせず、同じ能力値の対戦結果を同じ入力で安定させる。

const BAT_CONTACT_Z_NEUTRAL: float = 1.1432      # Bat_Barrel の野手平均。
const BAT_GAP_Z_NEUTRAL: float = 1.4929          # Bat_Impact の野手平均。
const BAT_HR_Z_NEUTRAL: float = 2.1865           # Bat_Impact + 0.5 * Bat_Loft の野手平均。
const BAT_AVOID_K_Z_NEUTRAL: float = 0.8297      # Bat_KAvoid の野手平均。
const PIT_STUFF_Z_NEUTRAL: float = 1.5427        # Pit_BarrelDeny + 0.5 * Pit_ImpactLimit の投手平均。
const PATIENCE_Z_NEUTRAL: float = 0.9772         # Bat_BBCreate の野手平均。
const AGGRESSION_Z_NEUTRAL: float = 0.3090       # Bat_Aggression の野手平均。
const EFFICIENCY_Z_NEUTRAL: float = 1.0287       # Pit_Efficiency の投手平均。
const GAMECALL_Z_NEUTRAL: float = 2.3417         # 一軍捕手候補の C_GameCall 平均。
const PITCHER_TAIL_PIVOT: float = 1.6722         # Pit_KCreate 平均 + 0.5σ。

const DRIFT_WARN_ABS: float = 0.25
const DRIFT_FAIL_ABS: float = 0.50


static func reference_values() -> Dictionary:
	return {
		"bat_contact_z_neutral": BAT_CONTACT_Z_NEUTRAL,
		"bat_gap_z_neutral": BAT_GAP_Z_NEUTRAL,
		"bat_hr_z_neutral": BAT_HR_Z_NEUTRAL,
		"bat_avoid_k_z_neutral": BAT_AVOID_K_Z_NEUTRAL,
		"pit_stuff_z_neutral": PIT_STUFF_Z_NEUTRAL,
		"patience_z_neutral": PATIENCE_Z_NEUTRAL,
		"aggression_z_neutral": AGGRESSION_Z_NEUTRAL,
		"efficiency_z_neutral": EFFICIENCY_Z_NEUTRAL,
		"gamecall_z_neutral": GAMECALL_Z_NEUTRAL,
		"pitcher_tail_pivot": PITCHER_TAIL_PIVOT,
	}


static func pool_snapshot(players: Array) -> Dictionary:
	var batters: Array = []
	var pitchers: Array = []
	var catchers: Array = []
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.is_retired():
			continue
		if player.is_pitcher():
			pitchers.append(player)
		else:
			batters.append(player)
			if _is_catcher(player):
				catchers.append(player)
	var observed: Dictionary = {
		"bat_contact_z_neutral": _mean_z(batters, "Bat_Barrel"),
		"bat_gap_z_neutral": _mean_z(batters, "Bat_Impact"),
		"bat_hr_z_neutral": _mean_composite(batters, [["Bat_Impact", 1.0], ["Bat_Loft", 0.5]]),
		"bat_avoid_k_z_neutral": _mean_z(batters, "Bat_KAvoid"),
		"pit_stuff_z_neutral": _mean_composite(pitchers, [["Pit_BarrelDeny", 1.0], ["Pit_ImpactLimit", 0.5]]),
		"patience_z_neutral": _mean_z(batters, "Bat_BBCreate"),
		"aggression_z_neutral": _mean_z(batters, "Bat_Aggression"),
		"efficiency_z_neutral": _mean_z(pitchers, "Pit_Efficiency"),
		"gamecall_z_neutral": _mean_z(catchers, "C_GameCall"),
	}
	var reference: Dictionary = reference_values()
	var delta: Dictionary = {}
	for key in observed.keys():
		delta[key] = float(observed.get(key, 0.0)) - float(reference.get(key, 0.0))
	return {
		"counts": {
			"batters": batters.size(),
			"pitchers": pitchers.size(),
			"catchers": catchers.size(),
		},
		"reference": reference,
		"observed": observed,
		"delta": delta,
	}


static func _is_catcher(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.position == 2:
		return true
	return int(player.position_aptitudes.get("catcher", 0)) > 0


static func _mean_z(players: Array, key: String) -> float:
	if players.is_empty():
		return 0.0
	var total: float = 0.0
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		total += player.z_ability(key, 0.0) if player != null else 0.0
	return total / float(players.size())


static func _mean_composite(players: Array, terms: Array) -> float:
	if players.is_empty():
		return 0.0
	var total: float = 0.0
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null:
			continue
		var value: float = 0.0
		for term_value in terms:
			var term: Array = term_value as Array
			value += player.z_ability(str(term[0]), 0.0) * float(term[1])
		total += value
	return total / float(players.size())
