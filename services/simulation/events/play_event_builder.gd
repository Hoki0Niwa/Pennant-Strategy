extends RefCounted
class_name PSPlayEventBuilder

const RunnerActionModel = preload("res://services/simulation/models/runner_action_model.gd")
const FieldingModel = preload("res://services/simulation/models/fielding_model.gd")

const EVENT_TYPE_PLAY: String = "play"
const EVENT_TYPE_PLATE_APPEARANCE: String = "plate_appearance"
const EVENT_TYPE_BATTED_BALL: String = "batted_ball"
const EVENT_TYPE_RUNNER_EVENT: String = "runner_event"
const EVENT_TYPE_RUNNER_INTENT: String = "runner_intent"

const VISIBILITY_OBSCURED_BY_BATTED_BALL: String = "obscured_by_batted_ball"
const CATEGORY_WALK: String = "walk"
const CATEGORY_HIT_BY_PITCH: String = "hit_by_pitch"
const CATEGORY_STRIKEOUT: String = "strikeout"


static func build_play_event(
	event_index: int,
	inning: int,
	half: String,
	offense: Dictionary,
	defense: Dictionary,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	outcome: Dictionary,
	bases_after: Array,
	outs_after: int,
	runs_scored: int,
	runner_events: Array = [],
	pitch_summary: Dictionary = {}
) -> Dictionary:
	var resolved_pitch_summary: Dictionary = pitch_summary
	if resolved_pitch_summary.is_empty():
		resolved_pitch_summary = _pitch_summary(event_index, batter, pitcher, outcome)
	var play_event: Dictionary = {
		"event_type": EVENT_TYPE_PLAY,
		"event_index": event_index,
		"inning": inning,
		"half": half,
		"batting_team_id": int(offense.get("team_id", 0)),
		"fielding_team_id": int(defense.get("team_id", 0)),
		"score_before": [],
		"score_after": [],
		"outs_before": outs_before,
		"outs_after": outs_after,
		"bases_before": _base_ids(bases_before),
		"bases_after": _base_ids(bases_after),
		"runs_scored": runs_scored,
		"plate_event": _plate_event(batter, pitcher, defense, outcome, resolved_pitch_summary),
		"batted_ball_event": {},
		"runner_events": runner_events,
		"runner_intents": [],
		"fielding_events": [],
		"defense_alignment": _defense_alignment(defense),
		"pitch_summary": resolved_pitch_summary,
		"run_value": 0.0,
	}
	if _is_batted_ball_outcome(outcome):
		play_event["batted_ball_event"] = _batted_ball_event(event_index, batter, pitcher, defense, outcome)
		play_event["fielding_events"] = FieldingModel.fielding_events_for_play(
			event_index,
			defense,
			outcome,
			play_event["batted_ball_event"] as Dictionary
		)
	play_event["runner_intents"] = runner_intents_for_play(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		outcome
	)
	return play_event


static func build_runner_event_play(
	event_index: int,
	inning: int,
	half: String,
	offense: Dictionary,
	defense: Dictionary,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	bases_after: Array,
	outs_after: int,
	runs_scored: int,
	runner_events: Array = [],
	play_phase: String = "before_pitch"
) -> Dictionary:
	return {
		"event_type": EVENT_TYPE_PLAY,
		"event_index": event_index,
		"play_kind": "runner_event",
		"play_phase": play_phase,
		"inning": inning,
		"half": half,
		"batting_team_id": int(offense.get("team_id", 0)),
		"fielding_team_id": int(defense.get("team_id", 0)),
		"score_before": [],
		"score_after": [],
		"outs_before": outs_before,
		"outs_after": outs_after,
		"bases_before": _base_ids(bases_before),
		"bases_after": _base_ids(bases_after),
		"runs_scored": runs_scored,
		"plate_event": {},
		"batted_ball_event": {},
		"runner_events": runner_events,
		"runner_intents": [],
		"fielding_events": [],
		"defense_alignment": _defense_alignment(defense),
		"pitch_summary": {},
		"run_value": 0.0,
	}


static func pitch_summary_for_play(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	outcome: Dictionary
) -> Dictionary:
	return _pitch_summary(event_index, batter, pitcher, outcome)


static func runner_events_for_play(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outs_before: int,
	outs_after_plate: int,
	outcome: Dictionary,
	context: Dictionary = {}
) -> Array:
	return RunnerActionModel.runner_events_for_play(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		bases_after_plate,
		outs_before,
		outs_after_plate,
		outcome,
		context
	)


static func runner_intents_for_play(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	outcome: Dictionary,
	context: Dictionary = {}
) -> Array:
	return RunnerActionModel.runner_intents_for_play(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		outcome,
		context
	)


static func _plate_event(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	outcome: Dictionary,
	pitch_summary: Dictionary
) -> Dictionary:
	var result: String = str(outcome.get("result", "out"))
	var category: String = str(outcome.get("category", "out"))
	var bases_taken: int = int(outcome.get("bases", 0))
	return {
		"event_type": EVENT_TYPE_PLATE_APPEARANCE,
		"batter_id": 0 if batter == null else batter.player_id,
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"catcher_id": _catcher_id(defense),
		"result": result,
		"category": category,
		"bases": bases_taken,
		"pa_completed": true,
		"ab_charged": _charges_at_bat(category),
		"is_hit": category == "hit",
		"is_walk": category == CATEGORY_WALK,
		"is_intentional_walk": result == "intentional_walk",
		"is_hit_by_pitch": category == CATEGORY_HIT_BY_PITCH,
		"is_strikeout": category == CATEGORY_STRIKEOUT,
		"is_sacrifice": category == "sacrifice",
		"is_sacrifice_fly": category == "sacrifice_fly",
		"is_reached_on_error": category == "error",
		"is_fielders_choice": category == "fielders_choice",
		"rbi": 0,
		"pitches": int(pitch_summary.get("pitches", 0)),
	}


static func _batted_ball_event(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	outcome: Dictionary
) -> Dictionary:
	var result: String = str(outcome.get("result", "out"))
	var position: int = int(outcome.get("fielder_position", 0))
	var event: Dictionary = {
		"event_type": EVENT_TYPE_BATTED_BALL,
		"batter_id": 0 if batter == null else batter.player_id,
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"fielder_id": _fielder_id(defense, position),
		"fielder_position": position,
		"batted_ball_type": _infer_batted_ball_type(result),
		"spray_direction": _infer_spray_direction(result, position),
		"field_zone": _field_zone(position),
		"zone_bucket": _zone_bucket(position, result),
		"trajectory_bucket": _trajectory_bucket(result),
		"exit_velocity": 0.0,
		"launch_angle": 0.0,
		"distance": 0.0,
		"hang_time": 0.0,
		"catch_probability": 0.0,
		"hit_probability": 0.0,
		"xba": 0.0,
		"xslg": 0.0,
		"xwoba": 0.0,
		"is_barrel": false,
		"is_hard_hit": false,
		"actual_result": result,
	}
	# PlateAppearanceCoordinator は batted-ball outcome に物理量を必ず埋めて返す。
	var physical_traits: Dictionary = outcome.get("physical_traits", {}) as Dictionary
	event.merge(physical_traits, true)
	if physical_traits.has("trajectory_bucket"):
		event["trajectory_bucket"] = str(physical_traits["trajectory_bucket"])
		event["batted_ball_type"] = _batted_ball_type_from_physics(str(physical_traits["trajectory_bucket"]))
	return event


static func _pitch_summary(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	outcome: Dictionary
) -> Dictionary:
	var category: String = str(outcome.get("category", "out"))
	var result: String = str(outcome.get("result", "out"))
	var min_pitches: int = 1
	var max_pitches: int = 5
	match category:
		CATEGORY_STRIKEOUT:
			min_pitches = 3
			max_pitches = 7
		CATEGORY_WALK:
			min_pitches = 4
			max_pitches = 8
		CATEGORY_HIT_BY_PITCH:
			min_pitches = 1
			max_pitches = 6
		"sacrifice", "sacrifice_fly":
			min_pitches = 1
			max_pitches = 4
		_:
			if int(outcome.get("bases", 0)) > 0 or result.contains("home_run"):
				min_pitches = 1
				max_pitches = 6
			else:
				min_pitches = 1
				max_pitches = 5

	# File 2 §9: z_abilities ベース。欠落時は旧キーで fallback。
	# 打者の選球眼・三振回避、投手の制球・球威の z。球数の微調整に使う。
	var eye: float = _ability(batter, "Bat_BBCreate")
	var avoid_k: float = _ability(batter, "Bat_KAvoid")
	var control: float = _ability(pitcher, "Pit_BBPrevent")
	var stuff: float = _ability(pitcher, "Pit_KCreate")
	var deterministic_roll: int = _deterministic_int([
		event_index,
		0 if batter == null else batter.player_id,
		0 if pitcher == null else pitcher.player_id,
		_hash_string(category),
		_hash_string(result),
	], min_pitches, max_pitches)
	var pitches: int = deterministic_roll
	if category == CATEGORY_WALK and control < -0.4:
		pitches += 1
	elif category == CATEGORY_STRIKEOUT and avoid_k >= 1.6:
		pitches += 1
	elif category != CATEGORY_STRIKEOUT and category != CATEGORY_WALK and eye >= 2.0:
		pitches += 1
	if category == CATEGORY_STRIKEOUT and stuff >= 2.0:
		pitches -= 1
	pitches = int(clamp(pitches, min_pitches, max_pitches))

	var balls: int = 0
	var strikes: int = 0
	if category == CATEGORY_WALK:
		balls = 4
		strikes = int(clamp(pitches - 4, 0, 2))
	elif category == CATEGORY_STRIKEOUT:
		strikes = 3
		balls = int(clamp(pitches - 3, 0, 3))
	else:
		var max_balls: int = int(min(3, max(0, pitches - 1)))
		balls = _deterministic_int([event_index, pitches, 17], 0, max_balls)
		var max_strikes: int = int(min(2, max(0, pitches - 1 - balls)))
		strikes = _deterministic_int([event_index, pitches, 29], 0, max_strikes)

	var swings: int = 0
	if _is_batted_ball_outcome(outcome):
		swings = 1 + _deterministic_int([event_index, pitches, 41], 0, int(max(0, pitches - 1)))
	elif category == CATEGORY_STRIKEOUT:
		swings = _deterministic_int([event_index, pitches, 53], 1, pitches)
	else:
		swings = _deterministic_int([event_index, pitches, 67], 0, pitches)
	swings = int(clamp(swings, 0, pitches))
	var whiffs: int = 0
	if category == CATEGORY_STRIKEOUT:
		whiffs = _deterministic_int([event_index, pitches, 71], 1, int(min(3, swings)))
	else:
		whiffs = _deterministic_int([event_index, pitches, 73], 0, int(min(1, swings)))
	var fouls: int = _deterministic_int([event_index, pitches, 79], 0, int(max(0, pitches - balls - strikes)))
	var called_strikes: int = int(max(0, strikes - whiffs))
	var in_zone: int = _deterministic_int([event_index, pitches, 83], int(ceil(float(pitches) * 0.38)), int(ceil(float(pitches) * 0.68)))
	in_zone = int(clamp(in_zone, 0, pitches))
	var first_pitch_strike: bool = _deterministic_unit([event_index, pitches, 89]) < (0.58 + float(control - 50) * 0.002)
	return {
		"pitches": pitches,
		"balls": balls,
		"strikes": strikes,
		"final_count": "%d-%d" % [balls, strikes],
		"swings": swings,
		"whiffs": whiffs,
		"called_strikes": called_strikes,
		"fouls": fouls,
		"in_zone_pitches": in_zone,
		"out_zone_pitches": pitches - in_zone,
		"first_pitch_strike": first_pitch_strike,
		"csw": whiffs + called_strikes,
	}


static func _is_batted_ball_outcome(outcome: Dictionary) -> bool:
	var category: String = str(outcome.get("category", "out"))
	if category == CATEGORY_WALK or category == CATEGORY_HIT_BY_PITCH or category == CATEGORY_STRIKEOUT:
		return false
	return true


static func _charges_at_bat(category: String) -> bool:
	return not (
		category == CATEGORY_WALK
		or category == CATEGORY_HIT_BY_PITCH
		or category == "sacrifice"
		or category == "sacrifice_fly"
	)


static func _base_ids(bases: Array) -> Array:
	var ids: Array = []
	for base_value in bases:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		ids.append(0 if runner == null else runner.player_id)
	return ids


static func _catcher_id(defense: Dictionary) -> int:
	var catcher: PSPlayerSeasonRecord = _catcher_record(defense)
	return 0 if catcher == null else catcher.player_id


static func _catcher_record(defense: Dictionary) -> PSPlayerSeasonRecord:
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) == 2:
			return slot.get("record", null) as PSPlayerSeasonRecord
	var batters: Array = defense.get("batters", []) as Array
	for record_value in batters:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null and record.position == 2:
			return record
	return null


static func _fielder_id(defense: Dictionary, position: int) -> int:
	if position <= 0:
		return 0
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) != position:
			continue
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		return 0 if record == null else record.player_id
	var pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
	if position == 1 and pitcher != null:
		return pitcher.player_id
	return 0


static func _defense_alignment(defense: Dictionary) -> Array:
	var alignment: Array = []
	var seen: Dictionary = {}
	var pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
	if pitcher != null and pitcher.player_id != 0:
		alignment.append(_alignment_row(pitcher.player_id, 1))
		seen[str(pitcher.player_id)] = true
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		var position: int = int(slot.get("position", 0))
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record == null or record.player_id == 0 or position <= 0:
			continue
		var player_key: String = str(record.player_id)
		if seen.has(player_key):
			continue
		alignment.append(_alignment_row(record.player_id, position))
		seen[player_key] = true
	return alignment


static func _alignment_row(player_id: int, position: int) -> Dictionary:
	return {
		"player_id": player_id,
		"position": position,
		"oaa_zone": _field_zone(position),
	}


static func _infer_batted_ball_type(result: String) -> String:
	if result.contains("ground") or result.contains("bunt") or result.contains("infield_single"):
		return "grounder"
	if result.contains("line"):
		return "liner"
	if result.contains("infield_fly") or result.contains("popup"):
		return "popup"
	if result.contains("fly") or result.contains("home_run"):
		return "fly"
	if result.contains("double") or result.contains("triple"):
		return "liner"
	return "unknown"


static func _batted_ball_type_from_physics(trajectory_bucket: String) -> String:
	match trajectory_bucket:
		"grounder":
			return "grounder"
		"liner":
			return "liner"
		"fly":
			return "fly"
		"popup":
			return "popup"
	return "unknown"


static func _infer_spray_direction(result: String, position: int) -> String:
	if result.ends_with("_left") or position == 7:
		return "left"
	if result.ends_with("_center") or position == 8:
		return "center"
	if result.ends_with("_right") or position == 9:
		return "right"
	if position == 3 or position == 4:
		return "right"
	if position == 5 or position == 6:
		return "left"
	return "center"


static func _field_zone(position: int) -> String:
	match position:
		1:
			return "pitcher"
		2:
			return "catcher"
		3, 4, 5, 6:
			return "infield"
		7, 8, 9:
			return "outfield"
		_:
			return "unknown"


static func _zone_bucket(position: int, result: String) -> String:
	if position <= 0:
		return "unknown"
	var prefix: String = "pos_%d" % position
	if result.contains("ground") or result.contains("infield_single"):
		return "%s_ground" % prefix
	if result.contains("fly") or result.contains("home_run"):
		return "%s_air" % prefix
	return prefix


static func _trajectory_bucket(result: String) -> String:
	var batted_ball_type: String = _infer_batted_ball_type(result)
	match batted_ball_type:
		"grounder":
			return "medium_grounder"
		"liner":
			return "medium_liner"
		"fly":
			return "medium_fly"
		"popup":
			return "popup"
		_:
			return "unknown"


# 能力を z-score で返す（0.0 が全体平均）。
static func _ability(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	return record.z_ability(key, default_value)


static func _deterministic_unit(values: Array) -> float:
	var seed: int = 1729
	for value in values:
		seed = int(abs((seed * 1103515245 + int(value) * 12345 + 1013904223) % 2147483647))
	return float(seed % 10000) / 10000.0


static func _deterministic_int(values: Array, min_value: int, max_value: int) -> int:
	if max_value <= min_value:
		return min_value
	var unit: float = _deterministic_unit(values)
	return min_value + int(floor(unit * float(max_value - min_value + 1)))


static func _hash_string(value: String) -> int:
	var hash_value: int = 0
	for index in range(value.length()):
		hash_value = int(abs((hash_value * 31 + value.unicode_at(index)) % 2147483647))
	return hash_value
