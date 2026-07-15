extends RefCounted
class_name ReleaseValueProjector

# 戦力外判断の projection 軸。「今後 PROJECTION_HORIZON_YEARS 年の期待戦力価値」を
# current + usage_evidence + growth - injury_penalty - salary_penalty の1スカラーへ合成する。
# 出場実績は二値保護ではなく current への連続的な乗算割引として扱い、怪我で説明できる欠場は
# season_injury_days に応じて割引を免除する。

const TeamAutoAI = preload("res://services/season/team_auto_ai.gd")
const TeamFinance = preload("res://services/season/team_finance.gd")
const OFFSEASON_SERVICE_PATH: String = "res://services/season/offseason_service.gd"

# 何年先までの成長期待を見込むか。現行 future_value_score (育成整理用) の 6 年より短く、
# 戦力外判断は「今すぐ切るか」なので直近の期待値に絞る。
const PROJECTION_HORIZON_YEARS: int = 3
# expected_development_score_bonus の生値 (概ね -8..+12) を current (overall スケール, 概ね
# 30-90) と同じ桁に引き伸ばす係数。
# 手計算 (2026-07-14, PROJECTION_HORIZON_YEARS=3 時点):
#   age=20: 20/21/22歳はいずれも成長曲線が同一区分 (覚醒1% 成長59% 停滞40% 衰退0%) で
#     year_bonus=(1*8+59*2.6)/100=1.614、3年分を future_weight (0.86 減衰) で合成すると
#     1.614*(1+0.86+0.86^2)≈4.196 -> growth ≈ 4.196*4.0 ≈ +16.8
#   age=35: 35/36/37歳は衰退が優勢 (major_decline 18-23% decline 50-65%) で year_bonus は
#     -2.03/-2.47/-2.68、合成すると ≈-6.14 -> growth ≈ -6.14*4.0 ≈ -24.6
#   両者の差は約41点で、同能力の21歳と33歳を比較する回帰テストが有意差として拾える大きさ。
const PROJECTION_GROWTH_WEIGHT: float = 4.0
# ゼロ出場時に current から割り引く最大比率。出場実績は「能力主張が実戦で裏付けられているか」の
# ベイズ的証拠として扱い、加点ではなく乗算割引にする: 能力が高いのに全く使われていない選手ほど
# 絶対値で大きく疑われる (overall 71 のゼロ出場 -24.9 点 / overall 45 のゼロ出場 -15.8 点)。
# フル出場 (usage_saturation=1) で割引なし。上げるとゼロ出場の高能力選手が放出側へ寄る。
const USAGE_ZERO_DISCOUNT: float = 0.35
# 出場割引が飽和する役割別の稼働量。投手は先発/救援の高い側を採用する。
const USAGE_SATURATION_FIELDER_GAMES: int = 80
const USAGE_SATURATION_STARTER_STARTS: int = 13
const USAGE_SATURATION_RELIEVER_APPEARANCES: int = 30
# シーズンの過半を怪我で欠場した場合は、出場ゼロでも能力主張を割り引かない。
# 小さいほど怪我欠場への免除が早く効く。
const INJURY_EXCUSE_FULL_DAYS: int = 90
# 年俸減点の減衰係数。overall の replacement〜スター差 ≈40 点に対し年俸スプレッドは
# 440万〜8億 ≈ 8億なので、1点 ≈ 2000万が妥当なスケール。TeamFinance.ai_acquisition_cost_penalty
# は 1点=1000万 (AI_SALARY_COST_PER_SCORE) の線形なので 0.4〜0.5 に減衰して使う。
# 上げると高年俸ほど放出側へ寄る (1.0 だと3.9億の主力が -39 点でフリンジ以下に落ちる)。
const SALARY_COST_WEIGHT: float = 0.4


# {"current","growth","usage_evidence","injury_penalty","salary_penalty","total"} を返す。
# projected_value() はこの "total" と同じ値。
# "current" は割引前の生値、"usage_evidence" は出場割引によるデルタ (effective_current - current,
# 常に 0 以下) で、total = current + usage_evidence + growth - injury_penalty - salary_penalty。
static func projected_value_components(player: PSPlayer, record: PSPlayerSeasonRecord) -> Dictionary:
	var effective_record: PSPlayerSeasonRecord = record
	if effective_record == null and player != null:
		effective_record = PSPlayerSeasonRecord.from_player(player, 0, 0)

	var current: float = TeamAutoAI.overall_prior(effective_record) if effective_record != null else 0.0
	var age: int = player.age if player != null else 0
	var position: int = player.position if player != null else 0
	# Runtime load keeps this projector reusable from OffseasonService without a preload cycle.
	var offseason_service: GDScript = load(OFFSEASON_SERVICE_PATH) as GDScript
	var growth: float = offseason_service.expected_development_score_bonus(age, PROJECTION_HORIZON_YEARS, position) * PROJECTION_GROWTH_WEIGHT
	var usage: float = usage_saturation(record)
	if record != null:
		var injury_excuse: float = clampf(float(record.season_injury_days) / float(INJURY_EXCUSE_FULL_DAYS), 0.0, 1.0)
		usage = maxf(usage, injury_excuse)
	var usage_evidence: float = -current * USAGE_ZERO_DISCOUNT * (1.0 - usage)
	var injury_penalty: float = offseason_service.injury_value_penalty(player)
	var salary: int = player.salary if player != null else 0
	var salary_penalty: float = TeamFinance.ai_acquisition_cost_penalty(salary) * SALARY_COST_WEIGHT
	var total: float = current + usage_evidence + growth - injury_penalty - salary_penalty
	return {
		"current": current,
		"growth": growth,
		"usage_evidence": usage_evidence,
		"injury_penalty": injury_penalty,
		"salary_penalty": salary_penalty,
		"total": total,
	}


static func projected_value(player: PSPlayer, record: PSPlayerSeasonRecord) -> float:
	return float(projected_value_components(player, record).get("total", 0.0))


# 出場実績を 0..1 の連続値へ正規化し、崖ではなく緩やかな坂として出場割引へ効かせる。
# 救援転向のスイングマンを損なわないよう
# 投手は先発/救援どちらか高い方 (max) を採用する。
static func usage_saturation(record: PSPlayerSeasonRecord) -> float:
	if record == null:
		return 0.0
	if record.is_pitcher():
		var starter_ratio: float = clampf(float(record.pitcher_stats.starts) / float(USAGE_SATURATION_STARTER_STARTS), 0.0, 1.0)
		var reliever_ratio: float = clampf(float(record.pitcher_stats.relief_appearances) / float(USAGE_SATURATION_RELIEVER_APPEARANCES), 0.0, 1.0)
		return maxf(starter_ratio, reliever_ratio)
	return clampf(float(record.batter_stats.games) / float(USAGE_SATURATION_FIELDER_GAMES), 0.0, 1.0)
