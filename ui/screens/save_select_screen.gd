extends "res://ui/components/dashboard_screen.gd"

# セーブデータ選択画面。user://saves/save_* を新しい順に一覧し、
# 選択ロード / 個別削除 (2クリック確認) を行う。タイトル/オプションの両方から入る。

const SaveContext = preload("res://services/storage/save_context.gd")

const LIST_W: float = 1080.0
const LIST_X: float = (BASE.x - LIST_W) * 0.5
const LIST_TOP: float = 170.0
const ROW_H: float = 92.0
const ROW_GAP: float = 14.0
const PAGE_SIZE: int = 8

var _saves: Array = []
var _page: int = 0
var _confirm_delete_id: String = ""
var _status_text: String = ""
var _status_is_error: bool = false


func _ready() -> void:
	_init_chrome()
	_refresh_saves()


func _refresh_saves() -> void:
	_saves = SaveService.list_saves()
	_page = clampi(_page, 0, _max_page())
	_build_buttons()
	queue_redraw()


func _max_page() -> int:
	@warning_ignore("integer_division")
	return max(0, (_saves.size() - 1) / PAGE_SIZE)


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_round(Rect2(0, 0, BASE.x, 4), Color(BLUE.r, BLUE.g, BLUE.b, 0.85), Color.TRANSPARENT, 0, 0)

	_text("セーブデータ", Vector2(LIST_X, 96), 34, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("読み込むセーブを選択してください。削除は取り消せません。", Vector2(LIST_X, 128), 15, MUTED)

	var rows: Array = _page_rows()
	if rows.is_empty():
		_text("セーブデータがありません", Vector2(0, LIST_TOP + 120.0), 18, MUTED, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)
	for i in range(rows.size()):
		_draw_save_row(rows[i] as Dictionary, LIST_TOP + float(i) * (ROW_H + ROW_GAP))

	# ページ表示
	if _saves.size() > PAGE_SIZE:
		_text("%d / %d ページ (全%d件)" % [_page + 1, _max_page() + 1, _saves.size()],
			Vector2(0, LIST_TOP + float(PAGE_SIZE) * (ROW_H + ROW_GAP) + 34.0), 14, MUTED, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)

	_text(_app_version_label(), Vector2(28, BASE.y - 28), 13, FAINT)
	if not _status_text.is_empty():
		_text(_status_text, Vector2(0, BASE.y - 26), 14, RED if _status_is_error else AMBER, BASE.x, HORIZONTAL_ALIGNMENT_CENTER)


func _draw_save_row(meta: Dictionary, y: float) -> void:
	var is_active: bool = bool(meta.get("is_active", false))
	var rect: Rect2 = Rect2(LIST_X, y, LIST_W, ROW_H)
	if is_active:
		_round(rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.10), Color(BLUE.r, BLUE.g, BLUE.b, 0.45), 10)
		_round(Rect2(rect.position.x, y + 10, 3, ROW_H - 20), BLUE, Color.TRANSPARENT, 2, 0)
	else:
		_round(rect, PANEL, BORDER_SOFT, 10)

	var x: float = LIST_X + 26.0
	# 1行目: セーブ日時 (フォルダ名由来) + 使用中チップ
	_text(_format_save_id(str(meta.get("save_id", ""))), Vector2(x, y + 36.0), 19, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	if is_active:
		_chip(Rect2(x + 250.0, y + 18.0, 64.0, 24.0), "使用中", BLUE)

	# 2行目: ゲーム内メタ (球団 / 年目 / ゲーム内日付 / 最終更新)
	var parts: Array = []
	var team_name: String = str(meta.get("team_name", ""))
	if not team_name.is_empty():
		parts.append(team_name)
	if meta.has("season_number"):
		parts.append("%d年目" % int(meta.get("season_number", 1)))
	var date_text: String = str(meta.get("date", ""))
	if not date_text.is_empty():
		parts.append(_format_date_long(date_text))
	if bool(meta.get("offseason_active", false)):
		parts.append("オフシーズン")
	var updated: String = str(meta.get("updated_at", ""))
	if not updated.is_empty():
		parts.append("最終セーブ %s" % updated)
	var detail: String = "  ・  ".join(parts) if not parts.is_empty() else "詳細情報なし (旧形式のセーブ)"
	_text(detail, Vector2(x, y + 66.0), 14, MUTED, LIST_W - 320.0)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	_add_button("back", "戻る", Rect2(LIST_X + LIST_W - 120.0, 74.0, 120.0, 42.0), _go_back, "action")

	var rows: Array = _page_rows()
	for i in range(rows.size()):
		var meta: Dictionary = rows[i] as Dictionary
		var save_id: String = str(meta.get("save_id", ""))
		var y: float = LIST_TOP + float(i) * (ROW_H + ROW_GAP)
		_add_button("load_%s" % save_id, "ロード", Rect2(LIST_X + LIST_W - 264.0, y + 24.0, 110.0, 44.0),
			func() -> void: _load_save(save_id), "primary")
		var deleting: bool = _confirm_delete_id == save_id
		_add_button("del_%s" % save_id, "本当に削除?" if deleting else "削除",
			Rect2(LIST_X + LIST_W - 140.0, y + 24.0, 114.0, 44.0),
			func() -> void: _delete_save(save_id), "chip_active" if deleting else "action")

	if _saves.size() > PAGE_SIZE:
		var pager_y: float = LIST_TOP + float(PAGE_SIZE) * (ROW_H + ROW_GAP) + 50.0
		_add_button("prev", "前のページ", Rect2(BASE.x * 0.5 - 190.0, pager_y, 170.0, 44.0),
			func() -> void: _set_page(_page - 1), "action")
		_add_button("next", "次のページ", Rect2(BASE.x * 0.5 + 20.0, pager_y, 170.0, 44.0),
			func() -> void: _set_page(_page + 1), "action")

	_layout_buttons()


func _page_rows() -> Array:
	return _saves.slice(_page * PAGE_SIZE, min(_saves.size(), (_page + 1) * PAGE_SIZE))


func _set_page(page: int) -> void:
	_page = clampi(page, 0, _max_page())
	_confirm_delete_id = ""
	_build_buttons()
	queue_redraw()


# ============================================================ actions

func _go_back() -> void:
	if not AppState.go_back():
		AppState.request_screen("start", false)


func _load_save(save_id: String) -> void:
	_confirm_delete_id = ""
	var payload: Dictionary = SaveService.load_save(save_id)
	if payload.is_empty():
		_set_status("セーブデータの読み込みに失敗しました。", true)
		_refresh_saves()
		return
	if not AppState.restore_from_save(payload):
		_set_status("セーブデータの復元に失敗しました。", true)
		_refresh_saves()


# 誤操作防止に2クリック確認: 1回目でボタンが「本当に削除?」へ変わり、2回目で実行する。
func _delete_save(save_id: String) -> void:
	if _confirm_delete_id != save_id:
		_confirm_delete_id = save_id
		_set_status("もう一度「本当に削除?」を押すと削除します。", false)
		_build_buttons()
		queue_redraw()
		return

	_confirm_delete_id = ""
	var was_active: bool = save_id == SaveContext.active_save_id()
	if SaveService.delete_save(save_id):
		var note: String = " 使用中のセーブだったため、次回セーブ時に新しいフォルダが作られます。" if was_active else ""
		_set_status("削除しました: %s。%s" % [_format_save_id(save_id), note], false)
	else:
		_set_status("削除に失敗しました。", true)
	_refresh_saves()


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_is_error = is_error


# "save_YYYYMMDD_HHMMSS[_NN]" → "YYYY/MM/DD HH:MM のセーブ" 表記。
# 想定外の形式はそのまま返す。
func _format_save_id(save_id: String) -> String:
	var parts: PackedStringArray = save_id.split("_")
	if parts.size() < 3 or parts[1].length() != 8 or parts[2].length() != 6:
		return save_id
	var d: String = parts[1]
	var t: String = parts[2]
	return "%s/%s/%s %s:%s" % [d.substr(0, 4), d.substr(4, 2), d.substr(6, 2), t.substr(0, 2), t.substr(2, 2)]
