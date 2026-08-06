extends RefCounted
class_name StrengthGrade

# 戦力値を S〜E の6段階へ落とす共有ロジック (2026-08-05)。
#
# **なぜグレードか**: 打撃/投手レーティングやデプスチャートの評価値は、12球団ぶんを並べると
# どれも似た数字 (例: 68〜74) に収まってしまい、素の数値では強弱が読み取れない。
# そこで**同じ母集団 (= 全球団の同じ指標) の中での相対位置**を z に直し、段階に切って見せる。
# 絶対値の閾値は使わない — 世界再生成やバランス較正で数値帯が動いても表示が壊れないため。
#
# 使う側は「比較対象の一覧」をそのまま sample に渡す:
#   - チーム選択画面 … 全12球団の打撃レーティング / 投手レーティング
#   - デプスチャート … 全12球団の同一スロットの現在値 / 将来値

const GRADES: Array = ["S", "A", "B", "C", "D", "E"]

# GRADES と同じ並びの下限 z (S から順)。最後の E は下限なし。
# 12球団の正規分布でおおよそ S:1 / A:2 / B:3 / C:3 / D:2 / E:1 球団に散る幅。
const Z_THRESHOLDS: Array = [1.4, 0.7, 0.15, -0.5, -1.2]

# 母集団のばらつきがこれ未満なら全球団横並びとみなし、無理に段階を付けず中央 (C) を返す。
const MIN_STDDEV: float = 0.0001


static func from_z(z: float) -> String:
	for index in range(Z_THRESHOLDS.size()):
		if z >= float(Z_THRESHOLDS[index]):
			return str(GRADES[index])
	return str(GRADES[GRADES.size() - 1])


# sample (比較対象の全値) の中での value のグレード。
static func from_sample(value: float, sample: Array) -> String:
	return from_z(z_in_sample(value, sample))


# sample 内での z スコア (母集団標準偏差)。sample が空/ばらつき無しなら 0。
static func z_in_sample(value: float, sample: Array) -> float:
	if sample.is_empty():
		return 0.0
	var total: float = 0.0
	for entry in sample:
		total += float(entry)
	var mean: float = total / float(sample.size())
	var variance: float = 0.0
	for entry in sample:
		variance += pow(float(entry) - mean, 2.0)
	var stddev: float = sqrt(variance / float(sample.size()))
	if stddev < MIN_STDDEV:
		return 0.0
	return (value - mean) / stddev


# バーの伸び (0〜1)。**最大値との比ではなく sample 内の min-max 正規化**にしてある —
# 生値は12球団が数点差に収まるため最大値比だと全球団のバーがほぼ同じ長さになり、
# 添えたグレードと見た目が矛盾する。最下位のバーが消えないよう BAR_FLOOR を底上げする。
const BAR_FLOOR: float = 0.12

static func fill_ratio(value: float, sample: Array) -> float:
	if sample.is_empty():
		return 0.0
	var lowest: float = float(sample[0])
	var highest: float = float(sample[0])
	for entry in sample:
		lowest = minf(lowest, float(entry))
		highest = maxf(highest, float(entry))
	if highest - lowest < MIN_STDDEV:
		return 1.0
	var normalized: float = clampf((value - lowest) / (highest - lowest), 0.0, 1.0)
	return BAR_FLOOR + (1.0 - BAR_FLOOR) * normalized
