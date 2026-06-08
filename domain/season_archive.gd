extends RefCounted
class_name PSSeasonArchive

var year: int
var season_number: int
var standings: Dictionary = {}  # team_id → {wins, losses, draws, runs_scored, runs_allowed}
var postseason: PSPostseasonResult
var awards: PSAwards


func to_dict() -> Dictionary:
	return {
		"year": year,
		"season_number": season_number,
		"standings": standings,
		"postseason": postseason.to_dict() if postseason != null else {},
		"awards": awards.to_dict() if awards != null else {},
	}


static func from_dict(data: Dictionary) -> PSSeasonArchive:
	var archive: PSSeasonArchive = PSSeasonArchive.new()
	archive.year = int(data.get("year", 0))
	archive.season_number = int(data.get("season_number", 1))
	archive.standings = (data.get("standings", {}) as Dictionary).duplicate(true)
	var post_data: Dictionary = data.get("postseason", {}) as Dictionary
	archive.postseason = PSPostseasonResult.from_dict(post_data) if not post_data.is_empty() else null
	var awards_data: Dictionary = data.get("awards", {}) as Dictionary
	archive.awards = PSAwards.from_dict(awards_data) if not awards_data.is_empty() else null
	return archive
