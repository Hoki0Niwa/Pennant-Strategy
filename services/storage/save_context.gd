extends RefCounted

# セーブ先フォルダの選択とパス解決を一元管理する。
# ゲーム本体・RecordStore・SQLite・試合ログはここから現在の save_* フォルダを取得し、
# セーブ本体の外へ状態を書かないようにする。
const SAVE_ROOT: String = "user://saves"
const ACTIVE_SAVE_PATH: String = "user://pennant_strategy_active_save.json"

const GAME_STATE_FILE: String = "pennant_strategy_m0.save"
const RECORDS_FILE: String = "pennant_strategy_records_m1.json"
const RUNTIME_DB_FILE: String = "pennant_strategy_runtime.sqlite"
const GAME_LOG_DIR: String = "game_logs"

static var _active_loaded: bool = false
static var _active_save_id: String = ""


# 新規ゲーム用に timestamp ベースの save_* フォルダを作り、以後の保存先として選択する。
# 同一秒に複数作られた場合は _02, _03... を付けて衝突を避ける。
static func begin_new_save() -> bool:
	if not _ensure_dir(SAVE_ROOT):
		return false
	var save_id: String = _new_save_id()
	var save_dir: String = save_dir_for_id(save_id)
	if not _ensure_dir(save_dir):
		return false
	_active_loaded = true
	_active_save_id = save_id
	return _write_active_meta()


# 起動時の復帰用。前回選択したフォルダが有効ならそれを使い、無ければ最新の save_* を選ぶ。
static func select_active_or_latest_save() -> bool:
	ensure_active_loaded()
	if has_active_save():
		return true
	var latest_id: String = latest_save_id()
	if latest_id.is_empty():
		return false
	return activate_save_id(latest_id)


# UI やロード処理から明示的にセーブフォルダを選ぶ入口。
# save_id はフォルダ名だけを受け取り、パス区切りを含む値は拒否する。
static func activate_save_id(save_id: String) -> bool:
	if not _valid_save_id(save_id):
		return false
	if not _save_dir_exists(save_id):
		return false
	_active_loaded = true
	_active_save_id = save_id
	return _write_active_meta()


# ACTIVE_SAVE_PATH を一度だけ読み、プロセス内キャッシュへ反映する。
# メタファイルが壊れている/指すフォルダが消えている場合はアクティブ無しとして扱う。
static func ensure_active_loaded() -> void:
	if _active_loaded:
		return
	_active_loaded = true
	_active_save_id = ""
	if not FileAccess.file_exists(ACTIVE_SAVE_PATH):
		return
	var file: FileAccess = FileAccess.open(ACTIVE_SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return
	var save_id: String = str((parsed as Dictionary).get("active_save_id", ""))
	if _valid_save_id(save_id) and _save_dir_exists(save_id):
		_active_save_id = save_id


static func has_active_save() -> bool:
	ensure_active_loaded()
	return (not _active_save_id.is_empty()) and _save_dir_exists(_active_save_id)


static func active_save_id() -> String:
	ensure_active_loaded()
	return _active_save_id


static func active_save_dir() -> String:
	if not has_active_save():
		return ""
	return save_dir_for_id(_active_save_id)


static func latest_save_id() -> String:
	var ids: Array = save_ids()
	if ids.is_empty():
		return ""
	return str(ids[ids.size() - 1])


# user://saves 配下にある有効な save_* フォルダを昇順で返す。
# timestamp 形式なので、末尾が最新セーブとして扱える。
static func save_ids() -> Array:
	if not _ensure_dir(SAVE_ROOT):
		return []
	var ids: Array = []
	var dir: DirAccess = DirAccess.open(SAVE_ROOT)
	if dir == null:
		return ids
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if dir.current_is_dir() and _valid_save_id(name) and name.begins_with("save_"):
			ids.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	ids.sort()
	return ids


static func save_dir_for_id(save_id: String) -> String:
	return _join(SAVE_ROOT, save_id)


# 現在選択中セーブの主要ファイルパス。未選択なら空文字を返し、呼び出し側が保存不可として扱う。
static func game_state_path() -> String:
	var dir: String = active_save_dir()
	if dir.is_empty():
		return ""
	return _join(dir, GAME_STATE_FILE)


static func records_path() -> String:
	var dir: String = active_save_dir()
	if dir.is_empty():
		return ""
	return _join(dir, RECORDS_FILE)


static func runtime_db_path() -> String:
	var dir: String = active_save_dir()
	if dir.is_empty():
		return ""
	return _join(dir, RUNTIME_DB_FILE)


static func game_log_root() -> String:
	var dir: String = active_save_dir()
	if dir.is_empty():
		return ""
	return _join(dir, GAME_LOG_DIR)


static func display_path() -> String:
	var dir: String = active_save_dir()
	if dir.is_empty():
		return "未作成"
	return dir


# 現在のセーブフォルダを丸ごと削除する。テスト/新規作成向けの破棄操作なので、
# ACTIVE_SAVE_PATH も同時にクリアして孤立したアクティブ参照を残さない。
static func delete_current_save_data() -> Array:
	var deleted: Array = []
	if has_active_save():
		var dir: String = active_save_dir()
		if _remove_dir_recursive(dir):
			deleted.append(dir)
		clear_active_save()
		return deleted

	return deleted


# 指定 save_id のフォルダを丸ごと削除する (アクティブ以外のセーブも削除できる)。
# アクティブなセーブを消した場合は ACTIVE_SAVE_PATH もクリアして孤立参照を残さない。
static func delete_save_id(save_id: String) -> bool:
	if not _valid_save_id(save_id) or not _save_dir_exists(save_id):
		return false
	if not _remove_dir_recursive(save_dir_for_id(save_id)):
		return false
	if active_save_id() == save_id:
		clear_active_save()
	return true


static func clear_active_save() -> void:
	_active_loaded = true
	_active_save_id = ""
	if FileAccess.file_exists(ACTIVE_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ACTIVE_SAVE_PATH))


static func _write_active_meta() -> bool:
	var file: FileAccess = FileAccess.open(ACTIVE_SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"active_save_id": _active_save_id}, "\t"))
	return true


static func _new_save_id() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var base: String = "save_%04d%02d%02d_%02d%02d%02d" % [
		int(dt.get("year", 0)),
		int(dt.get("month", 0)),
		int(dt.get("day", 0)),
		int(dt.get("hour", 0)),
		int(dt.get("minute", 0)),
		int(dt.get("second", 0)),
	]
	var candidate: String = base
	var suffix: int = 2
	while _save_dir_exists(candidate):
		candidate = "%s_%02d" % [base, suffix]
		suffix += 1
	return candidate


static func _save_dir_exists(save_id: String) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(save_dir_for_id(save_id)))


static func _valid_save_id(save_id: String) -> bool:
	return not save_id.is_empty() \
		and not save_id.contains("/") \
		and not save_id.contains("\\") \
		and save_id != "." \
		and save_id != ".."


static func _ensure_dir(path: String) -> bool:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		return true
	return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path)) == OK


# 再帰削除。Godot の user:// パスで DirAccess を開き、remove_absolute だけ globalize して使う。
# 呼び出し元は save_dir_for_id() 由来のパスだけを渡す前提。
static func _remove_dir_recursive(path: String) -> bool:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var child: String = _join(path, name)
		if dir.current_is_dir():
			_remove_dir_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		name = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


static func _join(base: String, child: String) -> String:
	if base.ends_with("/"):
		return base + child
	return "%s/%s" % [base, child]
