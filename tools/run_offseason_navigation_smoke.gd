extends Node


func _ready() -> void:
	var ok: bool = true
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	var original_screen: String = AppState.current_screen
	var original_team_id: int = AppState.selected_team_id
	var original_season: PSSeason = AppState.current_season
	var original_offseason_active: bool = AppState.offseason_active
	var original_step: int = AppState.offseason_step
	var original_records: Dictionary = RecordStore.to_dict().duplicate(true)
	var original_players: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null:
			original_players.append(player.to_dict())

	AppState.selected_team_id = 1
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026)
	AppState.current_screen = "team_select"
	AppState.offseason_active = true
	AppState.offseason_step = 9
	var advanced: bool = AppState.start_next_season()
	ok = _expect(advanced, "start_next_season succeeds", ok)
	ok = _expect(AppState.current_screen == "home", "next season starts on home screen (got %s)" % AppState.current_screen, ok)
	ok = _expect(AppState.selected_team_id == 1, "selected team is preserved", ok)

	AppState.current_screen = original_screen
	AppState.selected_team_id = original_team_id
	AppState.current_season = original_season
	AppState.offseason_active = original_offseason_active
	AppState.offseason_step = original_step
	if not original_players.is_empty():
		GameDb.replace_players_from_rows(original_players)
	RecordStore.load_from_dict(original_records)

	print("Offseason navigation smoke: %s" % ["ALL OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)


func _expect(condition: bool, label: String, running_ok: bool) -> bool:
	if not condition:
		push_error("[offseason_navigation] FAIL: %s" % label)
		return false
	return running_ok
