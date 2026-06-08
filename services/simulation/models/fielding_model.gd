extends RefCounted
class_name FieldingModel

const EVENT_TYPE_FIELDING: String = "fielding_event"
const LEAGUE_AVERAGE_FIELDING: float = 0.0

# UZR converts plays above average into runs. FanGraphs' public primer gives
# roughly .83 runs for the gap between a typical hit and a batted-ball out.
const OUT_VALUE_RUNS: float = 0.83
const ERROR_OUT_PROBABILITY: float = 0.95
# 失策の種別ごとの「本来アウトにできた確率」下限。捕球失策(正面/ルーチン)は高く、送球失策・外野後逸は
# 難度が高いので低め。これが OAA/ErrR の罰の重さになる（高いほど失策のマイナス評価が大きい）。
const ERROR_OUT_PROBABILITY_BY_TYPE: Dictionary = {
	"fielding": 0.95,
	"throwing": 0.82,
	"outfield_misplay": 0.80,
}
const NEUTRAL_CATCH_PROBABILITY_CALIBRATION: float = 0.006
const METRIC_OPPORTUNITY_SCALE: float = 0.35
const METRIC_ZONE_SCALE_BY_OAA_ZONE: Dictionary = {
	"infield": 1.00,
	"outfield": 1.05,
}

# Position-average fielding score (raw z スケール, リーグ平均 0) used for reporting defender probability.
# 守備位置難易度 (順位 SS>CF>2B>3B>RF>LF>1B、捕手は順位対象外)。
# play_resolver.gd POSITION_AVG_DEFENSE_SCORE_Z と同値で同期させること。
const POSITION_AVG_ABILITY_SCORE: Dictionary = {
	1: 0.80,
	2: 1.44,
	3: 0.20,
	4: 1.60,
	5: 1.12,
	6: 2.16,
	7: 0.48,
	8: 1.92,
	9: 0.80,
}


static func fielding_score_for_position(record: PSPlayerSeasonRecord, position: int) -> float:
	return _fielding_score(record, position)


static func position_average_ability_score(position: int) -> float:
	return _position_average_ability(position)


static func fielding_events_for_play(
	event_index: int,
	defense: Dictionary,
	outcome: Dictionary,
	batted_ball_event: Dictionary
) -> Array:
	if batted_ball_event.is_empty():
		return []

	var result: String = str(outcome.get("result", batted_ball_event.get("actual_result", "")))
	var category: String = str(outcome.get("category", "out"))
	var position: int = int(outcome.get("catch_attempt_position", batted_ball_event.get("fielder_position", 0)))
	if position <= 0:
		position = _infer_position_from_result(result)
	if position <= 0:
		return []

	var fielder: PSPlayerSeasonRecord = _fielder_record(defense, position)
	var ability_score: float = _fielding_score(fielder, position)
	var fielding_outs: int = _fielding_outs_added(category, result, outcome)
	var actual_out: bool = fielding_outs > 0
	var batter_out: bool = _batter_out_on_play(category, result, outcome)
	var runner_outs: int = _runner_outs_from_outcome(outcome, category, fielding_outs, batter_out)
	var difficulty: float = _opportunity_difficulty(batted_ball_event, category, result)
	var opportunity_weight: float = _opportunity_weight(batted_ball_event, category, result, difficulty)
	var catch_probability: float = _average_out_probability(outcome, actual_out, difficulty, category)
	var metric_scale: float = METRIC_OPPORTUNITY_SCALE * _metric_zone_scale(position)

	var oaa: float = 0.0
	if _is_ratable_fielding_play(category, result, outcome):
		oaa = _outs_above_average(actual_out, catch_probability) * metric_scale

	var uzr: float = oaa * OUT_VALUE_RUNS
	var rngr: float = 0.0
	var errr: float = 0.0
	var dpr: float = 0.0
	if _is_ratable_fielding_play(category, result, outcome):
		match category:
			"error":
				errr = uzr
			_:
				rngr = uzr
		dpr = _double_play_runs(outcome, category, metric_scale)
	var rounded_oaa: float = _round_float(oaa, 3)
	var rounded_rngr: float = _round_float(rngr, 3)
	var rounded_errr: float = _round_float(errr, 3)
	var rounded_dpr: float = _round_float(dpr, 3)
	var rounded_uzr: float = _round_float(rounded_rngr + rounded_errr + rounded_dpr, 3)
	var rounded_drs: float = rounded_uzr

	return [{
		"event_type": EVENT_TYPE_FIELDING,
		"event_index": event_index,
		"fielder_id": 0 if fielder == null else fielder.player_id,
		"position": position,
		"field_zone": str(batted_ball_event.get("field_zone", _field_zone(position))),
		"oaa_zone": _oaa_zone(position),
		"zone_bucket": str(batted_ball_event.get("zone_bucket", "pos_%d" % position)),
		"play_kind": _play_kind(category, result, batted_ball_event, outcome),
		"catch_probability": _round_float(catch_probability, 3),
		"defender_catch_probability": _round_float(_defender_catch_probability(catch_probability, ability_score), 3),
		"actual_outcome": _actual_outcome(category, result, actual_out, outcome),
		"actual_out": actual_out,
		"fielding_outs": fielding_outs,
		"runner_outs": runner_outs,
		"batter_out": batter_out,
		"fielding_result": _fielding_result(category, result, outcome, fielding_outs),
		"opportunity_weight": _round_float(opportunity_weight, 3),
		"fielding_score": _round_float(ability_score, 1),
		"comparison_position": position,
		"uzr_position": position,
		"runner_strategy": str(outcome.get("runner_strategy", "")),
		"throw_target_base": int(outcome.get("throw_target_base", outcome.get("force_out_to_base", 0))),
		"force_out_from_base": int(outcome.get("force_out_from_base", 0)),
		"force_out_to_base": int(outcome.get("force_out_to_base", 0)),
		"oaa": rounded_oaa,
		"rngr": rounded_rngr,
		"errr": rounded_errr,
		"dpr": rounded_dpr,
		"uzr": rounded_uzr,
		"drs": rounded_drs,
		"run_value": rounded_drs,
	}]


static func smoke_test_fielding_ability_gap() -> Dictionary:
	var high: PSPlayerSeasonRecord = _probe_fielder(-910001, 6, 85)
	var low: PSPlayerSeasonRecord = _probe_fielder(-910002, 6, 35)
	var out_outcome: Dictionary = {
		"result": "groundout_shortstop",
		"category": "out",
		"bases": 0,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.30,
	}
	var hit_outcome: Dictionary = {
		"result": "infield_single_shortstop",
		"category": "hit",
		"bases": 1,
		"fielder_position": 6,
		"catch_attempt_position": 6,
		"catch_probability_neutral": 0.30,
	}
	var batted_ball_event: Dictionary = {
		"fielder_position": 6,
		"field_zone": "infield",
		"zone_bucket": "pos_6_ground",
		"batted_ball_type": "grounder",
		"trajectory_bucket": "medium_grounder",
		"exit_velocity": 90.0,
		"launch_angle": -8.0,
		"distance": 32.0,
		"actual_result": "groundout_shortstop",
	}
	var high_events: Array = fielding_events_for_play(1, {"fielders": [{"record": high, "position": 6}]}, out_outcome, batted_ball_event)
	var low_events: Array = fielding_events_for_play(1, {"fielders": [{"record": low, "position": 6}]}, hit_outcome, batted_ball_event)
	var high_oaa: float = 0.0 if high_events.is_empty() else float((high_events[0] as Dictionary).get("oaa", 0.0))
	var low_oaa: float = 0.0 if low_events.is_empty() else float((low_events[0] as Dictionary).get("oaa", 0.0))
	var high_uzr: float = 0.0 if high_events.is_empty() else float((high_events[0] as Dictionary).get("uzr", 0.0))
	var low_uzr: float = 0.0 if low_events.is_empty() else float((low_events[0] as Dictionary).get("uzr", 0.0))
	return {
		"high_oaa": high_oaa,
		"low_oaa": low_oaa,
		"high_uzr": high_uzr,
		"low_uzr": low_uzr,
		"gap": _round_float(high_uzr - low_uzr, 3),
		"ok": (
			absf(high_oaa - 0.2450) < 0.001
			and absf(low_oaa + 0.1050) < 0.001
			and high_uzr > low_uzr
		),
	}


static func _probe_fielder(player_id: int, position: int, value: int) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player_id
	record.position = position
	record.role = "fielder"
	# _probe_fielder は smoke_test_fielding_ability_gap でしか使われない。
	# 入力の display 値も「シミュ式が想定する 1-100 スケール」なので線形逆変換。
	var z_value: float = PSAbilityScale.display_to_z(float(value))
	record.z_abilities_snapshot = {
		"IF_Reach": z_value,
		"IF_Secure": z_value,
		"IF_ThrowPower": z_value,
		"IF_ThrowAccuracy": z_value,
		"IF_Exchange": z_value,
		"IF_PositionFit": z_value,
		"OF_Reach": z_value,
		"OF_Route": z_value,
		"OF_Secure": z_value,
		"OF_ArmPower": z_value,
		"OF_ArmAccuracy": z_value,
		"OF_Release": z_value,
		"OF_PositionFit": z_value,
		"C_Framing": z_value,
		"C_Blocking": z_value,
		"C_Throw": z_value,
		"C_GameCall": z_value,
		"C_FieldSecure": z_value,
	}
	return record


static func _fielder_record(defense: Dictionary, position: int) -> PSPlayerSeasonRecord:
	if position == 1:
		return defense.get("pitcher", null) as PSPlayerSeasonRecord
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) != position:
			continue
		return slot.get("record", null) as PSPlayerSeasonRecord
	var batters: Array = defense.get("batters", []) as Array
	for record_value in batters:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record != null and record.position == position:
			return record
	return null


static func _fielding_score(record: PSPlayerSeasonRecord, position: int) -> float:
	if record == null:
		return LEAGUE_AVERAGE_FIELDING
	match position:
		1:
			return _weighted_score_z(record, [
				["PF_Reach", 0.40],
				["PF_Secure", 0.35],
				["PF_Throw", 0.25],
			])
		2:
			return _weighted_score_z(record, [
				["C_FieldSecure", 0.25],
				["C_Throw", 0.25],
				["C_Blocking", 0.20],
				["C_Framing", 0.15],
				["C_GameCall", 0.15],
			])
		3:
			return _weighted_score_z(record, [
				["IF_Secure", 0.42],
				["IF_Reach", 0.20],
				["IF_PositionFit", 0.18],
				["IF_ThrowAccuracy", 0.10],
				["IF_Exchange", 0.10],
			])
		4:
			# 二塁: 併殺完成(Exchange)重視、肩(ThrowPower)は低めだが残す、守備範囲確保。
			return _weighted_score_z(record, [
				["IF_Reach", 0.30],
				["IF_Exchange", 0.24],
				["IF_Secure", 0.18],
				["IF_PositionFit", 0.14],
				["IF_ThrowPower", 0.06],
				["IF_ThrowAccuracy", 0.08],
			])
		5:
			# 三塁: とにかく肩力(ThrowPower)突出。
			return _weighted_score_z(record, [
				["IF_ThrowPower", 0.32],
				["IF_Secure", 0.22],
				["IF_PositionFit", 0.16],
				["IF_Reach", 0.16],
				["IF_ThrowAccuracy", 0.10],
				["IF_Exchange", 0.04],
			])
		6:
			# 遊撃: 全守備能力が高水準 (all-around)。
			return _weighted_score_z(record, [
				["IF_Reach", 0.22],
				["IF_Secure", 0.18],
				["IF_ThrowPower", 0.16],
				["IF_PositionFit", 0.16],
				["IF_Exchange", 0.14],
				["IF_ThrowAccuracy", 0.14],
			])
		7:
			return _weighted_score_z(record, [
				["OF_Reach", 0.32],
				["OF_Route", 0.22],
				["OF_Secure", 0.22],
				["OF_ArmPower", 0.08],
				["OF_ArmAccuracy", 0.06],
				["OF_PositionFit", 0.10],
			])
		8:
			# 中堅: 守備範囲(Reach)突出。
			return _weighted_score_z(record, [
				["OF_Reach", 0.44],
				["OF_Route", 0.26],
				["OF_Secure", 0.14],
				["OF_PositionFit", 0.10],
				["OF_ArmPower", 0.04],
				["OF_ArmAccuracy", 0.02],
			])
		9:
			return _weighted_score_z(record, [
				["OF_ArmPower", 0.20],
				["OF_ArmAccuracy", 0.14],
				["OF_Reach", 0.24],
				["OF_Route", 0.16],
				["OF_Secure", 0.16],
				["OF_PositionFit", 0.10],
			])
	return float(LEAGUE_AVERAGE_FIELDING)


static func _position_average_ability(position: int) -> float:
	return float(POSITION_AVG_ABILITY_SCORE.get(position, LEAGUE_AVERAGE_FIELDING))


static func _weighted_score_z(record: PSPlayerSeasonRecord, weights: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	for row_value in weights:
		var row: Array = row_value as Array
		var z_key: String = str(row[0])
		var weight: float = float(row[1])
		var contribution: float
		if record.z_abilities_snapshot.has(z_key):
			# fielding_score は raw z スケール (リーグ平均 0)。欠落キーは平均 0 で補完。
			contribution = record.z_ability(z_key, 0.0)
		else:
			contribution = LEAGUE_AVERAGE_FIELDING
		total += contribution * weight
		weight_total += weight
	if weight_total <= 0.0:
		return LEAGUE_AVERAGE_FIELDING
	return total / weight_total


static func _average_out_probability(
	outcome: Dictionary,
	actual_out: bool,
	difficulty: float,
	category: String
) -> float:
	var probability: float
	if outcome.has("catch_probability_neutral"):
		probability = float(outcome["catch_probability_neutral"])
	elif outcome.has("catch_probability_used"):
		probability = float(outcome["catch_probability_used"])
	else:
		probability = _neutral_catch_probability(actual_out, difficulty)
	if category == "error":
		# 失策を一律「95%アウトにできた打球」とせず、種別ごとの基準で評価する。
		# 送球失策や外野後逸は難度が高く、ErrR(UZR)で過剰に罰しないよう下限を下げる。
		var error_type: String = str(outcome.get("error_type", "fielding"))
		var floor: float = float(ERROR_OUT_PROBABILITY_BY_TYPE.get(error_type, ERROR_OUT_PROBABILITY))
		return clamp(max(probability, floor), 0.0, 0.98)
	if category == "double_play" or category == "sacrifice_fly":
		return clamp(probability, 0.0, 1.0)
	return clamp(probability, 0.0, 1.0)


static func _outs_above_average(actual_out: bool, average_out_probability: float) -> float:
	if actual_out:
		return 1.0 - average_out_probability
	return -average_out_probability


static func _double_play_runs(outcome: Dictionary, category: String, metric_scale: float) -> float:
	if not bool(outcome.get("double_play_opportunity", false)):
		return 0.0
	var probability: float = clamp(float(outcome.get("double_play_probability", 0.0)), 0.0, 1.0)
	var turned_double_play: bool = category == "double_play"
	var plays_above_average: float = 1.0 - probability if turned_double_play else -probability
	return plays_above_average * metric_scale * OUT_VALUE_RUNS


static func _is_ratable_fielding_play(category: String, result: String, outcome: Dictionary) -> bool:
	if result.contains("home_run") or int(outcome.get("bases", 0)) >= 4:
		return false
	return category != "walk" and category != "hit_by_pitch" and category != "strikeout"


static func _neutral_catch_probability(actual_out: bool, difficulty: float) -> float:
	var miss_or_convert_chance: float = lerp(0.012, 0.050, difficulty)
	var base_probability: float = 1.0 - miss_or_convert_chance if actual_out else miss_or_convert_chance
	return clamp(base_probability + NEUTRAL_CATCH_PROBABILITY_CALIBRATION, 0.0, 1.0)


static func _defender_catch_probability(neutral_probability: float, ability_score: float) -> float:
	var ability_adjustment: float = (ability_score - LEAGUE_AVERAGE_FIELDING) * 0.04375
	return clamp(neutral_probability + ability_adjustment, 0.0, 1.0)


static func _opportunity_difficulty(batted_ball_event: Dictionary, category: String, result: String) -> float:
	var exit_velocity: float = float(batted_ball_event.get("exit_velocity", 88.0))
	var launch_angle: float = float(batted_ball_event.get("launch_angle", 12.0))
	var distance: float = float(batted_ball_event.get("distance", 35.0))
	var batted_ball_type: String = str(batted_ball_event.get("batted_ball_type", "unknown"))
	var difficulty: float = 0.35
	match batted_ball_type:
		"grounder":
			difficulty = clamp((exit_velocity - 72.0) / 38.0 + distance / 150.0, 0.10, 0.95)
		"liner":
			difficulty = clamp((exit_velocity - 78.0) / 35.0 + 0.25, 0.18, 0.98)
		"fly":
			var angle_score: float = 1.0 - exp(-pow((launch_angle - 28.0) / 18.0, 2.0))
			difficulty = clamp(distance / 135.0 * 0.75 + angle_score * 0.20, 0.15, 0.98)
		"popup":
			difficulty = 0.08
		_:
			difficulty = 0.35
	if category == "error":
		difficulty = max(difficulty, 0.55)
	if result.contains("home_run"):
		difficulty = 1.0
	return difficulty


static func _opportunity_weight(batted_ball_event: Dictionary, category: String, result: String, difficulty: float) -> float:
	var weight: float = 0.75 + difficulty * 0.85
	if category == "double_play":
		weight += 0.35
	if category == "error":
		weight += 0.20
	if result.contains("home_run"):
		weight *= 0.25
	if str(batted_ball_event.get("batted_ball_type", "")) == "popup":
		weight *= 0.65
	return clamp(weight, 0.25, 2.0)


static func _fielding_outs_added(category: String, result: String, outcome: Dictionary = {}) -> int:
	if result.contains("home_run"):
		return 0
	if category == "fielders_choice":
		return max(0, int(outcome.get("fielders_choice_outs", 1)))
	if category == "double_play":
		return 2
	match category:
		"out", "productive_out", "sacrifice", "sacrifice_fly":
			return 1
	return 0


static func _runner_outs_from_outcome(outcome: Dictionary, category: String = "", fielding_outs: int = 0, batter_out: bool = false) -> int:
	var count: int = 0
	for advancement_value in (outcome.get("runner_advancements", []) as Array):
		var advancement: Dictionary = advancement_value as Dictionary
		if bool(advancement.get("is_out", false)):
			count += 1
	if count > 0:
		return count
	if category == "double_play":
		return max(0, fielding_outs - (1 if batter_out else 0))
	if category == "fielders_choice" and fielding_outs > 0 and not batter_out:
		return fielding_outs
	return count


static func _batter_out_on_play(category: String, result: String, outcome: Dictionary) -> bool:
	if result.contains("home_run"):
		return false
	if category == "double_play":
		return true
	if category == "fielders_choice":
		return false
	if category == "out" or category == "productive_out" or category == "sacrifice" or category == "sacrifice_fly":
		return true
	return false


static func _fielding_result(category: String, result: String, outcome: Dictionary, fielding_outs: int) -> String:
	if category == "error":
		return str(outcome.get("error_type", "error"))
	if bool(outcome.get("infield_throw_beat", false)):
		return "throw_late"
	if category == "fielders_choice":
		if result.contains("home_throw"):
			return "home_throw_out" if fielding_outs > 0 else "home_throw_safe"
		return "force_out"
	if category == "double_play":
		return "double_play"
	if str(outcome.get("runner_strategy", "")) == "groundout_advance":
		return "groundout_advance"
	if fielding_outs > 0:
		return "out"
	if category == "hit":
		return "hit"
	return "no_out"


static func _actual_outcome(category: String, result: String, actual_out: bool, outcome: Dictionary = {}) -> String:
	if category == "error":
		return "error"
	if result.contains("home_run"):
		return "home_run"
	if bool(outcome.get("infield_throw_beat", false)):
		return "infield_single"
	if category == "fielders_choice":
		if result.contains("home_throw"):
			return "home_throw_out" if actual_out else "home_throw_safe"
		return "force_out" if actual_out else "fielders_choice_safe"
	if str(outcome.get("runner_strategy", "")) == "groundout_advance":
		return "out_with_runner_advance" if actual_out else "runner_advance_no_out"
	if actual_out:
		return "out"
	if category == "hit":
		return "hit"
	return "hit"


static func _play_kind(category: String, result: String, batted_ball_event: Dictionary, outcome: Dictionary = {}) -> String:
	if category == "error":
		return "error"
	if category == "double_play":
		return "double_play_pivot"
	if category == "fielders_choice":
		if result.contains("home_throw"):
			return "home_throw"
		return "fielders_choice"
	if bool(outcome.get("infield_throw_beat", false)):
		return "infield_throw"
	if str(outcome.get("runner_strategy", "")) == "groundout_advance":
		return "groundout_advance"
	if result.contains("home_run"):
		return "wall_play"
	var batted_ball_type: String = str(batted_ball_event.get("batted_ball_type", "unknown"))
	match batted_ball_type:
		"grounder":
			return "field_grounder"
		"liner":
			return "catch_liner"
		"fly", "popup":
			return "catch_fly"
	return "field_ball"


static func _infer_position_from_result(result: String) -> int:
	if result.contains("pitcher"):
		return 1
	if result.contains("catcher"):
		return 2
	if result.contains("first_base"):
		return 3
	if result.contains("second_base"):
		return 4
	if result.contains("third_base"):
		return 5
	if result.contains("shortstop"):
		return 6
	if result.contains("left"):
		return 7
	if result.contains("center"):
		return 8
	if result.contains("right"):
		return 9
	return 0


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
	return "unknown"


static func _oaa_zone(position: int) -> String:
	if position >= 3 and position <= 6:
		return "infield"
	if position >= 7 and position <= 9:
		return "outfield"
	if position == 1 or position == 2:
		return "battery"
	return "unknown"


static func _metric_zone_scale(position: int) -> float:
	return float(METRIC_ZONE_SCALE_BY_OAA_ZONE.get(_oaa_zone(position), 1.0))


static func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
