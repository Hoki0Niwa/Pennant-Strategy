extends Control

const ProgressOverlayScript = preload("res://ui/components/progress_overlay.gd")
const LongAutoplayReporterScript = preload("res://services/reports/long_autoplay_reporter.gd")
const DeveloperTools = preload("res://services/development/developer_tools.gd")

const SEED_PLAYERS_PATH: String = "res://data/initial_players.csv"
const SEED_TEAMS_PATH: String = "res://data/initial_teams.csv"

var status_label: Label
var save_path_label: Label
var central_dh_toggle: CheckButton
var pacific_dh_toggle: CheckButton
var regen_seasons_spin: SpinBox
var regen_seed_edit: LineEdit
var regen_button: Button
var regen_status_label: Label
var dist_button: Button
var dist_status_label: Label
var dist_texture_rect: TextureRect


func _ready() -> void:
	_build()


func _build() -> void:
	var root: VBoxContainer = VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 12)
	add_child(root)

	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var title: Label = Label.new()
	title.text = "オプション"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	var spacer: Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	if AppState.current_season == null:
		var back_button: Button = Button.new()
		back_button.text = "戻る"
		back_button.custom_minimum_size = Vector2(78, 34)
		back_button.pressed.connect(func() -> void: AppState.request_screen("start"))
		header.add_child(back_button)

	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	root.add_child(status_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)

	content.add_child(_build_section_label("セーブデータ"))
	save_path_label = Label.new()
	save_path_label.text = "保存先: user://pennant_strategy_m0.save"
	save_path_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	content.add_child(save_path_label)

	var save_row: HBoxContainer = HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 8)
	content.add_child(save_row)

	var save_button: Button = Button.new()
	save_button.text = "手動セーブ"
	save_button.custom_minimum_size = Vector2(120, 32)
	save_button.pressed.connect(_on_manual_save)
	save_row.add_child(save_button)

	var delete_button: Button = Button.new()
	delete_button.text = "セーブ削除"
	delete_button.custom_minimum_size = Vector2(120, 32)
	delete_button.pressed.connect(_on_delete_save)
	save_row.add_child(delete_button)

	content.add_child(_build_section_label("DHルール"))
	content.add_child(_build_dh_controls())

	if DeveloperTools.enabled():
		content.add_child(_build_section_label("デバッグ: 初期選手再生成"))
		content.add_child(_build_regenerate_controls())

		content.add_child(_build_section_label("デバッグ: 能力分布グラフ"))
		content.add_child(_build_distribution_controls())

	content.add_child(_build_section_label("情報"))
	var info_text: RichTextLabel = RichTextLabel.new()
	info_text.bbcode_enabled = false
	info_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_text.custom_minimum_size = Vector2(0, 140)
	info_text.text = _build_info_text()
	content.add_child(info_text)


func _build_section_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.86, 0.90, 0.94))
	return label


func _build_dh_controls() -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var desc: Label = Label.new()
	desc.text = "ホームチームのリーグ設定でDHの有無を決めます。変更は未消化試合に反映されます。"
	desc.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(desc)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)

	central_dh_toggle = CheckButton.new()
	central_dh_toggle.text = "第1リーグ DH"
	central_dh_toggle.set_pressed_no_signal(AppState.is_dh_enabled_for_league("central"))
	central_dh_toggle.toggled.connect(_on_central_dh_toggled)
	row.add_child(central_dh_toggle)

	pacific_dh_toggle = CheckButton.new()
	pacific_dh_toggle.text = "第2リーグ DH"
	pacific_dh_toggle.set_pressed_no_signal(AppState.is_dh_enabled_for_league("pacific"))
	pacific_dh_toggle.toggled.connect(_on_pacific_dh_toggled)
	row.add_child(pacific_dh_toggle)
	return box


func _build_regenerate_controls() -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var desc: Label = Label.new()
	desc.text = "本ゲームのペナントを指定年数だけ自動進行し、その時点の球団・選手を初期データ(CSV)として書き出します。\n※現在の初期選手データ(data/initial_players.csv)を上書きします。反映には再起動または新規ペナント開始を推奨。"
	desc.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(desc)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	var seasons_label: Label = Label.new()
	seasons_label.text = "年数"
	seasons_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(seasons_label)

	regen_seasons_spin = SpinBox.new()
	regen_seasons_spin.min_value = 1
	regen_seasons_spin.max_value = 60
	regen_seasons_spin.step = 1
	regen_seasons_spin.value = 40
	regen_seasons_spin.custom_minimum_size = Vector2(90, 32)
	row.add_child(regen_seasons_spin)

	var seed_label: Label = Label.new()
	seed_label.text = "シード"
	seed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(seed_label)

	regen_seed_edit = LineEdit.new()
	regen_seed_edit.text = str(_random_seed())
	regen_seed_edit.custom_minimum_size = Vector2(120, 32)
	row.add_child(regen_seed_edit)

	var randomize_button: Button = Button.new()
	randomize_button.text = "🎲"
	randomize_button.tooltip_text = "ランダムなシードを設定"
	randomize_button.custom_minimum_size = Vector2(40, 32)
	randomize_button.pressed.connect(func() -> void: regen_seed_edit.text = str(_random_seed()))
	row.add_child(randomize_button)

	regen_button = Button.new()
	regen_button.text = "初期選手を再生成"
	regen_button.custom_minimum_size = Vector2(160, 32)
	regen_button.pressed.connect(_on_regenerate_initial_players)
	row.add_child(regen_button)

	regen_status_label = Label.new()
	regen_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	regen_status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	box.add_child(regen_status_label)
	return box


func _regen_seed_value() -> int:
	var text: String = regen_seed_edit.text.strip_edges()
	return int(text) if text.is_valid_int() else 20260528


func _on_regenerate_initial_players() -> void:
	regen_button.disabled = true
	regen_status_label.text = "生成中…（%d年分のシーズンを進行します）" % int(regen_seasons_spin.value)

	var overlay: ProgressOverlay = ProgressOverlayScript.new()
	add_child(overlay)
	var cancel_token: Dictionary = {"cancelled": false}
	overlay.cancel_requested.connect(func() -> void: cancel_token["cancelled"] = true)
	overlay.show_progress("初期選手を生成中…")
	var update_overlay: Callable = func(done: int, total: int, label: String) -> void:
		if overlay != null:
			overlay.update_progress(done, total, label)

	var options: Dictionary = {
		"seasons": int(regen_seasons_spin.value),
		"seed": _regen_seed_value(),
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
		regen_status_label.text = "キャンセルされました（元のデータは保持）。"
		regen_button.disabled = false
		return
	if int(report.get("seasons_completed", 0)) <= 0:
		regen_status_label.text = "生成に失敗しました。"
		regen_button.disabled = false
		return

	var players: Array = PSPlayerCsvIo.normalize_initial_seed_players(
		_active_player_dicts(),
		SeasonService.DEFAULT_START_YEAR
	)
	var teams: Array = _team_dicts()
	var ok_players: bool = PSPlayerCsvIo.write_players(SEED_PLAYERS_PATH, players)
	var ok_teams: bool = PSPlayerCsvIo.write_teams(SEED_TEAMS_PATH, teams)

	# 進化中は永続化を suspend したままなので戻し、新シードで GameDb を再読込する。
	RecordStore.resume_persistence()
	GameDb.load_initial_data()

	if ok_players and ok_teams:
		regen_status_label.text = "完了: %d選手 / %d球団 (%d年後) を書き出しました。反映には再起動または新規ペナント開始を推奨。" % [
			players.size(), teams.size(), int(report.get("end_year", 0)),
		]
	else:
		regen_status_label.text = "CSV 書き出しに失敗しました（res:// が書込不可の可能性。エディタ/ソース実行時のみ可）。"
	# 次回再生成のためシードを新しいランダム値に更新し、生成結果の能力分布を表示する。
	regen_seed_edit.text = str(_random_seed())
	regen_button.disabled = false
	await _generate_distribution_graph()


# 球団に所属し現役の選手のみをシード対象にする。
func _active_player_dicts() -> Array:
	var rows: Array = []
	for player_row in GameDb.players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id <= 0:
			continue
		if player.is_retired():
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


func _random_seed() -> int:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	return int(rng.randi())


func _build_distribution_controls() -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var desc: Label = Label.new()
	desc.text = "現在の初期選手(GameDb)の各 z 能力値のヒストグラムを生成し、画面表示＋PNG(res://reports/ability_distribution.png)へ出力します。"
	desc.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(desc)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	dist_button = Button.new()
	dist_button.text = "能力分布グラフを出力"
	dist_button.custom_minimum_size = Vector2(180, 32)
	dist_button.pressed.connect(func() -> void: await _generate_distribution_graph())
	row.add_child(dist_button)

	dist_status_label = Label.new()
	dist_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dist_status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
	row.add_child(dist_status_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 360)
	box.add_child(scroll)

	dist_texture_rect = TextureRect.new()
	dist_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP
	scroll.add_child(dist_texture_rect)
	return box


func _generate_distribution_graph() -> void:
	if dist_button != null:
		dist_button.disabled = true
	if dist_status_label != null:
		dist_status_label.text = "分布グラフ生成中…"

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

	if dist_texture_rect != null:
		dist_texture_rect.texture = ImageTexture.create_from_image(image)
		dist_texture_rect.custom_minimum_size = chart_size

	if dist_status_label != null:
		if save_ok:
			dist_status_label.text = "保存: %s (%d能力)" % [ProjectSettings.globalize_path(path), distributions.size()]
		else:
			dist_status_label.text = "画面表示のみ (PNG保存失敗: res:// 書込不可の可能性)"
	if dist_button != null:
		dist_button.disabled = false


func _on_manual_save() -> void:
	if AppState.current_season == null:
		_set_status("シーズン開始前はセーブできません。", true)
		return
	var ok: bool = SaveService.save_state(AppState)
	_set_status("セーブしました。" if ok else "セーブに失敗しました。", not ok)


func _on_central_dh_toggled(pressed: bool) -> void:
	AppState.set_dh_enabled_for_league("central", pressed)
	var ok: bool = SaveService.save_state(AppState)
	_set_status("DH設定を保存しました。" if ok else "DH設定の保存に失敗しました。", not ok)


func _on_pacific_dh_toggled(pressed: bool) -> void:
	AppState.set_dh_enabled_for_league("pacific", pressed)
	var ok: bool = SaveService.save_state(AppState)
	_set_status("DH設定を保存しました。" if ok else "DH設定の保存に失敗しました。", not ok)


func _on_delete_save() -> void:
	var save_path: String = "user://pennant_strategy_m0.save"
	var records_path: String = "user://pennant_strategy_records_m1.json"
	var deleted: Array = []
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
		deleted.append("セーブ")
	if FileAccess.file_exists(records_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(records_path))
		deleted.append("成績記録")
	if deleted.is_empty():
		_set_status("削除対象のファイルが見つかりません。", true)
	else:
		_set_status("削除しました: %s。再起動後に反映されます。" % "、".join(deleted), false)


func _build_info_text() -> String:
	var lines: Array = []
	lines.append("ペナントストラテジー M4")
	lines.append("")
	lines.append("新しい打席判定モデルでは、打席を1球ごとに解決します。")
	lines.append("三振と四球はカウント進行から発生します。")
	lines.append("インプレー時は、先に打球速度・角度・方向を生成してから最終結果を決めます。")
	lines.append("")
	return "\n".join(lines)


func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.55))
	else:
		status_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
