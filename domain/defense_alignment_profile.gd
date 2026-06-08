extends Resource
class_name PSDefenseAlignmentProfile

# Phase 4: チーム別の守備配置テンプレート。
# 12 球団分 .tres は commit せず lazy default (starting_positions 空 → 初回 fallback)。
# Phase 3 PSBattingOrderProfile と同形パターン。DH の概念は守備に無関係なので team_id のみキャッシュキー。

const RESOURCE_DIR: String = "res://data/teams/"

@export var team_id: int = 0
@export var profile_name: String = "default"
# { position(int 2-9): player_id(int) }、空なら初回起動時に greedy で算出
@export var starting_positions: Dictionary = {}
# { position(int 2-9): Array[int] backup_player_ids (優先度順) }
@export var backup_priority: Dictionary = {}
# { position(int 2-9): {"starter_id": int, "sub_id": int, "sub_start_interval": int} }
@export var position_slots: Dictionary = {}

static var _cache: Dictionary = {}


static func load_for_team(team_id: int) -> PSDefenseAlignmentProfile:
	var key: String = str(team_id)
	if _cache.has(key):
		return _cache[key] as PSDefenseAlignmentProfile

	var path: String = _path_for(team_id)
	var profile: PSDefenseAlignmentProfile = null
	if ResourceLoader.exists(path):
		var loaded: Resource = load(path)
		if loaded is PSDefenseAlignmentProfile:
			profile = loaded as PSDefenseAlignmentProfile
	if profile == null:
		profile = build_default(team_id)
	_cache[key] = profile
	return profile


static func build_default(team_id: int) -> PSDefenseAlignmentProfile:
	var profile: PSDefenseAlignmentProfile = PSDefenseAlignmentProfile.new()
	profile.team_id = team_id
	profile.profile_name = "default"
	return profile


static func reset_cache() -> void:
	_cache.clear()


static func _path_for(team_id: int) -> String:
	return "%s%d/defense_alignment.tres" % [RESOURCE_DIR, team_id]
