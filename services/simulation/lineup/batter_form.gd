extends RefCounted
class_name PSBatterForm

# 打者を「監督が見られる情報」だけで評価する共通基盤。
# 使うのは表示能力 (PSPlayerVisibleRatings, 1-100) と今季・過去シーズンの打撃成績で、raw z は見ない。
# 打順 (PSBattingOrderService)・スタメン/DH/代打 (PSPlayerValueEvaluator) が共有する。
#
# 5 指標 (on_base / contact / power / speed / total) をそれぞれ σ 単位に揃え、
# 能力と成績の信頼度加重平均を取る:
#   index = (ability * ABILITY_PRIOR_WEIGHT + Σ_k stat_k * w_k) / (ABILITY_PRIOR_WEIGHT + Σ_k w_k)
#   w_k   = PAST_SEASON_DECAY^k * pa_k / (pa_k + PA_RELIABILITY_ANCHOR)   (k=0 が今季)
# 打席が無ければ w=0 なので、開幕直後や新人は表示能力そのもの。今季 pa が増えるほど w_0 が上がって
# 今季成績の比重が徐々に増し、過去シーズンは古いほど PAST_SEASON_DECAY で軽くなる。
# 走力 (speed) だけは成績に素直に現れないため表示能力のみ。
#
# σ スケールを与える基準分布と、能力指標そのもの (ability_indexes) は `PSBattingReference` 側。
# 成績側の分布は alignment を持ち、能力スケールとゼロ点が揃っている (詳細は同ファイル冒頭)。

# --- 出場判断 (打順/スタメン/DH/代打) のノブ ---
# 「今日誰を出すか」は短期判断なので、直近の好不調に素直に追随してよい。
# ability を下げると成績追随が速くなり、上げると能力どおりの評価を維持しやすくなる。
const ABILITY_PRIOR_WEIGHT: float = 1.0
# 成績の信頼度が 0.5 になる打席数。小さくすると少ない打席でも成績を信用する。
const PA_RELIABILITY_ANCHOR: float = 200.0
# 1 年古くなるごとに掛かる係数と、遡る年数。
const PAST_SEASON_DECAY: float = 0.5
const PAST_SEASON_LOOKBACK: int = 3

# --- 編成判断 (戦力外など) のノブ ---
# 「切るかどうか」は長期判断で、1 年の不振で主力を放出するのは典型的な失敗。出場判断より
# 能力 prior を厚く・遡る年数を長く・1 年あたりの減衰を緩く・rating 換算を小さくする。
const ROSTER_ABILITY_PRIOR_WEIGHT: float = 2.0
const ROSTER_PAST_SEASON_DECAY: float = 0.7
const ROSTER_PAST_SEASON_LOOKBACK: int = 5
const ROSTER_FORM_RATING_SCALE: float = 4.0
const ROSTER_FORM_RATING_MIN: float = -4.0
const ROSTER_FORM_RATING_MAX: float = 4.0

# --- rating 換算 ---
# 「成績込みの total」と「能力だけの total」の差を rating 点へ直したもの。
# PSPlayerValueEvaluator の守備実績 (realized_fielding_rating_delta) と対称に、
# 能力ブレンド比率を掛けずスコアへ直接加算する。
#
# SCALE は 1σ 相当の rating 点。守備実績のクリップ (-8..+5) より狭くしてあるのは、
# 打席 (年 ~600) が守備機会 (年 ~1000-1200) よりサンプルが小さく率成績のノイズが大きいため。
# 上げるほど「好不調で起用が入れ替わる」度合いが強くなる。
const FORM_RATING_SCALE: float = 6.0
const FORM_RATING_MIN: float = -6.0
const FORM_RATING_MAX: float = 6.0


# 表示能力と成績をブレンドした打者指標 5 種 (すべて σ 単位)。打順が使う (= 出場判断のノブ)。
# 基準分布は選手が属するシーズンのものを使うので、リーグ環境が動いても位置付けがズレない。
static func indexes(record: PSPlayerSeasonRecord) -> Dictionary:
	var season_reference: Dictionary = PSBattingReference.for_season(record.year, record.season_number)
	var ability: Dictionary = PSBattingReference.ability_indexes(record, season_reference["ratings"] as Dictionary)
	var samples: Array = _stat_samples(
		record, season_reference["stats"] as Dictionary, PAST_SEASON_LOOKBACK, PAST_SEASON_DECAY
	)
	return {
		"on_base": _blend(float(ability["on_base"]), samples, "on_base", ABILITY_PRIOR_WEIGHT),
		"contact": _blend(float(ability["contact"]), samples, "average", ABILITY_PRIOR_WEIGHT),
		"power": _blend(float(ability["power"]), samples, "isolated_power", ABILITY_PRIOR_WEIGHT),
		"speed": float(ability["speed"]),
		"total": _blend(float(ability["total"]), samples, "ops", ABILITY_PRIOR_WEIGHT),
	}


# 出場判断用: 成績が能力からどれだけ上振れ/下振れしているかを rating 点で返す。成績が無ければ 0。
static func rating_delta(record: PSPlayerSeasonRecord) -> float:
	return _rating_delta(
		record, ABILITY_PRIOR_WEIGHT, PAST_SEASON_LOOKBACK, PAST_SEASON_DECAY,
		FORM_RATING_SCALE, FORM_RATING_MIN, FORM_RATING_MAX
	)


# 編成判断用: 同じ差分を、より長い記憶と弱い追随で見る。
static func roster_rating_delta(record: PSPlayerSeasonRecord) -> float:
	return _rating_delta(
		record, ROSTER_ABILITY_PRIOR_WEIGHT, ROSTER_PAST_SEASON_LOOKBACK, ROSTER_PAST_SEASON_DECAY,
		ROSTER_FORM_RATING_SCALE, ROSTER_FORM_RATING_MIN, ROSTER_FORM_RATING_MAX
	)


static func _rating_delta(
	record: PSPlayerSeasonRecord,
	ability_prior: float,
	lookback: int,
	decay: float,
	scale: float,
	clip_min: float,
	clip_max: float
) -> float:
	if record == null:
		return 0.0
	var season_reference: Dictionary = PSBattingReference.for_season(record.year, record.season_number)
	var ability: Dictionary = PSBattingReference.ability_indexes(record, season_reference["ratings"] as Dictionary)
	var samples: Array = _stat_samples(record, season_reference["stats"] as Dictionary, lookback, decay)
	if samples.is_empty():
		return 0.0
	var ability_total: float = float(ability["total"])
	var blended_total: float = _blend(ability_total, samples, "ops", ability_prior)
	return clampf((blended_total - ability_total) * scale, clip_min, clip_max)


# 今季 + 直近 lookback 年の打撃成績を、信頼度と古さで重み付けして返す。
# 過去シーズンは (year-k, season_number-k) で 1 件ずつ引き、**そのシーズンの基準分布**で正規化する
# (シーズンは年と同時に繰り上がる)。年ごとにリーグ環境が動いても成績の位置付けが保たれる。
static func _stat_samples(
	record: PSPlayerSeasonRecord, stat_reference: Dictionary, lookback: int, decay: float
) -> Array:
	var samples: Array = []
	_append_stat_sample(samples, record.batter_stats, 1.0, stat_reference)
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
		var past_reference: Dictionary = PSBattingReference.for_season(past_year, past_season_number)
		_append_stat_sample(
			samples,
			past.batter_stats,
			pow(decay, float(k)),
			past_reference["stats"] as Dictionary
		)
	return samples


static func _append_stat_sample(
	samples: Array, stats: PSBatterStats, decay: float, distributions: Dictionary
) -> void:
	if stats == null or stats.plate_appearances <= 0:
		return
	var plate_appearances: float = float(stats.plate_appearances)
	var weight: float = decay * plate_appearances / (plate_appearances + PA_RELIABILITY_ANCHOR)
	if weight <= 0.0:
		return
	var average: float = stats.batting_average()
	samples.append({
		"weight": weight,
		"average": PSBattingReference.normalized(average, distributions, "average"),
		"on_base": PSBattingReference.normalized(stats.on_base_percentage(), distributions, "on_base"),
		"isolated_power": PSBattingReference.normalized(
			stats.slugging_percentage() - average, distributions, "isolated_power"
		),
		"ops": PSBattingReference.normalized(stats.ops(), distributions, "ops"),
	})


static func _blend(
	ability_index: float, samples: Array, stat_key: String, ability_prior: float
) -> float:
	var numerator: float = ability_index * ability_prior
	var denominator: float = ability_prior
	for sample_row in samples:
		var sample: Dictionary = sample_row as Dictionary
		var weight: float = float(sample["weight"])
		numerator += float(sample[stat_key]) * weight
		denominator += weight
	return numerator / denominator
