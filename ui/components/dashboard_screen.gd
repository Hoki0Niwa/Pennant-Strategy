extends Control

# ダッシュボード系画面の共有基底 (2026-06-20)。
# ホーム画面で確立した「左サイドバー + ヘッダ + ダーク角丸パネル」の運用ダッシュボード体裁を
# 複数画面で再利用するため、チーム横断で使う部分 (配色パレット / 1920x1080 固定座標系の座標変換 /
# 描画プリミティブ / サイドバー / ヘッダ / オーバーレイボタン基盤) をここへ集約する。
# サブクラス (home_screen / rotation_editor_screen など) は本クラスを継承し、
#   _ready: super なし or 任意。_font と _sidebar_entries の初期化は _init_chrome() を呼ぶ。
#   _draw:  先頭で _draw_shell(title, team, season) を呼び、その後に本文を描画する。
#   ボタン: _build_nav_buttons() でサイドバーナビを生成し、固有アクションは _add_button() で足す。
# のように使う。スケールは min(sx, sy) 等倍 + 中央寄せで非16:9でも破綻させない。

const DeveloperTools = preload("res://services/development/developer_tools.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")

const BASE: Vector2 = Vector2(1920, 1080)

# --- パレット ---
const BG: Color = Color(0.047, 0.056, 0.068)
const SIDEBAR_BG: Color = Color(0.066, 0.078, 0.095)
const HEADER_BG: Color = Color(0.078, 0.092, 0.112)
const PANEL: Color = Color(0.086, 0.104, 0.127)
const PANEL_2: Color = Color(0.112, 0.137, 0.167)
const PANEL_3: Color = Color(0.150, 0.182, 0.222)
const BORDER: Color = Color(0.205, 0.245, 0.300)
const BORDER_SOFT: Color = Color(0.140, 0.168, 0.205)
const TEXT: Color = Color(0.930, 0.948, 0.965)
const MUTED: Color = Color(0.605, 0.665, 0.725)
const FAINT: Color = Color(0.395, 0.450, 0.510)
const BLUE: Color = Color(0.290, 0.610, 0.965)
const BLUE_SOFT: Color = Color(0.180, 0.380, 0.620)
const GREEN: Color = Color(0.235, 0.790, 0.490)
const RED: Color = Color(0.910, 0.370, 0.370)
const AMBER: Color = Color(0.955, 0.715, 0.255)

# --- レイアウト基準 (base 座標) ---
const SIDEBAR_W: float = 240.0
const HEADER_H: float = 86.0
const INNER_L: float = 262.0
const INNER_R: float = 1900.0

const NAV_GROUPS: Array = [
	{"title": "試合・情報", "items": [
		{"id": "home", "label": "ホーム", "icon": "home"},
		{"id": "game_results", "label": "試合結果", "icon": "results"},
		{"id": "standings", "label": "順位表", "icon": "standings"},
		{"id": "rankings", "label": "タイトル争い", "icon": "rankings"},
		{"id": "history", "label": "シーズン履歴", "icon": "history"},
	]},
	{"title": "チーム・選手", "items": [
		{"id": "team_detail", "label": "チーム詳細", "icon": "team"},
		{"id": "player_detail", "label": "選手詳細", "icon": "player"},
		{"id": "lineup_editor", "label": "打順設定", "icon": "lineup"},
		{"id": "rotation_editor", "label": "投手起用法", "icon": "pitch"},
		{"id": "active_roster", "label": "選手登録", "icon": "swap"},
	]},
	{"title": "設定・その他", "items": [
		{"id": "team_select", "label": "チーム選択", "icon": "teamselect"},
		{"id": "options", "label": "オプション", "icon": "options"},
	]},
]

# Noto Sans JP (可変フォント, wght 軸つき)。本文は Medium 寄り、見出しは Bold で描く。
const FONT_PATH: String = "res://assets/fonts/NotoSansJP.ttf"
const FONT_WEIGHT_BODY: int = 520
const FONT_WEIGHT_BOLD: int = 700

var _font: Font
var _font_bold: Font
var _buttons: Array = []
var _sidebar_entries: Array = []
var _scale_f: float = 1.0
var _offset: Vector2 = Vector2.ZERO


# サブクラスの _ready から呼ぶ。フォントとサイドバーレイアウトを初期化する。
func _init_chrome() -> void:
	var base: FontFile = load(FONT_PATH) as FontFile
	if base != null:
		# 文字列キー "wght" は無視されるため、TextServer の整数タグで weight 軸を指定する。
		var ts: TextServer = TextServerManager.get_primary_interface()
		var wght_tag: int = ts.name_to_tag("weight")
		# Noto Sans JP の Regular(400) は細く見えるので、本文は Medium 寄り、見出しは Bold にする。
		_font = _make_weighted(base, wght_tag, FONT_WEIGHT_BODY)
		_font_bold = _make_weighted(base, wght_tag, FONT_WEIGHT_BOLD)
	else:
		_font = ThemeDB.fallback_font
		_font_bold = _font
	_sidebar_entries = _build_sidebar_layout()


func _make_weighted(base: FontFile, wght_tag: int, weight: int) -> FontVariation:
	var fv: FontVariation = FontVariation.new()
	fv.base_font = base
	fv.variation_opentype = {wght_tag: weight}
	return fv


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_buttons()
		queue_redraw()


# ============================================================ shell draw

# 背景レイヤ + サイドバー + ヘッダ。サブクラスの _draw 冒頭で呼ぶ。
func _draw_shell(title: String, team: PSTeam, season: PSSeason) -> void:
	_round(Rect2(0, 0, SIDEBAR_W, BASE.y), SIDEBAR_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, 0), Vector2(SIDEBAR_W, BASE.y), BORDER_SOFT, 1.0)
	_round(Rect2(SIDEBAR_W, 0, BASE.x - SIDEBAR_W, HEADER_H), HEADER_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, HEADER_H), Vector2(BASE.x, HEADER_H), BORDER_SOFT, 1.0)
	_draw_sidebar()
	_draw_header(title, team, season)


func _draw_sidebar() -> void:
	_text("PennantStrategy", Vector2(20, 40), 22, TEXT)
	_text("ペナント戦略シミュレーション", Vector2(21, 62), 11, MUTED)

	var current: String = AppState.current_screen
	for entry_value in _sidebar_entries:
		var entry: Dictionary = entry_value as Dictionary
		if str(entry.get("type", "")) == "title":
			# カテゴリ見出し: 左に青のアクセントバー + 明るめの文字で「分類」だと一目で分かるようにする。
			var ty: float = float(entry["y"])
			var tcol: Color = MUTED.lerp(TEXT, 0.45)
			_round(Rect2(12, ty - 13, 3, 15), BLUE, Color.TRANSPARENT, 2, 0)
			_text(str(entry["label"]), Vector2(24, ty), 15, tcol, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
			continue
		var item: Dictionary = entry["item"] as Dictionary
		var rect: Rect2 = entry["rect"] as Rect2
		var active: bool = str(item.get("id", "")) == current
		if active:
			_round(rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.16), Color(BLUE.r, BLUE.g, BLUE.b, 0.55), 7)
			_round(Rect2(rect.position.x, rect.position.y + 6, 3, rect.size.y - 12), BLUE, Color.TRANSPARENT, 2, 0)
		_icon(str(item.get("icon", "")), Rect2(rect.position.x + 14, rect.position.y + 9, 20, 20), TEXT if active else MUTED)

	_text("Ver 1.0.0", Vector2(22, BASE.y - 24), 12, FAINT)


func _draw_header(title: String, team: PSTeam, season: PSSeason) -> void:
	# タイトル幅に応じて左から流すレイアウト (長いタイトルでもチーム名/日付と重ならない)。
	_text(title, Vector2(INNER_L, 56), 28, TEXT)
	var x: float = INNER_L + _measure(title, 28) + 28.0
	_line(Vector2(x, 26), Vector2(x, 60), BORDER, 1.0)
	x += 22.0
	_team_badge(Rect2(x, 23, 40, 40), team)
	x += 52.0
	_text(team.name, Vector2(x, 54), 20, TEXT)
	x += _measure(team.name, 20) + 24.0
	_line(Vector2(x, 26), Vector2(x, 60), BORDER, 1.0)
	x += 22.0
	var date_text: String = _format_date_long(SeasonCalendar.current_date(season))
	_text("%s    %d年目" % [date_text, season.season_number], Vector2(x, 52), 16, MUTED)


# ============================================================ sidebar layout

func _build_sidebar_layout() -> Array:
	var entries: Array = []
	var y: float = 96.0
	var groups: Array = NAV_GROUPS.duplicate(true)
	if DeveloperTools.enabled():
		(groups[2]["items"] as Array).append({"id": "balance_report", "label": "分析ツール", "icon": "options"})
	var first: bool = true
	for group_value in groups:
		var group: Dictionary = group_value as Dictionary
		# グループ間は広め、見出し→配下項目は狭めにして、見出しが自分の属する項目群と
		# 視覚的に近くなるようにする (見出しが直前グループへ寄って見える問題の対策)。
		if not first:
			y += 40
		first = false
		entries.append({"type": "title", "label": str(group["title"]), "y": y})
		y += 14
		for item_value in group["items"] as Array:
			entries.append({"type": "item", "item": item_value, "rect": Rect2(12, y, SIDEBAR_W - 24, 38)})
			y += 42
	return entries


# サイドバーの各ナビ項目に対応する遷移ボタンを生成する。
func _build_nav_buttons() -> void:
	for entry_value in _sidebar_entries:
		var entry: Dictionary = entry_value as Dictionary
		if str(entry.get("type", "")) != "item":
			continue
		var item: Dictionary = entry["item"] as Dictionary
		var screen_name: String = str(item["id"])
		var active: bool = screen_name == AppState.current_screen
		_add_button("nav_%s" % screen_name, str(item["label"]), entry["rect"] as Rect2,
			func(target: String = screen_name) -> void: AppState.request_screen(target),
			"nav_active" if active else "nav")


# ============================================================ buttons

func _add_button(id: String, label: String, base_rect: Rect2, callback: Callable, kind: String) -> Button:
	var button: Button = Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.clip_text = true
	if kind == "nav" or kind == "nav_active":
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(callback)
	add_child(button)
	_buttons.append({"id": id, "button": button, "rect": base_rect, "kind": kind})
	return button


func _clear_buttons() -> void:
	for child in get_children():
		if child is Button:
			child.queue_free()
	_buttons.clear()


func _layout_buttons() -> void:
	_update_transform()
	for spec_value in _buttons:
		var spec: Dictionary = spec_value as Dictionary
		var button: Button = spec["button"] as Button
		if button == null:
			continue
		var rect: Rect2 = _r(spec["rect"] as Rect2)
		button.position = rect.position
		button.size = rect.size
		_apply_button_style(button, str(spec.get("kind", "action")))


func _apply_button_style(button: Button, kind: String) -> void:
	var font_px: int = max(9, int(round(14.0 * _scale_f)))
	var nav_pad: int = int(round(40.0 * _scale_f))
	match kind:
		"primary":
			_style(button, BLUE, BLUE, TEXT, Color(0.360, 0.660, 1.0), Color(0.180, 0.430, 0.800))
		"action":
			_style(button, PANEL_3, BORDER, TEXT, Color(0.180, 0.220, 0.270), PANEL_2)
		"chip_active":
			_style(button, BLUE, BLUE, TEXT, Color(0.360, 0.660, 1.0), Color(0.180, 0.430, 0.800))
			font_px = max(9, int(round(13.0 * _scale_f)))
		"chip":
			_style(button, PANEL_2, BORDER, MUTED, Color(0.160, 0.200, 0.245), PANEL)
			font_px = max(9, int(round(13.0 * _scale_f)))
		"nav_active":
			_style(button, Color.TRANSPARENT, Color.TRANSPARENT, TEXT, Color(1, 1, 1, 0.06), Color(BLUE.r, BLUE.g, BLUE.b, 0.18), nav_pad)
		_:
			_style(button, Color.TRANSPARENT, Color.TRANSPARENT, MUTED, Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.09), nav_pad)
	if _font != null:
		button.add_theme_font_override("font", _font)
	button.add_theme_font_size_override("font_size", font_px)


func _style(button: Button, bg: Color, border: Color, fg: Color, hover: Color, pressed: Color, pad_left: int = 6) -> void:
	button.add_theme_stylebox_override("normal", _box(bg, border, pad_left))
	button.add_theme_stylebox_override("hover", _box(hover, border if border.a > 0.0 else BORDER, pad_left))
	button.add_theme_stylebox_override("pressed", _box(pressed, BLUE, pad_left))
	button.add_theme_stylebox_override("disabled", _box(PANEL, BORDER_SOFT, pad_left))
	button.add_theme_color_override("font_color", fg)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_disabled_color", FAINT)


func _box(bg: Color, border: Color, pad_left: int) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0.0 else 0)
	style.set_corner_radius_all(7)
	style.content_margin_left = pad_left
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


# ============================================================ draw primitives

func _update_transform() -> void:
	_scale_f = min(size.x / BASE.x, size.y / BASE.y)
	_offset = (size - BASE * _scale_f) * 0.5


func _p(v: Vector2) -> Vector2:
	return _offset + v * _scale_f


func _r(rect: Rect2) -> Rect2:
	return Rect2(_offset + rect.position * _scale_f, rect.size * _scale_f)


func _round(base_rect: Rect2, bg: Color, border: Color, radius: int, border_width: int = 1) -> void:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	draw_style_box(style, _r(base_rect))


func _text(text: String, base_pos: Vector2, base_size: int, color: Color, base_width: float = -1.0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, bold: bool = false) -> void:
	var f: Font = _font_bold if bold and _font_bold != null else _font
	draw_string(f, _p(base_pos), text, align, (base_width * _scale_f) if base_width > 0.0 else -1.0, max(8, int(round(float(base_size) * _scale_f))), color)


func _text_right(text: String, right_x: float, base_y: float, base_size: int, color: Color, box: float = 80.0) -> void:
	_text(text, Vector2(right_x - box, base_y), base_size, color, box, HORIZONTAL_ALIGNMENT_RIGHT)


func _line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	draw_line(_p(from), _p(to), color, width * _scale_f, true)


func _dot(base_center: Vector2, base_radius: float, color: Color) -> void:
	draw_circle(_p(base_center), base_radius * _scale_f, color)


func _chip(base_rect: Rect2, text: String, color: Color) -> void:
	_round(base_rect, Color(color.r, color.g, color.b, 0.18), Color(color.r, color.g, color.b, 0.5), 9)
	_text(text, Vector2(base_rect.position.x, base_rect.position.y + base_rect.size.y * 0.72), int(base_rect.size.y * 0.52), color, base_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


func _panel(base_rect: Rect2, title: String, color: Color = TEXT) -> void:
	_round(base_rect, PANEL, BORDER, 10)
	_text(title, Vector2(base_rect.position.x + 18, base_rect.position.y + 32), 16, color)


func _measure(text: String, base_size: int) -> float:
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, base_size).x


func _team_badge(base_rect: Rect2, team: PSTeam) -> void:
	var bg: Color = Color(team.color.r * 0.85, team.color.g * 0.85, team.color.b * 0.85, 1.0)
	_round(base_rect, bg, team.color, 9)
	var label: String = team.short_name.substr(0, 2) if team.short_name.length() > 0 else "?"
	var fg: Color = Color(0.05, 0.06, 0.08) if _luminance(bg) > 0.6 else Color.WHITE
	_text(label, Vector2(base_rect.position.x, base_rect.position.y + base_rect.size.y * 0.68), int(base_rect.size.y * 0.48), fg, base_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


func _luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


# 簡易ラインアイコン。base 座標の box 内に正規化座標で描く。
func _icon(name: String, box: Rect2, color: Color) -> void:
	var r: Rect2 = _r(box)
	var w: float = max(1.3, 1.9 * _scale_f)
	var pt: Callable = func(x: float, y: float) -> Vector2: return r.position + Vector2(x * r.size.x, y * r.size.y)
	var seg: Callable = func(x0: float, y0: float, x1: float, y1: float) -> void:
		draw_line(r.position + Vector2(x0 * r.size.x, y0 * r.size.y), r.position + Vector2(x1 * r.size.x, y1 * r.size.y), color, w, true)
	var poly: Callable = func(pts: PackedVector2Array) -> void:
		draw_colored_polygon(pts, color)
	match name:
		"home":
			seg.call(0.12, 0.52, 0.5, 0.16)
			seg.call(0.5, 0.16, 0.88, 0.52)
			seg.call(0.22, 0.48, 0.22, 0.9)
			seg.call(0.78, 0.48, 0.78, 0.9)
			seg.call(0.22, 0.9, 0.78, 0.9)
			seg.call(0.43, 0.9, 0.43, 0.66)
			seg.call(0.57, 0.9, 0.57, 0.66)
			seg.call(0.43, 0.66, 0.57, 0.66)
		"skip":
			poly.call(PackedVector2Array([pt.call(0.14, 0.22), pt.call(0.14, 0.78), pt.call(0.5, 0.5)]))
			poly.call(PackedVector2Array([pt.call(0.5, 0.22), pt.call(0.5, 0.78), pt.call(0.86, 0.5)]))
		"results":
			for v in [0.28, 0.5, 0.72]:
				draw_circle(pt.call(0.2, v), w * 1.1, color)
				seg.call(0.36, v, 0.86, v)
		"standings":
			draw_rect(Rect2(pt.call(0.18, 0.55), Vector2(0.16 * r.size.x, 0.33 * r.size.y)), color)
			draw_rect(Rect2(pt.call(0.42, 0.4), Vector2(0.16 * r.size.x, 0.48 * r.size.y)), color)
			draw_rect(Rect2(pt.call(0.66, 0.26), Vector2(0.16 * r.size.x, 0.62 * r.size.y)), color)
		"rankings":
			draw_arc(pt.call(0.5, 0.42), 0.26 * r.size.x, 0, TAU, 20, color, w, true)
			seg.call(0.4, 0.62, 0.34, 0.9)
			seg.call(0.6, 0.62, 0.66, 0.9)
			seg.call(0.34, 0.9, 0.5, 0.78)
			seg.call(0.66, 0.9, 0.5, 0.78)
		"history":
			draw_arc(pt.call(0.5, 0.5), 0.34 * r.size.x, 0, TAU, 24, color, w, true)
			seg.call(0.5, 0.5, 0.5, 0.28)
			seg.call(0.5, 0.5, 0.66, 0.58)
		"team":
			var sh: PackedVector2Array = PackedVector2Array([pt.call(0.5, 0.12), pt.call(0.85, 0.26), pt.call(0.8, 0.6), pt.call(0.5, 0.9), pt.call(0.2, 0.6), pt.call(0.15, 0.26)])
			for i in range(sh.size()):
				draw_line(sh[i], sh[(i + 1) % sh.size()], color, w, true)
		"swap":
			seg.call(0.34, 0.82, 0.34, 0.2)
			seg.call(0.34, 0.2, 0.26, 0.32)
			seg.call(0.34, 0.2, 0.42, 0.32)
			seg.call(0.66, 0.18, 0.66, 0.8)
			seg.call(0.66, 0.8, 0.58, 0.68)
			seg.call(0.66, 0.8, 0.74, 0.68)
		"lineup":
			for v in [0.3, 0.5, 0.7]:
				draw_rect(Rect2(pt.call(0.16, v - 0.06), Vector2(0.12 * r.size.x, 0.12 * r.size.y)), color)
				seg.call(0.38, v, 0.86, v)
		"role", "options":
			draw_arc(pt.call(0.5, 0.5), 0.24 * r.size.x, 0, TAU, 20, color, w, true)
			draw_circle(pt.call(0.5, 0.5), 0.07 * r.size.x, color)
			for k in range(6):
				var a: float = float(k) / 6.0 * TAU
				var dir: Vector2 = Vector2(cos(a), sin(a))
				draw_line(pt.call(0.5, 0.5) + dir * 0.3 * r.size.x, pt.call(0.5, 0.5) + dir * 0.42 * r.size.x, color, w, true)
		"pitch":
			# 野球ボール: 塗りつぶした球 + 左右の縁に沿う細い縫い目2本 (中央は白く広く残す)。
			draw_circle(pt.call(0.5, 0.5), 0.38 * r.size.x, color)
			var seam_radius: float = 0.62 * r.size.x
			var seam_w: float = max(1.0, w * 0.9)
			draw_arc(pt.call(0.80, 0.5), seam_radius, deg_to_rad(155.0), deg_to_rad(205.0), 16, BG, seam_w, true)
			draw_arc(pt.call(0.20, 0.5), seam_radius, deg_to_rad(-25.0), deg_to_rad(25.0), 16, BG, seam_w, true)
		"player":
			draw_arc(pt.call(0.5, 0.34), 0.16 * r.size.x, 0, TAU, 16, color, w, true)
			poly.call(PackedVector2Array([pt.call(0.26, 0.9), pt.call(0.34, 0.62), pt.call(0.66, 0.62), pt.call(0.74, 0.9)]))
		"teamselect":
			seg.call(0.22, 0.38, 0.78, 0.38)
			seg.call(0.78, 0.38, 0.66, 0.28)
			seg.call(0.78, 0.38, 0.66, 0.48)
			seg.call(0.78, 0.64, 0.22, 0.64)
			seg.call(0.22, 0.64, 0.34, 0.54)
			seg.call(0.22, 0.64, 0.34, 0.74)
		"rank":
			poly.call(PackedVector2Array([pt.call(0.32, 0.2), pt.call(0.68, 0.2), pt.call(0.6, 0.54), pt.call(0.4, 0.54)]))
			seg.call(0.5, 0.54, 0.5, 0.72)
			seg.call(0.34, 0.84, 0.66, 0.84)
			seg.call(0.4, 0.72, 0.6, 0.72)
		"record":
			seg.call(0.24, 0.8, 0.72, 0.22)
			seg.call(0.28, 0.22, 0.76, 0.8)
			draw_circle(pt.call(0.24, 0.8), w * 1.3, color)
			draw_circle(pt.call(0.76, 0.8), w * 1.3, color)
		"winrate":
			seg.call(0.16, 0.84, 0.16, 0.18)
			seg.call(0.16, 0.84, 0.86, 0.84)
			seg.call(0.2, 0.7, 0.42, 0.46)
			seg.call(0.42, 0.46, 0.6, 0.6)
			seg.call(0.6, 0.6, 0.84, 0.24)
		"gb":
			seg.call(0.5, 0.2, 0.2, 0.8)
			seg.call(0.5, 0.2, 0.8, 0.8)
			seg.call(0.2, 0.8, 0.8, 0.8)
		"remaining":
			for i in range(4):
				draw_line(r.position + Vector2((0.2 + i * 0.16) * r.size.x, 0.28 * r.size.y), r.position + Vector2((0.2 + i * 0.16) * r.size.x, 0.84 * r.size.y), color, max(1.0, w * 0.7), true)
			seg.call(0.16, 0.28, 0.84, 0.28)
			seg.call(0.16, 0.84, 0.84, 0.84)
			seg.call(0.16, 0.28, 0.16, 0.84)
			seg.call(0.84, 0.28, 0.84, 0.84)
			seg.call(0.16, 0.44, 0.84, 0.44)
		"budget":
			draw_arc(pt.call(0.5, 0.5), 0.34 * r.size.x, 0, TAU, 24, color, w, true)
			seg.call(0.5, 0.4, 0.38, 0.28)
			seg.call(0.5, 0.4, 0.62, 0.28)
			seg.call(0.5, 0.4, 0.5, 0.66)
			seg.call(0.4, 0.5, 0.6, 0.5)
			seg.call(0.4, 0.58, 0.6, 0.58)
		"payroll":
			seg.call(0.18, 0.32, 0.82, 0.32)
			seg.call(0.18, 0.32, 0.18, 0.78)
			seg.call(0.82, 0.32, 0.82, 0.78)
			seg.call(0.18, 0.78, 0.82, 0.78)
			seg.call(0.55, 0.45, 0.82, 0.45)
			seg.call(0.55, 0.45, 0.55, 0.62)
			seg.call(0.55, 0.62, 0.82, 0.62)
			draw_circle(pt.call(0.66, 0.535), w * 1.1, color)
		_:
			draw_circle(pt.call(0.5, 0.5), 0.16 * r.size.x, color)


# ============================================================ formatting

func _rate_short(value: float) -> String:
	var s: String = "%0.3f" % value
	if s.begins_with("0."):
		return s.substr(1)
	return s


func _float1(value: float) -> String:
	return "%0.1f" % value


func _format_money(man_value: int) -> String:
	var oku: int = int(float(man_value) / 10000.0)
	var man: int = man_value - oku * 10000
	if oku > 0:
		return "%s億%s万円" % [_comma(oku), _comma(man)]
	return "%s万円" % _comma(man)


func _comma(value: int) -> String:
	var s: String = str(absi(value))
	var out: String = ""
	var c: int = 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out


func _format_date_long(date_text: String) -> String:
	var d: Dictionary = _parse_date(date_text)
	return "%d年 %d月%d日" % [int(d.get("year", 0)), int(d.get("month", 0)), int(d.get("day", 0))]


func _parse_date(date_text: String) -> Dictionary:
	var parts: PackedStringArray = date_text.split("-")
	return {
		"year": int(parts[0]) if parts.size() > 0 else 1970,
		"month": int(parts[1]) if parts.size() > 1 else 1,
		"day": int(parts[2]) if parts.size() > 2 else 1,
	}
