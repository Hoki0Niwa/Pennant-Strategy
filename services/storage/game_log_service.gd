extends RefCounted
class_name PSGameLogService

const SaveContext = preload("res://services/storage/save_context.gd")

# 試合の詳細ログ(打席ごと play-by-play + 交代)を、セーブ本体とは別の
# 年(シーズン)別ファイルへ書き出す。セーブ JSON を肥大化させずに全試合の詳細を保持し、
# 試合結果画面が必要時に遅延読込する。1 試合 1 ファイルなので長期オートプレイでも O(1) 書き込み。
#   <save_folder>/game_logs/<year>_s<season>/g<game_index>.json

# テスト/オートプレイで書き込みを抑止したい場合に false にする。
static var enabled: bool = true


static func log_root() -> String:
	return SaveContext.game_log_root()


static func _season_dir(season: PSSeason) -> String:
	return "%s/%d_s%d" % [log_root(), season.year, season.season_number]


static func _game_path(season: PSSeason, game_index: int) -> String:
	return "%s/g%d.json" % [_season_dir(season), game_index]


# result(メモリ上の完全結果)から永続化用の compact なログ Dictionary を作る。
static func build_game_log(result: Dictionary, season: PSSeason = null) -> Dictionary:
	return {
		"meta": {
			"away_team_id": int(result.get("away_team_id", 0)),
			"home_team_id": int(result.get("home_team_id", 0)),
			"away_score": int(result.get("away_score", 0)),
			"home_score": int(result.get("home_score", 0)),
		},
		"lineups": (result.get("lineups", {}) as Dictionary).duplicate(true),
		"decisions": {
			"winning_pitcher_id": int(result.get("winning_pitcher_id", 0)),
			"losing_pitcher_id": int(result.get("losing_pitcher_id", 0)),
			"save_pitcher_id": int(result.get("save_pitcher_id", 0)),
			"hold_pitcher_ids": (result.get("hold_pitcher_ids", []) as Array).duplicate(true),
		},
		"pitcher_outings": (result.get("pitcher_outings", []) as Array).duplicate(true),
		"errors": build_error_log(result),
		"pa_log": build_pa_log(result, season),
		"substitutions": (result.get("substitutions", []) as Array).duplicate(true),
	}


# 打球失策(plate_event.category=="error")を {inning,half,fielding_team_id,fielder_id,position} で収集。
# 走者イベント失策(捕手の盗塁送球ミス等)は v1 では対象外。
static func build_error_log(result: Dictionary) -> Array:
	var errors: Array = []
	for event_row in (result.get("play_events", []) as Array):
		var event: Dictionary = event_row as Dictionary
		var plate: Dictionary = event.get("plate_event", {}) as Dictionary
		if str(plate.get("category", "")) != "error":
			continue
		var batted: Dictionary = event.get("batted_ball_event", {}) as Dictionary
		var fielder_id: int = int(batted.get("fielder_id", 0))
		var position: int = int(batted.get("fielder_position", 0))
		if fielder_id <= 0:
			for fe_row in (event.get("fielding_events", []) as Array):
				var fe: Dictionary = fe_row as Dictionary
				if int(fe.get("fielder_id", 0)) > 0:
					fielder_id = int(fe.get("fielder_id", 0))
					position = int(fe.get("position", position))
					break
		errors.append({
			"inning": int(event.get("inning", 0)),
			"half": str(event.get("half", "")),
			"fielding_team_id": int(event.get("fielding_team_id", 0)),
			"fielder_id": fielder_id,
			"position": position,
		})
	return errors


# play_events から打席行のみを抜き出した compact 配列。runner-only イベント(plate_event 空)は除外。
static func build_pa_log(result: Dictionary, season: PSSeason = null) -> Array:
	var pa_log: Array = []
	for event_row in (result.get("play_events", []) as Array):
		var event: Dictionary = event_row as Dictionary
		var plate: Dictionary = event.get("plate_event", {}) as Dictionary
		if plate.is_empty():
			continue
		var pitch_summary: Dictionary = event.get("pitch_summary", {}) as Dictionary
		var batted: Dictionary = event.get("batted_ball_event", {}) as Dictionary
		pa_log.append({
			"inning": int(event.get("inning", 0)),
			"half": str(event.get("half", "")),
			"batting_team_id": int(event.get("batting_team_id", 0)),
			"batter_id": int(plate.get("batter_id", 0)),
			"pitcher_id": int(plate.get("pitcher_id", 0)),
			"category": str(plate.get("category", "out")),
			"result": str(plate.get("result", "out")),
			"bases": int(plate.get("bases", 0)),
			"rbi": int(plate.get("rbi", 0)),  # 正確な打点(reducer の runs_batted_in 差分由来)
			"outs_before": int(event.get("outs_before", 0)),
			"count": str(pitch_summary.get("final_count", "")),
			"fielder_position": int(batted.get("fielder_position", 0)),
			"batted_ball_type": str(batted.get("batted_ball_type", "")),
			"ab_charged": bool(plate.get("ab_charged", false)),
			"hr_number": 0,
		})
	_assign_hr_numbers(pa_log, season)
	return pa_log


# HR 行に「号数」(その本塁打時点での通算本塁打数)を付与。season の record(=この試合後の通算)から
# pre = 通算HR - 当試合HR を求め、当試合 HR を出現順に pre+1, pre+2... と振る。
# 完了時(finalize)/今セッション表示では record が試合後通算なので正確。ロード後はファイルの値を使う。
static func _assign_hr_numbers(pa_log: Array, season: PSSeason) -> void:
	if season == null:
		return
	var game_hr_total: Dictionary = {}
	for row_value in pa_log:
		var pa: Dictionary = row_value as Dictionary
		if str(pa.get("category", "")) == "hit" and int(pa.get("bases", 0)) >= 4:
			var bid: int = int(pa.get("batter_id", 0))
			game_hr_total[bid] = int(game_hr_total.get(bid, 0)) + 1
	var seen: Dictionary = {}
	for row_value in pa_log:
		var pa: Dictionary = row_value as Dictionary
		if str(pa.get("category", "")) != "hit" or int(pa.get("bases", 0)) < 4:
			continue
		var bid: int = int(pa.get("batter_id", 0))
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(bid, season.year, season.season_number)
		var pre: int = 0
		if record != null:
			pre = record.batter_stats.home_runs - int(game_hr_total.get(bid, 0))
		var idx: int = int(seen.get(bid, 0)) + 1
		seen[bid] = idx
		pa["hr_number"] = maxi(idx, pre + idx)


static func write_game_log(season: PSSeason, game_index: int, result: Dictionary) -> void:
	if not enabled or season == null:
		return
	if log_root().is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_season_dir(season))
	var file: FileAccess = FileAccess.open(_game_path(season, game_index), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(build_game_log(result, season)))
	file.close()


# 画面の遅延読込用。無ければ空 Dictionary。
static func read_game_log(season: PSSeason, game_index: int) -> Dictionary:
	if season == null:
		return {}
	if log_root().is_empty():
		return {}
	var path: String = _game_path(season, game_index)
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}
