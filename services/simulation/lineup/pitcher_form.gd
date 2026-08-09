extends RefCounted
class_name PSPitcherForm

# 投手版の `PSBatterForm`。表示能力 (球威/制球/スタミナ) と今季・過去シーズンの失点抑止成績を
# 同じ σ スケールでブレンドし、「成績が能力からどれだけ上振れ/下振れしたか」を rating 点で返す。
# 打者側と同じ縮約 (信頼度 = 対戦打者数 / (対戦打者数 + anchor)、過去は減衰) と、
# 同じゼロ点合わせ (PSPerformanceReference の alignment) を使う。
#
# 成績側は防御率のみ (符号反転して「高いほど良い」に揃えた run_prevention)。
# 先発と救援は防御率分布が別物なので、基準分布は役割ごとに測ったものを引く。

# --- 出場判断 (一二軍入替など) のノブ ---
const ABILITY_PRIOR_WEIGHT: float = 1.0
# 信頼度が 0.5 になる対戦打者数。先発の1シーズンは ≒750、救援は ≒280。
const BATTERS_FACED_RELIABILITY_ANCHOR: float = 300.0
const PAST_SEASON_DECAY: float = 0.5
const PAST_SEASON_LOOKBACK: int = 3

# --- 編成判断 (戦力外など) のノブ ---
const ROSTER_ABILITY_PRIOR_WEIGHT: float = 2.0
const ROSTER_PAST_SEASON_DECAY: float = 0.7
const ROSTER_PAST_SEASON_LOOKBACK: int = 5
const ROSTER_FORM_RATING_SCALE: float = 4.0
const ROSTER_FORM_RATING_MIN: float = -4.0
const ROSTER_FORM_RATING_MAX: float = 4.0

# 1σ 相当の rating 点。上げるほど好不調で起用が入れ替わりやすい。
const FORM_RATING_SCALE: float = 6.0
const FORM_RATING_MIN: float = -6.0
const FORM_RATING_MAX: float = 6.0


# 出場判断用。current_stats を渡すと今季ぶんをその成績で評価する (月別評価に使う)。
static func rating_delta(
	record: PSPlayerSeasonRecord, current_stats: PSPitcherStats = null
) -> float:
	return _rating_delta(
		record, current_stats, ABILITY_PRIOR_WEIGHT, PAST_SEASON_LOOKBACK, PAST_SEASON_DECAY,
		FORM_RATING_SCALE, FORM_RATING_MIN, FORM_RATING_MAX
	)


# 編成判断用: より長い記憶と弱い追随。
static func roster_rating_delta(record: PSPlayerSeasonRecord) -> float:
	return _rating_delta(
		record, null, ROSTER_ABILITY_PRIOR_WEIGHT, ROSTER_PAST_SEASON_LOOKBACK,
		ROSTER_PAST_SEASON_DECAY, ROSTER_FORM_RATING_SCALE, ROSTER_FORM_RATING_MIN, ROSTER_FORM_RATING_MAX
	)


static func _rating_delta(
	record: PSPlayerSeasonRecord,
	current_stats: PSPitcherStats,
	ability_prior: float,
	lookback: int,
	decay: float,
	scale: float,
	clip_min: float,
	clip_max: float
) -> float:
	if record == null or not record.is_pitcher():
		return 0.0
	var season_reference: Dictionary = PSPerformanceReference.for_season(record.year, record.season_number)
	var ratings_reference: Dictionary = season_reference["pitcher_ratings"] as Dictionary
	var ability: Dictionary = PSPerformanceReference.pitcher_ability_indexes(record, ratings_reference)
	var role: String = PSPerformanceReference.pitcher_role_of(record)
	var samples: Array = _stat_samples(record, current_stats, season_reference, role, lookback, decay)
	if samples.is_empty():
		return 0.0
	var ability_total: float = float(ability["total"])
	var blended: float = _blend(ability_total, samples, ability_prior)
	return clampf((blended - ability_total) * scale, clip_min, clip_max)


static func _stat_samples(
	record: PSPlayerSeasonRecord,
	current_stats: PSPitcherStats,
	season_reference: Dictionary,
	role: String,
	lookback: int,
	decay: float
) -> Array:
	var samples: Array = []
	var stats: PSPitcherStats = current_stats if current_stats != null else record.pitcher_stats
	_append_stat_sample(samples, stats, 1.0, _stat_distributions(season_reference, role))
	if record.year <= 0:
		return samples
	for k in range(1, lookback + 1):
		var past_year: int = record.year - k
		var past_season_number: int = record.season_number - k
		var past: PSPlayerSeasonRecord = RecordStore.get_player_record(
			record.player_id, past_year, past_season_number
		)
		if past == null:
			continue
		var past_reference: Dictionary = PSPerformanceReference.for_season(past_year, past_season_number)
		_append_stat_sample(
			samples,
			past.pitcher_stats,
			pow(decay, float(k)),
			_stat_distributions(past_reference, PSPerformanceReference.pitcher_role_of(past))
		)
	return samples


static func _stat_distributions(season_reference: Dictionary, role: String) -> Dictionary:
	return (season_reference["pitcher_stats"] as Dictionary)[role] as Dictionary


static func _append_stat_sample(
	samples: Array, stats: PSPitcherStats, decay: float, distributions: Dictionary
) -> void:
	if stats == null or stats.batters_faced <= 0 or stats.outs_pitched <= 0:
		return
	var batters_faced: float = float(stats.batters_faced)
	var weight: float = decay * batters_faced / (batters_faced + BATTERS_FACED_RELIABILITY_ANCHOR)
	if weight <= 0.0:
		return
	samples.append({
		"weight": weight,
		"run_prevention": PSPerformanceReference.normalized(
			PSPerformanceReference.run_prevention_value(stats), distributions, "run_prevention"
		),
	})


static func _blend(ability_index: float, samples: Array, ability_prior: float) -> float:
	var numerator: float = ability_index * ability_prior
	var denominator: float = ability_prior
	for sample_row in samples:
		var sample: Dictionary = sample_row as Dictionary
		var weight: float = float(sample["weight"])
		numerator += float(sample["run_prevention"]) * weight
		denominator += weight
	return numerator / denominator
