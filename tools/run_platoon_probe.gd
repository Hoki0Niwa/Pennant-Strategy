extends Node

# 左右 (プラトーン) の実効スプリットを実測する調査ツール。production の定数は変更しない。
#
#   godot --headless --path . res://tools/run_platoon_probe.tscn -- --seed=12345
#   godot --headless --path . res://tools/run_platoon_probe.tscn -- --pa=10000   (精密)
#   godot --headless --path . res://tools/run_platoon_probe.tscn -- --pa=400     (動作確認)
#
# 同じ一軍母集団を「相手投手が全員右」「全員左」の 2 条件で回し、打者ごとの
# 有利 - 不利 の OPS 差を出す。投手は複製して利き腕だけ書き換えるので、
# 実在の左投手プールの質の差 (初期ワールドで 0.070σ = OPS .014 相当) は混入しない。
#
# 詳細は docs/agent_memory/project_platoon_usage.md を参照。

const RunnerScript = preload("res://services/reports/platoon_probe_runner.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/platoon_probe_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/platoon_probe_latest.csv"


func _ready() -> void:
	var options: Dictionary = _parse_args()
	if bool(options.get("help", false)):
		_print_usage()
		get_tree().quit(0)
		return

	var runner: Object = RunnerScript.new()
	var report: Dictionary = runner.run(options)
	if not bool(report.get("ok", false)):
		for error in (report.get("errors", []) as Array):
			print("ERROR: %s" % str(error))
		get_tree().quit(1)
		return

	var output_path: String = str(options.get("output", DEFAULT_OUTPUT_PATH))
	var write_ok: bool = _write_text(output_path, JSON.stringify(report, "\t"))
	var csv_path: String = str(options.get("csv", DEFAULT_CSV_PATH))
	var csv_ok: bool = _write_text(csv_path, runner.csv_text(report))

	_print_report(report, output_path if write_ok else "", csv_path if csv_ok else "")

	var health: Dictionary = report.get("health", {}) as Dictionary
	var failed: bool = str(health.get("status", "pass")) == "fail"
	get_tree().quit(0 if write_ok and csv_ok and not failed else 1)


func _parse_args() -> Dictionary:
	var options: Dictionary = {
		"seed": 12345,
		"target_pa": RunnerScript.DEFAULT_TARGET_PA,
		"output": DEFAULT_OUTPUT_PATH,
		"csv": DEFAULT_CSV_PATH,
	}

	var args: Array = []
	for user_arg in OS.get_cmdline_user_args():
		args.append(str(user_arg))
	for engine_arg in OS.get_cmdline_args():
		args.append(str(engine_arg))

	for arg_value in args:
		var arg: String = str(arg_value)
		if arg == "--help" or arg == "-h":
			options["help"] = true
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--pa="):
			options["target_pa"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--csv="):
			options["csv"] = arg.get_slice("=", 1)
	return options


func _print_report(report: Dictionary, output_path: String, csv_path: String) -> void:
	var summary: Dictionary = report.get("summary", {}) as Dictionary
	var design: Dictionary = report.get("design", {}) as Dictionary
	var profile: Dictionary = report.get("reference_population", {}) as Dictionary
	print("=== Platoon probe (seed %d) ===" % int(report.get("seed", 0)))
	print("Design   : 打者 %d人 × 片腕 %d打席 (実測 %d) / %d試合・条件" % [
		int(summary.get("batters", 0)),
		int(design.get("target_pa_per_batter_per_hand", 0)),
		int(summary.get("pa_per_batter_per_hand", 0)),
		int(summary.get("games_per_condition", 0)),
	])
	print("Pop      : 一軍スタメン %d球団 / 打者 z %+.2f (n=%d) / 投手 z %+.2f (n=%d)" % [
		int(profile.get("teams", 0)),
		float(profile.get("batter_level", 0.0)), int(profile.get("batter_sample", 0)),
		float(profile.get("pitcher_level", 0.0)), int(profile.get("pitcher_sample", 0)),
	])
	print("Fixed    : %s" % str(design.get("held_fixed", "")))
	print("RefPoint : 対右 OPS %.3f / 対左 OPS %.3f" % [
		float(summary.get("reference_ops_vs_right", 0.0)),
		float(summary.get("reference_ops_vs_left", 0.0)),
	])
	print("")

	# 名目 = 打者ごとのシフト量 × 応答曲面の傾き。実効がこれより小さければテール圧縮で削られている。
	print("--- 実効スプリット (有利 - 不利) ---")
	print("係数     : base %.3fσ / 左打者 ×%.2f / Bat_Platoon 1σ あたり -%.0f%%" % [
		float(design.get("base_shift_z", 0.0)),
		float(design.get("left_batter_shift_ratio", 1.0)),
		float(design.get("platoon_shift_per_z", 0.0)) * 100.0,
	])
	print("名目 OPS 平均 (2 × shift × %.4f/σ) : %.4f" % [
		float(design.get("ops_per_sigma", 0.0)),
		float(summary.get("mean_nominal_split_ops", 0.0)),
	])
	print("実効 OPS 平均                   : %.4f ± %.4f (標本誤差) = 名目の %.2f 倍" % [
		float(summary.get("mean_split_ops", 0.0)),
		float(summary.get("mean_split_standard_error", 0.0)),
		float(summary.get("compression_ratio", 0.0)),
	])
	print("実効 K%% 平均 (不利 - 有利)      : %+.4f" % float(summary.get("mean_split_strikeout_rate", 0.0)))
	print("実効 HR%% 平均 (有利 - 不利)     : %+.4f" % float(summary.get("mean_split_home_run_rate", 0.0)))
	print("")
	print("打者間のばらつき: 観測SD %.4f = 真のSD %.4f + 標本誤差SD %.4f" % [
		float(summary.get("split_observed_sd_ops", 0.0)),
		float(summary.get("split_true_sd_ops", 0.0)),
		float(summary.get("split_noise_sd_ops", 0.0)),
	])
	print("逆スプリット (実効 < 0) : %d人 (%.1f%%)" % [
		int(summary.get("reverse_split_batters", 0)),
		float(summary.get("reverse_split_share", 0.0)) * 100.0,
	])
	print("傾き: Bat_Platoon z あたり %+.4f (名目 %+.4f) / 能力水準 z あたり %+.4f" % [
		float(summary.get("slope_vs_platoon_z", 0.0)),
		float(summary.get("nominal_slope_vs_platoon_z", 0.0)),
		float(summary.get("slope_vs_level_z", 0.0)),
	])
	print("")

	var by_side: Dictionary = summary.get("by_batting_side", {}) as Dictionary
	if not by_side.is_empty():
		print("--- 打席左右ごと (MLB実測: 右 .060 / 左 .096) ---")
		for side_value in by_side.keys():
			var side: Dictionary = by_side[side_value] as Dictionary
			print("%-4s %3d人  平均スプリット %.4f ± %.4f" % [
				str(side_value), int(side.get("batters", 0)),
				float(side.get("mean_split_ops", 0.0)), float(side.get("standard_error", 0.0)),
			])
		print("")

	_print_quartiles(summary.get("by_level_quartile", []) as Array, "能力水準 z", "テール圧縮が効くと上位帯ほど縮む")
	_print_quartiles(summary.get("by_platoon_quartile", []) as Array, "Bat_Platoon z", "左右対応が高い帯ほどスプリットが小さいのが正")

	var batters: Array = report.get("batters", []) as Array
	if batters.size() >= 6:
		print("--- 実効スプリットの両端 (標本誤差 ±%.3f なので個人の順位は読まない) ---" % [
			float((batters[0] as Dictionary).get("split_standard_error", 0.0)),
		])
		for index in [0, 1, 2, batters.size() - 3, batters.size() - 2, batters.size() - 1]:
			var row: Dictionary = batters[index] as Dictionary
			print("  %-14s %s  水準 %+.2f / 左右対応 %+.2f → 有利 %.3f 不利 %.3f = %+.4f" % [
				str(row.get("name", "")), str(row.get("bats", "")),
				float(row.get("level_z", 0.0)), float(row.get("platoon_z", 0.0)),
				float(row.get("ops_advantage", 0.0)), float(row.get("ops_disadvantage", 0.0)),
				float(row.get("split_ops", 0.0)),
			])
		print("")

	var health: Dictionary = report.get("health", {}) as Dictionary
	print("--- 判定 ---")
	for check_value in (health.get("checks", []) as Array):
		var check: Dictionary = check_value as Dictionary
		print("[%-4s] %-24s %+8.4f  帯 %s  %s" % [
			str(check.get("status", "")),
			str(check.get("name", "")),
			float(check.get("value", 0.0)),
			str(check.get("band", [])),
			str(check.get("description", "")),
		])
	print("Health   : %s (fail=%d warn=%d)" % [
		str(health.get("status", "")), int(health.get("fail", 0)), int(health.get("warn", 0)),
	])
	if not output_path.is_empty():
		print("JSON     : %s" % output_path)
	if not csv_path.is_empty():
		print("CSV      : %s" % csv_path)


func _print_quartiles(table: Array, label: String, note: String) -> void:
	if table.is_empty():
		return
	print("--- %s の四分位ごと (%s) ---" % [label, note])
	for row_value in table:
		var row: Dictionary = row_value as Dictionary
		print("  Q%d (%s 平均 %+.2f, %d人)  平均スプリット %.4f" % [
			int(row.get("quartile", 0)), label,
			float(row.get("mean_key_value", 0.0)), int(row.get("batters", 0)),
			float(row.get("mean_split_ops", 0.0)),
		])
	print("")


func _write_text(path: String, text: String) -> bool:
	var global_path: String = ProjectSettings.globalize_path(path)
	var make_dir_error: Error = DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	if make_dir_error != OK:
		print("Output directory error: %s" % error_string(make_dir_error))
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Output file error: %s" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(text)
	file.close()
	return true


func _print_usage() -> void:
	print("""
run_platoon_probe — 左右 (プラトーン) の実効スプリットを実測する

  --seed=N       乱数シード (既定 12345)
  --pa=N         1打者・片腕あたりの目標打席数 (既定 2000)
                 スプリットの標本誤差は 1.27 × √(2/N)
                 = 2,000 で ±.040 / 10,000 で ±.018 / 65,000 で ±.007
                 リーグ平均はさらに √打者数 で縮むので、既定でも ±.004 程度
  --output=PATH  JSON 出力先 (既定 res://reports/platoon_probe_latest.json)
  --csv=PATH     CSV 出力先 (既定 res://reports/platoon_probe_latest.csv)
""")
