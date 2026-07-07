extends RefCounted
class_name PSAbilityReference

# PA モデルはもう母集団の「中立点」を参照しない(K/BB/EV/テールピボットの各定数は
# pa_probability_calculator.gd / contact_quality_model.gd / pitch_aggregate_simulator.gd /
# plate_appearance_coordinator.gd 側にただのチューニング定数として直接持たせてある。値は
# 母集団を追跡・再計算する仕組みの一部ではなく、通常の較正(LEAGUE_K_BASE 等と同じ)で
# 手動調整する対象)。
#
# このファイルは balance_report / long_autoplay_report が「まとめて较正」セッションで
# 参考にするための observational な計測(現在のプールの能力平均・テール位置)だけを提供する。
# pass/fail の判定基準は持たない。


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
		"bat_contact_z_mean": _mean_z(batters, "Bat_Barrel"),
		"bat_gap_z_mean": _mean_z(batters, "Bat_Impact"),
		"bat_hr_z_mean": _mean_composite(batters, [["Bat_Impact", 1.0], ["Bat_Loft", 0.5]]),
		"bat_avoid_k_z_mean": _mean_z(batters, "Bat_KAvoid"),
		"pit_stuff_z_mean": _mean_composite(pitchers, [["Pit_BarrelDeny", 1.0], ["Pit_ImpactLimit", 0.5]]),
		"patience_z_mean": _mean_z(batters, "Bat_BBCreate"),
		"aggression_z_mean": _mean_z(batters, "Bat_Aggression"),
		"efficiency_z_mean": _mean_z(pitchers, "Pit_Efficiency"),
		"gamecall_z_mean": _mean_z(catchers, "C_GameCall"),
		"pit_k_create_z_mean": _mean_z(pitchers, "Pit_KCreate"),
		"pit_bb_prevent_z_mean": _mean_z(pitchers, "Pit_BBPrevent"),
		"pitcher_z_mean_plus_half_stddev": _mean_plus_stddev_z(pitchers, "Pit_KCreate", 0.5),
		"pitcher_stuff_z_mean_plus_half_stddev": _mean_plus_stddev_composite(pitchers, [["Pit_BarrelDeny", 1.0], ["Pit_ImpactLimit", 0.5]], 0.5),
		"bat_hr_z_mean_plus_half_stddev": _mean_plus_stddev_composite(batters, [["Bat_Impact", 1.0], ["Bat_Loft", 0.5]], 0.5),
		"bat_avoid_k_z_mean_plus_half_stddev": _mean_plus_stddev_z(batters, "Bat_KAvoid", 0.5),
	}
	return {
		"counts": {
			"batters": batters.size(),
			"pitchers": pitchers.size(),
			"catchers": catchers.size(),
		},
		"observed": observed,
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


static func _mean_plus_stddev_z(players: Array, key: String, stddev_factor: float) -> float:
	var values: Array = []
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		values.append(player.z_ability(key, 0.0) if player != null else 0.0)
	return _mean_plus_stddev(values, stddev_factor)


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


static func _mean_plus_stddev_composite(players: Array, terms: Array, stddev_factor: float) -> float:
	var values: Array = []
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null:
			values.append(0.0)
			continue
		var value: float = 0.0
		for term_value in terms:
			var term: Array = term_value as Array
			value += player.z_ability(str(term[0]), 0.0) * float(term[1])
		values.append(value)
	return _mean_plus_stddev(values, stddev_factor)


static func _mean_plus_stddev(values: Array, stddev_factor: float) -> float:
	if values.is_empty():
		return 0.0
	var mean: float = 0.0
	for value in values:
		mean += float(value)
	mean /= float(values.size())
	var variance: float = 0.0
	for value in values:
		var delta: float = float(value) - mean
		variance += delta * delta
	variance /= float(values.size())
	return mean + sqrt(variance) * stddev_factor
