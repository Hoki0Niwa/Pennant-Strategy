extends RefCounted
class_name PSScoringHelpers

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")


# 「この場面で誰に打たせるか」(代打・保存打順の欠員補充) の比較値。
# 能力だけでなく成績の上振れ/下振れ込みで見る (表示・査定用の batting_score とは別)。
static func batter_order_score(record: PSPlayerSeasonRecord) -> int:
	return PlayerValueEvaluator.batting_score_with_form(record)


static func pitcher_order_score(record: PSPlayerSeasonRecord) -> int:
	return int(round(PSPitcherRoleModel.starter_order_score(record)))


static func maybe_injure(record: PSPlayerSeasonRecord, is_pitcher: bool, exposure: float = 1.0) -> Dictionary:
	# 怪我の発生判定・重症度ティア・部位名・(まれな)恒久能力低下は PSInjuryModel が持つ。
	return PSInjuryModel.maybe_injure(record, is_pitcher, exposure)


static func maybe_injure_for_setup(setup: Dictionary, record: PSPlayerSeasonRecord, is_pitcher: bool, exposure: float = 1.0) -> Dictionary:
	var injury: Dictionary = maybe_injure(record, is_pitcher, exposure)
	if injury.is_empty() or record == null:
		return injury
	var events: Array = setup.get("injury_events", []) as Array
	var event: Dictionary = injury.duplicate(true)
	event["player_id"] = record.player_id
	event["team_id"] = int(setup.get("team_id", record.team_id))
	event["is_pitcher"] = is_pitcher
	event["injury_days"] = record.injury_days
	events.append(event)
	setup["injury_events"] = events
	return injury


static func drain_injury_events(setup: Dictionary) -> Array:
	var events: Array = (setup.get("injury_events", []) as Array).duplicate(true)
	setup["injury_events"] = []
	return events
