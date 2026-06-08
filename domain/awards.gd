extends RefCounted
class_name PSAwards

const BATTING_CATEGORIES: Array = ["average", "home_runs", "rbi", "stolen_bases", "hits"]
const PITCHING_CATEGORIES: Array = ["wins", "era", "strikeouts", "saves", "holds", "win_rate"]

var year: int
var season_number: int
var mvp_central_player_id: int = 0
var mvp_pacific_player_id: int = 0
var rookie_central_player_id: int = 0
var rookie_pacific_player_id: int = 0
# league key ("central" / "pacific") → category key → player_id
var batting_titles: Dictionary = {}
var pitching_titles: Dictionary = {}


func to_dict() -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		"mvp_central_player_id": mvp_central_player_id,
		"mvp_pacific_player_id": mvp_pacific_player_id,
		"rookie_central_player_id": rookie_central_player_id,
		"rookie_pacific_player_id": rookie_pacific_player_id,
		"batting_titles": batting_titles,
		"pitching_titles": pitching_titles,
	}


static func from_dict(data: Dictionary) -> PSAwards:
	var awards: PSAwards = PSAwards.new()
	awards.year = int(data.get("year", 0))
	awards.season_number = int(data.get("season_number", 1))
	awards.mvp_central_player_id = int(data.get("mvp_central_player_id", 0))
	awards.mvp_pacific_player_id = int(data.get("mvp_pacific_player_id", 0))
	awards.rookie_central_player_id = int(data.get("rookie_central_player_id", 0))
	awards.rookie_pacific_player_id = int(data.get("rookie_pacific_player_id", 0))
	awards.batting_titles = (data.get("batting_titles", {}) as Dictionary).duplicate(true)
	awards.pitching_titles = (data.get("pitching_titles", {}) as Dictionary).duplicate(true)
	return awards
