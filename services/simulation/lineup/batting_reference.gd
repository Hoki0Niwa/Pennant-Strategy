extends RefCounted
class_name PSBattingReference

# 打者評価 (PSBatterForm) が表示能力と成績を同じ σ スケールに載せるための基準分布を、
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

# 実測を採用する最小条件。これを下回る母集団では既定値へフォールバックする。
const MIN_RATING_SAMPLE: int = 60
const MIN_STAT_SAMPLE: int = 40
# 成績基準の母集団に入る最低打席数 (規定打席相当のレギュラーだけを見る)。
const MIN_REFERENCE_PLATE_APPEARANCES: int = 200
# 成績基準を探して遡る最大年数。
const STAT_REFERENCE_LOOKBACK: int = 5
# 成績母集団がまだ無いとき、alignment を測る「レギュラー相当」の人数 (1 球団あたり)。
const REGULARS_PER_TEAM: int = 9
# spread の下限。母集団が偏って spread≈0 になっても指標が発散しないようにする。
const MIN_RATING_SPREAD: float = 2.0
const MIN_STAT_SPREAD: float = 0.010

static var _cache: Dictionary = {}


# {ratings: {trait: {mean, spread}}, stats: {key: {mean, spread, alignment}}} を返す。
static func for_season(year: int, season_number: int) -> Dictionary:
	var key: String = "%d_%d" % [year, season_number]
	if _cache.has(key):
		return _cache[key] as Dictionary
	var records: Array = _season_records(year, season_number)
	var ratings: Dictionary = _measure_ratings(records)
	var measured: Dictionary = {
		"ratings": ratings,
		"stats": _resolve_stats(year, season_number, ratings, records),
	}
	_cache[key] = measured
	return measured


# シーズン開始時・セーブロード時にメインスレッドで呼ぶ。過去シーズンぶんも含めて凍結する
# (打者評価は直近数年の成績を参照するため)。
static func prewarm(year: int, season_number: int, lookback: int = 4) -> void:
	for k in range(lookback + 1):
		if season_number - k <= 0:
			break
		for_season(year - k, season_number - k)


static func reset_cache() -> void:
	_cache.clear()


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


# 進行中のシーズンは規定到達打者がまだ居ないので、標本が揃う直近の過去シーズンまで遡る。
# alignment は **参照元シーズンの母集団**を、**呼び出し側が使う ratings_reference** で測る
# (ゼロ点を揃える相手は、これから評価される選手の能力指標なので)。
static func _resolve_stats(
	year: int, season_number: int, ratings_reference: Dictionary, own_records: Array
) -> Dictionary:
	for k in range(STAT_REFERENCE_LOOKBACK + 1):
		if season_number - k <= 0:
			break
		var source: Array = own_records if k == 0 else _season_records(year - k, season_number - k)
		var measured: Dictionary = _measure_stats(source, ratings_reference)
		if not measured.is_empty():
			return measured
	return _default_stats_with_alignment(own_records, ratings_reference)


# 標本が足りなければ空 Dictionary を返す (呼び出し側がさらに遡る)。
static func _measure_stats(records: Array, ratings_reference: Dictionary) -> Dictionary:
	var samples: Dictionary = {"average": [], "on_base": [], "isolated_power": [], "ops": []}
	var regulars: Array = []
	for record_row in records:
		var record: PSPlayerSeasonRecord = record_row as PSPlayerSeasonRecord
		if record.is_pitcher():
			continue
		var stats: PSBatterStats = record.batter_stats
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
	distributions: Dictionary, population: Array, ratings_reference: Dictionary
) -> Dictionary:
	if population.is_empty():
		return distributions
	var totals: Dictionary = {}
	for stat_key in STAT_ABILITY_PAIRS.keys():
		totals[stat_key] = 0.0
	for record_row in population:
		var index: Dictionary = ability_indexes(record_row as PSPlayerSeasonRecord, ratings_reference)
		for stat_key in STAT_ABILITY_PAIRS.keys():
			totals[stat_key] = float(totals[stat_key]) + float(index[STAT_ABILITY_PAIRS[stat_key]])
	for stat_key in STAT_ABILITY_PAIRS.keys():
		var distribution: Dictionary = (distributions[stat_key] as Dictionary).duplicate()
		distribution["alignment"] = float(totals[stat_key]) / float(population.size())
		distributions[stat_key] = distribution
	return distributions


static func _season_records(year: int, season_number: int) -> Array:
	var records: Array = []
	for team_row in GameDb.teams:
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
