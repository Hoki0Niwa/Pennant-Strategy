extends RefCounted
class_name PSRunnerAdvanceResolver

# Resolves advancement after a batted ball has already become a hit.
# This layer does not modify EV/LA/spray/barrel traits. It only decides how far
# runners can take the play based on ball depth, processing time, runner speed,
# and the fielder's arm.

const RESULT_EXTRA_BASE: String = "extra_base_on_hit"
const RESULT_RUNNER_OUT: String = "runner_out_advancing"
const RESULT_ADVANCE_ON_THROW: String = "advance_on_throw"
const FIELDER_ARM_NEUTRAL_Z: float = 1.072
const FIELDER_ARM_DOUBLE_WEIGHT_Z: float = 0.020
const FIELDER_ARM_TRIPLE_WEIGHT_Z: float = 0.02125
const FIELDER_ARM_EXTRA_ADVANCE_WEIGHT_Z: float = 0.025
const FIELDER_ARM_OUT_WEIGHT_Z: float = 0.030
const OUTFIELD_THROW_DECISION_BASE: float = 0.34
const OUTFIELD_THROW_DECISION_ARM_WEIGHT_Z: float = 0.060
const OUTFIELD_THROW_DECISION_SPEED_WEIGHT_Z: float = 0.045
const OUTFIELD_THROW_DECISION_JUDGMENT_WEIGHT_Z: float = 0.020
const OUTFIELD_THROW_DECISION_CLOSE_PLAY_WEIGHT: float = 0.22
const OUTFIELD_THROW_DECISION_SHALLOW_WEIGHT: float = 0.18
const OUTFIELD_THROW_ERROR_BASE: float = 0.010
const OUTFIELD_THROW_ERROR_TARGET_HOME: float = 0.010
const OUTFIELD_THROW_ERROR_TARGET_THIRD: float = 0.005
const OUTFIELD_THROW_ERROR_DEPTH_WEIGHT: float = 0.010
const OUTFIELD_THROW_ERROR_ARM_WEIGHT_Z: float = 0.010
const OUTFIELD_THROW_ERROR_MIN: float = 0.002
const OUTFIELD_THROW_ERROR_MAX: float = 0.045

const FIELD_NAMES: Dictionary = {
	1: "pitcher",
	2: "catcher",
	3: "first_base",
	4: "second_base",
	5: "third_base",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}

const DOUBLE_RATE_SCALE: float = 0.43


static func resolve_hit(
	batter: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	physics: Dictionary,
	fielder_position: int,
	fielder_arm: float,
	min_batter_bases: int = 1
) -> Dictionary:
	var batter_bases: int = _batter_safe_bases(batter, physics, fielder_arm, min_batter_bases)
	var advancements: Array = _runner_advancements(
		batter,
		bases_before,
		outs_before,
		physics,
		fielder_position,
		fielder_arm,
		batter_bases
	)
	var runner_events: Array = _runner_events_from_advancements(
		batter,
		advancements,
		batter_bases,
		fielder_position,
		fielder_arm
	)
	var throw_contexts: Array = _throw_contexts_from_advancements(advancements)
	return {
		"bases": batter_bases,
		"runner_advancements": advancements,
		"runner_events": runner_events,
		"advance_context": {
			"fielder_position": fielder_position,
			"fielder_arm": fielder_arm,
			"ball_depth": _ball_depth(physics),
			"processing_time": _processing_time(physics, fielder_position),
			"throw_contexts": throw_contexts,
		},
	}


static func _batter_safe_bases(
	batter: PSPlayerSeasonRecord,
	physics: Dictionary,
	fielder_arm: float,
	min_batter_bases: int
) -> int:
	var bases: int = int(clamp(min_batter_bases, 1, 3))
	var speed: float = _ability(batter, "Run_Speed")
	var distance: float = float(physics.get("distance", 0.0))
	var ev: float = float(physics.get("exit_velocity", 88.0))
	var spray: float = float(physics.get("spray_angle", 0.0))
	var trajectory: String = str(physics.get("trajectory_bucket", "liner"))
	var in_gap: bool = _in_gap(spray)
	var wall_ball: bool = distance >= 99.0 and trajectory != "grounder"

	var legacy_double_chance: float = _legacy_double_chance(
		trajectory,
		in_gap,
		wall_ball,
		distance,
		ev,
		speed,
		fielder_arm
	)
	var triple_chance: float = _triple_chance(
		spray,
		in_gap,
		wall_ball,
		distance,
		speed,
		fielder_arm
	)
	var triple_roll_chance: float = triple_chance if bases >= 2 else legacy_double_chance * triple_chance
	if bases < 3 and Rng.roll_float() < triple_roll_chance:
		return 3

	var double_chance: float = clamp(legacy_double_chance * DOUBLE_RATE_SCALE, 0.005, 0.46)
	if bases < 2 and Rng.roll_float() < double_chance:
		bases = 2
	return bases


static func _legacy_double_chance(
	trajectory: String,
	in_gap: bool,
	wall_ball: bool,
	distance: float,
	ev: float,
	speed: float,
	fielder_arm: float
) -> float:
	var chance: float = 0.035
	if trajectory == "liner":
		chance += 0.12
	elif trajectory == "fly":
		chance += 0.09
	elif trajectory == "grounder":
		chance -= 0.02
	if in_gap:
		chance += 0.18
	if wall_ball:
		chance += 0.30
	chance += clamp((distance - 62.0) * 0.0040, -0.04, 0.28)
	chance += clamp((ev - 90.0) * 0.0030, -0.05, 0.12)
	# 走力 z が平均(0.78)を上回るほど二塁打を増やす。守備肩も z のまま、強いほど減らす。
	chance += (speed - 0.78) * 0.0275
	chance -= (fielder_arm - FIELDER_ARM_NEUTRAL_Z) * FIELDER_ARM_DOUBLE_WEIGHT_Z
	return clamp(chance, 0.01, 0.78)


static func _triple_chance(
	spray: float,
	in_gap: bool,
	wall_ball: bool,
	distance: float,
	speed: float,
	fielder_arm: float
) -> float:
	var chance: float = 0.004
	if in_gap:
		chance += 0.026
	if wall_ball:
		chance += 0.020
	chance += clamp((distance - 94.0) * 0.0014, 0.0, 0.07)
	chance += (speed - 0.78) * 0.0225
	chance -= (fielder_arm - FIELDER_ARM_NEUTRAL_Z) * FIELDER_ARM_TRIPLE_WEIGHT_Z
	if absf(spray) > 30.0:
		chance -= 0.018
	return clamp(chance, 0.0, 0.18)


static func _runner_advancements(
	_batter: PSPlayerSeasonRecord,
	bases_before: Array,
	outs_before: int,
	physics: Dictionary,
	fielder_position: int,
	fielder_arm: float,
	batter_bases: int
) -> Array:
	var advancements: Array = []
	var occupied: Dictionary = {}
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var from_base: int = base_index + 1
		var baseline_to: int = min(4, from_base + batter_bases)
		var to_base: int = baseline_to
		var is_out: bool = false
		var is_extra: bool = false
		var extra_probability: float = 0.0
		var throw_context: Dictionary = {}

		var extra_to: int = baseline_to + 1
		if extra_to <= 4 and not occupied.has(extra_to):
			extra_probability = _extra_advance_probability(
				runner,
				from_base,
				extra_to,
				outs_before,
				physics,
				fielder_position,
				fielder_arm,
				batter_bases
			)
			if Rng.roll_float() < extra_probability:
				to_base = extra_to
				is_extra = true
				throw_context = _outfield_throw_context(
					runner,
					from_base,
					to_base,
					outs_before,
					physics,
					fielder_position,
					fielder_arm,
					batter_bases,
					extra_probability
				)
				is_out = bool(throw_context.get("runner_out", false))

		if not is_out and to_base >= 1 and to_base <= 3:
			occupied[to_base] = true
		var advancement: Dictionary = {
			"runner": runner,
			"runner_id": runner.player_id,
			"from_base": from_base,
			"to_base": to_base,
			"baseline_to": baseline_to,
			"is_out": is_out,
			"is_extra": is_extra,
			"advance_probability": extra_probability,
		}
		if not throw_context.is_empty():
			advancement["throw_context"] = throw_context
		advancements.append(advancement)
	return advancements


static func _runner_events_from_advancements(
	batter: PSPlayerSeasonRecord,
	advancements: Array,
	batter_bases: int,
	fielder_position: int,
	fielder_arm: float
) -> Array:
	var events: Array = []
	if batter != null and batter_bases > 1:
		events.append(_runner_event(
			"batter_extra_base_on_hit",
			RESULT_EXTRA_BASE,
			batter,
			1,
			batter_bases,
			0,
			{
				"batter_runner": true,
				"fielder_position": fielder_position,
				"fielder_arm": fielder_arm,
			}
		))
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var is_extra: bool = bool(advancement.get("is_extra", false))
		var is_out: bool = bool(advancement.get("is_out", false))
		var throw_context: Dictionary = advancement.get("throw_context", {}) as Dictionary
		var throw_attempt: bool = bool(throw_context.get("throw_attempt", false))
		var throwing_error: bool = bool(throw_context.get("throwing_error", false))
		if not is_extra and not is_out and not throwing_error:
			continue
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		var result: String = RESULT_RUNNER_OUT if is_out else (RESULT_ADVANCE_ON_THROW if throw_attempt else RESULT_EXTRA_BASE)
		var event_extra: Dictionary = {
			"is_baserunning_out": is_out,
			"batter_rbi": (not is_out and int(advancement.get("to_base", 0)) >= 4),
			"fielder_position": fielder_position,
			"fielder_arm": fielder_arm,
		}
		if not throw_context.is_empty():
			event_extra.merge(_runner_event_throw_fields(throw_context), true)
		events.append(_runner_event(
			result,
			result,
			runner,
			int(advancement.get("baseline_to", advancement.get("from_base", 0))),
			int(advancement.get("to_base", 0)),
			1 if is_out else 0,
			event_extra
		))
	return events


static func _runner_event(
	strategy: String,
	result: String,
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	outs_added: int,
	extra: Dictionary = {}
) -> Dictionary:
	var event: Dictionary = {
		"event_type": "runner_event",
		"phase": "after_batted_ball",
		"strategy": strategy,
		"runner_id": 0 if runner == null else runner.player_id,
		"batter_id": 0,
		"pitcher_id": 0,
		"catcher_id": 0,
		"from_base": from_base,
		"to_base": to_base,
		"result": result,
		"is_steal_attempt": false,
		"is_stolen_base": false,
		"is_caught_stealing": false,
		"is_pickoff": false,
		"is_wild_pitch": false,
		"is_passed_ball": false,
		"is_balk": false,
		"is_defensive_indifference": false,
		"is_baserunning_out": result == RESULT_RUNNER_OUT,
		"recorded_as_attempt": false,
		"state_already_applied": true,
		"outs_added": outs_added,
		"run_value": 0.0,
	}
	for key_value in extra.keys():
		event[key_value] = extra[key_value]
	return event


static func _outfield_throw_context(
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	outs_before: int,
	physics: Dictionary,
	fielder_position: int,
	fielder_arm: float,
	batter_bases: int,
	extra_probability: float
) -> Dictionary:
	if fielder_position < 7:
		return {}
	var decision_probability: float = _outfield_throw_decision_probability(
		runner,
		from_base,
		to_base,
		outs_before,
		physics,
		fielder_position,
		fielder_arm,
		batter_bases,
		extra_probability
	)
	var context: Dictionary = {
		"throw_attempt": false,
		"throw_result": "cutoff_hold",
		"throw_target_base": to_base,
		"throw_decision_probability": decision_probability,
		"fielder_position": fielder_position,
		"fielder_arm": fielder_arm,
	}
	if Rng.roll_float() >= decision_probability:
		return context

	var out_probability: float = _advance_out_probability(runner, from_base, to_base, physics, fielder_arm)
	if fielder_position == 9 and to_base == 3:
		out_probability += 0.020
	elif fielder_position == 7 and to_base >= 4:
		out_probability += 0.012
	out_probability = clamp(out_probability, 0.015, 0.38)

	var error_probability: float = _outfield_throw_error_probability(physics, fielder_position, to_base, fielder_arm)
	var throwing_error: bool = Rng.roll_float() < error_probability
	var runner_out: bool = false if throwing_error else Rng.roll_float() < out_probability
	context["throw_attempt"] = true
	context["throw_result"] = "throwing_error" if throwing_error else ("runner_out" if runner_out else "safe")
	context["throw_out_probability"] = out_probability
	context["throw_error_probability"] = error_probability
	context["throwing_error"] = throwing_error
	context["runner_out"] = runner_out
	return context


static func _outfield_throw_decision_probability(
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	outs_before: int,
	physics: Dictionary,
	fielder_position: int,
	fielder_arm: float,
	batter_bases: int,
	extra_probability: float
) -> float:
	var speed: float = _ability(runner, "Run_Speed")
	var judgment: float = _ability(runner, "Run_Judgment")
	var distance: float = float(physics.get("distance", 0.0))
	var shallow_factor: float = clamp((82.0 - distance) / 46.0, 0.0, 1.0)
	var deep_factor: float = clamp((distance - 96.0) / 40.0, 0.0, 1.0)
	var close_play_factor: float = clamp((0.34 - extra_probability) / 0.34, -0.35, 1.0)
	var probability: float = OUTFIELD_THROW_DECISION_BASE
	probability += (fielder_arm - FIELDER_ARM_NEUTRAL_Z) * OUTFIELD_THROW_DECISION_ARM_WEIGHT_Z
	probability -= speed * OUTFIELD_THROW_DECISION_SPEED_WEIGHT_Z
	probability -= judgment * OUTFIELD_THROW_DECISION_JUDGMENT_WEIGHT_Z
	probability += close_play_factor * OUTFIELD_THROW_DECISION_CLOSE_PLAY_WEIGHT
	probability += shallow_factor * OUTFIELD_THROW_DECISION_SHALLOW_WEIGHT
	probability -= deep_factor * 0.12
	if to_base >= 4:
		probability += 0.16
	elif to_base == 3:
		probability += 0.09
	elif to_base == 2:
		probability += 0.04
	if outs_before == 2 and to_base < 4:
		probability -= 0.06
	if fielder_position == 9 and to_base == 3:
		probability += 0.06
	elif fielder_position == 7 and to_base >= 4:
		probability += 0.04
	if batter_bases >= 2 and from_base == 1 and to_base >= 4:
		probability += 0.05
	return clamp(probability, 0.06, 0.92)


static func _outfield_throw_error_probability(
	physics: Dictionary,
	fielder_position: int,
	to_base: int,
	fielder_arm: float
) -> float:
	var distance: float = float(physics.get("distance", 0.0))
	var depth_factor: float = clamp((distance - 58.0) / 62.0, 0.0, 1.0)
	var probability: float = OUTFIELD_THROW_ERROR_BASE
	probability += depth_factor * OUTFIELD_THROW_ERROR_DEPTH_WEIGHT
	if to_base >= 4:
		probability += OUTFIELD_THROW_ERROR_TARGET_HOME
	elif to_base == 3:
		probability += OUTFIELD_THROW_ERROR_TARGET_THIRD
	if fielder_position == 8:
		probability += 0.002
	probability -= (fielder_arm - FIELDER_ARM_NEUTRAL_Z) * OUTFIELD_THROW_ERROR_ARM_WEIGHT_Z
	return clamp(probability, OUTFIELD_THROW_ERROR_MIN, OUTFIELD_THROW_ERROR_MAX)


static func _runner_event_throw_fields(throw_context: Dictionary) -> Dictionary:
	var fields: Dictionary = {
		"throw_attempt": bool(throw_context.get("throw_attempt", false)),
		"throw_result": str(throw_context.get("throw_result", "")),
		"throw_target_base": int(throw_context.get("throw_target_base", 0)),
		"throw_decision_probability": float(throw_context.get("throw_decision_probability", 0.0)),
		"throw_out_probability": float(throw_context.get("throw_out_probability", 0.0)),
		"throw_error_probability": float(throw_context.get("throw_error_probability", 0.0)),
		"fielder_position": int(throw_context.get("fielder_position", 0)),
		"fielder_arm": float(throw_context.get("fielder_arm", 0.0)),
	}
	if bool(throw_context.get("throwing_error", false)):
		fields["throwing_error"] = true
		fields["is_fielding_error"] = true
		fields["fielding_error_type"] = "throwing"
		fields["error_position"] = int(throw_context.get("fielder_position", 0))
	return fields


static func _throw_contexts_from_advancements(advancements: Array) -> Array:
	var contexts: Array = []
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var throw_context: Dictionary = advancement.get("throw_context", {}) as Dictionary
		if throw_context.is_empty():
			continue
		contexts.append(throw_context.duplicate(true))
	return contexts


static func _extra_advance_probability(
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	outs_before: int,
	physics: Dictionary,
	fielder_position: int,
	fielder_arm: float,
	batter_bases: int
) -> float:
	var speed: float = _ability(runner, "Run_Speed")
	var baserunning: float = _ability(runner, "Run_Judgment")
	var distance: float = float(physics.get("distance", 0.0))
	var hang_time: float = float(physics.get("hang_time", 1.8))
	var spray: float = float(physics.get("spray_angle", 0.0))
	var probability: float = 0.08
	# 走力 z(中立0.78)・走塁判断 z(中立0.42)が高いほど追加進塁を増やす。守備肩も z のまま、強いほど減らす。
	probability += (speed - 0.78) * 0.04
	probability += (baserunning - 0.42) * 0.01875
	probability -= (fielder_arm - FIELDER_ARM_NEUTRAL_Z) * FIELDER_ARM_EXTRA_ADVANCE_WEIGHT_Z
	probability += clamp((distance - 70.0) * 0.0030, -0.05, 0.18)
	probability += clamp((hang_time - 2.0) * 0.035, -0.04, 0.12)
	if _in_gap(spray):
		probability += 0.08
	if outs_before == 2:
		probability += 0.10
	if to_base >= 4:
		probability -= 0.03
	if batter_bases >= 2 and from_base == 1 and to_base >= 4:
		probability += 0.08
	if fielder_position == 8:
		probability -= 0.03
	return clamp(probability, 0.0, 0.56)


static func _advance_out_probability(
	runner: PSPlayerSeasonRecord,
	from_base: int,
	to_base: int,
	physics: Dictionary,
	fielder_arm: float
) -> float:
	var speed: float = _ability(runner, "Run_Speed")
	var distance: float = float(physics.get("distance", 0.0))
	var hang_time: float = float(physics.get("hang_time", 1.8))
	var probability: float = 0.055
	# 守備肩 z が走者の走力 z を上回るほど走塁死が増える。
	probability += (fielder_arm - speed) * FIELDER_ARM_OUT_WEIGHT_Z
	probability -= clamp((distance - 78.0) * 0.0012, -0.025, 0.045)
	probability -= clamp((hang_time - 2.0) * 0.012, -0.025, 0.035)
	if to_base >= 4:
		probability += 0.025
	if from_base == 1 and to_base >= 3:
		probability += 0.010
	return clamp(probability, 0.015, 0.32)


static func _processing_time(physics: Dictionary, fielder_position: int) -> float:
	var trajectory: String = str(physics.get("trajectory_bucket", "liner"))
	var distance: float = float(physics.get("distance", 0.0))
	var hang_time: float = float(physics.get("hang_time", 1.2))
	if trajectory == "grounder":
		return clamp(0.7 + distance / 35.0, 0.8, 4.2)
	var outfield_delay: float = 0.55 if fielder_position >= 7 else 0.25
	return clamp(hang_time + outfield_delay + max(0.0, distance - 55.0) / 70.0, 0.9, 6.4)


static func _ball_depth(physics: Dictionary) -> String:
	var distance: float = float(physics.get("distance", 0.0))
	if distance >= 100.0:
		return "wall"
	if distance >= 72.0:
		return "deep"
	if distance >= 42.0:
		return "medium"
	return "shallow"


static func _in_gap(spray: float) -> bool:
	var abs_spray: float = absf(spray)
	return abs_spray >= 8.0 and abs_spray <= 25.0


# 能力を z-score で返す（0.0 が全体平均）。display 1-100 ではなく z のまま計算に使う。
static func _ability(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	return record.z_ability(key, default_value)
