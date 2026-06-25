extends RefCounted
class_name PSPlayerVisibleRatings

# UI / reports 用の表示能力をここに集約する。
# 打席シミュレーション本体は z_abilities を直接使い、ここには依存しない。
const MIN_RATING: int = 1
const MAX_RATING: int = 100


static func ratings_for_record(record: PSPlayerSeasonRecord) -> Dictionary:
	if record == null:
		return _display_rating_result("none", [])
	if record.is_pitcher():
		return pitcher_ratings(record)
	return fielder_ratings(record)


static func ratings_for_player(player: PSPlayer) -> Dictionary:
	if player == null:
		return _display_rating_result("none", [])
	return ratings_for_record(PSPlayerSeasonRecord.from_player(player, 0, 0))


static func ratings_for_player_data(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return _display_rating_result("none", [])
	return ratings_for_player(PSPlayer.from_dict(data))


static func fielder_ratings(record: PSPlayerSeasonRecord) -> Dictionary:
	return _display_rating_result("fielder", [
		{"key": "contact", "label": "巧打", "display_value": fielder_contact(record)},
		{"key": "power", "label": "長打", "display_value": fielder_power(record)},
		{"key": "speed", "label": "走力", "display_value": fielder_speed(record)},
		{"key": "defense", "label": "守備", "display_value": fielder_defense(record)},
		{"key": "arm", "label": "肩力", "display_value": fielder_arm(record)},
		{"key": "discipline", "label": "選球", "display_value": fielder_discipline(record)},
	])


static func pitcher_ratings(record: PSPlayerSeasonRecord) -> Dictionary:
	return _display_rating_result("pitcher", [
		{"key": "velocity", "label": "球速", "display_value": pitcher_velocity(record), "suffix": "km/h"},
		{"key": "stuff", "label": "球質", "display_value": pitcher_stuff(record)},
		{"key": "control", "label": "制球", "display_value": pitcher_control(record)},
		{"key": "stamina", "label": "持久", "display_value": pitcher_stamina(record)},
	])


static func summary_line(record: PSPlayerSeasonRecord) -> String:
	var result: Dictionary = ratings_for_record(record)
	return summary_line_from_result(result)


static func summary_line_for_player_data(data: Dictionary) -> String:
	return summary_line_from_result(ratings_for_player_data(data))


static func summary_line_from_result(result: Dictionary) -> String:
	var ratings: Array = result.get("display_ratings", result.get("ratings", [])) as Array
	var parts: Array = []
	for row_value in ratings:
		var row: Dictionary = row_value as Dictionary
		var suffix: String = str(row.get("suffix", ""))
		var display_value: int = int(row.get("display_value", row.get("value", 0)))
		parts.append("%s %d%s" % [str(row.get("label", "")), display_value, suffix])
	return "  ".join(parts)


static func fielder_contact(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Bat_Barrel", "Bat_KAvoid", "Bat_BBCreate", "Bat_Spray", "Bat_Platoon"]):
		return _display_from_weighted_z(record, {
			"Bat_Barrel": 0.46,
			"Bat_KAvoid": 0.24,
			"Bat_BBCreate": 0.12,
			"Bat_Spray": 0.08,
			"Bat_Platoon": 0.06,
			"Bat_Aggression": -0.04,
		})
	return record.z_display("Bat_Barrel")


static func fielder_power(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Bat_Impact", "Bat_Loft", "Bat_Barrel", "Bat_Aggression", "Bat_Spray"]):
		return _display_from_weighted_z(record, {
			"Bat_Impact": 0.50,
			"Bat_Loft": 0.24,
			"Bat_Barrel": 0.10,
			"Bat_Aggression": 0.08,
			"Bat_Spray": 0.04,
			"Bat_Platoon": 0.04,
		})
	return record.z_display("Bat_Impact")


static func fielder_speed(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Run_Speed", "Run_Judgment", "Run_Steal"]):
		return _display_from_weighted_z(record, {
			"Run_Speed": 0.64,
			"Run_Judgment": 0.22,
			"Run_Steal": 0.14,
		})
	return record.z_display("Run_Speed")


static func fielder_defense(record: PSPlayerSeasonRecord) -> int:
	match record.position:
		2:
			return _display_from_weighted_z_or_default(record, {
				"C_Blocking": 0.25,
				"C_FieldSecure": 0.24,
				"C_Framing": 0.20,
				"C_GameCall": 0.16,
				"C_Throw": 0.15,
			}, 60)
		3, 4, 5, 6:
			return _display_from_weighted_z_or_default(record, {
				"IF_Reach": 0.25,
				"IF_Secure": 0.24,
				"IF_ThrowAccuracy": 0.16,
				"IF_Exchange": 0.15,
				"IF_PositionFit": 0.10,
				"IF_ThrowPower": 0.10,
			}, 60)
		7, 8, 9:
			return _display_from_weighted_z_or_default(record, {
				"OF_Reach": 0.24,
				"OF_Route": 0.20,
				"OF_Secure": 0.20,
				"OF_Release": 0.12,
				"OF_PositionFit": 0.10,
				"OF_ArmAccuracy": 0.09,
				"OF_ArmPower": 0.05,
			}, 60)
	return _display_from_weighted_z_or_default(record, {"IF_Reach": 0.5, "IF_Secure": 0.5}, 60)


static func fielder_arm(record: PSPlayerSeasonRecord) -> int:
	match record.position:
		2:
			return _display_from_weighted_z_or_default(record, {
				"C_Throw": 0.54,
				"C_FieldSecure": 0.16,
				"C_GameCall": 0.12,
				"C_Blocking": 0.10,
				"C_Framing": 0.08,
			}, 60)
		3, 4, 5, 6:
			return _display_from_weighted_z_or_default(record, {
				"IF_ThrowPower": 0.44,
				"IF_ThrowAccuracy": 0.25,
				"IF_Exchange": 0.15,
				"IF_Reach": 0.10,
				"IF_PositionFit": 0.06,
			}, 60)
		7, 8, 9:
			return _display_from_weighted_z_or_default(record, {
				"OF_ArmPower": 0.44,
				"OF_ArmAccuracy": 0.25,
				"OF_Release": 0.16,
				"OF_Route": 0.09,
				"OF_PositionFit": 0.06,
			}, 60)
	return _display_from_weighted_z_or_default(record, {"IF_ThrowPower": 0.6, "IF_ThrowAccuracy": 0.4}, 60)


static func fielder_discipline(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Bat_BBCreate", "Bat_KAvoid", "Bat_Aggression", "Bat_Platoon", "Bat_Spray"]):
		return _display_from_weighted_z(record, {
			"Bat_BBCreate": 0.42,
			"Bat_KAvoid": 0.22,
			"Bat_Platoon": 0.12,
			"Bat_Spray": 0.08,
			"Bat_Barrel": 0.06,
			"Bat_Aggression": -0.10,
		})
	return record.z_display("Bat_BBCreate")


static func pitcher_velocity(record: PSPlayerSeasonRecord) -> int:
	var max_velocity: int = record.max_velocity_display()
	if max_velocity > 0:
		return max_velocity
	if _has_z(record, "Pit_KCreate"):
		return 70 + _display_from_z(record, "Pit_KCreate")
	return 70 + record.z_display("Pit_KCreate")


static func pitcher_stuff(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Pit_KCreate", "Pit_ImpactLimit", "Pit_BarrelDeny", "Pit_LoftControl", "Pit_EdgeRate"]):
		var stuff_z: float = _weighted_z(record, {
			"Pit_KCreate": 0.32,
			"Pit_ImpactLimit": 0.20,
			"Pit_BarrelDeny": 0.18,
			"Pit_LoftControl": 0.10,
			"Pit_EdgeRate": 0.10,
			"Pit_Efficiency": 0.05,
			"Pit_BBPrevent": 0.05,
		})
		stuff_z += _velocity_z(record) * 0.06
		return _clamp_rating(PSAbilityScale.z_to_display(stuff_z))
	return record.z_display("Pit_KCreate")


static func pitcher_control(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Pit_BBPrevent", "Pit_Efficiency", "Pit_EdgeRate", "Pit_HoldRunner"]):
		return _display_from_weighted_z(record, {
			"Pit_BBPrevent": 0.44,
			"Pit_Efficiency": 0.20,
			"Pit_EdgeRate": 0.16,
			"Pit_HoldRunner": 0.08,
			"Pit_FatigueResist": 0.06,
			"Pit_KCreate": 0.06,
		})
	return record.z_display("Pit_BBPrevent")


static func pitcher_stamina(record: PSPlayerSeasonRecord) -> int:
	if _has_any_z(record, ["Pit_Stamina", "Pit_FatigueResist", "Pit_Efficiency", "Pit_HoldRunner"]):
		return _display_from_weighted_z(record, {
			"Pit_Stamina": 0.44,
			"Pit_FatigueResist": 0.30,
			"Pit_Efficiency": 0.10,
			"Pit_HoldRunner": 0.10,
			"Pit_BBPrevent": 0.06,
		})
	return record.z_display("Pit_Stamina")


static func _has_z(record: PSPlayerSeasonRecord, key: String) -> bool:
	return record != null and record.z_abilities_snapshot.has(key)


static func _has_any_z(record: PSPlayerSeasonRecord, keys: Array) -> bool:
	if record == null:
		return false
	for key_value in keys:
		if record.z_abilities_snapshot.has(str(key_value)):
			return true
	return false


static func _display_from_z(record: PSPlayerSeasonRecord, key: String) -> int:
	return PSAbilityScale.z_to_display(record.z_ability(key, 0.0))


static func _display_from_weighted_z(record: PSPlayerSeasonRecord, weights: Dictionary) -> int:
	return _clamp_rating(PSAbilityScale.z_to_display(_weighted_z(record, weights)))


static func _display_from_weighted_z_or_default(record: PSPlayerSeasonRecord, weights: Dictionary, default_value: int) -> int:
	if _has_any_z(record, weights.keys()):
		return _display_from_weighted_z(record, weights)
	return default_value


static func _weighted_z(record: PSPlayerSeasonRecord, weights: Dictionary) -> float:
	if record == null:
		return 0.0
	var weighted_sum: float = 0.0
	var total_weight: float = 0.0
	for key_value in weights.keys():
		var key: String = str(key_value)
		var weight: float = float(weights.get(key_value, 0.0))
		weighted_sum += record.z_ability(key, 0.0) * weight
		total_weight += absf(weight)
	if total_weight <= 0.0:
		return 0.0
	return weighted_sum / total_weight


static func _velocity_z(record: PSPlayerSeasonRecord) -> float:
	var velocity: float = float(record.max_velocity_display())
	if velocity <= 0.0:
		return 0.0
	return clamp((velocity - 145.0) / 8.0, -3.0, 3.0)


static func _clamp_rating(value: float) -> int:
	return clampi(int(round(value)), MIN_RATING, MAX_RATING)


static func _display_rating_result(kind: String, display_ratings: Array) -> Dictionary:
	var rows: Array = []
	for rating_value in display_ratings:
		var row: Dictionary = (rating_value as Dictionary).duplicate(true)
		if not row.has("display_value"):
			row["display_value"] = int(row.get("value", 0))
		if not row.has("value"):
			row["value"] = int(row.get("display_value", 0))
		rows.append(row)
	return {
		"kind": kind,
		"display_ratings": rows,
		"ratings": rows,
	}
