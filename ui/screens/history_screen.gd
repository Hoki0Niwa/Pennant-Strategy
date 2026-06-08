extends Control

const STAGE_LABELS: Dictionary = {
	"cs1_central": "CS1 セ",
	"cs1_pacific": "CS1 パ",
	"cs2_central": "CS2 セ",
	"cs2_pacific": "CS2 パ",
	"japan_series": "日本シリーズ",
}

const BATTING_TITLE_LABELS: Dictionary = {
	"average": "首位打者", "home_runs": "本塁打王", "rbi": "打点王",
	"stolen_bases": "盗塁王", "hits": "最多安打",
}
const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "最多勝利", "era": "最優秀防御率", "strikeouts": "最多奪三振",
	"saves": "最多セーブ", "holds": "最多ホールド", "win_rate": "最高勝率",
}

const SortableTable = preload("res://ui/components/sortable_table.gd")

const STANDINGS_COLUMNS: Array = [
	{"title": "順", "key": "rank", "width": 40, "type": "number", "format": "int"},
	{"title": "球団", "key": "team", "width": 80, "type": "string", "format": "string"},
	{"title": "勝", "key": "w", "width": 52, "type": "number", "format": "int"},
	{"title": "敗", "key": "l", "width": 52, "type": "number", "format": "int"},
	{"title": "分", "key": "d", "width": 48, "type": "number", "format": "int"},
	{"title": "勝率", "key": "pct", "width": 70, "type": "number", "format": "rate"},
]

var year_select: OptionButton
var content_box: VBoxContainer
var archive_keys: Array = []


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
	title.text = "シーズン履歴"
	title.add_theme_font_size_override("font_size", 24)
	header.add_child(title)

	var year_label: Label = Label.new()
	year_label.text = "年度"
	header.add_child(year_label)

	year_select = OptionButton.new()
	year_select.custom_minimum_size = Vector2(160, 32)
	year_select.item_selected.connect(func(_index: int) -> void: _render())
	header.add_child(year_select)

	header.add_child(Control.new())

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	content_box = VBoxContainer.new()
	content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_box.add_theme_constant_override("separation", 8)
	scroll.add_child(content_box)

	_populate_years()
	_render()


func _populate_years() -> void:
	year_select.clear()
	archive_keys = []
	var archives: Array = RecordStore.get_season_archives()
	for i in range(archives.size() - 1, -1, -1):
		var archive: PSSeasonArchive = archives[i] as PSSeasonArchive
		year_select.add_item("%d年 (第%d年目)" % [archive.year, archive.season_number])
		archive_keys.append(i)
	if year_select.item_count > 0:
		year_select.select(0)


func _render() -> void:
	for child in content_box.get_children():
		content_box.remove_child(child)
		child.queue_free()

	var archives: Array = RecordStore.get_season_archives()
	if archives.is_empty():
		_add_text_block("まだ完了したシーズンがありません。")
		return
	if year_select.item_count == 0:
		return
	var idx: int = year_select.selected
	if idx < 0 or idx >= archive_keys.size():
		return
	var archive_index: int = int(archive_keys[idx])
	if archive_index < 0 or archive_index >= archives.size():
		return
	var archive: PSSeasonArchive = archives[archive_index] as PSSeasonArchive
	_render_archive(archive)


func _render_archive(archive: PSSeasonArchive) -> void:
	_add_heading("%d年 (第%d年目)" % [archive.year, archive.season_number], 20)

	# Final standings — リーグ別のソート可能な表
	_add_heading("最終順位", 16)
	for league_key in ["central", "pacific"]:
		var label: String = "第1リーグ" if league_key == "central" else "第2リーグ"
		var league_title: Label = Label.new()
		league_title.text = "[%s]" % label
		league_title.add_theme_color_override("font_color", Color(0.70, 0.74, 0.78))
		content_box.add_child(league_title)

		var table: Tree = SortableTable.new()
		table.custom_minimum_size = Vector2(0, 180)
		table.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		content_box.add_child(table)
		table.configure(STANDINGS_COLUMNS)
		table.set_default_sort(5, false)  # 勝率 降順
		table.set_rows(_league_standing_rows(archive, league_key))

	var rest: String = _format_postseason_awards(archive)
	if not rest.strip_edges().is_empty():
		_add_text_block(rest)


func _add_heading(text: String, font_size: int) -> void:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	content_box.add_child(label)


func _add_text_block(text: String) -> void:
	var rt: RichTextLabel = RichTextLabel.new()
	rt.bbcode_enabled = false
	rt.fit_content = true
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.text = text
	content_box.add_child(rt)


func _league_standing_rows(archive: PSSeasonArchive, league_key: String) -> Array:
	var entries: Array = []
	for team_id_str in archive.standings.keys():
		var team_id: int = int(team_id_str)
		var team: PSTeam = GameDb.get_team(team_id)
		if team == null or team.league != league_key:
			continue
		entries.append({"team": team, "entry": archive.standings[team_id_str] as Dictionary})

	entries.sort_custom(func(a, b) -> bool:
		var ea: Dictionary = (a as Dictionary)["entry"] as Dictionary
		var eb: Dictionary = (b as Dictionary)["entry"] as Dictionary
		var wa: int = int(ea.get("wins", 0))
		var la: int = int(ea.get("losses", 0))
		var wb: int = int(eb.get("wins", 0))
		var lb: int = int(eb.get("losses", 0))
		var pa: float = float(wa) / float(max(1, wa + la))
		var pb: float = float(wb) / float(max(1, wb + lb))
		if pa == pb: return wa > wb
		return pa > pb
	)

	var rows: Array = []
	var rank: int = 1
	for row_data in entries:
		var row: Dictionary = row_data as Dictionary
		var team: PSTeam = row["team"] as PSTeam
		var entry: Dictionary = row["entry"] as Dictionary
		var w: int = int(entry.get("wins", 0))
		var l: int = int(entry.get("losses", 0))
		var d: int = int(entry.get("draws", 0))
		rows.append({
			"rank": rank,
			"team": team.short_name,
			"w": w,
			"l": l,
			"d": d,
			"pct": float(w) / float(max(1, w + l)),
		})
		rank += 1
	return rows


func _format_postseason_awards(archive: PSSeasonArchive) -> String:
	var lines: Array = []

	# Postseason
	if archive.postseason != null:
		lines.append("== ポストシーズン ==")
		var post: PSPostseasonResult = archive.postseason
		for stage_key in PSPostseasonResult.STAGE_KEYS:
			var s: Dictionary = post.stage_dict(stage_key)
			if s.is_empty() or not bool(s.get("completed", false)):
				continue
			var top_id: int = int(s.get("top_id", 0))
			var chal_id: int = int(s.get("challenger_id", 0))
			var winner_id: int = int(s.get("winner_id", 0))
			var top_wins: int = int(s.get("top_wins_final", 0))
			var chal_wins: int = int(s.get("challenger_wins_final", 0))
			lines.append("%s: %s %d勝-%d敗 %s  → 勝者 %s" % [
				str(STAGE_LABELS.get(stage_key, stage_key)),
				_team_short(top_id), top_wins, chal_wins, _team_short(chal_id),
				_team_short(winner_id),
			])
		if post.champion_team_id > 0:
			lines.append("")
			lines.append("★ 日本一: %s ★" % _team_full(post.champion_team_id))
		lines.append("")

	# Awards
	if archive.awards != null:
		lines.append("== 主要表彰 ==")
		var awards: PSAwards = archive.awards
		lines.append("[セ MVP] %s   [パ MVP] %s" % [
			_player_label(awards.mvp_central_player_id), _player_label(awards.mvp_pacific_player_id),
		])
		lines.append("[セ 新人王] %s   [パ 新人王] %s" % [
			_player_label(awards.rookie_central_player_id), _player_label(awards.rookie_pacific_player_id),
		])
		lines.append("")
		lines.append("[打撃タイトル]")
		_add_titles_lines(lines, awards.batting_titles, BATTING_TITLE_LABELS, PSAwards.BATTING_CATEGORIES)
		lines.append("")
		lines.append("[投手タイトル]")
		_add_titles_lines(lines, awards.pitching_titles, PITCHING_TITLE_LABELS, PSAwards.PITCHING_CATEGORIES)

	return "\n".join(lines)


func _add_titles_lines(lines: Array, titles_by_league: Dictionary, label_map: Dictionary, order: Array) -> void:
	var central: Dictionary = titles_by_league.get("central", {}) as Dictionary
	var pacific: Dictionary = titles_by_league.get("pacific", {}) as Dictionary
	for key in order:
		lines.append("  %s  セ:%s  /  パ:%s" % [
			str(label_map.get(key, key)),
			_player_label(int(central.get(key, 0))),
			_player_label(int(pacific.get(key, 0))),
		])


func _player_label(player_id: int) -> String:
	if player_id <= 0:
		return "(該当なし)"
	# 履歴選手は過去年度のレコードを探す(同年度のみ)
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record.name
	# 現役選手から探す
	var player: PSPlayer = GameDb.get_player(player_id)
	if player != null:
		return player.name
	return "ID %d" % player_id


func _team_short(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


func _team_full(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.name
