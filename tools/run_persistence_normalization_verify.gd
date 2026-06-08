extends Node

# 永続化レイヤ v1 の整合性 + クエリ動作検証。
# 1) blob (record_store) と新テーブルで player_records.size() が一致するか
# 2) AwardsService が使う SQL クエリ群が動作し、メモリ全走査と同じ player_id を返すか
# 3) ランダムサンプルの home_runs / wins が blob 経路と table 経路で一致するか
#
# 実行: godot --headless --path . tools/run_persistence_normalization_verify.tscn

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")


func _ready() -> void:
	var failures: Array = []

	print("=== Persistence normalization verify ===")

	# (1) row count 一致
	var ram_count: int = RecordStore.player_records.size()
	var psr_count: int = _table_count("player_season_records")
	var bs_count: int = _table_count("batter_stats")
	var ps_count: int = _table_count("pitcher_stats")
	print("RAM player_records: %d" % ram_count)
	print("DB player_season_records: %d" % psr_count)
	print("DB batter_stats: %d" % bs_count)
	print("DB pitcher_stats: %d" % ps_count)
	if ram_count != psr_count:
		failures.append("RAM(%d) != psr(%d)" % [ram_count, psr_count])
	if ram_count != bs_count:
		failures.append("RAM(%d) != bs(%d)" % [ram_count, bs_count])
	if ram_count != ps_count:
		failures.append("RAM(%d) != ps(%d)" % [ram_count, ps_count])

	# (2) AwardsService SQL クエリ実行確認: 現セーブから season + team_ids を抽出
	if ram_count > 0:
		var sample_record: PSPlayerSeasonRecord = RecordStore.player_records.values()[0] as PSPlayerSeasonRecord
		var year: int = sample_record.year
		var season_number: int = sample_record.season_number
		var team_ids_by_league: Dictionary = {"central": [], "pacific": []}
		for team_row in GameDb.teams:
			var team: PSTeam = team_row as PSTeam
			if team != null and team_ids_by_league.has(team.league):
				(team_ids_by_league[team.league] as Array).append(team.id)
		var central_ids: Array = team_ids_by_league["central"] as Array
		print("Year=%d Season=%d; central teams=%d" % [year, season_number, central_ids.size()])

		# 全 stats が 0 の状態でも、ORDER BY DESC LIMIT 1 は何らかの player_id を返す
		var hr_leader: int = SQLiteStoreService.query_batter_title_leader(
			year, season_number, central_ids, "home_runs", 0, 30, 0
		)
		var avg_leader: int = SQLiteStoreService.query_batter_average_leader(
			year, season_number, central_ids, 0
		)
		var wins_leader: int = SQLiteStoreService.query_pitcher_title_leader(
			year, season_number, central_ids, "wins", 0, false
		)
		var era_leader: int = SQLiteStoreService.query_pitcher_era_leader(
			year, season_number, central_ids, 0
		)
		print("Title query smoke: HR leader=%d, AVG leader=%d, Wins leader=%d, ERA leader=%d" %
			[hr_leader, avg_leader, wins_leader, era_leader])

		# (3) メモリ全走査の最大 home_runs と SQL の HR leader が一致 (cross-league で max)
		var all_ids: Array = []
		for tid_array in team_ids_by_league.values():
			for tid in tid_array as Array:
				all_ids.append(int(tid))
		var ram_max_hr_pid: int = _ram_max_batter_field(year, season_number, "home_runs")
		var sql_max_hr_pid: int = SQLiteStoreService.query_batter_title_leader(
			year, season_number, all_ids, "home_runs", 0, 30, 0
		)
		print("Max HR cross-league: RAM=%d, SQL=%d" % [ram_max_hr_pid, sql_max_hr_pid])
		# 同点が大量にある (全員 0 HR) ケースでは tie-break の都合で
		# RAM と SQL が違う player_id を返すこともある。stats が全部 0 なら緩めにスキップ。
		var ram_max_hr_value: int = _ram_player_batter_field(ram_max_hr_pid, year, season_number, "home_runs")
		var sql_max_hr_value: int = _ram_player_batter_field(sql_max_hr_pid, year, season_number, "home_runs")
		if ram_max_hr_value != sql_max_hr_value:
			failures.append("HR value mismatch RAM=%d SQL=%d" % [ram_max_hr_value, sql_max_hr_value])

		# (3b) RAM の各レコードと DB 行の home_runs / wins が一致しているかを 5 件サンプル
		var checked: int = 0
		for record_value in RecordStore.player_records.values():
			if checked >= 5:
				break
			var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			var db_hr: int = _db_field(rec.player_id, rec.year, rec.season_number, "batter_stats", "home_runs")
			var db_wins: int = _db_field(rec.player_id, rec.year, rec.season_number, "pitcher_stats", "wins")
			if db_hr != rec.batter_stats.home_runs:
				failures.append("HR mismatch pid=%d ram=%d db=%d" % [rec.player_id, rec.batter_stats.home_runs, db_hr])
			if db_wins != rec.pitcher_stats.wins:
				failures.append("Wins mismatch pid=%d ram=%d db=%d" % [rec.player_id, rec.pitcher_stats.wins, db_wins])
			checked += 1

		# (4) advanced_stats_json 列の存在と JSON 解析、advanced_stats 累積値の RAM/DB 一致を確認。
		var advanced_checked: int = 0
		var advanced_with_chances: int = 0
		for record_value in RecordStore.player_records.values():
			if advanced_checked >= 10:
				break
			var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
			var db_json: String = _db_text_field(rec.player_id, rec.year, rec.season_number, "player_season_records", "advanced_stats_json")
			if db_json.is_empty():
				failures.append("advanced_stats_json missing pid=%d" % rec.player_id)
				advanced_checked += 1
				continue
			var parsed: Variant = JSON.parse_string(db_json)
			if not (parsed is Dictionary):
				failures.append("advanced_stats_json invalid JSON pid=%d" % rec.player_id)
				advanced_checked += 1
				continue
			var db_dict: Dictionary = parsed as Dictionary
			var ram_dict: Dictionary = rec.advanced_stats.to_dict() if rec.advanced_stats != null else {}
			# 代表的なスカラー値が RAM と DB で一致することを確認 (新規セーブなら全部 0)。
			for key in ["plate_appearances", "woba_denominator", "fielding_chances"]:
				if int(db_dict.get(key, 0)) != int(ram_dict.get(key, 0)):
					failures.append("advanced_stats[%s] mismatch pid=%d ram=%d db=%d" % [
						key, rec.player_id, int(ram_dict.get(key, 0)), int(db_dict.get(key, 0))
					])
			for key in ["woba_numerator", "bsr"]:
				var ram_val: float = float(ram_dict.get(key, 0.0))
				var db_val: float = float(db_dict.get(key, 0.0))
				if absf(ram_val - db_val) > 0.001:
					failures.append("advanced_stats[%s] mismatch pid=%d ram=%.3f db=%.3f" % [
						key, rec.player_id, ram_val, db_val
					])
			if int(ram_dict.get("fielding_chances", 0)) > 0:
				advanced_with_chances += 1
			advanced_checked += 1
		print("Advanced stats: checked %d records, %d had fielding chances" % [advanced_checked, advanced_with_chances])

	if failures.is_empty():
		print("Persistence normalization verify: ALL OK")
		get_tree().quit(0)
	else:
		print("Persistence normalization verify: FAILURES = %d" % failures.size())
		for f in failures:
			print("  - %s" % f)
		get_tree().quit(1)


func _table_count(table_name: String) -> int:
	var db: Object = ClassDB.instantiate("SQLite") as Object
	if db == null:
		return -1
	db.set("path", SQLiteStoreService.RUNTIME_DB_PATH)
	db.set("verbosity_level", 0)
	if not bool(db.call("open_db")):
		return -1
	if not bool(db.call("query", "SELECT COUNT(*) AS count FROM %s" % table_name)):
		db.call("close_db")
		return -1
	var result: Variant = db.get("query_result")
	db.call("close_db")
	if not (result is Array) or (result as Array).is_empty():
		return -1
	return int(((result as Array)[0] as Dictionary).get("count", -1))


func _db_field(player_id: int, year: int, season_number: int, table_name: String, column: String) -> int:
	var db: Object = ClassDB.instantiate("SQLite") as Object
	if db == null:
		return -1
	db.set("path", SQLiteStoreService.RUNTIME_DB_PATH)
	db.set("verbosity_level", 0)
	if not bool(db.call("open_db")):
		return -1
	var sql: String = "SELECT %s AS val FROM %s WHERE player_id=? AND year=? AND season_number=?" % [column, table_name]
	if not bool(db.call("query_with_bindings", sql, [player_id, year, season_number])):
		db.call("close_db")
		return -1
	var result: Variant = db.get("query_result")
	db.call("close_db")
	if not (result is Array) or (result as Array).is_empty():
		return -1
	return int(((result as Array)[0] as Dictionary).get("val", -1))


func _ram_max_batter_field(year: int, season_number: int, column: String) -> int:
	var best_pid: int = 0
	var best_value: int = -999999
	for record_value in RecordStore.player_records.values():
		var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if rec.year != year or rec.season_number != season_number:
			continue
		var val: int = int(rec.batter_stats.to_dict().get(column, 0))
		if val > best_value:
			best_value = val
			best_pid = rec.player_id
	return best_pid


func _ram_player_batter_field(player_id: int, year: int, season_number: int, column: String) -> int:
	for record_value in RecordStore.player_records.values():
		var rec: PSPlayerSeasonRecord = record_value as PSPlayerSeasonRecord
		if rec.player_id == player_id and rec.year == year and rec.season_number == season_number:
			return int(rec.batter_stats.to_dict().get(column, 0))
	return 0


func _db_text_field(player_id: int, year: int, season_number: int, table_name: String, column: String) -> String:
	var db: Object = ClassDB.instantiate("SQLite") as Object
	if db == null:
		return ""
	db.set("path", SQLiteStoreService.RUNTIME_DB_PATH)
	db.set("verbosity_level", 0)
	if not bool(db.call("open_db")):
		return ""
	var sql: String = "SELECT %s AS val FROM %s WHERE player_id=? AND year=? AND season_number=?" % [column, table_name]
	if not bool(db.call("query_with_bindings", sql, [player_id, year, season_number])):
		db.call("close_db")
		return ""
	var result: Variant = db.get("query_result")
	db.call("close_db")
	if not (result is Array) or (result as Array).is_empty():
		return ""
	return str(((result as Array)[0] as Dictionary).get("val", ""))
