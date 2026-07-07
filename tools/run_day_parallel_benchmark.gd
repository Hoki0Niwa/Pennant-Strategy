extends Node

# 1日分の試合並列化(WorkerThreadPool)の速度検証。同一seed・同一日数を
# force_sequential=true(逐次)/false(並列)それぞれで実行し所要時間を比較する。
const DEFAULT_DAYS: int = 30
const SEED: int = 20260520


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var days: int = _days()
	var sequential: Dictionary = _run_mode("sequential", days, true)
	var parallel: Dictionary = _run_mode("parallel", days, false)

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


func _run_mode(label: String, days: int, force_sequential: bool) -> Dictionary:
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

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
