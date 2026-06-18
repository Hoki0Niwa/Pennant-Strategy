extends RefCounted
class_name PSSchedule

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const PENNANT_GAMES_PER_TEAM: int = 143
const DEFAULT_YEAR_FOR_SCHEDULE: int = 2026
const TEMPLATE_ID: String = "npb_calendar_template_v1"
const TEMPLATE_PATH: String = "res://data/schedule_templates/npb_calendar_template.csv"
const TEMPLATE_BASE_YEAR: int = 2026
const EXPECTED_TOTAL_GAMES: int = 858
const EXPECTED_INTERLEAGUE_GAMES_PER_TEAM: int = 18
const ROUNDS_PER_CYCLE: int = 5
const INTRALEAGUE_THREE_GAME_BLOCKS: int = 40
const INTERLEAGUE_THREE_GAME_BLOCKS: int = 6
const SINGLE_GAME_DATES: int = 5
const GAMES_PER_SERIES: int = 3
const WEEKDAY_SUNDAY: int = 0
const WEEKDAY_MONDAY: int = 1
const WEEKDAY_TUESDAY: int = 2
const WEEKDAY_FRIDAY: int = 5
const TEMPLATE_INTERLEAGUE_START_DATE: String = "2026-05-26"
const TEMPLATE_INTERLEAGUE_END_DATE: String = "2026-06-14"
const TEMPLATE_ALL_STAR_START_DATE: String = "2026-07-28"
const TEMPLATE_ALL_STAR_END_DATE: String = "2026-07-29"


static func generate_pennant_schedule(
	teams: Array,
	games_per_team: int = PENNANT_GAMES_PER_TEAM,
	dh_by_league: Dictionary = {},
	year: int = DEFAULT_YEAR_FOR_SCHEDULE,
	season_number: int = 1
) -> Array:
	if games_per_team != PENNANT_GAMES_PER_TEAM:
		push_warning("games_per_team override is ignored in NPB-style schedule.")

	var team_rows: Array = teams.duplicate()
	team_rows.sort_custom(func(a, b) -> bool:
		var team_a: PSTeam = a as PSTeam
		var team_b: PSTeam = b as PSTeam
		return team_a.id < team_b.id
	)

	var centrals: Array = []
	var pacifics: Array = []
	var leagues_by_team_id: Dictionary = {}
	for team_row in team_rows:
		var team: PSTeam = team_row as PSTeam
		leagues_by_team_id[team.id] = team.league
		if team.league == "central":
			centrals.append(team.id)
		else:
			pacifics.append(team.id)

	if centrals.size() != 6 or pacifics.size() != 6:
		push_warning("Pennant schedule requires 6 central + 6 pacific teams.")
		return []

	var template_rows: Array = _load_template_rows()
	var games: Array = _schedule_from_template(
		template_rows, centrals, pacifics, leagues_by_team_id, dh_by_league, year, season_number
	)
	var validation: Dictionary = validate_schedule(games, team_rows)
	if not bool(validation.get("ok", false)):
		push_error("Invalid pennant schedule: %s" % str(validation.get("message", "")))
		return []
	return games


static func bucket_seed_for_season(year: int, season_number: int) -> int:
	return year * 1009 + season_number * 9173 + 143


static func validate_schedule(games: Array, teams: Array) -> Dictionary:
	if games.size() != EXPECTED_TOTAL_GAMES:
		return {"ok": false, "message": "expected %d games, got %d" % [EXPECTED_TOTAL_GAMES, games.size()]}

	var team_ids: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		team_ids.append(team.id)

	var games_by_team: Dictionary = {}
	var interleague_by_team: Dictionary = {}
	var home_by_team: Dictionary = {}
	var teams_by_day: Dictionary = {}
	for team_id in team_ids:
		games_by_team[team_id] = 0
		interleague_by_team[team_id] = 0
		home_by_team[team_id] = 0

	for game_row in games:
		var game: Dictionary = game_row as Dictionary
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		var day: int = int(game.get("day", 0))
		var date_text: String = str(game.get("date", ""))
		if date_text.is_empty():
			return {"ok": false, "message": "missing date on day %d" % day}
		if SeasonCalendar.weekday_for_date(date_text) == WEEKDAY_MONDAY:
			return {"ok": false, "message": "game scheduled on Monday: %s" % date_text}
		if away_id == home_id or not team_ids.has(away_id) or not team_ids.has(home_id):
			return {"ok": false, "message": "invalid teams on day %d" % day}
		var day_key: String = str(day)
		var used: Dictionary = teams_by_day.get(day_key, {}) as Dictionary
		if used.has(away_id) or used.has(home_id):
			return {"ok": false, "message": "team scheduled twice on day %d" % day}
		used[away_id] = true
		used[home_id] = true
		teams_by_day[day_key] = used

		games_by_team[away_id] = int(games_by_team.get(away_id, 0)) + 1
		games_by_team[home_id] = int(games_by_team.get(home_id, 0)) + 1
		home_by_team[home_id] = int(home_by_team.get(home_id, 0)) + 1
		if bool(game.get("is_interleague", false)):
			interleague_by_team[away_id] = int(interleague_by_team.get(away_id, 0)) + 1
			interleague_by_team[home_id] = int(interleague_by_team.get(home_id, 0)) + 1

	for team_id in team_ids:
		if int(games_by_team.get(team_id, 0)) != PENNANT_GAMES_PER_TEAM:
			return {"ok": false, "message": "team %d has %d games" % [team_id, int(games_by_team.get(team_id, 0))]}
		if int(interleague_by_team.get(team_id, 0)) != EXPECTED_INTERLEAGUE_GAMES_PER_TEAM:
			return {"ok": false, "message": "team %d has %d interleague games" % [team_id, int(interleague_by_team.get(team_id, 0))]}
		var home_games: int = int(home_by_team.get(team_id, 0))
		if home_games < 71 or home_games > 72:
			return {"ok": false, "message": "team %d has suspicious home games: %d" % [team_id, home_games]}

	return {"ok": true}


static func _schedule_from_template(
	template_rows: Array,
	centrals: Array,
	pacifics: Array,
	leagues_by_team_id: Dictionary,
	dh_by_league: Dictionary,
	year: int,
	season_number: int
) -> Array:
	var bucket_to_team: Dictionary = _bucket_assignment(centrals, pacifics, year, season_number)
	var opening_date: String = SeasonCalendar.opening_date_for_year(year)
	var base_opening_date: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	var games: Array = []
	var sequence_by_series: Dictionary = {}
	for row_value in template_rows:
		var row: Dictionary = row_value as Dictionary
		var template_date: String = "%04d-%02d-%02d" % [
			TEMPLATE_BASE_YEAR,
			int(row.get("template_month", 0)),
			int(row.get("template_day", 0)),
		]
		var day: int = SeasonCalendar.days_between(base_opening_date, template_date) + 1
		var date_text: String = SeasonCalendar.date_for_day(opening_date, day)
		var away_id: int = int(bucket_to_team.get(str(row.get("away_bucket", "")), 0))
		var home_id: int = int(bucket_to_team.get(str(row.get("home_bucket", "")), 0))
		var series_id: int = int(row.get("series_id", -1))
		var game_no: int = int(sequence_by_series.get(series_id, 0)) + 1
		sequence_by_series[series_id] = game_no
		games.append(_make_game(
			day,
			date_text,
			away_id,
			home_id,
			leagues_by_team_id,
			dh_by_league,
			bool(row.get("is_interleague", false)),
			series_id,
			game_no,
			int(row.get("cycle_number", -1))
		))
	return games


static func _bucket_assignment(centrals: Array, pacifics: Array, year: int, season_number: int) -> Dictionary:
	var central_order: Array = _deterministic_shuffle(centrals, bucket_seed_for_season(year, season_number))
	var pacific_order: Array = _deterministic_shuffle(pacifics, bucket_seed_for_season(year, season_number) + 7919)
	var out: Dictionary = {}
	for i in range(6):
		out["C%d" % (i + 1)] = int(central_order[i])
		out["P%d" % (i + 1)] = int(pacific_order[i])
	return out


static func _deterministic_shuffle(values: Array, seed: int) -> Array:
	var out: Array = values.duplicate()
	var state: int = seed & 0x7fffffff
	for i in range(out.size() - 1, 0, -1):
		state = int((1103515245 * state + 12345) & 0x7fffffff)
		var j: int = state % (i + 1)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


static func _load_template_rows() -> Array:
	var rows: Array = _read_template_csv(TEMPLATE_PATH)
	if rows.is_empty():
		rows = _generated_template_rows()
	if rows.size() != EXPECTED_TOTAL_GAMES:
		push_error("Schedule template %s has %d rows, expected %d." % [TEMPLATE_PATH, rows.size(), EXPECTED_TOTAL_GAMES])
		return []
	return rows


static func _read_template_csv(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var header: PackedStringArray = PackedStringArray()
	var rows: Array = []
	var line_no: int = 0
	while not file.eof_reached():
		var columns: PackedStringArray = file.get_csv_line()
		line_no += 1
		if columns.size() == 0 or (columns.size() == 1 and str(columns[0]).strip_edges().is_empty()):
			continue
		if str(columns[0]).begins_with("#"):
			continue
		if header.is_empty():
			header = columns
			continue
		if columns.size() != header.size():
			push_error("Bad schedule template row %d: expected %d columns, got %d" % [line_no, header.size(), columns.size()])
			return [{"invalid": true}]
		var row: Dictionary = {}
		for i in range(header.size()):
			row[str(header[i])] = str(columns[i])
		rows.append(_template_row_from_csv(row))
	return rows


static func _template_row_from_csv(row: Dictionary) -> Dictionary:
	return {
		"template_month": int(row.get("template_month", 0)),
		"template_day": int(row.get("template_day", 0)),
		"away_bucket": str(row.get("away_bucket", "")),
		"home_bucket": str(row.get("home_bucket", "")),
		"is_interleague": str(row.get("is_interleague", "false")).to_lower() == "true",
		"series_id": int(row.get("series_id", -1)),
		"cycle_number": int(row.get("cycle_number", -1)),
	}


static func _generated_template_rows() -> Array:
	var centrals: Array = []
	var pacifics: Array = []
	for i in range(1, 7):
		var central_bucket: String = "C%d" % i
		var pacific_bucket: String = "P%d" % i
		centrals.append(central_bucket)
		pacifics.append(pacific_bucket)

	var rows: Array = []
	var block_days: Dictionary = _template_three_game_block_days()
	var intra_days: Array = block_days.get("intra", []) as Array
	var interleague_days: Array = block_days.get("interleague", []) as Array
	if intra_days.size() != INTRALEAGUE_THREE_GAME_BLOCKS or interleague_days.size() != INTERLEAGUE_THREE_GAME_BLOCKS:
		push_error("Failed to build NPB-style calendar blocks.")
		return []

	var central_rounds: Array = _round_robin_rounds(centrals)
	var pacific_rounds: Array = _round_robin_rounds(pacifics)
	var series_id: int = 1

	for block_index in range(intra_days.size()):
		var round_index: int = block_index % ROUNDS_PER_CYCLE
		var cycle_number: int = int(block_index / ROUNDS_PER_CYCLE) + 1
		var series_specs: Array = []
		series_id = _append_intraleague_series_specs(
			series_specs,
			central_rounds[round_index] as Array,
			cycle_number,
			series_id
		)
		series_id = _append_intraleague_series_specs(
			series_specs,
			pacific_rounds[round_index] as Array,
			cycle_number,
			series_id
		)
		_append_three_game_series_rows(rows, int(intra_days[block_index]), series_specs)

	for card_index in range(interleague_days.size()):
		var interleague_specs: Array = []
		for central_index in range(centrals.size()):
			var pacific_index: int = (central_index + card_index) % pacifics.size()
			var c_id: String = str(centrals[central_index])
			var p_id: String = str(pacifics[pacific_index])
			var ha: Array = _interleague_home_pair(c_id, p_id, central_index, pacific_index)
			interleague_specs.append(_series_spec(str(ha[1]), str(ha[0]), true, series_id, -1))
			series_id += 1
		_append_three_game_series_rows(rows, int(interleague_days[card_index]), interleague_specs)

	var latest_block_start: int = 1
	for value in intra_days:
		latest_block_start = max(latest_block_start, int(value))
	for value in interleague_days:
		latest_block_start = max(latest_block_start, int(value))
	var single_days: Array = _template_single_game_days(latest_block_start + GAMES_PER_SERIES)
	var home_counts: Dictionary = {}
	for bucket in centrals:
		home_counts[str(bucket)] = 0
	for bucket in pacifics:
		home_counts[str(bucket)] = 0
	for round_index in range(SINGLE_GAME_DATES):
		series_id = _append_single_game_round_rows(
			rows,
			int(single_days[round_index]),
			central_rounds[round_index] as Array,
			home_counts,
			series_id,
			round_index
		)
		series_id = _append_single_game_round_rows(
			rows,
			int(single_days[round_index]),
			pacific_rounds[round_index] as Array,
			home_counts,
			series_id,
			round_index + ROUNDS_PER_CYCLE
		)

	return rows


static func _template_date_for_day(day: int) -> Dictionary:
	var base: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	var date_text: String = SeasonCalendar.date_for_day(base, day)
	var parts: PackedStringArray = date_text.split("-")
	return {"month": int(parts[1]), "day": int(parts[2])}


static func _make_template_row(day: int, away_bucket: String, home_bucket: String, is_interleague: bool, series_id: int, cycle_number: int) -> Dictionary:
	var date_parts: Dictionary = _template_date_for_day(day)
	return {
		"template_month": int(date_parts.get("month", 0)),
		"template_day": int(date_parts.get("day", 0)),
		"away_bucket": away_bucket,
		"home_bucket": home_bucket,
		"is_interleague": is_interleague,
		"series_id": series_id,
		"cycle_number": cycle_number,
	}


static func _template_three_game_block_days() -> Dictionary:
	var base_opening: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	var date_text: String = base_opening
	var intra_days: Array = []
	var interleague_days: Array = []
	var guard: int = 0
	while guard < 260 and (intra_days.size() < INTRALEAGUE_THREE_GAME_BLOCKS or interleague_days.size() < INTERLEAGUE_THREE_GAME_BLOCKS):
		var weekday: int = SeasonCalendar.weekday_for_date(date_text)
		if (weekday == WEEKDAY_TUESDAY or weekday == WEEKDAY_FRIDAY) and not _template_block_overlaps_all_star(date_text):
			var day: int = SeasonCalendar.days_between(base_opening, date_text) + 1
			if _template_date_in_range(date_text, TEMPLATE_INTERLEAGUE_START_DATE, TEMPLATE_INTERLEAGUE_END_DATE):
				if interleague_days.size() < INTERLEAGUE_THREE_GAME_BLOCKS:
					interleague_days.append(day)
			elif intra_days.size() < INTRALEAGUE_THREE_GAME_BLOCKS:
				intra_days.append(day)
		date_text = SeasonCalendar.add_days(date_text, 1)
		guard += 1
	return {"intra": intra_days, "interleague": interleague_days}


static func _template_single_game_days(start_day: int) -> Array:
	var base_opening: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	var day: int = start_day
	var days: Array = []
	while days.size() < SINGLE_GAME_DATES:
		var date_text: String = SeasonCalendar.date_for_day(base_opening, day)
		if SeasonCalendar.weekday_for_date(date_text) != WEEKDAY_MONDAY:
			days.append(day)
		day += 1
	return days


static func _template_block_overlaps_all_star(start_date: String) -> bool:
	for offset in range(GAMES_PER_SERIES):
		var date_text: String = SeasonCalendar.add_days(start_date, offset)
		if _template_date_in_range(date_text, TEMPLATE_ALL_STAR_START_DATE, TEMPLATE_ALL_STAR_END_DATE):
			return true
	return false


static func _template_date_in_range(date_text: String, start_date: String, end_date: String) -> bool:
	return SeasonCalendar.days_between(start_date, date_text) >= 0 and SeasonCalendar.days_between(date_text, end_date) >= 0


static func _append_intraleague_series_specs(specs: Array, pairs: Array, cycle_number: int, start_series_id: int) -> int:
	var series_id: int = start_series_id
	for pair_value in pairs:
		var pair: Array = pair_value as Array
		var ha: Array = _intraleague_home_pair(str(pair[0]), str(pair[1]), cycle_number)
		specs.append(_series_spec(str(ha[1]), str(ha[0]), false, series_id, cycle_number))
		series_id += 1
	return series_id


static func _append_three_game_series_rows(rows: Array, start_day: int, specs: Array) -> void:
	for game_offset in range(GAMES_PER_SERIES):
		for spec_value in specs:
			var spec: Dictionary = spec_value as Dictionary
			rows.append(_make_template_row(
				start_day + game_offset,
				str(spec.get("away_bucket", "")),
				str(spec.get("home_bucket", "")),
				bool(spec.get("is_interleague", false)),
				int(spec.get("series_id", -1)),
				int(spec.get("cycle_number", -1))
			))


static func _append_single_game_round_rows(
	rows: Array,
	day: int,
	pairs: Array,
	home_counts: Dictionary,
	start_series_id: int,
	salt: int
) -> int:
	var series_id: int = start_series_id
	for pair_value in pairs:
		var pair: Array = pair_value as Array
		var home_bucket: String = _single_home_bucket(str(pair[0]), str(pair[1]), home_counts, salt + series_id)
		var away_bucket: String = str(pair[1]) if home_bucket == str(pair[0]) else str(pair[0])
		rows.append(_make_template_row(day, away_bucket, home_bucket, false, series_id, -1))
		series_id += 1
	return series_id


static func _series_spec(away_bucket: String, home_bucket: String, is_interleague: bool, series_id: int, cycle_number: int) -> Dictionary:
	return {
		"away_bucket": away_bucket,
		"home_bucket": home_bucket,
		"is_interleague": is_interleague,
		"series_id": series_id,
		"cycle_number": cycle_number,
	}


static func _intraleague_home_pair(team_a: Variant, team_b: Variant, cycle_number: int) -> Array:
	var small_id: String = str(team_a) if str(team_a) < str(team_b) else str(team_b)
	var large_id: String = str(team_b) if str(team_a) < str(team_b) else str(team_a)
	if cycle_number % 2 == 1:
		return [small_id, large_id]
	return [large_id, small_id]


static func _interleague_home_pair(central_id: Variant, pacific_id: Variant, central_index: int, pacific_index: int) -> Array:
	if (central_index + pacific_index) % 2 == 0:
		return [central_id, pacific_id]
	return [pacific_id, central_id]


static func _single_home_bucket(bucket_a: String, bucket_b: String, home_counts: Dictionary, salt: int) -> String:
	var count_a: int = int(home_counts.get(bucket_a, 0))
	var count_b: int = int(home_counts.get(bucket_b, 0))
	var home_bucket: String = bucket_a
	if count_b < count_a:
		home_bucket = bucket_b
	elif count_a == count_b and _stable_bucket_value(bucket_b, salt) < _stable_bucket_value(bucket_a, salt):
		home_bucket = bucket_b
	home_counts[home_bucket] = int(home_counts.get(home_bucket, 0)) + 1
	return home_bucket


static func _stable_bucket_value(bucket: String, salt: int) -> int:
	var value: int = salt * 131
	for i in range(bucket.length()):
		value = int((value * 31 + bucket.unicode_at(i)) & 0x7fffffff)
	return value


static func _round_robin_rounds(team_ids: Array) -> Array:
	var rounds: Array = []
	var rotation: Array = team_ids.duplicate()
	for _round_index in range(ROUNDS_PER_CYCLE):
		var pairs: Array = []
		for pair_index in range(3):
			pairs.append([str(rotation[pair_index]), str(rotation[rotation.size() - 1 - pair_index])])
		rounds.append(pairs)
		var last: Variant = rotation.pop_back()
		rotation.insert(1, last)
	return rounds


static func _make_game(
	day: int,
	date_text: String,
	away_team_id: int,
	home_team_id: int,
	leagues_by_team_id: Dictionary,
	dh_by_league: Dictionary,
	is_interleague: bool,
	series_id: int,
	series_game_no: int,
	cycle_number: int
) -> Dictionary:
	var home_league: String = str(leagues_by_team_id.get(home_team_id, "central"))
	var dh_enabled: bool = bool(dh_by_league.get(home_league, true))
	return {
		"day": day,
		"date": date_text,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_score": 0,
		"home_score": 0,
		"played": false,
		"dh_enabled": dh_enabled,
		"innings": [],
		"result": {},
		"is_interleague": is_interleague,
		"series_id": series_id,
		"series_game_no": series_game_no,
		"cycle_number": cycle_number,
	}


static func _rotated_round_robin(team_ids: Array) -> Array:
	var rotated: Array = [team_ids[0], team_ids[team_ids.size() - 1]]
	for index in range(1, team_ids.size() - 1):
		rotated.append(team_ids[index])
	return rotated
