extends ConfirmationDialog

# スキップの行き先を日数でも日付でも指定できるダイアログ。確定すると target_chosen を出す。
# 2 つの入力は同じ行き先 (end_day = その日の試合まで消化する最終 season day) を表し、片方を
# 変えるともう片方がそれに追従する。日数 N は本日を含む N 日間 (= current_day + N - 1)。
# 指定できるのは本日〜未消化試合が残る最終日で、範囲外の入力は端へ丸める。
# skip_name は最後に触った入力に合わせる (日数なら「N日スキップ」、日付なら「M/D(曜)までスキップ」)。

signal target_chosen(end_day: int, skip_name: String)

const GameDialogStyle = preload("res://ui/components/game_dialog_style.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const SOURCE_DAYS: String = "days"
const SOURCE_DATE: String = "date"
# 開いた直後の初期値 (本日を含む日数)。
const DEFAULT_DAYS: int = 14

var _first_day: int = 0
var _last_day: int = 0
var _end_day: int = 0
# 最後に値を変えた入力。skip_name の書き方を決める。
var _last_source: String = SOURCE_DAYS
# 入力同士の追従で値を書き換えている間は、value_changed を利用者の操作として扱わない。
var _syncing: bool = false
# 月選択の各項目の {year, month}。OptionButton の index と対応する。
var _months: Array = []
var _days_spin: SpinBox = null
var _month_select: OptionButton = null
var _date_spin: SpinBox = null
var _preview: Label = null
var _font: Font = null
var _scale_factor: float = 1.0


# AppState.current_season の現在日と未消化試合から入力範囲を決めて UI を組む。
func setup(font: Font = null, scale_factor: float = 1.0) -> void:
	_font = font
	_scale_factor = scale_factor
	var season: PSSeason = AppState.current_season
	_first_day = season.current_day if season != null else 0
	_last_day = AppState.last_unplayed_game_day()

	title = Loc.t("skip_dialog.title")
	ok_button_text = Loc.t("skip_dialog.start")
	cancel_button_text = Loc.t("common.cancel")
	GameDialogStyle.style_confirmation(self, font, scale_factor)
	confirmed.connect(_on_confirmed)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", max(10, int(round(14.0 * scale_factor))))
	add_child(box)

	var days_row: HBoxContainer = _make_row(Loc.t("skip_dialog.days"))
	box.add_child(days_row)
	_days_spin = _make_spin(1, max(1, _last_day - _first_day + 1), 1)
	_days_spin.value_changed.connect(func(_value: float) -> void: _on_days_changed())
	days_row.add_child(_days_spin)
	days_row.add_child(_make_label(Loc.t("skip_dialog.days_suffix"), GameDialogStyle.TEXT))

	var date_row: HBoxContainer = _make_row(Loc.t("skip_dialog.date"))
	box.add_child(date_row)
	_month_select = OptionButton.new()
	_month_select.custom_minimum_size = Vector2(96.0, 0.0) * _scale_factor
	GameDialogStyle.style_option_button(_month_select, _font, _scale_factor)
	_month_select.item_selected.connect(func(_index: int) -> void: _on_date_changed())
	date_row.add_child(_month_select)
	_date_spin = _make_spin(1, 31, 1)
	_date_spin.value_changed.connect(func(_value: float) -> void: _on_date_changed())
	date_row.add_child(_date_spin)
	date_row.add_child(_make_label(Loc.t("skip_dialog.date_suffix"), GameDialogStyle.TEXT))

	_preview = _make_label("", GameDialogStyle.MUTED)
	box.add_child(_preview)

	if has_targets():
		_build_month_items()
		_end_day = clampi(_first_day + DEFAULT_DAYS - 1, _first_day, _last_day)
		_sync_inputs()
	else:
		_days_spin.editable = false
		_date_spin.editable = false
		_month_select.disabled = true
		get_ok_button().disabled = true
	_update_preview()


func has_targets() -> bool:
	return _first_day > 0 and _last_day >= _first_day


# 現在の行き先 (範囲へ丸め済み)。消化できる試合が無ければ 0。
func selected_end_day() -> int:
	return _end_day if has_targets() else 0


func selected_skip_name() -> String:
	if _last_source == SOURCE_DATE:
		return Loc.t("skip.skip_until", {"target": _date_label(_end_day)})
	return Loc.t("skip.days", {"days": _end_day - _first_day + 1})


# 日数入力を書き換えた扱いで行き先を決める (テスト・外部からの初期値指定用)。
func set_days(days: int) -> void:
	if has_targets():
		_days_spin.value = days


# 日付入力を書き換えた扱いで行き先を決める (テスト・外部からの初期値指定用)。
func set_end_day(end_day: int) -> void:
	if not has_targets():
		return
	_select_date_inputs(clampi(end_day, _first_day, _last_day))
	_on_date_changed()


func _on_days_changed() -> void:
	if _syncing or not has_targets():
		return
	_end_day = clampi(_first_day + int(_days_spin.value) - 1, _first_day, _last_day)
	_last_source = SOURCE_DAYS
	_sync_inputs()
	_update_preview()


func _on_date_changed() -> void:
	if _syncing or not has_targets():
		return
	# 月を切り替えたときは日の範囲をその月に合わせてから読む (範囲外の日は SpinBox が端へ寄せる)。
	_syncing = true
	_apply_month_range()
	_syncing = false
	var ym: Dictionary = _months[max(0, _month_select.selected)] as Dictionary
	var date_text: String = "%04d-%02d-%02d" % [int(ym["year"]), int(ym["month"]), int(_date_spin.value)]
	_end_day = clampi(SeasonCalendar.season_day_for_date(AppState.current_season, date_text), _first_day, _last_day)
	_last_source = SOURCE_DATE
	_sync_inputs()
	_update_preview()


# _end_day を両方の入力へ書き戻す。
func _sync_inputs() -> void:
	_syncing = true
	_days_spin.value = _end_day - _first_day + 1
	_select_date_inputs(_end_day)
	_syncing = false


func _build_month_items() -> void:
	var first: Dictionary = _date_parts(_first_day)
	var last: Dictionary = _date_parts(_last_day)
	var year: int = int(first["year"])
	var month: int = int(first["month"])
	while year * 12 + month <= int(last["year"]) * 12 + int(last["month"]):
		_months.append({"year": year, "month": month})
		_month_select.add_item(Loc.t("date.month", {"month": month}))
		month += 1
		if month > 12:
			month = 1
			year += 1


# end_day の月を選び、日の入力範囲をその月に合わせてから日を入れる。
func _select_date_inputs(end_day: int) -> void:
	var was_syncing: bool = _syncing
	_syncing = true
	var parts: Dictionary = _date_parts(end_day)
	for index in range(_months.size()):
		var ym: Dictionary = _months[index] as Dictionary
		if int(ym["year"]) == int(parts["year"]) and int(ym["month"]) == int(parts["month"]):
			_month_select.select(index)
			break
	_apply_month_range()
	_date_spin.value = int(parts["day"])
	_syncing = was_syncing


# 選択中の月で指定できる日の範囲。開幕月/最終月は本日/最終日で切り、それ以外は月の全日。
func _apply_month_range() -> void:
	if _months.is_empty():
		return
	var ym: Dictionary = _months[max(0, _month_select.selected)] as Dictionary
	var year: int = int(ym["year"])
	var month: int = int(ym["month"])
	var first: Dictionary = _date_parts(_first_day)
	var last: Dictionary = _date_parts(_last_day)
	var month_last_date: String = SeasonCalendar.last_day_of_month("%04d-%02d-01" % [year, month])
	var min_day: int = 1
	var max_day: int = int(month_last_date.split("-")[2])
	if year == int(first["year"]) and month == int(first["month"]):
		min_day = int(first["day"])
	if year == int(last["year"]) and month == int(last["month"]):
		max_day = int(last["day"])
	_date_spin.min_value = min_day
	_date_spin.max_value = max_day


func _update_preview() -> void:
	if _preview == null:
		return
	if not has_targets():
		_preview.text = Loc.t("sim.error.no_unplayed_games")
		return
	_preview.text = Loc.t("skip_dialog.preview", {
		"date": _date_label(_end_day),
		"days": _end_day - _first_day + 1,
		"games": AppState.count_unplayed_games_through_day(_end_day),
	})


func _on_confirmed() -> void:
	if not has_targets():
		return
	# 入力中の文字列は update_on_text_changed で値へ反映済み。ここで apply() すると、もう片方の
	# 入力から書き戻した直後 (表示文字列の更新前) の値を古い文字列で上書きしてしまう。
	target_chosen.emit(selected_end_day(), selected_skip_name())


func _make_row(caption: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", max(6, int(round(10.0 * _scale_factor))))
	var label: Label = _make_label(caption, GameDialogStyle.MUTED)
	label.custom_minimum_size = Vector2(44.0, 0.0) * _scale_factor
	row.add_child(label)
	return row


func _make_spin(min_value: int, max_value: int, value: int) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = 1
	spin.rounded = true
	spin.value = value
	spin.update_on_text_changed = true
	spin.select_all_on_focus = true
	spin.custom_minimum_size = Vector2(110.0, 0.0) * _scale_factor
	GameDialogStyle.style_spin_box(spin, _font, _scale_factor)
	return spin


func _make_label(text_value: String, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", max(12, int(round(15.0 * _scale_factor))))
	if _font != null:
		label.add_theme_font_override("font", _font)
	return label


func _date_parts(day: int) -> Dictionary:
	var parts: PackedStringArray = SeasonCalendar.date_for_season_day(AppState.current_season, day).split("-")
	return {"year": int(parts[0]), "month": int(parts[1]), "day": int(parts[2])}


func _date_label(day: int) -> String:
	return SeasonCalendar.label_for_date(SeasonCalendar.date_for_season_day(AppState.current_season, day))
