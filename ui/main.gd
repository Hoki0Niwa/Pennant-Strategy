extends Control

const StartScreen = preload("res://ui/screens/start_screen.gd")
const TeamSelectScreen = preload("res://ui/screens/team_select_screen.gd")
const HomeScreen = preload("res://ui/screens/home_screen.gd")
const BalanceReportScreen = preload("res://ui/screens/balance_report_screen.gd")
const PlayerProbeScreen = preload("res://ui/screens/player_probe_screen.gd")
const DraftSimulatorScreen = preload("res://ui/screens/draft_simulator_screen.gd")
const GameResultScreen = preload("res://ui/screens/game_result_screen.gd")
const LineupEditorScreen = preload("res://ui/screens/lineup_editor_screen.gd")
const RotationEditorScreen = preload("res://ui/screens/rotation_editor_screen.gd")
const PlayerDetailScreen = preload("res://ui/screens/player_detail_screen.gd")
const StandingsScreen = preload("res://ui/screens/standings_screen.gd")
const RankingsScreen = preload("res://ui/screens/rankings_screen.gd")
const ActiveRosterScreen = preload("res://ui/screens/active_roster_screen.gd")
const TeamDetailScreen = preload("res://ui/screens/team_detail_screen.gd")
const OptionsScreen = preload("res://ui/screens/options_screen.gd")
const SkipOptionsScreen = preload("res://ui/screens/skip_options_screen.gd")
const OFFSEASON_SCREEN_PATH: String = "res://ui/screens/offseason_screen.gd"
const PostseasonScreen = preload("res://ui/screens/postseason_screen.gd")
const AwardsScreen = preload("res://ui/screens/awards_screen.gd")
const HistoryScreen = preload("res://ui/screens/history_screen.gd")
const DeveloperTools = preload("res://services/development/developer_tools.gd")

const SIDEBAR_ITEMS: Array = [
	{"name": "home", "label": "ホーム"},
	{"name": "skip_options", "label": "スキップ設定"},
	{"name": "game_results", "label": "試合結果"},
	{"name": "standings", "label": "順位表"},
	{"name": "rankings", "label": "ランキング"},
	{"name": "history", "label": "シーズン履歴"},
	{"name": "team_detail", "label": "チーム詳細"},
	{"name": "active_roster", "label": "1軍入れ替え"},
	{"name": "lineup_editor", "label": "打順設定"},
	{"name": "rotation_editor", "label": "起用法"},
	{"name": "player_detail", "label": "選手詳細"},
	{"name": "balance_report", "label": "バランスレポート"},
	{"name": "player_probe", "label": "選手プローブ"},
	{"name": "draft_simulator", "label": "ドラフト検証"},
	{"name": "team_select", "label": "チーム選択"},
	{"name": "options", "label": "オプション"},
]

const DEVELOPER_SCREEN_NAMES: Dictionary = {
	"balance_report": true,
	"player_probe": true,
	"draft_simulator": true,
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

	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()

	if sidebar != null:
		sidebar.visible = screen_name != "start" and screen_name != "home" and (screen_name != "options" or AppState.current_season != null)
		for screen_key in sidebar_buttons.keys():
			var button: Button = sidebar_buttons[screen_key] as Button
			button.disabled = screen_key == screen_name
	if content != null:
		var home_margin: int = 0 if screen_name == "home" else 16
		var home_margin_top: int = 0 if screen_name == "home" else 14
		content.add_theme_constant_override("margin_left", home_margin)
		content.add_theme_constant_override("margin_top", home_margin_top)
		content.add_theme_constant_override("margin_right", home_margin)
		content.add_theme_constant_override("margin_bottom", home_margin_top)

	var screen: Control
	match screen_name:
		"team_select":
			screen = TeamSelectScreen.new()
		"balance_report":
			screen = BalanceReportScreen.new()
		"player_probe":
			screen = PlayerProbeScreen.new()
		"draft_simulator":
			screen = DraftSimulatorScreen.new()
		"game_results":
			screen = GameResultScreen.new()
		"lineup_editor":
			screen = LineupEditorScreen.new()
		"rotation_editor":
			screen = RotationEditorScreen.new()
		"player_detail":
			screen = PlayerDetailScreen.new()
		"standings":
			screen = StandingsScreen.new()
		"rankings":
			screen = RankingsScreen.new()
		"active_roster":
			screen = ActiveRosterScreen.new()
		"team_detail":
			screen = TeamDetailScreen.new()
		"options":
			screen = OptionsScreen.new()
		"skip_options":
			screen = SkipOptionsScreen.new()
		"offseason":
			screen = (load(OFFSEASON_SCREEN_PATH) as GDScript).new()
		"postseason":
			screen = PostseasonScreen.new()
		"awards":
			screen = AwardsScreen.new()
		"history":
			screen = HistoryScreen.new()
		"home":
			screen = HomeScreen.new()
		_:
			screen = StartScreen.new()

	screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(screen)
