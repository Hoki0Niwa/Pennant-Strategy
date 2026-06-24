extends RefCounted
class_name PSPostseasonResult

const STAGE_KEYS: Array = ["cs1_central", "cs1_pacific", "cs2_central", "cs2_pacific", "japan_series"]

# 同時並行で進むステージのまとまり (1日に各グループ内の全シリーズを1試合ずつ消化する)。
# CS ファースト (第1/第2リーグ) → CS ファイナル (第1/第2リーグ) → 日本シリーズ の順。
const STAGE_GROUPS: Array = [
	["cs1_central", "cs1_pacific"],
	["cs2_central", "cs2_pacific"],
	["japan_series"],
]

# セーブ時に各試合 result から残す軽量サマリ列 (詳細な play-by-play はログファイル側へ退避し、
# セーブ blob を肥大化させない。PSSeason._schedule_for_save と同じ方針)。
const SLIM_RESULT_KEYS: Array = [
	"winning_team_id", "draw",
	"winning_pitcher_id", "losing_pitcher_id", "save_pitcher_id", "hold_pitcher_ids",
	"away_pitcher_id", "home_pitcher_id",
]

var year: int
var season_number: int
var cs1_central: Dictionary = {}
var cs1_pacific: Dictionary = {}
var cs2_central: Dictionary = {}
var cs2_pacific: Dictionary = {}
var japan_series: Dictionary = {}
var champion_team_id: int = 0
# 日単位消化のカウンタ。1日進めるごとに +1 し、その日に消化した試合へ付与する。
var current_day: int = 0


static func make_pending_series(top_id: int, challenger_id: int, win_target: int, advantage_wins: int) -> Dictionary:
	return {
		"top_id": top_id,
		"challenger_id": challenger_id,
		"win_target": win_target,
		"advantage_wins": advantage_wins,
		"games": [],
		"top_wins": advantage_wins,
		"challenger_wins": 0,
		"winner_id": 0,
		"completed": false,
	}


func stage_dict(stage_key: String) -> Dictionary:
	match stage_key:
		"cs1_central": return cs1_central
		"cs1_pacific": return cs1_pacific
		"cs2_central": return cs2_central
		"cs2_pacific": return cs2_pacific
		"japan_series": return japan_series
		_: return {}


func set_stage(stage_key: String, dict: Dictionary) -> void:
	match stage_key:
		"cs1_central": cs1_central = dict
		"cs1_pacific": cs1_pacific = dict
		"cs2_central": cs2_central = dict
		"cs2_pacific": cs2_pacific = dict
		"japan_series": japan_series = dict


func next_pending_stage() -> String:
	for key in STAGE_KEYS:
		var s: Dictionary = stage_dict(key)
		if s.is_empty():
			continue
		if not bool(s.get("completed", false)):
			return key
	return ""


func is_complete() -> bool:
	return bool(japan_series.get("completed", false)) and int(japan_series.get("winner_id", 0)) > 0


func to_dict() -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		"cs1_central": _slim_series(cs1_central),
		"cs1_pacific": _slim_series(cs1_pacific),
		"cs2_central": _slim_series(cs2_central),
		"cs2_pacific": _slim_series(cs2_pacific),
		"japan_series": _slim_series(japan_series),
		"champion_team_id": champion_team_id,
		"current_day": current_day,
	}


# シリーズ辞書をセーブ用に複製し、各試合の重い result を軽量サマリへ差し替える。
# メモリ上のシリーズはそのまま (セッション中の詳細表示には影響しない)。
func _slim_series(series: Dictionary) -> Dictionary:
	if series.is_empty():
		return {}
	var out: Dictionary = series.duplicate()
	var games_out: Array = []
	for game_row in (series.get("games", []) as Array):
		var slim_game: Dictionary = (game_row as Dictionary).duplicate()
		if slim_game.has("result"):
			var full: Dictionary = slim_game.get("result", {}) as Dictionary
			var slim_result: Dictionary = {}
			for key in SLIM_RESULT_KEYS:
				if full.has(key):
					slim_result[key] = full[key]
			slim_game["result"] = slim_result
		games_out.append(slim_game)
	out["games"] = games_out
	return out


static func from_dict(data: Dictionary) -> PSPostseasonResult:
	var result: PSPostseasonResult = PSPostseasonResult.new()
	result.year = int(data.get("year", 0))
	result.season_number = int(data.get("season_number", 1))
	result.cs1_central = (data.get("cs1_central", {}) as Dictionary).duplicate(true)
	result.cs1_pacific = (data.get("cs1_pacific", {}) as Dictionary).duplicate(true)
	result.cs2_central = (data.get("cs2_central", {}) as Dictionary).duplicate(true)
	result.cs2_pacific = (data.get("cs2_pacific", {}) as Dictionary).duplicate(true)
	result.japan_series = (data.get("japan_series", {}) as Dictionary).duplicate(true)
	result.champion_team_id = int(data.get("champion_team_id", 0))
	result.current_day = int(data.get("current_day", 0))
	return result
