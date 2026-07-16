extends "res://ui/components/dashboard_screen.gd"

# タイトル画面。チーム/シーズン未選択の入口なので通常 shell は描かず、
# 中央のロゴとメニューカードだけを dashboard_screen の base 座標系で描画する。

# --- レイアウト基準 (base 座標) ---
const CARD_W: float = 460.0
const CARD_X: float = (BASE.x - CARD_W) * 0.5
const MENU_TOP: float = 470.0
const BTN_W: float = 380.0
const BTN_H: float = 58.0
const BTN_GAP: float = 16.0
const BTN_X: float = (BASE.x - BTN_W) * 0.5

var _status_text: String = ""


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
	_text(APP_VERSION, Vector2(28, BASE.y - 28), 13, FAINT)
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
	var rows: int = 4
	return 36.0 + float(rows) * (BTN_H + BTN_GAP) - BTN_GAP + 36.0


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	var y: float = MENU_TOP + 36.0
	_add_button("new_game", "新しく始める", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("team_select"), "primary")
	y += BTN_H + BTN_GAP
	_add_button("continue", "続きから", Rect2(BTN_X, y, BTN_W, BTN_H), _continue_game, "action")
	y += BTN_H + BTN_GAP
	_add_button("load", "セーブデータ選択", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("save_select"), "action")
	y += BTN_H + BTN_GAP
	_add_button("options", "オプション", Rect2(BTN_X, y, BTN_W, BTN_H), func() -> void: AppState.request_screen("options"), "action")

	_layout_buttons()


# ============================================================ actions

# 前回のアクティブセーブ (無ければ最新) をそのまま読み込む従来のロード。
func _continue_game() -> void:
	var save_data: Dictionary = SaveService.load_state()
	if save_data.is_empty():
		_status_text = "セーブデータがありません"
		queue_redraw()
		return
	AppState.restore_from_save(save_data)
