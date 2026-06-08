extends Control

const DeveloperTools = preload("res://services/development/developer_tools.gd")

var status_label: Label
var debug_row: HBoxContainer
var debug_toggle_button: Button


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 18)
	add_child(root)

	var title: Label = Label.new()
	title.text = "PennantStrategy"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	root.add_child(title)

	var subtitle: Label = Label.new()
	subtitle.text = "ペナントレース運営シミュレーション"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 18)
	root.add_child(subtitle)

	var summary: Label = Label.new()
	summary.text = "初期データ: %d球団 / %d選手" % [GameDb.get_team_count(), GameDb.get_player_count()]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(summary)

	# メイン行: 新規 / ロード / オプション / 開発ツール
	var main_row: HBoxContainer = HBoxContainer.new()
	main_row.alignment = BoxContainer.ALIGNMENT_CENTER
	main_row.add_theme_constant_override("separation", 12)
	root.add_child(main_row)

	var new_game_button: Button = Button.new()
	new_game_button.text = "新しく始める"
	new_game_button.custom_minimum_size = Vector2(180, 44)
	new_game_button.pressed.connect(func() -> void: AppState.request_screen("team_select"))
	main_row.add_child(new_game_button)

	var load_button: Button = Button.new()
	load_button.text = "ロード"
	load_button.custom_minimum_size = Vector2(140, 44)
	load_button.pressed.connect(_load_game)
	main_row.add_child(load_button)

	var options_button: Button = Button.new()
	options_button.text = "オプション"
	options_button.custom_minimum_size = Vector2(140, 44)
	options_button.pressed.connect(func() -> void: AppState.request_screen("options"))
	main_row.add_child(options_button)

	if DeveloperTools.enabled():
		_build_debug_tools(root, main_row)

	status_label = Label.new()
	status_label.text = ""
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(status_label)

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)


func _toggle_debug_row() -> void:
	if debug_row == null or debug_toggle_button == null:
		return
	debug_row.visible = not debug_row.visible
	debug_toggle_button.text = "開発ツール ▴" if debug_row.visible else "開発ツール ▾"


func _build_debug_tools(root: VBoxContainer, main_row: HBoxContainer) -> void:
	debug_toggle_button = Button.new()
	debug_toggle_button.text = "開発ツール ▾"
	debug_toggle_button.custom_minimum_size = Vector2(150, 44)
	debug_toggle_button.pressed.connect(_toggle_debug_row)
	main_row.add_child(debug_toggle_button)

	debug_row = HBoxContainer.new()
	debug_row.alignment = BoxContainer.ALIGNMENT_CENTER
	debug_row.add_theme_constant_override("separation", 12)
	debug_row.visible = false
	root.add_child(debug_row)

	var reload_button: Button = Button.new()
	reload_button.text = "データ再読込"
	reload_button.custom_minimum_size = Vector2(140, 44)
	reload_button.pressed.connect(_reload_data)
	debug_row.add_child(reload_button)

	var report_button: Button = Button.new()
	report_button.text = "計測レポート"
	report_button.custom_minimum_size = Vector2(150, 44)
	report_button.pressed.connect(func() -> void: AppState.request_screen("balance_report"))
	debug_row.add_child(report_button)

	var probe_button: Button = Button.new()
	probe_button.text = "選手プローブ"
	probe_button.custom_minimum_size = Vector2(150, 44)
	probe_button.pressed.connect(func() -> void: AppState.request_screen("player_probe"))
	debug_row.add_child(probe_button)

	var draft_simulator_button: Button = Button.new()
	draft_simulator_button.text = "ドラフト検証"
	draft_simulator_button.custom_minimum_size = Vector2(150, 44)
	draft_simulator_button.pressed.connect(func() -> void: AppState.request_screen("draft_simulator"))
	debug_row.add_child(draft_simulator_button)


func _load_game() -> void:
	var save_data: Dictionary = SaveService.load_state()
	if save_data.is_empty():
		status_label.text = "セーブデータがありません"
		return
	AppState.restore_from_save(save_data)


func _reload_data() -> void:
	GameDb.load_initial_data()
	status_label.text = "初期データを再読み込みしました: %d球団 / %d選手" % [GameDb.get_team_count(), GameDb.get_player_count()]
