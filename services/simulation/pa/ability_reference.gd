extends RefCounted
class_name PSAbilityReference

# PA シミュレーションが「平均的な能力」として扱う固定リファレンス母平均。
# リーグ平均との差し替えはせず、同じ能力値の対戦結果を同じ入力で安定させる。
# 値は initial_players.csv の母集団スナップショット。シード世界を再生成 (オプション画面の
# 書き出し / run_export_seed_world) したら再スナップショットが必要 (drift テストが検知する)。
# 現行値は 2026-07-06 23:28 再生成世界 (FA日数台帳修正後の再エクスポート、野手453/投手425/捕手90) の実測。

const BAT_CONTACT_Z_NEUTRAL: float = 0.9995      # Bat_Barrel の野手平均。
const BAT_GAP_Z_NEUTRAL: float = 1.3568          # Bat_Impact の野手平均。
const BAT_HR_Z_NEUTRAL: float = 2.0017           # Bat_Impact + 0.5 * Bat_Loft の野手平均。
const BAT_AVOID_K_Z_NEUTRAL: float = 0.7213      # Bat_KAvoid の野手平均。
const PIT_STUFF_Z_NEUTRAL: float = 1.5804        # Pit_BarrelDeny + 0.5 * Pit_ImpactLimit の投手平均。
const PATIENCE_Z_NEUTRAL: float = 0.8291         # Bat_BBCreate の野手平均。
const AGGRESSION_Z_NEUTRAL: float = 0.2957       # Bat_Aggression の野手平均。
const EFFICIENCY_Z_NEUTRAL: float = 1.0177       # Pit_Efficiency の投手平均。
const GAMECALL_Z_NEUTRAL: float = 2.4021         # 一軍捕手候補の C_GameCall 平均。
const PIT_K_CREATE_Z_NEUTRAL: float = 1.4096     # Pit_KCreate の投手平均。K/BB確率モデルの中立点。
const PIT_BB_PREVENT_Z_NEUTRAL: float = 1.3151   # Pit_BBPrevent の投手平均。K/BB確率モデルの中立点。
const PITCHER_TAIL_PIVOT: float = 1.7843         # Pit_KCreate の高能力テール圧縮開始点。
const PITCHER_STUFF_TAIL_PIVOT: float = 2.0684   # Pit_BarrelDeny + 0.5 * Pit_ImpactLimit の高能力テール圧縮開始点。
const BAT_HR_TAIL_PIVOT: float = 2.6190          # Bat_Impact + 0.5 * Bat_Loft の高能力テール圧縮開始点。
const BAT_AVOID_K_TAIL_PIVOT: float = 1.1550     # Bat_KAvoid の高能力テール圧縮開始点。

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
		"pit_k_create_z_neutral": PIT_K_CREATE_Z_NEUTRAL,
		"pit_bb_prevent_z_neutral": PIT_BB_PREVENT_Z_NEUTRAL,
		"pitcher_tail_pivot": PITCHER_TAIL_PIVOT,
		"pitcher_stuff_tail_pivot": PITCHER_STUFF_TAIL_PIVOT,
		"bat_hr_tail_pivot": BAT_HR_TAIL_PIVOT,
		"bat_avoid_k_tail_pivot": BAT_AVOID_K_TAIL_PIVOT,
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
		"pit_k_create_z_neutral": _mean_z(pitchers, "Pit_KCreate"),
		"pit_bb_prevent_z_neutral": _mean_z(pitchers, "Pit_BBPrevent"),
		"pitcher_tail_pivot": _mean_plus_stddev_z(pitchers, "Pit_KCreate", 0.5),
		"pitcher_stuff_tail_pivot": _mean_plus_stddev_composite(pitchers, [["Pit_BarrelDeny", 1.0], ["Pit_ImpactLimit", 0.5]], 0.5),
		"bat_hr_tail_pivot": _mean_plus_stddev_composite(batters, [["Bat_Impact", 1.0], ["Bat_Loft", 0.5]], 0.5),
		"bat_avoid_k_tail_pivot": _mean_plus_stddev_z(batters, "Bat_KAvoid", 0.5),
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
