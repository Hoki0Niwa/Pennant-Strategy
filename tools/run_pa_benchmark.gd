extends Node

# PA benchmark for the active v2 plate simulator.
const GAMES_PER_MODE: int = 40
const SEED: int = 20260520


func _ready() -> void:
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var metrics: Dictionary = _run_mode("v2")
	print("PA benchmark: games=%d elapsed_ms=%d msec_per_game=%.1f" % [
		int(metrics.get("games", 0)),
		int(metrics.get("elapsed_ms", 0)),
		float(metrics.get("msec_per_game", 0.0)),
	])
	var ok: bool = int(metrics.get("games", 0)) > 0
	get_tree().quit(0 if ok else 1)


func _run_mode(label: String) -> Dictionary:
	Rng.set_seed_value(SEED)
	RecordStore.clear_records()
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026)
	RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)

	var start_ms: int = Time.get_ticks_msec()
	var games: int = 0
	while games < GAMES_PER_MODE:
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
	}
