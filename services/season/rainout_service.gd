extends RefCounted
class_name PSRainoutService

# 一軍の雨天。**気象はモデル化せず、雨が試合に影響するかどうかを 1 回の確率抽選で決める**
# ([[project_rainout_postpone]])。プレイヤーが観測できるのは結果だけで、ゲームに効くのは
# ①ローテのやりくり ②消化試合数の不均衡 ③終盤の過密日程 の 3 点だから。
#
# 結末は 3 つ。振替は [[PSRescheduleService]] が持つ。
#   cancel   … 試合前に中止。振替日へ回す
#   called   … 5 回以降で打ち切り = 降雨コールド。**成立**するので記録も勝敗も通常どおり
#   no_game  … 5 回未満で打ち切り = ノーゲーム。**全記録が無効**になり後日初回から再試合
#
# ## 抽選が Rng レーンを使わない理由
# 判定は `RandomNumberGenerator` をこの場で作り、試合の同一性から導いたシードで引く。
# グローバル `Rng` のストリームを一切消費しないため、
# - 並列 (レーンごとに独立 seed) と逐次で結果が変わらない ([[project_game_day_parallelization]])。
# - **未来の試合の結果を先に問い合わせられる** = 予報を日程画面から引ける。
# 同じ試合・同じ順延回数なら何度呼んでも同じ答えになる (純粋関数)。
#
# ## 較正 (2026-09-10、NPB 公式ボックススコア 2,613 試合の実測)
# 2023-2025 のレギュラーシーズン全試合の回別得点と注記 (【雨天のためコールドゲーム】等) を
# 集計した実数。**推測ではなく一次資料の数値**なので、動かすときは根拠を持って動かすこと。
#   中止 26.7 / コールド 5.7 / ノーゲーム 2.0 (いずれも 1 シーズンあたり、リーグ全体)
#   屋外球場は 1,337 試合中 68 中止 (5.1%)、ドームは 1,276 試合中 12 (0.94%)
#   ※ ドームが 0 でないのは地方球場開催があるため。本作は地方開催を持たないのでドーム 0 で整合する。

# 雨が試合に影響する確率 (屋外球場・1 試合あたり)。実測の月別中止率を
# PRE_GAME_CANCEL_SHARE で割り戻した値 = 「中止 + 試合中の中断」の合計。
# 加重平均は約 7.0% で、実測の 91/1337 = 6.8% に対応する。
# **月別の形は実測なので動かさない。量を変えるときは FEEL_SCALE だけを触る。**
# 3 月は実測 20 試合で中止 0 だが母数不足なので 4 月と同値、10 月は予備日期間なので 9 月と同値。
const MONTHLY_RAIN_RATE: Dictionary = {
	3: 0.114,
	4: 0.114,
	5: 0.111,
	6: 0.046,
	7: 0.039,
	8: 0.064,
	9: 0.036,
	10: 0.036,
}
const DEFAULT_RAIN_RATE: float = 0.064

# 体感の調整ノブ。1.0 で実 NPB 水準 (中止 22 / コールド 5.5 / ノーゲーム 1.9 per season。
# 中止が実測 26.7 に届かないのは地方球場開催を持たないぶん)。
# **0.5 = 「中止は体感少なめ」というユーザー方針。**
const FEEL_SCALE: float = 0.5

# 雨に影響された試合のうち、試合開始前に中止が決まる割合。実測 68 / (68 + 23) = 0.747。
const PRE_GAME_CANCEL_SHARE: float = 0.747

# 試合中に打ち切られたときの「成立イニング数」の分布 (2023-2025 の実測 23 件)。
# **4 回がゼロなのは偶然ではない** — 2〜3 回で見切るか、あと 1 回で成立する 5 回まで粘るかの
# 二択になる審判運用の痕跡で、一様分布にすると再現できない特徴。
const INTERRUPTION_INNINGS: Array[int] = [2, 3, 5, 6, 7, 8]
const INTERRUPTION_WEIGHTS: Array[int] = [3, 3, 8, 5, 3, 1]

# 正式試合の成立回。これ未満で打ち切るとノーゲーム (公認野球規則 7.01)。
const OFFICIAL_GAME_INNINGS: int = 5

const OUTCOME_NONE: String = "none"
const OUTCOME_CANCEL: String = "cancel"
const OUTCOME_CALLED: String = "called"
const OUTCOME_NO_GAME: String = "no_game"

# 平年の降水確率 (%)。**中止率とは別物** — 表示専用で、遠い日の予報が寄っていく先。
# 梅雨の 6 月は「雨っぽいが中止は少ない」ので、6 月だけ確率を高くして中止率は低い。
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
const FORECAST_CONFIDENCE: Array[float] = [1.0, 0.78, 0.58, 0.40]
# これより先の試合は予報を出さない (実際の週間予報に合わせる)。
const FORECAST_MAX_LEAD_DAYS: int = 6
# 雨にやられる試合に出す降水確率の下限 (%)。当日は例外 (下の forecast を参照)。
const FORECAST_HIT_MIN_PCT: float = 70.0
# 試合が無事に終わる試合に出しうる降水確率の上限 (%)。予報が外れる余地を残す。
const FORECAST_MISS_MAX_PCT: float = 60.0
# 無事に終わる側の分布を低い方へ寄せる指数。大きいほど 0〜10% に集まる。
const FORECAST_MISS_SKEW: float = 2.2
# 当日 (lead 0) の表示。中止は発表済みなので 100、試合が始まってから降られる場合は 90。
const FORECAST_TODAY_CANCEL_PCT: float = 100.0
const FORECAST_TODAY_INTERRUPT_PCT: float = 90.0

# シードの混合に使う塩。用途ごとに変えて各抽選を無相関にする。
const SALT_RAIN: int = 0x5261696E
const SALT_SPLIT: int = 0x53706C74
const SALT_INNING: int = 0x496E6E67
const SALT_FORECAST: int = 0x466F7265

# 雨天の影響を丸ごと止めるスイッチ。**調査/較正ツールとテスト専用**で、通常プレイでは常に true。
# 日程が動くと試合のレーン割当が変わり、既存の逐次比較や成績ベースラインと突き合わせられなくなる。
# セーブには入れない (「雨の無い世界」のセーブが生まれると日程の前提が崩れるため)。
static var enabled: bool = true


# この試合が雨にやられる確率 (0.0〜1.0)。中止・コールド・ノーゲームの合計。ドームは 0。
static func rain_probability(game: Dictionary) -> float:
	if not _is_open_air(game):
		return 0.0
	var month: int = _month_of(game)
	return float(MONTHLY_RAIN_RATE.get(month, DEFAULT_RAIN_RATE)) * FEEL_SCALE


# この試合の結末。純粋関数 — 同じ試合・同じ順延回数なら常に同じ答えを返す。
#   { "kind": OUTCOME_*, "innings": int }  innings は called / no_game のときの成立回。
static func rain_outcome(season: PSSeason, game: Dictionary) -> Dictionary:
	if not enabled or season == null or game.is_empty():
		return {"kind": OUTCOME_NONE, "innings": 0}
	var probability: float = rain_probability(game)
	if probability <= 0.0:
		return {"kind": OUTCOME_NONE, "innings": 0}
	if _roll(season, game, SALT_RAIN) >= probability:
		return {"kind": OUTCOME_NONE, "innings": 0}
	if _roll(season, game, SALT_SPLIT) < PRE_GAME_CANCEL_SHARE:
		return {"kind": OUTCOME_CANCEL, "innings": 0}
	var innings: int = _interruption_inning(season, game)
	var kind: String = OUTCOME_CALLED if innings >= OFFICIAL_GAME_INNINGS else OUTCOME_NO_GAME
	return {"kind": kind, "innings": innings}


# 試合開始前に中止になるか。日程側 (apply_to_day) が使う。
static func will_be_cancelled(season: PSSeason, game: Dictionary) -> bool:
	return str(rain_outcome(season, game).get("kind", OUTCOME_NONE)) == OUTCOME_CANCEL


# 試合が打ち切られる回。打ち切られないなら 0。シミュレータが max_innings に流す。
static func called_after_inning(season: PSSeason, game: Dictionary) -> int:
	var outcome: Dictionary = rain_outcome(season, game)
	var kind: String = str(outcome.get("kind", OUTCOME_NONE))
	if kind == OUTCOME_CALLED or kind == OUTCOME_NO_GAME:
		return int(outcome.get("innings", 0))
	return 0


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
	var kind: String = str(rain_outcome(season, game).get("kind", OUTCOME_NONE))
	var outcome_pct: float
	if kind == OUTCOME_NONE:
		outcome_pct = pow(noise, FORECAST_MISS_SKEW) * FORECAST_MISS_MAX_PCT
	elif lead_days == 0:
		# 当日。中止は主催球団が発表済みなので確定表示、コールド/ノーゲームは試合が始まるので
		# 「かなり危ない」に留める。
		outcome_pct = FORECAST_TODAY_CANCEL_PCT if kind == OUTCOME_CANCEL else FORECAST_TODAY_INTERRUPT_PCT
	else:
		outcome_pct = lerpf(FORECAST_HIT_MIN_PCT, 100.0, noise)
	# 遠い日ほど平年値へ寄せる = やられる試合も無事な試合も似た数字になり、当てられなくなる。
	var climatology: float = float(CLIMATOLOGY_RAIN_PCT.get(_month_of(game), DEFAULT_CLIMATOLOGY_PCT))
	var pct: float = lerpf(climatology, outcome_pct, confidence)
	return {
		"kind": "rain",
		"chance": int(round(clampf(pct, 0.0, 100.0) / 10.0) * 10),
		"certain": lead_days == 0,
	}


# 指定日の未消化試合のうち**試合前に中止するもの**を振替へ回す。
# コールド / ノーゲームは試合を実際に回してから決まるのでここでは触らない。
# 戻り値の "postponed" は [[PSRescheduleService]] が作った振替の記録。
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
		if will_be_cancelled(season, game):
			targets.append(game)
	for game_row in targets:
		var entry: Dictionary = PSRescheduleService.postpone(season, game_row as Dictionary, OUTCOME_CANCEL)
		if not entry.is_empty():
			postponed.append(entry)
	return {"postponed": postponed}


# 打ち切られる回を実測の分布から引く。
static func _interruption_inning(season: PSSeason, game: Dictionary) -> int:
	var total: int = 0
	for weight in INTERRUPTION_WEIGHTS:
		total += weight
	var pick: float = _roll(season, game, SALT_INNING) * float(total)
	var accumulated: float = 0.0
	for index in range(INTERRUPTION_INNINGS.size()):
		accumulated += float(INTERRUPTION_WEIGHTS[index])
		if pick < accumulated:
			return INTERRUPTION_INNINGS[index]
	return INTERRUPTION_INNINGS[INTERRUPTION_INNINGS.size() - 1]


# 各抽選が引く一様乱数。グローバル Rng を汚さないよう毎回ローカルに作る。
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
	# 球団が引けないときは雨にやられない (ツールの合成日程などで誤って流さないため)。
	return home != null and not home.has_dome()


static func _month_of(game: Dictionary) -> int:
	var date_text: String = str(game.get("date", ""))
	if date_text.length() < 7:
		return 0
	return int(date_text.substr(5, 2))
