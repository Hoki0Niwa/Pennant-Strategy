# 表示文言の外部化 (Loc + data/strings/<locale>.json) の回帰テスト。
extends GdUnitTestSuite

const BASE_TABLE_PATH: String = "res://data/strings/ja.json"
const SCANNED_DIRS: Array[String] = ["res://autoload", "res://domain", "res://services", "res://ui"]
# 開発者向けの調査画面・レポート (プレイヤーに見せない) は文言をキー化していない。
const DEV_ONLY_FILES: Array[String] = [
	"res://ui/screens/balance_report_screen.gd",
	"res://ui/screens/draft_simulator_screen.gd",
	"res://ui/screens/player_probe_screen.gd",
	"res://ui/screens/player_probe_chart.gd",
	"res://ui/screens/draft_growth_distribution_chart.gd",
	"res://services/reports/simulation_reporter.gd",
	"res://services/reports/long_autoplay_reporter.gd",
	"res://services/reports/player_probe_runner.gd",
	"res://services/reports/pa_response_surface_runner.gd",
	"res://services/reports/platoon_probe_runner.gd",
	"res://services/reports/reference_population.gd",
	"res://services/reports/report_health.gd",
	"res://domain/farm_schedule.gd",
]
# 表示文言ではなくデータ値として保存・比較される日本語 (セーブ/CSV/SQLite に入る ID 相当)。
# 表示時は PSPlayer.registered_roster_label / contract_status_label 等で Loc に通す。
const DATA_VALUE_LITERALS: Array[String] = [
	"支配下", "育成", "ファーム", "通常", "FA可能", "FA権間近",
	"両",                              # 投打の旧入力値 (box_score_builder の読み替え)
	"佐藤", "翔",                       # 名前プールが空のときの既定氏名
	"ノースメン長野", "オスプレー大分",   # ファーム専用球団の球団名
]
const TEST_MOD_DIR: String = "user://__loc_test_mod"


func test_base_table_is_flat_string_object() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASE_TABLE_PATH))
	assert_bool(parsed is Dictionary).is_true()
	for key in (parsed as Dictionary).keys():
		assert_bool((parsed as Dictionary)[key] is String).override_failure_message("not a string: %s" % key).is_true()


# コード中のキーがすべて基底言語の辞書にあること。Loc.t("...") の直書きに加え、定数テーブル等に
# 置いたキー (辞書の名前空間 = キー先頭の区切りで始まるドット区切りリテラル) も検査する。
func test_code_keys_exist_in_base_table() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASE_TABLE_PATH)) as Dictionary
	var namespaces: Dictionary = {}
	for key in table.keys():
		namespaces[str(key).get_slice(".", 0)] = true
	var literal_pattern: RegEx = RegEx.create_from_string("\"([a-z0-9_]+(?:\\.[a-z0-9_]+)+)\"")
	var missing: Array[String] = []
	var used: int = 0
	for path in _gd_files():
		for m in literal_pattern.search_all(FileAccess.get_file_as_string(path)):
			var key: String = m.get_string(1)
			if not namespaces.has(key.get_slice(".", 0)):
				continue
			used += 1
			if not table.has(key):
				missing.append("%s: %s" % [path.get_file(), key])
	assert_int(used).is_greater(0)
	assert_array(missing).is_empty()


# 名前空間がルール JSON の dot path (ModManager.rule_value) と衝突すると上の検査が誤検出する。
func test_namespaces_do_not_collide_with_rule_paths() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASE_TABLE_PATH)) as Dictionary
	var rules: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ModManager.DEFAULT_RULES_PATH)) as Dictionary
	var collisions: Array[String] = []
	for key in table.keys():
		var ns: String = str(key).get_slice(".", 0)
		if rules.has(ns) and not collisions.has(ns):
			collisions.append(ns)
	assert_array(collisions).is_empty()


# 表示文言はすべて data/strings へ出してあること。コメント (行頭・行末とも) は対象外。
func test_code_has_no_japanese_literals() -> void:
	var japanese: RegEx = RegEx.create_from_string("[\\x{3040}-\\x{30ff}\\x{4e00}-\\x{9fff}]")
	var found: Array[String] = []
	for path in _gd_files():
		if DEV_ONLY_FILES.has(path):
			continue
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i in range(lines.size()):
			for literal in _string_literals(lines[i]):
				if japanese.search(literal) != null and not DATA_VALUE_LITERALS.has(literal):
					found.append("%s:%d %s" % [path.get_file(), i + 1, literal])
	assert_array(found).is_empty()


func test_data_value_labels_resolve_through_loc() -> void:
	assert_str(PSPlayer.registered_roster_label("育成")).is_equal(Loc.t("registered_roster.development"))
	assert_str(PSPlayer.contract_status_label("FA可能")).is_equal(Loc.t("contract_status.fa_eligible"))
	for position in range(1, 11):
		assert_bool(Loc.has_key(str(PSPlayer.POSITION_SHORT_KEYS[position]))).is_true()


func test_t_fills_named_params_and_falls_back_to_key() -> void:
	assert_str(Loc.t("options.title")).is_equal("オプション")
	assert_str(Loc.t("options.status.team_changed", {"team": "東京"})).is_equal("操作チームを変更しました: 東京")
	assert_str(Loc.t("__no_such_key__")).is_equal("__no_such_key__")


func test_mod_strings_override_only_listed_keys() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_MOD_DIR)
	var file: FileAccess = FileAccess.open("%s/ja.json" % TEST_MOD_DIR, FileAccess.WRITE)
	file.store_string(JSON.stringify({"options.title": "設定"}))
	file.close()

	ModManager._apply_manifest({"id": "__loc_test", "_base_dir": TEST_MOD_DIR, "strings": {"ja": "ja.json"}})
	Loc.reload()
	var overridden: String = Loc.t("options.title")
	var untouched: String = Loc.t("options.save.panel")

	# 実 mod 構成に戻してから検証する (assert が落ちても後続テストへ上書きを持ち越さない)。
	ModManager.reload_mods()
	DirAccess.remove_absolute("%s/ja.json" % TEST_MOD_DIR)
	DirAccess.remove_absolute(TEST_MOD_DIR)

	assert_str(overridden).is_equal("設定")
	assert_str(untouched).is_equal("セーブデータ")
	assert_str(Loc.t("options.title")).is_equal("オプション")


# 1行から文字列リテラルの中身を取り出す。文字列外の # 以降 (行末コメント) は読まない。
func _string_literals(line: String) -> Array[String]:
	var out: Array[String] = []
	var quote: String = ""
	var current: String = ""
	var i: int = 0
	while i < line.length():
		var ch: String = line[i]
		if quote.is_empty():
			if ch == "#":
				break
			if ch == "\"" or ch == "'":
				quote = ch
				current = ""
		elif ch == "\\":
			current += ch
			if i + 1 < line.length():
				current += line[i + 1]
			i += 1
		elif ch == quote:
			out.append(current)
			quote = ""
		else:
			current += ch
		i += 1
	return out


func _gd_files() -> Array[String]:
	var files: Array[String] = []
	for dir_path in SCANNED_DIRS:
		_collect_gd_files(dir_path, files)
	return files


func _collect_gd_files(dir_path: String, out: Array[String]) -> void:
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.ends_with(".gd"):
			out.append("%s/%s" % [dir_path, file_name])
	for sub in DirAccess.get_directories_at(dir_path):
		_collect_gd_files("%s/%s" % [dir_path, sub], out)
