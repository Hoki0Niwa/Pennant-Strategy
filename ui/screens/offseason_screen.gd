extends Control

const CampServiceRef = preload("res://services/season/camp_service.gd")
const Offseason = preload("res://services/season/offseason_service.gd")
const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const SortableTable = preload("res://ui/components/sortable_table.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const TOTAL_STEPS: int = 10

# 戦力外通告リストの列。先頭は選択チェック表示。
const RELEASE_COLUMNS: Array = [
	{"title": "選", "key": "check", "width": 36, "type": "string", "format": "string"},
	{"title": "区分", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "在籍", "key": "years", "width": 48, "type": "number", "format": "int", "align": "right"},
	{"title": "総合", "key": "eval", "width": 56, "type": "number", "format": "int", "align": "right"},
	{"title": "WAR", "key": "war", "width": 56, "type": "number", "format": "float1", "align": "right"},
	{"title": "怪我", "key": "injury", "width": 56, "type": "number", "format": "int", "align": "right"},
	{"title": "備考", "key": "note", "width": 80, "type": "string", "format": "string"},
	{"title": "今季成績", "key": "stat", "width": 260, "type": "string", "format": "string"},
]

# ドラフト候補ボードの列。
const CANDIDATE_COLUMNS: Array = [
	{"title": "#", "key": "rank", "width": 44, "type": "number", "format": "int"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "守備", "key": "pos", "width": 52, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall", "width": 56, "type": "number", "format": "int"},
	{"title": "出身", "key": "source", "width": 64, "type": "string", "format": "string"},
]

const PITCHER_CANDIDATE_COLUMNS: Array = [
	{"title": "#", "key": "rank", "width": 44, "type": "number", "format": "int"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "役割", "key": "pos", "width": 52, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall", "width": 56, "type": "number", "format": "int"},
	{"title": "出身", "key": "source", "width": 64, "type": "string", "format": "string"},
]

# 指名履歴の列。
const PICK_COLUMNS: Array = [
	{"title": "順", "key": "pick", "width": 48, "type": "number", "format": "int"},
	{"title": "巡", "key": "round", "width": 40, "type": "number", "format": "int"},
	{"title": "チーム", "key": "team", "width": 64, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "区分", "key": "pos", "width": 52, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall", "width": 56, "type": "number", "format": "int"},
	{"title": "抽選", "key": "note", "width": 48, "type": "string", "format": "string"},
]

# ステップ結果テーブルの列定義。
const PEOPLE_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "在籍", "key": "years", "width": 56, "type": "number", "format": "int"},
	{"title": "総合", "key": "overall", "width": 56, "type": "number", "format": "int"},
]

const ROOKIE_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall", "width": 56, "type": "number", "format": "int"},
]

# R4 Step1: 契約更新ステップの列定義。
const SALARY_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "ポジション", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "旧年俸", "key": "old", "width": 80, "type": "number", "format": "int", "align": "right"},
	{"title": "新年俸", "key": "new", "width": 80, "type": "number", "format": "int", "align": "right"},
	{"title": "増減", "key": "delta", "width": 80, "type": "number", "format": "int", "align": "right"},
]

const FA_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "在籍", "key": "years", "width": 56, "type": "number", "format": "int", "align": "right"},
	{"title": "FA日数", "key": "fa_days", "width": 72, "type": "number", "format": "int", "align": "right"},
	{"title": "必要", "key": "fa_required", "width": 72, "type": "number", "format": "int", "align": "right"},
]

const BUDGET_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "予算", "key": "funds", "width": 96, "type": "number", "format": "int", "align": "right"},
	{"title": "年俸総額", "key": "payroll", "width": 96, "type": "number", "format": "int", "align": "right"},
	{"title": "残枠", "key": "room", "width": 96, "type": "number", "format": "int", "align": "right"},
	{"title": "状態", "key": "state", "width": 72, "type": "string", "format": "string"},
]

# R4 Step2: FA移籍テーブルの列定義。
const FA_MOVE_COLUMNS: Array = [
	{"title": "元", "key": "from", "width": 64, "type": "string", "format": "string"},
	{"title": "→", "key": "arrow", "width": 28, "type": "string", "format": "string"},
	{"title": "先", "key": "to", "width": 64, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "ランク", "key": "rank", "width": 56, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "年俸", "key": "salary", "width": 80, "type": "number", "format": "int", "align": "right"},
	{"title": "補償", "key": "compensation", "width": 80, "type": "number", "format": "int", "align": "right"},
]

const FA_CANDIDATE_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "元", "key": "from", "width": 64, "type": "string", "format": "string"},
	{"title": "ランク", "key": "rank", "width": 56, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 72, "type": "string", "format": "string"},
	{"title": "総合", "key": "value", "width": 56, "type": "number", "format": "int"},
	{"title": "WAR", "key": "war", "width": 56, "type": "number", "format": "float1"},
	{"title": "需要", "key": "need", "width": 56, "type": "number", "format": "float1"},
	{"title": "成功", "key": "chance", "width": 56, "type": "number", "format": "pct1"},
	{"title": "宣言", "key": "declare", "width": 56, "type": "number", "format": "pct1"},
	{"title": "FA日数", "key": "fa_days", "width": 72, "type": "number", "format": "int", "align": "right"},
	{"title": "提示", "key": "offer", "width": 80, "type": "number", "format": "int", "align": "right"},
	{"title": "補償", "key": "compensation", "width": 80, "type": "number", "format": "int", "align": "right"},
]

const RELEASED_MOVE_COLUMNS: Array = [
	{"title": "元", "key": "from", "width": 64, "type": "string", "format": "string"},
	{"title": "→", "key": "arrow", "width": 28, "type": "string", "format": "string"},
	{"title": "先", "key": "to", "width": 64, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "年俸", "key": "salary", "width": 80, "type": "number", "format": "int", "align": "right"},
]

const RELEASED_CANDIDATE_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "元", "key": "from", "width": 64, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 72, "type": "string", "format": "string"},
	{"title": "総合", "key": "value", "width": 56, "type": "number", "format": "int"},
	{"title": "WAR", "key": "war", "width": 56, "type": "number", "format": "float1"},
	{"title": "需要", "key": "need", "width": 56, "type": "number", "format": "float1"},
	{"title": "年俸", "key": "salary", "width": 80, "type": "number", "format": "int", "align": "right"},
]

# R4 Step3: 外国人補強テーブルの列定義。
const FOREIGN_COLUMNS: Array = [
	{"title": "獲得", "key": "to", "width": 64, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 84, "type": "string", "format": "string"},
	{"title": "評価", "key": "tier", "width": 72, "type": "string", "format": "string"},
	{"title": "年俸", "key": "salary", "width": 88, "type": "number", "format": "int", "align": "right"},
]

const FOREIGN_CANDIDATE_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "区分", "key": "pos", "width": 72, "type": "string", "format": "string"},
	{"title": "評価", "key": "tier", "width": 80, "type": "string", "format": "string"},
	{"title": "総合", "key": "value", "width": 56, "type": "number", "format": "int"},
	{"title": "需要", "key": "need", "width": 56, "type": "number", "format": "float1"},
	{"title": "年俸", "key": "salary", "width": 88, "type": "number", "format": "int", "align": "right"},
]

const CAMP_ROSTER_COLUMNS: Array = [
	{"title": "背", "key": "jersey", "width": 44, "type": "string", "format": "string"},
	{"title": "区分", "key": "pos", "width": 48, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 56, "type": "number", "format": "int"},
	{"title": "評価", "key": "eval", "width": 56, "type": "number", "format": "int"},
]

const CAMP_RESULT_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "練習", "key": "training", "width": 120, "type": "string", "format": "string"},
	{"title": "成否", "key": "result", "width": 64, "type": "string", "format": "string"},
	{"title": "対象", "key": "target", "width": 80, "type": "string", "format": "string"},
	{"title": "変化", "key": "change", "width": 180, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall", "width": 84, "type": "string", "format": "string"},
]

const CAMP_PITCH_COLUMNS: Array = [
	{"title": "チーム", "key": "team", "width": 72, "type": "string", "format": "string"},
	{"title": "選手", "key": "name", "width": 120, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 52, "type": "number", "format": "int"},
	{"title": "習得球種", "key": "pitch", "width": 110, "type": "string", "format": "string"},
	{"title": "完成度", "key": "grade", "width": 64, "type": "string", "format": "string"},
]

# 成長結果テーブル: 投手 (左)。総合・表示能力 (球速/球質/制球/スタミナ) を同じ "66(+6)" 形式
# (変化後の値(+増減)) で見せる。総合列は表示は文字列だが sort_key=delta で数値ソートできる。
const PITCHER_GROWTH_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 110, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 48, "type": "number", "format": "int"},
	{"title": "種類", "key": "kind", "width": 72, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall_cell", "sort_key": "delta", "width": 84, "type": "number", "format": "string"},
	{"title": "球速", "key": "velocity", "width": 84, "type": "string", "format": "string"},
	{"title": "球質", "key": "stuff", "width": 72, "type": "string", "format": "string"},
	{"title": "制球", "key": "control", "width": 72, "type": "string", "format": "string"},
	{"title": "スタミナ", "key": "stamina", "width": 84, "type": "string", "format": "string"},
]

# 成長結果テーブル: 野手 (右)。巧打/長打/走力/守備/肩力/選球 の変化を同じ形式で見せる。
const FIELDER_GROWTH_COLUMNS: Array = [
	{"title": "選手", "key": "name", "width": 110, "type": "string", "format": "string"},
	{"title": "年齢", "key": "age", "width": 48, "type": "number", "format": "int"},
	{"title": "種類", "key": "kind", "width": 72, "type": "string", "format": "string"},
	{"title": "総合", "key": "overall_cell", "sort_key": "delta", "width": 84, "type": "number", "format": "string"},
	{"title": "巧打", "key": "contact", "width": 72, "type": "string", "format": "string"},
	{"title": "長打", "key": "power", "width": 72, "type": "string", "format": "string"},
	{"title": "走力", "key": "speed", "width": 72, "type": "string", "format": "string"},
	{"title": "守備", "key": "defense", "width": 72, "type": "string", "format": "string"},
	{"title": "肩力", "key": "arm", "width": 72, "type": "string", "format": "string"},
	{"title": "選球", "key": "discipline", "width": 72, "type": "string", "format": "string"},
]

# ドラフト結果 (球団ごとの表) の列。巡・選手・年齢・区分(1文字)・総合のみ。
const DRAFT_RESULT_COLUMNS: Array = [
	{"title": "巡", "key": "round", "width": 30, "type": "number", "format": "int"},
	{"title": "選手", "key": "name", "width": 92, "type": "string", "format": "string"},
	{"title": "年", "key": "age", "width": 32, "type": "number", "format": "int"},
	{"title": "区", "key": "pos", "width": 30, "type": "string", "format": "string"},
	{"title": "総", "key": "overall", "width": 36, "type": "number", "format": "int"},
]

# 守備位置の1文字表記。
const POSITION_CHARS: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "指",
}

var step_indicator: Label
var status_label: Label
var content_box: VBoxContainer
var next_button: Button
var finalize_button: Button

# step 1 (release editor) widgets
var release_panel: VBoxContainer
var release_list: Tree
var release_summary_label: Label
var commit_release_button: Button
var team_roster_records: Array = []
var selected_release_ids: Dictionary = {}
# roadmap #3: 育成降格に印を付けた選手。戦力外の軟らかい代替 (release せず育成化)。
var selected_demote_ids: Dictionary = {}
var last_release_meta: int = 0
# { player_id: war } 戦力外リスト構築時に season_war_table を 1 回計算してキャッシュ。
var release_war_by_id: Dictionary = {}

# step 3 draft widgets
var draft_panel: VBoxContainer
var draft_status_label: Label
var draft_position_summary_label: RichTextLabel
var draft_pitcher_list: Tree
var draft_fielder_list: Tree
var draft_pick_list: Tree
var draft_lottery_text: RichTextLabel
var draft_detail_text: RichTextLabel
var draft_submit_button: Button
var draft_skip_button: Button
var draft_auto_button: Button
var draft_auto_all_button: Button
var selected_draft_candidate_id: int = 0
var _suppress_candidate_select: bool = false

# step 4 released market widgets
var released_market_panel: VBoxContainer
var released_market_status_label: Label
var released_market_candidate_list: Tree
var released_market_detail_text: RichTextLabel
var released_market_submit_button: Button
var released_market_skip_button: Button
var released_market_auto_button: Button
var released_market_auto_all_button: Button
var selected_released_candidate_id: int = 0
var _suppress_released_select: bool = false

# step 5 FA widgets
var fa_panel: VBoxContainer
var fa_status_label: Label
var fa_candidate_list: Tree
var fa_detail_text: RichTextLabel
var fa_submit_button: Button
var fa_skip_button: Button
var fa_auto_button: Button
var fa_auto_all_button: Button
var selected_fa_candidate_id: int = 0
var _suppress_fa_select: bool = false

# step 6 foreign widgets
var foreign_panel: VBoxContainer
var foreign_status_label: Label
var foreign_candidate_list: Tree
var foreign_detail_text: RichTextLabel
var foreign_submit_button: Button
var foreign_skip_button: Button
var foreign_auto_button: Button
var foreign_auto_all_button: Button
var selected_foreign_candidate_id: int = 0
var _suppress_foreign_select: bool = false

# step 7 camp widgets
var camp_panel: VBoxContainer
var camp_status_label: Label
var camp_player_list: Tree
var camp_training_select: OptionButton
var camp_position_select: OptionButton
var camp_detail_text: RichTextLabel
var camp_submit_button: Button
var camp_auto_button: Button
var camp_finish_button: Button
var selected_camp_player_id: int = 0
var selected_camp_training_type: String = ""
var selected_camp_target_position: int = 0
var _suppress_camp_select: bool = false
var _suppress_camp_training_select: bool = false


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "オフシーズン"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	step_indicator = Label.new()
	step_indicator.add_theme_font_size_override("font_size", 18)
	step_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(step_indicator)

	next_button = Button.new()
	next_button.text = "次のステップへ"
	next_button.custom_minimum_size = Vector2(160, 32)
	next_button.pressed.connect(_on_next_pressed)
	header.add_child(next_button)

	finalize_button = Button.new()
	finalize_button.text = "翌年開始"
	finalize_button.custom_minimum_size = Vector2(120, 32)
	finalize_button.pressed.connect(_on_finalize_pressed)
	header.add_child(finalize_button)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	release_panel = _build_release_panel()
	root.add_child(release_panel)

	draft_panel = _build_draft_panel()
	root.add_child(draft_panel)

	released_market_panel = _build_released_market_panel()
	root.add_child(released_market_panel)

	fa_panel = _build_fa_panel()
	root.add_child(fa_panel)

	foreign_panel = _build_foreign_panel()
	root.add_child(foreign_panel)

	camp_panel = _build_camp_panel()
	root.add_child(camp_panel)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	content_box = VBoxContainer.new()
	content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_box.add_theme_constant_override("separation", 8)
	scroll.add_child(content_box)

	_refresh()


func _build_release_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 6)

	var info: Label = Label.new()
	info.text = "戦力外通告: 行クリックで 戦力外(✓)→育成降格(育)→解除 を切替。Shift+クリックで範囲戦力外。育成降格は支配下枠を空けつつ org に残します。確定後は戻せません。"
	info.add_theme_color_override("font_color", Color(0.78, 0.86, 0.92))
	panel.add_child(info)

	release_summary_label = Label.new()
	release_summary_label.add_theme_font_size_override("font_size", 16)
	panel.add_child(release_summary_label)

	release_list = SortableTable.new()
	panel.add_child(release_list)
	release_list.configure(RELEASE_COLUMNS)
	release_list.item_selected.connect(_on_release_item_selected)

	var button_row: HBoxContainer = HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 8)
	panel.add_child(button_row)

	var auto_select_button: Button = Button.new()
	auto_select_button.text = "自動で決める"
	auto_select_button.custom_minimum_size = Vector2(160, 32)
	auto_select_button.pressed.connect(_on_auto_select_release_pressed)
	button_row.add_child(auto_select_button)

	commit_release_button = Button.new()
	commit_release_button.text = "戦力外を確定して次へ"
	commit_release_button.custom_minimum_size = Vector2(220, 32)
	commit_release_button.pressed.connect(_on_commit_release_pressed)
	button_row.add_child(commit_release_button)
	return panel


func _build_draft_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var control_row: HBoxContainer = HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	panel.add_child(control_row)

	draft_status_label = Label.new()
	draft_status_label.add_theme_font_size_override("font_size", 16)
	draft_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(draft_status_label)

	draft_submit_button = Button.new()
	draft_submit_button.text = "指名する"
	draft_submit_button.custom_minimum_size = Vector2(120, 32)
	draft_submit_button.pressed.connect(_on_draft_submit_pressed)
	control_row.add_child(draft_submit_button)

	# 本指名/育成指名を打ち切るためのボタン。
	draft_skip_button = Button.new()
	draft_skip_button.text = "見送り"
	draft_skip_button.custom_minimum_size = Vector2(100, 32)
	draft_skip_button.pressed.connect(_on_draft_skip_pressed)
	draft_skip_button.visible = false
	control_row.add_child(draft_skip_button)

	draft_auto_button = Button.new()
	draft_auto_button.text = "この指名を自動"
	draft_auto_button.custom_minimum_size = Vector2(140, 32)
	draft_auto_button.pressed.connect(_on_draft_auto_pressed)
	control_row.add_child(draft_auto_button)

	draft_auto_all_button = Button.new()
	draft_auto_all_button.text = "残りを自動進行"
	draft_auto_all_button.custom_minimum_size = Vector2(150, 32)
	draft_auto_all_button.pressed.connect(_on_draft_auto_all_pressed)
	control_row.add_child(draft_auto_all_button)

	draft_position_summary_label = RichTextLabel.new()
	draft_position_summary_label.bbcode_enabled = false
	draft_position_summary_label.fit_content = true
	draft_position_summary_label.scroll_active = false
	draft_position_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	draft_position_summary_label.add_theme_font_size_override("normal_font_size", 13)
	panel.add_child(draft_position_summary_label)

	var candidate_title: Label = Label.new()
	candidate_title.text = "ドラフト候補 (列見出しクリックで並べ替え)"
	candidate_title.add_theme_font_size_override("font_size", 16)
	panel.add_child(candidate_title)

	var board_row: HBoxContainer = HBoxContainer.new()
	board_row.add_theme_constant_override("separation", 8)
	board_row.custom_minimum_size = Vector2(0, 360)
	board_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(board_row)

	var pitcher_box: VBoxContainer = VBoxContainer.new()
	pitcher_box.custom_minimum_size = Vector2(520, 0)
	pitcher_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pitcher_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pitcher_box.add_theme_constant_override("separation", 4)
	board_row.add_child(pitcher_box)

	var pitcher_title: Label = Label.new()
	pitcher_title.text = "投手"
	pitcher_box.add_child(pitcher_title)

	draft_pitcher_list = SortableTable.new()
	draft_pitcher_list.add_theme_font_size_override("font_size", 14)
	pitcher_box.add_child(draft_pitcher_list)
	draft_pitcher_list.configure(PITCHER_CANDIDATE_COLUMNS)
	draft_pitcher_list.set_default_sort(0, true)
	draft_pitcher_list.item_selected.connect(func() -> void: _on_candidate_selected(draft_pitcher_list, draft_fielder_list))

	var fielder_box: VBoxContainer = VBoxContainer.new()
	fielder_box.custom_minimum_size = Vector2(520, 0)
	fielder_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fielder_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fielder_box.add_theme_constant_override("separation", 4)
	board_row.add_child(fielder_box)

	var fielder_title: Label = Label.new()
	fielder_title.text = "野手"
	fielder_box.add_child(fielder_title)

	draft_fielder_list = SortableTable.new()
	draft_fielder_list.add_theme_font_size_override("font_size", 14)
	fielder_box.add_child(draft_fielder_list)
	draft_fielder_list.configure(CANDIDATE_COLUMNS)
	draft_fielder_list.set_default_sort(0, true)
	draft_fielder_list.item_selected.connect(func() -> void: _on_candidate_selected(draft_fielder_list, draft_pitcher_list))

	var lower_row: HBoxContainer = HBoxContainer.new()
	lower_row.add_theme_constant_override("separation", 8)
	lower_row.custom_minimum_size = Vector2(0, 260)
	lower_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lower_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(lower_row)

	var detail_box: VBoxContainer = VBoxContainer.new()
	detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_theme_constant_override("separation", 4)
	lower_row.add_child(detail_box)

	var detail_title: Label = Label.new()
	detail_title.text = "候補詳細"
	detail_title.add_theme_font_size_override("font_size", 16)
	detail_box.add_child(detail_title)

	draft_detail_text = RichTextLabel.new()
	draft_detail_text.bbcode_enabled = false
	draft_detail_text.custom_minimum_size = Vector2(620, 0)
	draft_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	draft_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(draft_detail_text)

	var pick_box: VBoxContainer = VBoxContainer.new()
	pick_box.custom_minimum_size = Vector2(560, 0)
	pick_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pick_box.add_theme_constant_override("separation", 4)
	lower_row.add_child(pick_box)

	var pick_title: Label = Label.new()
	pick_title.text = "指名履歴 / 抽選"
	pick_title.add_theme_font_size_override("font_size", 16)
	pick_box.add_child(pick_title)

	draft_lottery_text = RichTextLabel.new()
	draft_lottery_text.bbcode_enabled = false
	draft_lottery_text.fit_content = true
	draft_lottery_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick_box.add_child(draft_lottery_text)

	draft_pick_list = SortableTable.new()
	draft_pick_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pick_box.add_child(draft_pick_list)
	draft_pick_list.configure(PICK_COLUMNS, false)

	return panel


func _build_released_market_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var control_row: HBoxContainer = HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	panel.add_child(control_row)

	released_market_status_label = Label.new()
	released_market_status_label.add_theme_font_size_override("font_size", 16)
	released_market_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(released_market_status_label)

	released_market_submit_button = Button.new()
	released_market_submit_button.text = "獲得する"
	released_market_submit_button.custom_minimum_size = Vector2(110, 32)
	released_market_submit_button.pressed.connect(_on_released_submit_pressed)
	control_row.add_child(released_market_submit_button)

	released_market_skip_button = Button.new()
	released_market_skip_button.text = "見送る"
	released_market_skip_button.custom_minimum_size = Vector2(100, 32)
	released_market_skip_button.pressed.connect(_on_released_skip_pressed)
	control_row.add_child(released_market_skip_button)

	released_market_auto_button = Button.new()
	released_market_auto_button.text = "この判断を自動"
	released_market_auto_button.custom_minimum_size = Vector2(140, 32)
	released_market_auto_button.pressed.connect(_on_released_auto_pressed)
	control_row.add_child(released_market_auto_button)

	released_market_auto_all_button = Button.new()
	released_market_auto_all_button.text = "残りを自動進行"
	released_market_auto_all_button.custom_minimum_size = Vector2(150, 32)
	released_market_auto_all_button.pressed.connect(_on_released_auto_all_pressed)
	control_row.add_child(released_market_auto_all_button)

	var body_row: HBoxContainer = HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 8)
	body_row.custom_minimum_size = Vector2(0, 460)
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(body_row)

	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.custom_minimum_size = Vector2(760, 0)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(list_box)

	var title: Label = Label.new()
	title.text = "自由契約候補"
	title.add_theme_font_size_override("font_size", 16)
	list_box.add_child(title)

	released_market_candidate_list = SortableTable.new()
	released_market_candidate_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_box.add_child(released_market_candidate_list)
	released_market_candidate_list.configure(RELEASED_CANDIDATE_COLUMNS)
	released_market_candidate_list.item_selected.connect(_on_released_candidate_selected)

	var detail_box: VBoxContainer = VBoxContainer.new()
	detail_box.custom_minimum_size = Vector2(460, 0)
	detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(detail_box)

	var detail_title: Label = Label.new()
	detail_title.text = "候補詳細"
	detail_title.add_theme_font_size_override("font_size", 16)
	detail_box.add_child(detail_title)

	released_market_detail_text = RichTextLabel.new()
	released_market_detail_text.bbcode_enabled = false
	released_market_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	released_market_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(released_market_detail_text)
	return panel


func _build_fa_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var control_row: HBoxContainer = HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	panel.add_child(control_row)

	fa_status_label = Label.new()
	fa_status_label.add_theme_font_size_override("font_size", 16)
	fa_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(fa_status_label)

	fa_submit_button = Button.new()
	fa_submit_button.text = "交渉する"
	fa_submit_button.custom_minimum_size = Vector2(110, 32)
	fa_submit_button.pressed.connect(_on_fa_submit_pressed)
	control_row.add_child(fa_submit_button)

	fa_skip_button = Button.new()
	fa_skip_button.text = "見送る"
	fa_skip_button.custom_minimum_size = Vector2(100, 32)
	fa_skip_button.pressed.connect(_on_fa_skip_pressed)
	control_row.add_child(fa_skip_button)

	fa_auto_button = Button.new()
	fa_auto_button.text = "この判断を自動"
	fa_auto_button.custom_minimum_size = Vector2(140, 32)
	fa_auto_button.pressed.connect(_on_fa_auto_pressed)
	control_row.add_child(fa_auto_button)

	fa_auto_all_button = Button.new()
	fa_auto_all_button.text = "残りを自動進行"
	fa_auto_all_button.custom_minimum_size = Vector2(150, 32)
	fa_auto_all_button.pressed.connect(_on_fa_auto_all_pressed)
	control_row.add_child(fa_auto_all_button)

	var body_row: HBoxContainer = HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 8)
	body_row.custom_minimum_size = Vector2(0, 460)
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(body_row)

	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.custom_minimum_size = Vector2(760, 0)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(list_box)

	var title: Label = Label.new()
	title.text = "FA候補"
	title.add_theme_font_size_override("font_size", 16)
	list_box.add_child(title)

	fa_candidate_list = SortableTable.new()
	fa_candidate_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_box.add_child(fa_candidate_list)
	fa_candidate_list.configure(FA_CANDIDATE_COLUMNS)
	fa_candidate_list.item_selected.connect(_on_fa_candidate_selected)

	var detail_box: VBoxContainer = VBoxContainer.new()
	detail_box.custom_minimum_size = Vector2(460, 0)
	detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(detail_box)

	var detail_title: Label = Label.new()
	detail_title.text = "候補詳細"
	detail_title.add_theme_font_size_override("font_size", 16)
	detail_box.add_child(detail_title)

	fa_detail_text = RichTextLabel.new()
	fa_detail_text.bbcode_enabled = false
	fa_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fa_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(fa_detail_text)
	return panel


func _build_foreign_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var control_row: HBoxContainer = HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	panel.add_child(control_row)

	foreign_status_label = Label.new()
	foreign_status_label.add_theme_font_size_override("font_size", 16)
	foreign_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(foreign_status_label)

	foreign_submit_button = Button.new()
	foreign_submit_button.text = "獲得する"
	foreign_submit_button.custom_minimum_size = Vector2(110, 32)
	foreign_submit_button.pressed.connect(_on_foreign_submit_pressed)
	control_row.add_child(foreign_submit_button)

	foreign_skip_button = Button.new()
	foreign_skip_button.text = "見送る"
	foreign_skip_button.custom_minimum_size = Vector2(100, 32)
	foreign_skip_button.pressed.connect(_on_foreign_skip_pressed)
	control_row.add_child(foreign_skip_button)

	foreign_auto_button = Button.new()
	foreign_auto_button.text = "この判断を自動"
	foreign_auto_button.custom_minimum_size = Vector2(140, 32)
	foreign_auto_button.pressed.connect(_on_foreign_auto_pressed)
	control_row.add_child(foreign_auto_button)

	foreign_auto_all_button = Button.new()
	foreign_auto_all_button.text = "残りを自動進行"
	foreign_auto_all_button.custom_minimum_size = Vector2(150, 32)
	foreign_auto_all_button.pressed.connect(_on_foreign_auto_all_pressed)
	control_row.add_child(foreign_auto_all_button)

	var body_row: HBoxContainer = HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 8)
	body_row.custom_minimum_size = Vector2(0, 460)
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(body_row)

	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.custom_minimum_size = Vector2(720, 0)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(list_box)

	var title: Label = Label.new()
	title.text = "外国人候補"
	title.add_theme_font_size_override("font_size", 16)
	list_box.add_child(title)

	foreign_candidate_list = SortableTable.new()
	foreign_candidate_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_box.add_child(foreign_candidate_list)
	foreign_candidate_list.configure(FOREIGN_CANDIDATE_COLUMNS)
	foreign_candidate_list.item_selected.connect(_on_foreign_candidate_selected)

	var detail_box: VBoxContainer = VBoxContainer.new()
	detail_box.custom_minimum_size = Vector2(460, 0)
	detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(detail_box)

	var detail_title: Label = Label.new()
	detail_title.text = "候補詳細"
	detail_title.add_theme_font_size_override("font_size", 16)
	detail_box.add_child(detail_title)

	foreign_detail_text = RichTextLabel.new()
	foreign_detail_text.bbcode_enabled = false
	foreign_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foreign_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(foreign_detail_text)
	return panel


func _build_camp_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 8)

	var control_row: HBoxContainer = HBoxContainer.new()
	control_row.add_theme_constant_override("separation", 8)
	panel.add_child(control_row)

	camp_status_label = Label.new()
	camp_status_label.add_theme_font_size_override("font_size", 16)
	camp_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control_row.add_child(camp_status_label)

	camp_submit_button = Button.new()
	camp_submit_button.text = "実行"
	camp_submit_button.custom_minimum_size = Vector2(100, 32)
	camp_submit_button.pressed.connect(_on_camp_submit_pressed)
	control_row.add_child(camp_submit_button)

	camp_auto_button = Button.new()
	camp_auto_button.text = "自軍をAIに任せる"
	camp_auto_button.custom_minimum_size = Vector2(160, 32)
	camp_auto_button.pressed.connect(_on_camp_auto_pressed)
	control_row.add_child(camp_auto_button)

	camp_finish_button = Button.new()
	camp_finish_button.text = "キャンプ終了"
	camp_finish_button.custom_minimum_size = Vector2(130, 32)
	camp_finish_button.pressed.connect(_on_camp_finish_pressed)
	control_row.add_child(camp_finish_button)

	var body_row: HBoxContainer = HBoxContainer.new()
	body_row.add_theme_constant_override("separation", 8)
	body_row.custom_minimum_size = Vector2(0, 460)
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(body_row)

	var list_box: VBoxContainer = VBoxContainer.new()
	list_box.custom_minimum_size = Vector2(560, 0)
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(list_box)

	var title: Label = Label.new()
	title.text = "選手一覧"
	title.add_theme_font_size_override("font_size", 16)
	list_box.add_child(title)

	camp_player_list = SortableTable.new()
	camp_player_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_box.add_child(camp_player_list)
	camp_player_list.configure(CAMP_ROSTER_COLUMNS)
	camp_player_list.set_default_sort(4, false)
	camp_player_list.item_selected.connect(_on_camp_player_selected)

	var detail_box: VBoxContainer = VBoxContainer.new()
	detail_box.custom_minimum_size = Vector2(460, 0)
	detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_child(detail_box)

	var detail_title: Label = Label.new()
	detail_title.text = "特別練習"
	detail_title.add_theme_font_size_override("font_size", 16)
	detail_box.add_child(detail_title)

	var training_row: HBoxContainer = HBoxContainer.new()
	training_row.add_theme_constant_override("separation", 8)
	detail_box.add_child(training_row)

	camp_training_select = OptionButton.new()
	camp_training_select.custom_minimum_size = Vector2(190, 32)
	camp_training_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camp_training_select.item_selected.connect(_on_camp_training_selected)
	training_row.add_child(camp_training_select)

	camp_position_select = OptionButton.new()
	camp_position_select.custom_minimum_size = Vector2(150, 32)
	camp_position_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camp_position_select.item_selected.connect(_on_camp_target_selected)
	training_row.add_child(camp_position_select)

	camp_detail_text = RichTextLabel.new()
	camp_detail_text.bbcode_enabled = false
	camp_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camp_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_box.add_child(camp_detail_text)
	return panel


func _refresh() -> void:
	var step: int = AppState.offseason_step
	step_indicator.text = "ステップ%d / %d" % [step + 1, TOTAL_STEPS + 1]

	if not AppState.offseason_active:
		status_label.text = "オフシーズンが開始されていません"
		release_panel.visible = false
		draft_panel.visible = false
		released_market_panel.visible = false
		fa_panel.visible = false
		foreign_panel.visible = false
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		return

	if step == 1:
		# Release editor mode (step 1 = 戦力外通告エディタ)
		release_panel.visible = true
		draft_panel.visible = false
		released_market_panel.visible = false
		fa_panel.visible = false
		foreign_panel.visible = false
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		_populate_release_list()
		_refresh_release_summary()
		status_label.text = "戦力外通告(編集)"
		return

	if (step == 3 or step == 4) and not AppState.draft_state.is_empty() and not bool(AppState.draft_state.get("complete", false)):
		release_panel.visible = false
		draft_panel.visible = true
		released_market_panel.visible = false
		fa_panel.visible = false
		foreign_panel.visible = false
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		status_label.text = "育成指名" if step == 4 else "本指名"
		_populate_draft_panel()
		return

	if step == 5 and not AppState.released_market_state.is_empty() and not bool(AppState.released_market_state.get("complete", false)):
		release_panel.visible = false
		draft_panel.visible = false
		released_market_panel.visible = true
		fa_panel.visible = false
		foreign_panel.visible = false
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		status_label.text = "戦力外獲得"
		_populate_released_market_panel()
		return

	if step == 6 and not AppState.fa_state.is_empty() and not bool(AppState.fa_state.get("complete", false)):
		release_panel.visible = false
		draft_panel.visible = false
		released_market_panel.visible = false
		fa_panel.visible = true
		foreign_panel.visible = false
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		status_label.text = "FA市場"
		_populate_fa_panel()
		return

	if step == 7 and not AppState.foreign_state.is_empty() and not bool(AppState.foreign_state.get("complete", false)):
		release_panel.visible = false
		draft_panel.visible = false
		released_market_panel.visible = false
		fa_panel.visible = false
		foreign_panel.visible = true
		camp_panel.visible = false
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		status_label.text = "外国人補強"
		_populate_foreign_panel()
		return

	if step == 8 and not AppState.camp_state.is_empty() and not bool(AppState.camp_state.get("complete", false)):
		release_panel.visible = false
		draft_panel.visible = false
		released_market_panel.visible = false
		fa_panel.visible = false
		foreign_panel.visible = false
		camp_panel.visible = true
		_clear_content()
		next_button.disabled = true
		finalize_button.disabled = true
		status_label.text = "キャンプ"
		_populate_camp_panel()
		return

	release_panel.visible = false
	draft_panel.visible = false
	released_market_panel.visible = false
	fa_panel.visible = false
	foreign_panel.visible = false
	camp_panel.visible = false
	next_button.disabled = step >= TOTAL_STEPS
	finalize_button.disabled = step < TOTAL_STEPS

	var step_key: String = "step_%d" % step
	var result: Dictionary = AppState.offseason_results.get(step_key, {}) as Dictionary
	if result.is_empty():
		_set_content_message("結果データがありません")
		return

	status_label.text = str(result.get("title", ""))
	_render_step_content(step, result)


# ---------------------------------------------------------------------------
# 共通: content_box (ステップ結果表示)
# ---------------------------------------------------------------------------

func _clear_content() -> void:
	if content_box == null:
		return
	for child in content_box.get_children():
		content_box.remove_child(child)
		child.queue_free()


func _set_content_message(text: String) -> void:
	_clear_content()
	var label: Label = Label.new()
	label.text = text
	content_box.add_child(label)


func _add_content_heading(text: String, font_size: int = 16) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	content_box.add_child(label)


func _add_content_table(columns: Array, rows: Array, min_height: int) -> void:
	var table: Tree = SortableTable.new()
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	table.custom_minimum_size = Vector2(0, min_height)
	content_box.add_child(table)
	table.configure(columns)
	table.set_rows(rows)


func _render_step_content(step: int, result: Dictionary) -> void:
	_clear_content()
	match step:
		0:
			_render_people("引退した選手", result, "retired", "今オフは引退者がいませんでした。")
		2:
			_render_release(result)
		3:
			if result.has("draft_picks"):
				_render_draft_result(result)
			else:
				_render_rookies(result)
		4:
			_render_draft_result(result)
		5:
			_render_released_market(result)
		6:
			_render_fa_market(result)
		7:
			_render_foreign_market(result)
		8:
			_render_camp(result)
		9:
			_render_growth(result)
		10:
			_render_contract_update(result)
		_:
			pass


func _render_people(title_text: String, result: Dictionary, key: String, empty_text: String) -> void:
	var people: Array = result.get(key, []) as Array
	_add_content_heading("%s %d人" % [title_text, people.size()], 18)
	if people.is_empty():
		_set_content_message_after("%s\n%s" % [title_text, empty_text])
		return
	_add_content_table(PEOPLE_COLUMNS, _people_rows(people), 360)


func _set_content_message_after(text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	content_box.add_child(label)


func _people_rows(people: Array) -> Array:
	var rows: Array = []
	for entry_row in people:
		var entry: Dictionary = entry_row as Dictionary
		rows.append({
			"team": _team_short(int(entry.get("team_id", 0))),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"pos": _dict_role_or_position(entry),
			"years": int(entry.get("years", 0)),
			"overall": int(entry.get("overall", 0)),
		})
	return rows


func _render_release(result: Dictionary) -> void:
	var released: Array = result.get("released", []) as Array
	var user_n: int = int(result.get("user_released_count", -1))
	var cpu_n: int = int(result.get("cpu_released_count", -1))
	var foreign_n: int = int(result.get("foreign_released_count", 0))
	if user_n >= 0 and cpu_n >= 0:
		_add_content_heading("戦力外通告: %d人 (自軍%d人 / 他球団 %d人 / 外国人 %d人)" % [released.size(), user_n, cpu_n, foreign_n], 18)
	else:
		_add_content_heading("戦力外通告: %d人" % released.size(), 18)
	if released.is_empty():
		_set_content_message_after("今オフは戦力外通告がありませんでした。")
	else:
		_add_content_table(PEOPLE_COLUMNS, _people_rows(released), 360)

	# roadmap #3: 育成降格 (release ではなく育成化) の結果を続けて表示。
	var demoted: Array = result.get("demoted", []) as Array
	if not demoted.is_empty():
		var user_d: int = int(result.get("user_demoted_count", 0))
		var cpu_d: int = int(result.get("cpu_demoted_count", 0))
		_add_content_heading("育成降格: %d人 (自軍%d人 / 他球団 %d人)" % [demoted.size(), user_d, cpu_d], 18)
		_add_content_table(PEOPLE_COLUMNS, _people_rows(demoted), 240)


func _render_rookies(result: Dictionary) -> void:
	var rookies: Array = result.get("rookies", []) as Array
	_add_content_heading("新人補強: %d人" % rookies.size(), 18)
	if rookies.is_empty():
		_set_content_message_after("補強の候補がありませんでした。")
		return
	var rows: Array = []
	for entry_row in rookies:
		var entry: Dictionary = entry_row as Dictionary
		rows.append({
			"team": _team_short(int(entry.get("team_id", 0))),
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"pos": _dict_role_or_position(entry),
			"overall": int(entry.get("overall", 0)),
		})
	_add_content_table(ROOKIE_COLUMNS, rows, 360)


func _render_released_market(result: Dictionary) -> void:
	var candidates_count: int = int(result.get("candidates_count", 0))
	var signed_count: int = int(result.get("signed_count", 0))
	var remaining_count: int = int(result.get("remaining_count", 0))
	_add_content_heading("戦力外獲得: 候補 %d人 / 獲得 %d人 / 未獲得 %d人" % [
		candidates_count, signed_count, remaining_count,
	], 18)
	var signings: Array = result.get("signings", []) as Array
	if signings.is_empty():
		_set_content_message_after("今オフは戦力外からの獲得がありませんでした。")
		return
	var rows: Array = []
	for s_row in signings:
		var s: Dictionary = s_row as Dictionary
		rows.append({
			"from": _team_short(int(s.get("from_team", 0))),
			"arrow": "→",
			"to": _team_short(int(s.get("to_team", 0))),
			"name": str(s.get("name", "")),
			"rank": str(s.get("fa_rank", "C")),
			"age": int(s.get("age", 0)),
			"pos": _dict_role_or_position(s),
			"salary": int(s.get("offer_salary", s.get("salary", 0))),
			"compensation": int(s.get("compensation_money", 0)),
		})
	_add_content_table(RELEASED_MOVE_COLUMNS, rows, 360)


# R4 Step2: FA市場ステップ (自由契約宣言 + 移籍)。
func _render_fa_market(result: Dictionary) -> void:
	var declared_count: int = int(result.get("declared_count", 0))
	var moved_count: int = int(result.get("moved_count", 0))
	var returned_count: int = int(result.get("returned_count", 0))
	_add_content_heading("FA市場: 宣言 %d人 / 移籍 %d人 / 残留 %d人" % [
		declared_count, moved_count, returned_count,
	], 18)
	var signings: Array = result.get("signings", []) as Array
	if signings.is_empty():
		_set_content_message_after("今オフは FA 移籍が成立しませんでした。")
		return
	var rows: Array = []
	for s_row in signings:
		var s: Dictionary = s_row as Dictionary
		rows.append({
			"from": _team_short(int(s.get("from_team", 0))),
			"arrow": "→",
			"to": _team_short(int(s.get("to_team", 0))),
			"name": str(s.get("name", "")),
			"age": int(s.get("age", 0)),
			"pos": _dict_role_or_position(s),
			"salary": int(s.get("salary", 0)),
		})
	_add_content_heading("FA移籍 %d件" % signings.size(), 16)
	_add_content_table(FA_MOVE_COLUMNS, rows, 360)


const FOREIGN_TIER_LABELS: Dictionary = {
	"ace": "A (即戦力)", "good": "B (主力級)", "average": "C (平均)", "bust": "D (未知数)",
}

# R4 Step3: 外国人補強ステップ。
func _render_foreign_market(result: Dictionary) -> void:
	var candidates_count: int = int(result.get("candidates_count", 0))
	var signed_count: int = int(result.get("signed_count", 0))
	_add_content_heading("外国人補強: 候補 %d人 / 獲得 %d人" % [candidates_count, signed_count], 18)
	var signings: Array = result.get("signings", []) as Array
	if signings.is_empty():
		_set_content_message_after("今オフは外国人の獲得がありませんでした。")
		return
	var rows: Array = []
	for s_row in signings:
		var s: Dictionary = s_row as Dictionary
		rows.append({
			"to": _team_short(int(s.get("to_team", 0))),
			"name": str(s.get("name", "")),
			"age": int(s.get("age", 0)),
			"pos": _dict_role_or_position(s),
			"tier": str(FOREIGN_TIER_LABELS.get(str(s.get("tier", "")), str(s.get("tier", "")))),
			"salary": int(s.get("salary", 0)),
		})
	_add_content_heading("外国人獲得 %d人" % signings.size(), 16)
	_add_content_table(FOREIGN_COLUMNS, rows, 360)


func _render_camp(result: Dictionary) -> void:
	var actions_count: int = int(result.get("actions_count", 0))
	var success_count: int = int(result.get("success_count", 0))
	var pitch_count: int = int(result.get("normal_pitch_learning_count", 0))
	_add_content_heading("キャンプ: 特別練習 %d件 / 成功 %d件 / 通常キャンプ球種習得 %d人" % [
		actions_count, success_count, pitch_count,
	], 18)
	var actions: Array = result.get("actions", []) as Array
	if actions.is_empty():
		_set_content_message_after("今オフは特別練習がありませんでした。")
	else:
		var rows: Array = []
		for action_row in actions:
			var action: Dictionary = action_row as Dictionary
			rows.append({
				"team": _team_short(int(action.get("team_id", 0))),
				"name": str(action.get("name", "")),
				"training": str(action.get("training_label", "")),
				"result": "成功" if bool(action.get("success", false)) else ("失敗*" if bool(action.get("penalty", false)) else "失敗"),
				"target": _camp_action_target(action),
				"change": _camp_action_change(action),
				"overall": "%d→%d" % [int(action.get("before", 0)), int(action.get("after", 0))],
			})
		_add_content_table(CAMP_RESULT_COLUMNS, rows, 360)

	var pitch_learning: Array = result.get("normal_pitch_learning", []) as Array
	if not pitch_learning.is_empty():
		var pitch_rows: Array = []
		for pitch_row in pitch_learning:
			var pitch: Dictionary = pitch_row as Dictionary
			pitch_rows.append({
				"team": _team_short(int(pitch.get("team_id", 0))),
				"name": str(pitch.get("name", "")),
				"age": int(pitch.get("age", 0)),
				"pitch": str(pitch.get("pitch_name", "")),
				"grade": str(pitch.get("mastery_grade", "")),
			})
		_add_content_heading("通常キャンプでの変化球習得", 16)
		_add_content_table(CAMP_PITCH_COLUMNS, pitch_rows, 220)


func _camp_action_target(action: Dictionary) -> String:
	var target_position: int = int(action.get("target_position", 0))
	if target_position > 0:
		return _position_name(target_position)
	var new_role: String = str(action.get("new_role", ""))
	if new_role == "starter":
		return "先発"
	if new_role == "reliever":
		return "中継"
	return ""


func _camp_action_change(action: Dictionary) -> String:
	var target_position: int = int(action.get("target_position", 0))
	if target_position > 0:
		var apt_before: int = int(action.get("aptitude_before", 0))
		var apt_after: int = int(action.get("aptitude_after", 0))
		var old_pos: int = int(action.get("old_position", 0))
		var new_pos: int = int(action.get("new_position", 0))
		if old_pos != new_pos:
			return "%s→%s / 適性%d→%d" % [_position_name(old_pos), _position_name(new_pos), apt_before, apt_after]
		return "適性%d→%d" % [apt_before, apt_after]
	var old_role: String = str(action.get("old_role", ""))
	var new_role: String = str(action.get("new_role", ""))
	if old_role != new_role:
		return "%s→%s" % [_role_label(old_role), _role_label(new_role)]
	return _role_label(new_role)


func _role_label(role: String) -> String:
	match role:
		"starter":
			return "先発"
		"reliever":
			return "中継"
		"closer":
			return "抑え"
		_:
			return role


# R4 Step1: 契約更新ステップ (年俸再査定 + FA権遷移 + 予算会計)。
func _render_contract_update(result: Dictionary) -> void:
	var raises_count: int = int(result.get("raises_count", 0))
	var cuts_count: int = int(result.get("cuts_count", 0))
	var new_fa_count: int = int(result.get("new_fa_count", 0))
	var over_budget_count: int = int(result.get("over_budget_count", 0))
	_add_content_heading("契約更新: 昇給 %d人 / 減給 %d人 / 新規FA権 %d人 / 予算超過 %d球団" % [
		raises_count, cuts_count, new_fa_count, over_budget_count,
	], 18)

	# チーム予算会計 (全球団)。
	var budgets: Array = result.get("team_budgets", []) as Array
	if not budgets.is_empty():
		var budget_rows: Array = []
		for b_row in budgets:
			var b: Dictionary = b_row as Dictionary
			budget_rows.append({
				"team": _team_short(int(b.get("team_id", 0))),
				"funds": int(b.get("funds", 0)),
				"payroll": int(b.get("payroll", 0)),
				"room": int(b.get("room", 0)),
				"state": "超過" if bool(b.get("over_budget", false)) else "OK",
			})
		_add_content_heading("チーム予算 (万円)", 16)
		_add_content_table(BUDGET_COLUMNS, budget_rows, 320)

	# 新規 FA権取得者。
	var new_fa: Array = result.get("new_fa", []) as Array
	if not new_fa.is_empty():
		var fa_rows: Array = []
		for fa_row in new_fa:
			var fa: Dictionary = fa_row as Dictionary
			fa_rows.append({
				"team": _team_short(int(fa.get("team_id", 0))),
				"name": str(fa.get("name", "")),
				"age": int(fa.get("age", 0)),
				"pos": _dict_role_or_position(fa),
				"years": int(fa.get("years", 0)),
				"fa_days": int(fa.get("fa_nissuu", 0)),
				"fa_required": int(fa.get("fa_eligible_years", 0)) * PSPlayer.FA_SERVICE_DAYS_PER_YEAR,
			})
		_add_content_heading("新規FA権取得 %d人" % new_fa.size(), 16)
		_add_content_table(FA_COLUMNS, fa_rows, 240)

	# 年俸の主な増減 (昇給上位 + 減給上位)。
	var salary_changes: Array = []
	salary_changes.append_array(result.get("raises", []) as Array)
	salary_changes.append_array(result.get("cuts", []) as Array)
	if not salary_changes.is_empty():
		var salary_rows: Array = []
		for s_row in salary_changes:
			var s: Dictionary = s_row as Dictionary
			salary_rows.append({
				"team": _team_short(int(s.get("team_id", 0))),
				"name": str(s.get("name", "")),
				"age": int(s.get("age", 0)),
				"pos": _dict_role_or_position(s),
				"old": int(s.get("old_salary", 0)),
				"new": int(s.get("new_salary", 0)),
				"delta": int(s.get("delta", 0)),
			})
		_add_content_heading("主な年俸増減 (万円)", 16)
		_add_content_table(SALARY_COLUMNS, salary_rows, 280)


func _render_growth(result: Dictionary) -> void:
	# 自球団のみ。投手 (左) / 野手 (右) を左右に並べ、総合と表示能力の変化を一覧する。
	var team_name: String = ""
	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	if team != null:
		team_name = team.short_name
	_add_content_heading("%s の成長 %d人 / 衰え %d人" % [
		team_name,
		int(result.get("growers_count", 0)),
		int(result.get("decayers_count", 0)),
	], 18)
	var kind_counts: Dictionary = result.get("growth_kind_counts", {}) as Dictionary
	if not kind_counts.is_empty():
		var kc: Label = Label.new()
		kc.text = "覚醒 %d  成長 %d  停滞 %d  劣化 %d  大幅劣化 %d" % [
			int(kind_counts.get("awakening", 0)),
			int(kind_counts.get("growth", 0)),
			int(kind_counts.get("stagnation", 0)),
			int(kind_counts.get("decline", 0)),
			int(kind_counts.get("major_decline", 0)),
		]
		kc.add_theme_color_override("font_color", Color(0.78, 0.86, 0.92))
		content_box.add_child(kc)

	var pitchers: Array = result.get("pitchers", []) as Array
	var fielders: Array = result.get("fielders", []) as Array

	var split_row: HBoxContainer = HBoxContainer.new()
	split_row.add_theme_constant_override("separation", 8)
	split_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 見出しの下の余白を使い切るよう、ビューポート高からヘッダ等を差し引いた高さまで縦に伸ばす。
	var avail_height: float = get_viewport_rect().size.y - 190.0
	split_row.custom_minimum_size = Vector2(0, max(480.0, avail_height))
	content_box.add_child(split_row)

	split_row.add_child(_build_growth_column("投手 %d人" % pitchers.size(), PITCHER_GROWTH_COLUMNS, _growth_rows(pitchers)))
	split_row.add_child(_build_growth_column("野手 %d人" % fielders.size(), FIELDER_GROWTH_COLUMNS, _growth_rows(fielders)))


# 見出し付きの成長テーブル列 (VBox) を組んで返す。
func _build_growth_column(title_text: String, columns: Array, rows: Array) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)

	var title: Label = Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)

	var table: Tree = SortableTable.new()
	table.add_theme_font_size_override("font_size", 14)
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(table)
	table.configure(columns)
	table.set_rows(rows)
	return box


func _growth_rows(entries: Array) -> Array:
	var rows: Array = []
	for entry_row in entries:
		var entry: Dictionary = entry_row as Dictionary
		var after: int = int(entry.get("after", 0))
		var delta: int = int(entry.get("delta", 0))
		var row: Dictionary = {
			"name": str(entry.get("name", "")),
			"age": int(entry.get("age", 0)),
			"kind": str(entry.get("growth_label", "")),
			# 総合も表示能力と同じ "変化後(+増減)" 形式に統合。sort_key=delta で数値ソート可。
			"overall_cell": _ability_change_cell(after, delta, ""),
			"delta": delta,
		}
		# 表示能力セル ("66(+6)") を能力キーごとに割り当てる。列キーと rating キーは一致。
		for ability_row in entry.get("abilities", []) as Array:
			var ability: Dictionary = ability_row as Dictionary
			row[str(ability.get("key", ""))] = _ability_change_cell(
				int(ability.get("after", 0)),
				int(ability.get("delta", 0)),
				str(ability.get("suffix", "")),
			)
		rows.append(row)
	return rows


# 表示能力 1 項目を "66(+6)" 形式に整形する。変化 0 のときは括弧なしで値のみ。
func _ability_change_cell(after: int, delta: int, suffix: String) -> String:
	if delta == 0:
		return "%d%s" % [after, suffix]
	return "%d%s(%+d)" % [after, suffix, delta]


func _render_draft_result(result: Dictionary) -> void:
	var picks: Array = result.get("draft_picks", []) as Array
	var rookies: Array = result.get("rookies", []) as Array
	var title_text: String = str(result.get("title", "ドラフト"))
	_add_content_heading("%s終了 指名%d人 / 入団%d人" % [title_text, picks.size(), rookies.size()], 18)
	var league_label: Label = Label.new()
	league_label.text = "同順位優先リーグ: %s" % _league_label(str(result.get("priority_league", "")))
	league_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.92))
	content_box.add_child(league_label)

	var logs: Array = result.get("logs", []) as Array
	var lottery_lines: Array = []
	for log_row in logs:
		var log: Dictionary = log_row as Dictionary
		if str(log.get("type", "")) == "lottery":
			lottery_lines.append(_format_lottery_log(log))
	if not lottery_lines.is_empty():
		_add_content_heading("1巡目 抽選", 16)
		var lottery: RichTextLabel = RichTextLabel.new()
		lottery.bbcode_enabled = false
		lottery.fit_content = true
		lottery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lottery.text = "\n".join(lottery_lines)
		content_box.add_child(lottery)

	# 球団ごとに表を分け、各表は指名順 (overall_pick 昇順) で並べる。
	var picks_by_team: Dictionary = {}
	for pick_row in picks:
		var pick: Dictionary = pick_row as Dictionary
		var team_id: int = int(pick.get("team_id", 0))
		if not picks_by_team.has(team_id):
			picks_by_team[team_id] = []
		(picks_by_team[team_id] as Array).append(pick)

	# 6列x2行のグリッド: 上段=第1リーグ(セ)、下段=第2リーグ(パ)。各リーグ内は球団ID順。
	for league in ["central", "pacific"]:
		content_box.add_child(_build_league_result_row(league, picks_by_team))


# 1リーグ分の球団表を横6列で並べた行 (HBox) を返す。
func _build_league_result_row(league: String, picks_by_team: Dictionary) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for team in _league_team_ids(league):
		var team_picks: Array = (picks_by_team.get(team, []) as Array).duplicate()
		team_picks.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary).get("overall_pick", 0)) < int((b as Dictionary).get("overall_pick", 0))
		)
		row.add_child(_build_team_result_cell(int(team), team_picks))
	return row


# 1球団分のセル (見出し + コンパクト表) を返す。
func _build_team_result_cell(team_id: int, team_picks: Array) -> VBoxContainer:
	var cell: VBoxContainer = VBoxContainer.new()
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.custom_minimum_size = Vector2(224, 0)
	cell.add_theme_constant_override("separation", 2)

	var heading: Label = Label.new()
	heading.text = "%s  %d人" % [_team_short(team_id), team_picks.size()]
	heading.add_theme_font_size_override("font_size", 14)
	cell.add_child(heading)

	var rows: Array = []
	for pick_row in team_picks:
		rows.append(_pick_row(pick_row as Dictionary))
	var table: Tree = SortableTable.new()
	table.add_theme_font_size_override("font_size", 13)
	table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	table.custom_minimum_size = Vector2(0, 332)
	cell.add_child(table)
	table.configure(DRAFT_RESULT_COLUMNS)
	table.set_rows(rows)
	return cell


# 指定リーグの球団 ID を ID 昇順で返す。
func _league_team_ids(league: String) -> Array:
	var ids: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null and team.league == league:
			ids.append(team.id)
	ids.sort()
	return ids


# ---------------------------------------------------------------------------
# ドラフトパネル
# ---------------------------------------------------------------------------

func _populate_draft_panel() -> void:
	var state: Dictionary = AppState.draft_state
	var stage: String = str(state.get("stage", ""))
	var round_no: int = int(state.get("round", 1))
	var first_round_wave: int = int(state.get("first_round_wave", 1))
	var current_team_id: int = int(state.get("current_team_id", AppState.selected_team_id))
	var team_text: String = _team_short(current_team_id)
	var is_dev_segment: bool = str(state.get("segment", "main")) == "development"
	var phase_label: String = "育成ドラフト" if is_dev_segment else "本指名"
	if stage == "first_round_bid":
		var bid_label: String = "1巡目 入札" if first_round_wave <= 1 else "1巡目 再入札%d回目" % first_round_wave
		draft_status_label.text = "%s %s: %s" % [phase_label, bid_label, _team_short(AppState.selected_team_id)]
		draft_submit_button.text = "入札する"
	elif stage == "user_pick":
		draft_status_label.text = "%s %d巡目 指名: %s" % [phase_label, round_no, team_text]
		draft_submit_button.text = "指名する"
	else:
		draft_status_label.text = phase_label
		draft_submit_button.text = "指名する"
	# 本指名では自軍だけ指名終了し、他球団の本指名完了後に育成ドラフトへ移行する。
	# 育成ドラフトでは自軍の育成指名を打ち切る。
	draft_skip_button.visible = stage == "user_pick"
	draft_skip_button.text = "育成指名終了" if is_dev_segment else "本指名終了"

	_suppress_candidate_select = true
	# limit=0 で残り全候補を表示する (打ち切りなし)。
	_populate_candidate_table(draft_pitcher_list, DraftService.available_candidates_for_bucket(state, "pitcher", 0), true)
	_populate_candidate_table(draft_fielder_list, DraftService.available_candidates_for_bucket(state, "fielder", 0), false)
	_update_draft_position_summary(state)
	if selected_draft_candidate_id > 0 and _draft_candidate_by_id(state, selected_draft_candidate_id).is_empty():
		selected_draft_candidate_id = 0
	if selected_draft_candidate_id <= 0:
		var first_pitcher: Variant = draft_pitcher_list.get_first_meta()
		if first_pitcher != null:
			selected_draft_candidate_id = int(first_pitcher)
		else:
			var first_fielder: Variant = draft_fielder_list.get_first_meta()
			if first_fielder != null:
				selected_draft_candidate_id = int(first_fielder)
	draft_pitcher_list.select_meta(selected_draft_candidate_id)
	draft_fielder_list.select_meta(selected_draft_candidate_id)
	_suppress_candidate_select = false
	draft_detail_text.text = _format_candidate_details(_draft_candidate_by_id(state, selected_draft_candidate_id))

	var lottery_lines: Array = []
	for log_row in state.get("logs", []) as Array:
		var log: Dictionary = log_row as Dictionary
		if str(log.get("type", "")) == "lottery":
			lottery_lines.append(_format_lottery_log(log))
	draft_lottery_text.text = "\n".join(lottery_lines)

	var rows: Array = []
	for pick_row in state.get("picks", []) as Array:
		rows.append(_pick_row(pick_row as Dictionary))
	draft_pick_list.set_rows(rows)


# 自球団の守備位置別の本職人数・守備可人数・主力 (その位置を守れる最強選手) 総合値を表示。
func _update_draft_position_summary(state: Dictionary) -> void:
	if draft_position_summary_label == null:
		return
	var profiles: Dictionary = state.get("team_profiles", {}) as Dictionary
	var profile: Dictionary = profiles.get(str(AppState.selected_team_id), {}) as Dictionary
	if profile.is_empty():
		draft_position_summary_label.text = ""
		return
	var primary: Dictionary = profile.get("position_primary_count", {}) as Dictionary
	var holders: Dictionary = profile.get("position_holders", {}) as Dictionary
	var top: Dictionary = profile.get("position_top_overall", {}) as Dictionary
	var parts: Array = []
	for pos in [2, 3, 4, 5, 6, 7, 8, 9]:
		var primary_count: int = _profile_count(primary, pos)
		var holder_count: int = _profile_count(holders, pos)
		var top_overall: int = _profile_count(top, pos)
		var overall_text: String = str(top_overall) if top_overall > 0 else "—"
		parts.append("%s 本職%d 守備可%d 主力%s" % [_position_char(pos), primary_count, holder_count, overall_text])
	draft_position_summary_label.text = "自球団 " + _team_short(AppState.selected_team_id) + " ：  " + "   ｜  ".join(parts)


# team_profiles の position 別 Dictionary から値を取得 (保存/復元で int キーが文字列化する場合に両対応)。
func _profile_count(source: Dictionary, pos: int) -> int:
	if source.has(pos):
		return int(source.get(pos, 0))
	return int(source.get(str(pos), 0))


func _populate_candidate_table(table: Tree, candidates: Array, show_pitcher_role: bool = false) -> void:
	var rows: Array = []
	for candidate_row in candidates:
		var candidate: Dictionary = candidate_row as Dictionary
		rows.append({
			"rank": int(candidate.get("bucket_rank", 0)),
			"name": str(candidate.get("name", "")),
			"age": int(candidate.get("age", 0)),
			"pos": _candidate_role_or_position(candidate, show_pitcher_role),
			"overall": int(candidate.get("overall", 0)),
			"source": _source_label(str(candidate.get("source_type", ""))),
			"__meta": int(candidate.get("candidate_id", 0)),
		})
	table.set_rows(rows)


func _candidate_role_or_position(candidate: Dictionary, show_pitcher_role: bool) -> String:
	var position: int = int(candidate.get("position", 0))
	if show_pitcher_role and position == 1:
		var template: Dictionary = candidate.get("player_template", {}) as Dictionary
		return _role_label(str(template.get("role", "starter")))
	return _position_name(position)


func _on_candidate_selected(active_list: Tree, other_list: Tree) -> void:
	if _suppress_candidate_select:
		return
	var meta: Variant = active_list.get_selected_meta()
	if meta == null:
		return
	selected_draft_candidate_id = int(meta)
	_suppress_candidate_select = true
	other_list.deselect_all()
	_suppress_candidate_select = false
	draft_detail_text.text = _format_candidate_details(_draft_candidate_by_id(AppState.draft_state, selected_draft_candidate_id))


func _pick_row(pick: Dictionary) -> Dictionary:
	return {
		"pick": int(pick.get("overall_pick", 0)),
		"round": int(pick.get("round", 0)),
		"team": _team_short(int(pick.get("team_id", 0))),
		"name": str(pick.get("name", "")),
		"age": int(pick.get("age", 0)),
		"pos": _dict_role_or_position_char(pick),
		"overall": int(pick.get("overall", 0)),
		"source": _source_label(str(pick.get("source_type", ""))),
		"note": _pick_note(pick),
	}


# 指名履歴の「抽選」列。育成ドラフト指名は「育」、本指名の抽選は「抽選」。
func _pick_note(pick: Dictionary) -> String:
	if bool(pick.get("development", false)):
		return "育"
	return "抽選" if bool(pick.get("lottery", false)) else ""


func _draft_candidate_by_id(state: Dictionary, candidate_id: int) -> Dictionary:
	for candidate_row in state.get("candidate_pool", []) as Array:
		var candidate: Dictionary = candidate_row as Dictionary
		if int(candidate.get("candidate_id", 0)) == candidate_id and not bool(candidate.get("picked", false)):
			return candidate
	return {}


func _format_candidate_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "候補を選択してください。"
	var template: Dictionary = candidate.get("player_template", {}) as Dictionary
	var aptitudes: Dictionary = template.get("position_aptitudes", {}) as Dictionary
	var pos: int = int(candidate.get("position", 0))
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _candidate_role_or_position(candidate, pos == 1)])
	lines.append("%d歳  %s  指名優先#%d" % [
		int(candidate.get("age", 0)),
		_source_label(str(candidate.get("source_type", ""))),
		int(candidate.get("bucket_rank", 0)),
	])
	lines.append("総合 %d  期待成長 %+0.1f  評価 %0.1f" % [
		int(candidate.get("overall", 0)),
		float(candidate.get("growth_expectation", 0.0)),
		float(candidate.get("bucket_grade", 0.0)),
	])
	lines.append("")
	var visible_template: Dictionary = template.duplicate(true)
	visible_template["position"] = pos
	if pos == 1:
		visible_template["role"] = str(template.get("role", "starter"))
	else:
		visible_template["role"] = "fielder"
	lines.append("能力")
	lines.append(PlayerVisibleRatings.summary_line_for_player_data(visible_template))
	if pos == 1:
		var arsenal_text: String = PSPitchTypes.arsenal_line(template.get("arsenal", []) as Array)
		if not arsenal_text.is_empty():
			lines.append("")
			lines.append("球種")
			lines.append(arsenal_text)
	else:
		lines.append("")
		lines.append("守備位置適性")
		lines.append(_aptitude_line(aptitudes))
	return "\n".join(lines)


func _aptitude_line(aptitudes: Dictionary) -> String:
	var parts: Array = []
	for key_value in ["catcher", "first", "second", "third", "shortstop", "left", "center", "right"]:
		var key: String = str(key_value)
		var value: int = int(aptitudes.get(key, 0))
		if value > 0:
			parts.append("%s %d" % [_ability_label(key), value])
	if parts.is_empty():
		return "-"
	return "  ".join(parts)


func _ability_label(key: String) -> String:
	var labels: Dictionary = {
		"catcher": "C",
		"first": "1B",
		"second": "2B",
		"third": "3B",
		"shortstop": "SS",
		"left": "LF",
		"center": "CF",
		"right": "RF",
	}
	return str(labels.get(key, key))


func _source_label(source_type: String) -> String:
	match source_type:
		"high_school":
			return "高校"
		"university":
			return "大学"
		"industrial":
			return "社会人"
		"independent":
			return "独立"
		"overseas_school":
			return "海外"
		_:
			return source_type


func _format_lottery_log(log: Dictionary) -> String:
	var teams: PackedStringArray = PackedStringArray()
	for team_id_value in log.get("teams", []) as Array:
		teams.append(_team_short(int(team_id_value)))
	var team_text: String = ", ".join(teams)
	return "抽選%d回目: %s -> %s (%s)" % [
		int(log.get("wave", 0)),
		str(log.get("candidate_name", "")),
		_team_short(int(log.get("winner_team_id", 0))),
		team_text,
	]


# ---------------------------------------------------------------------------
# FA / 外国人パネル
# ---------------------------------------------------------------------------

func _populate_released_market_panel() -> void:
	var state: Dictionary = AppState.released_market_state
	var candidates: Array = ReleasedMarketService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var signings: Array = state.get("signings", []) as Array
	var user_signings: int = 0
	for row in signings:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	released_market_status_label.text = "戦力外獲得: 候補%d人 / 自軍獲得%d人 / 残り候補%d人" % [
		(state.get("candidates", []) as Array).size(),
		user_signings,
		candidates.size(),
	]
	var rows: Array = []
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		rows.append({
			"name": str(c.get("name", "")),
			"from": _team_short(int(c.get("from_team", 0))),
			"age": int(c.get("age", 0)),
			"pos": _dict_role_or_position(c),
			"value": int(c.get("value", 0)),
			"war": float(c.get("war", 0.0)),
			"need": float(c.get("need", 0.0)),
			"salary": int(c.get("salary", 0)),
			"__meta": int(c.get("player_id", 0)),
		})
	_suppress_released_select = true
	released_market_candidate_list.set_rows(rows)
	if selected_released_candidate_id > 0 and _released_candidate_by_id(candidates, selected_released_candidate_id).is_empty():
		selected_released_candidate_id = 0
	if selected_released_candidate_id <= 0:
		var first_meta: Variant = released_market_candidate_list.get_first_meta()
		if first_meta != null:
			selected_released_candidate_id = int(first_meta)
	released_market_candidate_list.select_meta(selected_released_candidate_id)
	_suppress_released_select = false
	released_market_detail_text.text = _format_released_details(_released_candidate_by_id(candidates, selected_released_candidate_id))
	var has_candidate: bool = selected_released_candidate_id > 0
	released_market_submit_button.disabled = not has_candidate
	released_market_skip_button.disabled = not has_candidate
	released_market_auto_button.disabled = candidates.is_empty()


func _released_candidate_by_id(candidates: Array, player_id: int) -> Dictionary:
	for row in candidates:
		var c: Dictionary = row as Dictionary
		if int(c.get("player_id", 0)) == player_id:
			return c
	return {}


func _format_released_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "自由契約候補を選択してください。"
	var team_id: int = AppState.selected_team_id
	var active_roster: int = _active_roster_count(team_id)
	var remaining_roster: int = max(0, TeamFinance.SHIENKA_LIMIT - active_roster)
	var salary: int = int(candidate.get("salary", 0))
	var team: PSTeam = GameDb.get_team(team_id)
	var budget_room: int = 0
	if team != null:
		budget_room = team.funds - TeamFinance.team_payroll(GameDb.players, team_id) - salary
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _dict_role_or_position(candidate)])
	lines.append("%d歳  元%s  年俸%d万" % [
		int(candidate.get("age", 0)),
		_team_short(int(candidate.get("from_team", 0))),
		salary,
	])
	lines.append("総合 %d  WAR %+0.1f  自軍需要 %+0.1f" % [
		int(candidate.get("value", 0)),
		float(candidate.get("war", 0.0)),
		float(candidate.get("need", 0.0)),
	])
	lines.append("枠: 支配下 %d/%d (補強残り%d)" % [
		active_roster,
		TeamFinance.SHIENKA_LIMIT,
		remaining_roster,
	])
	if team != null:
		lines.append("予算: 契約後余力 %+d万" % budget_room)
	if int(candidate.get("plate_appearances", 0)) > 0:
		lines.append("今季: %d試合 %d打席" % [int(candidate.get("games", 0)), int(candidate.get("plate_appearances", 0))])
	elif int(candidate.get("starts", 0)) > 0 or int(candidate.get("relief_appearances", 0)) > 0:
		lines.append("今季: 登板%d 先発%d 救援%d" % [
			int(candidate.get("games", 0)),
			int(candidate.get("starts", 0)),
			int(candidate.get("relief_appearances", 0)),
		])
	if team != null and budget_room < 0:
		lines.append("")
		lines.append("予算超過見込みです。CPU評価では獲得優先度が下がります。")
	if not bool(candidate.get("can_sign", true)):
		lines.append("")
		lines.append("支配下枠が不足しているため獲得できません。")
	return "\n".join(lines)


func _on_released_candidate_selected() -> void:
	if _suppress_released_select:
		return
	var meta: Variant = released_market_candidate_list.get_selected_meta()
	if meta == null:
		return
	selected_released_candidate_id = int(meta)
	var candidates: Array = ReleasedMarketService.available_user_candidates(AppState.released_market_state, GameDb.players, GameDb.teams)
	released_market_detail_text.text = _format_released_details(_released_candidate_by_id(candidates, selected_released_candidate_id))


func _populate_fa_panel() -> void:
	var state: Dictionary = AppState.fa_state
	var candidates: Array = FaMarketService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var signings: Array = state.get("signings", []) as Array
	var user_signings: int = 0
	for row in signings:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	fa_status_label.text = "FA市場: 宣言%d人 / 自軍獲得%d人 / 候補%d人" % [
		(state.get("declared", []) as Array).size(),
		user_signings,
		candidates.size(),
	]
	var rows: Array = []
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		rows.append({
			"name": str(c.get("name", "")),
			"from": _team_short(int(c.get("from_team", 0))),
			"rank": str(c.get("fa_rank", "C")),
			"age": int(c.get("age", 0)),
			"pos": _dict_role_or_position(c),
			"value": int(c.get("value", 0)),
			"war": float(c.get("war", 0.0)),
			"need": float(c.get("need", 0.0)),
			"chance": float(c.get("success_chance", 0.0)),
			"declare": float(c.get("declaration_chance", 0.0)),
			"fa_days": int(c.get("fa_nissuu", 0)),
			"offer": int(c.get("offer_salary", c.get("salary", 0))),
			"compensation": int(c.get("compensation_money", 0)),
			"__meta": int(c.get("player_id", 0)),
		})
	_suppress_fa_select = true
	fa_candidate_list.set_rows(rows)
	if selected_fa_candidate_id > 0 and _fa_candidate_by_id(candidates, selected_fa_candidate_id).is_empty():
		selected_fa_candidate_id = 0
	if selected_fa_candidate_id <= 0:
		var first_meta: Variant = fa_candidate_list.get_first_meta()
		if first_meta != null:
			selected_fa_candidate_id = int(first_meta)
	fa_candidate_list.select_meta(selected_fa_candidate_id)
	_suppress_fa_select = false
	fa_detail_text.text = _format_fa_details(_fa_candidate_by_id(candidates, selected_fa_candidate_id))
	var has_candidate: bool = selected_fa_candidate_id > 0
	fa_submit_button.disabled = not has_candidate
	fa_skip_button.disabled = not has_candidate
	fa_auto_button.disabled = candidates.is_empty()


func _fa_candidate_by_id(candidates: Array, player_id: int) -> Dictionary:
	for row in candidates:
		var c: Dictionary = row as Dictionary
		if int(c.get("player_id", 0)) == player_id:
			return c
	return {}


func _format_fa_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "FA候補を選択してください。"
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _dict_role_or_position(candidate)])
	lines.append("%d歳  元%s  ランク%s  年俸%d万" % [
		int(candidate.get("age", 0)),
		_team_short(int(candidate.get("from_team", 0))),
		str(candidate.get("fa_rank", "C")),
		int(candidate.get("salary", 0)),
	])
	lines.append("総合 %d  WAR %+0.1f  自軍需要 %+0.1f" % [
		int(candidate.get("value", 0)),
		float(candidate.get("war", 0.0)),
		float(candidate.get("need", 0.0)),
	])
	lines.append("交渉成功率 %d%%" % int(round(float(candidate.get("success_chance", 0.0)) * 100.0)))
	lines.append("宣言率 %d%%  提示年俸%d万  金銭補償%d万" % [
		int(round(float(candidate.get("declaration_chance", 0.0)) * 100.0)),
		int(candidate.get("offer_salary", candidate.get("salary", 0))),
		int(candidate.get("compensation_money", 0)),
	])
	lines.append("FA権取得年 %d  見送り%d回  FA日数 %d/%d" % [
		int(candidate.get("fa_eligible_year", 0)),
		int(candidate.get("fa_pass_count", 0)),
		int(candidate.get("fa_nissuu", 0)),
		int(candidate.get("fa_required_days", 0)),
	])
	if int(candidate.get("plate_appearances", 0)) > 0:
		lines.append("今季: %d試合 %d打席" % [int(candidate.get("games", 0)), int(candidate.get("plate_appearances", 0))])
	elif int(candidate.get("starts", 0)) > 0 or int(candidate.get("relief_appearances", 0)) > 0:
		lines.append("今季: 登板%d 先発%d 救援%d" % [
			int(candidate.get("games", 0)),
			int(candidate.get("starts", 0)),
			int(candidate.get("relief_appearances", 0)),
		])
	if not bool(candidate.get("can_sign", true)):
		lines.append("")
		lines.append("支配下枠が不足しているため獲得できません。")
	return "\n".join(lines)


func _on_fa_candidate_selected() -> void:
	if _suppress_fa_select:
		return
	var meta: Variant = fa_candidate_list.get_selected_meta()
	if meta == null:
		return
	selected_fa_candidate_id = int(meta)
	var candidates: Array = FaMarketService.available_user_candidates(AppState.fa_state, GameDb.players, GameDb.teams)
	fa_detail_text.text = _format_fa_details(_fa_candidate_by_id(candidates, selected_fa_candidate_id))


func _populate_foreign_panel() -> void:
	var state: Dictionary = AppState.foreign_state
	var candidates: Array = ForeignPlayerService.available_user_candidates(state, GameDb.players, GameDb.teams)
	var current_foreign: int = _active_foreign_count(AppState.selected_team_id)
	var user_signings: int = 0
	for row in state.get("signings", []) as Array:
		if int((row as Dictionary).get("to_team", 0)) == AppState.selected_team_id:
			user_signings += 1
	foreign_status_label.text = "外国人補強: 現在%d人 / 今オフ獲得%d人 / 上限4 / 候補%d人" % [
		current_foreign, user_signings, candidates.size(),
	]
	var rows: Array = []
	for candidate_row in candidates:
		var c: Dictionary = candidate_row as Dictionary
		rows.append({
			"name": str(c.get("name", "")),
			"age": int(c.get("age", 0)),
			"pos": _dict_role_or_position(c),
			"tier": str(FOREIGN_TIER_LABELS.get(str(c.get("tier", "")), str(c.get("tier", "")))),
			"value": int(c.get("value", 0)),
			"need": float(c.get("need", 0.0)),
			"salary": int(c.get("salary", 0)),
			"__meta": int(c.get("candidate_id", 0)),
		})
	_suppress_foreign_select = true
	foreign_candidate_list.set_rows(rows)
	if selected_foreign_candidate_id > 0 and _foreign_candidate_by_id(candidates, selected_foreign_candidate_id).is_empty():
		selected_foreign_candidate_id = 0
	if selected_foreign_candidate_id <= 0:
		var first_meta: Variant = foreign_candidate_list.get_first_meta()
		if first_meta != null:
			selected_foreign_candidate_id = int(first_meta)
	foreign_candidate_list.select_meta(selected_foreign_candidate_id)
	_suppress_foreign_select = false
	foreign_detail_text.text = _format_foreign_details(_foreign_candidate_by_id(candidates, selected_foreign_candidate_id))
	var has_candidate: bool = selected_foreign_candidate_id > 0
	foreign_submit_button.disabled = not has_candidate
	foreign_skip_button.disabled = not has_candidate
	foreign_auto_button.disabled = candidates.is_empty()


func _foreign_candidate_by_id(candidates: Array, candidate_id: int) -> Dictionary:
	for row in candidates:
		var c: Dictionary = row as Dictionary
		if int(c.get("candidate_id", 0)) == candidate_id:
			return c
	return {}


func _format_foreign_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "外国人候補を選択してください。"
	var template: Dictionary = (candidate.get("player_data", {}) as Dictionary).duplicate(true)
	var team_id: int = AppState.selected_team_id
	var active_roster: int = _active_roster_count(team_id)
	var current_foreign: int = _active_foreign_count(team_id)
	var remaining_roster: int = max(0, TeamFinance.SHIENKA_LIMIT - active_roster)
	var remaining_foreign: int = max(0, ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM - current_foreign)
	var salary: int = int(candidate.get("salary", 0))
	var team: PSTeam = GameDb.get_team(team_id)
	var budget_room: int = 0
	if team != null:
		budget_room = team.funds - TeamFinance.team_payroll(GameDb.players, team_id) - salary
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _dict_role_or_position(candidate)])
	lines.append("%d歳  %s  年俸%d万" % [
		int(candidate.get("age", 0)),
		str(FOREIGN_TIER_LABELS.get(str(candidate.get("tier", "")), str(candidate.get("tier", "")))),
		salary,
	])
	lines.append("総合 %d  自軍需要 %+0.1f" % [
		int(candidate.get("value", 0)),
		float(candidate.get("need", 0.0)),
	])
	lines.append("枠: 支配下 %d/%d (補強残り%d)  外国人 %d/%d (残り%d)" % [
		active_roster,
		TeamFinance.SHIENKA_LIMIT,
		remaining_roster,
		current_foreign,
		ForeignPlayerService.MAX_FOREIGN_HELD_PER_TEAM,
		remaining_foreign,
	])
	if team != null:
		lines.append("予算: 契約後余力 %+d万" % budget_room)
	lines.append("")
	lines.append("能力")
	lines.append(PlayerVisibleRatings.summary_line_for_player_data(template))
	if int(candidate.get("position", 0)) == 1:
		var arsenal_text: String = PSPitchTypes.arsenal_line(template.get("arsenal", []) as Array)
		if not arsenal_text.is_empty():
			lines.append("")
			lines.append("球種")
			lines.append(arsenal_text)
	if team != null and budget_room < 0:
		lines.append("")
		lines.append("予算超過見込みです。CPU評価では獲得優先度が下がります。")
	if not bool(candidate.get("can_sign", true)):
		lines.append("")
		lines.append("支配下枠または外国人枠が不足しているため獲得できません。")
	return "\n".join(lines)


func _on_foreign_candidate_selected() -> void:
	if _suppress_foreign_select:
		return
	var meta: Variant = foreign_candidate_list.get_selected_meta()
	if meta == null:
		return
	selected_foreign_candidate_id = int(meta)
	var candidates: Array = ForeignPlayerService.available_user_candidates(AppState.foreign_state, GameDb.players, GameDb.teams)
	foreign_detail_text.text = _format_foreign_details(_foreign_candidate_by_id(candidates, selected_foreign_candidate_id))


func _populate_camp_panel() -> void:
	var state: Dictionary = AppState.camp_state
	var actions: Array = state.get("actions", []) as Array
	var user_actions: int = 0
	for row in actions:
		if int((row as Dictionary).get("team_id", 0)) == AppState.selected_team_id:
			user_actions += 1
	var roster_players: Array = _camp_roster_players()
	camp_status_label.text = "キャンプ: 自軍特別練習 %d/%d件 / 選手%d人" % [
		user_actions,
		CampServiceRef.MAX_SPECIAL_TRAININGS_PER_TEAM,
		roster_players.size(),
	]
	var rows: Array = []
	var trained: Dictionary = _camp_trained_player_set(state)
	var roster_ids: Dictionary = {}
	for player_row in roster_players:
		var roster_player: PSPlayer = player_row as PSPlayer
		roster_ids[roster_player.id] = true
		rows.append(_camp_roster_row(roster_player, trained))
	_suppress_camp_select = true
	camp_player_list.set_rows(rows)
	if selected_camp_player_id > 0 and not roster_ids.has(selected_camp_player_id):
		selected_camp_player_id = 0
	if selected_camp_player_id <= 0:
		var first_meta: Variant = camp_player_list.get_first_meta()
		if first_meta != null:
			selected_camp_player_id = int(first_meta)
	camp_player_list.select_meta(selected_camp_player_id)
	_suppress_camp_select = false
	camp_auto_button.disabled = bool(state.get("complete", false))
	camp_finish_button.disabled = bool(state.get("complete", false))
	_refresh_camp_training_controls()


func _camp_roster_players() -> Array:
	var rows: Array = []
	var team_id: int = AppState.selected_team_id
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		rows.append(player)
	return rows


func _camp_roster_row(player: PSPlayer, trained: Dictionary) -> Dictionary:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(
		player,
		AppState.current_season.year if AppState.current_season != null else 0,
		AppState.current_season.season_number if AppState.current_season != null else 0
	)
	var row: Dictionary = {
		"jersey": _camp_jersey_text(player),
		"pos": _player_role_or_position(player),
		"name": player.name,
		"age": player.age,
		"eval": PlayerValueEvaluator.overall_score(record),
		"__meta": player.id,
	}
	if trained.has(player.id):
		row["__color"] = Color(0.55, 0.78, 1.0)
	return row


func _camp_jersey_text(player: PSPlayer) -> String:
	if player.jersey_number > 0:
		return str(player.jersey_number)
	if player.team_id > 0 or player.sensyu_num > 0:
		return "0"
	return "-"


func _camp_trained_player_set(state: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for id_value in state.get("trained_player_ids", []) as Array:
		out[int(id_value)] = true
	return out


func _refresh_camp_training_controls() -> void:
	if camp_training_select == null or camp_position_select == null:
		return
	var options: Array = CampServiceRef.user_training_options_for_player(
		AppState.camp_state,
		GameDb.players,
		AppState.current_season,
		selected_camp_player_id
	)
	_suppress_camp_training_select = true
	camp_training_select.clear()
	camp_position_select.clear()
	if selected_camp_player_id <= 0:
		selected_camp_training_type = ""
		selected_camp_target_position = 0
		camp_training_select.disabled = true
		camp_position_select.disabled = true
		camp_submit_button.disabled = true
		camp_detail_text.text = "選手を選択してください。"
		_suppress_camp_training_select = false
		return
	if options.is_empty():
		selected_camp_training_type = ""
		selected_camp_target_position = 0
		camp_training_select.disabled = true
		camp_position_select.disabled = true
		camp_submit_button.disabled = true
		camp_detail_text.text = _format_camp_unavailable_player(selected_camp_player_id)
		_suppress_camp_training_select = false
		return

	var type_indices: Dictionary = {}
	for option_row in options:
		var option: Dictionary = option_row as Dictionary
		var training_type: String = str(option.get("training_type", ""))
		if type_indices.has(training_type):
			continue
		var idx: int = camp_training_select.get_item_count()
		camp_training_select.add_item(str(option.get("training_label", "")))
		camp_training_select.set_item_metadata(idx, training_type)
		type_indices[training_type] = idx
	var selected_type_index: int = int(type_indices.get(selected_camp_training_type, 0))
	camp_training_select.disabled = false
	camp_training_select.select(selected_type_index)
	selected_camp_training_type = str(camp_training_select.get_item_metadata(selected_type_index))
	_populate_camp_target_select(options)
	var selected_option: Dictionary = _selected_camp_option(options)
	camp_submit_button.disabled = selected_option.is_empty()
	camp_detail_text.text = _format_camp_details(selected_option)
	_suppress_camp_training_select = false


func _populate_camp_target_select(options: Array) -> void:
	camp_position_select.clear()
	var matching: Array = []
	for option_row in options:
		var option: Dictionary = option_row as Dictionary
		if str(option.get("training_type", "")) == selected_camp_training_type:
			matching.append(option)
	if matching.is_empty():
		selected_camp_target_position = 0
		camp_position_select.disabled = true
		return
	var has_position_target: bool = false
	for option_row in matching:
		if int((option_row as Dictionary).get("target_position", 0)) > 0:
			has_position_target = true
			break
	if not has_position_target:
		selected_camp_target_position = 0
		camp_position_select.disabled = true
		return
	camp_position_select.disabled = false
	var selected_index: int = 0
	for option_row in matching:
		var option: Dictionary = option_row as Dictionary
		var pos: int = int(option.get("target_position", 0))
		if pos <= 0:
			continue
		var idx: int = camp_position_select.get_item_count()
		camp_position_select.add_item(str(option.get("target_position_name", _position_name(pos))))
		camp_position_select.set_item_metadata(idx, option.duplicate(true))
		if pos == selected_camp_target_position:
			selected_index = idx
	camp_position_select.select(selected_index)
	var selected_meta: Variant = camp_position_select.get_item_metadata(selected_index)
	var selected_option: Dictionary = selected_meta as Dictionary
	selected_camp_target_position = int(selected_option.get("target_position", 0))


func _selected_camp_option(options: Array) -> Dictionary:
	for option_row in options:
		var option: Dictionary = option_row as Dictionary
		if str(option.get("training_type", "")) != selected_camp_training_type:
			continue
		var target_position: int = int(option.get("target_position", 0))
		if target_position == selected_camp_target_position:
			return option
	return {}


func _format_camp_unavailable_player(player_id: int) -> String:
	var player: PSPlayer = GameDb.get_player(player_id)
	if player == null:
		return "選手を選択してください。"
	var lines: Array = []
	lines.append("%s  %s" % [player.name, _player_role_or_position(player)])
	if _camp_trained_player_set(AppState.camp_state).has(player.id):
		lines.append("この選手は今オフに特別練習済みです。")
	elif player.injury_days > 0:
		lines.append("怪我のため今オフの特別練習は選択できません。")
	else:
		lines.append("選択できる特別練習がありません。")
	lines.append("")
	lines.append("能力")
	lines.append(PlayerVisibleRatings.summary_line_for_player_data(player.to_dict()))
	return "\n".join(lines)


func _camp_training_target(candidate: Dictionary) -> String:
	var target_position: int = int(candidate.get("target_position", 0))
	if target_position > 0:
		return _position_name(target_position)
	var training_type: String = str(candidate.get("training_type", ""))
	if training_type == CampServiceRef.TRAIN_STARTER:
		return "先発"
	if training_type == CampServiceRef.TRAIN_RELIEVER:
		return "中継"
	return ""


func _format_camp_details(candidate: Dictionary) -> String:
	if candidate.is_empty():
		return "選手を選択し、特別練習を指定してください。"
	var player: PSPlayer = GameDb.get_player(int(candidate.get("player_id", 0)))
	var target_position: int = int(candidate.get("target_position", 0))
	var lines: Array = []
	lines.append("%s  %s" % [str(candidate.get("name", "")), _dict_role_or_position(candidate)])
	lines.append("%d歳  %s → %s" % [
		int(candidate.get("age", 0)),
		str(candidate.get("training_label", "")),
		_camp_training_target(candidate),
	])
	lines.append("成功率 %0.1f%%  リスク %s" % [
		float(candidate.get("success_chance", 0.0)) * 100.0,
		str(candidate.get("risk_label", "中")),
	])
	lines.append("理由: %s" % str(candidate.get("reason", "")))
	if target_position > 0:
		var current: int = _player_position_aptitude_for_ui(player, target_position)
		lines.append("対象適性: %s %d → 成功時 %d" % [
			_position_name(target_position),
			current,
			int(candidate.get("projected_aptitude", 0)),
		])
	if player != null:
		lines.append("")
		lines.append("能力")
		lines.append(PlayerVisibleRatings.summary_line_for_player_data(player.to_dict()))
		if player.is_pitcher():
			var arsenal_text: String = PSPitchTypes.arsenal_line(player.arsenal)
			if not arsenal_text.is_empty():
				lines.append("")
				lines.append("球種")
				lines.append(arsenal_text)
	return "\n".join(lines)


func _player_position_aptitude_for_ui(player: PSPlayer, pos: int) -> int:
	if player == null or pos < 3 or pos > 9:
		return 0
	var key: String = PSPlayer.position_experience_key(pos)
	if key.is_empty():
		return 0
	if player.position_aptitudes.is_empty():
		return 100 if player.position == pos else 0
	return int(player.position_aptitudes.get(key, 0))


func _on_camp_player_selected() -> void:
	if _suppress_camp_select:
		return
	var meta: Variant = camp_player_list.get_selected_meta()
	if meta == null:
		return
	selected_camp_player_id = int(meta)
	selected_camp_training_type = ""
	selected_camp_target_position = 0
	_refresh_camp_training_controls()


func _on_camp_training_selected(_index: int) -> void:
	if _suppress_camp_training_select:
		return
	var selected_index: int = camp_training_select.selected
	if selected_index < 0:
		return
	selected_camp_training_type = str(camp_training_select.get_item_metadata(selected_index))
	selected_camp_target_position = 0
	_refresh_camp_training_controls()


func _on_camp_target_selected(_index: int) -> void:
	if _suppress_camp_training_select:
		return
	var selected_index: int = camp_position_select.selected
	if selected_index >= 0:
		var selected_meta: Variant = camp_position_select.get_item_metadata(selected_index)
		var selected_option: Dictionary = selected_meta as Dictionary
		selected_camp_target_position = int(selected_option.get("target_position", 0))
	var options: Array = CampServiceRef.user_training_options_for_player(
		AppState.camp_state,
		GameDb.players,
		AppState.current_season,
		selected_camp_player_id
	)
	var selected_option: Dictionary = _selected_camp_option(options)
	camp_submit_button.disabled = selected_option.is_empty()
	camp_detail_text.text = _format_camp_details(selected_option)


func _active_foreign_count(team_id: int) -> int:
	var count: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null and player.team_id == team_id and player.foreign_player and not player.is_retired():
			count += 1
	return count


func _active_roster_count(team_id: int) -> int:
	var count: int = 0
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		count += 1
	return count


# ---------------------------------------------------------------------------
# 戦力外通告エディタ
# ---------------------------------------------------------------------------

func _populate_release_list() -> void:
	team_roster_records = []
	selected_release_ids = {}
	selected_demote_ids = {}
	last_release_meta = 0
	release_war_by_id = _build_release_war_map()
	var team_id: int = AppState.selected_team_id
	if team_id <= 0:
		release_list.set_rows([])
		return
	var pitchers: Array = []
	var batters: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		if player.is_pitcher():
			pitchers.append(player)
		else:
			batters.append(player)
	var sort_fn: Callable = func(a, b) -> bool:
		var pa: PSPlayer = a as PSPlayer
		var pb: PSPlayer = b as PSPlayer
		if pa.age == pb.age:
			return Offseason.player_value_score(pa) < Offseason.player_value_score(pb)
		return pa.age > pb.age
	pitchers.sort_custom(sort_fn)
	batters.sort_custom(sort_fn)

	team_roster_records = []
	for player_row in pitchers:
		team_roster_records.append(player_row)
	for player_row in batters:
		team_roster_records.append(player_row)
	_rebuild_release_rows()


func _rebuild_release_rows() -> void:
	var rows: Array = []
	for player_row in team_roster_records:
		rows.append(_release_row(player_row as PSPlayer))
	release_list.set_rows(rows)


func _release_row(player: PSPlayer) -> Dictionary:
	var is_release: bool = selected_release_ids.has(player.id)
	var is_demote: bool = selected_demote_ids.has(player.id)
	var note_parts: Array = []
	if player.foreign_player:
		note_parts.append("外")
	var check_text: String = ""
	if is_release:
		check_text = "✓"
	elif is_demote:
		check_text = "育"
	var row: Dictionary = {
		"check": check_text,
		"pos": _player_role_or_position(player),
		"name": player.name,
		"age": player.age,
		"years": player.years,
		"eval": Offseason.player_value_score(player),
		"war": float(release_war_by_id.get(player.id, 0.0)),
		"injury": _release_injury_days(player),
		"note": " ".join(note_parts),
		"stat": _release_stat_text(player),
		"__meta": player.id,
	}
	if is_release:
		row["__color"] = Color(0.95, 0.6, 0.55)
	elif is_demote:
		row["__color"] = Color(0.6, 0.85, 0.65)
	return row


# 怪我日数: 今季の累積怪我日数 (record.season_injury_days)。記録が無ければ現在の残り日数。
func _release_injury_days(player: PSPlayer) -> int:
	var season: PSSeason = AppState.current_season
	if season != null:
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if record != null:
			return record.season_injury_days
	return player.injury_days


# 自軍ロースター全員の今季 WAR を 1 度だけ計算して {player_id: war} を返す。
func _build_release_war_map() -> Dictionary:
	var map: Dictionary = {}
	var season: PSSeason = AppState.current_season
	if season == null:
		return map
	var war_rows: Array = PSWarCalculator.season_war_table(season.year, season.season_number)
	for row_value in war_rows:
		var row: Dictionary = row_value as Dictionary
		map[int(row.get("player_id", 0))] = float(row.get("war", 0.0))
	return map


func _release_stat_text(player: PSPlayer) -> String:
	var season: PSSeason = AppState.current_season
	if season == null:
		return ""
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
	if record == null:
		return ""
	if player.is_pitcher():
		var ps: PSPitcherStats = record.pitcher_stats
		if ps.games <= 0:
			return "登板なし"
		var era_str: String = "--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()
		return "登%d 先%d %d勝%d敗S%d H%d 防%s 奪%d" % [
			ps.games, ps.starts, ps.wins, ps.losses, ps.saves, ps.holds, era_str, ps.strikeouts,
		]
	var bs: PSBatterStats = record.batter_stats
	if bs.plate_appearances <= 0:
		return "出場なし"
	return "試%d 打席%d 率%0.3f 本%d 点%d 盗%d OPS%0.3f" % [
		bs.games, bs.plate_appearances, bs.batting_average(),
		bs.home_runs, bs.runs_batted_in, bs.stolen_bases, bs.ops(),
	]


func _on_release_item_selected() -> void:
	var meta: Variant = release_list.get_selected_meta()
	if meta == null:
		return
	var pid: int = int(meta)
	var shift_held: bool = Input.is_key_pressed(KEY_SHIFT)
	if shift_held and last_release_meta > 0:
		# 範囲チェック: 現在の表示順でアンカーから今クリックした行までをすべて ON。
		var metas: Array = release_list.get_ordered_metas()
		var i1: int = metas.find(last_release_meta)
		var i2: int = metas.find(pid)
		if i1 >= 0 and i2 >= 0:
			var lo: int = min(i1, i2)
			var hi: int = max(i1, i2)
			for i in range(lo, hi + 1):
				selected_release_ids[int(metas[i])] = true
				selected_demote_ids.erase(int(metas[i]))
	else:
		# 単発: 戦力外(✓) → 育成降格(育) → 解除 の 3 状態を巡回。
		if selected_release_ids.has(pid):
			selected_release_ids.erase(pid)
			selected_demote_ids[pid] = true
		elif selected_demote_ids.has(pid):
			selected_demote_ids.erase(pid)
		else:
			selected_release_ids[pid] = true
		last_release_meta = pid

	# 選択ハイライトを消し、同じ行を再クリックしても item_selected が再発火するようにする。
	# Tree の clear()/再構築を item_selected シグナル処理中に同期実行すると、選択中の
	# TreeItem が解放され Godot 内部が set_text を null に対して呼んでクラッシュする。
	# 1 フレーム遅延させて安全に作り直す。
	call_deferred("_apply_release_selection_change")


func _apply_release_selection_change() -> void:
	release_list.deselect_all()
	_rebuild_release_rows()
	_refresh_release_summary()


func _refresh_release_summary() -> void:
	var team_id: int = AppState.selected_team_id
	var roster_count: int = team_roster_records.size()
	var selected_count: int = selected_release_ids.size()
	var demote_count: int = selected_demote_ids.size()
	var team_name: String = ""
	var team: PSTeam = GameDb.get_team(team_id)
	if team != null:
		team_name = team.short_name
	release_summary_label.text = "[%s] 戦力外 %d人 / 育成降格 %d人 / 自軍%d人" % [team_name, selected_count, demote_count, roster_count]


func _on_auto_select_release_pressed() -> void:
	var team_id: int = AppState.selected_team_id
	var season: PSSeason = AppState.current_season
	if team_id <= 0 or season == null:
		return
	var candidate_ids: Array = OffseasonService.compute_release_candidates_for_team(GameDb.players, team_id, season, true)
	selected_release_ids = {}
	selected_demote_ids = {}
	# CPU と同じ基準で、若く価値の残る候補は育成降格に振り分けて提示する (確定前に編集可)。
	for pid_v in candidate_ids:
		var pid: int = int(pid_v)
		var player: PSPlayer = GameDb.get_player(pid)
		if player != null and OffseasonService._should_demote_to_development(player) and TeamFinance.has_development_room(GameDb.players, team_id):
			selected_demote_ids[pid] = true
		else:
			selected_release_ids[pid] = true
	_rebuild_release_rows()
	_refresh_release_summary()
	status_label.text = "自動で候補を選択しました (戦力外%d / 育成降格%d)。確定前に編集できます。" % [selected_release_ids.size(), selected_demote_ids.size()]
	status_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.92))


func _on_commit_release_pressed() -> void:
	var selected_ids: Array = []
	for pid in selected_release_ids.keys():
		selected_ids.append(int(pid))
	var demote_ids: Array = []
	for pid in selected_demote_ids.keys():
		demote_ids.append(int(pid))
	var result: Dictionary = AppState.commit_release(selected_ids, demote_ids)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", ""))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	_refresh()


# ---------------------------------------------------------------------------
# ボタンハンドラ
# ---------------------------------------------------------------------------

func _on_draft_submit_pressed() -> void:
	if selected_draft_candidate_id <= 0:
		status_label.text = "ドラフト候補を選択してください。"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var result: Dictionary = AppState.submit_draft_candidate(selected_draft_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "指名に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_draft_skip_pressed() -> void:
	var result: Dictionary = AppState.skip_draft_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "見送りに失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_draft_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_draft_user_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "自動指名に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_draft_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_draft_automatically()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "自動進行に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_released_submit_pressed() -> void:
	if selected_released_candidate_id <= 0:
		status_label.text = "自由契約候補を選択してください。"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var result: Dictionary = AppState.submit_released_candidate(selected_released_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "戦力外獲得に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_released_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_released_skip_pressed() -> void:
	if selected_released_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_released_candidate(selected_released_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "自由契約候補の見送りに失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_released_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_released_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_released_user_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "戦力外獲得の自動判断に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_released_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_released_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_released_market_automatically()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "戦力外獲得市場の自動進行に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_released_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_fa_submit_pressed() -> void:
	if selected_fa_candidate_id <= 0:
		status_label.text = "FA候補を選択してください。"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var result: Dictionary = AppState.submit_fa_candidate(selected_fa_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "FA獲得に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var message: String = str(result.get("message", ""))
	var acquired: bool = bool(result.get("acquired", true))
	selected_fa_candidate_id = 0
	_refresh()
	if acquired:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		return
	status_label.text = message if not message.is_empty() else "交渉はまとまりませんでした。"
	status_label.add_theme_color_override("font_color", Color(0.95, 0.78, 0.45))
	return


func _on_fa_skip_pressed() -> void:
	if selected_fa_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_fa_candidate(selected_fa_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "FA見送りに失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_fa_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_fa_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_fa_user_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "FA自動判断に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_fa_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_fa_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_fa_automatically()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "FA自動進行に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_fa_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_foreign_submit_pressed() -> void:
	if selected_foreign_candidate_id <= 0:
		status_label.text = "外国人候補を選択してください。"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var result: Dictionary = AppState.submit_foreign_candidate(selected_foreign_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "外国人獲得に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_foreign_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_foreign_skip_pressed() -> void:
	if selected_foreign_candidate_id <= 0:
		return
	var result: Dictionary = AppState.skip_foreign_candidate(selected_foreign_candidate_id)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "外国人見送りに失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_foreign_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_foreign_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_foreign_user_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "外国人自動判断に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_foreign_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_foreign_auto_all_pressed() -> void:
	var result: Dictionary = AppState.complete_foreign_automatically()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "外国人自動進行に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_foreign_candidate_id = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_camp_submit_pressed() -> void:
	if selected_camp_player_id <= 0 or selected_camp_training_type.is_empty():
		status_label.text = "選手と特別練習を選択してください。"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	var result: Dictionary = AppState.submit_camp_player_training(
		selected_camp_player_id,
		selected_camp_training_type,
		selected_camp_target_position
	)
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "特別練習の実行に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_camp_auto_pressed() -> void:
	var result: Dictionary = AppState.auto_camp_user_pick()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "キャンプ自動判断に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_camp_player_id = 0
	selected_camp_training_type = ""
	selected_camp_target_position = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_camp_finish_pressed() -> void:
	var result: Dictionary = AppState.finish_camp()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", "キャンプ終了に失敗しました。"))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	selected_camp_player_id = 0
	selected_camp_training_type = ""
	selected_camp_target_position = 0
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	_refresh()


func _on_next_pressed() -> void:
	var result: Dictionary = AppState.advance_offseason()
	if not bool(result.get("ok", false)):
		status_label.text = str(result.get("message", ""))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
		return
	_refresh()


func _on_finalize_pressed() -> void:
	var ok: bool = AppState.finalize_offseason()
	if not ok:
		status_label.text = "翌年開始に失敗しました"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))


func _league_label(league: String) -> String:
	if league == "central":
		return "セ"
	if league == "pacific":
		return "パ"
	return league


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _position_name(pos: int) -> String:
	return str(PSPlayer.POSITION_NAMES.get(pos, "?"))


func _position_char(pos: int) -> String:
	return str(POSITION_CHARS.get(pos, "?"))


func _dict_role_or_position(data: Dictionary) -> String:
	return _role_or_position_name(int(data.get("position", 0)), str(data.get("role", "")), data)


func _dict_role_or_position_char(data: Dictionary) -> String:
	var position: int = int(data.get("position", 0))
	if position == 1:
		return _role_char(_resolved_pitcher_role(str(data.get("role", "")), data))
	return _position_char(position)


func _player_role_or_position(player: PSPlayer) -> String:
	if player != null and player.is_pitcher():
		return _role_label(_resolved_pitcher_role(player.role, {}))
	return _position_name(player.position if player != null else 0)


func _role_or_position_name(position: int, role: String, data: Dictionary = {}) -> String:
	if position == 1:
		return _role_label(_resolved_pitcher_role(role, data))
	return _position_name(position)


func _resolved_pitcher_role(role: String, data: Dictionary) -> String:
	if role == "starter" or role == "reliever" or role == "closer":
		return role
	if int(data.get("starts", 0)) > int(data.get("relief_appearances", 0)):
		return "starter"
	return "reliever"


func _role_char(role: String) -> String:
	match role:
		"starter":
			return "先"
		"reliever":
			return "継"
		"closer":
			return "抑"
		_:
			return "継"
