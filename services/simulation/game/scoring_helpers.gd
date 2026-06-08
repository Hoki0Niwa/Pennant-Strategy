extends RefCounted
class_name PSScoringHelpers

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")


static func batter_order_score(record: PSPlayerSeasonRecord) -> int:
	return PlayerValueEvaluator.batting_score(record)


static func pitcher_order_score(record: PSPlayerSeasonRecord) -> int:
	return PlayerValueEvaluator.pitching_score(record)


static func maybe_injure(record: PSPlayerSeasonRecord, is_pitcher: bool, exposure: float = 1.0) -> void:
	if record.injury_days > 0:
		return
	var base_chance: float = 0.003 if is_pitcher else 0.001
	var fatigue_chance: float = float(record.fatigue) * (0.00006 if is_pitcher else 0.000035)
	var exposure_scale: float = clamp(exposure, 0.0, 2.0)
	if Rng.roll_float() < (base_chance + fatigue_chance) * exposure_scale:
		var days: int = Rng.range_int(3, 20)
		record.injury_days = days
		record.injury_return_day = 0
		record.season_injury_days += days
