# 表示文言の外部化 (Loc + data/strings/<locale>.json) の回帰テスト。
extends GdUnitTestSuite

const BASE_TABLE_PATH: String = "res://data/strings/ja.json"
const SCANNED_DIRS: Array[String] = ["res://autoload", "res://domain", "res://services", "res://ui"]
# 文言をキー化し終えたファイル。ここに載せたファイルへ日本語の文字列リテラルを書き戻すと落ちる。
const MIGRATED_FILES: Array[String] = [
	"res://ui/screens/options_screen.gd",
]
const TEST_MOD_DIR: String = "user://__loc_test_mod"


func test_base_table_is_flat_string_object() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASE_TABLE_PATH))
	assert_bool(parsed is Dictionary).is_true()
	for key in (parsed as Dictionary).keys():
		assert_bool((parsed as Dictionary)[key] is String).override_failure_message("not a string: %s" % key).is_true()


# コード中の Loc.t("...") のリテラルキーがすべて基底言語の辞書にあること。
func test_code_keys_exist_in_base_table() -> void:
	var table: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BASE_TABLE_PATH)) as Dictionary
	var key_pattern: RegEx = RegEx.create_from_string("Loc\\.t\\(\"([^\"]+)\"")
	var missing: Array[String] = []
	var used: int = 0
	for path in _gd_files():
		for m in key_pattern.search_all(FileAccess.get_file_as_string(path)):
			used += 1
			var key: String = m.get_string(1)
			if not table.has(key):
				missing.append("%s: %s" % [path.get_file(), key])
	assert_int(used).is_greater(0)
	assert_array(missing).is_empty()


func test_migrated_files_have_no_japanese_literals() -> void:
	var literal_pattern: RegEx = RegEx.create_from_string("\"[^\"]*[\\x{3040}-\\x{30ff}\\x{4e00}-\\x{9fff}][^\"]*\"")
	var found: Array[String] = []
	for path in MIGRATED_FILES:
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i in range(lines.size()):
			if lines[i].strip_edges().begins_with("#"):
				continue
			if literal_pattern.search(lines[i]) != null:
				found.append("%s:%d" % [path.get_file(), i + 1])
	assert_array(found).is_empty()


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
