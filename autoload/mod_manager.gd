extends Node

const DEFAULT_RULES_PATH: String = "res://data/rules/default_rules.json"
const MOD_ROOT: String = "user://mods"
const MOD_STATE_PATH: String = "user://pennant_strategy_mods.json"

var _default_rules: Dictionary = {}
var _rules: Dictionary = {}
var _rule_cache: Dictionary = {}
var _data_overrides: Dictionary = {}
var _active_mods: Array = []
var last_compatibility_warnings: Array[String] = []


func _ready() -> void:
	reload_mods()


func reload_mods() -> void:
	_default_rules = _read_json_dict(DEFAULT_RULES_PATH)
	_rules = _default_rules.duplicate(true)
	_rule_cache.clear()
	_data_overrides.clear()
	_active_mods.clear()
	last_compatibility_warnings.clear()

	var manifests: Dictionary = _discover_mod_manifests()
	var load_order: Array = _configured_load_order(manifests)
	for mod_id_value in load_order:
		var mod_id: String = str(mod_id_value)
		if not manifests.has(mod_id):
			continue
		_apply_manifest(manifests[mod_id] as Dictionary)


func resolve_data_path(key: String, fallback_path: String) -> String:
	return str(_data_overrides.get(key, fallback_path))


func rule_value(path: String, fallback: Variant = null) -> Variant:
	if path.is_empty():
		return _rules
	if _rule_cache.has(path):
		return _rule_cache[path]
	var current: Variant = _rules
	for part_value in path.split("."):
		var part: String = str(part_value)
		if not (current is Dictionary):
			return fallback
		var current_dict: Dictionary = current as Dictionary
		if not current_dict.has(part):
			return fallback
		current = current_dict[part]
	_rule_cache[path] = current
	return current


func rule_float(path: String, fallback: float) -> float:
	var value: Variant = rule_value(path, fallback)
	return float(value) if _is_number_like(value) else fallback


func rule_int(path: String, fallback: int) -> int:
	var value: Variant = rule_value(path, fallback)
	return int(value) if _is_number_like(value) else fallback


func rule_bool(path: String, fallback: bool) -> bool:
	var value: Variant = rule_value(path, fallback)
	if value is bool:
		return bool(value)
	if value is String:
		var text: String = str(value).strip_edges().to_lower()
		if text == "true" or text == "1" or text == "yes" or text == "on":
			return true
		if text == "false" or text == "0" or text == "no" or text == "off":
			return false
	return fallback


func rule_array(path: String, fallback: Array = []) -> Array:
	var value: Variant = rule_value(path, fallback)
	if value is Array:
		return (value as Array).duplicate(true)
	return fallback.duplicate(true)


func rule_dict(path: String, fallback: Dictionary = {}) -> Dictionary:
	var value: Variant = rule_value(path, fallback)
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return fallback.duplicate(true)


func active_mods_snapshot() -> Array:
	return _active_mods.duplicate(true)


func rules_profile_id() -> String:
	return str(_rules.get("id", "pennant_strategy_default"))


func rules_schema_version() -> int:
	return int(_rules.get("schema_version", 1))


func data_schema_version() -> int:
	return int(_rules.get("data_schema_version", 1))


func save_metadata() -> Dictionary:
	return {
		"active_mods": active_mods_snapshot(),
		"rules_profile_id": rules_profile_id(),
		"rules_schema_version": rules_schema_version(),
		"data_schema_version": data_schema_version(),
	}


func check_save_compatibility(saved_mods: Array) -> Array[String]:
	var warnings: Array[String] = []
	var current_by_id: Dictionary = {}
	for active_value in _active_mods:
		var active_mod: Dictionary = active_value as Dictionary
		current_by_id[str(active_mod.get("id", ""))] = active_mod

	for saved_value in saved_mods:
		if not (saved_value is Dictionary):
			continue
		var saved_mod: Dictionary = saved_value as Dictionary
		var mod_id: String = str(saved_mod.get("id", ""))
		if mod_id.is_empty():
			continue
		if not current_by_id.has(mod_id):
			warnings.append("Save expects mod '%s', but it is not active." % mod_id)
			continue
		var current_mod: Dictionary = current_by_id[mod_id] as Dictionary
		var saved_version: String = str(saved_mod.get("version", ""))
		var current_version: String = str(current_mod.get("version", ""))
		if not saved_version.is_empty() and not current_version.is_empty() and saved_version != current_version:
			warnings.append("Save expects mod '%s' version %s, active version is %s." % [mod_id, saved_version, current_version])
	last_compatibility_warnings = warnings
	return warnings


func _discover_mod_manifests() -> Dictionary:
	var manifests: Dictionary = {}
	var dir: DirAccess = DirAccess.open(MOD_ROOT)
	if dir == null:
		return manifests
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var manifest_path: String = "%s/%s/mod.json" % [MOD_ROOT, entry]
			var manifest: Dictionary = _read_json_dict(manifest_path)
			if not manifest.is_empty():
				var mod_id: String = str(manifest.get("id", entry))
				if not mod_id.is_empty():
					manifest["id"] = mod_id
					manifest["_base_dir"] = "%s/%s" % [MOD_ROOT, entry]
					manifests[mod_id] = manifest
		entry = dir.get_next()
	dir.list_dir_end()
	return manifests


func _configured_load_order(manifests: Dictionary) -> Array:
	var state: Dictionary = _read_json_dict(MOD_STATE_PATH)
	var configured: Array = []
	if state.has("load_order") and state["load_order"] is Array:
		configured = state["load_order"] as Array
	elif state.has("enabled_mods") and state["enabled_mods"] is Array:
		configured = state["enabled_mods"] as Array
	if not configured.is_empty():
		return configured

	var mod_ids: Array = []
	for mod_id in manifests.keys():
		var manifest: Dictionary = manifests[mod_id] as Dictionary
		if bool(manifest.get("enabled", false)):
			mod_ids.append(str(mod_id))
	mod_ids.sort()
	return mod_ids


func _apply_manifest(manifest: Dictionary) -> void:
	var base_dir: String = str(manifest.get("_base_dir", MOD_ROOT))
	var mod_id: String = str(manifest.get("id", ""))
	if mod_id.is_empty():
		return

	if manifest.has("data") and manifest["data"] is Dictionary:
		var data_map: Dictionary = manifest["data"] as Dictionary
		for key_value in data_map.keys():
			var key: String = str(key_value)
			var path: String = str(data_map[key_value])
			if not key.is_empty() and not path.is_empty():
				_data_overrides[key] = _resolve_mod_path(base_dir, path)

	if manifest.has("rules"):
		var rules_patch: Dictionary = {}
		var rules_value: Variant = manifest["rules"]
		if rules_value is Dictionary:
			rules_patch = (rules_value as Dictionary).duplicate(true)
		elif rules_value is String:
			rules_patch = _read_json_dict(_resolve_mod_path(base_dir, str(rules_value)))
		if not rules_patch.is_empty():
			_rules = _merge_dicts(_rules, rules_patch)

	_active_mods.append({
		"id": mod_id,
		"name": str(manifest.get("name", mod_id)),
		"version": str(manifest.get("version", "")),
	})


func _resolve_mod_path(base_dir: String, path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	return "%s/%s" % [base_dir.trim_suffix("/"), path.trim_prefix("./")]


func _read_json_dict(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Could not open JSON file: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed as Dictionary
	push_warning("JSON file must contain an object: %s" % path)
	return {}


func _merge_dicts(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	for key in overlay.keys():
		var overlay_value: Variant = overlay[key]
		if out.has(key) and out[key] is Dictionary and overlay_value is Dictionary:
			out[key] = _merge_dicts(out[key] as Dictionary, overlay_value as Dictionary)
		else:
			out[key] = overlay_value
	return out


func _is_number_like(value: Variant) -> bool:
	if value is int or value is float:
		return true
	if value is String:
		return str(value).is_valid_float()
	return false
