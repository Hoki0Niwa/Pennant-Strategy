extends RefCounted
class_name PSRunnerActionModel


const EVENT_TYPE_RUNNER_EVENT: String = "runner_event"
const EVENT_TYPE_RUNNER_INTENT: String = "runner_intent"

const VISIBILITY_OBSCURED_BY_BATTED_BALL: String = "obscured_by_batted_ball"
const VISIBILITY_VISIBLE: String = "visible_after_plate_result"

const CATEGORY_WALK: String = "walk"
const CATEGORY_HIT_BY_PITCH: String = "hit_by_pitch"
const CATEGORY_STRIKEOUT: String = "strikeout"
const CATCHER_METRIC_CACHE_KEY: String = "_runner_catcher_metric_cache"

# 盗塁阻止の送球が逸れて走者が生きる「捕手の送球失策」。本来 caught_stealing になる企図の一部を
# 失策に変換する（= reached-on-error 相当。盗塁数を水増しせず捕手にのみ失策を計上）。
# error_position=2 を持つイベントは game_loop.credit_runner_event_errors が拾って捕手の errors に計上する。
const CATCHER_THROW_ERROR_BASE: float = 0.55          # caught_stealing 企図あたりの送球失策率（中立捕手）
const CATCHER_THROW_ERROR_REFERENCE_Z: float = 2.046  # 捕手肩(steal_control) z の中立点
const CATCHER_THROW_ERROR_WEIGHT: float = 0.060       # 肩 z が中立を超える分だけ失策を減らす
const CATCHER_THROW_ERROR_MIN: float = 0.08
const CATCHER_THROW_ERROR_MAX: float = 0.70


static func pre_plate_runner_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	outs: int,
	context: Dictionary = {}
) -> Array:
	if outs >= 3:
		return []
	var material: Array = _pickoff_or_balk_events(event_index, batter, pitcher, defense, bases, context)
	return _sort_lead_runner_first(material)


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
	var is_batted_ball: bool = _is_batted_ball_outcome(outcome)
	var intents: Array = []
	var used_runner_ids: Dictionary = {}

	var double_steal: Array = _double_steal_intents(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not double_steal.is_empty():
		for intent_value in double_steal:
			var intent: Dictionary = intent_value as Dictionary
			used_runner_ids[int(intent.get("runner_id", 0))] = true
			intents.append(intent)

	var hit_and_run: Dictionary = _hit_and_run_intent(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		is_batted_ball
	)
	if not hit_and_run.is_empty() and not used_runner_ids.has(int(hit_and_run.get("runner_id", 0))):
		used_runner_ids[int(hit_and_run.get("runner_id", 0))] = true
		intents.append(hit_and_run)

	for base_index in range(0, 2):
		var runner: PSPlayerSeasonRecord = bases_before[base_index] as PSPlayerSeasonRecord
		if runner == null or used_runner_ids.has(runner.player_id):
			continue
		if base_index + 1 < bases_before.size() and bases_before[base_index + 1] != null:
			continue
		var strategy: String = "delayed_steal" if base_index == 0 and _should_try_delayed_steal(event_index, runner, pitcher, defense, context) else "straight_steal"
		var intent: Dictionary = _steal_intent(
			event_index,
			base_index + 1,
			base_index + 2,
			runner,
			batter,
			pitcher,
			defense,
			outs_before,
			is_batted_ball,
			strategy
		)
		if not intent.is_empty():
			intents.append(intent)
	return intents


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
	var category: String = str(outcome.get("category", "out"))
	var is_batted_ball: bool = _is_batted_ball_outcome(outcome)
	var events: Array = []

	if is_batted_ball:
		var planned_runner_events: Array = outcome.get("runner_events", []) as Array
		if outcome.has("runner_advancements") or not planned_runner_events.is_empty():
			events.append_array(planned_runner_events)
			return _sort_lead_runner_first(events)
		events.append_array(_already_applied_advancement_events(
			event_index,
			batter,
			pitcher,
			defense,
			bases_before,
			bases_after_plate,
			outcome
		))
		if outs_after_plate < 3:
			events.append_array(_batted_ball_extra_base_events(
				event_index,
				batter,
				pitcher,
				defense,
				bases_before,
				bases_after_plate,
				outs_before,
				outs_after_plate,
				outcome
			))
		return _sort_lead_runner_first(events)

	if outs_after_plate >= 3:
		return []

	var intents: Array = runner_intents_for_play(
		event_index,
		batter,
		pitcher,
		defense,
		bases_before,
		outs_before,
		outcome,
		context
	)
	if category == CATEGORY_STRIKEOUT:
		events.append_array(_steal_events_from_intents(event_index, intents, pitcher, defense))

	if events.is_empty():
		events.append_array(_battery_misplay_events(
			event_index,
			batter,
			pitcher,
			defense,
			bases_before,
			bases_after_plate,
			outcome
		))

	if events.is_empty():
		var indifference: Dictionary = _defensive_indifference_event(
			event_index,
			batter,
			pitcher,
			defense,
			bases_after_plate,
			context
		)
		if not indifference.is_empty():
			events.append(indifference)

	return _sort_lead_runner_first(events)


static func _pickoff_or_balk_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array,
	context: Dictionary
) -> Array:
	var runner_entry: Dictionary = _pickoff_target(bases)
	if runner_entry.is_empty():
		return []
	var runner: PSPlayerSeasonRecord = runner_entry.get("runner", null) as PSPlayerSeasonRecord
	var from_base: int = int(runner_entry.get("base", 0))
	if runner == null or from_base <= 0:
		return []

	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var runner_speed: float = _ability(runner, "Run_Speed")
	var runner_stealing: float = _ability(runner, "Run_Steal")
	var control: float = _ability(pitcher, "Pit_BBPrevent")
	# 走者の脅威 z（走力と盗塁技術の平均）。投手の牽制 z が脅威を上回るほど牽制死がわずかに増える。
	var threat: float = (runner_speed + runner_stealing) * 0.5
	var pickoff_out_probability: float = clamp((hold_runners - threat) * 0.0015 + 0.002025, 0.0, 0.006)
	# 制球 z・牽制 z が低い投手ほどボークしやすい。
	var balk_probability: float = clamp((1.44 - control) * 0.000625 - (0.488 + hold_runners) * 0.000375, 0.0, 0.002)
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if pitcher == null else pitcher.player_id,
		from_base,
		_hash_string(str(context.get("half", ""))),
		1103,
	])
	if roll < balk_probability:
		return _balk_events(event_index, batter, pitcher, defense, bases)
	if roll < balk_probability + pickoff_out_probability:
		return [_runner_event(
			"before_pitch",
			"pickoff",
			"pickoff",
			runner,
			batter,
			pitcher,
			defense,
			from_base,
			from_base,
			false,
			1
		)]
	return []


static func _balk_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases: Array
) -> Array:
	var events: Array = []
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		events.append(_runner_event(
			"before_pitch",
			"balk",
			"balk",
			runner,
			batter,
			pitcher,
			defense,
			base_index + 1,
			base_index + 2,
			false,
			0
		))
	return events


static func _double_steal_intents(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	is_batted_ball: bool
) -> Array:
	if bases_before.size() < 3 or bases_before[0] == null or bases_before[1] == null or bases_before[2] != null:
		return []
	var runner_first: PSPlayerSeasonRecord = bases_before[0] as PSPlayerSeasonRecord
	var runner_second: PSPlayerSeasonRecord = bases_before[1] as PSPlayerSeasonRecord
	var catcher_arm: float = _catcher_steal_control(defense)
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	# スコア(z): 各走者の盗塁技術+走力で加点、投手牽制と捕手肩で減点。
	var score: float = (
		(_ability(runner_first, "Run_Steal") + _ability(runner_first, "Run_Speed")) * 0.24
		+ (_ability(runner_second, "Run_Steal") + _ability(runner_second, "Run_Speed")) * 0.34
		- catcher_arm * 0.34
		- hold_runners * 0.24
	)
	if outs_before == 2:
		score += 0.24
	# 中立点(z -0.865)からのスコア差で確率を決める。
	var probability: float = clamp(0.020 + (score + 0.865) * 0.075, 0.0, 0.260)
	probability = clamp(probability, 0.0, 0.42)
	var roll: float = _deterministic_unit([
		event_index,
		runner_first.player_id,
		runner_second.player_id,
		0 if pitcher == null else pitcher.player_id,
		2203,
	])
	if roll >= probability:
		return []
	var group_id: String = "ds_%d_%d_%d" % [event_index, runner_second.player_id, runner_first.player_id]
	return [
		_make_intent(event_index, 2, 3, runner_second, batter, pitcher, defense, score, probability, is_batted_ball, "double_steal", group_id),
		_make_intent(event_index, 1, 2, runner_first, batter, pitcher, defense, score, probability, is_batted_ball, "double_steal", group_id),
	]


static func _hit_and_run_intent(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	is_batted_ball: bool
) -> Dictionary:
	if outs_before >= 2 or bases_before.is_empty() or bases_before[0] == null:
		return {}
	if bases_before.size() > 1 and bases_before[1] != null:
		return {}
	var runner: PSPlayerSeasonRecord = bases_before[0] as PSPlayerSeasonRecord
	var contact: float = _ability(batter, "Bat_Barrel")
	var avoid_k: float = _ability(batter, "Bat_KAvoid")
	var power: float = _ability(batter, "Bat_Impact")
	var runner_speed: float = _ability(runner, "Run_Speed")
	# スコア(z): 芯・三振回避・走者走力で加点、長打力で減点（強打者はエンドランしにくい）。
	var score: float = contact * 0.35 + avoid_k * 0.35 + runner_speed * 0.20 - power * 0.18
	var probability: float = clamp(0.010 + (score + 0.194) * 0.05, 0.0, 0.150)
	probability = clamp(probability, 0.0, 0.27)
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if batter == null else batter.player_id,
		3307,
	])
	if roll >= probability:
		return {}
	return _make_intent(event_index, 1, 2, runner, batter, pitcher, defense, score, probability, is_batted_ball, "hit_and_run", "")


static func _should_try_delayed_steal(
	event_index: int,
	runner: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	context: Dictionary
) -> bool:
	var catcher_arm: float = _catcher_steal_control(defense)
	# スコア(z): 走力・盗塁技術で加点、投手牽制・捕手肩で減点。
	var score: float = (
		_ability(runner, "Run_Speed") * 0.45
		+ _ability(runner, "Run_Steal") * 0.35
		- _ability(pitcher, "Pit_HoldRunner") * 0.25
		- catcher_arm * 0.40
	)
	var probability: float = clamp(0.006 + (score - 0.197) * 0.0375, 0.0, 0.120)
	probability = clamp(probability, 0.0, 0.20)
	return _deterministic_unit([event_index, runner.player_id, catcher_arm, _hash_string(str(context.get("half", ""))), 4409]) < probability


static func _steal_intent(
	event_index: int,
	from_base: int,
	to_base: int,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	outs_before: int,
	is_batted_ball: bool,
	strategy: String
) -> Dictionary:
	var stealing: float = _ability(runner, "Run_Steal")
	var speed: float = _ability(runner, "Run_Speed")
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var catcher_arm: float = _catcher_steal_control(defense)
	var batter_power: float = _ability(batter, "Bat_Impact")
	# スコア(z): 盗塁技術・走力で加点、投手牽制・捕手肩で減点。
	var score: float = (
		stealing * 0.55
		+ speed * 0.45
		- hold_runners * 0.35
		- catcher_arm * 0.30
	)
	if outs_before == 2:
		score += 0.32
	if from_base == 2:
		score -= 0.64
	if strategy == "delayed_steal":
		score -= 0.40
	if batter_power >= 2.0:
		score -= 0.40
	# 中立点(z -0.217)からのスコア差で確率を決める。
	var probability: float = clamp(0.060 + (score + 0.217) * 0.125, 0.0, 0.560)
	probability = clamp(probability, 0.0, 0.72)
	var roll: float = _deterministic_unit([
		event_index,
		from_base,
		runner.player_id,
		0 if batter == null else batter.player_id,
		0 if pitcher == null else pitcher.player_id,
		_hash_string(strategy),
	])
	if roll >= probability:
		return {}
	return _make_intent(event_index, from_base, to_base, runner, batter, pitcher, defense, score, probability, is_batted_ball, strategy, "")


static func _make_intent(
	event_index: int,
	from_base: int,
	to_base: int,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	score: float,
	probability: float,
	is_batted_ball: bool,
	strategy: String,
	group_id: String
) -> Dictionary:
	return {
		"event_type": EVENT_TYPE_RUNNER_INTENT,
		"intent_type": "steal" if strategy != "hit_and_run" else "hit_and_run",
		"strategy": strategy,
		"group_id": group_id,
		"phase": "on_pitch",
		"runner_id": runner.player_id,
		"batter_id": 0 if batter == null else batter.player_id,
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"catcher_id": _catcher_id(defense),
		"from_base": from_base,
		"to_base": to_base,
		"intent_score": round(score * 100.0) / 100.0,
		"attempt_probability": round(probability * 10000.0) / 10000.0,
		"visibility": VISIBILITY_OBSCURED_BY_BATTED_BALL if is_batted_ball else VISIBILITY_VISIBLE,
		"recorded_as_attempt": false,
		"obscured_by_batted_ball": is_batted_ball,
		"stage": 5,
	}


static func _steal_events_from_intents(
	event_index: int,
	intents: Array,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary
) -> Array:
	var events: Array = []
	for intent_value in intents:
		var intent: Dictionary = intent_value as Dictionary
		if bool(intent.get("obscured_by_batted_ball", false)):
			continue
		events.append(_runner_event_from_intent(event_index, intent, pitcher, defense))
	var any_caught: bool = false
	for event_value in events:
		var event: Dictionary = event_value as Dictionary
		if bool(event.get("is_caught_stealing", false)):
			any_caught = true
			break
	if events.size() > 1 and any_caught:
		for event_value in events:
			var event: Dictionary = event_value as Dictionary
			if bool(event.get("is_stolen_base", false)):
				event["result"] = "advance_on_double_steal_caught"
				event["is_stolen_base"] = false
	return events


static func _runner_event_from_intent(
	event_index: int,
	intent: Dictionary,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary
) -> Dictionary:
	var runner_id: int = int(intent.get("runner_id", 0))
	var from_base: int = int(intent.get("from_base", 0))
	var to_base: int = int(intent.get("to_base", 0))
	var stealing_score: float = float(intent.get("intent_score", 0.0))
	var hold_runners: float = _ability(pitcher, "Pit_HoldRunner")
	var catcher_arm: float = _catcher_steal_control(defense)
	var strategy: String = str(intent.get("strategy", "straight_steal"))
	var success_probability: float = 0.72
	# 企図スコア(z)が高いほど成功、投手牽制 z(中立0.712)・捕手肩 z(中立2.046)が高いほど失敗。
	success_probability += (stealing_score - 0.583) * 0.1
	success_probability -= (hold_runners - 0.712) * 0.015
	success_probability -= (catcher_arm - 2.046) * 0.035
	if strategy == "delayed_steal":
		success_probability -= 0.05
	elif strategy == "double_steal" and from_base == 2:
		success_probability -= 0.04
	success_probability = clamp(success_probability, 0.45, 0.88)
	var roll: float = _deterministic_unit([
		event_index,
		from_base,
		to_base,
		runner_id,
		int(success_probability * 10000.0),
		_hash_string(strategy),
		5501,
	])
	var success: bool = roll < success_probability
	# 本来 caught_stealing になる送球の一部が逸れ、走者が生きる（捕手の送球失策）。肩 z が低いほど増える。
	var throwing_error: bool = false
	if not success:
		var error_chance: float = clamp(
			CATCHER_THROW_ERROR_BASE - (catcher_arm - CATCHER_THROW_ERROR_REFERENCE_Z) * CATCHER_THROW_ERROR_WEIGHT,
			CATCHER_THROW_ERROR_MIN,
			CATCHER_THROW_ERROR_MAX
		)
		throwing_error = _deterministic_unit([event_index, from_base, to_base, runner_id, 9901]) < error_chance
	var runner_safe: bool = success or throwing_error
	var result_label: String = "stolen_base" if success else ("caught_stealing_throwing_error" if throwing_error else "caught_stealing")
	var runner_stub: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	runner_stub.player_id = runner_id
	return _runner_event(
		"after_plate_result",
		strategy,
		result_label,
		runner_stub,
		null,
		pitcher,
		defense,
		from_base,
		to_base,
		true,
		0 if runner_safe else 1,
		{
			"batter_id": int(intent.get("batter_id", 0)),
			"group_id": str(intent.get("group_id", "")),
			"is_stolen_base": success,
			"is_caught_stealing": not runner_safe,
			"is_fielding_error": throwing_error,
			"error_position": 2 if throwing_error else 0,
			"success_probability": round(success_probability * 10000.0) / 10000.0,
			"recorded_as_attempt": true,
		}
	)


static func _battery_misplay_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outcome: Dictionary
) -> Array:
	var runner_entry: Dictionary = _highest_original_runner_on_base(bases_before, bases_after_plate)
	if runner_entry.is_empty():
		return []
	var runner: PSPlayerSeasonRecord = runner_entry.get("runner", null) as PSPlayerSeasonRecord
	var from_base: int = int(runner_entry.get("base", 0))
	if runner == null or from_base <= 0:
		return []
	var control: float = _ability(pitcher, "Pit_BBPrevent")
	var stuff: float = _ability(pitcher, "Pit_KCreate")
	var catcher_blocking: float = _catcher_blocking(defense)
	var catcher_game_call: float = _catcher_game_call(defense)
	# 制球 z が低い・球威 z が高い投手、捕球 z・配球 z が低い捕手ほど暴投が増える。各中立点は wild_pitch 用にずらしてある。
	var wild_probability: float = clamp(
		0.002
		+ (1.44 - control) * 0.003125
		+ (stuff - 1.776) * 0.001
		- (catcher_blocking - 2.473) * 0.001
		- (catcher_game_call - 2.56) * 0.0005,
		0.0005,
		0.018
	)
	# 捕球 z が低い捕手ほど捕逸が増える。
	var passed_probability: float = clamp(0.001 + (2.473 - catcher_blocking) * 0.004, 0.0, 0.012)
	var roll: float = _deterministic_unit([
		event_index,
		runner.player_id,
		0 if pitcher == null else pitcher.player_id,
		_hash_string(str(outcome.get("category", ""))),
		6607,
	])
	if roll >= wild_probability + passed_probability:
		return []
	var result: String = "wild_pitch" if roll < wild_probability else "passed_ball"
	return [_runner_event(
		"after_plate_result",
		result,
		result,
		runner,
		batter,
		pitcher,
		defense,
		from_base,
		from_base + 1,
		false,
		0,
		{
			"is_wild_pitch": result == "wild_pitch",
			"is_passed_ball": result == "passed_ball",
		}
	)]


static func _defensive_indifference_event(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_after_plate: Array,
	context: Dictionary
) -> Dictionary:
	var inning: int = int(context.get("inning", 0))
	var defense_lead: int = int(context.get("defense_score", 0)) - int(context.get("offense_score", 0))
	if inning < 8 or defense_lead < 2:
		return {}
	for base_index in range(0, 2):
		var runner: PSPlayerSeasonRecord = bases_after_plate[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		if bases_after_plate[base_index + 1] != null:
			continue
		var probability: float = clamp(0.015 + float(defense_lead - 1) * 0.01, 0.0, 0.12)
		if _deterministic_unit([event_index, runner.player_id, defense_lead, 7703]) >= probability:
			return {}
		return _runner_event(
			"after_plate_result",
			"defensive_indifference",
			"defensive_indifference",
			runner,
			batter,
			pitcher,
			defense,
			base_index + 1,
			base_index + 2,
			false,
			0,
			{"is_defensive_indifference": true}
		)
	return {}


static func _batted_ball_extra_base_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outs_before: int,
	outs_after_plate: int,
	outcome: Dictionary
) -> Array:
	var category: String = str(outcome.get("category", "out"))
	if category != "hit" and int(outcome.get("bases", 0)) <= 0:
		return []
	if outs_after_plate >= 3:
		return []
	var events: Array = []
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var current_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		if current_base <= before_index + 1 or current_base <= 0:
			continue
		var to_base: int = current_base + 1
		if to_base <= 3 and bases_after_plate[to_base - 1] != null:
			continue
		var speed: float = _ability(runner, "Run_Speed")
		var outfield_arm: float = _fielder_throwing_for_outcome(defense, outcome)
		# 走力 z(中立0.78)が高いほど追加進塁、外野肩 z(中立0.272)が高いほど抑制。
		var probability: float = clamp(0.02 + (speed - 0.78) * 0.03125 - (outfield_arm - 0.272) * 0.01875, 0.0, 0.28)
		if outs_before == 2:
			probability += 0.08
		if to_base >= 4:
			probability -= 0.02
		var roll: float = _deterministic_unit([
			event_index,
			runner.player_id,
			current_base,
			to_base,
			_hash_string(str(outcome.get("result", ""))),
			8807,
		])
		if roll >= probability:
			continue
		# 外野肩 z が走者走力 z を上回るほど走塁死。
		var out_probability: float = clamp(0.06 + (outfield_arm - speed) * 0.025, 0.02, 0.22)
		var out_roll: float = _deterministic_unit([event_index, runner.player_id, current_base, to_base, 8819])
		var runner_out: bool = out_roll < out_probability
		events.append(_runner_event(
			"after_batted_ball",
			"runner_out_advancing" if runner_out else "extra_base_on_hit",
			"runner_out_advancing" if runner_out else "extra_base_on_hit",
			runner,
			batter,
			pitcher,
			defense,
			current_base,
			to_base,
			false,
			1 if runner_out else 0,
			{
				"is_baserunning_out": runner_out,
				"batter_rbi": not runner_out and to_base >= 4,
			}
		))
		break
	return events


static func _already_applied_advancement_events(
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	bases_before: Array,
	bases_after_plate: Array,
	outcome: Dictionary
) -> Array:
	var category: String = str(outcome.get("category", "out"))
	if category != "sacrifice_fly" and category != "sacrifice" and category != "productive_out":
		return []
	var events: Array = []
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var after_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		var from_base: int = before_index + 1
		var to_base: int = after_base if after_base > 0 else 4
		if to_base <= from_base:
			continue
		var strategy: String = "tag_up" if category == "sacrifice_fly" else "sacrifice_advance"
		if str(outcome.get("runner_strategy", "")) == "squeeze" and from_base == 3 and to_base >= 4:
			strategy = "squeeze"
		events.append(_runner_event(
			"after_batted_ball",
			strategy,
			strategy,
			runner,
			batter,
			pitcher,
			defense,
			from_base,
			to_base,
			false,
			0,
			{"state_already_applied": true}
		))
	return events


static func _runner_event(
	phase: String,
	strategy: String,
	result: String,
	runner: PSPlayerSeasonRecord,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	defense: Dictionary,
	from_base: int,
	to_base: int,
	is_steal_attempt: bool,
	outs_added: int,
	extra: Dictionary = {}
) -> Dictionary:
	var event: Dictionary = {
		"event_type": EVENT_TYPE_RUNNER_EVENT,
		"phase": phase,
		"strategy": strategy,
		"runner_id": 0 if runner == null else runner.player_id,
		"batter_id": int(extra.get("batter_id", 0 if batter == null else batter.player_id)),
		"pitcher_id": 0 if pitcher == null else pitcher.player_id,
		"catcher_id": _catcher_id(defense),
		"from_base": from_base,
		"to_base": to_base,
		"result": result,
		"is_steal_attempt": is_steal_attempt,
		"is_stolen_base": bool(extra.get("is_stolen_base", result == "stolen_base")),
		"is_caught_stealing": bool(extra.get("is_caught_stealing", result == "caught_stealing")),
		"is_pickoff": result == "pickoff",
		"is_wild_pitch": bool(extra.get("is_wild_pitch", false)),
		"is_passed_ball": bool(extra.get("is_passed_ball", false)),
		"is_balk": result == "balk",
		"is_defensive_indifference": bool(extra.get("is_defensive_indifference", false)),
		"is_baserunning_out": bool(extra.get("is_baserunning_out", false)),
		"recorded_as_attempt": bool(extra.get("recorded_as_attempt", is_steal_attempt)),
		"state_already_applied": bool(extra.get("state_already_applied", false)),
		"outs_added": outs_added,
		"run_value": 0.0,
	}
	for key_value in extra.keys():
		event[key_value] = extra[key_value]
	return event


static func _is_batted_ball_outcome(outcome: Dictionary) -> bool:
	var category: String = str(outcome.get("category", "out"))
	return category != CATEGORY_WALK and category != CATEGORY_HIT_BY_PITCH and category != CATEGORY_STRIKEOUT


static func _pickoff_target(bases: Array) -> Dictionary:
	for base_index in [0, 1]:
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner != null:
			return {"base": base_index + 1, "runner": runner}
	return {}


static func _highest_original_runner_on_base(bases_before: Array, bases_after_plate: Array) -> Dictionary:
	for before_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases_before[before_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var current_base: int = _base_for_runner_id(bases_after_plate, runner.player_id)
		if current_base > 0 and current_base < 4:
			return {"base": current_base, "runner": runner}
	return {}


static func _base_for_runner_id(bases: Array, runner_id: int) -> int:
	if runner_id <= 0:
		return 0
	for index in range(bases.size()):
		var runner: PSPlayerSeasonRecord = bases[index] as PSPlayerSeasonRecord
		if runner != null and runner.player_id == runner_id:
			return index + 1
	return 0


static func _sort_lead_runner_first(events: Array) -> Array:
	events.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("from_base", 0)) > int((b as Dictionary).get("from_base", 0))
	)
	return events


static func _catcher_id(defense: Dictionary) -> int:
	return int(_catcher_metrics(defense).get("id", 0))


# 捕手の盗塁抑止力を z で返す（0.0 が全体平均）。
static func _catcher_steal_control(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("steal_control", 0.0))


# 捕手の捕逸抑止力を z で返す。
static func _catcher_blocking(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("blocking", 0.0))


# 捕手の配球(ゲームコール)を z で返す。
static func _catcher_game_call(defense: Dictionary) -> float:
	return float(_catcher_metrics(defense).get("game_call", 0.0))


static func _catcher_metrics(defense: Dictionary) -> Dictionary:
	var cache: Dictionary = defense.get(CATCHER_METRIC_CACHE_KEY, {}) as Dictionary
	if not defense.has(CATCHER_METRIC_CACHE_KEY):
		defense[CATCHER_METRIC_CACHE_KEY] = cache
	var catcher: PSPlayerSeasonRecord = _catcher_record(defense)
	if catcher == null:
		if not cache.has("0"):
			cache["0"] = {
				"id": 0,
				"steal_control": 0.0,
				"blocking": 0.0,
				"game_call": 0.0,
			}
		return cache["0"] as Dictionary
	var cache_key: String = str(catcher.player_id)
	if cache.has(cache_key):
		return cache[cache_key] as Dictionary
	# 守備の安定(C_FieldSecure)と配球(C_GameCall)。盗塁抑止/捕逸抑止はこれらと肩/ブロックの z 加重平均。
	var field_secure: float = _ability(catcher, "C_FieldSecure")
	var game_call: float = _ability(catcher, "C_GameCall")
	var metrics: Dictionary = {
		"id": catcher.player_id,
		"steal_control": _weighted_z([
			_ability(catcher, "C_Throw"),
			field_secure,
			game_call,
		], [0.65, 0.18, 0.17]),
		"blocking": _weighted_z([
			_ability(catcher, "C_Blocking"),
			field_secure,
			game_call,
		], [0.75, 0.15, 0.10]),
		"game_call": game_call,
	}
	cache[cache_key] = metrics
	return metrics


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


# 打球を処理した野手の送球力(肩)を z で返す。外野=OF_ArmPower / 内野=IF_ThrowPower。投手/捕手は中立。
static func _fielder_throwing_for_outcome(defense: Dictionary, outcome: Dictionary) -> float:
	var position: int = int(outcome.get("fielder_position", 0))
	if position <= 0:
		return 0.0
	var fielders: Array = defense.get("fielders", []) as Array
	for slot_value in fielders:
		var slot: Dictionary = slot_value as Dictionary
		if int(slot.get("position", 0)) != position:
			continue
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			return 0.0
		if position >= 7:
			return _ability(record, "OF_ArmPower")
		if position >= 3:
			return _ability(record, "IF_ThrowPower")
		return 0.0
	return 0.0


# 能力を z-score で返す（0.0 が全体平均）。display 1-100 ではなく z のまま走塁計算に使う。
static func _ability(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	return record.z_ability(key, default_value)


# z 値の加重平均を返す（重みの和で正規化）。捕手能力の合成に使う。
static func _weighted_z(values: Array, weights: Array) -> float:
	var total: float = 0.0
	var weight_total: float = 0.0
	var n: int = min(values.size(), weights.size())
	for i in range(n):
		var weight: float = float(weights[i])
		total += float(values[i]) * weight
		weight_total += weight
	if weight_total <= 0.0:
		return 0.0
	return total / weight_total


static func _deterministic_unit(values: Array) -> float:
	var seed: int = 811
	for value in values:
		seed = int(abs((seed * 1103515245 + int(value) * 12345 + 1013904223) % 2147483647))
	return float(seed % 10000) / 10000.0


static func _hash_string(value: String) -> int:
	var hash_value: int = 0
	for index in range(value.length()):
		hash_value = int(abs((hash_value * 31 + value.unicode_at(index)) % 2147483647))
	return hash_value
