extends RefCounted
class_name PSPerformanceReference

# 選手評価 (PSBatterForm / PSPitcherForm) が表示能力と成績を同じ σ スケールに載せるための基準分布を、
# **その時点の母集団から実測**して返す。固定値を持たないので、バランス較正や長期セーブでの
# リーグ環境ドリフトが起きても打者の位置付けが古い基準のままにならない。
#
# 基準は 2 系統:
# - ratings = そのシーズンの支配下野手の表示能力分布。能力スナップショットはシーズン中ほぼ動かない。
# - stats   = 規定到達打者の率成績分布。**進行中のシーズンは母集団が育っていない**ので、
#             十分な標本が集まっている直近の過去シーズンまで遡って使う。
#
# ## alignment: 2 つのスケールのゼロ点を揃える
# ratings の母集団 (支配下野手全体) と stats の母集団 (規定到達打者) は同じではない。
# 素朴に両者を σ 化すると「平均的な支配下野手 = 能力 0」なのに「その打撃成績は規定到達打者平均を
# 下回る = 成績 マイナス」となり、**成績を見るほど下振れ扱いになる系統バイアス**が出る。
# バイアスは打席数(信頼度)に比例するのでレギュラーほど不利になり、スタメン選定が壊れる。
# そこで stats 側に `alignment` (= その成績母集団が能力スケール上のどこに居るかの平均) を持たせ、
# 成績指標を能力スケールへ平行移動する。これで「能力どおりの成績」がちょうど差分 0 になる。
#
# どちらも「完了した情報」しか見ないため中身が試合中に変化せず、プリウォームで凍結できる。
# これが重要な理由: 試合日は WorkerThreadPool で並列実行されるため、遅延書き込みのキャッシュを
# 複数スレッドが同時に埋めると Dictionary 構造変更のレースになる (BattingOrderProfile と同じ制約)。

# 母集団が足りないとき (新規ワールドの1年目・合成データのテスト) に使う既定値。
# 現行のワールド生成で実測した値で、通常運転ではこれではなく実測値が使われる。
const DEFAULT_RATING_REFERENCE: Dictionary = {
	"contact": {"mean": 61.0, "spread": 6.2},
	"power": {"mean": 65.5, "spread": 7.6},
	"speed": {"mean": 64.0, "spread": 7.5},
	"discipline": {"mean": 59.0, "spread": 6.1},
}
const DEFAULT_STAT_REFERENCE: Dictionary = {
	"average": {"mean": 0.271, "spread": 0.036, "alignment": 0.0},
	"on_base": {"mean": 0.335, "spread": 0.040, "alignment": 0.0},
	"isolated_power": {"mean": 0.130, "spread": 0.050, "alignment": 0.0},
	"ops": {"mean": 0.725, "spread": 0.120, "alignment": 0.0},
}

# 成績指標と、その比較相手になる能力指標の対応。alignment はこの対応で測る。
const STAT_ABILITY_PAIRS: Dictionary = {
	"average": "contact",
	"on_base": "on_base",
	"isolated_power": "power",
	"ops": "total",
}

# total (打者総合) を表示能力側から作るときの内訳。
const TOTAL_ABILITY_WEIGHTS: Dictionary = {
	"contact": 0.34,
	"power": 0.34,
	"on_base": 0.22,
	"speed": 0.10,
}

# --- 投手側 ---
# 先発と救援は防御率の分布が別物なので、成績基準は役割ごとに測る。
const PITCHER_ROLE_STARTER: String = "starter"
const PITCHER_ROLE_RELIEVER: String = "reliever"

const DEFAULT_PITCHER_RATING_REFERENCE: Dictionary = {
	"stuff": {"mean": 60.0, "spread": 8.0},
	"control": {"mean": 60.0, "spread": 8.0},
	"stamina": {"mean": 60.0, "spread": 9.0},
}
# run_prevention は「防御率の符号反転」(高いほど良い)。既定値は現行バランスの実測レンジ。
const DEFAULT_PITCHER_STAT_REFERENCE: Dictionary = {
	"run_prevention": {"mean": -3.70, "spread": 1.10, "alignment": 0.0},
}
const PITCHER_STAT_ABILITY_PAIRS: Dictionary = {"run_prevention": "total"}
const PITCHER_TOTAL_ABILITY_WEIGHTS: Dictionary = {
	"stuff": 0.45,
	"control": 0.35,
	"stamina": 0.20,
}
# 成績基準の母集団に入る最低対戦打者数 (先発 ≒ 年750 / 救援 ≒ 年280 なので規定相当の下限)。
const MIN_REFERENCE_BATTERS_FACED: int = 200
const MIN_PITCHER_STAT_SAMPLE: int = 20
const MIN_PITCHER_RATING_SAMPLE: int = 60
const MIN_PITCHER_STAT_SPREAD: float = 0.30

# --- 評価スコアの母集団分布 ---
# 「他の選択肢より良いか」を問う閾値 (主力か/レギュラー級か/代打を送る弱さか) を、
# 絶対値ではなく母集団の mean + sigma*spread で表すための基準。
# 絶対値で置くとリーグ全体の水準が動いただけで判定が一斉にズレる
# (前例: 旧 RELEASE_REPLACEMENT_VALUE を 52→56 と 4 点動かすだけで放出が 75.5→83.75 人/年)。
const DEFAULT_SCORE_REFERENCE: Dictionary = {
	"overall_batter": {"mean": 67.0, "spread": 9.0},
	"overall_pitcher": {"mean": 67.0, "spread": 9.0},
	"batting": {"mean": 70.0, "spread": 11.0},
}
const MIN_SCORE_SAMPLE: int = 60
const MIN_SCORE_SPREAD: float = 3.0

# 実測を採用する最小条件。これを下回る母集団では既定値へフォールバックする。
const MIN_RATING_SAMPLE: int = 60
const MIN_STAT_SAMPLE: int = 40
# 成績基準の母集団に入る最低打席数 (規定打席相当のレギュラーだけを見る)。
const MIN_REFERENCE_PLATE_APPEARANCES: int = 200
# 成績基準を探して遡る最大年数。
const STAT_REFERENCE_LOOKBACK: int = 5
# 成績母集団がまだ無いとき、alignment を測る「レギュラー相当」の人数 (1 球団あたり)。
# 出場シェア (PSTeamSetupBuilder) が使う `regulars` 分布の母集団サイズも同じ値で切る。
const REGULARS_PER_TEAM: int = 9
# `regulars` = 支配下野手を能力総合で並べた上位 (球団数 × REGULARS_PER_TEAM) の分布。
# 「リーグの先発級の中でどの位置に居るか」を測る物差しで、出場シェアの唯一の入力。
# **上位打ち切りの母集団なので左に裾が無い** — z の中央値は 0 ではなく -0.3 前後に寄る。
# シェア曲線 (PSTeamSetupBuilder.SHARE_CURVE) のアンカーはそれを前提に置いてある。
#
# `by_position` は登録ポジションごとの「1 球団 1 人ぶんの先発級」の平均 (spread は全体の値を共用)。
# 打撃指標そのままだと捕手・遊撃のように「打てなくても代わりが居ない」定位置ほど z が下がり、
# 出場シェアが実際と逆になる (実測で 捕 -1.47σ / 左 +0.48σ)。守備位置ごとに平均を測り直して
# ゼロ点を揃えることで、**その守備位置の先発級として平均なら share も平均**になる。
# fWAR のポジション補正を定数で足す方式は採らない — 本実装の守備配置ロジックが作る
# 実際の偏り (例: 中堅が打てる、一塁が打てない) と合わず、較正が固定値に依存するため。
const DEFAULT_REGULAR_REFERENCE: Dictionary = {"mean": 1.00, "spread": 0.43, "by_position": {}}
const MIN_REGULAR_SAMPLE: int = 27
const MIN_REGULAR_SPREAD: float = 0.10
# 守備位置別の平均を採用する最低人数 (これ未満のポジションは全体平均に落とす)。
const MIN_POSITION_REGULAR_SAMPLE: int = 6
# spread の下限。母集団が偏って spread≈0 になっても指標が発散しないようにする。
const MIN_RATING_SPREAD: float = 2.0
const MIN_STAT_SPREAD: float = 0.010

static var _cache: Dictionary = {}
# 試合日の並列計算フェーズの間だけ true。この間はキャッシュミスを**書き込まずに**その場で計算する
# (worker から静的 Dictionary を書くと冒頭のレースになる)。通常はプリウォーム済みなので
# ここへ落ちてこない — 落ちても遅いだけで結果は同じ、という安全弁。
static var _frozen: bool = false


# 並列計算フェーズの開始/終了でメインスレッドから呼ぶ。
static func set_frozen(value: bool) -> void:
	_frozen = value


static func is_frozen() -> bool:
	return _frozen


const LEVEL_FIRST: int = 0
const LEVEL_FARM: int = 1


static func batter_stats_for_level(record: PSPlayerSeasonRecord, level: int) -> PSBatterStats:
	if record == null:
		return null
	return record.farm_batter_stats if level == LEVEL_FARM else record.batter_stats


static func pitcher_stats_for_level(record: PSPlayerSeasonRecord, level: int) -> PSPitcherStats:
	if record == null:
		return null
	return record.farm_pitcher_stats if level == LEVEL_FARM else record.pitcher_stats


# {ratings: {trait: {mean, spread}}, stats: {key: {mean, spread, alignment}}} を返す。
#
# level=LEVEL_FARM では **能力分布 (ratings) は一軍のまま、成績分布 (stats) だけ二軍で測る**。
# 能力スケールは所属レベルに依らない共通の物差しであるべきで、変えると一軍選手と二軍選手を
# 同じ土俵で比べられなくなるため。リーグ難度の差は `_with_alignment` が吸収する — 二軍の
# 成績分布のゼロ点を「二軍のレギュラーが共通能力スケールのどこに居るか」へ合わせるので、
# 「二軍で能力なりに打っている」が delta 0 になる。
static func for_season(year: int, season_number: int, level: int = LEVEL_FIRST) -> Dictionary:
	var key: String = "%d_%d_%d" % [year, season_number, level]
	if _cache.has(key):
		return _cache[key] as Dictionary
	# 能力分布は常に一軍母集団から測る (共通の物差し)。
	var records: Array = _season_records(year, season_number)
	var ratings: Dictionary = _measure_ratings(records)
	var pitcher_ratings: Dictionary = _measure_pitcher_ratings(records)
	var stat_records: Array = records if level == LEVEL_FIRST else _season_records(year, season_number, level)
	var measured: Dictionary = {
		"ratings": ratings,
		"regulars": _measure_regulars(records, ratings),
		"stats": _resolve_stats(year, season_number, ratings, stat_records, level),
		"scores": _measure_scores(records),
		"pitcher_ratings": pitcher_ratings,
		"pitcher_stats": {
			PITCHER_ROLE_STARTER: _resolve_pitcher_stats(
				year, season_number, pitcher_ratings, stat_records, PITCHER_ROLE_STARTER, level
			),
			PITCHER_ROLE_RELIEVER: _resolve_pitcher_stats(
				year, season_number, pitcher_ratings, stat_records, PITCHER_ROLE_RELIEVER, level
			),
		},
	}
	if not _frozen:
		_cache[key] = measured
	return measured


# シーズン開始時・セーブロード時・試合日の worker 起動前にメインスレッドで呼ぶ。
# 過去シーズンぶんも含めて凍結する (選手評価は直近数年の成績を参照するため)。
#
# lookback の既定は **評価側が実際に遡る最大年数から導出する**。ここが実際の参照より浅いと、
# 未キャッシュの季を worker が for_season() で埋めにかかり、冒頭に書いたレースがそのまま起きる。
# 評価側より浅い固定値にはせず、ノブの変更にも追随させる。
static func prewarm(year: int, season_number: int, lookback: int = -1) -> void:
	var depth: int = lookback if lookback >= 0 else max_past_season_lookback()
	for k in range(depth + 1):
		if season_number - k <= 0:
			break
		for_season(year - k, season_number - k)
		# 二軍基準も同時に温める。一二軍入替の評価が worker 中に未キャッシュの二軍基準へ
		# 落ちると、静的 Dictionary への遅延書き込みでレースになる (一軍と同じ制約)。
		for_season(year - k, season_number - k, LEVEL_FARM)


# 打者/投手それぞれの出場判断・編成判断ノブのうち、最も長く遡るもの。
static func max_past_season_lookback() -> int:
	return maxi(
		maxi(PSBatterForm.PAST_SEASON_LOOKBACK, PSBatterForm.ROSTER_PAST_SEASON_LOOKBACK),
		maxi(PSPitcherForm.PAST_SEASON_LOOKBACK, PSPitcherForm.ROSTER_PAST_SEASON_LOOKBACK)
	)


# 基準分布と、それに紐づく過去シーズン標本をまとめて破棄する。レコードを読み直した/消した後は
# 過去シーズンぶんも変わり得るので、必ず両方落とす (片方だけ残すと stale な評価値が生き残る)。
static func reset_cache() -> void:
	_cache.clear()
	PSBatterForm.reset_sample_cache()
	PSPitcherForm.reset_sample_cache()


# --- 能力指標 (成績側と共通のスケール定義) ---

# 表示能力 (巧打/長打/走力/選球) を σ 単位の指標へ。total は 4 指標の重み付き和。
static func ability_indexes(record: PSPlayerSeasonRecord, ratings_reference: Dictionary) -> Dictionary:
	var index: Dictionary = {
		"contact": normalized(
			float(PSPlayerVisibleRatings.fielder_contact(record)), ratings_reference, "contact"
		),
		"power": normalized(
			float(PSPlayerVisibleRatings.fielder_power(record)), ratings_reference, "power"
		),
		"speed": normalized(
			float(PSPlayerVisibleRatings.fielder_speed(record)), ratings_reference, "speed"
		),
		"on_base": normalized(
			float(PSPlayerVisibleRatings.fielder_discipline(record)), ratings_reference, "discipline"
		),
	}
	var total: float = 0.0
	for key in TOTAL_ABILITY_WEIGHTS.keys():
		total += float(TOTAL_ABILITY_WEIGHTS[key]) * float(index[key])
	index["total"] = total
	return index


# total だけを使う出場判断向け。能力別 Dictionary を作らず、ability_indexes と同じ順序で加算する。
static func ability_total_index(record: PSPlayerSeasonRecord, ratings_reference: Dictionary) -> float:
	var total: float = 0.0
	total += float(TOTAL_ABILITY_WEIGHTS["contact"]) * normalized(
		float(PSPlayerVisibleRatings.fielder_contact(record)), ratings_reference, "contact"
	)
	total += float(TOTAL_ABILITY_WEIGHTS["power"]) * normalized(
		float(PSPlayerVisibleRatings.fielder_power(record)), ratings_reference, "power"
	)
	total += float(TOTAL_ABILITY_WEIGHTS["on_base"]) * normalized(
		float(PSPlayerVisibleRatings.fielder_discipline(record)), ratings_reference, "discipline"
	)
	total += float(TOTAL_ABILITY_WEIGHTS["speed"]) * normalized(
		float(PSPlayerVisibleRatings.fielder_speed(record)), ratings_reference, "speed"
	)
	return total


# (value - mean) / spread。stats 側の分布は alignment を持ち、能力スケールへ平行移動される。
static func normalized(value: float, distributions: Dictionary, key: String) -> float:
	var distribution: Dictionary = distributions[key] as Dictionary
	var index: float = (value - float(distribution["mean"])) / float(distribution["spread"])
	return index + float(distribution.get("alignment", 0.0))


# --- 実測 ---

static func _measure_ratings(records: Array) -> Dictionary:
	var samples: Dictionary = {"contact": [], "power": [], "speed": [], "discipline": []}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher() or record.development_player:
			continue
		(samples["contact"] as Array).append(float(PSPlayerVisibleRatings.fielder_contact(record)))
		(samples["power"] as Array).append(float(PSPlayerVisibleRatings.fielder_power(record)))
		(samples["speed"] as Array).append(float(PSPlayerVisibleRatings.fielder_speed(record)))
		(samples["discipline"] as Array).append(float(PSPlayerVisibleRatings.fielder_discipline(record)))
	return _distributions_or_default(
		samples, DEFAULT_RATING_REFERENCE, MIN_RATING_SAMPLE, MIN_RATING_SPREAD
	)


# 「リーグの先発級」の能力総合分布。能力スナップショットはシーズン中ほぼ動かないので
# ratings と同じくプリウォームで凍結できる (試合日の並列実行から書き込みが起きない)。
# 成績は混ぜない — 混ぜると物差し自体がシーズン中に動き、シェアの意味がブレるため。
static func _measure_regulars(records: Array, ratings_reference: Dictionary) -> Dictionary:
	var totals: Array = []
	var totals_by_position: Dictionary = {}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record == null or record.is_pitcher() or record.development_player:
			continue
		var total: float = ability_total_index(record, ratings_reference)
		totals.append(total)
		if record.position >= 2 and record.position <= 9:
			var position_totals: Array = totals_by_position.get(record.position, []) as Array
			position_totals.append(total)
			totals_by_position[record.position] = position_totals
	if totals.size() < MIN_REGULAR_SAMPLE:
		return DEFAULT_REGULAR_REFERENCE.duplicate(true)
	var team_count: int = maxi(GameDb.teams.size(), 1)
	var regulars: Array = _top_values(totals, team_count * REGULARS_PER_TEAM)
	var mean: float = _mean_of(regulars)
	var variance: float = 0.0
	for value in regulars:
		variance += pow(float(value) - mean, 2.0)
	# 守備位置ごとは「1 球団 1 人」= 各ポジションの定位置相当の平均だけを測る。
	# spread を位置別に測らないのは標本が 12 人しかなく不安定なため (全体の spread を共用)。
	var by_position: Dictionary = {}
	for position_value in totals_by_position.keys():
		var position_totals: Array = totals_by_position[position_value] as Array
		if position_totals.size() < MIN_POSITION_REGULAR_SAMPLE:
			continue
		by_position[int(position_value)] = _mean_of(_top_values(position_totals, team_count))
	return {
		"mean": mean,
		"spread": maxf(MIN_REGULAR_SPREAD, sqrt(variance / float(regulars.size()))),
		"by_position": by_position,
	}


static func _top_values(values: Array, count: int) -> Array:
	var sorted_values: Array = values.duplicate()
	sorted_values.sort()
	sorted_values.reverse()
	return sorted_values.slice(0, mini(sorted_values.size(), maxi(count, 1)))


static func _mean_of(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


# 進行中のシーズンは規定到達打者がまだ居ないので、標本が揃う直近の過去シーズンまで遡る。
# alignment は **参照元シーズンの母集団**を、**呼び出し側が使う ratings_reference** で測る
# (ゼロ点を揃える相手は、これから評価される選手の能力指標なので)。
static func _resolve_stats(
	year: int, season_number: int, ratings_reference: Dictionary, own_records: Array, level: int = LEVEL_FIRST
) -> Dictionary:
	for k in range(STAT_REFERENCE_LOOKBACK + 1):
		if season_number - k <= 0:
			break
		var source: Array = own_records if k == 0 else _season_records(year - k, season_number - k, level)
		var measured: Dictionary = _measure_stats(source, ratings_reference, level)
		if not measured.is_empty():
			return measured
	return _default_stats_with_alignment(own_records, ratings_reference)


# 標本が足りなければ空 Dictionary を返す (呼び出し側がさらに遡る)。
static func _measure_stats(records: Array, ratings_reference: Dictionary, level: int = LEVEL_FIRST) -> Dictionary:
	var samples: Dictionary = {"average": [], "on_base": [], "isolated_power": [], "ops": []}
	var regulars: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			continue
		var stats: PSBatterStats = batter_stats_for_level(record, level)
		if stats == null or stats.plate_appearances < MIN_REFERENCE_PLATE_APPEARANCES:
			continue
		var average: float = stats.batting_average()
		(samples["average"] as Array).append(average)
		(samples["on_base"] as Array).append(stats.on_base_percentage())
		(samples["isolated_power"] as Array).append(stats.slugging_percentage() - average)
		(samples["ops"] as Array).append(stats.ops())
		regulars.append(record)
	if regulars.size() < MIN_STAT_SAMPLE:
		return {}
	var distributions: Dictionary = _distributions_or_default(
		samples, DEFAULT_STAT_REFERENCE, MIN_STAT_SAMPLE, MIN_STAT_SPREAD
	)
	return _with_alignment(distributions, regulars, ratings_reference)


# 成績母集団がまだ無いとき (新規ワールドの1年目) の既定分布。alignment だけは
# 「レギュラー相当 = 能力上位」の能力指標から測れるので、ゼロ点のズレは残さない。
static func _default_stats_with_alignment(records: Array, ratings_reference: Dictionary) -> Dictionary:
	var batters: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher() or record.development_player:
			continue
		batters.append(record)
	if batters.is_empty():
		return DEFAULT_STAT_REFERENCE.duplicate(true)
	batters.sort_custom(func(a, b) -> bool:
		var index_a: Dictionary = ability_indexes(a as PSPlayerSeasonRecord, ratings_reference)
		var index_b: Dictionary = ability_indexes(b as PSPlayerSeasonRecord, ratings_reference)
		return float(index_a["total"]) > float(index_b["total"])
	)
	var regular_count: int = mini(batters.size(), maxi(GameDb.teams.size(), 1) * REGULARS_PER_TEAM)
	return _with_alignment(
		DEFAULT_STAT_REFERENCE.duplicate(true), batters.slice(0, regular_count), ratings_reference
	)


# distributions の各成績キーに、対応する能力指標の母集団平均を alignment として書き込む。
static func _with_alignment(
	distributions: Dictionary,
	population: Array,
	ratings_reference: Dictionary,
	pairs: Dictionary = STAT_ABILITY_PAIRS,
	pitcher_side: bool = false
) -> Dictionary:
	if population.is_empty():
		return distributions
	var totals: Dictionary = {}
	for stat_key in pairs.keys():
		totals[stat_key] = 0.0
	for record_row in population:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		var index: Dictionary = pitcher_ability_indexes(record, ratings_reference) if pitcher_side \
			else ability_indexes(record, ratings_reference)
		for stat_key in pairs.keys():
			totals[stat_key] = float(totals[stat_key]) + float(index[pairs[stat_key]])
	for stat_key in pairs.keys():
		var distribution: Dictionary = (distributions[stat_key] as Dictionary).duplicate()
		distribution["alignment"] = float(totals[stat_key]) / float(population.size())
		distributions[stat_key] = distribution
	return distributions


# --- 評価スコアの母集団分布 ---

# 「母集団の mean から sigma 個ぶん上」を返す。絶対値の代わりに使う判定ライン。
# sigma を上げるほど「その水準」が厳しくなる。母集団不足時は DEFAULT_SCORE_REFERENCE を使う。
static func score_threshold(year: int, season_number: int, key: String, sigma: float) -> float:
	var distribution: Dictionary = score_distribution(year, season_number, key)
	return float(distribution["mean"]) + sigma * float(distribution["spread"])


static func score_distribution(year: int, season_number: int, key: String) -> Dictionary:
	var scores: Dictionary = for_season(year, season_number)["scores"] as Dictionary
	return scores.get(key, DEFAULT_SCORE_REFERENCE[key]) as Dictionary


static func _measure_scores(records: Array) -> Dictionary:
	var samples: Dictionary = {"overall_batter": [], "overall_pitcher": [], "batting": []}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.development_player:
			continue
		var overall: float = float(PSPlayerValueEvaluator.overall_score(record))
		if record.is_pitcher():
			(samples["overall_pitcher"] as Array).append(overall)
			continue
		(samples["overall_batter"] as Array).append(overall)
		(samples["batting"] as Array).append(
			float(PSPlayerValueEvaluator.batting_score_without_fatigue(record))
		)
	return _distributions_or_default(
		samples, DEFAULT_SCORE_REFERENCE, MIN_SCORE_SAMPLE, MIN_SCORE_SPREAD
	)


# --- 投手側の実測 (打者側と同じ機構: 実測分布 + alignment でゼロ点合わせ) ---

# 投手の表示能力 (球威/制球/スタミナ) を σ 単位の指標へ。total は 3 指標の重み付き和。
static func pitcher_ability_indexes(
	record: PSPlayerSeasonRecord, ratings_reference: Dictionary
) -> Dictionary:
	var index: Dictionary = {
		"stuff": normalized(float(PSPlayerVisibleRatings.pitcher_stuff(record)), ratings_reference, "stuff"),
		"control": normalized(
			float(PSPlayerVisibleRatings.pitcher_control(record)), ratings_reference, "control"
		),
		"stamina": normalized(
			float(PSPlayerVisibleRatings.pitcher_stamina(record)), ratings_reference, "stamina"
		),
	}
	var total: float = 0.0
	for key in PITCHER_TOTAL_ABILITY_WEIGHTS.keys():
		total += float(PITCHER_TOTAL_ABILITY_WEIGHTS[key]) * float(index[key])
	index["total"] = total
	return index


# 投手の total だけを使う判断向け。pitcher_ability_indexes と同じ順序で加算する。
static func pitcher_ability_total_index(
	record: PSPlayerSeasonRecord, ratings_reference: Dictionary
) -> float:
	var total: float = 0.0
	total += float(PITCHER_TOTAL_ABILITY_WEIGHTS["stuff"]) * normalized(
		float(PSPlayerVisibleRatings.pitcher_stuff(record)), ratings_reference, "stuff"
	)
	total += float(PITCHER_TOTAL_ABILITY_WEIGHTS["control"]) * normalized(
		float(PSPlayerVisibleRatings.pitcher_control(record)), ratings_reference, "control"
	)
	total += float(PITCHER_TOTAL_ABILITY_WEIGHTS["stamina"]) * normalized(
		float(PSPlayerVisibleRatings.pitcher_stamina(record)), ratings_reference, "stamina"
	)
	return total


# 失点抑止の指標。防御率は低いほど良いので符号を反転して「高いほど良い」に揃える。
static func run_prevention_value(stats: PSPitcherStats) -> float:
	return -clampf(stats.era(), 0.0, 12.0)


static func pitcher_role_of(record: PSPlayerSeasonRecord) -> String:
	return PITCHER_ROLE_STARTER if record.is_starter_pitcher() else PITCHER_ROLE_RELIEVER


static func _measure_pitcher_ratings(records: Array) -> Dictionary:
	var samples: Dictionary = {"stuff": [], "control": [], "stamina": []}
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher() or record.development_player:
			continue
		(samples["stuff"] as Array).append(float(PSPlayerVisibleRatings.pitcher_stuff(record)))
		(samples["control"] as Array).append(float(PSPlayerVisibleRatings.pitcher_control(record)))
		(samples["stamina"] as Array).append(float(PSPlayerVisibleRatings.pitcher_stamina(record)))
	return _distributions_or_default(
		samples, DEFAULT_PITCHER_RATING_REFERENCE, MIN_PITCHER_RATING_SAMPLE, MIN_RATING_SPREAD
	)


static func _resolve_pitcher_stats(
	year: int, season_number: int, ratings_reference: Dictionary, own_records: Array, role: String,
	level: int = LEVEL_FIRST
) -> Dictionary:
	for k in range(STAT_REFERENCE_LOOKBACK + 1):
		if season_number - k <= 0:
			break
		var source: Array = own_records if k == 0 else _season_records(year - k, season_number - k, level)
		var measured: Dictionary = _measure_pitcher_stats(source, ratings_reference, role, level)
		if not measured.is_empty():
			return measured
	return _default_pitcher_stats_with_alignment(own_records, ratings_reference, role)


static func _measure_pitcher_stats(
	records: Array, ratings_reference: Dictionary, role: String, level: int = LEVEL_FIRST
) -> Dictionary:
	var samples: Dictionary = {"run_prevention": []}
	var qualified: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher() or pitcher_role_of(record) != role:
			continue
		var stats: PSPitcherStats = pitcher_stats_for_level(record, level)
		if stats == null or stats.batters_faced < MIN_REFERENCE_BATTERS_FACED:
			continue
		(samples["run_prevention"] as Array).append(run_prevention_value(stats))
		qualified.append(record)
	if qualified.size() < MIN_PITCHER_STAT_SAMPLE:
		return {}
	var distributions: Dictionary = _distributions_or_default(
		samples, DEFAULT_PITCHER_STAT_REFERENCE, MIN_PITCHER_STAT_SAMPLE, MIN_PITCHER_STAT_SPREAD
	)
	return _with_alignment(distributions, qualified, ratings_reference, PITCHER_STAT_ABILITY_PAIRS, true)


static func _default_pitcher_stats_with_alignment(
	records: Array, ratings_reference: Dictionary, role: String
) -> Dictionary:
	var pitchers: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if not record.is_pitcher() or record.development_player or pitcher_role_of(record) != role:
			continue
		pitchers.append(record)
	if pitchers.is_empty():
		return DEFAULT_PITCHER_STAT_REFERENCE.duplicate(true)
	pitchers.sort_custom(func(a, b) -> bool:
		var index_a: Dictionary = pitcher_ability_indexes(a as PSPlayerSeasonRecord, ratings_reference)
		var index_b: Dictionary = pitcher_ability_indexes(b as PSPlayerSeasonRecord, ratings_reference)
		return float(index_a["total"]) > float(index_b["total"])
	)
	# 「実際に投げる面々」= 1 球団あたり先発 6 / 救援 8 相当を基準にする。
	var per_team: int = 6 if role == PITCHER_ROLE_STARTER else 8
	var count: int = mini(pitchers.size(), maxi(GameDb.teams.size(), 1) * per_team)
	return _with_alignment(
		DEFAULT_PITCHER_STAT_REFERENCE.duplicate(true), pitchers.slice(0, count),
		ratings_reference, PITCHER_STAT_ABILITY_PAIRS, true
	)


# level=LEVEL_FARM ではファーム専用球団を含む14球団から集める (二軍リーグの母集団)。
# 既定 (一軍) が `GameDb.teams` の12球団なのは変えない — ここが一軍のリーグ基準の単一ソースで、
# 専用球団が混ざると一軍の基準が汚染される。
static func _season_records(year: int, season_number: int, level: int = LEVEL_FIRST) -> Array:
	var records: Array = []
	var source_teams: Array = GameDb.teams if level == LEVEL_FIRST else GameDb.farm_participating_teams()
	for team_row in source_teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		for record_row in RecordStore.get_team_player_records(team.id, year, season_number, true):
			var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
			if record != null:
				records.append(record)
	return records


static func _distributions_or_default(
	samples: Dictionary, defaults: Dictionary, min_sample: int, min_spread: float
) -> Dictionary:
	var out: Dictionary = {}
	for key in defaults.keys():
		var values: Array = samples.get(key, []) as Array
		if values.size() < min_sample:
			out[key] = (defaults[key] as Dictionary).duplicate()
			continue
		var mean: float = 0.0
		for value in values:
			mean += float(value)
		mean /= float(values.size())
		var variance: float = 0.0
		for value in values:
			variance += pow(float(value) - mean, 2.0)
		variance /= float(values.size())
		out[key] = {"mean": mean, "spread": maxf(sqrt(variance), min_spread)}
	return out
