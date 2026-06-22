extends Control

const GrowthReporterScript = preload("res://services/reports/draft_growth_curve_reporter.gd")
const LongReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const DistributionChartScript = preload("res://ui/screens/draft_growth_distribution_chart.gd")
const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const DevChrome = preload("res://ui/components/dev_chrome.gd")

const GROWTH_REPORT_PATH: String = "res://reports/draft_growth_curve_latest.json"
const GROWTH_CSV_PATH: String = "res://reports/draft_growth_curve_latest.csv"
const LONG_REPORT_PATH: String = "res://reports/long_autoplay_latest.json"
const LONG_CSV_PATH: String = "res://reports/long_autoplay_latest.csv"
const GROWTH_COLUMN_TO_AGE: Dictionary = {
	4: 18,
	5: 22,
	6: 25,
	7: 28,
	8: 31,
	9: 36,
	10: 28,
	11: 28,
}
const TITLE_LABELS: Dictionary = {
	"average": "首位打者",
	"ops": "OPS",
	"home_runs": "本塁打",
	"rbi": "打点",
	"hits": "安打",
	"walks": "四球",
	"era": "防御率",
	"whip": "WHIP",
	"wins": "勝利",
	"strikeouts": "奪三振",
	"saves": "セーブ",
	"home_runs_per_nine": "HR/9",
}

var growth_samples_spin: SpinBox
var growth_min_age_spin: SpinBox
var growth_max_age_spin: SpinBox
var growth_seed_edit: LineEdit
var growth_run_button: Button
var growth_status_label: Label
var growth_tree: Tree
var growth_distribution_label: Label
var growth_distribution_chart: Control
var growth_distribution_tree: Tree

var long_seasons_spin: SpinBox
var long_start_year_spin: SpinBox
var long_selected_team_spin: SpinBox
var long_seed_edit: LineEdit
var long_run_button: Button
var long_status_label: Label
var long_overview_tree: Tree
var long_yearly_tree: Tree
var long_ability_tree: Tree
var long_title_tree: Tree

var current_growth_report: Dictionary = {}
var current_long_report: Dictionary = {}


func _ready() -> void:
	_build()
	_load_existing_reports()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	add_child(root)
	DevChrome.apply_chrome(self, root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "ドラフト検証"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevChrome.style_title(title)
	header.add_child(title)

	var balance_button: Button = Button.new()
	balance_button.text = "バランスレポート"
	balance_button.custom_minimum_size = Vector2(132, 34)
	balance_button.pressed.connect(func() -> void: AppState.request_screen("balance_report", false))
	DevChrome.style_button(balance_button)
	header.add_child(balance_button)

	var back_button: Button = Button.new()
	back_button.text = "タイトルへ戻る"
	back_button.custom_minimum_size = Vector2(128, 34)
	back_button.pressed.connect(func() -> void: AppState.request_screen("start"))
	DevChrome.style_primary(back_button)
	header.add_child(back_button)

	var tabs: TabContainer = TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	tabs.add_child(_build_growth_tab())
	tabs.add_child(_build_long_tab())


func _build_growth_tab() -> Control:
	var margin: MarginContainer = MarginContainer.new()
	margin.name = "ドラフト成長曲線"
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_bottom", 4)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var controls: HBoxContainer = HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	root.add_child(controls)

	_add_label(controls, "サンプル")
	growth_samples_spin = _spin(1000, 500000, 1000, 50000, Vector2(110, 34))
	controls.add_child(growth_samples_spin)

	_add_label(controls, "年齢")
	growth_min_age_spin = _spin(16, 40, 1, 18, Vector2(70, 34))
	controls.add_child(growth_min_age_spin)
	_add_label(controls, "-")
	growth_max_age_spin = _spin(16, 45, 1, 36, Vector2(70, 34))
	controls.add_child(growth_max_age_spin)

	_add_label(controls, "Seed")
	growth_seed_edit = LineEdit.new()
	growth_seed_edit.text = "20260528"
	growth_seed_edit.custom_minimum_size = Vector2(120, 34)
	controls.add_child(growth_seed_edit)

	growth_run_button = Button.new()
	growth_run_button.text = "実行"
	growth_run_button.custom_minimum_size = Vector2(92, 34)
	growth_run_button.pressed.connect(_run_growth)
	controls.add_child(growth_run_button)

	growth_status_label = Label.new()
	growth_status_label.text = ""
	growth_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(growth_status_label)

	growth_tree = _create_table(
		["出身", "区分", "件数", "初期総合", "18歳", "22歳", "25歳", "28歳", "31歳", "36歳", "28歳P10", "28歳P90"],
		[120, 70, 72, 86, 70, 70, 70, 70, 70, 70, 80, 80]
	)
	growth_tree.custom_minimum_size = Vector2(0, 220)
	growth_tree.cell_selected.connect(_on_growth_cell_selected)

	var split: VSplitContainer = VSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	split.add_child(growth_tree)

	var distribution_panel: VBoxContainer = VBoxContainer.new()
	distribution_panel.add_theme_constant_override("separation", 4)
	distribution_panel.custom_minimum_size = Vector2(0, 340)
	split.add_child(distribution_panel)

	growth_distribution_label = Label.new()
	growth_distribution_label.text = "年齢セルを選択すると総合能力値の分布を表示します"
	distribution_panel.add_child(growth_distribution_label)

	growth_distribution_tree = _create_table(
		["総合", "人数", "割合", "累積", "分布"],
		[70, 80, 80, 80, 420]
	)
	growth_distribution_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	distribution_panel.add_child(growth_distribution_tree)
	growth_distribution_tree.visible = false

	growth_distribution_chart = DistributionChartScript.new()
	growth_distribution_chart.custom_minimum_size = Vector2(0, 300)
	growth_distribution_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	growth_distribution_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	distribution_panel.add_child(growth_distribution_chart)
	return margin


func _build_long_tab() -> Control:
	var margin: MarginContainer = MarginContainer.new()
	margin.name = "長期オートプレイ"
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_bottom", 4)

	var root: VBoxContainer = VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var controls: HBoxContainer = HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	root.add_child(controls)

	_add_label(controls, "年数")
	long_seasons_spin = _spin(1, 100, 1, 40, Vector2(82, 34))
	controls.add_child(long_seasons_spin)

	_add_label(controls, "開始年")
	long_start_year_spin = _spin(1900, 2200, 1, 2026, Vector2(90, 34))
	controls.add_child(long_start_year_spin)

	_add_label(controls, "チーム")
	long_selected_team_spin = _spin(1, max(1, GameDb.get_team_count()), 1, max(1, AppState.selected_team_id), Vector2(78, 34))
	controls.add_child(long_selected_team_spin)

	_add_label(controls, "Seed")
	long_seed_edit = LineEdit.new()
	long_seed_edit.text = "20260528"
	long_seed_edit.custom_minimum_size = Vector2(120, 34)
	controls.add_child(long_seed_edit)

	long_run_button = Button.new()
	long_run_button.text = "実行"
	long_run_button.custom_minimum_size = Vector2(92, 34)
	long_run_button.pressed.connect(_run_long_autoplay)
	controls.add_child(long_run_button)

	long_status_label = Label.new()
	long_status_label.text = ""
	long_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(long_status_label)

	long_overview_tree = _create_table(["項目", "値"], [250, 260])
	long_overview_tree.custom_minimum_size = Vector2(0, 190)
	root.add_child(long_overview_tree)

	var result_tabs: TabContainer = TabContainer.new()
	result_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(result_tabs)

	long_yearly_tree = _create_table(
		["年", "現役", "ドラフト%", "平均総合", "打総", "投総", "得点/チーム", "AVG", "OBP", "SLG", "OPS", "HR/G", "BB/G", "K/G", "ERA", "WHIP", "K/9", "BB/9", "HR/9", "戦力外", "新人"],
		[68, 68, 82, 82, 70, 70, 98, 68, 68, 68, 68, 72, 72, 72, 68, 72, 68, 68, 68, 68, 68]
	)
	_add_table_tab(result_tabs, long_yearly_tree, "年次指標")

	long_ability_tree = _create_table(
		["年", "打総", "Bat_KAvoid z", "Bat_BB z", "Bat_Impact z", "Bat_Loft z", "Bat_Barrel z", "Bat_Spray z", "走力 z", "投総", "Pit_K z", "Pit_BBPrev z", "Pit_ImpactLim z", "Pit_LoftCtl z", "Pit_BarrelDeny z", "Pit_Eff z", "Pit_Stam z"],
		[68, 70, 98, 88, 100, 88, 100, 94, 76, 70, 84, 104, 116, 104, 120, 84, 90]
	)
	_add_table_tab(result_tabs, long_ability_tree, "平均能力")

	long_title_tree = _create_table(
		["区分", "指標", "年", "1位", "2位", "3位"],
		[70, 86, 68, 220, 220, 220]
	)
	_add_table_tab(result_tabs, long_title_tree, "タイトル争い")
	return margin


func _run_growth() -> void:
	_commit_pending_input()
	growth_run_button.disabled = true
	growth_status_label.text = "実行中..."

	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("ドラフト成長曲線を集計中...")
	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)

	var reporter: Object = GrowthReporterScript.new()
	current_growth_report = await reporter.call("run_async", {
		"samples": int(growth_samples_spin.value),
		"min_age": int(growth_min_age_spin.value),
		"max_age": int(growth_max_age_spin.value),
		"seed": _seed_value(growth_seed_edit, 20260528),
		"scene_tree": get_tree(),
		"cancel_token": cancel_token,
		"progress_callback": update_overlay,
		"chunk_size": 250,
	}) as Dictionary

	overlay.hide_progress()
	overlay.queue_free()
	_render_growth_report()
	if bool(current_growth_report.get("cancelled", false)):
		growth_status_label.text = "キャンセル: %d / %d件まで集計" % [
			int(current_growth_report.get("candidates_generated", 0)),
			int(current_growth_report.get("samples_requested", 0)),
		]
		growth_run_button.disabled = false
		return

	var json_ok: bool = _write_text(GROWTH_REPORT_PATH, JSON.stringify(current_growth_report, "\t"))
	var csv_ok: bool = _write_text(GROWTH_CSV_PATH, str(reporter.call("csv_text", current_growth_report)))
	growth_status_label.text = "完了: %d件 / JSON:%s CSV:%s" % [
		int(current_growth_report.get("candidates_generated", 0)),
		"OK" if json_ok else "NG",
		"OK" if csv_ok else "NG",
	]
	growth_run_button.disabled = false


func _run_long_autoplay() -> void:
	_commit_pending_input()
	long_run_button.disabled = true
	long_status_label.text = "実行中..."

	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("長期オートプレイを実行中...")
	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)

	var reporter: Object = LongReporterScript.new()
	current_long_report = await reporter.call("run_async", {
		"seasons": int(long_seasons_spin.value),
		"start_year": int(long_start_year_spin.value),
		"selected_team_id": int(long_selected_team_spin.value),
		"seed": _seed_value(long_seed_edit, 20260528),
		"dh_by_league": AppState.dh_settings_for_schedule(),
		"scene_tree": get_tree(),
		"cancel_token": cancel_token,
		"progress_callback": update_overlay,
	}) as Dictionary

	overlay.hide_progress()
	overlay.queue_free()
	_render_long_report()
	var completed: int = int(current_long_report.get("seasons_completed", 0))
	var requested: int = int(current_long_report.get("seasons_requested", 0))
	if bool(current_long_report.get("cancelled", false)):
		long_status_label.text = "キャンセル: %d / %d年完了" % [completed, requested]
		long_run_button.disabled = false
		return

	var json_ok: bool = _write_text(LONG_REPORT_PATH, JSON.stringify(current_long_report, "\t"))
	var csv_ok: bool = _write_text(LONG_CSV_PATH, str(reporter.call("csv_text", current_long_report)))
	long_status_label.text = "完了: %d / %d年 / JSON:%s CSV:%s" % [
		completed,
		requested,
		"OK" if json_ok else "NG",
		"OK" if csv_ok else "NG",
	]
	long_run_button.disabled = false


func _load_existing_reports() -> void:
	current_growth_report = _read_report(GROWTH_REPORT_PATH)
	_render_growth_report()
	if current_growth_report.is_empty():
		growth_status_label.text = "未実行"
	else:
		growth_status_label.text = "読み込み済み: %s" % ProjectSettings.globalize_path(GROWTH_REPORT_PATH)

	current_long_report = _read_report(LONG_REPORT_PATH)
	_render_long_report()
	if current_long_report.is_empty():
		long_status_label.text = "未実行"
	else:
		long_status_label.text = "読み込み済み: %s" % ProjectSettings.globalize_path(LONG_REPORT_PATH)


func _render_growth_report() -> void:
	growth_tree.clear()
	_clear_growth_distribution("年齢セルを選択すると総合能力値の分布を表示します")
	var root: TreeItem = growth_tree.create_item()
	if current_growth_report.is_empty():
		return
	var source_order: Array = current_growth_report.get("source_order", []) as Array
	var sources: Dictionary = current_growth_report.get("sources", {}) as Dictionary
	var source_position_splits: Dictionary = current_growth_report.get("source_position_splits", {}) as Dictionary
	for source_value in source_order:
		var source_type: String = str(source_value)
		var splits: Dictionary = source_position_splits.get(source_type, {}) as Dictionary
		if splits.is_empty():
			_add_growth_row(root, source_type, "全体", sources.get(source_type, {}) as Dictionary)
			continue
		for player_group in ["pitcher", "fielder"]:
			if splits.has(player_group):
				_add_growth_row(root, source_type, _player_group_label(player_group), splits[player_group] as Dictionary)


func _add_growth_row(root: TreeItem, source_type: String, player_group_label: String, source: Dictionary) -> void:
	var item: TreeItem = growth_tree.create_item(root)
	item.set_text(0, source_type)
	item.set_text(1, player_group_label)
	item.set_text(2, "%d" % int(source.get("count", 0)))
	var initial: Dictionary = source.get("initial", {}) as Dictionary
	item.set_text(3, _format_float(float(initial.get("overall_mean", 0.0)), 1))
	var checkpoint_ages: Array = [18, 22, 25, 28, 31, 36]
	for i in range(checkpoint_ages.size()):
		var row: Dictionary = _growth_age_row(source, int(checkpoint_ages[i]))
		item.set_text(4 + i, _format_float(float(row.get("overall_mean", 0.0)), 1) if not row.is_empty() else "-")
	var age_28: Dictionary = _growth_age_row(source, 28)
	item.set_text(10, _format_float(float(age_28.get("overall_p10", 0.0)), 1) if not age_28.is_empty() else "-")
	item.set_text(11, _format_float(float(age_28.get("overall_p90", 0.0)), 1) if not age_28.is_empty() else "-")


func _on_growth_cell_selected() -> void:
	var item: TreeItem = growth_tree.get_selected()
	if item == null:
		return
	var selected_column: int = growth_tree.get_selected_column()
	if not GROWTH_COLUMN_TO_AGE.has(selected_column):
		_clear_growth_distribution("年齢列を選択してください")
		return
	var source_type: String = item.get_text(0)
	var player_group: String = _growth_player_group_key(item.get_text(1))
	var age: int = int(GROWTH_COLUMN_TO_AGE[selected_column])
	_render_growth_distribution(source_type, player_group, age)


func _render_growth_distribution(source_type: String, player_group: String, age: int) -> void:
	var source: Dictionary = _growth_group_data(source_type, player_group)
	if source.is_empty():
		_clear_growth_distribution("分布データがありません")
		return
	var row: Dictionary = _growth_age_row(source, age)
	if row.is_empty():
		_clear_growth_distribution("%s / %s / %d歳のデータがありません" % [source_type, _player_group_label(player_group), age])
		return
	var distribution: Dictionary = row.get("overall_distribution", {}) as Dictionary
	var bins: Array = distribution.get("bins", []) as Array
	if bins.is_empty():
		_clear_growth_distribution("このレポートには分布データがありません。再実行すると表示できます")
		return

	growth_distribution_tree.clear()
	var root: TreeItem = growth_distribution_tree.create_item()
	var observations: int = int(row.get("observations", distribution.get("count", 0)))
	var max_count: int = 1
	for bin_value in bins:
		var bin: Dictionary = bin_value as Dictionary
		max_count = max(max_count, int(bin.get("count", 0)))
	for bin_value in bins:
		var bin: Dictionary = bin_value as Dictionary
		var count: int = int(bin.get("count", 0))
		var item: TreeItem = growth_distribution_tree.create_item(root)
		item.set_text(0, "%d" % int(bin.get("overall", 0)))
		item.set_text(1, "%d" % count)
		item.set_text(2, _format_percent(float(bin.get("rate", 0.0))))
		item.set_text(3, _format_percent(float(bin.get("cumulative_rate", 0.0))))
		item.set_text(4, _bar_text(count, max_count, 38))
	growth_distribution_label.text = "%s / %s / %d歳  n=%d  平均%s  P10-%s  P50-%s  P90-%s" % [
		source_type,
		_player_group_label(player_group),
		age,
		observations,
		_format_float(float(row.get("overall_mean", 0.0)), 1),
		_format_float(float(row.get("overall_p10", 0.0)), 1),
		_format_float(float(row.get("overall_p50", 0.0)), 1),
		_format_float(float(row.get("overall_p90", 0.0)), 1),
	]
	var title_text: String = "%s / %s / %d歳" % [source_type, _player_group_label(player_group), age]
	var subtitle_text: String = "n=%d  AVG %s  P10 %s  P50 %s  P90 %s" % [
		observations,
		_format_float(float(row.get("overall_mean", 0.0)), 1),
		_format_float(float(row.get("overall_p10", 0.0)), 1),
		_format_float(float(row.get("overall_p50", 0.0)), 1),
		_format_float(float(row.get("overall_p90", 0.0)), 1),
	]
	growth_distribution_label.text = "%s  %s" % [title_text, subtitle_text]
	if growth_distribution_chart != null:
		growth_distribution_chart.call("set_distribution", bins, title_text, subtitle_text, {
			"mean": float(row.get("overall_mean", 0.0)),
			"p10": float(row.get("overall_p10", 0.0)),
			"p50": float(row.get("overall_p50", 0.0)),
			"p90": float(row.get("overall_p90", 0.0)),
		})


func _clear_growth_distribution(message: String) -> void:
	if growth_distribution_label != null:
		growth_distribution_label.text = message
	if growth_distribution_tree != null:
		growth_distribution_tree.clear()
		growth_distribution_tree.create_item()
	if growth_distribution_chart != null:
		growth_distribution_chart.call("clear_message", message)


func _render_long_report() -> void:
	long_overview_tree.clear()
	long_yearly_tree.clear()
	long_ability_tree.clear()
	long_title_tree.clear()
	var overview_root: TreeItem = long_overview_tree.create_item()
	var yearly_root: TreeItem = long_yearly_tree.create_item()
	var ability_root: TreeItem = long_ability_tree.create_item()
	var title_root: TreeItem = long_title_tree.create_item()
	if current_long_report.is_empty():
		return

	var milestones: Dictionary = current_long_report.get("milestones", {}) as Dictionary
	var final_roster: Dictionary = current_long_report.get("final_roster_after_last_offseason", {}) as Dictionary
	var windows: Dictionary = current_long_report.get("window_summaries", {}) as Dictionary
	var last_10: Dictionary = windows.get("last_10_years", {}) as Dictionary
	_add_metric(overview_root, "完了年数", "%d / %d" % [int(current_long_report.get("seasons_completed", 0)), int(current_long_report.get("seasons_requested", 0))])
	_add_metric(overview_root, "Seed", str(current_long_report.get("seed", "")))
	_add_metric(overview_root, "ドラフト95%到達年", _year_or_dash(int(milestones.get("draft_generated_95_percent_year", 0))))
	_add_metric(overview_root, "ドラフトのみ到達年", _year_or_dash(int(milestones.get("draft_only_year", 0))))
	_add_metric(overview_root, "最終現役人数", "%d" % int(final_roster.get("active_players", 0)))
	_add_metric(overview_root, "最終ドラフト比率", _format_percent(float(final_roster.get("draft_generated_ratio", 0.0))))
	_add_metric(overview_root, "最終平均総合", _format_float(float(final_roster.get("average_overall", 0.0)), 1))
	if not last_10.is_empty():
		_add_metric(overview_root, "直近10年 得点/チーム試合", _format_float(float(last_10.get("runs_per_team_game", 0.0)), 3))
		_add_metric(overview_root, "直近10年 AVG / OBP / SLG", "%s / %s / %s" % [
			_format_float(float(last_10.get("batting_average", 0.0)), 3),
			_format_float(float(last_10.get("on_base_percentage", 0.0)), 3),
			_format_float(float(last_10.get("slugging_percentage", 0.0)), 3),
		])
		_add_metric(overview_root, "直近10年 OPS / ERA", "%s / %s" % [
			_format_float(float(last_10.get("ops", 0.0)), 3),
			_format_float(float(last_10.get("era", 0.0)), 2),
		])
		_add_metric(overview_root, "直近10年 HR/G / HR/9", "%s / %s" % [
			_format_float(float(last_10.get("home_runs_per_game", 0.0)), 3),
			_format_float(float(last_10.get("home_runs_per_nine", 0.0)), 2),
		])
		_add_metric(overview_root, "直近10年 Bat_Impact z / Pit_ImpactLimit z", "%s / %s" % [
			_format_z(_coerce_z_value(float(last_10.get("average_bat_impact", 0.0)))),
			_format_z(_coerce_z_value(float(last_10.get("average_pit_impact_limit", 0.0)))),
		])

	for row_value in current_long_report.get("yearly", []) as Array:
		var row: Dictionary = row_value as Dictionary
		var roster: Dictionary = row.get("roster_before_season", {}) as Dictionary
		var season_summary: Dictionary = row.get("season", {}) as Dictionary
		var batting: Dictionary = season_summary.get("batting", {}) as Dictionary
		var pitching: Dictionary = season_summary.get("pitching", {}) as Dictionary
		var offseason: Dictionary = row.get("offseason", {}) as Dictionary
		var item: TreeItem = long_yearly_tree.create_item(yearly_root)
		item.set_text(0, "%d" % int(row.get("year", 0)))
		item.set_text(1, "%d" % int(roster.get("active_players", 0)))
		item.set_text(2, _format_percent(float(roster.get("draft_generated_ratio", 0.0))))
		item.set_text(3, _format_float(float(roster.get("average_overall", 0.0)), 1))
		item.set_text(4, _format_float(float(roster.get("average_batter_overall", 0.0)), 1))
		item.set_text(5, _format_float(float(roster.get("average_pitcher_overall", 0.0)), 1))
		item.set_text(6, _format_float(float(season_summary.get("runs_per_team_game", 0.0)), 3))
		item.set_text(7, _format_float(float(batting.get("batting_average", 0.0)), 3))
		item.set_text(8, _format_float(float(batting.get("on_base_percentage", 0.0)), 3))
		item.set_text(9, _format_float(float(batting.get("slugging_percentage", 0.0)), 3))
		item.set_text(10, _format_float(float(batting.get("ops", 0.0)), 3))
		item.set_text(11, _format_float(float(batting.get("home_runs_per_game", 0.0)), 3))
		item.set_text(12, _format_float(float(batting.get("walks_per_game", 0.0)), 3))
		item.set_text(13, _format_float(float(batting.get("strikeouts_per_game", 0.0)), 3))
		item.set_text(14, _format_float(float(pitching.get("era", 0.0)), 2))
		item.set_text(15, _format_float(float(pitching.get("whip", 0.0)), 3))
		item.set_text(16, _format_float(float(pitching.get("strikeouts_per_nine", 0.0)), 2))
		item.set_text(17, _format_float(float(pitching.get("walks_per_nine", 0.0)), 2))
		item.set_text(18, _format_float(float(pitching.get("home_runs_per_nine", 0.0)), 2))
		item.set_text(19, "%d" % int(offseason.get("released_count", 0)))
		item.set_text(20, "%d" % int(offseason.get("rookies_count", 0)))
		_add_ability_row(ability_root, row)

	_fill_title_rows(title_root, current_long_report.get("yearly", []) as Array)


func _create_table(headers: Array, widths: Array) -> Tree:
	var tree: Tree = Tree.new()
	tree.hide_root = true
	tree.column_titles_visible = true
	tree.columns = headers.size()
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for i in range(headers.size()):
		tree.set_column_title(i, str(headers[i]))
		tree.set_column_title_alignment(i, HORIZONTAL_ALIGNMENT_LEFT)
		tree.set_column_custom_minimum_width(i, int(widths[i]))
		tree.set_column_expand(i, true)
	tree.create_item()
	return tree


func _add_table_tab(tabs: TabContainer, table: Tree, title: String) -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.name = title
	margin.add_theme_constant_override("margin_left", 4)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(table)
	tabs.add_child(margin)


func _add_ability_row(root: TreeItem, row: Dictionary) -> void:
	var roster: Dictionary = row.get("roster_before_season", {}) as Dictionary
	var item: TreeItem = long_ability_tree.create_item(root)
	item.set_text(0, "%d" % int(row.get("year", 0)))
	item.set_text(1, _format_float(float(roster.get("average_batter_overall", 0.0)), 1))
	item.set_text(2, _format_z(_ability_mean(roster, "batters", "Bat_KAvoid")))
	item.set_text(3, _format_z(_ability_mean(roster, "batters", "Bat_BBCreate")))
	item.set_text(4, _format_z(_ability_mean(roster, "batters", "Bat_Impact")))
	item.set_text(5, _format_z(_ability_mean(roster, "batters", "Bat_Loft")))
	item.set_text(6, _format_z(_ability_mean(roster, "batters", "Bat_Barrel")))
	item.set_text(7, _format_z(_ability_mean(roster, "batters", "Bat_Spray")))
	item.set_text(8, _format_z(_ability_mean(roster, "batters", "Run_Speed")))
	item.set_text(9, _format_float(float(roster.get("average_pitcher_overall", 0.0)), 1))
	item.set_text(10, _format_z(_ability_mean(roster, "pitchers", "Pit_KCreate")))
	item.set_text(11, _format_z(_ability_mean(roster, "pitchers", "Pit_BBPrevent")))
	item.set_text(12, _format_z(_ability_mean(roster, "pitchers", "Pit_ImpactLimit")))
	item.set_text(13, _format_z(_ability_mean(roster, "pitchers", "Pit_LoftControl")))
	item.set_text(14, _format_z(_ability_mean(roster, "pitchers", "Pit_BarrelDeny")))
	item.set_text(15, _format_z(_ability_mean(roster, "pitchers", "Pit_Efficiency")))
	item.set_text(16, _format_z(_ability_mean(roster, "pitchers", "Pit_Stamina")))


func _fill_title_rows(root: TreeItem, yearly_rows: Array) -> void:
	var rows: Array = yearly_rows.duplicate()
	rows.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary).get("year", 0)) < int((b as Dictionary).get("year", 0))
	)

	for metric in ["average", "ops", "home_runs", "rbi", "hits", "walks"]:
		for row_value in rows:
			var row: Dictionary = row_value as Dictionary
			var leaderboards: Dictionary = row.get("leaderboards", {}) as Dictionary
			var batting: Dictionary = leaderboards.get("batting", {}) as Dictionary
			_add_title_row(root, int(row.get("year", 0)), "打撃", metric, batting.get(metric, []) as Array)

	for metric in ["era", "whip", "wins", "strikeouts", "saves", "home_runs_per_nine"]:
		for row_value in rows:
			var row: Dictionary = row_value as Dictionary
			var leaderboards: Dictionary = row.get("leaderboards", {}) as Dictionary
			var pitching: Dictionary = leaderboards.get("pitching", {}) as Dictionary
			_add_title_row(root, int(row.get("year", 0)), "投手", metric, pitching.get(metric, []) as Array)


func _add_title_row(root: TreeItem, year: int, group_label: String, metric: String, rows: Array) -> void:
	var item: TreeItem = long_title_tree.create_item(root)
	item.set_text(0, group_label)
	item.set_text(1, str(TITLE_LABELS.get(metric, metric)))
	item.set_text(2, "%d" % year)
	for i in range(3):
		item.set_text(3 + i, _leader_text(rows, i))


func _leader_text(rows: Array, index: int) -> String:
	if index >= rows.size():
		return "-"
	var row: Dictionary = rows[index] as Dictionary
	var draft_mark: String = "D" if bool(row.get("draft_generated", false)) else "I"
	return "%s %s %s (%s, %s, OVR%d)" % [
		str(row.get("display", "")),
		str(row.get("name", "")),
		draft_mark,
		str(row.get("team", "")),
		"%d歳" % int(row.get("age", 0)),
		int(row.get("overall", 0)),
	]


func _ability_mean(roster: Dictionary, group: String, key: String) -> float:
	var ability_averages: Dictionary = roster.get("ability_averages", {}) as Dictionary
	var group_rows: Dictionary = ability_averages.get(group, {}) as Dictionary
	return _coerce_z_value(float(group_rows.get(key, 0.0)))


func _add_label(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(label)


func _spin(min_value: float, max_value: float, step: float, value: float, box_size: Vector2) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = box_size
	return spin


func _add_metric(root: TreeItem, label: String, value: String) -> void:
	var item: TreeItem = long_overview_tree.create_item(root)
	item.set_text(0, label)
	item.set_text(1, value)


func _growth_age_row(source: Dictionary, age: int) -> Dictionary:
	for row_value in source.get("age_curve", []) as Array:
		var row: Dictionary = row_value as Dictionary
		if int(row.get("age", 0)) == age:
			return row
	return {}


func _growth_group_data(source_type: String, player_group: String) -> Dictionary:
	if current_growth_report.is_empty():
		return {}
	if player_group == "all":
		var sources: Dictionary = current_growth_report.get("sources", {}) as Dictionary
		return sources.get(source_type, {}) as Dictionary
	var source_position_splits: Dictionary = current_growth_report.get("source_position_splits", {}) as Dictionary
	var splits: Dictionary = source_position_splits.get(source_type, {}) as Dictionary
	return splits.get(player_group, {}) as Dictionary


func _growth_player_group_key(label: String) -> String:
	if label == _player_group_label("pitcher"):
		return "pitcher"
	if label == _player_group_label("fielder"):
		return "fielder"
	return "all"


func _player_group_label(player_group: String) -> String:
	match player_group:
		"all":
			return "全体"
		"pitcher":
			return "投手"
		"fielder":
			return "野手"
		_:
			return player_group


func _read_report(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func _write_text(path: String, text: String) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(parent_dir) != OK:
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	return true


func _selected_metadata(select: OptionButton) -> String:
	if select == null or select.selected < 0:
		return ""
	return str(select.get_item_metadata(select.selected))


func _seed_value(edit: LineEdit, default_value: int) -> int:
	var text: String = edit.text.strip_edges()
	if text.is_valid_int():
		return int(text)
	return default_value


func _commit_pending_input() -> void:
	var viewport: Viewport = get_viewport()
	if viewport != null:
		viewport.gui_release_focus()


func _format_float(value: float, digits: int) -> String:
	var pattern: String = "%." + str(digits) + "f"
	return pattern % value


func _format_z(value: float) -> String:
	return "%+.2f" % value


func _coerce_z_value(value: float) -> float:
	if absf(value) > 8.0:
		return PSAbilityScale.display_to_z(clampi(int(round(value)), PSAbilityScale.DISPLAY_MIN, PSAbilityScale.DISPLAY_MAX))
	return value


func _format_percent(value: float) -> String:
	return "%.1f%%" % (value * 100.0)


func _bar_text(count: int, max_count: int, width: int) -> String:
	if max_count <= 0 or count <= 0:
		return ""
	var filled: int = clampi(int(round(float(count) / float(max_count) * float(width))), 1, width)
	return "#".repeat(filled)


func _year_or_dash(year: int) -> String:
	return "-" if year <= 0 else str(year)
