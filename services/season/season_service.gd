extends RefCounted
class_name SeasonService

const SeasonCalendar = preload("res://services/season/season_calendar.gd")

# PSSeason を新規作成するファクトリ。
# AppState はここで年度、開幕日、schedule template 情報、チーム年度記録、ペナント日程をまとめて初期化する。
const DEFAULT_START_YEAR = 2026


# 完全新規ゲームの初年度を作る。
static func create_new_season(teams: Array, selected_team_id: int, year: int = DEFAULT_START_YEAR, dh_by_league: Dictionary = {}) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = year
	season.season_number = 1
	season.selected_team_id = selected_team_id
	season.current_day = 1
	season.calendar_start_date = SeasonCalendar.opening_date_for_year(year)
	season.schedule_template_id = PSSchedule.TEMPLATE_ID
	season.schedule_bucket_seed = PSSchedule.bucket_seed_for_season(year, season.season_number)

	var team_ids: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		team_ids.append(team.id)
	season.setup(team_ids)

	season.schedule = PSSchedule.generate_pennant_schedule(teams, PSSchedule.PENNANT_GAMES_PER_TEAM, dh_by_league, season.year, season.season_number)
	return season


# 前年の操作チームと season_number を引き継いで翌年シーズンを作る。
# ロスター/能力は GameDb 側の現在状態を使い、日程は新年度の開幕日と bucket seed で再生成する。
static func create_next_season(previous_season: PSSeason, teams: Array, dh_by_league: Dictionary = {}) -> PSSeason:
	var season: PSSeason = PSSeason.new()
	season.year = previous_season.year + 1
	season.season_number = previous_season.season_number + 1
	season.selected_team_id = previous_season.selected_team_id
	season.current_day = 1
	season.calendar_start_date = SeasonCalendar.opening_date_for_year(season.year)
	season.schedule_template_id = PSSchedule.TEMPLATE_ID
	season.schedule_bucket_seed = PSSchedule.bucket_seed_for_season(season.year, season.season_number)

	var team_ids: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		team_ids.append(team.id)
	season.setup(team_ids)

	season.schedule = PSSchedule.generate_pennant_schedule(teams, PSSchedule.PENNANT_GAMES_PER_TEAM, dh_by_league, season.year, season.season_number)
	return season
