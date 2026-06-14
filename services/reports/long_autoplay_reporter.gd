extends RefCounted
class_name PSLongAutoplayReporter

const SimulationReporterScript = preload("res://services/reports/simulation_reporter.gd")
const CampServiceRef = preload("res://services/season/camp_service.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const GameLogService = preload("res://services/storage/game_log_service.gd")

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
		"central": bool(settings.get("central", true)),
		"pacific": bool(settings.get("pacific", true)),
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
		RecordStore.clear_records()
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

		var roster_before: Dictionary = _roster_summary(GameDb.players, GameDb.teams, seed_cohort_ids)
		GameLogService.enabled = false  # 長期レポートは試合ログを書かない (大量ファイル回避)
		var simulation_result: Dictionary = GameSimulator.simulate_remaining_season(season, false)
		GameLogService.enabled = true
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": season.year,
				"season_index": season_index + 1,
				"message": str(simulation_result.get("message", "")),
			})
			break

		var season_report: Dictionary = simulation_reporter.call("_season_report", season) as Dictionary
		var season_summary: Dictionary = simulation_reporter.call("_public_season_summary", season_report) as Dictionary
		var leaderboards: Dictionary = _leaderboards_for_season(season)
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
			"season": season_summary,
			"leaderboards": leaderboards,
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
		RecordStore.save_records()
		Rng.current_seed = original_rng_seed
		Rng.generator.seed = original_rng_seed
		Rng.generator.state = original_rng_state

	return {
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
		GameLogService.enabled = false  # 長期レポートは試合ログを書かない (大量ファイル回避)
		var simulation_result: Dictionary = await GameSimulator.simulate_remaining_season_async(
			season, false, {}, tree, inner_cb, cancel_token
		)
		GameLogService.enabled = true
		if bool(simulation_result.get("cancelled", false)) or _is_cancelled(cancel_token):
			break
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": season.year,
				"season_index": season_index + 1,
				"message": str(simulation_result.get("message", "")),
			})
			break

		var season_report: Dictionary = simulation_reporter.call("_season_report", season) as Dictionary
		var season_summary: Dictionary = simulation_reporter.call("_public_season_summary", season_report) as Dictionary
		var leaderboards: Dictionary = _leaderboards_for_season(season)
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
			"season": season_summary,
			"leaderboards": leaderboards,
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
		RecordStore.save_records()
		Rng.current_seed = original_rng_seed
		Rng.generator.seed = original_rng_seed
		Rng.generator.state = original_rng_state

	return {
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


func csv_text(report: Dictionary) -> String:
	var lines: Array = []
	lines.append("season_index,year,active_players,draft_generated_active,draft_generated_ratio,non_draft_active,seed_cohort_active,seed_cohort_ratio,in_run_added_active,age_23_under,age_24_29,age_30_34,age_35_plus,veteran_regular_30s,veteran_bench_35_plus,avg_age,avg_overall,batter_overall,pitcher_overall,overall_p10,overall_p50,overall_p90,roster_min,roster_avg,roster_max,runs_per_team_game,runs_per_game_total,avg,obp,slg,ops,hr_per_game,bb_per_game,so_per_game,era,whip,k_per_9,bb_per_9,hr_per_9,avg_bat_kavoid_z,avg_bat_bbcreate_z,avg_bat_impact_z,avg_bat_loft_z,avg_bat_barrel_z,avg_pit_kcreate_z,avg_pit_bbprevent_z,avg_pit_impactlimit_z,avg_pit_barreldeny_z,avg_pit_stamina_z,hr_leader,hr_leader_name,avg_leader,avg_leader_name,ops_leader,ops_leader_name,era_leader,era_leader_name,k_leader,k_leader_name,retired,released,demoted,promoted,draft_picks,rookies,growers,decayers,camp_actions,camp_pitch_learning,post_active_players,post_draft_generated_ratio,post_seed_cohort_ratio")
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
		lines.append("%d,%d,%d,%d,%.4f,%d,%d,%.4f,%d,%d,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.0f,%s,%.3f,%s,%.3f,%s,%.2f,%s,%.0f,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.4f,%.4f" % [
			int(row.get("season_index", 0)),
			int(row.get("year", 0)),
			int(roster.get("active_players", 0)),
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
			_csv_text(_leader_name(leaderboards, "batting", "home_runs")),
			_leader_value(leaderboards, "batting", "average"),
			_csv_text(_leader_name(leaderboards, "batting", "average")),
			_leader_value(leaderboards, "batting", "ops"),
			_csv_text(_leader_name(leaderboards, "batting", "ops")),
			_leader_value(leaderboards, "pitching", "era"),
			_csv_text(_leader_name(leaderboards, "pitching", "era")),
			_leader_value(leaderboards, "pitching", "strikeouts"),
			_csv_text(_leader_name(leaderboards, "pitching", "strikeouts")),
			int(offseason.get("retired_count", 0)),
			int(offseason.get("released_count", 0)),
			int(offseason.get("demoted_count", 0)),
			int(offseason.get("promoted_count", 0)),
			int(offseason.get("draft_picks_count", 0)),
			int(offseason.get("rookies_count", 0)),
			int(offseason.get("growers_count", 0)),
			int(offseason.get("decayers_count", 0)),
			int(offseason.get("camp_actions_count", 0)),
			int(offseason.get("camp_pitch_learning_count", 0)),
			int(post_roster.get("active_players", 0)),
			float(post_roster.get("draft_generated_ratio", 0.0)),
			float(post_roster.get("seed_cohort_ratio", 0.0)),
		])
	return "\n".join(lines)


func _run_auto_offseason(season: PSSeason, selected_team_id: int) -> Dictionary:
	var retirement_result: Dictionary = OffseasonService.process_retirement(GameDb.players, season)
	GameDb.rebuild_player_indices()

	# R4/R5/R7 調整: 順番は 戦力外 → ドラフト → 戦力外獲得 → FA → 外国人 → キャンプ → 成長。
	# 戦力外: 先に外国人 (別基準: 4枠 + 能力バー) を確定し、その後日本人を外国人込み総数 60 まで詰める
	# (残す外国人が多いほど日本人を多く切る)。
	var foreign_release_result: Dictionary = OffseasonService.process_foreign_releases(GameDb.players, GameDb.teams, season)
	GameDb.rebuild_player_indices()
	var release_result: Dictionary = OffseasonService.process_cpu_releases(GameDb.players, GameDb.teams, 0, season)
	GameDb.rebuild_player_indices()
	var merged_release_result: Dictionary = release_result.duplicate(true)
	var merged_released: Array = []
	merged_released.append_array(release_result.get("released", []) as Array)
	merged_released.append_array(foreign_release_result.get("released", []) as Array)
	merged_release_result["released"] = merged_released

	# ドラフト (日本人 66 枠まで 6〜7 人補充)。
	var draft_state: Dictionary = DraftService.create_draft_state(GameDb.players, GameDb.teams, season, selected_team_id)
	var complete_result: Dictionary = DraftService.complete_automatically(draft_state)
	draft_state = complete_result.get("state", draft_state) as Dictionary
	var draft_result: Dictionary = {}
	if bool(draft_state.get("complete", false)):
		draft_result = DraftService.finalize_draft(draft_state, GameDb.players)
	GameDb.rebuild_player_indices()

	# 戦力外獲得 (ドラフト後FA前)。team_id が動くので再構築。
	var released_market_result: Dictionary = ReleasedMarketService.process_released_market(
		GameDb.players, GameDb.teams, season, merged_release_result, 0
	)
	GameDb.rebuild_player_indices()

	# FA市場 (戦力外獲得後)。team_id が動くので再構築。
	var fa_result: Dictionary = FaMarketService.process_fa_market(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	# 外国人補強 (FA後)。生成選手を外国人枠に追加。
	var foreign_result: Dictionary = ForeignPlayerService.process_foreign_market(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	var camp_result: Dictionary = CampServiceRef.process_camp(GameDb.players, GameDb.teams, season, 0)
	GameDb.rebuild_player_indices()

	var growth_result: Dictionary = OffseasonService.process_growth_decay(GameDb.players)
	GameDb.rebuild_player_indices()

	# roadmap #3: 育った育成選手を全球団自動で支配下登録 (長期検証では自軍も自動扱い)。
	var promotion_result: Dictionary = OffseasonService.process_development_promotions(GameDb.players, GameDb.teams, 0)
	GameDb.rebuild_player_indices()

	# 育成の整理 (失敗プロスペクト/枠超過を放出し pipeline を循環)。累積で player 数が膨れるのを防ぐ。
	var dev_release_result: Dictionary = OffseasonService.process_development_releases(GameDb.players, GameDb.teams, 0)
	GameDb.rebuild_player_indices()

	# R4 Step1: 契約更新 (年俸再査定 + FA権遷移 + 予算会計)。長期検証で FA権到達が累積するよう
	# 実フローと同様 advance_players_one_year の直前に実行する。
	var contract_result: Dictionary = OffseasonService.process_contract_update(GameDb.players, GameDb.teams, season)

	return {
		"retired_count": int(retirement_result.get("retired_count", 0)),
		"released_count": int(release_result.get("released_count", 0)),
		"demoted_count": int(release_result.get("demoted_count", 0)),
		"promoted_count": int(promotion_result.get("promoted_count", 0)),
		"dev_released_count": int(dev_release_result.get("released_count", 0)),
		"draft_complete": bool(draft_state.get("complete", false)),
		"draft_picks_count": (draft_state.get("picks", []) as Array).size(),
		"rookies_count": int(draft_result.get("rookies_count", 0)),
		"priority_league": str(draft_result.get("priority_league", draft_state.get("priority_league", ""))),
		"growers_count": int(growth_result.get("growers_count", 0)),
		"decayers_count": int(growth_result.get("decayers_count", 0)),
		"growth_kind_counts": (growth_result.get("growth_kind_counts", {}) as Dictionary).duplicate(true),
		"new_fa_count": int(contract_result.get("new_fa_count", 0)),
		"over_budget_count": int(contract_result.get("over_budget_count", 0)),
		"fa_moved_count": int(fa_result.get("moved_count", 0)),
		"fa_declared_count": int(fa_result.get("declared_count", 0)),
		"released_signed_count": int(released_market_result.get("signed_count", 0)),
		"released_candidates_count": int(released_market_result.get("candidates_count", 0)),
		"foreign_signed_count": int(foreign_result.get("signed_count", 0)),
		"foreign_released_count": int(foreign_release_result.get("released_count", 0)),
		"camp_actions_count": int(camp_result.get("actions_count", 0)),
		"camp_pitch_learning_count": int(camp_result.get("normal_pitch_learning_count", 0)),
	}


func _leaderboards_for_season(season: PSSeason) -> Dictionary:
	var records: Array = _records_for_season(season)
	var team_by_id: Dictionary = _team_by_id()
	var max_games: int = _max_team_games(season)
	var qualifier_pa: int = int(max(1.0, ceil(QUALIFIER_PA_PER_GAME * float(max_games))))
	var qualifier_outs: int = int(max(1.0, ceil(QUALIFIER_OUTS_PER_GAME * float(max_games))))
	return {
		"qualifier_pa": qualifier_pa,
		"qualifier_outs": qualifier_outs,
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
	var draft_generated_players: int = 0
	var seed_cohort_players: int = 0
	var total_age: int = 0
	var total_overall: int = 0
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
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		by_team[str(team.id)] = 0

	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not _is_active_roster_player(player):
			continue
		active_players += 1
		total_age += player.age
		var overall: int = OffseasonService.player_value_score(player)
		total_overall += overall
		overall_values.append(overall)
		age_values.append(player.age)
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
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		team_counts.append(int(by_team.get(str(team.id), 0)))

	return {
		"player_rows_total": players.size(),
		"active_players": active_players,
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
		"team_roster_min": int(_min_value(team_counts)),
		"team_roster_average": _round_float(_mean(team_counts), 2),
		"team_roster_max": int(_max_value(team_counts)),
		"team_rosters": by_team,
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
		"era": _round_float(_mean_nested(rows, ["season", "pitching", "era"]), 2),
		"whip": _round_float(_mean_nested(rows, ["season", "pitching", "whip"]), 3),
		"strikeouts_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "strikeouts_per_nine"]), 2),
		"walks_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "walks_per_nine"]), 2),
		"home_runs_per_nine": _round_float(_mean_nested(rows, ["season", "pitching", "home_runs_per_nine"]), 2),
		"released_per_year": _round_float(_mean_nested(rows, ["offseason", "released_count"]), 2),
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
	if player.is_retired() or player.is_manager_candidate():
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
