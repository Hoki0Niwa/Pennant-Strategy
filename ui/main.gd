extends Control

const DeveloperTools = preload("res://services/development/developer_tools.gd")

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
	"active_roster": "res://ui/screens/active_roster_screen.gd",
	"team_detail": "res://ui/screens/team_detail_screen.gd",
	"options": "res://ui/screens/options_screen.gd",
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
	{"name": "history", "label": "シーズン履歴"},
	{"name": "team_detail", "label": "チーム詳細"},
	{"name": "player_detail", "label": "選手詳細"},
	{"name": "lineup_editor", "label": "打順・守備位置"},
	{"name": "rotation_editor", "label": "投手起用法"},
	{"name": "active_roster", "label": "選手登録"},
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
	"balance_report": true,
	"player_probe": true,
	"draft_simulator": true,
	"lineup_editor": true,
	"rotation_editor": true,
	"active_roster": true,
	"rankings": true,
	"standings": true,
	"history": true,
	"team_detail": true,
	"player_detail": true,
	"postseason": true,
}

var sidebar: VBoxContainer
var sidebar_buttons: Dictionary = {}
var content: MarginContainer


func _ready() -> void:
	if not GameDb.data_loaded_ok:
		await GameDb.data_loaded

	AppState.screen_change_requested.connect(_show_screen)
	_build_shell()
	_show_screen(AppState.current_screen)


func _input(event: InputEvent) -> void:
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
	var effective_screen: String = screen_name
	if screen_name == "home" and AppState.postseason_active and AppState.current_postseason != null:
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
