extends RefCounted
class_name PSRescheduleService

# 中止試合の振替 (順延)。実装の重心はここ — 中止の判定自体は [[PSRainoutService]] の 1 行の抽選で、
# 難しいのは「143 試合を必ず消化させながら、実 NPB と同じ場所へ押し込む」方 ([[project_rainout_postpone]])。
#
# ## 振替先 (NPB 公式の試合結果 2023-2025 の実測)
# 1. **リーグ戦はシーズン終盤の追加日程へ回す。** 中止 89 件のうち、シーズン途中の月曜 (移動日) で
#    消化されたのは 1 割ほどで、残りは 9 月下旬〜10 月上旬に集まる。消化が終盤まで持ち越されるので、
#    中止の多い屋外球団ほど消化試合数が遅れ、最終戦の日付も球団ごとにずれる
#    (実測はリーグで最初と最後の球団の最終戦が平均 3.8 日差)。
# 2. **交流戦は直後の空き日で消化する。** 期間が固定なので、交流戦中の月曜で吸収する。
# 3. 追加日程はクライマックスシリーズの手前 (`POSTSEASON_GAP_DAYS`) で打ち止め。そこまでに空きが
#    無ければ 2. と同じく直後の空き日へ回す。
# 4. ダブルヘッダーはレギュラーシーズンでは 1998 年を最後に行われていない (2020年のコロナ禍を除く)。
#    → **同日に同一チーム 2 試合を作らない**制約はそのまま守る。
#
# ## 実装
# 試合は配列から消さず `day` / `date` を振替日へ書き換えて `PSSchedule.sort_by_day` で再整列する。
# これだけでローテ ([[project_starter_rotation_weekly]]) と `advance_current_day` はそのまま追随する
# (`record_rotation_start` は実際に消化した試合でしか呼ばれないので、中止日に最終登板日も進まない)。
#
# 元の日付には試合が残らないので、カレンダーに「中止」を出すための台帳を `season.rainouts` に積む。
#
# ⚠️ 再整列で**消化済み試合の index が動いてはいけない** — 詳細ログは schedule の index を
# ファイル名にしている (`game_logs/g<index>.json`) ので、動くと過去の試合ログが別の試合に化ける。
# `sort_by_day` の比較キー (day, series_id, series_game_no) は試合ごとに一意なので整列は決定的で、
# 順延した試合は必ず未消化ブロックの中だけで動く。回帰は
# `test_postponing_does_not_move_played_game_indices`。

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

# シーズン最終試合日の翌日から確保する予備日の日数。実 NPB も全日程終了後に追加日程を置く。
const RESERVE_DAYS: int = 5
# 予備日も埋まったときに、さらに何日まで後ろへ伸ばすか。143 試合の消化を保証するための最後の逃げ道で、
# 通常のシーズンではここまで来ない (来ているなら中止率が高すぎる)。
const OVERFLOW_DAYS: int = 30
# これ以上続けて試合の無い日が並んだら「リーグ全体の中断期間」とみなし、振替先にしない。
# 月曜の移動日は 1 日なので候補に残り、オールスター休みと交流戦後の休養カードは除外される。
const LEAGUE_BREAK_MIN_DAYS: int = 3
# リーグ戦の振替を探し始める位置 = 当初の最終試合日の何日前か。大きくするほど 9 月の空き日
# (月曜の移動日や 2 連戦の週の休養日) へ早めに押し込まれて終盤が過密になり、小さくするほど
# 最終戦の後ろへ並んで、最終戦の日付が球団ごとに大きくずれる。
const LATE_WINDOW_DAYS: int = 7
# クライマックスシリーズ開幕の何日前までを追加日程に使えるか。2 ならレギュラーシーズンの最終戦と
# CS の間に最低 1 日空く。
const POSTSEASON_GAP_DAYS: int = 2


# 1 試合を振替に回す。`game` は `season.schedule` の要素そのもの (Dictionary は参照なので直接書き換わる)。
# `kind` は台帳に残す理由 (`PSRainoutService.OUTCOME_CANCEL` = 試合前の中止 /
# `OUTCOME_NO_GAME` = 5 回未満で打ち切られて記録ごと無効になった試合)。UI の表示分けに使う。
# 戻り値は台帳に積んだ記録。振替先が見つからなければ空 Dictionary を返し、日程は変更しない。
static func postpone(season: PSSeason, game: Dictionary, kind: String = "cancel") -> Dictionary:
	if season == null or game.is_empty() or bool(game.get("played", false)):
		return {}
	var from_day: int = int(game.get("day", 0))
	var makeup_day: int = find_makeup_day(season, game, from_day)
	if makeup_day <= from_day:
		push_warning("PSRescheduleService: no makeup day for game on day %d" % from_day)
		return {}

	var from_date: String = str(game.get("date", ""))
	var makeup_date: String = SeasonCalendar.date_for_season_day(season, makeup_day)
	var entry: Dictionary = {
		"day": from_day,
		"date": from_date,
		"kind": kind,
		"away_team_id": int(game.get("away_team_id", 0)),
		"home_team_id": int(game.get("home_team_id", 0)),
		"makeup_day": makeup_day,
		"makeup_date": makeup_date,
	}

	# 試合側が持つのは順延回数だけ。「いつ流れたか」は台帳 (season.rainouts) の役目で、
	# 両方に持つと二重管理になる (台帳は 2 度目以降の順延も 1 件ずつ積む)。
	game["postponed_count"] = int(game.get("postponed_count", 0)) + 1
	game["day"] = makeup_day
	game["date"] = makeup_date
	PSSchedule.sort_by_day(season.schedule)

	season.rainouts.append(entry)
	return entry


# 振替先の day を探す。見つからなければ from_day を返す。
# リーグ戦は終盤の窓 (late_window_start_day〜latest_makeup_day) の最初の空き日。交流戦と、
# 窓が埋まっているときは from_day の翌日から前方へ走査する — カード中の他日は両チームとも
# 試合が入っているので、最初に空くのは直後の移動日になる。
static func find_makeup_day(season: PSSeason, game: Dictionary, from_day: int) -> int:
	var busy_days: Dictionary = _busy_days_by_team(season, game)
	var games_by_day: Dictionary = _game_counts_by_day(season)
	var last_day: int = _last_scheduled_day(season)
	var limit: int = last_day + RESERVE_DAYS + OVERFLOW_DAYS

	if not bool(game.get("is_interleague", false)):
		var late_start: int = max(from_day + 1, late_window_start_day(season))
		var late_limit: int = min(limit, latest_makeup_day(season))
		var late_day: int = _first_open_day(game, busy_days, games_by_day, late_start, late_limit, last_day)
		if late_day > 0:
			return late_day
	# 前方走査は CS の手前で止めない。手前に空きがあれば先にそこが見つかり、無いときだけ
	# CS 側へ伸びる (143 試合の消化を CS の日程より優先する)。
	var near_day: int = _first_open_day(game, busy_days, games_by_day, from_day + 1, limit, last_day)
	return near_day if near_day > 0 else from_day


# リーグ戦の振替を探し始める day (当初の最終試合日の LATE_WINDOW_DAYS 日前)。
static func late_window_start_day(season: PSSeason) -> int:
	return _last_scheduled_day(season) - LATE_WINDOW_DAYS


# 追加日程に使える最後の day。クライマックスシリーズ開幕の POSTSEASON_GAP_DAYS 日前。
static func latest_makeup_day(season: PSSeason) -> int:
	var cs_start: String = PostseasonService.cs1_start_date(season.year)
	return SeasonCalendar.season_day_for_date(season, cs_start) - POSTSEASON_GAP_DAYS


# start_day〜limit で両チームとも試合が無い最初の day。無ければ 0。
# 予備日 (当初の最終試合日より後) は無条件に使える。シーズン中はリーグ全体の中断期間を避ける。
static func _first_open_day(
	game: Dictionary, busy_days: Dictionary, games_by_day: Dictionary, start_day: int, limit: int, last_day: int
) -> int:
	var away_id: int = int(game.get("away_team_id", 0))
	var home_id: int = int(game.get("home_team_id", 0))
	for day in range(start_day, limit + 1):
		if _is_team_busy(busy_days, away_id, day) or _is_team_busy(busy_days, home_id, day):
			continue
		if day <= last_day and _is_league_break_day(games_by_day, day, last_day):
			continue
		return day
	return 0


# 振替対象の試合を除いた「チームごとに埋まっている day」。消化済みの試合も枠を占有する。
static func _busy_days_by_team(season: PSSeason, exclude_game: Dictionary) -> Dictionary:
	var busy: Dictionary = {}
	for game_row in season.schedule:
		var other: Dictionary = game_row as Dictionary
		# 参照一致で除く (Dictionary の == は中身の比較なので、同カードの別試合まで落ちてしまう)。
		if is_same(other, exclude_game):
			continue
		var day: int = int(other.get("day", 0))
		_mark_busy(busy, int(other.get("away_team_id", 0)), day)
		_mark_busy(busy, int(other.get("home_team_id", 0)), day)
	return busy


static func _mark_busy(busy: Dictionary, team_id: int, day: int) -> void:
	var days: Dictionary = busy.get(team_id, {}) as Dictionary
	days[day] = true
	busy[team_id] = days


static func _is_team_busy(busy: Dictionary, team_id: int, day: int) -> bool:
	return (busy.get(team_id, {}) as Dictionary).has(day)


static func _game_counts_by_day(season: PSSeason) -> Dictionary:
	var counts: Dictionary = {}
	for game_row in season.schedule:
		var day: int = int((game_row as Dictionary).get("day", 0))
		counts[day] = int(counts.get(day, 0)) + 1
	return counts


# 予備日の起点になる「当初の」最終試合日。**順延した試合は数えない** — 数えると振替が末尾へ
# 落ちるたびに last_day が伸び、予備日 5 日枠が実質無制限にずれ続ける。
static func _last_scheduled_day(season: PSSeason) -> int:
	var last_day: int = 0
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if int(game.get("postponed_count", 0)) > 0:
			continue
		last_day = max(last_day, int(game.get("day", 0)))
	return last_day


# その日が「リーグ全体の中断期間」に含まれるか。試合の無い日が LEAGUE_BREAK_MIN_DAYS 日以上
# 続いていればオールスター休みか交流戦後の休養カードなので、振替先にしない。
static func _is_league_break_day(games_by_day: Dictionary, day: int, last_day: int) -> bool:
	if int(games_by_day.get(day, 0)) > 0:
		return false
	var span: int = 1
	var back: int = day - 1
	while back >= 1 and int(games_by_day.get(back, 0)) == 0:
		span += 1
		back -= 1
	var forward: int = day + 1
	while forward <= last_day and int(games_by_day.get(forward, 0)) == 0:
		span += 1
		forward += 1
	return span >= LEAGUE_BREAK_MIN_DAYS
