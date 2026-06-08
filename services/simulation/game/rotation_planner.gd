extends RefCounted
class_name PSRotationPlanner

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")

const ROTATION_SIZE_MAX: int = 6
const MIN_STARTER_REST_DAYS: int = 4
const STARTER_DANGER_FATIGUE: int = 145


static func resolve_rotation_decision(season: PSSeason, team_id: int, starter_pitchers: Array, team_record: PSTeamSeasonRecord) -> Dictionary:
	var saved: Dictionary = season.get_rotation(team_id) if season != null else {}
	var rotation: Array = resolve_rotation_order_from_saved(saved, starter_pitchers)
	if rotation.is_empty():
		return {
			"pitcher": null,
			"order": [],
			"order_ids": [],
			"selected_index": -1,
			"next_rotation_index": 0,
			"reason": "empty",
		}

	var rotation_size: int = rotation.size()
	var current_day: int = 1 if season == null else season.current_day
	var next_index: int = _next_rotation_index(saved, rotation_size, team_record)
	var last_starts: Dictionary = saved.get("last_start_day_by_pitcher", {}) as Dictionary
	var manual_skips: Dictionary = _id_set(saved.get("manual_skip_pitcher_ids", []) as Array)

	var chosen: Dictionary = _first_rotation_candidate(rotation, next_index, current_day, last_starts, manual_skips, true, true, true)
	if chosen.is_empty():
		chosen = _first_rotation_candidate(rotation, next_index, current_day, last_starts, manual_skips, true, false, true)
	if chosen.is_empty():
		chosen = _spot_starter_candidate(saved, starter_pitchers, current_day, last_starts)
	if chosen.is_empty():
		chosen = _best_emergency_starter(rotation, current_day, last_starts)

	var pitcher: PSPlayerSeasonRecord = chosen.get("pitcher", null) as PSPlayerSeasonRecord
	return {
		"pitcher": pitcher,
		"order": rotation,
		"order_ids": _record_ids(rotation),
		"selected_index": int(chosen.get("index", -1)),
		"next_rotation_index": next_index,
		"reason": str(chosen.get("reason", "")),
	}


static func record_rotation_start(season: PSSeason, team_id: int, setup: Dictionary, day: int) -> void:
	if season == null or team_id <= 0:
		return
	var starter: PSPlayerSeasonRecord = setup.get("starter_pitcher", setup.get("pitcher", null)) as PSPlayerSeasonRecord
	if starter == null:
		return
	var stored: Dictionary = season.get_rotation(team_id).duplicate(true)
	var order_ids: Array = (setup.get("rotation_order_ids", []) as Array).duplicate()
	if order_ids.is_empty():
		order_ids = (stored.get("pitcher_ids", []) as Array).duplicate()
	if (stored.get("pitcher_ids", []) as Array).is_empty() and not order_ids.is_empty():
		stored["pitcher_ids"] = order_ids
		stored["auto_generated"] = true

	var selected_index: int = int(setup.get("rotation_selected_index", -1))
	if selected_index < 0 and not order_ids.is_empty():
		selected_index = order_ids.find(starter.player_id)
	if selected_index >= 0 and not order_ids.is_empty():
		stored["next_rotation_index"] = (selected_index + 1) % order_ids.size()

	var last_starts: Dictionary = (stored.get("last_start_day_by_pitcher", {}) as Dictionary).duplicate(true)
	last_starts[str(starter.player_id)] = day
	stored["last_start_day_by_pitcher"] = last_starts
	stored["last_start_pitcher_id"] = starter.player_id
	stored["last_start_day"] = day

	var manual_skips: Array = (stored.get("manual_skip_pitcher_ids", []) as Array).duplicate()
	if manual_skips.has(starter.player_id):
		manual_skips.erase(starter.player_id)
		stored["manual_skip_pitcher_ids"] = manual_skips

	season.set_rotation(team_id, stored)


static func resolve_rotation_order_from_saved(saved: Dictionary, starter_pitchers: Array) -> Array:
	if starter_pitchers.is_empty():
		return []
	var by_id: Dictionary = {}
	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		by_id[pitcher.player_id] = pitcher

	var rotation: Array = []
	var used: Dictionary = {}
	var saved_ids: Array = saved.get("pitcher_ids", []) as Array
	for id_value in saved_ids:
		var pid: int = int(id_value)
		if pid <= 0 or not by_id.has(pid) or used.has(pid):
			continue
		var pitcher: PSPlayerSeasonRecord = by_id[pid] as PSPlayerSeasonRecord
		if pitcher.injury_days > 0:
			continue
		rotation.append(pitcher)
		used[pid] = true

	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if used.has(pitcher.player_id):
			continue
		rotation.append(pitcher)
		if rotation.size() >= ROTATION_SIZE_MAX:
			break

	return rotation


static func _next_rotation_index(saved: Dictionary, rotation_size: int, team_record: PSTeamSeasonRecord) -> int:
	if rotation_size <= 0:
		return 0
	if saved.has("next_rotation_index"):
		return posmod(int(saved.get("next_rotation_index", 0)), rotation_size)
	var games_played: int = 0 if team_record == null else team_record.stats.games
	return posmod(games_played, rotation_size)


static func _first_rotation_candidate(
	rotation: Array,
	next_index: int,
	current_day: int,
	last_starts: Dictionary,
	manual_skips: Dictionary,
	require_rest: bool,
	require_fatigue: bool,
	honor_manual_skip: bool
) -> Dictionary:
	for offset in range(rotation.size()):
		var index: int = (next_index + offset) % rotation.size()
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if not _can_start_pitcher(pitcher, current_day, last_starts, require_rest, require_fatigue):
			continue
		if honor_manual_skip and manual_skips.has(pitcher.player_id):
			continue
		return {"pitcher": pitcher, "index": index, "reason": "rotation"}
	return {}


static func _spot_starter_candidate(saved: Dictionary, starter_pitchers: Array, current_day: int, last_starts: Dictionary) -> Dictionary:
	var spot_id: int = int(saved.get("spot_starter_id", 0))
	if spot_id <= 0:
		return {}
	for pitcher_row in starter_pitchers:
		var pitcher: PSPlayerSeasonRecord = pitcher_row as PSPlayerSeasonRecord
		if pitcher == null or pitcher.player_id != spot_id:
			continue
		if _can_start_pitcher(pitcher, current_day, last_starts, true, true):
			return {"pitcher": pitcher, "index": -1, "reason": "spot"}
	return {}


static func _best_emergency_starter(rotation: Array, current_day: int, last_starts: Dictionary) -> Dictionary:
	var best: PSPlayerSeasonRecord = null
	var best_index: int = -1
	var best_score: float = -999999.0
	for index in range(rotation.size()):
		var pitcher: PSPlayerSeasonRecord = rotation[index] as PSPlayerSeasonRecord
		if pitcher == null or pitcher.injury_days > 0:
			continue
		var score: float = _emergency_start_score(pitcher, current_day, last_starts)
		if best == null or score > best_score:
			best = pitcher
			best_index = index
			best_score = score
	if best == null:
		return {}
	return {"pitcher": best, "index": best_index, "reason": "emergency"}


static func _can_start_pitcher(
	pitcher: PSPlayerSeasonRecord,
	current_day: int,
	last_starts: Dictionary,
	require_rest: bool,
	require_fatigue: bool
) -> bool:
	if pitcher == null or pitcher.injury_days > 0:
		return false
	if require_fatigue and pitcher.fatigue >= STARTER_DANGER_FATIGUE:
		return false
	if require_rest and not _has_minimum_rest(pitcher, current_day, last_starts):
		return false
	return true


static func _has_minimum_rest(pitcher: PSPlayerSeasonRecord, current_day: int, last_starts: Dictionary) -> bool:
	if pitcher == null:
		return false
	var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
	if last_day <= 0:
		return true
	return current_day - last_day > MIN_STARTER_REST_DAYS


static func _emergency_start_score(pitcher: PSPlayerSeasonRecord, current_day: int, last_starts: Dictionary) -> float:
	var last_day: int = int(last_starts.get(str(pitcher.player_id), 0))
	var rest_days: int = 999 if last_day <= 0 else max(0, current_day - last_day - 1)
	var rest_score: float = float(min(rest_days, 10)) * 18.0
	return rest_score + float(PlayerValueEvaluator.pitching_score_without_fatigue(pitcher)) - float(pitcher.fatigue) * 1.7


static func _record_ids(records: Array) -> Array:
	var ids: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record != null:
			ids.append(record.player_id)
	return ids


static func _id_set(ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for id_value in ids:
		out[int(id_value)] = true
	return out


static func select_relievers_for_innings(reliever_pool: Array, starter_pool_fallback: Array, exclude_pitcher_id: int) -> Array:
	var eligible: Array = []
	for r in reliever_pool:
		var pitcher: PSPlayerSeasonRecord = r as PSPlayerSeasonRecord
		if pitcher.player_id == exclude_pitcher_id or pitcher.injury_days > 0:
			continue
		eligible.append(pitcher)
	eligible.sort_custom(func(a, b) -> bool:
		return PlayerValueEvaluator.pitching_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.pitching_score(b as PSPlayerSeasonRecord)
	)
	var top6: Array = []
	for i in range(int(min(6, eligible.size()))):
		top6.append(eligible[i])
	if top6.size() < 6:
		var used_ids: Dictionary = {}
		for p in top6:
			used_ids[(p as PSPlayerSeasonRecord).player_id] = true
		used_ids[exclude_pitcher_id] = true
		var fallback: Array = []
		for p in starter_pool_fallback:
			var pitcher: PSPlayerSeasonRecord = p as PSPlayerSeasonRecord
			if used_ids.has(pitcher.player_id) or pitcher.injury_days > 0:
				continue
			fallback.append(pitcher)
		fallback.sort_custom(func(a, b) -> bool:
			return PlayerValueEvaluator.pitching_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.pitching_score(b as PSPlayerSeasonRecord)
		)
		for p in fallback:
			if top6.size() >= 6:
				break
			top6.append(p)
	# top6 は overall 降順 [最強, 2番手, 3番手, 4番手, 5番手, 6番手]。
	# 出力順: [7回, 8回, 9回, 10回, 11回, 12回] = [3番手, 2番手, 最強, 4番手, 5番手, 6番手]
	var ordered: Array = []
	var top3: Array = top6.slice(0, int(min(3, top6.size())))
	top3.reverse()
	ordered.append_array(top3)
	if top6.size() > 3:
		ordered.append_array(top6.slice(3))
	return ordered
