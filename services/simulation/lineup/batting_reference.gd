extends RefCounted
class_name PSBattingReference

# 打順評価 (PSBattingOrderService) が表示能力と成績を同じ σ スケールに載せるための基準分布を、
# **その時点の母集団から実測**して返す。固定値を持たないので、バランス較正や長期セーブでの
# リーグ環境ドリフトが起きても打者の位置付けが古い基準のままにならない。
#
# 基準は 2 系統:
# - ratings = そのシーズンの支配下野手の表示能力分布。能力スナップショットはシーズン中ほぼ動かない。
# - stats   = 規定到達打者の率成績分布。**進行中のシーズンは母集団が育っていない**ので、
#             十分な標本が集まっている直近の過去シーズンまで遡って使う。
#
# どちらも「完了した情報」だけを見るため中身が試合中に変化せず、プリウォームで凍結できる。
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
	"average": {"mean": 0.271, "spread": 0.036},
	"on_base": {"mean": 0.335, "spread": 0.040},
	"isolated_power": {"mean": 0.130, "spread": 0.050},
	"ops": {"mean": 0.725, "spread": 0.120},
}

# 実測を採用する最小条件。これを下回る母集団では既定値へフォールバックする。
const MIN_RATING_SAMPLE: int = 60
const MIN_STAT_SAMPLE: int = 40
# 成績基準の母集団に入る最低打席数 (規定打席相当のレギュラーだけを見る)。
const MIN_REFERENCE_PLATE_APPEARANCES: int = 200
# 成績基準を探して遡る最大年数。
const STAT_REFERENCE_LOOKBACK: int = 5
# spread の下限。母集団が偏って spread≈0 になっても指標が発散しないようにする。
const MIN_RATING_SPREAD: float = 2.0
const MIN_STAT_SPREAD: float = 0.010

static var _cache: Dictionary = {}


# {ratings: {trait: {mean, spread}}, stats: {key: {mean, spread}}} を返す。
static func for_season(year: int, season_number: int) -> Dictionary:
	var key: String = "%d_%d" % [year, season_number]
	if _cache.has(key):
		return _cache[key] as Dictionary
	var measured: Dictionary = {
		"ratings": _measure_ratings(year, season_number),
		"stats": _resolve_stats(year, season_number),
	}
	_cache[key] = measured
	return measured


# シーズン開始時・セーブロード時にメインスレッドで呼ぶ。過去シーズンぶんも含めて凍結する
# (打順評価は直近 PAST_SEASON_LOOKBACK 年の成績を参照するため)。
static func prewarm(year: int, season_number: int, lookback: int = 4) -> void:
	for k in range(lookback + 1):
		if season_number - k <= 0:
			break
		for_season(year - k, season_number - k)


static func reset_cache() -> void:
	_cache.clear()


# --- 実測 ---

static func _measure_ratings(year: int, season_number: int) -> Dictionary:
	var samples: Dictionary = {"contact": [], "power": [], "speed": [], "discipline": []}
	for record_row in _season_records(year, season_number):
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
static func _resolve_stats(year: int, season_number: int) -> Dictionary:
	for k in range(STAT_REFERENCE_LOOKBACK + 1):
		if season_number - k <= 0:
			break
		var measured: Dictionary = _measure_stats(year - k, season_number - k)
		if not measured.is_empty():
			return measured
	return DEFAULT_STAT_REFERENCE.duplicate(true)


# 標本が足りなければ空 Dictionary を返す (呼び出し側がさらに遡る)。
static func _measure_stats(year: int, season_number: int) -> Dictionary:
	var samples: Dictionary = {"average": [], "on_base": [], "isolated_power": [], "ops": []}
	for record_row in _season_records(year, season_number):
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
	if (samples["ops"] as Array).size() < MIN_STAT_SAMPLE:
		return {}
	return _distributions_or_default(samples, DEFAULT_STAT_REFERENCE, MIN_STAT_SAMPLE, MIN_STAT_SPREAD)


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
