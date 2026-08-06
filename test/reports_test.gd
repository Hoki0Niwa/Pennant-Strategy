extends GdUnitTestSuite

# レポートの health チェック (services/reports/report_health.gd) の受入条件を固定する。
# 長期オートプレイを回さずに閾値と参照先だけを検証するので、帯を動かしたらここも一緒に直す。

const ReportHealth = preload("res://services/reports/report_health.gd")


# 戦力外フェーズの支配下枠除外数は「戦力外通告 + 育成降格」で数える。
# 通告だけを見ていた頃は育成降格の分を取りこぼし、実際の枠の空き方より過少に出ていた。
func test_long_distributions_released_flow_counts_controlled_removals() -> void:
	var report: Dictionary = {
		"yearly": [
			_yearly_row(90, 30),
			_yearly_row(80, 25),
		],
	}
	var flows: Dictionary = (ReportHealth.long_distributions(report).get("flows", {}) as Dictionary)
	var released: Dictionary = flows.get("released", {}) as Dictionary
	assert_float(float(released.get("min", 0.0))).is_equal_approx(105.0, 0.001)
	assert_float(float(released.get("max", 0.0))).is_equal_approx(120.0, 0.001)
	assert_float(float(released.get("mean", 0.0))).is_equal_approx(112.5, 0.001)


# 帯は NPB 実測 (12月頭の支配下自由契約公示から外国人を除いた日本人 104〜129人/年) に合わせてある。
func test_long_health_released_per_year_band_matches_npb() -> void:
	assert_str(_released_status(113.0)).is_equal("pass")
	assert_str(_released_status(96.0)).is_equal("warn")
	assert_str(_released_status(130.0)).is_equal("warn")
	assert_str(_released_status(80.0)).is_equal("fail")
	assert_str(_released_status(145.0)).is_equal("fail")


func _yearly_row(released: int, demoted: int) -> Dictionary:
	return {
		"offseason": {
			"released_count": released,
			"demoted_count": demoted,
			"controlled_removed_count": released + demoted,
		},
	}


func _released_status(released_per_year: float) -> String:
	var health: Dictionary = ReportHealth.long_health({
		"window_summaries": {"last_10_years": {"released_per_year": released_per_year}},
	})
	for check_value in health.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if str(check.get("id", "")) == "released_per_year":
			return str(check.get("status", ""))
	return ""
