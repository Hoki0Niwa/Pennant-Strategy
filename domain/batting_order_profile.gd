extends Resource
class_name PSBattingOrderProfile

# チーム別の基本打順テンプレ + グループ定義 + 固定制約。
# 12 球団分 .tres は commit せず lazy default (base_order_player_ids 空 → 初回 fallback)。
# SimulationTuning と同じ load + キャッシュパターン。

const RESOURCE_DIR: String = "res://data/teams/"

@export var team_id: int = 0
@export var profile_name: String = "default"
# index 0 = 1番、index 8 = 9番。空なら BattingOrderService 側で従来 sort を base として使う。
@export var base_order_player_ids: Array[int] = []
@export var dh_enabled: bool = true
@export var top_group: Array[int] = [1, 2]
@export var middle_group: Array[int] = [3, 4, 5]
@export var lower_group: Array[int] = [6, 7, 8, 9]
@export var keep_cleanup_fixed: bool = false
@export var keep_catcher_lower: bool = true
@export var allow_random_bonus: bool = true
@export var random_bonus_range: int = 3
# キーは str(player_id)。Godot Resource で Dictionary key 型強制が弱いため呼出側でも正規化する。
@export var fixed_slot_by_player: Dictionary = {}
@export var allowed_slots_by_player: Dictionary = {}

static var _cache: Dictionary = {}


static func load_for_team(p_team_id: int, dh: bool) -> PSBattingOrderProfile:
	var key: String = _cache_key(p_team_id, dh)
	if _cache.has(key):
		return _cache[key] as PSBattingOrderProfile

	var path: String = _path_for(p_team_id, dh)
	var profile: PSBattingOrderProfile = null
	if ResourceLoader.exists(path):
		var loaded: Resource = load(path)
		if loaded is PSBattingOrderProfile:
			profile = loaded as PSBattingOrderProfile
	if profile == null:
		profile = build_default(p_team_id, dh)
	_cache[key] = profile
	return profile


static func build_default(p_team_id: int, dh: bool) -> PSBattingOrderProfile:
	var profile: PSBattingOrderProfile = PSBattingOrderProfile.new()
	profile.team_id = p_team_id
	profile.dh_enabled = dh
	profile.profile_name = "default_%s" % ("dh" if dh else "nodh")
	return profile


static func reset_cache() -> void:
	_cache.clear()


static func _cache_key(p_team_id: int, dh: bool) -> String:
	return "%d_%d" % [p_team_id, 1 if dh else 0]


static func _path_for(p_team_id: int, dh: bool) -> String:
	var suffix: String = "dh" if dh else "nodh"
	return "%s%d/batting_order_profile_%s.tres" % [RESOURCE_DIR, p_team_id, suffix]
