extends RefCounted
class_name PSPostseasonResult

const STAGE_KEYS: Array = ["cs1_central", "cs1_pacific", "cs2_central", "cs2_pacific", "japan_series"]

var year: int
var season_number: int
var cs1_central: Dictionary = {}
var cs1_pacific: Dictionary = {}
var cs2_central: Dictionary = {}
var cs2_pacific: Dictionary = {}
var japan_series: Dictionary = {}
var champion_team_id: int = 0


static func make_pending_series(top_id: int, challenger_id: int, win_target: int, advantage_wins: int) -> Dictionary:
	return {
		"top_id": top_id,
		"challenger_id": challenger_id,
		"win_target": win_target,
		"advantage_wins": advantage_wins,
		"games": [],
		"winner_id": 0,
		"completed": false,
	}


func stage_dict(stage_key: String) -> Dictionary:
	match stage_key:
		"cs1_central": return cs1_central
		"cs1_pacific": return cs1_pacific
		"cs2_central": return cs2_central
		"cs2_pacific": return cs2_pacific
		"japan_series": return japan_series
		_: return {}


func set_stage(stage_key: String, dict: Dictionary) -> void:
	match stage_key:
		"cs1_central": cs1_central = dict
		"cs1_pacific": cs1_pacific = dict
		"cs2_central": cs2_central = dict
		"cs2_pacific": cs2_pacific = dict
		"japan_series": japan_series = dict


func next_pending_stage() -> String:
	for key in STAGE_KEYS:
		var s: Dictionary = stage_dict(key)
		if s.is_empty():
			continue
		if not bool(s.get("completed", false)):
			return key
	return ""


func is_complete() -> bool:
	return bool(japan_series.get("completed", false)) and int(japan_series.get("winner_id", 0)) > 0


func to_dict() -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		"cs1_central": cs1_central,
		"cs1_pacific": cs1_pacific,
		"cs2_central": cs2_central,
		"cs2_pacific": cs2_pacific,
		"japan_series": japan_series,
		"champion_team_id": champion_team_id,
	}


static func from_dict(data: Dictionary) -> PSPostseasonResult:
	var result: PSPostseasonResult = PSPostseasonResult.new()
	result.year = int(data.get("year", 0))
	result.season_number = int(data.get("season_number", 1))
	result.cs1_central = (data.get("cs1_central", {}) as Dictionary).duplicate(true)
	result.cs1_pacific = (data.get("cs1_pacific", {}) as Dictionary).duplicate(true)
	result.cs2_central = (data.get("cs2_central", {}) as Dictionary).duplicate(true)
	result.cs2_pacific = (data.get("cs2_pacific", {}) as Dictionary).duplicate(true)
	result.japan_series = (data.get("japan_series", {}) as Dictionary).duplicate(true)
	result.champion_team_id = int(data.get("champion_team_id", 0))
	return result
