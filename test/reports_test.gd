extends GdUnitTestSuite

# レポートの health チェック (services/reports/report_health.gd) の受入条件を固定する。
# 長期オートプレイを回さずに閾値と参照先だけを検証するので、帯を動かしたらここも一緒に直す。

const ReportHealth = preload("res://services/reports/report_health.gd")


# PA 応答曲面は**初期ワールドの一軍**を動作点として測る。打線と守備の選出は
# `PSPerformanceReference` の静的キャッシュを参照するので、別 suite が合成リーグで温めた
# 基準分布が残っていると δ=0 セルがその母集団の水準になり、動作点の検査が意味を失う
# (実測: 得点/27アウト が 4.09 → 2.10)。レポートツールは常に新しいプロセスで走るので、
# ここでも世界・レコード・基準分布を作り直して同じ条件にする。
func before() -> void:
	GameDb.load_initial_data()
	RecordStore.clear_records()
	PSPerformanceReference.reset_cache()


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


# ベテランの積み上がりはシェアで見る。平均年齢だけだと若手の増減で相殺されて動かず、
# 15年かけた高齢化が素通りする (旧 last10_average_age の帯 25-30 がまさにそれだった)。
# 分母は**支配下のみ** (育成の人数が NPB と倍違うので全登録では比較にならない)。
# 帯は NPB 支配下の 35歳以上 6.6% を基準に、warn 8.5% / fail 10.5%。
func test_long_health_age_35_plus_share_band_tracks_npb() -> void:
	assert_str(_age_35_plus_share_status(0.066)).is_equal("pass")
	assert_str(_age_35_plus_share_status(0.097)).is_equal("warn")
	assert_str(_age_35_plus_share_status(0.120)).is_equal("fail")


# 集計キーが無い (= 世界が空の) レポートでも例外を出さず pass 側に倒れること。
func test_long_health_age_35_plus_share_handles_empty_roster() -> void:
	var health: Dictionary = ReportHealth.long_health({"window_summaries": {"last_10_years": {}}})
	for check_value in health.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if str(check.get("id", "")) == "last10_age_35_plus_share":
			assert_str(str(check.get("status", ""))).is_equal("pass")
			return
	fail("last10_age_35_plus_share check missing")


func _age_35_plus_share_status(share: float) -> String:
	var health: Dictionary = ReportHealth.long_health({
		"window_summaries": {"last_10_years": {"controlled_age_35_plus_share": share}},
	})
	for check_value in health.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if str(check.get("id", "")) == "last10_age_35_plus_share":
			return str(check.get("status", ""))
	return ""


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


# --- PA 応答曲面 (services/reports/pa_response_surface_runner.gd) ---
# 能力差 → 結果 の傾きを測る計測層。値そのものは較正の対象なので固定しない。
# 固定するのは「曲面が読める形で出ること」= 符号と整合性の構造だけ。
# 詳細は docs/agent_memory/project_pa_talent_sensitivity_calibration.md。

const PaResponseSurface = preload("res://services/reports/pa_response_surface_runner.gd")

# 短縮グリッド。1セル 270 アウト = 10試合ぶんで、構造の検査には足りる。
const SURFACE_OPTIONS: Dictionary = {
	"batter_offsets": [-0.8, 0.0],
	"pitcher_offsets": [-0.8, 0.0],
	"target_outs": 270,
	"seed": 4242,
}


# 打者を強くすれば得点は増え、投手を強くすれば減る。この符号が崩れたら曲面を読む意味がない。
# 併せて「対角 = 打者傾き + 投手傾き」が成り立つこと (局所線形なので定義上一致する) を確認する。
func test_pa_response_surface_slopes_have_the_expected_signs() -> void:
	var report: Dictionary = PaResponseSurface.new().run(SURFACE_OPTIONS)
	assert_bool(bool(report.get("ok", false))).is_true()
	assert_int((report.get("cells", []) as Array).size()).is_equal(4)

	var runs: Dictionary = (report.get("slopes", {}) as Dictionary).get("runs_per_game", {}) as Dictionary
	var batter_slope: float = float(runs.get("batter_slope", 0.0))
	var pitcher_slope: float = float(runs.get("pitcher_slope", 0.0))
	assert_float(batter_slope).is_greater(0.0)
	assert_float(pitcher_slope).is_less(0.0)
	assert_float(float(runs.get("diagonal_slope", 0.0))).is_equal_approx(batter_slope + pitcher_slope, 0.001)


# δ=0 のセルは一軍の動作点でなければならない。ここがずれると「別の場所の傾き」を測ってしまうので、
# 母集団の作り方 (スタメン選出・投手の抽出) を変えたらこのテストが先に落ちる。
func test_pa_response_surface_reference_cell_reproduces_the_first_team() -> void:
	var report: Dictionary = PaResponseSurface.new().run(SURFACE_OPTIONS)
	var reference: Dictionary = report.get("reference_cell", {}) as Dictionary
	assert_dict(reference).is_not_empty()
	# 帯は report_health.gd のリーグ帯より広く取る (270 アウトの標本誤差ぶん)。
	assert_float(float(reference.get("runs_per_game", 0.0))).is_between(2.2, 5.2)
	assert_float(float(reference.get("strikeout_rate", 0.0))).is_between(0.14, 0.25)
	assert_float(float(reference.get("walk_rate", 0.0))).is_between(0.05, 0.12)
	assert_float(float(reference.get("babip", 0.0))).is_between(0.24, 0.38)

	var population: Dictionary = report.get("reference_population", {}) as Dictionary
	assert_int(int(population.get("teams", 0))).is_equal(GameDb.teams.size())
	# 専用球団 (GameDb.farm_clubs) が母集団へ混ざっていないこと。混ざると水準が下がり動作点が狂う。
	assert_int(int(population.get("batter_sample", 0))).is_equal(GameDb.teams.size() * 9)


# 同じ seed で2回走らせたら完全に一致する。Rng レーンを跨ぐ計測なので決定性を明示的に張る。
func test_pa_response_surface_is_deterministic_for_a_seed() -> void:
	var first: Dictionary = PaResponseSurface.new().run(SURFACE_OPTIONS)
	var second: Dictionary = PaResponseSurface.new().run(SURFACE_OPTIONS)
	assert_str(JSON.stringify(first.get("cells", []))).is_equal(JSON.stringify(second.get("cells", [])))
