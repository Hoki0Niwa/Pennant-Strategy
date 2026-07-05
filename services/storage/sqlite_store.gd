extends RefCounted
class_name SQLiteStore

const SaveContext = preload("res://services/storage/save_context.gd")
const RUNTIME_TEMPLATE_DB_PATH = "res://data/pennant_strategy.sqlite"

# SQLite の user_version に保存する永続化スキーマ世代。
# required columns と indexes が揃っているかを起動時に確認する。
const SCHEMA_VERSION: int = 4

# スキーマ構築 (CREATE TABLE / INDEX / レガシー検出 / PRAGMA table_info) はプロセス内で
# 一度実行できれば十分。毎 open で走らせると save が連続する場面 (オフシーズン開始時など) で
# 固定オーバーヘッドが積み上がるため、成功後はこのフラグでスキップする。
static var _schema_ensured: bool = false
static var _schema_ensured_path: String = ""


static func is_available() -> bool:
	return ClassDB.class_exists("SQLite")


static func runtime_db_path() -> String:
	return SaveContext.runtime_db_path()


static func save_game_state(payload: Dictionary) -> bool:
	return _save_blob("game_state", payload)


static func load_game_state() -> Dictionary:
	return _load_blob("game_state")


# freelist が一定割合 (既定 25%) を超えるときだけ VACUUM する。
# 健全な DB を毎回まるごと書き直す無駄を避けつつ、肥大化した既存セーブは回収する。
static func vacuum_if_needed(free_ratio_threshold: float = 0.25) -> bool:
	if not is_available():
		return false
	var db: Object = _open_runtime_db()
	if db == null:
		return false
	var page_count: int = _pragma_int(db, "page_count")
	var freelist_count: int = _pragma_int(db, "freelist_count")
	var needed: bool = page_count > 0 and float(freelist_count) / float(page_count) >= free_ratio_threshold
	var ok: bool = true
	if needed:
		ok = _execute(db, "VACUUM")
	_close(db)
	return ok


static func _pragma_int(db: Object, pragma_name: String) -> int:
	var rows: Array = _query(db, "PRAGMA %s" % pragma_name)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get(pragma_name, 0))


static func load_record_store() -> Dictionary:
	return _load_blob("record_store")


# 実データ保護: ランタイム DB ファイルが「存在するのに開けない」(ロック等の一時故障) 状態を
# 「データが無い」と区別するためのプローブ。RecordStore.load_records はこれが false のとき
# hydration を失敗扱いにする (空の RecordStore を正として保存すると、ensure_season_records が
# 再生成した空白レコードで実データが上書きされ全成績が失われるため)。
static func runtime_db_file_exists() -> bool:
	var path: String = runtime_db_path()
	return not path.is_empty() and FileAccess.file_exists(ProjectSettings.globalize_path(path))


static func can_open_runtime_db() -> bool:
	if not is_available():
		return false
	var db: Object = _open_runtime_db()
	if db == null:
		return false
	_close(db)
	return true


# -----------------------------------------------------------------------------
# 選手年度記録は検索・集計しやすいよう、選手本体/打撃成績/投手成績の3テーブルに正規化する。
# -----------------------------------------------------------------------------

const PLAYER_SEASON_COLUMNS: Array = [
	"player_id", "year", "season_number", "team_id",
	"sensyu_num", "jersey_number", "development_player",
	"name", "age", "years", "height", "weight",
	"position", "role", "throwing_hand", "batting_side",
	"salary", "draft_round", "hometown",
	"registered_roster", "contract_status", "foreign_player",
	"fa_eligible_years",
	"fatigue", "injury_days", "season_injury_days",
	"injury_return_day", "injury_type", "injury_severity",
	"consecutive_appearances", "last_pitched_team_game",
	"position_aptitudes_snapshot_json", "position_experience_snapshot_json",
	"source_data_json", "z_abilities_snapshot_json", "raw_abilities_snapshot_json",
	"advanced_stats_json",
]

const BATTER_STATS_COLUMNS: Array = [
	"player_id", "year", "season_number",
	"games", "plate_appearances", "at_bats", "hits",
	"doubles", "triples", "home_runs",
	"runs_batted_in", "runs", "walks", "hit_by_pitches",
	"strikeouts", "pitches_seen",
	"stolen_base_attempts", "stolen_bases",
	"sacrifices", "sacrifice_flies", "double_plays", "errors",
]

const PITCHER_STATS_COLUMNS: Array = [
	"player_id", "year", "season_number",
	"games", "starts", "relief_appearances",
	"wins", "losses", "holds", "saves",
	"outs_pitched", "batters_faced", "pitches_thrown",
	"hits_allowed", "home_runs_allowed",
	"walks", "hit_batters", "strikeouts",
	"ground_balls_allowed", "line_drives_allowed",
	"infield_flies_allowed", "outfield_flies_allowed",
	"runs_allowed", "earned_runs",
	"complete_games", "shutouts", "quality_starts",
]


# RecordStore.save_records() から呼ばれる保存入口。
# 軽量 blob と正規化3テーブルを同一 transaction で更新し、片方だけ成功する状態を防ぐ。
static func save_record_store_and_normalized(blob_payload: Dictionary) -> bool:
	var db: Object = _open_runtime_db()
	if db == null:
		return false

	var ok: bool = _save_record_store_and_normalized_inner(db, blob_payload)
	_close(db)
	return ok


static func _save_record_store_and_normalized_inner(db: Object, blob_payload: Dictionary) -> bool:
	if not _execute(db, "BEGIN TRANSACTION"):
		return false

	# player_records は正規化テーブルを読み込み元にするため、blob にはチーム記録と履歴だけを残す。
	# autosave ごとに全選手履歴 JSON を書き直さずに済み、DB サイズの肥大化を抑えられる。
	var slim_blob: Dictionary = {
		"version": blob_payload.get("version", 2),
		"team_records": blob_payload.get("team_records", []),
		"season_archives": blob_payload.get("season_archives", []),
	}
	var value_json: String = JSON.stringify(slim_blob)
	var blob_sql: String = "INSERT OR REPLACE INTO runtime_blobs (key, value_json, updated_at) VALUES (?, ?, datetime('now'))"
	if not _query_with_bindings(db, blob_sql, ["record_store", value_json]):
		_execute(db, "ROLLBACK")
		return false

	var player_records: Array = blob_payload.get("player_records", []) as Array

	# (year, season_number) ごとに有効な player_id 集合を作り、
	# DB 側で集合に居ない行を DELETE してから upsert する。
	var by_season: Dictionary = {}  # "year:season_number" -> Array[int]
	for record_value in player_records:
		var record: Dictionary = record_value as Dictionary
		var year: int = int(record.get("year", 0))
		var season_number: int = int(record.get("season_number", 0))
		var key: String = "%d:%d" % [year, season_number]
		if not by_season.has(key):
			by_season[key] = []
		by_season[key].append(int(record.get("player_id", 0)))

	for season_key in by_season.keys():
		var ids: Array = by_season[season_key] as Array
		if ids.is_empty():
			continue
		var parts: PackedStringArray = (season_key as String).split(":")
		var year: int = int(parts[0])
		var season_number: int = int(parts[1])
		var placeholders: String = _build_placeholders(ids.size())
		var del_bindings: Array = [year, season_number]
		for pid in ids:
			del_bindings.append(int(pid))
		for table_name in ["player_season_records", "batter_stats", "pitcher_stats"]:
			var del_sql: String = "DELETE FROM %s WHERE year = ? AND season_number = ? AND player_id NOT IN (%s)" % [table_name, placeholders]
			if not _query_with_bindings(db, del_sql, del_bindings):
				_execute(db, "ROLLBACK")
				return false

	for record_value in player_records:
		var record: Dictionary = record_value as Dictionary
		if not _upsert_player_season_record(db, record):
			_execute(db, "ROLLBACK")
			return false
		var player_id: int = int(record.get("player_id", 0))
		var year: int = int(record.get("year", 0))
		var season_number: int = int(record.get("season_number", 0))
		var batter_stats: Dictionary = record.get("batter_stats", {}) as Dictionary
		if not _upsert_batter_stats(db, player_id, year, season_number, batter_stats):
			_execute(db, "ROLLBACK")
			return false
		var pitcher_stats: Dictionary = record.get("pitcher_stats", {}) as Dictionary
		if not _upsert_pitcher_stats(db, player_id, year, season_number, pitcher_stats):
			_execute(db, "ROLLBACK")
			return false

	if get_user_version(db) < SCHEMA_VERSION:
		if not set_user_version(db, SCHEMA_VERSION):
			_execute(db, "ROLLBACK")
			return false

	return _execute(db, "COMMIT")


# 正規化テーブルから全選手年度記録を復元する。RecordStore.load_records() では blob より優先される。
static func load_all_player_season_record_dicts() -> Array:
	var db: Object = _open_runtime_db()
	if db == null:
		return []
	var psr_rows: Array = _select_with_bindings(db, "SELECT * FROM player_season_records", [])
	var bs_rows: Array = _select_with_bindings(db, "SELECT * FROM batter_stats", [])
	var ps_rows: Array = _select_with_bindings(db, "SELECT * FROM pitcher_stats", [])
	_close(db)
	return _merge_normalized_rows(psr_rows, bs_rows, ps_rows)


# 正規化テーブルがまだ空なら、古い blob だけのセーブとして扱って hydrate ルートへ戻す。
static func normalized_tables_empty() -> bool:
	if not is_available():
		return true
	var db: Object = _open_runtime_db()
	if db == null:
		return true
	var rows: Array = _select_with_bindings(db, "SELECT COUNT(*) AS count FROM player_season_records", [])
	_close(db)
	if rows.is_empty():
		return true
	return int((rows[0] as Dictionary).get("count", 0)) == 0


# -----------------------------------------------------------------------------
# AwardsService 用: 単一タイトル (max / min ORDER BY) を取得する
# -----------------------------------------------------------------------------

# 打撃タイトル (本塁打/打点/盗塁/安打 など) のリーダーを 1 件取得。
# qualifier_pa を 0 にすると規定打席フィルタをかけない (カウンティング・タイトル用)。
# pitcher_exclude_pa を 0 より大きい値にすると、role が starter/reliever/closer かつ
# plate_appearances < pitcher_exclude_pa の選手を除外する (打席タイトルでの投手除外)。
static func query_batter_title_leader(
	year: int,
	season_number: int,
	team_ids: Array,
	column: String,
	qualifier_pa: int,
	pitcher_exclude_pa: int,
	min_at_bats: int,
) -> int:
	if team_ids.is_empty():
		return 0
	var db: Object = _open_runtime_db()
	if db == null:
		return 0

	var team_placeholders: String = _build_placeholders(team_ids.size())
	var sql: String = "SELECT bs.player_id AS player_id FROM batter_stats AS bs "
	sql += "JOIN player_season_records AS psr ON psr.player_id = bs.player_id AND psr.year = bs.year AND psr.season_number = bs.season_number "
	sql += "WHERE bs.year = ? AND bs.season_number = ? AND psr.team_id IN (%s) " % team_placeholders
	var bindings: Array = [year, season_number]
	for tid in team_ids:
		bindings.append(int(tid))
	if qualifier_pa > 0:
		sql += "AND bs.plate_appearances >= ? "
		bindings.append(qualifier_pa)
	if min_at_bats > 0:
		sql += "AND bs.at_bats >= ? "
		bindings.append(min_at_bats)
	if pitcher_exclude_pa > 0:
		sql += "AND NOT (psr.role IN ('starter','reliever','closer') AND bs.plate_appearances < ?) "
		bindings.append(pitcher_exclude_pa)
	sql += "ORDER BY bs.%s DESC LIMIT 1" % column

	var rows: Array = _select_with_bindings(db, sql, bindings)
	_close(db)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get("player_id", 0))


# 打率タイトル用: at_bats > 0 のみ対象に、batting_average を SQL 内で計算して max。
static func query_batter_average_leader(
	year: int,
	season_number: int,
	team_ids: Array,
	qualifier_pa: int,
) -> int:
	if team_ids.is_empty():
		return 0
	var db: Object = _open_runtime_db()
	if db == null:
		return 0

	var team_placeholders: String = _build_placeholders(team_ids.size())
	var sql: String = "SELECT bs.player_id AS player_id FROM batter_stats AS bs "
	sql += "JOIN player_season_records AS psr ON psr.player_id = bs.player_id AND psr.year = bs.year AND psr.season_number = bs.season_number "
	sql += "WHERE bs.year = ? AND bs.season_number = ? AND psr.team_id IN (%s) " % team_placeholders
	sql += "AND bs.at_bats > 0 AND bs.plate_appearances >= ? "
	sql += "ORDER BY (CAST(bs.hits AS REAL) / bs.at_bats) DESC LIMIT 1"
	var bindings: Array = [year, season_number]
	for tid in team_ids:
		bindings.append(int(tid))
	bindings.append(qualifier_pa)

	var rows: Array = _select_with_bindings(db, sql, bindings)
	_close(db)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get("player_id", 0))


# 投手タイトル (勝利/奪三振/セーブ/ホールド): カウンティング (qualifier_outs=0) を選べる。
# is_pitcher_only=true の場合 role が starter/reliever/closer のみ対象。
static func query_pitcher_title_leader(
	year: int,
	season_number: int,
	team_ids: Array,
	column: String,
	qualifier_outs: int,
	ascending: bool,
) -> int:
	if team_ids.is_empty():
		return 0
	var db: Object = _open_runtime_db()
	if db == null:
		return 0

	var team_placeholders: String = _build_placeholders(team_ids.size())
	var sql: String = "SELECT ps.player_id AS player_id FROM pitcher_stats AS ps "
	sql += "JOIN player_season_records AS psr ON psr.player_id = ps.player_id AND psr.year = ps.year AND psr.season_number = ps.season_number "
	sql += "WHERE ps.year = ? AND ps.season_number = ? AND psr.team_id IN (%s) " % team_placeholders
	sql += "AND ps.games > 0 "
	# 投手ロール限定 (打撃タイトルでの投手判定と同じ条件で揃える)
	sql += "AND (psr.role IN ('starter','reliever','closer') OR psr.position = 1) "
	var bindings: Array = [year, season_number]
	for tid in team_ids:
		bindings.append(int(tid))
	if qualifier_outs > 0:
		sql += "AND ps.outs_pitched >= ? "
		bindings.append(qualifier_outs)
	var direction: String = "ASC" if ascending else "DESC"
	sql += "ORDER BY ps.%s %s LIMIT 1" % [column, direction]

	var rows: Array = _select_with_bindings(db, sql, bindings)
	_close(db)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get("player_id", 0))


# 防御率タイトル: outs_pitched > 0 のみ対象に era = earned_runs*27/outs_pitched を最小化。
static func query_pitcher_era_leader(
	year: int,
	season_number: int,
	team_ids: Array,
	qualifier_outs: int,
) -> int:
	if team_ids.is_empty():
		return 0
	var db: Object = _open_runtime_db()
	if db == null:
		return 0

	var team_placeholders: String = _build_placeholders(team_ids.size())
	var sql: String = "SELECT ps.player_id AS player_id FROM pitcher_stats AS ps "
	sql += "JOIN player_season_records AS psr ON psr.player_id = ps.player_id AND psr.year = ps.year AND psr.season_number = ps.season_number "
	sql += "WHERE ps.year = ? AND ps.season_number = ? AND psr.team_id IN (%s) " % team_placeholders
	sql += "AND ps.outs_pitched > 0 AND ps.outs_pitched >= ? "
	sql += "AND (psr.role IN ('starter','reliever','closer') OR psr.position = 1) "
	sql += "ORDER BY (CAST(ps.earned_runs AS REAL) * 27.0 / ps.outs_pitched) ASC LIMIT 1"
	var bindings: Array = [year, season_number]
	for tid in team_ids:
		bindings.append(int(tid))
	bindings.append(qualifier_outs)

	var rows: Array = _select_with_bindings(db, sql, bindings)
	_close(db)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get("player_id", 0))


# 勝率タイトル: (wins + losses) >= 8 かつ規定投球回。win_rate = wins / (wins + losses) を最大化。
static func query_pitcher_win_rate_leader(
	year: int,
	season_number: int,
	team_ids: Array,
	qualifier_outs: int,
	min_decisions: int,
) -> int:
	if team_ids.is_empty():
		return 0
	var db: Object = _open_runtime_db()
	if db == null:
		return 0

	var team_placeholders: String = _build_placeholders(team_ids.size())
	var sql: String = "SELECT ps.player_id AS player_id FROM pitcher_stats AS ps "
	sql += "JOIN player_season_records AS psr ON psr.player_id = ps.player_id AND psr.year = ps.year AND psr.season_number = ps.season_number "
	sql += "WHERE ps.year = ? AND ps.season_number = ? AND psr.team_id IN (%s) " % team_placeholders
	sql += "AND ps.outs_pitched >= ? AND (ps.wins + ps.losses) >= ? "
	sql += "AND (psr.role IN ('starter','reliever','closer') OR psr.position = 1) "
	sql += "ORDER BY (CAST(ps.wins AS REAL) / (ps.wins + ps.losses)) DESC LIMIT 1"
	var bindings: Array = [year, season_number]
	for tid in team_ids:
		bindings.append(int(tid))
	bindings.append(qualifier_outs)
	bindings.append(min_decisions)

	var rows: Array = _select_with_bindings(db, sql, bindings)
	_close(db)
	if rows.is_empty():
		return 0
	return int((rows[0] as Dictionary).get("player_id", 0))


# -----------------------------------------------------------------------------
# 内部実装ヘルパー
# -----------------------------------------------------------------------------

static func _upsert_player_season_record(db: Object, record: Dictionary) -> bool:
	var sql: String = "INSERT OR REPLACE INTO player_season_records (%s) VALUES (%s)" % [
		",".join(PLAYER_SEASON_COLUMNS),
		_build_placeholders(PLAYER_SEASON_COLUMNS.size()),
	]
	var bindings: Array = []
	for column_value in PLAYER_SEASON_COLUMNS:
		bindings.append(_player_season_value(record, str(column_value)))
	return _query_with_bindings(db, sql, bindings)


static func _upsert_batter_stats(db: Object, player_id: int, year: int, season_number: int, stats: Dictionary) -> bool:
	var sql: String = "INSERT OR REPLACE INTO batter_stats (%s) VALUES (%s)" % [
		",".join(BATTER_STATS_COLUMNS),
		_build_placeholders(BATTER_STATS_COLUMNS.size()),
	]
	var bindings: Array = [player_id, year, season_number]
	for i in range(3, BATTER_STATS_COLUMNS.size()):
		var col: String = str(BATTER_STATS_COLUMNS[i])
		bindings.append(int(stats.get(col, 0)))
	return _query_with_bindings(db, sql, bindings)


static func _upsert_pitcher_stats(db: Object, player_id: int, year: int, season_number: int, stats: Dictionary) -> bool:
	var sql: String = "INSERT OR REPLACE INTO pitcher_stats (%s) VALUES (%s)" % [
		",".join(PITCHER_STATS_COLUMNS),
		_build_placeholders(PITCHER_STATS_COLUMNS.size()),
	]
	var bindings: Array = [player_id, year, season_number]
	for i in range(3, PITCHER_STATS_COLUMNS.size()):
		var col: String = str(PITCHER_STATS_COLUMNS[i])
		bindings.append(int(stats.get(col, 0)))
	return _query_with_bindings(db, sql, bindings)


static func _player_season_value(record: Dictionary, column: String) -> Variant:
	match column:
		"development_player":
			return 1 if bool(record.get("development_player", false)) else 0
		"foreign_player":
			return 1 if bool(record.get("foreign_player", false)) else 0
		"position_aptitudes_snapshot_json":
			return JSON.stringify(record.get("position_aptitudes_snapshot", {}))
		"position_experience_snapshot_json":
			return JSON.stringify(record.get("position_experience_snapshot", {}))
		"source_data_json":
			return JSON.stringify(record.get("source_data", {}))
		"z_abilities_snapshot_json":
			return JSON.stringify(record.get("z_abilities_snapshot", {}))
		"raw_abilities_snapshot_json":
			return JSON.stringify(record.get("raw_abilities_snapshot", {}))
		"advanced_stats_json":
			return JSON.stringify(record.get("advanced_stats", {}))
		"name", "role", "throwing_hand", "batting_side", "hometown", "registered_roster", "contract_status", "injury_type":
			return str(record.get(column, ""))
		_:
			return int(record.get(column, 0))


# psr / batter_stats / pitcher_stats を player_id+year+season_number で merge し、
# PSPlayerSeasonRecord.from_dict() がそのまま読める Dictionary 配列を返す。
static func _merge_normalized_rows(psr_rows: Array, bs_rows: Array, ps_rows: Array) -> Array:
	var bs_by_key: Dictionary = {}
	for row_value in bs_rows:
		var row: Dictionary = row_value as Dictionary
		var key: String = "%d:%d:%d" % [int(row.get("player_id", 0)), int(row.get("year", 0)), int(row.get("season_number", 0))]
		bs_by_key[key] = _normalized_stats_dict(row, BATTER_STATS_COLUMNS)
	var ps_by_key: Dictionary = {}
	for row_value in ps_rows:
		var row: Dictionary = row_value as Dictionary
		var key: String = "%d:%d:%d" % [int(row.get("player_id", 0)), int(row.get("year", 0)), int(row.get("season_number", 0))]
		ps_by_key[key] = _normalized_stats_dict(row, PITCHER_STATS_COLUMNS)

	var out: Array = []
	for row_value in psr_rows:
		var row: Dictionary = row_value as Dictionary
		var key: String = "%d:%d:%d" % [int(row.get("player_id", 0)), int(row.get("year", 0)), int(row.get("season_number", 0))]
		var record: Dictionary = _normalized_player_season_dict(row)
		record["batter_stats"] = bs_by_key.get(key, _empty_batter_stats_dict())
		record["pitcher_stats"] = ps_by_key.get(key, _empty_pitcher_stats_dict())
		out.append(record)
	return out


static func _normalized_player_season_dict(row: Dictionary) -> Dictionary:
	return {
		"player_id": int(row.get("player_id", 0)),
		"sensyu_num": int(row.get("sensyu_num", 0)),
		"jersey_number": int(row.get("jersey_number", 0)),
		"development_player": int(row.get("development_player", 0)) != 0,
		"year": int(row.get("year", 0)),
		"season_number": int(row.get("season_number", 0)),
		"team_id": int(row.get("team_id", 0)),
		"name": str(row.get("name", "")),
		"age": int(row.get("age", 0)),
		"years": int(row.get("years", 0)),
		"height": int(row.get("height", 0)),
		"weight": int(row.get("weight", 0)),
		"position": int(row.get("position", 0)),
		"role": str(row.get("role", "fielder")),
		"throwing_hand": str(row.get("throwing_hand", "R")),
		"batting_side": str(row.get("batting_side", "R")),
		"salary": int(row.get("salary", 0)),
		"draft_round": int(row.get("draft_round", 0)),
		"hometown": str(row.get("hometown", "")),
		"registered_roster": str(row.get("registered_roster", "支配下")),
		"contract_status": str(row.get("contract_status", "通常")),
		"foreign_player": int(row.get("foreign_player", 0)) != 0,
		"fa_eligible_years": int(row.get("fa_eligible_years", 0)),
		"fatigue": int(row.get("fatigue", 0)),
		"injury_days": int(row.get("injury_days", 0)),
		"season_injury_days": int(row.get("season_injury_days", 0)),
		"injury_return_day": int(row.get("injury_return_day", 0)),
		"injury_type": str(row.get("injury_type", "")),
		"injury_severity": int(row.get("injury_severity", 0)),
		"consecutive_appearances": int(row.get("consecutive_appearances", 0)),
		"last_pitched_team_game": int(row.get("last_pitched_team_game", 0)),
		"position_aptitudes_snapshot": _parse_json_dict(str(row.get("position_aptitudes_snapshot_json", "{}"))),
		"position_experience_snapshot": _parse_json_dict(str(row.get("position_experience_snapshot_json", "{}"))),
		"source_data": _parse_json_dict(str(row.get("source_data_json", "{}"))),
		"z_abilities_snapshot": _parse_json_dict(str(row.get("z_abilities_snapshot_json", "{}"))),
		"raw_abilities_snapshot": _parse_json_dict(str(row.get("raw_abilities_snapshot_json", "{}"))),
		"advanced_stats": _parse_json_dict(str(row.get("advanced_stats_json", "{}"))),
	}


static func _normalized_stats_dict(row: Dictionary, columns: Array) -> Dictionary:
	var out: Dictionary = {}
	for i in range(3, columns.size()):
		var col: String = str(columns[i])
		out[col] = int(row.get(col, 0))
	return out


static func _empty_batter_stats_dict() -> Dictionary:
	var out: Dictionary = {}
	for i in range(3, BATTER_STATS_COLUMNS.size()):
		out[str(BATTER_STATS_COLUMNS[i])] = 0
	return out


static func _empty_pitcher_stats_dict() -> Dictionary:
	var out: Dictionary = {}
	for i in range(3, PITCHER_STATS_COLUMNS.size()):
		out[str(PITCHER_STATS_COLUMNS[i])] = 0
	return out


static func _parse_json_dict(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


static func _build_placeholders(count: int) -> String:
	if count <= 0:
		return ""
	var parts: PackedStringArray = []
	for _i in range(count):
		parts.append("?")
	return ",".join(parts)


static func _query_with_bindings(db: Object, sql: String, bindings: Array) -> bool:
	return bool(db.call("query_with_bindings", sql, bindings))


static func _select_with_bindings(db: Object, sql: String, bindings: Array) -> Array:
	if not _query_with_bindings(db, sql, bindings):
		return []
	var result: Variant = db.get("query_result")
	if result is Array:
		return result as Array
	return []


static func _save_blob(key: String, payload: Dictionary) -> bool:
	var db: Object = _open_runtime_db()
	if db == null:
		return false

	var value_json: String = JSON.stringify(payload)
	var sql: String = "INSERT OR REPLACE INTO runtime_blobs (key, value_json, updated_at) VALUES (%s, %s, datetime('now'))" % [
		_sql_string(key),
		_sql_string(value_json),
	]
	var ok: bool = _execute(db, sql)
	_close(db)
	return ok


static func _load_blob(key: String) -> Dictionary:
	var db: Object = _open_runtime_db()
	if db == null:
		return {}

	var rows: Array = _query(db, "SELECT value_json FROM runtime_blobs WHERE key = %s LIMIT 1" % _sql_string(key))
	_close(db)
	if rows.is_empty():
		return {}

	var row: Dictionary = rows[0] as Dictionary
	var parsed: Variant = JSON.parse_string(str(row.get("value_json", "{}")))
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


static func _open_runtime_db() -> Object:
	if not is_available():
		return null
	var runtime_path: String = runtime_db_path()
	if runtime_path.is_empty():
		return null
	if not _ensure_runtime_db_file(runtime_path):
		return null

	var db: Object = ClassDB.instantiate("SQLite") as Object
	if db == null:
		return null

	db.set("path", runtime_path)
	db.set("foreign_keys", true)
	db.set("verbosity_level", 0)
	if not bool(db.call("open_db")):
		return null

	# 書き込み高速化: WAL (ファイル永続・初回のみ実効) + synchronous=NORMAL (接続ごと)。
	# fsync 回数を減らし、save 連発時のレイテンシを下げる。
	_execute(db, "PRAGMA journal_mode = WAL")
	_execute(db, "PRAGMA synchronous = NORMAL")

	if (not _schema_ensured) or _schema_ensured_path != runtime_path:
		if not _ensure_runtime_schema(db):
			_close(db)
			return null
		_schema_ensured = true
		_schema_ensured_path = runtime_path

	return db


static func _ensure_runtime_db_file(runtime_path: String) -> bool:
	if FileAccess.file_exists(runtime_path):
		return true
	# Per-save runtime DBs must start empty; copying the bundled seed/template DB can
	# bring an older record schema into a brand-new save folder.
	if SaveContext.has_active_save():
		return true

	var template_path: String = ProjectSettings.globalize_path(RUNTIME_TEMPLATE_DB_PATH)
	var global_runtime_path: String = ProjectSettings.globalize_path(runtime_path)
	if FileAccess.file_exists(global_runtime_path):
		return true
	if not FileAccess.file_exists(template_path):
		return true

	if DirAccess.copy_absolute(template_path, global_runtime_path) == OK:
		return true

	var source: FileAccess = FileAccess.open(template_path, FileAccess.READ)
	if source == null:
		return true

	var bytes: PackedByteArray = source.get_buffer(source.get_length())
	var target: FileAccess = FileAccess.open(global_runtime_path, FileAccess.WRITE)
	if target == null:
		return true

	target.store_buffer(bytes)
	return true


static func _ensure_runtime_schema(db: Object) -> bool:
	var statements: Array = [
		"CREATE TABLE IF NOT EXISTS runtime_blobs (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
		# --- 永続化スキーマ v1: 年度別選手記録の正規化テーブル ---
		# blob (runtime_blobs.record_store) と dual-write される。読み込みは新テーブル優先、
		# 空なら blob から hydrate する。
		"""CREATE TABLE IF NOT EXISTS player_season_records (
			player_id INTEGER NOT NULL,
			year INTEGER NOT NULL,
			season_number INTEGER NOT NULL,
			team_id INTEGER NOT NULL,
			sensyu_num INTEGER NOT NULL DEFAULT 0,
			jersey_number INTEGER NOT NULL DEFAULT 0,
			development_player INTEGER NOT NULL DEFAULT 0,
			name TEXT NOT NULL DEFAULT '',
			age INTEGER NOT NULL DEFAULT 0,
			years INTEGER NOT NULL DEFAULT 0,
			height INTEGER NOT NULL DEFAULT 0,
			weight INTEGER NOT NULL DEFAULT 0,
			position INTEGER NOT NULL DEFAULT 0,
			role TEXT NOT NULL DEFAULT 'fielder',
			throwing_hand TEXT NOT NULL DEFAULT 'R',
			batting_side TEXT NOT NULL DEFAULT 'R',
			salary INTEGER NOT NULL DEFAULT 0,
			draft_round INTEGER NOT NULL DEFAULT 0,
			hometown TEXT NOT NULL DEFAULT '',
			registered_roster TEXT NOT NULL DEFAULT '支配下',
			contract_status TEXT NOT NULL DEFAULT '通常',
			foreign_player INTEGER NOT NULL DEFAULT 0,
			fa_eligible_years INTEGER NOT NULL DEFAULT 0,
			fatigue INTEGER NOT NULL DEFAULT 0,
			injury_days INTEGER NOT NULL DEFAULT 0,
			season_injury_days INTEGER NOT NULL DEFAULT 0,
			injury_return_day INTEGER NOT NULL DEFAULT 0,
			injury_type TEXT NOT NULL DEFAULT '',
			injury_severity INTEGER NOT NULL DEFAULT 0,
			consecutive_appearances INTEGER NOT NULL DEFAULT 0,
			last_pitched_team_game INTEGER NOT NULL DEFAULT 0,
			position_aptitudes_snapshot_json TEXT NOT NULL DEFAULT '{}',
			position_experience_snapshot_json TEXT NOT NULL DEFAULT '{}',
			source_data_json TEXT NOT NULL DEFAULT '{}',
			z_abilities_snapshot_json TEXT NOT NULL DEFAULT '{}',
			raw_abilities_snapshot_json TEXT NOT NULL DEFAULT '{}',
			advanced_stats_json TEXT NOT NULL DEFAULT '{}',
			PRIMARY KEY (player_id, year, season_number)
		)""",
		"CREATE INDEX IF NOT EXISTS idx_psr_year_season ON player_season_records(year, season_number)",
		"CREATE INDEX IF NOT EXISTS idx_psr_team ON player_season_records(year, season_number, team_id)",
		"""CREATE TABLE IF NOT EXISTS batter_stats (
			player_id INTEGER NOT NULL,
			year INTEGER NOT NULL,
			season_number INTEGER NOT NULL,
			games INTEGER NOT NULL DEFAULT 0,
			plate_appearances INTEGER NOT NULL DEFAULT 0,
			at_bats INTEGER NOT NULL DEFAULT 0,
			hits INTEGER NOT NULL DEFAULT 0,
			doubles INTEGER NOT NULL DEFAULT 0,
			triples INTEGER NOT NULL DEFAULT 0,
			home_runs INTEGER NOT NULL DEFAULT 0,
			runs_batted_in INTEGER NOT NULL DEFAULT 0,
			runs INTEGER NOT NULL DEFAULT 0,
			walks INTEGER NOT NULL DEFAULT 0,
			hit_by_pitches INTEGER NOT NULL DEFAULT 0,
			strikeouts INTEGER NOT NULL DEFAULT 0,
			pitches_seen INTEGER NOT NULL DEFAULT 0,
			stolen_base_attempts INTEGER NOT NULL DEFAULT 0,
			stolen_bases INTEGER NOT NULL DEFAULT 0,
			sacrifices INTEGER NOT NULL DEFAULT 0,
			sacrifice_flies INTEGER NOT NULL DEFAULT 0,
			double_plays INTEGER NOT NULL DEFAULT 0,
			errors INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (player_id, year, season_number)
		)""",
		"CREATE INDEX IF NOT EXISTS idx_bs_year_season ON batter_stats(year, season_number)",
		"CREATE INDEX IF NOT EXISTS idx_bs_hr ON batter_stats(year, season_number, home_runs DESC)",
		"CREATE INDEX IF NOT EXISTS idx_bs_hits ON batter_stats(year, season_number, hits DESC)",
		"CREATE INDEX IF NOT EXISTS idx_bs_rbi ON batter_stats(year, season_number, runs_batted_in DESC)",
		"CREATE INDEX IF NOT EXISTS idx_bs_sb ON batter_stats(year, season_number, stolen_bases DESC)",
		"""CREATE TABLE IF NOT EXISTS pitcher_stats (
			player_id INTEGER NOT NULL,
			year INTEGER NOT NULL,
			season_number INTEGER NOT NULL,
			games INTEGER NOT NULL DEFAULT 0,
			starts INTEGER NOT NULL DEFAULT 0,
			relief_appearances INTEGER NOT NULL DEFAULT 0,
			wins INTEGER NOT NULL DEFAULT 0,
			losses INTEGER NOT NULL DEFAULT 0,
			holds INTEGER NOT NULL DEFAULT 0,
			saves INTEGER NOT NULL DEFAULT 0,
			outs_pitched INTEGER NOT NULL DEFAULT 0,
			batters_faced INTEGER NOT NULL DEFAULT 0,
			pitches_thrown INTEGER NOT NULL DEFAULT 0,
			hits_allowed INTEGER NOT NULL DEFAULT 0,
			home_runs_allowed INTEGER NOT NULL DEFAULT 0,
			walks INTEGER NOT NULL DEFAULT 0,
			hit_batters INTEGER NOT NULL DEFAULT 0,
			strikeouts INTEGER NOT NULL DEFAULT 0,
			ground_balls_allowed INTEGER NOT NULL DEFAULT 0,
			line_drives_allowed INTEGER NOT NULL DEFAULT 0,
			infield_flies_allowed INTEGER NOT NULL DEFAULT 0,
			outfield_flies_allowed INTEGER NOT NULL DEFAULT 0,
			runs_allowed INTEGER NOT NULL DEFAULT 0,
			earned_runs INTEGER NOT NULL DEFAULT 0,
			complete_games INTEGER NOT NULL DEFAULT 0,
			shutouts INTEGER NOT NULL DEFAULT 0,
			quality_starts INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (player_id, year, season_number)
		)""",
		"CREATE INDEX IF NOT EXISTS idx_ps_year_season ON pitcher_stats(year, season_number)",
		"CREATE INDEX IF NOT EXISTS idx_ps_wins ON pitcher_stats(year, season_number, wins DESC)",
		"CREATE INDEX IF NOT EXISTS idx_ps_k ON pitcher_stats(year, season_number, strikeouts DESC)",
		"CREATE INDEX IF NOT EXISTS idx_ps_saves ON pitcher_stats(year, season_number, saves DESC)",
		"CREATE INDEX IF NOT EXISTS idx_ps_holds ON pitcher_stats(year, season_number, holds DESC)",
	]
	for statement_row in statements:
		var statement: String = str(statement_row)
		if not _execute(db, statement):
			return false
	if not _ensure_player_season_raw_abilities_column(db):
		return false
	if not _ensure_player_season_advanced_stats_column(db):
		return false
	if not _ensure_player_season_season_injury_days_column(db):
		return false
	if not _ensure_player_season_injury_return_day_column(db):
		return false
	if not _ensure_player_season_injury_type_column(db):
		return false
	if not _ensure_player_season_injury_severity_column(db):
		return false
	if not _ensure_player_season_fa_eligible_years_column(db):
		return false
	if not _ensure_pitcher_batted_ball_columns(db):
		return false
	return true


static func _ensure_player_season_raw_abilities_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "raw_abilities_snapshot_json":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN raw_abilities_snapshot_json TEXT NOT NULL DEFAULT '{}'")


static func _ensure_player_season_advanced_stats_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "advanced_stats_json":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN advanced_stats_json TEXT NOT NULL DEFAULT '{}'")


static func _ensure_player_season_fa_eligible_years_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "fa_eligible_years":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN fa_eligible_years INTEGER NOT NULL DEFAULT 0")


static func _ensure_player_season_season_injury_days_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "season_injury_days":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN season_injury_days INTEGER NOT NULL DEFAULT 0")


static func _ensure_player_season_injury_return_day_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "injury_return_day":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN injury_return_day INTEGER NOT NULL DEFAULT 0")


static func _ensure_player_season_injury_type_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "injury_type":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN injury_type TEXT NOT NULL DEFAULT ''")


static func _ensure_player_season_injury_severity_column(db: Object) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(player_season_records)")
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		if str(col.get("name", "")) == "injury_severity":
			return true
	return _execute(db, "ALTER TABLE player_season_records ADD COLUMN injury_severity INTEGER NOT NULL DEFAULT 0")


static func _ensure_pitcher_batted_ball_columns(db: Object) -> bool:
	return _ensure_table_columns(db, "pitcher_stats", {
		"ground_balls_allowed": "INTEGER NOT NULL DEFAULT 0",
		"line_drives_allowed": "INTEGER NOT NULL DEFAULT 0",
		"infield_flies_allowed": "INTEGER NOT NULL DEFAULT 0",
		"outfield_flies_allowed": "INTEGER NOT NULL DEFAULT 0",
	})


static func _ensure_table_columns(db: Object, table_name: String, column_defs: Dictionary) -> bool:
	var cols: Array = _query(db, "PRAGMA table_info(%s)" % table_name)
	var existing: Dictionary = {}
	for col_value in cols:
		var col: Dictionary = col_value as Dictionary
		existing[str(col.get("name", ""))] = true
	for column_value in column_defs.keys():
		var column_name: String = str(column_value)
		if bool(existing.get(column_name, false)):
			continue
		var column_def: String = str(column_defs[column_value])
		if not _execute(db, "ALTER TABLE %s ADD COLUMN %s %s" % [table_name, column_name, column_def]):
			return false
	return true


# PRAGMA user_version を読む (= 既に適用済のスキーマ世代)。
# 取れない場合は 0 (= 未適用) を返す。
static func get_user_version(db: Object) -> int:
	var rows: Array = _query(db, "PRAGMA user_version")
	if rows.is_empty():
		return 0
	var row: Dictionary = rows[0] as Dictionary
	return int(row.get("user_version", 0))


static func set_user_version(db: Object, version: int) -> bool:
	return _execute(db, "PRAGMA user_version = %d" % version)


static func _query(db: Object, sql: String) -> Array:
	if not _execute(db, sql):
		return []
	var result: Variant = db.get("query_result")
	if result is Array:
		return result as Array
	return []


static func _execute(db: Object, sql: String) -> bool:
	return bool(db.call("query", sql))


static func _close(db: Object) -> void:
	if db != null and db.has_method("close_db"):
		db.call("close_db")


static func _sql_string(value: String) -> String:
	return "'" + value.replace("'", "''") + "'"
