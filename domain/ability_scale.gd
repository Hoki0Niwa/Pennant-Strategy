extends RefCounted
class_name PSAbilityScale

# File 2 §4.1: 内部値(z-score) ↔ 表示値(1〜100) ↔ 総合値(1〜1000) の変換。
#
# シミュレーション側 (plate_appearance_coordinator, play_resolver, fielding_model 等)
# も UI 側 (player_visible_ratings) も同じ線形変換を使う:
#   display = clamp(round(50 + z * 12.5), 1, 100)
#
# 例:
# - z=-1.5 → display 31
# - z= 0.0 → display 50
# - z=+1.0 → display 63
# - z=+2.0 → display 75
const DISPLAY_MEAN: float = 50.0
const DISPLAY_STDEV: float = 12.5
const DISPLAY_MIN: int = 1
const DISPLAY_MAX: int = 100


static func z_to_display(z_value: float) -> int:
	return clampi(int(round(DISPLAY_MEAN + z_value * DISPLAY_STDEV)), DISPLAY_MIN, DISPLAY_MAX)


static func display_to_z(display_value: int) -> float:
	return (float(display_value) - DISPLAY_MEAN) / DISPLAY_STDEV
