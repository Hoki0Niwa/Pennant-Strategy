extends RefCounted
class_name PSAbilityScale

# File 2 §4.1: 内部値(z-score) ↔ 表示値 ↔ 総合値(1〜1000) の変換。
#
# シミュレーション側 (plate_appearance_coordinator, play_resolver, fielding_model 等)
# も UI 側 (player_visible_ratings) も同じ線形変換を使う:
#   display = max(round(50 + z * 12.5), 1)
# 能力に上限は無いので、表示値も 100 を越える (z = 4.0 で 100)。
#
# 例:
# - z=-1.5 → display 31
# - z= 0.0 → display 50
# - z=+1.0 → display 63
# - z=+2.0 → display 75
# - z=+4.4 → display 105
const DISPLAY_MEAN: float = 50.0
const DISPLAY_STDEV: float = 12.5
const DISPLAY_MIN: int = 1
# 調査画面 (バランスレポート / ドラフトシミュレータ) の表示値入力欄の上限。能力の上限ではない。
const DISPLAY_MAX: int = 100
# soft_clamp_z が限界の手前から曲げ始める幅 (z)。上げると限界の手前の広い範囲が圧縮され、
# 下げると限界の直前に値が寄って表示値の山ができやすくなる。
const SOFT_BOUND_KNEE_Z: float = 0.6


static func z_to_display(z_value: float) -> int:
	return maxi(int(round(DISPLAY_MEAN + z_value * DISPLAY_STDEV)), DISPLAY_MIN)


static func display_to_z(display_value: int) -> float:
	return (float(display_value) - DISPLAY_MEAN) / DISPLAY_STDEV


# 限界の knee 手前から tanh で限界へ漸近させる clamp。限界から knee 以上内側の値はそのまま。
# 順序を保ったまま限界に届かないので、clampf と違って限界値に同じ値の山 (張り付き) ができない。
static func soft_clamp_z(value: float, min_z: float, max_z: float, knee: float = SOFT_BOUND_KNEE_Z) -> float:
	var width: float = minf(knee, (max_z - min_z) * 0.5)
	if width <= 0.0:
		return clampf(value, min_z, max_z)
	var upper_start: float = max_z - width
	if value > upper_start:
		return upper_start + width * tanh((value - upper_start) / width)
	var lower_start: float = min_z + width
	if value < lower_start:
		return lower_start - width * tanh((lower_start - value) / width)
	return value
