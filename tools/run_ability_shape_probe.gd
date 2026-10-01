extends Node

# 能力分布の「形」を試合なしで測る調査ツール。
#   1. ドラフト候補を CANDIDATE_POOL_SIZE 人ずつ生成し、draft_grade 上位 TYPICAL_DRAFT_PICK_COUNT 人を指名扱いにする
#   2. 指名組を Offseason の年次成長でピーク年齢まで育てる
#   3. 生成直後の候補 / ピーク年齢の指名組 / 初期ワールド (12球団の在籍) に同じ指標を当てて並べる
# 指標: 分位・歪度・超過尖度、上側の裾の長さ (p99-p50)/(p90-p50) (正規分布で 1.82)、
# 上位の詰まり (n 人の標本での 1位と5位の差 ÷ SD の平均。正規分布なら n=470 で 0.68)、
# 最大値の同値率 (上限クランプへの張り付き)、選手内の能力のばらつき (尖り) と能力間の平均相関。
# 生成/成長の乱数を触る前後で回して比べる。
#   godot --headless --path . --scene res://tools/run_ability_shape_probe.tscn -- --drafts=60 --seed=20260528

const Offseason = preload("res://services/season/offseason_service.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/ability_shape_probe_latest.json"
const BATTER_KEYS: Array = ["Bat_KAvoid", "Bat_BBCreate", "Bat_Impact", "Bat_Loft", "Bat_Barrel", "Run_Speed"]
const PITCHER_KEYS: Array = ["Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_LoftControl", "Pit_BarrelDeny", "Pit_Stamina"]
# 上位の詰まりを測る標本の大きさ。12球団の野手/投手の在籍数 (各 470 前後) に揃える。
const TOP_GAP_SAMPLE_SIZE: int = 470
# 総合上位 3 割の層での標本の大きさ (470 × 0.3)。正規分布なら 1位と5位の差は 0.83 SD。
const TOP30_GAP_SAMPLE_SIZE: int = 140
const TOP_GAP_RESAMPLES: int = 200
const OVERALL_KEY: String = "__overall"
const ROLE_KEY: String = "__role"
# 指名時 (成長前) に付いた役割。ゲーム内の役割はこちらで決まり、成長しても判定し直さない。
const DRAFT_ROLE_KEY: String = "__draft_role"

var _gap_sample_size: int = TOP_GAP_SAMPLE_SIZE


func _ready() -> void:
	var options: Dictionary = _parse_args()
	Rng.set_seed_value(int(options.get("seed", 20260528)))
	var pool_fielders: Array = []
	var pool_pitchers: Array = []
	var peak_fielders: Array = []
	var peak_pitchers: Array = []
	var peak_age: int = int(options.get("peak_age", 27))
	for _draft_index in range(int(options.get("drafts", 60))):
		var pool: Array = []
		for i in range(DraftService.CANDIDATE_POOL_SIZE):
			pool.append(DraftService._generate_candidate(i + 1))
		pool.sort_custom(func(a, b) -> bool:
			return float((a as Dictionary).get("draft_grade", 0.0)) > float((b as Dictionary).get("draft_grade", 0.0))
		)
		for i in range(pool.size()):
			var candidate: Dictionary = pool[i] as Dictionary
			var player: PSPlayer = PSPlayer.from_dict((candidate.get("player_template", {}) as Dictionary).duplicate(true))
			(pool_pitchers if player.is_pitcher() else pool_fielders).append(_snapshot(player))
			if i >= DraftService.TYPICAL_DRAFT_PICK_COUNT:
				continue
			var draft_role: String = player.role
			while player.age < peak_age:
				Offseason._mutate_abilities(player)
				player.age += 1
			var peak_row: Dictionary = _snapshot(player)
			peak_row[DRAFT_ROLE_KEY] = draft_role
			(peak_pitchers if player.is_pitcher() else peak_fielders).append(peak_row)

	var world_fielders: Array = []
	var world_pitchers: Array = []
	GameDb.load_initial_data()
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.is_retired() or player.team_id <= 0 or PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		(world_pitchers if player.is_pitcher() else world_fielders).append(_snapshot(player))

	var report: Dictionary = {
		"seed": int(options.get("seed", 20260528)),
		"drafts": int(options.get("drafts", 60)),
		"peak_age": peak_age,
		"groups": {
			"draft_pool": _group_summary(pool_fielders, pool_pitchers),
			"drafted_at_peak": _group_summary(peak_fielders, peak_pitchers),
			"drafted_at_peak_top30": _group_summary(_top_by_overall(peak_fielders, 0.3), _top_by_overall(peak_pitchers, 0.3), TOP30_GAP_SAMPLE_SIZE),
			"initial_world": _group_summary(world_fielders, world_pitchers),
			"initial_world_top30": _group_summary(_top_by_overall(world_fielders, 0.3), _top_by_overall(world_pitchers, 0.3), TOP30_GAP_SAMPLE_SIZE),
		},
	}
	_print_report(report)
	var path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var file: FileAccess = FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
		print("output: %s" % ProjectSettings.globalize_path(path))
	get_tree().quit(0)


# 総合値の上位 share だけを残す (一軍の主力に相当する層の形を見る)。
func _top_by_overall(rows: Array, share: float) -> Array:
	var sorted: Array = rows.duplicate()
	sorted.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary).get(OVERALL_KEY, 0.0)) > float((b as Dictionary).get(OVERALL_KEY, 0.0))
	)
	return sorted.slice(0, maxi(1, int(round(float(sorted.size()) * share))))


# z 能力の複製に総合値 (OVERALL_KEY) を足した 1 行。
func _snapshot(player: PSPlayer) -> Dictionary:
	var row: Dictionary = player.z_abilities.duplicate()
	row[OVERALL_KEY] = float(Offseason.player_value_score(player))
	if player.is_pitcher():
		var neutral: Dictionary = player.to_dict()
		neutral["role"] = ""
		row[ROLE_KEY] = PSPitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral))
	return row


# 先発/救援 (能力から判定した役割) ごとの主要能力の平均と、総合上位 3 割に占める救援の割合。
# 救援だけが弱くなると、救援の FIP が先発より悪くなる (report_health の relief_fip_minus_starter_fip)。
func _role_summary(pitchers: Array, role_key: String = ROLE_KEY) -> Dictionary:
	var out: Dictionary = {}
	for role in [PSPitcherRoleModel.ROLE_STARTER, "reliever"]:
		var rows: Array = pitchers.filter(func(r) -> bool: return str((r as Dictionary).get(role_key, "")) == role)
		var summary: Dictionary = {"n": rows.size()}
		for key in PITCHER_KEYS + ["Pit_FatigueResist", "Pit_Efficiency", OVERALL_KEY]:
			summary[key] = _r(_mean(_column(rows, key)))
		summary["pa5"] = _r(_mean(_mean_column(rows, ["Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_LoftControl", "Pit_BarrelDeny"])))
		out[role] = summary
	var top: Array = _top_by_overall(pitchers, 0.3)
	var top_relievers: int = top.filter(func(r) -> bool: return str((r as Dictionary).get(role_key, "")) != PSPitcherRoleModel.ROLE_STARTER).size()
	out["top30_reliever_share"] = _r(float(top_relievers) / float(maxi(1, top.size())))
	return out


func _group_summary(fielders: Array, pitchers: Array, gap_sample_size: int = TOP_GAP_SAMPLE_SIZE) -> Dictionary:
	_gap_sample_size = gap_sample_size
	var batter: Dictionary = {"n": fielders.size()}
	batter["overall"] = _series_summary(_column(fielders, OVERALL_KEY))
	for key in BATTER_KEYS:
		batter[key] = _series_summary(_column(fielders, key))
	batter["power"] = _series_summary(_power_column(fielders))
	batter["core_mean"] = _series_summary(_mean_column(fielders, BATTER_KEYS))
	batter["within_player_sd"] = _within_player_sd(fielders, BATTER_KEYS)
	batter["mean_pair_corr"] = _mean_pair_corr(fielders, BATTER_KEYS)
	batter["impact_kavoid_corr"] = _corr(_column(fielders, "Bat_Impact"), _column(fielders, "Bat_KAvoid"))
	var pitcher: Dictionary = {"n": pitchers.size()}
	pitcher["overall"] = _series_summary(_column(pitchers, OVERALL_KEY))
	for key in PITCHER_KEYS:
		pitcher[key] = _series_summary(_column(pitchers, key))
	pitcher["core_mean"] = _series_summary(_mean_column(pitchers, PITCHER_KEYS))
	pitcher["within_player_sd"] = _within_player_sd(pitchers, PITCHER_KEYS)
	pitcher["mean_pair_corr"] = _mean_pair_corr(pitchers, PITCHER_KEYS)
	pitcher["by_role"] = _role_summary(pitchers)
	if not pitchers.is_empty() and (pitchers[0] as Dictionary).has(DRAFT_ROLE_KEY):
		pitcher["by_draft_role"] = _role_summary(pitchers, DRAFT_ROLE_KEY)
	return {"batter": batter, "pitcher": pitcher}


func _column(rows: Array, key: String) -> Array:
	var values: Array = []
	for row in rows:
		values.append(float((row as Dictionary).get(key, 0.0)))
	return values


func _power_column(rows: Array) -> Array:
	var values: Array = []
	for row in rows:
		var z: Dictionary = row as Dictionary
		values.append(float(z.get("Bat_Impact", 0.0)) + 0.5 * float(z.get("Bat_Loft", 0.0)))
	return values


func _mean_column(rows: Array, keys: Array) -> Array:
	var values: Array = []
	for row in rows:
		var z: Dictionary = row as Dictionary
		var total: float = 0.0
		for key in keys:
			total += float(z.get(key, 0.0))
		values.append(total / float(keys.size()))
	return values


func _series_summary(values: Array) -> Dictionary:
	var n: int = values.size()
	if n < 10:
		return {"n": n}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var mean: float = _mean(values)
	var m2: float = 0.0
	var m3: float = 0.0
	var m4: float = 0.0
	for value in values:
		var d: float = float(value) - mean
		m2 += d * d
		m3 += d * d * d
		m4 += d * d * d * d
	m2 /= float(n)
	m3 /= float(n)
	m4 /= float(n)
	var sd: float = sqrt(m2)
	var p50: float = _quantile(sorted, 0.50)
	var p90: float = _quantile(sorted, 0.90)
	var p99: float = _quantile(sorted, 0.99)
	var max_value: float = float(sorted[n - 1])
	var ties_at_max: int = 0
	for value in sorted:
		if float(value) >= max_value - 0.0001:
			ties_at_max += 1
	return {
		"n": n,
		"mean": _r(mean),
		"sd": _r(sd),
		"skew": _r(m3 / pow(sd, 3.0)) if sd > 0.0 else 0.0,
		"exkurt": _r(m4 / pow(sd, 4.0) - 3.0) if sd > 0.0 else 0.0,
		"p50": _r(p50),
		"p90": _r(p90),
		"p99": _r(p99),
		"max": _r(max_value),
		"tail_ratio": _r((p99 - p50) / (p90 - p50)) if p90 > p50 else 0.0,
		"top_gap": _r(_top_gap(values)),
		"max_tie_share": _r(float(ties_at_max) / float(n)),
	}


# n=_gap_sample_size の無作為標本での (1位 - 5位) / SD の平均。n が標本より小さければ全体で 1 回。
func _top_gap(values: Array) -> float:
	var sample_size: int = mini(_gap_sample_size, values.size())
	var resamples: int = 1 if sample_size == values.size() else TOP_GAP_RESAMPLES
	var total: float = 0.0
	for _i in range(resamples):
		var sample: Array = values.duplicate() if resamples == 1 else _sample(values, sample_size)
		sample.sort()
		var sd: float = _sd(sample)
		if sd <= 0.0:
			continue
		total += (float(sample[sample.size() - 1]) - float(sample[sample.size() - 5])) / sd
	return total / float(resamples)


func _sample(values: Array, size: int) -> Array:
	var picked: Array = []
	for _i in range(size):
		picked.append(values[Rng.range_int(0, values.size() - 1)])
	return picked


func _within_player_sd(rows: Array, keys: Array) -> Dictionary:
	var sds: Array = []
	var spikes: Array = []
	var spiky: int = 0
	for row in rows:
		var z: Dictionary = row as Dictionary
		var values: Array = []
		for key in keys:
			values.append(float(z.get(key, 0.0)))
		sds.append(_sd(values))
		# 尖りの高さ = 最も高い能力 - 選手内の平均。1.5 (表示で約 19 点) 以上を「一芸が突出」と数える。
		var spike: float = float(values.max()) - _mean(values)
		spikes.append(spike)
		if spike >= 1.5:
			spiky += 1
	sds.sort()
	spikes.sort()
	return {
		"p10": _r(_quantile(sds, 0.10)), "p50": _r(_quantile(sds, 0.50)), "p90": _r(_quantile(sds, 0.90)),
		"spike_p50": _r(_quantile(spikes, 0.50)), "spike_p90": _r(_quantile(spikes, 0.90)),
		"spiky_share": _r(float(spiky) / float(maxi(1, rows.size()))),
	}


func _mean_pair_corr(rows: Array, keys: Array) -> float:
	var total: float = 0.0
	var pairs: int = 0
	for i in range(keys.size()):
		for j in range(i + 1, keys.size()):
			if (keys[i] == "Bat_Impact" and keys[j] == "Bat_Loft") or (keys[i] == "Bat_Loft" and keys[j] == "Bat_Impact"):
				continue
			total += _corr(_column(rows, str(keys[i])), _column(rows, str(keys[j])))
			pairs += 1
	return _r(total / float(maxi(1, pairs)))


func _corr(a: Array, b: Array) -> float:
	var n: int = a.size()
	if n < 3:
		return 0.0
	var ma: float = _mean(a)
	var mb: float = _mean(b)
	var sab: float = 0.0
	var saa: float = 0.0
	var sbb: float = 0.0
	for i in range(n):
		var da: float = float(a[i]) - ma
		var db: float = float(b[i]) - mb
		sab += da * db
		saa += da * da
		sbb += db * db
	return _r(sab / sqrt(saa * sbb)) if saa > 0.0 and sbb > 0.0 else 0.0


func _mean(values: Array) -> float:
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(maxi(1, values.size()))


func _sd(values: Array) -> float:
	var mean: float = _mean(values)
	var total: float = 0.0
	for value in values:
		total += pow(float(value) - mean, 2.0)
	return sqrt(total / float(maxi(1, values.size())))


func _quantile(sorted: Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	var position: float = clampf(q, 0.0, 1.0) * float(sorted.size() - 1)
	var lower: int = int(floor(position))
	var upper: int = int(ceil(position))
	return lerpf(float(sorted[lower]), float(sorted[upper]), position - float(lower))


func _r(value: float) -> float:
	return snappedf(value, 0.001)


func _print_report(report: Dictionary) -> void:
	var groups: Dictionary = report.get("groups", {}) as Dictionary
	for side in ["batter", "pitcher"]:
		var series_keys: Array = (["overall", "power", "core_mean"] + BATTER_KEYS) if side == "batter" else (["overall", "core_mean"] + PITCHER_KEYS)
		for group_name in groups.keys():
			var group: Dictionary = (groups[group_name] as Dictionary).get(side, {}) as Dictionary
			print("== %s / %s  n=%d  within_sd p50 %.2f  pair_corr %.2f%s" % [
				group_name, side, int(group.get("n", 0)),
				float((group.get("within_player_sd", {}) as Dictionary).get("p50", 0.0)),
				float(group.get("mean_pair_corr", 0.0)),
				("  impact~kavoid %.2f" % float(group.get("impact_kavoid_corr", 0.0))) if side == "batter" else "",
			])
			for key in series_keys:
				var s: Dictionary = group.get(key, {}) as Dictionary
				print("  %-16s mean %+.2f sd %.2f skew %+.2f exk %+.2f p90 %+.2f p99 %+.2f max %+.2f tail %.2f gap %.2f tie %.3f" % [
					key, float(s.get("mean", 0.0)), float(s.get("sd", 0.0)), float(s.get("skew", 0.0)),
					float(s.get("exkurt", 0.0)), float(s.get("p90", 0.0)), float(s.get("p99", 0.0)),
					float(s.get("max", 0.0)), float(s.get("tail_ratio", 0.0)), float(s.get("top_gap", 0.0)),
					float(s.get("max_tie_share", 0.0)),
				])


func _parse_args() -> Dictionary:
	var options: Dictionary = {"seed": 20260528, "drafts": 60, "peak_age": 27, "output": DEFAULT_OUTPUT_PATH}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for arg_value in args:
		var arg: String = str(arg_value)
		if arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--drafts="):
			options["drafts"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--peak-age="):
			options["peak_age"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
	return options
