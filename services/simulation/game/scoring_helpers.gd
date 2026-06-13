extends RefCounted
class_name PSScoringHelpers

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")


static func batter_order_score(record: PSPlayerSeasonRecord) -> int:
	return PlayerValueEvaluator.batting_score(record)


static func pitcher_order_score(record: PSPlayerSeasonRecord) -> int:
	return int(round(PSPitcherRoleModel.starter_order_score(record)))


static func maybe_injure(record: PSPlayerSeasonRecord, is_pitcher: bool, exposure: float = 1.0) -> void:
	# 怪我の発生判定・重症度ティア・部位名・(まれな)恒久能力低下は PSInjuryModel に集約 (roadmap #6)。
	PSInjuryModel.maybe_injure(record, is_pitcher, exposure)
