extends Node

const SimulationReporterScript = preload("res://services/reports/simulation_reporter.gd")
const LongAutoplayReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const LineupEditorScreenScript = preload("res://ui/screens/lineup_editor_screen.gd")


func _ready() -> void:
	var failures: Array = []
	if GameDb.teams.is_empty() or GameDb.players.is_empty():
		GameDb.load_initial_data()

	failures.append_array(_test_default_dh_enabled_for_both_leagues())
	failures.append_array(_test_league_specific_schedule_settings())
	failures.append_array(_test_schedule_rest_days())
	failures.append_array(_test_app_state_updates_unplayed_games())
	failures.append_array(_test_reporter_option_settings())
	failures.append_array(_test_lineup_editor_mode_buttons())

	if failures.is_empty():
		print("DH settings smoke: ALL OK")
		get_tree().quit(0)
	else:
		print("DH settings smoke: FAILURES = %d" % failures.size())
		for failure in failures:
			print("  - %s" % str(failure))
		get_tree().quit(1)


func _test_default_dh_enabled_for_both_leagues() -> Array:
	var failures: Array = []
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams)
	var seen: Dictionary = _dh_seen_by_home_league(schedule)
	for league in ["central", "pacific"]:
		if not bool(seen.get(league, false)):
			failures.append("default: no %s home game found" % league)
		if bool(seen.get("%s_disabled" % league, false)):
			failures.append("default: %s home game had DH disabled" % league)
	return failures


func _test_league_specific_schedule_settings() -> Array:
	var failures: Array = []
	var central_off: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {
		"central": false,
		"pacific": true,
	})
	failures.append_array(_expect_home_league_dh(central_off, "central", false, "central off"))
	failures.append_array(_expect_home_league_dh(central_off, "pacific", true, "central off"))

	var pacific_off: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {
		"central": true,
		"pacific": false,
	})
	failures.append_array(_expect_home_league_dh(pacific_off, "central", true, "pacific off"))
	failures.append_array(_expect_home_league_dh(pacific_off, "pacific", false, "pacific off"))
	return failures


func _test_schedule_rest_days() -> Array:
	var failures: Array = []
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams)
	var expected_games: int = int(PSSchedule.PENNANT_GAMES_PER_TEAM * GameDb.teams.size() / 2)
	if schedule.size() != expected_games:
		failures.append("schedule rest: games=%d expected %d" % [schedule.size(), expected_games])

	var seen_days: Dictionary = {}
	var days: Array = []
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		var day: int = int(game.get("day", 0))
		if not seen_days.has(day):
			seen_days[day] = true
			days.append(day)
	days.sort()

	var has_rest_gap: bool = false
	var current_run: int = 1
	var max_run: int = 1
	for i in range(1, days.size()):
		var gap: int = int(days[i]) - int(days[i - 1])
		if gap > 1:
			has_rest_gap = true
			current_run = 1
		else:
			current_run += 1
			max_run = max(max_run, current_run)
	if not has_rest_gap:
		failures.append("schedule rest: no off-day gap found")
	if max_run > PSSchedule.ROUNDS_PER_CYCLE:
		failures.append("schedule rest: consecutive game days=%d expected <=%d" % [max_run, PSSchedule.ROUNDS_PER_CYCLE])
	return failures


func _test_app_state_updates_unplayed_games() -> Array:
	var failures: Array = []
	var original_season: PSSeason = AppState.current_season
	var original_selected: int = AppState.selected_team_id
	var original_auto_save: bool = AppState.auto_save_enabled
	var original_settings: Dictionary = AppState.dh_settings_for_schedule()

	AppState.auto_save_enabled = false
	AppState.selected_team_id = _first_team_id()
	AppState.league_dh_enabled = {
		"central": true,
		"pacific": true,
	}
	AppState.current_season = SeasonService.create_new_season(GameDb.teams, AppState.selected_team_id, 2026, AppState.dh_settings_for_schedule())
	AppState.set_dh_enabled_for_league("central", false)
	failures.append_array(_expect_home_league_dh(AppState.current_season.schedule, "central", false, "app central off"))
	failures.append_array(_expect_home_league_dh(AppState.current_season.schedule, "pacific", true, "app central off"))

	AppState.set_dh_enabled_for_league("pacific", false)
	failures.append_array(_expect_home_league_dh(AppState.current_season.schedule, "central", false, "app both off"))
	failures.append_array(_expect_home_league_dh(AppState.current_season.schedule, "pacific", false, "app both off"))

	AppState.current_season = original_season
	AppState.selected_team_id = original_selected
	AppState.auto_save_enabled = original_auto_save
	AppState.league_dh_enabled = original_settings
	return failures


func _test_reporter_option_settings() -> Array:
	var failures: Array = []
	var options: Dictionary = {
		"dh_by_league": {
			"central": false,
			"pacific": true,
		},
	}
	var simulation_reporter: Object = SimulationReporterScript.new()
	var simulation_settings: Dictionary = simulation_reporter.call("_dh_settings_from_options", options) as Dictionary
	if bool(simulation_settings.get("central", true)):
		failures.append("simulation reporter: central DH setting was not false")
	if not bool(simulation_settings.get("pacific", false)):
		failures.append("simulation reporter: pacific DH setting was not true")

	var long_reporter: Object = LongAutoplayReporterScript.new()
	var long_settings: Dictionary = long_reporter.call("_dh_settings_from_options", {
		"league_dh_enabled": {
			"central": true,
			"pacific": false,
		},
	}) as Dictionary
	if not bool(long_settings.get("central", false)):
		failures.append("long autoplay reporter: central DH setting was not true")
	if bool(long_settings.get("pacific", true)):
		failures.append("long autoplay reporter: pacific DH setting was not false")
	return failures


func _test_lineup_editor_mode_buttons() -> Array:
	var failures: Array = []
	var original_settings: Dictionary = AppState.dh_settings_for_schedule()
	var screen = LineupEditorScreenScript.new()
	screen.mode_non_dh_button = Button.new()
	screen.mode_dh_button = Button.new()

	AppState.league_dh_enabled = {
		"central": true,
		"pacific": true,
	}
	screen.dh_enabled = false
	screen.call("_apply_dh_mode_availability", null)
	if screen.mode_non_dh_button.visible:
		failures.append("lineup editor: non-DH button was visible when both leagues use DH")
	if not screen.mode_dh_button.visible or not bool(screen.dh_enabled):
		failures.append("lineup editor: DH mode was not forced when both leagues use DH")

	AppState.league_dh_enabled = {
		"central": false,
		"pacific": false,
	}
	screen.dh_enabled = true
	screen.call("_apply_dh_mode_availability", null)
	if screen.mode_dh_button.visible:
		failures.append("lineup editor: DH button was visible when neither league uses DH")
	if not screen.mode_non_dh_button.visible or bool(screen.dh_enabled):
		failures.append("lineup editor: non-DH mode was not forced when neither league uses DH")

	AppState.league_dh_enabled = {
		"central": true,
		"pacific": false,
	}
	screen.call("_apply_dh_mode_availability", null)
	if not screen.mode_dh_button.visible or not screen.mode_non_dh_button.visible:
		failures.append("lineup editor: both mode buttons were not visible for mixed DH settings")

	AppState.league_dh_enabled = original_settings
	screen.mode_non_dh_button.free()
	screen.mode_dh_button.free()
	screen.free()
	return failures


func _expect_home_league_dh(schedule: Array, league: String, expected: bool, label: String) -> Array:
	var failures: Array = []
	var checked: int = 0
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		var home_team: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
		if home_team == null or str(home_team.league) != league:
			continue
		checked += 1
		if bool(game.get("dh_enabled", false)) != expected:
			failures.append("%s: %s home game day %d had dh_enabled=%s expected %s" % [
				label,
				league,
				int(game.get("day", 0)),
				str(game.get("dh_enabled", false)),
				str(expected),
			])
			break
	if checked <= 0:
		failures.append("%s: no %s home games checked" % [label, league])
	return failures


func _dh_seen_by_home_league(schedule: Array) -> Dictionary:
	var seen: Dictionary = {}
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		var home_team: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
		if home_team == null:
			continue
		var league: String = str(home_team.league)
		seen[league] = true
		if not bool(game.get("dh_enabled", false)):
			seen["%s_disabled" % league] = true
	return seen


func _first_team_id() -> int:
	if GameDb.teams.is_empty():
		return 0
	var team: PSTeam = GameDb.teams[0] as PSTeam
	return team.id if team != null else 0
