extends RefCounted
class_name PSDraftRetrospectiveService


# 完了総括の凍結台帳だけを合算し、名簿・成績の入力は変更しない。
static func build(draft_class: PSDraftClass, reviews: Array, end_year: int, end_season_number: int, team_id: int) -> Dictionary:
	if draft_class == null:
		return {}
	var team_name: String = ""
	for team: Dictionary in draft_class.teams:
		if int(team.get("team_id", 0)) == team_id:
			team_name = str(team.get("team_name", ""))
	var picks: Array = []
	for pick: Dictionary in draft_class.picks:
		if int(pick.get("team_id", 0)) == team_id:
			picks.append(pick)
	picks.sort_custom(_pick_before)
	var seasons: Dictionary = {}
	for review: PSSeasonReview in reviews:
		if review == null or review.season_number <= draft_class.season_number or review.season_number > end_season_number:
			continue
		if review.year <= draft_class.year or review.year > end_year:
			continue
		# 同じ年度の総括が重複して渡されても一度だけ足す。
		seasons[review.season_number] = review
	var season_numbers: Array = seasons.keys()
	season_numbers.sort()
	var missing: Array = []
	for number in range(draft_class.season_number + 1, end_season_number + 1):
		var year: int = draft_class.year + number - draft_class.season_number
		if year <= end_year and not seasons.has(number):
			missing.append({"year": year, "season_number": number})
	var players: Array = []
	var by_id: Dictionary = {}
	var summary: Dictionary = {"main_count": 0, "development_count": 0, "appeared_count": 0, "war": 0.0, "team_war": 0.0}
	for pick: Dictionary in picks:
		var row: Dictionary = {"identity": pick.duplicate(true), "all": _empty_totals(), "team": _empty_totals(), "years": []}
		players.append(row)
		by_id[int(pick["player_id"])] = row
		var count_key: String = "development_count" if bool(pick.get("development", false)) else "main_count"
		summary[count_key] = int(summary[count_key]) + 1
	for number: int in season_numbers:
		var review: PSSeasonReview = seasons[number] as PSSeasonReview
		var facts: Dictionary = {}
		for fact: Dictionary in review.player_facts:
			facts[int(fact["player_id"])] = fact
		for id: int in by_id:
			var row: Dictionary = by_id[id] as Dictionary
			var fact: Dictionary = facts.get(id, {}) as Dictionary
			var all_totals: Dictionary = _empty_totals()
			var team_totals: Dictionary = _empty_totals()
			_add_totals(all_totals, fact.get("total", {}) as Dictionary)
			_add_totals(team_totals, (fact.get("teams", {}) as Dictionary).get(str(team_id), {}) as Dictionary)
			_add_totals(row["all"] as Dictionary, all_totals)
			_add_totals(row["team"] as Dictionary, team_totals)
			(row["years"] as Array).append({"year": review.year, "season_number": number, "all": all_totals, "team": team_totals})
	for row: Dictionary in players:
		var totals: Dictionary = row["all"] as Dictionary
		if int(totals["batter_stats"]["games"]) > 0 or int(totals["pitcher_stats"]["games"]) > 0:
			summary["appeared_count"] = int(summary["appeared_count"]) + 1
		summary["war"] = float(summary["war"]) + float(totals["war"])
		summary["team_war"] = float(summary["team_war"]) + float(row["team"]["war"])
	return {"year": draft_class.year, "season_number": draft_class.season_number,
		"team_id": team_id, "team_name": team_name, "end_year": end_year, "end_season_number": end_season_number,
		"completed_seasons": season_numbers.size(), "has_completed_season": not season_numbers.is_empty(),
		"missing_seasons": missing, "summary": summary, "players": players}


static func _pick_before(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.get("development", false)) != bool(b.get("development", false)):
		return not bool(a.get("development", false))
	for key: String in ["round", "pick_order", "player_id"]:
		if int(a.get(key, 0)) != int(b.get(key, 0)):
			return int(a.get(key, 0)) < int(b.get(key, 0))
	return false


static func _empty_totals() -> Dictionary:
	var result: Dictionary = {"batter_stats": {}, "pitcher_stats": {}, "war": 0.0}
	for key: String in PSSeasonReviewService.BATTER_COUNTS:
		result["batter_stats"][key] = 0
	for key: String in PSSeasonReviewService.PITCHER_COUNTS:
		result["pitcher_stats"][key] = 0
	return result


static func _add_totals(target: Dictionary, source: Dictionary) -> void:
	for category: String in ["batter_stats", "pitcher_stats"]:
		var counts: Dictionary = source.get(category, {}) as Dictionary
		for key: String in target[category]:
			target[category][key] = int(target[category][key]) + int(counts.get(key, 0))
	target["war"] = float(target["war"]) + float(source.get("war", 0.0))
