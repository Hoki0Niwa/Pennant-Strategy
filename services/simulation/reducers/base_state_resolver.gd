extends RefCounted
class_name PSBaseStateResolver


static func advance_walk(batter: PSPlayerSeasonRecord, bases: Array) -> int:
	var runs: int = 0
	if bases[0] == null:
		bases[0] = batter
		return runs
	if bases[1] == null:
		bases[1] = bases[0]
		bases[0] = batter
		return runs
	if bases[2] != null:
		_score_runner(bases[2] as PSPlayerSeasonRecord)
		runs += 1
	bases[2] = bases[1]
	bases[1] = bases[0]
	bases[0] = batter
	return runs


static func advance_hit(batter: PSPlayerSeasonRecord, bases: Array, bases_taken: int) -> int:
	var runs: int = 0
	for index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		bases[index] = null
		var next_base: int = index + bases_taken
		if next_base >= 3:
			_score_runner(runner)
			runs += 1
		else:
			bases[next_base] = runner

	if bases_taken >= 4:
		_score_runner(batter)
		runs += 1
	else:
		bases[bases_taken - 1] = batter
	return runs


static func advance_hit_with_plan(
	batter: PSPlayerSeasonRecord,
	bases: Array,
	bases_taken: int,
	advancements: Array
) -> Dictionary:
	if advancements.is_empty():
		return {"runs": advance_hit(batter, bases, bases_taken), "outs": 0}

	var runs: int = 0
	var outs: int = 0
	for index in range(3):
		bases[index] = null

	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		if runner == null:
			continue
		if bool(advancement.get("is_out", false)):
			outs += 1
			continue
		var to_base: int = int(advancement.get("to_base", 0))
		if to_base >= 4:
			_score_runner(runner)
			runs += 1
		elif to_base >= 1 and to_base <= 3:
			bases[to_base - 1] = runner

	if bases_taken >= 4:
		_score_runner(batter)
		runs += 1
	elif bases_taken >= 1 and bases_taken <= 3:
		bases[bases_taken - 1] = batter
	return {"runs": runs, "outs": outs}


static func advance_fielders_choice(batter: PSPlayerSeasonRecord, bases: Array, outcome: Dictionary) -> Dictionary:
	var advancements: Array = outcome.get("runner_advancements", []) as Array
	if advancements.is_empty():
		var force_from_base: int = int(outcome.get("force_out_from_base", 1))
		var force_to_base: int = int(outcome.get("force_out_to_base", force_from_base + 1))
		advancements = _default_fielders_choice_advancements(bases, force_from_base, force_to_base)

	var runs: int = 0
	var outs: int = 0
	for index in range(3):
		bases[index] = null

	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		if runner == null:
			continue
		if bool(advancement.get("is_out", false)):
			outs += 1
			continue
		var to_base: int = int(advancement.get("to_base", 0))
		if to_base >= 4:
			_score_runner(runner)
			runs += 1
		elif to_base >= 1 and to_base <= 3:
			bases[to_base - 1] = runner

	var batter_base: int = int(clamp(int(outcome.get("bases", 1)), 1, 3))
	if batter != null and bases[batter_base - 1] == null:
		bases[batter_base - 1] = batter
	var outs_result: int = outs
	if outcome.has("fielders_choice_outs"):
		outs_result = int(outcome.get("fielders_choice_outs", outs))
	else:
		outs_result = max(1, outs)
	return {"runs": runs, "outs": max(0, outs_result)}


static func _default_fielders_choice_advancements(bases: Array, force_from_base: int, force_to_base: int) -> Array:
	var advancements: Array = []
	for base_index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[base_index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		var from_base: int = base_index + 1
		var to_base: int = from_base
		var is_out: bool = from_base == force_from_base
		if is_out:
			to_base = force_to_base
		elif from_base < force_from_base:
			to_base = from_base + 1
		advancements.append({
			"runner": runner,
			"runner_id": runner.player_id,
			"from_base": from_base,
			"to_base": to_base,
			"baseline_to": from_base,
			"is_out": is_out,
			"is_extra": to_base > from_base,
		})
	return advancements


static func advance_error(batter: PSPlayerSeasonRecord, bases: Array, bases_taken: int = 1) -> int:
	# 失策。打者は bases_taken まで進む（送球失策・外野後逸では二塁まで）。既存走者も同数進塁。
	return advance_hit(batter, bases, clamp(bases_taken, 1, 3))


static func advance_hit_by_pitch(batter: PSPlayerSeasonRecord, bases: Array) -> int:
	return advance_walk(batter, bases)


static func advance_sacrifice(bases: Array) -> int:
	return advance_runners_one_base(bases)


static func advance_productive_out(bases: Array) -> int:
	return advance_runners_one_base(bases)


static func advance_out_with_plan(bases: Array, outcome: Dictionary) -> int:
	var planned_advancements: Array = outcome.get("runner_advancements", []) as Array
	if planned_advancements.is_empty():
		return 0
	return _advance_existing_runners_with_plan(bases, planned_advancements)


static func advance_sacrifice_fly(bases: Array, outcome: Dictionary = {}) -> int:
	var planned_advancements: Array = outcome.get("runner_advancements", []) as Array
	if not planned_advancements.is_empty():
		return _advance_existing_runners_with_plan(bases, planned_advancements)

	var runs: int = 0
	var runner_on_third: PSPlayerSeasonRecord = bases[2] as PSPlayerSeasonRecord
	if runner_on_third != null:
		bases[2] = null
		_score_runner(runner_on_third)
		runs += 1
	var runner_on_second: PSPlayerSeasonRecord = bases[1] as PSPlayerSeasonRecord
	if runner_on_second != null and bases[2] == null and Rng.roll_float() < 0.35:
		bases[2] = runner_on_second
		bases[1] = null
	return runs


static func _advance_existing_runners_with_plan(bases: Array, advancements: Array) -> int:
	var runs: int = 0
	for advancement_value in advancements:
		var advancement: Dictionary = advancement_value as Dictionary
		var runner: PSPlayerSeasonRecord = advancement.get("runner", null) as PSPlayerSeasonRecord
		var runner_id: int = int(advancement.get("runner_id", 0 if runner == null else runner.player_id))
		var from_base: int = int(advancement.get("from_base", 0))
		var to_base: int = int(advancement.get("to_base", 0))
		if runner == null:
			runner = _runner_from_plan(bases, from_base, runner_id)
		if runner == null:
			continue
		var current_index: int = _base_index_for_runner(bases, runner, from_base, runner_id)
		if current_index >= 0:
			bases[current_index] = null
		if bool(advancement.get("is_out", false)):
			continue
		if to_base >= 4:
			_score_runner(runner)
			runs += 1
		elif to_base >= 1 and to_base <= 3:
			bases[to_base - 1] = runner
	return runs


static func _runner_from_plan(bases: Array, from_base: int, runner_id: int) -> PSPlayerSeasonRecord:
	if from_base >= 1 and from_base <= 3:
		var runner: PSPlayerSeasonRecord = bases[from_base - 1] as PSPlayerSeasonRecord
		if runner != null and (runner_id <= 0 or runner.player_id == runner_id):
			return runner
	for base_value in bases:
		var runner: PSPlayerSeasonRecord = base_value as PSPlayerSeasonRecord
		if runner != null and (runner_id <= 0 or runner.player_id == runner_id):
			return runner
	return null


static func _base_index_for_runner(
	bases: Array,
	runner: PSPlayerSeasonRecord,
	from_base: int,
	runner_id: int
) -> int:
	if from_base >= 1 and from_base <= 3:
		var preferred: PSPlayerSeasonRecord = bases[from_base - 1] as PSPlayerSeasonRecord
		if preferred != null and _same_runner(preferred, runner, runner_id):
			return from_base - 1
	for index in range(3):
		var base_runner: PSPlayerSeasonRecord = bases[index] as PSPlayerSeasonRecord
		if base_runner != null and _same_runner(base_runner, runner, runner_id):
			return index
	return -1


static func _same_runner(a: PSPlayerSeasonRecord, b: PSPlayerSeasonRecord, runner_id: int) -> bool:
	if a == null or b == null:
		return false
	if runner_id > 0:
		return a.player_id == runner_id
	return a == b


static func advance_runners_one_base(bases: Array) -> int:
	var runs: int = 0
	for index in range(2, -1, -1):
		var runner: PSPlayerSeasonRecord = bases[index] as PSPlayerSeasonRecord
		if runner == null:
			continue
		bases[index] = null
		var next_base: int = index + 1
		if next_base >= 3:
			_score_runner(runner)
			runs += 1
		elif bases[next_base] == null:
			bases[next_base] = runner
		else:
			bases[index] = runner
	return runs


static func apply_double_play(bases: Array, current_outs: int) -> int:
	var outs_added: int = 1
	if current_outs <= 1 and bases[0] != null:
		bases[0] = null
		outs_added = 2
	return int(min(3 - current_outs, outs_added))


static func apply_runner_event(bases: Array, current_outs: int, runner_event: Dictionary) -> Dictionary:
	var result: String = str(runner_event.get("result", "advance"))
	var from_base: int = int(runner_event.get("from_base", 0))
	var to_base: int = int(runner_event.get("to_base", 0))
	var outs_added: int = 0
	var runs: int = 0
	if from_base < 1 or from_base > 3:
		return {"outs": 0, "runs": 0}
	var runner: PSPlayerSeasonRecord = bases[from_base - 1] as PSPlayerSeasonRecord
	if runner == null:
		return {"outs": 0, "runs": 0}

	match result:
		"caught_stealing", "pickoff", "runner_out", "runner_out_advancing":
			bases[from_base - 1] = null
			outs_added = int(min(3 - current_outs, 1))
		"stolen_base", "advance_on_double_steal_caught", "defensive_indifference", "wild_pitch", "passed_ball", "balk", "extra_base_on_hit", "advance_on_throw", "tag_up", "sacrifice_advance", "advance":
			bases[from_base - 1] = null
			if to_base >= 4:
				_score_runner(runner)
				runs += 1
			elif to_base >= 1 and to_base <= 3 and bases[to_base - 1] == null:
				bases[to_base - 1] = runner
			else:
				bases[from_base - 1] = runner
		_:
			return {"outs": 0, "runs": 0}

	return {
		"outs": outs_added,
		"runs": runs,
	}


static func _score_runner(runner: PSPlayerSeasonRecord) -> void:
	if runner != null:
		runner.batter_stats.runs += 1
