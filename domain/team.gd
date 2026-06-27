extends RefCounted
class_name PSTeam

var id: int
var name: String
var short_name: String
var league: String
var color: Color = Color.WHITE
var previous_rank: int
var funds: int
var ratings: Dictionary = {}
# true なら保存打順を使わず、試合ごとに自動打順と守備テンプレートからチーム編成を作る。
var auto_lineup: bool = true


static func from_dict(data: Dictionary) -> PSTeam:
	var team: PSTeam = PSTeam.new()
	team.apply_dict(data)
	return team


func apply_dict(data: Dictionary) -> void:
	id = int(data.get("id", 0))
	name = str(data.get("name", ""))
	short_name = str(data.get("short_name", name))
	league = str(data.get("league", ""))
	color = Color.html(str(data.get("color", "#ffffff")))
	previous_rank = int(data.get("previous_rank", 0))
	funds = int(data.get("funds", 0))
	ratings = (data.get("ratings", {}) as Dictionary).duplicate(true)
	auto_lineup = bool(data.get("auto_lineup", true))


func overall() -> int:
	if ratings.is_empty():
		return 0
	var total: int = 0
	for value in ratings.values():
		total += int(value)
	@warning_ignore("integer_division")
	return int(total / ratings.size())


func league_label() -> String:
	return "第1リーグ" if league == "central" else "第2リーグ"


func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"short_name": short_name,
		"league": league,
		"color": color.to_html(false),
		"previous_rank": previous_rank,
		"funds": funds,
		"ratings": ratings,
		"auto_lineup": auto_lineup,
	}
