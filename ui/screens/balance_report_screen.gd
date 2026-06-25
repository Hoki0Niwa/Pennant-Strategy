extends Control

const ReporterScript = preload("res://services/reports/simulation_reporter.gd")
const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const DevChrome = preload("res://ui/components/dev_chrome.gd")
const REPORT_PATH: String = "res://reports/balance_report_latest.json"
const BATTER_COLUMNS: Array = [
	{"title": "年", "key": "year", "width": 64, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 70, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 150, "type": "string", "format": "string"},
	{"title": "守備", "key": "position", "width": 70, "type": "string", "format": "string"},
	{"title": "試", "key": "games", "width": 56, "type": "number", "format": "int"},
	{"title": "打席", "key": "plate_appearances", "width": 64, "type": "number", "format": "int"},
	{"title": "打数", "key": "at_bats", "width": 64, "type": "number", "format": "int"},
	{"title": "安打", "key": "hits", "width": 64, "type": "number", "format": "int"},
	{"title": "2B", "key": "doubles", "width": 56, "type": "number", "format": "int"},
	{"title": "3B", "key": "triples", "width": 56, "type": "number", "format": "int"},
	{"title": "本", "key": "home_runs", "width": 56, "type": "number", "format": "int"},
	{"title": "打点", "key": "runs_batted_in", "width": 64, "type": "number", "format": "int"},
	{"title": "得点", "key": "runs", "width": 64, "type": "number", "format": "int"},
	{"title": "四球", "key": "walks", "width": 64, "type": "number", "format": "int"},
	{"title": "三振", "key": "strikeouts", "width": 64, "type": "number", "format": "int"},
	{"title": "犠打", "key": "sacrifices", "width": 64, "type": "number", "format": "int"},
	{"title": "犠飛", "key": "sacrifice_flies", "width": 64, "type": "number", "format": "int"},
	{"title": "併殺", "key": "double_plays", "width": 64, "type": "number", "format": "int"},
	{"title": "失策", "key": "errors", "width": 64, "type": "number", "format": "int"},
	{"title": "打率", "key": "batting_average", "width": 70, "type": "number", "format": "rate"},
	{"title": "出塁率", "key": "on_base_percentage", "width": 70, "type": "number", "format": "rate"},
	{"title": "長打率", "key": "slugging_percentage", "width": 70, "type": "number", "format": "rate"},
	{"title": "OPS", "key": "ops", "width": 70, "type": "number", "format": "rate"},
]
const PITCHER_COLUMNS: Array = [
	{"title": "年", "key": "year", "width": 64, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 70, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 150, "type": "string", "format": "string"},
	{"title": "登板", "key": "games", "width": 64, "type": "number", "format": "int"},
	{"title": "先発", "key": "starts", "width": 64, "type": "number", "format": "int"},
	{"title": "救援", "key": "relief_appearances", "width": 64, "type": "number", "format": "int"},
	{"title": "勝", "key": "wins", "width": 56, "type": "number", "format": "int"},
	{"title": "敗", "key": "losses", "width": 56, "type": "number", "format": "int"},
	{"title": "H", "key": "holds", "width": 56, "type": "number", "format": "int"},
	{"title": "S", "key": "saves", "width": 56, "type": "number", "format": "int"},
	{"title": "投球回", "key": "innings_pitched", "width": 70, "type": "number", "format": "float1"},
	{"title": "打者", "key": "batters_faced", "width": 64, "type": "number", "format": "int"},
	{"title": "被安打", "key": "hits_allowed", "width": 64, "type": "number", "format": "int"},
	{"title": "被本", "key": "home_runs_allowed", "width": 64, "type": "number", "format": "int"},
	{"title": "四球", "key": "walks", "width": 64, "type": "number", "format": "int"},
	{"title": "奪三振", "key": "strikeouts", "width": 64, "type": "number", "format": "int"},
	{"title": "失点", "key": "runs_allowed", "width": 64, "type": "number", "format": "int"},
	{"title": "自責", "key": "earned_runs", "width": 64, "type": "number", "format": "int"},
	{"title": "完投", "key": "complete_games", "width": 64, "type": "number", "format": "int"},
	{"title": "完封", "key": "shutouts", "width": 64, "type": "number", "format": "int"},
	{"title": "QS", "key": "quality_starts", "width": 56, "type": "number", "format": "int"},
	{"title": "防御", "key": "era", "width": 70, "type": "number", "format": "float2"},
	{"title": "WHIP", "key": "whip", "width": 70, "type": "number", "format": "float3"},
	{"title": "K/9", "key": "strikeouts_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "BB/9", "key": "walks_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "HR/9", "key": "home_runs_per_nine", "width": 70, "type": "number", "format": "float2"},
]
const BATTER_METRIC_COLUMNS: Array = [
	{"title": "年", "key": "year", "width": 64, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 70, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 150, "type": "string", "format": "string"},
	{"title": "守備", "key": "position", "width": 70, "type": "string", "format": "string"},
	{"title": "PA", "key": "plate_appearances", "width": 64, "type": "number", "format": "int"},
	{"title": "打率", "key": "batting_average", "width": 70, "type": "number", "format": "rate"},
	{"title": "OBP", "key": "on_base_percentage", "width": 70, "type": "number", "format": "rate"},
	{"title": "SLG", "key": "slugging_percentage", "width": 70, "type": "number", "format": "rate"},
	{"title": "OPS", "key": "ops", "width": 70, "type": "number", "format": "rate"},
	{"title": "ISO", "key": "isolated_power", "width": 70, "type": "number", "format": "rate"},
	{"title": "接触", "key": "contact_result", "width": 76, "type": "number", "format": "rate"},
	{"title": "K%", "key": "strikeout_rate", "width": 70, "type": "number", "format": "percent1"},
	{"title": "BB%", "key": "walk_rate", "width": 70, "type": "number", "format": "percent1"},
	{"title": "BB/K", "key": "walks_per_strikeout", "width": 70, "type": "number", "format": "float2"},
	{"title": "PA/K", "key": "plate_appearances_per_strikeout", "width": 70, "type": "number", "format": "float2"},
	{"title": "HR%", "key": "home_run_rate", "width": 70, "type": "number", "format": "percent1"},
	{"title": "接触%", "key": "contact_rate", "width": 76, "type": "number", "format": "percent1"},
	{"title": "Bat_KAvoid z", "key": "pa_bat_k_avoid", "width": 98, "type": "number", "format": "z"},
	{"title": "Bat_BB z", "key": "pa_bat_bb_create", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Impact z", "key": "pa_bat_impact", "width": 100, "type": "number", "format": "z"},
	{"title": "Bat_Loft z", "key": "pa_bat_loft", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Barrel z", "key": "pa_bat_barrel", "width": 100, "type": "number", "format": "z"},
	{"title": "Bat_Spray z", "key": "pa_bat_spray", "width": 94, "type": "number", "format": "z"},
	{"title": "Bat_Agg z", "key": "pa_bat_aggression", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Platoon z", "key": "pa_bat_platoon", "width": 104, "type": "number", "format": "z"},
	{"title": "Run_Speed z", "key": "pa_run_speed", "width": 96, "type": "number", "format": "z"},
	{"title": "表示巧打", "key": "display_contact", "width": 76, "type": "number", "format": "int"},
	{"title": "表示長打", "key": "display_power", "width": 76, "type": "number", "format": "int"},
	{"title": "表示走力", "key": "display_speed", "width": 76, "type": "number", "format": "int"},
	{"title": "表示守備", "key": "display_defense", "width": 76, "type": "number", "format": "int"},
	{"title": "表示肩力", "key": "display_arm", "width": 76, "type": "number", "format": "int"},
	{"title": "表示選球", "key": "display_discipline", "width": 76, "type": "number", "format": "int"},
]
const PITCHER_METRIC_COLUMNS: Array = [
	{"title": "年", "key": "year", "width": 64, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 70, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 150, "type": "string", "format": "string"},
	{"title": "登板", "key": "games", "width": 64, "type": "number", "format": "int"},
	{"title": "先発", "key": "starts", "width": 64, "type": "number", "format": "int"},
	{"title": "投球回", "key": "innings_pitched", "width": 70, "type": "number", "format": "float1"},
	{"title": "ERA", "key": "era", "width": 70, "type": "number", "format": "float2"},
	{"title": "WHIP", "key": "whip", "width": 70, "type": "number", "format": "float3"},
	{"title": "K/9", "key": "strikeouts_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "BB/9", "key": "walks_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "HR/9", "key": "home_runs_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "H/9", "key": "hits_per_nine", "width": 70, "type": "number", "format": "float2"},
	{"title": "K%", "key": "strikeout_rate", "width": 70, "type": "number", "format": "percent1"},
	{"title": "BB%", "key": "walk_rate", "width": 70, "type": "number", "format": "percent1"},
	{"title": "K-BB%", "key": "strikeout_minus_walk_rate", "width": 82, "type": "number", "format": "percent1"},
	{"title": "K/BB", "key": "strikeouts_per_walk", "width": 70, "type": "number", "format": "float2"},
	{"title": "Pit_K z", "key": "pa_pit_k_create", "width": 84, "type": "number", "format": "z"},
	{"title": "Pit_BBPrev z", "key": "pa_pit_bb_prevent", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_ImpactLim z", "key": "pa_pit_impact_limit", "width": 116, "type": "number", "format": "z"},
	{"title": "Pit_LoftCtl z", "key": "pa_pit_loft_control", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_BarrelDeny z", "key": "pa_pit_barrel_deny", "width": 120, "type": "number", "format": "z"},
	{"title": "Pit_Eff z", "key": "pa_pit_efficiency", "width": 84, "type": "number", "format": "z"},
	{"title": "Pit_Stam z", "key": "pa_pit_stamina", "width": 90, "type": "number", "format": "z"},
	{"title": "Pit_Fatigue z", "key": "pa_pit_fatigue_resist", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_Hold z", "key": "pa_pit_hold_runner", "width": 90, "type": "number", "format": "z"},
	{"title": "Pit_Edge z", "key": "pa_pit_edge_rate", "width": 90, "type": "number", "format": "z"},
	{"title": "表示球速", "key": "display_velocity", "width": 82, "type": "number", "format": "int"},
	{"title": "表示球質", "key": "display_stuff", "width": 82, "type": "number", "format": "int"},
	{"title": "表示制球", "key": "display_control", "width": 82, "type": "number", "format": "int"},
	{"title": "表示持久", "key": "display_stamina", "width": 82, "type": "number", "format": "int"},
]
const BATTING_ADVANCED_COLUMNS: Array = [
	{"title": "Adv PA", "key": "advanced_plate_appearances", "width": 76, "type": "number", "format": "int"},
	{"title": "WAR", "key": "war", "width": 70, "type": "number", "format": "float2"},
	{"title": "wRAA", "key": "war_wraa", "width": 72, "type": "number", "format": "float1"},
	{"title": "wOBA", "key": "woba", "width": 74, "type": "number", "format": "float3"},
	{"title": "xwOBA", "key": "xwoba", "width": 78, "type": "number", "format": "float3"},
	{"title": "wRC+", "key": "wrc_plus", "width": 74, "type": "number", "format": "float1"},
	{"title": "RE24", "key": "re24", "width": 74, "type": "number", "format": "float1"},
	{"title": "BsR", "key": "bsr", "width": 70, "type": "number", "format": "float1"},
]
const PITCHING_ADVANCED_COLUMNS: Array = [
	{"title": "Adv BF", "key": "advanced_batters_faced", "width": 76, "type": "number", "format": "int"},
	{"title": "WAR", "key": "war", "width": 70, "type": "number", "format": "float2"},
	{"title": "FIP", "key": "fip", "width": 70, "type": "number", "format": "float2"},
	{"title": "wOBAA", "key": "woba_allowed", "width": 78, "type": "number", "format": "float3"},
	{"title": "xwOBAA", "key": "xwoba_allowed", "width": 82, "type": "number", "format": "float3"},
	{"title": "wRC+ A", "key": "wrc_plus_allowed", "width": 82, "type": "number", "format": "float1"},
	{"title": "RE24 A", "key": "re24_allowed", "width": 82, "type": "number", "format": "float1"},
]
const FIELDING_ADVANCED_COLUMNS: Array = [
	{"title": "Fld Ch", "key": "fielding_chances", "width": 74, "type": "number", "format": "int"},
	# OAA Zone: 集計対象ゾーン (IF / OF)。"OAA" 列の値はこのゾーンの OAA を表す。
	{"title": "OAA Zone", "key": "primary_oaa_zone", "width": 78, "type": "string", "format": "zone"},
	{"title": "OAA", "key": "oaa", "width": 70, "type": "number", "format": "float1"},
	{"title": "OAA IF", "key": "oaa_infield", "width": 74, "type": "number", "format": "float1"},
	{"title": "OAA OF", "key": "oaa_outfield", "width": 74, "type": "number", "format": "float1"},
	# UZR Pos: 集計対象ポジション (P1-P9)。RngR / ErrR / DPR / UZR / DRS はこのポジションの値。
	{"title": "UZR Pos", "key": "primary_uzr_position", "width": 78, "type": "string", "format": "position"},
	{"title": "RngR", "key": "rngr", "width": 70, "type": "number", "format": "float1"},
	{"title": "ErrR", "key": "errr", "width": 70, "type": "number", "format": "float1"},
	{"title": "DPR", "key": "dpr", "width": 70, "type": "number", "format": "float1"},
	{"title": "UZR", "key": "uzr", "width": 70, "type": "number", "format": "float1"},
	{"title": "DRS", "key": "drs", "width": 70, "type": "number", "format": "float1"},
	{"title": "OAA Runs", "key": "oaa_runs", "width": 84, "type": "number", "format": "float1"},
	{"title": "PosAdj", "key": "positional_adjustment_runs", "width": 76, "type": "number", "format": "float1"},
	{"title": "Def", "key": "def_runs", "width": 70, "type": "number", "format": "float1"},
]
const BATTING_ABILITY_COLUMNS: Array = [
	{"title": "Bat_KAvoid z", "key": "pa_bat_k_avoid", "width": 98, "type": "number", "format": "z"},
	{"title": "Bat_BB z", "key": "pa_bat_bb_create", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Impact z", "key": "pa_bat_impact", "width": 100, "type": "number", "format": "z"},
	{"title": "Bat_Loft z", "key": "pa_bat_loft", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Barrel z", "key": "pa_bat_barrel", "width": 100, "type": "number", "format": "z"},
	{"title": "Bat_Spray z", "key": "pa_bat_spray", "width": 94, "type": "number", "format": "z"},
	{"title": "Bat_Agg z", "key": "pa_bat_aggression", "width": 88, "type": "number", "format": "z"},
	{"title": "Bat_Platoon z", "key": "pa_bat_platoon", "width": 104, "type": "number", "format": "z"},
	{"title": "Run_Speed z", "key": "pa_run_speed", "width": 96, "type": "number", "format": "z"},
	{"title": "表示巧打", "key": "display_contact", "width": 76, "type": "number", "format": "int"},
	{"title": "表示長打", "key": "display_power", "width": 76, "type": "number", "format": "int"},
	{"title": "表示走力", "key": "display_speed", "width": 76, "type": "number", "format": "int"},
	{"title": "表示守備", "key": "display_defense", "width": 76, "type": "number", "format": "int"},
	{"title": "表示肩力", "key": "display_arm", "width": 76, "type": "number", "format": "int"},
	{"title": "表示選球", "key": "display_discipline", "width": 76, "type": "number", "format": "int"},
]
const PITCHING_ABILITY_COLUMNS: Array = [
	{"title": "Pit_K z", "key": "pa_pit_k_create", "width": 84, "type": "number", "format": "z"},
	{"title": "Pit_BBPrev z", "key": "pa_pit_bb_prevent", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_ImpactLim z", "key": "pa_pit_impact_limit", "width": 116, "type": "number", "format": "z"},
	{"title": "Pit_LoftCtl z", "key": "pa_pit_loft_control", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_BarrelDeny z", "key": "pa_pit_barrel_deny", "width": 120, "type": "number", "format": "z"},
	{"title": "Pit_Eff z", "key": "pa_pit_efficiency", "width": 84, "type": "number", "format": "z"},
	{"title": "Pit_Stam z", "key": "pa_pit_stamina", "width": 90, "type": "number", "format": "z"},
	{"title": "Pit_Fatigue z", "key": "pa_pit_fatigue_resist", "width": 104, "type": "number", "format": "z"},
	{"title": "Pit_Hold z", "key": "pa_pit_hold_runner", "width": 90, "type": "number", "format": "z"},
	{"title": "Pit_Edge z", "key": "pa_pit_edge_rate", "width": 90, "type": "number", "format": "z"},
	{"title": "表示球速", "key": "display_velocity", "width": 82, "type": "number", "format": "int"},
	{"title": "表示球質", "key": "display_stuff", "width": 82, "type": "number", "format": "int"},
	{"title": "表示制球", "key": "display_control", "width": 82, "type": "number", "format": "int"},
	{"title": "表示持久", "key": "display_stamina", "width": 82, "type": "number", "format": "int"},
]
const FIELDING_ABILITY_COLUMNS: Array = []

var seasons_spin: SpinBox
var seed_edit: LineEdit
var selected_team_spin: SpinBox
var run_button: Button
var status_label: Label
var overview_tree: Tree
var season_tree: Tree
var team_tree: Tree
var batter_tree: Tree
var pitcher_tree: Tree
var batter_metric_tree: Tree
var pitcher_metric_tree: Tree
var current_report: Dictionary = {}
var batter_sort_column: int = 2
var batter_sort_ascending: bool = true
var pitcher_sort_column: int = 2
var pitcher_sort_ascending: bool = true
var batter_metric_sort_column: int = 8
var batter_metric_sort_ascending: bool = false
var pitcher_metric_sort_column: int = 6
var pitcher_metric_sort_ascending: bool = true


func _ready() -> void:
	_build()
	_load_existing_report()


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
	title.text = "シミュレーション計測"
	title.add_theme_font_size_override("font_size", 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevChrome.style_title(title)
	header.add_child(title)

	var probe_button: Button = Button.new()
	probe_button.text = "選手プローブ"
	probe_button.custom_minimum_size = Vector2(118, 34)
	probe_button.pressed.connect(func() -> void: AppState.request_screen("player_probe", false))
	DevChrome.style_button(probe_button)
	header.add_child(probe_button)

	var back_button: Button = Button.new()
	back_button.text = "タイトルへ戻る"
	back_button.custom_minimum_size = Vector2(128, 34)
	back_button.pressed.connect(_go_back)
	DevChrome.style_primary(back_button)
	header.add_child(back_button)

	var controls: HBoxContainer = HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	root.add_child(controls)

	_add_control_label(controls, "シーズン")
	seasons_spin = SpinBox.new()
	seasons_spin.min_value = 1
	seasons_spin.max_value = 20
	seasons_spin.step = 1
	seasons_spin.value = 3
	seasons_spin.custom_minimum_size = Vector2(86, 34)
	controls.add_child(seasons_spin)

	_add_control_label(controls, "シード")
	seed_edit = LineEdit.new()
	seed_edit.text = "12345"
	seed_edit.custom_minimum_size = Vector2(110, 34)
	controls.add_child(seed_edit)

	_add_control_label(controls, "自チーム")
	selected_team_spin = SpinBox.new()
	selected_team_spin.min_value = 1
	selected_team_spin.max_value = max(1, GameDb.get_team_count())
	selected_team_spin.step = 1
	selected_team_spin.value = max(1, AppState.selected_team_id)
	selected_team_spin.custom_minimum_size = Vector2(86, 34)
	controls.add_child(selected_team_spin)

	run_button = Button.new()
	run_button.text = "計測実行"
	run_button.custom_minimum_size = Vector2(112, 34)
	run_button.pressed.connect(_run_report)
	controls.add_child(run_button)

	status_label = Label.new()
	status_label.text = ""
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(status_label)

	var tabs: TabContainer = TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)

	overview_tree = _create_table(["項目", "値"], [260, 220])
	_add_tab(tabs, overview_tree, "概況")

	season_tree = _create_table(["年", "試合", "得点/チーム", "打率", "OPS", "本/試合", "ERA", "WHIP", "K/9", "BB/9", "wOBA", "xwOBA", "wRC+", "RE24", "BsR", "OAA Zone", "OAA", "OAA IF", "OAA OF", "UZR Pos", "RngR", "ErrR", "DPR", "UZR", "DRS", "PosAdj", "Def"], [70, 70, 110, 70, 70, 80, 70, 70, 70, 70, 74, 78, 74, 74, 70, 78, 70, 74, 74, 78, 70, 70, 70, 70, 70, 76, 70])
	_add_tab(tabs, season_tree, "年度")

	team_tree = _create_table(["年", "チーム", "勝", "敗", "分", "勝率", "得点/試合", "失点/試合", "打率", "本", "ERA", "WHIP"], [70, 80, 56, 56, 56, 70, 90, 90, 70, 64, 70, 70])
	_add_tab(tabs, team_tree, "チーム")

	batter_tree = _create_stat_table(_batter_columns())
	batter_tree.column_title_clicked.connect(_on_batter_column_title_clicked)
	_add_tab(tabs, batter_tree, "野手")

	batter_metric_tree = _create_stat_table(_batter_metric_columns())
	batter_metric_tree.column_title_clicked.connect(_on_batter_metric_column_title_clicked)
	_add_tab(tabs, batter_metric_tree, "野手指標")

	pitcher_tree = _create_stat_table(_pitcher_columns())
	pitcher_tree.column_title_clicked.connect(_on_pitcher_column_title_clicked)
	_add_tab(tabs, pitcher_tree, "投手")

	pitcher_metric_tree = _create_stat_table(_pitcher_metric_columns())
	pitcher_metric_tree.column_title_clicked.connect(_on_pitcher_metric_column_title_clicked)
	_add_tab(tabs, pitcher_metric_tree, "投手指標")


func _add_control_label(parent: Control, text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(label)


func _add_tab(tabs: TabContainer, table: Tree, title: String) -> void:
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


func _create_table(headers: Array, widths: Array) -> Tree:
	var tree: Tree = Tree.new()
	tree.hide_root = true
	tree.column_titles_visible = true
	tree.columns = headers.size()
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for index in range(headers.size()):
		tree.set_column_title(index, str(headers[index]))
		tree.set_column_title_alignment(index, HORIZONTAL_ALIGNMENT_LEFT)
		tree.set_column_expand(index, true)
		tree.set_column_custom_minimum_width(index, int(widths[index]))
	return tree


func _create_stat_table(columns: Array) -> Tree:
	var headers: Array = []
	var widths: Array = []
	for column_value in columns:
		var column: Dictionary = column_value as Dictionary
		headers.append(str(column.get("title", "")))
		widths.append(int(column.get("width", 72)))
	return _create_table(headers, widths)


func _batter_columns() -> Array:
	return _combined_columns(BATTER_COLUMNS, [
		BATTING_ADVANCED_COLUMNS,
		FIELDING_ADVANCED_COLUMNS,
		BATTING_ABILITY_COLUMNS,
		PITCHING_ABILITY_COLUMNS,
		FIELDING_ABILITY_COLUMNS,
	])


func _batter_metric_columns() -> Array:
	return _combined_columns(BATTER_METRIC_COLUMNS, [
		BATTING_ADVANCED_COLUMNS,
		FIELDING_ADVANCED_COLUMNS,
		BATTING_ABILITY_COLUMNS,
		PITCHING_ABILITY_COLUMNS,
		FIELDING_ABILITY_COLUMNS,
	])


func _pitcher_columns() -> Array:
	return _combined_columns(PITCHER_COLUMNS, [
		PITCHING_ADVANCED_COLUMNS,
		FIELDING_ADVANCED_COLUMNS,
		BATTING_ABILITY_COLUMNS,
		PITCHING_ABILITY_COLUMNS,
		FIELDING_ABILITY_COLUMNS,
	])


func _pitcher_metric_columns() -> Array:
	return _combined_columns(PITCHER_METRIC_COLUMNS, [
		PITCHING_ADVANCED_COLUMNS,
		FIELDING_ADVANCED_COLUMNS,
		BATTING_ABILITY_COLUMNS,
		PITCHING_ABILITY_COLUMNS,
		FIELDING_ABILITY_COLUMNS,
	])


func _combined_columns(base_columns: Array, column_groups: Array) -> Array:
	var columns: Array = base_columns.duplicate(true)
	var seen_keys: Dictionary = {}
	for column_value in columns:
		var column: Dictionary = column_value as Dictionary
		seen_keys[str(column.get("key", ""))] = true
	for group_value in column_groups:
		var group: Array = group_value as Array
		for column_value in group:
			var column: Dictionary = (column_value as Dictionary).duplicate(true)
			var key: String = str(column.get("key", ""))
			if seen_keys.has(key):
				continue
			columns.append(column)
			seen_keys[key] = true
	return columns


func _load_existing_report() -> void:
	if not FileAccess.file_exists(REPORT_PATH):
		status_label.text = "未計測"
		_clear_tables()
		return

	var file: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.READ)
	if file == null:
		status_label.text = "既存レポートを読み込めません"
		return

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		status_label.text = "既存レポートが不正です"
		return

	current_report = parsed as Dictionary
	_render_report()
	status_label.text = "読み込み済み: %s" % ProjectSettings.globalize_path(REPORT_PATH)


func _run_report() -> void:
	status_label.text = "計測中..."
	run_button.disabled = true

	# UI フリーズ対策: ProgressOverlay + cancel_token を渡し、試合単位で yield する。
	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("シーズンシミュレーション中…")

	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)
	var options: Dictionary = {
		"seasons": int(seasons_spin.value),
		"seed": _seed_value(),
		"selected_team_id": int(selected_team_spin.value),
		"output": REPORT_PATH,
		"dh_by_league": AppState.dh_settings_for_schedule(),
		"scene_tree": get_tree(),
		"cancel_token": cancel_token,
		"progress_callback": update_overlay,
	}
	var reporter: Object = ReporterScript.new()
	var report_value: Variant = await reporter.call("run_async", options)
	current_report = report_value as Dictionary

	overlay.hide_progress()
	overlay.queue_free()

	var cancelled: bool = bool(current_report.get("cancelled", false))
	var completed: int = int(current_report.get("seasons_completed", 0))
	var requested: int = int(current_report.get("seasons_requested", 0))
	if cancelled:
		_render_report()
		status_label.text = "キャンセルされました (%d/%dシーズン完了)" % [completed, requested]
		run_button.disabled = false
		return

	var write_ok: bool = _write_report(REPORT_PATH, current_report)
	_render_report()

	var output_status: String = "JSON保存済み" if write_ok else "JSON保存失敗"
	status_label.text = "%d/%dシーズン完走 / %s" % [completed, requested, output_status]
	run_button.disabled = false


func _seed_value() -> int:
	var text: String = seed_edit.text.strip_edges()
	if text.is_valid_int():
		return int(text)
	return 12345


func _write_report(path: String, report: Dictionary) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var parent_dir: String = global_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(parent_dir) != OK:
		return false

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false

	file.store_string(JSON.stringify(report, "\t"))
	return true


func _render_report() -> void:
	_clear_tables()
	if current_report.is_empty():
		return

	_fill_overview_table()
	_fill_season_table()
	_fill_team_table()
	_fill_batter_table()
	_fill_pitcher_table()
	_fill_batter_metric_table()
	_fill_pitcher_metric_table()


func _clear_tables() -> void:
	for tree in [overview_tree, season_tree, team_tree, batter_tree, pitcher_tree, batter_metric_tree, pitcher_metric_tree]:
		if tree != null:
			tree.clear()
			tree.create_item()


func _fill_overview_table() -> void:
	var root: TreeItem = overview_tree.get_root()
	var run_environment: Dictionary = current_report.get("run_environment", {}) as Dictionary
	var batting: Dictionary = current_report.get("batting", {}) as Dictionary
	var pitching: Dictionary = current_report.get("pitching", {}) as Dictionary
	var advanced: Dictionary = current_report.get("advanced", {}) as Dictionary
	var advanced_players: Dictionary = advanced.get("players", {}) as Dictionary
	var advanced_pitchers: Dictionary = advanced.get("pitchers", {}) as Dictionary
	_add_metric(root, "完走シーズン", "%d / %d" % [int(current_report.get("seasons_completed", 0)), int(current_report.get("seasons_requested", 0))])
	_add_metric(root, "シード", str(current_report.get("seed", "")))
	_add_metric(root, "データ", "%s / %dチーム / %d選手" % [str(current_report.get("data_source", "")), int(current_report.get("team_count", 0)), int(current_report.get("player_count", 0))])
	_add_metric(root, "総試合", "%d" % int(run_environment.get("games", 0)))
	_add_metric(root, "得点/チーム試合", _format_float(float(run_environment.get("runs_per_team_game", 0.0)), 3))
	_add_metric(root, "得点/試合", _format_float(float(run_environment.get("runs_per_game_total", 0.0)), 3))
	_add_metric(root, "打率 / 出塁率 / 長打率", "%s / %s / %s" % [
		_format_rate(float(batting.get("batting_average", 0.0))),
		_format_rate(float(batting.get("on_base_percentage", 0.0))),
		_format_rate(float(batting.get("slugging_percentage", 0.0))),
	])
	_add_metric(root, "OPS", _format_rate(float(batting.get("ops", 0.0))))
	_add_metric(root, "本塁打/試合", _format_float(float(batting.get("home_runs_per_game", 0.0)), 3))
	_add_metric(root, "三振/試合", _format_float(float(batting.get("strikeouts_per_game", 0.0)), 3))
	_add_metric(root, "ERA / WHIP", "%s / %s" % [
		_format_float(float(pitching.get("era", 0.0)), 2),
		_format_float(float(pitching.get("whip", 0.0)), 3),
	])
	var pa: int = int(batting.get("plate_appearances", 0))
	var ab: int = int(batting.get("at_bats", 0))
	_add_metric(root, "PA/K / PA/BB / AB/HR", "%s / %s / %s" % [
		_format_float(_ratio(pa, int(batting.get("strikeouts", 0))), 2),
		_format_float(_ratio(pa, int(batting.get("walks", 0))), 2),
		_format_float(_ratio(ab, int(batting.get("home_runs", 0))), 2),
	])
	_add_metric(root, "Advanced batting", _advanced_batting_text(advanced_players))
	_add_metric(root, "Advanced pitching", _advanced_pitching_text(advanced_pitchers))
	_add_metric(root, "Advanced fielding", _advanced_fielding_text(advanced_players))


func _fill_season_table() -> void:
	var root: TreeItem = season_tree.get_root()
	var rows: Array = current_report.get("season_summaries", []) as Array
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var batting: Dictionary = row.get("batting", {}) as Dictionary
		var pitching: Dictionary = row.get("pitching", {}) as Dictionary
		var advanced: Dictionary = row.get("advanced", {}) as Dictionary
		var advanced_players: Dictionary = advanced.get("players", {}) as Dictionary
		_add_row(season_tree, root, [
			str(row.get("year", "")),
			str(row.get("games", "")),
			_format_float(float(row.get("runs_per_team_game", 0.0)), 3),
			_format_rate(float(batting.get("batting_average", 0.0))),
			_format_rate(float(batting.get("ops", 0.0))),
			_format_float(float(batting.get("home_runs_per_game", 0.0)), 3),
			_format_float(float(pitching.get("era", 0.0)), 2),
			_format_float(float(pitching.get("whip", 0.0)), 3),
			_format_float(float(pitching.get("strikeouts_per_nine", 0.0)), 2),
			_format_float(float(pitching.get("walks_per_nine", 0.0)), 2),
			_format_float(float(advanced_players.get("woba", 0.0)), 3),
			_format_float(float(advanced_players.get("xwoba", 0.0)), 3),
			_format_float(float(advanced_players.get("wrc_plus", 0.0)), 1),
			_format_float(float(advanced_players.get("re24", 0.0)), 1),
			_format_float(float(advanced_players.get("bsr", 0.0)), 1),
			_oaa_zone_label(str(advanced_players.get("primary_oaa_zone", ""))),
			_format_float(float(advanced_players.get("oaa", 0.0)), 1),
			_format_float(float(advanced_players.get("oaa_infield", 0.0)), 1),
			_format_float(float(advanced_players.get("oaa_outfield", 0.0)), 1),
			_uzr_position_label(int(advanced_players.get("primary_uzr_position", 0))),
			_format_float(float(advanced_players.get("rngr", 0.0)), 1),
			_format_float(float(advanced_players.get("errr", 0.0)), 1),
			_format_float(float(advanced_players.get("dpr", 0.0)), 1),
			_format_float(float(advanced_players.get("uzr", 0.0)), 1),
			_format_float(float(advanced_players.get("drs", 0.0)), 1),
			_format_float(float(advanced_players.get("positional_adjustment_runs", 0.0)), 1),
			_format_float(float(advanced_players.get("def_runs", 0.0)), 1),
		])


func _fill_team_table() -> void:
	var root: TreeItem = team_tree.get_root()
	var rows: Array = current_report.get("team_seasons", []) as Array
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		_add_row(team_tree, root, [
			str(row.get("year", "")),
			str(row.get("team", "")),
			str(row.get("wins", "")),
			str(row.get("losses", "")),
			str(row.get("draws", "")),
			_format_rate(float(row.get("win_rate", 0.0))),
			_format_float(float(row.get("runs_per_game", 0.0)), 3),
			_format_float(float(row.get("runs_allowed_per_game", 0.0)), 3),
			_format_rate(float(row.get("batting_average", 0.0))),
			str(row.get("home_runs", "")),
			_format_float(float(row.get("era", 0.0)), 2),
			_format_float(float(row.get("whip", 0.0)), 3),
		])


func _fill_batter_table() -> void:
	batter_tree.clear()
	var root: TreeItem = batter_tree.create_item()
	var player_stats: Dictionary = current_report.get("player_stats", {}) as Dictionary
	var rows: Array = player_stats.get("batters", []) as Array
	var columns: Array = _batter_columns()
	var sorted_rows: Array = _sorted_rows(rows, columns, batter_sort_column, batter_sort_ascending)
	for row_value in sorted_rows:
		var row: Dictionary = row_value as Dictionary
		_add_stat_row(batter_tree, root, columns, row)


func _fill_pitcher_table() -> void:
	pitcher_tree.clear()
	var root: TreeItem = pitcher_tree.create_item()
	var player_stats: Dictionary = current_report.get("player_stats", {}) as Dictionary
	var rows: Array = player_stats.get("pitchers", []) as Array
	var columns: Array = _pitcher_columns()
	var sorted_rows: Array = _sorted_rows(rows, columns, pitcher_sort_column, pitcher_sort_ascending)
	for row_value in sorted_rows:
		var row: Dictionary = row_value as Dictionary
		_add_stat_row(pitcher_tree, root, columns, row)


func _fill_batter_metric_table() -> void:
	batter_metric_tree.clear()
	var root: TreeItem = batter_metric_tree.create_item()
	var player_stats: Dictionary = current_report.get("player_stats", {}) as Dictionary
	var rows: Array = player_stats.get("batters", []) as Array
	var columns: Array = _batter_metric_columns()
	var sorted_rows: Array = _sorted_rows(rows, columns, batter_metric_sort_column, batter_metric_sort_ascending)
	for row_value in sorted_rows:
		var row: Dictionary = row_value as Dictionary
		_add_stat_row(batter_metric_tree, root, columns, row)


func _fill_pitcher_metric_table() -> void:
	pitcher_metric_tree.clear()
	var root: TreeItem = pitcher_metric_tree.create_item()
	var player_stats: Dictionary = current_report.get("player_stats", {}) as Dictionary
	var rows: Array = player_stats.get("pitchers", []) as Array
	var columns: Array = _pitcher_metric_columns()
	var sorted_rows: Array = _sorted_rows(rows, columns, pitcher_metric_sort_column, pitcher_metric_sort_ascending)
	for row_value in sorted_rows:
		var row: Dictionary = row_value as Dictionary
		_add_stat_row(pitcher_metric_tree, root, columns, row)


func _add_stat_row(tree: Tree, root: TreeItem, columns: Array, row: Dictionary) -> void:
	var item: TreeItem = tree.create_item(root)
	for index in range(columns.size()):
		var column: Dictionary = columns[index] as Dictionary
		item.set_text(index, _format_cell(row, column))


func _advanced_batting_text(summary: Dictionary) -> String:
	return "PA %d / wOBA %s / xwOBA %s / wRC+ %s / RE24 %s / BsR %s" % [
		int(summary.get("plate_appearances", 0)),
		_format_float(float(summary.get("woba", 0.0)), 3),
		_format_float(float(summary.get("xwoba", 0.0)), 3),
		_format_float(float(summary.get("wrc_plus", 0.0)), 1),
		_format_float(float(summary.get("re24", 0.0)), 1),
		_format_float(float(summary.get("bsr", 0.0)), 1),
	]


func _advanced_pitching_text(summary: Dictionary) -> String:
	return "BF %d / wOBAA %s / xwOBAA %s / wRC+ A %s / RE24 A %s" % [
		int(summary.get("plate_appearances", 0)),
		_format_float(float(summary.get("woba", 0.0)), 3),
		_format_float(float(summary.get("xwoba", 0.0)), 3),
		_format_float(float(summary.get("wrc_plus", 0.0)), 1),
		_format_float(float(summary.get("re24", 0.0)), 1),
	]


func _advanced_fielding_text(summary: Dictionary) -> String:
	# OAA は守備機会の多い方のゾーン (IF / OF) を集計対象とする。
	# UZR / RngR / ErrR / DPR / DRS は守備機会の多いポジション (P1-P9) を集計対象とする。
	return "Ch %d / OAA[%s] %s (IF %s OF %s) / UZR[%s] %s / RngR %s / ErrR %s / DPR %s / DRS %s / Def %s" % [
		int(summary.get("fielding_chances", 0)),
		_oaa_zone_label(str(summary.get("primary_oaa_zone", ""))),
		_format_float(float(summary.get("oaa", 0.0)), 1),
		_format_float(float(summary.get("oaa_infield", 0.0)), 1),
		_format_float(float(summary.get("oaa_outfield", 0.0)), 1),
		_uzr_position_label(int(summary.get("primary_uzr_position", 0))),
		_format_float(float(summary.get("uzr", 0.0)), 1),
		_format_float(float(summary.get("rngr", 0.0)), 1),
		_format_float(float(summary.get("errr", 0.0)), 1),
		_format_float(float(summary.get("dpr", 0.0)), 1),
		_format_float(float(summary.get("drs", 0.0)), 1),
		_format_float(float(summary.get("def_runs", 0.0)), 1),
	]


# OAA ゾーンを表示用に変換。
func _oaa_zone_label(zone: String) -> String:
	if zone == "infield":
		return "IF"
	if zone == "outfield":
		return "OF"
	return "-"


# UZR / RngR / ErrR / DPR の集計対象ポジションを表示用に変換。
func _uzr_position_label(pos: int) -> String:
	if pos <= 0 or pos > 9:
		return "-"
	return "P%d" % pos


func _add_metric(root: TreeItem, label: String, value: String) -> void:
	_add_row(overview_tree, root, [label, value])


func _add_row(tree: Tree, root: TreeItem, values: Array) -> void:
	var item: TreeItem = tree.create_item(root)
	for index in range(values.size()):
		item.set_text(index, str(values[index]))


func _on_batter_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if batter_sort_column == column:
		batter_sort_ascending = not batter_sort_ascending
	else:
		batter_sort_column = column
		batter_sort_ascending = false
	_fill_batter_table()


func _on_pitcher_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if pitcher_sort_column == column:
		pitcher_sort_ascending = not pitcher_sort_ascending
	else:
		pitcher_sort_column = column
		pitcher_sort_ascending = false
	_fill_pitcher_table()


func _on_batter_metric_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if batter_metric_sort_column == column:
		batter_metric_sort_ascending = not batter_metric_sort_ascending
	else:
		batter_metric_sort_column = column
		batter_metric_sort_ascending = false
	_fill_batter_metric_table()


func _on_pitcher_metric_column_title_clicked(column: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	if pitcher_metric_sort_column == column:
		pitcher_metric_sort_ascending = not pitcher_metric_sort_ascending
	else:
		pitcher_metric_sort_column = column
		pitcher_metric_sort_ascending = false
	_fill_pitcher_metric_table()


func _sorted_rows(rows: Array, columns: Array, sort_column: int, ascending: bool) -> Array:
	var sorted_rows: Array = rows.duplicate(true)
	if sort_column < 0 or sort_column >= columns.size():
		return sorted_rows

	var column: Dictionary = columns[sort_column] as Dictionary
	var sort_key: String = str(column.get("key", ""))
	var sort_type: String = str(column.get("type", "string"))
	sorted_rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var left: Dictionary = a as Dictionary
		var right: Dictionary = b as Dictionary
		var comparison: int = _compare_rows(left, right, sort_key, sort_type)
		if comparison == 0:
			comparison = _compare_tiebreak(left, right)
		if ascending:
			return comparison < 0
		return comparison > 0
	)
	return sorted_rows


func _compare_rows(left: Dictionary, right: Dictionary, sort_key: String, sort_type: String) -> int:
	if sort_type == "number":
		var left_number: float = float(left.get(sort_key, 0.0))
		var right_number: float = float(right.get(sort_key, 0.0))
		if is_equal_approx(left_number, right_number):
			return 0
		return -1 if left_number < right_number else 1

	var left_text: String = str(left.get(sort_key, "")).to_lower()
	var right_text: String = str(right.get(sort_key, "")).to_lower()
	if left_text == right_text:
		return 0
	return -1 if left_text < right_text else 1


func _compare_tiebreak(left: Dictionary, right: Dictionary) -> int:
	var left_text: String = "%04d:%s:%s" % [
		int(left.get("year", 0)),
		str(left.get("team", "")),
		str(left.get("name", "")),
	]
	var right_text: String = "%04d:%s:%s" % [
		int(right.get("year", 0)),
		str(right.get("team", "")),
		str(right.get("name", "")),
	]
	if left_text == right_text:
		return 0
	return -1 if left_text < right_text else 1


func _format_cell(row: Dictionary, column: Dictionary) -> String:
	var key: String = str(column.get("key", ""))
	if not row.has(key) and key.begins_with("display_"):
		key = key.replace("display_", "visible_")
	var format: String = str(column.get("format", "string"))
	match format:
		"int":
			return str(int(row.get(key, 0)))
		"rate":
			return _format_rate(float(row.get(key, 0.0)))
		"float1":
			return _format_float(float(row.get(key, 0.0)), 1)
		"float2":
			return _format_float(float(row.get(key, 0.0)), 2)
		"float3":
			return _format_float(float(row.get(key, 0.0)), 3)
		"z":
			return _format_z(_coerce_z_value(float(row.get(key, 0.0))))
		"percent1":
			return "%0.1f%%" % (float(row.get(key, 0.0)) * 100.0)
		"zone":
			# OAA は内野 / 外野どちらをまとめた値か明示する。
			var zone: String = str(row.get(key, ""))
			if zone == "infield":
				return "IF"
			if zone == "outfield":
				return "OF"
			return "-"
		"position":
			# UZR / RngR / ErrR / DPR はポジション単位の集計値。0 (未集計) は "-"。
			var pos: int = int(row.get(key, 0))
			if pos <= 0 or pos > 9:
				return "-"
			return "P%d" % pos
		_:
			return str(row.get(key, ""))


func _go_back() -> void:
	AppState.request_screen("start")


func _format_rate(value: float) -> String:
	return "%0.3f" % value


# 分母が 0 のときは 0.0 を返す安全な除算（PA/K などの比率算出用）。
func _ratio(numerator: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	return float(numerator) / float(denominator)


func _format_float(value: float, digits: int) -> String:
	if digits == 1:
		return "%0.1f" % value
	if digits == 2:
		return "%0.2f" % value
	return "%0.3f" % value


func _format_z(value: float) -> String:
	return "%+.2f" % value


func _coerce_z_value(value: float) -> float:
	if absf(value) > 8.0:
		return PSAbilityScale.display_to_z(clampi(int(round(value)), PSAbilityScale.DISPLAY_MIN, PSAbilityScale.DISPLAY_MAX))
	return value
