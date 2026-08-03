extends RefCounted
class_name PSPlayerCsvIo

# 選手・球団データの CSV ↔ dict 変換（1 行 = 1 エンティティ、表計算ソフトで編集可能）。
#
# 設計方針:
# - z_abilities / raw_abilities / position_aptitudes / position_experience はドット記法の
#   個別列に平坦化（例 z_abilities.Bat_Impact）。能力値は編集しやすいよう列に展開する。
# - source_data / arsenal は可変構造なので 1 セルに JSON 文字列で格納（*_json 列）。
# - 旧能力 (batting_abilities/fielding_abilities/legacy_abilities) は含めない（z が正準）。
# - クォート/エスケープは FileAccess.store_csv_line / get_csv_line に委譲（RFC 準拠）。
# - PSPlayer.to_dict() / PSTeam.to_dict() と 1 対 1 でラウンドトリップする。

# シード育成選手の「育成契約 N年目」推定に使う散らばりの幅 (在籍年数でこの年数までクランプする)。
# 育成年数の満了ルール (OffseasonService.DEV_CONTRACT_MAX_SEASONS) と同じ値にしておくと、
# 初期世界の育成選手が満了年で綺麗にばらける。
const SEED_DEVELOPMENT_TENURE_SPREAD: int = 3

const META_ORDER: Array = [
	"id", "name", "team_id", "position", "role", "age", "years", "bats", "throws",
	"height", "weight", "salary", "draft_round", "jersey_number", "sensyu_num",
	"development_player", "foreign_player", "hometown", "registered_roster",
	"contract_status", "fatigue", "injury_days", "injury_type", "injury_severity",
	"condition", "fixed_slot",
]
const META_INT_FIELDS: Array = [
	"id", "team_id", "position", "age", "years", "height", "weight", "salary",
	"draft_round", "jersey_number", "sensyu_num", "fatigue", "injury_days",
	"injury_severity", "condition", "fixed_slot",
]
const META_BOOL_FIELDS: Array = ["development_player", "foreign_player"]
const ARRAY_FIELDS: Array = ["allowed_slots", "preferred_slots"]
const FLAT_DICT_FIELDS: Array = [
	"z_abilities", "raw_abilities", "position_aptitudes", "position_experience",
]
const JSON_DICT_FIELDS: Array = ["source_data"]
# 変化球アーセナルは可変長の配列なので列に平坦化できない。source_data と同様 1 セルに JSON で持つ。
const JSON_ARRAY_FIELDS: Array = ["arsenal"]

const TEAM_META_ORDER: Array = [
	"id", "name", "short_name", "league", "color", "previous_rank", "funds", "auto_lineup",
]


# ---- Players ----

static func normalize_initial_seed_players(player_dicts: Array, initial_year: int) -> Array:
	var career_offset: int = career_log_year_offset(player_dicts, initial_year)
	var rows: Array = []
	for row_value in player_dicts:
		rows.append(normalize_initial_seed_player(row_value as Dictionary, initial_year, career_offset))
	return rows


# 進化後ワールドの career_log は各エントリの年 (y) がエクスポート時の未来年のまま残る。
# エクスポートは最終オフ完了後の開幕前状態なので、世界共通の一律シフトで全選手の最大 y が
# 「開始前年のオフシーズン」(initial_year - 1) に一致するようなオフセットを返す。
# 選手ごとの推定 (各自の最大 y アンカー) にしないのは、最終オフに記録が無い選手 (年俸据え置き等)
# だけずれてドラフト入団年が draft_year のリベース値と食い違うため。正規化済みデータでは 0 (冪等)。
static func career_log_year_offset(player_dicts: Array, initial_year: int) -> int:
	var max_year: int = 0
	for row_value in player_dicts:
		var source: Dictionary = (row_value as Dictionary).get("source_data", {}) as Dictionary
		for entry_value in source.get(PSCareerLog.KEY, []) as Array:
			max_year = maxi(max_year, int((entry_value as Dictionary).get("y", 0)))
	return maxi(0, max_year - (initial_year - 1))


static func normalize_initial_seed_player(row: Dictionary, initial_year: int, career_year_offset: int = 0) -> Dictionary:
	var out: Dictionary = row.duplicate(true)
	# 初期世界の全選手も年俸を有効数字2桁へ揃える (CSV由来の値は較正の都合で丸くないことがある)。
	# 冪等 (round_salary_2sig は既に2桁の値を変えない) なので再ロードしても値は安定する。
	out["salary"] = OffseasonService.round_salary_2sig(int(out.get("salary", 0)))
	var source: Dictionary = (out.get("source_data", {}) as Dictionary).duplicate(true)
	var fa_years: int = int(out.get("fa_eligible_years", 0))
	if fa_years <= 0:
		fa_years = PSPlayer.default_fa_eligible_years(
			bool(out.get("foreign_player", false)),
			int(out.get("age", 18)),
			int(out.get("years", 1)),
			source
		)
	var required_days: int = maxi(1, fa_years) * PSPlayer.FA_SERVICE_DAYS_PER_YEAR
	var service_days: int = maxi(0, int(source.get("fa_nissuu", int(out.get("years", 0)) * PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))
	var is_fa: bool = str(out.get("contract_status", "通常")) == "FA可能" or service_days >= required_days

	if is_fa:
		var inferred_pass_count: int = int(floor(float(maxi(0, service_days - required_days)) / float(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))
		var pass_count: int = maxi(0, int(source.get("fa_pass_count", inferred_pass_count)))
		source["fa_pass_count"] = pass_count
		var eligible_year: int = int(source.get("fa_eligible_year", 0))
		if eligible_year <= 0 or eligible_year > initial_year:
			source["fa_eligible_year"] = initial_year - pass_count
	elif int(source.get("fa_eligible_year", 0)) > initial_year:
		source.erase("fa_eligible_year")
		source.erase("fa_pass_count")

	if int(source.get("fa_signed_year", 0)) > initial_year:
		source.erase("fa_signed_year")
		source.erase("fa_contract_salary")
	if int(source.get("fa_days_accrued_year", 0)) > initial_year:
		source.erase("fa_days_accrued_year")
		source.erase("fa_active_days_last_season")
	# 初期世界は全員無契約 (単年) で開始する。複数年契約の発生源 (FA/外国人/契約年数決定) が
	# 生成した情報がシードに紛れ込んでいても無視する。オフ進行中のマーカー
	# (今オフFA宣言した / FA市場で引き取り手がなく残留した) も同様に落とす。
	source.erase("contract_end_year")
	source.erase("contract_total_years")
	source.erase("contract_signed_year")
	source.erase("fa_declared_year")
	source.erase("fa_returned_year")

	# draft_year / traded_year は現役ドラフトの適格判定 (当年ドラフト新人・当年トレード獲得の
	# 除外) に使われる (geneki_draft_service.gd)。進化後ワールドの未来年がそのまま残っていると
	# 初期世界の開始年でこの判定が誤爆するため、在籍年数から遡った年へリベースする。
	if source.has("draft_year") and int(source.get("draft_year", 0)) > initial_year:
		var years_in_league: int = maxi(0, int(out.get("years", 0)))
		source["draft_year"] = clampi(initial_year - years_in_league, initial_year - 60, initial_year)
	if source.has("traded_year") and int(source.get("traded_year", 0)) >= initial_year:
		source.erase("traded_year")
		source.erase("traded_from_team")

	# 育成契約の年数カウンタ (PSPlayer.development_seasons_completed の起点)。シードには履歴が無いので
	# 在籍年数から遡って推定する。全員に同じ年を入れると「N年ルール」で初期育成が同じオフに一斉放出
	# されるため、years でばらけさせて満了年をずらす。支配下選手には持たせない。
	if bool(out.get("development_player", false)):
		var since: int = int(source.get("development_since_year", 0))
		if since <= 0 or since > initial_year:
			var dev_years: int = clampi(int(out.get("years", 0)), 0, SEED_DEVELOPMENT_TENURE_SPREAD)
			source["development_since_year"] = initial_year - dev_years
	else:
		source.erase("development_since_year")

	# career_log の y も未来年のまま残ると経歴タブに未来年が表示される。世界共通オフセット
	# (career_log_year_offset) で一括シフトする。シフト後も開始年以降に残るエントリ
	# (オフセット 0 の単独呼び出しに紛れた未来年など) は年を偽装できないので落とす。
	if source.has(PSCareerLog.KEY):
		var kept_entries: Array = []
		for entry_value in source.get(PSCareerLog.KEY, []) as Array:
			var entry: Dictionary = entry_value as Dictionary
			var entry_year: int = int(entry.get("y", 0))
			if entry_year > 0:
				entry_year -= career_year_offset
				if entry_year >= initial_year:
					continue
				entry["y"] = entry_year
			kept_entries.append(entry)
		source[PSCareerLog.KEY] = kept_entries
	out["source_data"] = source
	_normalize_arsenal(out)
	return out


# 初期世界の投手に変化球アーセナルの実データを持たせ、現行ルールへ揃える。
# 1) 空なら生成して埋める: 旧シード CSV には arsenal 列が無く、初期選手だけが arsenal 空 =
#    z からの派生表示に頼る状態だった (派生は z で一意に決まるため球種構成に個性が無く、
#    ドラフト/外国人の生成投手とも扱いが違った)。生成器はそれらと同じ
#    PSPitchTypes.generate_arsenal。seed は選手 ID 由来で固定するので起動ごと・読み込み経路ごとに
#    ブレず、世界 Rng も消費しない。
# 2) 直球(ストレート)が無ければ1本を直球へ読み替える: 直球がシンカー等に差し替わりうる頃に
#    書き出されたシード CSV を、全投手が直球を持つ現行ルールへ揃える。
# どちらも既存データを尊重する形なので再正規化しても結果が変わらない (冪等)。
static func _normalize_arsenal(out: Dictionary) -> void:
	if int(out.get("position", 0)) != 1:
		return
	var existing: Variant = out.get("arsenal", [])
	if existing is Array and not (existing as Array).is_empty():
		out["arsenal"] = PSPitchTypes.ensure_straight((existing as Array).duplicate(true))
		return
	out["arsenal"] = PSPitchTypes.generate_arsenal(
		out.get("z_abilities", {}) as Dictionary,
		absi(hash(int(out.get("id", 0))))
	)

static func write_players(path: String, player_dicts: Array) -> bool:
	var flat_keys: Dictionary = _collect_flat_keys(player_dicts)
	var columns: Array = _player_columns(flat_keys)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSPlayerCsvIo.write_players: cannot open %s" % path)
		return false
	file.store_csv_line(PackedStringArray(columns))
	for row_value in player_dicts:
		var row: Dictionary = row_value as Dictionary
		file.store_csv_line(PackedStringArray(_player_row_cells(row, columns, flat_keys)))
	return true


static func read_players(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("PSPlayerCsvIo.read_players: missing %s" % path)
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSPlayerCsvIo.read_players: cannot open %s" % path)
		return []
	var header: PackedStringArray = file.get_csv_line()
	var columns: Array = []
	for h in header:
		columns.append(str(h))
	var rows: Array = []
	while not file.eof_reached():
		var cells: PackedStringArray = file.get_csv_line()
		if cells.size() == 1 and str(cells[0]).is_empty():
			continue
		rows.append(_player_dict_from_cells(columns, cells))
	return rows


static func _collect_flat_keys(player_dicts: Array) -> Dictionary:
	var result: Dictionary = {}
	for field in FLAT_DICT_FIELDS:
		result[field] = {}
	for row_value in player_dicts:
		var row: Dictionary = row_value as Dictionary
		for field in FLAT_DICT_FIELDS:
			var d: Variant = row.get(field, {})
			if d is Dictionary:
				for key in (d as Dictionary).keys():
					(result[field] as Dictionary)[str(key)] = true
	return result


static func _player_columns(flat_keys: Dictionary) -> Array:
	var columns: Array = META_ORDER.duplicate()
	columns.append_array(ARRAY_FIELDS)
	for field in FLAT_DICT_FIELDS:
		var keys: Array = (flat_keys[field] as Dictionary).keys()
		keys.sort()
		for key in keys:
			columns.append("%s.%s" % [field, str(key)])
	for field in JSON_DICT_FIELDS:
		columns.append("%s_json" % field)
	for field in JSON_ARRAY_FIELDS:
		columns.append("%s_json" % field)
	return columns


static func _player_row_cells(row: Dictionary, columns: Array, _flat_keys: Dictionary) -> Array:
	var cells: Array = []
	for column_value in columns:
		var column: String = str(column_value)
		cells.append(_player_cell_value(row, column))
	return cells


static func _player_cell_value(row: Dictionary, column: String) -> String:
	if column.ends_with("_json"):
		var field: String = column.substr(0, column.length() - 5)
		if JSON_ARRAY_FIELDS.has(field):
			var a: Variant = row.get(field, [])
			return JSON.stringify(a if a is Array else [])
		var d: Variant = row.get(field, {})
		return JSON.stringify(d if d is Dictionary else {})
	var dot: int = column.find(".")
	if dot >= 0:
		var group: String = column.substr(0, dot)
		var key: String = column.substr(dot + 1)
		var gd: Variant = row.get(group, {})
		if gd is Dictionary and (gd as Dictionary).has(key):
			return _num_to_str((gd as Dictionary)[key])
		return ""
	if ARRAY_FIELDS.has(column):
		var arr: Variant = row.get(column, [])
		if arr is Array:
			var parts: Array = []
			for x in (arr as Array):
				parts.append(str(int(x)))
			return ";".join(parts)
		return ""
	if META_BOOL_FIELDS.has(column):
		return "true" if bool(row.get(column, false)) else "false"
	if META_INT_FIELDS.has(column):
		return str(int(row.get(column, 0)))
	return str(row.get(column, ""))


static func _player_dict_from_cells(columns: Array, cells: PackedStringArray) -> Dictionary:
	var data: Dictionary = {}
	for field in FLAT_DICT_FIELDS:
		data[field] = {}
	for i in range(columns.size()):
		if i >= cells.size():
			break
		var column: String = str(columns[i])
		var cell: String = str(cells[i])
		if column.ends_with("_json"):
			var field: String = column.substr(0, column.length() - 5)
			var parsed: Variant = JSON.parse_string(cell) if not cell.is_empty() else null
			if JSON_ARRAY_FIELDS.has(field):
				data[field] = parsed if parsed is Array else []
			else:
				data[field] = parsed if parsed is Dictionary else {}
			continue
		var dot: int = column.find(".")
		if dot >= 0:
			if cell.is_empty():
				continue
			var group: String = column.substr(0, dot)
			var key: String = column.substr(dot + 1)
			if not data.has(group):
				data[group] = {}
			(data[group] as Dictionary)[key] = float(cell)
			continue
		if ARRAY_FIELDS.has(column):
			data[column] = _parse_int_array(cell)
			continue
		if META_BOOL_FIELDS.has(column):
			data[column] = cell == "true"
			continue
		if META_INT_FIELDS.has(column):
			data[column] = int(cell) if not cell.is_empty() else 0
			continue
		data[column] = cell
	return data


static func _parse_int_array(cell: String) -> Array:
	var result: Array = []
	if cell.is_empty():
		return result
	for part in cell.split(";", false):
		result.append(int(part))
	return result


static func _num_to_str(value: Variant) -> String:
	if value is float:
		var f: float = value as float
		if f == floor(f) and absf(f) < 1.0e15:
			return str(int(f))
		return str(f)
	if value is int:
		return str(value)
	return str(value)


# ---- Teams ----

static func write_teams(path: String, team_dicts: Array) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("PSPlayerCsvIo.write_teams: cannot open %s" % path)
		return false
	file.store_csv_line(PackedStringArray(TEAM_META_ORDER))
	for row_value in team_dicts:
		var row: Dictionary = row_value as Dictionary
		var cells: Array = []
		for column_value in TEAM_META_ORDER:
			var column: String = str(column_value)
			match column:
				"auto_lineup":
					cells.append("true" if bool(row.get(column, true)) else "false")
				"id", "previous_rank", "funds":
					cells.append(str(int(row.get(column, 0))))
				_:
					cells.append(str(row.get(column, "")))
		file.store_csv_line(PackedStringArray(cells))
	return true


static func read_teams(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_error("PSPlayerCsvIo.read_teams: missing %s" % path)
		return []
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PSPlayerCsvIo.read_teams: cannot open %s" % path)
		return []
	var header: PackedStringArray = file.get_csv_line()
	var columns: Array = []
	for h in header:
		columns.append(str(h))
	var rows: Array = []
	while not file.eof_reached():
		var cells: PackedStringArray = file.get_csv_line()
		if cells.size() == 1 and str(cells[0]).is_empty():
			continue
		var data: Dictionary = {}
		for i in range(columns.size()):
			if i >= cells.size():
				break
			var column: String = str(columns[i])
			var cell: String = str(cells[i])
			match column:
				"auto_lineup":
					data[column] = cell == "true"
				"id", "previous_rank", "funds":
					data[column] = int(cell) if not cell.is_empty() else 0
				_:
					data[column] = cell
		rows.append(data)
	return rows
