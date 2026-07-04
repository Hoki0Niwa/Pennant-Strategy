extends Node

# PA benchmark for the active v2 plate simulator.
const DEFAULT_GAMES_PER_MODE: int = 40
const SEED: int = 20260520


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var games_per_mode: int = _games_per_mode()
	var profile: bool = not OS.get_environment("PS_PROFILE_GAME_SIM").is_empty()
	var metrics: Dictionary = _run_mode("v2", games_per_mode, profile)
	print("PA benchmark: games=%d elapsed_ms=%d msec_per_game=%.1f" % [
		int(metrics.get("games", 0)),
		int(metrics.get("elapsed_ms", 0)),
		float(metrics.get("msec_per_game", 0.0)),
	])
	if profile:
		print("PA benchmark profile_ms=%s" % str(metrics.get("profile_ms", {})))
	var ok: bool = int(metrics.get("games", 0)) > 0
	get_tree().quit(0 if ok else 1)


func _run_mode(label: String, games_per_mode: int, profile: bool = false) -> Dictionary:
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	GameSimulator.reset_profile(profile)
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var start_ms: int = Time.get_ticks_msec()
	var games: int = 0
	while games < games_per_mode:
		var simulation: Dictionary = GameSimulator.simulate_next_unplayed_game(season, false)
		if not bool(simulation.get("ok", false)):
			break
		games += 1
	var elapsed_ms: int = Time.get_ticks_msec() - start_ms
	var msec_per_game: float = 0.0 if games == 0 else float(elapsed_ms) / float(games)
	print("[%s] games=%d elapsed_ms=%d msec_per_game=%.1f" % [label, games, elapsed_ms, msec_per_game])
	return {
		"games": games,
		"elapsed_ms": elapsed_ms,
		"msec_per_game": msec_per_game,
		"profile_ms": GameSimulator.profile_totals_msec() if profile else {},
	}


func _games_per_mode() -> int:
	var raw: String = OS.get_environment("PS_PA_BENCH_GAMES")
	if raw.is_valid_int():
		return max(1, int(raw))
	return DEFAULT_GAMES_PER_MODE
