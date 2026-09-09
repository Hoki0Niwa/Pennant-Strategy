extends RefCounted
class_name PSRainoutService

# 一軍の雨天中止。**気象はモデル化せず、中止の有無だけを 1 回の確率抽選で決める**
# ([[project_rainout_postpone]])。プレイヤーが観測できるのは「その試合が流れたか否か」だけで、
# ゲームに効くのは中止そのものではなく ①ローテのやりくり ②消化試合数の不均衡
# ③終盤の過密日程 の 3 点だから。振替は [[PSRescheduleService]] が持つ。
#
# ## 抽選が Rng レーンを使わない理由
# 中止の判定は `RandomNumberGenerator` をこの場で作り、試合の同一性から導いたシードで引く。
# グローバル `Rng` のストリームを一切消費しないため、
# - 並列 (レーンごとに独立 seed) と逐次で結果が変わらない ([[project_game_day_parallelization]])。
# - **未来の試合の結果を先に問い合わせられる** = 予報を日程画面から引ける。
# 同じ試合・同じ順延回数なら何度呼んでも同じ答えになる (純粋関数)。
#
# ## 較正
# 実 NPB はリーグ全体で年 20〜30 試合 (2025年: セ 13 + パ 17 = 30 / 858 試合)、
# 屋外球団は年 5〜8 試合、ドーム球団は年 0.5 試合以下。月別は台風期の 9〜10 月が最多で、
# 梅雨の 6 月はむしろ少なく 7 月が最少 (2016-2025 の 10 年集計)。
# `MONTHLY_OPEN_RATE` はその**実水準**を置いてあり、`FEEL_SCALE` で体感ぶんだけ薄めている。
# 量を変えたいときは `FEEL_SCALE` だけを触る (月別の形は実データなので動かさない)。

# 屋外球場の1試合あたり中止率 (実 NPB 水準)。これに FEEL_SCALE を掛けたものが実効値。
# 加重平均で約 7.1% → 屋外ホーム 429 試合 × 7.1% ≒ 30 試合/シーズンで実 NPB に一致する。
const MONTHLY_OPEN_RATE: Dictionary = {
	3: 0.090,
	4: 0.100,
	5: 0.060,
	6: 0.050,
	7: 0.036,
	8: 0.060,
	9: 0.120,
	10: 0.120,
}
const DEFAULT_OPEN_RATE: float = 0.060

# 体感の調整ノブ。1.0 で実 NPB 水準 (年 30 試合)、0.5 で約半分 (年 15 試合前後 =
# 屋外球団あたり 2.5 試合/年)。**「中止は体感少なめ」という方針でこの値を選んでいる**。
const FEEL_SCALE: float = 0.5

# 平年の降水確率 (%)。**中止率とは別物** — 表示専用で、遠い日の予報が寄っていく先。
# 梅雨の 6 月は「雨っぽいが中止は少ない」が実データなので、6 月だけ確率を高くして中止率は低い。
const CLIMATOLOGY_RAIN_PCT: Dictionary = {
	3: 20.0,
	4: 25.0,
	5: 25.0,
	6: 45.0,
	7: 35.0,
	8: 30.0,
	9: 30.0,
	10: 20.0,
}
const DEFAULT_CLIMATOLOGY_PCT: float = 25.0

# 予報の確度。index = 試合日までの残り日数 (0=当日)、3 以上は末尾で頭打ち。
# 1.0 は「結果どおりに出す」= 当日は中止なら 60〜100%、開催なら 0〜60% になる。
const FORECAST_CONFIDENCE: Array[float] = [1.0, 0.78, 0.58, 0.40]
# これより先の試合は予報を出さない (実際の天気予報の週間予報に合わせる)。
const FORECAST_MAX_LEAD_DAYS: int = 6
# 中止する試合に出す降水確率の下限 (%)。当日は主催球団が中止を発表する日なので例外的に 100 固定。
const FORECAST_CANCEL_MIN_PCT: float = 70.0
# 開催する試合に出しうる降水確率の上限 (%)。ここまで振れるので「予報が外れる」余地が残る。
const FORECAST_PLAY_MAX_PCT: float = 60.0
# 開催側の分布を低い方へ寄せる指数。大きいほど 0〜10% に集まる。
const FORECAST_PLAY_SKEW: float = 2.2

# シードの混合に使う塩。用途ごとに変えて 2 つの抽選 (中止判定 / 予報のノイズ) を無相関にする。
const SALT_CANCEL: int = 0x5261696E
const SALT_FORECAST: int = 0x466F7265

# 雨天中止を丸ごと止めるスイッチ。**調査/較正ツールとテスト専用**で、通常プレイでは常に true。
# 日程が動くと試合のレーン割当が変わり、既存の逐次比較や成績ベースラインと突き合わせられなくなる。
# セーブには入れない (「中止の無い世界」のセーブが生まれると日程の前提が崩れるため)。
static var enabled: bool = true


# この試合が中止になる確率 (0.0〜1.0)。ドームは 0。
static func cancel_probability(game: Dictionary) -> float:
	if not _is_open_air(game):
		return 0.0
	var month: int = _month_of(game)
	return float(MONTHLY_OPEN_RATE.get(month, DEFAULT_OPEN_RATE)) * FEEL_SCALE


# この試合が中止になるか。純粋関数 — 同じ試合・同じ順延回数なら常に同じ答えを返す。
static func will_be_postponed(season: PSSeason, game: Dictionary) -> bool:
	if not enabled:
		return false
	var probability: float = cancel_probability(game)
	if probability <= 0.0:
		return false
	return _roll(season, game, SALT_CANCEL) < probability


# 予報 1 件。UI はこれだけを見ればよい。
#   kind = "roof"  … ドームなので雨に左右されない (chance は使わない)
#   kind = "none"  … 予報の対象外 (遠すぎる / 日程が無い)
#   kind = "rain"  … chance = 降水確率 (%、10刻み)、certain = 当日ぶんで確定しているか
static func forecast(season: PSSeason, game: Dictionary) -> Dictionary:
	if season == null or game.is_empty():
		return {"kind": "none", "chance": 0, "certain": false}
	if not _is_open_air(game):
		return {"kind": "roof", "chance": 0, "certain": true}
	var lead_days: int = int(game.get("day", 0)) - season.current_day
	if lead_days < 0 or lead_days > FORECAST_MAX_LEAD_DAYS:
		return {"kind": "none", "chance": 0, "certain": false}

	var confidence: float = FORECAST_CONFIDENCE[min(lead_days, FORECAST_CONFIDENCE.size() - 1)]
	var noise: float = _roll(season, game, SALT_FORECAST)
	var postponed: bool = will_be_postponed(season, game)
	var outcome_pct: float
	if postponed:
		# 当日は「中止発表」なので 100 固定。前日以前は幅を持たせ、空振りの予報と重なる余地を残す。
		outcome_pct = 100.0 if lead_days == 0 else lerpf(FORECAST_CANCEL_MIN_PCT, 100.0, noise)
	else:
		outcome_pct = pow(noise, FORECAST_PLAY_SKEW) * FORECAST_PLAY_MAX_PCT
	# 遠い日ほど平年値へ寄せる = 中止する試合もしない試合も同じような数字になり、当てられなくなる。
	var climatology: float = float(CLIMATOLOGY_RAIN_PCT.get(_month_of(game), DEFAULT_CLIMATOLOGY_PCT))
	var pct: float = lerpf(climatology, outcome_pct, confidence)
	return {
		"kind": "rain",
		"chance": int(round(clampf(pct, 0.0, 100.0) / 10.0) * 10),
		"certain": lead_days == 0,
	}


# 指定日の未消化試合を判定し、中止ぶんを振替へ回す。
# 戻り値の "postponed" は [[PSRescheduleService]] が作った振替の記録 (順位表やUIの通知用)。
# **schedule はここで並び替わるので、呼び出し側は当日の index を作り直すこと。**
static func apply_to_day(season: PSSeason, day: int) -> Dictionary:
	var postponed: Array = []
	if season == null or not enabled:
		return {"postponed": postponed}
	# 判定と振替を分ける: 振替は schedule を再整列するため、走査中に index が動いてしまう。
	var targets: Array = []
	for game_row in season.schedule:
		var game: Dictionary = game_row as Dictionary
		if bool(game.get("played", false)) or int(game.get("day", 0)) != day:
			continue
		if will_be_postponed(season, game):
			targets.append(game)
	for game_row in targets:
		var entry: Dictionary = PSRescheduleService.postpone(season, game_row as Dictionary)
		if not entry.is_empty():
			postponed.append(entry)
	return {"postponed": postponed}


# 中止の抽選と予報のノイズが引く一様乱数。グローバル Rng を汚さないよう毎回ローカルに作る。
static func _roll(season: PSSeason, game: Dictionary, salt: int) -> float:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _seed_for(season, game, salt)
	return rng.randf()


# 試合の同一性から決まるシード。**順延しても変わらない値だけ**を混ぜ、順延回数で振り直す
# (振替試合がまた流れることはあるが、同じ日に何度も引き直されることはない)。
static func _seed_for(season: PSSeason, game: Dictionary, salt: int) -> int:
	var key: int = int(season.schedule_bucket_seed)
	key = key * 1000003 + season.year
	key = key * 31 + season.season_number
	key = key * 131 + int(game.get("series_id", 0))
	key = key * 17 + int(game.get("series_game_no", 0))
	key = key * 13 + int(game.get("home_team_id", 0))
	key = key * 7 + int(game.get("away_team_id", 0))
	key = key * 1000033 + int(game.get("postponed_count", 0))
	return key ^ salt


static func _is_open_air(game: Dictionary) -> bool:
	var home: PSTeam = GameDb.get_team(int(game.get("home_team_id", 0)))
	# 球団が引けないときは中止させない (ツールの合成日程などで誤って流さないため)。
	return home != null and not home.has_dome()


static func _month_of(game: Dictionary) -> int:
	var date_text: String = str(game.get("date", ""))
	if date_text.length() < 7:
		return 0
	return int(date_text.substr(5, 2))
