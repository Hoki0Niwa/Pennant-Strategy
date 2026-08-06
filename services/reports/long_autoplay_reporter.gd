extends RefCounted
class_name PSLongAutoplayReporter

const SimulationReporterScript = preload("res://services/reports/simulation_reporter.gd")
const CampServiceRef = preload("res://services/season/camp_service.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const ReportHealth = preload("res://services/reports/report_health.gd")
const SaveContext = preload("res://services/storage/save_context.gd")
const ReleaseValueProjector = preload("res://services/season/release_value_projector.gd")

const VERSION: int = 2
const DEFAULT_SEASONS: int = 40
const DEFAULT_SELECTED_TEAM_ID: int = 1
const DEFAULT_START_YEAR: int = 2026
const DEFAULT_SEED: int = 20260528
const LEADERBOARD_LIMIT: int = 5
const QUALIFIER_PA_PER_GAME: float = 3.1
const QUALIFIER_OUTS_PER_GAME: float = 3.0
const COUNTING_TITLE_MIN_PA: int = 50
const PITCHER_EXCLUDE_PA: int = 30

const BATTER_ABILITY_KEYS: Array = [
	"Bat_KAvoid",
	"Bat_BBCreate",
	"Bat_Impact",
	"Bat_Loft",
	"Bat_Barrel",
	"Bat_Spray",
	"Bat_Aggression",
	"Run_Speed",
]
const PITCHER_ABILITY_KEYS: Array = [
	"Pit_KCreate",
	"Pit_BBPrevent",
	"Pit_ImpactLimit",
	"Pit_LoftControl",
	"Pit_BarrelDeny",
	"Pit_Efficiency",
	"Pit_Stamina",
	"Pit_FatigueResist",
]


func _dh_settings_from_options(options: Dictionary) -> Dictionary:
	var settings_value: Variant = options.get("dh_by_league", options.get("league_dh_enabled", {}))
	var settings: Dictionary = settings_value as Dictionary if settings_value is Dictionary else {}
	return {
		"league1": bool(settings.get("league1", true)),
		"league2": bool(settings.get("league2", true)),
	}


func run(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var season_count: int = max(1, int(options.get("seasons", DEFAULT_SEASONS)))
	var selected_team_id: int = int(options.get("selected_team_id", DEFAULT_SELECTED_TEAM_ID))
	if selected_team_id <= 0 and not GameDb.teams.is_empty():
		var first_team: PSTeam = GameDb.teams[0] as PSTeam
		selected_team_id = first_team.id
	var start_year: int = int(options.get("start_year", DEFAULT_START_YEAR))
	var seed_value: int = int(options.get("seed", DEFAULT_SEED))
	var dh_by_league: Dictionary = _dh_settings_from_options(options)
	# keep_world=true のとき、進化後の GameDb（最終年ロスター）を復元せずに残す。
	# シード生成ツール (run_export_seed_world) が最終状態を CSV へ書き出すために使う。
	var keep_world: bool = bool(options.get("keep_world", false))

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_player_rows: Array = _snapshot_players()
	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	var seed_cohort_ids: Dictionary = _active_player_id_set(GameDb.players)

	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var simulation_reporter: Object = SimulationReporterScript.new()
	var yearly_rows: Array = []
	var errors: Array = []
	var completed_seasons: int = 0
	var draft_95_year: int = 0
	var draft_only_year: int = 0
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, selected_team_id, start_year, dh_by_league)

	for season_index in range(season_count):
		_prepare_report_season(season)
		RecordStore.clear_records()
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

		var roster_before: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)
		# 実プレイ経路 (AppState) と同じ週次入替/トレードのフックを有効にする
		# (ctx 無しだと一二軍入替AI・シーズン中トレードが一切走らず、実挙動から乖離する)。
		var simulation_result: Dictionary = GameSimulator.simulate_remaining_season(season, false, _auto_swap_ctx(selected_team_id))
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": season.year,
				"season_index": season_index + 1,
				"message": str(simulation_result.get("message", "")),
			})
			break

		# 季末 (オフ処理前) のロースター。開幕時との差が支配下登録期限 (7/31) の育成昇格の効果で、
		# これがそのまま翌オフの戦力外計画の入力 (在籍数) になる。
		var roster_end_of_season: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)

		var season_report: Dictionary = simulation_reporter.call("_season_report", season) as Dictionary
		var season_summary: Dictionary = simulation_reporter.call("_public_season_summary", season_report) as Dictionary
		var leaderboards: Dictionary = _leaderboards_for_season(season)
		var trades_summary: Dictionary = _trade_summary(season)
		var offseason_result: Dictionary = _run_auto_offseason(season, selected_team_id)
		GameDb.advance_players_one_year()
		GameDb.rebuild_player_indices()
		var roster_after: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)

		completed_seasons += 1
		var draft_ratio: float = float(roster_before.get("draft_generated_ratio", 0.0))
		if draft_95_year <= 0 and draft_ratio >= 0.95:
			draft_95_year = season.year
		if draft_only_year <= 0 and int(roster_before.get("active_players", 0)) > 0 and int(roster_before.get("non_draft_active_players", 0)) == 0:
			draft_only_year = season.year

		yearly_rows.append({
			"season_index": season_index + 1,
			"year": season.year,
			"season_number": season.season_number,
			"roster_before_season": roster_before,
			"roster_end_of_season": roster_end_of_season,
			"season": season_summary,
			"leaderboards": leaderboards,
			"trades": trades_summary,
			"offseason": offseason_result,
			"roster_after_offseason_next_year": roster_after,
			"simulated_games": int(simulation_result.get("simulated_count", 0)),
		})

		if season_index < season_count - 1:
			season = SeasonService.create_next_season(season, GameDb.teams, dh_by_league)

	var final_roster: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)

	if not keep_world:
		_restore_players(original_player_rows)
		RecordStore.load_from_dict(original_records)
		RecordStore.resume_persistence()
		if SaveContext.has_active_save():
			RecordStore.save_records()
		Rng.current_seed = original_rng_seed
		Rng.generator.seed = original_rng_seed
		Rng.generator.state = original_rng_state

	var report: Dictionary = {
		"ok": completed_seasons == season_count and errors.is_empty(),
		"version": VERSION,
		"method": "Evolve one persistent roster world with fully automatic releases, draft, growth/decay, and age advancement after each simulated season.",
		"seasons_requested": season_count,
		"seasons_completed": completed_seasons,
		"selected_team_id": selected_team_id,
		"start_year": start_year,
		"end_year": start_year + max(0, completed_seasons - 1),
		"seed": seed_value,
		"league_dh_enabled": dh_by_league.duplicate(true),
		"data_source": GameDb.data_source,
		"team_count": GameDb.teams.size(),
		"seed_cohort_initial_active_players": seed_cohort_ids.size(),
		"milestones": {
			"draft_generated_95_percent_year": draft_95_year,
			"draft_only_year": draft_only_year,
		},
		"window_summaries": {
			"last_5_years": _window_summary(yearly_rows, 5),
			"last_10_years": _window_summary(yearly_rows, 10),
			"draft_only_years": _draft_only_window_summary(yearly_rows, draft_only_year),
		},
		"initial_roster": (yearly_rows[0] as Dictionary).get("roster_before_season", {}) if not yearly_rows.is_empty() else {},
		"final_roster_after_last_offseason": final_roster,
		"yearly": yearly_rows,
		"errors": errors,
	}
	report["distributions"] = ReportHealth.long_distributions(report)
	report["health"] = ReportHealth.long_health(report)
	return report


func run_async(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var season_count: int = max(1, int(options.get("seasons", DEFAULT_SEASONS)))
	var selected_team_id: int = int(options.get("selected_team_id", DEFAULT_SELECTED_TEAM_ID))
	if selected_team_id <= 0 and not GameDb.teams.is_empty():
		var first_team: PSTeam = GameDb.teams[0] as PSTeam
		selected_team_id = first_team.id
	var start_year: int = int(options.get("start_year", DEFAULT_START_YEAR))
	var seed_value: int = int(options.get("seed", DEFAULT_SEED))
	var dh_by_league: Dictionary = _dh_settings_from_options(options)
	var tree: SceneTree = options.get("scene_tree") as SceneTree
	var outer_progress_cb: Callable = options.get("progress_callback", Callable())
	# keep_world=true のとき進化後の GameDb（最終年ロスター）を復元せず残す（シード生成用）。
	var keep_world: bool = bool(options.get("keep_world", false))
	var cancel_token: Dictionary = options.get("cancel_token", {})

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_player_rows: Array = _snapshot_players()
	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	var seed_cohort_ids: Dictionary = _active_player_id_set(GameDb.players)

	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var simulation_reporter: Object = SimulationReporterScript.new()
	var yearly_rows: Array = []
	var errors: Array = []
	var completed_seasons: int = 0
	var draft_95_year: int = 0
	var draft_only_year: int = 0
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, selected_team_id, start_year, dh_by_league)
	var total_progress_units: int = max(1, season_count * max(1, season.schedule.size()))
	var progress_base: int = 0

	for season_index in range(season_count):
		if _is_cancelled(cancel_token):
			break
		_prepare_report_season(season)
		RecordStore.clear_records()
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

		var roster_before: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)
		var season_total_games: int = max(1, season.schedule.size())
		var season_label: String = "season %d/%d (%d)" % [season_index + 1, season_count, season.year]
		var inner_cb: Callable = Callable()
		if outer_progress_cb.is_valid():
			inner_cb = func(done: int, total: int, _inner_label: String) -> void:
				var effective_total: int = max(1, total)
				var scaled_done: int = progress_base + int(round(float(done) / float(effective_total) * float(season_total_games)))
				outer_progress_cb.call(scaled_done, total_progress_units, season_label)
		var simulation_result: Dictionary = await GameSimulator.simulate_remaining_season_async(
			season, false, _auto_swap_ctx(selected_team_id), tree, inner_cb, cancel_token
		)
		if bool(simulation_result.get("cancelled", false)) or _is_cancelled(cancel_token):
			break
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": season.year,
				"season_index": season_index + 1,
				"message": str(simulation_result.get("message", "")),
			})
			break

		var roster_end_of_season: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)
		var season_report: Dictionary = simulation_reporter.call("_season_report", season) as Dictionary
		var season_summary: Dictionary = simulation_reporter.call("_public_season_summary", season_report) as Dictionary
		var leaderboards: Dictionary = _leaderboards_for_season(season)
		var trades_summary: Dictionary = _trade_summary(season)
		if outer_progress_cb.is_valid():
			outer_progress_cb.call(progress_base + season_total_games, total_progress_units, "offseason %d" % season.year)
		var offseason_result: Dictionary = _run_auto_offseason(season, selected_team_id)
		GameDb.advance_players_one_year()
		GameDb.rebuild_player_indices()
		var roster_after: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)

		completed_seasons += 1
		var draft_ratio: float = float(roster_before.get("draft_generated_ratio", 0.0))
		if draft_95_year <= 0 and draft_ratio >= 0.95:
			draft_95_year = season.year
		if draft_only_year <= 0 and int(roster_before.get("active_players", 0)) > 0 and int(roster_before.get("non_draft_active_players", 0)) == 0:
			draft_only_year = season.year

		yearly_rows.append({
			"season_index": season_index + 1,
			"year": season.year,
			"season_number": season.season_number,
			"roster_before_season": roster_before,
			"roster_end_of_season": roster_end_of_season,
			"season": season_summary,
			"leaderboards": leaderboards,
			"trades": trades_summary,
			"offseason": offseason_result,
			"roster_after_offseason_next_year": roster_after,
			"simulated_games": int(simulation_result.get("simulated_count", 0)),
		})

		progress_base += season_total_games
		if tree != null:
			await tree.process_frame
		if season_index < season_count - 1:
			season = SeasonService.create_next_season(season, GameDb.teams, dh_by_league)

	var final_roster: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)
	var cancelled: bool = _is_cancelled(cancel_token)

	# keep_world では復元しない。ただしキャンセル時は中途半端な世界を残さないため復元する。
	if not keep_world or cancelled:
		_restore_players(original_player_rows)
		RecordStore.load_from_dict(original_records)
		RecordStore.resume_persistence()
		if SaveContext.has_active_save():
			RecordStore.save_records()
		Rng.current_seed = original_rng_seed
		Rng.generator.seed = original_rng_seed
		Rng.generator.state = original_rng_state

	var report: Dictionary = {
		"ok": not cancelled and completed_seasons == season_count and errors.is_empty(),
		"cancelled": cancelled,
		"version": VERSION,
		"method": "Evolve one persistent roster world with fully automatic releases, draft, growth/decay, and age advancement after each simulated season.",
		"seasons_requested": season_count,
		"seasons_completed": completed_seasons,
		"selected_team_id": selected_team_id,
		"start_year": start_year,
		"end_year": start_year + max(0, completed_seasons - 1),
		"seed": seed_value,
		"league_dh_enabled": dh_by_league.duplicate(true),
		"data_source": GameDb.data_source,
		"team_count": GameDb.teams.size(),
		"seed_cohort_initial_active_players": seed_cohort_ids.size(),
		"milestones": {
			"draft_generated_95_percent_year": draft_95_year,
			"draft_only_year": draft_only_year,
		},
		"window_summaries": {
			"last_5_years": _window_summary(yearly_rows, 5),
			"last_10_years": _window_summary(yearly_rows, 10),
			"draft_only_years": _draft_only_window_summary(yearly_rows, draft_only_year),
		},
		"initial_roster": (yearly_rows[0] as Dictionary).get("roster_before_season", {}) if not yearly_rows.is_empty() else {},
		"final_roster_after_last_offseason": final_roster,
		"yearly": yearly_rows,
		"errors": errors,
	}
	report["distributions"] = ReportHealth.long_distributions(report)
	report["health"] = ReportHealth.long_health(report)
	return report


# SimulationReporter の詳細集計は schedule の full result ではなく、この逐次集計を読む。
# 新season生成のたび、試合を始める前に必ずopt-inする。
func _prepare_report_season(season: PSSeason) -> void:
	if season != null:
		season.collect_simulation_report_data = true
		season.generate_game_logs = false


# 実プレイ (AppState._build_auto_swap_ctx) と同等の日次フック設定。自軍もCPU自動管理する。
func _auto_swap_ctx(selected_team_id: int) -> Dictionary:
	return {"user_team_id": selected_team_id, "include_user_team": true}


# 当季のシーズン中トレード集計 (source 別内訳つき)。
func _trade_summary(season: PSSeason) -> Dictionary:
	var executed: Array = TradeService.executed_trades(season)
	var by_source: Dictionary = {}
	for entry_value in executed:
		var source: String = str((entry_value as Dictionary).get("source", ""))
		by_source[source] = int(by_source.get(source, 0)) + 1
	return {
		"count": executed.size(),
		"by_source": by_source,
	}


func csv_text(report: Dictionary) -> String:
	var lines: Array = []
	lines.append("season_index,year,active_players,controlled_players,development_players,foreign_players,team_controlled_max,team_development_max,team_foreign_max,free_agent_orphans,released_orphans,teamless_active_players,draft_generated_active,draft_generated_ratio,non_draft_active,seed_cohort_active,seed_cohort_ratio,in_run_added_active,age_23_under,age_24_29,age_30_34,age_35_plus,veteran_regular_30s,veteran_bench_35_plus,avg_age,avg_overall,batter_overall,pitcher_overall,overall_p10,overall_p50,overall_p90,roster_min,roster_avg,roster_max,runs_per_team_game,runs_per_game_total,avg,obp,slg,ops,hr_per_game,bb_per_game,so_per_game,era,whip,k_per_9,bb_per_9,hr_per_9,avg_bat_kavoid_z,avg_bat_bbcreate_z,avg_bat_impact_z,avg_bat_loft_z,avg_bat_barrel_z,avg_pit_kcreate_z,avg_pit_bbprevent_z,avg_pit_impactlimit_z,avg_pit_barreldeny_z,avg_pit_stamina_z,hr_leader,hr_leader_name,avg_leader,avg_leader_name,ops_leader,ops_leader_name,era_leader,era_leader_name,k_leader,k_leader_name,trades,retired,released,released_pitchers,released_fielders,released_avg_age,demoted,promoted,dev_released,fa_declared,fa_moved,geneki_moved,geneki_round2,released_signed,foreign_signed,foreign_released,draft_picks,rookies,growers,decayers,camp_actions,camp_pitch_learning,post_active_players,post_controlled_players,post_development_players,post_team_controlled_max,post_team_development_max,post_team_foreign_max,post_draft_generated_ratio,post_seed_cohort_ratio,foreign_retained,foreign_poached,foreign_multi_year_signed,contract_years_total,contract_years_multi,multi_year_active")
	for row_value in report.get("yearly", []) as Array:
		var row: Dictionary = row_value as Dictionary
		var roster: Dictionary = row.get("roster_before_season", {}) as Dictionary
		var season_summary: Dictionary = row.get("season", {}) as Dictionary
		var batting: Dictionary = season_summary.get("batting", {}) as Dictionary
		var pitching: Dictionary = season_summary.get("pitching", {}) as Dictionary
		var offseason: Dictionary = row.get("offseason", {}) as Dictionary
		var post_roster: Dictionary = row.get("roster_after_offseason_next_year", {}) as Dictionary
		var leaderboards: Dictionary = row.get("leaderboards", {}) as Dictionary
		var age_bands: Dictionary = roster.get("age_bands", {}) as Dictionary
		var csv_values: Array = [
			int(row.get("season_index", 0)),
			int(row.get("year", 0)),
			int(roster.get("active_players", 0)),
			int(roster.get("controlled_players", 0)),
			int(roster.get("development_players", 0)),
			int(roster.get("foreign_players", 0)),
			int(roster.get("team_controlled_max", 0)),
			int(roster.get("team_development_max", 0)),
			int(roster.get("team_foreign_max", 0)),
			int(roster.get("free_agent_orphans", 0)),
			int(roster.get("released_orphans", 0)),
			int(roster.get("teamless_active_players", 0)),
			int(roster.get("draft_generated_active_players", 0)),
			float(roster.get("draft_generated_ratio", 0.0)),
			int(roster.get("non_draft_active_players", 0)),
			int(roster.get("seed_cohort_active_players", 0)),
			float(roster.get("seed_cohort_ratio", 0.0)),
			int(roster.get("in_run_added_active_players", 0)),
			int(age_bands.get("age_23_under", 0)),
			int(age_bands.get("age_24_29", 0)),
			int(age_bands.get("age_30_34", 0)),
			int(age_bands.get("age_35_plus", 0)),
			int(roster.get("veteran_regular_30s", 0)),
			int(roster.get("veteran_bench_35_plus", 0)),
			float(roster.get("average_age", 0.0)),
			float(roster.get("average_overall", 0.0)),
			float(roster.get("average_batter_overall", 0.0)),
			float(roster.get("average_pitcher_overall", 0.0)),
			float(roster.get("overall_p10", 0.0)),
			float(roster.get("overall_p50", 0.0)),
			float(roster.get("overall_p90", 0.0)),
			int(roster.get("team_roster_min", 0)),
			float(roster.get("team_roster_average", 0.0)),
			int(roster.get("team_roster_max", 0)),
			float(season_summary.get("runs_per_team_game", 0.0)),
			float(season_summary.get("runs_per_game_total", 0.0)),
			float(batting.get("batting_average", 0.0)),
			float(batting.get("on_base_percentage", 0.0)),
			float(batting.get("slugging_percentage", 0.0)),
			float(batting.get("ops", 0.0)),
			float(batting.get("home_runs_per_game", 0.0)),
			float(batting.get("walks_per_game", 0.0)),
			float(batting.get("strikeouts_per_game", 0.0)),
			float(pitching.get("era", 0.0)),
			float(pitching.get("whip", 0.0)),
			float(pitching.get("strikeouts_per_nine", 0.0)),
			float(pitching.get("walks_per_nine", 0.0)),
			float(pitching.get("home_runs_per_nine", 0.0)),
			_ability_mean(roster, "batters", "Bat_KAvoid"),
			_ability_mean(roster, "batters", "Bat_BBCreate"),
			_ability_mean(roster, "batters", "Bat_Impact"),
			_ability_mean(roster, "batters", "Bat_Loft"),
			_ability_mean(roster, "batters", "Bat_Barrel"),
			_ability_mean(roster, "pitchers", "Pit_KCreate"),
			_ability_mean(roster, "pitchers", "Pit_BBPrevent"),
			_ability_mean(roster, "pitchers", "Pit_ImpactLimit"),
			_ability_mean(roster, "pitchers", "Pit_BarrelDeny"),
			_ability_mean(roster, "pitchers", "Pit_Stamina"),
			_leader_value(leaderboards, "batting", "home_runs"),
			_leader_name(leaderboards, "batting", "home_runs"),
			_leader_value(leaderboards, "batting", "average"),
			_leader_name(leaderboards, "batting", "average"),
			_leader_value(leaderboards, "batting", "ops"),
			_leader_name(leaderboards, "batting", "ops"),
			_leader_value(leaderboards, "pitching", "era"),
			_leader_name(leaderboards, "pitching", "era"),
			_leader_value(leaderboards, "pitching", "strikeouts"),
			_leader_name(leaderboards, "pitching", "strikeouts"),
			int((row.get("trades", {}) as Dictionary).get("count", 0)),
			int(offseason.get("retired_count", 0)),
			int(offseason.get("released_count", 0)),
			int(offseason.get("released_pitcher_count", 0)),
			int(offseason.get("released_fielder_count", 0)),
			float(offseason.get("released_average_age", 0.0)),
			int(offseason.get("demoted_count", 0)),
			int(offseason.get("promoted_count", 0)),
			int(offseason.get("dev_released_count", 0)),
			int(offseason.get("fa_declared_count", 0)),
			int(offseason.get("fa_moved_count", 0)),
			int(offseason.get("geneki_moved_count", 0)),
			int(offseason.get("geneki_round2_count", 0)),
			int(offseason.get("released_signed_count", 0)),
			int(offseason.get("foreign_signed_count", 0)),
			int(offseason.get("foreign_released_count", 0)),
			int(offseason.get("draft_picks_count", 0)),
			int(offseason.get("rookies_count", 0)),
			int(offseason.get("growers_count", 0)),
			int(offseason.get("decayers_count", 0)),
			int(offseason.get("camp_actions_count", 0)),
			int(offseason.get("camp_pitch_learning_count", 0)),
			int(post_roster.get("active_players", 0)),
			int(post_roster.get("controlled_players", 0)),
			int(post_roster.get("development_players", 0)),
			int(post_roster.get("team_controlled_max", 0)),
			int(post_roster.get("team_development_max", 0)),
			int(post_roster.get("team_foreign_max", 0)),
			float(post_roster.get("draft_generated_ratio", 0.0)),
			float(post_roster.get("seed_cohort_ratio", 0.0)),
			int(offseason.get("foreign_retained_count", 0)),
			int(offseason.get("foreign_poached_count", 0)),
			int(offseason.get("foreign_multi_year_signed_count", 0)),
			int(offseason.get("contract_years_total_count", 0)),
			int(offseason.get("contract_years_multi_count", 0)),
			int(offseason.get("multi_year_active_count", 0)),
		]
		lines.append(_csv_values(csv_values))
	return "\n".join(lines)


func _run_auto_offseason(season: PSSeason, selected_team_id: int) -> Dictionary:
	# FA宣言 (オフ冒頭)。FA日数の締めと contract_status 遷移もここで済ませる。実フロー
	# (app_state.start_offseason) と同じく引退より前に走らせる。
	var declaration_result: Dictionary = FaMarketService.create_declaration_state(GameDb.players, GameDb.teams, season)

	# 怪我の越冬回復 (実フローと同じく引退判定と同じ位置)。戦力外/育成降格が読む
	# player.injury_days を今季の値へ更新するので、必ず戦力外ステップより前に走らせる。
	var injury_carryover: Dictionary = OffseasonService.process_injury_carryover(GameDb.players, season)

	var retirement_result: Dictionary = OffseasonService.process_retirement(GameDb.players, season)
	GameDb.rebuild_player_indices()

	# 予算は固定 (2026-08-04): 実フロー (app_state.advance_offseason) と同じく引退直後に
	# 前年順位だけ更新する。budget_result は補強フェーズ開始前 (引退者除外後) の残額スナップショット。
	TeamFinance.update_previous_ranks(GameDb.teams, season)
	var budget_result: Dictionary = TeamFinance.budget_summary(GameDb.players, GameDb.teams)

	# 順番は 戦力外 → ドラフト → 戦力外獲得 → 現役ドラフト → 契約更改 → FA → 契約年数 → 外国人 →
	# キャンプ → 成長 (AppState.OFFSEASON_STEP_ORDER と同じ)。
	# 外国人の去就 (残留/引き抜き/退団) は戦力外ステップではなく外国人契約市場ステップが決める。
	var release_result: Dictionary = OffseasonService.process_cpu_releases(GameDb.players, GameDb.teams, 0, season)
	GameDb.rebuild_player_indices()
	# 戦力外フェーズ直後に残った「30歳以上・今季出場ゼロ・入団3年目以降」の支配下選手数。
	# 本職保護が実績ゼロのベテランを生き残らせる再発バグ (2026-07-02 修正) の監視用で、期待値はほぼ 0。
	var noshow_thirties_survivor_rows: Array = _noshow_thirties_survivor_rows(season)
	var noshow_thirties_survivors: int = _noshow_thirties_unblocked_count(noshow_thirties_survivor_rows)
	# 戦力外通告 (+当落線上の若手の育成降格) 直後の支配下人数。ここからドラフト・戦力外獲得・
	# FA・外国人・育成昇格で開幕目標 (OPENING_ROSTER_TARGET) まで積み直す。
	# 放出計画が過不足なく効いているかは「この人数 + 見込み流入 ≒ 68」で確認する。
	var post_release_controlled: Dictionary = _controlled_count_stats()
	var merged_release_result: Dictionary = release_result.duplicate(true)

	# ドラフト (日本人 66 枠まで 6〜7 人補充)。
	var draft_state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, season, selected_team_id)
	var complete_result: Dictionary = DraftService.complete_automatically(draft_state)
	draft_state = complete_result.get("state", draft_state) as Dictionary
	var draft_result: Dictionary = {}
	if bool(draft_state.get("complete", false)):
		draft_result = DraftService.finalize_draft(draft_state, GameDb.players)
	GameDb.rebuild_player_indices()
	# 本指名 (支配下) と育成指名の内訳。総数だけだと「支配下の指名が細っているのか、
	# 育成が細っているのか」が区別できず、戦力外/降格の較正で判断を誤る。
	var draft_main_picks: int = 0
	var draft_dev_picks: int = 0
	for rookie_row in draft_result.get("rookies", []) as Array:
		if bool((rookie_row as Dictionary).get("development_player", false)):
			draft_dev_picks += 1
		else:
			draft_main_picks += 1

	# 戦力外獲得 (ドラフト後FA前)。team_id が動くので再構築。
	var released_market_result: Dictionary = ReleasedMarketService.process_released_market(
		GameDb.players, GameDb.teams, season, merged_release_result, 0
	)
	GameDb.rebuild_player_indices()

	# 現役ドラフト (戦力外獲得後・FA前)。user_team_id=0 で全球団CPU自動解決。
	var geneki_state: Dictionary = GenekiDraftService.create_geneki_draft_state(GameDb.players, GameDb.teams, season, 0)
	var geneki_result: Dictionary = GenekiDraftService.finalize_geneki_draft(geneki_state, GameDb.players, GameDb.teams, season)
	GameDb.rebuild_player_indices()

	# 契約更改 (補強市場の直前)。ここで player.salary が来季の確定額になり、以降の
	# FA/外国人の予算ゲートが来季 payroll に対して正確に効く。
	var contract_result: Dictionary = OffseasonService.process_contract_renewal(GameDb.players, GameDb.teams, season)

	# FA市場 (契約更改後)。team_id が動くので再構築。
	var fa_result: Dictionary = FaMarketService.process_fa_market(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	# 契約年数 (FA市場の直後)。user_team_id=0 なので全球団がCPU基準で自動決定される。
	var contract_years_state: Dictionary = OffseasonService.create_contract_years_state(GameDb.players, GameDb.teams, season, 0)
	var contract_years_result: Dictionary = OffseasonService.finalize_contract_years(contract_years_state, GameDb.players, GameDb.teams)

	# 外国人補強 (FA後)。生成選手を外国人枠に追加。
	var foreign_result: Dictionary = ForeignPlayerService.process_foreign_market(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	var camp_result: Dictionary = CampServiceRef.process_camp(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	var growth_result: Dictionary = OffseasonService.process_growth_decay(GameDb.players)
	GameDb.rebuild_player_indices()

	# roadmap #3: 育った育成選手を全球団自動で支配下登録 (長期検証では自軍も自動扱い)。
	var promotion_result: Dictionary = OffseasonService.process_development_promotions(GameDb.players, GameDb.teams, 0, season.year)
	GameDb.rebuild_player_indices()

	# 育成の整理 (失敗プロスペクト/枠超過を放出し pipeline を循環)。累積で player 数が膨れるのを防ぐ。
	var dev_release_result: Dictionary = OffseasonService.process_development_releases(GameDb.players, GameDb.teams, 0, season.year)
	GameDb.rebuild_player_indices()

	# 育成契約の消化シーズン数の分布 (オフ完了時点)。「育成のまま N年で自由契約」ルールの較正用で、
	# max が伸び続けるなら育成が滞留している (= 人数が発散する) サイン。
	var dev_tenure_max: int = 0
	var dev_tenure_sum: int = 0
	var dev_tenure_count: int = 0
	for dev_row in GameDb.players:
		var dev_player: PSPlayer = dev_row as PSPlayer
		if dev_player == null or dev_player.is_retired() or not dev_player.development_player:
			continue
		if dev_player.team_id <= 0:
			continue
		var tenure: int = dev_player.development_seasons_completed(season.year)
		dev_tenure_max = maxi(dev_tenure_max, tenure)
		dev_tenure_sum += tenure
		dev_tenure_count += 1

	# 複数年契約中選手の全リーグ総数 (制度が定着後どの程度の規模で推移するかの監視)。
	# cap saturation ([[feedback_cap_saturation_pattern]]) の監視対象は contract_years_multi 側。
	var multi_year_active_count: int = 0
	for active_player_row in GameDb.players:
		var active_player: PSPlayer = active_player_row as PSPlayer
		if active_player == null or active_player.is_retired():
			continue
		if active_player.is_multi_year_locked_offseason(season.year):
			multi_year_active_count += 1

	# 戦力外の投手/野手内訳 (position==1 が投手)。現実の NPB はおおむね 1:1〜投手やや多で、
	# 野手側へ大きく偏っていないかの監視用 (2026-07-03、実測 1:2 の偏り報告を受けて追加)。
	var released_pitcher_count: int = 0
	var released_age_sum: int = 0
	var released_age_min: int = 0
	var released_age_max: int = 0
	for released_row in release_result.get("released", []) as Array:
		var released_entry: Dictionary = released_row as Dictionary
		if int(released_entry.get("position", 0)) == 1:
			released_pitcher_count += 1
		var released_age: int = int(released_entry.get("age", 0))
		released_age_sum += released_age
		if released_age_min <= 0 or released_age < released_age_min:
			released_age_min = released_age
		released_age_max = maxi(released_age_max, released_age)
	var released_age_count: int = int(release_result.get("released_count", 0))
	var released_average_age: float = _safe_div(float(released_age_sum), float(released_age_count))

	# 引退直後 (補強フェーズ開始前) の固定予算に対する残額。offseason 中の署名で目減りする前の
	# 「今オフどれだけ配分できたか」の指標。offseason 完了後の実効拘束は over_budget_* 側を見る。
	var budget_rooms: Array = []
	for budget_row in budget_result.get("team_budgets", []) as Array:
		budget_rooms.append(int((budget_row as Dictionary).get("room", 0)))
	var budget_room_avg: float = 0.0
	var budget_room_min: int = 0
	if not budget_rooms.is_empty():
		var room_sum: int = 0
		budget_room_min = int(budget_rooms[0])
		for room_value in budget_rooms:
			room_sum += int(room_value)
			budget_room_min = mini(budget_room_min, int(room_value))
		budget_room_avg = float(room_sum) / float(budget_rooms.size())

	# オフ完了時点 (来季開幕ロースター) の予算拘束。予算キャップの較正はこの3列を見る:
	#   over_budget_count = 超過球団数 (0 が目標) / final_payroll_max = 最も重い球団の年俸総額
	#   final_room_min    = 最も苦しい球団の残額 (負なら超過額)
	var over_budget_count: int = 0
	var final_payroll_sum: int = 0
	var final_payroll_max: int = 0
	var final_room_min: int = 0
	var budget_team_count: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		var final_payroll: int = TeamFinance.team_payroll(GameDb.players, team.id)
		var final_room: int = TeamFinance.budget_room(team.funds, final_payroll)
		if TeamFinance.is_over_budget(team.funds, final_payroll):
			over_budget_count += 1
		final_payroll_sum += final_payroll
		final_payroll_max = maxi(final_payroll_max, final_payroll)
		final_room_min = final_room if budget_team_count == 0 else mini(final_room_min, final_room)
		budget_team_count += 1

	return {
		"budget_room_avg": budget_room_avg,
		"budget_room_min": budget_room_min,
		"final_payroll_avg": _round_float(_safe_div(float(final_payroll_sum), float(budget_team_count)), 0),
		"final_payroll_max": final_payroll_max,
		"final_room_min": final_room_min,
		"injury_carried_count": int(injury_carryover.get("carried", 0)),
		"retired_count": int(retirement_result.get("retired_count", 0)),
		"released_count": int(release_result.get("released_count", 0)),
		# 戦力外フェーズで支配下枠から取り除かれた総数 = 戦力外通告 + 育成降格 (長期故障 + 当落線上の若手)。
		# NPB の「12月頭に一括公示される支配下選手の自由契約」(= 戦力外通告と支配下→育成再契約の合計) と
		# 同じ母集団で、health の released_per_year / released_yearly_* はこの値を見る。
		# released_count だけだと育成降格の分を取りこぼし、実際の枠の空き方より過少に見える。
		"controlled_removed_count": int(release_result.get("released_count", 0)) + int(release_result.get("demoted_count", 0)),
		"released_pitcher_count": released_pitcher_count,
		"released_fielder_count": int(release_result.get("released_count", 0)) - released_pitcher_count,
		"released_age_count": released_age_count,
		"released_age_sum": released_age_sum,
		"released_average_age": _round_float(released_average_age, 2),
		"released_age_min": released_age_min,
		"released_age_max": released_age_max,
		"noshow_thirties_survivors": noshow_thirties_survivors,
		"post_release_controlled_avg": float(post_release_controlled.get("avg", 0.0)),
		"post_release_controlled_min": int(post_release_controlled.get("min", 0)),
		"post_release_controlled_max": int(post_release_controlled.get("max", 0)),
		"noshow_thirties_survivor_rows": noshow_thirties_survivor_rows,
		"demoted_count": int(release_result.get("demoted_count", 0)),
		"promoted_count": int(promotion_result.get("promoted_count", 0)),
		"dev_released_count": int(dev_release_result.get("released_count", 0)),
		"development_tenure_max": dev_tenure_max,
		"development_tenure_avg": _round_float(_safe_div(float(dev_tenure_sum), float(dev_tenure_count)), 2),
		"draft_complete": bool(draft_state.get("complete", false)),
		"draft_picks_count": (draft_state.get("picks", []) as Array).size(),
		"draft_main_picks_count": draft_main_picks,
		"draft_dev_picks_count": draft_dev_picks,
		"rookies_count": int(draft_result.get("rookies_count", 0)),
		"priority_league": str(draft_result.get("priority_league", draft_state.get("priority_league", ""))),
		"growers_count": int(growth_result.get("growers_count", 0)),
		"decayers_count": int(growth_result.get("decayers_count", 0)),
		"growth_kind_counts": (growth_result.get("growth_kind_counts", {}) as Dictionary).duplicate(true),
		"new_fa_count": int(declaration_result.get("new_fa_count", 0)),
		"over_budget_count": over_budget_count,
		"contract_renewal_raises": int(contract_result.get("raises_count", 0)),
		"contract_renewal_cuts": int(contract_result.get("cuts_count", 0)),
		"fa_moved_count": int(fa_result.get("moved_count", 0)),
		"fa_declared_count": int(fa_result.get("declared_count", 0)),
		"geneki_moved_count": int(geneki_result.get("moved_count", 0)),
		"geneki_round2_count": int(geneki_result.get("round2_count", 0)),
		"released_signed_count": int(released_market_result.get("signed_count", 0)),
		# 上限 (MAX_CONTROLLED_SIGNINGS_PER_TEAM) が効くのは支配下だけなので内訳も見る (育成は無制限)。
		"released_signed_controlled_count": int(released_market_result.get("signed_controlled_count", 0)),
		"released_signed_development_count": int(released_market_result.get("signed_development_count", 0)),
		# 育成獲得の年齢ペナルティ (高齢を弾く) と若手枠 (将来性で拾う) が効いているかの監視。
		"released_signed_development_avg_age": float(released_market_result.get("signed_development_avg_age", 0.0)),
		"released_signed_controlled_avg_age": float(released_market_result.get("signed_controlled_avg_age", 0.0)),
		# 戦力外獲得を1人も行わなかった球団数。「とりあえず2人獲る」になっていないかの監視用
		# (2026-08-03、獲得基準を TeamDepthChart の弱点+即戦力/将来性へ厳格化したときに追加)。
		"released_signed_zero_teams": _teams_without_released_signing(released_market_result),
		"released_candidates_count": int(released_market_result.get("candidates_count", 0)),
		"foreign_signed_count": int(foreign_result.get("signed_count", 0)),
		# 外国人契約市場 (残留/引き抜き/退団) の内訳。foreign_released_count は退団数を指す
		# (旧・外国人戦力外と同じ「保有から抜けた人数」の意味を維持、中身は退団のみに変わった)。
		"foreign_released_count": int(foreign_result.get("contract_departed_count", 0)),
		"foreign_retained_count": int(foreign_result.get("contract_retained_count", 0)),
		"foreign_poached_count": int(foreign_result.get("contract_poached_count", 0)),
		"foreign_multi_year_signed_count": int(foreign_result.get("contract_multi_year_count", 0)),
		"camp_actions_count": int(camp_result.get("actions_count", 0)),
		"camp_pitch_learning_count": int(camp_result.get("normal_pitch_learning_count", 0)),
		"contract_years_total_count": int(contract_years_result.get("decided_count", 0)),
		"contract_years_multi_count": int(contract_years_result.get("multi_year_count", 0)),
		"multi_year_active_count": multi_year_active_count,
	}


# 戦力外ステップ後に残った「30歳以上・今季出場ゼロ・入団3年目以降」の日本人支配下選手数。
# シーズンの過半を怪我で欠場して出場割引を全免除された選手は、意図的な残留として数えない。
# 現時点の支配下人数の球団別統計 {avg, min, max}。オフの各段階でロースターがどこまで
# 削れ / 積み直されたかを見るのに使う。
func _controlled_count_stats() -> Dictionary:
	var counts: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		counts.append(TeamFinance.controlled_count(GameDb.players, team.id))
	if counts.is_empty():
		return {"avg": 0.0, "min": 0, "max": 0}
	var total: int = 0
	var lowest: int = int(counts[0])
	var highest: int = int(counts[0])
	for value in counts:
		total += int(value)
		lowest = mini(lowest, int(value))
		highest = maxi(highest, int(value))
	return {
		"avg": _round_float(float(total) / float(counts.size()), 2),
		"min": lowest,
		"max": highest,
	}


# 戦力外獲得で1人も獲らなかった球団数。獲得基準が「弱点に合う選手だけ」になっていれば
# 0人の球団が普通に出る (全球団が毎年上限まで埋めていた頃はここが常に0だった)。
func _teams_without_released_signing(released_market_result: Dictionary) -> int:
	var signed_teams: Dictionary = {}
	for row in released_market_result.get("signings", []) as Array:
		signed_teams[int((row as Dictionary).get("to_team", 0))] = true
	var zero_teams: int = 0
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and not signed_teams.has(team.id):
			zero_teams += 1
	return zero_teams


# 「30歳以上・当季出場ゼロ・入団3年目以降」で支配下に残った日本人選手の一覧。
# 各行に `block_reason` (複数年契約中/FA宣言済み等、契約上そもそも通告できない理由) を持たせ、
# 集計 (`noshow_thirties_survivors`) は **block_reason が無い = 切れたのに切らなかった選手だけ**を
# 数える。契約で守られている選手を混ぜると「放出AIの取りこぼし」を測る指標として意味を失う
# (2026-08-04: 複数年契約の高年俸選手が出場ゼロで残るのは仕様どおりの挙動)。
func _noshow_thirties_survivor_rows(season: PSSeason) -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0 or player.is_retired():
			continue
		if player.development_player or player.foreign_player:
			continue
		if player.age < 30 or player.years <= 2:
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			var games: int = record.pitcher_stats.games if record.is_pitcher() else record.batter_stats.games
			if games > 0:
				continue
			if record.season_injury_days >= ReleaseValueProjector.INJURY_EXCUSE_FULL_DAYS:
				continue
		rows.append({
			"player_id": player.id,
			"name": player.name,
			"team_id": player.team_id,
			"age": player.age,
			"position": player.position,
			"role": player.role,
			"overall": OffseasonService.player_value_score(player),
			"projected_value": _round_float(ReleaseValueProjector.projected_value(player, record), 2),
			"block_reason": OffseasonService.release_block_reason(player, season.year),
		})
	return rows


# 契約上そもそも通告できない選手を除いた「取りこぼし」件数。health の監視対象はこちら。
func _noshow_thirties_unblocked_count(rows: Array) -> int:
	var count: int = 0
	for row in rows:
		if str((row as Dictionary).get("block_reason", "")).is_empty():
			count += 1
	return count


func _leaderboards_for_season(season: PSSeason) -> Dictionary:
	var records: Array = _records_for_season(season)
	var team_by_id: Dictionary = _team_by_id()
	var max_games: int = _max_team_games(season)
	var qualifier_pa: int = int(max(1.0, ceil(QUALIFIER_PA_PER_GAME * float(max_games))))
	var qualifier_outs: int = int(max(1.0, ceil(QUALIFIER_OUTS_PER_GAME * float(max_games))))
	return {
		"qualifier_pa": qualifier_pa,
		"qualifier_outs": qualifier_outs,
		"player_distributions": _player_distributions_for_season(records, qualifier_pa, qualifier_outs),
		"batting": {
			"average": _top_batters(records, team_by_id, "average", qualifier_pa, true),
			"ops": _top_batters(records, team_by_id, "ops", qualifier_pa, true),
			"home_runs": _top_batters(records, team_by_id, "home_runs", COUNTING_TITLE_MIN_PA, true),
			"rbi": _top_batters(records, team_by_id, "rbi", COUNTING_TITLE_MIN_PA, true),
			"hits": _top_batters(records, team_by_id, "hits", COUNTING_TITLE_MIN_PA, true),
			"walks": _top_batters(records, team_by_id, "walks", COUNTING_TITLE_MIN_PA, true),
		},
		"pitching": {
			"era": _top_pitchers(records, team_by_id, "era", qualifier_outs, false),
			"whip": _top_pitchers(records, team_by_id, "whip", qualifier_outs, false),
			"wins": _top_pitchers(records, team_by_id, "wins", 0, true),
			"strikeouts": _top_pitchers(records, team_by_id, "strikeouts", 0, true),
			"saves": _top_pitchers(records, team_by_id, "saves", 0, true),
			"home_runs_per_nine": _top_pitchers(records, team_by_id, "home_runs_per_nine", qualifier_outs, false),
		},
	}


func _player_distributions_for_season(records: Array, qualifier_pa: int, qualifier_outs: int) -> Dictionary:
	var batting_averages: Array = []
	var batting_ops: Array = []
	var batter_walks: Array = []
	var batter_strikeouts: Array = []
	var batter_walk_rates: Array = []
	var batter_strikeout_rates: Array = []
	var pitcher_eras: Array = []
	var pitcher_innings: Array = []
	var pitcher_walks: Array = []
	var pitcher_strikeouts: Array = []
	var pitcher_walks_per_nine: Array = []
	var pitcher_strikeouts_per_nine: Array = []
	var starter_innings: Array = []
	var starter_starts: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher():
			var pitcher_stats: PSPitcherStats = record.pitcher_stats
			if pitcher_stats.starts >= 10:
				starter_innings.append(pitcher_stats.innings_pitched())
				starter_starts.append(float(pitcher_stats.starts))
			if pitcher_stats.outs_pitched < qualifier_outs or pitcher_stats.outs_pitched <= 0:
				continue
			pitcher_eras.append(pitcher_stats.era())
			pitcher_innings.append(pitcher_stats.innings_pitched())
			pitcher_walks.append(float(pitcher_stats.walks))
			pitcher_strikeouts.append(float(pitcher_stats.strikeouts))
			pitcher_walks_per_nine.append(_safe_div(float(pitcher_stats.walks) * 27.0, float(pitcher_stats.outs_pitched)))
			pitcher_strikeouts_per_nine.append(pitcher_stats.strikeouts_per_nine())
			continue
		var batter_stats: PSBatterStats = record.batter_stats
		if batter_stats.plate_appearances < qualifier_pa or batter_stats.at_bats <= 0:
			continue
		batting_averages.append(batter_stats.batting_average())
		batting_ops.append(batter_stats.ops())
		batter_walks.append(float(batter_stats.walks))
		batter_strikeouts.append(float(batter_stats.strikeouts))
		batter_walk_rates.append(_safe_div(float(batter_stats.walks), float(batter_stats.plate_appearances)))
		batter_strikeout_rates.append(_safe_div(float(batter_stats.strikeouts), float(batter_stats.plate_appearances)))
	return {
		"batters": {
			"qualified_count": batting_averages.size(),
			"average": _distribution_summary(batting_averages, 3),
			"ops": _distribution_summary(batting_ops, 3),
			"walks": _distribution_summary(batter_walks, 0),
			"strikeouts": _distribution_summary(batter_strikeouts, 0),
			"walk_rate": _distribution_summary(batter_walk_rates, 4),
			"strikeout_rate": _distribution_summary(batter_strikeout_rates, 4),
			"average_300_count": _count_at_least(batting_averages, 0.300),
			"average_320_count": _count_at_least(batting_averages, 0.320),
			"ops_850_count": _count_at_least(batting_ops, 0.850),
			"ops_900_count": _count_at_least(batting_ops, 0.900),
			"ops_950_count": _count_at_least(batting_ops, 0.950),
			"ops_1000_count": _count_at_least(batting_ops, 1.000),
		},
		"pitchers": {
			"qualified_count": pitcher_eras.size(),
			"era": _distribution_summary(pitcher_eras, 2),
			"innings_pitched": _distribution_summary(pitcher_innings, 1),
			"walks": _distribution_summary(pitcher_walks, 0),
			"strikeouts": _distribution_summary(pitcher_strikeouts, 0),
			"walks_per_nine": _distribution_summary(pitcher_walks_per_nine, 2),
			"strikeouts_per_nine": _distribution_summary(pitcher_strikeouts_per_nine, 2),
			"starter_innings_pitched": _distribution_summary(starter_innings, 1),
			"starter_starts": _distribution_summary(starter_starts, 0),
			"innings_120_count": _count_at_least(starter_innings, 120.0),
			"innings_130_count": _count_at_least(starter_innings, 130.0),
			"innings_140_count": _count_at_least(starter_innings, 140.0),
			"era_200_count": _count_at_most(pitcher_eras, 2.00),
			"era_250_count": _count_at_most(pitcher_eras, 2.50),
			"era_300_count": _count_at_most(pitcher_eras, 3.00),
		},
	}


func _records_for_season(season: PSSeason) -> Array:
	var records: Array = []
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.year != season.year or record.season_number != season.season_number:
			continue
		if record.team_id <= 0:
			continue
		records.append(record)
	return records


func _top_batters(records: Array, team_by_id: Dictionary, metric: String, min_pa: int, descending: bool) -> Array:
	var rows: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var stats: PSBatterStats = record.batter_stats
		if record.is_pitcher() and stats.plate_appearances < PITCHER_EXCLUDE_PA:
			continue
		if stats.plate_appearances < min_pa:
			continue
		if (metric == "average" or metric == "ops") and stats.at_bats <= 0:
			continue
		var value: float = _batting_metric_value(stats, metric)
		rows.append(_batter_leader_row(record, stats, team_by_id, metric, value))
	rows.sort_custom(func(a, b) -> bool:
		var row_a: Dictionary = a as Dictionary
		var row_b: Dictionary = b as Dictionary
		if is_equal_approx(float(row_a.get("value", 0.0)), float(row_b.get("value", 0.0))):
			return int(row_a.get("plate_appearances", 0)) > int(row_b.get("plate_appearances", 0))
		return float(row_a.get("value", 0.0)) > float(row_b.get("value", 0.0)) if descending else float(row_a.get("value", 0.0)) < float(row_b.get("value", 0.0))
	)
	return _ranked_top_rows(rows)


func _top_pitchers(records: Array, team_by_id: Dictionary, metric: String, min_outs: int, descending: bool) -> Array:
	var rows: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher():
			continue
		var stats: PSPitcherStats = record.pitcher_stats
		if stats.games <= 0:
			continue
		if stats.outs_pitched < min_outs:
			continue
		if (metric == "era" or metric == "whip" or metric == "home_runs_per_nine") and stats.outs_pitched <= 0:
			continue
		var value: float = _pitching_metric_value(stats, metric)
		rows.append(_pitcher_leader_row(record, stats, team_by_id, metric, value))
	rows.sort_custom(func(a, b) -> bool:
		var row_a: Dictionary = a as Dictionary
		var row_b: Dictionary = b as Dictionary
		if is_equal_approx(float(row_a.get("value", 0.0)), float(row_b.get("value", 0.0))):
			return int(row_a.get("outs_pitched", 0)) > int(row_b.get("outs_pitched", 0))
		return float(row_a.get("value", 0.0)) > float(row_b.get("value", 0.0)) if descending else float(row_a.get("value", 0.0)) < float(row_b.get("value", 0.0))
	)
	return _ranked_top_rows(rows)


func _ranked_top_rows(rows: Array) -> Array:
	var result: Array = []
	var limit: int = min(LEADERBOARD_LIMIT, rows.size())
	for i in range(limit):
		var row: Dictionary = (rows[i] as Dictionary).duplicate(true)
		row["rank"] = i + 1
		result.append(row)
	return result


func _batter_leader_row(record: PSPlayerSeasonRecord, stats: PSBatterStats, team_by_id: Dictionary, metric: String, value: float) -> Dictionary:
	var team: PSTeam = team_by_id.get(record.team_id, null) as PSTeam
	return {
		"player_id": record.player_id,
		"name": record.name,
		"team_id": record.team_id,
		"team": team.short_name if team != null else str(record.team_id),
		"age": record.age,
		"overall": PlayerValueEvaluator.overall_score(record),
		"draft_generated": _is_draft_generated_record(record),
		"metric": metric,
		"value": _round_float(value, 4),
		"display": _format_leader_value(metric, value, false),
		"plate_appearances": stats.plate_appearances,
		"at_bats": stats.at_bats,
		"hits": stats.hits,
		"home_runs": stats.home_runs,
		"runs_batted_in": stats.runs_batted_in,
		"walks": stats.walks,
		"strikeouts": stats.strikeouts,
		"batting_average": _round_float(stats.batting_average(), 3),
		"on_base_percentage": _round_float(stats.on_base_percentage(), 3),
		"slugging_percentage": _round_float(stats.slugging_percentage(), 3),
		"ops": _round_float(stats.ops(), 3),
	}


func _pitcher_leader_row(record: PSPlayerSeasonRecord, stats: PSPitcherStats, team_by_id: Dictionary, metric: String, value: float) -> Dictionary:
	var team: PSTeam = team_by_id.get(record.team_id, null) as PSTeam
	return {
		"player_id": record.player_id,
		"name": record.name,
		"team_id": record.team_id,
		"team": team.short_name if team != null else str(record.team_id),
		"age": record.age,
		"overall": PlayerValueEvaluator.overall_score(record),
		"draft_generated": _is_draft_generated_record(record),
		"metric": metric,
		"value": _round_float(value, 4),
		"display": _format_leader_value(metric, value, true),
		"games": stats.games,
		"starts": stats.starts,
		"wins": stats.wins,
		"losses": stats.losses,
		"saves": stats.saves,
		"holds": stats.holds,
		"outs_pitched": stats.outs_pitched,
		"innings_pitched": _round_float(stats.innings_pitched(), 1),
		"strikeouts": stats.strikeouts,
		"walks": stats.walks,
		"home_runs_allowed": stats.home_runs_allowed,
		"era": _round_float(stats.era(), 2),
		"whip": _round_float(stats.whip(), 3),
		"strikeouts_per_nine": _round_float(stats.strikeouts_per_nine(), 2),
		"walks_per_nine": _round_float(_safe_div(float(stats.walks) * 27.0, float(stats.outs_pitched)), 2),
		"home_runs_per_nine": _round_float(_safe_div(float(stats.home_runs_allowed) * 27.0, float(stats.outs_pitched)), 2),
	}


func _batting_metric_value(stats: PSBatterStats, metric: String) -> float:
	match metric:
		"average":
			return stats.batting_average()
		"ops":
			return stats.ops()
		"home_runs":
			return float(stats.home_runs)
		"rbi":
			return float(stats.runs_batted_in)
		"hits":
			return float(stats.hits)
		"walks":
			return float(stats.walks)
		_:
			return 0.0


func _pitching_metric_value(stats: PSPitcherStats, metric: String) -> float:
	match metric:
		"era":
			return stats.era()
		"whip":
			return stats.whip()
		"wins":
			return float(stats.wins)
		"strikeouts":
			return float(stats.strikeouts)
		"saves":
			return float(stats.saves)
		"home_runs_per_nine":
			return _safe_div(float(stats.home_runs_allowed) * 27.0, float(stats.outs_pitched))
		_:
			return 0.0


func _format_leader_value(metric: String, value: float, is_pitcher: bool) -> String:
	if metric == "average" or metric == "ops":
		return "%.3f" % value
	if metric == "era" or metric == "whip" or metric == "home_runs_per_nine":
		return "%.2f" % value
	if is_pitcher and metric == "strikeouts":
		return "%dK" % int(round(value))
	if is_pitcher and metric == "saves":
		return "%dS" % int(round(value))
	if is_pitcher and metric == "wins":
		return "%d勝" % int(round(value))
	if metric == "home_runs":
		return "%d本" % int(round(value))
	if metric == "rbi":
		return "%d点" % int(round(value))
	return "%d" % int(round(value))


func _roster_summary(players: Array, teams: Array, seed_cohort_ids: Dictionary = {}) -> Dictionary:
	var active_players: int = 0
	var controlled_players: int = 0
	var development_players: int = 0
	var foreign_players: int = 0
	var draft_generated_players: int = 0
	var seed_cohort_players: int = 0
	var total_age: int = 0
	var total_overall: int = 0
	var salary_values: Array = []
	var batter_overalls: Array = []
	var pitcher_overalls: Array = []
	var batter_abilities: Dictionary = _empty_ability_accumulator(BATTER_ABILITY_KEYS)
	var pitcher_abilities: Dictionary = _empty_ability_accumulator(PITCHER_ABILITY_KEYS)
	var overall_values: Array = []
	var age_values: Array = []
	var source_counts: Dictionary = {}
	var position_counts: Dictionary = {
		"pitcher": 0,
		"catcher": 0,
		"infield": 0,
		"outfield": 0,
	}
	var age_bands: Dictionary = {
		"age_23_under": 0,
		"age_24_29": 0,
		"age_30_34": 0,
		"age_35_plus": 0,
	}
	var veteran_regular_30s: int = 0
	var veteran_bench_35_plus: int = 0
	var by_team: Dictionary = {}
	var by_team_controlled: Dictionary = {}
	var by_team_development: Dictionary = {}
	var by_team_foreign: Dictionary = {}
	var free_agent_orphans: int = 0
	var released_orphans: int = 0
	var teamless_active_players: int = 0
	var retired_team_players: int = 0
	var injured_players: int = 0
	var long_injured_players: int = 0
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		by_team[str(team.id)] = 0
		by_team_controlled[str(team.id)] = 0
		by_team_development[str(team.id)] = 0
		by_team_foreign[str(team.id)] = 0

	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null:
			continue
		if player.team_id <= 0 and not player.is_retired():
			if bool(player.source_data.get("free_agent", false)):
				free_agent_orphans += 1
			elif bool(player.source_data.get("released", false)):
				released_orphans += 1
			else:
				teamless_active_players += 1
		if player.team_id > 0 and player.is_retired():
			retired_team_players += 1
		if not _is_active_roster_player(player):
			continue
		active_players += 1
		if player.development_player:
			development_players += 1
			by_team_development[str(player.team_id)] = int(by_team_development.get(str(player.team_id), 0)) + 1
		else:
			controlled_players += 1
			by_team_controlled[str(player.team_id)] = int(by_team_controlled.get(str(player.team_id), 0)) + 1
		if player.foreign_player:
			foreign_players += 1
			by_team_foreign[str(player.team_id)] = int(by_team_foreign.get(str(player.team_id), 0)) + 1
		if player.injury_days > 0:
			injured_players += 1
			if player.injury_days >= 120:
				long_injured_players += 1
		total_age += player.age
		var overall: int = OffseasonService.player_value_score(player)
		total_overall += overall
		overall_values.append(overall)
		age_values.append(player.age)
		salary_values.append(player.salary)
		if seed_cohort_ids.has(player.id):
			seed_cohort_players += 1
		if player.age <= 23:
			age_bands["age_23_under"] = int(age_bands["age_23_under"]) + 1
		elif player.age <= 29:
			age_bands["age_24_29"] = int(age_bands["age_24_29"]) + 1
		elif player.age <= 34:
			age_bands["age_30_34"] = int(age_bands["age_30_34"]) + 1
		else:
			age_bands["age_35_plus"] = int(age_bands["age_35_plus"]) + 1
		if player.age >= 30 and player.age <= 39 and overall >= 60:
			veteran_regular_30s += 1
		if player.age >= 35 and overall >= 45 and overall < 60:
			veteran_bench_35_plus += 1
		if player.is_pitcher():
			pitcher_overalls.append(overall)
			_accumulate_player_abilities(pitcher_abilities, player, PITCHER_ABILITY_KEYS)
		else:
			batter_overalls.append(overall)
			_accumulate_player_abilities(batter_abilities, player, BATTER_ABILITY_KEYS)
		by_team[str(player.team_id)] = int(by_team.get(str(player.team_id), 0)) + 1
		var position_group: String = _position_group(player.position)
		position_counts[position_group] = int(position_counts.get(position_group, 0)) + 1
		if _is_draft_generated(player):
			draft_generated_players += 1
			var source_type: String = str(player.source_data.get("draft_source", "unknown"))
			if source_type.is_empty():
				source_type = "unknown"
			source_counts[source_type] = int(source_counts.get(source_type, 0)) + 1

	var team_counts: Array = []
	var team_controlled_counts: Array = []
	var team_development_counts: Array = []
	var team_foreign_counts: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		team_counts.append(int(by_team.get(str(team.id), 0)))
		team_controlled_counts.append(int(by_team_controlled.get(str(team.id), 0)))
		team_development_counts.append(int(by_team_development.get(str(team.id), 0)))
		team_foreign_counts.append(int(by_team_foreign.get(str(team.id), 0)))

	return {
		"player_rows_total": players.size(),
		"active_players": active_players,
		"controlled_players": controlled_players,
		"development_players": development_players,
		"foreign_players": foreign_players,
		"draft_generated_active_players": draft_generated_players,
		"non_draft_active_players": active_players - draft_generated_players,
		"draft_generated_ratio": _round_float(_safe_div(draft_generated_players, active_players), 4),
		"seed_cohort_active_players": seed_cohort_players,
		"seed_cohort_ratio": _round_float(_safe_div(seed_cohort_players, active_players), 4),
		"in_run_added_active_players": active_players - seed_cohort_players,
		"average_age": _round_float(_safe_div(total_age, active_players), 2),
		"age_p10": _round_float(_percentile(age_values, 0.10), 2),
		"age_p50": _round_float(_percentile(age_values, 0.50), 2),
		"age_p90": _round_float(_percentile(age_values, 0.90), 2),
		"average_overall": _round_float(_safe_div(total_overall, active_players), 2),
		"average_batter_overall": _round_float(_mean(batter_overalls), 2),
		"average_pitcher_overall": _round_float(_mean(pitcher_overalls), 2),
		"overall_p10": _round_float(_percentile(overall_values, 0.10), 2),
		"overall_p50": _round_float(_percentile(overall_values, 0.50), 2),
		"overall_p90": _round_float(_percentile(overall_values, 0.90), 2),
		"salary_p50": _round_float(_percentile(salary_values, 0.50), 0),
		"salary_p90": _round_float(_percentile(salary_values, 0.90), 0),
		"salary_max": _round_float(_max_value(salary_values), 0),
		"team_roster_min": int(_min_value(team_counts)),
		"team_roster_average": _round_float(_mean(team_counts), 2),
		"team_roster_max": int(_max_value(team_counts)),
		"team_controlled_min": int(_min_value(team_controlled_counts)),
		"team_controlled_average": _round_float(_mean(team_controlled_counts), 2),
		"team_controlled_max": int(_max_value(team_controlled_counts)),
		"team_development_min": int(_min_value(team_development_counts)),
		"team_development_average": _round_float(_mean(team_development_counts), 2),
		"team_development_max": int(_max_value(team_development_counts)),
		"team_foreign_max": int(_max_value(team_foreign_counts)),
		"team_rosters": by_team,
		"team_controlled_rosters": by_team_controlled,
		"team_development_rosters": by_team_development,
		"team_foreign_rosters": by_team_foreign,
		"free_agent_orphans": free_agent_orphans,
		"released_orphans": released_orphans,
		"teamless_active_players": teamless_active_players,
		"retired_team_players": retired_team_players,
		"injured_players": injured_players,
		"long_injured_players": long_injured_players,
		"draft_source_counts": source_counts,
		"position_counts": position_counts,
		"age_bands": age_bands,
		"veteran_regular_30s": veteran_regular_30s,
		"veteran_bench_35_plus": veteran_bench_35_plus,
		"ability_averages": {
			"batters": _finalize_ability_accumulator(batter_abilities),
			"pitchers": _finalize_ability_accumulator(pitcher_abilities),
		},
	}


func _empty_ability_accumulator(keys: Array) -> Dictionary:
	var rows: Dictionary = {"count": 0, "keys": {}}
	var key_rows: Dictionary = rows["keys"] as Dictionary
	for key_value in keys:
		key_rows[str(key_value)] = 0.0
	return rows


func _accumulate_player_abilities(accumulator: Dictionary, player: PSPlayer, keys: Array) -> void:
	accumulator["count"] = int(accumulator.get("count", 0)) + 1
	var key_rows: Dictionary = accumulator.get("keys", {}) as Dictionary
	for key_value in keys:
		var key: String = str(key_value)
		key_rows[key] = float(key_rows.get(key, 0.0)) + player.z_ability(key, 0.0)


func _finalize_ability_accumulator(accumulator: Dictionary) -> Dictionary:
	var count: int = int(accumulator.get("count", 0))
	var key_rows: Dictionary = accumulator.get("keys", {}) as Dictionary
	var result: Dictionary = {"count": count}
	for key_value in key_rows.keys():
		var key: String = str(key_value)
		result[key] = _round_float(_safe_div(float(key_rows.get(key, 0.0)), float(count)), 2)
	return result


func _ability_mean(roster: Dictionary, group: String, key: String) -> float:
	var ability_averages: Dictionary = roster.get("ability_averages", {}) as Dictionary
	var group_rows: Dictionary = ability_averages.get(group, {}) as Dictionary
	return float(group_rows.get(key, 0.0))


func _leader_value(leaderboards: Dictionary, group: String, metric: String) -> float:
	var rows: Array = ((leaderboards.get(group, {}) as Dictionary).get(metric, []) as Array)
	if rows.is_empty():
		return 0.0
	return float((rows[0] as Dictionary).get("value", 0.0))


func _leader_name(leaderboards: Dictionary, group: String, metric: String) -> String:
	var rows: Array = ((leaderboards.get(group, {}) as Dictionary).get(metric, []) as Array)
	if rows.is_empty():
		return ""
	return str((rows[0] as Dictionary).get("name", ""))


func _csv_text(value: String) -> String:
	var text: String = value.replace("\"", "\"\"")
	if text.find(",") >= 0 or text.find("\"") >= 0 or text.find("\n") >= 0:
		return "\"%s\"" % text
	return text


func _csv_values(values: Array) -> String:
	var cells: Array = []
	for value in values:
		cells.append(_csv_text(str(value)))
	return ",".join(cells)


func _window_summary(rows: Array, year_count: int) -> Dictionary:
	if rows.is_empty():
		return {}
	var from_index: int = max(0, rows.size() - max(1, year_count))
	return _summarize_rows(rows.slice(from_index, rows.size()))


func _draft_only_window_summary(rows: Array, draft_only_year: int) -> Dictionary:
	if draft_only_year <= 0:
		return {}
	var selected: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("year", 0)) >= draft_only_year:
			selected.append(row)
	return _summarize_rows(selected)


func _summarize_rows(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	return {
		"years": rows.size(),
		"start_year": int((rows[0] as Dictionary).get("year", 0)),
		"end_year": int((rows[rows.size() - 1] as Dictionary).get("year", 0)),
		"active_players": _round_float(_mean_nested(rows, ["roster_before_season", "active_players"]), 2),
		"controlled_players": _round_float(_mean_nested(rows, ["roster_before_season", "controlled_players"]), 2),
		"development_players": _round_float(_mean_nested(rows, ["roster_before_season", "development_players"]), 2),
		"team_controlled_max": _round_float(_mean_nested(rows, ["roster_before_season", "team_controlled_max"]), 2),
		"team_development_max": _round_float(_mean_nested(rows, ["roster_before_season", "team_development_max"]), 2),
		"draft_generated_ratio": _round_float(_mean_nested(rows, ["roster_before_season", "draft_generated_ratio"]), 4),
		"seed_cohort_ratio": _round_float(_mean_nested(rows, ["roster_before_season", "seed_cohort_ratio"]), 4),
		"in_run_added_active_players": _round_float(_mean_nested(rows, ["roster_before_season", "in_run_added_active_players"]), 2),
		"average_age": _round_float(_mean_nested(rows, ["roster_before_season", "average_age"]), 2),
		"age_23_under": _round_float(_mean_nested(rows, ["roster_before_season", "age_bands", "age_23_under"]), 2),
		"age_24_29": _round_float(_mean_nested(rows, ["roster_before_season", "age_bands", "age_24_29"]), 2),
		"age_30_34": _round_float(_mean_nested(rows, ["roster_before_season", "age_bands", "age_30_34"]), 2),
		"age_35_plus": _round_float(_mean_nested(rows, ["roster_before_season", "age_bands", "age_35_plus"]), 2),
		"veteran_regular_30s": _round_float(_mean_nested(rows, ["roster_before_season", "veteran_regular_30s"]), 2),
		"veteran_bench_35_plus": _round_float(_mean_nested(rows, ["roster_before_season", "veteran_bench_35_plus"]), 2),
		"average_overall": _round_float(_mean_nested(rows, ["roster_before_season", "average_overall"]), 2),
		"average_batter_overall": _round_float(_mean_nested(rows, ["roster_before_season", "average_batter_overall"]), 2),
		"average_pitcher_overall": _round_float(_mean_nested(rows, ["roster_before_season", "average_pitcher_overall"]), 2),
		"average_bat_impact": _round_float(_mean_nested(rows, ["roster_before_season", "ability_averages", "batters", "Bat_Impact"]), 2),
		"average_bat_barrel": _round_float(_mean_nested(rows, ["roster_before_season", "ability_averages", "batters", "Bat_Barrel"]), 2),
		"average_pit_impact_limit": _round_float(_mean_nested(rows, ["roster_before_season", "ability_averages", "pitchers", "Pit_ImpactLimit"]), 2),
		"average_pit_bb_prevent": _round_float(_mean_nested(rows, ["roster_before_season", "ability_averages", "pitchers", "Pit_BBPrevent"]), 2),
		"runs_per_team_game": _round_float(_mean_nested(rows, ["season", "runs_per_team_game"]), 3),
		"runs_per_game_total": _round_float(_mean_nested(rows, ["season", "runs_per_game_total"]), 3),
		"batting_average": _round_float(_mean_nested(rows, ["season", "batting", "batting_average"]), 3),
		"on_base_percentage": _round_float(_mean_nested(rows, ["season", "batting", "on_base_percentage"]), 3),
		"slugging_percentage": _round_float(_mean_nested(rows, ["season", "batting", "slugging_percentage"]), 3),
		"ops": _round_float(_mean_nested(rows, ["season", "batting", "ops"]), 3),
		"home_runs_per_game": _round_float(_mean_nested(rows, ["season", "batting", "home_runs_per_game"]), 3),
		"walks_per_game": _round_float(_mean_nested(rows, ["season", "batting", "walks_per_game"]), 3),
		"strikeouts_per_game": _round_float(_mean_nested(rows, ["season", "batting", "strikeouts_per_game"]), 3),
		"walk_rate": _round_float(_ratio_nested(rows, ["season", "batting", "walks"], ["season", "batting", "plate_appearances"]), 4),
		"strikeout_rate": _round_float(_ratio_nested(rows, ["season", "batting", "strikeouts"], ["season", "batting", "plate_appearances"]), 4),
		"era": _round_float(_mean_nested(rows, ["season", "pitching", "era"]), 2),
		"whip": _round_float(_mean_nested(rows, ["season", "pitching", "whip"]), 3),
		"strikeouts_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "strikeouts_per_nine"]), 2),
		"walks_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "walks_per_nine"]), 2),
		"home_runs_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "home_runs_per_nine"]), 2),
		# 戦力外フェーズが支配下枠から外した人数 (戦力外通告 + 育成降格)。以下の投野比・平均年齢は
		# 内訳の取れる戦力外通告のみが母集団なので、released_per_year とは母数が違う。
		"released_per_year": _round_float(_mean_nested(rows, ["offseason", "controlled_removed_count"]), 2),
		"released_notified_per_year": _round_float(_mean_nested(rows, ["offseason", "released_count"]), 2),
		"released_pitchers_per_year": _round_float(_mean_nested(rows, ["offseason", "released_pitcher_count"]), 2),
		"released_fielders_per_year": _round_float(_mean_nested(rows, ["offseason", "released_fielder_count"]), 2),
		"released_fielders_per_pitcher": _round_float(_safe_div(
			_mean_nested(rows, ["offseason", "released_fielder_count"]),
			_mean_nested(rows, ["offseason", "released_pitcher_count"])
		), 3),
		"released_average_age": _round_float(_weighted_mean_nested(
			rows,
			["offseason", "released_age_sum"],
			["offseason", "released_age_count"]
		), 2),
		"noshow_thirties_survivors_per_year": _round_float(_mean_nested(rows, ["offseason", "noshow_thirties_survivors"]), 2),
		"retired_per_year": _round_float(_mean_nested(rows, ["offseason", "retired_count"]), 2),
		"rookies_per_year": _round_float(_mean_nested(rows, ["offseason", "rookies_count"]), 2),
	}


func _mean_nested(rows: Array, keys: Array) -> float:
	var values: Array = []
	for row_value in rows:
		var current: Variant = row_value
		for key_value in keys:
			if not (current is Dictionary):
				current = null
				break
			current = (current as Dictionary).get(str(key_value), null)
		if current == null:
			continue
		values.append(float(current))
	return _mean(values)


func _ratio_nested(rows: Array, numerator_keys: Array, denominator_keys: Array) -> float:
	var numerator: float = 0.0
	var denominator: float = 0.0
	for row_value in rows:
		numerator += _nested_float(row_value, numerator_keys)
		denominator += _nested_float(row_value, denominator_keys)
	return _safe_div(numerator, denominator)


func _weighted_mean_nested(rows: Array, sum_keys: Array, count_keys: Array) -> float:
	var total_sum: float = 0.0
	var total_count: float = 0.0
	for row_value in rows:
		total_sum += _nested_float(row_value, sum_keys)
		total_count += _nested_float(row_value, count_keys)
	return _safe_div(total_sum, total_count)


func _nested_float(root: Variant, keys: Array) -> float:
	var current: Variant = root
	for key_value in keys:
		if not (current is Dictionary):
			return 0.0
		current = (current as Dictionary).get(str(key_value), null)
		if current == null:
			return 0.0
	return float(current)


func _active_player_id_set(players: Array) -> Dictionary:
	var ids: Dictionary = {}
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if _is_active_roster_player(player):
			ids[player.id] = true
	return ids


func _snapshot_players() -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		rows.append(player.to_dict().duplicate(true))
	return rows


func _restore_players(player_rows: Array) -> void:
	GameDb.players.clear()
	GameDb.players_by_id.clear()
	GameDb.players_by_team.clear()
	for row_value in player_rows:
		var row: Dictionary = row_value as Dictionary
		var player: PSPlayer = PSPlayer.from_dict(row)
		GameDb.players.append(player)
		GameDb.players_by_id[player.id] = player
		if not GameDb.players_by_team.has(player.team_id):
			GameDb.players_by_team[player.team_id] = []
		GameDb.players_by_team[player.team_id].append(player)


func _is_active_roster_player(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.team_id <= 0:
		return false
	if player.is_retired():
		return false
	return true


func _is_draft_generated(player: PSPlayer) -> bool:
	var source: Dictionary = player.source_data
	if bool(source.get("draft_candidate", false)):
		return true
	if source.has("draft_year") or source.has("draft_candidate_id"):
		return true
	return not str(source.get("draft_source", "")).is_empty()


func _is_draft_generated_record(record: PSPlayerSeasonRecord) -> bool:
	var source: Dictionary = record.source_data
	if bool(source.get("draft_candidate", false)):
		return true
	if source.has("draft_year") or source.has("draft_candidate_id"):
		return true
	return not str(source.get("draft_source", "")).is_empty()


func _team_by_id() -> Dictionary:
	var rows: Dictionary = {}
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			rows[team.id] = team
	return rows


func _max_team_games(season: PSSeason) -> int:
	var result: int = 0
	for stats_value in season.standings.values():
		var stats: PSStats = stats_value as PSStats
		if stats != null:
			result = max(result, stats.games)
	return result


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


func _safe_div(numerator: float, denominator: float) -> float:
	if absf(denominator) < 0.000001:
		return 0.0
	return numerator / denominator


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _distribution_summary(values: Array, digits: int) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	return {
		"count": values.size(),
		"min": _round_float(_min_value(values), digits),
		"p10": _round_float(_percentile(values, 0.10), digits),
		"p25": _round_float(_percentile(values, 0.25), digits),
		"p50": _round_float(_percentile(values, 0.50), digits),
		"p75": _round_float(_percentile(values, 0.75), digits),
		"p90": _round_float(_percentile(values, 0.90), digits),
		"max": _round_float(_max_value(values), digits),
		"mean": _round_float(_mean(values), digits),
	}


func _count_at_least(values: Array, threshold: float) -> int:
	var count: int = 0
	for value in values:
		if float(value) >= threshold:
			count += 1
	return count


func _count_at_most(values: Array, threshold: float) -> int:
	var count: int = 0
	for value in values:
		if float(value) <= threshold:
			count += 1
	return count


func _percentile(values: Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var index: int = int(round(clamp(percentile, 0.0, 1.0) * float(sorted.size() - 1)))
	return float(sorted[index])


func _min_value(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = float(values[0])
	for value in values:
		result = min(result, float(value))
	return result


func _max_value(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var result: float = float(values[0])
	for value in values:
		result = max(result, float(value))
	return result


func _round_float(value: float, digits: int = 2) -> float:
	var factor: float = pow(10.0, float(digits))
	return round(value * factor) / factor
