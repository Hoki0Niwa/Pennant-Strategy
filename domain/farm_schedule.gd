extends RefCounted
class_name PSFarmSchedule

# 二軍 (ファーム) の日程生成。14球団・3地区 (東5 / 中5 / 西4) の 1 リーグ制。
#
# **一軍日程のミラーではなく専用のジェネレータ**。14球団・地区非対称 (5/5/4) は
# 一軍 (12球団 6/6) の日程に対応付けられないため。
#
# ## 試合数 (docs/agent_memory/project_farm_system_design.md)
# NPB ファームの**予定**は135-146試合/球団だが、**中止試合の再試合を行わない**ため実消化は
# 120台に落ちる (2025年実測: 14球団平均 ≒ 124)。中止をイベントとして実装しない以上、
# 最初から実消化相当の本数を組むのが正しいので `GAMES_PER_TEAM = 124` を採る。
# 全14球団が同数 (124 × 14 / 2 = 868試合)。実 NPB の地区別の試合数差は再現しない。
#
# ## 構成
# 1 ラウンド = 14球団の完全マッチング = 7試合 (全球団が必ず出場)。
# ラウンドを3日連続で回して 1 カード (3連戦) とし、「地区内6カード → 地区間2カード」を反復する
# (NPB の日程構成に倣う)。東・中は奇数球団なので地区内カードでも 1 試合だけ中↔東の
# 橋渡しが入る — これも NPB と同じ ("奇数のため地区内対戦期間にも交流戦を行う")。
#
# ## 試合日
# **一軍の試合日の部分集合**に割り当てる (一軍が試合の無い日には二軍も試合をしない)。
# これにより `PSGameDecisions.advance_current_day` を含む既存の日進行に一切手を入れずに済む。
# 実 NPB は一軍が休みの月曜にもファームが試合をするが、再現の価値に対して
# 日進行・スキップ・セーブ/ロード・ポストシーズンへの波及リスクが大きすぎる。

const GAMES_PER_TEAM: int = 124
const GAMES_PER_SERIES: int = 3
# 「地区内6カード → 地区間2カード」の反復 (NPB の日程構成)。
const INTRA_SERIES_PER_CYCLE: int = 6
const INTER_SERIES_PER_CYCLE: int = 2
# ファーム公式戦は両地区とも DH 制。一軍と違いリーグによる差を持たない。
const DH_ENABLED: bool = true
# 一軍は延長12回だが、ファームは延長が10〜11回までに制限され9回打ち切りの特例も多い。
# 実測でウエスタンの引き分けは10%超 (一軍は約2%)。引き分け率を寄せるための較正ノブ。
const MAX_INNINGS: int = 10

const BYE: int = -1


# 二軍日程を生成する。`first_team_schedule` は同シーズンの一軍日程 (試合日と日付の供給元)。
static func generate(first_team_schedule: Array, team_ids: Array, games_per_team: int = GAMES_PER_TEAM) -> Array:
	var by_district: Dictionary = PSFarmLeague.team_ids_by_district(team_ids)
	var rounds: Array = _build_rounds(by_district, games_per_team)
	if rounds.is_empty():
		return []
	return _assign_to_days(rounds, first_team_schedule)


# 生成した日程の検証。試合数・1日1球団1試合・地区構成をまとめて確認する。
static func validate(games: Array, team_ids: Array) -> Dictionary:
	var errors: Array = []
	var games_by_team: Dictionary = {}
	var teams_by_day: Dictionary = {}
	for id_value in team_ids:
		games_by_team[int(id_value)] = 0

	for game_row in games:
		var game: Dictionary = game_row as Dictionary
		var day: int = int(game.get("day", 0))
		var away_id: int = int(game.get("away_team_id", 0))
		var home_id: int = int(game.get("home_team_id", 0))
		if away_id == home_id:
			errors.append("day %d: 同一球団同士の対戦" % day)
		for team_id in [away_id, home_id]:
			if not games_by_team.has(team_id):
				errors.append("day %d: 未知の球団 %d" % [day, team_id])
				continue
			games_by_team[team_id] = int(games_by_team[team_id]) + 1
			var day_key: String = "%d_%d" % [day, team_id]
			if teams_by_day.has(day_key):
				errors.append("day %d: 球団 %d が同日に2試合" % [day, team_id])
			teams_by_day[day_key] = true

	var min_games: int = -1
	var max_games: int = 0
	for team_id in games_by_team.keys():
		var count: int = int(games_by_team[team_id])
		min_games = count if min_games < 0 else min(min_games, count)
		max_games = max(max_games, count)

	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"total_games": games.size(),
		"games_by_team": games_by_team,
		"min_games_per_team": max(0, min_games),
		"max_games_per_team": max_games,
	}


# ---- ラウンド構築 ----------------------------------------------------------

# 必要なラウンド数 (= 1球団あたりの試合数。1ラウンドで全球団が1試合ずつ消化するため) だけ、
# 地区内カードと地区間カードを反復して積む。
static func _build_rounds(by_district: Dictionary, games_per_team: int) -> Array:
	var east: Array = by_district.get(PSFarmLeague.DISTRICT_EAST, []) as Array
	var central: Array = by_district.get(PSFarmLeague.DISTRICT_CENTRAL, []) as Array
	var west: Array = by_district.get(PSFarmLeague.DISTRICT_WEST, []) as Array
	if east.is_empty() or central.is_empty() or west.is_empty():
		return []

	var east_rounds: Array = _round_robin_rounds(east)
	var central_rounds: Array = _round_robin_rounds(central)
	var west_rounds: Array = _round_robin_rounds(west)

	var rounds: Array = []
	var series_index: int = 0
	var intra_index: int = 0
	var inter_index: int = 0
	var cycle_length: int = INTRA_SERIES_PER_CYCLE + INTER_SERIES_PER_CYCLE
	while rounds.size() < games_per_team:
		var is_intra: bool = posmod(series_index, cycle_length) < INTRA_SERIES_PER_CYCLE
		var pairs: Array
		if is_intra:
			pairs = _intra_round_pairs(east_rounds, central_rounds, west_rounds, intra_index)
			intra_index += 1
		else:
			pairs = _inter_round_pairs(east, central, west, east_rounds, central_rounds, inter_index)
			inter_index += 1
		for game_no in range(GAMES_PER_SERIES):
			if rounds.size() >= games_per_team:
				break
			rounds.append({
				"pairs": pairs,
				"series_index": series_index,
				"series_game_no": game_no + 1,
				"is_interdistrict_card": not is_intra,
			})
		series_index += 1
	return rounds


# 地区内カードのラウンド: 東・中・西それぞれの総当たり1ラウンドぶん + 橋渡し1試合。
# 東(5)・中(5) は奇数なので各ラウンドで1球団が余る。その2球団を突き合わせて
# 全14球団が出場する7試合にする (NPB の「奇数地区は地区内期間にも中↔東の交流を行う」に相当)。
static func _intra_round_pairs(
	east_rounds: Array,
	central_rounds: Array,
	west_rounds: Array,
	intra_index: int
) -> Array:
	var east_round: Dictionary = east_rounds[posmod(intra_index, east_rounds.size())] as Dictionary
	var central_round: Dictionary = central_rounds[posmod(intra_index, central_rounds.size())] as Dictionary
	var west_round: Dictionary = west_rounds[posmod(intra_index, west_rounds.size())] as Dictionary

	var pairs: Array = []
	pairs.append_array((east_round.get("pairs", []) as Array).duplicate(true))
	pairs.append_array((central_round.get("pairs", []) as Array).duplicate(true))
	pairs.append_array((west_round.get("pairs", []) as Array).duplicate(true))

	var east_bye: int = int(east_round.get("bye", BYE))
	var central_bye: int = int(central_round.get("bye", BYE))
	if east_bye != BYE and central_bye != BYE:
		pairs.append([east_bye, central_bye])
	return pairs


# 地区間カードのラウンド。東5/中5/西4 では「全試合が地区をまたぐ」完全マッチングは作れない
# (西4が余る) ので、3種のパターンを巡回させる。余った地区は地区内で埋める —
# これは実 NPB で西地区の地区内試合数が突出して多い (99-107試合) のと同じ理由。
static func _inter_round_pairs(
	east: Array,
	central: Array,
	west: Array,
	east_rounds: Array,
	central_rounds: Array,
	inter_index: int
) -> Array:
	var pattern: int = posmod(inter_index, 3)
	var offset: int = inter_index / 3
	match pattern:
		0:
			# 東 × 中 を総当たりでずらしながら組み、西は地区内で埋める。
			var pairs: Array = _cross_pairs(east, central, offset)
			var west_round: Dictionary = _round_robin_rounds(west)[posmod(inter_index, max(1, west.size() - 1))] as Dictionary
			pairs.append_array((west_round.get("pairs", []) as Array).duplicate(true))
			return pairs
		1:
			# 東の4球団 × 西、残った東1球団は中の余りと組む。
			return _cross_with_leftover(east, west, central, east_rounds, central_rounds, inter_index, true)
		_:
			# 中の4球団 × 西、残った中1球団は東の余りと組む。
			return _cross_with_leftover(central, west, east, central_rounds, east_rounds, inter_index, false)


# 同数の2地区を offset をずらしながら1対1で組む。
static func _cross_pairs(group_a: Array, group_b: Array, offset: int) -> Array:
	var pairs: Array = []
	var count: int = min(group_a.size(), group_b.size())
	for i in range(count):
		pairs.append([int(group_a[i]), int(group_b[posmod(i + offset, group_b.size())])])
	return pairs


# 奇数地区 (5) のうち4球団を西(4)へぶつけ、余った1球団はもう一方の奇数地区の余りと組む。
# もう一方の奇数地区の残り4球団は地区内で消化する。
static func _cross_with_leftover(
	odd_group: Array,
	west: Array,
	other_odd_group: Array,
	odd_rounds: Array,
	other_rounds: Array,
	inter_index: int,
	_odd_is_east: bool
) -> Array:
	var odd_round: Dictionary = odd_rounds[posmod(inter_index, odd_rounds.size())] as Dictionary
	var leftover: int = int(odd_round.get("bye", BYE))
	if leftover == BYE:
		leftover = int(odd_group[0])

	var crossing: Array = []
	for id_value in odd_group:
		if int(id_value) != leftover:
			crossing.append(int(id_value))

	var pairs: Array = []
	for i in range(min(crossing.size(), west.size())):
		pairs.append([crossing[i], int(west[posmod(i + inter_index, west.size())])])

	var other_round: Dictionary = other_rounds[posmod(inter_index, other_rounds.size())] as Dictionary
	pairs.append_array((other_round.get("pairs", []) as Array).duplicate(true))
	var other_bye: int = int(other_round.get("bye", BYE))
	if other_bye != BYE:
		pairs.append([leftover, other_bye])
	return pairs


# 円卓法の総当たり。奇数ならダミーを足し、ダミーと当たった球団を bye として返す。
# 偶数チーム数 n なら n-1 ラウンド、奇数 n なら n ラウンドで一巡する。
static func _round_robin_rounds(ids: Array) -> Array:
	var work: Array = []
	for id_value in ids:
		work.append(int(id_value))
	if work.size() % 2 == 1:
		work.append(BYE)
	var count: int = work.size()
	if count < 2:
		return []

	var rounds: Array = []
	for _round_index in range(count - 1):
		var pairs: Array = []
		var bye: int = BYE
		for i in range(count >> 1):
			var a: int = int(work[i])
			var b: int = int(work[count - 1 - i])
			if a == BYE:
				bye = b
			elif b == BYE:
				bye = a
			else:
				pairs.append([a, b])
		rounds.append({"pairs": pairs, "bye": bye})
		var last: Variant = work[count - 1]
		for i in range(count - 1, 1, -1):
			work[i] = work[i - 1]
		work[1] = last
	return rounds


# ---- 試合日への割り当て ----------------------------------------------------

# ラウンド列を一軍の試合日へ均等に散らす。一軍の試合日数 (約150) より二軍のラウンド数 (124) が
# 少ないので、等間隔に間引いて割り当てる = ファームの休養日が自然に混ざる。
static func _assign_to_days(rounds: Array, first_team_schedule: Array) -> Array:
	var date_by_day: Dictionary = {}
	var day_pool: Array = []
	for game_row in first_team_schedule:
		var game: Dictionary = game_row as Dictionary
		var day: int = int(game.get("day", 0))
		if day <= 0 or date_by_day.has(day):
			continue
		date_by_day[day] = str(game.get("date", ""))
		day_pool.append(day)
	day_pool.sort()
	if day_pool.is_empty():
		return []

	var needed: int = min(rounds.size(), day_pool.size())
	var games: Array = []
	for round_index in range(needed):
		var round_data: Dictionary = rounds[round_index] as Dictionary
		var day_index: int = int(floor(float(round_index) * float(day_pool.size()) / float(needed)))
		var day: int = int(day_pool[min(day_index, day_pool.size() - 1)])
		var pairs: Array = round_data.get("pairs", []) as Array
		for pair_index in range(pairs.size()):
			var pair: Array = pairs[pair_index] as Array
			# ホーム/ビジターはラウンドと試合順の偶奇で入れ替え、片寄りを避ける。
			var swap_home: bool = posmod(round_index + pair_index, 2) == 1
			var away_id: int = int(pair[1] if swap_home else pair[0])
			var home_id: int = int(pair[0] if swap_home else pair[1])
			games.append(_make_farm_game(
				day,
				str(date_by_day.get(day, "")),
				away_id,
				home_id,
				int(round_data.get("series_index", 0)),
				int(round_data.get("series_game_no", 1))
			))
	return games


static func _make_farm_game(
	day: int,
	date_text: String,
	away_team_id: int,
	home_team_id: int,
	series_id: int,
	series_game_no: int
) -> Dictionary:
	var away_district: String = PSFarmLeague.district_for_team(away_team_id)
	var home_district: String = PSFarmLeague.district_for_team(home_team_id)
	return {
		"day": day,
		"date": date_text,
		"away_team_id": away_team_id,
		"home_team_id": home_team_id,
		"away_score": 0,
		"home_score": 0,
		"played": false,
		"dh_enabled": DH_ENABLED,
		"innings": [],
		"result": {},
		"is_farm": true,
		"is_interleague": false,
		"is_interdistrict": away_district != home_district,
		"away_district": away_district,
		"home_district": home_district,
		"series_id": series_id,
		"series_game_no": series_game_no,
		"cycle_number": 1,
	}
