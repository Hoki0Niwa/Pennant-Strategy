extends RefCounted

# season day と実カレンダー日付の相互変換ヘルパー。
# 内部シミュレーションは current_day を使い、UI 表示や日程テンプレートは YYYY-MM-DD を使う。
const SECONDS_PER_DAY: int = 86400
const OPENING_MONTH: int = 3
const JAPANESE_WEEKDAYS: Array = ["日", "月", "火", "水", "木", "金", "土"]


# 開幕日は「3月最終金曜日」。25〜31日を後ろから探す。
static func opening_date_for_year(year: int) -> String:
	var day: int = 31
	while day >= 25:
		var date_text: String = _date_string(year, OPENING_MONTH, day)
		if weekday_for_date(date_text) == 5:
			return date_text
		day -= 1
	return _date_string(year, OPENING_MONTH, 31)


# YYYY-MM-DD に日数を足す。Godot の datetime dict は UTC 秒へ変換して扱う。
static func add_days(date_text: String, days: int) -> String:
	var unix: int = Time.get_unix_time_from_datetime_dict(_date_dict(date_text))
	var out: Dictionary = Time.get_datetime_dict_from_unix_time(unix + days * SECONDS_PER_DAY)
	return _date_string(int(out.get("year", 0)), int(out.get("month", 0)), int(out.get("day", 0)))


# from_date から to_date までの日数差。date_for_day の逆算やテンプレート変換で使う。
static func days_between(from_date: String, to_date: String) -> int:
	var from_unix: int = Time.get_unix_time_from_datetime_dict(_date_dict(from_date))
	var to_unix: int = Time.get_unix_time_from_datetime_dict(_date_dict(to_date))
	@warning_ignore("integer_division")
	return int((to_unix - from_unix) / SECONDS_PER_DAY)


# 1始まりの season day を実日付へ変換する。
static func date_for_day(start_date: String, day: int) -> String:
	return add_days(start_date, max(1, day) - 1)


# season.calendar_start_date が古いセーブで空の場合は年度から開幕日を補う。
static func date_for_season_day(season: PSSeason, day: int) -> String:
	if season == null:
		return ""
	var start_date: String = season.calendar_start_date
	if start_date.is_empty():
		start_date = opening_date_for_year(season.year)
	return date_for_day(start_date, day)


static func current_date(season: PSSeason) -> String:
	if season == null:
		return ""
	return date_for_season_day(season, season.current_day)


# date_for_season_day の逆変換。カレンダー日付に対応する season day (1始まり) を返す。
static func season_day_for_date(season: PSSeason, date_text: String) -> int:
	if season == null or date_text.is_empty():
		return 0
	var start_date: String = season.calendar_start_date
	if start_date.is_empty():
		start_date = opening_date_for_year(season.year)
	return days_between(start_date, date_text) + 1


# 指定日付が属する月の最終日 (YYYY-MM-DD)。翌月1日の前日として求める。
static func last_day_of_month(date_text: String) -> String:
	var d: Dictionary = _date_dict(date_text)
	var year: int = int(d.get("year", 0))
	var month: int = int(d.get("month", 1)) + 1
	if month > 12:
		month = 1
		year += 1
	return add_days(_date_string(year, month, 1), -1)


# UI 用の短い日付ラベル。入力が壊れていれば元文字列をそのまま返す。
static func label_for_date(date_text: String) -> String:
	if date_text.is_empty():
		return "-"
	var parts: PackedStringArray = date_text.split("-")
	if parts.size() != 3:
		return date_text
	var month: int = int(parts[1])
	var day: int = int(parts[2])
	return "%d/%d(%s)" % [month, day, weekday_label_for_date(date_text)]


static func compact_label_for_game(game: Dictionary, season: PSSeason = null) -> String:
	var date_text: String = str(game.get("date", ""))
	if date_text.is_empty() and season != null:
		date_text = date_for_season_day(season, int(game.get("day", 1)))
	return label_for_date(date_text)


static func relative_label(current_day: int, target_day: int) -> String:
	var gap: int = target_day - current_day
	if gap == 0:
		return "本日"
	if gap == 1:
		return "明日"
	if gap > 1:
		return "%d日後" % gap
	return "%d日前" % abs(gap)


static func day_status_label(season: PSSeason, day: int) -> String:
	if season == null:
		return "Day %d" % day
	return "%s / Day %d" % [label_for_date(date_for_season_day(season, day)), day]


static func weekday_for_date(date_text: String) -> int:
	var unix: int = Time.get_unix_time_from_datetime_dict(_date_dict(date_text))
	var data: Dictionary = Time.get_datetime_dict_from_unix_time(unix)
	return int(data.get("weekday", 0))


static func weekday_label_for_date(date_text: String) -> String:
	return str(JAPANESE_WEEKDAYS[weekday_for_date(date_text)])


static func _date_dict(date_text: String) -> Dictionary:
	var parts: PackedStringArray = date_text.split("-")
	return {
		"year": int(parts[0]) if parts.size() > 0 else 1970,
		"month": int(parts[1]) if parts.size() > 1 else 1,
		"day": int(parts[2]) if parts.size() > 2 else 1,
		"hour": 0,
		"minute": 0,
		"second": 0,
	}


static func _date_string(year: int, month: int, day: int) -> String:
	return "%04d-%02d-%02d" % [year, month, day]
