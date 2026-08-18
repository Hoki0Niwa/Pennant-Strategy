extends Node

# 能力水準 (z) → 打席結果 の伝達関数を実測する調査ツール。production の定数は変更しない。
#
#   godot --headless --path . res://tools/run_pa_response_surface.tscn -- --seed=12345
#   godot --headless --path . res://tools/run_pa_response_surface.tscn -- --outs=1350   (短縮確認)
#   godot --headless --path . res://tools/run_pa_response_surface.tscn -- --offsets=-1.6:0.4:0.4
#
# 軸は一軍相当プロファイルからのオフセット δ (σ)。δ=0 が一軍の動作点。
# 詳細と改装計画は docs/agent_memory/project_pa_talent_sensitivity_calibration.md を参照。

const RunnerScript = preload("res://services/reports/pa_response_surface_runner.gd")
const DEFAULT_OUTPUT_PATH: String = "res://reports/pa_response_surface_latest.json"
const DEFAULT_CSV_PATH: String = "res://reports/pa_response_surface_latest.csv"


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
		"target_outs": 4050,
		"batter_offsets": [],
		"pitcher_offsets": [],
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
		elif arg.begins_with("--outs="):
			options["target_outs"] = int(arg.get_slice("=", 1))
		elif arg.begins_with("--games="):
			options["target_outs"] = int(arg.get_slice("=", 1)) * 27
		elif arg.begins_with("--offsets="):
			var shared: Array = _parse_offsets(arg.get_slice("=", 1))
			options["batter_offsets"] = shared
			options["pitcher_offsets"] = shared.duplicate()
		elif arg.begins_with("--batter-offsets="):
			options["batter_offsets"] = _parse_offsets(arg.get_slice("=", 1))
		elif arg.begins_with("--pitcher-offsets="):
			options["pitcher_offsets"] = _parse_offsets(arg.get_slice("=", 1))
		elif arg.begins_with("--output="):
			options["output"] = arg.get_slice("=", 1)
		elif arg.begins_with("--csv="):
			options["csv"] = arg.get_slice("=", 1)
	return options


# "-0.8,0,0.4" のリスト、または "start:end:step" のレンジを受け取る。
func _parse_offsets(text: String) -> Array:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return []
	var offsets: Array = []
	# 負値を含むので ":" のレンジ形式かどうかは区切り数で判定する。
	var range_parts: PackedStringArray = trimmed.split(":", false)
	if range_parts.size() == 3:
		var start_value: float = float(range_parts[0])
		var end_value: float = float(range_parts[1])
		var step: float = max(0.01, abs(float(range_parts[2])))
		var value: float = start_value
		while value <= end_value + 0.0001:
			offsets.append(value)
			value += step
		return offsets
	for part in trimmed.split(",", false):
		offsets.append(float(str(part).strip_edges()))
	return offsets


func _print_report(report: Dictionary, output_path: String, csv_path: String) -> void:
	var grid: Dictionary = report.get("grid", {}) as Dictionary
	var profile: Dictionary = report.get("reference_population", {}) as Dictionary
	print("=== PA response surface (seed %d) ===" % int(report.get("seed", 0)))
	print("Grid     : 打者δ %s × 投手δ %s / %d アウト・セル" % [
		str(grid.get("batter_offsets", [])),
		str(grid.get("pitcher_offsets", [])),
		int(grid.get("target_outs_per_cell", 0)),
	])
	# 実測プロファイル。run_farm_report の usage_levels (一軍 打者 +1.60 / 投手 +1.75) と
	# 大きく離れていたら、抽出条件かワールドが想定と違う。
	print("Pop      : 一軍スタメン %d球団 / 打者 z %+.2f (n=%d) / 投手 z %+.2f (n=%d)" % [
		int(profile.get("teams", 0)),
		float(profile.get("batter_level", 0.0)), int(profile.get("batter_sample", 0)),
		float(profile.get("pitcher_level", 0.0)), int(profile.get("pitcher_sample", 0)),
	])
	print("Fixed    : %s" % str(grid.get("held_fixed", "")))
	var reference_cell: Variant = report.get("reference_cell", null)
	if reference_cell != null:
		# δ=0 セル = 一軍の動作点。実 NPB (R/G 3.4-3.5 / OPS .666-.673 / K% 19.3 / BB% 8.3) と
		# 見比べる。ここがずれていると傾きを読む場所そのものがずれる。
		var cell: Dictionary = reference_cell as Dictionary
		print("RefCell  : δ=0 → R/G %.2f / OPS %.3f / K%% %.1f / BB%% %.1f / BABIP %.3f / EV %.1f" % [
			float(cell.get("runs_per_game", 0.0)), float(cell.get("ops", 0.0)),
			float(cell.get("strikeout_rate", 0.0)) * 100.0, float(cell.get("walk_rate", 0.0)) * 100.0,
			float(cell.get("babip", 0.0)), float(cell.get("mean_exit_velocity", 0.0)),
		])
	print("")

	_print_matrix(report, "runs_per_game", "得点/27ｱｳﾄ", 2)
	_print_matrix(report, "strikeout_rate", "K%", 3)
	_print_matrix(report, "home_runs_per_game", "HR/27ｱｳﾄ", 3)
	_print_matrix(report, "ops", "OPS", 3)

	print("--- 傾き (水準 +1σ あたりの変化) ---")
	print("%-22s %10s %10s %10s" % ["metric", "打者", "投手", "対角"])
	for metric_value in (report.get("slopes", {}) as Dictionary).keys():
		var metric: String = str(metric_value)
		var entry: Dictionary = (report["slopes"] as Dictionary)[metric] as Dictionary
		print("%-22s %+10.4f %+10.4f %+10.4f" % [
			metric,
			float(entry.get("batter_slope", 0.0)),
			float(entry.get("pitcher_slope", 0.0)),
			float(entry.get("diagonal_slope", 0.0)),
		])
	print("※ 対角 = 打者と投手を同じだけ動かしたときの傾き。0 に近いほどレベル不変。")
	print("")

	var matchups: Array = report.get("matchups", []) as Array
	if not matchups.is_empty():
		print("--- 両側とも弱いチーム vs 標準チーム (専用球団のケース) ---")
		print("%-10s %10s %10s %12s" % ["水準差", "得点", "失点", "Pythag勝率"])
		for row_value in matchups:
			var row: Dictionary = row_value as Dictionary
			print("%-10s %10.2f %10.2f %12.3f" % [
				"-%.2fσ" % float(row.get("level_drop", 0.0)),
				float(row.get("runs_scored_per_game", 0.0)),
				float(row.get("runs_allowed_per_game", 0.0)),
				float(row.get("pythagorean_win_pct", 0.0)),
			])
		print("")

	var anchors: Dictionary = report.get("anchors", {}) as Dictionary
	var direct: Dictionary = anchors.get("direct", {}) as Dictionary
	var health: Dictionary = report.get("health", {}) as Dictionary
	print("--- 動作点とアンカー比較 (NPB 2013-2025 の一軍 vs ファーム) ---")
	for check_value in (health.get("checks", []) as Array):
		var check: Dictionary = check_value as Dictionary
		var value: Variant = check.get("value", null)
		# アンカー系は回帰値と「δ=0 → δ=-0.8 の直接差」を並べる。両者が大きく食い違ったら
		# 対角が非線形か標本が足りない。数値をそのまま結論にしないための併記。
		var metric_key: String = str(check.get("name", "")).replace("level_deviation_", "")
		var direct_column: String = ""
		if metric_key == "runs":
			direct_column = _direct_column(direct, "runs_per_game")
		elif metric_key == "strikeout_rate" or metric_key == "walk_rate":
			direct_column = _direct_column(direct, metric_key)
		elif metric_key == "home_runs":
			direct_column = _direct_column(direct, "home_runs_per_game")
		print("[%-4s] %-34s %s %-12s %s" % [
			str(check.get("status", "")),
			str(check.get("name", "")),
			"     n/a" if value == null else "%+8.4f" % float(value),
			direct_column,
			str(check.get("description", "")),
		])
	print("※ 左の数値は対角5点の回帰傾き×(-0.8)、[直接 x] は δ=0 と δ=-0.8 の2セル差。")
	print("※ 1セル %d試合 → 得点/試合の標本誤差は約 ±%.2f (2セル差なら約 ±%.2f)。" % [
		int(anchors.get("games_per_cell", 0)),
		float(anchors.get("runs_standard_error_per_cell", 0.0)),
		float(anchors.get("runs_standard_error_per_cell", 0.0)) * sqrt(2.0),
	])
	print("")
	print("Health   : %s (fail=%d warn=%d)" % [
		str(health.get("status", "")), int(health.get("fail", 0)), int(health.get("warn", 0)),
	])
	if not output_path.is_empty():
		print("JSON     : %s" % output_path)
	if not csv_path.is_empty():
		print("CSV      : %s" % csv_path)


func _print_matrix(report: Dictionary, metric: String, label: String, digits: int) -> void:
	var grid: Dictionary = report.get("grid", {}) as Dictionary
	var batter_offsets: Array = grid.get("batter_offsets", []) as Array
	var pitcher_offsets: Array = grid.get("pitcher_offsets", []) as Array
	var by_key: Dictionary = {}
	for cell_value in (report.get("cells", []) as Array):
		var cell: Dictionary = cell_value as Dictionary
		by_key["%.3f|%.3f" % [float(cell["batter_offset"]), float(cell["pitcher_offset"])]] = cell

	var header: String = "%-14s" % ("%s 打δ\\投δ" % label)
	for pitcher_offset in pitcher_offsets:
		header += "%9.2f" % float(pitcher_offset)
	print(header)
	for batter_offset in batter_offsets:
		var line: String = "%-14.2f" % float(batter_offset)
		for pitcher_offset in pitcher_offsets:
			var cell2: Variant = by_key.get("%.3f|%.3f" % [float(batter_offset), float(pitcher_offset)], null)
			if cell2 == null:
				line += "%9s" % "-"
			else:
				line += "%9.*f" % [digits, float((cell2 as Dictionary).get(metric, 0.0))]
		print(line)
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
run_pa_response_surface — 能力水準 z → 打席結果 の伝達関数を実測する

  --seed=N                 乱数シード (既定 12345)
  --outs=N                 1セルあたりのアウト数 (既定 4050 = 150試合ぶん)
  --games=N                1セルあたりの試合数 (--outs の代わりに指定可)
  --offsets=A,B,C          打者・投手のオフセットを共通指定 (既定 -1.2,-0.8,-0.4,0,0.4)
  --offsets=start:end:step レンジ指定 (例 -1.6:0.4:0.4)
  --batter-offsets=...     打者軸だけ指定
  --pitcher-offsets=...    投手軸だけ指定
  --output=PATH            JSON 出力先
  --csv=PATH               CSV 出力先

軸は「一軍相当プロファイルからのオフセット (σ)」。δ=0 が一軍の動作点で、
run_farm_report が報告する一軍→二軍の水準差 (打者 -0.87σ / 投手 -0.78σ) と同じスケール。
""".strip_edges())


func _direct_column(direct: Dictionary, key: String) -> String:
	if not direct.has(key):
		return ""
	return "[直接 %+.4f]" % float(direct[key])
