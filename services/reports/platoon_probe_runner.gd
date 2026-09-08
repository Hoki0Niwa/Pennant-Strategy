extends RefCounted
class_name PlatoonProbeRunner

# 左右 (プラトーン) の**実効スプリット**を実測する調査ツール。production の定数は変更しない。
#
# 同じ一軍母集団を「相手投手が全員右」「全員左」の 2 条件で回し、打者ごとに
# 有利 - 不利 の OPS 差 (= 実効スプリット) を出す。
#
# ## なぜ利き腕を反転させたクローンを使うか
# 実在の左投手だけを相手にすると、**投手プールの質の差がスプリットに混入する**。
# 初期ワールドの実測で 左投手は右投手より平均 0.070σ 低く、投手側の OPS 傾き -0.206/σ で
# 換算すると OPS .014 = 目標スプリット .05 の約 3 割に相当する。
# ここでは母集団の投手をそのまま複製して `throwing_hand` だけ書き換えるので、
# 2 条件の違いは利き腕だけになり、この偏りが構造的に消える。
#
# ## 測れるもの / 測れないもの
# 1 打席あたりの OPS 寄与の SD は約 1.27 なので、片腕 n 打席のスプリットの標準誤差は
# 1.27 × √(2/n) (n=2,000 で ±.040 / n=10,000 で ±.018)。
# - **リーグ平均**と**水準帯ごとの平均**は既定の打席数で足りる (打者 108 人ぶん平均されるため)。
# - **打者 1 人のスプリット**を ±.01 で確定させたいなら片腕 65,000 打席が要る。
# - 打者間の**真のばらつき** (SD) は、観測 SD からこの標本誤差ぶんを差し引いて推定する
#   (`split_true_sd_ops`)。個別推定を並べただけでは標本誤差ぶん過大に出る。
#
# 詳細は docs/agent_memory/project_platoon_usage.md を参照。

const PlayEventBuilder = preload("res://services/simulation/events/play_event_builder.gd")
const PlateEventReducer = preload("res://services/simulation/reducers/plate_event_reducer.gd")

const GAME_OUTS: int = 27
# 1 打者・片腕あたりの目標打席数。108 人 × 2 条件なので、既定でも約 43 万打席になる。
const DEFAULT_TARGET_PA: int = 2000

# run_pa_response_surface の実測。質能力 5 本を +1σ 動かしたときの OPS の傾き。
# 名目シフト量 (σ) → 期待スプリット (OPS) の換算に使う。
const OPS_PER_SIGMA: float = 0.2587

# --- 現実の参照値 (MLB 実測。2026-09-08 に MLB Stats API から算出) ---
# 2018-2025 (2020除く) の 128 万打席。**リーグ集計の平均スプリットは 右 .0445 / 左 .0807**、
# 通算 300 打席以上の 371 人で見ると **右 .060 / 左 .096、打者間の真の SD は 右 .028 / 左 .034**
# (観測分散から標本誤差ぶんを差し引いた推定)。ゲームの一軍スタメンと対応するのは後者。
# ⚠️ NPB は 2026 年の進行中データしか取れず、スプリットの誤差が ±.017 と大きいので参照にしない。
const REAL_SPLIT_OPS_RIGHT: float = 0.060
const REAL_SPLIT_OPS_LEFT: float = 0.096
const REAL_SPLIT_SD_RIGHT: float = 0.028
const REAL_SPLIT_SD_LEFT: float = 0.034

# --- 判定帯 ---
# 打者構成 (右 2/3・左 1/3) で加重した MLB 実測は 平均 .073 / SD .035。
# ⚠️ 下限が MLB (.073) より低いのは、PA モデルが投打の優位差を飽和させるぶん実効が 8 割に
# 留まるため (係数では越えられない。詳細は PSPlatoonMatchup.ABILITY_SHIFT_Z のコメント)。
const BAND_MEAN_SPLIT: Array = [0.050, 0.088]
const BAND_MEAN_SPLIT_HARD: Array = [0.040, 0.105]
const BAND_SPLIT_SD: Array = [0.025, 0.048]
const BAND_SPLIT_SD_HARD: Array = [0.015, 0.060]
# 水準の上位四分位 - 下位四分位。**MLB 実測では右打者はほぼ平ら、左打者はむしろ打力が高いほど
# 広い** (四分位平均 .057 → .096 → .111 → .119)。ゲームは水準と無関係に散らす設計なので 0 付近が正。
# シフトをテール圧縮の前に足していた頃はここが -.02 まで落ちていた (強打者ほど縮む = 現実と逆)。
const BAND_LEVEL_GAP: Array = [-0.015, 0.020]
const BAND_LEVEL_GAP_HARD: Array = [-0.030, 0.035]
# 動作点の確認帯。ここが外れていたらスプリットを読む場所そのものがずれている。
const BAND_REFERENCE_OPS: Array = [0.600, 0.740]

const STATUS_PASS: String = "pass"
const STATUS_WARN: String = "warn"
const STATUS_FAIL: String = "fail"

const HAND_RIGHT: String = PSPlatoonMatchup.HAND_RIGHT
const HAND_LEFT: String = PSPlatoonMatchup.HAND_LEFT


func run(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var population: Dictionary = PSReferencePopulation.build()
	if not bool(population.get("ok", false)):
		return {
			"version": 1,
			"tool": "platoon_probe",
			"ok": false,
			"errors": [str(population.get("message", "一軍母集団を構築できませんでした"))],
		}

	var target_pa: int = int(max(100, int(options.get("target_pa", DEFAULT_TARGET_PA))))
	var seed_value: int = int(options.get("seed", 12345))

	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state

	# 2 条件とも同じシードで始める (共通乱数)。系列は途中で分岐するが、
	# 立ち上がりが揃うぶんスプリットの分散がわずかに下がる。
	var vs_right: Dictionary = _simulate_condition(HAND_RIGHT, population, target_pa, seed_value)
	var vs_left: Dictionary = _simulate_condition(HAND_LEFT, population, target_pa, seed_value)

	Rng.set_seed_value(original_seed)
	Rng.generator.state = original_state

	var batters: Array = _build_batter_rows(vs_right, vs_left)
	var summary: Dictionary = _summarize(batters, vs_right, vs_left)
	var checks: Array = _build_checks(summary)

	return {
		"version": 1,
		"tool": "platoon_probe",
		"ok": true,
		"seed": seed_value,
		"design": {
			"target_pa_per_batter_per_hand": target_pa,
			"pitcher_hand_source": "母集団の投手を複製して throwing_hand だけ書き換え (プール差を排除)",
			"held_fixed": "打者・守備・捕手・投手の能力はすべて実在のまま / 変えるのは相手の利き腕だけ",
			"base_shift_z": PSPlatoonMatchup.ABILITY_SHIFT_Z,
			"left_batter_shift_ratio": PSPlatoonMatchup.LEFT_BATTER_SHIFT_RATIO,
			"platoon_shift_per_z": PSPlatoonMatchup.PLATOON_SHIFT_PER_Z,
			"ops_per_sigma": OPS_PER_SIGMA,
		},
		"reference_population": {
			"teams": int(population.get("teams", 0)),
			"batter_sample": int(population.get("batter_sample", 0)),
			"pitcher_sample": int(population.get("pitcher_sample", 0)),
			"batter_level": population.get("batter_level", 0.0),
			"pitcher_level": population.get("pitcher_level", 0.0),
		},
		"real_world_reference": {
			"mean_split_ops_right": REAL_SPLIT_OPS_RIGHT,
			"mean_split_ops_left": REAL_SPLIT_OPS_LEFT,
			"true_sd_ops_right": REAL_SPLIT_SD_RIGHT,
			"true_sd_ops_left": REAL_SPLIT_SD_LEFT,
			"source": "MLB Stats API 2018-2025 (2020除く) / 通算300打席以上の371人・観測分散から標本誤差を除いた推定",
		},
		"summary": summary,
		"batters": batters,
		"health": _health_summary(checks),
		"errors": [],
	}


# --- 1 条件 (相手投手の利き腕を固定) の実測 ---

func _simulate_condition(hand: String, population: Dictionary, target_pa: int, seed_value: int) -> Dictionary:
	Rng.set_seed_value(seed_value)

	# 条件ごとに母集団を複製する。成績が混ざらないよう毎回作り直す。
	var lineups: Array = []
	var batters: Array = []
	for order_value in (population.get("lineups", []) as Array):
		var order: Array = []
		for record_value in (order_value as Array):
			var batter: PSPlayerSeasonRecord = _clone_record(record_value as PSPlayerSeasonRecord)
			order.append(batter)
			batters.append(batter)
		lineups.append(order)
	# 投手は利き腕だけ書き換えたクローン。能力・スタミナ・球種はそのままなので、
	# 2 条件の差は純粋にプラトーン補正だけになる。
	var pitchers: Array = []
	for record_value in (population.get("pitchers", []) as Array):
		var pitcher: PSPlayerSeasonRecord = _clone_record(record_value as PSPlayerSeasonRecord)
		pitcher.throwing_hand = hand
		pitchers.append(pitcher)
	var defenses: Array = []
	for slots_value in (population.get("fielding_slots", []) as Array):
		defenses.append(_clone_fielding_slots(slots_value as Array))

	var needed_pa: int = target_pa * batters.size()
	var total_pa: int = 0
	var games: int = 0
	while total_pa < needed_pa:
		var lineup: Array = lineups[games % lineups.size()] as Array
		# 打線と投手の組み合わせが 11 通りに縮退しないよう、投手側は 1 周ごとに 1 つずらす
		# (球団数 12 が投手数 132 を割り切るので、単純な games % では同じ顔ぶれしか当たらない)。
		var lineup_cycles: int = int(float(games) / float(lineups.size()))
		var pitcher_index: int = (games + lineup_cycles) % pitchers.size()
		var pitcher: PSPlayerSeasonRecord = pitchers[pitcher_index] as PSPlayerSeasonRecord
		var defense: Dictionary = {
			"ok": true,
			"team_id": 0,
			"pitcher": pitcher,
			"batters": [],
			"fielders": defenses[(games + 1) % defenses.size()],
		}
		# 毎試合を「先発が万全で投げ始める」状態にする (疲労の持ち越しは Pit_Stamina 経由で
		# 条件ごとに別の意味を持ってしまう)。
		pitcher.fatigue = 0
		var game_outs: int = 0
		var inning_outs: int = 0
		var batting_index: int = 0
		var bases: Array = [null, null, null]
		while game_outs < GAME_OUTS:
			var batter: PSPlayerSeasonRecord = lineup[batting_index % lineup.size()] as PSPlayerSeasonRecord
			batting_index += 1
			var event_index: int = int(pitcher.pitcher_stats.batters_faced)
			var outcome: Dictionary = PSPlateAppearanceCoordinator.resolve(batter, pitcher, defense, bases, inning_outs, false)
			var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
			if pitch_summary.is_empty():
				pitch_summary = PlayEventBuilder.pitch_summary_for_play(event_index, batter, pitcher, outcome)
			var applied: Dictionary = PlateEventReducer.apply_plate_outcome(batter, pitcher, bases, inning_outs, outcome, {
				PlateEventReducer.OPTION_TRACK_BATTER: true,
				PlateEventReducer.OPTION_TRACK_PITCHER: true,
				PlateEventReducer.OPTION_PITCH_SUMMARY: pitch_summary,
			})
			total_pa += 1
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
		games += 1

	var stats_by_id: Dictionary = {}
	var records_by_id: Dictionary = {}
	var totals: PSBatterStats = PSBatterStats.new()
	for record_value in batters:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		stats_by_id[record.player_id] = record.batter_stats
		records_by_id[record.player_id] = record
		totals.add_from(record.batter_stats)
	return {
		"hand": hand,
		"games": games,
		"stats_by_id": stats_by_id,
		"records_by_id": records_by_id,
		"totals": totals,
	}


# --- 打者ごとの行 ---

func _build_batter_rows(vs_right: Dictionary, vs_left: Dictionary) -> Array:
	var rows: Array = []
	var records_by_id: Dictionary = vs_right.get("records_by_id", {}) as Dictionary
	var right_stats: Dictionary = vs_right.get("stats_by_id", {}) as Dictionary
	var left_stats: Dictionary = vs_left.get("stats_by_id", {}) as Dictionary
	for player_id_value in records_by_id.keys():
		var player_id: int = int(player_id_value)
		var record: PSPlayerSeasonRecord = records_by_id[player_id] as PSPlayerSeasonRecord
		var against_right: PSBatterStats = right_stats.get(player_id, null) as PSBatterStats
		var against_left: PSBatterStats = left_stats.get(player_id, null) as PSBatterStats
		if against_right == null or against_left == null:
			continue
		var side: String = record.batting_side.to_upper()
		# 有利 = 逆の利き腕。スイッチは常に逆打席へ入るのでどちらも有利側 = 差は出ない。
		var advantage_is_left_pitcher: bool = side == HAND_RIGHT
		var advantage: PSBatterStats = against_left if advantage_is_left_pitcher else against_right
		var disadvantage: PSBatterStats = against_right if advantage_is_left_pitcher else against_left
		var row: Dictionary = {
			"player_id": player_id,
			"name": record.name,
			"team_id": record.team_id,
			"bats": side,
			"level_z": _round_float(PSReferencePopulation.batter_level_z(record), 3),
			"platoon_z": _round_float(record.z_ability("Bat_Platoon", 0.0), 3),
			"shift_z": _round_float(PSPlatoonMatchup.batter_shift_z(record), 4),
			"nominal_split_ops": _round_float(
				2.0 * PSPlatoonMatchup.batter_shift_z(record) * OPS_PER_SIGMA, 4
			),
			"pa_advantage": advantage.plate_appearances,
			"pa_disadvantage": disadvantage.plate_appearances,
			"ops_advantage": _round_float(advantage.ops(), 4),
			"ops_disadvantage": _round_float(disadvantage.ops(), 4),
			"split_ops": _round_float(advantage.ops() - disadvantage.ops(), 4),
			"split_strikeout_rate": _round_float(
				_rate(disadvantage.strikeouts, disadvantage.plate_appearances)
					- _rate(advantage.strikeouts, advantage.plate_appearances), 4
			),
			"split_home_run_rate": _round_float(
				_rate(advantage.home_runs, advantage.plate_appearances)
					- _rate(disadvantage.home_runs, disadvantage.plate_appearances), 4
			),
			"split_standard_error": _round_float(
				_split_standard_error(advantage, disadvantage), 4
			),
			"switch_hitter": side == PSPlatoonMatchup.HAND_SWITCH,
		}
		rows.append(row)
	rows.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["split_ops"]) > float((b as Dictionary)["split_ops"])
	)
	return rows


# --- 集計 ---

func _summarize(batters: Array, vs_right: Dictionary, vs_left: Dictionary) -> Dictionary:
	var measured: Array = []
	for row_value in batters:
		var row: Dictionary = row_value as Dictionary
		if not bool(row.get("switch_hitter", false)):
			measured.append(row)

	var splits: Array = []
	var noise_variance_total: float = 0.0
	for row_value in measured:
		var row: Dictionary = row_value as Dictionary
		splits.append(float(row["split_ops"]))
		var standard_error: float = float(row["split_standard_error"])
		noise_variance_total += standard_error * standard_error
	var mean_split: float = _mean(splits)
	var observed_variance: float = _variance(splits)
	var noise_variance: float = 0.0 if measured.is_empty() else noise_variance_total / float(measured.size())
	# 観測分散 = 真の分散 + 標本誤差の分散。負になったら「真のばらつきは測定限界以下」。
	var true_variance: float = observed_variance - noise_variance

	var right_totals: PSBatterStats = vs_right.get("totals", null) as PSBatterStats
	var left_totals: PSBatterStats = vs_left.get("totals", null) as PSBatterStats

	var by_side: Dictionary = {}
	for side in [HAND_RIGHT, HAND_LEFT]:
		var side_splits: Array = []
		for row_value in measured:
			var row: Dictionary = row_value as Dictionary
			if str(row["bats"]) == side:
				side_splits.append(float(row["split_ops"]))
		if side_splits.is_empty():
			continue
		by_side[side] = {
			"batters": side_splits.size(),
			"mean_split_ops": _round_float(_mean(side_splits), 4),
			"standard_error": _round_float(sqrt(noise_variance / float(side_splits.size())), 4),
		}

	return {
		"batters": measured.size(),
		"switch_hitters": batters.size() - measured.size(),
		"pa_per_batter_per_hand": 0 if batters.is_empty() else int(
			float(right_totals.plate_appearances) / float(batters.size())
		),
		"games_per_condition": int(vs_right.get("games", 0)),
		"reference_ops_vs_right": _round_float(right_totals.ops(), 4),
		"reference_ops_vs_left": _round_float(left_totals.ops(), 4),
		"mean_split_ops": _round_float(mean_split, 4),
		"mean_split_standard_error": _round_float(
			0.0 if measured.is_empty() else sqrt(noise_variance / float(measured.size())), 4
		),
		"split_observed_sd_ops": _round_float(sqrt(max(0.0, observed_variance)), 4),
		"split_noise_sd_ops": _round_float(sqrt(max(0.0, noise_variance)), 4),
		"split_true_sd_ops": _round_float(sqrt(max(0.0, true_variance)), 4),
		# 名目 = 打者ごとのシフト量 × 応答曲面の傾き。実効 / 名目 がテール圧縮の実測値。
		"mean_nominal_split_ops": _round_float(_mean_of_key(measured, "nominal_split_ops"), 4),
		"compression_ratio": _round_float(
			0.0 if is_zero_approx(_mean_of_key(measured, "nominal_split_ops"))
			else mean_split / _mean_of_key(measured, "nominal_split_ops"), 3
		),
		"nominal_slope_vs_platoon_z": _round_float(_slope(measured, "platoon_z", "nominal_split_ops"), 4),
		"mean_split_strikeout_rate": _round_float(_mean_of_key(measured, "split_strikeout_rate"), 4),
		"mean_split_home_run_rate": _round_float(_mean_of_key(measured, "split_home_run_rate"), 4),
		"by_batting_side": by_side,
		"by_level_quartile": _quartile_table(measured, "level_z"),
		"by_platoon_quartile": _quartile_table(measured, "platoon_z"),
		"slope_vs_platoon_z": _round_float(_slope(measured, "platoon_z"), 4),
		"slope_vs_level_z": _round_float(_slope(measured, "level_z"), 4),
		"reverse_split_batters": _count_below(measured, 0.0),
		"reverse_split_share": _round_float(
			0.0 if measured.is_empty() else float(_count_below(measured, 0.0)) / float(measured.size()), 3
		),
	}


# 打者を key の四分位で 4 帯に分け、帯ごとの平均スプリットを出す。
func _quartile_table(rows: Array, key: String) -> Array:
	if rows.size() < 4:
		return []
	var sorted_rows: Array = rows.duplicate()
	sorted_rows.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)[key]) < float((b as Dictionary)[key])
	)
	var table: Array = []
	var size: int = sorted_rows.size()
	for quartile in range(4):
		var from_index: int = int(float(size) * float(quartile) / 4.0)
		var to_index: int = int(float(size) * float(quartile + 1) / 4.0)
		var splits: Array = []
		var keys: Array = []
		for index in range(from_index, to_index):
			var row: Dictionary = sorted_rows[index] as Dictionary
			splits.append(float(row["split_ops"]))
			keys.append(float(row[key]))
		table.append({
			"quartile": quartile + 1,
			"batters": splits.size(),
			"mean_key_value": _round_float(_mean(keys), 3),
			"mean_split_ops": _round_float(_mean(splits), 4),
		})
	return table


# value_key を key へ回帰したときの傾き (最小二乗)。
func _slope(rows: Array, key: String, value_key: String = "split_ops") -> float:
	if rows.size() < 2:
		return 0.0
	var keys: Array = []
	var splits: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		keys.append(float(row[key]))
		splits.append(float(row[value_key]))
	var mean_key: float = _mean(keys)
	var mean_split: float = _mean(splits)
	var covariance: float = 0.0
	var key_variance: float = 0.0
	for index in range(keys.size()):
		var delta_key: float = float(keys[index]) - mean_key
		covariance += delta_key * (float(splits[index]) - mean_split)
		key_variance += delta_key * delta_key
	if is_zero_approx(key_variance):
		return 0.0
	return covariance / key_variance


# --- 健全性チェック ---

func _build_checks(summary: Dictionary) -> Array:
	var checks: Array = []
	checks.append(_band_check(
		"reference_ops_vs_right", float(summary.get("reference_ops_vs_right", 0.0)),
		BAND_REFERENCE_OPS, BAND_REFERENCE_OPS,
		"動作点: 全員右投手のときのリーグ OPS"
	))
	checks.append(_band_check(
		"mean_split_ops", float(summary.get("mean_split_ops", 0.0)),
		BAND_MEAN_SPLIT, BAND_MEAN_SPLIT_HARD,
		"リーグ平均の実効スプリット (MLB実測 右.060/左.096 → 加重 .073)"
	))
	checks.append(_band_check(
		"split_true_sd_ops", float(summary.get("split_true_sd_ops", 0.0)),
		BAND_SPLIT_SD, BAND_SPLIT_SD_HARD,
		"打者間の真のばらつき (MLB実測 右.028/左.034 → 加重 .035)"
	))
	var quartiles: Array = summary.get("by_level_quartile", []) as Array
	if quartiles.size() == 4:
		var gap: float = float((quartiles[3] as Dictionary)["mean_split_ops"]) - float((quartiles[0] as Dictionary)["mean_split_ops"])
		checks.append(_band_check(
			"level_quartile_gap", gap,
			BAND_LEVEL_GAP, BAND_LEVEL_GAP_HARD,
			"能力上位帯 - 下位帯 の実効スプリット差 (テール圧縮の効き)"
		))
	return checks


func _band_check(name: String, value: float, band: Array, hard_band: Array, description: String) -> Dictionary:
	var status: String = STATUS_PASS
	if value < float(hard_band[0]) or value > float(hard_band[1]):
		status = STATUS_FAIL
	elif value < float(band[0]) or value > float(band[1]):
		status = STATUS_WARN
	return {
		"name": name,
		"status": status,
		"value": _round_float(value, 4),
		"band": band,
		"hard_band": hard_band,
		"description": description,
	}


func _health_summary(checks: Array) -> Dictionary:
	var fail_count: int = 0
	var warn_count: int = 0
	for check_value in checks:
		var status: String = str((check_value as Dictionary).get("status", STATUS_PASS))
		if status == STATUS_FAIL:
			fail_count += 1
		elif status == STATUS_WARN:
			warn_count += 1
	var status_value: String = STATUS_PASS
	if fail_count > 0:
		status_value = STATUS_FAIL
	elif warn_count > 0:
		status_value = STATUS_WARN
	return {
		"status": status_value,
		"fail": fail_count,
		"warn": warn_count,
		"checks": checks,
	}


# --- CSV ---

func csv_text(report: Dictionary) -> String:
	var lines: Array = [
		"player_id,name,bats,level_z,platoon_z,shift_z,nominal_split_ops,pa_advantage,pa_disadvantage,ops_advantage,ops_disadvantage,split_ops,split_standard_error,split_strikeout_rate,split_home_run_rate",
	]
	for row_value in (report.get("batters", []) as Array):
		var row: Dictionary = row_value as Dictionary
		lines.append("%d,%s,%s,%.3f,%.3f,%.4f,%.4f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f" % [
			int(row.get("player_id", 0)),
			str(row.get("name", "")).replace(",", " "),
			str(row.get("bats", "")),
			float(row.get("level_z", 0.0)),
			float(row.get("platoon_z", 0.0)),
			float(row.get("shift_z", 0.0)),
			float(row.get("nominal_split_ops", 0.0)),
			int(row.get("pa_advantage", 0)),
			int(row.get("pa_disadvantage", 0)),
			float(row.get("ops_advantage", 0.0)),
			float(row.get("ops_disadvantage", 0.0)),
			float(row.get("split_ops", 0.0)),
			float(row.get("split_standard_error", 0.0)),
			float(row.get("split_strikeout_rate", 0.0)),
			float(row.get("split_home_run_rate", 0.0)),
		])
	return "\n".join(lines) + "\n"


# --- helpers ---

# 1 打席あたりの OPS 寄与の分散から、スプリット (2 条件の差) の標準誤差を出す。
# OPS = OBP + SLG を 1 打席の寄与 x = 出塁 + 塁打/(打数/打席) とみなした近似。
func _split_standard_error(advantage: PSBatterStats, disadvantage: PSBatterStats) -> float:
	var combined: PSBatterStats = PSBatterStats.new()
	combined.add_from(advantage)
	combined.add_from(disadvantage)
	var plate_appearances: int = combined.plate_appearances
	if plate_appearances <= 0 or advantage.plate_appearances <= 0 or disadvantage.plate_appearances <= 0:
		return 0.0
	var at_bat_share: float = float(combined.at_bats) / float(plate_appearances)
	if is_zero_approx(at_bat_share):
		return 0.0
	var singles: int = combined.hits - combined.doubles - combined.triples - combined.home_runs
	var events: Array = [
		[singles, 1.0, 1.0], [combined.doubles, 1.0, 2.0], [combined.triples, 1.0, 3.0],
		[combined.home_runs, 1.0, 4.0], [combined.walks, 1.0, 0.0], [combined.hit_by_pitches, 1.0, 0.0],
	]
	var mean: float = 0.0
	var mean_square: float = 0.0
	for event_value in events:
		var event: Array = event_value as Array
		var probability: float = float(int(event[0])) / float(plate_appearances)
		var contribution: float = float(event[1]) + float(event[2]) / at_bat_share
		mean += probability * contribution
		mean_square += probability * contribution * contribution
	var variance: float = max(0.0, mean_square - mean * mean)
	return sqrt(variance * (1.0 / float(advantage.plate_appearances) + 1.0 / float(disadvantage.plate_appearances)))


func _clone_record(source: PSPlayerSeasonRecord) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(source.to_dict())
	record.batter_stats = PSBatterStats.new()
	record.pitcher_stats = PSPitcherStats.new()
	record.fatigue = 0
	record.injury_days = 0
	return record


func _clone_fielding_slots(slots: Array) -> Array:
	var cloned: Array = []
	for slot_value in slots:
		var slot: Dictionary = slot_value as Dictionary
		var record: PSPlayerSeasonRecord = slot.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		cloned.append({"record": _clone_record(record), "position": int(slot.get("position", 0))})
	return cloned


func _rate(count: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return float(count) / float(denominator)


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _variance(values: Array) -> float:
	if values.size() < 2:
		return 0.0
	var mean: float = _mean(values)
	var total: float = 0.0
	for value in values:
		var delta: float = float(value) - mean
		total += delta * delta
	return total / float(values.size() - 1)


func _mean_of_key(rows: Array, key: String) -> float:
	var values: Array = []
	for row_value in rows:
		values.append(float((row_value as Dictionary).get(key, 0.0)))
	return _mean(values)


func _count_below(rows: Array, threshold: float) -> int:
	var count: int = 0
	for row_value in rows:
		if float((row_value as Dictionary).get("split_ops", 0.0)) < threshold:
			count += 1
	return count


func _round_float(value: float, digits: int) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor
