extends "res://ui/components/dashboard_screen.gd"

# タイトル画面 (2026-06-22 ホーム画面に合わせて再設計)。
# ホーム系ダッシュボード (dashboard_screen.gd) のダーク配色・固定座標系・描画プリミティブ・
# ボタン基盤を流用し、統一感のあるエントリ画面にする。チーム/シーズン未選択なので
# サイドバー+ヘッダ (_draw_shell) は使わず、中央ヒーロー (ロゴ + メニューカード) を描く。
# DeveloperTools / 配色 / 描画プリミティブ / ボタン基盤は基底 (dashboard_screen.gd) が提供する。

# --- レイアウト基準 (base 座標) ---
const CARD_W: float = 460.0
const CARD_X: float = (BASE.x - CARD_W) * 0.5
const MENU_TOP: float = 470.0
const BTN_W: float = 380.0
const BTN_H: float = 58.0
const BTN_GAP: float = 16.0
const BTN_X: float = (BASE.x - BTN_W) * 0.5

var _status_text: String = ""
var _debug_open: bool = false


func _ready() -> void:
	_init_chrome()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	# 上端のブルーアクセント (ホームの青系アクセントに合わせる)
	_round(Rect2(0, 0, BASE.x, 4), Color(BLUE.r, BLUE.g, BLUE.b, 0.85), Color.TRANSPARENT, 0, 0)

	# ロゴエンブレム + タイトル
	_draw_emblem(Rect2(BASE.x * 0.5 - 64, 196, 128, 128))
	_text("PennantStrategy", Vector2(0, 410), 60, TEXT, BASE.x, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text("ペナントレース運営シミュレーション", Vector2(0, 452), 20, MUTED, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)

	# メニューカード (ボタンの背面パネル)
	var card_h: float = _menu_card_height()
	_round(Rect2(CARD_X, MENU_TOP, CARD_W, card_h), PANEL, BORDER, 14)

	# 収録データのサマリー (カード下端)
	_text("初期データ  %d球団 ・ %d選手" % [GameDb.get_team_count(), GameDb.get_player_count()],
		Vector2(0, MENU_TOP + card_h + 38), 14, MUTED, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)

	# フッタ + ステータス
	_text("Ver 1.0.0", Vector2(28, BASE.y - 28), 13, FAINT)
	if not _status_text.is_empty():
		_text(_status_text, Vector2(0, BASE.y - 26), 14, AMBER, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)


# 白球 + 赤い縫い目のロゴエンブレム。
func _draw_emblem(box: Rect2) -> void:
	_round(box, PANEL_2, BORDER, 20)
	var ctr: Vector2 = box.position + box.size * 0.5
	draw_circle(_p(ctr), box.size.x * 0.30 * _scale_f, Color(0.945, 0.958, 0.972))
	var seam_r: float = box.size.x * 0.46 * _scale_f
	var seam_w: float = max(1.5, 2.6 * _scale_f)
	draw_arc(_p(ctr + Vector2(box.size.x * 0.30, 0.0)), seam_r, deg_to_rad(150.0), deg_to_rad(210.0), 20, RED, seam_w, true)
	draw_arc(_p(ctr - Vector2(box.size.x * 0.30, 0.0)), seam_r, deg_to_rad(-30.0), deg_to_rad(30.0), 20, RED, seam_w, true)


func _menu_card_height() -> float:
	var rows: int = 3 + (1 if DeveloperTools.enabled() else 0)
	if DeveloperTools.enabled() and _debug_open:
		rows += 3
	return 36.0 + float(rows) * (BTN_H + BTN_GAP) - BTN_GAP + 36.0


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	var y: float = MENU_TOP + 36.0
	_add_button("new_game", "新しく始める", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("team_select"), "primary")
	y += BTN_H + BTN_GAP
	_add_button("load", "ロード", Rect2(BTN_X, y, BTN_W, BTN_H), _load_game, "action")
	y += BTN_H + BTN_GAP
	_add_button("options", "オプション", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("options"), "action")
	y += BTN_H + BTN_GAP

	if DeveloperTools.enabled():
		_add_button("debug_toggle", "開発ツール ▴" if _debug_open else "開発ツール ▾", Rect2(BTN_X, y, BTN_W, BTN_H), _toggle_debug, "action")
		y += BTN_H + BTN_GAP
		if _debug_open:
			_add_button("reload", "データ再読込", Rect2(BTN_X, y, BTN_W, BTN_H), _reload_data, "chip")
			y += BTN_H + BTN_GAP
			_add_button("balance_report", "計測レポート", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("balance_report"), "chip")
			y += BTN_H + BTN_GAP
			_add_button("player_probe", "選手プローブ", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("player_probe"), "chip")
			y += BTN_H + BTN_GAP
			_add_button("draft_simulator", "ドラフト検証", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("draft_simulator"), "chip")

	_layout_buttons()


func _toggle_debug() -> void:
	_debug_open = not _debug_open
	_build_buttons()
	queue_redraw()


# ============================================================ actions

func _load_game() -> void:
	var save_data: Dictionary = SaveService.load_state()
	if save_data.is_empty():
		_status_text = "セーブデータがありません"
		queue_redraw()
		return
	AppState.restore_from_save(save_data)


func _reload_data() -> void:
	GameDb.load_initial_data()
	_status_text = "初期データを再読み込みしました: %d球団 / %d選手" % [GameDb.get_team_count(), GameDb.get_player_count()]
	queue_redraw()
