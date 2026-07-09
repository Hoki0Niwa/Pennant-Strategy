extends GdUnitTestSuite

const SeasonCalendar = preload("res://services/season/season_calendar.gd")
const JapaneseHolidays = preload("res://services/season/japanese_holidays.gd")


func before() -> void:
	if GameDb.teams.is_empty():
		GameDb.load_initial_data()


func test_template_schedule_has_pennant_invariants() -> void:
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var validation: Dictionary = PSSchedule.validate_schedule(schedule, GameDb.teams)

	assert_bool(bool(validation.get("ok", false))).is_true()
	assert_int(schedule.size()).is_equal(PSSchedule.EXPECTED_TOTAL_GAMES)


func test_schedule_stays_valid_across_centuries() -> void:
	# 「何百年もペナントを回し続ける」運用を想定し、祝日月曜(春分・秋分の近似式含む)を
	# 反映した日程生成が遠い未来の年度でも不変条件を壊さないことを確認する。
	for year in [2026, 2100, 2200, 2300, 2400, 2500, 2600]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var validation: Dictionary = PSSchedule.validate_schedule(schedule, GameDb.teams)
		assert_bool(bool(validation.get("ok", false))).override_failure_message(
			"Schedule invalid for year %d: %s" % [year, str(validation.get("message", ""))]
		).is_true()
		assert_int(schedule.size()).is_equal(PSSchedule.EXPECTED_TOTAL_GAMES)


func test_japanese_holidays_known_2026_dates() -> void:
	# 固定日 (元日) / ハッピーマンデー (海の日=7月第3月曜) / 春分・秋分の近似式 の各経路を確認する。
	assert_bool(JapaneseHolidays.is_holiday("2026-01-01")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-07-20")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-03-20")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-09-23")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-07-21")).is_false()


func test_japanese_holidays_substitute_holiday_for_sunday() -> void:
	# 2026年の憲法記念日(5/3)は日曜。5/4・5/5は既に祝日(みどりの日/こどもの日)なので、
	# 振替休日は最初の非祝日である5/6(水)にずれる。
	assert_int(SeasonCalendar.weekday_for_date("2026-05-03")).is_equal(0)
	assert_bool(JapaneseHolidays.is_holiday("2026-05-04")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-05-05")).is_true()
	assert_bool(JapaneseHolidays.is_holiday("2026-05-06")).is_true()
	assert_str(str(JapaneseHolidays.holidays_for_year(2026).get("2026-05-06", ""))).is_equal("振替休日")


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


func test_no_non_holiday_monday_games() -> void:
	# 月曜開催は祝日(海の日など)のみ許容する。それ以外の月曜に試合が入っていないことを確認する。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)

	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		var date_text: String = str(game.get("date", ""))
		if SeasonCalendar.weekday_for_date(date_text) == 1:
			assert_bool(JapaneseHolidays.is_holiday(date_text)).override_failure_message(
				"Unexpected non-holiday Monday game: %s" % date_text
			).is_true()


func test_holiday_monday_becomes_a_game_day() -> void:
	# 2026年の海の日(7/20, 月)は移動日ではなく3連戦の初日として試合が組まれる。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var has_game_on_marine_day: bool = false
	for game_value in schedule:
		if str((game_value as Dictionary).get("date", "")) == "2026-07-20":
			has_game_on_marine_day = true
			break
	assert_bool(has_game_on_marine_day).is_true()


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


func test_interleague_is_followed_by_one_rest_card_then_friday_restart() -> void:
	# 交流戦最終カード(〜06-14)直後の1カードは休養日にし、リーグ戦は次のFriカード(06-19)から再開する。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var dates_with_games: Dictionary = {}
	for game_value in schedule:
		var date_text: String = str((game_value as Dictionary).get("date", ""))
		dates_with_games[date_text] = true

	for rest_date in ["2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18"]:
		assert_bool(dates_with_games.has(rest_date)).override_failure_message(
			"Expected no games on %s (post-interleague rest card)" % rest_date
		).is_false()

	for restart_date in ["2026-06-19", "2026-06-20", "2026-06-21"]:
		assert_bool(dates_with_games.has(restart_date)).override_failure_message(
			"Expected league play to resume on %s" % restart_date
		).is_true()


func test_interleague_home_away_swaps_every_two_years() -> void:
	# 実球団の対戦カード(central id=1 vs pacific id=7)は2年間同じ側がホーム→次の2年で反転、を
	# バケットのシャッフルに関係なく維持する(交流戦の主催権は球団ID固定+年度2年周期で決まる)。
	var home_by_year: Dictionary = {}
	for year in [2026, 2027, 2028, 2029, 2030, 2031]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var home_id: int = -1
		for game_value in schedule:
			var game: Dictionary = game_value as Dictionary
			if not bool(game.get("is_interleague", false)):
				continue
			var away_id: int = int(game.get("away_team_id", 0))
			var home_team_id: int = int(game.get("home_team_id", 0))
			if (away_id == 1 and home_team_id == 7) or (away_id == 7 and home_team_id == 1):
				home_id = home_team_id
				break
		assert_int(home_id).override_failure_message("No interleague game found between team 1 and team 7 in %d" % year).is_not_equal(-1)
		home_by_year[year] = home_id

	assert_int(int(home_by_year[2026])).is_equal(int(home_by_year[2027]))
	assert_int(int(home_by_year[2028])).is_equal(int(home_by_year[2029]))
	assert_int(int(home_by_year[2030])).is_equal(int(home_by_year[2031]))
	assert_int(int(home_by_year[2026])).is_not_equal(int(home_by_year[2028]))
	assert_int(int(home_by_year[2028])).is_not_equal(int(home_by_year[2030]))
	assert_int(int(home_by_year[2026])).is_equal(int(home_by_year[2030]))


func test_intraleague_series_lengths_mix_one_to_three_games() -> void:
	# 現実のNPBは同一カードの余り試合を「単独1試合」だけでなく「2連戦」でも組んでおり
	# (2026年公式日程を12球団分検証して確認、docs/agent_memory 参照)、本実装も巡ごとに
	# 1〜3試合の可変長カードを許容する。交流戦は常に3連戦のまま。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var groups: Dictionary = _series_groups(schedule)
	var length_counts: Dictionary = {1: 0, 2: 0, 3: 0}

	for series_key in groups.keys():
		var series_games: Array = groups.get(series_key, []) as Array
		var size: int = series_games.size()
		var sample: Dictionary = series_games[0] as Dictionary
		var is_interleague: bool = bool(sample.get("is_interleague", false))
		if is_interleague:
			assert_int(size).override_failure_message("Interleague series %s should always be 3 games" % str(series_key)).is_equal(3)
		else:
			assert_bool(size == 1 or size == 2 or size == 3).override_failure_message(
				"Unexpected intra-league series size %d for %s" % [size, str(series_key)]
			).is_true()
		length_counts[size] = int(length_counts.get(size, 0)) + 1
		_assert_consistent_series(series_games)

	assert_int(int(length_counts.get(1, 0))).override_failure_message("Expected at least one single-game series").is_greater(0)
	assert_int(int(length_counts.get(2, 0))).override_failure_message("Expected at least one two-game series").is_greater(0)
	assert_int(int(length_counts.get(3, 0))).override_failure_message("Expected most series to remain three-game").is_greater(0)


func test_single_game_series_only_occur_in_september_or_later() -> void:
	# 単独1試合(length=1)は9月以降限定で組む(ユーザー指摘、2026-07-08: 火水木カードの
	# 「水曜移動日」を単独戦と誤認していたことの反省を踏まえ、真の単独戦は9月以降にのみ
	# 現れるよう再設計した)。2連戦にはこの制約は適用しない(4-9月に分散するのが正しい実データ、
	# 既存の派生調査を参照)。
	for year in [2026, 2027, 2028, 2029, 2030, 2100]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var groups: Dictionary = _series_groups(schedule)
		for series_key in groups.keys():
			var series_games: Array = groups.get(series_key, []) as Array
			var sample: Dictionary = series_games[0] as Dictionary
			if bool(sample.get("is_interleague", false)) or series_games.size() != 1:
				continue
			var date_text: String = str(sample.get("date", ""))
			var month: int = int(date_text.split("-")[1])
			assert_int(month).override_failure_message(
				"Year %d: single-game series %s found before September (%s)" % [year, str(series_key), date_text]
			).is_greater_equal(9)


func test_teams_never_get_a_three_day_rest_gap_around_shortened_series() -> void:
	# 固定週間隔カレンダー(火水木/金土日)上で、2連戦(火水木は木曜休養、金土日は金曜休養)は
	# 同じ週の相方が短縮されない限り休養1日以内に収まる。単独1試合はどちらの曜日に置いても
	# 構造上どちらか片側が2日休養になる(火水木なら火のみ→水木休養、金土日ならどこに置いても
	# 反対側が2日空く)ため、休養2日は許容する。ただし同じ週の両カードを同時に短縮すると
	# 木・金と2日連続休養(=3日ギャップ)になってしまうため、_intraleague_cycle_plans の
	# same_week_as_next 制約でこれを防ぎ、3日以上のギャップは発生しないことを確認する。
	# 交流戦の前後(参加準備・交流戦後の休養カード)とオールスター期間だけは
	# 意図的に長い空きがあるため、そこだけ例外として許容する。
	var base_opening: String = SeasonCalendar.opening_date_for_year(PSSchedule.TEMPLATE_BASE_YEAR)
	for year in [2026, 2027, 2100]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var target_opening: String = SeasonCalendar.opening_date_for_year(year)
		var all_star_start: String = PSSchedule._resolve_target_date(PSSchedule.TEMPLATE_ALL_STAR_START_DATE, base_opening, target_opening)
		var all_star_end: String = PSSchedule._resolve_target_date(PSSchedule.TEMPLATE_ALL_STAR_END_DATE, base_opening, target_opening)
		var interleague_start: String = ""
		var interleague_end: String = ""
		for game_value in schedule:
			var game: Dictionary = game_value as Dictionary
			if bool(game.get("is_interleague", false)):
				var date_text: String = str(game.get("date", ""))
				if interleague_start.is_empty() or date_text < interleague_start:
					interleague_start = date_text
				if interleague_end.is_empty() or date_text > interleague_end:
					interleague_end = date_text

		var team_ids: Array = []
		for team_row in GameDb.teams:
			team_ids.append((team_row as PSTeam).id)
		for team_id in team_ids:
			var dates: Array = []
			for game_value in schedule:
				var game: Dictionary = game_value as Dictionary
				if int(game.get("away_team_id", 0)) == int(team_id) or int(game.get("home_team_id", 0)) == int(team_id):
					dates.append(str(game.get("date", "")))
			dates.sort()
			for i in range(1, dates.size()):
				var prev_date: String = str(dates[i - 1])
				var curr_date: String = str(dates[i])
				var gap: int = SeasonCalendar.days_between(prev_date, curr_date) - 1
				if gap <= 2:
					continue
				# 交流戦の前後(参加準備+直後の休養カード)、オールスター期間は意図的に
				# 長い空きを許容する。
				var near_interleague: bool = gap <= 10 and (
					(prev_date <= interleague_start and curr_date >= interleague_start) \
					or (prev_date >= interleague_start and prev_date <= interleague_end)
				)
				var near_all_star: bool = gap <= 10 and prev_date <= all_star_end and curr_date >= all_star_start
				assert_bool(near_interleague or near_all_star).override_failure_message(
					"Year %d: team %d has an unexpected %d-day rest gap between %s and %s" % [
						year, team_id, gap, prev_date, curr_date
					]
				).is_true()


func test_golden_week_series_stay_full_length_and_form_nine_game_bridge() -> void:
	# ゴールデンウィーク(4/27-5/7)は現実のNPBで移動日なしの9連戦が組まれる期間なので、
	# この期間に重なるカードは短縮(2連戦/単独1試合)の対象外であることを確認する。
	# あわせて、少なくとも1球団がこの期間にオフ日なしで9試合以上連続消化することも確認する
	# (=実際の「GW9連戦」を再現できていること)。
	for year in [2026, 2027, 2100]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var groups: Dictionary = _series_groups(schedule)

		for series_key in groups.keys():
			var series_games: Array = groups[series_key] as Array
			var sample: Dictionary = series_games[0] as Dictionary
			if bool(sample.get("is_interleague", false)):
				continue
			var overlaps_gw: bool = false
			for game_value in series_games:
				if _date_is_in_golden_week(str((game_value as Dictionary).get("date", ""))):
					overlaps_gw = true
					break
			if overlaps_gw:
				assert_int(series_games.size()).override_failure_message(
					"Year %d: series %s overlapping golden week should stay a full 3-game series, got %d" % [
						year, str(series_key), series_games.size()
					]
				).is_equal(3)

		var team_ids: Array = []
		for team_row in GameDb.teams:
			team_ids.append((team_row as PSTeam).id)
		var found_nine_game_bridge: bool = false
		for team_id in team_ids:
			var dates: Array = []
			for game_value in schedule:
				var game: Dictionary = game_value as Dictionary
				if int(game.get("away_team_id", 0)) == int(team_id) or int(game.get("home_team_id", 0)) == int(team_id):
					dates.append(str(game.get("date", "")))
			dates.sort()
			var streak_start: int = 0
			for i in range(1, dates.size() + 1):
				if i < dates.size() and SeasonCalendar.days_between(str(dates[i - 1]), str(dates[i])) == 1:
					continue
				var streak_len: int = i - streak_start
				if streak_len >= 9:
					var overlaps_gw_streak: bool = false
					for d in range(streak_start, i):
						if _date_is_in_golden_week(str(dates[d])):
							overlaps_gw_streak = true
							break
					if overlaps_gw_streak:
						found_nine_game_bridge = true
				streak_start = i
			if found_nine_game_bridge:
				break
		assert_bool(found_nine_game_bridge).override_failure_message(
			"Year %d: expected at least one team to play a 9-game bridge (no rest day) around golden week" % year
		).is_true()


func _date_is_in_golden_week(date_text: String) -> bool:
	var parts: PackedStringArray = date_text.split("-")
	if parts.size() != 3:
		return false
	var month: int = int(parts[1])
	var day: int = int(parts[2])
	return (month == 4 and day >= 27) or (month == 5 and day <= 7)


func test_series_right_after_long_breaks_stay_full_length() -> void:
	# 開幕戦・交流戦明け・オールスター明けは、長い休養(オフシーズン/交流戦の休養カード/
	# オールスター休養)の直後に短縮カード(1・2連戦)が来ると不自然なため、必ず3連戦になる
	# ことを確認する(ユーザー指摘、2026-07-08)。intra_days はセ・パ共通なので、該当日には
	# 両リーグそれぞれのカードが存在し、どちらも3連戦であることを確認する。
	var base_opening: String = SeasonCalendar.opening_date_for_year(PSSchedule.TEMPLATE_BASE_YEAR)
	for year in [2026, 2027, 2100]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var target_opening: String = SeasonCalendar.opening_date_for_year(year)
		var all_star_end: String = PSSchedule._resolve_target_date(PSSchedule.TEMPLATE_ALL_STAR_END_DATE, base_opening, target_opening)
		var interleague_end: String = ""
		for game_value in schedule:
			var game: Dictionary = game_value as Dictionary
			if bool(game.get("is_interleague", false)):
				var date_text: String = str(game.get("date", ""))
				if interleague_end.is_empty() or date_text > interleague_end:
					interleague_end = date_text

		var groups: Dictionary = _series_groups(schedule)
		var intra_series: Array = []
		for series_key in groups.keys():
			var series_games: Array = groups[series_key] as Array
			var sample: Dictionary = series_games[0] as Dictionary
			if bool(sample.get("is_interleague", false)):
				continue
			var start_date: String = ""
			for game_value in series_games:
				var d: String = str((game_value as Dictionary).get("date", ""))
				if start_date.is_empty() or d < start_date:
					start_date = d
			intra_series.append({"games": series_games, "start_date": start_date})

		var opening_date: String = _earliest_start_date(intra_series, "")
		_assert_all_series_on_date_are_full_length(intra_series, opening_date, year, "opening day")

		var post_interleague_date: String = _earliest_start_date(intra_series, interleague_end)
		_assert_all_series_on_date_are_full_length(intra_series, post_interleague_date, year, "right after interleague")

		var post_all_star_date: String = _earliest_start_date(intra_series, all_star_end)
		_assert_all_series_on_date_are_full_length(intra_series, post_all_star_date, year, "right after the all-star break")


# intra_series のうち start_date > after (after が空なら制約なし) を満たす最も早い start_date を返す。
func _earliest_start_date(intra_series: Array, after: String) -> String:
	var earliest: String = ""
	for entry_value in intra_series:
		var d: String = str((entry_value as Dictionary).get("start_date", ""))
		if not after.is_empty() and d <= after:
			continue
		if earliest.is_empty() or d < earliest:
			earliest = d
	return earliest


func _assert_all_series_on_date_are_full_length(intra_series: Array, target_date: String, year: int, label: String) -> void:
	assert_bool(target_date.is_empty()).override_failure_message(
		"Year %d: could not find any series for %s" % [year, label]
	).is_false()
	var checked: int = 0
	for entry_value in intra_series:
		var entry: Dictionary = entry_value as Dictionary
		if str(entry.get("start_date", "")) != target_date:
			continue
		checked += 1
		var games: Array = entry.get("games", []) as Array
		assert_int(games.size()).override_failure_message(
			"Year %d: series %s should be a full 3-game series, got %d" % [year, label, games.size()]
		).is_equal(3)
	assert_int(checked).override_failure_message(
		"Year %d: expected at least one series for %s" % [year, label]
	).is_greater(0)


func test_intraleague_pairs_each_play_exactly_25_games() -> void:
	# 同一リーグの各カード(2球団の組)は「3連戦の本数×3 + 短縮分」の合計が必ず25試合になる。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var games_by_pair: Dictionary = {}
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("is_interleague", false)):
			continue
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		var pair_key: String = "%d-%d" % [min(away_id, home_id), max(away_id, home_id)]
		games_by_pair[pair_key] = int(games_by_pair.get(pair_key, 0)) + 1

	assert_int(games_by_pair.size()).is_equal(30) # 6球団から2つ選ぶ組み合わせ(15)×2リーグ
	for pair_key in games_by_pair.keys():
		assert_int(int(games_by_pair[pair_key])).override_failure_message(
			"Pair %s should play exactly 25 intra-league games" % str(pair_key)
		).is_equal(25)


func test_intraleague_opponents_never_repeat_consecutively() -> void:
	# 同一リーグの対戦順は5カードで1巡する構造は変わらないが、巡目ごとの順番はシャッフルされる。
	# ラウンドロビンの性質上、巡内は相手が全て異なるはずだが、巡の変わり目(前巡最終カード→
	# 次巡初戦)だけは同じ相手が連続しうるため、そこを含めて連続対戦が無いことを複数年度で確認する。
	for year in [2026, 2027, 2100, 2500]:
		var season_number: int = year - 2025
		var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, year, season_number)
		var groups: Dictionary = _series_groups(schedule)
		var opponent_log_by_team: Dictionary = {}

		for series_key in groups.keys():
			var series_games: Array = groups[series_key] as Array
			var sample: Dictionary = series_games[0] as Dictionary
			if bool(sample.get("is_interleague", false)):
				continue
			var away_id: int = int(sample.get("away_team_id", 0))
			var home_id: int = int(sample.get("home_team_id", 0))
			var first_day: int = int(sample.get("day", 0))
			for game_value in series_games:
				first_day = min(first_day, int((game_value as Dictionary).get("day", first_day)))
			_append_opponent_entry(opponent_log_by_team, away_id, first_day, home_id)
			_append_opponent_entry(opponent_log_by_team, home_id, first_day, away_id)

		for team_id in opponent_log_by_team.keys():
			var entries: Array = opponent_log_by_team[team_id] as Array
			entries.sort_custom(func(a, b) -> bool:
				return int((a as Dictionary).get("day", 0)) < int((b as Dictionary).get("day", 0))
			)
			for i in range(1, entries.size()):
				var prev: Dictionary = entries[i - 1] as Dictionary
				var curr: Dictionary = entries[i] as Dictionary
				assert_int(int(curr.get("opponent", -2))).override_failure_message(
					"Year %d: team %s faces opponent %d on consecutive intra-league series (day %d -> %d)" % [
						year, str(team_id), int(curr.get("opponent", -2)), int(prev.get("day", 0)), int(curr.get("day", 0))
					]
				).is_not_equal(int(prev.get("opponent", -1)))


func test_round_orders_for_cycles_shuffle_without_boundary_repeats() -> void:
	# 巡ごとのカード順シャッフル本体 (_round_orders_for_cycles) を直接検証する:
	# 各巡は5カード全てを含む順列であること、巡の変わり目で同じカードが連続しないこと、
	# 全巡が固定順(0,1,2,3,4の繰り返し)ではなく実際にシャッフルされていること。
	var orders: Array = PSSchedule._round_orders_for_cycles(PSSchedule.INTRALEAGUE_CYCLES, 424242)
	assert_int(orders.size()).is_equal(PSSchedule.INTRALEAGUE_CYCLES)
	var previous_last: int = -1
	var saw_non_identity: bool = false
	for cycle_index in range(orders.size()):
		var perm: Array = orders[cycle_index] as Array
		assert_int(perm.size()).is_equal(PSSchedule.ROUNDS_PER_CYCLE)
		var seen: Dictionary = {}
		for value in perm:
			assert_bool(seen.has(int(value))).is_false()
			seen[int(value)] = true
		if previous_last != -1:
			assert_int(int(perm[0])).is_not_equal(previous_last)
		if perm != [0, 1, 2, 3, 4]:
			saw_non_identity = true
		previous_last = int(perm[perm.size() - 1])
	assert_bool(saw_non_identity).is_true()


func test_intraleague_cycle_plans_always_sum_to_25_with_valid_lengths() -> void:
	# _intraleague_cycle_plans 本体を直接検証する: 各 round_index の長さ合計が必ず25、
	# 長さは1/2/3のみ、かつ「12側」(designated_home=false)の合計が必ず12になること
	# (=designated側は必ず13になる)を、複数シードで確認する。
	var no_protected_cycles_by_round: Array = []
	for round_index in range(PSSchedule.ROUNDS_PER_CYCLE):
		var flags: Array = []
		for i in range(PSSchedule.INTRALEAGUE_CYCLES):
			flags.append(false)
		no_protected_cycles_by_round.append(flags)
	var no_same_week_as_next: Array = []
	for i in range(PSSchedule.INTRALEAGUE_CYCLES * PSSchedule.ROUNDS_PER_CYCLE):
		no_same_week_as_next.append(false)
	var all_september: Array = []
	for round_index in range(PSSchedule.ROUNDS_PER_CYCLE):
		var flags: Array = []
		for i in range(PSSchedule.INTRALEAGUE_CYCLES):
			flags.append(true)
		all_september.append(flags)
	for seed in [88001, 271828, 424242, 999983]:
		var round_orders: Array = PSSchedule._round_orders_for_cycles(PSSchedule.INTRALEAGUE_CYCLES, seed)
		var plans: Array = PSSchedule._intraleague_cycle_plans(PSSchedule.INTRALEAGUE_CYCLES, round_orders, seed, no_protected_cycles_by_round, no_same_week_as_next, all_september)
		assert_int(plans.size()).is_equal(PSSchedule.ROUNDS_PER_CYCLE)
		for plan_value in plans:
			var plan: Dictionary = plan_value as Dictionary
			var lengths: Array = plan.get("lengths", []) as Array
			var designated_home: Array = plan.get("designated_home", []) as Array
			assert_int(lengths.size()).is_equal(PSSchedule.INTRALEAGUE_CYCLES)
			assert_int(designated_home.size()).is_equal(PSSchedule.INTRALEAGUE_CYCLES)

			var total: int = 0
			var other_total: int = 0
			for i in range(lengths.size()):
				var length: int = int(lengths[i])
				assert_bool(length == 1 or length == 2 or length == 3).override_failure_message(
					"Unexpected cycle length %d" % length
				).is_true()
				total += length
				if not bool(designated_home[i]):
					other_total += length
			assert_int(total).override_failure_message("Cycle lengths for round should sum to 25").is_equal(25)
			assert_int(other_total).override_failure_message("Non-designated side should total exactly 12 games").is_equal(12)


func _append_opponent_entry(log_by_team: Dictionary, team_id: int, day: int, opponent_id: int) -> void:
	var key: String = str(team_id)
	var entries: Array = log_by_team.get(key, []) as Array
	entries.append({"day": day, "opponent": opponent_id})
	log_by_team[key] = entries


func test_schedule_is_sorted_by_day_with_interleague_mid_season() -> void:
	# 配列が day 昇順であること (シミュレータが配列順 == 日付順を前提にしているため必須)。
	var schedule: Array = PSSchedule.generate_pennant_schedule(GameDb.teams, PSSchedule.PENNANT_GAMES_PER_TEAM, {}, 2026, 1)
	var prev_day: int = 0
	for game_value in schedule:
		var day: int = int((game_value as Dictionary).get("day", 0))
		assert_int(day).is_greater_equal(prev_day)
		prev_day = day

	# 交流戦はシーズン中盤に挟まる: 最後の交流戦より後に通常(非交流戦)の試合が存在する。
	var max_interleague_day: int = 0
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		if bool(game.get("is_interleague", false)):
			max_interleague_day = max(max_interleague_day, int(game.get("day", 0)))
	assert_int(max_interleague_day).is_greater(0)
	var has_intra_after_interleague: bool = false
	for game_value in schedule:
		var game: Dictionary = game_value as Dictionary
		if not bool(game.get("is_interleague", false)) and int(game.get("day", 0)) > max_interleague_day:
			has_intra_after_interleague = true
			break
	assert_bool(has_intra_after_interleague).is_true()


func test_month_end_boundary_helpers() -> void:
	# 月末日付の算出 (うるう年含む)。
	assert_str(SeasonCalendar.last_day_of_month("2026-03-15")).is_equal("2026-03-31")
	assert_str(SeasonCalendar.last_day_of_month("2026-02-10")).is_equal("2026-02-28")
	assert_str(SeasonCalendar.last_day_of_month("2028-02-10")).is_equal("2028-02-29")
	assert_str(SeasonCalendar.last_day_of_month("2026-12-05")).is_equal("2026-12-31")

	var season: PSSeason = SeasonService.create_new_season(GameDb.teams, 1, 2026, {})
	# season_day_for_date は date_for_season_day の逆変換。
	for day in [1, 5, 30, 120]:
		var date_text: String = SeasonCalendar.date_for_season_day(season, day)
		assert_int(SeasonCalendar.season_day_for_date(season, date_text)).is_equal(day)

	# 開幕月(3月)の月末 day index を境界に、当月の試合は <=、翌月以降は > になる。
	var end_date: String = SeasonCalendar.last_day_of_month(SeasonCalendar.current_date(season))
	var end_day: int = SeasonCalendar.season_day_for_date(season, end_date)
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		var month: int = int(str(game.get("date", "")).split("-")[1])
		if month == 3:
			assert_int(int(game.get("day", 0))).is_less_equal(end_day)
		elif month >= 4:
			assert_int(int(game.get("day", 0))).is_greater(end_day)


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


func _assert_consistent_series(series_games: Array) -> void:
	# 同一カードは同じ対戦相手・同じ日付順で並び、日付の飛びは非祝日の月曜スキップ
	# (_advance_game_days 参照)以外に存在しないことを確認する。
	series_games.sort_custom(func(a, b) -> bool:
		var game_a: Dictionary = a as Dictionary
		var game_b: Dictionary = b as Dictionary
		return int(game_a.get("day", 0)) < int(game_b.get("day", 0))
	)
	var first_game: Dictionary = series_games[0] as Dictionary
	var prev_date: String = ""
	for index in range(series_games.size()):
		var game: Dictionary = series_games[index] as Dictionary
		assert_int(int(game.get("away_team_id", 0))).is_equal(int(first_game.get("away_team_id", 0)))
		assert_int(int(game.get("home_team_id", 0))).is_equal(int(first_game.get("home_team_id", 0)))
		var date_text: String = str(game.get("date", ""))
		if index > 0:
			var gap_date: String = prev_date
			while SeasonCalendar.days_between(gap_date, date_text) > 1:
				gap_date = SeasonCalendar.add_days(gap_date, 1)
				assert_int(SeasonCalendar.weekday_for_date(gap_date)).override_failure_message(
					"Series has an unexpected non-Monday gap day %s" % gap_date
				).is_equal(1)
				assert_bool(JapaneseHolidays.is_holiday(gap_date)).override_failure_message(
					"Series skips %s but it is not a holiday" % gap_date
				).is_false()
		prev_date = date_text
