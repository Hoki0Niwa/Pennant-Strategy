extends "res://ui/components/dashboard_screen.gd"

# オプション画面。開始前とシーズン中の両方から開かれるため、状態に応じて簡易 chrome か通常 shell を描く。
# トグルは ON=青(chip_active)/OFF=灰(chip) のチップボタンで表し、1クリックで AppState の設定を切り替える。
# 再生成の年数/シードは LineEdit を座標系に重ねて直接入力でき、focus_exited/Enter で確定する。
# 能力分布グラフは SubViewport で PNG を生成し、得られたテクスチャを _draw 内で直接描画する。

const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const LongAutoplayReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")

const SEED_PLAYERS_PATH: String = "res://data/initial_players.csv"
const SEED_TEAMS_PATH: String = "res://data/initial_teams.csv"

const CONTENT_TOP: float = 108.0
const CONTENT_BOTTOM: float = 1056.0

var _save_path: String = ""
var _status_text: String = ""
var _status_color: Color = MUTED

var _regen_seasons: int = 40
var _regen_seed: int = 0
var _regen_status: String = ""
var _regen_running: bool = false
var _regen_button: Button = null

var _dist_texture: ImageTexture = null
var _dist_size: Vector2 = Vector2.ZERO
var _dist_status: String = ""
var _dist_button: Button = null

var _seasons_edit: LineEdit = null
var _seed_edit: LineEdit = null
var _team_dropdown: OptionButton = null


func _ready() -> void:
	_init_chrome()
	_save_path = SaveService.current_save_display_path()
	_regen_seed = _random_seed()
	_build_buttons()
	_build_inputs()
	queue_redraw()


func _has_session() -> bool:
	return AppState.current_season != null and GameDb.get_team(AppState.selected_team_id) != null


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	if _has_session():
		_draw_shell("オプション", GameDb.get_team(AppState.selected_team_id), AppState.current_season)
	else:
		_draw_pregame_chrome()

	var rects: Dictionary = _layout_rects()
	_draw_save_panel(rects["save_panel"] as Rect2)
	_draw_settings_panel(rects["settings_panel"] as Rect2)

	if DeveloperTools.enabled():
		_draw_devtools_panel(rects["devtools_panel"] as Rect2)
		# 初期選手再生成・能力分布グラフはシーズン開始前のみ。
		if not _has_session():
			_draw_regen_panel(rects["regen_panel"] as Rect2)
			_draw_dist_panel(rects["dist_panel"] as Rect2)

	if not _status_text.is_empty():
		_text(_status_text, Vector2(INNER_L, 1076), 13, _status_color)


# start から来た (シーズン未開始) 場合の簡易チローム。
func _draw_pregame_chrome() -> void:
	_round(Rect2(0, 0, SIDEBAR_W, BASE.y), SIDEBAR_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, 0), Vector2(SIDEBAR_W, BASE.y), BORDER_SOFT, 1.0)
	_round(Rect2(SIDEBAR_W, 0, BASE.x - SIDEBAR_W, HEADER_H), HEADER_BG, Color.TRANSPARENT, 0, 0)
	_line(Vector2(SIDEBAR_W, HEADER_H), Vector2(BASE.x, HEADER_H), BORDER_SOFT, 1.0)
	_text("PennantStrategy", Vector2(20, 40), 22, TEXT)
	_text("ペナント戦略シミュレーション", Vector2(21, 62), 11, MUTED)
	_text(APP_VERSION, Vector2(22, BASE.y - 24), 12, FAINT)
	_text("オプション", Vector2(INNER_L, 56), 28, TEXT)


# ============================================================ layout

# パネル/操作系の base 座標を一括計算 (描画とボタン配置で共有)。
func _layout_rects() -> Dictionary:
	var dev: bool = DeveloperTools.enabled()
	var left_x: float = INNER_L
	var left_w: float = 720.0 if dev else 760.0
	var right_x: float = left_x + left_w + 24.0
	var right_w: float = INNER_R - right_x

	var save_panel: Rect2 = Rect2(left_x, CONTENT_TOP, left_w, 150.0)
	var settings_panel: Rect2 = Rect2(left_x, save_panel.end.y + 18.0, left_w, 320.0)

	var rects: Dictionary = {
		"save_panel": save_panel,
		"save_btn": Rect2(save_panel.position.x + 18.0, save_panel.end.y - 50.0, 150.0, 36.0),
		"delete_btn": Rect2(save_panel.position.x + 182.0, save_panel.end.y - 50.0, 150.0, 36.0),
		"settings_panel": settings_panel,
	}

	if dev:
		# 左カラム下段: 開発ツール。開始前=テストモードメニュー / 開始後=操作チーム変更。
		var dev_panel: Rect2 = Rect2(left_x, settings_panel.end.y + 18.0, left_w, CONTENT_BOTTOM - (settings_panel.end.y + 18.0))
		rects["devtools_panel"] = dev_panel
		var dx0: float = dev_panel.position.x + 18.0
		var dy0: float = dev_panel.position.y + 84.0
		if _has_session():
			rects["team_dropdown"] = Rect2(dx0 + 116.0, dy0, dev_panel.size.x - 36.0 - 116.0, 40.0)
		else:
			var dgap: float = 12.0
			var dbw: float = (dev_panel.size.x - 36.0 - dgap) / 2.0
			var dbh: float = 46.0
			rects["dev_balance"] = Rect2(dx0, dy0, dbw, dbh)
			rects["dev_probe"] = Rect2(dx0 + dbw + dgap, dy0, dbw, dbh)
			rects["dev_draft"] = Rect2(dx0, dy0 + dbh + dgap, dbw, dbh)
			rects["dev_reload"] = Rect2(dx0 + dbw + dgap, dy0 + dbh + dgap, dbw, dbh)

			# 右カラム: 初期選手再生成 + 能力分布グラフ (開始前のみ)。
			var regen_panel: Rect2 = Rect2(right_x, CONTENT_TOP, right_w, 300.0)
			var cy: float = regen_panel.position.y + 150.0
			rects["regen_panel"] = regen_panel
			rects["regen_seasons_edit"] = Rect2(regen_panel.position.x + 108.0, cy, 70.0, 34.0)
			rects["regen_seed_edit"] = Rect2(regen_panel.position.x + 290.0, cy, 150.0, 34.0)
			rects["regen_seedbtn"] = Rect2(regen_panel.position.x + 448.0, cy, 40.0, 34.0)
			rects["regen_run"] = Rect2(regen_panel.end.x - 18.0 - 170.0, cy, 170.0, 34.0)
			var dist_panel: Rect2 = Rect2(right_x, regen_panel.end.y + 18.0, right_w, CONTENT_BOTTOM - (regen_panel.end.y + 18.0))
			rects["dist_panel"] = dist_panel
			rects["dist_btn"] = Rect2(dist_panel.end.x - 18.0 - 210.0, dist_panel.position.y + 16.0, 210.0, 34.0)

	return rects


# 設定パネル内の i 番目のトグル行 (base 座標)。
func _toggle_row_rect(panel: Rect2, i: int) -> Rect2:
	return Rect2(panel.position.x + 18.0, panel.position.y + 76.0 + float(i) * 58.0, panel.size.x - 36.0, 50.0)


func _toggle_rows() -> Array:
	return [
		{"id": "autoswap", "label": "スキップ中の自動一二軍入替", "desc": "成績ベースで自動的に一二軍入替を行う", "on": AppState.auto_roster_swap_during_skip},
		{"id": "autosave", "label": "自動セーブ", "desc": "試合進行・オフシーズン処理時に自動で保存する", "on": AppState.auto_save_enabled},
		{"id": "dh1", "label": "第1リーグ DH", "desc": "ホーム主催試合で指名打者制を使用", "on": AppState.is_dh_enabled_for_league("central")},
		{"id": "dh2", "label": "第2リーグ DH", "desc": "ホーム主催試合で指名打者制を使用", "on": AppState.is_dh_enabled_for_league("pacific")},
	]


# ============================================================ panels

func _draw_save_panel(panel: Rect2) -> void:
	_panel(panel, "セーブデータ")
	_text("保存フォルダ", Vector2(panel.position.x + 18, panel.position.y + 62), 12, FAINT)
	_text(_save_path, Vector2(panel.position.x + 18, panel.position.y + 84), 13, MUTED, panel.size.x - 36)


func _draw_settings_panel(panel: Rect2) -> void:
	# トグル本体は ON/OFF チップボタンで右端に配置する。本文ではラベル/説明/区切り線のみ描く。
	_panel(panel, "ゲーム設定")
	var rows: Array = _toggle_rows()
	for i in range(rows.size()):
		var row: Dictionary = rows[i] as Dictionary
		var rect: Rect2 = _toggle_row_rect(panel, i)
		_text(str(row["label"]), Vector2(rect.position.x + 4, rect.position.y + 20), 15, TEXT)
		_text(str(row["desc"]), Vector2(rect.position.x + 4, rect.position.y + 42), 12, MUTED, rect.size.x - 90)
		if i < rows.size() - 1:
			_line(Vector2(rect.position.x, rect.end.y + 4), Vector2(rect.end.x, rect.end.y + 4), BORDER_SOFT, 1.0)


func _draw_devtools_panel(panel: Rect2) -> void:
	# 操作系 (ボタン/プルダウン) は _build_buttons / _build_inputs で生成する。本文はタイトル/説明のみ。
	if _has_session():
		_panel(panel, "操作チーム変更（開発）")
		_text("操作チーム", Vector2(panel.position.x + 18, panel.position.y + 109), 13, TEXT)
		_text("日付・選手・成績・怪我などをすべて保持したまま、操作するチームを切り替えます。",
			Vector2(panel.position.x + 18, panel.position.y + 150), 12, MUTED, panel.size.x - 36)
	else:
		_panel(panel, "開発ツール（テストモード）")
		_text("各ボタンでテストモードに移行します。", Vector2(panel.position.x + 18, panel.position.y + 58), 12, MUTED, panel.size.x - 36)


func _draw_regen_panel(panel: Rect2) -> void:
	# 年数/シードの入力欄 (LineEdit) は _build_inputs で生成し、ここではラベルのみ描く。
	_panel(panel, "初期選手の再生成")
	_multiline("指定年数だけペナントを自動進行し、その時点の球団・選手を初期データ(CSV)へ書き出します。現在の initial_players.csv を上書きするため、反映には再起動または新規ペナント開始を推奨。",
		Vector2(panel.position.x + 18, panel.position.y + 58), 12, MUTED, panel.size.x - 36)

	var cy: float = panel.position.y + 150.0
	_text("年数", Vector2(panel.position.x + 20, cy + 22), 13, TEXT)
	_text("シード", Vector2(panel.position.x + 226, cy + 22), 13, TEXT)

	if not _regen_status.is_empty():
		_multiline(_regen_status, Vector2(panel.position.x + 18, panel.position.y + 212), 12, MUTED, panel.size.x - 36)


func _draw_dist_panel(panel: Rect2) -> void:
	_panel(panel, "能力分布グラフ")
	if not _dist_status.is_empty():
		_text(_dist_status, Vector2(panel.position.x + 18, panel.position.y + 70), 12, MUTED, panel.size.x - 250)
	var area: Rect2 = Rect2(panel.position.x + 18, panel.position.y + 86, panel.size.x - 36, panel.size.y - 104)
	_round(area, Color(0.040, 0.048, 0.060), BORDER_SOFT, 8)
	if _dist_texture != null:
		_draw_texture_fit(area, _dist_texture)
	else:
		_text("「グラフを出力」で各 z 能力値のヒストグラムを表示します。", Vector2(area.position.x + 16, area.position.y + 32), 13, FAINT, area.size.x - 32)


# テクスチャを base_rect 内にアスペクト維持で収めて描画する。
func _draw_texture_fit(base_rect: Rect2, tex: Texture2D) -> void:
	var dst: Rect2 = _r(base_rect)
	var tex_size: Vector2 = tex.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	var scale: float = min(dst.size.x / tex_size.x, dst.size.y / tex_size.y)
	var draw_size: Vector2 = tex_size * scale
	var pos: Vector2 = dst.position + (dst.size - draw_size) * 0.5
	draw_texture_rect(tex, Rect2(pos, draw_size), false)


func _multiline(text: String, base_pos: Vector2, base_size: int, color: Color, base_width: float) -> void:
	draw_multiline_string(_font, _p(base_pos), text, HORIZONTAL_ALIGNMENT_LEFT, base_width * _scale_f,
		max(8, int(round(float(base_size) * _scale_f))), -1, color)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()

	if _has_session():
		_build_nav_buttons()
	else:
		_add_button("back", "戻る", Rect2(INNER_R - 120.0, 22.0, 120.0, 42.0), func() -> void: AppState.request_screen("start"), "action")

	var rects: Dictionary = _layout_rects()
	_add_button("manual_save", "手動セーブ", rects["save_btn"] as Rect2, _on_manual_save, "primary")
	_add_button("delete_save", "セーブ削除", rects["delete_btn"] as Rect2, _on_delete_save, "action")

	# トグル: 各行の右端に ON/OFF チップを置き、1クリックで切り替える。
	var settings_panel: Rect2 = rects["settings_panel"] as Rect2
	var rows: Array = _toggle_rows()
	for i in range(rows.size()):
		var spec: Dictionary = rows[i] as Dictionary
		var id: String = str(spec["id"])
		var on: bool = bool(spec["on"])
		var row: Rect2 = _toggle_row_rect(settings_panel, i)
		_add_button("tg_%s" % id, "有効" if on else "無効", Rect2(row.end.x - 80.0, row.position.y + 4.0, 76.0, 32.0),
			func(target: String = id) -> void: _on_toggle(target), "chip_active" if on else "chip")

	if DeveloperTools.enabled():
		if not _has_session():
			# テストモード遷移は履歴に積まない (戻る操作でタイトルへ直行できるように)。
			_add_button("dev_balance", "計測レポート", rects["dev_balance"] as Rect2, func() -> void: AppState.request_screen("balance_report", false), "action")
			_add_button("dev_probe", "選手プローブ", rects["dev_probe"] as Rect2, func() -> void: AppState.request_screen("player_probe", false), "action")
			_add_button("dev_draft", "ドラフト検証", rects["dev_draft"] as Rect2, func() -> void: AppState.request_screen("draft_simulator", false), "action")
			_add_button("dev_reload", "データ再読込", rects["dev_reload"] as Rect2, _reload_data, "action")
			# 初期選手再生成・能力分布グラフ (開始前のみ)。
			_add_button("regen_seed", "🎲", rects["regen_seedbtn"] as Rect2, func() -> void: _randomize_seed(), "chip")
			_regen_button = _add_button("regen_run", "初期選手を再生成", rects["regen_run"] as Rect2, _on_regenerate_initial_players, "primary")
			_regen_button.disabled = _regen_running
			_dist_button = _add_button("dist_run", "グラフを出力", rects["dist_btn"] as Rect2, func() -> void: await _generate_distribution_graph(), "action")

	_layout_buttons()


# 基底のボタン再配置に LineEdit/プルダウンの追従を足す (リサイズ時にも呼ばれる)。
func _layout_buttons() -> void:
	super._layout_buttons()
	_layout_inputs()


# _build_buttons の度に呼ばれる _clear_buttons は基底だと全 Button 子を消すため、
# Button 派生の OptionButton (チーム変更プルダウン) まで巻き込む。ここでは _add_button で
# 生成した追跡対象のみ解放し、プルダウン/LineEdit は維持する。
func _clear_buttons() -> void:
	for spec_value in _buttons:
		var button: Button = (spec_value as Dictionary)["button"] as Button
		if is_instance_valid(button):
			button.queue_free()
	_buttons.clear()


# ============================================================ direct inputs (LineEdit / OptionButton)

func _build_inputs() -> void:
	if not DeveloperTools.enabled():
		return
	if not _has_session():
		# 初期選手再生成の年数/シード入力 (開始前のみ)。
		_seasons_edit = _make_line_edit(str(_regen_seasons), HORIZONTAL_ALIGNMENT_CENTER, 2)
		_seasons_edit.text_submitted.connect(func(_t: String) -> void: _commit_seasons())
		_seasons_edit.focus_exited.connect(_commit_seasons)
		add_child(_seasons_edit)

		_seed_edit = _make_line_edit(str(_regen_seed), HORIZONTAL_ALIGNMENT_LEFT, 12)
		_seed_edit.text_submitted.connect(func(_t: String) -> void: _commit_seed())
		_seed_edit.focus_exited.connect(_commit_seed)
		add_child(_seed_edit)

	if _has_session():
		_team_dropdown = OptionButton.new()
		_team_dropdown.focus_mode = Control.FOCUS_NONE
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			_team_dropdown.add_item("%s（%s）" % [team.name, team.league_label()])
			_team_dropdown.set_item_metadata(_team_dropdown.item_count - 1, team.id)
			if team.id == AppState.selected_team_id:
				_team_dropdown.select(_team_dropdown.item_count - 1)
		_team_dropdown.item_selected.connect(_on_team_changed)
		add_child(_team_dropdown)

	_layout_inputs()


func _make_line_edit(text: String, align: HorizontalAlignment, max_len: int) -> LineEdit:
	var edit: LineEdit = LineEdit.new()
	edit.text = text
	edit.alignment = align
	edit.max_length = max_len
	edit.context_menu_enabled = false
	edit.caret_blink = true
	return edit


func _layout_inputs() -> void:
	var rects: Dictionary = _layout_rects()
	if _seasons_edit != null and rects.has("regen_seasons_edit"):
		_place_edit(_seasons_edit, rects["regen_seasons_edit"] as Rect2)
		_place_edit(_seed_edit, rects["regen_seed_edit"] as Rect2)
	if _team_dropdown != null and rects.has("team_dropdown"):
		_place_dropdown(_team_dropdown, rects["team_dropdown"] as Rect2)


func _place_dropdown(dropdown: OptionButton, base_rect: Rect2) -> void:
	var r: Rect2 = _r(base_rect)
	dropdown.position = r.position
	dropdown.size = r.size
	if _font != null:
		dropdown.add_theme_font_override("font", _font)
	dropdown.add_theme_font_size_override("font_size", max(9, int(round(14.0 * _scale_f))))
	dropdown.add_theme_color_override("font_color", TEXT)
	dropdown.add_theme_color_override("font_hover_color", TEXT)
	dropdown.add_theme_color_override("font_focus_color", TEXT)
	dropdown.add_theme_stylebox_override("normal", _box(PANEL_2, BORDER, 10))
	dropdown.add_theme_stylebox_override("hover", _box(PANEL_3, BORDER, 10))
	dropdown.add_theme_stylebox_override("pressed", _box(PANEL_3, BLUE, 10))
	dropdown.add_theme_stylebox_override("focus", _box(PANEL_2, BLUE, 10))
	var popup: PopupMenu = dropdown.get_popup()
	popup.add_theme_color_override("font_color", TEXT)
	popup.add_theme_color_override("font_hover_color", TEXT)
	popup.add_theme_stylebox_override("panel", _box(PANEL_2, BORDER, 6))
	popup.add_theme_stylebox_override("hover", _box(Color(BLUE.r, BLUE.g, BLUE.b, 0.18), BLUE, 6))


func _place_edit(edit: LineEdit, base_rect: Rect2) -> void:
	var r: Rect2 = _r(base_rect)
	edit.position = r.position
	edit.size = r.size
	if _font != null:
		edit.add_theme_font_override("font", _font)
	edit.add_theme_font_size_override("font_size", max(9, int(round(15.0 * _scale_f))))
	edit.add_theme_color_override("font_color", TEXT)
	edit.add_theme_color_override("caret_color", TEXT)
	edit.add_theme_color_override("font_placeholder_color", MUTED)
	edit.add_theme_color_override("selection_color", Color(BLUE.r, BLUE.g, BLUE.b, 0.35))
	edit.add_theme_stylebox_override("normal", _box(PANEL_2, BORDER, 8))
	edit.add_theme_stylebox_override("focus", _box(PANEL_2, BLUE, 8))


func _commit_seasons() -> void:
	if _seasons_edit == null:
		return
	var t: String = _seasons_edit.text.strip_edges()
	_regen_seasons = clampi(int(t), 1, 60) if t.is_valid_int() else _regen_seasons
	_seasons_edit.text = str(_regen_seasons)


func _commit_seed() -> void:
	if _seed_edit == null:
		return
	var t: String = _seed_edit.text.strip_edges()
	_regen_seed = int(t) if t.is_valid_int() else _regen_seed
	_seed_edit.text = str(_regen_seed)


# ============================================================ settings actions

func _on_toggle(id: String) -> void:
	match id:
		"autoswap":
			var v: bool = not AppState.auto_roster_swap_during_skip
			AppState.auto_roster_swap_during_skip = v
			var season: PSSeason = AppState.current_season
			var team_id: int = AppState.selected_team_id
			if v and season != null and team_id > 0:
				season.set_last_auto_swap_day(team_id, season.current_day - TeamAutoAI.SWAP_INTERVAL_DAYS)
			_save_and_status("自動入替設定を保存しました。")
		"autosave":
			AppState.auto_save_enabled = not AppState.auto_save_enabled
			_save_and_status("自動セーブ設定を保存しました。")
		"dh1":
			AppState.set_dh_enabled_for_league("central", not AppState.is_dh_enabled_for_league("central"))
			_save_and_status("DH設定を保存しました。")
		"dh2":
			AppState.set_dh_enabled_for_league("pacific", not AppState.is_dh_enabled_for_league("pacific"))
			_save_and_status("DH設定を保存しました。")
	# チップの ON/OFF 表示とスタイルを更新するため、ボタンを作り直す。
	_build_buttons()
	queue_redraw()


func _reload_data() -> void:
	GameDb.load_initial_data()
	_set_status("初期データを再読み込みしました: %d球団 / %d選手" % [GameDb.get_team_count(), GameDb.get_player_count()], false)
	queue_redraw()


# 開発用: 日付・選手・成績・怪我などのシーズン状態を保持したまま操作チームのみ差し替える。
func _on_team_changed(index: int) -> void:
	if _team_dropdown == null:
		return
	var team_id: int = int(_team_dropdown.get_item_metadata(index))
	if team_id <= 0 or team_id == AppState.selected_team_id:
		return
	AppState.select_team(team_id)
	var team: PSTeam = GameDb.get_team(team_id)
	_set_status("操作チームを変更しました: %s" % (team.name if team != null else "-"), false)
	queue_redraw()


func _save_and_status(ok_message: String) -> void:
	var ok: bool = SaveService.save_state(AppState)
	_set_status(ok_message if ok else "設定の保存に失敗しました。", not ok)


func _on_manual_save() -> void:
	if AppState.current_season == null:
		_set_status("シーズン開始前はセーブできません。", true)
		queue_redraw()
		return
	var ok: bool = SaveService.save_state(AppState)
	_save_path = SaveService.current_save_display_path()
	_set_status("セーブしました。" if ok else "セーブに失敗しました。", not ok)
	queue_redraw()


func _on_delete_save() -> void:
	var deleted: Array = SaveService.delete_current_save()
	_save_path = SaveService.current_save_display_path()
	if deleted.is_empty():
		_set_status("削除対象のファイルが見つかりません。", true)
	else:
		_set_status("削除しました: %s。再起動後に反映されます。" % "、".join(deleted), false)
	queue_redraw()


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_color = RED if is_error else MUTED


# ============================================================ debug: regenerate

func _randomize_seed() -> void:
	_regen_seed = _random_seed()
	if _seed_edit != null:
		_seed_edit.text = str(_regen_seed)
	queue_redraw()


func _random_seed() -> int:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	return int(rng.randi())


func _on_regenerate_initial_players() -> void:
	if _regen_running:
		return
	_regen_running = true
	if _regen_button != null:
		_regen_button.disabled = true
	_regen_status = "生成中…（%d年分のシーズンを進行します）" % _regen_seasons
	queue_redraw()

	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("初期選手を生成中…")
	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)

	var options: Dictionary = {
		"seasons": _regen_seasons,
		"seed": _regen_seed,
		"keep_world": true,
		"scene_tree": get_tree(),
		"cancel_token": cancel_token,
		"progress_callback": update_overlay,
	}
	var reporter: Object = LongAutoplayReporterScript.new()
	var report_value: Variant = await reporter.call("run_async", options)
	var report: Dictionary = report_value as Dictionary

	overlay.hide_progress()
	overlay.queue_free()

	if bool(report.get("cancelled", false)):
		_finish_regen("キャンセルされました（元のデータは保持）。")
		return
	if int(report.get("seasons_completed", 0)) <= 0:
		_finish_regen("生成に失敗しました。")
		return

	var players: Array = PSPlayerCsvIo.normalize_initial_seed_players(_active_player_dicts(), SeasonService.DEFAULT_START_YEAR)
	var teams: Array = _team_dicts()
	var ok_players: bool = PSPlayerCsvIo.write_players(SEED_PLAYERS_PATH, players)
	var ok_teams: bool = PSPlayerCsvIo.write_teams(SEED_TEAMS_PATH, teams)

	# 進化中は永続化を suspend したままなので戻し、新シードで GameDb を再読込する。
	RecordStore.resume_persistence()
	GameDb.load_initial_data()

	if ok_players and ok_teams:
		_finish_regen("完了: %d選手 / %d球団 (%d年後) を書き出しました。反映には再起動または新規ペナント開始を推奨。" % [
			players.size(), teams.size(), int(report.get("end_year", 0)),
		])
	else:
		_finish_regen("CSV 書き出しに失敗しました（res:// が書込不可の可能性。エディタ/ソース実行時のみ可）。")
	_regen_seed = _random_seed()
	if _seed_edit != null:
		_seed_edit.text = str(_regen_seed)
	await _generate_distribution_graph()


func _finish_regen(message: String) -> void:
	_regen_status = message
	_regen_running = false
	if _regen_button != null:
		_regen_button.disabled = false
	queue_redraw()


func _active_player_dicts() -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0 or player.is_retired():
			continue
		rows.append(player.to_dict())
	rows.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ta: int = int((a as Dictionary).get("team_id", 0))
		var tb: int = int((b as Dictionary).get("team_id", 0))
		if ta == tb:
			return int((a as Dictionary).get("id", 0)) < int((b as Dictionary).get("id", 0))
		return ta < tb
	)
	return rows


func _team_dicts() -> Array:
	var rows: Array = []
	for team_row in GameDb.teams:
		var team: PSTeam = team_row as PSTeam
		if team != null:
			rows.append(team.to_dict())
	return rows


# ============================================================ debug: distribution graph

func _generate_distribution_graph() -> void:
	if _dist_button != null:
		_dist_button.disabled = true
	_dist_status = "分布グラフ生成中…"
	queue_redraw()

	var keys: Array = AbilityDistributionChart.all_ability_keys()
	var distributions: Array = AbilityDistributionChart.compute_from_players(GameDb.players, keys)

	var chart: AbilityDistributionChart = AbilityDistributionChart.new()
	chart.set_distributions(distributions)
	var chart_size: Vector2 = chart.custom_minimum_size

	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(int(ceil(chart_size.x)), int(ceil(chart_size.y)))
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(viewport)
	viewport.add_child(chart)
	chart.position = Vector2.ZERO

	# SubViewport の描画完了を待ってからテクスチャを取得する。
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image = viewport.get_texture().get_image()
	viewport.queue_free()

	var path: String = "res://reports/ability_distribution.png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://reports"))
	var save_ok: bool = image.save_png(path) == OK

	_dist_texture = ImageTexture.create_from_image(image)
	_dist_size = chart_size
	if save_ok:
		_dist_status = "保存: %s (%d能力)" % [ProjectSettings.globalize_path(path), distributions.size()]
	else:
		_dist_status = "画面表示のみ (PNG保存失敗: res:// 書込不可の可能性)"
	if _dist_button != null:
		_dist_button.disabled = false
	queue_redraw()
