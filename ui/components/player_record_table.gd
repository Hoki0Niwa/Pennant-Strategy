extends "res://ui/components/dashboard_screen.gd"

const PlayerVisibleRatings = preload("res://services/simulation/player_visible_ratings.gd")
const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
# 行ハイライト/選択強調用の補助色。
const SEL_RELEASE: Color = Color(0.95, 0.6, 0.55)
const SEL_DEMOTE: Color = Color(0.6, 0.85, 0.65)
const CLOSER_RED: Color = Color(0.92, 0.24, 0.30)
const PLAYER_TAB_PITCHER: String = "pitcher"
const PLAYER_TAB_FIELDER: String = "fielder"
# 選手表の区分ラベル (ポスティング / 復帰 / 支配下 など) の枠幅。投手表の区分は FIP 枠の右端から
# 80px 右にあるので、これより広げると FIP と重なる。「ポスティング」(13px で約 78px) が収まる幅。
const OUTCOME_LABEL_BOX: float = 80.0
var _row_hits: Array = []          # [{rect, kind, meta}] base 座標の行当たり判定
var _scroll_zones: Array = []      # [{rect, key, max}] ホイールスクロール領域
var _scroll: Dictionary = {}       # key -> 先頭行オフセット


# 共通選手表。指名履歴の混在モード以外は投手・野手を分ける。
func _draw_player_record_table(rect: Rect2, title: String, source_rows: Array, pitcher_table: bool, sel_kind: String, scroll_key: String, _selection_group: String, selected_id: int, empty_text: String, show_tab_space: bool, career_stats: bool, team_mode: String = "", show_salary: bool = false, show_offer_years: bool = false, history_mode: bool = false) -> void:
	if history_mode and team_mode == "draft_history_mixed":
		_draw_draft_history_mixed_table(rect, title, source_rows, sel_kind, scroll_key, selected_id, empty_text, show_tab_space)
		return
	_round(rect, PANEL, Color.TRANSPARENT, 8, 0)
	var title_x: float = rect.position.x + (222.0 if show_tab_space else 18.0)
	_round(Rect2(title_x, rect.position.y + 21.0, 3, 14), BLUE, Color.TRANSPARENT, 2, 0)
	_text(title, Vector2(title_x + 9.0, rect.position.y + 34.0), 15, TEXT, rect.end.x - title_x - 9.0 - 18.0, HORIZONTAL_ALIGNMENT_LEFT, true)

	var rows: Array = []
	for row_value in source_rows:
		var model: Dictionary = _player_row_model(row_value)
		history_mode = history_mode or str(model.get("presentation", "")) == "historical"
		var record: PSPlayerSeasonRecord = model.get("record", null) as PSPlayerSeasonRecord
		if record == null:
			continue
		if record.is_pitcher() == pitcher_table:
			rows.append(model)

	var effective_team_mode: String = team_mode
	if history_mode:
		effective_team_mode = "draft_history" if team_mode == "draft_history" else "history"
		show_salary = false
		show_offer_years = false
		for i in rows.size():
			var historical_row: Dictionary = (rows[i] as Dictionary).duplicate(false)
			historical_row["presentation"] = "historical"
			rows[i] = historical_row
	elif effective_team_mode.is_empty() and _rows_include_multiple_teams(rows):
		effective_team_mode = "team"
	var table_gap: float = 14.0 if show_tab_space else 0.0
	var hy: float = rect.position.y + 64.0 + table_gap
	if pitcher_table:
		_draw_pitcher_table_header(rect, hy, effective_team_mode, career_stats, show_salary, show_offer_years, history_mode)
	else:
		_draw_fielder_table_header(rect, hy, effective_team_mode, career_stats, show_salary, show_offer_years, history_mode)

	if rows.is_empty():
		if not empty_text.is_empty():
			_text(empty_text, Vector2(rect.position.x + 18.0, rect.position.y + 116.0 + table_gap), 14, MUTED)
		return

	var row_h: float = 27.0
	var row_top: float = rect.position.y + 94.0 + table_gap
	var bottom: float = rect.end.y - 12.0
	var visible_count: int = max(1, int((bottom - row_top) / row_h))
	var max_scroll: int = max(0, rows.size() - visible_count)
	var offset: int = clampi(int(_scroll.get(scroll_key, 0)), 0, max_scroll)
	_scroll[scroll_key] = offset
	if max_scroll > 0:
		_scroll_zones.append({"rect": rect, "key": scroll_key, "max": max_scroll})

	var y: float = row_top + 21.0
	var drawn: int = 0
	for i in range(offset, min(offset + visible_count, rows.size())):
		var row: Dictionary = rows[i] as Dictionary
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		var row_rect: Rect2 = Rect2(rect.position.x + 10.0, y - 19.0, rect.size.x - 20.0, row_h)
		var state: String = "" if history_mode else _player_table_selection_state(record.player_id, sel_kind)
		var selected: bool = sel_kind != "release" and sel_kind != "geneki_list" and selected_id > 0 and record.player_id == selected_id
		if state == "release":
			_round(row_rect, Color(SEL_RELEASE.r, SEL_RELEASE.g, SEL_RELEASE.b, 0.14), Color(SEL_RELEASE.r, SEL_RELEASE.g, SEL_RELEASE.b, 0.45), 6, 1)
		elif state == "demote":
			_round(row_rect, Color(SEL_DEMOTE.r, SEL_DEMOTE.g, SEL_DEMOTE.b, 0.14), Color(SEL_DEMOTE.r, SEL_DEMOTE.g, SEL_DEMOTE.b, 0.45), 6, 1)
		elif selected:
			_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.14), Color(BLUE.r, BLUE.g, BLUE.b, 0.45), 6, 1)

		if pitcher_table:
			_draw_pitcher_player_row(rect, row, y, effective_team_mode, career_stats, show_salary, show_offer_years)
		else:
			_draw_fielder_player_row(rect, row, y, effective_team_mode, career_stats, show_salary, show_offer_years)
		# 行モデルの `__dim` は「対象外/非該当」を表すグレーアウト (例: FA宣言しなかった選手)。
		# セルごとに色を持たせず、描画後に背景色の半透明を重ねて行全体を一様に沈める。
		if bool(row.get("__dim", false)):
			_round(row_rect, Color(PANEL.r, PANEL.g, PANEL.b, 0.62), Color.TRANSPARENT, 6, 0)
		if not sel_kind.is_empty():
			_row_hits.append({"rect": row_rect, "kind": sel_kind, "meta": record.player_id})
		# 縞の代わりに全行の下へヘアライン区切り (基底 _draw_data_table と同じ表現)。
		_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), HAIRLINE, 1.0)
		drawn += 1
		y += row_h

	# 列グループ境界の縦ヘアライン (識別 / 評価 / 能力 / 成績の各ブロック境界)。
	var sep_xs: Array = _player_table_sep_xs(_player_table_x(rect, effective_team_mode, show_salary, show_offer_years, history_mode), pitcher_table, history_mode)
	var band_top: float = hy - 18.0
	var rows_bottom: float = row_top + float(drawn) * row_h
	for sep_x in sep_xs:
		_line(Vector2(float(sep_x), band_top), Vector2(float(sep_x), rows_bottom), HAIRLINE, 1.0)

	if max_scroll > 0:
		_text_right("%d / %d" % [min(offset + visible_count, rows.size()), rows.size()], rect.end.x - 14.0, rect.end.y - 8.0, 10, FAINT, 120.0)


func _draw_draft_history_mixed_table(rect: Rect2, title: String, source_rows: Array, sel_kind: String, scroll_key: String, selected_id: int, empty_text: String, show_tab_space: bool) -> void:
	var columns: Array = [
		{"key": "round", "title": "col.round", "w": 42, "align": "c"},
		{"key": "name", "title": "col.player", "w": 240, "align": "l", "strong": true},
		{"key": "age", "title": "col.age", "w": 52},
		{"key": "position", "title": "col.pos", "w": 64, "fmt": "pos_badge"},
		{"key": "source", "title": "col.source", "w": 110, "align": "l"},
		{"key": "war", "title": "WAR", "w": 84, "sep_before": true},
		{"key": "games", "title": "col.games", "w": 80},
		{"key": "pa", "title": "col.pa", "w": 90},
		{"key": "avg", "title": "col.avg", "w": 95},
		{"key": "hr", "title": "col.hr", "w": 70},
		{"key": "rbi", "title": "stat.rbi", "w": 80},
		{"key": "ops", "title": "OPS", "w": 95},
		{"key": "appearances", "title": "col.appearances", "w": 80, "sep_before": true},
		{"key": "ip", "title": "col.innings", "w": 100},
		{"key": "era", "title": "stat.era", "w": 90},
		{"key": "strikeouts", "title": "stat.strikeouts", "w": 85},
	]
	var rows: Array = []
	for row_value in source_rows:
		var model: Dictionary = _player_row_model(row_value)
		if model.get("record") is PSPlayerSeasonRecord:
			rows.append(_draft_history_mixed_row(model))
	_draw_data_table(rect, columns, rows, {"title": title, "title_pad": 222.0 if show_tab_space else 18.0,
		"title_y": 34.0, "title_size": 15, "title_width": rect.size.x - (258.0 if show_tab_space else 54.0),
		"header_top": 78.0 if show_tab_space else 64.0, "header_size": 11, "cell_size": 13,
		"default_align": "r", "row_h": 27.0, "bottom_pad": 12.0, "empty_text": empty_text,
		"scroll_key": scroll_key, "scroll": _scroll, "scroll_zones": _scroll_zones,
		"sel_kind": sel_kind, "selected_id": selected_id, "hits": _row_hits})


# 混在表でも、当該役割の件数・率と凍結WARだけを表示する。
func _draft_history_mixed_row(model: Dictionary) -> Dictionary:
	var record: PSPlayerSeasonRecord = model["record"] as PSPlayerSeasonRecord
	var entry: Dictionary = model.get("entry", {}) as Dictionary
	var values: Dictionary = PSPlayerRecordTableRow.historical_values(model)
	var bs: PSBatterStats = record.batter_stats
	var ps: PSPitcherStats = record.pitcher_stats
	var pitcher: bool = record.is_pitcher()
	var source_type: String = str(entry.get("source_type", ""))
	var source_key: String = "draft.source.%s" % source_type
	var source_label: String = Loc.t(source_key) if Loc.has_key(source_key) else "-"
	var has_obp: bool = bs.at_bats + bs.walks + bs.hit_by_pitches + bs.sacrifice_flies > 0
	return {"__meta": record.player_id, "round": str(int(entry["round"])) if int(entry.get("round", 0)) > 0 else "-",
		"name": record.name, "age": str(record.age), "position": _position_char(record.position),
		"position_color": _pos_color(record.position), "position_dev": record.development_player, "source": source_label,
		"war": str(values["war_text"]), "war_color": _war_value_color(float(values["war_value"])),
		"games": "-" if pitcher else str(bs.games), "pa": "-" if pitcher else str(bs.plate_appearances),
		"avg": _rate_short(bs.batting_average()) if not pitcher and bs.at_bats > 0 else "-",
		"hr": "-" if pitcher else str(bs.home_runs), "rbi": "-" if pitcher else str(bs.runs_batted_in),
		"ops": _rate_short(bs.ops()) if not pitcher and bs.at_bats > 0 and has_obp else "-",
		"appearances": str(ps.games) if pitcher else "-",
		"ip": "%d.%d" % [int(float(ps.outs_pitched) / 3.0), ps.outs_pitched % 3] if pitcher else "-",
		"era": "%.2f" % ps.era() if pitcher and ps.outs_pitched > 0 else "-",
		"strikeouts": str(ps.strikeouts) if pitcher else "-"}


func _draw_pitcher_table_header(rect: Rect2, y: float, team_mode: String, _career_stats: bool,show_salary: bool, show_offer_years: bool = false, history_mode: bool = false) -> void:
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years, history_mode)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_draw_player_table_identity_header(xs, y, team_mode, true, history_mode)
	if not history_mode:
		_text_cell(Loc.t("rating.velocity"), float(xs["velo_r"]), y, 11, FAINT, 58.0)
		_text_cell(Loc.t("rating.stuff"), float(xs["stuff_r"]), y, 11, FAINT)
		_text_cell(Loc.t("rating.control"), float(xs["ctrl_r"]), y, 11, FAINT)
		_text_cell(Loc.t("rating.stamina"), float(xs["stam_r"]), y, 11, FAINT, 54.0)
	_text_cell(Loc.t("col.appearances"), float(xs["g_r"]), y, 11, FAINT, 44.0)
	_text_cell(Loc.t("col.wins"), float(xs["w_r"]), y, 11, FAINT, 28.0)
	_text_cell(Loc.t("col.losses"), float(xs["l_r"]), y, 11, FAINT, 28.0)
	_text_cell("S", float(xs["sv_r"]), y, 11, FAINT, 28.0)
	_text_cell("H", float(xs["hld_r"]), y, 11, FAINT, 28.0)
	_text_cell(Loc.t("col.innings"), float(xs["ip_r"]), y, 11, FAINT, 62.0)
	_text_cell(Loc.t("stat.era"), float(xs["era_r"]), y, 11, FAINT, 62.0)
	_text_cell(_contract_slot_label(team_mode, "FIP"), float(xs["fip_r"]), y, 11, FAINT, 54.0)
	_text_cell(_outcome_slot_label(team_mode, "WHIP"), float(xs["whip_r"]), y, 11, FAINT, 58.0)
	if not xs.has("salary_r"):
		_text_cell("K/9", float(xs["k9_r"]), y, 11, FAINT, 54.0)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


# 投手/野手表で共通の左側見出し (球団列 → 役割/守備 → 選手 → 契約系列 → 年齢/在籍/怪我/評価/WAR)。
func _draw_player_table_identity_header(xs: Dictionary, y: float, team_mode: String, pitcher: bool, history_mode: bool = false) -> void:
	if history_mode:
		_text(Loc.t("col.team"), Vector2(float(xs["team_x"]), y), 11, FAINT, 56.0)
	elif _is_move_team_column_mode(team_mode):
		_text(Loc.t("offseason.col.from_team"), Vector2(float(xs["team_from_x"]), y), 11, FAINT, 56.0)
		_text(Loc.t("offseason.col.to_team"), Vector2(float(xs["team_to_x"]), y), 11, FAINT, 56.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text(Loc.t("offseason.col.current_team") if team_mode == "fgc_market_away" else Loc.t("col.team"), Vector2(float(xs["team_x"]), y), 11, FAINT)
	if pitcher:
		_text(Loc.t("col.role"), Vector2(float(xs["role_x"]), y), 11, FAINT, 52.0, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_text(Loc.t("col.pos"), Vector2(float(xs["role_x"]), y), 11, FAINT, 40.0, HORIZONTAL_ALIGNMENT_CENTER)
	_text(Loc.t("col.player"), Vector2(float(xs["name_x"]), y), 11, FAINT)
	if history_mode:
		_text_cell(Loc.t("col.age"), float(xs["age_r"]), y, 11, FAINT, 40.0)
		if team_mode == "draft_history":
			_text_cell(Loc.t("col.round"), float(xs["years_r"]), y, 11, FAINT, 44.0)
			_text_cell(Loc.t("col.category"), float(xs["inj_r"]), y, 11, FAINT, 54.0)
			_text(Loc.t("col.source"), Vector2(float(xs["source_x"]), y), 11, FAINT, 100.0)
		_text_cell("WAR", float(xs["war_r"]), y, 11, FAINT, 46.0)
		return
	if xs.has("salary_r"):
		_text_cell(Loc.t("offseason.col.years") if _is_contract_offer_mode(team_mode) else Loc.t("col.salary"), float(xs["salary_r"]), y, 11, FAINT, 44.0 if _is_contract_offer_mode(team_mode) else 76.0)
	if xs.has("offer_years_r"):
		_text_cell(_offer_amount_label(team_mode), float(xs["offer_years_r"]), y, 11, FAINT, 66.0 if _is_contract_offer_mode(team_mode) else 46.0)
	if team_mode == "contract":
		_text_cell(Loc.t("offseason.col.salary_delta"), float(xs["salary_delta_r"]), y, 11, FAINT, 80.0)
	if xs.has("contract_years_r"):
		_text_cell(Loc.t("offseason.col.contract_years"), float(xs["contract_years_r"]), y, 11, FAINT, 52.0)
	_text_cell(Loc.t("col.age"), float(xs["age_r"]), y, 11, FAINT, 40.0)
	_text_cell(Loc.t("offseason.col.tenure_short"), float(xs["years_r"]), y, 11, FAINT, 30.0)
	_text_cell(Loc.t("offseason.col.injury_short"), float(xs["inj_r"]), y, 11, FAINT, 30.0)
	_text_cell(Loc.t("col.evaluation"), float(xs["eval_r"]), y, 11, FAINT, 44.0)
	_text_cell("WAR", float(xs["war_r"]), y, 11, FAINT, 46.0)


func _draw_fielder_table_header(rect: Rect2, y: float, team_mode: String, _career_stats: bool, show_salary: bool, show_offer_years: bool = false, history_mode: bool = false) -> void:
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years, history_mode)
	_round(Rect2(rect.position.x + 12.0, y - 18.0, rect.size.x - 24.0, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_draw_player_table_identity_header(xs, y, team_mode, false, history_mode)
	if not history_mode:
		_text_cell(Loc.t("rating.contact"), float(xs["meet_r"]), y, 11, FAINT, 38.0)
		_text_cell(Loc.t("rating.power"), float(xs["pow_r"]), y, 11, FAINT, 38.0)
		_text_cell(Loc.t("rating.speed"), float(xs["spd_r"]), y, 11, FAINT, 38.0)
		_text_cell(Loc.t("rating.defense"), float(xs["def_r"]), y, 11, FAINT, 38.0)
		_text_cell(Loc.t("rating.arm"), float(xs["arm_r"]), y, 11, FAINT, 38.0)
		_text_cell(Loc.t("rating.discipline"), float(xs["eye_r"]), y, 11, FAINT, 38.0)
	_text_cell(Loc.t("col.games"), float(xs["g_r"]), y, 11, FAINT, 42.0)
	_text_cell(Loc.t("col.avg"), float(xs["avg_r"]), y, 11, FAINT, 52.0)
	_text_cell(Loc.t("col.hr"), float(xs["hr_r"]), y, 11, FAINT, 34.0)
	_text_cell(Loc.t("stat.rbi"), float(xs["rbi_r"]), y, 11, FAINT, 44.0)
	_text_cell(_contract_slot_label(team_mode, "stat.stolen_bases"), float(xs["sb_r"]), y, 11, FAINT, 44.0)
	if not xs.has("salary_r"):
		_text_cell(Loc.t("stat.obp"), float(xs["obp_r"]), y, 11, FAINT, 62.0)
	_text_cell("OPS", float(xs["ops_r"]), y, 11, FAINT, 54.0)
	if xs.has("salary_r"):
		_text_cell("wRC+", float(xs["woba_r"]), y, 11, FAINT, 60.0)
	else:
		_text_cell("wOBA", float(xs["woba_r"]), y, 11, FAINT, 60.0)
		_text_cell("wRC+", float(xs["wrc_r"]), y, 11, FAINT, 56.0)
	_text_cell(_outcome_slot_label(team_mode, "OAA"), float(xs["oaa_r"]), y, 11, FAINT, 54.0)
	_line(Vector2(rect.position.x + 12.0, y + 8.0), Vector2(rect.end.x - 12.0, y + 8.0), BORDER, 1.5)


func _draw_pitcher_player_row(rect: Rect2, row: Dictionary, y: float, team_mode: String, career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
	var player: PSPlayer = row.get("player", null) as PSPlayer
	var history_mode: bool = str(row.get("presentation", "")) == "historical"
	var values: Dictionary = _player_table_values(row, career_stats)
	var entry: Dictionary = row.get("entry", {}) as Dictionary
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years, history_mode)
	if history_mode:
		_text(str(entry.get("team_name", "-")), Vector2(float(xs["team_x"]), y), 12, MUTED, 56.0)
	elif _is_move_team_column_mode(team_mode):
		_text(_move_team_short(int(entry.get("from_team", 0)), team_mode), Vector2(float(xs["team_from_x"]), y), 12, MUTED, 52.0)
		_text(_move_team_short(int(entry.get("to_team", entry.get("team_id", record.team_id))), team_mode), Vector2(float(xs["team_to_x"]), y), 12, TEXT, 52.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text(_team_short(int(entry.get("team_id", record.team_id))), Vector2(float(xs["team_x"]), y), 12, MUTED, 52.0)
	_role_badge(Rect2(float(xs["role_x"]), y - 16.0, 52.0, 22.0), record, _entry_development_flag(entry, record))
	_draw_identity_cells(record, player, entry, xs, y, team_mode, history_mode)

	if not history_mode:
		var value: int = PlayerValueEvaluator.overall_score(record)
		_text_cell(str(value), float(xs["eval_r"]), y, 13, _grade_color(value), 44.0)
		_draw_velocity_value(PlayerVisibleRatings.pitcher_velocity(record), float(xs["velo_r"]), y, 58.0)
		_draw_rating_value(PlayerVisibleRatings.pitcher_stuff(record), float(xs["stuff_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.pitcher_control(record), float(xs["ctrl_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.pitcher_stamina(record), float(xs["stam_r"]), y)
	_text_cell(str(values["war_text"]), float(xs["war_r"]), y, 13, _war_value_color(float(values["war_value"])), 46.0)

	var ps: PSPitcherStats = values["pitcher_stats"] as PSPitcherStats
	_text_cell(str(ps.games), float(xs["g_r"]), y, 13, TEXT, 44.0)
	_text_cell(str(ps.wins), float(xs["w_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.losses), float(xs["l_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.saves), float(xs["sv_r"]), y, 13, MUTED, 28.0)
	_text_cell(str(ps.holds), float(xs["hld_r"]), y, 13, MUTED, 28.0)
	_text_cell(_ip_str(ps), float(xs["ip_r"]), y, 13, TEXT, 62.0)
	_text_cell(_era_str_from_stats(ps), float(xs["era_r"]), y, 13, TEXT, 62.0)
	# 契約系の team_mode は FIP/WHIP 枠を契約情報へ差し替える (見出しは _contract_slot_label /
	# _outcome_slot_label が単一ソース)。契約提示系 (fgc_market* / contract_years) は提示状態・現年俸、
	# fa_declaration は権利・去就。成立した契約年数は年俸の隣の専用列 (contract_years_r) が出す。
	if _is_contract_offer_mode(team_mode) or team_mode == "fa_declaration":
		_text_cell(str(entry.get("offer_text", "-")), float(xs["fip_r"]), y, 13, entry.get("offer_color", FAINT) as Color, 54.0)
	else:
		_text_cell(str(values["fip_text"]), float(xs["fip_r"]), y, 13, MUTED, 54.0)
	if _is_outcome_slot_mode(team_mode):
		_text_cell(str(entry.get("outcome_label", "")), float(xs["whip_r"]), y, 13, entry.get("outcome_color", TEXT) as Color, OUTCOME_LABEL_BOX)
	elif _is_contract_offer_mode(team_mode):
		_text_cell(str(entry.get("fgc_current_salary_text", "-")), float(xs["whip_r"]), y, 13, MUTED, 58.0)
	else:
		_text_cell(_whip_str(ps), float(xs["whip_r"]), y, 13, MUTED, 58.0)
	if not xs.has("salary_r"):
		_text_cell(_k9_str(ps), float(xs["k9_r"]), y, 13, MUTED, 54.0)


func _draw_fielder_player_row(rect: Rect2, row: Dictionary, y: float, team_mode: String, career_stats: bool, show_salary: bool, show_offer_years: bool = false) -> void:
	var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
	var player: PSPlayer = row.get("player", null) as PSPlayer
	var history_mode: bool = str(row.get("presentation", "")) == "historical"
	var values: Dictionary = _player_table_values(row, career_stats)
	var entry: Dictionary = row.get("entry", {}) as Dictionary
	var xs: Dictionary = _player_table_x(rect, team_mode, show_salary, show_offer_years, history_mode)
	if history_mode:
		_text(str(entry.get("team_name", "-")), Vector2(float(xs["team_x"]), y), 12, MUTED, 56.0)
	elif _is_move_team_column_mode(team_mode):
		_text(_move_team_short(int(entry.get("from_team", 0)), team_mode), Vector2(float(xs["team_from_x"]), y), 12, MUTED, 52.0)
		_text(_move_team_short(int(entry.get("to_team", entry.get("team_id", record.team_id))), team_mode), Vector2(float(xs["team_to_x"]), y), 12, TEXT, 52.0)
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		_text(_team_short(int(entry.get("team_id", record.team_id))), Vector2(float(xs["team_x"]), y), 12, MUTED, 52.0)
	_position_badge(Rect2(float(xs["role_x"]), y - 16.0, 40.0, 22.0), record.position, _entry_development_flag(entry, record))
	_draw_identity_cells(record, player, entry, xs, y, team_mode, history_mode)

	if not history_mode:
		var value: int = PlayerValueEvaluator.overall_score(record)
		_text_cell(str(value), float(xs["eval_r"]), y, 13, _grade_color(value), 44.0)
		_draw_rating_value(PlayerVisibleRatings.fielder_contact(record), float(xs["meet_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_power(record), float(xs["pow_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_speed(record), float(xs["spd_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_defense(record), float(xs["def_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_arm(record), float(xs["arm_r"]), y)
		_draw_rating_value(PlayerVisibleRatings.fielder_discipline(record), float(xs["eye_r"]), y)
	_text_cell(str(values["war_text"]), float(xs["war_r"]), y, 13, _war_value_color(float(values["war_value"])), 46.0)

	var bs: PSBatterStats = values["batter_stats"] as PSBatterStats
	var has_at_bats: bool = not history_mode or bs.at_bats > 0
	var has_obp: bool = not history_mode or bs.at_bats + bs.walks + bs.hit_by_pitches + bs.sacrifice_flies > 0
	_text_cell(str(bs.games), float(xs["g_r"]), y, 13, TEXT, 42.0)
	_text_cell(_rate_short(bs.batting_average()) if has_at_bats else "-", float(xs["avg_r"]), y, 13, TEXT, 52.0)
	_text_cell(str(bs.home_runs), float(xs["hr_r"]), y, 13, TEXT, 34.0)
	_text_cell(str(bs.runs_batted_in), float(xs["rbi_r"]), y, 13, MUTED, 44.0)
	# 契約系の team_mode は盗塁/OAA 枠を契約情報へ差し替える (投手表の FIP/WHIP 枠と対応、
	# 見出しは _contract_slot_label / _outcome_slot_label が単一ソース)。
	if _is_contract_offer_mode(team_mode) or team_mode == "fa_declaration":
		_text_cell(str(entry.get("offer_text", "-")), float(xs["sb_r"]), y, 13, entry.get("offer_color", FAINT) as Color, 44.0)
	else:
		_text_cell(str(bs.stolen_bases), float(xs["sb_r"]), y, 13, MUTED, 44.0)
	if not xs.has("salary_r"):
		_text_cell(_rate_short(bs.on_base_percentage()) if has_obp else "-", float(xs["obp_r"]), y, 13, MUTED, 62.0)
	_text_cell(_rate_short(bs.ops()) if has_at_bats and has_obp else "-", float(xs["ops_r"]), y, 13, TEXT, 54.0)
	var woba_text: String = str(values["woba_text"])
	var wrc_text: String = str(values["wrc_text"])
	if xs.has("salary_r"):
		_text_cell(wrc_text, float(xs["woba_r"]), y, 13, MUTED, 60.0)
	else:
		_text_cell(woba_text, float(xs["woba_r"]), y, 13, MUTED, 60.0)
		_text_cell(wrc_text, float(xs["wrc_r"]), y, 13, MUTED, 56.0)
	if _is_outcome_slot_mode(team_mode):
		_text_cell(str(entry.get("outcome_label", "")), float(xs["oaa_r"]), y, 13, entry.get("outcome_color", TEXT) as Color, OUTCOME_LABEL_BOX)
	elif _is_contract_offer_mode(team_mode):
		_text_cell(str(entry.get("fgc_current_salary_text", "-")), float(xs["oaa_r"]), y, 13, MUTED, 54.0)
	else:
		_text_cell(str(values["oaa_text"]), float(xs["oaa_r"]), y, 13, values["oaa_color"] as Color, 54.0)


func _draw_identity_cells(record: PSPlayerSeasonRecord, player: PSPlayer, entry: Dictionary, xs: Dictionary, y: float, team_mode: String = "", history_mode: bool = false) -> void:
	if not history_mode and record.jersey_number > 0:
		_text(str(record.jersey_number), Vector2(float(xs["jersey_x"]), y), 12, FAINT)
	var name_limit_x: float = (float(xs["salary_r"]) - 88.0) if xs.has("salary_r") else (float(xs["age_r"]) - 46.0)
	_text(record.name, Vector2(float(xs["name_x"]), y), 13, TEXT, name_limit_x - float(xs["name_x"]), HORIZONTAL_ALIGNMENT_LEFT, true)
	if history_mode:
		_text_cell(str(record.age), float(xs["age_r"]), y, 13, MUTED, 40.0)
		if team_mode == "draft_history":
			var round_text: String = str(int(entry["round"])) if int(entry.get("round", 0)) > 0 else "-"
			_text_cell(round_text, float(xs["years_r"]), y, 13, TEXT, 44.0)
			var type_key: String = "registered_roster.development" if record.development_player else "registered_roster.controlled"
			_text_cell(Loc.t(type_key), float(xs["inj_r"]), y, 13, MUTED, 54.0)
			var source_type: String = str(entry.get("source_type", ""))
			var source_key: String = "draft.source.%s" % source_type
			var source_label: String = Loc.t(source_key) if Loc.has_key(source_key) else (source_type if not source_type.is_empty() else "-")
			_text(source_label, Vector2(float(xs["source_x"]), y), 12, MUTED, 100.0)
		return
	# 契約市場 (fgc_market) は前方2列を [年数][提示年俸] にする。salary_r 枠に年数、offer_years_r 枠に
	# 提示年俸 (億表示・幅広) を描く。現年俸は後方 (whip_r/oaa_r 枠) へ回す (_draw_*_player_row 側)。
	var fgc_market: bool = _is_contract_offer_mode(team_mode)
	if xs.has("salary_r"):
		if fgc_market:
			# 年数は既定で "N年"。決定状態そのものを見せたい一覧 (契約年数) は fgc_years_text で上書きする。
			_text_cell(str(entry.get("fgc_years_text", Loc.t("offseason.years_value", {"n": int(entry.get("fgc_years", 1))}))),
				float(xs["salary_r"]), y, 13, entry.get("fgc_years_color", TEXT) as Color, 44.0)
		else:
			# salary_text は年俸を持たない行 (MLB で引退した選手など) の表示の上書き。
			var salary_text: String = str(entry["salary_text"]) if entry.has("salary_text") else _comma(_player_table_salary(entry, record))
			_text_cell(salary_text, float(xs["salary_r"]), y, 13, TEXT, 76.0)
	if xs.has("offer_years_r"):
		if fgc_market:
			_text_cell(str(entry.get("market_salary_text", "-")), float(xs["offer_years_r"]), y, 13, TEXT, 66.0)
		else:
			_text_cell(Loc.t("offseason.years_value", {"n": int(entry.get("offer_years", 0))}), float(xs["offer_years_r"]), y, 13, TEXT, 46.0)
	if xs.has("salary_delta_r"):
		var salary_delta: int = int(entry.get("salary_delta", 0))
		_text_cell(_salary_delta_text(salary_delta), float(xs["salary_delta_r"]), y, 13, _salary_delta_color(salary_delta), 80.0)
	if xs.has("contract_years_r"):
		# 契約年数は 1 を「単年」、2年以上を "N年" と出す。0 以下 (FA権未取得で年数を決める場面が無い、
		# 退団で契約自体が無い) は "-"。
		var contract_years: int = int(entry.get("contract_years", 1))
		var contract_years_text: String = "-"
		if contract_years == 1:
			contract_years_text = Loc.t("offseason.single_year")
		elif contract_years >= 2:
			contract_years_text = Loc.t("offseason.years_value", {"n": contract_years})
		_text_cell(contract_years_text, float(xs["contract_years_r"]), y, 13,
			BLUE if contract_years >= 2 else (MUTED if contract_years == 1 else FAINT), 52.0)
	_text_cell(str(record.age), float(xs["age_r"]), y, 13, MUTED, 40.0)
	_text_cell(str(record.years), float(xs["years_r"]), y, 13, MUTED, 30.0)
	var injury: int = _record_injury_days(record, player, entry)
	_text_cell(str(injury) if injury > 0 else "-", float(xs["inj_r"]), y, 13, RED if injury > 0 else FAINT, 30.0)


func _player_table_salary(entry: Dictionary, record: PSPlayerSeasonRecord) -> int:
	for key in ["new_salary", "offer_salary", "salary"]:
		if entry.has(key):
			return int(entry.get(key, record.salary))
	var candidate: Dictionary = entry.get("candidate", {}) as Dictionary
	for key in ["offer_salary", "salary"]:
		if candidate.has(key):
			return int(candidate.get(key, record.salary))
	return record.salary


# 外国人契約市場 (未解決) の team_mode。"fgc_market" は自軍 (現球団列なし)、"fgc_market_away" は
# 他球団 (現球団列あり)。
func _is_fgc_market_mode(team_mode: String) -> bool:
	return team_mode == "fgc_market" or team_mode == "fgc_market_away"


# 「契約年数を決める」系の一覧 (外国人契約市場と国内の契約年数ステップ) の team_mode。
# 前方2列を [年数][金額] にし、FIP/盗塁・WHIP/OAA 相当の枠を契約情報へ差し替える点が共通。
func _is_contract_offer_mode(team_mode: String) -> bool:
	return _is_fgc_market_mode(team_mode) or team_mode == "contract_years"


# FIP (投手) / 盗塁 (野手) 枠の見出し。契約系の team_mode はここを契約情報へ差し替える。
func _contract_slot_label(team_mode: String, default_label: String) -> String:
	match team_mode:
		"fgc_market", "fgc_market_away":
			return Loc.t("offseason.col.offer_state")
		"contract_years":
			return Loc.t("col.category")
		"fa_declaration":
			return Loc.t("offseason.col.fa_right")
	return Loc.t(default_label)


# WHIP (投手) / OAA (野手) 枠の見出し。契約系の team_mode はここを去就・現年俸へ差し替える。
func _outcome_slot_label(team_mode: String, default_label: String) -> String:
	match team_mode:
		"fgc_result", "fa_declaration":
			return Loc.t("offseason.col.outcome")
		"released_result", "overseas_result":
			return Loc.t("col.category")
		"fgc_market", "fgc_market_away", "contract_years":
			return Loc.t("offseason.col.current_salary")
	return Loc.t(default_label)


# 移籍元/移籍先の2列 (旧球団→新球団) を出す team_mode。
func _is_move_team_column_mode(team_mode: String) -> bool:
	return team_mode == "move" or team_mode == "fa_result" \
		or team_mode == "fgc_result" or team_mode == "released_result" \
		or team_mode == "overseas_result"


# 移籍元/移籍先の列に出す球団略称。メジャー挑戦の結果だけは海外側 (team_id 0) を「MLB」と出す
# (MLB で引退した選手の移籍先 OVERSEAS_RETIRED_TO_TEAM は球団が無いので「-」)。
func _move_team_short(team_id: int, team_mode: String) -> String:
	if team_id == 0 and team_mode == "overseas_result":
		return Loc.t("offseason.team.mlb")
	return _team_short(team_id)


# WHIP (投手) / OAA (野手) 枠へ、成績ではなく entry のラベル (去就・契約区分) を描く team_mode。
func _is_outcome_slot_mode(team_mode: String) -> bool:
	return team_mode == "fgc_result" or team_mode == "fa_declaration" \
		or team_mode == "released_result" or team_mode == "overseas_result"


# 前方2列目 (offer_years_r 枠) の見出し。契約提示系だけ金額を出すのでモードごとに呼び分ける。
func _offer_amount_label(team_mode: String) -> String:
	if team_mode == "contract_years":
		return Loc.t("offseason.col.base_salary")
	if _is_fgc_market_mode(team_mode):
		return Loc.t("offseason.col.offer_salary")
	return Loc.t("offseason.col.years")


# 年俸の隣に「契約年数」列を出す team_mode。列の幅は選手名の余白から捻出するので、
# 右側の成績ブロックの位置は変わらない (レイアウト崩れを起こさずに1列足せる唯一の空き)。
func _has_contract_years_column(team_mode: String) -> bool:
	return team_mode == "contract" or team_mode == "fa_result" or team_mode == "fgc_result" or team_mode == "contract_years_result"


func _player_table_x(rect: Rect2, team_mode: String, show_salary: bool = false, show_offer_years: bool = false, history_mode: bool = false) -> Dictionary:
	if history_mode:
		var xs: Dictionary = _player_table_x(rect, "team")
		var left: float = rect.position.x
		xs["age_r"] = left + 420.0
		xs["years_r"] = left + 480.0
		xs["inj_r"] = left + 560.0
		xs["war_r"] = left + 640.0
		xs["source_x"] = left + 664.0
		return xs
	if team_mode == "contract":
		var cleft: float = rect.position.x
		var cright: float = rect.end.x
		return {
			"team_x": cleft + 18.0,
			"team_from_x": cleft + 18.0,
			"team_to_x": cleft + 76.0,
			"role_x": cleft + 18.0,
			"jersey_x": cleft + 78.0,
			"name_x": cleft + 104.0,
			"salary_r": cleft + 286.0,
			"salary_delta_r": cleft + 366.0,
			"contract_years_r": cleft + 424.0,
			"age_r": cleft + 486.0,
			"years_r": cleft + 532.0,
			"inj_r": cleft + 578.0,
			"eval_r": cleft + 642.0,
			"war_r": cleft + 706.0,
			"velo_r": cleft + 790.0,
			"stuff_r": cleft + 872.0,
			"ctrl_r": cleft + 930.0,
			"stam_r": cleft + 988.0,
			"meet_r": cleft + 776.0,
			"pow_r": cleft + 822.0,
			"spd_r": cleft + 868.0,
			"def_r": cleft + 914.0,
			"arm_r": cleft + 960.0,
			"eye_r": cleft + 1006.0,
			"g_r": cright - 552.0,
			"w_r": cright - 500.0,
			"l_r": cright - 456.0,
			"sv_r": cright - 412.0,
			"hld_r": cright - 368.0,
			"ip_r": cright - 284.0,
			"era_r": cright - 196.0,
			"fip_r": cright - 108.0,
			"whip_r": cright - 28.0,
			"k9_r": cright - 28.0,
			"avg_r": cright - 486.0,
			"hr_r": cright - 426.0,
			"rbi_r": cright - 364.0,
			"sb_r": cright - 304.0,
			"obp_r": cright - 304.0,
			"ops_r": cright - 214.0,
			"woba_r": cright - 126.0,
			"wrc_r": cright - 126.0,
			"oaa_r": cright - 28.0,
		}
	var team_shift: float = 0.0
	if _is_move_team_column_mode(team_mode):
		team_shift = 120.0
	elif team_mode == "team" or team_mode == "contract_years_result" or team_mode == "fa_declaration" or team_mode == "fgc_market_away":
		team_shift = 68.0
	var left: float = rect.position.x
	var right: float = rect.end.x
	if show_salary:
		# 年俸列を持つ一覧は右側の成績を圧縮し、球団列の有無に応じて識別・能力ブロックを送る。
		# 限られた幅では K/9 (投手) または出塁率・wOBA (野手) を省き、契約更新表と同じ成績配置にする。
		# show_offer_years (FA候補一覧) は年俸の直後に提示年数を挿し込み、以降の左詰め列を後ろへ送る。
		# 右詰め列 (g_r 以降) は成績側の余白を消費するのみでここでは動かさない。
		var years_shift: float = 46.0 if show_offer_years else 0.0
		# 契約年数列は選手名の余白 (52px) を使うので、年俸列だけ左へ寄せて後続列は動かさない。
		var salary_shift: float = -52.0 if _has_contract_years_column(team_mode) else 0.0
		var salary_xs: Dictionary = {
			"team_x": left + 18.0,
			"team_from_x": left + 18.0,
			"team_to_x": left + 76.0,
			"role_x": left + 18.0 + team_shift,
			"jersey_x": left + 78.0 + team_shift,
			"name_x": left + 104.0 + team_shift,
			"salary_r": left + 338.0 + team_shift + salary_shift,
			"age_r": left + 406.0 + team_shift + years_shift,
			"years_r": left + 452.0 + team_shift + years_shift,
			"inj_r": left + 498.0 + team_shift + years_shift,
			"eval_r": left + 562.0 + team_shift + years_shift,
			"war_r": left + 626.0 + team_shift + years_shift,
			"velo_r": left + 710.0 + team_shift + years_shift,
			"stuff_r": left + 792.0 + team_shift + years_shift,
			"ctrl_r": left + 850.0 + team_shift + years_shift,
			"stam_r": left + 908.0 + team_shift + years_shift,
			"meet_r": left + 692.0 + team_shift + years_shift,
			"pow_r": left + 738.0 + team_shift + years_shift,
			"spd_r": left + 784.0 + team_shift + years_shift,
			"def_r": left + 830.0 + team_shift + years_shift,
			"arm_r": left + 876.0 + team_shift + years_shift,
			"eye_r": left + 922.0 + team_shift + years_shift,
			"g_r": right - 552.0,
			"w_r": right - 500.0,
			"l_r": right - 456.0,
			"sv_r": right - 412.0,
			"hld_r": right - 368.0,
			"ip_r": right - 284.0,
			"era_r": right - 196.0,
			"fip_r": right - 108.0,
			"whip_r": right - 28.0,
			"k9_r": right - 28.0,
			"avg_r": right - 486.0,
			"hr_r": right - 426.0,
			"rbi_r": right - 364.0,
			"sb_r": right - 304.0,
			"obp_r": right - 304.0,
			"ops_r": right - 214.0,
			"woba_r": right - 126.0,
			"wrc_r": right - 126.0,
			"oaa_r": right - 28.0,
		}
		if show_offer_years:
			# 契約市場は offer_years_r 枠に提示年俸 (億表示・66px) を描くため右へ広げる (年数列と衝突させない)。
			salary_xs["offer_years_r"] = (left + 408.0 + team_shift) if _is_contract_offer_mode(team_mode) else (left + 384.0 + team_shift)
		if _has_contract_years_column(team_mode):
			salary_xs["contract_years_r"] = left + 338.0 + team_shift
		return salary_xs
	var rating_shift: float = min(team_shift, 68.0)
	return {
		"team_x": left + 18.0,
		"team_from_x": left + 18.0,
		"team_to_x": left + 76.0,
		"role_x": left + 18.0 + team_shift,
		"jersey_x": left + 78.0 + team_shift,
		"name_x": left + 104.0 + team_shift,
		"age_r": left + 290.0 + team_shift,
		"years_r": left + 338.0 + team_shift,
		"inj_r": left + 388.0 + team_shift,
		"eval_r": left + 458.0 + team_shift,
		"war_r": left + 526.0 + team_shift,
		"velo_r": left + 626.0 + rating_shift,
		"stuff_r": left + 708.0 + rating_shift,
		"ctrl_r": left + 766.0 + rating_shift,
		"stam_r": left + 824.0 + rating_shift,
		"meet_r": left + 612.0 + rating_shift,
		"pow_r": left + 654.0 + rating_shift,
		"spd_r": left + 696.0 + rating_shift,
		"def_r": left + 738.0 + rating_shift,
		"arm_r": left + 780.0 + rating_shift,
		"eye_r": left + 822.0 + rating_shift,
		"g_r": right - 704.0,
		"w_r": right - 648.0,
		"l_r": right - 602.0,
		"sv_r": right - 556.0,
		"hld_r": right - 510.0,
		"ip_r": right - 426.0,
		"era_r": right - 326.0,
		"fip_r": right - 226.0,
		"whip_r": right - 122.0,
		"k9_r": right - 18.0,
		"avg_r": right - 626.0,
		"hr_r": right - 568.0,
		"rbi_r": right - 504.0,
		"sb_r": right - 444.0,
		"obp_r": right - 352.0,
		"ops_r": right - 264.0,
		"woba_r": right - 176.0,
		"wrc_r": right - 106.0,
		"oaa_r": right - 18.0,
	}


# _player_table_x の列 x から「識別 / 評価 / 能力 / 成績」ブロック境界の縦ヘアライン位置を出す。
# team_mode ごとに絶対値は変わるが eval_r/velo_r(or meet_r)/g_r は全モード共通キーなので分岐不要。
func _player_table_sep_xs(xs: Dictionary, pitcher: bool, history_mode: bool = false) -> Array:
	if history_mode:
		return [float(xs["age_r"]) - 50.0, float(xs["g_r"]) - 54.0]
	var eval_r: float = float(xs["eval_r"])
	var ability_r: float = float(xs["velo_r"]) if pitcher else float(xs["meet_r"])
	var ability_box: float = 58.0 if pitcher else 38.0
	var g_r: float = float(xs["g_r"])
	var g_box: float = 44.0 if pitcher else 42.0
	return [eval_r - 44.0 - 10.0, ability_r - ability_box - 10.0, g_r - g_box - 10.0]


func _player_row_model(row_value: Variant) -> Dictionary:
	if row_value is Dictionary:
		return row_value as Dictionary
	var record: PSPlayerSeasonRecord = row_value as PSPlayerSeasonRecord
	if record == null:
		return {}
	var player: PSPlayer = GameDb.get_player(record.player_id)
	return {
		"record": record,
		"player": player,
		"entry": {
			"player_id": record.player_id,
			"team_id": record.team_id,
			"position": record.position,
			"role": record.role,
		},
	}


func _rows_include_multiple_teams(rows: Array) -> bool:
	var first_team: int = -999
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var entry: Dictionary = row.get("entry", {}) as Dictionary
		var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
		var team_id: int = int(entry.get("team_id", record.team_id if record != null else 0))
		if first_team == -999:
			first_team = team_id
		elif team_id != first_team:
			return true
	return first_team != AppState.selected_team_id


# 支配下=塗り / 育成=アウトライン (枠のみ) で描き分ける。バッジ列を持つ全テーブルで共通。
# development を省略すると成績レコードの登録区分を使う。**移籍/獲得の結果表では
# レコードは移籍前 (=前所属での区分) を指す**ので、呼び出し側が新しい契約の区分を渡すこと
# (_entry_development_flag)。バッジは支配下=塗りつぶし / 育成=枠線のみ。
func _role_badge(rect: Rect2, record: PSPlayerSeasonRecord, development: bool = false) -> void:
	var role: String = _resolved_pitcher_role(record.role, {"starts": record.pitcher_stats.starts, "relief_appearances": record.pitcher_stats.relief_appearances})
	_chip(rect, _role_label(role), _role_color(role), not development)


# 行に描く登録区分 (支配下 false / 育成 true)。entry が新しい契約の区分を持っていればそれを優先し、
# 無ければ成績レコードの区分にフォールバックする。
func _entry_development_flag(entry: Dictionary, record: PSPlayerSeasonRecord) -> bool:
	return bool(entry.get("development_player", record.development_player))


func _position_badge(rect: Rect2, pos: int, development: bool = false) -> void:
	_chip(rect, _position_char(pos), _pos_color(pos), not development)


func _role_color(role: String) -> Color:
	match role:
		"starter":
			return PINK
		"closer":
			return CLOSER_RED
		_:
			return RED


func _text_cell(text: String, right_x: float, y: float, font_size: int, color: Color, box: float = 44.0) -> void:
	_text_right(text, right_x, y, font_size, color, box)


func _salary_delta_text(delta: int) -> String:
	if delta > 0:
		return "+%d" % delta
	return str(delta)


func _salary_delta_color(delta: int) -> Color:
	if delta > 0:
		return GREEN
	if delta < 0:
		return RED
	return FAINT


func _draw_velocity_value(value: int, right_x: float, y: float, box: float = 56.0) -> void:
	_text_cell("%dkm/h" % value, right_x, y, 12, TEXT, box)


func _draw_rating_value(value: int, right_x: float, y: float) -> void:
	_text_cell(str(value), right_x, y, 13, _grade_color(value))


func _grade_color(value: int) -> Color:
	return _table_rating_color(value)


func _record_injury_days(record: PSPlayerSeasonRecord, player: PSPlayer, _entry: Dictionary) -> int:
	if record != null and record.season_injury_days > 0:
		return record.season_injury_days
	return player.injury_days if player != null else 0


func _ip_str(ps: PSPitcherStats) -> String:
	if ps == null or ps.outs_pitched <= 0:
		return "0"
	@warning_ignore("integer_division")
	return "%d.%d" % [ps.outs_pitched / 3, ps.outs_pitched % 3]


func _era_str_from_stats(ps: PSPitcherStats) -> String:
	return "-.--" if ps == null or ps.outs_pitched <= 0 else "%0.2f" % ps.era()


func _whip_str(ps: PSPitcherStats) -> String:
	return "-.--" if ps == null or ps.outs_pitched <= 0 else "%0.2f" % ps.whip()


func _k9_str(ps: PSPitcherStats) -> String:
	return "-.-" if ps == null or ps.outs_pitched <= 0 else "%0.1f" % ps.strikeouts_per_nine()


func _war_value_color(war: float) -> Color:
	if war >= 2.0:
		return GREEN
	if war < 0.0:
		return RED
	return TEXT


func _role_label(role: String) -> String:
	match role:
		"starter":
			return Loc.t("role.starter")
		"reliever":
			return Loc.t("role.middle_short")
		"closer":
			return Loc.t("role.closer_short")
		_:
			return role


func _team_short(team_id: int) -> String:
	var team: PSTeam = GameDb.get_team(team_id)
	if team == null:
		return "-"
	return team.short_name


# 1文字の守備位置表記。DH だけは "DH" では幅が合わないので打順表と同じ "指" を使う。
func _position_char(pos: int) -> String:
	if pos == 10:
		return Loc.t("box.position.dh")
	return PSPlayer.position_short_name(pos)


func _resolved_pitcher_role(role: String, data: Dictionary) -> String:
	if role == "starter" or role == "reliever" or role == "closer":
		return role
	if int(data.get("starts", 0)) > int(data.get("relief_appearances", 0)):
		return "starter"
	return "reliever"

func _player_table_selection_state(_player_id: int, _sel_kind: String) -> String:
	return ""


# 回顧行は指定期間の値だけを使い、現在の通算を取得するホスト側のproviderを呼ばない。
func _player_table_values(row: Dictionary, career_stats: bool) -> Dictionary:
	if str(row.get("presentation", "")) == "historical":
		var values: Dictionary = PSPlayerRecordTableRow.historical_values(row)
		var oaa: float = float(values["oaa_value"])
		values["oaa_color"] = GREEN if oaa > 0.5 else (RED if oaa < -0.5 else MUTED)
		return values
	return _player_table_live_values(row, career_stats)


func _player_table_live_values(row: Dictionary, _career_stats: bool) -> Dictionary:
	var record: PSPlayerSeasonRecord = row.get("record", null) as PSPlayerSeasonRecord
	return {
		"batter_stats": record.batter_stats, "pitcher_stats": record.pitcher_stats,
		"advanced_stats": record.advanced_stats,
		"war_text": "-", "war_value": 0.0, "fip_text": "-",
		"wrc_text": "-", "woba_text": "-", "oaa_text": "-", "oaa_color": MUTED,
	}
