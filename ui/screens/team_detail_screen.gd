extends "res://ui/components/dashboard_screen.gd"

# チーム詳細画面。選択球団の順位、直近/今後の試合、起用設定、チーム内ランキングをまとめる。
# 表示要素:
#   - チーム識別バー: バッジ + 球団名 + リーグ + 右端の球団選択プルダウン (全12球団)。
#   - サマリーバー (2段): 今期のチーム成績。順位/勝敗/勝率/ゲーム差/得点/失点 と
#     打率/本塁打/盗塁/防御率/セーブ を並べ、各指標にリーグ内順位を添える。
#   - 直近5年のチーム成績 (アーカイブから簡素な順位/勝敗表)。
#   - 打線 (スタメン打順) / ローテーション・勝ちパターン (先発6 + セット/抑え)。
#   - 直近の対戦結果 / 今後の対戦予定 (schedule から自軍視点で抽出)。
#   - チーム内成績ランキング: 野手(打率/本塁打/打点/OPS/WAR) と投手(勝利/防御率/WAR/FIP/登板) を
#     色分け (野手=GREEN / 投手=BLUE) し各 Top3。防御率は先発限定。
# 重い集計は _refresh で1度だけ行いキャッシュし、_draw は描画専念。
# 打順/ローテ/勝ちパターンは保存値 (get_lineup/get_rotation) を優先、無ければ preview を表示。

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

# 打順表示用の短いポジション名。
const POS_SHORT: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "DH",
}

# --- レイアウト基準 (base 座標) ---
# ヘッダ (shell) は y=0..86。識別バーはその下に十分余白を取り、球団名が上へ飛び出さないようにする。
const ID_Y: float = 116.0                 # 識別バーの縦中心
const LOGO_X: float = INNER_L             # バッジ左端
const NAME_X: float = INNER_L + 48.0      # 球団名左端 (バッジの右)
const STAT_Y1: float = 150.0              # サマリー1段目
const STAT_Y2: float = 228.0              # サマリー2段目
const STAT_H: float = 72.0

# 上段 3 パネル (打線 / ローテ・勝ちパターン / 直近5年)
const LINEUP_RECT: Rect2 = Rect2(262, 314, 500, 374)
const ROTATION_RECT: Rect2 = Rect2(778, 314, 560, 374)
const HISTORY_RECT: Rect2 = Rect2(1354, 314, 546, 374)

# 下段 2 パネル: 対戦結果/予定を直近・今後6試合に短縮して幅を詰め、空いた分をランキングへ回す。
# 下段は上段より少し低くして全体の収まりを良くする。
const SCHEDULE_RECT: Rect2 = Rect2(262, 704, 620, 344)
const RANKING_RECT: Rect2 = Rect2(898, 704, 1002, 344)

const RECENT_LIMIT: int = 6

const CLOSER_RED: Color = Color(0.92, 0.24, 0.30)
# 野手/投手ランキングのアクセント色 (明るめ・投手はピンク寄り)。
const BAT_ACCENT: Color = Color(0.46, 0.73, 1.0)
const PIT_ACCENT: Color = Color(0.95, 0.62, 0.78)

var _team_id: int = 0
var _team_ids: Array = []                 # 選択候補 (リーグ→id)
var _team_menu_button: Button = null

# 集計キャッシュ
var _stats: PSStats = null
var _rank: int = 0
var _league_size: int = 0
var _gb: float = 0.0
var _team_metric: Dictionary = {}         # 自チームの指標 {rs,ra,avg,hr,sb,era,sv,outs}
var _metric_ranks: Dictionary = {}        # 各指標のリーグ内順位 {rs,ra,avg,hr,sb,era,sv}
var _war_by_id: Dictionary = {}           # player_id -> season_war 結果 dict (war/fip)
var _recent5: Array = []                  # {year, season_number, rank, w, l, d, pct}
var _lineup_rows: Array = []              # {slot, pos, name, avg, hr, pid}
var _rotation_rows: Array = []            # {num, name, era, pid}
var _win_pattern: Array = []              # {role, color, name}
var _recent_games: Array = []             # 直近の自軍試合 (新しい順)
var _upcoming_games: Array = []           # 今後の自軍試合 (古い順)
var _ranking_cards: Array = []            # {title, accent, fmt, entries:[{name, value}]}


func _ready() -> void:
	_init_chrome()
	_team_id = AppState.selected_team_id
	_build_team_order()
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

	var your_team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	if season == null:
		_text("PennantStrategy", Vector2(740, 430), 44, TEXT)
		_text("シーズンが開始されていません", Vector2(770, 496), 20, MUTED)
		return

	var team: PSTeam = GameDb.get_team(_team_id)
	if your_team == null:
		your_team = team
	_draw_shell("チーム詳細", your_team, season)
	if team == null:
		_text("チーム情報が取得できません", Vector2(INNER_L, 300), 20, MUTED)
		return

	_draw_identity(team)
	_draw_statbar()
	_draw_lineup(LINEUP_RECT)
	_draw_rotation(ROTATION_RECT)
	_draw_history(HISTORY_RECT)
	_draw_schedule(SCHEDULE_RECT)
	_draw_rankings(RANKING_RECT)


# --- チーム識別バー ---

# 左のロゴ (バッジ + 球団名 + ▼) 自体が球団選択プルダウン。クリックは _build_buttons が同領域へ置く
# 透明ボタンが拾う (描画は本関数、ヒットはボタン)。右へリーグ / 自軍 chip を続ける。
func _draw_identity(team: PSTeam) -> void:
	_team_badge(Rect2(LOGO_X, ID_Y - 18, 36, 36), team)
	_text(team.name, Vector2(NAME_X, ID_Y + 9), 26, TEXT)
	var nx: float = NAME_X + _measure(team.name, 26) + 12.0
	_text("▼", Vector2(nx, ID_Y + 6), 14, MUTED)               # プルダウン記号
	var cx: float = nx + 28.0
	_chip(Rect2(cx, ID_Y - 13, 92, 26), team.league_label(), BLUE)
	if team.id == AppState.selected_team_id:
		_chip(Rect2(cx + 102, ID_Y - 13, 72, 26), "自軍", GREEN)


# ロゴ+名前+▼ を覆う透明ボタンの矩形 (プルダウンのヒット領域)。
func _logo_hotspot_rect(team: PSTeam) -> Rect2:
	var name_w: float = _measure(team.name, 26) if team != null else 0.0
	var w: float = (NAME_X - LOGO_X) + name_w + 12.0 + 22.0
	return Rect2(LOGO_X - 6.0, ID_Y - 22.0, w, 44.0)


# --- サマリーバー (今期成績, 2段) ---

func _draw_statbar() -> void:
	var team: PSTeam = GameDb.get_team(_team_id)
	var wins: int = _stats.wins if _stats != null else 0
	var losses: int = _stats.losses if _stats != null else 0
	var draws: int = _stats.draws if _stats != null else 0
	var rs: int = int(_team_metric.get("rs", 0))
	var ra: int = int(_team_metric.get("ra", 0))
	var has_pitch: bool = int(_team_metric.get("outs", 0)) > 0

	var rank_text: String = "%d位" % _rank if _rank > 0 else "-"
	# 1段目: 順位・勝敗・勝率・ゲーム差・得点・失点
	var row1: Array = [
		{"icon": "rank", "label": "順位 (%s)" % (team.league_label() if team != null else ""), "value": rank_text, "vsize": 23, "color": BLUE},
		{"icon": "record", "label": "勝敗", "value": "%d勝 %d敗 %d分" % [wins, losses, draws], "vsize": 18, "color": TEXT},
		{"icon": "winrate", "label": "勝率", "value": _rate_short(_stats.win_rate() if _stats != null else 0.0), "vsize": 23, "color": GREEN},
		{"icon": "gb", "label": "ゲーム差", "value": ("-" if _gb <= 0.0 else _float1(_gb)), "vsize": 22, "color": TEXT},
		{"icon": "results", "label": "得点", "value": str(rs), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("rs", 0))},
		{"icon": "results", "label": "失点", "value": str(ra), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("ra", 0))},
	]
	# 2段目: 打率・本塁打・盗塁・失策・防御率・セーブ (いずれもリーグ内順位つき)
	var row2: Array = [
		{"icon": "winrate", "label": "打率", "value": _rate_short(float(_team_metric.get("avg", 0.0))), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("avg", 0))},
		{"icon": "standings", "label": "本塁打", "value": str(int(_team_metric.get("hr", 0))), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("hr", 0))},
		{"icon": "swap", "label": "盗塁", "value": str(int(_team_metric.get("sb", 0))), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("sb", 0))},
		{"icon": "role", "label": "失策", "value": str(int(_team_metric.get("err", 0))), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("err", 0))},
		{"icon": "pitch", "label": "防御率", "value": ("%0.2f" % float(_team_metric.get("era", 0.0))) if has_pitch else "-", "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("era", 0)) if has_pitch else 0},
		{"icon": "record", "label": "セーブ", "value": str(int(_team_metric.get("sv", 0))), "vsize": 22, "color": TEXT, "rank": int(_metric_ranks.get("sv", 0))},
	]
	_draw_stat_row(row1, STAT_Y1)
	_draw_stat_row(row2, STAT_Y2)


func _draw_stat_row(cards: Array, y: float) -> void:
	var count: int = cards.size()
	var gap: float = 10.0
	var total_w: float = INNER_R - INNER_L
	var card_w: float = (total_w - gap * float(count - 1)) / float(count)
	var x: float = INNER_L
	for card_value in cards:
		var card: Dictionary = card_value as Dictionary
		_round(Rect2(x, y, card_w, STAT_H), PANEL, BORDER, 9)
		_icon(str(card["icon"]), Rect2(x + 16, y + 24, 26, 26), MUTED)
		_text(str(card["label"]), Vector2(x + 52, y + 30), 12, MUTED, card_w - 60)
		_text(str(card["value"]), Vector2(x + 52, y + 57), int(card["vsize"]), card["color"] as Color, card_w - 60)
		var rank: int = int(card.get("rank", 0))
		if rank > 0:
			# 1位=金 / 最下位(=リーグ6位)=紫 / それ以外=青。
			var last: int = _league_size if _league_size > 0 else 6
			var rc: Color = AMBER if rank == 1 else (VIOLET if rank >= last else BLUE)
			_chip(Rect2(x + card_w - 78, y + 12, 64, 20), "リーグ%d位" % rank, rc)
		x += card_w + gap


# --- 打線 (スタメン打順) ---

func _draw_lineup(rect: Rect2) -> void:
	_panel(rect, "打線（スタメン）")

	# 右側の値列 (右端からの右寄せ基準): 打率 / 本 / OPS / WAR
	var c_avg: float = rect.end.x - 176.0
	var c_hr: float = rect.end.x - 130.0
	var c_ops: float = rect.end.x - 72.0
	var c_war: float = rect.end.x - 14.0
	var name_right: float = rect.end.x - 230.0

	var hy: float = rect.position.y + 58
	_text("打順", Vector2(rect.position.x + 18, hy), 11, FAINT)
	_text("守", Vector2(rect.position.x + 64, hy), 11, FAINT)
	_text("選手", Vector2(rect.position.x + 98, hy), 11, FAINT)
	_text_right("打率", c_avg, hy, 11, FAINT, 52)
	_text_right("本", c_hr, hy, 11, FAINT, 40)
	_text_right("OPS", c_ops, hy, 11, FAINT, 52)
	_text_right("WAR", c_war, hy, 11, FAINT, 46)
	_line(Vector2(rect.position.x + 16, rect.position.y + 66), Vector2(rect.end.x - 16, rect.position.y + 66), BORDER_SOFT, 1.0)

	if _lineup_rows.is_empty():
		_text("打順を編成できません", Vector2(rect.position.x + 20, rect.position.y + 110), 14, MUTED)
		return

	var top: float = rect.position.y + 74.0
	var row_h: float = (rect.end.y - top - 10.0) / 9.0
	for i in range(_lineup_rows.size()):
		var row: Dictionary = _lineup_rows[i] as Dictionary
		var ry: float = top + float(i) * row_h
		var ty: float = ry + row_h * 0.5 + 5.0
		if i % 2 == 1:
			_round(Rect2(rect.position.x + 12, ry, rect.size.x - 24, row_h), Color(1, 1, 1, 0.018), Color.TRANSPARENT, 4, 0)
		var pos: int = int(row.get("pos", 0))
		var is_pitcher: bool = pos == 1
		_text(str(i + 1), Vector2(rect.position.x + 24, ty), 14, BLUE)
		_chip(Rect2(rect.position.x + 56, ry + row_h * 0.5 - 11, 30, 22), str(row.get("pos_label", "")), _pos_color(pos))
		_text(str(row.get("name", "")), Vector2(rect.position.x + 98, ty), 14, TEXT, name_right - (rect.position.x + 98))
		if is_pitcher:
			_text_right("-", c_avg, ty, 13, FAINT, 52)
			_text_right("-", c_hr, ty, 13, FAINT, 40)
			_text_right("-", c_ops, ty, 13, FAINT, 52)
			_text_right("-", c_war, ty, 13, FAINT, 46)
		else:
			_text_right(_rate_short(float(row.get("avg", 0.0))), c_avg, ty, 13, TEXT, 52)
			_text_right(str(int(row.get("hr", 0))), c_hr, ty, 13, MUTED, 40)
			_text_right("%0.3f" % float(row.get("ops", 0.0)), c_ops, ty, 13, TEXT, 52)
			_text_right("%0.1f" % float(row.get("war", 0.0)), c_war, ty, 13, MUTED, 46)


# --- ローテーション・勝ちパターン ---

func _draw_rotation(rect: Rect2) -> void:
	_panel(rect, "ローテーション・勝ちパターン")

	# 勝ちパターンはパネル下部の固定帯に置き、先発ローテはその上の領域に収める
	# (枠からはみ出さないよう、勝ちパターンの高さから逆算する)。
	var wp_count: int = min(3, _win_pattern.size())
	var wp_row_h: float = 26.0
	var wp_band: float = 30.0 + float(max(1, wp_count)) * wp_row_h   # ラベル + 行
	var wp_label_y: float = rect.end.y - wp_band

	# 値列 (右端からの右寄せ基準): 勝敗 / 防御率 / WAR
	var c_wl: float = rect.end.x - 150.0
	var c_era: float = rect.end.x - 72.0
	var c_war: float = rect.end.x - 14.0

	var sub_y: float = rect.position.y + 56
	_text("先発ローテーション", Vector2(rect.position.x + 18, sub_y), 13, MUTED)
	_text_right("勝敗", c_wl, sub_y, 11, FAINT, 78)
	_text_right("防御率", c_era, sub_y, 11, FAINT, 60)
	_text_right("WAR", c_war, sub_y, 11, FAINT, 46)

	var rot_top: float = sub_y + 10.0
	var rot_area: float = wp_label_y - 10.0 - rot_top
	if _rotation_rows.is_empty():
		_text("ローテーションを編成できません", Vector2(rect.position.x + 20, rot_top + 24), 13, MUTED)
	else:
		var rot_h: float = min(30.0, rot_area / float(_rotation_rows.size()))
		for i in range(_rotation_rows.size()):
			var row: Dictionary = _rotation_rows[i] as Dictionary
			var ry: float = rot_top + float(i) * rot_h
			var ty: float = ry + rot_h * 0.5 + 5.0
			_round(Rect2(rect.position.x + 18, ry + rot_h * 0.5 - 11, 26, 22), Color(PINK.r, PINK.g, PINK.b, 0.18), Color(PINK.r, PINK.g, PINK.b, 0.55), 6)
			_text("%d" % int(row.get("num", i + 1)), Vector2(rect.position.x + 18, ty), 14, PINK, 26, HORIZONTAL_ALIGNMENT_CENTER)
			_text(str(row.get("name", "")), Vector2(rect.position.x + 54, ty), 14, TEXT, c_wl - 78 - (rect.position.x + 54))
			_text_right(str(row.get("wl", "")), c_wl, ty, 13, TEXT, 78)
			_text_right(str(row.get("era", "-.--")), c_era, ty, 13, TEXT, 60)
			_text_right(str(row.get("war", "-")), c_war, ty, 13, MUTED, 46)

	# 勝ちパターン (セットアッパー / クローザー) — 下部固定帯
	_line(Vector2(rect.position.x + 18, wp_label_y), Vector2(rect.end.x - 18, wp_label_y), BORDER_SOFT, 1.0)
	_text("勝ちパターン", Vector2(rect.position.x + 18, wp_label_y + 22), 13, MUTED)
	if _win_pattern.is_empty():
		_text("リリーフ未設定", Vector2(rect.position.x + 150, wp_label_y + 22), 13, MUTED)
		return
	var wy: float = wp_label_y + 30.0
	for i in range(wp_count):
		var entry: Dictionary = _win_pattern[i] as Dictionary
		var color: Color = entry.get("color", RED) as Color
		var cy: float = wy + wp_row_h * 0.5
		_round(Rect2(rect.position.x + 18, cy - 11, 116, 22), Color(color.r, color.g, color.b, 0.18), Color(color.r, color.g, color.b, 0.55), 7)
		_text(str(entry.get("role", "")), Vector2(rect.position.x + 18, cy + 5), 12, color, 116, HORIZONTAL_ALIGNMENT_CENTER)
		_text(str(entry.get("name", "")), Vector2(rect.position.x + 146, cy + 5), 13, TEXT, c_wl - 78 - (rect.position.x + 146))
		_text_right(str(entry.get("wl", "")), c_wl, cy + 5, 13, MUTED, 78)
		_text_right(str(entry.get("era", "-.--")), c_era, cy + 5, 13, MUTED, 60)
		_text_right(str(entry.get("war", "-")), c_war, cy + 5, 13, MUTED, 46)
		wy += wp_row_h


# --- 直近5年のチーム成績 ---

func _draw_history(rect: Rect2) -> void:
	_panel(rect, "直近5年のチーム成績")

	var inner_x: float = rect.position.x + 18.0
	var hy: float = rect.position.y + 58
	_text("年度", Vector2(inner_x, hy), 11, FAINT)
	_text_right("順位", rect.position.x + 250, hy, 11, FAINT, 56)
	_text_right("勝-敗-分", rect.end.x - 96, hy, 11, FAINT, 120)
	_text_right("勝率", rect.end.x - 18, hy, 11, FAINT, 64)
	_line(Vector2(inner_x, rect.position.y + 66), Vector2(rect.end.x - 16, rect.position.y + 66), BORDER_SOFT, 1.0)

	if _recent5.is_empty():
		_text("完了したシーズンの記録がありません", Vector2(inner_x, rect.position.y + 110), 13, MUTED)
		return

	var top: float = rect.position.y + 74.0
	var row_h: float = min(52.0, (rect.end.y - top - 10.0) / float(_recent5.size()))
	for i in range(_recent5.size()):
		var row: Dictionary = _recent5[i] as Dictionary
		var ry: float = top + float(i) * row_h
		var ty: float = ry + row_h * 0.5 + 5.0
		if i % 2 == 1:
			_round(Rect2(rect.position.x + 12, ry, rect.size.x - 24, row_h), Color(1, 1, 1, 0.018), Color.TRANSPARENT, 4, 0)
		var rank: int = int(row.get("rank", 0))
		var rank_color: Color = AMBER if rank == 1 else TEXT
		_text("%d年" % int(row.get("year", 0)), Vector2(inner_x, ty), 14, TEXT)
		# CS / 日本シリーズ進出時はその到達段階を chip で表示。
		var ps_text: String = str(row.get("ps", ""))
		if not ps_text.is_empty():
			var ps_w: float = _measure(ps_text, 11) + 18.0
			_chip(Rect2(inner_x + 62.0, ry + row_h * 0.5 - 10.0, ps_w, 20.0), ps_text, row.get("ps_color", MUTED) as Color)
		_text_right("%d位" % rank if rank > 0 else "-", rect.position.x + 250, ty, 14, rank_color, 56)
		_text_right("%d-%d-%d" % [int(row.get("w", 0)), int(row.get("l", 0)), int(row.get("d", 0))], rect.end.x - 96, ty, 13, MUTED, 120)
		_text_right(_rate_short(float(row.get("pct", 0.0))), rect.end.x - 18, ty, 13, TEXT, 64)


# --- 直近の対戦結果 / 今後の対戦予定 ---

func _draw_schedule(rect: Rect2) -> void:
	_panel(rect, "直近の対戦結果 / 今後の対戦予定")

	var gap: float = 16.0
	var col_w: float = (rect.size.x - 36.0 - gap) / 2.0
	var left_x: float = rect.position.x + 18.0
	var right_x: float = left_x + col_w + gap
	var head_y: float = rect.position.y + 60.0
	_text("直近の結果", Vector2(left_x, head_y), 13, MUTED)
	_text("今後の予定", Vector2(right_x, head_y), 13, MUTED)
	_line(Vector2(left_x, head_y + 8), Vector2(left_x + col_w, head_y + 8), BORDER_SOFT, 1.0)
	_line(Vector2(right_x, head_y + 8), Vector2(right_x + col_w, head_y + 8), BORDER_SOFT, 1.0)

	var top: float = head_y + 22.0
	var max_rows: int = RECENT_LIMIT
	var row_h: float = (rect.end.y - top - 10.0) / float(max_rows)

	# 左: 直近の結果
	if _recent_games.is_empty():
		_text("消化済みの試合はありません", Vector2(left_x, top + 30), 13, MUTED)
	else:
		for i in range(min(_recent_games.size(), max_rows)):
			_draw_result_row(Rect2(left_x, top + float(i) * row_h, col_w, row_h - 6.0), _recent_games[i] as Dictionary)

	# 右: 今後の予定
	if _upcoming_games.is_empty():
		_text("予定された試合はありません", Vector2(right_x, top + 30), 13, MUTED)
	else:
		for i in range(min(_upcoming_games.size(), max_rows)):
			_draw_upcoming_row(Rect2(right_x, top + float(i) * row_h, col_w, row_h - 6.0), _upcoming_games[i] as Dictionary)


func _draw_result_row(cell: Rect2, game: Dictionary) -> void:
	var color: Color = _game_color(game)
	_round(cell, PANEL_2, BORDER_SOFT, 7)
	var opp: PSTeam = GameDb.get_team(int(game.get("opponent_id", 0)))
	var ty: float = cell.position.y + cell.size.y * 0.5 + 5.0
	_text(str(game.get("date_label", "")), Vector2(cell.position.x + 12, ty), 12, MUTED, 90)
	_text("%s %s" % [str(game.get("venue", "vs")), opp.short_name if opp != null else "-"], Vector2(cell.position.x + 104, ty), 14, TEXT, cell.size.x - 220)
	var symbol: String = str(game.get("symbol", ""))
	_text_right(str(game.get("score", "")), cell.end.x - 40, ty, 14, color, 70)
	_draw_result_mark(Vector2(cell.end.x - 20, cell.position.y + cell.size.y * 0.5), 7.0, symbol, color)


func _draw_upcoming_row(cell: Rect2, game: Dictionary) -> void:
	_round(cell, PANEL_2, BORDER_SOFT, 7)
	var opp: PSTeam = GameDb.get_team(int(game.get("opponent_id", 0)))
	var ty: float = cell.position.y + cell.size.y * 0.5 + 5.0
	_text(str(game.get("date_label", "")), Vector2(cell.position.x + 12, ty), 12, MUTED, 90)
	_text("%s %s" % [str(game.get("venue", "vs")), opp.short_name if opp != null else "-"], Vector2(cell.position.x + 104, ty), 14, TEXT, cell.size.x - 116)
	if bool(game.get("dh", false)):
		_chip(Rect2(cell.end.x - 44, cell.position.y + cell.size.y * 0.5 - 10, 30, 18), "DH", BLUE_SOFT)


# --- チーム内成績ランキング ---

func _draw_rankings(rect: Rect2) -> void:
	_panel(rect, "チーム内成績ランキング")

	# 上段=野手5部門 (青) / 下段=投手5部門 (赤)。
	var cols: int = 5
	var rows_n: int = 2
	var gap: float = 10.0
	var inner_x: float = rect.position.x + 18.0
	var inner_y: float = rect.position.y + 52.0
	var usable_w: float = rect.size.x - 36.0
	var usable_h: float = rect.end.y - inner_y - 14.0
	var cw: float = (usable_w - gap * float(cols - 1)) / float(cols)
	var ch: float = (usable_h - gap * float(rows_n - 1)) / float(rows_n)

	for i in range(_ranking_cards.size()):
		if i >= cols * rows_n:
			break
		var col: int = i % cols
		var row: int = 0 if i < cols else 1
		var cr: Rect2 = Rect2(inner_x + float(col) * (cw + gap), inner_y + float(row) * (ch + gap), cw, ch)
		_draw_ranking_card(cr, _ranking_cards[i] as Dictionary)


func _draw_ranking_card(rect: Rect2, card: Dictionary) -> void:
	_round(rect, PANEL_2, BORDER_SOFT, 8)
	var accent: Color = card.get("accent", BLUE) as Color
	_round(Rect2(rect.position.x, rect.position.y, 3, rect.size.y), accent, Color.TRANSPARENT, 0, 0)
	_text(str(card.get("title", "")), Vector2(rect.position.x + 14, rect.position.y + 28), 14, accent, rect.size.x - 24)

	var entries: Array = card.get("entries", []) as Array
	if entries.is_empty():
		_text("該当者なし", Vector2(rect.position.x + 14, rect.position.y + 60), 12, MUTED)
		return
	var top: float = rect.position.y + 44.0
	var row_h: float = min(34.0, (rect.end.y - top - 8.0) / float(max(1, entries.size())))
	# 値は右寄せの固定ボックス、名前は残り幅いっぱい (途切れ対策で value 幅を詰める)。
	var value_box: float = 52.0
	var name_x: float = rect.position.x + 28.0
	var name_w: float = rect.end.x - 10.0 - value_box - 6.0 - name_x
	for i in range(entries.size()):
		var entry: Dictionary = entries[i] as Dictionary
		var ty: float = top + float(i) * row_h + row_h * 0.5 + 5.0
		var medal: Color = AMBER if i == 0 else (MUTED if i == 1 else FAINT)
		_text("%d" % (i + 1), Vector2(rect.position.x + 12, ty), 12, medal)
		_text(str(entry.get("name", "")), Vector2(name_x, ty), 13, TEXT, name_w)
		_text_right(str(entry.get("value", "")), rect.end.x - 10, ty, 13, accent, value_box)


# ============================================================ buttons

func _build_buttons() -> void:
	_clear_buttons()
	var season: PSSeason = AppState.current_season
	if season == null:
		_add_button("home_empty", "ホームへ", Rect2(880, 560, 160, 46), func() -> void: AppState.request_screen("home"), "primary")
		_layout_buttons()
		return

	_build_nav_buttons()

	# 左のロゴ+球団名 自体を球団選択プルダウンにする。透明ボタンを同領域へ重ね、
	# クリックで全12球団の PopupMenu を出す (描画は _draw_identity 側)。
	var team: PSTeam = GameDb.get_team(_team_id)
	_team_menu_button = _add_button("team_menu", "", _logo_hotspot_rect(team), _on_team_menu_pressed, "nav")

	_layout_buttons()


# プルダウンを開き、選んだ球団へ即切り替える。スタイルは home/game_result の _style_popup と同等。
func _on_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	for i in range(_team_ids.size()):
		var team: PSTeam = GameDb.get_team(int(_team_ids[i]))
		if team == null:
			continue
		# リーグの境目に区切りを入れて第1/第2を見分けやすくする。
		if i > 0:
			var prev: PSTeam = GameDb.get_team(int(_team_ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(team.league_label())
		elif team != null:
			menu.add_separator(team.league_label())
		menu.add_item("%s (%s)" % [team.name, team.short_name], int(_team_ids[i]))
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_team_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(LOGO_X, ID_Y + 22.0))
	if _team_menu_button != null:
		anchor = _team_menu_button.global_position + Vector2(0.0, _team_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_team_selected(team_id: int) -> void:
	if team_id == _team_id or not _team_ids.has(team_id):
		return
	_team_id = team_id
	_refresh()
	_build_buttons()
	queue_redraw()


# ダッシュボードのダーク配色に合わせて PopupMenu をテーマ上書きする (home から移植)。
func _style_popup(menu: PopupMenu) -> void:
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = PANEL_2
	panel.border_color = BORDER
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(8)
	panel.content_margin_left = 6
	panel.content_margin_right = 6
	panel.content_margin_top = 6
	panel.content_margin_bottom = 6
	menu.add_theme_stylebox_override("panel", panel)
	var hover: StyleBoxFlat = StyleBoxFlat.new()
	hover.bg_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.18)
	hover.border_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.55)
	hover.set_border_width_all(1)
	hover.set_corner_radius_all(6)
	menu.add_theme_stylebox_override("hover", hover)
	menu.add_theme_color_override("font_color", TEXT)
	menu.add_theme_color_override("font_hover_color", TEXT)
	menu.add_theme_color_override("font_separator_color", MUTED)
	menu.add_theme_constant_override("v_separation", 6)
	if _font != null:
		menu.add_theme_font_override("font", _font)
	menu.add_theme_font_size_override("font_size", max(11, int(round(14.0 * _scale_f))))


# ============================================================ aggregation

func _build_team_order() -> void:
	_team_ids = []
	# 第1リーグ→第2リーグ、リーグ内は id 昇順で巡回。
	for league_key in ["central", "pacific"]:
		var ids: Array = []
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team.league == league_key:
				ids.append(team.id)
		ids.sort()
		for id_value in ids:
			_team_ids.append(int(id_value))
	if not _team_ids.has(_team_id) and not _team_ids.is_empty():
		_team_id = int(_team_ids[0])


func _refresh() -> void:
	_stats = null
	_rank = 0
	_league_size = 0
	_gb = 0.0
	_team_metric = {}
	_metric_ranks = {}
	_war_by_id = {}
	_recent5 = []
	_lineup_rows = []
	_rotation_rows = []
	_win_pattern = []
	_recent_games = []
	_upcoming_games = []
	_ranking_cards = []

	var season: PSSeason = AppState.current_season
	var team: PSTeam = GameDb.get_team(_team_id)
	if season == null or team == null:
		return

	_build_standing(team, season)
	_build_metric_ranks(team, season)
	_build_recent5(team)

	var records: Array = RecordStore.get_team_player_records(team.id, season.year, season.season_number)
	var record_by_id: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		record_by_id[record.player_id] = record

	# WAR / FIP はリーグ文脈が要るので season ごとに 1 回計算してキャッシュ (rotation/lineup editor と同型)。
	var ctx: Dictionary = WarCalculator.build_league_context(season.year, season.season_number)
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		_war_by_id[record.player_id] = WarCalculator.season_war(record, ctx)

	_build_lineup(team, season, record_by_id)
	_build_rotation(team, season, record_by_id)
	_build_win_pattern(team, season, record_by_id)
	_build_schedule(team, season)
	_build_rankings(records)


func _build_standing(team: PSTeam, season: PSSeason) -> void:
	_stats = season.standings.get(team.id) as PSStats
	var entries: Array = []
	for team_id in season.standings.keys():
		var t: PSTeam = GameDb.get_team(int(team_id))
		if t == null or t.league != team.league:
			continue
		entries.append({"id": t.id, "stats": season.standings[team_id] as PSStats})
	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		var sa: PSStats = (a as Dictionary)["stats"] as PSStats
		var sb: PSStats = (b as Dictionary)["stats"] as PSStats
		return sa.wins > sb.wins if is_equal_approx(sa.win_rate(), sb.win_rate()) else sa.win_rate() > sb.win_rate()
	)
	_league_size = entries.size()
	var leader: PSStats = (entries[0] as Dictionary)["stats"] as PSStats if not entries.is_empty() else null
	var rank: int = 1
	for entry_value in entries:
		var entry: Dictionary = entry_value as Dictionary
		if int(entry["id"]) == team.id:
			_rank = rank
			var stats: PSStats = entry["stats"] as PSStats
			_gb = 0.0 if (leader == null or rank == 1) else float((leader.wins - stats.wins) + (stats.losses - leader.losses)) / 2.0
			break
		rank += 1


# 自チームの今期指標 (得点/失点/打率/本/盗/防/S) と、各指標のリーグ内順位を求める。
# 失点・防御率は小さいほど上位 (昇順)、それ以外は大きいほど上位。
func _build_metric_ranks(team: PSTeam, season: PSSeason) -> void:
	var by_team: Dictionary = {}   # team_id -> 指標 dict
	for team_id in season.standings.keys():
		var t: PSTeam = GameDb.get_team(int(team_id))
		if t == null or t.league != team.league:
			continue
		by_team[t.id] = _aggregate_team(t.id, season)
	_team_metric = by_team.get(team.id, {}) as Dictionary
	if _team_metric.is_empty():
		return

	# era は投球回 0 のチームを除外して順位付けする (序盤の 0.00 を最上位にしない)。
	# 失点・防御率・失策は小さいほど上位 (昇順)。
	for metric in ["rs", "ra", "avg", "hr", "sb", "err", "era", "sv"]:
		var ascending: bool = metric == "ra" or metric == "era" or metric == "err"
		var my_value: float = float(_team_metric.get(metric, 0.0))
		var better: int = 0
		for tid in by_team.keys():
			if int(tid) == team.id:
				continue
			var m: Dictionary = by_team[tid] as Dictionary
			if metric == "era" and int(m.get("outs", 0)) <= 0:
				continue
			var v: float = float(m.get(metric, 0.0))
			if (v < my_value) if ascending else (v > my_value):
				better += 1
		_metric_ranks[metric] = better + 1


func _aggregate_team(team_id: int, season: PSSeason) -> Dictionary:
	var batter: PSBatterStats = PSBatterStats.new()
	var pitcher: PSPitcherStats = PSPitcherStats.new()
	for record_row in RecordStore.get_team_player_records(team_id, season.year, season.season_number):
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		batter.add_from(record.batter_stats)
		if record.is_pitcher():
			pitcher.add_from(record.pitcher_stats)
	var stats: PSStats = season.standings.get(team_id) as PSStats
	return {
		"rs": stats.runs_scored if stats != null else 0,
		"ra": stats.runs_allowed if stats != null else 0,
		"avg": batter.batting_average(),
		"hr": batter.home_runs,
		"sb": batter.stolen_bases,
		"err": batter.errors,
		"era": pitcher.era() if pitcher.outs_pitched > 0 else 0.0,
		"sv": pitcher.saves,
		"outs": pitcher.outs_pitched,
	}


func _build_recent5(team: PSTeam) -> void:
	var archives: Array = RecordStore.get_season_archives()
	# 新しい順に最大5件。
	var start: int = max(0, archives.size() - 5)
	for i in range(archives.size() - 1, start - 1, -1):
		var archive: PSSeasonArchive = archives[i] as PSSeasonArchive
		_recent5.append(_archive_row(archive, team))


func _archive_row(archive: PSSeasonArchive, team: PSTeam) -> Dictionary:
	var entry: Dictionary = archive.standings.get(str(team.id), {}) as Dictionary
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	var d: int = int(entry.get("draws", 0))
	var decisions: int = w + l
	var pct: float = float(w) / float(decisions) if decisions > 0 else 0.0
	var ps: Dictionary = _archive_postseason_label(archive, team)
	return {
		"year": archive.year, "season_number": archive.season_number,
		"rank": _archive_rank(archive, team), "w": w, "l": l, "d": d, "pct": pct,
		"ps": str(ps.get("text", "")), "ps_color": ps.get("color", MUTED),
	}


# 当該シーズンのポストシーズン(CS/日本シリーズ)で、チームが到達した段階のラベル+色。
# 日本一 > 日本シリーズ進出(=リーグ優勝) > CSファイナル > CSファースト。進出なしは空。
func _archive_postseason_label(archive: PSSeasonArchive, team: PSTeam) -> Dictionary:
	if archive.postseason == null:
		return {}
	var post: PSPostseasonResult = archive.postseason
	if post.champion_team_id == team.id:
		return {"text": "日本一", "color": AMBER}
	if _stage_has_team(post.stage_dict("japan_series"), team.id):
		return {"text": "日本S", "color": GREEN}
	if _stage_has_team(post.stage_dict("cs2_%s" % team.league), team.id):
		return {"text": "CSファイナル", "color": BLUE}
	if _stage_has_team(post.stage_dict("cs1_%s" % team.league), team.id):
		return {"text": "CSファースト", "color": VIOLET}
	return {}


func _stage_has_team(stage: Dictionary, team_id: int) -> bool:
	if stage.is_empty():
		return false
	return int(stage.get("top_id", 0)) == team_id or int(stage.get("challenger_id", 0)) == team_id


func _archive_rank(archive: PSSeasonArchive, team: PSTeam) -> int:
	var entries: Array = []
	for team_id_str in archive.standings.keys():
		var t: PSTeam = GameDb.get_team(int(team_id_str))
		if t == null or t.league != team.league:
			continue
		entries.append({"id": t.id, "entry": archive.standings[team_id_str] as Dictionary})
	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		return _archive_pct((a as Dictionary)["entry"] as Dictionary) > _archive_pct((b as Dictionary)["entry"] as Dictionary)
	)
	var rank: int = 1
	for entry_value in entries:
		if int((entry_value as Dictionary)["id"]) == team.id:
			return rank
		rank += 1
	return 0


func _archive_pct(entry: Dictionary) -> float:
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	return float(w) / float(max(1, w + l))


func _build_lineup(team: PSTeam, season: PSSeason, record_by_id: Dictionary) -> void:
	var dh: bool = AppState.is_dh_enabled_for_league(team.league)
	var lineup: Dictionary = season.get_lineup(team.id, dh)
	var saved: bool = not lineup.is_empty() and not (lineup.get("batting_order", []) as Array).is_empty()
	if not saved:
		var preview: Dictionary = GameSimulator.preview_lineup(season, team.id, dh)
		if not bool(preview.get("ok", false)):
			return
		lineup = preview

	var order: Array = lineup.get("batting_order", []) as Array
	order.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int((a as Dictionary).get("slot", 0)) < int((b as Dictionary).get("slot", 0))
	)
	for entry_value in order:
		var entry: Dictionary = entry_value as Dictionary
		var pid: int = int(entry.get("player_id", 0))
		var pos: int = int(entry.get("position", 0))
		var record: PSPlayerSeasonRecord = record_by_id.get(pid, null) as PSPlayerSeasonRecord
		_lineup_rows.append({
			"slot": int(entry.get("slot", 0)),
			"pos": pos,
			"pos_label": str(POS_SHORT.get(pos, "-")),
			"name": record.name if record != null else "(空き)",
			"avg": record.batter_stats.batting_average() if record != null else 0.0,
			"hr": record.batter_stats.home_runs if record != null else 0,
			"ops": record.batter_stats.ops() if record != null else 0.0,
			"war": _war_of(record) if record != null else 0.0,
			"pid": pid,
		})


func _build_rotation(team: PSTeam, season: PSSeason, record_by_id: Dictionary) -> void:
	var rotation: Dictionary = season.get_rotation(team.id)
	var ids: Array = rotation.get("pitcher_ids", []) as Array
	if ids.is_empty():
		var preview: Dictionary = GameSimulator.preview_rotation(season, team.id)
		if bool(preview.get("ok", false)):
			ids = preview.get("pitcher_ids", []) as Array
	var num: int = 1
	for id_value in ids:
		if num > 6:
			break
		var record: PSPlayerSeasonRecord = record_by_id.get(int(id_value), null) as PSPlayerSeasonRecord
		if record == null:
			continue
		_rotation_rows.append({
			"num": num,
			"name": record.name,
			"wl": "%d勝%d敗" % [record.pitcher_stats.wins, record.pitcher_stats.losses],
			"era": _era_str(record),
			"war": _war_str(record),
			"pid": record.player_id,
		})
		num += 1


func _build_win_pattern(team: PSTeam, season: PSSeason, record_by_id: Dictionary) -> void:
	var rotation: Dictionary = season.get_rotation(team.id)
	var roles: Dictionary = rotation.get("relief_roles", {}) as Dictionary
	var closer_id: int = int(roles.get("closer_id", 0))
	var setup_ids: Array = (roles.get("setup_ids", []) as Array).duplicate()

	# 保存が無ければ、ローテに入っていないリリーフを評価順で簡易割当 (抑え=最良 / セット=次2人)。
	if closer_id <= 0 and setup_ids.is_empty():
		var rotation_set: Dictionary = {}
		for id_value in (rotation.get("pitcher_ids", []) as Array):
			rotation_set[int(id_value)] = true
		var relievers: Array = []
		for record_row in RecordStore.get_team_player_records(team.id, season.year, season.season_number):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record.is_pitcher() and not rotation_set.has(record.player_id) and not record.is_starter_pitcher():
				relievers.append(record)
		relievers.sort_custom(func(a: Variant, b: Variant) -> bool:
			return PlayerValueEvaluator.overall_score(a as PSPlayerSeasonRecord) > PlayerValueEvaluator.overall_score(b as PSPlayerSeasonRecord)
		)
		if relievers.size() >= 1:
			closer_id = (relievers[0] as PSPlayerSeasonRecord).player_id
		if relievers.size() >= 2:
			setup_ids.append((relievers[1] as PSPlayerSeasonRecord).player_id)
		if relievers.size() >= 3:
			setup_ids.append((relievers[2] as PSPlayerSeasonRecord).player_id)

	# 表示は セットアッパー(最大2) → クローザー の順。
	for pid in setup_ids.slice(0, 2):
		var record: PSPlayerSeasonRecord = record_by_id.get(int(pid), null) as PSPlayerSeasonRecord
		if record != null:
			_win_pattern.append(_relief_entry("セットアッパー", VIOLET, record))
	if closer_id > 0:
		var closer: PSPlayerSeasonRecord = record_by_id.get(closer_id, null) as PSPlayerSeasonRecord
		if closer != null:
			_win_pattern.append(_relief_entry("クローザー", CLOSER_RED, closer))


func _relief_entry(role: String, color: Color, record: PSPlayerSeasonRecord) -> Dictionary:
	return {
		"role": role, "color": color, "name": record.name,
		"wl": "%d勝%d敗" % [record.pitcher_stats.wins, record.pitcher_stats.losses],
		"era": _era_str(record),
		"war": _war_str(record),
	}


func _build_schedule(team: PSTeam, season: PSSeason) -> void:
	for game_value in season.schedule:
		var game: Dictionary = game_value as Dictionary
		if not _is_team_game(game, team.id):
			continue
		if bool(game.get("played", false)):
			_recent_games.append(_result_entry(game, team.id, season))
		else:
			if _upcoming_games.size() < RECENT_LIMIT:
				_upcoming_games.append(_upcoming_entry(game, team.id, season))
	# 直近の結果は新しい順 (schedule は day 昇順前提なので末尾が新しい)。直近 RECENT_LIMIT 試合のみ。
	_recent_games.reverse()
	_recent_games = _recent_games.slice(0, RECENT_LIMIT)


func _result_entry(game: Dictionary, team_id: int, season: PSSeason) -> Dictionary:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var user_home: bool = home_id == team_id
	var opp_id: int = away_id if user_home else home_id
	var us: int = int(game.get("home_score", 0)) if user_home else int(game.get("away_score", 0))
	var them: int = int(game.get("away_score", 0)) if user_home else int(game.get("home_score", 0))
	return {
		"opponent_id": opp_id,
		"venue": "vs" if user_home else "@",
		"score": "%d - %d" % [us, them],
		"symbol": _result_symbol(game, team_id),
		"date_label": SeasonCalendar.compact_label_for_game(game, season),
	}


func _upcoming_entry(game: Dictionary, team_id: int, season: PSSeason) -> Dictionary:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	var user_home: bool = home_id == team_id
	return {
		"opponent_id": away_id if user_home else home_id,
		"venue": "vs" if user_home else "@",
		"dh": bool(game.get("dh_enabled", false)),
		"date_label": SeasonCalendar.compact_label_for_game(game, season),
	}


func _build_rankings(records: Array) -> void:
	var team_games: int = _stats.games if _stats != null else 0
	var min_ab: int = max(10, int(team_games * 1.5))
	var min_outs: int = max(15, team_games * 2)

	var batters: Array = []
	var pitchers: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			pitchers.append(record)
		else:
			batters.append(record)

	# 上段=野手 (GREEN) / 下段=投手 (BLUE)。各 Top3。
	_ranking_cards = [
		_rank_card("打率", BAT_ACCENT, batters, "rate",
			func(r: PSPlayerSeasonRecord) -> bool: return r.batter_stats.at_bats >= min_ab,
			func(r: PSPlayerSeasonRecord) -> float: return r.batter_stats.batting_average()),
		_rank_card("本塁打", BAT_ACCENT, batters, "int",
			func(r: PSPlayerSeasonRecord) -> bool: return r.batter_stats.home_runs > 0,
			func(r: PSPlayerSeasonRecord) -> float: return float(r.batter_stats.home_runs)),
		_rank_card("打点", BAT_ACCENT, batters, "int",
			func(r: PSPlayerSeasonRecord) -> bool: return r.batter_stats.runs_batted_in > 0,
			func(r: PSPlayerSeasonRecord) -> float: return float(r.batter_stats.runs_batted_in)),
		_rank_card("OPS", BAT_ACCENT, batters, "ops",
			func(r: PSPlayerSeasonRecord) -> bool: return r.batter_stats.at_bats >= min_ab,
			func(r: PSPlayerSeasonRecord) -> float: return r.batter_stats.ops()),
		_rank_card("WAR (野手)", BAT_ACCENT, batters, "war",
			func(r: PSPlayerSeasonRecord) -> bool: return r.batter_stats.plate_appearances > 0,
			func(r: PSPlayerSeasonRecord) -> float: return _war_of(r)),
		_rank_card("勝利", PIT_ACCENT, pitchers, "int",
			func(r: PSPlayerSeasonRecord) -> bool: return r.pitcher_stats.wins > 0,
			func(r: PSPlayerSeasonRecord) -> float: return float(r.pitcher_stats.wins)),
		# 防御率は先発のみ (規定投球回ベースの簡易閾値)。
		_rank_card("防御率 (先発)", PIT_ACCENT, pitchers, "era",
			func(r: PSPlayerSeasonRecord) -> bool: return r.is_starter_pitcher() and r.pitcher_stats.outs_pitched >= min_outs,
			func(r: PSPlayerSeasonRecord) -> float: return r.pitcher_stats.era()),
		_rank_card("登板数", PIT_ACCENT, pitchers, "int",
			func(r: PSPlayerSeasonRecord) -> bool: return r.pitcher_stats.games > 0,
			func(r: PSPlayerSeasonRecord) -> float: return float(r.pitcher_stats.games)),
		_rank_card("FIP", PIT_ACCENT, pitchers, "fip",
			func(r: PSPlayerSeasonRecord) -> bool: return r.pitcher_stats.outs_pitched >= min_outs,
			func(r: PSPlayerSeasonRecord) -> float: return _fip_of(r)),
		_rank_card("WAR (投手)", PIT_ACCENT, pitchers, "war",
			func(r: PSPlayerSeasonRecord) -> bool: return r.pitcher_stats.outs_pitched > 0,
			func(r: PSPlayerSeasonRecord) -> float: return _war_of(r)),
	]


# 汎用ランキングカード生成。era / fip は小さいほど上位 (昇順)。
func _rank_card(title: String, accent: Color, pool: Array, fmt: String, qualify: Callable, value_of: Callable) -> Dictionary:
	var qualified: Array = []
	for record_row in pool:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if qualify.call(record):
			qualified.append(record)
	var ascending: bool = fmt == "era" or fmt == "fip"
	qualified.sort_custom(func(a: Variant, b: Variant) -> bool:
		var va: float = value_of.call(a as PSPlayerSeasonRecord)
		var vb: float = value_of.call(b as PSPlayerSeasonRecord)
		return va < vb if ascending else va > vb
	)
	var entries: Array = []
	for i in range(min(3, qualified.size())):
		var record: PSPlayerSeasonRecord = qualified[i] as PSPlayerSeasonRecord
		entries.append({"name": record.name, "value": _fmt_rank_value(fmt, value_of.call(record))})
	return {"title": title, "accent": accent, "entries": entries}


func _war_of(record: PSPlayerSeasonRecord) -> float:
	return float((_war_by_id.get(record.player_id, {}) as Dictionary).get("war", 0.0))


# 表示用 WAR 文字列。投手で未登板なら "-"。
func _war_str(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher() and record.pitcher_stats.outs_pitched <= 0:
		return "-"
	return "%0.1f" % _war_of(record)


func _fip_of(record: PSPlayerSeasonRecord) -> float:
	return float((_war_by_id.get(record.player_id, {}) as Dictionary).get("fip", 0.0))


func _fmt_rank_value(fmt: String, value: float) -> String:
	match fmt:
		"rate":
			return _rate_short(value)
		"ops":
			return "%0.3f" % value
		"era", "fip":
			return "%0.2f" % value
		"war":
			return "%0.1f" % value
		_:
			return str(int(value))


# ============================================================ helpers

func _era_str(record: PSPlayerSeasonRecord) -> String:
	var ps: PSPitcherStats = record.pitcher_stats
	return "-.--" if ps.outs_pitched <= 0 else "%0.2f" % ps.era()


func _is_team_game(game: Dictionary, team_id: int) -> bool:
	return int(game.get("away_team_id", 0)) == team_id or int(game.get("home_team_id", 0)) == team_id


func _result_symbol(game: Dictionary, team_id: int) -> String:
	if not bool(game.get("played", false)):
		return ""
	var result: Dictionary = game.get("result", {}) as Dictionary
	if bool(result.get("draw", false)):
		return "△"
	return "○" if int(result.get("winning_team_id", 0)) == team_id else "●"


func _game_color(game: Dictionary) -> Color:
	var symbol: String = str(game.get("symbol", ""))
	if symbol == "○":
		return GREEN
	if symbol == "●":
		return RED
	if symbol == "△":
		return AMBER
	return MUTED
