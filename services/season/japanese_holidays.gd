extends RefCounted

# 日本の祝日判定 (国民の祝日に関する法律ベース、2000年以降のハッピーマンデー制度反映)。
# 用途は日程生成での「祝日の月曜は試合日にする」判定のみなので、正確な運用よりも
# 何百年先まで再生成しても破綻しない外挿性を優先する。
# - 固定日祝日 / ハッピーマンデー祝日は暦のルールそのものなので永続的に正確。
# - 春分・秋分の日は天文近似式 (国立天文台の式、公称精度は1980-2099年) を使う。
#   対象年代を超えると実際の分点日から数日ずれ得るが、ゲーム内では「祝日フレーバー」
#   としてのみ使うため実害はない (docs/agent_memory 参照)。
# - 振替休日 (祝日が日曜なら翌日以降の最初の平日を振替) のみ対応し、祝日に挟まれた
#   平日を休日とする「国民の休日」規定は月曜には影響しない組み合わせが大半のため未対応。
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const WEEKDAY_SUNDAY: int = 0
const WEEKDAY_MONDAY: int = 1

# {month, day, name} の固定日祝日。
const FIXED_HOLIDAYS: Array = [
	{"month": 1, "day": 1, "name": "元日"},
	{"month": 2, "day": 11, "name": "建国記念の日"},
	{"month": 2, "day": 23, "name": "天皇誕生日"},
	{"month": 5, "day": 3, "name": "憲法記念日"},
	{"month": 5, "day": 4, "name": "みどりの日"},
	{"month": 5, "day": 5, "name": "こどもの日"},
	{"month": 8, "day": 11, "name": "山の日"},
	{"month": 11, "day": 3, "name": "文化の日"},
	{"month": 11, "day": 23, "name": "勤労感謝の日"},
]

# {month, nth, name} の「第n月曜」祝日 (ハッピーマンデー制度)。
const HAPPY_MONDAY_HOLIDAYS: Array = [
	{"month": 1, "nth": 2, "name": "成人の日"},
	{"month": 7, "nth": 3, "name": "海の日"},
	{"month": 9, "nth": 3, "name": "敬老の日"},
	{"month": 10, "nth": 2, "name": "スポーツの日"},
]


static func is_holiday(date_text: String) -> bool:
	return holidays_for_year(_year_of(date_text)).has(date_text)


# date_text -> 祝日名。振替休日を含む。
static func holidays_for_year(year: int) -> Dictionary:
	var base: Dictionary = _base_holidays_for_year(year)
	var combined: Dictionary = base.duplicate()

	var base_dates: Array = base.keys()
	base_dates.sort()
	for date_text in base_dates:
		if SeasonCalendar.weekday_for_date(str(date_text)) != WEEKDAY_SUNDAY:
			continue
		var candidate: String = SeasonCalendar.add_days(str(date_text), 1)
		var guard: int = 0
		while combined.has(candidate) and guard < 10:
			candidate = SeasonCalendar.add_days(candidate, 1)
			guard += 1
		combined[candidate] = "振替休日"

	return combined


static func _base_holidays_for_year(year: int) -> Dictionary:
	var holidays: Dictionary = {}
	for entry_value in FIXED_HOLIDAYS:
		var entry: Dictionary = entry_value as Dictionary
		holidays[_date_string(year, int(entry.get("month", 1)), int(entry.get("day", 1)))] = str(entry.get("name", ""))
	for entry_value in HAPPY_MONDAY_HOLIDAYS:
		var entry: Dictionary = entry_value as Dictionary
		var date_text: String = SeasonCalendar.nth_weekday_of_month(year, int(entry.get("month", 1)), WEEKDAY_MONDAY, int(entry.get("nth", 1)))
		holidays[date_text] = str(entry.get("name", ""))
	holidays[_date_string(year, 3, _vernal_equinox_day(year))] = "春分の日"
	holidays[_date_string(year, 9, _autumnal_equinox_day(year))] = "秋分の日"
	return holidays


# 国立天文台の近似式 (公称精度1980-2099年)。設計方針によりこの範囲外もそのまま外挿する。
static func _vernal_equinox_day(year: int) -> int:
	var offset: int = year - 1980
	@warning_ignore("integer_division")
	return int(floor(20.8431 + 0.242194 * offset)) - int(offset / 4)


static func _autumnal_equinox_day(year: int) -> int:
	var offset: int = year - 1980
	@warning_ignore("integer_division")
	return int(floor(23.2488 + 0.242194 * offset)) - int(offset / 4)


static func _year_of(date_text: String) -> int:
	var parts: PackedStringArray = date_text.split("-")
	return int(parts[0]) if parts.size() > 0 else 1970


static func _date_string(year: int, month: int, day: int) -> String:
	return "%04d-%02d-%02d" % [year, month, day]
