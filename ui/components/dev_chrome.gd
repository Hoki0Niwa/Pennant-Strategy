extends RefCounted

# 開発系のネイティブ Control 画面 (計測レポート / 選手プローブ / ドラフト検証) を、
# ダッシュボード (dashboard_screen.gd) と同じダーク配色に「枠だけ」合わせるためのヘルパ。
# 中身の表・グラフ・入力部はそのまま流用し、背景/ヘッダのトーンだけ統一する。
# class_name は付けず preload 参照で使う。

const GameDialogStyle = preload("res://ui/components/game_dialog_style.gd")

const BG: Color = Color(0.047, 0.056, 0.068)
const PANEL: Color = Color(0.086, 0.104, 0.127)
const PANEL_2: Color = Color(0.112, 0.137, 0.167)
const PANEL_3: Color = Color(0.150, 0.182, 0.222)
const BORDER: Color = Color(0.205, 0.245, 0.300)
const BORDER_SOFT: Color = Color(0.140, 0.168, 0.205)
const TEXT: Color = Color(0.930, 0.948, 0.965)
const MUTED: Color = Color(0.605, 0.665, 0.725)
const BLUE: Color = Color(0.290, 0.610, 0.965)


# 画面全体の背面にダーク背景を敷く (full-bleed 化で素の背景が見えるのを防ぐ)。
static func add_background(screen: Control) -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(bg)
	screen.move_child(bg, 0)


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(7)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


static func style_button(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", _box(PANEL_3, BORDER))
	btn.add_theme_stylebox_override("hover", _box(Color(0.180, 0.220, 0.270), BORDER))
	btn.add_theme_stylebox_override("pressed", _box(PANEL_2, BLUE))
	btn.add_theme_stylebox_override("disabled", _box(PANEL, BORDER_SOFT))
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", TEXT)
	btn.add_theme_color_override("font_pressed_color", TEXT)


# プライマリ (戻る等の主要操作) 用の青ボタン。
static func style_primary(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", _box(BLUE, BLUE))
	btn.add_theme_stylebox_override("hover", _box(Color(0.360, 0.660, 1.0), BLUE))
	btn.add_theme_stylebox_override("pressed", _box(Color(0.180, 0.430, 0.800), BLUE))
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", TEXT)


static func style_title(label: Label) -> void:
	label.add_theme_color_override("font_color", TEXT)


# full-bleed 化で余白が消えて端まで詰まるため、ルートを内側へ寄せて余白を作る。
static func inset_root(root: Control, h: float = 28.0, v: float = 18.0) -> void:
	root.offset_left = h
	root.offset_top = v
	root.offset_right = -h
	root.offset_bottom = -v


# 背景 + 余白 + 明るめダークテーマ をまとめて適用する。
static func apply_chrome(screen: Control, root: Control) -> void:
	add_background(screen)
	inset_root(root)
	screen.theme = make_theme()


static func _flat(bg: Color, border: Color, radius: int = 6, pad: int = 6) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad
	s.content_margin_bottom = pad
	return s


# 黒背景の上で本文(表/ラベル/入力部)を読みやすくする明色テーマ。
# 画面ルートに割り当てると全子ノードへ波及する。
static func make_theme() -> Theme:
	var t: Theme = Theme.new()
	var accent: Color = Color(BLUE.r, BLUE.g, BLUE.b, 0.32)

	t.set_color("font_color", "Label", TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)

	# 一覧表 (Tree ノードを使う画面)
	t.set_color("font_color", "Tree", TEXT)
	t.set_color("font_hovered_color", "Tree", Color.WHITE)
	t.set_color("font_selected_color", "Tree", Color.WHITE)
	t.set_color("title_button_color", "Tree", TEXT)
	t.set_color("guide_color", "Tree", BORDER_SOFT)
	t.set_color("drop_position_color", "Tree", BLUE)
	t.set_stylebox("panel", "Tree", _flat(PANEL_2, BORDER, 8))
	t.set_stylebox("title_button_normal", "Tree", _flat(PANEL_3, BORDER, 4))
	t.set_stylebox("title_button_hover", "Tree", _flat(Color(0.180, 0.220, 0.270), BORDER, 4))
	t.set_stylebox("title_button_pressed", "Tree", _flat(PANEL_3, BLUE, 4))
	var sel: StyleBoxFlat = StyleBoxFlat.new()
	sel.bg_color = accent
	sel.set_corner_radius_all(4)
	t.set_stylebox("selected", "Tree", sel)
	t.set_stylebox("selected_focus", "Tree", sel)

	# 入力部
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", MUTED)
	t.set_stylebox("normal", "LineEdit", _flat(PANEL_2, BORDER, 6))
	t.set_stylebox("focus", "LineEdit", _flat(PANEL_2, BLUE, 6))

	# タブ
	t.set_color("font_selected_color", "TabContainer", TEXT)
	t.set_color("font_unselected_color", "TabContainer", MUTED)
	t.set_color("font_hovered_color", "TabContainer", TEXT)

	# 既定ボタン (個別 style_button 未適用のもの)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_stylebox("normal", "Button", _flat(PANEL_3, BORDER, 7))
	t.set_stylebox("hover", "Button", _flat(Color(0.180, 0.220, 0.270), BORDER, 7))
	t.set_stylebox("pressed", "Button", _flat(PANEL_2, BLUE, 7))

	GameDialogStyle.apply_popup_theme(t)
	return t
