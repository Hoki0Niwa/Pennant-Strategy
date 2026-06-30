extends Node


func _ready() -> void:
	var args: Dictionary = _parse_args()
	var seed_value: int = int(args.get("seed", 12345))
	var seasons: int = int(max(1, int(args.get("seasons", 1))))
	var start_year: int = int(args.get("start_year", 2026))

	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_seed: int = Rng.current_seed
	var original_state: int = Rng.generator.state
	RecordStore.suspend_persistence()
	Rng.set_seed_value(seed_value)

	var counts: Dictionary = {}
	var first_pitch_contact: int = 0
	var one_pitch_pa: int = 0
	var total_pa: int = 0
	for season_index in range(seasons):
		RecordStore.clear_records()
		var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, start_year + season_index, {})
		RecordStore.ensure_season_records(season, GameDb.teams, GameDb.players, false)
		for game_index in range(season.schedule.size()):
			var game_result: Dictionary = GameSimulator.simulate_game_at_index(season, game_index, false)
			if not bool(game_result.get("ok", false)):
				push_error(str(game_result.get("message", "game simulation failed")))
				continue
			var result: Dictionary = game_result.get("result", {}) as Dictionary
			for event_value in (result.get("play_events", []) as Array):
				var event: Dictionary = event_value as Dictionary
				var plate: Dictionary = event.get("plate_event", {}) as Dictionary
				if not bool(plate.get("pa_completed", false)):
					continue
				var pitches: int = int(plate.get("pitches", 0))
				if pitches <= 0:
					continue
				total_pa += 1
				counts[pitches] = int(counts.get(pitches, 0)) + 1
				if pitches == 1:
					one_pitch_pa += 1
					if _is_contact_pa(plate):
						first_pitch_contact += 1

	RecordStore.load_from_dict(original_records)
	RecordStore.resume_persistence()
	Rng.current_seed = original_seed
	Rng.generator.seed = original_seed
	Rng.generator.state = original_state

	var distribution: Array = []
	var keys: Array = counts.keys()
	keys.sort()
	for key in keys:
		var count: int = int(counts[key])
		distribution.append({
			"pitches": int(key),
			"count": count,
			"rate": _round_float(_safe_div(count, total_pa), 4),
		})
	var summary: Dictionary = {
		"seed": seed_value,
		"seasons": seasons,
		"total_pa": total_pa,
		"one_pitch_pa": one_pitch_pa,
		"one_pitch_pa_rate": _round_float(_safe_div(one_pitch_pa, total_pa), 4),
		"first_pitch_contact": first_pitch_contact,
		"first_pitch_contact_rate": _round_float(_safe_div(first_pitch_contact, total_pa), 4),
		"distribution": distribution,
	}
	print(JSON.stringify(summary, "\t"))
	get_tree().quit(0)


func _is_contact_pa(plate: Dictionary) -> bool:
	if bool(plate.get("is_hit", false)) or bool(plate.get("ab_charged", false)):
		var category: String = str(plate.get("category", ""))
		return category != "strikeout"
	var category: String = str(plate.get("category", ""))
	return category in ["hit", "out", "error", "fielders_choice", "sacrifice", "sacrifice_fly"]


func _safe_div(a: float, b: float) -> float:
	return 0.0 if b == 0.0 else a / b


func _round_float(value: float, digits: int) -> float:
	var scale: float = pow(10.0, digits)
	return round(value * scale) / scale


func _parse_args() -> Dictionary:
	var parsed: Dictionary = {}
	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))
	for arg in args:
		var text: String = str(arg)
		if not text.begins_with("--"):
			continue
		var body: String = text.substr(2)
		var eq: int = body.find("=")
		if eq >= 0:
			parsed[body.substr(0, eq)] = body.substr(eq + 1)
		else:
			parsed[body] = true
	return parsed
