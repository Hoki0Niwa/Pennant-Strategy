extends RefCounted
class_name SimulationReporter

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

const DEFAULT_SEASONS: int = 5
const DEFAULT_SELECTED_TEAM_ID: int = 1
const DEFAULT_START_YEAR: int = 2026
const BATTER_QUALIFIED_PLATE_APPEARANCES_PER_TEAM_GAME: float = 3.1
const PITCHER_QUALIFIED_OUTS_PER_TEAM_GAME: int = 3
const ADVANCED_LEAGUE_WOBA: float = 0.315
const ADVANCED_WOBA_SCALE: float = 1.20
const ADVANCED_LEAGUE_RUNS_PER_PA: float = 0.115
const POSITION_ADJUSTMENT_FULL_SEASON_OUTS: float = 162.0 * 27.0
const POSITION_ADJUSTMENT_RUNS_PER_162: Dictionary = {
	2: 12.5,
	3: -12.5,
	4: 2.5,
	5: 2.5,
	6: 7.5,
	7: -7.5,
	8: 2.5,
	9: -7.5,
}
# 1 アウト奪取の平均ラン価値 (FanGraphs UZR primer)。
# WAR の守備成分 (def_runs) は OAA × ADVANCED_RUN_PER_OUT + 守備位置補正 で算出する。
const ADVANCED_RUN_PER_OUT: float = 0.83


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

	var season_count: int = int(max(1, int(options.get("seasons", DEFAULT_SEASONS))))
	var selected_team_id: int = int(options.get("selected_team_id", DEFAULT_SELECTED_TEAM_ID))
	if selected_team_id <= 0 and not GameDb.teams.is_empty():
		var first_team: PSTeam = GameDb.teams[0] as PSTeam
		selected_team_id = first_team.id
	var start_year: int = int(options.get("start_year", DEFAULT_START_YEAR))
	var seed: int = int(options.get("seed", -1))
	var dh_by_league: Dictionary = _dh_settings_from_options(options)

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	# 永続化レイヤ v1: レポート中は RecordStore の中間状態 (各シーズン分の clear/再構築)
	# を新テーブルへ漏らさないため persistence を suspend する。
	RecordStore.suspend_persistence()
	if seed >= 0:
		Rng.set_seed_value(seed)

	var aggregate_batting: PSBatterStats = PSBatterStats.new()
	var aggregate_pitching: PSPitcherStats = PSPitcherStats.new()
	var aggregate_batted_ball: Dictionary = _empty_batted_ball_aggregate()
	var aggregate_advanced: Dictionary = _empty_advanced_aggregate()
	var total_games: int = 0
	var total_team_games: int = 0
	var total_runs: int = 0
	var completed_seasons: int = 0
	var season_summaries: Array = []
	var team_seasons: Array = []
	var batter_players: Array = []
	var pitcher_players: Array = []
	var errors: Array = []

	for season_index in range(season_count):
		var year: int = start_year + int(season_index)
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, selected_team_id, year, dh_by_league)
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		var simulation_result: Dictionary = GameSimulator.simulate_remaining_season(season, false)
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": year,
				"message": str(simulation_result.get("message", "")),
			})
			continue

		var season_report: Dictionary = _season_report(season)
		var season_batting: PSBatterStats = PSBatterStats.from_dict(season_report.get("batting_stats", {}) as Dictionary)
		var season_pitching: PSPitcherStats = PSPitcherStats.from_dict(season_report.get("pitching_stats", {}) as Dictionary)
		aggregate_batting.add_from(season_batting)
		aggregate_pitching.add_from(season_pitching)
		total_games += int(season_report.get("games", 0))
		total_team_games += int(season_report.get("team_games", 0))
		total_runs += int(season_report.get("runs", 0))
		_accumulate_batted_ball(aggregate_batted_ball, season_report.get("batted_ball_raw", {}) as Dictionary)
		_accumulate_advanced(aggregate_advanced, season_report.get("advanced_raw", {}) as Dictionary)
		completed_seasons += 1

		season_summaries.append(_public_season_summary(season_report))
		var team_rows: Array = season_report.get("teams", []) as Array
		for row in team_rows:
			team_seasons.append(row)
		_collect_player_stats(season.year, season.season_number, batter_players, pitcher_players, season_report.get("advanced_records", {}) as Dictionary)

	RecordStore.load_from_dict(original_records)
	# suspend を解除し、復元状態を 1 度だけ新テーブルへ flush して同期させる。
	RecordStore.resume_persistence()
	RecordStore.save_records()
	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	return {
		"version": 1,
		"seasons_requested": season_count,
		"seasons_completed": completed_seasons,
		"selected_team_id": selected_team_id,
		"start_year": start_year,
		"seed": seed,
		"league_dh_enabled": dh_by_league.duplicate(true),
		"data_source": GameDb.data_source,
		"team_count": GameDb.teams.size(),
		"player_count": GameDb.players.size(),
		"run_environment": {
			"games": total_games,
			"team_games": total_team_games,
			"runs": total_runs,
			"runs_per_team_game": _round_float(_safe_div(total_runs, total_team_games), 3),
			"runs_per_game_total": _round_float(_safe_div(total_runs, total_games), 3),
		},
		"batting": _batting_summary(aggregate_batting, total_games),
		"pitching": _pitching_summary(aggregate_pitching),
		"batted_ball": _batted_ball_summary(aggregate_batted_ball),
		"advanced": _advanced_summary(aggregate_advanced),
		"season_summaries": season_summaries,
		"team_seasons": team_seasons,
		"player_stats": {
			"batters": batter_players,
			"pitchers": pitcher_players,
		},
		"errors": errors,
	}


# --- async 版 (UI フリーズ対策) ---
# 同期版 run() と同じ集計を行うが、各シーズンを GameSimulator の async 版で進めることで
# 試合間に必ず 1 フレ yield + キャンセル確認する。
# options に "scene_tree" / "progress_callback" / "cancel_token" を渡す。
func run_async(options: Dictionary = {}) -> Dictionary:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var season_count: int = int(max(1, int(options.get("seasons", DEFAULT_SEASONS))))
	var selected_team_id: int = int(options.get("selected_team_id", DEFAULT_SELECTED_TEAM_ID))
	if selected_team_id <= 0 and not GameDb.teams.is_empty():
		var first_team: PSTeam = GameDb.teams[0] as PSTeam
		selected_team_id = first_team.id
	var start_year: int = int(options.get("start_year", DEFAULT_START_YEAR))
	var seed: int = int(options.get("seed", -1))
	var dh_by_league: Dictionary = _dh_settings_from_options(options)

	var tree: SceneTree = options.get("scene_tree") as SceneTree
	var outer_progress_cb: Callable = options.get("progress_callback", Callable())
	var cancel_token: Dictionary = options.get("cancel_token", {})

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_rng_seed: int = Rng.current_seed
	var original_rng_state: int = Rng.generator.state
	# 永続化レイヤ v1: レポート中は RecordStore の中間状態を新テーブルへ漏らさない。
	RecordStore.suspend_persistence()
	if seed >= 0:
		Rng.set_seed_value(seed)

	var aggregate_batting: PSBatterStats = PSBatterStats.new()
	var aggregate_pitching: PSPitcherStats = PSPitcherStats.new()
	var aggregate_batted_ball: Dictionary = _empty_batted_ball_aggregate()
	var aggregate_advanced: Dictionary = _empty_advanced_aggregate()
	var total_games: int = 0
	var total_team_games: int = 0
	var total_runs: int = 0
	var completed_seasons: int = 0
	var season_summaries: Array = []
	var team_seasons: Array = []
	var batter_players: Array = []
	var pitcher_players: Array = []
	var errors: Array = []

	for season_index in range(season_count):
		if not cancel_token.is_empty() and bool(cancel_token.get("cancelled", false)):
			break
		var year: int = start_year + int(season_index)
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, selected_team_id, year, dh_by_league)
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		# シーズンごとに進捗 cb をラップして「N/M シーズン」を一緒に表示する
		var season_label: String = "シーズン %d/%d (%d年)" % [season_index + 1, season_count, year]
		var inner_cb: Callable = Callable()
		if outer_progress_cb.is_valid():
			inner_cb = func(done: int, total: int, _inner_label: String) -> void:
				outer_progress_cb.call(done, total, season_label)
		var simulation_result: Dictionary = await GameSimulator.simulate_remaining_season_async(
			season, false, {}, tree, inner_cb, cancel_token
		)
		if not bool(simulation_result.get("ok", false)):
			errors.append({
				"year": year,
				"message": str(simulation_result.get("message", "")),
			})
			continue

		var season_report: Dictionary = _season_report(season)
		var season_batting: PSBatterStats = PSBatterStats.from_dict(season_report.get("batting_stats", {}) as Dictionary)
		var season_pitching: PSPitcherStats = PSPitcherStats.from_dict(season_report.get("pitching_stats", {}) as Dictionary)
		aggregate_batting.add_from(season_batting)
		aggregate_pitching.add_from(season_pitching)
		total_games += int(season_report.get("games", 0))
		total_team_games += int(season_report.get("team_games", 0))
		total_runs += int(season_report.get("runs", 0))
		_accumulate_batted_ball(aggregate_batted_ball, season_report.get("batted_ball_raw", {}) as Dictionary)
		_accumulate_advanced(aggregate_advanced, season_report.get("advanced_raw", {}) as Dictionary)
		completed_seasons += 1

		season_summaries.append(_public_season_summary(season_report))
		var team_rows: Array = season_report.get("teams", []) as Array
		for row in team_rows:
			team_seasons.append(row)
		_collect_player_stats(season.year, season.season_number, batter_players, pitcher_players, season_report.get("advanced_records", {}) as Dictionary)
		if bool(simulation_result.get("cancelled", false)):
			break

	RecordStore.load_from_dict(original_records)
	# suspend を解除し、復元状態を 1 度だけ新テーブルへ flush して同期させる。
	RecordStore.resume_persistence()
	RecordStore.save_records()
	Rng.current_seed = original_rng_seed
	Rng.generator.seed = original_rng_seed
	Rng.generator.state = original_rng_state

	var cancelled: bool = not cancel_token.is_empty() and bool(cancel_token.get("cancelled", false))
	return {
		"version": 1,
		"seasons_requested": season_count,
		"seasons_completed": completed_seasons,
		"cancelled": cancelled,
		"selected_team_id": selected_team_id,
		"start_year": start_year,
		"seed": seed,
		"league_dh_enabled": dh_by_league.duplicate(true),
		"data_source": GameDb.data_source,
		"team_count": GameDb.teams.size(),
		"player_count": GameDb.players.size(),
		"run_environment": {
			"games": total_games,
			"team_games": total_team_games,
			"runs": total_runs,
			"runs_per_team_game": _round_float(_safe_div(total_runs, total_team_games), 3),
			"runs_per_game_total": _round_float(_safe_div(total_runs, total_games), 3),
		},
		"batting": _batting_summary(aggregate_batting, total_games),
		"pitching": _pitching_summary(aggregate_pitching),
		"batted_ball": _batted_ball_summary(aggregate_batted_ball),
		"advanced": _advanced_summary(aggregate_advanced),
		"season_summaries": season_summaries,
		"team_seasons": team_seasons,
		"player_stats": {
			"batters": batter_players,
			"pitchers": pitcher_players,
		},
		"errors": errors,
	}


func _season_report(season: PSSeason) -> Dictionary:
	var batting_total: PSBatterStats = PSBatterStats.new()
	var pitching_total: PSPitcherStats = PSPitcherStats.new()
	var team_rows: Array = []
	var total_team_games: int = 0
	var total_runs: int = 0

	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(team.id, season.year, season.season_number)
		if team_record == null:
			continue
		var team_batting: PSBatterStats = _team_batter_stats(team.id, season.year, season.season_number)
		var team_pitching: PSPitcherStats = _team_pitcher_stats(team.id, season.year, season.season_number)
		batting_total.add_from(team_batting)
		pitching_total.add_from(team_pitching)
		total_team_games += team_record.stats.games
		total_runs += team_record.stats.runs_scored
		team_rows.append(_team_report_row(team_record, team_batting, team_pitching))

	var total_games: int = int(total_team_games / 2)
	var batted_ball_raw: Dictionary = _batted_ball_aggregate_for_season(season)
	var advanced_raw: Dictionary = _advanced_aggregate_for_season(season)
	var advanced_records: Dictionary = _advanced_records_for_season(season)
	return {
		"year": season.year,
		"season_number": season.season_number,
		"games": total_games,
		"team_games": total_team_games,
		"runs": total_runs,
		"runs_per_team_game": _round_float(_safe_div(total_runs, total_team_games), 3),
		"runs_per_game_total": _round_float(_safe_div(total_runs, total_games), 3),
		"batting": _batting_summary(batting_total, total_games),
		"pitching": _pitching_summary(pitching_total),
		"batted_ball": _batted_ball_summary(batted_ball_raw),
		"batted_ball_raw": batted_ball_raw,
		"advanced": _advanced_summary(advanced_raw),
		"advanced_raw": advanced_raw,
		"advanced_records": advanced_records,
		"batting_stats": batting_total.to_dict(),
		"pitching_stats": pitching_total.to_dict(),
		"teams": team_rows,
	}


func _public_season_summary(season_report: Dictionary) -> Dictionary:
	return {
		"year": int(season_report.get("year", 0)),
		"games": int(season_report.get("games", 0)),
		"runs": int(season_report.get("runs", 0)),
		"runs_per_team_game": float(season_report.get("runs_per_team_game", 0.0)),
		"runs_per_game_total": float(season_report.get("runs_per_game_total", 0.0)),
		"batting": season_report.get("batting", {}) as Dictionary,
		"pitching": season_report.get("pitching", {}) as Dictionary,
		"batted_ball": season_report.get("batted_ball", {}) as Dictionary,
		"advanced": season_report.get("advanced", {}) as Dictionary,
	}


func _team_report_row(team_record: PSTeamSeasonRecord, batting: PSBatterStats, pitching: PSPitcherStats) -> Dictionary:
	var games: int = team_record.stats.games
	return {
		"year": team_record.year,
		"team_id": team_record.team_id,
		"team": team_record.name,
		"league": team_record.league,
		"games": games,
		"wins": team_record.stats.wins,
		"losses": team_record.stats.losses,
		"draws": team_record.stats.draws,
		"win_rate": _round_float(team_record.stats.win_rate(), 3),
		"runs_scored": team_record.stats.runs_scored,
		"runs_allowed": team_record.stats.runs_allowed,
		"runs_per_game": _round_float(_safe_div(team_record.stats.runs_scored, games), 3),
		"runs_allowed_per_game": _round_float(_safe_div(team_record.stats.runs_allowed, games), 3),
		"batting_average": _round_float(batting.batting_average(), 3),
		"on_base_percentage": _round_float(batting.on_base_percentage(), 3),
		"slugging_percentage": _round_float(batting.slugging_percentage(), 3),
		"ops": _round_float(batting.ops(), 3),
		"pitches_per_plate_appearance": _round_float(_safe_div(batting.pitches_seen, batting.plate_appearances), 2),
		"home_runs": batting.home_runs,
		"home_runs_per_game": _round_float(_safe_div(batting.home_runs, games), 3),
		"stolen_bases": batting.stolen_bases,
		"stolen_bases_per_game": _round_float(_safe_div(batting.stolen_bases, games), 3),
		"era": _round_float(pitching.era(), 2),
		"whip": _round_float(pitching.whip(), 3),
		"strikeouts_per_nine": _round_float(pitching.strikeouts_per_nine(), 2),
		"pitches_per_inning": _round_float(_per_nine(pitching.pitches_thrown, pitching.outs_pitched) / 9.0, 1),
	}


func _team_batter_stats(team_id: int, year: int, season_number: int) -> PSBatterStats:
	var stats: PSBatterStats = PSBatterStats.new()
	var records: Array = RecordStore.get_team_player_records(team_id, year, season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		stats.add_from(record.batter_stats)
	return stats


func _team_pitcher_stats(team_id: int, year: int, season_number: int) -> PSPitcherStats:
	var stats: PSPitcherStats = PSPitcherStats.new()
	var records: Array = RecordStore.get_team_player_records(team_id, year, season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			stats.add_from(record.pitcher_stats)
	return stats


func _collect_player_stats(
	year: int,
	season_number: int,
	batter_players: Array,
	pitcher_players: Array,
	advanced_raw: Dictionary = {}
) -> void:
	var player_advanced: Dictionary = advanced_raw.get("players", {}) as Dictionary
	var pitcher_advanced: Dictionary = advanced_raw.get("pitchers", {}) as Dictionary
	# WAR 計算用リーグ context を 1 度だけ構築 (全選手 advanced_stats 集計)。
	var war_ctx: Dictionary = WarCalculator.build_league_context(year, season_number)
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.year != year or record.season_number != season_number:
			continue

		var fielding_advanced_record: Dictionary = player_advanced.get(str(record.player_id), {}) as Dictionary
		# 守備指標(OAA/UZR)はポジション別ゼロセンタリング後の値を表示する（リーグ平均0基準）。
		fielding_advanced_record.merge(WarCalculator.recenter_fielding(fielding_advanced_record, war_ctx), true)
		var war_row: Dictionary = WarCalculator.season_war(record, war_ctx)
		if record.is_pitcher():
			if _qualified_pitcher(record):
				var pitcher_advanced_record: Dictionary = pitcher_advanced.get(str(record.player_id), {}) as Dictionary
				var row: Dictionary = _pitcher_player_row(record, pitcher_advanced_record, fielding_advanced_record)
				_merge_war_row_into(row, war_row, false)
				pitcher_players.append(row)
			continue

		if _qualified_batter(record):
			var row: Dictionary = _batter_player_row(record, fielding_advanced_record)
			_merge_war_row_into(row, war_row, true)
			batter_players.append(row)


# WAR 行 (WarCalculator.season_war の出力) をプレイヤーレポート行へマージする。
# 投手は fip / war / raa など、野手は war / wraa / oaa_runs / pos_adj / replacement_runs など。
func _merge_war_row_into(row: Dictionary, war_row: Dictionary, is_batter: bool) -> void:
	if war_row.is_empty():
		return
	row["war"] = float(war_row.get("war", 0.0))
	row["war_role"] = str(war_row.get("role", ""))
	if is_batter:
		row["war_wraa"] = float(war_row.get("wraa", 0.0))
		row["war_bsr"] = float(war_row.get("bsr", 0.0))
		row["war_oaa_runs"] = float(war_row.get("oaa_runs", 0.0))
		row["war_pos_adj"] = float(war_row.get("pos_adj", 0.0))
		row["war_replacement_runs"] = float(war_row.get("replacement_runs", 0.0))
	else:
		row["fip"] = float(war_row.get("fip", 0.0))
		row["war_raa"] = float(war_row.get("raa", 0.0))
		row["war_replacement_factor"] = float(war_row.get("replacement_factor", 0.0))


func _qualified_batter(record: PSPlayerSeasonRecord) -> bool:
	var required_plate_appearances: int = _required_plate_appearances(record)
	return required_plate_appearances > 0 and record.batter_stats.plate_appearances >= required_plate_appearances


func _qualified_pitcher(record: PSPlayerSeasonRecord) -> bool:
	var required_outs: int = _required_pitcher_outs(record)
	return required_outs > 0 and record.pitcher_stats.outs_pitched >= required_outs


func _required_plate_appearances(record: PSPlayerSeasonRecord) -> int:
	var team_games: int = _team_games_for_record(record)
	return int(ceil(float(team_games) * BATTER_QUALIFIED_PLATE_APPEARANCES_PER_TEAM_GAME))


func _required_pitcher_outs(record: PSPlayerSeasonRecord) -> int:
	var team_games: int = _team_games_for_record(record)
	return team_games * PITCHER_QUALIFIED_OUTS_PER_TEAM_GAME


func _team_games_for_record(record: PSPlayerSeasonRecord) -> int:
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(record.team_id, record.year, record.season_number)
	if team_record == null:
		return 0
	return team_record.stats.games


func _batter_player_row(record: PSPlayerSeasonRecord, advanced_record: Dictionary = {}) -> Dictionary:
	var stats: PSBatterStats = record.batter_stats
	var row: Dictionary = {
		"year": record.year,
		"team_id": record.team_id,
		"team": _team_name(record.team_id),
		"player_id": record.player_id,
		"name": record.name,
		"position": _position_name(record.position),
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
		"stolen_base_attempts": stats.stolen_base_attempts,
		"stolen_bases": stats.stolen_bases,
		"sacrifices": stats.sacrifices,
		"sacrifice_flies": stats.sacrifice_flies,
		"double_plays": stats.double_plays,
		"errors": stats.errors,
		"batting_average": _round_float(stats.batting_average(), 3),
		"on_base_percentage": _round_float(stats.on_base_percentage(), 3),
		"slugging_percentage": _round_float(stats.slugging_percentage(), 3),
		"ops": _round_float(stats.ops(), 3),
		"isolated_power": _round_float(_isolated_power(stats), 3),
		"contact_result": _round_float(_batter_contact_result(stats), 3),
		"strikeout_rate": _round_float(_safe_div(stats.strikeouts, stats.plate_appearances), 3),
		"walk_rate": _round_float(_safe_div(stats.walks, stats.plate_appearances), 3),
		"walks_per_strikeout": _round_float(_safe_div(stats.walks, stats.strikeouts), 3),
		"plate_appearances_per_strikeout": _round_float(_safe_div(stats.plate_appearances, stats.strikeouts), 2),
		"pitches_per_plate_appearance": _round_float(_safe_div(stats.pitches_seen, stats.plate_appearances), 2),
		"home_run_rate": _round_float(_safe_div(stats.home_runs, stats.plate_appearances), 3),
		"stolen_base_success_rate": _round_float(_safe_div(stats.stolen_bases, stats.stolen_base_attempts), 3),
		"contact_rate": _round_float(1.0 - _safe_div(stats.strikeouts, stats.plate_appearances), 3),
		"overall": PlayerValueEvaluator.overall_score(record),
	}
	# 能力は z キー (pa_*) と表示能力 (display_*/visible_*) のみを出力する。
	row.merge(_pa_ability_row(record), true)
	row.merge(_display_rating_row(record), true)
	row.merge(_advanced_batter_row(advanced_record), true)
	return row


func _pitcher_player_row(record: PSPlayerSeasonRecord, advanced_record: Dictionary = {}, fielding_advanced_record: Dictionary = {}) -> Dictionary:
	var stats: PSPitcherStats = record.pitcher_stats
	var row: Dictionary = {
		"year": record.year,
		"team_id": record.team_id,
		"team": _team_name(record.team_id),
		"player_id": record.player_id,
		"name": record.name,
		"games": stats.games,
		"starts": stats.starts,
		"relief_appearances": stats.relief_appearances,
		"wins": stats.wins,
		"losses": stats.losses,
		"holds": stats.holds,
		"saves": stats.saves,
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
		"quality_starts": stats.quality_starts,
		"era": _round_float(stats.era(), 2),
		"whip": _round_float(stats.whip(), 3),
		"strikeouts_per_nine": _round_float(stats.strikeouts_per_nine(), 2),
		"walks_per_nine": _round_float(_per_nine(stats.walks, stats.outs_pitched), 2),
		"home_runs_per_nine": _round_float(_per_nine(stats.home_runs_allowed, stats.outs_pitched), 2),
		"hits_per_nine": _round_float(_per_nine(stats.hits_allowed, stats.outs_pitched), 2),
		"strikeout_rate": _round_float(_safe_div(stats.strikeouts, stats.batters_faced), 3),
		"walk_rate": _round_float(_safe_div(stats.walks, stats.batters_faced), 3),
		"strikeout_minus_walk_rate": _round_float(_safe_div(stats.strikeouts, stats.batters_faced) - _safe_div(stats.walks, stats.batters_faced), 3),
		"strikeouts_per_walk": _round_float(_safe_div(stats.strikeouts, stats.walks), 3),
		"pitches_per_batter_faced": _round_float(_safe_div(stats.pitches_thrown, stats.batters_faced), 2),
		"pitches_per_inning": _round_float(_per_nine(stats.pitches_thrown, stats.outs_pitched) / 9.0, 1),
		"overall": PlayerValueEvaluator.overall_score(record),
	}
	# 能力は z キー (pa_*) と表示能力 (display_*/visible_*) のみを出力する。
	row.merge(_pa_ability_row(record), true)
	row.merge(_display_rating_row(record), true)
	row.merge(_advanced_pitcher_row(advanced_record), true)
	row.merge(_advanced_fielding_row(fielding_advanced_record), true)
	return row


func _pa_ability_row(record: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"pa_bat_k_avoid": _z_value(record, "Bat_KAvoid"),
		"pa_bat_bb_create": _z_value(record, "Bat_BBCreate"),
		"pa_bat_impact": _z_value(record, "Bat_Impact"),
		"pa_bat_loft": _z_value(record, "Bat_Loft"),
		"pa_bat_barrel": _z_value(record, "Bat_Barrel"),
		"pa_bat_spray": _z_value(record, "Bat_Spray"),
		"pa_bat_aggression": _z_value(record, "Bat_Aggression"),
		"pa_bat_platoon": _z_value(record, "Bat_Platoon"),
		"pa_run_speed": _z_value(record, "Run_Speed"),
		"pa_pit_k_create": _z_value(record, "Pit_KCreate"),
		"pa_pit_bb_prevent": _z_value(record, "Pit_BBPrevent"),
		"pa_pit_impact_limit": _z_value(record, "Pit_ImpactLimit"),
		"pa_pit_loft_control": _z_value(record, "Pit_LoftControl"),
		"pa_pit_barrel_deny": _z_value(record, "Pit_BarrelDeny"),
		"pa_pit_efficiency": _z_value(record, "Pit_Efficiency"),
		"pa_pit_stamina": _z_value(record, "Pit_Stamina"),
		"pa_pit_fatigue_resist": _z_value(record, "Pit_FatigueResist"),
		"pa_pit_hold_runner": _z_value(record, "Pit_HoldRunner"),
		"pa_pit_edge_rate": _z_value(record, "Pit_EdgeRate"),
	}


func _display_rating_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var display_contact: int = PlayerVisibleRatings.fielder_contact(record)
	var display_power: int = PlayerVisibleRatings.fielder_power(record)
	var display_speed: int = PlayerVisibleRatings.fielder_speed(record)
	var display_defense: int = PlayerVisibleRatings.fielder_defense(record)
	var display_arm: int = PlayerVisibleRatings.fielder_arm(record)
	var display_discipline: int = PlayerVisibleRatings.fielder_discipline(record)
	var display_velocity: int = PlayerVisibleRatings.pitcher_velocity(record)
	var display_stuff: int = PlayerVisibleRatings.pitcher_stuff(record)
	var display_control: int = PlayerVisibleRatings.pitcher_control(record)
	var display_stamina: int = PlayerVisibleRatings.pitcher_stamina(record)
	return {
		"display_contact": display_contact,
		"display_power": display_power,
		"display_speed": display_speed,
		"display_defense": display_defense,
		"display_arm": display_arm,
		"display_discipline": display_discipline,
		"display_velocity": display_velocity,
		"display_stuff": display_stuff,
		"display_control": display_control,
		"display_stamina": display_stamina,
		"visible_contact": display_contact,
		"visible_power": display_power,
		"visible_speed": display_speed,
		"visible_defense": display_defense,
		"visible_arm": display_arm,
		"visible_discipline": display_discipline,
		"visible_velocity": display_velocity,
		"visible_stuff": display_stuff,
		"visible_control": display_control,
		"visible_stamina": display_stamina,
	}


func _z_value(record: PSPlayerSeasonRecord, key: String) -> float:
	if record == null:
		return 0.0
	return _round_float(record.z_ability(key, 0.0), 3)


func _advanced_batter_row(record: Dictionary) -> Dictionary:
	var row: Dictionary = {
		"advanced_plate_appearances": int(record.get("plate_appearances", 0)),
		"woba": float(record.get("woba", 0.0)),
		"xwoba": float(record.get("xwoba", 0.0)),
		"wrc_plus": float(record.get("wrc_plus", 0.0)),
		"re24": float(record.get("re24", 0.0)),
		"bsr": float(record.get("bsr", 0.0)),
	}
	row.merge(_advanced_fielding_row(record), true)
	return row


func _advanced_pitcher_row(record: Dictionary) -> Dictionary:
	return {
		"advanced_batters_faced": int(record.get("plate_appearances", 0)),
		"woba_allowed": float(record.get("woba", 0.0)),
		"xwoba_allowed": float(record.get("xwoba", 0.0)),
		"wrc_plus_allowed": float(record.get("wrc_plus", 0.0)),
		"re24_allowed": float(record.get("re24", 0.0)),
		"woba": float(record.get("woba", 0.0)),
		"xwoba": float(record.get("xwoba", 0.0)),
		"wrc_plus": float(record.get("wrc_plus", 0.0)),
		"re24": float(record.get("re24", 0.0)),
	}


func _advanced_fielding_row(record: Dictionary) -> Dictionary:
	var row: Dictionary = {
		"fielding_chances": int(record.get("fielding_chances", 0)),
		"fielding_outs": int(record.get("fielding_outs", 0)),
		"fielding_chances_by_position": record.get("fielding_chances_by_position", {}),
		"fielding_chances_by_oaa_zone": record.get("fielding_chances_by_oaa_zone", {}),
		"fielding_outs_by_position": record.get("fielding_outs_by_position", {}),
		"fielding_outs_by_oaa_zone": record.get("fielding_outs_by_oaa_zone", {}),
		"defensive_outs_by_position": record.get("defensive_outs_by_position", {}),
		"defensive_outs_by_oaa_zone": record.get("defensive_outs_by_oaa_zone", {}),
		"primary_uzr_position": int(record.get("primary_uzr_position", 0)),
		"primary_oaa_zone": str(record.get("primary_oaa_zone", "")),
		"oaa_by_zone": record.get("oaa_by_zone", {}),
		"oaa_infield": float(record.get("oaa_infield", 0.0)),
		"oaa_outfield": float(record.get("oaa_outfield", 0.0)),
		"oaa": float(record.get("oaa", 0.0)),
		"rngr_by_position": record.get("rngr_by_position", {}),
		"errr_by_position": record.get("errr_by_position", {}),
		"dpr_by_position": record.get("dpr_by_position", {}),
		"uzr_by_position": record.get("uzr_by_position", {}),
		"drs_by_position": record.get("drs_by_position", {}),
		"rngr": float(record.get("rngr", 0.0)),
		"errr": float(record.get("errr", 0.0)),
		"dpr": float(record.get("dpr", 0.0)),
		"uzr": float(record.get("uzr", 0.0)),
		"drs": float(record.get("drs", 0.0)),
	}
	_apply_defense_value_adjustment(row)
	return row


func _batting_summary(stats: PSBatterStats, games: int) -> Dictionary:
	return {
		"games": games,
		"plate_appearances": stats.plate_appearances,
		"at_bats": stats.at_bats,
		"hits": stats.hits,
		"doubles": stats.doubles,
		"triples": stats.triples,
		"home_runs": stats.home_runs,
		"walks": stats.walks,
		"hit_by_pitches": stats.hit_by_pitches,
		"strikeouts": stats.strikeouts,
		"pitches_seen": stats.pitches_seen,
		"stolen_base_attempts": stats.stolen_base_attempts,
		"stolen_bases": stats.stolen_bases,
		"errors": stats.errors,
		"batting_average": _round_float(stats.batting_average(), 3),
		"on_base_percentage": _round_float(stats.on_base_percentage(), 3),
		"slugging_percentage": _round_float(stats.slugging_percentage(), 3),
		"ops": _round_float(stats.ops(), 3),
		"home_runs_per_game": _round_float(_safe_div(stats.home_runs, games), 3),
		"stolen_bases_per_game": _round_float(_safe_div(stats.stolen_bases, games), 3),
		"stolen_base_attempts_per_game": _round_float(_safe_div(stats.stolen_base_attempts, games), 3),
		"stolen_base_success_rate": _round_float(_safe_div(stats.stolen_bases, stats.stolen_base_attempts), 3),
		"walks_per_game": _round_float(_safe_div(stats.walks, games), 3),
		"strikeouts_per_game": _round_float(_safe_div(stats.strikeouts, games), 3),
		"pitches_per_plate_appearance": _round_float(_safe_div(stats.pitches_seen, stats.plate_appearances), 2),
	}


func _pitching_summary(stats: PSPitcherStats) -> Dictionary:
	return {
		"games": stats.games,
		"starts": stats.starts,
		"relief_appearances": stats.relief_appearances,
		"wins": stats.wins,
		"losses": stats.losses,
		"holds": stats.holds,
		"saves": stats.saves,
		"complete_games": stats.complete_games,
		"shutouts": stats.shutouts,
		"quality_starts": stats.quality_starts,
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
		"era": _round_float(stats.era(), 2),
		"whip": _round_float(stats.whip(), 3),
		"strikeouts_per_nine": _round_float(stats.strikeouts_per_nine(), 2),
		"walks_per_nine": _round_float(_per_nine(stats.walks, stats.outs_pitched), 2),
		"home_runs_per_nine": _round_float(_per_nine(stats.home_runs_allowed, stats.outs_pitched), 2),
		"hits_per_nine": _round_float(_per_nine(stats.hits_allowed, stats.outs_pitched), 2),
		"pitches_per_batter_faced": _round_float(_safe_div(stats.pitches_thrown, stats.batters_faced), 2),
		"pitches_per_inning": _round_float(_per_nine(stats.pitches_thrown, stats.outs_pitched) / 9.0, 1),
	}


func _advanced_aggregate_for_season(season: PSSeason) -> Dictionary:
	var aggregate: Dictionary = _empty_advanced_aggregate()
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var result: Dictionary = game.get("result", {}) as Dictionary
		var advanced_stats: Dictionary = result.get("advanced_stats", {}) as Dictionary
		if advanced_stats.is_empty():
			continue
		_accumulate_advanced_stats(aggregate, advanced_stats)
	return aggregate


func _advanced_records_for_season(season: PSSeason) -> Dictionary:
	var records: Dictionary = {
		"players": {},
		"pitchers": {},
	}
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var result: Dictionary = game.get("result", {}) as Dictionary
		var advanced_stats: Dictionary = result.get("advanced_stats", {}) as Dictionary
		if advanced_stats.is_empty():
			continue
		_accumulate_advanced_record_maps(records, advanced_stats)
	return records


func _accumulate_advanced_record_maps(target: Dictionary, advanced_stats: Dictionary) -> void:
	for bucket_name in ["players", "pitchers"]:
		var target_bucket: Dictionary = target.get(bucket_name, {}) as Dictionary
		var source_bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		for key_value in source_bucket.keys():
			var key: String = str(key_value)
			var target_record = AdvancedStatsRecord.new()
			target_record.load_from_dict(target_bucket.get(key, {}) as Dictionary)
			var source_record = AdvancedStatsRecord.new()
			source_record.load_from_dict(source_bucket.get(key_value, {}) as Dictionary)
			if source_record.player_id == 0 and key.is_valid_int():
				source_record.player_id = int(key)
			if target_record.player_id == 0:
				target_record.player_id = source_record.player_id
			target_record.add_from(source_record)
			target_bucket[key] = target_record.to_dict()
		target[bucket_name] = target_bucket


func _empty_advanced_aggregate() -> Dictionary:
	return {
		"players": _empty_advanced_bucket_aggregate(),
		"pitchers": _empty_advanced_bucket_aggregate(),
	}


func _empty_advanced_bucket_aggregate() -> Dictionary:
	return {
		"records": 0,
		"plate_appearances": 0,
		"woba_denominator": 0,
		"xwoba_denominator": 0,
		"woba_numerator": 0.0,
		"xwoba_numerator": 0.0,
		"re24": 0.0,
		"bsr": 0.0,
		"fielding_chances": 0,
		"fielding_outs": 0,
		"fielding_chances_by_position": {},
		"fielding_chances_by_oaa_zone": {},
		"fielding_outs_by_position": {},
		"fielding_outs_by_oaa_zone": {},
		"defensive_outs_by_position": {},
		"defensive_outs_by_oaa_zone": {},
		"oaa_by_zone": {},
		"oaa": 0.0,
		"oaa_infield": 0.0,
		"oaa_outfield": 0.0,
		"rngr_by_position": {},
		"errr_by_position": {},
		"dpr_by_position": {},
		"uzr_by_position": {},
		"drs_by_position": {},
		"rngr": 0.0,
		"errr": 0.0,
		"dpr": 0.0,
		"uzr": 0.0,
		"drs": 0.0,
		"fielding_runs": 0.0,
		"oaa_total": 0.0,
		"oaa_runs": 0.0,
		"positional_adjustment_runs": 0.0,
		"def_runs": 0.0,
	}


func _accumulate_advanced_stats(target: Dictionary, advanced_stats: Dictionary) -> void:
	for bucket_name in ["players", "pitchers"]:
		var target_bucket: Dictionary = target.get(bucket_name, _empty_advanced_bucket_aggregate()) as Dictionary
		var source_bucket: Dictionary = advanced_stats.get(bucket_name, {}) as Dictionary
		target_bucket["records"] = int(target_bucket.get("records", 0)) + source_bucket.size()
		for record_value in source_bucket.values():
			var record: Dictionary = record_value as Dictionary
			target_bucket["plate_appearances"] = int(target_bucket.get("plate_appearances", 0)) + int(record.get("plate_appearances", 0))
			target_bucket["woba_denominator"] = int(target_bucket.get("woba_denominator", 0)) + int(record.get("woba_denominator", 0))
			target_bucket["xwoba_denominator"] = int(target_bucket.get("xwoba_denominator", 0)) + int(record.get("xwoba_denominator", 0))
			target_bucket["woba_numerator"] = float(target_bucket.get("woba_numerator", 0.0)) + float(record.get("woba_numerator", 0.0))
			target_bucket["xwoba_numerator"] = float(target_bucket.get("xwoba_numerator", 0.0)) + float(record.get("xwoba_numerator", 0.0))
			target_bucket["re24"] = float(target_bucket.get("re24", 0.0)) + float(record.get("re24", record.get("re24_sum", 0.0)))
			target_bucket["bsr"] = float(target_bucket.get("bsr", 0.0)) + float(record.get("bsr", record.get("bsr_sum", 0.0)))
			target_bucket["fielding_chances"] = int(target_bucket.get("fielding_chances", 0)) + int(record.get("fielding_chances", 0))
			target_bucket["fielding_outs"] = int(target_bucket.get("fielding_outs", 0)) + int(record.get("fielding_outs", 0))
			_merge_int_map(target_bucket.get("fielding_chances_by_position", {}) as Dictionary, record.get("fielding_chances_by_position", {}) as Dictionary, target_bucket, "fielding_chances_by_position")
			_merge_int_map(target_bucket.get("fielding_chances_by_oaa_zone", {}) as Dictionary, record.get("fielding_chances_by_oaa_zone", {}) as Dictionary, target_bucket, "fielding_chances_by_oaa_zone")
			_merge_int_map(target_bucket.get("fielding_outs_by_position", {}) as Dictionary, record.get("fielding_outs_by_position", {}) as Dictionary, target_bucket, "fielding_outs_by_position")
			_merge_int_map(target_bucket.get("fielding_outs_by_oaa_zone", {}) as Dictionary, record.get("fielding_outs_by_oaa_zone", {}) as Dictionary, target_bucket, "fielding_outs_by_oaa_zone")
			_merge_int_map(target_bucket.get("defensive_outs_by_position", {}) as Dictionary, record.get("defensive_outs_by_position", {}) as Dictionary, target_bucket, "defensive_outs_by_position")
			_merge_int_map(target_bucket.get("defensive_outs_by_oaa_zone", {}) as Dictionary, record.get("defensive_outs_by_oaa_zone", {}) as Dictionary, target_bucket, "defensive_outs_by_oaa_zone")
			_merge_float_map(target_bucket.get("oaa_by_zone", {}) as Dictionary, record.get("oaa_by_zone", {}) as Dictionary, target_bucket, "oaa_by_zone")
			_merge_float_map(target_bucket.get("rngr_by_position", {}) as Dictionary, record.get("rngr_by_position", {}) as Dictionary, target_bucket, "rngr_by_position")
			_merge_float_map(target_bucket.get("errr_by_position", {}) as Dictionary, record.get("errr_by_position", {}) as Dictionary, target_bucket, "errr_by_position")
			_merge_float_map(target_bucket.get("dpr_by_position", {}) as Dictionary, record.get("dpr_by_position", {}) as Dictionary, target_bucket, "dpr_by_position")
			_merge_float_map(target_bucket.get("uzr_by_position", {}) as Dictionary, record.get("uzr_by_position", {}) as Dictionary, target_bucket, "uzr_by_position")
			_merge_float_map(target_bucket.get("drs_by_position", {}) as Dictionary, record.get("drs_by_position", {}) as Dictionary, target_bucket, "drs_by_position")
		target[bucket_name] = target_bucket


func _accumulate_advanced(target: Dictionary, source: Dictionary) -> void:
	for bucket_name in ["players", "pitchers"]:
		var target_bucket: Dictionary = target.get(bucket_name, _empty_advanced_bucket_aggregate()) as Dictionary
		var source_bucket: Dictionary = source.get(bucket_name, {}) as Dictionary
		target_bucket["records"] = int(target_bucket.get("records", 0)) + int(source_bucket.get("records", 0))
		target_bucket["plate_appearances"] = int(target_bucket.get("plate_appearances", 0)) + int(source_bucket.get("plate_appearances", 0))
		target_bucket["woba_denominator"] = int(target_bucket.get("woba_denominator", 0)) + int(source_bucket.get("woba_denominator", 0))
		target_bucket["xwoba_denominator"] = int(target_bucket.get("xwoba_denominator", 0)) + int(source_bucket.get("xwoba_denominator", 0))
		target_bucket["woba_numerator"] = float(target_bucket.get("woba_numerator", 0.0)) + float(source_bucket.get("woba_numerator", 0.0))
		target_bucket["xwoba_numerator"] = float(target_bucket.get("xwoba_numerator", 0.0)) + float(source_bucket.get("xwoba_numerator", 0.0))
		target_bucket["re24"] = float(target_bucket.get("re24", 0.0)) + float(source_bucket.get("re24", 0.0))
		target_bucket["bsr"] = float(target_bucket.get("bsr", 0.0)) + float(source_bucket.get("bsr", 0.0))
		target_bucket["fielding_chances"] = int(target_bucket.get("fielding_chances", 0)) + int(source_bucket.get("fielding_chances", 0))
		target_bucket["fielding_outs"] = int(target_bucket.get("fielding_outs", 0)) + int(source_bucket.get("fielding_outs", 0))
		_merge_int_map(target_bucket.get("fielding_chances_by_position", {}) as Dictionary, source_bucket.get("fielding_chances_by_position", {}) as Dictionary, target_bucket, "fielding_chances_by_position")
		_merge_int_map(target_bucket.get("fielding_chances_by_oaa_zone", {}) as Dictionary, source_bucket.get("fielding_chances_by_oaa_zone", {}) as Dictionary, target_bucket, "fielding_chances_by_oaa_zone")
		_merge_int_map(target_bucket.get("fielding_outs_by_position", {}) as Dictionary, source_bucket.get("fielding_outs_by_position", {}) as Dictionary, target_bucket, "fielding_outs_by_position")
		_merge_int_map(target_bucket.get("fielding_outs_by_oaa_zone", {}) as Dictionary, source_bucket.get("fielding_outs_by_oaa_zone", {}) as Dictionary, target_bucket, "fielding_outs_by_oaa_zone")
		_merge_int_map(target_bucket.get("defensive_outs_by_position", {}) as Dictionary, source_bucket.get("defensive_outs_by_position", {}) as Dictionary, target_bucket, "defensive_outs_by_position")
		_merge_int_map(target_bucket.get("defensive_outs_by_oaa_zone", {}) as Dictionary, source_bucket.get("defensive_outs_by_oaa_zone", {}) as Dictionary, target_bucket, "defensive_outs_by_oaa_zone")
		_merge_float_map(target_bucket.get("oaa_by_zone", {}) as Dictionary, source_bucket.get("oaa_by_zone", {}) as Dictionary, target_bucket, "oaa_by_zone")
		_merge_float_map(target_bucket.get("rngr_by_position", {}) as Dictionary, source_bucket.get("rngr_by_position", {}) as Dictionary, target_bucket, "rngr_by_position")
		_merge_float_map(target_bucket.get("errr_by_position", {}) as Dictionary, source_bucket.get("errr_by_position", {}) as Dictionary, target_bucket, "errr_by_position")
		_merge_float_map(target_bucket.get("dpr_by_position", {}) as Dictionary, source_bucket.get("dpr_by_position", {}) as Dictionary, target_bucket, "dpr_by_position")
		_merge_float_map(target_bucket.get("uzr_by_position", {}) as Dictionary, source_bucket.get("uzr_by_position", {}) as Dictionary, target_bucket, "uzr_by_position")
		_merge_float_map(target_bucket.get("drs_by_position", {}) as Dictionary, source_bucket.get("drs_by_position", {}) as Dictionary, target_bucket, "drs_by_position")
		target[bucket_name] = target_bucket


func _advanced_summary(raw: Dictionary) -> Dictionary:
	return {
		"players": _advanced_bucket_summary(raw.get("players", {}) as Dictionary),
		"pitchers": _advanced_bucket_summary(raw.get("pitchers", {}) as Dictionary),
	}


func _advanced_bucket_summary(raw: Dictionary) -> Dictionary:
	var woba_denominator: int = int(raw.get("woba_denominator", 0))
	var xwoba_denominator: int = int(raw.get("xwoba_denominator", 0))
	var woba: float = _safe_div_float(float(raw.get("woba_numerator", 0.0)), woba_denominator)
	var xwoba: float = _safe_div_float(float(raw.get("xwoba_numerator", 0.0)), xwoba_denominator)
	var chances_by_position: Dictionary = raw.get("fielding_chances_by_position", {}) as Dictionary
	var chances_by_oaa_zone: Dictionary = raw.get("fielding_chances_by_oaa_zone", {}) as Dictionary
	var defensive_outs_by_position: Dictionary = raw.get("defensive_outs_by_position", {}) as Dictionary
	var defensive_outs_by_oaa_zone: Dictionary = raw.get("defensive_outs_by_oaa_zone", {}) as Dictionary
	var oaa_by_zone: Dictionary = raw.get("oaa_by_zone", {}) as Dictionary
	# 「出場の多い方」を集計レベルでも反映するため fielding_chances を優先する。
	# defensive_outs はゾーン内のポジション数 (IF=4 / OF=3) や、全ポジションに按分される
	# チーム合計 outs の影響で IF / P1 が機械的に勝ってしまうため一次基準には使わない。
	var position_counts: Dictionary = chances_by_position if not chances_by_position.is_empty() else defensive_outs_by_position
	var primary_position: int = _primary_position_from_chances(position_counts)
	var primary_position_key: String = str(primary_position)
	var oaa_zone_counts: Dictionary = chances_by_oaa_zone if not chances_by_oaa_zone.is_empty() else defensive_outs_by_oaa_zone
	var primary_oaa_zone: String = _primary_oaa_zone_from_chances(oaa_zone_counts)
	var rngr_by_position: Dictionary = raw.get("rngr_by_position", {}) as Dictionary
	var errr_by_position: Dictionary = raw.get("errr_by_position", {}) as Dictionary
	var dpr_by_position: Dictionary = raw.get("dpr_by_position", {}) as Dictionary
	var uzr_by_position: Dictionary = raw.get("uzr_by_position", {}) as Dictionary
	var drs_by_position: Dictionary = raw.get("drs_by_position", {}) as Dictionary
	var rngr_display: float = float(rngr_by_position.get(primary_position_key, 0.0))
	var errr_display: float = float(errr_by_position.get(primary_position_key, 0.0))
	var dpr_display: float = float(dpr_by_position.get(primary_position_key, 0.0))
	var uzr_display: float = rngr_display + errr_display + dpr_display
	var row: Dictionary = {
		"records": int(raw.get("records", 0)),
		"plate_appearances": int(raw.get("plate_appearances", 0)),
		"woba_denominator": woba_denominator,
		"xwoba_denominator": xwoba_denominator,
		"woba": _round_float(woba, 3),
		"xwoba": _round_float(xwoba, 3),
		"wrc_plus": _round_float(_advanced_wrc_plus(woba, woba_denominator), 1),
		"re24": _round_float(float(raw.get("re24", 0.0)), 3),
		"bsr": _round_float(float(raw.get("bsr", 0.0)), 3),
		"fielding_chances": int(raw.get("fielding_chances", 0)),
		"fielding_outs": int(raw.get("fielding_outs", 0)),
		"fielding_chances_by_position": chances_by_position.duplicate(true),
		"fielding_chances_by_oaa_zone": chances_by_oaa_zone.duplicate(true),
		"fielding_outs_by_position": (raw.get("fielding_outs_by_position", {}) as Dictionary).duplicate(true),
		"fielding_outs_by_oaa_zone": (raw.get("fielding_outs_by_oaa_zone", {}) as Dictionary).duplicate(true),
		"defensive_outs_by_position": defensive_outs_by_position.duplicate(true),
		"defensive_outs_by_oaa_zone": defensive_outs_by_oaa_zone.duplicate(true),
		"primary_uzr_position": primary_position,
		"primary_oaa_zone": primary_oaa_zone,
		"oaa_by_zone": _rounded_float_map(oaa_by_zone, 3),
		"oaa_infield": _round_float(float(oaa_by_zone.get("infield", 0.0)), 3),
		"oaa_outfield": _round_float(float(oaa_by_zone.get("outfield", 0.0)), 3),
		"oaa": _round_float(float(oaa_by_zone.get(primary_oaa_zone, 0.0)), 3),
		"rngr_by_position": _rounded_float_map(rngr_by_position, 3),
		"errr_by_position": _rounded_float_map(errr_by_position, 3),
		"dpr_by_position": _rounded_float_map(dpr_by_position, 3),
		"uzr_by_position": _rounded_float_map(uzr_by_position, 3),
		"drs_by_position": _rounded_float_map(drs_by_position, 3),
		"rngr": _round_float(rngr_display, 3),
		"errr": _round_float(errr_display, 3),
		"dpr": _round_float(dpr_display, 3),
		"uzr": _round_float(uzr_display, 3),
		"drs": _round_float(uzr_display, 3),
	}
	# リーグ集計の OAA/UZR は自身のポジション別平均でゼロセンタリング（ゼロサム指標なので合計は ≈0 になる）。
	var oaa_by_position: Dictionary = raw.get("oaa_by_position", {}) as Dictionary
	var self_center: Dictionary = {"fielding_center": {
		"oaa_per_chance_by_position": WarCalculator._per_chance_map(oaa_by_position, chances_by_position),
		"rngr_per_chance_by_position": WarCalculator._per_chance_map(rngr_by_position, chances_by_position),
		"errr_per_chance_by_position": WarCalculator._per_chance_map(errr_by_position, chances_by_position),
		"dpr_per_chance_by_position": WarCalculator._per_chance_map(dpr_by_position, chances_by_position),
	}}
	var centered: Dictionary = WarCalculator.recenter_fielding({
		"fielding_chances_by_position": chances_by_position,
		"oaa_by_position": oaa_by_position,
		"rngr_by_position": rngr_by_position,
		"errr_by_position": errr_by_position,
		"dpr_by_position": dpr_by_position,
		"positional_adjustment_runs": 0.0,
	}, self_center)
	for key in ["oaa", "oaa_infield", "oaa_outfield", "rngr", "errr", "dpr", "uzr", "drs"]:
		row[key] = float(centered.get(key, row.get(key, 0.0)))
	_apply_defense_value_adjustment(row)
	return row


func _advanced_wrc_plus(woba: float, denominator: int) -> float:
	if denominator <= 0 or ADVANCED_LEAGUE_RUNS_PER_PA <= 0.0:
		return 0.0
	var runs_per_pa: float = ((woba - ADVANCED_LEAGUE_WOBA) / ADVANCED_WOBA_SCALE) + ADVANCED_LEAGUE_RUNS_PER_PA
	return runs_per_pa / ADVANCED_LEAGUE_RUNS_PER_PA * 100.0


func _batted_ball_aggregate_for_season(season: PSSeason) -> Dictionary:
	var aggregate: Dictionary = _empty_batted_ball_aggregate()
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var result: Dictionary = game.get("result", {}) as Dictionary
		var play_events: Array = result.get("play_events", []) as Array
		for event_value in play_events:
			var event: Dictionary = event_value as Dictionary
			var batted_ball_event: Dictionary = event.get("batted_ball_event", {}) as Dictionary
			if batted_ball_event.is_empty():
				continue
			aggregate["batted_balls"] = int(aggregate.get("batted_balls", 0)) + 1
			aggregate["exit_velocity_total"] = float(aggregate.get("exit_velocity_total", 0.0)) + float(batted_ball_event.get("exit_velocity", 0.0))
			aggregate["launch_angle_total"] = float(aggregate.get("launch_angle_total", 0.0)) + float(batted_ball_event.get("launch_angle", 0.0))
			aggregate["distance_total"] = float(aggregate.get("distance_total", 0.0)) + float(batted_ball_event.get("distance", 0.0))
			if bool(batted_ball_event.get("is_barrel", false)):
				aggregate["barrels"] = int(aggregate.get("barrels", 0)) + 1
			if bool(batted_ball_event.get("is_hard_hit", false)):
				aggregate["hard_hits"] = int(aggregate.get("hard_hits", 0)) + 1
			if str(batted_ball_event.get("actual_result", "")).contains("home_run"):
				aggregate["home_run_batted_balls"] = int(aggregate.get("home_run_batted_balls", 0)) + 1
				if bool(batted_ball_event.get("is_barrel", false)):
					aggregate["home_run_barrels"] = int(aggregate.get("home_run_barrels", 0)) + 1
	return aggregate


func _empty_batted_ball_aggregate() -> Dictionary:
	return {
		"batted_balls": 0,
		"barrels": 0,
		"hard_hits": 0,
		"home_run_batted_balls": 0,
		"home_run_barrels": 0,
		"exit_velocity_total": 0.0,
		"launch_angle_total": 0.0,
		"distance_total": 0.0,
	}


func _accumulate_batted_ball(target: Dictionary, source: Dictionary) -> void:
	for key in ["batted_balls", "barrels", "hard_hits", "home_run_batted_balls", "home_run_barrels"]:
		target[key] = int(target.get(key, 0)) + int(source.get(key, 0))
	for key in ["exit_velocity_total", "launch_angle_total", "distance_total"]:
		target[key] = float(target.get(key, 0.0)) + float(source.get(key, 0.0))


func _batted_ball_summary(raw: Dictionary) -> Dictionary:
	var batted_balls: int = int(raw.get("batted_balls", 0))
	var barrels: int = int(raw.get("barrels", 0))
	var hard_hits: int = int(raw.get("hard_hits", 0))
	var home_run_batted_balls: int = int(raw.get("home_run_batted_balls", 0))
	var home_run_barrels: int = int(raw.get("home_run_barrels", 0))
	return {
		"batted_balls": batted_balls,
		"barrels": barrels,
		"hard_hits": hard_hits,
		"barrel_rate": _round_float(_safe_div(barrels, batted_balls), 3),
		"hard_hit_rate": _round_float(_safe_div(hard_hits, batted_balls), 3),
		"home_run_batted_balls": home_run_batted_balls,
		"home_run_barrels": home_run_barrels,
		"home_run_barrel_rate": _round_float(_safe_div(home_run_barrels, home_run_batted_balls), 3),
		"average_exit_velocity": _round_float(_safe_div_float(float(raw.get("exit_velocity_total", 0.0)), batted_balls), 1),
		"average_launch_angle": _round_float(_safe_div_float(float(raw.get("launch_angle_total", 0.0)), batted_balls), 1),
		"average_distance": _round_float(_safe_div_float(float(raw.get("distance_total", 0.0)), batted_balls), 1),
	}


func _team_name(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "Free"
	return team.name


func _position_name(position: int) -> String:
	return str(PSPlayer.POSITION_NAMES.get(position, "不明"))


func _isolated_power(stats: PSBatterStats) -> float:
	return stats.slugging_percentage() - stats.batting_average()


func _batter_contact_result(stats: PSBatterStats) -> float:
	var denominator: int = stats.at_bats - stats.strikeouts - stats.home_runs + stats.sacrifice_flies
	if denominator <= 0:
		return 0.0
	return float(stats.hits - stats.home_runs) / float(denominator)


func _merge_int_map(target: Dictionary, source: Dictionary, parent: Dictionary, field: String) -> void:
	var merged: Dictionary = target.duplicate(true)
	for key_value in source.keys():
		var key: String = str(key_value)
		merged[key] = int(merged.get(key, 0)) + int(source[key_value])
	parent[field] = merged


func _merge_float_map(target: Dictionary, source: Dictionary, parent: Dictionary, field: String) -> void:
	var merged: Dictionary = target.duplicate(true)
	for key_value in source.keys():
		var key: String = str(key_value)
		merged[key] = float(merged.get(key, 0.0)) + float(source[key_value])
	parent[field] = merged


func _primary_position_from_chances(chances: Dictionary) -> int:
	var best_position: int = 0
	var best_chances: int = -1
	for key_value in chances.keys():
		var position: int = int(str(key_value))
		var chance_count: int = int(chances.get(key_value, 0))
		if chance_count > best_chances or (chance_count == best_chances and (best_position == 0 or position < best_position)):
			best_position = position
			best_chances = chance_count
	return best_position


func _primary_oaa_zone_from_chances(chances: Dictionary) -> String:
	var infield_chances: int = int(chances.get("infield", 0))
	var outfield_chances: int = int(chances.get("outfield", 0))
	if infield_chances <= 0 and outfield_chances <= 0:
		return ""
	return "outfield" if outfield_chances > infield_chances else "infield"


func _rounded_float_map(source: Dictionary, digits: int) -> Dictionary:
	var result: Dictionary = {}
	for key_value in source.keys():
		var key: String = str(key_value)
		result[key] = _round_float(float(source[key_value]), digits)
	return result


func _sum_float_map(source: Dictionary) -> float:
	var total: float = 0.0
	for key_value in source.keys():
		total += float(source[key_value])
	return total


func _position_adjustment_from_outs(defensive_outs_by_position: Dictionary) -> float:
	if POSITION_ADJUSTMENT_FULL_SEASON_OUTS <= 0.0:
		return 0.0
	var adjustment: float = 0.0
	for key_value in defensive_outs_by_position.keys():
		var position: int = int(str(key_value))
		var outs: int = int(defensive_outs_by_position[key_value])
		var full_season_runs: float = float(POSITION_ADJUSTMENT_RUNS_PER_162.get(position, 0.0))
		adjustment += full_season_runs * float(outs) / POSITION_ADJUSTMENT_FULL_SEASON_OUTS
	return adjustment


func _apply_defense_value_adjustment(row: Dictionary) -> void:
	# fielding_runs (= UZR 系合計) は伝統指標として残置。分析・互換性のため出力する。
	var uzr_by_position: Dictionary = row.get("uzr_by_position", {}) as Dictionary
	var fielding_runs: float = _sum_float_map(uzr_by_position) if not uzr_by_position.is_empty() else float(row.get("uzr", 0.0))
	# WAR の守備成分は OAA ベース (oaa_total × RUN_PER_OUT + 守備位置補正)。
	# row.oaa_by_zone か oaa_infield / oaa_outfield のいずれかが揃っていれば算出可能。
	var oaa_by_zone: Dictionary = row.get("oaa_by_zone", {}) as Dictionary
	var oaa_infield: float = float(oaa_by_zone.get("infield", row.get("oaa_infield", 0.0)))
	var oaa_outfield: float = float(oaa_by_zone.get("outfield", row.get("oaa_outfield", 0.0)))
	var oaa_total: float = oaa_infield + oaa_outfield
	var oaa_runs: float = oaa_total * ADVANCED_RUN_PER_OUT
	var defensive_outs_by_position: Dictionary = row.get("defensive_outs_by_position", {}) as Dictionary
	var positional_adjustment: float = _position_adjustment_from_outs(defensive_outs_by_position)
	row["fielding_runs"] = _round_float(fielding_runs, 3)
	row["oaa_total"] = _round_float(oaa_total, 3)
	row["oaa_runs"] = _round_float(oaa_runs, 3)
	row["positional_adjustment_runs"] = _round_float(positional_adjustment, 3)
	row["def_runs"] = _round_float(oaa_runs + positional_adjustment, 3)


func _safe_div(numerator: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return float(numerator) / float(denominator)


func _safe_div_float(numerator: float, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return numerator / float(denominator)


func _per_nine(count: int, outs: int) -> float:
	if outs <= 0:
		return 0.0
	return float(count) * 27.0 / float(outs)


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, float(digits))
	return round(value * scale) / scale
