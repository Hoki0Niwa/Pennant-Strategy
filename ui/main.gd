extends Control

const DeveloperTools = preload("res://services/development/developer_tools.gd")
const GameDialogStyle = preload("res://ui/components/game_dialog_style.gd")

const START_SCREEN_PATH: String = "res://ui/screens/start_screen.gd"
const SCREEN_SCRIPT_PATHS: Dictionary = {
	"start": START_SCREEN_PATH,
	"team_select": "res://ui/screens/team_select_screen.gd",
	"home": "res://ui/screens/home_screen.gd",
	"balance_report": "res://ui/screens/balance_report_screen.gd",
	"player_probe": "res://ui/screens/player_probe_screen.gd",
	"draft_simulator": "res://ui/screens/draft_simulator_screen.gd",
	"game_results": "res://ui/screens/game_result_screen.gd",
	"lineup_editor": "res://ui/screens/lineup_editor_screen.gd",
	"rotation_editor": "res://ui/screens/rotation_editor_screen.gd",
	"player_detail": "res://ui/screens/player_detail_screen.gd",
	"standings": "res://ui/screens/standings_screen.gd",
	"rankings": "res://ui/screens/rankings_screen.gd",
	"ability_stats": "res://ui/screens/ability_stats_screen.gd",
	"active_roster": "res://ui/screens/active_roster_screen.gd",
	"trade": "res://ui/screens/trade_screen.gd",
	"team_detail": "res://ui/screens/team_detail_screen.gd",
	"options": "res://ui/screens/options_screen.gd",
	"save_select": "res://ui/screens/save_select_screen.gd",
	"offseason": "res://ui/screens/offseason_screen.gd",
	"postseason": "res://ui/screens/postseason_screen.gd",
	"awards": "res://ui/screens/awards_screen.gd",
	"history": "res://ui/screens/history_screen.gd",
}

const SIDEBAR_ITEMS: Array = [
	{"name": "home", "label": "ホーム"},
	{"name": "game_results", "label": "試合結果"},
	{"name": "standings", "label": "順位表"},
	{"name": "rankings", "label": "タイトル争い"},
	{"name": "ability_stats", "label": "能力・成績一覧"},
	{"name": "history", "label": "シーズン履歴"},
	{"name": "team_detail", "label": "チーム詳細"},
	{"name": "player_detail", "label": "選手詳細"},
	{"name": "lineup_editor", "label": "打順・守備位置"},
	{"name": "rotation_editor", "label": "投手起用法"},
	{"name": "active_roster", "label": "選手登録"},
	{"name": "trade", "label": "トレード"},
	{"name": "balance_report", "label": "バランスレポート"},
	{"name": "player_probe", "label": "選手プローブ"},
	{"name": "draft_simulator", "label": "ドラフト検証"},
	{"name": "options", "label": "オプション"},
]

const DEVELOPER_SCREEN_NAMES: Dictionary = {
	"balance_report": true,
	"player_probe": true,
	"draft_simulator": true,
}

# 自前のサイドバー+ヘッダを内包しシェルのサイドバー/余白を使わない全画面ダッシュボード。
const FULL_BLEED_SCREENS: Dictionary = {
	"start": true,
	"team_select": true,
	"home": true,
	"game_results": true,
	"options": true,
	"save_select": true,
	"balance_report": true,
	"player_probe": true,
	"draft_simulator": true,
	"lineup_editor": true,
	"rotation_editor": true,
	"active_roster": true,
	"trade": true,
	"rankings": true,
	"standings": true,
	"ability_stats": true,
	"history": true,
	"team_detail": true,
	"player_detail": true,
	"postseason": true,
	"awards": true,
	"offseason": true,
}

var sidebar: VBoxContainer
var sidebar_buttons: Dictionary = {}
var content: MarginContainer
var _quit_dialog: Control
var _quit_message: Label
var _quit_save_button: Button
var _quit_discard_button: Button
var _quit_save_failed: bool = false
var _quit_in_progress: bool = false


func _ready() -> void:
	# OS の終了要求を自動受理せず、進行中データの保存確認を必ず経由させる。
	get_tree().set_auto_accept_quit(false)
	if not GameDb.data_loaded_ok:
		await GameDb.data_loaded

	AppState.screen_change_requested.connect(_show_screen)
	_build_shell()
	_show_screen(AppState.current_screen)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_request_quit()


func _request_quit() -> void:
	if _quit_in_progress:
		return
	match _quit_request_mode():
		"quit":
			_perform_quit()
		"autosave":
			_on_save_and_quit()
		"confirm":
			if _quit_dialog != null and is_instance_valid(_quit_dialog) and _quit_dialog.visible:
				return
			_quit_save_failed = false
			_show_quit_dialog()


func _quit_request_mode() -> String:
	if AppState.current_season == null or SaveService.is_state_current(AppState):
		return "quit"
	if AppState.auto_save_enabled:
		return "autosave"
	return "confirm"


func _show_quit_dialog() -> void:
	_ensure_quit_dialog()
	if _quit_save_failed:
		_quit_message.text = "セーブに失敗しました。\nもう一度保存するか、保存せずに終了してください。"
	else:
		_quit_message.text = "現在の進行状況を保存して終了しますか？"
	_quit_dialog.visible = true
	if _quit_save_button.is_inside_tree():
		_quit_save_button.grab_focus()


func _ensure_quit_dialog() -> Control:
	if _quit_dialog != null and is_instance_valid(_quit_dialog):
		return _quit_dialog

	_quit_dialog = Control.new()
	_quit_dialog.name = "QuitDialogOverlay"
	_quit_dialog.set_anchors_preset(Control.PRESET_FULL_RECT)
	_quit_dialog.mouse_filter = Control.MOUSE_FILTER_STOP
	_quit_dialog.z_index = 1000
	add_child(_quit_dialog)

	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_quit_dialog.add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quit_dialog.add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 220)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	GameDialogStyle.style_modal_panel(panel)
	center.add_child(panel)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	panel.add_child(column)

	var title: Label = Label.new()
	title.text = "セーブして終了"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	GameDialogStyle.style_modal_title(title)
	column.add_child(title)

	_quit_message = Label.new()
	_quit_message.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_quit_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quit_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_quit_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	GameDialogStyle.style_modal_body(_quit_message)
	column.add_child(_quit_message)

	var actions: HBoxContainer = HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 18)
	column.add_child(actions)

	_quit_save_button = Button.new()
	_quit_save_button.text = "保存して終了"
	_quit_save_button.custom_minimum_size = Vector2(126, 40)
	_quit_save_button.pressed.connect(_on_save_and_quit)
	GameDialogStyle.style_button(_quit_save_button, "primary")
	actions.add_child(_quit_save_button)

	var cancel_button: Button = Button.new()
	cancel_button.text = "キャンセル"
	cancel_button.custom_minimum_size = Vector2(112, 40)
	cancel_button.pressed.connect(_hide_quit_dialog)
	GameDialogStyle.style_button(cancel_button, "action")
	actions.add_child(cancel_button)

	_quit_discard_button = Button.new()
	_quit_discard_button.text = "保存せず終了"
	_quit_discard_button.custom_minimum_size = Vector2(126, 40)
	_quit_discard_button.pressed.connect(_on_quit_without_save)
	GameDialogStyle.style_button(_quit_discard_button, "danger")
	actions.add_child(_quit_discard_button)

	_quit_dialog.visible = false
	return _quit_dialog


func _on_save_and_quit() -> void:
	if SaveService.save_state(AppState):
		_perform_quit()
		return
	_quit_save_failed = true
	_show_quit_dialog()


func _on_quit_without_save() -> void:
	_quit_dialog.visible = false
	_perform_quit()


func _hide_quit_dialog() -> void:
	if _quit_dialog != null:
		_quit_dialog.visible = false
	_quit_save_failed = false


func _perform_quit() -> void:
	_quit_in_progress = true
	get_tree().set_auto_accept_quit(true)
	get_tree().quit()


func _input(event: InputEvent) -> void:
	if (
		_quit_dialog != null
		and _quit_dialog.visible
		and event is InputEventKey
		and event.pressed
		and not event.echo
		and event.keycode == KEY_ESCAPE
	):
		_hide_quit_dialog()
		get_viewport().set_input_as_handled()
		return
	# 画面遷移の「戻る/進む」。マウスのサイドボタンと Alt+←/Alt+→ に対応。
	# 画面は mouse_filter=STOP の Control で覆われており _unhandled_input には届かないため、
	# GUI より先に届く _input で処理する (これらの入力は他用途に使っていないので横取りして安全)。
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_XBUTTON1:  # マウスの「戻る」ボタン
				if AppState.go_back():
					get_viewport().set_input_as_handled()
			MOUSE_BUTTON_XBUTTON2:  # マウスの「進む」ボタン
				if AppState.go_forward():
					get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.alt_pressed:
		match event.keycode:
			KEY_LEFT:  # Alt+← で戻る
				if AppState.go_back():
					get_viewport().set_input_as_handled()
			KEY_RIGHT:  # Alt+→ で進む
				if AppState.go_forward():
					get_viewport().set_input_as_handled()


func _build_shell() -> void:
	var root: HBoxContainer = HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	sidebar = VBoxContainer.new()
	sidebar.custom_minimum_size = Vector2(160, 0)
	sidebar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar.add_theme_constant_override("separation", 4)
	root.add_child(sidebar)

	var menu_title: Label = Label.new()
	menu_title.text = "メニュー"
	menu_title.add_theme_font_size_override("font_size", 16)
	menu_title.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	sidebar.add_child(menu_title)

	for item_row in SIDEBAR_ITEMS:
		var item: Dictionary = item_row as Dictionary
		var screen_name: String = str(item.get("name", ""))
		if DEVELOPER_SCREEN_NAMES.has(screen_name) and not DeveloperTools.enabled():
			continue
		var button: Button = Button.new()
		button.text = str(item.get("label", ""))
		button.custom_minimum_size = Vector2(150, 32)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: AppState.request_screen(screen_name))
		sidebar.add_child(button)
		sidebar_buttons[screen_name] = button

	content = MarginContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("margin_left", 16)
	content.add_theme_constant_override("margin_top", 14)
	content.add_theme_constant_override("margin_right", 16)
	content.add_theme_constant_override("margin_bottom", 14)
	root.add_child(content)


func _show_screen(screen_name: String) -> void:
	if content == null:
		return
	if DEVELOPER_SCREEN_NAMES.has(screen_name) and not DeveloperTools.enabled():
		screen_name = "home" if AppState.current_season != null else "start"

	# ポストシーズン中はホーム画面をポストシーズン用ダッシュボードへ差し替える。
	# current_screen("home") はそのまま = サイドバーの「ホーム」がハイライトされる。
	# オフシーズン/ポストシーズン中はホーム画面をそれぞれのダッシュボードへ差し替える。
	# current_screen("home") はそのまま = サイドバーの「ホーム」がハイライトされる。
	var effective_screen: String = screen_name
	if screen_name == "home" and AppState.offseason_active:
		effective_screen = "offseason"
	elif screen_name == "home" and AppState.postseason_active and AppState.current_postseason != null:
		effective_screen = "postseason"

	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()

	var full_bleed: bool = FULL_BLEED_SCREENS.has(effective_screen)
	if sidebar != null:
		sidebar.visible = screen_name != "start" and not full_bleed and (screen_name != "options" or AppState.current_season != null)
		for screen_key in sidebar_buttons.keys():
			var button: Button = sidebar_buttons[screen_key] as Button
			button.disabled = screen_key == screen_name
	if content != null:
		var margin_x: int = 0 if full_bleed else 16
		var margin_y: int = 0 if full_bleed else 14
		content.add_theme_constant_override("margin_left", margin_x)
		content.add_theme_constant_override("margin_top", margin_y)
		content.add_theme_constant_override("margin_right", margin_x)
		content.add_theme_constant_override("margin_bottom", margin_y)

	var screen_path: String = str(SCREEN_SCRIPT_PATHS.get(effective_screen, START_SCREEN_PATH))
	var screen: Control = _instantiate_screen(screen_path)

	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(screen)


func _instantiate_screen(path: String) -> Control:
	var script: GDScript = load(path) as GDScript
	if script == null:
		push_error("Could not load screen script: %s" % path)
		var fallback: Label = Label.new()
		fallback.text = "画面を読み込めませんでした: %s" % path
		return fallback
	var screen: Control = script.new() as Control
	if screen == null:
		push_error("Screen script is not a Control: %s" % path)
		var fallback: Label = Label.new()
		fallback.text = "画面の型が不正です: %s" % path
		return fallback
	return screen
