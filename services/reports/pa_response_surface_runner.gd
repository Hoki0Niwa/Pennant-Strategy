extends RefCounted
class_name PaResponseSurfaceRunner

# 能力水準 (z) → 打席結果 の伝達関数 (感度) を測る計測層。
#
# **現行ワールドの一軍スタメン12球団ぶんをそのまま母集団として使い**、その質能力へ
# オフセット δ を一律に足して実際に打席を回す。δ=0 のセルが一軍の動作点を再現するので、
# そこを起点に 打者オフセット × 投手オフセット のグリッドで応答曲面を作る。
# 守備・捕手・走塁は全セルで δ=0 のまま (傾きには効かないが、動作点を実リーグへ合わせるのに必要)。
#
# ⚠️ **母集団の異質性を捨ててはいけない。** 当初は「同じ水準の合成打者9人 vs 合成投手1人」で
# 作ったが、softmax が非線形なので**平均的な対戦の結果 ≠ 母集団平均の結果**になり、
# δ=0 セルが K% 11.3% (実リーグ 19.4%) / BABIP .353 と大きく外れた。実在の打線・投手陣を
# そのまま使えば動作点が自動的に合い、δ はその上の平行移動として読める。
#
# 得られる3種類の傾き:
#   batter_slope  … ∂metric/∂δb (投手を固定して打者だけ動かす)
#   pitcher_slope … ∂metric/∂δp
#   diagonal      … ∂metric/∂δ  (δb = δp を一緒に動かす = リーグ全体の水準が動くケース)
#
# diagonal が 0 でないことが「レベル不変でない」ことの直接指標、
# batter_slope / pitcher_slope の大きさが「能力差が結果へ効きすぎているか」の指標になる。
# 詳細と改装計画は docs/agent_memory/project_pa_talent_sensitivity_calibration.md を参照。
#
# ⚠️ このツールは production の定数を一切変更しない。観測専用。

const PlayEventBuilder = preload("res://services/simulation/events/play_event_builder.gd")
const PlateEventReducer = preload("res://services/simulation/reducers/plate_event_reducer.gd")

const DEFAULT_YEAR: int = 2026
const DEFAULT_SEASON_NUMBER: int = 1
const GAME_OUTS: int = 27
const DEFAULT_TARGET_OUTS: int = 4050  # = 150 試合ぶん。1セル約 5,600 打席。
const DEFAULT_OFFSETS: Array[float] = [-1.2, -0.8, -0.4, 0.0, 0.4]

# オフセットを載せる「質」の能力キー。スタイル軸 (Bat_Spray/Bat_Aggression/Bat_Platoon/
# Pit_EdgeRate/Pit_HoldRunner) は水準に含めない。
# ⚠️ この分け方は PSPitcherRoleModel.ROLE_QUALITY_KEYS / run_farm_report の
# BATTER_QUALITY_KEYS・PITCHER_QUALITY_KEYS と同じ考え方。全質キーへ同じ δ を足すので、
# run_farm_report が報告する一軍→二軍の水準差 (打者 -0.87σ / 投手 -0.78σ) を
# **そのままこのグリッドの軸として読める**。
const BATTER_LEVEL_KEYS: Array[String] = [
	"Bat_Barrel", "Bat_Impact", "Bat_Loft", "Bat_BBCreate", "Bat_KAvoid",
]
const PITCHER_LEVEL_KEYS: Array[String] = [
	"Pit_KCreate", "Pit_BBPrevent", "Pit_ImpactLimit", "Pit_LoftControl",
	"Pit_BarrelDeny", "Pit_Efficiency", "Pit_Stamina", "Pit_FatigueResist",
]

# 母集団は**ゲーム自身の選出ロジック**で決める。独自ランキング (打撃 z 上位9人など) で採ると
# 守備込みで選ばれる捕手・二遊間が落ちて打者側だけ強く出る (実測: OPS .929 / BABIP .412)。
# 打線 = select_defensive_starters + DH、守備も同じ9人。投手は pitcher_order_score 上位
# = 6ローテ + 主力救援5 ≒ 一軍イニングの大半を投げる層。
# ⚠️ 妥当性の確認は reference_* の health checks で行う。
const POPULATION_PITCHERS_PER_TEAM: int = 11

# --- 較正ターゲット ---
# ⚠️ **2026-08-17 ユーザー方針: 一軍とファームのどちらが高いかは問わない。**
# 大きく逸脱していなければ十分なので、レベル差の帯は**両側**にする (以前は NPB 13年の
# 符号安定性を根拠に片側ゲートにしていたが、その要件は取り下げ)。
# 直さなければならないのは **専用球団の勝率** = 非対称マッチアップの感度。
const ANCHOR_LEVEL_DROP: float = 0.80
# 水準 -0.8σ で一軍からどれだけ動いてよいか (両側)。基準は δ=0 の得点 3.5-3.6 に対する割合と、
# NPB 2013-2025 の一軍 vs ファーム年次レンジ (得点 -.25〜+.58 / BB% -0.2〜+1.8pt)。
const DEVIATION_RUNS: Array = [-0.60, 0.60]
const DEVIATION_RUNS_HARD: Array = [-1.20, 1.20]
const DEVIATION_K_RATE: Array = [-0.025, 0.025]
const DEVIATION_K_RATE_HARD: Array = [-0.045, 0.045]
const DEVIATION_HR: Array = [-0.40, 0.40]
const DEVIATION_HR_HARD: Array = [-0.70, 0.70]
const DEVIATION_BB_RATE: Array = [-0.020, 0.020]
const DEVIATION_BB_RATE_HARD: Array = [-0.035, 0.035]
# **主ゲート**: ファーム専用球団の勝率 (ハヤテ2024 .315 / オイシックス2024 .358)。
# グリッドから Pythagorean で推定する。守備・走塁の差を含まないので帯は広めだが、
# 現状 .079 は桁で外れているので広さは問題にならない。
const ANCHOR_FARM_CLUB_WIN_PCT: Array = [0.270, 0.420]
const ANCHOR_FARM_CLUB_WIN_PCT_HARD: Array = [0.200, 0.500]
const PYTHAGOREAN_EXPONENT: float = 1.83
# 得点/試合の試合間ばらつき (NPB 実測で概ね 2.5-3.0)。セルあたり標本誤差の見積もりに使う。
const RUNS_PER_GAME_SD: float = 2.7

# δ=0 のセルが一軍の動作点を再現できているかの確認帯。report_health.gd のリーグ帯に揃える。
# ここが外れていると傾きを測る場所そのものがずれるので、まずこれを見る。
const REFERENCE_RUNS_BAND: Array = [2.80, 4.20]
const REFERENCE_OPS_BAND: Array = [0.620, 0.760]
const REFERENCE_K_RATE_BAND: Array = [0.175, 0.210]
const REFERENCE_BB_RATE_BAND: Array = [0.072, 0.095]

const STATUS_PASS: String = "pass"
const STATUS_WARN: String = "warn"
const STATUS_FAIL: String = "fail"

const SLOPE_METRICS: Array[String] = [
	"runs_per_game", "strikeout_rate", "walk_rate", "home_runs_per_game",
	"batting_average", "on_base_percentage", "slugging_percentage", "ops",
	"babip", "mean_exit_velocity",
]


func run(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var population: Dictionary = _build_reference_population()
	if not bool(population.get("ok", false)):
		return {
			"version": 1,
			"tool": "pa_response_surface",
			"ok": false,
			"errors": [str(population.get("message", "一軍母集団を構築できませんでした"))],
		}

	var batter_offsets: Array = _offset_axis(options, "batter_offsets")
	var pitcher_offsets: Array = _offset_axis(options, "pitcher_offsets")
	var target_outs: int = int(max(27, int(options.get("target_outs", DEFAULT_TARGET_OUTS))))
	var seed_value: int = int(options.get("seed", 12345))

	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state

	var cells: Array = []
	for batter_index in range(batter_offsets.size()):
		for pitcher_index in range(pitcher_offsets.size()):
			var cell_seed: int = seed_value + batter_index * 7919 + pitcher_index * 104729
			cells.append(_simulate_cell(
				float(batter_offsets[batter_index]),
				float(pitcher_offsets[pitcher_index]),
				population,
				target_outs,
				cell_seed
			))

	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var slopes: Dictionary = _slopes(cells, batter_offsets, pitcher_offsets)
	var matchups: Array = _matchups(cells, batter_offsets, pitcher_offsets)
	var reference_cell: Variant = _cell_at(cells, 0.0, 0.0)
	var anchors: Dictionary = _anchor_comparison(slopes, matchups, cells)
	var checks: Array = _health_checks(anchors, reference_cell)

	return {
		"version": 1,
		"tool": "pa_response_surface",
		"ok": true,
		"seed": seed_value,
		"data_source": GameDb.data_source,
		"grid": {
			"batter_offsets": batter_offsets,
			"pitcher_offsets": pitcher_offsets,
			"target_outs_per_cell": target_outs,
			"batter_level_keys": BATTER_LEVEL_KEYS,
			"pitcher_level_keys": PITCHER_LEVEL_KEYS,
			"held_fixed": "守備・捕手・走塁・利き腕は実在の一軍スタメンのまま固定 / 球種・巡目 (TTO) は補正なし",
		},
		"reference_population": {
			"teams": int(population.get("teams", 0)),
			"batter_sample": int(population.get("batter_sample", 0)),
			"pitcher_sample": int(population.get("pitcher_sample", 0)),
			"batter_level": population.get("batter_level", 0.0),
			"pitcher_level": population.get("pitcher_level", 0.0),
			"batter_profile": population.get("batter_profile", {}),
			"pitcher_profile": population.get("pitcher_profile", {}),
		},
		"reference_cell": reference_cell,
		"cells": cells,
		"slopes": slopes,
		"matchups": matchups,
		"anchors": anchors,
		"health": _health_summary(checks),
		"errors": [],
	}


# --- 一軍相当プロファイルの実測 ---
# GameDb.teams (12球団) からのみ測る。専用球団は GameDb.farm_clubs 側なので構造的に混ざらない
# ([[project_farm_system_design]] の pool_snapshot 汚染と同じ罠を避ける)。
func _build_reference_population() -> Dictionary:
	var lineups: Array = []          # 球団ごとの打順 (9人)
	var fielding_slots: Array = []   # 球団ごとの守備スロット
	var pitchers: Array = []         # 全球団の一軍主力投手をフラットに
	var all_batters: Array = []
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		if team == null:
			continue
		var team_fielders: Array = []
		var team_pitchers: Array = []
		for player_value in GameDb.get_players_for_team(team.id):
			var player: PSPlayer = player_value as PSPlayer
			if player == null or player.is_retired() or player.development_player:
				continue
			var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, DEFAULT_YEAR, DEFAULT_SEASON_NUMBER)
			if record.is_pitcher():
				team_pitchers.append(record)
			else:
				team_fielders.append(record)

		# 打線と守備はゲーム自身の選出ロジックで決める (season は不要 = null で呼べる)。
		var slots: Array = PSTeamSetupBuilder.select_defensive_starters(null, team.id, team_fielders)
		if slots.is_empty() or team_pitchers.is_empty():
			continue
		var order: Array = PSTeamSetupBuilder.records_from_fielding_slots(slots)
		var designated_hitter: PSPlayerSeasonRecord = PSTeamSetupBuilder.select_designated_hitter(team_fielders, slots)
		if designated_hitter != null:
			order.append(designated_hitter)
		PSTeamSetupBuilder.sort_batting_order(order)
		lineups.append(order)
		fielding_slots.append(slots)
		all_batters.append_array(order)

		team_pitchers.sort_custom(func(a, b) -> bool:
			return PSScoringHelpers.pitcher_order_score(a as PSPlayerSeasonRecord) > PSScoringHelpers.pitcher_order_score(b as PSPlayerSeasonRecord)
		)
		for index in range(min(POPULATION_PITCHERS_PER_TEAM, team_pitchers.size())):
			pitchers.append(team_pitchers[index])

	if lineups.is_empty() or pitchers.is_empty():
		return {"ok": false, "message": "一軍相当の選手を抽出できませんでした"}

	var batter_profile: Dictionary = _mean_z_by_key(all_batters, BATTER_LEVEL_KEYS)
	var pitcher_profile: Dictionary = _mean_z_by_key(pitchers, PITCHER_LEVEL_KEYS)
	return {
		"ok": true,
		"lineups": lineups,
		"fielding_slots": fielding_slots,
		"pitchers": pitchers,
		"teams": lineups.size(),
		"batter_sample": all_batters.size(),
		"pitcher_sample": pitchers.size(),
		"batter_profile": batter_profile,
		"pitcher_profile": pitcher_profile,
		# run_farm_report の usage_levels と直接比べる値 (一軍は 打者 +1.60 / 投手 +1.75 付近)。
		"batter_level": _round_float(_mean_of_values(batter_profile), 3),
		"pitcher_level": _round_float(_mean_of_values(pitcher_profile), 3),
	}


func _mean_z_by_key(records: Array, keys: Array[String]) -> Dictionary:
	var means: Dictionary = {}
	if records.is_empty():
		return means
	for key in keys:
		var total: float = 0.0
		for record_value in records:
			total += (record_value as PSPlayerSeasonRecord).z_ability(key, 0.0)
		means[key] = _round_float(total / float(records.size()), 4)
	return means


# --- グリッド1セルの実測 ---

func _simulate_cell(batter_offset: float, pitcher_offset: float, population: Dictionary, target_outs: int, cell_seed: int) -> Dictionary:
	Rng.set_seed_value(cell_seed)

	# セルごとに母集団を複製し、質キーへオフセットを足す。成績が混ざらないよう毎セル作り直す。
	var lineups: Array = []
	for order_value in (population.get("lineups", []) as Array):
		var order: Array = []
		for record_value in (order_value as Array):
			order.append(_offset_record(record_value as PSPlayerSeasonRecord, BATTER_LEVEL_KEYS, batter_offset))
		lineups.append(order)
	var pitchers: Array = []
	for record_value in (population.get("pitchers", []) as Array):
		pitchers.append(_offset_record(record_value as PSPlayerSeasonRecord, PITCHER_LEVEL_KEYS, pitcher_offset))
	# 守備・捕手はオフセットを掛けず実在のスタメンのまま。セル間で同じ順に回すので傾きに効かない。
	var defenses: Array = []
	for slots_value in (population.get("fielding_slots", []) as Array):
		defenses.append(_clone_fielding_slots(slots_value as Array))

	var exit_velocity_sum: float = 0.0
	var launch_angle_sum: float = 0.0
	var batted_balls: int = 0
	var outs_done: int = 0
	var games: int = 0

	while outs_done < target_outs:
		# 打線・投手・守備を決定論的に巡回させ、全セルで同じ組み合わせ列を使う。
		var lineup: Array = lineups[games % lineups.size()] as Array
		var pitcher: PSPlayerSeasonRecord = pitchers[games % pitchers.size()] as PSPlayerSeasonRecord
		var defense: Dictionary = {
			"ok": true,
			"team_id": 0,
			"pitcher": pitcher,
			"batters": [],
			"fielders": defenses[(games + 1) % defenses.size()],
		}
		# 毎試合を「先発が万全で投げ始める」状態にする。疲労を持ち越すと Pit_Stamina 経由で
		# オフセットがセルごとに別の意味を持ってしまう。
		pitcher.fatigue = 0
		var game_outs: int = 0
		var inning_outs: int = 0
		var batting_index: int = 0
		var bases: Array = [null, null, null]
		while game_outs < GAME_OUTS and outs_done < target_outs:
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
				PlateEventReducer.OPTION_CHARGE_PITCHER_RUNS: true,
				PlateEventReducer.OPTION_PITCH_SUMMARY: pitch_summary,
			})
			var quality: Dictionary = outcome.get("contact_quality", {}) as Dictionary
			if not quality.is_empty():
				exit_velocity_sum += float(quality.get("exit_velocity", 0.0))
				launch_angle_sum += float(quality.get("launch_angle", 0.0))
				batted_balls += 1
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			outs_done += outs_added
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
		games += 1

	var batting_totals: PSBatterStats = PSBatterStats.new()
	for order_value in lineups:
		for record_value in (order_value as Array):
			batting_totals.add_from((record_value as PSPlayerSeasonRecord).batter_stats)
	var pitching_totals: PSPitcherStats = PSPitcherStats.new()
	for record_value in pitchers:
		pitching_totals.add_from((record_value as PSPlayerSeasonRecord).pitcher_stats)

	var metrics: Dictionary = _cell_metrics(batting_totals, pitching_totals, games, exit_velocity_sum, launch_angle_sum, batted_balls)
	metrics["batter_offset"] = _round_float(batter_offset, 3)
	metrics["pitcher_offset"] = _round_float(pitcher_offset, 3)
	metrics["batter_level"] = _round_float(float(population.get("batter_level", 0.0)) + batter_offset, 3)
	metrics["pitcher_level"] = _round_float(float(population.get("pitcher_level", 0.0)) + pitcher_offset, 3)
	return metrics


# 記録を複製し、指定キーの z へオフセットを足す。成績はリセットする。
func _offset_record(source: PSPlayerSeasonRecord, keys: Array[String], offset: float) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(source.to_dict())
	for key in keys:
		record.z_abilities_snapshot[key] = record.z_ability(key, 0.0) + offset
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
		var copy: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_dict(record.to_dict())
		copy.batter_stats = PSBatterStats.new()
		copy.pitcher_stats = PSPitcherStats.new()
		copy.fatigue = 0
		cloned.append({"record": copy, "position": int(slot.get("position", 0))})
	return cloned


func _cell_metrics(
	batting: PSBatterStats,
	pitching: PSPitcherStats,
	games: int,
	exit_velocity_sum: float,
	launch_angle_sum: float,
	batted_balls: int
) -> Dictionary:
	var plate_appearances: int = int(batting.plate_appearances)
	var outs: int = int(pitching.outs_pitched)
	var balls_in_play: int = int(batting.at_bats) - int(batting.strikeouts) - int(batting.home_runs) + int(batting.sacrifice_flies)
	return {
		"games": games,
		"plate_appearances": plate_appearances,
		"outs_pitched": outs,
		# 得点/27アウト = 実 NPB の「得点/球団試合」と直接比較できる単位。
		"runs_per_game": _round_float(_per_game(int(pitching.runs_allowed), outs), 3),
		"home_runs_per_game": _round_float(_per_game(int(batting.home_runs), outs), 3),
		"strikeout_rate": _round_float(_safe_div(int(batting.strikeouts), plate_appearances), 4),
		"walk_rate": _round_float(_safe_div(int(batting.walks), plate_appearances), 4),
		"hit_by_pitch_rate": _round_float(_safe_div(int(batting.hit_by_pitches), plate_appearances), 4),
		"batting_average": _round_float(batting.batting_average(), 4),
		"on_base_percentage": _round_float(batting.on_base_percentage(), 4),
		"slugging_percentage": _round_float(batting.slugging_percentage(), 4),
		"ops": _round_float(batting.ops(), 4),
		"babip": _round_float(_safe_div(int(batting.hits) - int(batting.home_runs), balls_in_play), 4),
		"pitches_per_plate_appearance": _round_float(_safe_div(int(batting.pitches_seen), plate_appearances), 3),
		"mean_exit_velocity": _round_float(_safe_div_float(exit_velocity_sum, batted_balls), 2),
		"mean_launch_angle": _round_float(_safe_div_float(launch_angle_sum, batted_balls), 2),
		"balls_in_play": batted_balls,
	}


# --- 傾きの算出 ---

func _slopes(cells: Array, batter_offsets: Array, pitcher_offsets: Array) -> Dictionary:
	var by_key: Dictionary = _cells_by_key(cells)
	var result: Dictionary = {}
	for metric in SLOPE_METRICS:
		# 打者傾き: 投手オフセットを1つ固定して打者軸で回帰し、全投手オフセットで平均する。
		var batter_slopes: Array = []
		for pitcher_offset in pitcher_offsets:
			var xs: Array = []
			var ys: Array = []
			for batter_offset in batter_offsets:
				var cell: Variant = by_key.get(_cell_key(float(batter_offset), float(pitcher_offset)), null)
				if cell == null:
					continue
				xs.append(float(batter_offset))
				ys.append(float((cell as Dictionary).get(metric, 0.0)))
			var slope: float = _linear_slope(xs, ys)
			if not is_nan(slope):
				batter_slopes.append(slope)
		var pitcher_slopes: Array = []
		for batter_offset in batter_offsets:
			var xs2: Array = []
			var ys2: Array = []
			for pitcher_offset in pitcher_offsets:
				var cell2: Variant = by_key.get(_cell_key(float(batter_offset), float(pitcher_offset)), null)
				if cell2 == null:
					continue
				xs2.append(float(pitcher_offset))
				ys2.append(float((cell2 as Dictionary).get(metric, 0.0)))
			var slope2: float = _linear_slope(xs2, ys2)
			if not is_nan(slope2):
				pitcher_slopes.append(slope2)
		# 対角: δb = δp を一緒に動かす。両軸に共通するオフセットだけを使う。
		var diag_xs: Array = []
		var diag_ys: Array = []
		for offset in batter_offsets:
			if not _axis_has(pitcher_offsets, float(offset)):
				continue
			var diag_cell: Variant = by_key.get(_cell_key(float(offset), float(offset)), null)
			if diag_cell == null:
				continue
			diag_xs.append(float(offset))
			diag_ys.append(float((diag_cell as Dictionary).get(metric, 0.0)))
		var diagonal_slope: float = _linear_slope(diag_xs, diag_ys)
		result[metric] = {
			"batter_slope": _round_float(_mean(batter_slopes), 5),
			"pitcher_slope": _round_float(_mean(pitcher_slopes), 5),
			"diagonal_slope": _round_float(0.0 if is_nan(diagonal_slope) else diagonal_slope, 5),
			"diagonal_points": diag_xs.size(),
		}
	return result


# --- 非対称マッチアップ (専用球団のケース) ---
# δ=0 の標準チームに対し「両側とも δ だけ弱いチーム」の得点環境を Pythagorean 勝率へ変換する。
# RS = 弱い打線 vs 標準投手 / RA = 標準打線 vs 弱い投手。
func _matchups(cells: Array, batter_offsets: Array, pitcher_offsets: Array) -> Array:
	var by_key: Dictionary = _cells_by_key(cells)
	if not _axis_has(batter_offsets, 0.0) or not _axis_has(pitcher_offsets, 0.0):
		return []

	var rows: Array = []
	for batter_offset in batter_offsets:
		var drop: float = -float(batter_offset)
		if drop <= 0.0001 or not _axis_has(pitcher_offsets, float(batter_offset)):
			continue
		var scored: Variant = by_key.get(_cell_key(float(batter_offset), 0.0), null)
		var allowed: Variant = by_key.get(_cell_key(0.0, float(batter_offset)), null)
		if scored == null or allowed == null:
			continue
		var runs_scored: float = float((scored as Dictionary).get("runs_per_game", 0.0))
		var runs_allowed: float = float((allowed as Dictionary).get("runs_per_game", 0.0))
		rows.append({
			"level_drop": _round_float(drop, 3),
			"runs_scored_per_game": _round_float(runs_scored, 3),
			"runs_allowed_per_game": _round_float(runs_allowed, 3),
			"pythagorean_win_pct": _round_float(_pythagorean(runs_scored, runs_allowed), 4),
		})
	return rows


# --- アンカー比較 ---

func _anchor_comparison(slopes: Dictionary, matchups: Array, cells: Array) -> Dictionary:
	# diagonal_slope は「オフセット +1σ あたりの変化」。アンカーは「-0.8σ したときの変化」なので
	# 符号を反転して ANCHOR_LEVEL_DROP を掛ける。
	var scale: float = -ANCHOR_LEVEL_DROP
	var result: Dictionary = {
		"level_drop": ANCHOR_LEVEL_DROP,
		"note": "値は「水準を %.2fσ 下げたときの変化量」。NPB 2013-2025 の一軍 vs ファーム実測が目標帯。" % ANCHOR_LEVEL_DROP,
	}
	# ⚠️ 回帰値と直接差は一致するとは限らない。対角は線形とは限らず、回帰は両端に引っ張られる。
	# 実測 (2026-08-17) では K% は両者が一致した (+.0245 / +.0208) 一方、得点は -.633 / -.113 と
	# 5倍以上ずれた。**両方を出して、食い違ったら標本を増やすか非線形を疑う。**
	# レベル差の判定は方向を問わない両側帯なので、どちらを見ても結論は変わらないのが正常。
	var reference: Variant = _cell_at(cells, 0.0, 0.0)
	var dropped: Variant = _cell_at(cells, -ANCHOR_LEVEL_DROP, -ANCHOR_LEVEL_DROP)
	var direct: Dictionary = {}
	for metric in ["runs_per_game", "strikeout_rate", "walk_rate", "home_runs_per_game"]:
		var entry: Dictionary = slopes.get(metric, {}) as Dictionary
		result[metric] = _round_float(float(entry.get("diagonal_slope", 0.0)) * scale, 5)
		if reference != null and dropped != null:
			direct[metric] = _round_float(
				float((dropped as Dictionary).get(metric, 0.0)) - float((reference as Dictionary).get(metric, 0.0)), 5
			)
	result["direct"] = direct
	# 1セルの標本誤差の目安。得点/試合の試合間 σ は概ね 2.7 なので、セルあたり試合数から出す。
	# 2セルの差はこの √2 倍。得点の直接差がこの帯に埋もれていたら「測れていない」と読む。
	var games_per_cell: float = float((reference as Dictionary).get("games", 0)) if reference != null else 0.0
	result["runs_standard_error_per_cell"] = _round_float(
		RUNS_PER_GAME_SD / sqrt(max(1.0, games_per_cell)), 4
	)
	result["games_per_cell"] = int(games_per_cell)

	var farm_win_pct: Variant = null
	var best_gap: float = INF
	for row_value in matchups:
		var row: Dictionary = row_value as Dictionary
		var gap: float = abs(float(row.get("level_drop", 0.0)) - ANCHOR_LEVEL_DROP)
		if gap < best_gap:
			best_gap = gap
			farm_win_pct = row.get("pythagorean_win_pct", null)
	result["farm_club_win_pct"] = farm_win_pct
	return result


func _health_checks(anchors: Dictionary, reference_cell: Variant) -> Array:
	var checks: Array = []
	# ① まず動作点。δ=0 のセルが一軍を再現していなければ、以降の傾きは別の場所の傾き。
	var reference_runs: Variant = null
	var reference_ops: Variant = null
	if reference_cell != null:
		reference_runs = (reference_cell as Dictionary).get("runs_per_game", null)
		reference_ops = (reference_cell as Dictionary).get("ops", null)
	_add_range_check(checks, "reference_runs_per_game", reference_runs,
		REFERENCE_RUNS_BAND, [2.60, 4.40],
		"δ=0 セルの 得点/27アウト が一軍水準か (NPB 3.4-3.5)")
	_add_range_check(checks, "reference_ops", reference_ops,
		REFERENCE_OPS_BAND, [0.580, 0.780],
		"δ=0 セルの OPS が一軍水準か (NPB .666-.673)")
	# K%/BB% は感度を触ると真っ先に動く。対戦優位の圧縮を強めすぎると一軍の率まで平坦化するので、
	# 主ゲートを通すために圧縮を強める作業では**これが歯止めになる**。
	_add_range_check(checks, "reference_strikeout_rate", _reference_metric(reference_cell, "strikeout_rate"),
		REFERENCE_K_RATE_BAND, [0.150, 0.235],
		"δ=0 セルの K% が一軍水準か (NPB 19.3%)")
	_add_range_check(checks, "reference_walk_rate", _reference_metric(reference_cell, "walk_rate"),
		REFERENCE_BB_RATE_BAND, [0.060, 0.110],
		"δ=0 セルの BB% が一軍水準か (NPB 8.3%)")
	# ② レベル差 (対角)。**方向は問わない。両側で「大きく逸脱していない」ことだけ見る。**
	_add_range_check(checks, "level_deviation_runs", anchors.get("runs_per_game", null),
		DEVIATION_RUNS, DEVIATION_RUNS_HARD,
		"水準 -0.8σ での 得点/27アウト の変化 (方向は問わない / 参考: NPB 13年 -.25〜+.58)")
	_add_range_check(checks, "level_deviation_strikeout_rate", anchors.get("strikeout_rate", null),
		DEVIATION_K_RATE, DEVIATION_K_RATE_HARD,
		"水準 -0.8σ での K% の変化 (方向は問わない)")
	_add_range_check(checks, "level_deviation_home_runs", anchors.get("home_runs_per_game", null),
		DEVIATION_HR, DEVIATION_HR_HARD,
		"水準 -0.8σ での HR/27アウト の変化 (方向は問わない)")
	_add_range_check(checks, "level_deviation_walk_rate", anchors.get("walk_rate", null),
		DEVIATION_BB_RATE, DEVIATION_BB_RATE_HARD,
		"水準 -0.8σ での BB% の変化 (方向は問わない)")
	# ③ 非対称マッチアップ (専用球団のケース)。
	# ⚠️ **これはゲートではない。** 「ゲーム内の 0.8σ が実クラブの実力差と等しい」という
	# 根拠の無い仮定に依存するため、2026-08-17 に pass/fail を外して観測値へ降格した。
	# 専用球団の勝率の正式ゲートは `run_farm_report` の `farm_club_win_rate`
	# (実シーズンの実勝率を実クラブ .315/.358 と比べる) にある。
	# ここの値は「能力差 δ に対する勝率の応答曲線」として較正の入力に使う。
	_add_observation(checks, "asymmetric_matchup_win_pct", anchors.get("farm_club_win_pct", null),
		"両側 -0.8σ のチームの Pythagorean 勝率 (観測値。ゲートは run_farm_report 側)")
	return checks


# pass/fail を付けずに数値だけ残す。仮定に依存していてゲートにできないが、
# 較正の入力として毎回見たい量に使う。
func _add_observation(checks: Array, name: String, value: Variant, description: String) -> void:
	checks.append({
		"name": name,
		"status": STATUS_PASS,
		"observation": true,
		"value": null if value == null else _round_float(float(value), 5),
		"description": description,
	})


func _reference_metric(reference_cell: Variant, key: String) -> Variant:
	if reference_cell == null:
		return null
	return (reference_cell as Dictionary).get(key, null)


func _add_range_check(checks: Array, name: String, value: Variant, warn_band: Array, fail_band: Array, description: String) -> void:
	if value == null:
		checks.append({"name": name, "status": STATUS_WARN, "value": null, "description": description + " (未測定)"})
		return
	var numeric: float = float(value)
	var status: String = STATUS_PASS
	if numeric < float(fail_band[0]) or numeric > float(fail_band[1]):
		status = STATUS_FAIL
	elif numeric < float(warn_band[0]) or numeric > float(warn_band[1]):
		status = STATUS_WARN
	checks.append({
		"name": name,
		"status": status,
		"value": _round_float(numeric, 5),
		"warn_band": warn_band,
		"fail_band": fail_band,
		"description": description,
	})


func _health_summary(checks: Array) -> Dictionary:
	var fail: int = 0
	var warn: int = 0
	for check_value in checks:
		match str((check_value as Dictionary).get("status", STATUS_PASS)):
			STATUS_FAIL:
				fail += 1
			STATUS_WARN:
				warn += 1
	var status: String = STATUS_PASS
	if fail > 0:
		status = STATUS_FAIL
	elif warn > 0:
		status = STATUS_WARN
	return {"status": status, "fail": fail, "warn": warn, "checks": checks}


# --- 出力補助 ---

func csv_text(report: Dictionary) -> String:
	var columns: Array[String] = [
		"batter_offset", "pitcher_offset", "batter_level", "pitcher_level",
		"plate_appearances", "outs_pitched",
		"runs_per_game", "home_runs_per_game", "strikeout_rate", "walk_rate",
		"batting_average", "on_base_percentage", "slugging_percentage", "ops",
		"babip", "pitches_per_plate_appearance", "mean_exit_velocity", "mean_launch_angle",
	]
	var lines: Array[String] = [",".join(columns)]
	for cell_value in (report.get("cells", []) as Array):
		var cell: Dictionary = cell_value as Dictionary
		var fields: Array[String] = []
		for column in columns:
			fields.append(str(cell.get(column, "")))
		lines.append(",".join(fields))
	return "\n".join(lines) + "\n"


# --- 数値ヘルパー ---

func _offset_axis(options: Dictionary, key: String) -> Array:
	var values: Array = options.get(key, []) as Array
	var parsed: Array = []
	for value in values:
		parsed.append(_round_float(float(value), 3))
	if parsed.is_empty():
		for value in DEFAULT_OFFSETS:
			parsed.append(_round_float(value, 3))
	parsed.sort()
	return parsed


func _cells_by_key(cells: Array) -> Dictionary:
	var by_key: Dictionary = {}
	for cell_value in cells:
		var cell: Dictionary = cell_value as Dictionary
		by_key[_cell_key(float(cell["batter_offset"]), float(cell["pitcher_offset"]))] = cell
	return by_key


func _cell_at(cells: Array, batter_offset: float, pitcher_offset: float) -> Variant:
	return _cells_by_key(cells).get(_cell_key(batter_offset, pitcher_offset), null)


func _axis_has(axis: Array, value: float) -> bool:
	for entry in axis:
		if abs(float(entry) - value) < 0.0005:
			return true
	return false


func _cell_key(batter_offset: float, pitcher_offset: float) -> String:
	return "%.3f|%.3f" % [batter_offset, pitcher_offset]


# 最小二乗の傾き。点が2つ未満、または x が全て同じなら NAN。
func _linear_slope(xs: Array, ys: Array) -> float:
	var n: int = xs.size()
	if n < 2 or ys.size() != n:
		return NAN
	var mean_x: float = 0.0
	var mean_y: float = 0.0
	for index in range(n):
		mean_x += float(xs[index])
		mean_y += float(ys[index])
	mean_x /= float(n)
	mean_y /= float(n)
	var numerator: float = 0.0
	var denominator: float = 0.0
	for index in range(n):
		var dx: float = float(xs[index]) - mean_x
		numerator += dx * (float(ys[index]) - mean_y)
		denominator += dx * dx
	if denominator <= 0.0000001:
		return NAN
	return numerator / denominator


func _pythagorean(runs_scored: float, runs_allowed: float) -> float:
	if runs_scored <= 0.0:
		return 0.0
	if runs_allowed <= 0.0:
		return 1.0
	var scored_power: float = pow(runs_scored, PYTHAGOREAN_EXPONENT)
	var allowed_power: float = pow(runs_allowed, PYTHAGOREAN_EXPONENT)
	return scored_power / (scored_power + allowed_power)


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _mean_of_values(values: Dictionary) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for key in values.keys():
		total += float(values[key])
	return total / float(values.size())


func _per_game(count: int, outs: int) -> float:
	if outs <= 0:
		return 0.0
	return float(count) * float(GAME_OUTS) / float(outs)


func _safe_div(numerator: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return float(numerator) / float(denominator)


func _safe_div_float(numerator: float, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return numerator / float(denominator)


func _round_float(value: float, digits: int) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor
