extends RefCounted
class_name PSSeasonReview

const FORMAT_VERSION: int = 1
var _payload: Dictionary = {}
var year: int:
	get: return int(_payload.get("year", 0))
var season_number: int:
	get: return int(_payload.get("season_number", 1))
var format_version: int:
	get: return int(_payload.get("format_version", FORMAT_VERSION))
var teams: Array:
	get: return (_payload.get("teams", []) as Array).duplicate(true)
var player_facts: Array:
	get: return (_payload.get("player_facts", []) as Array).duplicate(true)
var completion_kind: String:
	get: return str(_payload.get("completion_kind", "regular_season"))


func to_dict() -> Dictionary:
	return _payload.duplicate(true)


static func from_dict(data: Dictionary) -> PSSeasonReview:
	var review: PSSeasonReview = PSSeasonReview.new()
	review._payload = data.duplicate(true)
	review._payload["format_version"] = int(data.get("format_version", FORMAT_VERSION))
	return review
