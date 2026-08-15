extends RefCounted
class_name PSFarmLeague

# 二軍 (ファーム) のリーグ構成。NPB は 2026 年からイースタン/ウエスタンを廃し、
# **1リーグ3地区制・14球団** (東5 / 中5 / 西4) へ移行した。本作もこれに倣う。
#
# 14球団 = 一軍を持つ12球団 + **ファーム専用球団2つ**。専用球団は NPB 球団ではないので
# 一軍・FA・予算・戦力外・トレード・表彰といった一軍系の仕組みからは完全に隔離する
# (詳細は docs/agent_memory/project_farm_system_design.md)。
#
# ⚠️ 専用球団を `GameDb.teams` へ混ぜてはいけない。`GameDb.teams` の参照は 300 箇所以上あり、
#    すべて「12球団前提」で書かれている。専用球団は `GameDb.farm_clubs` に分けて持ち、
#    team_id の空間だけを共有する (RecordStore / PSPlayer.team_id は team_id キーの汎用実装なので、
#    id さえ衝突しなければ専用球団の選手レコードは無改修で通る)。

const DISTRICT_EAST: String = "east"
const DISTRICT_CENTRAL: String = "central"
const DISTRICT_WEST: String = "west"

const DISTRICT_ORDER: Array[String] = [DISTRICT_EAST, DISTRICT_CENTRAL, DISTRICT_WEST]

const DISTRICT_LABELS: Dictionary = {
	DISTRICT_EAST: "東地区",
	DISTRICT_CENTRAL: "中地区",
	DISTRICT_WEST: "西地区",
}

# ファーム専用球団。id は一軍12球団 (1-12) の続き。`league` は空文字 = どの一軍リーグにも属さない。
# `farm_only` が true の PSTeam として GameDb.farm_clubs へ載る。
const FARM_CLUB_DEFS: Array[Dictionary] = [
	{
		"id": 13,
		"name": "ノースメン長野",
		"short_name": "N",
		"league": "",
		"color": "60a0d0",
	},
	{
		"id": 14,
		"name": "オスプレー大分",
		"short_name": "O",
		"league": "",
		"color": "e08040",
	},
]

# 地区割り。実 NPB と同じく**一軍のリーグとは独立**に、地理で分ける
# (実 NPB も東地区に楽天・ヤクルト・ロッテ・日本ハムとセ/パが混在する)。
# 東5 / 中5 / 西4 で、専用球団は東と西に1つずつ入る。
#
# ⚠️ 球団数の 5/5/4 と「東・中が奇数、西が偶数」は `PSFarmSchedule._build_rounds` の前提
#    (奇数地区の余り同士で橋渡し1試合を作り、7試合 = 全14球団出場のラウンドにしている)。
#    地区を動かすときはこの組み合わせを保つこと。
const DISTRICT_BY_TEAM_ID: Dictionary = {
	1: DISTRICT_EAST,     # 旭川アトミックス
	4: DISTRICT_EAST,     # 出羽ダークデビルズ
	8: DISTRICT_EAST,     # 八王子ホーネッツ
	9: DISTRICT_EAST,     # 上越ジェスターズ
	13: DISTRICT_EAST,    # ノースメン長野 (専用)
	2: DISTRICT_CENTRAL,  # 備前ブラスターズ
	3: DISTRICT_CENTRAL,  # 茅ヶ崎クルセイダーズ
	6: DISTRICT_CENTRAL,  # 福井ファルコンズ
	7: DISTRICT_CENTRAL,  # 岐阜ゲームコックス
	10: DISTRICT_CENTRAL, # 京都キーストーンズ
	5: DISTRICT_WEST,     # 愛媛エレファンツ
	11: DISTRICT_WEST,    # 琉球ライトニング
	12: DISTRICT_WEST,    # 宮崎メープルズ
	14: DISTRICT_WEST,    # オスプレー大分 (専用)
}


# 専用球団の選手が NPB でプレーした経験 (= ドラフト指名歴) を持つかの印。
# **供給元が指名資格を決める** (実ルールがそうなっている):
#   戦力外から拾った選手 = 指名歴あり → ドラフトを経ずに NPB へ戻れる
#   自動生成した選手     = NPB 未経験 → ドラフト指名を受ける必要がある
# 立てるのは `FarmClubService` (選手を作る/拾う側)、読むのは `DraftService` (指名する側)。
# 判定をここ (domain) に置くのは、両サービスが互いを preload しないようにするため。
const SOURCE_KEY_NPB_EXPERIENCED: String = "npb_experienced"


static func farm_club_ids() -> Array[int]:
	var ids: Array[int] = []
	for def_row in FARM_CLUB_DEFS:
		ids.append(int((def_row as Dictionary).get("id", 0)))
	return ids


static func is_farm_club_id(team_id: int) -> bool:
	return farm_club_ids().has(team_id)


static func has_npb_experience(player: PSPlayer) -> bool:
	return player != null and bool(player.source_data.get(SOURCE_KEY_NPB_EXPERIENCED, false))


# NPB のドラフト指名の対象になる専用球団の選手か。実ルール準拠で **NPB 経験のない日本人選手**
# のみが対象 (外国人と指名歴ありの選手は 7/31 までの直接移籍で動く別経路)。
static func is_draft_eligible_farm_club_player(player: PSPlayer) -> bool:
	if player == null or player.is_retired():
		return false
	if not is_farm_club_id(player.team_id):
		return false
	if player.foreign_player:
		return false
	return not has_npb_experience(player)


# 地区。表に無い team_id (Mod でシードを差し替えた等) は id から決定論的に割り当てる。
static func district_for_team(team_id: int) -> String:
	if DISTRICT_BY_TEAM_ID.has(team_id):
		return str(DISTRICT_BY_TEAM_ID[team_id])
	return DISTRICT_ORDER[posmod(team_id, DISTRICT_ORDER.size())]


static func district_label(district: String) -> String:
	return str(DISTRICT_LABELS.get(district, district))


# 二軍に参加する全 team_id (一軍12球団 + 専用2球団)。引数の team_ids は一軍側の球団。
static func all_team_ids(first_team_ids: Array) -> Array[int]:
	var ids: Array[int] = []
	for id_value in first_team_ids:
		ids.append(int(id_value))
	for id_value in farm_club_ids():
		if not ids.has(id_value):
			ids.append(id_value)
	return ids


# 地区 → その地区に属する team_id 配列。渡された全 team_id を地区で仕分ける。
static func team_ids_by_district(team_ids: Array) -> Dictionary:
	var by_district: Dictionary = {}
	for district in DISTRICT_ORDER:
		by_district[district] = [] as Array[int]
	for id_value in team_ids:
		var team_id: int = int(id_value)
		(by_district[district_for_team(team_id)] as Array[int]).append(team_id)
	return by_district
