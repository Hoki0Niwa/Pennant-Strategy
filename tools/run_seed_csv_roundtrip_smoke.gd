extends Node

# seed CSV が PSPlayer.from_dict/to_dict を通して無損失でラウンドトリップすることを検証する。
#   --players=res://reports/seed_players_test.csv （既定）

const PSPlayerCsvIo = preload("res://services/data/player_csv_io.gd")


func _ready() -> void:
	var players_path: String = "res://reports/seed_players_test.csv"
	for arg in OS.get_cmdline_user_args():
		if str(arg).begins_with("--players="):
			players_path = str(arg).get_slice("=", 1)

	var rows: Array = PSPlayerCsvIo.read_players(players_path)
	if rows.is_empty():
		print("FAIL: no rows read from %s" % players_path)
		get_tree().quit(1)
		return
	var normalized_rows: Array = PSPlayerCsvIo.normalize_initial_seed_players(rows, SeasonService.DEFAULT_START_YEAR)
	var future_fa_year_rows: int = 0
	var future_signed_year_rows: int = 0
	var future_accrued_year_rows: int = 0
	for normalized_value in normalized_rows:
		var normalized: Dictionary = normalized_value as Dictionary
		var source: Dictionary = normalized.get("source_data", {}) as Dictionary
		if int(source.get("fa_eligible_year", 0)) > SeasonService.DEFAULT_START_YEAR:
			future_fa_year_rows += 1
		if int(source.get("fa_signed_year", 0)) > SeasonService.DEFAULT_START_YEAR:
			future_signed_year_rows += 1
		if int(source.get("fa_days_accrued_year", 0)) > SeasonService.DEFAULT_START_YEAR:
			future_accrued_year_rows += 1

	# CSV → PSPlayer → to_dict → CSV(再出力) で 2 回目以降が安定（冪等）であることを確認する。
	var players: Array = []
	for row in rows:
		players.append(PSPlayer.from_dict(row as Dictionary))
	var redumped: Array = []
	for p in players:
		redumped.append((p as PSPlayer).to_dict())

	var tmp_a: String = "res://reports/seed_rt_a.csv"
	var tmp_b: String = "res://reports/seed_rt_b.csv"
	PSPlayerCsvIo.write_players(tmp_a, redumped)
	var rows_b: Array = PSPlayerCsvIo.read_players(tmp_a)
	var players_b: Array = []
	for row in rows_b:
		players_b.append(PSPlayer.from_dict(row as Dictionary))
	var redumped_b: Array = []
	for p in players_b:
		redumped_b.append((p as PSPlayer).to_dict())
	PSPlayerCsvIo.write_players(tmp_b, redumped_b)

	var text_a: String = FileAccess.get_file_as_string(tmp_a)
	var text_b: String = FileAccess.get_file_as_string(tmp_b)
	var stable: bool = text_a == text_b

	# サンプル選手の z_abilities が CSV 値と PSPlayer で一致するか確認。
	var sample: PSPlayer = players[0] as PSPlayer
	var sample_row: Dictionary = rows[0] as Dictionary
	var sample_z: Dictionary = sample_row.get("z_abilities", {}) as Dictionary
	var z_match: bool = true
	var checked_keys: int = 0
	for key in sample_z.keys():
		checked_keys += 1
		if not is_equal_approx(sample.z_ability(str(key), -999.0), float(sample_z[key])):
			z_match = false
			print("  z mismatch key=%s csv=%s player=%s" % [key, sample_z[key], sample.z_ability(str(key))])

	print("Seed CSV roundtrip smoke: rows=%d stable=%s z_match=%s checked_z_keys=%d sample=%s pos=%d" % [
		rows.size(), str(stable), str(z_match), checked_keys, sample.name, sample.position,
	])
	print("  normalized future FA years: eligible=%d signed=%d accrued=%d" % [
		future_fa_year_rows,
		future_signed_year_rows,
		future_accrued_year_rows,
	])
	print("  sample raw_abilities=%s position_aptitudes_keys=%d source_data_keys=%d" % [
		JSON.stringify(sample.raw_abilities),
		(sample.position_aptitudes as Dictionary).size(),
		(sample.source_data as Dictionary).size(),
	])

	var ok: bool = stable and z_match and checked_keys > 0 and future_fa_year_rows == 0 and future_signed_year_rows == 0 and future_accrued_year_rows == 0
	get_tree().quit(0 if ok else 1)
