extends Control

const RunnerScript = preload("res://services/reports/player_probe_runner.gd")
const ChartScript = preload("res://ui/screens/player_probe_chart.gd")
const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const DevChrome = preload("res://ui/components/dev_chrome.gd")
const REPORT_PATH: String = "res://reports/player_probe_ui_latest.json"
const CSV_PATH: String = "res://reports/player_probe_ui_latest.csv"
const GRAPH_PATH: String = "res://reports/player_probe_ui_latest.svg"
const BATTER_ABILITIES: Array = [
	{"label": "K回避", "key": "Bat_KAvoid", "value": 0.8},
	{"label": "四球生成", "key": "Bat_BBCreate", "value": 0.8},
	{"label": "打球威力", "key": "Bat_Impact", "value": 0.8},
	{"label": "弾道", "key": "Bat_Loft", "value": 0.8},
	{"label": "芯捉え", "key": "Bat_Barrel", "value": 0.8},
	{"label": "打球方向", "key": "Bat_Spray", "value": 0.0},
	{"label": "積極性", "key": "Bat_Aggression", "value": 0.0},
	{"label": "左右対応", "key": "Bat_Platoon", "value": 0.0},
	{"label": "走力", "key": "Run_Speed", "value": 0.8},
]
const PITCHER_ABILITIES: Array = [
	{"label": "球速", "key": "max_velocity", "value": 146.0, "min": 128.0, "max": 165.0, "step": 1.0, "kind": "raw"},
	{"label": "奪三振", "key": "Pit_KCreate", "value": 0.8},
	{"label": "四球抑制", "key": "Pit_BBPrevent", "value": 0.8},
	{"label": "強打抑制", "key": "Pit_ImpactLimit", "value": 0.8},
	{"label": "弾道抑制", "key": "Pit_LoftControl", "value": 0.8},
	{"label": "芯外し", "key": "Pit_BarrelDeny", "value": 0.8},
	{"label": "投球効率", "key": "Pit_Efficiency", "value": 0.8},
	{"label": "スタミナ", "key": "Pit_Stamina", "value": 1.6},
	{"label": "疲労耐性", "key": "Pit_FatigueResist", "value": 0.8},
	{"label": "走者抑制", "key": "Pit_HoldRunner", "value": 0.8},
	{"label": "ゾーン端", "key": "Pit_EdgeRate", "value": 0.0},
]
const FIELDING_ABILITIES: Array = []
const BATTER_METRICS: Array = [
	{"label": "本塁打", "key": "home_runs"},
	{"label": "HR%", "key": "home_run_rate"},
	{"label": "打率", "key": "batting_average"},
	{"label": "出塁率", "key": "on_base_percentage"},
	{"label": "長打率", "key": "slugging_percentage"},
	{"label": "OPS", "key": "ops"},
	{"label": "wOBA", "key": "woba"},
	{"label": "xwOBA", "key": "xwoba"},
	{"label": "wRC+", "key": "wrc_plus"},
	{"label": "RE24", "key": "re24"},
	{"label": "BsR", "key": "bsr"},
	{"label": "OAA", "key": "oaa"},
	{"label": "OAA IF", "key": "oaa_infield"},
	{"label": "OAA OF", "key": "oaa_outfield"},
	{"label": "RngR", "key": "rngr"},
	{"label": "ErrR", "key": "errr"},
	{"label": "DPR", "key": "dpr"},
	{"label": "UZR", "key": "uzr"},
	{"label": "DRS", "key": "drs"},
	{"label": "PosAdj", "key": "positional_adjustment_runs"},
	{"label": "Def", "key": "def_runs"},
	{"label": "二塁打", "key": "doubles"},
	{"label": "三振率", "key": "strikeout_rate"},
	{"label": "四球率", "key": "walk_rate"},
]
const PITCHER_METRICS: Array = [
	{"label": "ERA", "key": "era"},
	{"label": "WHIP", "key": "whip"},
	{"label": "K/9", "key": "strikeouts_per_nine"},
	{"label": "BB/9", "key": "walks_per_nine"},
	{"label": "HR/9", "key": "home_runs_per_nine"},
	{"label": "wOBAA", "key": "woba_allowed"},
	{"label": "xwOBAA", "key": "xwoba_allowed"},
	{"label": "wRC+ A", "key": "wrc_plus_allowed"},
	{"label": "RE24 A", "key": "re24_allowed"},
	{"label": "BsR", "key": "bsr"},
	{"label": "OAA", "key": "oaa"},
	{"label": "OAA IF", "key": "oaa_infield"},
	{"label": "OAA OF", "key": "oaa_outfield"},
	{"label": "RngR", "key": "rngr"},
	{"label": "ErrR", "key": "errr"},
	{"label": "DPR", "key": "dpr"},
	{"label": "UZR", "key": "uzr"},
	{"label": "DRS", "key": "drs"},
	{"label": "PosAdj", "key": "positional_adjustment_runs"},
	{"label": "Def", "key": "def_runs"},
	{"label": "被本塁打", "key": "home_runs_allowed"},
	{"label": "奪三振", "key": "strikeouts"},
	{"label": "与四球", "key": "walks"},
]

var mode_select: OptionButton
var target_spin: SpinBox
var target_label: Label
var ability_grid: GridContainer
var ability_select: OptionButton
var metric_select: OptionButton
var start_spin: SpinBox
var end_spin: SpinBox
var step_spin: SpinBox
var iterations_spin: SpinBox
var seed_edit: LineEdit
var run_button: Button
var status_label: Label
var result_tree: Tree
var summary_label: RichTextLabel
var chart: Control
var ability_spins: Dictionary = {}
var current_report: Dictionary = {}
var result_sort_column: int = -1
var result_sort_ascending: bool = false


func _ready() -> void:
	_build()
	_refresh_mode_controls()


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
	title.text = "選手プローブ"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevChrome.style_title(title)
	header.add_child(title)

	var report_button: Button = Button.new()
	report_button.text = "計測レポート"
	report_button.custom_minimum_size = Vector2(118, 34)
	report_button.pressed.connect(func() -> void: AppState.request_screen("balance_report", false))
	DevChrome.style_button(report_button)
	header.add_child(report_button)

	var back_button: Button = Button.new()
	back_button.text = "タイトルへ戻る"
	back_button.custom_minimum_size = Vector2(128, 34)
	back_button.pressed.connect(func() -> void: AppState.request_screen("start"))
	DevChrome.style_primary(back_button)
	header.add_child(back_button)

	var top_controls: HBoxContainer = HBoxContainer.new()
	top_controls.add_theme_constant_override("separation", 8)
	root.add_child(top_controls)

	_add_label(top_controls, "モード")
	mode_select = OptionButton.new()
	mode_select.custom_minimum_size = Vector2(120, 34)
	mode_select.add_item("野手")
	mode_select.set_item_metadata(0, "batter")
	mode_select.add_item("投手")
	mode_select.set_item_metadata(1, "pitcher")
	mode_select.item_selected.connect(func(_index: int) -> void: _refresh_mode_controls())
	top_controls.add_child(mode_select)

	target_label = Label.new()
	target_label.text = "打席"
	target_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top_controls.add_child(target_label)

	target_spin = SpinBox.new()
	target_spin.min_value = 30
	target_spin.max_value = 100000
	target_spin.step = 10
	target_spin.value = 65000
	target_spin.custom_minimum_size = Vector2(108, 34)
	top_controls.add_child(target_spin)

	_add_label(top_controls, "シード")
	seed_edit = LineEdit.new()
	seed_edit.text = "12345"
	seed_edit.custom_minimum_size = Vector2(104, 34)
	top_controls.add_child(seed_edit)

	var ability_panel: VBoxContainer = VBoxContainer.new()
	ability_panel.add_theme_constant_override("separation", 6)
	root.add_child(ability_panel)

	var ability_title: Label = Label.new()
	ability_title.text = "固定能力"
	ability_title.add_theme_font_size_override("font_size", 16)
	ability_panel.add_child(ability_title)

	ability_grid = GridContainer.new()
	ability_grid.columns = 6
	ability_grid.add_theme_constant_override("h_separation", 10)
	ability_grid.add_theme_constant_override("v_separation", 6)
	ability_panel.add_child(ability_grid)

	var sweep_controls: HBoxContainer = HBoxContainer.new()
	sweep_controls.add_theme_constant_override("separation", 8)
	root.add_child(sweep_controls)

	_add_label(sweep_controls, "変更能力")
	ability_select = OptionButton.new()
	ability_select.custom_minimum_size = Vector2(170, 34)
	ability_select.item_selected.connect(func(_index: int) -> void: _apply_default_metric())
	sweep_controls.add_child(ability_select)

	_add_label(sweep_controls, "開始")
	start_spin = _small_spin(-4.0, 4.0, 0.1, -1.0)
	sweep_controls.add_child(start_spin)

	_add_label(sweep_controls, "終了")
	end_spin = _small_spin(-4.0, 4.0, 0.1, 3.0)
	sweep_controls.add_child(end_spin)

	_add_label(sweep_controls, "刻み")
	step_spin = _small_spin(0.1, 2.0, 0.1, 0.5)
	sweep_controls.add_child(step_spin)

	_add_label(sweep_controls, "試行")
	iterations_spin = _small_spin(1, 20, 1, 2)
	sweep_controls.add_child(iterations_spin)

	_add_label(sweep_controls, "縦軸")
	metric_select = OptionButton.new()
	metric_select.custom_minimum_size = Vector2(150, 34)
	sweep_controls.add_child(metric_select)

	run_button = Button.new()
	run_button.text = "実行"
	run_button.custom_minimum_size = Vector2(94, 34)
	run_button.pressed.connect(_run_probe)
	sweep_controls.add_child(run_button)

	status_label = Label.new()
	status_label.text = "条件を設定して実行してください"
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sweep_controls.add_child(status_label)

	var split: HSplitContainer = HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var left_box: VBoxContainer = VBoxContainer.new()
	left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_box.add_theme_constant_override("separation", 8)
	split.add_child(left_box)

	result_tree = Tree.new()
	result_tree.hide_root = true
	result_tree.column_titles_visible = true
	result_tree.columns = 25
	result_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# OAA Zone は OAA の集計対象ゾーン (IF / OF) を表示し、OAA 列の解釈を明確にする。
	# UZR Pos は UZR / RngR / ErrR / DPR の集計対象ポジション (P1-P9) を表示する。
	var headers: Array = ["値", "指標", "PA/IP", "AVG/ERA", "HR/被HR", "HR%/HR9", "BB%/BB9", "K%/K9", "OPS/WHIP", "wOBA", "xwOBA", "wRC+", "RE24", "BsR", "OAA Zone", "OAA", "OAA IF", "OAA OF", "UZR Pos", "RngR", "ErrR", "DPR", "UZR", "DRS", "Def"]
	var widths: Array = [62, 76, 76, 82, 82, 86, 86, 86, 86, 74, 78, 74, 74, 70, 78, 70, 74, 74, 78, 70, 70, 70, 70, 70, 70]
	for index in range(headers.size()):
		result_tree.set_column_title(index, str(headers[index]))
		result_tree.set_column_custom_minimum_width(index, int(widths[index]))
		result_tree.set_column_expand(index, true)
	result_tree.column_title_clicked.connect(_on_result_column_title_clicked)
	left_box.add_child(result_tree)

	summary_label = RichTextLabel.new()
	summary_label.bbcode_enabled = false
	summary_label.custom_minimum_size = Vector2(420, 110)
	summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.add_child(summary_label)

	chart = ChartScript.new()
	chart.custom_minimum_size = Vector2(420, 260)
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(chart)


func _refresh_mode_controls() -> void:
	var mode: String = _selected_mode()
	target_label.text = "打席" if mode == "batter" else "投球回"
	target_spin.min_value = 30 if mode == "batter" else 10
	target_spin.max_value = 100000 if mode == "batter" else 2000
	target_spin.step = 10
	target_spin.value = 65000 if mode == "batter" else 120
	_refresh_ability_inputs(mode)
	_refresh_ability_select(mode)
	_refresh_metric_select(mode)
	_apply_default_metric()


func _refresh_ability_inputs(mode: String) -> void:
	if ability_grid == null:
		return
	for child in ability_grid.get_children():
		ability_grid.remove_child(child)
		child.queue_free()
	ability_spins.clear()
	var source: Array = _ability_items_for_mode(mode)
	for item_value in source:
		var item: Dictionary = item_value as Dictionary
		var label: Label = Label.new()
		label.text = str(item.get("label", ""))
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ability_grid.add_child(label)
		var spin: SpinBox = _small_spin(
			float(item.get("min", -4.0)),
			float(item.get("max", 4.0)),
			float(item.get("step", 0.1)),
			float(item.get("value", 0.0))
		)
		spin.custom_minimum_size = Vector2(78, 30)
		ability_grid.add_child(spin)
		ability_spins[str(item.get("key", ""))] = spin


func _refresh_ability_select(mode: String) -> void:
	ability_select.clear()
	var source: Array = _ability_items_for_mode(mode)
	for item_value in source:
		var item: Dictionary = item_value as Dictionary
		var index: int = ability_select.item_count
		ability_select.add_item(str(item.get("label", "")))
		ability_select.set_item_metadata(index, str(item.get("key", "")))
	if mode == "batter":
		_select_metadata(ability_select, "Bat_Impact")
	else:
		_select_metadata(ability_select, "Pit_BBPrevent")


func _ability_items_for_mode(mode: String) -> Array:
	var source: Array = (BATTER_ABILITIES if mode == "batter" else PITCHER_ABILITIES).duplicate(true)
	source.append_array(FIELDING_ABILITIES)
	return source


func _refresh_metric_select(mode: String) -> void:
	metric_select.clear()
	var source: Array = BATTER_METRICS if mode == "batter" else PITCHER_METRICS
	for item_value in source:
		var item: Dictionary = item_value as Dictionary
		var index: int = metric_select.item_count
		metric_select.add_item(str(item.get("label", "")))
		metric_select.set_item_metadata(index, str(item.get("key", "")))


func _apply_default_metric() -> void:
	var ability: String = _selected_metadata(ability_select)
	var mode: String = _selected_mode()
	var metric: String = "home_runs" if mode == "batter" else "era"
	_apply_sweep_range_for_ability(ability)
	match ability:
		"Bat_Impact", "Bat_Loft":
			metric = "home_runs"
		"Bat_Barrel":
			metric = "batting_average"
		"Bat_BBCreate":
			metric = "walk_rate"
		"Bat_KAvoid":
			metric = "strikeout_rate"
		"Bat_Spray":
			metric = "doubles"
		"Bat_Aggression", "Bat_Platoon", "Run_Speed":
			metric = "ops"
		"Pit_KCreate":
			metric = "strikeouts_per_nine"
		"max_velocity":
			metric = "strikeouts_per_nine"
		"Pit_BBPrevent", "Pit_EdgeRate":
			metric = "walks_per_nine"
		"Pit_ImpactLimit", "Pit_LoftControl", "Pit_BarrelDeny":
			metric = "home_runs_per_nine"
		"Pit_Stamina", "Pit_FatigueResist":
			metric = "outs_pitched"
		"Pit_Efficiency":
			metric = "pitches_per_inning"
		"Pit_HoldRunner":
			metric = "whip"
	_select_metadata(metric_select, metric)


func _run_probe() -> void:
	# 入力中の SpinBox / LineEdit の値を確定させる (Godot の SpinBox は
	# フォーカスを失うまで LineEdit のテキストが value に反映されないため、
	# 設定変更直後に「実行」を押すと前回値で走ってしまう)。
	_commit_pending_input()

	status_label.text = "実行中..."
	run_button.disabled = true

	var mode: String = _selected_mode()
	var options: Dictionary = {
		"mode": mode,
		"custom_subject": true,
		"subject_name": "検証用野手" if mode == "batter" else "検証用投手",
		"position": 3 if mode == "batter" else 1,
		"role": "fielder" if mode == "batter" else "starter",
		"seed": _seed_value(),
		"sweep_ability": _selected_metadata(ability_select),
		"sweep_start": float(start_spin.value),
		"sweep_end": float(end_spin.value),
		"sweep_step": float(step_spin.value),
		"iterations": int(iterations_spin.value),
		"metric": _selected_metadata(metric_select),
	}
	if mode == "batter":
		options["plate_appearances"] = int(target_spin.value)
	else:
		options["innings"] = float(target_spin.value)
	options["custom_z_abilities"] = _custom_z_ability_values()
	options["custom_raw_abilities"] = _custom_raw_ability_values()

	# UI フリーズ対策: ProgressOverlay + cancel_token を渡し、PA 単位で yield する。
	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("打席シミュレーション中…" if mode == "batter" else "投球シミュレーション中…")

	options["scene_tree"] = get_tree()
	options["cancel_token"] = cancel_token
	options["chunk_size"] = 50
	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)
	options["progress_callback"] = update_overlay

	var runner: Object = RunnerScript.new()
	current_report = await runner.call("run_async", options) as Dictionary

	overlay.hide_progress()
	overlay.queue_free()

	if bool(current_report.get("cancelled", false)):
		_render_report()
		var partial_rows: Array = current_report.get("rows", []) as Array
		status_label.text = "キャンセルされました (%d条件まで集計)" % partial_rows.size()
		run_button.disabled = false
		return

	_write_text(REPORT_PATH, JSON.stringify(current_report, "\t"))
	_write_text(CSV_PATH, str(runner.call("csv_text", current_report)))
	var graph_text: String = str(runner.call("svg_text", current_report))
	if not graph_text.is_empty():
		_write_text(GRAPH_PATH, graph_text)
	_render_report()

	var rows: Array = current_report.get("rows", []) as Array
	status_label.text = "%d条件を検証しました / JSON・CSV保存済み" % rows.size()
	run_button.disabled = false


func _render_report() -> void:
	result_tree.clear()
	var root: TreeItem = result_tree.create_item()
	var rows: Array = current_report.get("rows", []) as Array
	var mode: String = str(current_report.get("mode", _selected_mode()))
	var metric: String = str((current_report.get("sweep", {}) as Dictionary).get("metric", _selected_metadata(metric_select)))
	var graph_points: Array = []
	var table_rows: Array = _sorted_result_rows(rows, mode)
	for row_value in table_rows:
		var row: Dictionary = row_value as Dictionary
		var summary: Dictionary = row.get("summary", {}) as Dictionary
		var item: TreeItem = result_tree.create_item(root)
		var ability_value: Variant = row.get("ability_value", "")
		item.set_text(0, _format_z(float(ability_value)) if ability_value != null else "")
		item.set_text(1, _format_number(float(row.get("metric_value", 0.0)), 3))
		if mode == "pitcher":
			item.set_text(2, _format_number(float(summary.get("innings_pitched", 0.0)), 1))
			item.set_text(3, _format_number(float(summary.get("era", 0.0)), 2))
			item.set_text(4, _format_number(float(summary.get("home_runs_allowed", 0.0)), 1))
			item.set_text(5, _format_number(float(summary.get("home_runs_per_nine", 0.0)), 2))
			item.set_text(6, _format_number(float(summary.get("walks_per_nine", 0.0)), 2))
			item.set_text(7, _format_number(float(summary.get("strikeouts_per_nine", 0.0)), 2))
			item.set_text(8, _format_number(float(summary.get("whip", 0.0)), 3))
		else:
			item.set_text(2, _format_number(float(summary.get("plate_appearances", 0.0)), 0))
			item.set_text(3, _format_number(float(summary.get("batting_average", 0.0)), 3))
			item.set_text(4, _format_number(float(summary.get("home_runs", 0.0)), 1))
			item.set_text(5, _format_percent(float(summary.get("home_run_rate", 0.0))))
			item.set_text(6, _format_percent(float(summary.get("walk_rate", 0.0))))
			item.set_text(7, _format_percent(float(summary.get("strikeout_rate", 0.0))))
			item.set_text(8, _format_number(float(summary.get("ops", 0.0)), 3))
		var woba_key: String = "woba_allowed" if mode == "pitcher" else "woba"
		var xwoba_key: String = "xwoba_allowed" if mode == "pitcher" else "xwoba"
		var wrc_key: String = "wrc_plus_allowed" if mode == "pitcher" else "wrc_plus"
		var re24_key: String = "re24_allowed" if mode == "pitcher" else "re24"
		item.set_text(9, _format_number(float(summary.get(woba_key, 0.0)), 3))
		item.set_text(10, _format_number(float(summary.get(xwoba_key, 0.0)), 3))
		item.set_text(11, _format_number(float(summary.get(wrc_key, 0.0)), 1))
		item.set_text(12, _format_number(float(summary.get(re24_key, 0.0)), 1))
		item.set_text(13, _format_number(float(summary.get("bsr", 0.0)), 1))
		item.set_text(14, _oaa_zone_label(str(summary.get("primary_oaa_zone", ""))))
		item.set_text(15, _format_number(float(summary.get("oaa", 0.0)), 1))
		item.set_text(16, _format_number(float(summary.get("oaa_infield", 0.0)), 1))
		item.set_text(17, _format_number(float(summary.get("oaa_outfield", 0.0)), 1))
		item.set_text(18, _uzr_position_label(int(summary.get("primary_uzr_position", 0))))
		item.set_text(19, _format_number(float(summary.get("rngr", 0.0)), 1))
		item.set_text(20, _format_number(float(summary.get("errr", 0.0)), 1))
		item.set_text(21, _format_number(float(summary.get("dpr", 0.0)), 1))
		item.set_text(22, _format_number(float(summary.get("uzr", 0.0)), 1))
		item.set_text(23, _format_number(float(summary.get("drs", 0.0)), 1))
		item.set_text(24, _format_number(float(summary.get("def_runs", 0.0)), 1))
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var ability_value: Variant = row.get("ability_value", null)
		if ability_value == null:
			continue
		graph_points.append({
			"x": float(ability_value),
			"y": float(row.get("metric_value", 0.0)),
		})
	chart.call("set_data", graph_points, "%s z" % _selected_metadata(ability_select), metric)
	_render_summary()


func _on_result_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if result_sort_column == column:
		result_sort_ascending = not result_sort_ascending
	else:
		result_sort_column = column
		result_sort_ascending = false
	_render_report()


func _sorted_result_rows(rows: Array, mode: String) -> Array:
	var sorted_rows: Array = rows.duplicate(true)
	if result_sort_column < 0 or result_sort_column >= 25:
		return sorted_rows
	var column: int = result_sort_column
	var ascending: bool = result_sort_ascending
	sorted_rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var left: Dictionary = a as Dictionary
		var right: Dictionary = b as Dictionary
		var comparison: int = _compare_result_rows(left, right, column, mode)
		if comparison == 0:
			comparison = _compare_result_tiebreak(left, right)
		if ascending:
			return comparison < 0
		return comparison > 0
	)
	return sorted_rows


func _compare_result_rows(left: Dictionary, right: Dictionary, column: int, mode: String) -> int:
	if column == 14 or column == 18:
		return _compare_text(
			str(_result_sort_value(left, column, mode)),
			str(_result_sort_value(right, column, mode))
		)
	var left_number: float = float(_result_sort_value(left, column, mode))
	var right_number: float = float(_result_sort_value(right, column, mode))
	if is_equal_approx(left_number, right_number):
		return 0
	return -1 if left_number < right_number else 1


func _compare_result_tiebreak(left: Dictionary, right: Dictionary) -> int:
	var comparison: int = _compare_numbers(float(left.get("ability_value", 0.0)), float(right.get("ability_value", 0.0)))
	if comparison != 0:
		return comparison
	return _compare_numbers(float(left.get("metric_value", 0.0)), float(right.get("metric_value", 0.0)))


func _result_sort_value(row: Dictionary, column: int, mode: String) -> Variant:
	var summary: Dictionary = row.get("summary", {}) as Dictionary
	match column:
		0:
			return row.get("ability_value", 0.0)
		1:
			return row.get("metric_value", 0.0)
		2:
			return summary.get("innings_pitched" if mode == "pitcher" else "plate_appearances", 0.0)
		3:
			return summary.get("era" if mode == "pitcher" else "batting_average", 0.0)
		4:
			return summary.get("home_runs_allowed" if mode == "pitcher" else "home_runs", 0.0)
		5:
			return summary.get("home_runs_per_nine" if mode == "pitcher" else "home_run_rate", 0.0)
		6:
			return summary.get("walks_per_nine" if mode == "pitcher" else "walk_rate", 0.0)
		7:
			return summary.get("strikeouts_per_nine" if mode == "pitcher" else "strikeout_rate", 0.0)
		8:
			return summary.get("whip" if mode == "pitcher" else "ops", 0.0)
		9:
			return summary.get("woba_allowed" if mode == "pitcher" else "woba", 0.0)
		10:
			return summary.get("xwoba_allowed" if mode == "pitcher" else "xwoba", 0.0)
		11:
			return summary.get("wrc_plus_allowed" if mode == "pitcher" else "wrc_plus", 0.0)
		12:
			return summary.get("re24_allowed" if mode == "pitcher" else "re24", 0.0)
		13:
			return summary.get("bsr", 0.0)
		14:
			return summary.get("primary_oaa_zone", "")
		15:
			return summary.get("oaa", 0.0)
		16:
			return summary.get("oaa_infield", 0.0)
		17:
			return summary.get("oaa_outfield", 0.0)
		18:
			return _uzr_position_label(int(summary.get("primary_uzr_position", 0)))
		19:
			return summary.get("rngr", 0.0)
		20:
			return summary.get("errr", 0.0)
		21:
			return summary.get("dpr", 0.0)
		22:
			return summary.get("uzr", 0.0)
		23:
			return summary.get("drs", 0.0)
		24:
			return summary.get("def_runs", 0.0)
	return 0.0


func _compare_numbers(left: float, right: float) -> int:
	if is_equal_approx(left, right):
		return 0
	return -1 if left < right else 1


func _compare_text(left: String, right: String) -> int:
	var left_text: String = left.to_lower()
	var right_text: String = right.to_lower()
	if left_text == right_text:
		return 0
	return -1 if left_text < right_text else 1


func _render_summary() -> void:
	var subject: Dictionary = current_report.get("subject", {}) as Dictionary
	var sweep: Dictionary = current_report.get("sweep", {}) as Dictionary
	var lines: Array = []
	lines.append("対象: %s" % str(subject.get("name", "")))
	lines.append("検証能力 %s  指標 %s  試行 %d" % [
		str(sweep.get("ability", "")),
		str(sweep.get("metric", "")),
		int(sweep.get("iterations", 1)),
	])
	lines.append("固定実能力 %s" % _ability_summary_text())
	lines.append("可視能力 %s" % _visible_summary_text())
	lines.append("出力 %s" % ProjectSettings.globalize_path(REPORT_PATH))
	lines.append("CSV: %s" % ProjectSettings.globalize_path(CSV_PATH))
	lines.append("SVG: %s" % ProjectSettings.globalize_path(GRAPH_PATH))
	summary_label.text = "\n".join(lines)


func _add_label(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(label)


func _small_spin(min_value: float, max_value: float, step_value: float, initial_value: float) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step_value
	spin.value = initial_value
	spin.custom_minimum_size = Vector2(82, 34)
	return spin


func _selected_mode() -> String:
	return str(mode_select.get_item_metadata(mode_select.selected))


func _selected_metadata(select: OptionButton) -> String:
	if select == null or select.item_count <= 0:
		return ""
	return str(select.get_item_metadata(select.selected))


func _select_metadata(select: OptionButton, metadata: String) -> void:
	for index in range(select.item_count):
		if str(select.get_item_metadata(index)) == metadata:
			select.select(index)
			return


func _custom_z_ability_values() -> Dictionary:
	var values: Dictionary = {}
	for key_value in ability_spins.keys():
		var key: String = str(key_value)
		if _is_probe_raw_key(key):
			continue
		var spin: SpinBox = ability_spins.get(key_value) as SpinBox
		if spin != null:
			values[key] = float(spin.value)
	return values


func _custom_raw_ability_values() -> Dictionary:
	var values: Dictionary = {}
	for key_value in ability_spins.keys():
		var key: String = str(key_value)
		if not _is_probe_raw_key(key):
			continue
		var spin: SpinBox = ability_spins.get(key_value) as SpinBox
		if spin != null:
			values[key] = float(spin.value)
	return values


func _ability_summary_text() -> String:
	var parts: Array = []
	for key_value in ability_spins.keys():
		var key: String = str(key_value)
		var spin: SpinBox = ability_spins.get(key_value) as SpinBox
		if spin != null:
			if _is_probe_raw_key(key):
				parts.append("%s=%dkm/h" % [_ability_label_for_key(key), int(round(float(spin.value)))])
			else:
				parts.append("%s=%s" % [_ability_label_for_key(key), _format_z(float(spin.value))])
	return ", ".join(parts)


func _visible_summary_text() -> String:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	var mode: String = _selected_mode()
	record.position = 3 if mode == "batter" else 1
	record.role = "fielder" if mode == "batter" else "starter"
	record.z_abilities_snapshot = _default_visible_summary_z()
	record.raw_abilities_snapshot = _default_visible_summary_raw(mode)
	for key_value in ability_spins.keys():
		var key: String = str(key_value)
		var spin: SpinBox = ability_spins.get(key_value) as SpinBox
		if spin == null:
			continue
		if _is_probe_raw_key(key):
			record.raw_abilities_snapshot[key] = float(spin.value)
		elif _is_probe_z_key(key):
			record.z_abilities_snapshot[key] = float(spin.value)
	return PlayerVisibleRatings.summary_line(record)


func _default_visible_summary_z() -> Dictionary:
	var z50: float = PSAbilityScale.display_to_z(50)
	var z60: float = PSAbilityScale.display_to_z(60)
	var z70: float = PSAbilityScale.display_to_z(70)
	return {
		"Bat_KAvoid": z60,
		"Bat_BBCreate": z60,
		"Bat_Impact": z60,
		"Bat_Loft": z60,
		"Bat_Barrel": z60,
		"Bat_Spray": z50,
		"Bat_Aggression": z50,
		"Bat_Platoon": z50,
		"Run_Speed": z60,
		"Pit_KCreate": z60,
		"Pit_BBPrevent": z60,
		"Pit_ImpactLimit": z60,
		"Pit_LoftControl": z60,
		"Pit_BarrelDeny": z60,
		"Pit_Efficiency": z60,
		"Pit_Stamina": z70,
		"Pit_FatigueResist": z60,
		"Pit_HoldRunner": z60,
		"Pit_EdgeRate": z50,
		"C_Blocking": z60,
		"C_Throw": z60,
		"IF_Reach": z60,
		"IF_ThrowPower": z60,
		"OF_Reach": z60,
		"OF_ArmPower": z60,
	}


func _is_probe_z_key(key: String) -> bool:
	return key.begins_with("Bat_") or key.begins_with("Pit_") or key.begins_with("Run_")


func _is_probe_raw_key(key: String) -> bool:
	return key == "max_velocity"


func _default_visible_summary_raw(mode: String) -> Dictionary:
	if mode == "pitcher":
		return {"max_velocity": 146.0}
	return {}


func _apply_sweep_range_for_ability(ability: String) -> void:
	if _is_probe_raw_key(ability):
		start_spin.min_value = 128.0
		start_spin.max_value = 165.0
		start_spin.step = 1.0
		end_spin.min_value = 128.0
		end_spin.max_value = 165.0
		end_spin.step = 1.0
		step_spin.min_value = 1.0
		step_spin.max_value = 10.0
		step_spin.step = 1.0
		if float(start_spin.value) < 128.0 or float(start_spin.value) > 165.0:
			start_spin.value = 138.0
		if float(end_spin.value) < 128.0 or float(end_spin.value) > 165.0:
			end_spin.value = 156.0
		if float(step_spin.value) < 1.0:
			step_spin.value = 3.0
		return
	start_spin.min_value = -4.0
	start_spin.max_value = 4.0
	start_spin.step = 0.1
	end_spin.min_value = -4.0
	end_spin.max_value = 4.0
	end_spin.step = 0.1
	step_spin.min_value = 0.1
	step_spin.max_value = 2.0
	step_spin.step = 0.1
	if absf(float(start_spin.value)) > 4.0 or absf(float(end_spin.value)) > 4.0:
		start_spin.value = -1.0
		end_spin.value = 3.0
		step_spin.value = 0.5


func _ability_label_for_key(key: String) -> String:
	var source: Array = BATTER_ABILITIES.duplicate(true)
	source.append_array(PITCHER_ABILITIES)
	source.append_array(FIELDING_ABILITIES)
	for item_value in source:
		var item: Dictionary = item_value as Dictionary
		if str(item.get("key", "")) == key:
			return str(item.get("label", key))
	return key


func _seed_value() -> int:
	var text: String = seed_edit.text.strip_edges()
	if text.is_valid_int():
		return int(text)
	return 12345


# 編集中の SpinBox / LineEdit を確定させる。SpinBox.apply() は内部 LineEdit の
# テキストを value に流し込み、release_focus() は LineEdit のフォーカスを外して
# 通常の commit パスを発火させる。両方やっておけばどの入力経路でも取りこぼさない。
func _commit_pending_input() -> void:
	var viewport: Viewport = get_viewport()
	if viewport != null:
		var focus_owner: Control = viewport.gui_get_focus_owner()
		if focus_owner != null:
			focus_owner.release_focus()
	for spin in [target_spin, start_spin, end_spin, step_spin, iterations_spin]:
		if spin != null:
			spin.apply()
	for key in ability_spins.keys():
		var ability_spin: SpinBox = ability_spins.get(key) as SpinBox
		if ability_spin != null:
			ability_spin.apply()


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


func _format_number(value: float, digits: int) -> String:
	if digits <= 0:
		return "%0.0f" % value
	if digits == 1:
		return "%0.1f" % value
	if digits == 2:
		return "%0.2f" % value
	return "%0.3f" % value


func _format_z(value: float) -> String:
	return "%+.2f" % value


func _format_percent(value: float) -> String:
	return "%0.1f%%" % (value * 100.0)


# OAA の集計対象ゾーンを内部表現 "infield" / "outfield" から表示用 "IF" / "OF" に変換。
# OAA はゾーン単位の集計値なので、表示の隣にどちらを集計したかを明示する。
func _oaa_zone_label(zone: String) -> String:
	if zone == "infield":
		return "IF"
	if zone == "outfield":
		return "OF"
	return "-"


# UZR / RngR / ErrR / DPR の集計対象ポジション (1-9) を "P1"-"P9" に変換。
func _uzr_position_label(pos: int) -> String:
	if pos <= 0 or pos > 9:
		return "-"
	return "P%d" % pos
