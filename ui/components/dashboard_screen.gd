extends Control

# ダッシュボード系画面の共有基底。
# 1920x1080 の base 座標を現在 viewport へ等倍変換し、左サイドバー・ヘッダ・共通描画部品・
# オーバーレイボタン管理を提供する。サブクラスは _init_chrome() でフォント/ナビを初期化し、
# _draw() の先頭で _draw_shell(title, team, season) を呼んでから本文を描く。
# 固有アクションは _add_button()、サイドバーナビは _build_nav_buttons() で生成する。

const AppVersion = preload("res://services/app_version.gd")
const DeveloperTools = preload("res://services/development/developer_tools.gd")
const SeasonCalendar = preload("res://services/season/season_calendar.gd")
const GameDialogStyle = preload("res://ui/components/game_dialog_style.gd")

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
# 守備位置/投手役割の色 (全ダッシュボード画面で共通)。投=PINK / DH=VIOLET。
const PINK: Color = Color(0.94, 0.46, 0.66)
const VIOLET: Color = Color(0.64, 0.52, 0.96)
# 表・帯のヘアライン区切り (BORDER_SOFT の半透過)。行区切り/縦区切りなど、面を割らずに
# 整列だけを見せたい罫線に使う (実線の枠は BORDER / BORDER_SOFT のまま)。
const HAIRLINE: Color = Color(0.140, 0.168, 0.205, 0.5)

# --- タイポグラフィスケール (base px) ---
# 文字サイズの階層はこの4段に寄せる: ラベル(補足/表ヘッダ) / セル(表本文) /
# セクション見出し(表タイトル) / KPI値(_stat_strip の数値)。opts での明示指定はそのまま優先。
const FS_LABEL: int = 11
const FS_CELL: int = 14
const FS_SECTION: int = 17
const FS_VALUE: int = 30

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
		{"id": "ability_stats", "label": "能力・成績一覧", "icon": "record"},
		{"id": "history", "label": "シーズン履歴", "icon": "history"},
	]},
	{"title": "チーム・選手", "items": [
		{"id": "team_detail", "label": "チーム詳細", "icon": "team"},
		{"id": "player_detail", "label": "選手詳細", "icon": "player"},
		{"id": "lineup_editor", "label": "打順・守備位置", "icon": "lineup"},
		{"id": "rotation_editor", "label": "投手起用法", "icon": "pitch"},
		{"id": "active_roster", "label": "選手登録", "icon": "swap"},
		{"id": "trade", "label": "トレード", "icon": "swap"},
	]},
	{"title": "設定・その他", "items": [
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

	_text(_app_version_label(), Vector2(22, BASE.y - 24), 12, FAINT)


func _app_version_label() -> String:
	return AppVersion.label()


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


func _style_popup(menu: PopupMenu) -> void:
	GameDialogStyle.style_popup(menu, _font, _scale_f)


func _style_confirmation_dialog(dialog: ConfirmationDialog) -> void:
	GameDialogStyle.style_confirmation(dialog, _font, _scale_f)


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


func _text_right(text: String, right_x: float, base_y: float, base_size: int, color: Color, box: float = 80.0, bold: bool = false) -> void:
	_text(text, Vector2(right_x - box, base_y), base_size, color, box, HORIZONTAL_ALIGNMENT_RIGHT, bold)


func _line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
	draw_line(_p(from), _p(to), color, width * _scale_f, true)


func _dot(base_center: Vector2, base_radius: float, color: Color) -> void:
	draw_circle(_p(base_center), base_radius * _scale_f, color)


# 勝敗記号を図形で描く。ダークモードではフォントの ○/● が判別しづらいため、
# 白星 (勝ち="○") は白丸、黒星 (負け="●") は黒丸 + 白縁で塗り分ける (絵文字の白丸/黒丸相当)。
# それ以外 (引分"△" や勝者略称などの文字列) は fallback 色のテキストで描く。
func _draw_result_mark(base_center: Vector2, base_radius: float, symbol: String, fallback: Color) -> void:
	var c: Vector2 = _p(base_center)
	var r: float = base_radius * _scale_f
	# 白星と黒星でシルエット (塗り半径 + 白縁) を揃える。縁はほんの少し細め。
	var stroke: float = max(1.0, 1.2 * _scale_f)
	match symbol:
		"○":
			draw_circle(c, r, TEXT)
			draw_arc(c, r, 0.0, TAU, 28, TEXT, stroke, true)
		"●":
			draw_circle(c, r, Color(0.03, 0.04, 0.05))
			draw_arc(c, r, 0.0, TAU, 28, TEXT, stroke, true)
		"△":
			# 引分も黒星と同じく黒塗り + 白縁。形 (三角) で勝敗と区別する。
			var p0: Vector2 = c + Vector2(0.0, -r)
			var p1: Vector2 = c + Vector2(r * 0.92, r * 0.72)
			var p2: Vector2 = c + Vector2(-r * 0.92, r * 0.72)
			draw_colored_polygon(PackedVector2Array([p0, p1, p2]), Color(0.03, 0.04, 0.05))
			draw_polyline(PackedVector2Array([p0, p1, p2, p0]), TEXT, stroke, true)
		_:
			_text(symbol, Vector2(base_center.x - base_radius, base_center.y + base_radius * 0.78),
				int(round(base_radius * 1.9)), fallback, base_radius * 2.0, HORIZONTAL_ALIGNMENT_CENTER)


# filled=true は塗り (背景 0.14 + 枠 0.5)、false は枠のみ (背景なし + 枠を濃く)。
# 塗り/アウトラインで支配下/育成などの2状態を色を変えずに描き分けるのに使う。
func _chip(base_rect: Rect2, text: String, color: Color, filled: bool = true) -> void:
	var bg_alpha: float = 0.14 if filled else 0.0
	var border_alpha: float = 0.5 if filled else 0.85
	_round(base_rect, Color(color.r, color.g, color.b, bg_alpha), Color(color.r, color.g, color.b, border_alpha), 5)
	_text(text, Vector2(base_rect.position.x, base_rect.position.y + base_rect.size.y * 0.72), int(base_rect.size.y * 0.52), color, base_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)


# フラットパネル (枠線なし)。タイトルは bold + 左に BLUE のアクセントティック
# (サイドバーのカテゴリ見出しと同じ言語)。title 空文字ならタイトル領域は描かない。
func _panel(base_rect: Rect2, title: String, color: Color = TEXT) -> void:
	_round(base_rect, PANEL, Color.TRANSPARENT, 8, 0)
	if title.is_empty():
		return
	_round(Rect2(base_rect.position.x + 18, base_rect.position.y + 19, 3, 14), BLUE, Color.TRANSPARENT, 2, 0)
	_text(title, Vector2(base_rect.position.x + 27, base_rect.position.y + 32), 16, color, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)


# KPI帯: アイコン付き個別カード列の置き換え。1枚のフラットな帯に cells を等幅で並べ、
# セル間は縦ヘアラインで区切る。各 cell:
#   {label:String, value:String, color?:Color(値の色, 既定TEXT), note?:String(値の右の小さな補足), note_color?:Color}
# 値は FS_VALUE bold を基準に、セル幅へ収まらない場合のみ段階的に縮小する (欠けよりも縮小を優先)。
func _stat_strip(base_rect: Rect2, cells: Array) -> void:
	_round(base_rect, PANEL, Color.TRANSPARENT, 8, 0)
	if cells.is_empty():
		return
	var cell_w: float = base_rect.size.x / float(cells.size())
	for i in range(cells.size()):
		var cell: Dictionary = cells[i] as Dictionary
		var cx: float = base_rect.position.x + cell_w * float(i)
		if i > 0:
			_line(Vector2(cx, base_rect.position.y + 14.0), Vector2(cx, base_rect.end.y - 14.0), HAIRLINE, 1.0)
		var pad: float = 20.0
		# ラベルと値の縦位置・値サイズは帯の高さから決める (高さ72前後の低い帯でも
		# ラベルと値が重ならないように)。値は高さの約36%を上限とし FS_VALUE を超えない。
		var strip_h: float = base_rect.size.y
		_text(str(cell.get("label", "")), Vector2(cx + pad, base_rect.position.y + 22.0), FS_LABEL, MUTED)
		var value: String = str(cell.get("value", ""))
		var note: String = str(cell.get("note", ""))
		var note_w: float = (_measure(note, FS_LABEL) + 10.0) if not note.is_empty() else 0.0
		var max_w: float = cell_w - pad * 2.0 - note_w
		# bold は body より僅かに広い。_measure は body 基準なので 6% の余裕を見て縮める。
		var vsize: int = mini(FS_VALUE, int(strip_h * 0.36))
		while vsize > 16 and _measure(value, vsize) * 1.06 > max_w:
			vsize -= 2
		var vy: float = base_rect.end.y - max(14.0, strip_h * 0.18)
		_text(value, Vector2(cx + pad, vy), vsize, cell.get("color", TEXT) as Color, max_w, HORIZONTAL_ALIGNMENT_LEFT, true)
		if not note.is_empty():
			_text(note, Vector2(cx + pad + min(max_w, _measure(value, vsize) * 1.06) + 8.0, vy), FS_LABEL,
				cell.get("note_color", MUTED) as Color)


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


# 守備位置 (1-10) → 役割色。全画面共通: 投=PINK / 捕=BLUE / 内野(一二三遊)=AMBER / 外野(左中右)=GREEN / DH=VIOLET。
# lineup_editor / active_roster / team_detail が共用する (各画面の重複実装は廃止)。
func _pos_color(pos: int) -> Color:
	match pos:
		1:
			return PINK
		2:
			return BLUE
		3, 4, 5, 6:
			return AMBER
		7, 8, 9:
			return GREEN
		10:
			return VIOLET
		_:
			return MUTED


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
			var radius: float = min(r.size.x, r.size.y) * 0.39
			var center: Vector2 = pt.call(0.5, 0.5)
			var seam_radius: float = radius * 1.18
			var seam_offset: float = radius * 0.70
			var seam_w: float = max(1.0, w * 0.85)
			draw_arc(center, radius, 0.0, TAU, 32, color, w, true)
			draw_arc(center + Vector2(seam_offset, 0.0), seam_radius, deg_to_rad(145.0), deg_to_rad(215.0), 18, color, seam_w, true)
			draw_arc(center - Vector2(seam_offset, 0.0), seam_radius, deg_to_rad(-35.0), deg_to_rad(35.0), 18, color, seam_w, true)
			_draw_baseball_stitches(center + Vector2(seam_offset, 0.0), seam_radius, [156.0, 180.0, 204.0], color, radius, seam_w)
			_draw_baseball_stitches(center - Vector2(seam_offset, 0.0), seam_radius, [-24.0, 0.0, 24.0], color, radius, seam_w)
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


func _draw_baseball_stitches(arc_center: Vector2, arc_radius: float, angles_degrees: Array, color: Color, ball_radius: float, width: float) -> void:
	var half_len: float = max(1.8 * _scale_f, ball_radius * 0.12)
	var stroke: float = max(1.0, width * 0.70)
	for value in angles_degrees:
		var angle: float = deg_to_rad(float(value))
		var dir: Vector2 = Vector2(cos(angle), sin(angle))
		var p: Vector2 = arc_center + dir * arc_radius
		draw_line(p - dir * half_len, p + dir * half_len, color, stroke, true)


# ============================================================ shared data table

# 共通テーブル描画 (2026-06-24)。各画面に重複していた _draw_table / _draw_table_row / _fmt_cell を集約。
# 列 columns: 幅 = w / 整列 = align ("l"|"left"/"c"|"center"/"r"|"right", 無指定は default_align) / 書式 = fmt。
#   任意キー: sep_before:bool (列の左に縦ヘアライン。列グループの境界表現) /
#   strong:bool (セルを bold で描く。選手名・球団名列の強調用)。
# 行 rows は key->値の Dictionary。特殊キー: __meta(選択/当たり判定) / __color(行文字色) /
# is_self (左端の BLUE アクセントバー + 薄い青地) / is_leader / is_total (強調)。
# opts (すべて任意):
#   panel:bool(=true) パネル背景を描く / title:String 見出し / right_label:String 右肩ラベル
#   title_size(=FS_SECTION) title_pad(=18) title_y(=32) title_width(=-1)
#   header_top(=60 見出し行テキストの rect 上端からのベースライン y。ヘッダ帯は
#     header_top-18 〜 header_top+8 の 26px。ヒット判定を複製する画面はこの幾何に追従させる)
#   header_size(=12) cell_size(=FS_CELL)
#   inner_pad(=12) bottom_pad(=8) default_align("left"|"right", =推論) empty_text:String
#   row_h(=0 → 行数で均等ストレッチ。上限は row_h_max、未指定時 34.0。0 を明示すると上限なし)
#   alt_rows:bool (互換のため受け取るが縞は描かない。行区切りのヘアラインで代替)
#   scroll_key:String + scroll:Dictionary + scroll_zones:Array (固定行高 row_h>0 のときホイールスクロール)
#   sel_kind:String + selected_id:int + hits:Array (__meta 行を選択可能にし hits へ当たり判定を push)
func _draw_data_table(rect: Rect2, columns: Array, rows: Array, opts: Dictionary = {}) -> void:
	if bool(opts.get("panel", true)):
		_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	var title: String = str(opts.get("title", ""))
	if not title.is_empty():
		var title_pad: float = float(opts.get("title_pad", 18.0))
		var title_y: float = float(opts.get("title_y", 32.0))
		_round(Rect2(rect.position.x + title_pad, rect.position.y + title_y - 13.0, 3, 14), BLUE, Color.TRANSPARENT, 2, 0)
		_text(title, Vector2(rect.position.x + title_pad + 9.0, rect.position.y + title_y),
			int(opts.get("title_size", FS_SECTION)), TEXT, float(opts.get("title_width", -1.0)), HORIZONTAL_ALIGNMENT_LEFT, true)
	var right_label: String = str(opts.get("right_label", ""))
	if not right_label.is_empty():
		_text_right(right_label, rect.end.x - 18.0, rect.position.y + 30.0, 12, MUTED, 200.0)

	var default_align: String = str(opts.get("default_align", ""))
	var inner_pad: float = float(opts.get("inner_pad", 12.0))
	var inner_x: float = rect.position.x + inner_pad
	var usable: float = rect.size.x - inner_pad * 2.0
	var sum_w: float = 0.0
	for col_value in columns:
		sum_w += _col_width(col_value as Dictionary)
	var factor: float = usable / sum_w if sum_w > 0.0 else 1.0

	# ヘッダ帯: 列領域全幅に PANEL_2 の帯 + bold ラベル、下端に太めのルール線。
	var header_size: int = int(opts.get("header_size", 12))
	var hy: float = rect.position.y + float(opts.get("header_top", 60.0))
	var band_top: float = hy - 18.0
	_round(Rect2(inner_x, band_top, usable, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	var sep_xs: Array = []   # sep_before 列の左端 x (縦ヘアラインは行描画後にまとめて引く)
	var cx: float = inner_x
	for col_value in columns:
		var col: Dictionary = col_value as Dictionary
		var w: float = _col_width(col) * factor
		if bool(col.get("sep_before", false)) and cx > inner_x:
			sep_xs.append(cx)
		var content_w: float = _col_content_width(col, w, factor)
		var header_delta_w: float = _growth_delta_width(col, factor)
		var header_w: float = max(8.0, content_w - header_delta_w) if header_delta_w > 0.0 else content_w
		match _col_align(col, default_align):
			HORIZONTAL_ALIGNMENT_LEFT:
				_text(str(col.get("title", "")), Vector2(cx + 4.0, hy), header_size, MUTED, header_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
			HORIZONTAL_ALIGNMENT_CENTER:
				_text(str(col.get("title", "")), Vector2(cx + 2.0, hy), header_size, MUTED, header_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER, true)
			_:
				_text_right(str(col.get("title", "")), cx + header_w - 4.0, hy, header_size, MUTED, header_w - 6.0, true)
		cx += w
	var line_y: float = hy + 8.0
	_line(Vector2(inner_x, line_y), Vector2(rect.end.x - inner_pad, line_y), BORDER, 1.5)

	if rows.is_empty():
		var empty_text: String = str(opts.get("empty_text", ""))
		if not empty_text.is_empty():
			_text(empty_text, Vector2(inner_x + 6.0, rect.position.y + rect.size.y * 0.55), 14, MUTED)
		return

	var row_top: float = line_y + 6.0
	var area_h: float = rect.end.y - row_top - float(opts.get("bottom_pad", 8.0))
	var row_h: float = float(opts.get("row_h", 0.0))
	var scroll_key: String = str(opts.get("scroll_key", ""))
	var offset: int = 0
	var visible: int = rows.size()
	if row_h > 0.0:
		visible = max(1, int(area_h / row_h))
		if not scroll_key.is_empty():
			var scroll: Dictionary = opts.get("scroll", {}) as Dictionary
			var max_off: int = max(0, rows.size() - visible)
			offset = clampi(int(scroll.get(scroll_key, 0)), 0, max_off)
			scroll[scroll_key] = offset
			if max_off > 0:
				(opts.get("scroll_zones", []) as Array).append({"rect": rect, "key": scroll_key, "max": max_off})
	else:
		# 均等ストレッチは上限つき (表ごとに行高が伸びてバラつかないように)。
		# row_h_max 明示があればそれを優先し、0 の明示は「上限なし」の意味を保つ。
		row_h = area_h / float(rows.size())
		var row_h_max: float = float(opts.get("row_h_max", 34.0))
		if row_h_max > 0.0:
			row_h = min(row_h_max, row_h)

	var sel_kind: String = str(opts.get("sel_kind", ""))
	var selected_id: int = int(opts.get("selected_id", 0))
	var cell_size: int = int(opts.get("cell_size", FS_CELL))
	var hits: Array = opts.get("hits", []) as Array
	var drawn: int = 0
	for vi in range(visible):
		var ri: int = offset + vi
		if ri >= rows.size():
			break
		var ry: float = row_top + float(vi) * row_h
		_draw_data_row(rect, inner_x, factor, columns, rows[ri] as Dictionary, ry, row_h,
			default_align, cell_size, sel_kind, selected_id, ri, hits)
		# 全行の下にヘアライン区切り (縞の代わりに罫線で行を刻む)。
		_line(Vector2(inner_x, ry + row_h), Vector2(inner_x + usable, ry + row_h), HAIRLINE, 1.0)
		drawn += 1

	# 列グループ境界の縦ヘアライン (ヘッダ帯上端から最終行の下端まで)。
	var rows_bottom: float = row_top + float(drawn) * row_h
	for sep_x_value in sep_xs:
		_line(Vector2(float(sep_x_value), band_top), Vector2(float(sep_x_value), rows_bottom), HAIRLINE, 1.0)

	if not scroll_key.is_empty() and rows.size() > visible:
		_text_right("%d / %d" % [min(offset + visible, rows.size()), rows.size()], rect.end.x - 14.0, rect.end.y - 8.0, 10, FAINT, 120.0)


# index は行番号 (現状は当たり判定/強調に未使用だが、呼び出し互換のため残す)。
func _draw_data_row(rect: Rect2, inner_x: float, factor: float, columns: Array, row: Dictionary, ry: float, row_h: float, default_align: String, cell_size: int, sel_kind: String, selected_id: int, _index: int, hits: Array) -> void:
	var has_meta: bool = row.has("__meta")
	var meta: int = int(row.get("__meta", 0)) if has_meta else 0
	var selectable: bool = not sel_kind.is_empty() and has_meta
	var is_self: bool = bool(row.get("is_self", false))
	var is_total: bool = bool(row.get("is_total", false))
	var is_leader: bool = bool(row.get("is_leader", false))
	if selectable and selected_id != 0 and meta == selected_id:
		_round(Rect2(rect.position.x + 8.0, ry + 1.0, rect.size.x - 16.0, row_h - 2.0), Color(BLUE.r, BLUE.g, BLUE.b, 0.16), Color(BLUE.r, BLUE.g, BLUE.b, 0.5), 6, 1)
	elif is_self:
		# 自軍行: 左端の 3px BLUE アクセントバー + ごく薄い青地。文字色は通常のまま。
		_round(Rect2(rect.position.x + 4.0, ry, rect.size.x - 8.0, row_h), Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 0, 0)
		_round(Rect2(rect.position.x + 4.0, ry, 3.0, row_h), BLUE, Color.TRANSPARENT, 0, 0)
	elif is_total:
		_round(Rect2(rect.position.x + 10.0, ry + 1.0, rect.size.x - 20.0, row_h - 2.0), Color(BLUE.r, BLUE.g, BLUE.b, 0.10), Color.TRANSPARENT, 6, 0)
	var base_color: Color = TEXT
	if row.has("__color"):
		base_color = row["__color"] as Color
	elif is_total:
		base_color = BLUE
	var bold: bool = is_total
	var ty: float = ry + row_h * 0.5 + 5.0
	var cx: float = inner_x
	for col_value in columns:
		var col: Dictionary = col_value as Dictionary
		var key: String = str(col.get("key", ""))
		var w: float = _col_width(col) * factor
		var content_w: float = _col_content_width(col, w, factor)
		# strong 列 (選手名/球団名など) は行の bold 指定と独立してセル単位で bold にする。
		var cell_bold: bool = bold or bool(col.get("strong", false))
		match _col_format(col):
			"rank":
				_text(str(row.get("rank", "")), Vector2(cx + 4.0, ty), cell_size, AMBER if is_leader else base_color, content_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, is_leader)
			"team":
				_dot(Vector2(cx + 9.0, ry + row_h * 0.5), 5.0, row.get("color", MUTED) as Color)
				_text(str(row.get("team", "")), Vector2(cx + 20.0, ty), cell_size, base_color, content_w - 24.0, HORIZONTAL_ALIGNMENT_LEFT, cell_bold)
			"pos_badge":
				# 守備位置/役割を色付きチップで描く。row[key]=表示文字 / row[key+"_color"]=色。
				# row[key+"_dev"]=true なら育成選手としてアウトライン (枠のみ) で描く。
				var badge_text: String = str(row.get(key, ""))
				if not badge_text.is_empty():
					var bw: float = min(content_w - 8.0, 40.0)
					_chip(Rect2(cx + (content_w - bw) * 0.5, ry + row_h * 0.5 - 11.0, bw, 22.0),
						badge_text, row.get("%s_color" % key, MUTED) as Color,
						not bool(row.get("%s_dev" % key, false)))
			"diff":
				var dv: int = int(row.get(key, 0))
				var dcol: Color = GREEN if dv > 0 else (RED if dv < 0 else MUTED)
				_text_right(("+%d" % dv) if dv > 0 else str(dv), cx + content_w - 6.0, ty, cell_size, dcol, content_w - 8.0)
			"delta":
				if row.has(key):
					var delta_value: int = int(row.get(key, 0))
					if delta_value != 0:
						var delta_col: Color = GREEN if delta_value > 0 else RED
						_text_right(("+%d" % delta_value) if delta_value > 0 else str(delta_value), cx + content_w - 6.0, ty, cell_size, delta_col, content_w - 8.0)
			"growth":
				# 能力の変化セル: row[key] = {after, delta, suffix}。後値は能力段階色、増減値(+N/-N)は緑/赤で色分け。
				var fixed_delta_w: float = _growth_delta_width(col, factor)
				var value_w: float = max(8.0, content_w - fixed_delta_w) if fixed_delta_w > 0.0 else content_w
				var gcell: Dictionary = row.get(key, {}) as Dictionary
				if gcell.is_empty():
					match _col_align(col, default_align):
						HORIZONTAL_ALIGNMENT_LEFT:
							_text("-", Vector2(cx + 4.0, ty), cell_size, FAINT, value_w - 8.0)
						HORIZONTAL_ALIGNMENT_CENTER:
							_text("-", Vector2(cx + 2.0, ty), cell_size, FAINT, value_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER)
						_:
							_text_right("-", cx + value_w - 6.0, ty, cell_size, FAINT, value_w - 8.0)
					cx += w
					continue
				var after_value: int = int(gcell.get("after", 0))
				var suffix: String = str(gcell.get("suffix", ""))
				var after_text: String = "%d%s" % [after_value, suffix]
				var gdelta: int = int(gcell.get("delta", 0))
				var after_color: Color = _growth_value_color(key, after_value, suffix)
				var delta_text: String = "(%+d)" % gdelta if gdelta != 0 else ""
				var compact_delta_text: String = "%+d" % gdelta if gdelta != 0 else ""
				var gcol: Color = GREEN if gdelta > 0 else RED
				if fixed_delta_w > 0.0:
					match _col_align(col, default_align):
						HORIZONTAL_ALIGNMENT_LEFT:
							_text(after_text, Vector2(cx + 4.0, ty), cell_size, after_color, value_w - 8.0)
						HORIZONTAL_ALIGNMENT_CENTER:
							_text(after_text, Vector2(cx + 2.0, ty), cell_size, after_color, value_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER)
						_:
							_text_right(after_text, cx + value_w - 6.0, ty, cell_size, after_color, value_w - 8.0)
					if not compact_delta_text.is_empty():
						_text(compact_delta_text, Vector2(cx + value_w + 2.0, ty), cell_size, gcol, max(0.0, fixed_delta_w - 4.0))
					cx += w
					continue
				match _col_align(col, default_align):
					HORIZONTAL_ALIGNMENT_LEFT:
						_text(after_text, Vector2(cx + 4.0, ty), cell_size, after_color, content_w - 8.0)
						if not delta_text.is_empty():
							var after_w_left: float = _font.get_string_size(after_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_size).x
							_text(delta_text, Vector2(cx + 8.0 + after_w_left, ty), cell_size, gcol, max(0.0, content_w - 12.0 - after_w_left))
					HORIZONTAL_ALIGNMENT_CENTER:
						var joined_text: String = after_text
						if not delta_text.is_empty():
							joined_text += " " + delta_text
						var total_w: float = _font.get_string_size(joined_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_size).x
						var start_x: float = cx + max(2.0, (content_w - total_w) * 0.5)
						_text(after_text, Vector2(start_x, ty), cell_size, after_color, content_w)
						if not delta_text.is_empty():
							var after_w_center: float = _font.get_string_size(after_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_size).x
							_text(delta_text, Vector2(start_x + after_w_center + 4.0, ty), cell_size, gcol, content_w)
					_:
						if delta_text.is_empty():
							_text_right(after_text, cx + content_w - 6.0, ty, cell_size, after_color, content_w - 8.0)
						else:
							var dw: float = _font.get_string_size(delta_text, HORIZONTAL_ALIGNMENT_LEFT, -1, cell_size).x
							_text_right(delta_text, cx + content_w - 6.0, ty, cell_size, gcol, dw + 4.0)
							_text_right(after_text, cx + content_w - 6.0 - dw - 3.0, ty, cell_size, after_color, content_w - 10.0 - dw)
			_:
				var text: String = _fmt_cell(_col_format(col), row.get(key, ""))
				var cell_color: Color = row.get("%s_color" % key, base_color) as Color
				match _col_align(col, default_align):
					HORIZONTAL_ALIGNMENT_LEFT:
						_text(text, Vector2(cx + 4.0, ty), cell_size, cell_color, content_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, cell_bold)
					HORIZONTAL_ALIGNMENT_CENTER:
						_text(text, Vector2(cx + 2.0, ty), cell_size, cell_color, content_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER, cell_bold)
					_:
						_text_right(text, cx + content_w - 6.0, ty, cell_size, cell_color, content_w - 8.0, cell_bold)
		cx += w
	if selectable:
		hits.append({"rect": Rect2(rect.position.x + 8.0, ry, rect.size.x - 16.0, row_h), "kind": sel_kind, "meta": meta})


func _col_width(col: Dictionary) -> float:
	return float(col.get("w", 72))


func _col_content_width(col: Dictionary, width: float, factor: float) -> float:
	return max(8.0, width - max(0.0, float(col.get("gap_after", 0.0)) * factor))


func _growth_delta_width(col: Dictionary, factor: float) -> float:
	if _col_format(col) != "growth":
		return 0.0
	return max(0.0, float(col.get("delta_w", 0.0)) * factor)


func _col_format(col: Dictionary) -> String:
	return str(col.get("fmt", "string"))


func _growth_value_color(key: String, value: int, suffix: String) -> Color:
	if key == "velocity" or suffix.find("km") >= 0 or value > 110:
		return TEXT
	return _table_rating_color(value)


func _table_rating_color(value: int) -> Color:
	if value >= 75:
		return BLUE
	if value >= 66:
		return GREEN
	if value >= 52:
		return TEXT
	return MUTED


# 表の整列規約: 文字列/チーム列は左寄せ、バッジ列は中央寄せ、数値系の列は右寄せを既定にする
# (align 未指定でも書式から推測して全表で統一する)。明示 align があればそれを優先。
const _TEXT_FORMATS: Array = ["string", "str", "team"]

func _col_align(col: Dictionary, _default_align: String = "") -> int:
	match str(col.get("align", "")):
		"l", "left":
			return HORIZONTAL_ALIGNMENT_LEFT
		"c", "center":
			return HORIZONTAL_ALIGNMENT_CENTER
		"r", "right":
			return HORIZONTAL_ALIGNMENT_RIGHT
		_:
			if _col_format(col) == "pos_badge":
				return HORIZONTAL_ALIGNMENT_CENTER
			match _default_align:
				"l", "left":
					return HORIZONTAL_ALIGNMENT_LEFT
				"c", "center":
					return HORIZONTAL_ALIGNMENT_CENTER
				"r", "right":
					return HORIZONTAL_ALIGNMENT_RIGHT
			return HORIZONTAL_ALIGNMENT_LEFT if _TEXT_FORMATS.has(_col_format(col)) else HORIZONTAL_ALIGNMENT_RIGHT


# 各画面の _fmt_cell を集約した上位集合。値が String ならそのまま (例: 欠損 "-")。
# 書式トークン: int/rate/float1/float2(負→"-")/float3/f1/f2/f1s(符号付)/z/pct1/gb/comma/str(既定)。
func _fmt_cell(fmt: String, value: Variant) -> String:
	if value is String:
		return str(value)
	match fmt:
		"int":
			return str(int(value))
		"rate":
			return _rate_short(float(value))
		"float1", "f1":
			return "%0.1f" % float(value)
		"float2":
			return "-" if float(value) < 0.0 else "%0.2f" % float(value)
		"f2":
			return "%0.2f" % float(value)
		"float3":
			return "%0.3f" % float(value)
		"f1s":
			var f: float = float(value)
			return ("+%0.1f" % f) if f > 0.0 else ("%0.1f" % f)
		"z":
			return "%+.2f" % float(value)
		"pct1":
			return "%0.1f%%" % (float(value) * 100.0)
		"gb":
			return "-" if float(value) <= 0.0 else _float1(float(value))
		"comma":
			return _comma(int(value))
		_:
			return str(value)


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


# 幅の狭い箇所 (SUMMARYパネル/12球団の予算一覧など) 向けの短縮表記 (例: 32000万円→3.2億)。
# 符号は呼び出し側で付与する想定 (_format_money と同様、絶対値の文字列を返す)。
func _format_money_compact(man_value: int) -> String:
	var abs_value: int = absi(man_value)
	if abs_value >= 10000:
		return "%.1f億" % (float(abs_value) / 10000.0)
	return "%s万" % _comma(abs_value)


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
	return "%d年 %d月%d日(%s)" % [
		int(d.get("year", 0)),
		int(d.get("month", 0)),
		int(d.get("day", 0)),
		SeasonCalendar.weekday_label_for_date(date_text),
	]


func _parse_date(date_text: String) -> Dictionary:
	var parts: PackedStringArray = date_text.split("-")
	return {
		"year": int(parts[0]) if parts.size() > 0 else 1970,
		"month": int(parts[1]) if parts.size() > 1 else 1,
		"day": int(parts[2]) if parts.size() > 2 else 1,
	}
