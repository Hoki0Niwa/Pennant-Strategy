extends RefCounted
class_name PSTeamSeasonRecord

# 1チーム×1シーズンのチーム記録。
# PSTeam の静的情報をスナップショットし、PSStats に試合結果を累積する。
var team_id: int
var year: int
var season_number: int
var name: String
var league: String
var stats: PSStats = PSStats.new()
# 二軍 (ファーム) の勝敗。一軍とは別インスタンスで持ち、順位表・優勝判定も別系統。
# `season.farm_standings` が当季の正で、こちらはアーカイブ (年度履歴) へ乗せるための控え
# — 一軍が `season.standings` と `stats` の両方を更新するのと同じ二重書き。
# ファーム専用球団 (id 13/14) の team record も RecordStore に作られる。
var farm_stats: PSStats = PSStats.new()


# 新シーズン開始時に PSTeam から空の年度記録を作る。
static func from_team(team: PSTeam, p_year: int, p_season_number: int) -> PSTeamSeasonRecord:
	var record: PSTeamSeasonRecord = PSTeamSeasonRecord.new()
	record.team_id = team.id
	record.year = p_year
	record.season_number = p_season_number
	record.name = team.name
	record.league = team.league
	return record


static func from_dict(data: Dictionary) -> PSTeamSeasonRecord:
	var record: PSTeamSeasonRecord = PSTeamSeasonRecord.new()
	record.team_id = int(data.get("team_id", 0))
	record.year = int(data.get("year", 0))
	record.season_number = int(data.get("season_number", 0))
	record.name = str(data.get("name", ""))
	record.league = str(data.get("league", ""))
	record.stats = PSStats.from_dict(data.get("stats", {}) as Dictionary)
	record.farm_stats = PSStats.from_dict(data.get("farm_stats", {}) as Dictionary)
	return record


func to_dict() -> Dictionary:
	return {
		"team_id": team_id,
		"year": year,
		"season_number": season_number,
		"name": name,
		"league": league,
		"stats": stats.to_dict(),
		"farm_stats": farm_stats.to_dict(),
	}
