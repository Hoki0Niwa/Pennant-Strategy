extends RefCounted
class_name PlayerProbeRunner

const PlayEventBuilder = preload("res://services/simulation/events/play_event_builder.gd")
const PlateEventReducer = preload("res://services/simulation/reducers/plate_event_reducer.gd")
const AdvancedStatReducer = preload("res://services/simulation/reducers/advanced_stat_reducer.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")

const DEFAULT_YEAR: int = 2026
const DEFAULT_SEASON_NUMBER: int = 1
const DEFAULT_PLATE_APPEARANCES: int = 600

# (team_id, dh_enabled) ごとに「ローテーション・守備スロット・打順素材」を
# 1 度だけ作って使い回す。打撃プローブでは相手投手の記録、投球プローブでは
# 相手打者の記録ともに track フラグが false で渡されるためミューテートされず、
# 試合間で安全に共有できる。
var _team_blueprint_cache: Dictionary = {}
const DEFAULT_TARGET_OUTS: int = 600
const GAME_OUTS: int = 27
const DEFAULT_METRIC_BY_ABILITY: Dictionary = {
	"Bat_KAvoid": "strikeout_rate",
	"Bat_BBCreate": "walk_rate",
	"Bat_Impact": "home_runs",
	"Bat_Loft": "home_runs",
	"Bat_Barrel": "batting_average",
	"Bat_Spray": "doubles",
	"Bat_Aggression": "ops",
	"Bat_Platoon": "ops",
	"Run_Speed": "ops",
	"Pit_KCreate": "strikeouts_per_nine",
	"Pit_BBPrevent": "walks_per_nine",
	"Pit_ImpactLimit": "home_runs_per_nine",
	"Pit_LoftControl": "home_runs_per_nine",
	"Pit_BarrelDeny": "home_runs_per_nine",
	"Pit_Efficiency": "pitches_per_inning",
	"Pit_Stamina": "outs_pitched",
	"Pit_FatigueResist": "outs_pitched",
	"Pit_HoldRunner": "whip",
	"Pit_EdgeRate": "walks_per_nine",
	"max_velocity": "strikeouts_per_nine",
}


func run(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var normalized: Dictionary = _normalized_options(options)
	var mode: String = str(normalized.get("mode", "batter"))
	var base_subject: PSPlayerSeasonRecord = _custom_subject_record(normalized) if bool(normalized.get("custom_subject", false)) else null
	var subject_player: PSPlayer = null
	if base_subject == null:
		subject_player = _select_subject_player(normalized)
		if subject_player != null:
			base_subject = PSPlayerSeasonRecord.from_player(subject_player, DEFAULT_YEAR, DEFAULT_SEASON_NUMBER)
	if base_subject == null:
		return {
			"version": 1,
			"tool": "player_probe",
			"ok": false,
			"errors": ["検証対象を作成できませんでした。選手指定またはカスタム能力値を確認してください。"],
		}

	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	var seed_value: int = int(normalized.get("seed", -1))
	if seed_value >= 0:
		Rng.set_seed_value(seed_value)

	_apply_set_overrides(base_subject, normalized.get("set_overrides", {}) as Dictionary)
	var sweep_ability: String = str(normalized.get("sweep_ability", ""))
	var sweep_values: Array = _sweep_values(normalized)
	var iterations: int = int(normalized.get("iterations", 1))
	var metric: String = str(normalized.get("metric", ""))
	if metric.is_empty():
		metric = str(DEFAULT_METRIC_BY_ABILITY.get(sweep_ability, "home_runs" if mode == "batter" else "era"))

	var errors: Array = []
	var rows: Array = []
	if sweep_ability.is_empty():
		var runs: Array = []
		for iteration in range(iterations):
			var run_seed: int = _run_seed(seed_value, 0, iteration)
			runs.append(_run_single(base_subject, normalized, "", 0, run_seed))
		var summary: Dictionary = _average_summaries(runs)
		rows.append({
			"ability": "",
			"ability_value": null,
			"iterations": iterations,
			"metric": metric,
			"metric_value": _metric_value(summary, metric),
			"summary": summary,
			"runs": runs,
		})
	else:
		for value_index in range(sweep_values.size()):
			var ability_value: float = float(sweep_values[value_index])
			var runs_for_value: Array = []
			for iteration in range(iterations):
				var run_seed: int = _run_seed(seed_value, value_index, iteration)
				runs_for_value.append(_run_single(base_subject, normalized, sweep_ability, ability_value, run_seed))
			var value_summary: Dictionary = _average_summaries(runs_for_value)
			rows.append({
				"ability": sweep_ability,
				"ability_value": ability_value,
				"iterations": iterations,
				"metric": metric,
				"metric_value": _metric_value(value_summary, metric),
				"summary": value_summary,
				"runs": runs_for_value,
			})

	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	return {
		"version": 1,
		"tool": "player_probe",
		"ok": errors.is_empty(),
		"mode": mode,
		"seed": seed_value,
		"data_source": GameDb.data_source,
		"subject": _record_subject_row(base_subject, subject_player),
		"base_abilities": _record_ability_row(base_subject),
		"target": {
			"plate_appearances": int(normalized.get("plate_appearances", DEFAULT_PLATE_APPEARANCES)),
			"outs": int(normalized.get("target_outs", DEFAULT_TARGET_OUTS)),
			"innings": _round_float(float(int(normalized.get("target_outs", DEFAULT_TARGET_OUTS))) / 3.0, 1),
		},
		"sweep": {
			"ability": sweep_ability,
			"values": sweep_values,
			"iterations": iterations,
			"metric": metric,
		},
		"rows": rows,
		"errors": errors,
	}


# --- async 版 (UI フリーズ対策) ---
# 同期版 run() と同じ振る舞いだが、PA 単位で yield + キャンセル確認を行う。
# options:
#   "scene_tree": SceneTree (await get_tree().process_frame に使う)
#   "progress_callback": Callable(done: int, total: int, label: String)
#   "cancel_token": { "cancelled": bool }
#   "chunk_size": int (この PA 数ごとに 1 フレ yield, 既定 50)
# 戻り値の Dictionary には "cancelled" を含む。キャンセル時も途中までの集計を返す。
func run_async(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var normalized: Dictionary = _normalized_options(options)
	var mode: String = str(normalized.get("mode", "batter"))
	var base_subject: PSPlayerSeasonRecord = _custom_subject_record(normalized) if bool(normalized.get("custom_subject", false)) else null
	var subject_player: PSPlayer = null
	if base_subject == null:
		subject_player = _select_subject_player(normalized)
		if subject_player != null:
			base_subject = PSPlayerSeasonRecord.from_player(subject_player, DEFAULT_YEAR, DEFAULT_SEASON_NUMBER)
	if base_subject == null:
		return {
			"version": 1,
			"tool": "player_probe",
			"ok": false,
			"errors": ["検証対象を作成できませんでした。選手指定またはカスタム能力値を確認してください。"],
		}

	var tree: SceneTree = options.get("scene_tree") as SceneTree
	var progress_cb: Callable = options.get("progress_callback", Callable())
	var cancel_token: Dictionary = options.get("cancel_token", {})
	var chunk_size: int = int(max(1, int(options.get("chunk_size", 50))))

	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	var seed_value: int = int(normalized.get("seed", -1))
	if seed_value >= 0:
		Rng.set_seed_value(seed_value)

	_apply_set_overrides(base_subject, normalized.get("set_overrides", {}) as Dictionary)
	var sweep_ability: String = str(normalized.get("sweep_ability", ""))
	var sweep_values: Array = _sweep_values(normalized)
	var iterations: int = int(normalized.get("iterations", 1))
	var metric: String = str(normalized.get("metric", ""))
	if metric.is_empty():
		metric = str(DEFAULT_METRIC_BY_ABILITY.get(sweep_ability, "home_runs" if mode == "batter" else "era"))

	# 進捗の母数: 全 sweep × iterations での目標 PA (打撃) または target_outs (投球)
	var per_run_units: int = int(normalized.get("plate_appearances", DEFAULT_PLATE_APPEARANCES)) if mode == "batter" else int(normalized.get("target_outs", DEFAULT_TARGET_OUTS))
	var sweep_total_runs: int = max(1, sweep_values.size()) * iterations if not sweep_ability.is_empty() else iterations
	var total_units: int = per_run_units * sweep_total_runs
	var done_units: int = 0
	var progress_label: String = "打席シミュレーション中" if mode == "batter" else "投球シミュレーション中"
	if progress_cb.is_valid():
		progress_cb.call(0, total_units, progress_label)

	var async_ctx: Dictionary = {
		"tree": tree,
		"progress_cb": progress_cb,
		"cancel_token": cancel_token,
		"chunk_size": chunk_size,
		"total_units": total_units,
		"label": progress_label,
	}

	var errors: Array = []
	var rows: Array = []
	if sweep_ability.is_empty():
		var runs: Array = []
		for iteration in range(iterations):
			if _is_cancelled(cancel_token):
				break
			var run_seed: int = _run_seed(seed_value, 0, iteration)
			var single: Dictionary = await _run_single_async(base_subject, normalized, "", 0, run_seed, async_ctx, done_units)
			runs.append(single)
			done_units += int(single.get("_units_this_run", 0))
		var summary: Dictionary = _average_summaries(runs)
		rows.append({
			"ability": "",
			"ability_value": null,
			"iterations": iterations,
			"metric": metric,
			"metric_value": _metric_value(summary, metric),
			"summary": summary,
			"runs": runs,
		})
	else:
		for value_index in range(sweep_values.size()):
			if _is_cancelled(cancel_token):
				break
			var ability_value: float = float(sweep_values[value_index])
			var runs_for_value: Array = []
			for iteration in range(iterations):
				if _is_cancelled(cancel_token):
					break
				var run_seed: int = _run_seed(seed_value, value_index, iteration)
				var single: Dictionary = await _run_single_async(base_subject, normalized, sweep_ability, ability_value, run_seed, async_ctx, done_units)
				runs_for_value.append(single)
				done_units += int(single.get("_units_this_run", 0))
			if runs_for_value.is_empty():
				continue
			var value_summary: Dictionary = _average_summaries(runs_for_value)
			rows.append({
				"ability": sweep_ability,
				"ability_value": ability_value,
				"iterations": iterations,
				"metric": metric,
				"metric_value": _metric_value(value_summary, metric),
				"summary": value_summary,
				"runs": runs_for_value,
			})

	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	var cancelled: bool = _is_cancelled(cancel_token)
	return {
		"version": 1,
		"tool": "player_probe",
		"ok": errors.is_empty(),
		"cancelled": cancelled,
		"mode": mode,
		"seed": seed_value,
		"data_source": GameDb.data_source,
		"subject": _record_subject_row(base_subject, subject_player),
		"base_abilities": _record_ability_row(base_subject),
		"target": {
			"plate_appearances": int(normalized.get("plate_appearances", DEFAULT_PLATE_APPEARANCES)),
			"outs": int(normalized.get("target_outs", DEFAULT_TARGET_OUTS)),
			"innings": _round_float(float(int(normalized.get("target_outs", DEFAULT_TARGET_OUTS))) / 3.0, 1),
		},
		"sweep": {
			"ability": sweep_ability,
			"values": sweep_values,
			"iterations": iterations,
			"metric": metric,
		},
		"rows": rows,
		"errors": errors,
	}


func _is_cancelled(cancel_token: Dictionary) -> bool:
	return not cancel_token.is_empty() and bool(cancel_token.get("cancelled", false))


func _run_single_async(
	base_subject: PSPlayerSeasonRecord,
	options: Dictionary,
	sweep_ability: String,
	ability_value: float,
	run_seed: int,
	async_ctx: Dictionary,
	progress_baseline: int
) -> Dictionary:
	if run_seed >= 0:
		Rng.set_seed_value(run_seed)
	var subject: PSPlayerSeasonRecord = _clone_record(base_subject)
	_reset_record_stats(subject)
	if not sweep_ability.is_empty():
		_set_ability(subject, sweep_ability, ability_value)
	var mode: String = str(options.get("mode", "batter"))
	var run_meta: Dictionary = {}
	var units_done_in_run: int = 0
	if mode == "pitcher":
		run_meta = await _simulate_pitcher_async(subject, options, async_ctx, progress_baseline)
		units_done_in_run = int(subject.pitcher_stats.outs_pitched)
		var pitcher_summary: Dictionary = _pitcher_summary(subject.pitcher_stats)
		pitcher_summary.merge(run_meta, true)
		pitcher_summary["seed"] = run_seed
		pitcher_summary["ability_value"] = null
		if not sweep_ability.is_empty():
			pitcher_summary["ability_value"] = ability_value
		pitcher_summary["_units_this_run"] = units_done_in_run
		return pitcher_summary
	var batter_meta: Dictionary = await _simulate_batter_async(subject, options, async_ctx, progress_baseline)
	units_done_in_run = int(subject.batter_stats.plate_appearances)
	var batter_summary: Dictionary = _batter_summary(subject.batter_stats)
	batter_summary.merge(batter_meta, true)
	batter_summary["seed"] = run_seed
	batter_summary["ability_value"] = null
	if not sweep_ability.is_empty():
		batter_summary["ability_value"] = ability_value
	batter_summary["_units_this_run"] = units_done_in_run
	return batter_summary


func _simulate_batter_async(subject: PSPlayerSeasonRecord, options: Dictionary, async_ctx: Dictionary, progress_baseline: int) -> Dictionary:
	var target_pa: int = int(options.get("plate_appearances", DEFAULT_PLATE_APPEARANCES))
	var game_index: int = 0
	var team_ids: Array = _opponent_team_ids(subject.team_id, bool(options.get("exclude_subject_team", true)))
	var advanced_stats: Dictionary = AdvancedStatReducer.empty_advanced_stats()
	var tree: SceneTree = async_ctx.get("tree") as SceneTree
	var progress_cb: Callable = async_ctx.get("progress_cb", Callable())
	var cancel_token: Dictionary = async_ctx.get("cancel_token", {})
	var chunk_size: int = int(async_ctx.get("chunk_size", 50))
	var total_units: int = int(async_ctx.get("total_units", 0))
	var label: String = str(async_ctx.get("label", ""))
	var chunk_counter: int = 0
	while subject.batter_stats.plate_appearances < target_pa:
		if _is_cancelled(cancel_token):
			break
		var opponent_team_id: int = _random_team_id(team_ids)
		var defense: Dictionary = _build_team_setup(opponent_team_id, game_index, bool(options.get("dh", true)))
		if not bool(defense.get("ok", false)):
			break
		var pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
		if pitcher == null:
			break
		subject.batter_stats.games += 1
		var bases: Array = [null, null, null]
		var inning_outs: int = 0
		var game_outs: int = 0
		while game_outs < GAME_OUTS and subject.batter_stats.plate_appearances < target_pa:
			if _is_cancelled(cancel_token):
				break
			var event_index: int = int(subject.batter_stats.plate_appearances)
			var bases_before: Array = bases.duplicate()
			var outs_before: int = inning_outs
			var outcome: Dictionary = _resolve_plate_outcome(subject, pitcher, defense, bases, inning_outs, false)
			var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
			if pitch_summary.is_empty():
				pitch_summary = PlayEventBuilder.pitch_summary_for_play(event_index, subject, pitcher, outcome)
			var applied: Dictionary = _apply_plate_outcome(subject, pitcher, bases, inning_outs, outcome, true, false, pitch_summary)
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			_apply_probe_advanced_event(
				advanced_stats, event_index, subject, pitcher, _probe_offense(subject), defense,
				bases_before, outs_before, outcome, bases, inning_outs,
				int(applied.get("runs", 0)), pitch_summary
			)
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
			chunk_counter += 1
			if chunk_counter >= chunk_size:
				chunk_counter = 0
				if progress_cb.is_valid():
					progress_cb.call(progress_baseline + int(subject.batter_stats.plate_appearances), total_units, label)
				if tree != null:
					await tree.process_frame
		game_index += 1
	if progress_cb.is_valid():
		progress_cb.call(progress_baseline + int(subject.batter_stats.plate_appearances), total_units, label)
	var meta: Dictionary = {
		"games_simulated": game_index,
	}
	meta.merge(_advanced_summary_for_subject(advanced_stats, subject, false), true)
	return meta


func _simulate_pitcher_async(subject: PSPlayerSeasonRecord, options: Dictionary, async_ctx: Dictionary, progress_baseline: int) -> Dictionary:
	var target_outs: int = int(options.get("target_outs", DEFAULT_TARGET_OUTS))
	var game_index: int = 0
	var team_ids: Array = _opponent_team_ids(subject.team_id, bool(options.get("exclude_subject_team", true)))
	var defense_team_id: int = int(options.get("defense_team_id", subject.team_id))
	var advanced_stats: Dictionary = AdvancedStatReducer.empty_advanced_stats()
	var tree: SceneTree = async_ctx.get("tree") as SceneTree
	var progress_cb: Callable = async_ctx.get("progress_cb", Callable())
	var cancel_token: Dictionary = async_ctx.get("cancel_token", {})
	var chunk_size: int = int(async_ctx.get("chunk_size", 50))
	var total_units: int = int(async_ctx.get("total_units", 0))
	var label: String = str(async_ctx.get("label", ""))
	var chunk_counter: int = 0
	while subject.pitcher_stats.outs_pitched < target_outs:
		if _is_cancelled(cancel_token):
			break
		var opponent_team_id: int = _random_team_id(team_ids)
		var offense: Dictionary = _build_team_setup(opponent_team_id, game_index, bool(options.get("dh", true)))
		if not bool(offense.get("ok", false)):
			break
		var defense: Dictionary = _build_subject_defense(subject, defense_team_id)
		subject.pitcher_stats.games += 1
		subject.pitcher_stats.starts += 1
		var lineup: Array = offense.get("batters", []) as Array
		var batting_index: int = 0
		var bases: Array = [null, null, null]
		var inning_outs: int = 0
		var game_outs: int = 0
		while game_outs < GAME_OUTS and subject.pitcher_stats.outs_pitched < target_outs and not lineup.is_empty():
			if _is_cancelled(cancel_token):
				break
			var batter: PSPlayerSeasonRecord = lineup[batting_index % lineup.size()] as PSPlayerSeasonRecord
			batting_index += 1
			var event_index: int = int(subject.pitcher_stats.batters_faced)
			var bases_before: Array = bases.duplicate()
			var outs_before: int = inning_outs
			var outcome: Dictionary = _resolve_plate_outcome(batter, subject, defense, bases, inning_outs, bool(options.get("reliever", false)))
			var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
			if pitch_summary.is_empty():
				pitch_summary = PlayEventBuilder.pitch_summary_for_play(event_index, batter, subject, outcome)
			var applied: Dictionary = _apply_plate_outcome(batter, subject, bases, inning_outs, outcome, false, true, pitch_summary)
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			_apply_probe_advanced_event(
				advanced_stats, event_index, batter, subject, offense, defense,
				bases_before, outs_before, outcome, bases, inning_outs,
				int(applied.get("runs", 0)), pitch_summary
			)
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
			chunk_counter += 1
			if chunk_counter >= chunk_size:
				chunk_counter = 0
				if progress_cb.is_valid():
					progress_cb.call(progress_baseline + int(subject.pitcher_stats.outs_pitched), total_units, label)
				if tree != null:
					await tree.process_frame
		if game_outs >= GAME_OUTS:
			subject.pitcher_stats.complete_games += 1
			if int(subject.pitcher_stats.runs_allowed) == 0:
				subject.pitcher_stats.shutouts += 1
		game_index += 1
	if progress_cb.is_valid():
		progress_cb.call(progress_baseline + int(subject.pitcher_stats.outs_pitched), total_units, label)
	var meta: Dictionary = {
		"games_simulated": game_index,
	}
	meta.merge(_advanced_summary_for_subject(advanced_stats, subject, true), true)
	return meta


func csv_text(report: Dictionary) -> String:
	var rows: Array = report.get("rows", []) as Array
	var lines: Array = [
		"ability,ability_value,metric,metric_value,iterations,games,plate_appearances,at_bats,hits,doubles,triples,home_runs,walks,hit_by_pitches,strikeouts,pitches_seen,pitches_per_plate_appearance,batting_average,on_base_percentage,slugging_percentage,ops,woba,wrc_plus,re24,bsr,xwoba,fielding_chances,oaa,oaa_infield,oaa_outfield,rngr,errr,dpr,uzr,drs,fielding_runs,positional_adjustment_runs,def_runs,outs_pitched,innings_pitched,batters_faced,pitches_thrown,pitches_per_batter_faced,pitches_per_inning,hits_allowed,home_runs_allowed,runs_allowed,earned_runs,era,whip,strikeouts_per_nine,walks_per_nine,home_runs_per_nine"
	]
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var summary: Dictionary = row.get("summary", {}) as Dictionary
		var values: Array = [
			_csv_cell(str(row.get("ability", ""))),
			_csv_cell(str(row.get("ability_value", ""))),
			_csv_cell(str(row.get("metric", ""))),
			_num(summary.get(str(row.get("metric", "")), row.get("metric_value", 0.0))),
			str(int(row.get("iterations", 1))),
			_num(summary.get("games", 0.0)),
			_num(summary.get("plate_appearances", 0.0)),
			_num(summary.get("at_bats", 0.0)),
			_num(summary.get("hits", 0.0)),
			_num(summary.get("doubles", 0.0)),
			_num(summary.get("triples", 0.0)),
			_num(summary.get("home_runs", 0.0)),
			_num(summary.get("walks", 0.0)),
			_num(summary.get("hit_by_pitches", 0.0)),
			_num(summary.get("strikeouts", 0.0)),
			_num(summary.get("pitches_seen", 0.0)),
			_num(summary.get("pitches_per_plate_appearance", 0.0)),
			_num(summary.get("batting_average", 0.0)),
			_num(summary.get("on_base_percentage", 0.0)),
			_num(summary.get("slugging_percentage", 0.0)),
			_num(summary.get("ops", 0.0)),
			_num(summary.get("woba", 0.0)),
			_num(summary.get("wrc_plus", 0.0)),
			_num(summary.get("re24", 0.0)),
			_num(summary.get("bsr", 0.0)),
			_num(summary.get("xwoba", 0.0)),
			_num(summary.get("fielding_chances", 0.0)),
			_num(summary.get("oaa", 0.0)),
			_num(summary.get("oaa_infield", 0.0)),
			_num(summary.get("oaa_outfield", 0.0)),
			_num(summary.get("rngr", 0.0)),
			_num(summary.get("errr", 0.0)),
			_num(summary.get("dpr", 0.0)),
			_num(summary.get("uzr", 0.0)),
			_num(summary.get("drs", 0.0)),
			_num(summary.get("fielding_runs", 0.0)),
			_num(summary.get("positional_adjustment_runs", 0.0)),
			_num(summary.get("def_runs", 0.0)),
			_num(summary.get("outs_pitched", 0.0)),
			_num(summary.get("innings_pitched", 0.0)),
			_num(summary.get("batters_faced", 0.0)),
			_num(summary.get("pitches_thrown", 0.0)),
			_num(summary.get("pitches_per_batter_faced", 0.0)),
			_num(summary.get("pitches_per_inning", 0.0)),
			_num(summary.get("hits_allowed", 0.0)),
			_num(summary.get("home_runs_allowed", 0.0)),
			_num(summary.get("runs_allowed", 0.0)),
			_num(summary.get("earned_runs", 0.0)),
			_num(summary.get("era", 0.0)),
			_num(summary.get("whip", 0.0)),
			_num(summary.get("strikeouts_per_nine", 0.0)),
			_num(summary.get("walks_per_nine", 0.0)),
			_num(summary.get("home_runs_per_nine", 0.0)),
		]
		lines.append(",".join(values))
	return "\n".join(lines) + "\n"


func svg_text(report: Dictionary) -> String:
	var rows: Array = report.get("rows", []) as Array
	if rows.size() < 2:
		return ""
	var sweep: Dictionary = report.get("sweep", {}) as Dictionary
	var ability: String = str(sweep.get("ability", "ability"))
	var metric: String = str(sweep.get("metric", "metric"))
	var points: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if row.get("ability_value", null) == null:
			continue
		points.append({
			"x": float(row.get("ability_value", 0)),
			"y": float(row.get("metric_value", 0.0)),
		})
	if points.size() < 2:
		return ""

	var min_x: float = float(points[0].get("x", 0.0))
	var max_x: float = min_x
	var min_y: float = float(points[0].get("y", 0.0))
	var max_y: float = min_y
	for point_value in points:
		var point: Dictionary = point_value as Dictionary
		min_x = min(min_x, float(point.get("x", 0.0)))
		max_x = max(max_x, float(point.get("x", 0.0)))
		min_y = min(min_y, float(point.get("y", 0.0)))
		max_y = max(max_y, float(point.get("y", 0.0)))
	if is_equal_approx(max_x, min_x):
		max_x += 1.0
	if is_equal_approx(max_y, min_y):
		max_y += 1.0

	var width: float = 900.0
	var height: float = 520.0
	var left: float = 72.0
	var right: float = 28.0
	var top: float = 42.0
	var bottom: float = 72.0
	var plot_w: float = width - left - right
	var plot_h: float = height - top - bottom
	var polyline: Array = []
	var circles: Array = []
	for point_value in points:
		var point: Dictionary = point_value as Dictionary
		var px: float = left + (float(point.get("x", 0.0)) - min_x) / (max_x - min_x) * plot_w
		var py: float = top + plot_h - (float(point.get("y", 0.0)) - min_y) / (max_y - min_y) * plot_h
		polyline.append("%.1f,%.1f" % [px, py])
		circles.append('<circle cx="%.1f" cy="%.1f" r="4" fill="#2563eb"><title>%s z %+.2f / %s %.3f</title></circle>' % [px, py, _xml_escape(ability), float(point.get("x", 0.0)), _xml_escape(metric), float(point.get("y", 0.0))])

	return """<svg xmlns="http://www.w3.org/2000/svg" width="900" height="520" viewBox="0 0 900 520">
<rect width="900" height="520" fill="#ffffff"/>
<text x="450" y="24" text-anchor="middle" font-family="sans-serif" font-size="18" fill="#111827">%s vs %s</text>
<line x1="72" y1="448" x2="872" y2="448" stroke="#374151" stroke-width="1"/>
<line x1="72" y1="42" x2="72" y2="448" stroke="#374151" stroke-width="1"/>
<text x="472" y="500" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#374151">%s z</text>
<text x="18" y="245" text-anchor="middle" font-family="sans-serif" font-size="14" fill="#374151" transform="rotate(-90 18 245)">%s</text>
<text x="72" y="468" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#6b7280">%+.2f</text>
<text x="872" y="468" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#6b7280">%+.2f</text>
<text x="64" y="452" text-anchor="end" font-family="sans-serif" font-size="12" fill="#6b7280">%.3f</text>
<text x="64" y="46" text-anchor="end" font-family="sans-serif" font-size="12" fill="#6b7280">%.3f</text>
<polyline points="%s" fill="none" stroke="#2563eb" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
%s
</svg>
""" % [
		_xml_escape(ability),
		_xml_escape(metric),
		_xml_escape(ability),
		_xml_escape(metric),
		min_x,
		max_x,
		min_y,
		max_y,
		" ".join(polyline),
		"\n".join(circles),
	]


func _run_single(base_subject: PSPlayerSeasonRecord, options: Dictionary, sweep_ability: String, ability_value: float, run_seed: int) -> Dictionary:
	if run_seed >= 0:
		Rng.set_seed_value(run_seed)
	var subject: PSPlayerSeasonRecord = _clone_record(base_subject)
	_reset_record_stats(subject)
	if not sweep_ability.is_empty():
		_set_ability(subject, sweep_ability, ability_value)
	var mode: String = str(options.get("mode", "batter"))
	var run_meta: Dictionary = {}
	if mode == "pitcher":
		run_meta = _simulate_pitcher(subject, options)
		var pitcher_summary: Dictionary = _pitcher_summary(subject.pitcher_stats)
		pitcher_summary.merge(run_meta, true)
		pitcher_summary["seed"] = run_seed
		pitcher_summary["ability_value"] = null
		if not sweep_ability.is_empty():
			pitcher_summary["ability_value"] = ability_value
		return pitcher_summary
	var batter_meta: Dictionary = _simulate_batter(subject, options)
	var batter_summary: Dictionary = _batter_summary(subject.batter_stats)
	batter_summary.merge(batter_meta, true)
	batter_summary["seed"] = run_seed
	batter_summary["ability_value"] = null
	if not sweep_ability.is_empty():
		batter_summary["ability_value"] = ability_value
	return batter_summary


func _simulate_batter(subject: PSPlayerSeasonRecord, options: Dictionary) -> Dictionary:
	var target_pa: int = int(options.get("plate_appearances", DEFAULT_PLATE_APPEARANCES))
	var game_index: int = 0
	var team_ids: Array = _opponent_team_ids(subject.team_id, bool(options.get("exclude_subject_team", true)))
	var advanced_stats: Dictionary = AdvancedStatReducer.empty_advanced_stats()
	while subject.batter_stats.plate_appearances < target_pa:
		var opponent_team_id: int = _random_team_id(team_ids)
		var defense: Dictionary = _build_team_setup(opponent_team_id, game_index, bool(options.get("dh", true)))
		if not bool(defense.get("ok", false)):
			break
		var pitcher: PSPlayerSeasonRecord = defense.get("pitcher", null) as PSPlayerSeasonRecord
		if pitcher == null:
			break
		subject.batter_stats.games += 1
		var bases: Array = [null, null, null]
		var inning_outs: int = 0
		var game_outs: int = 0
		while game_outs < GAME_OUTS and subject.batter_stats.plate_appearances < target_pa:
			var event_index: int = int(subject.batter_stats.plate_appearances)
			var bases_before: Array = bases.duplicate()
			var outs_before: int = inning_outs
			var outcome: Dictionary = _resolve_plate_outcome(subject, pitcher, defense, bases, inning_outs, false)
			var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
			if pitch_summary.is_empty():
				pitch_summary = PlayEventBuilder.pitch_summary_for_play(
					event_index,
					subject,
					pitcher,
					outcome
				)
			var applied: Dictionary = _apply_plate_outcome(subject, pitcher, bases, inning_outs, outcome, true, false, pitch_summary)
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			_apply_probe_advanced_event(
				advanced_stats,
				event_index,
				subject,
				pitcher,
				_probe_offense(subject),
				defense,
				bases_before,
				outs_before,
				outcome,
				bases,
				inning_outs,
				int(applied.get("runs", 0)),
				pitch_summary
			)
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
		game_index += 1
	var meta: Dictionary = {
		"games_simulated": game_index,
	}
	meta.merge(_advanced_summary_for_subject(advanced_stats, subject, false), true)
	return meta


func _simulate_pitcher(subject: PSPlayerSeasonRecord, options: Dictionary) -> Dictionary:
	var target_outs: int = int(options.get("target_outs", DEFAULT_TARGET_OUTS))
	var game_index: int = 0
	var team_ids: Array = _opponent_team_ids(subject.team_id, bool(options.get("exclude_subject_team", true)))
	var defense_team_id: int = int(options.get("defense_team_id", subject.team_id))
	var advanced_stats: Dictionary = AdvancedStatReducer.empty_advanced_stats()
	while subject.pitcher_stats.outs_pitched < target_outs:
		var opponent_team_id: int = _random_team_id(team_ids)
		var offense: Dictionary = _build_team_setup(opponent_team_id, game_index, bool(options.get("dh", true)))
		if not bool(offense.get("ok", false)):
			break
		var defense: Dictionary = _build_subject_defense(subject, defense_team_id)
		subject.pitcher_stats.games += 1
		subject.pitcher_stats.starts += 1
		var lineup: Array = offense.get("batters", []) as Array
		var batting_index: int = 0
		var bases: Array = [null, null, null]
		var inning_outs: int = 0
		var game_outs: int = 0
		while game_outs < GAME_OUTS and subject.pitcher_stats.outs_pitched < target_outs and not lineup.is_empty():
			var batter: PSPlayerSeasonRecord = lineup[batting_index % lineup.size()] as PSPlayerSeasonRecord
			batting_index += 1
			var event_index: int = int(subject.pitcher_stats.batters_faced)
			var bases_before: Array = bases.duplicate()
			var outs_before: int = inning_outs
			var outcome: Dictionary = _resolve_plate_outcome(batter, subject, defense, bases, inning_outs, bool(options.get("reliever", false)))
			var pitch_summary: Dictionary = outcome.get("pitch_summary", {}) as Dictionary
			if pitch_summary.is_empty():
				pitch_summary = PlayEventBuilder.pitch_summary_for_play(
					event_index,
					batter,
					subject,
					outcome
				)
			var applied: Dictionary = _apply_plate_outcome(batter, subject, bases, inning_outs, outcome, false, true, pitch_summary)
			var outs_added: int = int(applied.get("outs", 0))
			inning_outs += outs_added
			game_outs += outs_added
			_apply_probe_advanced_event(
				advanced_stats,
				event_index,
				batter,
				subject,
				offense,
				defense,
				bases_before,
				outs_before,
				outcome,
				bases,
				inning_outs,
				int(applied.get("runs", 0)),
				pitch_summary
			)
			if inning_outs >= 3:
				inning_outs = 0
				bases = [null, null, null]
		if game_outs >= GAME_OUTS:
			subject.pitcher_stats.complete_games += 1
			if int(subject.pitcher_stats.runs_allowed) == 0:
				subject.pitcher_stats.shutouts += 1
		game_index += 1
	var meta: Dictionary = {
		"games_simulated": game_index,
	}
	meta.merge(_advanced_summary_for_subject(advanced_stats, subject, true), true)
	return meta


func _resolve_plate_outcome(batter: PSPlayerSeasonRecord, pitcher: PSPlayerSeasonRecord, defense: Dictionary, bases: Array, outs: int, is_reliever: bool) -> Dictionary:
	return PSPlateAppearanceCoordinator.resolve(batter, pitcher, defense, bases, outs, is_reliever)


func _apply_plate_outcome(
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	bases: Array,
	outs: int,
	outcome: Dictionary,
	track_batter: bool,
	track_pitcher: bool,
	pitch_summary: Dictionary = {}
) -> Dictionary:
	return PlateEventReducer.apply_plate_outcome(batter, pitcher, bases, outs, outcome, {
		PlateEventReducer.OPTION_TRACK_BATTER: track_batter,
		PlateEventReducer.OPTION_TRACK_PITCHER: track_pitcher,
		PlateEventReducer.OPTION_CHARGE_PITCHER_RUNS: track_pitcher,
		PlateEventReducer.OPTION_PITCH_SUMMARY: pitch_summary,
	})


func _apply_probe_advanced_event(
	advanced_stats: Dictionary,
	event_index: int,
	batter: PSPlayerSeasonRecord,
	pitcher: PSPlayerSeasonRecord,
	offense: Dictionary,
	defense: Dictionary,
	bases_before: Array,
	outs_before: int,
	outcome: Dictionary,
	bases_after: Array,
	outs_after: int,
	runs_scored: int,
	pitch_summary: Dictionary
) -> void:
	var play_event: Dictionary = PlayEventBuilder.build_play_event(
		event_index,
		0,
		"probe",
		offense,
		defense,
		batter,
		pitcher,
		bases_before,
		outs_before,
		outcome,
		bases_after,
		outs_after,
		runs_scored,
		[],
		pitch_summary
	)
	AdvancedStatReducer.apply_play_event(advanced_stats, play_event)


func _probe_offense(subject: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"team_id": 0 if subject == null else subject.team_id,
	}


func _advanced_summary_for_subject(advanced_stats: Dictionary, subject: PSPlayerSeasonRecord, pitcher_view: bool) -> Dictionary:
	var bucket_name: String = AdvancedStatReducer.BUCKET_PITCHERS if pitcher_view else AdvancedStatReducer.BUCKET_PLAYERS
	var bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
	var record: Dictionary = bucket.get(str(subject.player_id), {}) as Dictionary
	var fielding_bucket: Dictionary = advanced_stats.get(AdvancedStatReducer.BUCKET_PLAYERS, {}) as Dictionary
	var fielding_record: Dictionary = fielding_bucket.get(str(subject.player_id), {}) as Dictionary
	var fielding_source: Dictionary = fielding_record if not fielding_record.is_empty() else record
	var summary: Dictionary = {
		"advanced_plate_appearances": int(record.get("plate_appearances", 0)),
		"woba": float(record.get("woba", 0.0)),
		"wrc_plus": float(record.get("wrc_plus", 0.0)),
		"re24": float(record.get("re24", 0.0)),
		"bsr": float(record.get("bsr", 0.0)),
		"xwoba": float(record.get("xwoba", 0.0)),
		"fielding_chances": int(fielding_source.get("fielding_chances", 0)),
		"fielding_outs": int(fielding_source.get("fielding_outs", 0)),
		"fielding_chances_by_position": fielding_source.get("fielding_chances_by_position", {}),
		"fielding_chances_by_oaa_zone": fielding_source.get("fielding_chances_by_oaa_zone", {}),
		"fielding_outs_by_position": fielding_source.get("fielding_outs_by_position", {}),
		"fielding_outs_by_oaa_zone": fielding_source.get("fielding_outs_by_oaa_zone", {}),
		"defensive_outs_by_position": fielding_source.get("defensive_outs_by_position", {}),
		"defensive_outs_by_oaa_zone": fielding_source.get("defensive_outs_by_oaa_zone", {}),
		"primary_uzr_position": int(fielding_source.get("primary_uzr_position", 0)),
		"primary_oaa_zone": str(fielding_source.get("primary_oaa_zone", "")),
		"oaa_by_zone": fielding_source.get("oaa_by_zone", {}),
		"oaa": float(fielding_source.get("oaa", 0.0)),
		"oaa_infield": float(fielding_source.get("oaa_infield", 0.0)),
		"oaa_outfield": float(fielding_source.get("oaa_outfield", 0.0)),
		"rngr_by_position": fielding_source.get("rngr_by_position", {}),
		"errr_by_position": fielding_source.get("errr_by_position", {}),
		"dpr_by_position": fielding_source.get("dpr_by_position", {}),
		"uzr_by_position": fielding_source.get("uzr_by_position", {}),
		"drs_by_position": fielding_source.get("drs_by_position", {}),
		"rngr": float(fielding_source.get("rngr", 0.0)),
		"errr": float(fielding_source.get("errr", 0.0)),
		"dpr": float(fielding_source.get("dpr", 0.0)),
		"uzr": float(fielding_source.get("uzr", 0.0)),
		"drs": float(fielding_source.get("drs", 0.0)),
		"fielding_runs": float(fielding_source.get("fielding_runs", 0.0)),
		"positional_adjustment_runs": float(fielding_source.get("positional_adjustment_runs", 0.0)),
		"def_runs": float(fielding_source.get("def_runs", 0.0)),
	}
	if pitcher_view:
		summary["woba_allowed"] = summary["woba"]
		summary["wrc_plus_allowed"] = summary["wrc_plus"]
		summary["re24_allowed"] = summary["re24"]
		summary["xwoba_allowed"] = summary["xwoba"]
	return summary


func _build_team_setup(team_id: int, game_index: int, dh_enabled: bool) -> Dictionary:
	var blueprint: Dictionary = _team_blueprint(team_id, dh_enabled)
	if not bool(blueprint.get("ok", false)):
		return blueprint
	var rotation: Array = blueprint["rotation"] as Array
	var rotation_size: int = int(blueprint["rotation_size"])
	var pitcher: PSPlayerSeasonRecord = rotation[game_index % rotation_size] as PSPlayerSeasonRecord
	var fielding_slots: Array = blueprint["fielding_slots"] as Array
	var batting_order: Array
	var cached_order: Variant = blueprint.get("batting_order", null)
	if cached_order != null:
		batting_order = cached_order as Array
	else:
		batting_order = (blueprint["fielders_records"] as Array).duplicate()
		batting_order.append(pitcher)
		PSTeamSetupBuilder.sort_batting_order(batting_order)
	return {
		"ok": true,
		"team_id": team_id,
		"pitcher": pitcher,
		"batters": batting_order,
		"fielders": fielding_slots,
		"batting_index": 0,
	}


func _team_blueprint(team_id: int, dh_enabled: bool) -> Dictionary:
	var cache_key: String = "%d_%s" % [team_id, "dh" if dh_enabled else "nodh"]
	var cached: Variant = _team_blueprint_cache.get(cache_key, null)
	if cached != null:
		return cached as Dictionary
	var blueprint: Dictionary = _compute_team_blueprint(team_id, dh_enabled)
	if bool(blueprint.get("ok", false)):
		_team_blueprint_cache[cache_key] = blueprint
	return blueprint


func _compute_team_blueprint(team_id: int, dh_enabled: bool) -> Dictionary:
	var records: Array = _fresh_team_records(team_id)
	var pitchers: Array = []
	var fielders: Array = []
	for record_value in records:
		var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitchers.append(record)
		else:
			fielders.append(record)

	var rotation: Array = PSTeamSetupBuilder.starter_pitcher_candidates(pitchers)
	if rotation.is_empty():
		rotation = pitchers.duplicate()
	rotation.sort_custom(func(a, b) -> bool:
		return PSScoringHelpers.pitcher_order_score(a as PSPlayerSeasonRecord) > PSScoringHelpers.pitcher_order_score(b as PSPlayerSeasonRecord)
	)
	var fielding_slots: Array = PSTeamSetupBuilder.select_defensive_starters(null, team_id, fielders)
	if rotation.is_empty() or fielding_slots.is_empty():
		return {"ok": false, "message": "team setup failed"}
	var fielders_records: Array = PSTeamSetupBuilder.records_from_fielding_slots(fielding_slots)
	var rotation_size: int = int(min(6, rotation.size()))
	# DH 有効時の打順は試合間で変わらないので事前にソート済みのものをキャッシュする。
	# DH 無効時は投手が試合ごとに変わるため _build_team_setup で都度組む。
	var batting_order: Variant = null
	if dh_enabled:
		var dh: PSPlayerSeasonRecord = PSTeamSetupBuilder.select_designated_hitter(fielders, fielding_slots)
		var order: Array = fielders_records.duplicate()
		if dh != null:
			order.append(dh)
		PSTeamSetupBuilder.sort_batting_order(order)
		batting_order = order
	return {
		"ok": true,
		"rotation": rotation,
		"rotation_size": rotation_size,
		"fielding_slots": fielding_slots,
		"fielders_records": fielders_records,
		"batting_order": batting_order,
	}


func _build_subject_defense(subject: PSPlayerSeasonRecord, defense_team_id: int) -> Dictionary:
	var fielding_slots: Array = []
	if defense_team_id > 0:
		var records: Array = _fresh_team_records(defense_team_id)
		var fielders: Array = []
		for record_value in records:
			var record: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			if not record.is_pitcher() and record.player_id != subject.player_id:
				fielders.append(record)
		fielding_slots = PSTeamSetupBuilder.select_defensive_starters(null, defense_team_id, fielders)
	if fielding_slots.is_empty():
		fielding_slots = _neutral_fielding_slots()
	return {
		"ok": true,
		"team_id": defense_team_id,
		"pitcher": subject,
		"batters": [],
		"fielders": fielding_slots,
	}


func _fresh_team_records(team_id: int) -> Array:
	var records: Array = []
	var players: Array = GameDb.get_players_for_team(team_id)
	for player_value in players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.is_retired():
			continue
		records.append(PSPlayerSeasonRecord.from_player(player, DEFAULT_YEAR, DEFAULT_SEASON_NUMBER))
	return records


func _neutral_fielding_slots() -> Array:
	var slots: Array = []
	for position in GameSimulator.DEFENSIVE_ASSIGNMENT_ORDER:
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
		record.player_id = -1000 - int(position)
		record.name = "Neutral %d" % int(position)
		record.position = int(position)
		record.role = "fielder"
		record.position_aptitudes_snapshot = _default_position_aptitudes(record.position)
		record.position_experience_snapshot = PSPlayer.default_position_experience(record.position, record.position_aptitudes_snapshot)
		# z_abilities_snapshot は空のままで OK（z=0.0=リーグ平均で読まれる）
		slots.append({
			"record": record,
			"position": int(position),
		})
	return slots


func _opponent_team_ids(subject_team_id: int, exclude_subject_team: bool) -> Array:
	var ids: Array = []
	for team_value in GameDb.teams:
		var team: PSTeam = team_value as PSTeam
		if team == null:
			continue
		if exclude_subject_team and GameDb.teams.size() > 1 and team.id == subject_team_id:
			continue
		ids.append(team.id)
	return ids


func _random_team_id(team_ids: Array) -> int:
	if team_ids.is_empty():
		return 0
	return int(team_ids[Rng.range_int(0, team_ids.size() - 1)])


func _select_subject_player(options: Dictionary) -> PSPlayer:
	var player_id: int = int(options.get("player_id", 0))
	if player_id > 0:
		return GameDb.get_player(player_id)
	var player_name: String = str(options.get("player_name", ""))
	if not player_name.is_empty():
		for player_value in GameDb.players:
			var named_player: PSPlayer = player_value as PSPlayer
			if named_player != null and named_player.name == player_name:
				return named_player
		for player_value in GameDb.players:
			var contains_player: PSPlayer = player_value as PSPlayer
			if contains_player != null and contains_player.name.contains(player_name):
				return contains_player
	var mode: String = str(options.get("mode", "batter"))
	for player_value in GameDb.players:
		var player: PSPlayer = player_value as PSPlayer
		if player == null or player.is_retired():
			continue
		if mode == "pitcher" and player.is_pitcher():
			return player
		if mode != "pitcher" and not player.is_pitcher():
			return player
	return null


func _custom_subject_record(options: Dictionary) -> PSPlayerSeasonRecord:
	var mode: String = str(options.get("mode", "batter"))
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = int(options.get("custom_player_id", -900001 if mode == "batter" else -900002))
	record.sensyu_num = 0
	record.jersey_number = 0
	record.development_player = false
	record.year = DEFAULT_YEAR
	record.season_number = DEFAULT_SEASON_NUMBER
	record.team_id = int(options.get("subject_team_id", 0))
	record.name = str(options.get("subject_name", "検証用野手" if mode == "batter" else "検証用投手"))
	record.age = int(options.get("age", 27))
	record.years = int(options.get("years", 5))
	record.height = int(options.get("height", 180))
	record.weight = int(options.get("weight", 84))
	record.position = int(options.get("position", 3 if mode == "batter" else 1))
	record.role = str(options.get("role", "fielder" if mode == "batter" else "starter"))
	record.throwing_hand = str(options.get("throws", "R"))
	record.batting_side = str(options.get("bats", "R"))
	record.salary = 0
	record.draft_round = 0
	record.hometown = ""
	record.registered_roster = "検証"
	record.contract_status = "検証"
	record.foreign_player = false
	record.fatigue = 0
	record.injury_days = 0
	record.position_aptitudes_snapshot = _default_position_aptitudes(record.position)
	record.position_experience_snapshot = PSPlayer.default_position_experience(record.position, record.position_aptitudes_snapshot)
	record.source_data = {
		"generated_by": "player_probe",
	}
	# z_abilities_snapshot / raw_abilities_snapshot に直接書き込む。
	record.z_abilities_snapshot = _default_z_abilities()
	record.raw_abilities_snapshot = _default_raw_abilities(mode)
	var custom_keys: Array = ["custom_z_abilities", "custom_raw_abilities"]
	for custom_key in custom_keys:
		var overrides: Dictionary = options.get(custom_key, {}) as Dictionary
		for ability_key in overrides.keys():
			_set_ability(record, str(ability_key), float(overrides.get(ability_key)))
	return record


func _default_z_abilities() -> Dictionary:
	# display 値ベースのデフォルト (60-70) を z へ変換。
	# 60 → z=+0.8, 70 → z=+1.6, 50 → z=0.0
	var z60: float = PSAbilityScale.display_to_z(60)
	var z50: float = 0.0
	var z70: float = PSAbilityScale.display_to_z(70)
	return {
		# Batting (旧 contact/gap_power/home_run_power/eye/avoid_k=60, bunt=40 相当)
		"Bat_Barrel": z60,
		"Bat_Impact": z60,
		"Bat_Loft": z60,
		"Bat_BBCreate": z60,
		"Bat_KAvoid": z60,
		"Bat_Spray": z50,
		"Bat_Aggression": z50,
		"Bat_Platoon": z50,
		# Pitching (旧 stuff/movement/control=60, stamina=70, hold_runners/recovery=60)
		"Pit_KCreate": z60,
		"Pit_BBPrevent": z60,
		"Pit_ImpactLimit": z60,
		"Pit_LoftControl": z60,
		"Pit_BarrelDeny": z60,
		"Pit_Efficiency": z60,
		"Pit_Stamina": z70,
		"Pit_FatigueResist": z60,
		"Pit_HoldRunner": z60,
		"Pit_EdgeRate": z50,
		# Running (旧 speed=60, stealing=50)
		"Run_Speed": z60,
		"Run_Judgment": z50,
		"Run_Steal": z50,
		# 守備 (デフォルト)
		"C_Framing": z60, "C_Blocking": z60, "C_Throw": z60, "C_GameCall": z60, "C_FieldSecure": z60,
		"IF_Reach": z60, "IF_Secure": z60, "IF_ThrowPower": z60, "IF_ThrowAccuracy": z60, "IF_Exchange": z60, "IF_PositionFit": z50,
		"OF_Reach": z60, "OF_Route": z60, "OF_Secure": z60, "OF_ArmPower": z60, "OF_ArmAccuracy": z60, "OF_Release": z60, "OF_PositionFit": z50,
	}


func _default_raw_abilities(mode: String) -> Dictionary:
	if mode == "pitcher":
		return {"max_velocity": 146.0}
	return {}


func _default_position_aptitudes(position: int) -> Dictionary:
	var keys: Dictionary = GameSimulator.POSITION_APTITUDE_KEYS
	var aptitudes: Dictionary = {}
	for key_value in keys.values():
		aptitudes[str(key_value)] = 0
	var selected_key: String = str(keys.get(position, "first"))
	if not selected_key.is_empty():
		aptitudes[selected_key] = 100
	return aptitudes


func _normalized_options(options: Dictionary) -> Dictionary:
	var normalized: Dictionary = options.duplicate(true)
	var mode: String = str(normalized.get("mode", "batter")).to_lower()
	if mode == "pitching":
		mode = "pitcher"
	if mode == "hitter" or mode == "batting":
		mode = "batter"
	normalized["mode"] = mode
	normalized["plate_appearances"] = int(max(1, int(normalized.get("plate_appearances", DEFAULT_PLATE_APPEARANCES))))
	var target_outs: int = int(normalized.get("target_outs", 0))
	if target_outs <= 0:
		target_outs = int(round(float(normalized.get("innings", float(DEFAULT_TARGET_OUTS) / 3.0)) * 3.0))
	normalized["target_outs"] = int(max(1, target_outs))
	normalized["iterations"] = int(max(1, int(normalized.get("iterations", 1))))
	if not normalized.has("exclude_subject_team"):
		normalized["exclude_subject_team"] = true
	if not normalized.has("dh"):
		normalized["dh"] = true
	if not normalized.has("seed"):
		normalized["seed"] = 12345
	return normalized


func _sweep_values(options: Dictionary) -> Array:
	var ability: String = str(options.get("sweep_ability", ""))
	if ability.is_empty():
		return []
	var explicit_values: Array = options.get("sweep_values", []) as Array
	if not explicit_values.is_empty():
		var parsed_values: Array = []
		for value in explicit_values:
			parsed_values.append(_round_float(float(value), 3))
		return parsed_values
	var start_value: float = float(options.get("sweep_start", -1.0))
	var end_value: float = float(options.get("sweep_end", 3.0))
	var step: float = max(0.01, abs(float(options.get("sweep_step", 0.5))))
	var values: Array = []
	if start_value <= end_value:
		var ascending_value: float = start_value
		while ascending_value <= end_value + 0.0001:
			values.append(_round_float(ascending_value, 3))
			ascending_value += step
	else:
		var descending_value: float = start_value
		while descending_value >= end_value - 0.0001:
			values.append(_round_float(descending_value, 3))
			descending_value -= step
	return values


func _apply_set_overrides(record: PSPlayerSeasonRecord, overrides: Dictionary) -> void:
	for key_value in overrides.keys():
		_set_ability(record, str(key_value), float(overrides.get(key_value)))


func _set_ability(record: PSPlayerSeasonRecord, key: String, value: float) -> void:
	# z キーは計算用の z 値を直接受け取る。max_velocity のみ raw に格納。
	# z 等価の無いキーは無視する。
	if _is_z_ability_key(key):
		record.z_abilities_snapshot[key] = value
		return
	if key == "max_velocity":
		record.raw_abilities_snapshot["max_velocity"] = clamp(float(value), 128.0, 165.0)


func _is_z_ability_key(key: String) -> bool:
	return PSPlayer.Z_BATTER_ABILITY_KEYS.has(key) \
		or PSPlayer.Z_PITCHER_ABILITY_KEYS.has(key) \
		or PSPlayer.Z_RUNNING_ABILITY_KEYS.has(key) \
		or PSPlayer.Z_CATCHER_ABILITY_KEYS.has(key) \
		or PSPlayer.Z_INFIELD_ABILITY_KEYS.has(key) \
		or PSPlayer.Z_OUTFIELD_ABILITY_KEYS.has(key)


func _clone_record(record: PSPlayerSeasonRecord) -> PSPlayerSeasonRecord:
	return PSPlayerSeasonRecord.from_dict(record.to_dict())


func _reset_record_stats(record: PSPlayerSeasonRecord) -> void:
	record.batter_stats = PSBatterStats.new()
	record.pitcher_stats = PSPitcherStats.new()
	record.fatigue = 0
	record.injury_days = 0


func _run_seed(base_seed: int, value_index: int, iteration: int) -> int:
	if base_seed < 0:
		return -1
	return base_seed + value_index * 1009 + iteration * 9176


func _batter_summary(stats: PSBatterStats) -> Dictionary:
	return {
		"games": stats.games,
		"plate_appearances": stats.plate_appearances,
		"at_bats": stats.at_bats,
		"hits": stats.hits,
		"doubles": stats.doubles,
		"triples": stats.triples,
		"home_runs": stats.home_runs,
		"runs_batted_in": stats.runs_batted_in,
		"runs": stats.runs,
		"walks": stats.walks,
		"hit_by_pitches": stats.hit_by_pitches,
		"strikeouts": stats.strikeouts,
		"pitches_seen": stats.pitches_seen,
		"sacrifices": stats.sacrifices,
		"sacrifice_flies": stats.sacrifice_flies,
		"double_plays": stats.double_plays,
		"batting_average": _round_float(stats.batting_average(), 3),
		"on_base_percentage": _round_float(stats.on_base_percentage(), 3),
		"slugging_percentage": _round_float(stats.slugging_percentage(), 3),
		"ops": _round_float(stats.ops(), 3),
		"home_run_rate": _round_float(_safe_div(stats.home_runs, stats.plate_appearances), 3),
		"walk_rate": _round_float(_safe_div(stats.walks, stats.plate_appearances), 3),
		"strikeout_rate": _round_float(_safe_div(stats.strikeouts, stats.plate_appearances), 3),
		"pitches_per_plate_appearance": _round_float(_safe_div(stats.pitches_seen, stats.plate_appearances), 2),
	}


func _pitcher_summary(stats: PSPitcherStats) -> Dictionary:
	return {
		"games": stats.games,
		"starts": stats.starts,
		"outs_pitched": stats.outs_pitched,
		"innings_pitched": _round_float(stats.innings_pitched(), 1),
		"batters_faced": stats.batters_faced,
		"pitches_thrown": stats.pitches_thrown,
		"hits_allowed": stats.hits_allowed,
		"home_runs_allowed": stats.home_runs_allowed,
		"walks": stats.walks,
		"hit_batters": stats.hit_batters,
		"strikeouts": stats.strikeouts,
		"runs_allowed": stats.runs_allowed,
		"earned_runs": stats.earned_runs,
		"complete_games": stats.complete_games,
		"shutouts": stats.shutouts,
		"era": _round_float(stats.era(), 2),
		"whip": _round_float(stats.whip(), 3),
		"strikeouts_per_nine": _round_float(stats.strikeouts_per_nine(), 2),
		"walks_per_nine": _round_float(_per_nine(stats.walks, stats.outs_pitched), 2),
		"home_runs_per_nine": _round_float(_per_nine(stats.home_runs_allowed, stats.outs_pitched), 2),
		"strikeout_rate": _round_float(_safe_div(stats.strikeouts, stats.batters_faced), 3),
		"walk_rate": _round_float(_safe_div(stats.walks, stats.batters_faced), 3),
		"pitches_per_batter_faced": _round_float(_safe_div(stats.pitches_thrown, stats.batters_faced), 2),
		"pitches_per_inning": _round_float(_per_nine(stats.pitches_thrown, stats.outs_pitched) / 9.0, 1),
	}


func _average_summaries(runs: Array) -> Dictionary:
	var totals: Dictionary = {}
	var counts: Dictionary = {}
	for run_value in runs:
		var run_dict: Dictionary = run_value as Dictionary
		for key_value in run_dict.keys():
			var key: String = str(key_value)
			var value: Variant = run_dict.get(key_value)
			if value is int or value is float:
				totals[key] = float(totals.get(key, 0.0)) + float(value)
				counts[key] = int(counts.get(key, 0)) + 1
	var averaged: Dictionary = {}
	for key_value in totals.keys():
		var key: String = str(key_value)
		averaged[key] = _round_float(float(totals.get(key, 0.0)) / float(max(1, int(counts.get(key, 1)))), 3)
	return averaged


func _metric_value(summary: Dictionary, metric: String) -> float:
	if summary.has(metric):
		return float(summary.get(metric, 0.0))
	return 0.0


func _player_row(player: PSPlayer) -> Dictionary:
	return {
		"id": player.id,
		"name": player.name,
		"team_id": player.team_id,
		"position": player.position,
		"role": player.role,
	}


func _record_subject_row(record: PSPlayerSeasonRecord, source_player: PSPlayer = null) -> Dictionary:
	if source_player != null:
		return _player_row(source_player)
	return {
		"id": record.player_id,
		"name": record.name,
		"team_id": record.team_id,
		"position": record.position,
		"role": record.role,
		"custom": true,
	}


func _record_ability_row(record: PSPlayerSeasonRecord) -> Dictionary:
	# 計算用能力は display 値へ戻さず z 値のまま出力する。
	var z: Dictionary = record.z_abilities_snapshot
	var display: Dictionary = _display_ability_row(record)
	var raw: Dictionary = {}
	for key_value in record.raw_abilities_snapshot.keys():
		var key: String = str(key_value)
		raw[key] = _round_float(float(record.raw_abilities_snapshot.get(key, 0.0)), 3)
	var batting: Dictionary = {}
	for key in PSPlayer.Z_BATTER_ABILITY_KEYS.keys():
		if z.has(key):
			batting[str(key)] = _round_float(float(z[key]), 3)
	var pitching: Dictionary = {}
	for key in PSPlayer.Z_PITCHER_ABILITY_KEYS.keys():
		if z.has(key):
			pitching[str(key)] = _round_float(float(z[key]), 3)
	var fielding: Dictionary = {}
	for group_value in [PSPlayer.Z_CATCHER_ABILITY_KEYS, PSPlayer.Z_INFIELD_ABILITY_KEYS, PSPlayer.Z_OUTFIELD_ABILITY_KEYS]:
		var group: Dictionary = group_value as Dictionary
		for key in group.keys():
			if z.has(key):
				fielding[str(key)] = _round_float(float(z[key]), 3)
	var running: Dictionary = {}
	for key in PSPlayer.Z_RUNNING_ABILITY_KEYS.keys():
		if z.has(key):
			running[str(key)] = _round_float(float(z[key]), 3)
	return {
		"batting": batting,
		"pitching": pitching,
		"fielding": fielding,
		"raw": raw,
		"display": display,
		"visible": display,
		"position_experience": record.position_experience_snapshot.duplicate(true),
		"running": running,
	}


func _display_ability_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var result: Dictionary = PlayerVisibleRatings.ratings_for_record(record)
	var row: Dictionary = {"summary": PlayerVisibleRatings.summary_line_from_result(result)}
	var ratings: Array = result.get("display_ratings", result.get("ratings", [])) as Array
	for item_value in ratings:
		var item: Dictionary = item_value as Dictionary
		row[str(item.get("key", ""))] = int(item.get("display_value", item.get("value", 0)))
	return row


func _safe_div(numerator: int, denominator: int) -> float:
	if denominator == 0:
		return 0.0
	return float(numerator) / float(denominator)


func _per_nine(count: int, outs: int) -> float:
	if outs == 0:
		return 0.0
	return float(count) * 27.0 / float(outs)


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale


func _num(value: Variant) -> String:
	if value is int:
		return str(int(value))
	if value is float:
		return str(float(value))
	return str(value)


func _csv_cell(value: String) -> String:
	if value.contains(",") or value.contains("\"") or value.contains("\n"):
		return "\"%s\"" % value.replace("\"", "\"\"")
	return value


func _xml_escape(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
