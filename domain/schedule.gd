extends RefCounted
class_name PSSchedule

const SeasonCalendar = preload("res://services/season/season_calendar.gd")
const JapaneseHolidays = preload("res://services/season/japanese_holidays.gd")

# NPB 風の143試合ペナント日程を、CSV テンプレートの「日付枠」と球団バケット割当から生成する。
# テンプレートは実日付の並びだけを持ち、年度ごとの球団割当は deterministic shuffle で変える。
# 生成結果は game Dictionary 配列で、シミュレータは day 昇順であることを前提に消化する。
const PENNANT_GAMES_PER_TEAM: int = 143
const DEFAULT_YEAR_FOR_SCHEDULE: int = 2026
const TEMPLATE_ID: String = "npb_calendar_template_v1"
const TEMPLATE_PATH: String = "res://data/schedule_templates/npb_calendar_template.csv"
const TEMPLATE_BASE_YEAR: int = 2026
const EXPECTED_TOTAL_GAMES: int = 858
const EXPECTED_INTERLEAGUE_GAMES_PER_TEAM: int = 18
const ROUNDS_PER_CYCLE: int = 5
# 同一リーグの対戦は5カード(ROUNDS_PER_CYCLE)を1巡として9巡行う。9巡×3試合=27では
# 25試合(1相手あたり)を超えるため、巡ごとに1〜2カードを短縮(2連戦か単独1試合)して
# ちょうど25試合に揃える。詳細は _intraleague_cycle_plans を参照。
const INTRALEAGUE_CYCLES: int = 9
const INTRALEAGUE_BLOCK_COUNT: int = INTRALEAGUE_CYCLES * ROUNDS_PER_CYCLE
const INTERLEAGUE_THREE_GAME_BLOCKS: int = 6
const GAMES_PER_SERIES: int = 3
const WEEKDAY_SUNDAY: int = 0
const WEEKDAY_MONDAY: int = 1
const WEEKDAY_TUESDAY: int = 2
const WEEKDAY_FRIDAY: int = 5
const TEMPLATE_INTERLEAGUE_START_DATE: String = "2026-05-26"
const TEMPLATE_INTERLEAGUE_END_DATE: String = "2026-06-14"
const TEMPLATE_ALL_STAR_START_DATE: String = "2026-07-28"
const TEMPLATE_ALL_STAR_END_DATE: String = "2026-07-29"
# ゴールデンウィーク(昭和の日4/29〜こどもの日5/5+振替)は現実のNPBで「移動日なしの9連戦」
# (3連戦を3本ノーブレークで繋げる)が組まれる期間なので、_intraleague_cycle_plans の
# 巡短縮(2連戦/単独1試合化)の対象から除外する。実際の9連戦(4/28-5/6の例)より前後1日
# 余裕を持たせた月日固定の範囲(年に依らない祝日なので month/day 比較で十分)。
const GOLDEN_WEEK_START_MONTH: int = 4
const GOLDEN_WEEK_START_DAY: int = 27
const GOLDEN_WEEK_END_MONTH: int = 5
const GOLDEN_WEEK_END_DAY: int = 7


# 12球団をリーグ別に並べ、テンプレート上の C1..C6/P1..P6 バケットへ割り当てて日程を作る。
# 現状は6球団×2リーグ専用で、生成後に validate_schedule で試合数・休養日・重複を検証する。
static func generate_pennant_schedule(
	teams: Array,
	games_per_team: int = PENNANT_GAMES_PER_TEAM,
	dh_by_league: Dictionary = {},
	year: int = DEFAULT_YEAR_FOR_SCHEDULE,
	season_number: int = 1
) -> Array:
	var expected_games_per_team: int = _rule_int("pennant_games_per_team", PENNANT_GAMES_PER_TEAM)
	if games_per_team != expected_games_per_team:
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

	var teams_per_league: int = _rule_int("teams_per_league", 6)
	if centrals.size() != teams_per_league or pacifics.size() != teams_per_league:
		push_warning("Pennant schedule requires %d central + %d pacific teams." % [teams_per_league, teams_per_league])
		return []
	if teams_per_league != 6:
		push_warning("Current NPB-style schedule generator only supports 6 teams per league.")
		return []

	var template_rows: Array = _load_template_rows(year, season_number)
	var games: Array = _schedule_from_template(
		template_rows, centrals, pacifics, leagues_by_team_id, dh_by_league, year, season_number
	)
	sort_by_day(games)
	var validation: Dictionary = validate_schedule(games, team_rows)
	if not bool(validation.get("ok", false)):
		push_error("Invalid pennant schedule: %s" % str(validation.get("message", "")))
		return []
	return games


# schedule を day 昇順(同日内は series_id / 試合番号)で安定整列する。
# シミュレータの _next_unplayed_game_index / advance_current_day は配列順 == 日付順を前提に
# しているため、交流戦ブロックなど後から append された日程が飛ばされないよう必ず整列する。
static func sort_by_day(games: Array) -> void:
	games.sort_custom(func(a, b) -> bool:
		var ga: Dictionary = a as Dictionary
		var gb: Dictionary = b as Dictionary
		var da: int = int(ga.get("day", 0))
		var db: int = int(gb.get("day", 0))
		if da != db:
			return da < db
		var sa: int = int(ga.get("series_id", 0))
		var sb: int = int(gb.get("series_id", 0))
		if sa != sb:
			return sa < sb
		return int(ga.get("series_game_no", 0)) < int(gb.get("series_game_no", 0))
	)


# 年度と season_number からバケットシャッフル用 seed を作る。
# 同じ年度/周回なら常に同じ日程、次年度や次周回ではカード配置が変わる。
static func bucket_seed_for_season(year: int, season_number: int) -> int:
	return year * 1009 + season_number * 9173 + 143


# 日程の不変条件をまとめて検査する。
# 総試合数、各球団143試合、交流戦18試合、月曜開催は祝日のみ、同日二重登録なし、ホーム試合数を確認する。
static func validate_schedule(games: Array, teams: Array) -> Dictionary:
	var expected_total_games: int = _rule_int("expected_total_games", EXPECTED_TOTAL_GAMES)
	var expected_games_per_team: int = _rule_int("pennant_games_per_team", PENNANT_GAMES_PER_TEAM)
	var expected_interleague_games_per_team: int = _rule_int("expected_interleague_games_per_team", EXPECTED_INTERLEAGUE_GAMES_PER_TEAM)
	if games.size() != expected_total_games:
		return {"ok": false, "message": "expected %d games, got %d" % [expected_total_games, games.size()]}

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
		if SeasonCalendar.weekday_for_date(date_text) == WEEKDAY_MONDAY and not JapaneseHolidays.is_holiday(date_text):
			return {"ok": false, "message": "game scheduled on non-holiday Monday: %s" % date_text}
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
		if int(games_by_team.get(team_id, 0)) != expected_games_per_team:
			return {"ok": false, "message": "team %d has %d games" % [team_id, int(games_by_team.get(team_id, 0))]}
		if int(interleague_by_team.get(team_id, 0)) != expected_interleague_games_per_team:
			return {"ok": false, "message": "team %d has %d interleague games" % [team_id, int(interleague_by_team.get(team_id, 0))]}
		var home_games: int = int(home_by_team.get(team_id, 0))
		if home_games < 71 or home_games > 72:
			return {"ok": false, "message": "team %d has suspicious home games: %d" % [team_id, home_games]}

	return {"ok": true}


# テンプレートの月日を対象年度の開幕日基準 day へ変換し、バケット名を実球団 id に置き換える。
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
		var is_interleague: bool = bool(row.get("is_interleague", false))
		if is_interleague:
			var sides: Array = _interleague_home_away_for_year(away_id, home_id, leagues_by_team_id, centrals, pacifics, year)
			away_id = int(sides[0])
			home_id = int(sides[1])
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
			is_interleague,
			series_id,
			game_no,
			int(row.get("cycle_number", -1))
		))
	return games


# 交流戦の主催権は「central/pacific内の球団ID昇順index」だけで固定して決め、年度2年周期で
# 丸ごと反転させる。バケット割当(年ごとの対戦カードのシャッフル)には依存しないため、
# 同一カード(実球団Avs実球団B)は2年間Aが主催→次の2年間はBが主催、という安定した周期になる。
# (シャッフルに home/away を委ねると年ごとにほぼランダムになり、周期性が出せないため分離した。)
static func _interleague_home_away_for_year(
	away_id: int,
	home_id: int,
	leagues_by_team_id: Dictionary,
	centrals: Array,
	pacifics: Array,
	year: int
) -> Array:
	var away_is_central: bool = str(leagues_by_team_id.get(away_id, "")) == "central"
	var central_id: int = away_id if away_is_central else home_id
	var pacific_id: int = home_id if away_is_central else away_id
	var central_index: int = centrals.find(central_id)
	var pacific_index: int = pacifics.find(pacific_id)
	var base_central_home: bool = (central_index + pacific_index) % 2 == 0
	@warning_ignore("integer_division")
	var half_cycle: int = (year - TEMPLATE_BASE_YEAR) / 2
	var flipped: bool = (half_cycle % 2) != 0
	var central_home: bool = base_central_home != flipped
	if central_home:
		return [pacific_id, central_id]
	return [central_id, pacific_id]


# C1..C6/P1..P6 へ球団 id を割り当てる。リーグ内の並びだけを seed で変え、リーグ所属は固定する。
static func _bucket_assignment(centrals: Array, pacifics: Array, year: int, season_number: int) -> Dictionary:
	var central_order: Array = _deterministic_shuffle(centrals, bucket_seed_for_season(year, season_number))
	var pacific_order: Array = _deterministic_shuffle(pacifics, bucket_seed_for_season(year, season_number) + 7919)
	var out: Dictionary = {}
	for i in range(6):
		out["C%d" % (i + 1)] = int(central_order[i])
		out["P%d" % (i + 1)] = int(pacific_order[i])
	return out


# Godot のグローバル RNG を汚さない簡易 deterministic shuffle。
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


static func _load_template_rows(year: int, season_number: int) -> Array:
	var template_path: String = ModManager.resolve_data_path(
		"schedule_template",
		str(ModManager.rule_value("season.schedule.template_path", TEMPLATE_PATH))
	)
	var expected_total_games: int = _rule_int("expected_total_games", EXPECTED_TOTAL_GAMES)
	var rows: Array = _read_template_csv(template_path)
	if rows.is_empty():
		rows = _generated_template_rows(year, season_number)
	if rows.size() != expected_total_games:
		push_error("Schedule template %s has %d rows, expected %d." % [template_path, rows.size(), expected_total_games])
		return []
	return rows


static func _rule_int(name: String, fallback: int) -> int:
	return ModManager.rule_int("season.schedule.%s" % name, fallback)


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


static func _generated_template_rows(year: int, season_number: int) -> Array:
	var centrals: Array = []
	var pacifics: Array = []
	for i in range(1, 7):
		var central_bucket: String = "C%d" % i
		var pacific_bucket: String = "P%d" % i
		centrals.append(central_bucket)
		pacifics.append(pacific_bucket)

	var rows: Array = []
	var target_opening: String = SeasonCalendar.opening_date_for_year(year)
	var block_days: Dictionary = _template_three_game_block_days(year)
	var intra_days: Array = block_days.get("intra", []) as Array
	var interleague_days: Array = block_days.get("interleague", []) as Array
	if intra_days.size() != INTRALEAGUE_BLOCK_COUNT or interleague_days.size() != INTERLEAGUE_THREE_GAME_BLOCKS:
		push_error("Failed to build NPB-style calendar blocks.")
		return []

	var central_rounds: Array = _round_robin_rounds(centrals)
	var pacific_rounds: Array = _round_robin_rounds(pacifics)
	var series_id: int = 1

	# 同一カード(5カード)を1巡とする構造は変えず、巡目ごとにカード順だけをシャッフルする
	# (現実のリーグ戦は毎巡固定の順番で同じ相手と当たるわけではないため)。ラウンドロビンの
	# 性質上、1巡内の5カードは相手が全て異なるので、巡内で連続対戦になることはない。
	# 巡の変わり目(前巡最終カード→次巡初戦)だけ同一相手が続き得るので、そこだけ明示的に回避する。
	@warning_ignore("integer_division")
	var cycles_count: int = intra_days.size() / ROUNDS_PER_CYCLE
	var round_order_seed: int = bucket_seed_for_season(year, season_number)
	var central_round_orders: Array = _round_orders_for_cycles(cycles_count, round_order_seed + 31)
	var pacific_round_orders: Array = _round_orders_for_cycles(cycles_count, round_order_seed + 53113)

	# 実際のNPBは「8×3連戦+終盤に単独1試合」のような単一ルールではなく、対戦カードごとに
	# 「7×3連戦+2連戦×2」等も混在する(docs/agent_memory 参照: 2026年公式日程を12球団分検証済み)。
	# 9巡のうち1〜2巡だけ短縮することでこれを再現し、かつ短縮された巡は通常の巡と同列に
	# シャッフル済みの並びに乗るため、終盤に固めず自然にシーズン中へ散らばる。
	# ただしゴールデンウィークは現実のNPBで「移動日なしの9連戦」が組まれる期間なので、
	# その期間に当たる巡は短縮対象から除外する(_gw_protected_cycles_by_round_index)。
	# 短縮する巡がどこに来るかで「多い方(13試合)」と「少ない方(12試合)」の割り振りが崩れない
	# よう、_intraleague_cycle_plans が length と同時にホーム側も決定的に確定させる
	# (詳細はその関数のコメント参照)。
	#
	# intra_days は両リーグ共通の固定週間隔カレンダー(常に火水木/金土日のペースで前進し、
	# カードの短縮では前倒し圧縮しない)。そのため GW 判定も「保護なし試行」を経由せず、
	# この実日付をそのまま使える(2026-07-08 の前倒し圧縮方式から固定週間隔方式へ変更)。
	var same_week_as_next: Array = _same_week_as_next_flags(intra_days, target_opening)
	var slot_is_holiday_monday: Array = _slot_is_holiday_monday_flags(intra_days, target_opening)

	var cycle_length_seed: int = bucket_seed_for_season(year, season_number)
	var central_protected_cycles: Array = _gw_protected_cycles_by_round_index(central_round_orders, intra_days, target_opening)
	var pacific_protected_cycles: Array = _gw_protected_cycles_by_round_index(pacific_round_orders, intra_days, target_opening)
	# 祝日月曜始まりのカードは短縮対象から除外する(火/金カードと違い「前寄せ/後ろ寄せ」の
	# 内部アンカーを別途持たせずに済むよう、稀な祝日月曜カードは常に3連戦のままにする)。
	_mark_holiday_monday_slots_protected(central_protected_cycles, central_round_orders, slot_is_holiday_monday)
	_mark_holiday_monday_slots_protected(pacific_protected_cycles, pacific_round_orders, slot_is_holiday_monday)
	# 開幕戦・交流戦明け・オールスター明けは長い休養の直後なので、必ず3連戦にする
	# (短縮カードだと不自然、ユーザー指摘)。intra_days は両リーグ共通なので判定も共通。
	var long_break_protected_block_indices: Dictionary = _long_break_protected_block_indices(intra_days)
	_mark_long_break_slots_protected(central_protected_cycles, central_round_orders, long_break_protected_block_indices)
	_mark_long_break_slots_protected(pacific_protected_cycles, pacific_round_orders, long_break_protected_block_indices)
	# 単独1試合(length=1)は9月以降限定で組む(ユーザー指摘、2026-07-08)。
	var central_is_september: Array = _is_september_or_later_by_round_index(central_round_orders, intra_days, target_opening)
	var pacific_is_september: Array = _is_september_or_later_by_round_index(pacific_round_orders, intra_days, target_opening)

	var central_cycle_plans: Array = _intraleague_cycle_plans(cycles_count, central_round_orders, cycle_length_seed + 88001, central_protected_cycles, same_week_as_next, central_is_september)
	var pacific_cycle_plans: Array = _intraleague_cycle_plans(cycles_count, pacific_round_orders, cycle_length_seed + 271828, pacific_protected_cycles, same_week_as_next, pacific_is_september)
	# 単独1試合は実際には「他の対戦カードがその窓の残り日へ相乗りする」ことが多い
	# (ユーザー指摘: 木曜移動日の2連戦相当を単独戦と誤認していた、という反省を踏まえた再設計)。
	# 相乗り元(ドナー)は同じ9月以降のどこかの巡にある別 round_index の length=3 を
	# 1試合分だけ2に短縮して提供する(ドナー自身の総試合数は変わらない)。
	var central_companions: Dictionary = _assign_single_game_companions(central_cycle_plans, central_round_orders, central_protected_cycles, central_is_september, same_week_as_next, cycle_length_seed + 313111)
	var pacific_companions: Dictionary = _assign_single_game_companions(pacific_cycle_plans, pacific_round_orders, pacific_protected_cycles, pacific_is_september, same_week_as_next, cycle_length_seed + 707909)

	for block_index in range(INTRALEAGUE_BLOCK_COUNT):
		var position_in_cycle: int = block_index % ROUNDS_PER_CYCLE
		@warning_ignore("integer_division")
		var cycle_index: int = block_index / ROUNDS_PER_CYCLE
		var cycle_number: int = cycle_index + 1

		var central_round_index: int = int((central_round_orders[cycle_index] as Array)[position_in_cycle])
		var central_plan: Dictionary = central_cycle_plans[central_round_index] as Dictionary
		var central_length: int = int((central_plan.get("lengths", []) as Array)[cycle_index])
		var central_designated_home: bool = bool((central_plan.get("designated_home", []) as Array)[cycle_index])
		var central_specs: Array = []
		if central_companions.has(block_index):
			var central_companion: Dictionary = central_companions[block_index] as Dictionary
			series_id = _append_intraleague_series_specs_with_day_offset(
				central_specs, central_rounds[central_round_index] as Array, cycle_number, series_id,
				central_designated_home, int(central_companion.get("recipient_day_offset", 0))
			)
			var central_donor_round_index: int = int(central_companion.get("donor_round_index", 0))
			var central_donor_plan: Dictionary = central_cycle_plans[central_donor_round_index] as Dictionary
			var central_donor_cycle_index: int = int(central_companion.get("donor_cycle_index", cycle_index))
			var central_donor_designated_home: bool = bool((central_donor_plan.get("designated_home", []) as Array)[central_donor_cycle_index])
			series_id = _append_intraleague_series_specs_with_day_offset(
				central_specs, central_rounds[central_donor_round_index] as Array, cycle_number, series_id,
				central_donor_designated_home, int(central_companion.get("companion_day_offset", 1))
			)
		else:
			series_id = _append_intraleague_series_specs(
				central_specs,
				central_rounds[central_round_index] as Array,
				cycle_number,
				series_id,
				central_length,
				central_designated_home
			)
		_append_series_rows(rows, int(intra_days[block_index]), central_specs, target_opening)

		var pacific_round_index: int = int((pacific_round_orders[cycle_index] as Array)[position_in_cycle])
		var pacific_plan: Dictionary = pacific_cycle_plans[pacific_round_index] as Dictionary
		var pacific_length: int = int((pacific_plan.get("lengths", []) as Array)[cycle_index])
		var pacific_designated_home: bool = bool((pacific_plan.get("designated_home", []) as Array)[cycle_index])
		var pacific_specs: Array = []
		if pacific_companions.has(block_index):
			var pacific_companion: Dictionary = pacific_companions[block_index] as Dictionary
			series_id = _append_intraleague_series_specs_with_day_offset(
				pacific_specs, pacific_rounds[pacific_round_index] as Array, cycle_number, series_id,
				pacific_designated_home, int(pacific_companion.get("recipient_day_offset", 0))
			)
			var pacific_donor_round_index: int = int(pacific_companion.get("donor_round_index", 0))
			var pacific_donor_plan: Dictionary = pacific_cycle_plans[pacific_donor_round_index] as Dictionary
			var pacific_donor_cycle_index: int = int(pacific_companion.get("donor_cycle_index", cycle_index))
			var pacific_donor_designated_home: bool = bool((pacific_donor_plan.get("designated_home", []) as Array)[pacific_donor_cycle_index])
			series_id = _append_intraleague_series_specs_with_day_offset(
				pacific_specs, pacific_rounds[pacific_donor_round_index] as Array, cycle_number, series_id,
				pacific_donor_designated_home, int(pacific_companion.get("companion_day_offset", 1))
			)
		else:
			series_id = _append_intraleague_series_specs(
				pacific_specs,
				pacific_rounds[pacific_round_index] as Array,
				cycle_number,
				series_id,
				pacific_length,
				pacific_designated_home
			)
		_append_series_rows(rows, int(intra_days[block_index]), pacific_specs, target_opening)

	for card_index in range(interleague_days.size()):
		var interleague_specs: Array = []
		for central_index in range(centrals.size()):
			var pacific_index: int = (central_index + card_index) % pacifics.size()
			var c_id: String = str(centrals[central_index])
			var p_id: String = str(pacifics[pacific_index])
			var ha: Array = _interleague_home_pair(c_id, p_id, central_index, pacific_index)
			interleague_specs.append(_series_spec(str(ha[1]), str(ha[0]), true, series_id, -1))
			series_id += 1
		_append_series_rows(rows, int(interleague_days[card_index]), interleague_specs, target_opening)

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


# 戻り値の "interleague" と "intra" はどちらも実際のスケジューリングにそのまま使う実カレンダー。
# カードの短縮(1・2連戦)は開始日を前倒ししない固定週間隔方式(_append_series_rows の
# カード内アンカー参照)なので、"intra" は central/pacific 両リーグで共有できる。
static func _template_three_game_block_days(year: int) -> Dictionary:
	var base_opening: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	# 曜日の並び (Tue/Fri 判定・交流戦/オールスター期間) は「開幕日=必ず金曜」という不変条件のおかげで
	# 年度に依らず TEMPLATE_BASE_YEAR の日付だけで組める。しかし祝日は暦日そのものに紐づくため、
	# 同じ day オフセットでも実際の対象年度でどの暦日になるかを別途解決しないと判定できない
	# (例: TEMPLATE_BASE_YEAR で祝日月曜だった day オフセットが、別の年では単なる平日月曜になりうる)。
	var target_opening: String = SeasonCalendar.opening_date_for_year(year)
	var date_text: String = base_opening
	var intra_days: Array = []
	var interleague_days: Array = []
	# 交流戦最終カード直後の1カード分は休養日にし、リーグ戦再開を次の候補枠(2026年は金曜)に送る。
	var rest_card_pending: bool = false
	var guard: int = 0
	while guard < 260 and (intra_days.size() < INTRALEAGUE_BLOCK_COUNT or interleague_days.size() < INTERLEAGUE_THREE_GAME_BLOCKS):
		var weekday: int = SeasonCalendar.weekday_for_date(date_text)
		# NPBの実運用と同じく、祝日の月曜は移動日ではなく試合日として3連戦の初日にできる
		# (例: 2026年は海の日 7/20(月) からの3連戦)。Tue/Fri と同格の開始候補に加える。
		var is_holiday_monday: bool = false
		if weekday == WEEKDAY_MONDAY:
			var day_offset: int = SeasonCalendar.days_between(base_opening, date_text) + 1
			var target_date: String = SeasonCalendar.date_for_day(target_opening, day_offset)
			is_holiday_monday = JapaneseHolidays.is_holiday(target_date)
		var is_block_start_candidate: bool = weekday == WEEKDAY_TUESDAY or weekday == WEEKDAY_FRIDAY or is_holiday_monday
		var block_consumed: bool = false
		if is_block_start_candidate and not _template_block_overlaps_all_star(date_text):
			var day: int = SeasonCalendar.days_between(base_opening, date_text) + 1
			if _template_date_in_range(date_text, TEMPLATE_INTERLEAGUE_START_DATE, TEMPLATE_INTERLEAGUE_END_DATE):
				if interleague_days.size() < INTERLEAGUE_THREE_GAME_BLOCKS:
					interleague_days.append(day)
					block_consumed = true
					if interleague_days.size() == INTERLEAGUE_THREE_GAME_BLOCKS:
						rest_card_pending = true
			elif rest_card_pending:
				rest_card_pending = false
				block_consumed = true
			elif intra_days.size() < INTRALEAGUE_BLOCK_COUNT:
				intra_days.append(day)
				block_consumed = true
		# 消費した3連戦分は丸ごと飛ばす。祝日月曜始まりの回では中2日目(火)がTue候補と
		# 重複してしまうため、1日ずつ進める従来のロジックのままだと二重にブロックを
		# 拾ってしまう。
		date_text = SeasonCalendar.add_days(date_text, GAMES_PER_SERIES if block_consumed else 1)
		guard += 1
	return {"intra": intra_days, "interleague": interleague_days}


# intra_days[i] と intra_days[i+1] が同じ週(火カード→間隔3日の金カード)かどうかを
# 事前計算する。金土日カードを短縮する際、同じ週の火水木カードが既に短縮されていないかを
# 調べるのに使う(逆に火水木カードを短縮する際は直後の金カードとの組で調べる)。
# 火→金は必ずちょうど3日間隔、金→翌週火は4日以上(土日+月曜移動日)になるため、
# 間隔が GAMES_PER_SERIES(3) かどうかだけで判定できる。
static func _same_week_as_next_flags(intra_days: Array, target_opening: String) -> Array:
	var flags: Array = []
	for i in range(intra_days.size()):
		if i >= intra_days.size() - 1:
			flags.append(false)
			continue
		var date_i: String = SeasonCalendar.date_for_day(target_opening, int(intra_days[i]))
		var date_next: String = SeasonCalendar.date_for_day(target_opening, int(intra_days[i + 1]))
		flags.append(SeasonCalendar.days_between(date_i, date_next) == GAMES_PER_SERIES)
	return flags


# 祝日月曜始まりのカード(月火水)かどうかを、各ブロックの実日付から判定する。
static func _slot_is_holiday_monday_flags(intra_days: Array, target_opening: String) -> Array:
	var flags: Array = []
	for day_value in intra_days:
		var date_text: String = SeasonCalendar.date_for_day(target_opening, int(day_value))
		flags.append(SeasonCalendar.weekday_for_date(date_text) == WEEKDAY_MONDAY)
	return flags


# block_index(全リーグ共通の intra_days 上のインデックス)ベースの判定を
# protected_cycles_by_round(round_index×cycle_index ベース)へ変換する共通ヘルパー。
# GW保護・祝日月曜・開幕/交流戦明け/オールスター明けの保護は、いずれも「特定の
# block_index を短縮対象から除外したい」という同じ形の要求なのでこれに載せる。
static func _mark_blocks_protected(protected_cycles_by_round: Array, round_orders: Array, block_is_protected: Callable) -> void:
	var cycles_count: int = round_orders.size()
	for round_index in range(ROUNDS_PER_CYCLE):
		var flags: Array = protected_cycles_by_round[round_index] as Array
		for cycle_index in range(cycles_count):
			var order: Array = round_orders[cycle_index] as Array
			var position: int = order.find(round_index)
			var block_index: int = cycle_index * ROUNDS_PER_CYCLE + position
			if block_is_protected.call(block_index):
				flags[cycle_index] = true


# 祝日月曜始まりのカードを短縮対象から除外する。火/金カードのような前寄せ/後ろ寄せの
# 内部アンカーを別途持たせずに済むよう、稀な祝日月曜カードは常に3連戦のまま扱う。
static func _mark_holiday_monday_slots_protected(protected_cycles_by_round: Array, round_orders: Array, slot_is_holiday_monday: Array) -> void:
	_mark_blocks_protected(protected_cycles_by_round, round_orders, func(block_index: int) -> bool:
		return bool(slot_is_holiday_monday[block_index])
	)


# 開幕戦・交流戦明け・オールスター明けは、長い休養(オフシーズン/交流戦の休養カード/
# オールスター休養)の直後に短縮カード(1・2連戦)が来ると不自然なため、必ず3連戦にする
# (ユーザー指摘、2026-07-08)。該当する block_index を intra_days(全リーグ共通の固定
# 週間隔カレンダー)から特定する: 開幕戦は intra_days の先頭、交流戦明け/オールスター明けは
# その期間の終了日より後で最初に来る intra ブロック。
static func _long_break_protected_block_indices(intra_days: Array) -> Dictionary:
	var base_opening: String = SeasonCalendar.opening_date_for_year(TEMPLATE_BASE_YEAR)
	var interleague_end_offset: int = SeasonCalendar.days_between(base_opening, TEMPLATE_INTERLEAGUE_END_DATE) + 1
	var all_star_end_offset: int = SeasonCalendar.days_between(base_opening, TEMPLATE_ALL_STAR_END_DATE) + 1
	var protected_indices: Dictionary = {}
	if intra_days.size() > 0:
		protected_indices[0] = true
	for i in range(intra_days.size()):
		if int(intra_days[i]) > interleague_end_offset:
			protected_indices[i] = true
			break
	for i in range(intra_days.size()):
		if int(intra_days[i]) > all_star_end_offset:
			protected_indices[i] = true
			break
	return protected_indices


static func _mark_long_break_slots_protected(protected_cycles_by_round: Array, round_orders: Array, long_break_protected_block_indices: Dictionary) -> void:
	_mark_blocks_protected(protected_cycles_by_round, round_orders, func(block_index: int) -> bool:
		return long_break_protected_block_indices.has(block_index)
	)


# TEMPLATE_BASE_YEAR 基準の日付定数(交流戦/オールスター期間の境界など)を、対象年度の
# 実日付へ変換する。day オフセット自体は年に依らず同じ意味を持つため、
# base_opening からのオフセットを求めてから target_opening で解決するだけでよい。
static func _resolve_target_date(template_date: String, base_opening: String, target_opening: String) -> String:
	var day_offset: int = SeasonCalendar.days_between(base_opening, template_date) + 1
	return SeasonCalendar.date_for_day(target_opening, day_offset)


static func _template_block_overlaps_all_star(start_date: String) -> bool:
	for offset in range(GAMES_PER_SERIES):
		var date_text: String = SeasonCalendar.add_days(start_date, offset)
		if _template_date_in_range(date_text, TEMPLATE_ALL_STAR_START_DATE, TEMPLATE_ALL_STAR_END_DATE):
			return true
	return false


static func _template_date_in_range(date_text: String, start_date: String, end_date: String) -> bool:
	return SeasonCalendar.days_between(start_date, date_text) >= 0 and SeasonCalendar.days_between(date_text, end_date) >= 0


static func _append_intraleague_series_specs(specs: Array, pairs: Array, cycle_number: int, start_series_id: int, length: int, designated_home: bool) -> int:
	var series_id: int = start_series_id
	for pair_value in pairs:
		var pair: Array = pair_value as Array
		var ha: Array = _intraleague_home_pair(str(pair[0]), str(pair[1]), designated_home)
		specs.append(_series_spec(str(ha[1]), str(ha[0]), false, series_id, cycle_number, length))
		series_id += 1
	return series_id


# _assign_single_game_companions が相乗りを割り当てたブロック用: 窓内の特定の1日
# (day_offset)だけを使う単独戦カードを追加する(_append_intraleague_series_specs の
# day_offset 指定版)。
static func _append_intraleague_series_specs_with_day_offset(specs: Array, pairs: Array, cycle_number: int, start_series_id: int, designated_home: bool, day_offset: int) -> int:
	var series_id: int = start_series_id
	for pair_value in pairs:
		var pair: Array = pair_value as Array
		var ha: Array = _intraleague_home_pair(str(pair[0]), str(pair[1]), designated_home)
		specs.append(_series_spec(str(ha[1]), str(ha[0]), false, series_id, cycle_number, 1, day_offset))
		series_id += 1
	return series_id


# specs は 1〜GAMES_PER_SERIES 試合の可変長カード(_intraleague_cycle_plans 参照)。
# カードの開始日(=次カードの開始日)は短縮の有無に関わらず不変な固定週間隔カレンダー
# (intra_days)なので、圧縮は行わない。短縮時にどの曜日を休むかだけをここで決める:
# 火曜始まりカード(火水木)は前寄せ(先頭から詰めて末尾を休む: 2連戦=火水、単独1試合=火のみ)。
# 金曜始まりカード(金土日)は土曜始まりに固定する(2連戦=土日で金曜のみ休む、単独1試合=
# 土曜のみで金・日を休む)。ユーザー指摘通り、火水木の2連戦は火水で行い木曜休養、
# 金土日の2連戦は土日で行い金曜休養とすることで、同じ週にもう一方が短縮されない限り
# 休養は常に1日以内に収まる(2つの週境界のうち、火→金は間隔0日で無バッファ、金→翌週火は
# 月曜移動日で1日分のバッファがあるため、後ろ寄せ/前寄せの選び方は非対称: 火曜カードは
# 月曜バッファ側=前を詰めずに残し、金曜カードは月曜バッファ側=後ろを詰めずに残す)。
# 同じ週の両カードを同時に短縮しない制約は _intraleague_cycle_plans の same_week_as_next で
# 担保する。単独1試合(2日休む)は「日曜のみ」だと直前が祝日月曜カード(水曜終わり、通常の
# 木曜終わりより1日早い)の場合に休養3日になる罠がある(2100年で実際に発生した回帰)ため、
# 「土曜のみ」に固定し前後とも休養2日以内に収める(火曜カードの単独1試合は前後とも
# 休養2日以内に収まることを確認済みなので、こちらは前寄せのままでよい)。
# 祝日月曜始まりカードは _mark_holiday_monday_slots_protected で短縮対象から除外済みなので
# 常に length==GAMES_PER_SERIES で呼ばれ、以下のアンカー分岐は素通りする。
static func _append_series_rows(rows: Array, start_day: int, specs: Array, target_opening: String) -> void:
	var slot_start_date: String = SeasonCalendar.date_for_day(target_opening, start_day)
	var is_friday_slot: bool = SeasonCalendar.weekday_for_date(slot_start_date) == WEEKDAY_FRIDAY
	for spec_value in specs:
		var spec: Dictionary = spec_value as Dictionary
		var length: int = int(spec.get("length", GAMES_PER_SERIES))
		var explicit_day_offset: int = int(spec.get("day_offset", -1))
		var date_text: String = slot_start_date
		if explicit_day_offset >= 0:
			# 相乗り単独戦(_assign_single_game_companions)など、窓内のどの日を使うか
			# 明示的に指定されている場合はそれに従う(以下の自動アンカーは使わない)。
			date_text = SeasonCalendar.add_days(slot_start_date, explicit_day_offset)
		elif is_friday_slot and length < GAMES_PER_SERIES:
			# 2連戦(土日)は金曜を休むだけで前後とも休養1日以内に収まる。単独1試合は
			# 「日曜のみ」(金土を休む)だと、直前が祝日月曜カード(水曜終わり、通常の
			# 木曜終わりより1日早い)の場合に休養3日になってしまう(2100年で実際に発生した
			# 回帰)。「土曜のみ」(金を休み・日を休む)なら前後とも休養2日以内に収まり、
			# 直前カードの終わり方に関わらず安全なため、土曜へ固定する。
			date_text = SeasonCalendar.add_days(slot_start_date, 1)
		var placed: int = 0
		while placed < length:
			if SeasonCalendar.weekday_for_date(date_text) == WEEKDAY_MONDAY and not JapaneseHolidays.is_holiday(date_text):
				date_text = SeasonCalendar.add_days(date_text, 1)
				continue
			var day: int = SeasonCalendar.days_between(target_opening, date_text) + 1
			rows.append(_make_template_row(
				day,
				str(spec.get("away_bucket", "")),
				str(spec.get("home_bucket", "")),
				bool(spec.get("is_interleague", false)),
				int(spec.get("series_id", -1)),
				int(spec.get("cycle_number", -1))
			))
			placed += 1
			date_text = SeasonCalendar.add_days(date_text, 1)


# day_offset は窓(3日間)内での明示的な開始位置(0=初日等)。-1 なら _append_series_rows が
# 従来通り length/曜日種別から自動決定する。相乗り単独戦(_assign_single_game_companions)の
# ように、同じ窓内で複数カードが「どの日を使うか」を明示的に指定したい場合に使う。
static func _series_spec(away_bucket: String, home_bucket: String, is_interleague: bool, series_id: int, cycle_number: int, length: int = GAMES_PER_SERIES, day_offset: int = -1) -> Dictionary:
	return {
		"away_bucket": away_bucket,
		"home_bucket": home_bucket,
		"is_interleague": is_interleague,
		"series_id": series_id,
		"cycle_number": cycle_number,
		"length": length,
		"day_offset": day_offset,
	}


# designated_home は _intraleague_cycle_plans が決定的に確定させた「この巡は
# 13試合側(_extra_home_bucket が決めた球団)がホームか」のフラグ。カードごとに
# どちらが13側かは _extra_home_bucket が固定するので、ここでは渡された巡単位の
# フラグに従うだけでよい。
static func _intraleague_home_pair(team_a: String, team_b: String, designated_home: bool) -> Array:
	var designated: String = _extra_home_bucket(team_a, team_b)
	var other: String = team_b if designated == team_a else team_a
	if designated_home:
		return [designated, other]
	return [other, designated]


# 6球団(C1..C6/P1..P6)の近正則トーナメント: 15カードのうち各球団3カードで「13」側
# (25試合中の多い方)になり、残り2カードで「12」側になるよう固定する。これにより
# 6球団のうち3球団がリーグ内ホーム63試合、残り3球団が62試合となり(+交流戦9試合固定で
# 71-72に収まる)、validate_schedule のホーム試合数条件を毎年安定して満たせる。
static func _extra_home_bucket(team_a: String, team_b: String) -> String:
	var index_a: int = int(team_a.substr(1)) - 1
	var index_b: int = int(team_b.substr(1)) - 1
	var diff: int = ((index_b - index_a) % 6 + 6) % 6
	if diff == 1 or diff == 2:
		return team_a
	if diff == 4 or diff == 5:
		return team_b
	return team_a if index_a < index_b else team_b


static func _interleague_home_pair(central_id: Variant, pacific_id: Variant, central_index: int, pacific_index: int) -> Array:
	if (central_index + pacific_index) % 2 == 0:
		return [central_id, pacific_id]
	return [pacific_id, central_id]


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


# 各巡目に使うラウンドロビンの「カード順」を巡ごとに独立でシャッフルする。
# ラウンドロビン(1-factorization)の性質上、同一巡内の5カードは各球団にとって相手が
# 全て異なるため、巡内で連続対戦になることは無い。巡の変わり目(前巡最後のカード→
# 次巡最初のカード)だけ同じラウンド番号(=同じ相手の組み合わせ)にならないよう調整する。
static func _round_orders_for_cycles(cycles_count: int, seed: int) -> Array:
	var orders: Array = []
	var previous_last: int = -1
	for cycle_index in range(cycles_count):
		var base_indices: Array = []
		for i in range(ROUNDS_PER_CYCLE):
			base_indices.append(i)
		var perm: Array = _deterministic_shuffle(base_indices, seed + cycle_index * 104729)
		if previous_last != -1 and int(perm[0]) == previous_last:
			for k in range(1, perm.size()):
				if int(perm[k]) != previous_last:
					var tmp: Variant = perm[0]
					perm[0] = perm[k]
					perm[k] = tmp
					break
		orders.append(perm)
		previous_last = int(perm[perm.size() - 1])
	return orders


# round_index(0..ROUNDS_PER_CYCLE-1)ごとに、INTRALEAGUE_CYCLES 回の巡での試合数
# (通常 GAMES_PER_SERIES=3、一部だけ短縮)と、どちらのホーム/ビジターが「多い方(13試合)」に
# なるかを同時に決定的に決める。
# 実際のNPBは同一カードの全25試合を「8×3連戦+単独1試合」のような単一ルールでは組んでおらず、
# 「7×3連戦+2連戦×2」等も同程度の頻度で混在する(2026年公式日程を12球団分検証して確認、
# docs/agent_memory 参照)。9巡×3試合=27は25試合を2試合超過するため、
# 60%の確率で2巡を2連戦に短縮(7×3+2×2=25)、40%の確率で1巡を単独1試合に短縮(8×3+1=25)する。
# どの巡が短縮されるかは _round_orders_for_cycles 由来のシャッフル済み並びに乗るだけなので、
# 終盤に固めず自然にシーズン中へ散らばる。
#
# ホーム試合数は「13側(_extra_home_bucket が決めた球団)」「12側」にきっちり分けたい。
# どちらのパターンでも "12側が3連戦(通常長)を4本ホームにし、13側が残り(短縮分含む)全てを
# ホームにする" と必ず 12/13 に割れる (8×3+1: 12側4本×3=12、13側4本×3+1=13。
# 7×3+2×2: 12側4本×3=12、13側3本×3+2×2=13)。巡の長さや配置に関わらず必ず成立する
# 決定的な式なので、乱数の収束に頼るバランサ(かつて実装して71-72に収まらず失敗した)より
# 安定する。
#
# protected_cycles_by_round は round_index ごとに cycles_count 個の bool 配列を持ち、
# true の巡(ゴールデンウィークに重なる巡・祝日月曜始まりの巡・開幕戦/交流戦明け/
# オールスター明けの巡)は短縮対象から除外する。
#
# round_orders(巡ごとのカード順シャッフル)と same_week_as_next(_same_week_as_next_flags、
# 火カード→直後の金カードが同じ週かどうか)を渡すことで、「同じ週の火水木カードと金土日
# カードを両方短縮しない」制約を round_index をまたいで守る。両方短縮すると、火水木側は
# 木曜を休み・金土日側は金曜を休むため、木・金と2日連続の休養日になってしまう
# (ユーザー指摘、2026-07-08)。round_index を 0..4 の順に処理し、既に他の round_index が
# 短縮済みのブロックと同じ週なら候補から除外する形でこの制約を保証する。
# フォールバックの優先順位: 候補が尽きた場合、週制約より先に protected_cycles_by_round を
# 無視する(=まれに保護対象が短縮される方が、休養3日以上という深刻な回帰より軽微なため)。
#
# is_september_or_later は round_index ごとに cycles_count 個の bool 配列を持ち、単独1試合
# (length=1、use_two_reductions==false のパターン)はこれが true の巡にしか割り当てない
# (ユーザー指摘、2026-07-08: 単独戦は9月以降に限定する)。2連戦(length=2)にはこの制約は
# 適用しない(実データで4-9月に渡って分散していることを確認済みのため)。
static func _intraleague_cycle_plans(cycles_count: int, round_orders: Array, seed: int, protected_cycles_by_round: Array, same_week_as_next: Array, is_september_or_later: Array) -> Array:
	var reduced_blocks: Dictionary = {}
	var result: Array = []
	for round_index in range(ROUNDS_PER_CYCLE):
		var protected_cycles: Array = protected_cycles_by_round[round_index] as Array
		var september_flags: Array = is_september_or_later[round_index] as Array
		var block_index_for_cycle: Array = []
		for cycle_index in range(cycles_count):
			var order: Array = round_orders[cycle_index] as Array
			var position: int = order.find(round_index)
			block_index_for_cycle.append(cycle_index * ROUNDS_PER_CYCLE + position)
		var lengths: Array = []
		for i in range(cycles_count):
			lengths.append(GAMES_PER_SERIES)
		var indices: Array = []
		for i in range(cycles_count):
			indices.append(i)
		var shuffled: Array = _deterministic_shuffle(indices, seed + round_index * 7919)
		var use_two_reductions: bool = (int(shuffled[shuffled.size() - 1]) % 5) < 3
		var is_single_game_pattern: bool = not use_two_reductions
		var reduced: Dictionary = {}
		var reductions_needed: int = 2 if use_two_reductions else 1
		for idx_value in shuffled:
			var idx: int = int(idx_value)
			if reductions_needed <= 0:
				break
			if bool(protected_cycles[idx]):
				continue
			if is_single_game_pattern and not bool(september_flags[idx]):
				continue
			if _week_partner_already_reduced(int(block_index_for_cycle[idx]), same_week_as_next, reduced_blocks):
				continue
			reduced[idx] = true
			reduced_blocks[int(block_index_for_cycle[idx])] = true
			reductions_needed -= 1
		# 保護巡・週の相方短縮済みだけで埋まってしまう(GW保護に加えて祝日月曜・開幕/交流戦明け/
		# オールスター明けの保護も乗るため、稀に起きうる)ケースへのフォールバック: 週制約
		# (同じ週の二重短縮=木・金と2日連続休養)は絶対に破らず、まず保護の方を先に無視する。
		# 週制約を破ると「休養3日以上」という、より深刻な回帰を再導入してしまうため。
		# 9月限定制約(単独1試合のみ)は、週制約より後・保護より先には緩めない
		# (「9月以降」自体はユーザー指摘の直接の要件なので、週制約の次に守る)。
		if reductions_needed > 0:
			for idx_value in shuffled:
				var idx: int = int(idx_value)
				if reductions_needed <= 0:
					break
				if reduced.has(idx):
					continue
				if is_single_game_pattern and not bool(september_flags[idx]):
					continue
				if _week_partner_already_reduced(int(block_index_for_cycle[idx]), same_week_as_next, reduced_blocks):
					continue
				reduced[idx] = true
				reduced_blocks[int(block_index_for_cycle[idx])] = true
				reductions_needed -= 1
		# それでも埋まらない場合、9月限定制約も緩める(保護は既にtier2で緩めている。週制約は維持)。
		if reductions_needed > 0:
			for idx_value in shuffled:
				var idx: int = int(idx_value)
				if reductions_needed <= 0:
					break
				if reduced.has(idx):
					continue
				if _week_partner_already_reduced(int(block_index_for_cycle[idx]), same_week_as_next, reduced_blocks):
					continue
				reduced[idx] = true
				reduced_blocks[int(block_index_for_cycle[idx])] = true
				reductions_needed -= 1
		# それでも埋まらない(保護・9月限定を無視しても週制約だけで9巡全滅する)場合のみ、
		# 最後の手段として週制約も無視する。
		if reductions_needed > 0:
			for idx_value in shuffled:
				var idx: int = int(idx_value)
				if reductions_needed <= 0:
					break
				if reduced.has(idx):
					continue
				reduced[idx] = true
				reduced_blocks[int(block_index_for_cycle[idx])] = true
				reductions_needed -= 1
		for idx in reduced.keys():
			lengths[idx] = 2 if use_two_reductions else 1

		var designated_home: Array = []
		for i in range(cycles_count):
			designated_home.append(true)
		var other_home_remaining: int = 4
		for idx_value in shuffled:
			var idx: int = int(idx_value)
			if other_home_remaining <= 0:
				break
			if not reduced.has(idx):
				designated_home[idx] = false
				other_home_remaining -= 1

		result.append({"lengths": lengths, "designated_home": designated_home})
	return result


# block_index の週の相方(直前 or 直後で same_week_as_next が true のブロック)が
# 既に(他の round_index によって)短縮済みかどうかを調べる。
static func _week_partner_already_reduced(block_index: int, same_week_as_next: Array, reduced_blocks: Dictionary) -> bool:
	if block_index > 0 and bool(same_week_as_next[block_index - 1]) and reduced_blocks.has(block_index - 1):
		return true
	if block_index < same_week_as_next.size() and bool(same_week_as_next[block_index]) and reduced_blocks.has(block_index + 1):
		return true
	return false


# 単独1試合(length=1、9月以降限定)は、実際には「その1試合だけで火水木/金土日の残り2日を
# 空けたまま待つ」のではなく、他の対戦カード(別の round_index)がその窓の空いた1日へ
# 相乗りすることが多い(ユーザー指摘、2026-07-08: 木曜が移動日になっていただけの2連戦相当を
# 単独戦と誤認していた、という指摘を踏まえた再設計)。相乗り元(ドナー)は同じ9月以降の
# どこかの巡で length=3 の別 round_index を1試合分だけ 2 に短縮して提供する(ドナー自身の
# 総試合数=25は変わらず、ドナー自身の窓では通常の2連戦としてそのまま処理される。相乗り分は
# ドナーの本来の窓とは別の暦日=単独戦側の窓に「テレポート」して1試合だけ行われる)。
# 相乗りが成立するかどうか、どちらが先の日になるか(火水/火木/水木の3パターン)は
# 決定的シードでランダムに決め、成立しないケースも残す(本当に1試合だけで終わる単独戦)。
# 戻り値は recipient 側の block_index -> {"donor_round_index", "donor_cycle_index",
# "recipient_day_offset", "companion_day_offset"} の Dictionary。
static func _assign_single_game_companions(cycle_plans: Array, round_orders: Array, protected_cycles_by_round: Array, is_september_or_later: Array, same_week_as_next: Array, seed: int) -> Dictionary:
	var cycles_count: int = round_orders.size()
	var reduced_blocks: Dictionary = {}
	var recipients: Array = []
	for round_index in range(ROUNDS_PER_CYCLE):
		var plan: Dictionary = cycle_plans[round_index] as Dictionary
		var lengths: Array = plan.get("lengths", []) as Array
		for cycle_index in range(cycles_count):
			var order: Array = round_orders[cycle_index] as Array
			var position: int = order.find(round_index)
			var block_index: int = cycle_index * ROUNDS_PER_CYCLE + position
			if int(lengths[cycle_index]) < GAMES_PER_SERIES:
				reduced_blocks[block_index] = true
			if int(lengths[cycle_index]) == 1:
				recipients.append({"round_index": round_index, "cycle_index": cycle_index, "block_index": block_index})

	var day_patterns: Array = [[0, 1], [0, 2], [1, 2]]
	var companions: Dictionary = {}
	for recipient_value in recipients:
		var recipient: Dictionary = recipient_value as Dictionary
		var r_round: int = int(recipient.get("round_index", 0))
		var r_cycle: int = int(recipient.get("cycle_index", 0))
		var r_block: int = int(recipient.get("block_index", 0))

		var roll_seed: int = seed + r_round * 131 + r_cycle * 977 + 5
		if int(_deterministic_shuffle([0, 1], roll_seed)[0]) != 0:
			continue # 確率的に相乗りさせない(本当に1試合だけの単独戦のまま)

		var donor_round_indices: Array = []
		for i in range(ROUNDS_PER_CYCLE):
			donor_round_indices.append(i)
		var donor_seed: int = seed + r_round * 5081 + r_cycle * 6151 + 11
		var shuffled_donor_rounds: Array = _deterministic_shuffle(donor_round_indices, donor_seed)
		var donor_found: bool = false
		for donor_round_value in shuffled_donor_rounds:
			if donor_found:
				break
			var donor_round: int = int(donor_round_value)
			if donor_round == r_round:
				continue
			var donor_plan: Dictionary = cycle_plans[donor_round] as Dictionary
			var donor_lengths: Array = donor_plan.get("lengths", []) as Array
			var donor_protected: Array = protected_cycles_by_round[donor_round] as Array
			var donor_september: Array = is_september_or_later[donor_round] as Array
			var donor_cycle_indices: Array = []
			for i in range(cycles_count):
				donor_cycle_indices.append(i)
			var shuffled_donor_cycles: Array = _deterministic_shuffle(donor_cycle_indices, donor_seed + donor_round * 293)
			for donor_cycle_value in shuffled_donor_cycles:
				var donor_cycle: int = int(donor_cycle_value)
				if int(donor_lengths[donor_cycle]) != GAMES_PER_SERIES:
					continue
				if bool(donor_protected[donor_cycle]):
					continue
				if not bool(donor_september[donor_cycle]):
					continue
				var donor_order: Array = round_orders[donor_cycle] as Array
				var donor_position: int = int(donor_order.find(donor_round))
				var donor_block: int = donor_cycle * ROUNDS_PER_CYCLE + donor_position
				if _week_partner_already_reduced(donor_block, same_week_as_next, reduced_blocks):
					continue
				# ドナー確定: 自身の窓では通常の2連戦として2に短縮する(総試合数は変わらない)。
				donor_lengths[donor_cycle] = 2
				reduced_blocks[donor_block] = true
				var pattern: Array = (_deterministic_shuffle(day_patterns, roll_seed + 17)[0]) as Array
				var recipient_first: bool = int(_deterministic_shuffle([0, 1], roll_seed + 29)[0]) == 0
				companions[r_block] = {
					"donor_round_index": donor_round,
					"donor_cycle_index": donor_cycle,
					"recipient_day_offset": int(pattern[0]) if recipient_first else int(pattern[1]),
					"companion_day_offset": int(pattern[1]) if recipient_first else int(pattern[0]),
				}
				donor_found = true
				break
	return companions


# round_index(0..ROUNDS_PER_CYCLE-1)ごとに、その巡が INTRALEAGUE_CYCLES 回のうちどの
# cycle_index でゴールデンウィーク期間に重なるかを判定する。round_index の実際の日付は
# サイクルごとの並び替え(_round_orders_for_cycles)に乗るため、round_orders を逆引きして
# 実際の block_index → 開始日 → 対象年度の暦日を解決してから判定する。
static func _gw_protected_cycles_by_round_index(round_orders: Array, intra_days: Array, target_opening: String) -> Array:
	var cycles_count: int = round_orders.size()
	var result: Array = []
	for round_index in range(ROUNDS_PER_CYCLE):
		var flags: Array = []
		for cycle_index in range(cycles_count):
			var order: Array = round_orders[cycle_index] as Array
			var position: int = order.find(round_index)
			var block_index: int = cycle_index * ROUNDS_PER_CYCLE + position
			var day_offset: int = int(intra_days[block_index])
			var target_date: String = SeasonCalendar.date_for_day(target_opening, day_offset)
			flags.append(_template_block_overlaps_golden_week(target_date))
		result.append(flags)
	return result


# round_index(0..ROUNDS_PER_CYCLE-1)ごとに、各 cycle_index の実際の開始日が9月以降かどうかを
# 判定する(_gw_protected_cycles_by_round_index と同じ逆引き手順)。単独1試合(length=1)は
# 9月以降限定で組む、というユーザー指摘の実装に使う(_intraleague_cycle_plans 参照)。
static func _is_september_or_later_by_round_index(round_orders: Array, intra_days: Array, target_opening: String) -> Array:
	var cycles_count: int = round_orders.size()
	var result: Array = []
	for round_index in range(ROUNDS_PER_CYCLE):
		var flags: Array = []
		for cycle_index in range(cycles_count):
			var order: Array = round_orders[cycle_index] as Array
			var position: int = order.find(round_index)
			var block_index: int = cycle_index * ROUNDS_PER_CYCLE + position
			var day_offset: int = int(intra_days[block_index])
			var target_date: String = SeasonCalendar.date_for_day(target_opening, day_offset)
			var month: int = int(target_date.split("-")[1])
			flags.append(month >= 9)
		result.append(flags)
	return result


static func _template_block_overlaps_golden_week(start_date: String) -> bool:
	for offset in range(GAMES_PER_SERIES):
		var date_text: String = SeasonCalendar.add_days(start_date, offset)
		var parts: PackedStringArray = date_text.split("-")
		var month: int = int(parts[1])
		var day: int = int(parts[2])
		if (month == GOLDEN_WEEK_START_MONTH and day >= GOLDEN_WEEK_START_DAY) or (month == GOLDEN_WEEK_END_MONTH and day <= GOLDEN_WEEK_END_DAY):
			return true
	return false


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
