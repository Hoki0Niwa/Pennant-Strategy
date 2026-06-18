extends GdUnitTestSuite

const SeasonCalendar = preload("res://services/season/season_calendar.gd")


func before() -> void:
	if GameDb.teams.is_empty():
		GameDb.load_initial_data()


func test_template_schedule_has_pennant_invariants() -> void:
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var validation: Dictionary = PSSchedule.validate_schedule(schedule, GameDb.teams)

	assert_bool(bool(validation.get("ok", false))).is_true()
	assert_int(schedule.size()).is_equal(PSSchedule.EXPECTED_TOTAL_GAMES)


func test_opening_date_is_last_friday_of_march() -> void:
	for year in [2026, 2027, 2028, 2029, 2030]:
		var opening: String = SeasonCalendar.opening_date_for_year(int(year))
		var parts: PackedStringArray = opening.split("-")
		assert_int(int(parts[1])).is_equal(3)
		assert_int(SeasonCalendar.weekday_for_date(opening)).is_equal(5)
		assert_int(int(parts[2])).is_between(25, 31)
		assert_int(SeasonCalendar.weekday_for_date(SeasonCalendar.add_days(opening, 7))).is_equal(5)
		assert_str(SeasonCalendar.add_days(opening, 7).substr(5, 2)).is_not_equal("03")


func test_same_seed_is_stable_and_next_year_changes_cards() -> void:
	var schedule_a: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var schedule_b: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var schedule_next: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2027, 2)

	assert_str(_matchup_signature(schedule_a)).is_equal(_matchup_signature(schedule_b))
	assert_str(_matchup_signature(schedule_a)).is_not_equal(_matchup_signature(schedule_next))


func test_game_day_and_date_are_consistent_across_years() -> void:
	for year in range(2026, 2041):
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, year - 2025)
		var opening: String = SeasonCalendar.opening_date_for_year(year)
		assert_int(SeasonCalendar.weekday_for_date(opening)).is_equal(5)

		for game_value in schedule:
			var game: Dictionary = game_value as Dictionary
			var expected: String = SeasonCalendar.date_for_day(opening, int(game.get("day", 0)))
			var date_text: String = str(game.get("date", ""))
			assert_str(date_text).is_equal(expected)
			assert_str(SeasonCalendar.label_for_date(date_text)).contains(SeasonCalendar.weekday_label_for_date(date_text))


func test_calendar_display_helpers_are_stable() -> void:
	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	var first_game: Dictionary = season.schedule[0] as Dictionary

	assert_str(SeasonCalendar.current_date(season)).is_equal(season.calendar_start_date)
	assert_str(SeasonCalendar.compact_label_for_game(first_game, season)).is_equal("3/27(金)")
	assert_str(SeasonCalendar.relative_label(1, 1)).is_equal("本日")
	assert_str(SeasonCalendar.relative_label(1, 2)).is_equal("明日")
	assert_str(SeasonCalendar.relative_label(1, 4)).is_equal("3日後")


func test_no_monday_regular_games() -> void:
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)

	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		assert_int(SeasonCalendar.weekday_for_date(str(game.get("date", "")))).is_not_equal(1)


func test_interleague_matches_official_2026_window() -> void:
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var first_date: String = ""
	var last_date: String = ""

	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("is_interleague", false)):
			continue
		var date_text: String = str(game.get("date", ""))
		if first_date.is_empty() or date_text < first_date:
			first_date = date_text
		if last_date.is_empty() or date_text > last_date:
			last_date = date_text

	assert_str(first_date).is_equal("2026-05-26")
	assert_str(last_date).is_equal("2026-06-14")


func test_three_game_series_are_the_default() -> void:
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var groups: Dictionary = _series_groups(schedule)
	var three_game_series: int = 0
	var single_games: int = 0

	for series_key in groups.keys():
		var series_games: Array = groups.get(series_key, []) as Array
		if series_games.size() == 3:
			three_game_series += 1
			_assert_three_game_series(series_games)
		elif series_games.size() == 1:
			single_games += 1
		else:
			assert_bool(false).override_failure_message("Unexpected series size %d for %s" % [series_games.size(), str(series_key)]).is_true()

	assert_int(three_game_series).is_equal(276)
	assert_int(single_games).is_equal(30)


func _matchup_signature(schedule: Array) -> String:
	var parts: Array = []
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		parts.append("%d-%d-%d" % [
			int(game.get("day", 0)),
			int(game.get("away_team_id", 0)),
			int(game.get("home_team_id", 0)),
		])
	return "|".join(parts)


func _series_groups(schedule: Array) -> Dictionary:
	var groups: Dictionary = {}
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		var key: String = str(game.get("series_id", -1))
		var games: Array = groups.get(key, []) as Array
		games.append(game)
		groups[key] = games
	return groups


func _assert_three_game_series(series_games: Array) -> void:
	series_games.sort_custom(func(a, b) -> bool:
		var game_a: Dictionary = a as Dictionary
		var game_b: Dictionary = b as Dictionary
		return int(game_a.get("day", 0)) < int(game_b.get("day", 0))
	)
	var first_game: Dictionary = series_games[0] as Dictionary
	for index in range(series_games.size()):
		var game: Dictionary = series_games[index] as Dictionary
		assert_int(int(game.get("away_team_id", 0))).is_equal(int(first_game.get("away_team_id", 0)))
		assert_int(int(game.get("home_team_id", 0))).is_equal(int(first_game.get("home_team_id", 0)))
		assert_int(int(game.get("day", 0))).is_equal(int(first_game.get("day", 0)) + index)
		assert_str(str(game.get("date", ""))).is_equal(SeasonCalendar.add_days(str(first_game.get("date", "")), index))
