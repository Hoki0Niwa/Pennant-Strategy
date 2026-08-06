extends "res://ui/components/dashboard_screen.gd"

# シーズン履歴画面。4ビューを右上チップで切り替える (R7 記録・履歴基盤 + スタメン履歴統合)。
# - 年度別: season_archives から過去年度を選び、最終順位・ポストシーズン・表彰を復元表示。
# - 通算記録: 全選手の通算リーダーとシーズン最高記録 (RecordStore の全年度レコードを集計)。
#   カウント系部門に加え、規定 (打席/投球回) を満たす選手のみを対象にした率系部門 (打率/OPS/
#   防御率/WHIP) も扱う。シーズン記録側の規定は rankings_screen.gd の per-team-game 式を流用し、
#   通算側は CAREER_MIN_PA/CAREER_MIN_OUTS の固定下限を使う。各表は文脈列 (打者=試合/打率/本/打点、
#   投手=登板/勝/防御率/奪三振) を選択部門と併記し、選択部門の「記録」列を強調 (strong) する。
# - タイトル履歴: 部門を選んで年度×両リーグの歴代受賞者を一覧。PSAwards は受賞者の player_id しか
#   持たないため、受賞年の PSPlayerSeasonRecord から該当部門の成績値を都度復元して表示する
#   (PSAwards のスキーマ自体は変更しない)。MVP/新人王は単一部門を持たないので代表的な成績ライン
#   (打者=打率/本/打点、投手=勝/防御率) を出す。レコードが引けない (引退等で消失) 場合は名前のみ
#   表示し、球団・記録は "-" にフォールバックする。
# - スタメン履歴: 選択した年度・球団の「守備位置別スタメン数(+成績)」と「試合別打線」。
#   データ取得は PSLineupHistory (services/reports/lineup_history_service.gd、読み取り専用の
#   集計 API) に一任し、この画面は表示用の整形・キャッシュ・入力(独自の年度/球団プルダウン・
#   下段表のホイールスクロール・選手セルのホバー連動ハイライト)のみを担う。年度別ビューの
#   ◀/▶ (_archives ベース、当季を含まない) とは独立に、スタメン履歴専用の年度プルダウン
#   (PSLineupHistory.available_seasons() 由来、当季を含む) を持つ。
# 重い集計は _refresh / _refresh_lineup / _build_career で1度だけ行いキャッシュし、
# _draw は描画専念。

const WarCalculator = preload("res://services/reports/war_calculator.gd")

const BATTING_TITLE_LABELS: Dictionary = {
	"average": "首位打者", "home_runs": "本塁打王", "rbi": "打点王",
	"stolen_bases": "盗塁王", "hits": "最多安打",
}
const PITCHING_TITLE_LABELS: Dictionary = {
	"wins": "最多勝利", "era": "最優秀防御率", "strikeouts": "最多奪三振",
	"saves": "最多セーブ", "holds": "最多ホールド", "win_rate": "最高勝率",
}

const LEAGUES: Array = [
	{"key": "league1", "label": "第1リーグ 最終順位"},
	{"key": "league2", "label": "第2リーグ 最終順位"},
]

# --- レイアウト基準 (base 座標) ---
const NAV_PREV: Rect2 = Rect2(262, 98, 38, 30)
const NAV_NEXT: Rect2 = Rect2(560, 98, 38, 30)
const YEAR_LABEL_X: float = 306.0
const YEAR_LABEL_W: float = 248.0

const TABLE_A: Rect2 = Rect2(262, 144, 808, 280)
const TABLE_B: Rect2 = Rect2(1092, 144, 808, 280)
const POST_RECT: Rect2 = Rect2(262, 440, 808, 618)
const AWARD_RECT: Rect2 = Rect2(1092, 440, 808, 196)
const BAT_RECT: Rect2 = Rect2(1092, 652, 396, 406)
const PIT_RECT: Rect2 = Rect2(1504, 652, 396, 406)

# ポストシーズンのステージ並び: 同ステージを横並び (左=第1リーグ league1 / 右=第2リーグ league2)。
# 日本シリーズは両リーグ代表の対戦なので全幅の統合カードで描く。
const POST_GROUPS: Array = [
	{"lines": ["CS", "ファースト"], "league1": "cs1_league1", "league2": "cs1_league2", "split": true},
	{"lines": ["CS", "ファイナル"], "league1": "cs2_league1", "league2": "cs2_league2", "split": true},
	{"lines": ["日本シリーズ"], "japan": "japan_series", "split": false},
]

const HIST_COLUMNS: Array = [
	{"title": "順",   "key": "rank", "w": 40,  "align": "l", "fmt": "rank"},
	{"title": "球団", "key": "team", "w": 180, "align": "l", "fmt": "team", "strong": true},
	{"title": "試",   "key": "g",    "w": 58,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "勝",   "key": "w",    "w": 56,  "align": "r", "fmt": "int"},
	{"title": "敗",   "key": "l",    "w": 56,  "align": "r", "fmt": "int"},
	{"title": "分",   "key": "d",    "w": 50,  "align": "r", "fmt": "int"},
	{"title": "勝率", "key": "pct",  "w": 78,  "align": "r", "fmt": "rate", "sep_before": true},
	{"title": "差",   "key": "gb",   "w": 66,  "align": "r", "fmt": "gb"},
	{"title": "得",   "key": "rs",   "w": 62,  "align": "r", "fmt": "int", "sep_before": true},
	{"title": "失",   "key": "ra",   "w": 62,  "align": "r", "fmt": "int"},
	{"title": "得失", "key": "diff", "w": 70,  "align": "r", "fmt": "diff"},
]

# --- 通算記録 / タイトル履歴 / スタメン履歴 ビュー ---
const VIEW_YEAR: String = "year"
const VIEW_CAREER: String = "career"
const VIEW_TITLES: String = "titles"
const VIEW_LINEUP: String = "lineup"
const VIEW_CHIPS: Array = [
	{"key": VIEW_YEAR, "label": "年度別"},
	{"key": VIEW_CAREER, "label": "通算記録"},
	{"key": VIEW_TITLES, "label": "タイトル履歴"},
	{"key": VIEW_LINEUP, "label": "スタメン履歴"},
]
# ビュー切替チップはヘッダ行 (home の「本日を終了」等と同じ y=22/高さ42/右端1900) に置く。
# y=96 の帯は各ビュー固有のコントロール専用になるため、部門チップの折り返し・右寄せ判定は
# 画面のコンテンツ右端 (_content_right_x()) だけを基準にすればよい。

# 通算記録の上位表示件数。CAREER_BAT_RECT等 (高さ448) に row_h=28 で収まる上限 (13*28=364 <= 368)。
const CAREER_TOP_N: int = 13

# 率系部門の通算下限 (調整ノブ)。低打席/低投球回のシーズンで異常値が上位に出るのを防ぐ。
# 打率/OPS: MLBの通算打率ランキングで慣習的に使われる 3000打席を目安値として採用。
const CAREER_MIN_PA: int = 3000
# 防御率/WHIP: Baseball-Referenceの通算防御率ランキングの目安 (1000投球回=3000アウト) を採用。
const CAREER_MIN_OUTS: int = 3000

# シーズン記録の率系部門は rankings_screen.gd の規定打席/規定投球回 (所属球団のその時点の試合数
# 基準) をそのまま流用する。[[project_ability_stats_qualifier_filter]] に既知の重複あり (3箇所目)
# だが、新しい式を発明せず既存定義を踏襲する。
const SEASON_QUALIFIER_PA_PER_TEAM_GAME: float = 3.1
const SEASON_QUALIFIER_OUTS_PER_TEAM_GAME: float = 3.0

# fmt: "記録"列と率系部門のソート方向を決める書式トークン (int/rate/f2)。qualifier: 規定の種別
# ("pa"=規定打席 / "outs"=規定投球回、空なら規定なし=カウント系)。ascending: true で昇順ソート
# (防御率/WHIPは小さいほど上位)。
const CAREER_BAT_CATEGORIES: Array = [
	{"key": "hits", "label": "安打", "fmt": "int"},
	{"key": "home_runs", "label": "本塁打", "fmt": "int"},
	{"key": "runs_batted_in", "label": "打点", "fmt": "int"},
	{"key": "stolen_bases", "label": "盗塁", "fmt": "int"},
	{"key": "games", "label": "出場", "fmt": "int"},
	{"key": "average", "label": "打率", "fmt": "rate", "qualifier": "pa"},
	{"key": "ops", "label": "OPS", "fmt": "rate", "qualifier": "pa"},
]
const CAREER_PIT_CATEGORIES: Array = [
	{"key": "wins", "label": "勝利", "fmt": "int"},
	{"key": "saves", "label": "S", "fmt": "int"},
	{"key": "holds", "label": "H", "fmt": "int"},
	{"key": "strikeouts", "label": "奪三振", "fmt": "int"},
	{"key": "games", "label": "登板", "fmt": "int"},
	{"key": "era", "label": "防御率", "fmt": "f2", "qualifier": "outs", "ascending": true},
	{"key": "whip", "label": "WHIP", "fmt": "f2", "qualifier": "outs", "ascending": true},
]
const TITLE_HISTORY_CATEGORIES: Array = [
	{"key": "mvp", "label": "MVP"},
	{"key": "rookie", "label": "新人王"},
	{"key": "bat_average", "label": "首位打者"},
	{"key": "bat_home_runs", "label": "本塁打王"},
	{"key": "bat_rbi", "label": "打点王"},
	{"key": "bat_stolen_bases", "label": "盗塁王"},
	{"key": "bat_hits", "label": "最多安打"},
	{"key": "pit_wins", "label": "最多勝利"},
	{"key": "pit_era", "label": "最優秀防御率"},
	{"key": "pit_strikeouts", "label": "最多奪三振"},
	{"key": "pit_saves", "label": "最多セーブ"},
	{"key": "pit_holds", "label": "最多ホールド"},
	{"key": "pit_win_rate", "label": "最高勝率"},
]

const CAREER_BAT_RECT: Rect2 = Rect2(262, 150, 808, 448)
const CAREER_PIT_RECT: Rect2 = Rect2(1092, 150, 808, 448)
const SEASON_BAT_RECT: Rect2 = Rect2(262, 610, 808, 448)
const SEASON_PIT_RECT: Rect2 = Rect2(1092, 610, 808, 448)
# 他ビューのパネルと同じコンテンツ幅 (262..1900 = 1638) を使う。旧 1240 幅は増設した列
# (選手・球団・記録 を第1/第2リーグ別に7列) に対して狭すぎ、右側に約400pxの空白が残っていた。
const TITLE_TABLE_RECT: Rect2 = Rect2(262, 190, 1638, 868)

# 通算/シーズン記録テーブルの列は打者/投手モードで固定 (部門チップを切り替えても列構成は変わらない)。
# 文脈列 (試合/打率/本/打点、または登板/勝/防御率/奪三振) を選択部門の値と併記し、選択部門を保持する
# 「記録」列だけ strong で強調する。「記録」列の fmt はカテゴリ定義 (int/rate/f2) から都度差し込む。
func _career_bat_columns(category: Dictionary) -> Array:
	return [
		{"title": "順",   "key": "rank",   "w": 40,  "align": "l", "fmt": "rank"},
		{"title": "選手", "key": "player", "w": 190, "align": "l", "fmt": "str", "strong": true},
		{"title": "球団", "key": "team",   "w": 140, "align": "l", "fmt": "team", "sep_before": true},
		{"title": "在籍", "key": "span",   "w": 110, "align": "l", "fmt": "str"},
		{"title": "試合", "key": "g",      "w": 74,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "打率", "key": "avg",    "w": 82,  "align": "r", "fmt": "rate"},
		{"title": "本",   "key": "hr",     "w": 64,  "align": "r", "fmt": "int"},
		{"title": "打点", "key": "rbi",    "w": 74,  "align": "r", "fmt": "int"},
		{"title": "記録", "key": "value",  "w": 90,  "align": "r", "fmt": str(category.get("fmt", "int")), "strong": true, "sep_before": true},
	]


func _career_pit_columns(category: Dictionary) -> Array:
	return [
		{"title": "順",   "key": "rank",   "w": 40,  "align": "l", "fmt": "rank"},
		{"title": "選手", "key": "player", "w": 190, "align": "l", "fmt": "str", "strong": true},
		{"title": "球団", "key": "team",   "w": 140, "align": "l", "fmt": "team", "sep_before": true},
		{"title": "在籍", "key": "span",   "w": 110, "align": "l", "fmt": "str"},
		{"title": "登板", "key": "g",      "w": 74,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "勝",   "key": "wins",   "w": 60,  "align": "r", "fmt": "int"},
		{"title": "防御率", "key": "era",  "w": 84,  "align": "r", "fmt": "f2"},
		{"title": "奪三振", "key": "so",   "w": 80,  "align": "r", "fmt": "int"},
		{"title": "記録", "key": "value",  "w": 90,  "align": "r", "fmt": str(category.get("fmt", "int")), "strong": true, "sep_before": true},
	]


# シーズン記録は「在籍」の代わりに「年度」列 (達成年度) を持つ以外は通算と同じ文脈列構成。
func _season_bat_columns(category: Dictionary) -> Array:
	return [
		{"title": "順",   "key": "rank",   "w": 40,  "align": "l", "fmt": "rank"},
		{"title": "選手", "key": "player", "w": 170, "align": "l", "fmt": "str", "strong": true},
		{"title": "球団", "key": "team",   "w": 130, "align": "l", "fmt": "team", "sep_before": true},
		{"title": "年度", "key": "year",   "w": 76,  "align": "l", "fmt": "str", "sep_before": true},
		{"title": "試合", "key": "g",      "w": 70,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "打率", "key": "avg",    "w": 80,  "align": "r", "fmt": "rate"},
		{"title": "本",   "key": "hr",     "w": 60,  "align": "r", "fmt": "int"},
		{"title": "打点", "key": "rbi",    "w": 70,  "align": "r", "fmt": "int"},
		{"title": "記録", "key": "value",  "w": 88,  "align": "r", "fmt": str(category.get("fmt", "int")), "strong": true, "sep_before": true},
	]


func _season_pit_columns(category: Dictionary) -> Array:
	return [
		{"title": "順",   "key": "rank",   "w": 40,  "align": "l", "fmt": "rank"},
		{"title": "選手", "key": "player", "w": 170, "align": "l", "fmt": "str", "strong": true},
		{"title": "球団", "key": "team",   "w": 130, "align": "l", "fmt": "team", "sep_before": true},
		{"title": "年度", "key": "year",   "w": 76,  "align": "l", "fmt": "str", "sep_before": true},
		{"title": "登板", "key": "g",      "w": 70,  "align": "r", "fmt": "int", "sep_before": true},
		{"title": "勝",   "key": "wins",   "w": 56,  "align": "r", "fmt": "int"},
		{"title": "防御率", "key": "era",  "w": 80,  "align": "r", "fmt": "f2"},
		{"title": "奪三振", "key": "so",   "w": 76,  "align": "r", "fmt": "int"},
		{"title": "記録", "key": "value",  "w": 88,  "align": "r", "fmt": str(category.get("fmt", "int")), "strong": true, "sep_before": true},
	]


# 年度 / 第1リーグ[選手・球団・記録] / 第2リーグ[選手・球団・記録] の7列。両リーグのブロックは
# 同じ列幅比率にして対称に見せ、ブロック境界(年度|第1・第1|第2)と各ブロック内の記録境界に
# sep_before の縦ヘアラインを入れる。
# "team" fmt はリーグ毎に別セル (p1_team/p2_team) を持つため、基底 _draw_data_table 側の
# team 列描画を row[key]/row[key+"_color"] 参照に対応させてある (通常の単一 team 列は後方互換)。
# **列幅は `_draw_data_table` の `factor = usable/Σw` で一律スケールされるため w の比率がそのまま
# 見た目の比率になる**(usable=1638-inner_pad*2=1614)。球団は色ドット+短縮名1文字しか持たず
# 実測 60px 強で足りるため w=64 に絞り、年度も "2027年" 相当で足りる w=70 に絞る。
# **記録は左揃え**(他画面の数値専用「記録」列は右揃えだが、ここは可変長の複合文字列
# 例: ".371 / 29本 / 81点" なので、球団の直後で左揃えにして地続きに読ませる)。右揃えのまま列を
# 広げると「球団の短い文字列の直後〜記録の右詰め文字列の直前」に大きな空白の谷ができてしまう
# (2026-07-31 に実測して判明。列幅の比率だけ直しても解消しなかった)。左揃えなら余った幅は
# ブロック末尾(次ブロックの sep_before 罫線の直前、または表の右端)に流れるだけなので目立たない。
# 空いた幅は 選手(可変長の氏名) と 記録 に回す。球団のような「内容に対して桁違いに広い列」を
# 作らないことが列間の不自然な空白を避ける要点。
const TITLE_COLUMNS: Array = [
	{"title": "年度", "key": "year",     "w": 70,  "align": "l", "fmt": "str"},
	{"title": "選手", "key": "p1_name",  "w": 260, "align": "l", "fmt": "str", "strong": true, "sep_before": true},
	{"title": "球団", "key": "p1_team",  "w": 64,  "align": "l", "fmt": "team"},
	{"title": "記録", "key": "p1_value", "w": 300, "align": "l", "fmt": "str", "sep_before": true},
	{"title": "選手", "key": "p2_name",  "w": 260, "align": "l", "fmt": "str", "strong": true, "sep_before": true},
	{"title": "球団", "key": "p2_team",  "w": 64,  "align": "l", "fmt": "team"},
	{"title": "記録", "key": "p2_value", "w": 300, "align": "l", "fmt": "str", "sep_before": true},
]

# --- スタメン履歴 ビュー ---
const POS_SHORT: Dictionary = {
	1: "投", 2: "捕", 3: "一", 4: "二", 5: "三",
	6: "遊", 7: "左", 8: "中", 9: "右", 10: "DH",
}
# 守備位置別スタメン数パネルのグループ順 (捕・一・二・三・遊・左・中・右・DH・投)。
# 投手を末尾に置くのは、先発を務めた投手が10人超になり先頭だと野手グループが
# スクロールしないと見えなくなるため (この画面の主役は守備位置=野手側)。
const LINEUP_TOP_POSITIONS: Array = [2, 3, 4, 5, 6, 7, 8, 9, 10, 1]
const LINEUP_SLOT_COUNT: int = 9
# 試合別打線パネルの列数 = 打順9 + 右端の先発投手列。先発投手セルは打順スロットと同じ
# 「守備位置バッジ+選手名」形式で slots 配列の10番目に積むため、セル幅もこの列数で等分する。
const LINEUP_GAME_COLUMN_COUNT: int = LINEUP_SLOT_COUNT + 1

# --- レイアウト基準 (base 座標) ---
# 独自の年度/球団プルダウンはビュー切替チップがヘッダ行(y=22)へ移ったので、
# y=96 の帯を自由に使って左寄せに置く (年度別ビューの ◀/▶・年度ラベルとは領域が近いが
# _view で排他的に描画されるため衝突しない)。ラベル("年度"/"球団")は表示しないので、
# 帯の中で値と▼だけが縦中央に来るよう LINEUP_SEL_Y を基準に組む。
const LINEUP_SEL_Y: float = 106.0
const LINEUP_SEASON_X: float = 262.0
const LINEUP_TEAM_X: float = 640.0
# 年度の値テキスト(22px)・球団名(18px)・▼マーカー(13px)は異なるフォントサイズ・ウェイトで、
# いずれも draw_string のベースライン指定なので同じ y を渡しても視覚中心は揃わない
# (ascent/descent が字体ごとに違う)。実測 (reports/ui_shots の history_lineup.png を対象文字色の
# RGB に一致するピクセルを連結成分化しグリフの y 範囲を測定) でベースラインを詰め、値・▼・
# 球団バッジ(28px角、中心 y ≈ LINEUP_SEL_Y+10) の視覚中心が揃う値にしてある。
const LINEUP_VALUE_BASELINE_Y: float = LINEUP_SEL_Y + 17.0
const LINEUP_ARROW_BASELINE_Y: float = LINEUP_SEL_Y + 15.0
# 守備位置別スタメン数パネル / 試合別打線パネルの矩形はモードで縦配分が変わる (詳細モードは
# 全員分の行を見せるためパネルを大きく取り、概要モードはカードの中身が3行+見出しで収まるぶん
# パネルを詰めて空いた縦幅を試合別打線へ回す)。両パネルの下端は 1056 で揃える。
const POSITION_RECT_ALL: Rect2 = Rect2(262, 144, 1638, 486)
const GAMES_RECT_ALL: Rect2 = Rect2(262, 646, 1638, 410)
const POSITION_RECT_TOP3: Rect2 = Rect2(262, 144, 1638, 388)
const GAMES_RECT_TOP3: Rect2 = Rect2(262, 548, 1638, 508)

# 守備位置別スタメン数パネルの表示モード。既定は概要(上位3名) = カードグリッド、
# 「全員」は従来のグループ化テーブル (詳細モード)。
const LU_POS_MODE_TOP3: String = "top3"
const LU_POS_MODE_ALL: String = "all"

# 守備位置別テーブルの縦積み単位 (グループ見出し / 列見出し / 選手行) の高さとピクセル単位スクロール歩幅。
const POS_GROUP_HEADER_H: float = 34.0
const POS_COL_HEADER_H: float = 22.0
const POS_ROW_H: float = 26.0
const POS_GROUP_GAP: float = 14.0
const POS_SCROLL_STEP: float = 30.0

# 概要モード (守備位置カードグリッド) のレイアウト定数。列数固定 5 × 可変行数、
# カード幅は枚数(DH有無)に依存しない (5列グリッドの1マス分で決まる)。
const LU_CARD_COLS: int = 5
const LU_CARD_GAP: float = 14.0
const LU_CARD_TOP_N: int = 3
const LU_CARD_PAD_X: float = 10.0
const LU_CARD_HEADER_H: float = 40.0
const LU_CARD_COLHEAD_H: float = 20.0
const LU_CARD_ROW_START: float = LU_CARD_HEADER_H + LU_CARD_COLHEAD_H + 4.0
const LU_CARD_ROW_H: float = 26.0
const LU_CARD_STAT_GAP: float = 10.0

# カード内の列見出しラベル (キーは POS_BATTER_COLUMNS/POS_PITCHER_COLUMNS の一部と共有)。
const CARD_HEADER_BATTER: Dictionary = {
	"starts": "スタメン", "avg": "打率", "hr": "本", "ops": "OPS", "war": "WAR",
}
const CARD_HEADER_PITCHER: Dictionary = {
	"starts": "先発", "era": "防御率", "war": "WAR",
}

# 野手グループの列 (lineup_editor_screen の一軍登録野手一覧の列 + 打席/四球/三振。
# 列順は player_detail_screen の過去成績タブ (試合〜盗塁 → 率系 → 四球/三振) の並びに準じる)。
const POS_BATTER_COLUMNS: Array = [
	{"key": "name", "title": "選手", "w": 230.0, "align": "l"},
	{"key": "starts", "title": "スタメン", "w": 80.0, "align": "r"},
	{"key": "games", "title": "試合", "w": 62.0, "align": "r"},
	{"key": "pa", "title": "打席", "w": 62.0, "align": "r"},
	{"key": "avg", "title": "打率", "w": 78.0, "align": "r"},
	{"key": "hr", "title": "本", "w": 56.0, "align": "r"},
	{"key": "rbi", "title": "打点", "w": 68.0, "align": "r"},
	{"key": "sb", "title": "盗塁", "w": 68.0, "align": "r"},
	{"key": "obp", "title": "出塁率", "w": 80.0, "align": "r"},
	{"key": "ops", "title": "OPS", "w": 76.0, "align": "r"},
	{"key": "bb", "title": "四球", "w": 56.0, "align": "r"},
	{"key": "so", "title": "三振", "w": 56.0, "align": "r"},
	{"key": "woba", "title": "wOBA", "w": 80.0, "align": "r"},
	{"key": "wrc_plus", "title": "wRC+", "w": 76.0, "align": "r"},
	{"key": "oaa", "title": "OAA", "w": 76.0, "align": "r"},
	{"key": "war", "title": "WAR", "w": 76.0, "align": "r"},
]

# 投手グループ (投=pos1、グループ見出しは「先発」表示。データ源は starts_by_position の
# starter_pitcher_id 集計のまま = スタメン履歴由来) の列。打撃列は無意味なので投手成績列に差し替える。
# 列順は 登板〜敗 (計数) → 投球回/防御率/WHIP (率系) → 奪三振/与四球 (計数) → K/9/WAR。
const POS_PITCHER_COLUMNS: Array = [
	{"key": "name", "title": "選手", "w": 320.0, "align": "l"},
	{"key": "starts", "title": "スタメン(先発登板)", "w": 130.0, "align": "r"},
	{"key": "games", "title": "登板", "w": 80.0, "align": "r"},
	{"key": "wins", "title": "勝", "w": 66.0, "align": "r"},
	{"key": "losses", "title": "敗", "w": 66.0, "align": "r"},
	{"key": "ip", "title": "投球回", "w": 80.0, "align": "r"},
	{"key": "era", "title": "防御率", "w": 86.0, "align": "r"},
	{"key": "whip", "title": "WHIP", "w": 86.0, "align": "r"},
	{"key": "so", "title": "奪三振", "w": 80.0, "align": "r"},
	{"key": "bb", "title": "与四球", "w": 80.0, "align": "r"},
	{"key": "k9", "title": "K/9", "w": 76.0, "align": "r"},
	{"key": "war", "title": "WAR", "w": 86.0, "align": "r"},
]

# 集計キャッシュ
var _archives: Array = []                   # 古い順 (RecordStore 由来)
var _sel: int = 0                           # 0 = 最新。表示対象 = _archives[size-1-_sel]
var _has_data: bool = false
var _year_label: String = ""
var _rows_by_league: Dictionary = {}        # {league_key: Array of 表示用 Dictionary}
var _post_champion_id: int = 0
var _post_by_stage: Dictionary = {}         # stage_key → シリーズ行 Dictionary (完了分のみ)
var _award_cards: Array = []                # MVP/新人王 カード Dictionary
var _bat_rows: Array = []                   # 打撃タイトル行 {label, league1, league2}
var _pit_rows: Array = []                   # 投手タイトル行

var _view: String = VIEW_YEAR
var _career_bat_key: String = "hits"
var _career_pit_key: String = "wins"
var _title_key: String = "mvp"
var _career_built: bool = false
var _career_bat_by_key: Dictionary = {}     # category key → 行 Array
var _career_pit_by_key: Dictionary = {}
var _season_bat_by_key: Dictionary = {}
var _season_pit_by_key: Dictionary = {}
var _title_rows: Array = []                 # タイトル履歴 (選択部門の年度別行、新しい順)

# スタメン履歴ビュー用キャッシュ (年度別/通算記録/タイトル履歴とは独立)。
var _lu_seasons: Array = []                 # PSLineupHistory.available_seasons() の結果 (新しい順)
var _lu_sel_season_index: int = 0
var _team_id: int = 0
var _team_ids: Array = []                   # 第1→第2リーグ、リーグ内 id 昇順
var _lu_rows: Array = []                    # 選択中の年度・球団の全試合スタメン行
var _lu_pos_starts: Dictionary = {}         # starts_by_position(_lu_rows)
var _lu_game_rows: Array = []               # 表示用に整形した試合別打線 (新しい順)
var _lu_position_groups: Array = []         # 守備位置別テーブル (グループ見出し+列+選手行、_refresh_lineup で1回構築)
var _lu_name_cache: Dictionary = {}         # player_id -> 選手名 (選択中の年度に閉じる)
var _lu_war_ctx_cache: Dictionary = {}      # "year-sn" -> WarCalculator.build_league_context() (年度ごとに1回)
var _lu_cur_year: int = 0
var _lu_cur_season_number: int = 0
var _lu_scroll: Dictionary = {}
var _lu_scroll_zones: Array = []            # [{rect, key, max}] ホイールスクロール領域
var _hover_pid: int = 0                     # 上下パネルを跨いで連動ハイライトする選手 (0=なし)
var _lu_pos_row_hits: Array = []            # {rect, pid} 守備位置別テーブルの選手行 (ホバー/相互ハイライト用)
var _lu_game_cell_hits: Array = []          # {rect, pid} 試合別打線の選手セル (ホバー/相互ハイライト用)
var _lu_pos_mode: String = LU_POS_MODE_TOP3 # 守備位置別スタメン数パネルの表示モード (既定=概要/上位3名)

var _season_menu_button: Button = null
var _team_menu_button: Button = null


func _ready() -> void:
	_init_chrome()
	_build_team_order()
	_team_id = AppState.selected_team_id
	if not _team_ids.has(_team_id) and not _team_ids.is_empty():
		_team_id = int(_team_ids[0])
	_refresh()
	_refresh_lineup()
	_build_buttons()
	queue_redraw()


# ============================================================ draw

func _draw() -> void:
	_update_transform()
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)
	_lu_scroll_zones = []
	_lu_pos_row_hits = []
	_lu_game_cell_hits = []

	var team: PSTeam = GameDb.get_team(AppState.selected_team_id)
	var season: PSSeason = AppState.current_season
	_draw_shell("シーズン履歴", team, season)

	match _view:
		VIEW_CAREER:
			_draw_career_view()
			return
		VIEW_TITLES:
			_draw_titles_view()
			return
		VIEW_LINEUP:
			_draw_lineup_view()
			return

	if not _has_data:
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ完了したシーズンがありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text("シーズンを最後までプレイすると、ここに順位表・ポストシーズン・タイトルが記録されます。",
			Vector2(560, 548), 14, MUTED, 800, HORIZONTAL_ALIGNMENT_CENTER)
		return

	# 年度ラベル (◀/▶ ボタンの間に描画)
	_round(Rect2(YEAR_LABEL_X, 96, YEAR_LABEL_W, 34), PANEL_2, BORDER, 8)
	_text(_year_label, Vector2(YEAR_LABEL_X, 119), 17, TEXT, YEAR_LABEL_W, HORIZONTAL_ALIGNMENT_CENTER, true)

	_draw_table(TABLE_A, str(LEAGUES[0]["label"]), HIST_COLUMNS, _rows_by_league.get("league1", []) as Array)
	_draw_table(TABLE_B, str(LEAGUES[1]["label"]), HIST_COLUMNS, _rows_by_league.get("league2", []) as Array)
	_draw_postseason(POST_RECT)
	_draw_awards(AWARD_RECT)
	_draw_titles(BAT_RECT, "打撃タイトル", _bat_rows)
	_draw_titles(PIT_RECT, "投手タイトル", _pit_rows)


# ============================================================ 通算記録 / タイトル履歴 ビュー

func _draw_career_view() -> void:
	_build_career()
	if (_career_bat_by_key.get(_career_bat_key, []) as Array).is_empty() \
			and (_career_pit_by_key.get(_career_pit_key, []) as Array).is_empty():
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ成績の記録がありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		return
	var bat_cat: Dictionary = _category_by_key(CAREER_BAT_CATEGORIES, _career_bat_key)
	var pit_cat: Dictionary = _category_by_key(CAREER_PIT_CATEGORIES, _career_pit_key)
	var bat_label: String = str(bat_cat.get("label", _career_bat_key))
	var pit_label: String = str(pit_cat.get("label", _career_pit_key))
	_draw_data_table(CAREER_BAT_RECT, _career_bat_columns(bat_cat), _career_bat_by_key.get(_career_bat_key, []) as Array, {
		"title": "通算打撃リーダー: %s" % bat_label, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
		"cell_size": 13, "empty_text": "記録がありません",
	})
	_draw_data_table(CAREER_PIT_RECT, _career_pit_columns(pit_cat), _career_pit_by_key.get(_career_pit_key, []) as Array, {
		"title": "通算投手リーダー: %s" % pit_label, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
		"cell_size": 13, "empty_text": "記録がありません",
	})
	_draw_data_table(SEASON_BAT_RECT, _season_bat_columns(bat_cat), _season_bat_by_key.get(_career_bat_key, []) as Array, {
		"title": "シーズン打撃記録: %s" % bat_label, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
		"cell_size": 13, "empty_text": "記録がありません",
	})
	_draw_data_table(SEASON_PIT_RECT, _season_pit_columns(pit_cat), _season_pit_by_key.get(_career_pit_key, []) as Array, {
		"title": "シーズン投手記録: %s" % pit_label, "header_top": 58.0, "row_h": 28.0, "alt_rows": true,
		"cell_size": 13, "empty_text": "記録がありません",
	})


func _draw_titles_view() -> void:
	var label: String = _category_label(TITLE_HISTORY_CATEGORIES, _title_key)
	if _title_rows.is_empty():
		_round(Rect2(560, 380, 800, 240), PANEL, BORDER, 12)
		_text("まだ完了したシーズンがありません", Vector2(560, 508), 22, TEXT, 800, HORIZONTAL_ALIGNMENT_CENTER, true)
		return
	_draw_data_table(TITLE_TABLE_RECT, TITLE_COLUMNS, _title_rows, {
		"title": "タイトル履歴: %s" % label, "header_top": 58.0, "row_h": 30.0, "alt_rows": true,
		"cell_size": 14, "empty_text": "記録がありません",
	})


func _category_label(categories: Array, key: String) -> String:
	return str(_category_by_key(categories, key).get("label", key))


# 部門定義 (fmt/qualifier/ascending 等) をキーから引く。TITLE_HISTORY_CATEGORIES のような
# label のみの用途は _category_label 経由でこれを使う。
func _category_by_key(categories: Array, key: String) -> Dictionary:
	for category_value in categories:
		var category: Dictionary = category_value as Dictionary
		if str(category.get("key", "")) == key:
			return category
	return {}


# ============================================================ 順位表 (順位表画面から流用)

# 描画本体は基底 _draw_data_table に集約 (2026-06-24)。
func _draw_table(rect: Rect2, title: String, columns: Array, rows: Array) -> void:
	_draw_data_table(rect, columns, rows, {"title": title, "empty_text": "記録がありません"})


# ============================================================ ポストシーズン

func _draw_postseason(rect: Rect2) -> void:
	_panel(rect, "ポストシーズン")

	# 日本一バナー: 枠は使わずアンバーの地色だけで強調する (勝者の色分けは維持)。
	var banner: Rect2 = Rect2(rect.position.x + 18, rect.position.y + 52, rect.size.x - 36, 88)
	if _post_champion_id > 0:
		_round(banner, Color(AMBER.r, AMBER.g, AMBER.b, 0.14), Color.TRANSPARENT, 10, 0)
		var champ: PSTeam = GameDb.get_team(_post_champion_id)
		_text("★ 日本一 ★", Vector2(banner.position.x + 24, banner.position.y + 34), 16, AMBER, 200, HORIZONTAL_ALIGNMENT_LEFT, true)
		if champ != null:
			_team_badge(Rect2(banner.position.x + 24, banner.position.y + 42, 34, 34), champ)
			_text(champ.name, Vector2(banner.position.x + 68, banner.position.y + 66), 22, TEXT, banner.size.x - 90, HORIZONTAL_ALIGNMENT_LEFT, true)
	else:
		_round(banner, PANEL_2, Color.TRANSPARENT, 10, 0)
		_text("日本一未決定", Vector2(banner.position.x, banner.position.y + 50), 16, MUTED, banner.size.x, HORIZONTAL_ALIGNMENT_CENTER)

	if _post_by_stage.is_empty():
		_text("ポストシーズンの記録がありません", Vector2(rect.position.x + 24, rect.position.y + 200), 14, MUTED)
		return

	# レイアウト: 左に細いガター(ステージ名)、その右を2カラム(第1/第2リーグ)に分割。
	var inner_x: float = rect.position.x + 18.0
	var gutter_w: float = 86.0
	var cards_x: float = inner_x + gutter_w
	var cards_w: float = rect.end.x - 18.0 - cards_x
	var gap: float = 14.0
	var col_w: float = (cards_w - gap) / 2.0
	var left_x: float = cards_x
	var right_x: float = cards_x + col_w + gap
	var lay: Dictionary = {
		"inner_x": inner_x, "gutter_w": gutter_w, "left_x": left_x,
		"right_x": right_x, "col_w": col_w, "cards_x": cards_x, "cards_w": cards_w,
	}

	# 列見出し (第1リーグ / 第2リーグ) — バナーから離し、試合結果カードの直上へ寄せる。
	var head_y: float = banner.end.y + 32.0
	_text("第1リーグ", Vector2(left_x, head_y), 14, MUTED, col_w, HORIZONTAL_ALIGNMENT_CENTER)
	_text("第2リーグ", Vector2(right_x, head_y), 14, MUTED, col_w, HORIZONTAL_ALIGNMENT_CENTER)

	# 完了シリーズを1つでも持つステージグループだけ描画する。
	var groups: Array = []
	for group_value in POST_GROUPS:
		if _group_has_data(group_value as Dictionary):
			groups.append(group_value)
	if groups.is_empty():
		return

	var area_top: float = head_y + 16.0
	var area_bottom: float = rect.end.y - 14.0
	var gh: float = (area_bottom - area_top) / float(groups.size())
	for i in range(groups.size()):
		_draw_stage_group(groups[i] as Dictionary, lay, area_top + float(i) * gh, gh)


func _group_has_data(group: Dictionary) -> bool:
	for key in ["league1", "league2", "japan"]:
		if group.has(key) and _post_by_stage.has(str(group[key])):
			return true
	return false


func _draw_stage_group(group: Dictionary, lay: Dictionary, y: float, gh: float) -> void:
	# ガターのステージ名 (複数行は縦中央寄せ)。
	var lines: Array = group.get("lines", []) as Array
	var n: int = lines.size()
	var ly0: float = y + gh * 0.5 - float(n - 1) * 9.0 + 5.0
	for j in range(n):
		_text(str(lines[j]), Vector2(float(lay["inner_x"]), ly0 + float(j) * 18.0), 12, MUTED, float(lay["gutter_w"]) - 6.0, HORIZONTAL_ALIGNMENT_LEFT, j == n - 1)

	var card_y: float = y + 6.0
	var card_h: float = gh - 12.0
	if bool(group.get("split", false)):
		_draw_post_card(Rect2(float(lay["left_x"]), card_y, float(lay["col_w"]), card_h), _post_by_stage.get(str(group["league1"])))
		_draw_post_card(Rect2(float(lay["right_x"]), card_y, float(lay["col_w"]), card_h), _post_by_stage.get(str(group["league2"])))
	else:
		_draw_post_card(Rect2(float(lay["cards_x"]), card_y, float(lay["cards_w"]), card_h), _post_by_stage.get(str(group["japan"])))


# 1シリーズ分のカード。row が null のステージは「未実施」と表示する。
func _draw_post_card(card: Rect2, row: Variant) -> void:
	_round(card, PANEL_2, Color.TRANSPARENT, 8, 0)
	if row == null:
		_text("未実施", Vector2(card.position.x, card.position.y + card.size.y * 0.5 + 5.0), 13, FAINT, card.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		return

	var r: Dictionary = row as Dictionary
	var top_id: int = int(r.get("top_id", 0))
	var chal_id: int = int(r.get("chal_id", 0))
	var win_id: int = int(r.get("winner_id", 0))
	var games: Array = r.get("games", []) as Array
	var has_breakdown: bool = not games.is_empty()

	# --- 対戦カード ---
	# スコアをカード中央のボックスに固定し、両チーム名をその両脇へ寄せて左右間隔を対称にする。
	var line1_y: float = card.position.y + (card.size.y * 0.40 if has_breakdown else card.size.y * 0.5)
	var cxs: float = card.position.x + card.size.x * 0.5
	var score: String = "%d勝%d敗" % [int(r.get("top_wins", 0)), int(r.get("chal_wins", 0))]
	_text(score, Vector2(cxs - 54.0, line1_y + 6.0), 18, TEXT, 108, HORIZONTAL_ALIGNMENT_CENTER, true)

	# 勝者は AMBER 強調、敗退チームはグレーアウト、未決着は通常色。
	var decided: bool = win_id != 0
	var top_col: Color = AMBER if win_id == top_id else (MUTED if decided else TEXT)
	var chal_col: Color = AMBER if win_id == chal_id else (MUTED if decided else TEXT)

	var top_dot_x: float = cxs - 54.0 - 12.0
	_dot(Vector2(top_dot_x, line1_y), 5.0, _team_color(top_id))
	_text_right(_team_short(top_id), top_dot_x - 10.0, line1_y + 6.0, 17, top_col, 96)

	var chal_dot_x: float = cxs + 54.0 + 12.0
	_dot(Vector2(chal_dot_x, line1_y), 5.0, _team_color(chal_id))
	_text(_team_short(chal_id), Vector2(chal_dot_x + 10.0, line1_y + 6.0), 17, chal_col, 96)

	# --- 勝敗の内訳 (各試合のスコアを top チーム視点で) ---
	if has_breakdown:
		_draw_breakdown(card, top_id, games, int(r.get("advantage", 0)))


# カード下部に各試合のスコアチップを中央寄せで並べる (top 視点、勝=緑/敗=赤/分=灰)。
func _draw_breakdown(card: Rect2, top_id: int, games: Array, advantage: int) -> void:
	var chips: Array = []
	if advantage > 0:
		chips.append({"label": "AD", "col": AMBER})
	for game_value in games:
		var g: Dictionary = game_value as Dictionary
		var top_is_home: bool = int(g.get("home_id", 0)) == top_id
		var top_score: int = int(g.get("home_score", 0)) if top_is_home else int(g.get("away_score", 0))
		var opp_score: int = int(g.get("away_score", 0)) if top_is_home else int(g.get("home_score", 0))
		var col: Color = MUTED
		if not bool(g.get("draw", false)):
			col = GREEN if int(g.get("winner_id", 0)) == top_id else RED
		chips.append({"label": "%d-%d" % [top_score, opp_score], "col": col})

	var widths: Array = []
	var total: float = 0.0
	for chip_value in chips:
		var w: float = max(40.0, _measure(str((chip_value as Dictionary)["label"]), 11) + 14.0)
		widths.append(w)
		total += w + 6.0
	if not chips.is_empty():
		total -= 6.0

	var cy: float = card.position.y + card.size.y - 18.0
	var sx: float = card.position.x + max(10.0, (card.size.x - total) * 0.5)
	for i in range(chips.size()):
		var w: float = float(widths[i])
		if sx + w > card.end.x - 8.0:
			break
		var chip: Dictionary = chips[i] as Dictionary
		_draw_game_chip(sx, cy, w, str(chip["label"]), chip["col"] as Color)
		sx += w + 6.0


# 内訳の1試合分チップ。色で勝(緑)/敗(赤)/分(灰)を示す。
func _draw_game_chip(x: float, center_y: float, w: float, label: String, col: Color) -> void:
	_round(Rect2(x, center_y - 11.0, w, 22.0), Color(col.r, col.g, col.b, 0.16), Color(col.r, col.g, col.b, 0.5), 6)
	var tcol: Color = TEXT if col == MUTED else col
	_text(label, Vector2(x, center_y + 4.0), 11, tcol, w, HORIZONTAL_ALIGNMENT_CENTER, true)


# ============================================================ 最優秀選手・新人王

func _draw_awards(rect: Rect2) -> void:
	_panel(rect, "最優秀選手・新人王")

	if _award_cards.is_empty():
		_text("表彰の記録がありません", Vector2(rect.position.x + 24, rect.position.y + rect.size.y * 0.6), 14, MUTED)
		return

	var n: int = _award_cards.size()
	var inner_x: float = rect.position.x + 18.0
	var usable: float = rect.size.x - 36.0
	var gap: float = 14.0
	var card_w: float = (usable - gap * float(n - 1)) / float(n)
	var card_y: float = rect.position.y + 64.0
	var card_h: float = rect.size.y - 64.0 - 18.0
	for i in range(n):
		var c: Dictionary = _award_cards[i] as Dictionary
		var cr: Rect2 = Rect2(inner_x + float(i) * (card_w + gap), card_y, card_w, card_h)
		var accent: Color = c.get("accent", BLUE) as Color
		# 枠は落とし、上端のアクセントバーだけで部門色を示す。
		_round(cr, PANEL_2, Color.TRANSPARENT, 9, 0)
		_round(Rect2(cr.position.x, cr.position.y, cr.size.x, 4.0), accent, Color.TRANSPARENT, 0, 0)
		_text(str(c.get("title", "")), Vector2(cr.position.x, cr.position.y + 32.0), 16, accent, cr.size.x, HORIZONTAL_ALIGNMENT_CENTER, true)
		_text(str(c.get("league", "")), Vector2(cr.position.x, cr.position.y + 54.0), 12, MUTED, cr.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		_text(str(c.get("player", "")), Vector2(cr.position.x + 6.0, cr.position.y + cr.size.y - 22.0), 17, TEXT, cr.size.x - 12.0, HORIZONTAL_ALIGNMENT_CENTER, true)


# ============================================================ 打撃/投手タイトル

func _draw_titles(rect: Rect2, title: String, rows: Array) -> void:
	_panel(rect, title)

	var inner_x: float = rect.position.x + 16.0
	var label_w: float = 104.0
	var col_w: float = (rect.size.x - 32.0 - label_w) / 2.0
	var c1_x: float = inner_x + label_w
	var c2_x: float = c1_x + col_w

	# ヘッダ帯 (v2 の _draw_data_table と同じ言語)。
	var hy: float = rect.position.y + 60.0
	_round(Rect2(inner_x, hy - 18.0, rect.end.x - 16.0 - inner_x, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	_text("部門", Vector2(inner_x + 2.0, hy), 11, MUTED, label_w, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("第1リーグ", Vector2(c1_x + 4.0, hy), 11, MUTED, col_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text("第2リーグ", Vector2(c2_x + 4.0, hy), 11, MUTED, col_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	_line(Vector2(inner_x, rect.position.y + 68.0), Vector2(rect.end.x - 16.0, rect.position.y + 68.0), BORDER, 1.5)

	if rows.is_empty():
		_text("記録がありません", Vector2(inner_x + 4.0, rect.position.y + 100.0), 13, MUTED)
		return

	var row_top: float = rect.position.y + 76.0
	var row_h: float = (rect.end.y - row_top - 10.0) / float(rows.size())
	for i in range(rows.size()):
		var r: Dictionary = rows[i] as Dictionary
		var ry: float = row_top + float(i) * row_h
		var ty: float = ry + row_h * 0.5 + 5.0
		_text(str(r.get("label", "")), Vector2(inner_x + 2.0, ty), 13, MUTED, label_w - 4.0)
		_text(str(r.get("league1", "")), Vector2(c1_x + 4.0, ty), 13, TEXT, col_w - 8.0)
		_text(str(r.get("league2", "")), Vector2(c2_x + 4.0, ty), 13, TEXT, col_w - 8.0)
		_line(Vector2(inner_x, ry + row_h), Vector2(rect.end.x - 16.0, ry + row_h), HAIRLINE, 1.0)


# ============================================================ スタメン履歴 ビュー

func _draw_lineup_view() -> void:
	_draw_lineup_selectors()
	_draw_position_panel(_lineup_position_rect())
	_draw_games_panel(_lineup_games_rect())


# 2パネルの矩形はモード依存。_draw / _build_buttons / スクロール領域 / 当たり矩形が全て
# この2関数経由で同じ Rect を参照する (どちらかだけ古い定数を見ると当たり判定がズレる)。
func _lineup_position_rect() -> Rect2:
	return POSITION_RECT_TOP3 if _lu_pos_mode == LU_POS_MODE_TOP3 else POSITION_RECT_ALL


func _lineup_games_rect() -> Rect2:
	return GAMES_RECT_TOP3 if _lu_pos_mode == LU_POS_MODE_TOP3 else GAMES_RECT_ALL


# --- 年度/球団プルダウン (player_detail の閲覧球団プルダウンと同じ部品・挙動) ---

func _draw_lineup_selectors() -> void:
	var label: String = _lineup_season_label_current()
	_text(label, Vector2(LINEUP_SEASON_X, LINEUP_VALUE_BASELINE_Y), 22, TEXT, -1.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	# ▼ は「押せる」ことの唯一の手掛かり (当たり判定 _lineup_season_hotspot_rect も追従して見込んでいる)。
	_text("▼", Vector2(LINEUP_SEASON_X + _measure(label, 22) + 10.0, LINEUP_ARROW_BASELINE_Y), 13, MUTED)

	var team: PSTeam = GameDb.get_team(_team_id)
	if team == null:
		return
	_team_badge(Rect2(LINEUP_TEAM_X, LINEUP_SEL_Y - 4.0, 28.0, 28.0), team)
	_text(team.name, Vector2(LINEUP_TEAM_X + 38.0, LINEUP_VALUE_BASELINE_Y), 18, TEXT)
	var nx: float = LINEUP_TEAM_X + 38.0 + _measure(team.name, 18) + 10.0
	_text("▼", Vector2(nx, LINEUP_ARROW_BASELINE_Y), 13, MUTED)


func _lineup_season_label_current() -> String:
	if _lu_seasons.is_empty():
		return "-"
	_lu_sel_season_index = clampi(_lu_sel_season_index, 0, _lu_seasons.size() - 1)
	var s: Dictionary = _lu_seasons[_lu_sel_season_index] as Dictionary
	return _lineup_season_label(int(s.get("year", 0)), int(s.get("season_number", 0)))


func _lineup_season_label(year: int, season_number: int) -> String:
	return "%d年 (第%d年目)" % [year, season_number]


func _lineup_season_hotspot_rect() -> Rect2:
	var label: String = _lineup_season_label_current()
	var w: float = _measure(label, 22)
	var top: float = LINEUP_SEL_Y - 6.0
	var bottom: float = LINEUP_VALUE_BASELINE_Y + 8.0
	return Rect2(LINEUP_SEASON_X - 6.0, top, w + 12.0 + 30.0, bottom - top)


func _lineup_team_hotspot_rect() -> Rect2:
	var team: PSTeam = GameDb.get_team(_team_id)
	var name_w: float = _measure(team.name, 18) if team != null else 0.0
	var top: float = LINEUP_SEL_Y - 6.0
	var bottom: float = LINEUP_VALUE_BASELINE_Y + 8.0
	return Rect2(LINEUP_TEAM_X - 6.0, top, 38.0 + name_w + 28.0, bottom - top)


# --- 守備位置別スタメン数 (グループ=守備位置、行=選手の縦積みテーブル) ---

func _draw_position_panel(rect: Rect2) -> void:
	_panel(rect, "守備位置別スタメン")
	if _lu_rows.is_empty() or _lu_position_groups.is_empty():
		_text("記録がありません", Vector2(rect.position.x + 24.0, rect.position.y + rect.size.y * 0.5), 16, MUTED)
		return
	if _lu_pos_mode == LU_POS_MODE_ALL:
		_draw_position_table(rect)
	else:
		_draw_position_cards(rect)


# 詳細モード (「全員」): 従来のグループ化テーブル。スクロールしないと全守備位置を見渡せないが、
# 野手16列 / 投手12列の全項目を選手全員分見せる (概要モードでは上位3名+主要項目のみ)。
func _draw_position_table(rect: Rect2) -> void:
	var inner_x: float = rect.position.x + 18.0
	var usable: float = rect.size.x - 36.0
	var view_top: float = rect.position.y + 60.0
	var view_bottom: float = rect.end.y - 14.0

	var content_h: float = 0.0
	for i in range(_lu_position_groups.size()):
		content_h += _group_content_height(_lu_position_groups[i] as Dictionary)
		if i > 0:
			content_h += POS_GROUP_GAP
	var max_off: int = int(ceil(maxf(0.0, content_h - (view_bottom - view_top)) / POS_SCROLL_STEP))
	var offset: int = clampi(int(_lu_scroll.get("position", 0)), 0, max_off)
	_lu_scroll["position"] = offset
	if max_off > 0:
		_lu_scroll_zones.append({"rect": rect, "key": "position", "max": max_off})

	var y: float = view_top - float(offset) * POS_SCROLL_STEP
	for gi in range(_lu_position_groups.size()):
		y = _draw_position_group(_lu_position_groups[gi] as Dictionary, inner_x, usable, y, view_top, view_bottom)
		if gi < _lu_position_groups.size() - 1:
			y += POS_GROUP_GAP


# 概要モード (「上位3名」既定): 守備位置ごとのカードを 5列 × 可変行のグリッドで敷き詰める。
# スクロールなしで全守備位置を一望できることが目的なので、枚数が変わっても (DH無しで9枚等)
# 列数は固定のまま行数だけ ceil(枚数/5) で伸縮させる。
func _draw_position_cards(rect: Rect2) -> void:
	var inner_x: float = rect.position.x + 18.0
	var usable: float = rect.size.x - 36.0
	var view_top: float = rect.position.y + 60.0
	var view_bottom: float = rect.end.y - 14.0
	var n: int = _lu_position_groups.size()
	if n == 0:
		return

	var cols: int = LU_CARD_COLS
	var rows: int = int(ceil(float(n) / float(cols)))
	var card_w: float = (usable - float(cols - 1) * LU_CARD_GAP) / float(cols)
	var card_h: float = (view_bottom - view_top - float(rows - 1) * LU_CARD_GAP) / float(rows)
	for i in range(n):
		var col: int = i % cols
		var row: int = int(i / cols)
		var cx: float = inner_x + float(col) * (card_w + LU_CARD_GAP)
		var cy: float = view_top + float(row) * (card_h + LU_CARD_GAP)
		_draw_position_card(Rect2(cx, cy, card_w, card_h), _lu_position_groups[i] as Dictionary)


# 1守備位置分のカード。枠線なし PANEL_2 塗り (post カードと同じ意匠) + ヘッダ下ヘアライン。
func _draw_position_card(card: Rect2, group: Dictionary) -> void:
	_round(card, PANEL_2, Color.TRANSPARENT, 8, 0)
	var pos: int = int(group.get("pos", 0))
	var is_pitcher_group: bool = bool(group.get("is_pitcher", false))
	var rows: Array = group.get("rows", []) as Array

	var badge_w: float = 36.0
	_chip(Rect2(card.position.x + LU_CARD_PAD_X, card.position.y + 9.0, badge_w, 22.0), _position_group_badge_label(pos), _pos_color(pos))
	_text("%d試合" % int(group.get("total_games", 0)), Vector2(card.position.x + LU_CARD_PAD_X + badge_w + 8.0, card.position.y + 26.0), 12, MUTED)
	_line(Vector2(card.position.x + LU_CARD_PAD_X, card.position.y + LU_CARD_HEADER_H), Vector2(card.end.x - LU_CARD_PAD_X, card.position.y + LU_CARD_HEADER_H), HAIRLINE, 1.0)

	if rows.is_empty():
		_text("記録なし", Vector2(card.position.x + LU_CARD_PAD_X, card.position.y + LU_CARD_ROW_START + 18.0), 12, FAINT)
		return

	# 列 x 座標はカード単位で1回だけ決め、列見出しと選手行の両方がそれを参照する
	# (行ごとに文字幅で計算し直すと、桁数の違いで列がずれるため)。
	var layout: Dictionary = _card_column_layout(card, rows, is_pitcher_group)
	_draw_position_card_col_header(card, layout, is_pitcher_group)

	var top_n: int = mini(LU_CARD_TOP_N, rows.size())
	for i in range(top_n):
		var row: Dictionary = rows[i] as Dictionary
		var ry: float = card.position.y + LU_CARD_ROW_START + float(i) * LU_CARD_ROW_H
		_draw_position_card_row(card, ry, row, layout)


# カード内の列レイアウトを1回だけ算出する。各列の幅は見出しラベルと表示対象行(最大 LU_CARD_TOP_N件)
# の実測文字幅の最大値+ガター。右端(WAR)から左へ積み、名前列に残る幅を stats_left_x として返す。
# 優先度の低い項目(配列末尾、スタメン数は先頭固定で最後まで残る)から、名前の最大幅を確保できる
# まで削る (カード幅(約300px)に収まらない場合の縮退)。
func _card_column_layout(card: Rect2, rows: Array, is_pitcher_group: bool) -> Dictionary:
	var keys: Array = ["starts", "era", "war"] if is_pitcher_group else ["starts", "avg", "hr", "ops", "war"]
	var headers: Dictionary = CARD_HEADER_PITCHER if is_pitcher_group else CARD_HEADER_BATTER
	var top_n: int = mini(LU_CARD_TOP_N, rows.size())

	var col_w: Dictionary = {}
	for key_value in keys:
		var key: String = str(key_value)
		var w: float = _measure(str(headers.get(key, "")), 11)
		for i in range(top_n):
			w = maxf(w, _measure(_pos_cell_text(key, rows[i] as Dictionary), 12))
		col_w[key] = w + LU_CARD_STAT_GAP

	var name_w: float = 0.0
	for i in range(top_n):
		name_w = maxf(name_w, _measure(str((rows[i] as Dictionary).get("name", "-")), 12))
	var avail: float = card.size.x - LU_CARD_PAD_X * 2.0 - name_w - 6.0

	var shown: Array = keys.duplicate()
	while shown.size() > 1:
		var total: float = 0.0
		for key_value in shown:
			total += float(col_w[key_value])
		if total <= avail:
			break
		shown.remove_at(shown.size() - 1)

	var positions: Dictionary = {}
	var x: float = card.end.x - LU_CARD_PAD_X
	for i in range(shown.size() - 1, -1, -1):
		var key: String = str(shown[i])
		var w: float = float(col_w[key])
		positions[key] = {"right": x, "w": w}
		x -= w

	return {"keys": shown, "positions": positions, "stats_left_x": x}


# 列見出し行。意匠は基底 _draw_data_table のヘッダ (MUTED の小さい bold + 下端の細いルール) に
# 準じ、帯の塗りは足さない。x 座標は _card_column_layout が選手行と共有する。
func _draw_position_card_col_header(card: Rect2, layout: Dictionary, is_pitcher_group: bool) -> void:
	var headers: Dictionary = CARD_HEADER_PITCHER if is_pitcher_group else CARD_HEADER_BATTER
	var positions: Dictionary = layout["positions"] as Dictionary
	var header_top: float = card.position.y + LU_CARD_HEADER_H
	var ty: float = header_top + LU_CARD_COLHEAD_H - 6.0
	for key_value in layout["keys"] as Array:
		var key: String = str(key_value)
		var pos: Dictionary = positions[key] as Dictionary
		_text_right(str(headers.get(key, "")), float(pos["right"]), ty, 11, MUTED, float(pos["w"]), true)
	var line_y: float = header_top + LU_CARD_COLHEAD_H
	_line(Vector2(card.position.x + LU_CARD_PAD_X, line_y), Vector2(card.end.x - LU_CARD_PAD_X, line_y), HAIRLINE, 1.0)


# カード内の選手1行。数値は _card_column_layout の共有 x 座標で右詰めに並べ、名前はその左に
# 残った幅いっぱいへ左詰めで置く。表示テキスト/色は詳細モードの _pos_cell_text/_pos_cell_color を
# そのまま再利用し、2モード間で値・色の食い違いを防ぐ。当たり矩形は描画に使う row_rect を
# そのまま _lu_pos_row_hits へ積む (別式で組み直さない不変条件)。
func _draw_position_card_row(card: Rect2, y: float, row: Dictionary, layout: Dictionary) -> void:
	var pid: int = int(row.get("pid", 0))
	var row_rect: Rect2 = Rect2(card.position.x + 4.0, y, card.size.x - 8.0, LU_CARD_ROW_H)
	if pid > 0 and pid == _hover_pid:
		_round(row_rect, Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 0, 0)
		_round(Rect2(row_rect.position.x, row_rect.position.y, 3.0, row_rect.size.y), BLUE, Color.TRANSPARENT, 0, 0)

	var ty: float = y + LU_CARD_ROW_H * 0.5 + 5.0
	var positions: Dictionary = layout["positions"] as Dictionary
	for key_value in layout["keys"] as Array:
		var key: String = str(key_value)
		var pos: Dictionary = positions[key] as Dictionary
		_text_right(_pos_cell_text(key, row), float(pos["right"]), ty, 12, _pos_cell_color(key, row), float(pos["w"]))

	var name: String = str(row.get("name", "-"))
	var name_w: float = float(layout["stats_left_x"]) - card.position.x - LU_CARD_PAD_X - 6.0
	_text(name, Vector2(card.position.x + LU_CARD_PAD_X, ty), 12, TEXT, name_w, HORIZONTAL_ALIGNMENT_LEFT, true)

	if pid > 0:
		_lu_pos_row_hits.append({"rect": row_rect, "pid": pid})


# 1守備位置分のグループ (見出し + 列見出し + 選手行) を描き、次のグループの開始 y を返す。
# レイアウト上の y 送りは常に行うが、描画は「その要素が view_top..view_bottom に完全に収まる時だけ」
# 行う (どちらか一方でもはみ出す要素は描かず空白にする)。パネルには枠クリップが無いため、
# 半分だけ見える要素をそのまま描くとパネルの角丸背景の外へバッジ/文字がはみ出して浮いて見える。
# はみ出す要素を丸ごとスキップすることで解消する。
func _draw_position_group(group: Dictionary, inner_x: float, usable: float, y: float, view_top: float, view_bottom: float) -> float:
	var pos: int = int(group.get("pos", 0))
	var is_pitcher_group: bool = bool(group.get("is_pitcher", false))
	var rows: Array = group.get("rows", []) as Array

	if y >= view_top and y + POS_GROUP_HEADER_H <= view_bottom:
		var badge_w: float = 40.0
		_chip(Rect2(inner_x, y + 6.0, badge_w, 22.0), _position_group_badge_label(pos), _pos_color(pos))
		_text("%d試合" % int(group.get("total_games", 0)), Vector2(inner_x + badge_w + 10.0, y + 22.0), 13, MUTED)
		_line(Vector2(inner_x, y + POS_GROUP_HEADER_H - 4.0), Vector2(inner_x + usable, y + POS_GROUP_HEADER_H - 4.0), BORDER_SOFT, 1.0)
	y += POS_GROUP_HEADER_H

	var cols: Array = POS_PITCHER_COLUMNS if is_pitcher_group else POS_BATTER_COLUMNS
	if y >= view_top and y + POS_COL_HEADER_H <= view_bottom:
		_draw_pos_col_header(inner_x, usable, y, cols)
	y += POS_COL_HEADER_H

	if rows.is_empty():
		if y >= view_top and y + POS_ROW_H <= view_bottom:
			_text("記録なし", Vector2(inner_x + 8.0, y + 18.0), 13, FAINT)
		y += POS_ROW_H
		return y

	for row_value in rows:
		if y >= view_top and y + POS_ROW_H <= view_bottom:
			_draw_pos_player_row(inner_x, usable, y, cols, row_value as Dictionary)
		y += POS_ROW_H
	return y


# 守備位置別スタメン数パネルのグループ見出しバッジ文字。POS_SHORT は試合別打線の打順セル
# バッジとも共有しているため、投手グループの見出しに限り「先発」に差し替える (このパネルの
# 投グループはスタメン履歴由来=先発投手しか持たないデータであることを明示するため。
# 打順9番の投手バッジは打順上の守備位置表記なので "投" のまま変更しない)。
func _position_group_badge_label(pos: int) -> String:
	if pos == PSLineupHistory.POSITION_PITCHER:
		return "先発"
	return str(POS_SHORT.get(pos, "?"))


func _group_content_height(group: Dictionary) -> float:
	var row_count: int = max(1, (group.get("rows", []) as Array).size())
	return POS_GROUP_HEADER_H + POS_COL_HEADER_H + POS_ROW_H * float(row_count)


func _draw_pos_col_header(inner_x: float, usable: float, y: float, cols: Array) -> void:
	_round(Rect2(inner_x, y, usable, POS_COL_HEADER_H), PANEL_2, Color.TRANSPARENT, 0, 0)
	var ty: float = y + POS_COL_HEADER_H - 7.0
	for entry_value in _lineup_col_layout(cols, inner_x, usable):
		var entry: Dictionary = entry_value as Dictionary
		var col: Dictionary = entry["col"] as Dictionary
		var x: float = float(entry["x"])
		var w: float = float(entry["w"])
		if str(col.get("align", "r")) == "l":
			_text(str(col.get("title", "")), Vector2(x + 6.0, ty), 11, MUTED, w - 8.0, HORIZONTAL_ALIGNMENT_LEFT, true)
		else:
			_text_right(str(col.get("title", "")), x + w - 6.0, ty, 11, MUTED, w - 8.0, true)


# 選手1行分。行全体を当たり判定にする (この画面は1行=1選手なので、games panel のような
# セル単位の分割は不要。ホバー中の選手 (_hover_pid) と一致したら基底 _draw_data_table の
# is_self 行と同じ意匠 = 左端3px BLUEバー + α0.08 青地で強調する)。
func _draw_pos_player_row(inner_x: float, usable: float, y: float, cols: Array, row: Dictionary) -> void:
	var pid: int = int(row.get("pid", 0))
	if pid > 0 and pid == _hover_pid:
		_round(Rect2(inner_x, y, usable, POS_ROW_H), Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 0, 0)
		_round(Rect2(inner_x, y, 3.0, POS_ROW_H), BLUE, Color.TRANSPARENT, 0, 0)

	var ty: float = y + POS_ROW_H * 0.5 + 5.0
	for entry_value in _lineup_col_layout(cols, inner_x, usable):
		var entry: Dictionary = entry_value as Dictionary
		var col: Dictionary = entry["col"] as Dictionary
		var key: String = str(col.get("key", ""))
		var x: float = float(entry["x"])
		var w: float = float(entry["w"])
		var text: String = _pos_cell_text(key, row)
		var color: Color = _pos_cell_color(key, row)
		if str(col.get("align", "r")) == "l":
			_text(text, Vector2(x + 6.0, ty), 13, color, w - 10.0, HORIZONTAL_ALIGNMENT_LEFT, key == "name")
		else:
			_text_right(text, x + w - 6.0, ty, 13, color, w - 10.0)
	_line(Vector2(inner_x, y + POS_ROW_H), Vector2(inner_x + usable, y + POS_ROW_H), HAIRLINE, 1.0)

	if pid > 0:
		_lu_pos_row_hits.append({"rect": Rect2(inner_x, y, usable, POS_ROW_H), "pid": pid})


# 列幅の重み (w) を実ピクセルへ伸縮する (usable/Σw の factor は基底 _draw_data_table と同じ考え方)。
func _lineup_col_layout(cols: Array, inner_x: float, usable: float) -> Array:
	var sum_w: float = 0.0
	for col_value in cols:
		sum_w += float((col_value as Dictionary).get("w", 80.0))
	var factor: float = usable / sum_w if sum_w > 0.0 else 1.0
	var out: Array = []
	var cx: float = inner_x
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		var w: float = float(col.get("w", 80.0)) * factor
		out.append({"col": col, "x": cx, "w": w})
		cx += w
	return out


func _pos_cell_text(key: String, row: Dictionary) -> String:
	if key == "name":
		return str(row.get("name", "-"))
	if key == "starts":
		return str(int(row.get("starts", 0)))
	if not bool(row.get("has_record", false)):
		return "-"
	var played: bool = bool(row.get("played", false))
	match key:
		"games":
			return str(int(row.get("games", 0)))
		"pa":
			return str(int(row.get("pa", 0)))
		"avg":
			return _rate_short(float(row.get("avg", 0.0)))
		"hr":
			return str(int(row.get("hr", 0)))
		"rbi":
			return str(int(row.get("rbi", 0)))
		"sb":
			return str(int(row.get("sb", 0)))
		"obp":
			return _rate_short(float(row.get("obp", 0.0)))
		"ops":
			return _rate_short(float(row.get("ops", 0.0)))
		"bb":
			return str(int(row.get("bb", 0)))
		"so":
			return str(int(row.get("so", 0)))
		"woba":
			return _rate_short(float(row.get("woba", 0.0))) if played else "-"
		"wrc_plus":
			return str(int(round(float(row.get("wrc_plus", 0.0))))) if played else "-"
		"oaa":
			return "%+0.1f" % float(row.get("oaa", 0.0)) if played else "-"
		"war":
			return "%0.1f" % float(row.get("war", 0.0))
		"wins":
			return str(int(row.get("wins", 0)))
		"losses":
			return str(int(row.get("losses", 0)))
		"ip":
			return "%0.1f" % float(row.get("ip", 0.0))
		"era":
			return "%0.2f" % float(row.get("era", 0.0))
		"whip":
			return "%0.2f" % float(row.get("whip", 0.0))
		"k9":
			return "%0.2f" % float(row.get("k9", 0.0))
		_:
			return "-"


# 配色規約 ([[feedback_ui_color_conventions]]): WAR/wRC+/OAA は「高い=好」の±指標なので
# 能力段階色(優秀=青)ではなく緑=好/赤=悪の _pm_color 系。率成績は既存画面同様グレーディングしない。
func _pos_cell_color(key: String, row: Dictionary) -> Color:
	if key == "name" or key == "starts":
		return TEXT
	if not bool(row.get("has_record", false)):
		return FAINT
	var played: bool = bool(row.get("played", false))
	match key:
		"war":
			return _pm_color(float(row.get("war", 0.0)))
		"oaa":
			return _pm_color(float(row.get("oaa", 0.0))) if played else MUTED
		"wrc_plus":
			return _pm_color(float(row.get("wrc_plus", 0.0)) - 100.0) if played else MUTED
		"woba", "rbi", "sb", "obp", "losses":
			return MUTED
		_:
			return TEXT


# --- 試合別打線 ---

func _draw_games_panel(rect: Rect2) -> void:
	_panel(rect, "試合別打線")
	var inner_x: float = rect.position.x + 16.0
	var usable: float = rect.size.x - 32.0
	var date_w: float = 78.0
	var opp_w: float = 62.0
	var result_w: float = 78.0
	var slot_w: float = (usable - date_w - opp_w - result_w) / float(LINEUP_GAME_COLUMN_COUNT)

	var hy: float = rect.position.y + 60.0
	_round(Rect2(inner_x, hy - 18.0, usable, 26.0), PANEL_2, Color.TRANSPARENT, 0, 0)
	var cx: float = inner_x
	_text("日付", Vector2(cx + 4.0, hy), 11, MUTED, date_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	cx += date_w
	_text("相手", Vector2(cx + 4.0, hy), 11, MUTED, opp_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	cx += opp_w
	_text("結果", Vector2(cx + 4.0, hy), 11, MUTED, result_w - 6.0, HORIZONTAL_ALIGNMENT_LEFT, true)
	cx += result_w
	for slot_num in range(1, LINEUP_SLOT_COUNT + 1):
		_text(str(slot_num), Vector2(cx + 2.0, hy), 11, MUTED, slot_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER, true)
		cx += slot_w
	_text("先発", Vector2(cx + 2.0, hy), 11, MUTED, slot_w - 4.0, HORIZONTAL_ALIGNMENT_CENTER, true)
	var line_y: float = hy + 8.0
	_line(Vector2(inner_x, line_y), Vector2(rect.end.x - 16.0, line_y), BORDER, 1.5)

	if _lu_game_rows.is_empty():
		_text("記録がありません", Vector2(inner_x + 6.0, rect.position.y + rect.size.y * 0.5), 14, MUTED)
		return

	var row_top: float = line_y + 8.0
	var row_h: float = 34.0
	var area_h: float = rect.end.y - row_top - 10.0
	var visible: int = max(1, int(area_h / row_h))
	var max_off: int = max(0, _lu_game_rows.size() - visible)
	var offset: int = clampi(int(_lu_scroll.get("games", 0)), 0, max_off)
	_lu_scroll["games"] = offset
	if max_off > 0:
		_lu_scroll_zones.append({"rect": rect, "key": "games", "max": max_off})

	for vi in range(visible):
		var ri: int = offset + vi
		if ri >= _lu_game_rows.size():
			break
		var row: Dictionary = _lu_game_rows[ri] as Dictionary
		var ry: float = row_top + float(vi) * row_h
		_draw_game_row(inner_x, date_w, opp_w, result_w, slot_w, ry, row_h, row)
		_line(Vector2(inner_x, ry + row_h), Vector2(inner_x + usable, ry + row_h), HAIRLINE, 1.0)

	if max_off > 0:
		_text_right("%d / %d" % [min(offset + visible, _lu_game_rows.size()), _lu_game_rows.size()], rect.end.x - 14.0, rect.end.y - 8.0, 10, FAINT, 120.0)


func _draw_game_row(inner_x: float, date_w: float, opp_w: float, result_w: float, slot_w: float, ry: float, row_h: float, row: Dictionary) -> void:
	var cy: float = ry + row_h * 0.5 + 5.0
	var cx: float = inner_x
	_text(str(row.get("date_label", "")), Vector2(cx + 4.0, cy), 12, MUTED, date_w - 6.0)
	cx += date_w
	_text(str(row.get("opp_label", "")), Vector2(cx + 4.0, cy), 12, TEXT, opp_w - 6.0)
	cx += opp_w

	var result: String = str(row.get("result", ""))
	var symbol: String = "○" if result == "勝" else ("●" if result == "敗" else "△")
	_draw_result_mark(Vector2(cx + 11.0, ry + row_h * 0.5), 6.0, symbol, MUTED)
	var score_text: String = "%d-%d" % [int(row.get("score_for", 0)), int(row.get("score_against", 0))]
	_text(score_text, Vector2(cx + 24.0, cy), 12, TEXT, result_w - 26.0)
	cx += result_w

	var slots: Array = row.get("slots", []) as Array
	for slot_value in slots:
		var slot: Dictionary = slot_value as Dictionary
		var pid: int = int(slot.get("pid", 0))
		if pid > 0:
			var cell_rect: Rect2 = Rect2(cx, ry, slot_w, row_h)
			if pid == _hover_pid:
				# ホバー中の選手セルを全試合分ハイライト (基底 is_self 行と同じ言語 =
				# 左端3px BLUEバー + α0.08 青地)。当たり判定 (_lu_game_cell_hits) と同じ cell_rect を使うため
				# 強調表示とクリック/ホバー判定のジオメトリは常に一致する。
				_round(Rect2(cell_rect.position.x + 2.0, cell_rect.position.y + 2.0, cell_rect.size.x - 4.0, cell_rect.size.y - 4.0), Color(BLUE.r, BLUE.g, BLUE.b, 0.08), Color.TRANSPARENT, 4, 0)
				_round(Rect2(cell_rect.position.x + 2.0, cell_rect.position.y + 2.0, 3.0, cell_rect.size.y - 4.0), BLUE, Color.TRANSPARENT, 0, 0)
			var badge_w: float = 28.0
			_chip(Rect2(cx + 4.0, ry + row_h * 0.5 - 10.0, badge_w, 20.0), str(slot.get("pos_label", "")), _pos_color(int(slot.get("pos", 1))))
			_text(str(slot.get("name", "")), Vector2(cx + 4.0 + badge_w + 6.0, cy), 12, TEXT, slot_w - badge_w - 16.0)
			_lu_game_cell_hits.append({"rect": cell_rect, "pid": pid})
		else:
			_text("-", Vector2(cx, cy), 12, FAINT, slot_w, HORIZONTAL_ALIGNMENT_CENTER)
		cx += slot_w


# ============================================================ buttons

# ビュー切替チップ行の左端 x (base 座標、ヘッダ行)。チップは右端 1900 基準・108px幅・
# 116px刻みで左へ並ぶため、個数が増えるほど左端は左へ伸びる。ビューチップ自身の配置は
# 必ずこの関数を経由する (個数が変わっても home の他ヘッダボタンと同じ右端 1900 を保つ)。
func _view_chip_row_left() -> float:
	return 1900.0 - 116.0 * float(VIEW_CHIPS.size())


# 各ビュー固有の右上コンテンツ (通算記録の部門チップ、タイトル履歴の折返し判定) が右端の
# 基準にするコンテンツ領域の右端。ビュー切替チップはヘッダ行にあり y=96 の帯とは競合しない
# ため、単純に画面のコンテンツ右端 (TABLE_B/AWARD_RECT 等と同じ x=1900) を返せばよい。
func _content_right_x() -> float:
	return 1900.0


func _build_buttons() -> void:
	_clear_buttons()
	_build_nav_buttons()

	# ビュー切替チップ (ヘッダ行、home の「本日を終了」等と同じ y=22/高さ42/右端1900)。
	var vx: float = _view_chip_row_left()
	for chip_value in VIEW_CHIPS:
		var chip: Dictionary = chip_value as Dictionary
		var key: String = str(chip.get("key", ""))
		_add_button("view_%s" % key, str(chip.get("label", "")), Rect2(vx, 22, 108, 42),
			func() -> void: _set_view(key), "chip_active" if _view == key else "chip")
		vx += 116.0

	match _view:
		VIEW_YEAR:
			if _has_data and _archives.size() > 1:
				var at_newest: bool = _sel <= 0
				var at_oldest: bool = _sel >= _archives.size() - 1
				_add_button("year_prev", "◀", NAV_PREV,
					func() -> void: _step_year(1), "chip" if not at_oldest else "nav")
				_add_button("year_next", "▶", NAV_NEXT,
					func() -> void: _step_year(-1), "chip" if not at_newest else "nav")
		VIEW_CAREER:
			var career_bound: float = _content_right_x()
			_build_category_chips("bat", CAREER_BAT_CATEGORIES, _career_bat_key, CAREER_BAT_RECT.position.x, 108.0,
				func(key: String) -> void: _set_career_key(true, key), career_bound)
			_build_category_chips("pit", CAREER_PIT_CATEGORIES, _career_pit_key, CAREER_PIT_RECT.position.x, 108.0,
				func(key: String) -> void: _set_career_key(false, key), career_bound)
		VIEW_TITLES:
			var title_bound: float = _content_right_x()
			var tx: float = TITLE_TABLE_RECT.position.x
			var ty: float = 96.0
			for category_value in TITLE_HISTORY_CATEGORIES:
				var category: Dictionary = category_value as Dictionary
				var t_key: String = str(category.get("key", ""))
				var t_label: String = str(category.get("label", ""))
				var w: float = max(76.0, _measure(t_label, 12) + 30.0)
				if tx + w > title_bound:
					tx = TITLE_TABLE_RECT.position.x
					ty += 38.0
				_add_button("title_%s" % t_key, t_label, Rect2(tx, ty, w, 30),
					func() -> void: _set_title_key(t_key), "chip_active" if _title_key == t_key else "chip")
				tx += w + 8.0
		VIEW_LINEUP:
			_season_menu_button = _add_button("lineup_season_menu", "", _lineup_season_hotspot_rect(), _on_lineup_season_menu_pressed, "nav")
			_team_menu_button = _add_button("lineup_team_menu", "", _lineup_team_hotspot_rect(), _on_lineup_team_menu_pressed, "nav")
			_build_lineup_pos_mode_chips()

	_layout_buttons()


# 通算記録ビューの部門チップ (打者/投手テーブルの上に横並び)。既定は対象テーブル (rect) の左端
# 揃えだが、部門数が多く右端がビュー切替チップ行の領域 (right_bound) へ食い込む場合は、
# チップ群全体を right_bound 右端揃えへ寄せて避ける (投手側は5部門で幅が伸びやすく、テーブル数が
# 増えたり部門が増えたときにも同じ計算で自動的に避ける)。
func _build_category_chips(prefix: String, categories: Array, active_key: String, x: float, y: float, on_pick: Callable, right_bound: float = 1900.0) -> void:
	var widths: Array = []
	var total: float = 0.0
	for category_value in categories:
		var label: String = str((category_value as Dictionary).get("label", ""))
		var w: float = max(64.0, _measure(label, 12) + 28.0)
		widths.append(w)
		total += w
	if categories.size() > 1:
		total += 8.0 * float(categories.size() - 1)

	var cx: float = x
	if cx + total > right_bound:
		cx = right_bound - total

	for i in range(categories.size()):
		var category: Dictionary = categories[i] as Dictionary
		var key: String = str(category.get("key", ""))
		var label: String = str(category.get("label", ""))
		var w: float = float(widths[i])
		_add_button("%s_%s" % [prefix, key], label, Rect2(cx, y, w, 30),
			func() -> void: on_pick.call(key), "chip_active" if active_key == key else "chip")
		cx += w + 8.0


# 守備位置別スタメン数パネルのヘッダ右端に置く概要/詳細切替チップ。
# game_result の打席結果パネル (ビジター/ホーム切替) と同じ配置作法 = パネルヘッダ右に右詰め。
func _build_lineup_pos_mode_chips() -> void:
	var top3_label: String = "上位3名"
	var all_label: String = "全員"
	var w_all: float = max(64.0, _measure(all_label, 12) + 28.0)
	var w_top3: float = max(64.0, _measure(top3_label, 12) + 28.0)
	var rect: Rect2 = _lineup_position_rect()
	var x_all: float = rect.end.x - 12.0 - w_all
	var x_top3: float = x_all - 6.0 - w_top3
	var y: float = rect.position.y + 14.0
	_add_button("lu_pos_mode_top3", top3_label, Rect2(x_top3, y, w_top3, 28),
		func() -> void: _set_lineup_pos_mode(LU_POS_MODE_TOP3), "chip_active" if _lu_pos_mode == LU_POS_MODE_TOP3 else "chip")
	_add_button("lu_pos_mode_all", all_label, Rect2(x_all, y, w_all, 28),
		func() -> void: _set_lineup_pos_mode(LU_POS_MODE_ALL), "chip_active" if _lu_pos_mode == LU_POS_MODE_ALL else "chip")


# モード切替は表示のみの変更 (_lu_position_groups は _refresh_lineup で作った集計をそのまま使い回す
# = 再集計しない)。ホバー当たり矩形は _draw 冒頭で毎回リセットされるので、切替後も古い矩形は残らない。
func _set_lineup_pos_mode(mode: String) -> void:
	if _lu_pos_mode == mode:
		return
	_lu_pos_mode = mode
	_build_buttons()
	queue_redraw()


func _set_view(view: String) -> void:
	if _view == view:
		return
	_view = view
	if view == VIEW_TITLES:
		_build_title_history_rows()
	_build_buttons()
	queue_redraw()


func _set_career_key(batting: bool, key: String) -> void:
	if batting:
		_career_bat_key = key
	else:
		_career_pit_key = key
	_build_buttons()
	queue_redraw()


func _set_title_key(key: String) -> void:
	if _title_key == key:
		return
	_title_key = key
	_build_title_history_rows()
	_build_buttons()
	queue_redraw()


func _step_year(delta: int) -> void:
	var next_sel: int = clampi(_sel + delta, 0, max(0, _archives.size() - 1))
	if next_sel == _sel:
		return
	_sel = next_sel
	_refresh()
	_build_buttons()
	queue_redraw()


# ============================================================ スタメン履歴 入力 (ホバー/スクロール/プルダウン)

func _gui_input(event: InputEvent) -> void:
	if _view != VIEW_LINEUP:
		return
	if event is InputEventMouseButton and event.pressed:
		_update_transform()
		var base_pos: Vector2 = _to_base(event.position)
		match event.button_index:
			MOUSE_BUTTON_WHEEL_DOWN:
				if _lineup_scroll_at(base_pos, 1):
					accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				if _lineup_scroll_at(base_pos, -1):
					accept_event()
	elif event is InputEventMouseMotion:
		_update_transform()
		var pid: int = _lineup_pid_at(_to_base(event.position))
		if pid != _hover_pid:
			_hover_pid = pid
			queue_redraw()


func _to_base(pos: Vector2) -> Vector2:
	if _scale_f <= 0.0:
		return pos
	return (pos - _offset) / _scale_f


# 上段(守備位置別)・下段(試合別打線)のどちらの当たり判定にも同じ base_pos を突き合わせる。
# _draw はホバーごとに毎回走るため、_lu_pos_row_hits/_lu_game_cell_hits は直前の _draw で最新化されている。
# どちらのパネルで検出しても同じ _hover_pid を更新するので、相互ハイライトは自然に成立する。
func _lineup_pid_at(base_pos: Vector2) -> int:
	for hit_value in _lu_pos_row_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return int(hit["pid"])
	for hit_value in _lu_game_cell_hits:
		var hit: Dictionary = hit_value as Dictionary
		if (hit["rect"] as Rect2).has_point(base_pos):
			return int(hit["pid"])
	return 0


func _lineup_scroll_at(base_pos: Vector2, direction: int) -> bool:
	for zone_value in _lu_scroll_zones:
		var zone: Dictionary = zone_value as Dictionary
		if not (zone["rect"] as Rect2).has_point(base_pos):
			continue
		var key: String = str(zone.get("key", ""))
		var max_off: int = int(zone.get("max", 0))
		var current: int = clampi(int(_lu_scroll.get(key, 0)) + direction, 0, max_off)
		if current != int(_lu_scroll.get(key, 0)):
			_lu_scroll[key] = current
			queue_redraw()
		return true
	return false


func _on_lineup_season_menu_pressed() -> void:
	if _lu_seasons.is_empty():
		return
	var menu: PopupMenu = PopupMenu.new()
	for i in range(_lu_seasons.size()):
		var s: Dictionary = _lu_seasons[i] as Dictionary
		menu.add_item(_lineup_season_label(int(s.get("year", 0)), int(s.get("season_number", 0))), i)
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_lineup_season_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(LINEUP_SEASON_X, LINEUP_SEL_Y + 24.0))
	if _season_menu_button != null:
		anchor = _season_menu_button.global_position + Vector2(0.0, _season_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_lineup_season_selected(index: int) -> void:
	if index == _lu_sel_season_index or index < 0 or index >= _lu_seasons.size():
		return
	_lu_sel_season_index = index
	_refresh_lineup()
	_build_buttons()
	queue_redraw()


func _on_lineup_team_menu_pressed() -> void:
	var menu: PopupMenu = PopupMenu.new()
	for i in range(_team_ids.size()):
		var team: PSTeam = GameDb.get_team(int(_team_ids[i]))
		if team == null:
			continue
		if i > 0:
			var prev: PSTeam = GameDb.get_team(int(_team_ids[i - 1]))
			if prev != null and prev.league != team.league:
				menu.add_separator(team.league_label())
		else:
			menu.add_separator(team.league_label())
		menu.add_item("%s (%s)" % [team.name, team.short_name], int(_team_ids[i]))
	_style_popup(menu)
	add_child(menu)
	menu.id_pressed.connect(_on_lineup_team_selected)
	menu.popup_hide.connect(func() -> void:
		if is_instance_valid(menu):
			menu.queue_free()
	)
	var anchor: Vector2 = _p(Vector2(LINEUP_TEAM_X, LINEUP_SEL_Y + 24.0))
	if _team_menu_button != null:
		anchor = _team_menu_button.global_position + Vector2(0.0, _team_menu_button.size.y)
	menu.position = Vector2i(anchor.round())
	menu.reset_size()
	menu.popup()


func _on_lineup_team_selected(team_id: int) -> void:
	if team_id == _team_id or not _team_ids.has(team_id):
		return
	_team_id = team_id
	_refresh_lineup()
	_build_buttons()
	queue_redraw()


# ============================================================ aggregation

func _refresh() -> void:
	_archives = RecordStore.get_season_archives()
	_has_data = not _archives.is_empty()
	_rows_by_league = {}
	_post_champion_id = 0
	_post_by_stage = {}
	_award_cards = []
	_bat_rows = []
	_pit_rows = []
	_year_label = ""
	if not _has_data:
		return

	_sel = clampi(_sel, 0, _archives.size() - 1)
	var archive: PSSeasonArchive = _archives[_archives.size() - 1 - _sel] as PSSeasonArchive
	_year_label = "%d年 (第%d年目)" % [archive.year, archive.season_number]

	for league_row in LEAGUES:
		var key: String = str((league_row as Dictionary)["key"])
		_rows_by_league[key] = _build_league_rows(archive, key)

	_build_postseason(archive)
	_build_awards(archive)
	_build_title_history_rows()


# 全年度の選手レコードから通算リーダーとシーズン最高記録を部門別に構築する。
# 画面インスタンス生成ごとに1回だけ (10年×~900レコードで数ms、初回は RecordStore の
# 全履歴 hydrate が乗るため通算記録ビューを開いたときに限り実行する)。
func _build_career() -> void:
	if _career_built:
		return
	_career_built = true
	var career: Dictionary = {}          # player_id → {name, team_id, first, last, bat, pit}
	var season_bat: Dictionary = {}      # category key → Array[行]
	var season_pit: Dictionary = {}
	for category_value in CAREER_BAT_CATEGORIES:
		season_bat[str((category_value as Dictionary)["key"])] = []
	for category_value in CAREER_PIT_CATEGORIES:
		season_pit[str((category_value as Dictionary)["key"])] = []

	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null:
			continue
		var entry: Dictionary = career.get(record.player_id, {}) as Dictionary
		if entry.is_empty():
			entry = {"name": record.name, "team_id": record.team_id, "first": record.year, "last": record.year,
				"bat": PSBatterStats.new(), "pit": PSPitcherStats.new()}
		entry["first"] = mini(int(entry["first"]), record.year)
		if record.year >= int(entry["last"]):
			# 通算テーブルの球団表示は最終在籍年 (最新シーズン) の所属とする。
			entry["last"] = record.year
			entry["name"] = record.name
			entry["team_id"] = record.team_id
		(entry["bat"] as PSBatterStats).add_from(record.batter_stats)
		(entry["pit"] as PSPitcherStats).add_from(record.pitcher_stats)
		career[record.player_id] = entry

		for category_value in CAREER_BAT_CATEGORIES:
			var category: Dictionary = category_value as Dictionary
			var key: String = str(category["key"])
			var qualifier: String = str(category.get("qualifier", ""))
			if qualifier == "pa" and record.batter_stats.plate_appearances < _season_qualifier_pa(record):
				continue
			var value: float = _batter_metric_value(record.batter_stats, key)
			if qualifier.is_empty() and value <= 0.0:
				continue
			(season_bat[key] as Array).append(_season_bat_entry(record, value))
		for category_value in CAREER_PIT_CATEGORIES:
			var category: Dictionary = category_value as Dictionary
			var key: String = str(category["key"])
			var qualifier: String = str(category.get("qualifier", ""))
			if qualifier == "outs" and record.pitcher_stats.outs_pitched < _season_qualifier_outs(record):
				continue
			var value: float = _pitcher_metric_value(record.pitcher_stats, key)
			if qualifier.is_empty() and value <= 0.0:
				continue
			(season_pit[key] as Array).append(_season_pit_entry(record, value))

	for category_value in CAREER_BAT_CATEGORIES:
		var category: Dictionary = category_value as Dictionary
		var key: String = str(category["key"])
		_career_bat_by_key[key] = _career_leader_rows(career, "bat", category)
		_season_bat_by_key[key] = _season_best_rows(season_bat[key] as Array, bool(category.get("ascending", false)))
	for category_value in CAREER_PIT_CATEGORIES:
		var category: Dictionary = category_value as Dictionary
		var key: String = str(category["key"])
		_career_pit_by_key[key] = _career_leader_rows(career, "pit", category)
		_season_pit_by_key[key] = _season_best_rows(season_pit[key] as Array, bool(category.get("ascending", false)))


# 打者/投手のカウント系はフィールドをそのまま、率系 (打率/OPS, 防御率/WHIP) は導出メソッドを読む。
func _batter_metric_value(stats: PSBatterStats, key: String) -> float:
	match key:
		"average":
			return stats.batting_average()
		"ops":
			return stats.ops()
		_:
			return float(stats.get(key))


func _pitcher_metric_value(stats: PSPitcherStats, key: String) -> float:
	match key:
		"era":
			return stats.era()
		"whip":
			return stats.whip()
		_:
			return float(stats.get(key))


# 文脈列 (試合/打率/本/打点、登板/勝/防御率/奪三振) のセル値。通算/シーズンどちらの行にも使う。
func _batter_context_cells(stats: PSBatterStats) -> Dictionary:
	return {"g": stats.games, "avg": stats.batting_average(), "hr": stats.home_runs, "rbi": stats.runs_batted_in}


func _pitcher_context_cells(stats: PSPitcherStats) -> Dictionary:
	return {"g": stats.games, "wins": stats.wins, "era": stats.era(), "so": stats.strikeouts}


func _season_bat_entry(record: PSPlayerSeasonRecord, value: float) -> Dictionary:
	var row: Dictionary = {
		"value": value, "player": record.name, "year": "%d年" % record.year,
		"team": _team_short(record.team_id), "color": _team_color(record.team_id),
	}
	row.merge(_batter_context_cells(record.batter_stats))
	return row


func _season_pit_entry(record: PSPlayerSeasonRecord, value: float) -> Dictionary:
	var row: Dictionary = {
		"value": value, "player": record.name, "year": "%d年" % record.year,
		"team": _team_short(record.team_id), "color": _team_color(record.team_id),
	}
	row.merge(_pitcher_context_cells(record.pitcher_stats))
	return row


# rankings_screen.gd の規定打席/規定投球回 (所属球団のその時点の試合数基準) をそのまま流用する。
# get_team_record は record.year/season_number だけで引けるため、過去年度でも current_season を
# 必要としない。
func _season_qualifier_pa(record: PSPlayerSeasonRecord) -> int:
	return int(max(1, ceil(SEASON_QUALIFIER_PA_PER_TEAM_GAME * float(_team_games_for_record(record)))))


func _season_qualifier_outs(record: PSPlayerSeasonRecord) -> int:
	return int(max(1, ceil(SEASON_QUALIFIER_OUTS_PER_TEAM_GAME * float(_team_games_for_record(record)))))


func _team_games_for_record(record: PSPlayerSeasonRecord) -> int:
	var team_record: PSTeamSeasonRecord = RecordStore.get_team_record(record.team_id, record.year, record.season_number)
	return int(team_record.stats.games) if team_record != null else 0


func _career_leader_rows(career: Dictionary, stats_key: String, category: Dictionary) -> Array:
	var key: String = str(category["key"])
	var ascending: bool = bool(category.get("ascending", false))
	var qualifier: String = str(category.get("qualifier", ""))
	var entries: Array = []
	for player_id in career.keys():
		var entry: Dictionary = career[player_id] as Dictionary
		var bat_stats: PSBatterStats = entry["bat"] as PSBatterStats
		var pit_stats: PSPitcherStats = entry["pit"] as PSPitcherStats
		if qualifier == "pa" and bat_stats.plate_appearances < CAREER_MIN_PA:
			continue
		if qualifier == "outs" and pit_stats.outs_pitched < CAREER_MIN_OUTS:
			continue
		var value: float = _batter_metric_value(bat_stats, key) if stats_key == "bat" else _pitcher_metric_value(pit_stats, key)
		if qualifier.is_empty() and value <= 0.0:
			continue
		var row: Dictionary = {
			"value": value, "player": str(entry["name"]),
			"span": "%d-%d" % [int(entry["first"]), int(entry["last"])],
			"team": _team_short(int(entry["team_id"])), "color": _team_color(int(entry["team_id"])),
		}
		row.merge(_batter_context_cells(bat_stats) if stats_key == "bat" else _pitcher_context_cells(pit_stats))
		entries.append(row)
	entries.sort_custom(func(a, b) -> bool:
		var av: float = float((a as Dictionary)["value"])
		var bv: float = float((b as Dictionary)["value"])
		return av < bv if ascending else av > bv
	)
	var rows: Array = []
	for i in range(mini(CAREER_TOP_N, entries.size())):
		var row: Dictionary = entries[i] as Dictionary
		row["rank"] = i + 1
		rows.append(row)
	return rows


func _season_best_rows(entries: Array, ascending: bool = false) -> Array:
	entries.sort_custom(func(a, b) -> bool:
		var av: float = float((a as Dictionary)["value"])
		var bv: float = float((b as Dictionary)["value"])
		return av < bv if ascending else av > bv
	)
	var rows: Array = []
	for i in range(mini(CAREER_TOP_N, entries.size())):
		var row: Dictionary = entries[i] as Dictionary
		row["rank"] = i + 1
		rows.append(row)
	return rows


# 選択中のタイトル部門について、年度×両リーグの受賞者一覧を作る (新しい順)。PSAwards は player_id
# しか持たないため、受賞年の PSPlayerSeasonRecord から都度、球団と成績値を復元する。
func _build_title_history_rows() -> void:
	_title_rows = []
	var archives: Array = RecordStore.get_season_archives()
	for i in range(archives.size() - 1, -1, -1):
		var archive: PSSeasonArchive = archives[i] as PSSeasonArchive
		var league1_id: int = 0
		var league2_id: int = 0
		if archive.awards != null:
			var a: PSAwards = archive.awards
			if _title_key == "mvp":
				league1_id = a.mvp_league1_player_id
				league2_id = a.mvp_league2_player_id
			elif _title_key == "rookie":
				league1_id = a.rookie_league1_player_id
				league2_id = a.rookie_league2_player_id
			elif _title_key.begins_with("bat_"):
				var bat_key: String = _title_key.substr(4)
				league1_id = int((a.batting_titles.get("league1", {}) as Dictionary).get(bat_key, 0))
				league2_id = int((a.batting_titles.get("league2", {}) as Dictionary).get(bat_key, 0))
			elif _title_key.begins_with("pit_"):
				var pit_key: String = _title_key.substr(4)
				league1_id = int((a.pitching_titles.get("league1", {}) as Dictionary).get(pit_key, 0))
				league2_id = int((a.pitching_titles.get("league2", {}) as Dictionary).get(pit_key, 0))
		var row: Dictionary = {"year": "%d年" % archive.year}
		var p1: Dictionary = _title_player_cell(league1_id, archive)
		var p2: Dictionary = _title_player_cell(league2_id, archive)
		row["p1_name"] = p1["name"]
		row["p1_team"] = p1["team"]
		row["p1_team_color"] = p1["team_color"]
		row["p1_value"] = p1["value"]
		row["p2_name"] = p2["name"]
		row["p2_team"] = p2["team"]
		row["p2_team_color"] = p2["team_color"]
		row["p2_value"] = p2["value"]
		_title_rows.append(row)


# 受賞者1名分のセル ({name, team, team_color, value})。受賞年のレコードが引けない (引退などで
# 消失) 場合は名前だけ解決し、球団・記録は "-" にフォールバックする。
func _title_player_cell(pid: int, archive: PSSeasonArchive) -> Dictionary:
	var cell: Dictionary = {"name": _player_label(pid), "team": "-", "team_color": MUTED, "value": "-"}
	if pid <= 0:
		return cell
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, archive.year, archive.season_number)
	if record == null:
		return cell
	cell["team"] = _team_short(record.team_id)
	cell["team_color"] = _team_color(record.team_id)
	cell["value"] = _title_value_from_record(record)
	return cell


# MVP/新人王は単一部門を持たないため代表的な成績ラインを出す。他部門はその部門の成績値のみ。
func _title_value_from_record(record: PSPlayerSeasonRecord) -> String:
	if _title_key == "mvp" or _title_key == "rookie":
		return _title_representative_line(record)
	if _title_key.begins_with("bat_"):
		return _title_batting_value_text(record.batter_stats, _title_key.substr(4))
	if _title_key.begins_with("pit_"):
		return _title_pitching_value_text(record.pitcher_stats, _title_key.substr(4))
	return "-"


func _title_representative_line(record: PSPlayerSeasonRecord) -> String:
	if record.is_pitcher():
		return "%d勝 / 防%0.2f" % [record.pitcher_stats.wins, record.pitcher_stats.era()]
	return "%s / %d本 / %d点" % [_rate_short(record.batter_stats.batting_average()), record.batter_stats.home_runs, record.batter_stats.runs_batted_in]


func _title_batting_value_text(stats: PSBatterStats, key: String) -> String:
	match key:
		"average":
			return _rate_short(stats.batting_average())
		"home_runs":
			return "%d本" % stats.home_runs
		"rbi":
			return "%d点" % stats.runs_batted_in
		"stolen_bases":
			return "%d盗" % stats.stolen_bases
		"hits":
			return "%d安打" % stats.hits
		_:
			return "-"


func _title_pitching_value_text(stats: PSPitcherStats, key: String) -> String:
	match key:
		"wins":
			return "%d勝" % stats.wins
		"era":
			return "%0.2f" % stats.era()
		"strikeouts":
			return "%d奪三振" % stats.strikeouts
		"saves":
			return "%dS" % stats.saves
		"holds":
			return "%dH" % stats.holds
		"win_rate":
			return _rate_short(_pitcher_win_rate(stats))
		_:
			return "-"


func _pitcher_win_rate(stats: PSPitcherStats) -> float:
	var denom: int = stats.wins + stats.losses
	return float(stats.wins) / float(denom) if denom > 0 else 0.0


func _build_league_rows(archive: PSSeasonArchive, league_key: String) -> Array:
	var entries: Array = []
	for team_id_str in archive.standings.keys():
		var team: PSTeam = GameDb.get_team(int(team_id_str))
		if team == null or team.league != league_key:
			continue
		entries.append({"team": team, "entry": archive.standings[team_id_str] as Dictionary})

	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ea: Dictionary = (a as Dictionary)["entry"] as Dictionary
		var eb: Dictionary = (b as Dictionary)["entry"] as Dictionary
		var pa: float = _pct(ea)
		var pb: float = _pct(eb)
		if is_equal_approx(pa, pb):
			return int(ea.get("wins", 0)) > int(eb.get("wins", 0))
		return pa > pb
	)

	var self_id: int = AppState.selected_team_id
	var leader: Dictionary = ((entries[0] as Dictionary)["entry"] as Dictionary) if not entries.is_empty() else {}
	var rows: Array = []
	var rank: int = 1
	for entry_value in entries:
		var ev: Dictionary = entry_value as Dictionary
		var team: PSTeam = ev["team"] as PSTeam
		var e: Dictionary = ev["entry"] as Dictionary
		var w: int = int(e.get("wins", 0))
		var l: int = int(e.get("losses", 0))
		var d: int = int(e.get("draws", 0))
		var rs: int = int(e.get("runs_scored", 0))
		var ra: int = int(e.get("runs_allowed", 0))
		rows.append({
			"rank": rank, "team": team.name, "color": team.color,
			"is_self": team.id == self_id, "is_leader": rank == 1,
			"g": w + l + d, "w": w, "l": l, "d": d, "pct": _pct(e),
			"gb": 0.0 if (rank == 1 or leader.is_empty()) else _game_back(leader, e),
			"rs": rs, "ra": ra, "diff": rs - ra,
		})
		rank += 1
	return rows


func _build_postseason(archive: PSSeasonArchive) -> void:
	if archive.postseason == null:
		return
	var post: PSPostseasonResult = archive.postseason
	_post_champion_id = post.champion_team_id
	for stage_key in PSPostseasonResult.STAGE_KEYS:
		var s: Dictionary = post.stage_dict(stage_key)
		if s.is_empty() or not bool(s.get("completed", false)):
			continue
		_post_by_stage[stage_key] = {
			"top_id": int(s.get("top_id", 0)),
			"chal_id": int(s.get("challenger_id", 0)),
			"winner_id": int(s.get("winner_id", 0)),
			"top_wins": int(s.get("top_wins_final", 0)),
			"chal_wins": int(s.get("challenger_wins_final", 0)),
			"advantage": int(s.get("advantage_wins", 0)),
			"games": s.get("games", []) as Array,
		}


func _build_awards(archive: PSSeasonArchive) -> void:
	if archive.awards == null:
		return
	var a: PSAwards = archive.awards
	_award_cards = [
		{"title": "MVP", "league": "第1リーグ", "accent": AMBER, "player": _player_label(a.mvp_league1_player_id)},
		{"title": "MVP", "league": "第2リーグ", "accent": AMBER, "player": _player_label(a.mvp_league2_player_id)},
		{"title": "新人王", "league": "第1リーグ", "accent": BLUE, "player": _player_label(a.rookie_league1_player_id)},
		{"title": "新人王", "league": "第2リーグ", "accent": BLUE, "player": _player_label(a.rookie_league2_player_id)},
	]
	_bat_rows = _build_title_rows(a.batting_titles, BATTING_TITLE_LABELS, PSAwards.BATTING_CATEGORIES)
	_pit_rows = _build_title_rows(a.pitching_titles, PITCHING_TITLE_LABELS, PSAwards.PITCHING_CATEGORIES)


func _build_title_rows(titles_by_league: Dictionary, label_map: Dictionary, order: Array) -> Array:
	var league1: Dictionary = titles_by_league.get("league1", {}) as Dictionary
	var league2: Dictionary = titles_by_league.get("league2", {}) as Dictionary
	var rows: Array = []
	for key in order:
		rows.append({
			"label": str(label_map.get(key, key)),
			"league1": _player_label(int(league1.get(key, 0))),
			"league2": _player_label(int(league2.get(key, 0))),
		})
	return rows


# ============================================================ スタメン履歴 data

func _build_team_order() -> void:
	_team_ids = []
	for league_key in ["league1", "league2"]:
		var ids: Array = []
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team.league == league_key:
				ids.append(team.id)
		ids.sort()
		for id_value in ids:
			_team_ids.append(int(id_value))


func _refresh_lineup() -> void:
	_lu_seasons = PSLineupHistory.available_seasons()
	_lu_rows = []
	_lu_pos_starts = {}
	_lu_game_rows = []
	_lu_position_groups = []
	_lu_name_cache = {}
	_lu_cur_year = 0
	_lu_cur_season_number = 0
	_hover_pid = 0
	if _lu_seasons.is_empty() or _team_ids.is_empty():
		return

	_lu_sel_season_index = clampi(_lu_sel_season_index, 0, _lu_seasons.size() - 1)
	var sel: Dictionary = _lu_seasons[_lu_sel_season_index] as Dictionary
	_lu_cur_year = int(sel.get("year", 0))
	_lu_cur_season_number = int(sel.get("season_number", 0))

	if not _team_ids.has(_team_id):
		_team_id = int(_team_ids[0])
	_lu_rows = PSLineupHistory.team_lineups(_lu_cur_year, _lu_cur_season_number, _team_id)
	_lu_pos_starts = PSLineupHistory.starts_by_position(_lu_rows)
	_lu_game_rows = _build_lineup_game_rows(_lu_rows)
	_lu_position_groups = _build_position_groups(_lu_pos_starts)


# 守備位置別テーブルの元データ。位置ごとに {pos, total_games, is_pitcher, rows} を積む
# (DH はエントリが無ければグループごと省略 = 従来挙動を維持)。総試合数はその位置の
# 全選手のスタメン数合計 (=その位置にスタメンが立った延べ試合数)。
func _build_position_groups(pos_starts: Dictionary) -> Array:
	var groups: Array = []
	for pos_value in LINEUP_TOP_POSITIONS:
		var pos: int = int(pos_value)
		var entries: Array = pos_starts.get(pos, []) as Array
		if pos == PSLineupHistory.POSITION_DH and entries.is_empty():
			continue
		var total_games: int = 0
		for entry_value in entries:
			total_games += int((entry_value as Dictionary).get("starts", 0))
		var is_pitcher_group: bool = pos == PSLineupHistory.POSITION_PITCHER
		var rows: Array = []
		for entry_value in entries:
			var entry: Dictionary = entry_value as Dictionary
			rows.append(_position_player_row(int(entry.get("player_id", 0)), int(entry.get("starts", 0)), is_pitcher_group))
		groups.append({"pos": pos, "total_games": total_games, "is_pitcher": is_pitcher_group, "rows": rows})
	return groups


# 選手1名分の成績行。取得元は選択中の年度・シーズンのレコード (RecordStore.get_player_record)。
# 記録が無い選手 (トレード/引退で当該年度のレコードが引けない) は has_record=false にし、
# 表示側 (_pos_cell_text/_pos_cell_color) が各セルを "-" にする。
func _position_player_row(pid: int, starts: int, is_pitcher_group: bool) -> Dictionary:
	var row: Dictionary = {"pid": pid, "name": _resolve_lineup_name(pid), "starts": starts, "has_record": false}
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(pid, _lu_cur_year, _lu_cur_season_number)
	if record == null:
		return row
	row["has_record"] = true
	var ctx: Dictionary = _league_ctx_for(_lu_cur_year, _lu_cur_season_number)
	var war: Dictionary = WarCalculator.season_war(record, ctx)
	row["war"] = float(war.get("war", 0.0))
	if is_pitcher_group:
		var ps: PSPitcherStats = record.pitcher_stats
		row["games"] = ps.games if ps != null else 0
		row["wins"] = ps.wins if ps != null else 0
		row["losses"] = ps.losses if ps != null else 0
		row["ip"] = ps.innings_pitched() if ps != null else 0.0
		row["era"] = ps.era() if ps != null else 0.0
		row["whip"] = ps.whip() if ps != null else 0.0
		row["so"] = ps.strikeouts if ps != null else 0
		row["bb"] = ps.walks if ps != null else 0
		row["k9"] = ps.strikeouts_per_nine() if ps != null else 0.0
	else:
		var bs: PSBatterStats = record.batter_stats
		var ad: PSAdvancedStats = record.advanced_stats
		var played: bool = ad != null and ad.plate_appearances > 0
		row["games"] = bs.games if bs != null else 0
		row["pa"] = bs.plate_appearances if bs != null else 0
		row["avg"] = bs.batting_average() if bs != null else 0.0
		row["hr"] = bs.home_runs if bs != null else 0
		row["rbi"] = bs.runs_batted_in if bs != null else 0
		row["sb"] = bs.stolen_bases if bs != null else 0
		row["obp"] = bs.on_base_percentage() if bs != null else 0.0
		row["ops"] = bs.ops() if bs != null else 0.0
		row["bb"] = bs.walks if bs != null else 0
		row["so"] = bs.strikeouts if bs != null else 0
		row["played"] = played
		row["woba"] = ad.woba() if played else 0.0
		row["wrc_plus"] = ad.wrc_plus() if played else 0.0
		row["oaa"] = (float(ad.oaa_by_zone.get("infield", 0.0)) + float(ad.oaa_by_zone.get("outfield", 0.0))) if played else 0.0
	return row


# WAR のリーグ文脈は重いので年度ごとに1回だけ構築してキャッシュする (player_detail_screen の
# _league_ctx_for/_war_ctx_cache と同じパターン、キャッシュ本体は _lu_war_ctx_cache)。
# 呼び出しは _refresh_lineup() 内 (_position_player_row 経由) に限定し、_draw からは呼ばない。
func _league_ctx_for(year: int, season_number: int) -> Dictionary:
	var key: String = "%d-%d" % [year, season_number]
	if not _lu_war_ctx_cache.has(key):
		_lu_war_ctx_cache[key] = WarCalculator.build_league_context(year, season_number)
	return _lu_war_ctx_cache[key] as Dictionary


# team_lineups は day/game_index 昇順で返るため、逆順に積んで新しい試合から並べる。
func _build_lineup_game_rows(rows: Array) -> Array:
	var out: Array = []
	for i in range(rows.size() - 1, -1, -1):
		var row: Dictionary = rows[i] as Dictionary
		var slots_by_num: Dictionary = {}
		for slot_value in (row.get("slots", []) as Array):
			var slot_dict: Dictionary = slot_value as Dictionary
			slots_by_num[int(slot_dict.get("slot", 0))] = slot_dict

		var slot_cells: Array = []
		for slot_num in range(1, LINEUP_SLOT_COUNT + 1):
			var matched: Dictionary = slots_by_num.get(slot_num, {}) as Dictionary
			var pid: int = int(matched.get("pid", 0))
			var pos: int = int(matched.get("pos", 0))
			slot_cells.append({
				"pid": pid,
				"pos": pos,
				"pos_label": str(POS_SHORT.get(pos, "-")),
				"name": _resolve_lineup_name(pid) if pid > 0 else "-",
			})

		# 先発投手セルを打順スロットの末尾に積む (要望3)。非DH の試合では打順9番と同一選手に
		# なるが、それは仕様どおりの重複表示 (先発投手が打順にも入っているため) なので消さない。
		# 同じ配列に載せることで _draw_game_row のループ・ホバー当たり判定をそのまま流用できる。
		var starter_pid: int = int(row.get("starter_pitcher_id", 0))
		slot_cells.append({
			"pid": starter_pid,
			"pos": PSLineupHistory.POSITION_PITCHER,
			"pos_label": str(POS_SHORT.get(PSLineupHistory.POSITION_PITCHER, "-")),
			"name": _resolve_lineup_name(starter_pid) if starter_pid > 0 else "-",
		})

		var opp: PSTeam = GameDb.get_team(int(row.get("opponent_id", 0)))
		var is_home: bool = str(row.get("home_away", "")) == "home"
		out.append({
			"date_label": SeasonCalendar.label_for_date(str(row.get("date", ""))),
			"opp_label": "%s%s" % ["vs" if is_home else "@", opp.short_name if opp != null else "-"],
			"result": str(row.get("result", "")),
			"score_for": int(row.get("score_for", 0)),
			"score_against": int(row.get("score_against", 0)),
			"slots": slot_cells,
		})
	return out


# RecordStore の当該年度レコード → 見つからなければ GameDb (現存選手のみ) の順で選手名を解決する
# (ability_stats/game_result/player_detail と同じフォールバック順)。選択中の年度に閉じてキャッシュする。
func _resolve_lineup_name(player_id: int) -> String:
	if player_id <= 0:
		return "-"
	if _lu_name_cache.has(player_id):
		return str(_lu_name_cache[player_id])
	var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player_id, _lu_cur_year, _lu_cur_season_number)
	var resolved: String
	if record != null:
		resolved = record.name
	else:
		var player: PSPlayer = GameDb.get_player(player_id)
		resolved = player.name if player != null else "#%d" % player_id
	_lu_name_cache[player_id] = resolved
	return resolved


# ============================================================ helpers

func _pct(entry: Dictionary) -> float:
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	return float(w) / float(max(1, w + l))


func _game_back(leader: Dictionary, entry: Dictionary) -> float:
	var lw: int = int(leader.get("wins", 0))
	var ll: int = int(leader.get("losses", 0))
	var w: int = int(entry.get("wins", 0))
	var l: int = int(entry.get("losses", 0))
	return float((lw - w) + (l - ll)) / 2.0


func _player_label(player_id: int) -> String:
	if player_id <= 0:
		return "(該当なし)"
	for record_row in RecordStore.player_records.values():
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.player_id == player_id:
			return record.name
	var player: PSPlayer = GameDb.get_player(player_id)
	if player != null:
		return player.name
	return "ID %d" % player_id


func _team_short(team_id: int) -> String:
	if team_id <= 0:
		return "-"
	var team: PSTeam = GameDb.get_team(team_id)
	return team.short_name if team != null else "-"


func _team_color(team_id: int) -> Color:
	var team: PSTeam = GameDb.get_team(team_id)
	return team.color if team != null else MUTED
