extends RefCounted
class_name PSDraftClass

const FORMAT_VERSION: int = 1
var _payload: Dictionary = {}
var year: int:
	get: return int(_payload.get("year", 0))
var season_number: int:
	get: return int(_payload.get("season_number", 1))
var format_version: int:
	get: return int(_payload.get("format_version", FORMAT_VERSION))
var picks: Array:
	get: return (_payload.get("picks", []) as Array).duplicate(true)
var teams: Array:
	get: return (_payload.get("teams", []) as Array).duplicate(true)


func to_dict() -> Dictionary:
	return _payload.duplicate(true)


static func from_dict(data: Dictionary) -> PSDraftClass:
	var draft_class: PSDraftClass = PSDraftClass.new()
	draft_class._payload = data.duplicate(true)
	draft_class._payload["format_version"] = int(data.get("format_version", FORMAT_VERSION))
	return draft_class
