extends RefCounted
class_name PSSeasonReviewService

const BATTER_COUNTS: Array = ["games", "plate_appearances", "at_bats", "hits", "doubles", "triples", "home_runs", "runs_batted_in", "runs", "walks", "hit_by_pitches", "strikeouts", "pitches_seen", "stolen_base_attempts", "stolen_bases", "sacrifices", "sacrifice_flies", "double_plays", "errors"]
const PITCHER_COUNTS: Array = ["games", "starts", "relief_appearances", "wins", "losses", "holds", "saves", "outs_pitched", "batters_faced", "pitches_thrown", "hits_allowed", "home_runs_allowed", "walks", "hit_batters", "strikeouts", "runs_allowed", "earned_runs", "complete_games", "shutouts", "quality_starts"]


# 年度合計と球団別の値を別々に確定し、オフ中の所属・役割更新から切り離す。
static func build(season: PSSeason, teams: Array, previous_review: PSSeasonReview = null, completion_kind: String = "regular_season", archive: PSSeasonArchive = null) -> PSSeasonReview:
	var context: Dictionary = PSWarCalculator.build_league_context(season.year, season.season_number)
	var facts: Array = []
	var team_rows: Array = []
	var ranks: Dictionary = {}
	for league_teams: Array in PostseasonService.league_standings(season, teams).values():
		for index in league_teams.size():
			ranks[(league_teams[index] as PSTeam).id] = index + 1
	var previous: Dictionary = {}
	if previous_review != null and previous_review.year == season.year - 1 and previous_review.season_number == season.season_number - 1:
		for row: Dictionary in previous_review.teams:
			previous[int(row["team_id"])] = row
	for record: PSPlayerSeasonRecord in RecordStore.get_player_records_for_season(season.year, season.season_number):
		if not _appeared(record):
			continue
		var by_team: Dictionary = {}
		for team: PSTeam in teams:
			var view: PSPlayerSeasonRecord = record.stats_view_for_teams([team.id])
			if view != null and _appeared(view):
				by_team[str(team.id)] = _counts(view, context)
		facts.append({"player_id": record.player_id, "name": record.name, "role": record.role, "team_id": record.team_id,
			"position": record.position, "age": record.age, "total": _counts(record, context), "teams": by_team})
	for team: PSTeam in teams:
		if team.farm_only:
			continue
		var stats: PSStats = season.standings.get(team.id) as PSStats
		if stats == null:
			stats = PSStats.new()
		var bat: PSBatterStats = PSBatterStats.new()
		var pit: PSPitcherStats = PSPitcherStats.new()
		var contributors: Array = []
		var war: float = 0.0
		for fact: Dictionary in facts:
			var values: Dictionary = (fact["teams"] as Dictionary).get(str(team.id), {}) as Dictionary
			if values.is_empty():
				continue
			bat.add_from(PSBatterStats.from_dict(values["batter_stats"] as Dictionary))
			pit.add_from(PSPitcherStats.from_dict(values["pitcher_stats"] as Dictionary))
			war += float(values["war"])
			contributors.append({"player_id": fact["player_id"], "name": fact["name"], "age": fact["age"], "team_id": team.id, "team_name": team.name,
				"role": fact["role"], "position": fact["position"], "stats": values.duplicate(true), "war": values["war"]})
		var pitchers: Array = _select_contributors(contributors, true)
		var fielders: Array = _select_contributors(contributors, false)
		var metrics: Dictionary = _metrics(stats.to_dict(), war)
		var delta: Dictionary = {}
		if previous.has(team.id):
			var old: Dictionary = previous[team.id] as Dictionary
			var old_standing: Dictionary = old["standings"] as Dictionary
			for key: String in ["wins", "losses", "draws", "runs_scored", "runs_allowed"]:
				delta[key] = int(stats.to_dict()[key]) - int(old_standing.get(key, 0))
			delta["war"] = war - float(old.get("war", 0.0))
			if str(old.get("league", "")) == team.league:
				delta["rank"] = int(ranks.get(team.id, 0)) - int(old.get("rank", 0))
			var old_metrics: Dictionary = _metrics(old_standing, float(old.get("war", 0.0)))
			for key: String in ["win_rate", "runs_scored_per_game", "runs_allowed_per_game"]:
				if metrics[key] != null and old_metrics[key] != null:
					delta[key] = float(metrics[key]) - float(old_metrics[key])
			delta["run_difference"] = int(delta["runs_scored"]) - int(delta["runs_allowed"])
		var row: Dictionary = {"team_id": team.id, "team_name": team.name, "league": team.league,
			"standings": stats.to_dict(), "win_rate": metrics["win_rate"], "rank": int(ranks.get(team.id, 0)),
			"run_difference": stats.runs_scored - stats.runs_allowed,
			"batter_stats": bat.to_dict(), "pitcher_stats": pit.to_dict(), "war": war,
			"previous_delta": delta, "metrics": metrics, "contributors": pitchers + fielders,
			"contributors_pitcher": pitchers, "contributors_fielder": fielders,
			"postseason": _postseason_fact(archive, team.id), "awards": _awards(archive, team, facts)}
		row["facts"] = _sentence_facts(row)
		row["comparison_fact"] = _comparison_fact(row)
		team_rows.append(row)
	return PSSeasonReview.from_dict({"year": season.year, "season_number": season.season_number,
		"completion_kind": completion_kind,
		"teams": team_rows, "player_facts": facts})


# 閲覧は保存済み事実だけを使い、文言の差し替えを表示時に反映する。
static func team_view(review: PSSeasonReview, team_id: int) -> Dictionary:
	if review == null:
		return {}
	for team: Dictionary in review.teams:
		if int(team["team_id"]) != team_id:
			continue
		var sentences: Array[String] = []
		for fact: Dictionary in team.get("facts", []):
			sentences.append(_render(fact))
		var pitchers: Array[Dictionary] = []
		var fielders: Array[Dictionary] = []
		for contributor: Dictionary in team.get("contributors_pitcher", []):
			contributor["team_name"] = team["team_name"]
			pitchers.append(PSPlayerRecordTableRow.from_history(contributor, contributor["stats"] as Dictionary))
		for contributor: Dictionary in team.get("contributors_fielder", []):
			contributor["team_name"] = team["team_name"]
			fielders.append(PSPlayerRecordTableRow.from_history(contributor, contributor["stats"] as Dictionary))
		var awards: Array = (team.get("awards", []) as Array).duplicate(true)
		for award: Dictionary in awards:
			award["label"] = Loc.t(str(award["label_key"]))
		return {"team": team, "sentences": sentences, "contributors_pitcher": pitchers,
			"contributors_fielder": fielders, "awards": awards,
			"postseason_text": _render(team.get("postseason", {}) as Dictionary),
			"comparison_text": _render(team.get("comparison_fact", {"key": "season_review.comparison.unavailable"}) as Dictionary), "metrics": team.get("metrics", {})}
	return {}


static func _render(fact: Dictionary) -> String:
	if not fact.has("key"):
		return ""
	var params: Dictionary = (fact.get("params", {}) as Dictionary).duplicate(true)
	for key: String in ["rank", "wins", "losses", "draws", "count"]:
		if params.get(key) is float or params.get(key) is int:
			params[key] = int(params[key])
	if params.get("names") is Array:
		params["names"] = Loc.t("common.list_separator").join(params["names"] as Array)
	return Loc.t(str(fact["key"]), params)


static func _metrics(standing: Dictionary, war: float) -> Dictionary:
	var games: int = int(standing.get("games", 0))
	var decisions: int = int(standing.get("wins", 0)) + int(standing.get("losses", 0))
	var metrics: Dictionary = {"games": games, "win_rate": null,
		"runs_scored_per_game": null, "runs_allowed_per_game": null,
		"run_difference": int(standing.get("runs_scored", 0)) - int(standing.get("runs_allowed", 0)), "war": war}
	if decisions > 0:
		metrics["win_rate"] = float(standing.get("wins", 0)) / float(decisions)
	if games > 0:
		metrics["runs_scored_per_game"] = float(standing.get("runs_scored", 0)) / float(games)
		metrics["runs_allowed_per_game"] = float(standing.get("runs_allowed", 0)) / float(games)
	return metrics


static func _select_contributors(contributors: Array, pitcher: bool) -> Array:
	var selected: Array = []
	for row: Dictionary in contributors:
		var is_pitcher: bool = int(row.get("position", 0)) == 1 or str(row.get("role", "")) in ["starter", "reliever", "closer"]
		if is_pitcher == pitcher:
			selected.append(row.duplicate(true))
	selected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["war"]) != float(b["war"]):
			return float(a["war"]) > float(b["war"])
		var stat_key: String = "pitcher_stats" if pitcher else "batter_stats"
		var count_key: String = "outs_pitched" if pitcher else "plate_appearances"
		var a_count: int = int(a["stats"][stat_key][count_key])
		var b_count: int = int(b["stats"][stat_key][count_key])
		return a_count > b_count if a_count != b_count else int(a["player_id"]) < int(b["player_id"])
	)
	return selected.slice(0, 3)


static func _comparison_fact(team: Dictionary) -> Dictionary:
	var delta: Dictionary = team.get("previous_delta", {}) as Dictionary
	if not delta.has("win_rate") or not delta.has("runs_scored_per_game") or not delta.has("runs_allowed_per_game"):
		return {"key": "season_review.comparison.unavailable", "params": {}}
	var params: Dictionary = {"win_rate": "%+.3f" % float(delta["win_rate"]),
		"scored": "%+.2f" % float(delta["runs_scored_per_game"]), "allowed": "%+.2f" % float(delta["runs_allowed_per_game"])}
	if delta.has("rank"):
		params["rank"] = "%+d" % int(delta["rank"])
		return {"key": "season_review.fact.comparison_rank", "params": params}
	return {"key": "season_review.fact.comparison", "params": params}


static func _sentence_facts(team: Dictionary) -> Array:
	var standing: Dictionary = team["standings"] as Dictionary
	var selected: Array = [{"key": "season_review.fact.record", "params": {"team": team["team_name"],
		"rank": team["rank"], "wins": standing["wins"], "losses": standing["losses"], "draws": standing["draws"]}}]
	var metrics: Dictionary = team["metrics"] as Dictionary
	var comparison: Dictionary = _comparison_fact(team)
	if comparison["key"] != "season_review.comparison.unavailable":
		selected.append(comparison)
	var leaders: Array = []
	for kind: String in ["pitcher", "fielder"]:
		var contributors: Array = team["contributors_" + kind] as Array
		if not contributors.is_empty():
			var leader: Dictionary = contributors[0] as Dictionary
			leaders.append({"kind": kind, "name": leader["name"], "war": "%.1f" % float(leader["war"])})
	if leaders.size() == 2:
		selected.append({"key": "season_review.fact.contributors", "params": {"pitcher": leaders[0]["name"], "pitcher_war": leaders[0]["war"],
			"fielder": leaders[1]["name"], "fielder_war": leaders[1]["war"]}})
	elif leaders.size() == 1:
		var key: String = "season_review.fact.contributor_pitcher" if str(leaders[0]["kind"]) == "pitcher" else "season_review.fact.contributor_fielder"
		selected.append({"key": key, "params": {"name": leaders[0]["name"], "war": leaders[0]["war"]}})
	var awards: Array = team.get("awards", []) as Array
	if not awards.is_empty():
		var names: Array[String] = []
		for award: Dictionary in awards:
			var name: String = str(award["name"])
			if not names.has(name):
				names.append(name)
		selected.append({"key": "season_review.fact.awards", "params": {"count": awards.size(), "names": names}})
	if selected.size() < 4 and metrics["runs_scored_per_game"] != null:
		selected.append({"key": "season_review.fact.runs", "params": {"scored": "%.2f" % float(metrics["runs_scored_per_game"]),
			"allowed": "%.2f" % float(metrics["runs_allowed_per_game"]), "difference": "%+d" % int(metrics["run_difference"])}})
	return selected


static func _postseason_fact(archive: PSSeasonArchive, team_id: int) -> Dictionary:
	if archive == null or archive.postseason == null:
		return {"key": "season_review.postseason.unavailable", "params": {}, "stages": []}
	var post: PSPostseasonResult = archive.postseason
	var reached: String = "none"
	var stages: Array = []
	for key: String in PSPostseasonResult.STAGE_KEYS:
		var stage: Dictionary = post.stage_dict(key)
		if int(stage.get("top_id", 0)) == team_id or int(stage.get("challenger_id", 0)) == team_id:
			stages.append({"stage": key, "completed": bool(stage.get("completed", false)), "winner_id": int(stage.get("winner_id", 0))})
			reached = "japan_series" if key == "japan_series" else ("cs2" if key.begins_with("cs2") else "cs1")
	if post.champion_team_id == team_id:
		reached = "champion"
	return {"key": "season_review.postseason." + reached, "params": {}, "stages": stages}


static func _awards(archive: PSSeasonArchive, team: PSTeam, facts: Array) -> Array:
	var result: Array = []
	if archive == null or archive.awards == null:
		return result
	var awards: PSAwards = archive.awards
	var candidates: Array = []
	for league: String in ["league1", "league2"]:
		for kind: String in ["mvp", "rookie"]:
			candidates.append({"player_id": int(awards.get(kind + "_" + league + "_player_id")), "label_key": "season_review.award." + kind, "league": league})
		for kind: String in ["batting", "pitching"]:
			var titles: Dictionary = awards.get(kind + "_titles") as Dictionary
			var categories: Array = PSAwards.BATTING_CATEGORIES if kind == "batting" else PSAwards.PITCHING_CATEGORIES
			for category: String in categories:
				candidates.append({"player_id": int((titles.get(league, {}) as Dictionary).get(category, 0)), "label_key": "season_review.award." + category, "league": league})
		for kind: String in ["best_nine", "golden_glove"]:
			var slots: Array = PSAwards.BEST_NINE_SLOT_POSITIONS if kind == "best_nine" else PSAwards.GOLDEN_GLOVE_SLOT_POSITIONS
			var winners: Array = (awards.get(kind) as Dictionary).get(league, []) as Array
			for index in winners.size():
				candidates.append({"player_id": int(winners[index].get("pid", 0)), "label_key": "season_review.award." + kind, "league": league, "position": int(slots[index])})
	for award: Dictionary in candidates:
		if int(award["player_id"]) <= 0:
			continue
		for fact: Dictionary in facts:
			if int(fact["player_id"]) == int(award["player_id"]) and int(fact["team_id"]) == team.id:
				award.merge({"name": fact["name"], "team_id": team.id, "team_name": team.name})
				result.append(award)
				break
	return result


static func _appeared(record: PSPlayerSeasonRecord) -> bool:
	return record.batter_stats.games > 0 or record.pitcher_stats.games > 0


static func _counts(record: PSPlayerSeasonRecord, context: Dictionary) -> Dictionary:
	var batter: Dictionary = {}
	var pitcher: Dictionary = {}
	for key: String in BATTER_COUNTS:
		batter[key] = record.batter_stats.get(key)
	for key: String in PITCHER_COUNTS:
		pitcher[key] = record.pitcher_stats.get(key)
	return {"batter_stats": batter, "pitcher_stats": pitcher,
		"war": float(PSWarCalculator.season_war(record, context).get("war", 0.0))}
