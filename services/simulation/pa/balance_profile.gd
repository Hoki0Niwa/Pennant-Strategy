extends RefCounted
class_name PSBalanceProfile

# 打席計算用の純粋数式ヘルパー集（確率・logit・softmax・能力カーブ）。
# 旧バランススライダー層と PSSimulationTuning(.tres) は 2026-06 に全廃。
# 調整係数は各計算ファイル（pa_probability_calculator.gd / pitch_aggregate_simulator.gd /
# fatigue_calculator.gd / plate_appearance_coordinator.gd / contact_quality_model.gd /
# play_resolver.gd 等）の const へ移設済み。ここにはチューニング値は持たない。


# 能力 z を [-1, 1] のS字カーブへ写す。center が中立点、width が立ち上がりの広がり。
static func ability_curve_z(z: float, center: float = 0.4, width: float = 1.6) -> float:
	var x: float = clamp((z - center) / max(0.001, width), -4.0, 4.0)
	return 2.0 / (1.0 + exp(-2.0 * x)) - 1.0


static func sigmoid(logit_value: float) -> float:
	return 1.0 / (1.0 + exp(-clamp(logit_value, -12.0, 12.0)))


static func logit(probability: float) -> float:
	var p: float = clamp(probability, 0.000001, 0.999999)
	return log(p / (1.0 - p))


static func weighted_softmax_pick(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	var max_logit: float = -INF
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		max_logit = max(max_logit, float(row.get("logit", 0.0)))

	var total: float = 0.0
	var weights: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var weight: float = exp(clamp(float(row.get("logit", 0.0)) - max_logit, -30.0, 30.0))
		weights.append(weight)
		total += weight

	if total <= 0.0:
		return rows[0] as Dictionary

	var roll: float = Rng.roll_float() * total
	var running: float = 0.0
	for index in range(rows.size()):
		running += float(weights[index])
		if roll <= running:
			return rows[index] as Dictionary
	return rows[rows.size() - 1] as Dictionary
