extends RefCounted
class_name PSTeam

# 本拠地の属性は屋根と地方の 2 つで、どちらも雨天の判定に使う — ドームは中止せず、同じ地方の球場は
# 同じ日に同じ天気になる ([[project_rainout_postpone]])。球場サイズ (park factor) は別系統の mod 係数で、
# ここには持たない。
const ROOF_OPEN: String = "open"
const ROOF_DOME: String = "dome"

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
# ファーム専用球団 (一軍を持たない = NPB 球団ではない) なら true。
# 一軍日程・順位・ポストシーズン・FA・予算・戦力外・トレード・表彰・WAR・支配下枠の
# いずれの対象にもならず、二軍戦にだけ参加する。`GameDb.teams` には載らず
# `GameDb.farm_clubs` 側に持つ ([[project_farm_system_design]])。
var farm_only: bool = false
# 本拠地球場の屋根 (ROOF_OPEN / ROOF_DOME)。ファーム専用球団は二軍球場しか持たないため常に屋外。
var home_park_roof: String = ROOF_OPEN
# 本拠地の地方 (気象庁の地方予報区の id。表示名は `PSRainoutService.REGION_LABELS`)。
# 同じ地方の球場は同じ日に同じ天気になる。空なら球団ごとに独立した地方として扱う。
var home_region: String = ""


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
	farm_only = bool(data.get("farm_only", false))
	home_park_roof = ROOF_DOME if str(data.get("home_park_roof", ROOF_OPEN)) == ROOF_DOME else ROOF_OPEN
	home_region = str(data.get("home_region", "")).strip_edges()


func has_dome() -> bool:
	return home_park_roof == ROOF_DOME


func overall() -> int:
	if ratings.is_empty():
		return 0
	var total: int = 0
	for value in ratings.values():
		total += int(value)
	@warning_ignore("integer_division")
	return int(total / ratings.size())


func league_label() -> String:
	return "第1リーグ" if league == "league1" else "第2リーグ"


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
		"farm_only": farm_only,
		"home_park_roof": home_park_roof,
		"home_region": home_region,
	}
