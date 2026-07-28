extends Node

# 1日分の試合並列化(WorkerThreadPool)の速度検証。同一seed・同一日数を
# force_sequential=true(逐次)/false(並列)それぞれで実行し所要時間を比較する。
const DEFAULT_DAYS: int = 30
const SEED: int = 20260520


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var days: int = _days()
	var history_years: int = _history_years()
	var lookup_repeats: int = _lookup_repeats()
	var sequential: Dictionary = _run_mode("sequential", days, true, history_years, lookup_repeats)
	var parallel: Dictionary = _run_mode("parallel", days, false, history_years, lookup_repeats)

	var speedup: float = 0.0
	var seq_ms: int = int(sequential.get("elapsed_ms", 0))
	var par_ms: int = int(parallel.get("elapsed_ms", 0))
	if par_ms > 0:
		speedup = float(seq_ms) / float(par_ms)
	print("Day parallel benchmark: days=%d sequential_ms=%d parallel_ms=%d speedup=%.2fx" % [
		days, seq_ms, par_ms, speedup,
	])

	var ok: bool = int(sequential.get("days_simulated", 0)) > 0 and int(parallel.get("days_simulated", 0)) > 0
	get_tree().quit(0 if ok else 1)


func _run_mode(
	label: String,
	days: int,
	force_sequential: bool,
	history_years: int,
	lookup_repeats: int
) -> Dictionary:
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	_seed_history_records(season, history_years)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
	if lookup_repeats > 0:
		_benchmark_team_record_lookups(label, season, history_years, lookup_repeats)

	var start_ms: int = Time.get_ticks_msec()
	var days_simulated: int = 0
	var games_simulated: int = 0
	while days_simulated < days:
		var day_result: Dictionary = GameSimulator.simulate_current_day(season, false, {}, force_sequential)
		if not bool(day_result.get("ok", false)):
			break
		days_simulated += 1
		games_simulated += (day_result.get("results", []) as Array).size()
	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	var msec_per_day: float = 0.0 if days_simulated == 0 else float(elapsed_ms) / float(days_simulated)
	print("[%s] days=%d games=%d elapsed_ms=%d msec_per_day=%.1f" % [
		label, days_simulated, games_simulated, elapsed_ms, msec_per_day,
	])
	return {
		"days_simulated": days_simulated,
		"games_simulated": games_simulated,
		"elapsed_ms": elapsed_ms,
		"msec_per_day": msec_per_day,
	}


func _days() -> int:
	var raw: String = OS.get_environment("PS_DAY_BENCH_DAYS")
	if raw.is_valid_int():
		return max(1, int(raw))
	return DEFAULT_DAYS


func _history_years() -> int:
	var raw: String = OS.get_environment("PS_DAY_BENCH_HISTORY_YEARS")
	if raw.is_valid_int():
		return max(0, int(raw))
	return 0


func _lookup_repeats() -> int:
	var raw: String = OS.get_environment("PS_RECORD_LOOKUP_BENCH_REPEATS")
	if raw.is_valid_int():
		return max(0, int(raw))
	return 0


func _seed_history_records(current_season: PSSeason, history_years: int) -> void:
	for year_offset in range(history_years, 0, -1):
		var historical_season: PSSeason = PSSeason.new()
		historical_season.year = current_season.year - year_offset
		historical_season.season_number = current_season.season_number
		RecordStore.ensure_season_records(historical_season, GameDb.teams, GameDb.players, false)


func _benchmark_team_record_lookups(
	label: String,
	season: PSSeason,
	history_years: int,
	repeats: int
) -> void:
	var lookup_count: int = 0
	var matched_count: int = 0
	var start_usec: int = Time.get_ticks_usec()
	for _repeat in range(repeats):
		for team_value in GameDb.teams:
			var team: PSTeam = team_value as PSTeam
			matched_count += RecordStore.get_team_player_records(
				team.id,
				season.year,
				season.season_number
			).size()
			lookup_count += 1
	var elapsed_usec: int = Time.get_ticks_usec() - start_usec
	var usec_per_lookup: float = (
		0.0
		if lookup_count == 0
		else float(elapsed_usec) / float(lookup_count)
	)
	print("[%s] record_lookup history_years=%d records=%d lookups=%d matched=%d elapsed_ms=%.1f usec_per_lookup=%.2f" % [
		label,
		history_years,
		RecordStore.player_records.size(),
		lookup_count,
		matched_count,
		float(elapsed_usec) / 1000.0,
		usec_per_lookup,
	])
