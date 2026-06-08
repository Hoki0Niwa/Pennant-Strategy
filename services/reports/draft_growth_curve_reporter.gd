extends RefCounted
class_name PSDraftGrowthCurveReporter

const DraftService = preload("res://services/season/draft_service.gd")
const Offseason = preload("res://services/season/offseason_service.gd")

const VERSION: int = 4
const DEFAULT_SAMPLES: int = 50000
const DEFAULT_MIN_AGE: int = 18
const DEFAULT_MAX_AGE: int = 36
const DEFAULT_SEED: int = 20260528

const SOURCE_ORDER: Array = [
	"high_school",
	"university",
	"industrial",
	"independent",
]

const SOURCE_LABELS: Dictionary = {
	"high_school": "high_school",
	"university": "university",
	"industrial": "industrial",
	"independent": "independent",
}

const GROWTH_KIND_ORDER: Array = [
	"awakening",
	"growth",
	"stagnation",
	"decline",
	"major_decline",
]
const PLAYER_GROUP_ORDER: Array = ["all", "pitcher", "fielder"]


func run(options: Dictionary = {}) -> Dictionary:
	var seed: int = int(options.get("seed", DEFAULT_SEED))
	var samples: int = max(1, int(options.get("samples", DEFAULT_SAMPLES)))
	var min_age: int = clampi(int(options.get("min_age", DEFAULT_MIN_AGE)), 1, 99)
	var max_age: int = clampi(int(options.get("max_age", DEFAULT_MAX_AGE)), min_age, 99)
	Rng.set_seed_value(seed)

	var groups: Dictionary = {}
	var split_groups: Dictionary = {}
	var candidates: Array = DraftService._generate_candidate_pool(samples)
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value as Dictionary
		var source_type: String = str(candidate.get("source_type", "unknown"))
		if not groups.has(source_type):
			groups[source_type] = _new_group(source_type)
		var player_group: String = _player_group_for_position(int(candidate.get("position", 0)))
		var target_groups: Array = [groups[source_type] as Dictionary, _ensure_split_group(split_groups, source_type, player_group)]
		_simulate_candidate(candidate, target_groups, min_age, max_age)

	var source_order: Array = _source_order(groups)
	var sources: Dictionary = {}
	var source_position_splits: Dictionary = {}
	for source_value in source_order:
		var source_type: String = str(source_value)
		sources[source_type] = _finalize_group(groups[source_type] as Dictionary, min_age, max_age)
		source_position_splits[source_type] = _finalize_split_groups(split_groups, source_type, min_age, max_age)

	return {
		"ok": true,
		"version": VERSION,
		"seed": seed,
		"samples_requested": samples,
		"candidates_generated": candidates.size(),
		"min_age": min_age,
		"max_age": max_age,
		"method": "Generate draft candidates with DraftService, then aggregate simulated growth by attained age instead of elapsed years.",
		"source_order": source_order,
		"player_group_order": PLAYER_GROUP_ORDER.duplicate(),
		"sources": sources,
		"source_position_splits": source_position_splits,
	}


func run_async(options: Dictionary = {}) -> Dictionary:
	var seed: int = int(options.get("seed", DEFAULT_SEED))
	var samples: int = max(1, int(options.get("samples", DEFAULT_SAMPLES)))
	var min_age: int = clampi(int(options.get("min_age", DEFAULT_MIN_AGE)), 1, 99)
	var max_age: int = clampi(int(options.get("max_age", DEFAULT_MAX_AGE)), min_age, 99)
	var tree: SceneTree = options.get("scene_tree") as SceneTree
	var progress_cb: Callable = options.get("progress_callback", Callable())
	var cancel_token: Dictionary = options.get("cancel_token", {})
	var chunk_size: int = max(1, int(options.get("chunk_size", 250)))

	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	Rng.set_seed_value(seed)

	var groups: Dictionary = {}
	var split_groups: Dictionary = {}
	var generated: int = 0
	for i in range(samples):
		if _is_cancelled(cancel_token):
			break
		var candidate: Dictionary = DraftService._generate_candidate(i + 1)
		generated += 1
		var source_type: String = str(candidate.get("source_type", "unknown"))
		if not groups.has(source_type):
			groups[source_type] = _new_group(source_type)
		var player_group: String = _player_group_for_position(int(candidate.get("position", 0)))
		var target_groups: Array = [groups[source_type] as Dictionary, _ensure_split_group(split_groups, source_type, player_group)]
		_simulate_candidate(candidate, target_groups, min_age, max_age)
		if progress_cb.is_valid() and (generated % chunk_size == 0 or generated == samples):
			progress_cb.call(generated, samples, "draft candidates")
		if tree != null and generated % chunk_size == 0:
			await tree.process_frame

	var source_order: Array = _source_order(groups)
	var sources: Dictionary = {}
	var source_position_splits: Dictionary = {}
	for source_value in source_order:
		var source_type: String = str(source_value)
		sources[source_type] = _finalize_group(groups[source_type] as Dictionary, min_age, max_age)
		source_position_splits[source_type] = _finalize_split_groups(split_groups, source_type, min_age, max_age)

	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	var cancelled: bool = _is_cancelled(cancel_token)
	return {
		"ok": not cancelled,
		"cancelled": cancelled,
		"version": VERSION,
		"seed": seed,
		"samples_requested": samples,
		"candidates_generated": generated,
		"min_age": min_age,
		"max_age": max_age,
		"method": "Generate draft candidates with DraftService, then aggregate simulated growth by attained age instead of elapsed years.",
		"source_order": source_order,
		"player_group_order": PLAYER_GROUP_ORDER.duplicate(),
		"sources": sources,
		"source_position_splits": source_position_splits,
	}


func csv_text(report: Dictionary) -> String:
	var lines: Array = []
	lines.append("source_type,source_label,player_group,source_count,age,observations,draft_age_mean,years_since_draft_mean,overall_mean,overall_p10,overall_p50,overall_p90,delta_from_draft_mean,awakening_rate,growth_rate,stagnation_rate,decline_rate,major_decline_rate")
	var source_order: Array = report.get("source_order", []) as Array
	var sources: Dictionary = report.get("sources", {}) as Dictionary
	var source_position_splits: Dictionary = report.get("source_position_splits", {}) as Dictionary
	for source_value in source_order:
		var source_type: String = str(source_value)
		var source: Dictionary = sources.get(source_type, {}) as Dictionary
		_append_csv_group_rows(lines, source_type, "all", source)
		var splits: Dictionary = source_position_splits.get(source_type, {}) as Dictionary
		for player_group_value in ["pitcher", "fielder"]:
			var player_group: String = str(player_group_value)
			if splits.has(player_group):
				_append_csv_group_rows(lines, source_type, player_group, splits[player_group] as Dictionary)
	return "\n".join(lines)


func _append_csv_group_rows(lines: Array, source_type: String, player_group: String, source: Dictionary) -> void:
	var source_count: int = int(source.get("count", 0))
	for curve_value in source.get("age_curve", []) as Array:
		var row: Dictionary = curve_value as Dictionary
		var rates: Dictionary = row.get("growth_kind_rates_from_previous_age", {}) as Dictionary
		lines.append("%s,%s,%s,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
			source_type,
			str(source.get("source_label", source_type)),
			player_group,
			source_count,
			int(row.get("age", 0)),
			int(row.get("observations", 0)),
			float(row.get("draft_age_mean", 0.0)),
			float(row.get("years_since_draft_mean", 0.0)),
			float(row.get("overall_mean", 0.0)),
			float(row.get("overall_p10", 0.0)),
			float(row.get("overall_p50", 0.0)),
			float(row.get("overall_p90", 0.0)),
			float(row.get("delta_from_draft_mean", 0.0)),
			float(rates.get("awakening", 0.0)),
			float(rates.get("growth", 0.0)),
			float(rates.get("stagnation", 0.0)),
			float(rates.get("decline", 0.0)),
			float(rates.get("major_decline", 0.0)),
		])


func _new_group(source_type: String) -> Dictionary:
	return {
		"source_type": source_type,
		"count": 0,
		"initial_age": [],
		"initial_overall": [],
		"initial_potential": [],
		"initial_future_value": [],
		"positions": {
			"pitcher": 0,
			"catcher": 0,
			"infield": 0,
			"outfield": 0,
		},
		"age_rows": {},
		"growth_counts_by_age": {},
	}


func _simulate_candidate(candidate: Dictionary, groups: Array, min_age: int, max_age: int) -> void:
	var template: Dictionary = (candidate.get("player_template", {}) as Dictionary).duplicate(true)
	var player: PSPlayer = PSPlayer.from_dict(template)
	var draft_age: int = player.age
	var initial_overall: int = Offseason.player_value_score(player)

	var position_group: String = _position_group(player.position)
	for group_value in groups:
		var group: Dictionary = group_value as Dictionary
		group["count"] = int(group.get("count", 0)) + 1
		(group.get("initial_age", []) as Array).append(draft_age)
		(group.get("initial_overall", []) as Array).append(initial_overall)
		(group.get("initial_potential", []) as Array).append(int(candidate.get("potential", initial_overall)))
		(group.get("initial_future_value", []) as Array).append(int(candidate.get("future_value", initial_overall)))

		var positions: Dictionary = group.get("positions", {}) as Dictionary
		positions[position_group] = int(positions.get(position_group, 0)) + 1

	if player.age >= min_age and player.age <= max_age:
		for group_value in groups:
			_add_age_sample(group_value as Dictionary, player.age, draft_age, initial_overall, initial_overall)

	while player.age < max_age:
		var mutation: Dictionary = Offseason._mutate_abilities(player)
		var next_age: int = player.age + 1
		for group_value in groups:
			_add_growth_count(group_value as Dictionary, next_age, str(mutation.get("kind", "stagnation")))
		player.age = next_age
		player.years += 1
		if player.age < min_age:
			continue
		var current_overall: int = Offseason.player_value_score(player)
		for group_value in groups:
			_add_age_sample(group_value as Dictionary, player.age, draft_age, initial_overall, current_overall)


func _add_age_sample(group: Dictionary, age: int, draft_age: int, initial_overall: int, current_overall: int) -> void:
	var age_rows: Dictionary = group.get("age_rows", {}) as Dictionary
	var key: String = str(age)
	if not age_rows.has(key):
		age_rows[key] = {
			"draft_ages": [],
			"years_since_draft": [],
			"overall": [],
			"delta_from_draft": [],
		}
	var row: Dictionary = age_rows[key] as Dictionary
	(row.get("draft_ages", []) as Array).append(draft_age)
	(row.get("years_since_draft", []) as Array).append(age - draft_age)
	(row.get("overall", []) as Array).append(current_overall)
	(row.get("delta_from_draft", []) as Array).append(current_overall - initial_overall)


func _add_growth_count(group: Dictionary, age: int, kind: String) -> void:
	var rows: Dictionary = group.get("growth_counts_by_age", {}) as Dictionary
	var key: String = str(age)
	if not rows.has(key):
		rows[key] = _empty_growth_counts()
	var counts: Dictionary = rows[key] as Dictionary
	counts[kind] = int(counts.get(kind, 0)) + 1


func _finalize_group(group: Dictionary, min_age: int, max_age: int) -> Dictionary:
	var age_curve: Array = []
	var age_rows: Dictionary = group.get("age_rows", {}) as Dictionary
	var growth_rows: Dictionary = group.get("growth_counts_by_age", {}) as Dictionary
	for age in range(min_age, max_age + 1):
		var key: String = str(age)
		if not age_rows.has(key):
			continue
		var row: Dictionary = age_rows[key] as Dictionary
		var counts: Dictionary = growth_rows.get(key, _empty_growth_counts()) as Dictionary
		var overall_values: Array = row.get("overall", []) as Array
		age_curve.append({
			"age": age,
			"observations": overall_values.size(),
			"draft_age_mean": _round(_mean(row.get("draft_ages", []) as Array), 2),
			"years_since_draft_mean": _round(_mean(row.get("years_since_draft", []) as Array), 2),
			"overall_mean": _round(_mean(overall_values), 2),
			"overall_p10": _round(_percentile(overall_values, 0.10), 2),
			"overall_p50": _round(_percentile(overall_values, 0.50), 2),
			"overall_p90": _round(_percentile(overall_values, 0.90), 2),
			"overall_distribution": _overall_distribution(overall_values),
			"delta_from_draft_mean": _round(_mean(row.get("delta_from_draft", []) as Array), 2),
			"growth_kind_counts_from_previous_age": counts.duplicate(true),
			"growth_kind_rates_from_previous_age": _growth_rates(counts),
		})

	return {
		"source_type": str(group.get("source_type", "")),
		"source_label": str(SOURCE_LABELS.get(str(group.get("source_type", "")), str(group.get("source_type", "")))),
		"count": int(group.get("count", 0)),
		"initial": {
			"age_mean": _round(_mean(group.get("initial_age", []) as Array), 2),
			"overall_mean": _round(_mean(group.get("initial_overall", []) as Array), 2),
			"overall_p10": _round(_percentile(group.get("initial_overall", []) as Array, 0.10), 2),
			"overall_p50": _round(_percentile(group.get("initial_overall", []) as Array, 0.50), 2),
			"overall_p90": _round(_percentile(group.get("initial_overall", []) as Array, 0.90), 2),
			"future_value_mean": _round(_mean(group.get("initial_future_value", []) as Array), 2),
			"potential_mean": _round(_mean(group.get("initial_potential", []) as Array), 2),
		},
		"position_counts": (group.get("positions", {}) as Dictionary).duplicate(true),
		"age_curve": age_curve,
	}


func _source_order(groups: Dictionary) -> Array:
	var ordered: Array = []
	for source_value in SOURCE_ORDER:
		var source_type: String = str(source_value)
		if groups.has(source_type):
			ordered.append(source_type)
	for key_value in groups.keys():
		var source_type: String = str(key_value)
		if not ordered.has(source_type):
			ordered.append(source_type)
	return ordered


func _ensure_split_group(split_groups: Dictionary, source_type: String, player_group: String) -> Dictionary:
	if not split_groups.has(source_type):
		split_groups[source_type] = {}
	var source_splits: Dictionary = split_groups[source_type] as Dictionary
	if not source_splits.has(player_group):
		source_splits[player_group] = _new_group(source_type)
	return source_splits[player_group] as Dictionary


func _finalize_split_groups(split_groups: Dictionary, source_type: String, min_age: int, max_age: int) -> Dictionary:
	var result: Dictionary = {}
	var source_splits: Dictionary = split_groups.get(source_type, {}) as Dictionary
	for player_group_value in ["pitcher", "fielder"]:
		var player_group: String = str(player_group_value)
		if source_splits.has(player_group):
			result[player_group] = _finalize_group(source_splits[player_group] as Dictionary, min_age, max_age)
	return result


func _empty_growth_counts() -> Dictionary:
	var counts: Dictionary = {}
	for kind_value in GROWTH_KIND_ORDER:
		counts[str(kind_value)] = 0
	return counts


func _growth_rates(counts: Dictionary) -> Dictionary:
	var total: int = 0
	for kind_value in GROWTH_KIND_ORDER:
		total += int(counts.get(str(kind_value), 0))
	var rates: Dictionary = {}
	for kind_value in GROWTH_KIND_ORDER:
		var kind: String = str(kind_value)
		rates[kind] = 0.0 if total <= 0 else _round(float(counts.get(kind, 0)) / float(total), 4)
	return rates


func _is_cancelled(cancel_token: Dictionary) -> bool:
	return not cancel_token.is_empty() and bool(cancel_token.get("cancelled", false))


func _position_group(position: int) -> String:
	if position == 1:
		return "pitcher"
	if position == 2:
		return "catcher"
	if position >= 3 and position <= 6:
		return "infield"
	return "outfield"


func _player_group_for_position(position: int) -> String:
	return "pitcher" if position == 1 else "fielder"


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _percentile(values: Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	if sorted.size() == 1:
		return float(sorted[0])
	var clamped: float = clamp(percentile, 0.0, 1.0)
	var position: float = clamped * float(sorted.size() - 1)
	var lower: int = int(floor(position))
	var upper: int = int(ceil(position))
	if lower == upper:
		return float(sorted[lower])
	var weight: float = position - float(lower)
	return lerp(float(sorted[lower]), float(sorted[upper]), weight)


func _overall_distribution(values: Array) -> Dictionary:
	if values.is_empty():
		return {
			"count": 0,
			"min": 0,
			"max": 0,
			"bins": [],
		}
	var histogram: Dictionary = {}
	var min_value: int = 999999
	var max_value: int = -999999
	for value in values:
		var overall: int = int(value)
		var key: String = str(overall)
		histogram[key] = int(histogram.get(key, 0)) + 1
		min_value = min(min_value, overall)
		max_value = max(max_value, overall)

	var bins: Array = []
	var total: int = values.size()
	var cumulative: int = 0
	for overall in range(min_value, max_value + 1):
		var count: int = int(histogram.get(str(overall), 0))
		if count <= 0:
			continue
		cumulative += count
		bins.append({
			"overall": overall,
			"count": count,
			"rate": _round(float(count) / float(total), 4),
			"cumulative_rate": _round(float(cumulative) / float(total), 4),
		})
	return {
		"count": total,
		"min": min_value,
		"max": max_value,
		"bins": bins,
	}


func _round(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
