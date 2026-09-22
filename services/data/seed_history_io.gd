extends RefCounted
class_name PSSeedHistoryIo

# 初期世界の「開始前の年」の履歴 (選手の年度成績・球団の年度成績・季ごとのリーグ文脈) の書き出しと
# 読み込み。シード生成 (tools/run_export_seed_world) が進化 run の成績をここで書き出し、新規ゲームの
# 開始時 (AppState.start_new_season) に RecordStore へ流し込む。これで長いプロ歴の選手も開始時点で
# 過去成績を持つ。
#
# ファイルは 2 本:
# - 選手の年度成績 (CSV、1 行 = 1 選手 × 1 季)。能力スナップショットと成績は列に平坦化し、守備位置別の
#   高度指標のような可変構造だけを JSON セルに入れる (PSPlayerCsvIo と同じ方針)。
# - 季ごとの履歴 (JSON)。球団の年度成績と、その季のリーグ全体の文脈 (WAR のリーグ文脈・選手評価の
#   基準分布) を持つ。
#
# ## 季ごとの文脈を持ち込む理由
# シードに入るのは開始時点の現役と海外組だけで、進化 run の途中で引退した選手の成績は入らない。
# 古い季ほど母集団が生き残った選手に偏るので、そこから文脈を測り直すと壊れる — WAR は
# 「試合数に比例する WAR プールを在籍者の打席で割る」ため、母集団が半分なら 1 人あたりの WAR が
# 倍近くに膨らむ。そこで書き出し時 (母集団が揃っている進化 run 中) に測った文脈を持ち込み、開始前の季は
# それを使う (PSWarCalculator.build_league_context / PSPerformanceReference.for_season)。
#
# ## 年と season_number
# 開始年を initial_year とすると、開始前の季は year < initial_year、
# season_number = year − initial_year + 1 (前年 = 0、2 年前 = −1、…)。読み込み時に year から付け直す。
#
# ## 選手との対応
# 年度成績は選手 ID と名前の両方が一致したときだけ付ける。選手 CSV だけを mod で差し替えたときに、
# 別人の成績が同じ ID に付くのを防ぐため。

const RECORD_META_ORDER: Array = [
	"player_id", "year", "season_number", "team_id", "name", "age", "years", "position", "role",
	"development_player", "foreign_player", "registered_roster", "salary", "jersey_number",
	"season_injury_days", "fa_eligible_years",
]
const RECORD_META_INT_FIELDS: Array = [
	"player_id", "year", "season_number", "team_id", "age", "years", "position", "salary",
	"jersey_number", "season_injury_days", "fa_eligible_years",
]
const RECORD_META_BOOL_FIELDS: Array = ["development_player", "foreign_player"]
# 列に平坦化する辞書。列はファイル内の全行のキーの和集合。
const RECORD_FLAT_FIELDS: Array = [
	"z_abilities_snapshot", "raw_abilities_snapshot", "position_aptitudes_snapshot",
	"position_experience_snapshot", "batter_stats", "pitcher_stats", "farm_batter_stats",
	"farm_pitcher_stats",
]
# 成績の辞書は 0 のキーを書かない (投手の打撃成績・一軍選手の二軍成績はほぼ全部 0)。
const RECORD_SPARSE_FIELDS: Array = ["batter_stats", "pitcher_stats", "farm_batter_stats", "farm_pitcher_stats"]
const RECORD_JSON_ARRAY_FIELDS: Array = ["arsenal_snapshot"]
const RECORD_JSON_DICT_FIELDS: Array = ["advanced_stats", "farm_advanced_stats"]
# 高度指標のうち読み戻し (PSAdvancedStats.load_from_dict) が使う生の値。率や表示用の派生値は
# 読み戻し時に計算し直されるので書かない。
const ADVANCED_RAW_KEYS: Array = [
	"plate_appearances", "woba_denominator", "xwoba_denominator", "woba_numerator", "xwoba_numerator",
	"re24", "bsr", "fielding_chances", "fielding_outs",
	"fielding_chances_by_position", "fielding_chances_by_oaa_zone", "fielding_outs_by_position",
	"fielding_outs_by_oaa_zone", "defensive_outs_by_position", "defensive_outs_by_oaa_zone",
	"oaa_by_zone", "oaa_by_position", "rngr_by_position", "errr_by_position", "dpr_by_position",
	"uzr_by_position", "drs_by_position",
]
# 能力スナップショット (z) の丸め。表示 1〜100 点へ写すだけなので 1e-4 で足りる。
const SNAPSHOT_STEP: float = 0.0001

const SEASONS_FORMAT_VERSION: int = 1
const SEASON_KEY_TEAM_RECORDS: String = "team_records"
const SEASON_KEY_WAR_CONTEXT: String = "war_context"
const SEASON_KEY_REFERENCES: String = "references"


static func season_number_for_year(year: int, initial_year: int) -> int:
	return year - initial_year + 1


# ---- 書き出し側 (進化 run の各季末に呼ぶ) ----

# 1 選手 × 1 季の書き出し用の行。source_data (経歴ログ等) は選手側が持つので落とす。
static func record_row(record: PSPlayerSeasonRecord) -> Dictionary:
	var row: Dictionary = {}
	var full: Dictionary = record.to_dict()
	for key in RECORD_META_ORDER:
		row[key] = full.get(key)
	row["z_abilities_snapshot"] = _snapped_map(record.z_abilities_snapshot)
	row["raw_abilities_snapshot"] = record.raw_abilities_snapshot.duplicate(true)
	row["position_aptitudes_snapshot"] = record.position_aptitudes_snapshot.duplicate(true)
	row["position_experience_snapshot"] = record.position_experience_snapshot.duplicate(true)
	for field in RECORD_SPARSE_FIELDS:
		row[field] = _nonzero_map(full.get(field, {}) as Dictionary)
	row["arsenal_snapshot"] = record.arsenal_snapshot.duplicate(true)
	for field in RECORD_JSON_DICT_FIELDS:
		row[field] = _advanced_raw(full.get(field, {}) as Dictionary)
	return row


# 季ごとの履歴 1 件。references は PSPerformanceReference.measure_completed_season の戻り値。
static func season_entry(year: int, season_number: int, team_records: Array, war_context: Dictionary, references: Dictionary) -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		SEASON_KEY_TEAM_RECORDS: team_records,
		SEASON_KEY_WAR_CONTEXT: war_context,
		SEASON_KEY_REFERENCES: references,
	}


# 進化 run の年を開始前の年へずらす (経歴ログと同じ PSPlayerCsvIo.career_log_year_offset を渡す)。
# ずらした結果が開始年以降になる行は「開始前」として置けないので落とす。
static func shift_record_rows(rows: Array, year_offset: int, initial_year: int) -> Array:
	var shifted: Array = []
	for row_value in rows:
		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		var year: int = int(row.get("year", 0)) - year_offset
		if year <= 0 or year >= initial_year:
			continue
		row["year"] = year
		row["season_number"] = season_number_for_year(year, initial_year)
		shifted.append(row)
	return shifted


static func shift_season_entries(entries: Array, year_offset: int, initial_year: int) -> Array:
	var shifted: Array = []
	for entry_value in entries:
		var entry: Dictionary = (entry_value as Dictionary).duplicate(true)
		var year: int = int(entry.get("year", 0)) - year_offset
		if year <= 0 or year >= initial_year:
			continue
		_set_season_year(entry, year, season_number_for_year(year, initial_year))
		shifted.append(entry)
	return shifted


static func write_records(path: String, rows: Array) -> bool:
	var flat_keys: Dictionary = _collect_flat_keys(rows)
	var columns: Array = _record_columns(flat_keys)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSSeedHistoryIo.write_records: cannot open %s" % path)
		return false
	file.store_csv_line(PackedStringArray(columns))
	for row_value in rows:
		file.store_csv_line(PackedStringArray(_record_cells(row_value as Dictionary, columns)))
	return true


static func write_seasons(path: String, entries: Array) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSSeedHistoryIo.write_seasons: cannot open %s" % path)
		return false
	var payload: Dictionary = {"version": SEASONS_FORMAT_VERSION, "seasons": entries}
	file.store_string(JSON.stringify(payload, "", true, true))
	return true


# ---- 読み込み側 ----

static func read_records(path: String) -> Array:
	var rows: Array = []
	if not FileAccess.file_exists(path):
		return rows
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSSeedHistoryIo.read_records: cannot open %s" % path)
		return rows
	var columns: Array = []
	for header_cell in file.get_csv_line():
		columns.append(str(header_cell))
	while not file.eof_reached():
		var cells: PackedStringArray = file.get_csv_line()
		if cells.size() == 1 and str(cells[0]).is_empty():
			continue
		rows.append(_record_row_from_cells(columns, cells))
	return rows


static func read_seasons(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSSeedHistoryIo.read_seasons: cannot open %s" % path)
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_error("PSSeedHistoryIo.read_seasons: invalid %s" % path)
		return []
	return ((parsed as Dictionary).get("seasons", []) as Array).duplicate(true)


# 行を年度レコードにする。能力や成績以外の静的な情報 (身長・出身地・投打など) は選手本体から取る。
# 開始年以降の行・選手が居ない行・名前が食い違う行は捨てる (冒頭「選手との対応」)。
static func build_records(rows: Array, players_by_id: Dictionary, initial_year: int) -> Array:
	var records: Array = []
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var year: int = int(row.get("year", 0))
		if year <= 0 or year >= initial_year:
			continue
		var player: PSPlayer = players_by_id.get(int(row.get("player_id", 0))) as PSPlayer
		if player == null or player.name != str(row.get("name", "")):
			continue
		var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, year, season_number_for_year(year, initial_year))
		record.source_data = {}
		# 行の列名は年度レコードのプロパティ名と同じ。年と season_number は上で付け直した値を使う。
		for key in RECORD_META_ORDER:
			if key != "year" and key != "season_number" and row.has(key):
				record.set(key, row[key])
		record.z_abilities_snapshot = (row.get("z_abilities_snapshot", {}) as Dictionary).duplicate()
		record.raw_abilities_snapshot = (row.get("raw_abilities_snapshot", {}) as Dictionary).duplicate()
		record.position_aptitudes_snapshot = (row.get("position_aptitudes_snapshot", {}) as Dictionary).duplicate()
		record.position_experience_snapshot = PSPlayer.normalized_position_experience(
			row.get("position_experience_snapshot", {}) as Dictionary, record.position, record.position_aptitudes_snapshot
		)
		record.arsenal_snapshot = (row.get("arsenal_snapshot", []) as Array).duplicate(true)
		record.batter_stats = PSBatterStats.from_dict(row.get("batter_stats", {}) as Dictionary)
		record.pitcher_stats = PSPitcherStats.from_dict(row.get("pitcher_stats", {}) as Dictionary)
		record.farm_batter_stats = PSBatterStats.from_dict(row.get("farm_batter_stats", {}) as Dictionary)
		record.farm_pitcher_stats = PSPitcherStats.from_dict(row.get("farm_pitcher_stats", {}) as Dictionary)
		record.advanced_stats = _advanced_from_row(row.get("advanced_stats", {}) as Dictionary, player.id)
		record.farm_advanced_stats = _advanced_from_row(row.get("farm_advanced_stats", {}) as Dictionary, player.id)
		records.append(record)
	return records


# 季ごとの履歴を initial_year 基準の season_number へ付け直し、JSON で崩れた型を戻す。
# 開始年以降の季は捨てる。セーブの読み戻し (RecordStore) も同じ正規化を通す。
static func normalize_season_entries(entries: Array, initial_year: int) -> Array:
	var normalized: Array = []
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = normalize_season_entry(entry_value as Dictionary)
		var year: int = int(entry.get("year", 0))
		if year <= 0 or year >= initial_year:
			continue
		_set_season_year(entry, year, season_number_for_year(year, initial_year))
		normalized.append(entry)
	return normalized


# JSON を通ると整数キーが文字列になる。基準分布の守備位置別平均 (regulars.by_position) は
# 整数の守備位置で引かれるので、ここで戻す。
static func normalize_season_entry(entry: Dictionary) -> Dictionary:
	var out: Dictionary = entry.duplicate(true)
	out["year"] = int(out.get("year", 0))
	out["season_number"] = int(out.get("season_number", 0))
	var references: Dictionary = out.get(SEASON_KEY_REFERENCES, {}) as Dictionary
	for level_key in references.keys():
		var reference: Dictionary = references[level_key] as Dictionary
		var regulars: Dictionary = reference.get("regulars", {}) as Dictionary
		var by_position: Dictionary = {}
		for position_key in (regulars.get("by_position", {}) as Dictionary).keys():
			by_position[int(position_key)] = float((regulars["by_position"] as Dictionary)[position_key])
		if regulars.has("by_position"):
			regulars["by_position"] = by_position
	return out


static func reference_level_key(level: int) -> String:
	return str(level)


# ---- 内部 ----

static func _set_season_year(entry: Dictionary, year: int, season_number: int) -> void:
	entry["year"] = year
	entry["season_number"] = season_number
	var war_context: Dictionary = entry.get(SEASON_KEY_WAR_CONTEXT, {}) as Dictionary
	if not war_context.is_empty():
		war_context["year"] = year
		war_context["season_number"] = season_number
	for team_value in entry.get(SEASON_KEY_TEAM_RECORDS, []) as Array:
		var team_row: Dictionary = team_value as Dictionary
		team_row["year"] = year
		team_row["season_number"] = season_number


static func _advanced_from_row(source: Dictionary, player_id: int) -> PSAdvancedStats:
	var advanced: PSAdvancedStats = PSAdvancedStats.new()
	if not source.is_empty():
		advanced.load_from_dict(source)
	advanced.player_id = player_id
	return advanced


static func _snapped_map(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in source.keys():
		out[key] = snappedf(float(source[key]), SNAPSHOT_STEP)
	return out


static func _nonzero_map(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in source.keys():
		var value: Variant = source[key]
		if (value is int or value is float) and float(value) == 0.0:
			continue
		out[key] = value
	return out


static func _advanced_raw(source: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in ADVANCED_RAW_KEYS:
		if not source.has(key):
			continue
		var value: Variant = source[key]
		if value is Dictionary:
			if (value as Dictionary).is_empty():
				continue
		elif float(value) == 0.0:
			continue
		out[key] = value
	return out


static func _collect_flat_keys(rows: Array) -> Dictionary:
	var result: Dictionary = {}
	for field in RECORD_FLAT_FIELDS:
		result[field] = {}
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		for field in RECORD_FLAT_FIELDS:
			for key in (row.get(field, {}) as Dictionary).keys():
				(result[field] as Dictionary)[str(key)] = true
	return result


static func _record_columns(flat_keys: Dictionary) -> Array:
	var columns: Array = RECORD_META_ORDER.duplicate()
	for field in RECORD_FLAT_FIELDS:
		var keys: Array = (flat_keys[field] as Dictionary).keys()
		keys.sort()
		for key in keys:
			columns.append("%s.%s" % [field, str(key)])
	for field in RECORD_JSON_ARRAY_FIELDS + RECORD_JSON_DICT_FIELDS:
		columns.append("%s_json" % field)
	return columns


static func _record_cells(row: Dictionary, columns: Array) -> Array:
	var cells: Array = []
	for column_value in columns:
		var column: String = str(column_value)
		if column.ends_with("_json"):
			var value: Variant = row.get(column.substr(0, column.length() - 5))
			var empty: bool = value == null \
				or (value is Array and (value as Array).is_empty()) \
				or (value is Dictionary and (value as Dictionary).is_empty())
			cells.append("" if empty else JSON.stringify(value))
			continue
		var dot: int = column.find(".")
		if dot >= 0:
			var group: Dictionary = row.get(column.substr(0, dot), {}) as Dictionary
			var key: String = column.substr(dot + 1)
			cells.append(PSPlayerCsvIo._num_to_str(group[key]) if group.has(key) else "")
			continue
		if RECORD_META_BOOL_FIELDS.has(column):
			cells.append("true" if bool(row.get(column, false)) else "false")
		elif RECORD_META_INT_FIELDS.has(column):
			cells.append(str(int(row.get(column, 0))))
		else:
			cells.append(str(row.get(column, "")))
	return cells


static func _record_row_from_cells(columns: Array, cells: PackedStringArray) -> Dictionary:
	var row: Dictionary = {}
	for field in RECORD_FLAT_FIELDS:
		row[field] = {}
	for index in range(mini(columns.size(), cells.size())):
		var column: String = str(columns[index])
		var cell: String = str(cells[index])
		if column.ends_with("_json"):
			var field: String = column.substr(0, column.length() - 5)
			var parsed: Variant = JSON.parse_string(cell) if not cell.is_empty() else null
			if RECORD_JSON_ARRAY_FIELDS.has(field):
				row[field] = parsed if parsed is Array else []
			else:
				row[field] = parsed if parsed is Dictionary else {}
			continue
		var dot: int = column.find(".")
		if dot >= 0:
			if not cell.is_empty():
				# 成績・適性・球速は整数で戻す (z だけが実数)。
				var group: String = column.substr(0, dot)
				var number: float = float(cell)
				var integral: bool = group != "z_abilities_snapshot" and number == floor(number)
				(row[group] as Dictionary)[column.substr(dot + 1)] = int(number) if integral else number
			continue
		if RECORD_META_BOOL_FIELDS.has(column):
			row[column] = cell == "true"
		elif RECORD_META_INT_FIELDS.has(column):
			row[column] = int(cell) if not cell.is_empty() else 0
		else:
			row[column] = cell
	return row
