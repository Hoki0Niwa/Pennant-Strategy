extends RefCounted
class_name PSLineupHistory

# 「スタメン履歴」機能のクエリ API。書き込み (season.append_team_lineup /
# SQLiteStoreService.save_team_lineup_history) は GameSimulator / SaveService 側の責務で、
# ここは読み取り専用の集計・整形だけを行う。

const SQLiteStoreService = preload("res://services/storage/sqlite_store.gd")

# 守備位置コード (team_lineup_history の slot.pos / row.starter_pitcher_id と対応)。
const POSITION_PITCHER: int = 1
const POSITION_DH: int = 10


# 選択可能な年度 (当季を含む、新しい順)。[{"year": int, "season_number": int}]
static func available_seasons() -> Array:
	var combined: Dictionary = {}  # "year:season_number" -> {"year", "season_number"}
	var season: PSSeason = AppState.current_season
	if season != null:
		combined[_season_key(season.year, season.season_number)] = {"year": season.year, "season_number": season.season_number}
	if SQLiteStoreService.is_available():
		for row_value in SQLiteStoreService.list_lineup_history_seasons():
			var row: Dictionary = row_value as Dictionary
			var year: int = int(row.get("year", 0))
			var season_number: int = int(row.get("season_number", 0))
			combined[_season_key(year, season_number)] = {"year": year, "season_number": season_number}

	var out: Array = combined.values()
	out.sort_custom(_season_desc)
	return out


# 指定年度・球団の全試合のスタメン行 (day/game_index 昇順)。
# 当季なら AppState.current_season.team_lineup_history から、過去年度は SQLite から読む。
# team_id == 0 で全球団。
static func team_lineups(year: int, season_number: int, team_id: int = 0) -> Array:
	var season: PSSeason = AppState.current_season
	if season != null and season.year == year and season.season_number == season_number:
		var out: Array = []
		for row_value in season.team_lineup_history:
			var row: Dictionary = row_value as Dictionary
			if team_id != 0 and int(row.get("team_id", 0)) != team_id:
				continue
			out.append((row as Dictionary).duplicate(true))
		return out
	return SQLiteStoreService.load_team_lineup_history(year, season_number, team_id)


# 守備位置別のスタメン数ランキング。{pos:int -> [{"player_id": int, "starts": int}]}
# pos は 1=投, 2..9=守備位置, 10=DH。starts 降順、同数は player_id 昇順。
# 投手 (pos 1) は starter_pitcher_id から集計する。非DH で打順に pos==1 の枠がある場合は
# starter_pitcher_id 側と同一試合の同一選手なので、そちらは数えず二重計上を避ける。
static func starts_by_position(rows: Array) -> Dictionary:
	var counts: Dictionary = {}  # pos:int -> {player_id:int -> starts:int}
	for row_value in rows:
		var row: Dictionary = row_value as Dictionary
		var starter_pitcher_id: int = int(row.get("starter_pitcher_id", 0))
		if starter_pitcher_id > 0:
			_bump(counts, POSITION_PITCHER, starter_pitcher_id)
		for slot_value in (row.get("slots", []) as Array):
			var slot: Dictionary = slot_value as Dictionary
			var pos: int = int(slot.get("pos", 0))
			if pos == POSITION_PITCHER:
				continue
			var player_id: int = int(slot.get("pid", 0))
			if player_id <= 0:
				continue
			_bump(counts, pos, player_id)
	return _finalize_counts(counts)


# 単一選手の起用集計。トレードを跨ぐので全球団を走査する。
# {"by_position": {pos:int -> starts:int}, "by_order": {slot:int -> starts:int}, "total_starts": int}
static func player_summary(player_id: int, year: int, season_number: int) -> Dictionary:
	var by_position: Dictionary = {}
	var by_order: Dictionary = {}
	var total_starts: int = 0
	if player_id <= 0:
		return {"by_position": by_position, "by_order": by_order, "total_starts": total_starts}

	for row_value in team_lineups(year, season_number, 0):
		var row: Dictionary = row_value as Dictionary
		var appeared: bool = false
		if int(row.get("starter_pitcher_id", 0)) == player_id:
			by_position[POSITION_PITCHER] = int(by_position.get(POSITION_PITCHER, 0)) + 1
			appeared = true
		for slot_value in (row.get("slots", []) as Array):
			var slot: Dictionary = slot_value as Dictionary
			if int(slot.get("pid", 0)) != player_id:
				continue
			var slot_num: int = int(slot.get("slot", 0))
			if slot_num > 0:
				by_order[slot_num] = int(by_order.get(slot_num, 0)) + 1
			var pos: int = int(slot.get("pos", 0))
			# 非DHの投手打順枠 (pos==1) は starter_pitcher_id 側で既に計上済み。
			if pos != POSITION_PITCHER:
				by_position[pos] = int(by_position.get(pos, 0)) + 1
			appeared = true
		if appeared:
			total_starts += 1

	return {"by_position": by_position, "by_order": by_order, "total_starts": total_starts}


static func _bump(counts: Dictionary, key: int, player_id: int) -> void:
	var bucket: Dictionary = counts.get(key, {}) as Dictionary
	bucket[player_id] = int(bucket.get(player_id, 0)) + 1
	counts[key] = bucket


static func _finalize_counts(counts: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key_value in counts.keys():
		var key: int = int(key_value)
		var bucket: Dictionary = counts[key_value] as Dictionary
		var list: Array = []
		for player_id_value in bucket.keys():
			list.append({"player_id": int(player_id_value), "starts": int(bucket[player_id_value])})
		list.sort_custom(_starts_desc_then_player_id_asc)
		out[key] = list
	return out


static func _starts_desc_then_player_id_asc(a: Dictionary, b: Dictionary) -> bool:
	var starts_a: int = int(a.get("starts", 0))
	var starts_b: int = int(b.get("starts", 0))
	if starts_a != starts_b:
		return starts_a > starts_b
	return int(a.get("player_id", 0)) < int(b.get("player_id", 0))


static func _season_key(year: int, season_number: int) -> String:
	return "%d:%d" % [year, season_number]


static func _season_desc(a: Dictionary, b: Dictionary) -> bool:
	var year_a: int = int(a.get("year", 0))
	var year_b: int = int(b.get("year", 0))
	if year_a != year_b:
		return year_a > year_b
	return int(a.get("season_number", 0)) > int(b.get("season_number", 0))
