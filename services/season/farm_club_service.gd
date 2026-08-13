extends RefCounted
class_name FarmClubService

# ファーム専用球団 (一軍を持たない2球団) の選手供給。
#
# 専用球団は NPB 球団ではないので、支配下枠・予算・FA・契約更改・戦力外・トレード・表彰・WAR の
# どれも通らない。そのぶんロスターを維持する仕組みを自前で持つ必要がある。
# 流入は2チャネル、流出は3経路:
#
#   流入 ① 戦力外から一定数獲得 — NPB12球団の獲得フェーズが終わった後の残り物を拾う
#          (実際の受け皿としての位置づけ)。**上限 const が必須** — 専用球団には枠制約が
#          一切効かないので、無いとロスターが元NPB選手だけで埋まる。
#   流入 ② 自動生成 — NPB に指名されなかった水準の若手を目標人数まで作る。
#
#   流出 ① 高齢による整理 (下記 ATTRITION_*)
#   流出 ② NPB のドラフト指名 (Phase 6。生成組=NPB経験なし日本人のみが対象)
#   流出 ③ 7/31 までの直接移籍 (Phase 6。戦力外獲得組=ドラフト指名歴ありが対象)
#
# **供給元が指名資格を決める**のは実ルールがそうなっているため:
#   戦力外獲得組 = ドラフト指名歴あり → ドラフト不要で移籍できる
#   自動生成組   = NPB経験なし日本人 → ドラフト指名を受ける必要がある
# その判別のために `source_data["npb_experienced"]` を立てる (Phase 6 がこれを読む)。
#
# 詳細は docs/agent_memory/project_farm_system_design.md。

const Offseason = preload("res://services/season/offseason_service.gd")
const Draft = preload("res://services/season/draft_service.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")

# 目標ロスター人数。実クラブ相当 (オイシックス新潟の2026年登録は50人)。一軍を持たず
# 二軍1チーム分を故障込みで回す規模。
const ROSTER_TARGET: int = 48

# 1オフあたり1球団が戦力外から獲れる上限。**この const がロスターの性格を決める** —
# 大きくすると「元NPB選手の再挑戦の場」、小さくすると「生え抜き育成クラブ」になる。
# Phase 6 のドラフト対象は生成組だけなので、小さいほどドラフトの目玉が増える。
const MAX_RELEASED_SIGNINGS_PER_CLUB: int = 6
# 戦力外獲得の年齢上限。これを超える選手は拾わない (拾っても翌オフに整理されるだけ)。
const RELEASED_SIGNING_MAX_AGE: int = 32

# 高齢整理。ATTRITION_START_AGE から確率が立ち上がり、ATTRITION_CERTAIN_AGE で必ず整理される。
# NPB の引退判定 (`OffseasonService.process_retirement`) は**一軍成績**を見るので専用球団には
# 意味を持たない。そのため専用球団は retirement ステップから除外し、ここで独自に流出させる。
const ATTRITION_START_AGE: int = 27
const ATTRITION_CERTAIN_AGE: int = 32

# 生成する選手の能力水準。**この4つが専用球団の強さを決める最重要ノブ。**
#
# ⚠️ 2026-08-12 に 33〜50 / max 62 から引き上げた。旧値は「NPB に指名されなかった層だから
# ドラフト候補 (center 42〜68) より低く」という意図で置いたものだったが、実測すると
# 専用球団の投手は質 z が平均 **-0.85** (12球団の二軍投手は +1.3) の 2σ 低で、
# **防御率 20〜25 / BB/9 26〜32 / 3勝31敗** という壊滅状態になっていた。
# 現行の打席モデルは投手能力の差に対して非常に急峻で、1σ の差が防御率の 5〜6 倍差になる。
#
# そのため「指名されなかった層」の建前を額面どおり数値化すると球団が成立しない。
# 現状はドラフト候補と**同水準やや狭め** (center 50-62 / 候補は 42-68) に置き、
# 二軍リーグの最下位争いをする実在感のある弱小球団に落とし込んでいる。
# **打席モデルの水準依存を直す作業 (レベル差が環境によらず妥当に効くようにする) が入ったら、
# この4つは建前どおりの水準へ下げ直せるはず。そのときに再較正すること。**
const GENERATED_MIN_AGE: int = 18
const GENERATED_MAX_AGE: int = 24
const GENERATED_CENTER_MIN: int = 54
const GENERATED_CENTER_MAX: int = 66
const GENERATED_ABILITY_VARIANCE: int = 11
const GENERATED_MAX_DISPLAY: int = 72

# 専用球団の年俸は固定 (NPB の年俸査定・契約更改の外)。
const SALARY: int = 400
const REGISTERED_ROSTER: String = "ファーム"

# ロスター構成。二軍戦を必ず組めるように守備位置を明示的に割り当てる
# (ドラフト候補の分布をそのまま使うと捕手や内野の頭数が保証されない)。合計 = ROSTER_TARGET。
const POSITION_QUOTA: Dictionary = {
	1: 22,  # 投手
	2: 5,   # 捕手
	3: 3,   # 一塁
	4: 3,   # 二塁
	5: 3,   # 三塁
	6: 4,   # 遊撃
	7: 3,   # 左翼
	8: 3,   # 中堅
	9: 2,   # 右翼
}


static func roster_players(players: Array, club_id: int) -> Array:
	var roster: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired():
			continue
		if player.team_id == club_id:
			roster.append(player)
	return roster


static func roster_count(players: Array, club_id: int) -> int:
	return roster_players(players, club_id).size()


# 専用球団に所属する選手か。ドラフトで NPB へ移った瞬間に false になる (team_id で判定するため)。
static func is_farm_club_player(player: PSPlayer) -> bool:
	return player != null and PSFarmLeague.is_farm_club_id(player.team_id)


# NPB でのプレー経験 (= ドラフト指名歴) があるか。Phase 6 のドラフト対象判定が読む。
static func has_npb_experience(player: PSPlayer) -> bool:
	return player != null and bool(player.source_data.get("npb_experienced", false))


# 初期ワールド生成の固定シード。
# ⚠️ **`Rng.current_seed` を使ってはいけない。** `ensure_initial_rosters` は
# `GameDb._finish_initial_load()` から呼ばれるが、その時点の `Rng.current_seed` は
# `Rng._ready()` の `randomize_seed()` が入れた**乱数**で、レポートやテストが
# `set_seed_value()` を呼ぶより前。ここを world seed に依存させると
# **同じ seed でもワールドごとに専用球団の選手が変わり、シミュ全体が再現しなくなる**
# (実際に farm report の2回実行で中止16件→0件・BB% .104→.145 と揺れて発覚した)。
# 12球団の選手が `initial_players.csv` で毎回同一なのと同じく、専用球団も
# シードワールドの一部として固定するのが一貫している。
const INITIAL_ROSTER_SEED: int = 20260811


# 新規ワールド用。空の専用球団を目標人数まで生成選手で埋める。
# 全選手が「NPB経験なし」なので、初回ドラフトから指名対象になる。
static func ensure_initial_rosters(players: Array, year: int) -> Dictionary:
	var generated_total: int = 0
	for club_id in PSFarmLeague.farm_club_ids():
		generated_total += _fill_to_target(players, int(club_id), year, INITIAL_ROSTER_SEED)
	return {
		"generated_count": generated_total,
		"clubs": _roster_summary(players),
	}


# オフシーズンの補充。**NPB12球団の戦力外獲得フェーズが完了した後**に呼ぶこと
# (専用球団は残り物を拾う立場なので、順序が逆だと NPB より先に有望な選手を取ってしまう)。
static func process_offseason(players: Array, year: int) -> Dictionary:
	var released_out: Array = []
	var signed: Array = []
	var generated_total: int = 0

	for club_id_value in PSFarmLeague.farm_club_ids():
		var club_id: int = int(club_id_value)
		released_out.append_array(_process_attrition(players, club_id, year))

	# 獲得は全球団ぶんを1つの候補プールから順に取る (先に1球団が総取りしないよう club を交互に回す)。
	signed = _sign_released_players(players, year)

	for club_id_value in PSFarmLeague.farm_club_ids():
		generated_total += _fill_to_target(players, int(club_id_value), year)

	return {
		"attrition": released_out,
		"attrition_count": released_out.size(),
		"signings": signed,
		"signed_count": signed.size(),
		"generated_count": generated_total,
		"clubs": _roster_summary(players),
	}


# ---- 流出: 高齢整理 --------------------------------------------------------

static func _process_attrition(players: Array, club_id: int, year: int) -> Array:
	var released: Array = []
	for player_row in roster_players(players, club_id):
		var player: PSPlayer = player_row as PSPlayer
		if not _should_release_for_age(player.age):
			continue
		player.source_data["retired"] = true
		player.source_data["retired_age"] = player.age
		player.source_data["farm_club_released_year"] = year
		player.team_id = 0
		released.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"club_id": club_id,
			"npb_experienced": has_npb_experience(player),
		})
	return released


static func _should_release_for_age(age: int) -> bool:
	if age >= ATTRITION_CERTAIN_AGE:
		return true
	if age < ATTRITION_START_AGE:
		return false
	var span: float = float(ATTRITION_CERTAIN_AGE - ATTRITION_START_AGE)
	var chance: float = float(age - ATTRITION_START_AGE + 1) / (span + 1.0)
	return Rng.roll_float() < chance


# ---- 流入①: 戦力外からの獲得 ----------------------------------------------

# NPB の獲得フェーズを通り抜けて残った戦力外選手 (team_id==0 かつ released) を、
# 価値の高い順に球団へ交互配分する。上限は球団ごとに MAX_RELEASED_SIGNINGS_PER_CLUB。
static func _sign_released_players(players: Array, year: int) -> Array:
	var candidates: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != 0:
			continue
		if not bool(player.source_data.get("released", false)):
			continue
		if player.age > RELEASED_SIGNING_MAX_AGE:
			continue
		candidates.append(player)
	if candidates.is_empty():
		return []

	candidates.sort_custom(func(a, b) -> bool:
		var value_a: int = Offseason.player_value_score(a as PSPlayer)
		var value_b: int = Offseason.player_value_score(b as PSPlayer)
		if value_a == value_b:
			return (a as PSPlayer).id < (b as PSPlayer).id
		return value_a > value_b
	)

	var club_ids: Array = PSFarmLeague.farm_club_ids()
	var signed_by_club: Dictionary = {}
	for club_id in club_ids:
		signed_by_club[int(club_id)] = 0

	var signings: Array = []
	var club_cursor: int = 0
	for candidate_row in candidates:
		var remaining_capacity: bool = false
		for club_id in club_ids:
			if int(signed_by_club[int(club_id)]) < MAX_RELEASED_SIGNINGS_PER_CLUB:
				remaining_capacity = true
				break
		if not remaining_capacity:
			break

		# 空きのある球団を交互に選ぶ。
		var club_id: int = 0
		for _attempt in range(club_ids.size()):
			var candidate_club: int = int(club_ids[posmod(club_cursor, club_ids.size())])
			club_cursor += 1
			if int(signed_by_club[candidate_club]) < MAX_RELEASED_SIGNINGS_PER_CLUB:
				club_id = candidate_club
				break
		if club_id == 0:
			break
		if roster_count(players, club_id) >= ROSTER_TARGET:
			signed_by_club[club_id] = MAX_RELEASED_SIGNINGS_PER_CLUB
			continue

		var player: PSPlayer = candidate_row as PSPlayer
		_apply_farm_club_signing(player, club_id, year)
		signed_by_club[club_id] = int(signed_by_club[club_id]) + 1
		signings.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"position": player.position,
			"club_id": club_id,
			"value": Offseason.player_value_score(player),
		})
	return signings


static func _apply_farm_club_signing(player: PSPlayer, club_id: int, year: int) -> void:
	player.team_id = club_id
	# 戦力外市場から外す (残しておくと翌オフに NPB 側が在籍中の選手を拾ってしまう)。
	player.source_data.erase("released")
	player.source_data.erase("retired")
	player.source_data.erase("retired_age")
	# 育成契約は NPB の制度なので専用球団では持たない。支配下枠の計数からも外れる。
	player.development_player = false
	player.registered_roster = REGISTERED_ROSTER
	player.source_data.erase("development_since_year")
	player.source_data.erase("dev_from_controlled")
	player.source_data.erase("dev_demote_hold")
	player.salary = SALARY
	player.source_data["farm_club_signed_year"] = year
	# 戦力外組はドラフト指名歴があるので、Phase 6 ではドラフトを経ずに移籍できる側になる。
	player.source_data["npb_experienced"] = true


# ---- 流入②: 自動生成 ------------------------------------------------------

# 目標人数まで生成する。守備位置は POSITION_QUOTA の不足分から埋め、
# 余りは投手と野手を交互に足して構成の偏りを防ぐ。
# seed_base は乱数ストリームの起点。初期ワールド生成は固定値 (INITIAL_ROSTER_SEED)、
# オフの補充はプレイ中なので `Rng.current_seed` (ワールドの seed) を使う。
static func _fill_to_target(players: Array, club_id: int, year: int, seed_base: int = 0) -> int:
	var roster: Array = roster_players(players, club_id)
	if roster.size() >= ROSTER_TARGET:
		return 0

	var have_by_position: Dictionary = {}
	for position in POSITION_QUOTA.keys():
		have_by_position[int(position)] = 0
	for player_row in roster:
		var position: int = (player_row as PSPlayer).position
		if have_by_position.has(position):
			have_by_position[position] = int(have_by_position[position]) + 1

	var wanted: Array = []
	for position in POSITION_QUOTA.keys():
		var deficit: int = int(POSITION_QUOTA[position]) - int(have_by_position[int(position)])
		for _i in range(max(0, deficit)):
			wanted.append(int(position))
	# 既存選手の構成が偏っていて quota だけでは目標人数に届かない場合の埋め草。
	var filler_positions: Array = [1, 8, 2, 6, 1, 4, 1, 5]
	var filler_cursor: int = 0
	while roster.size() + wanted.size() < ROSTER_TARGET:
		wanted.append(int(filler_positions[posmod(filler_cursor, filler_positions.size())]))
		filler_cursor += 1
	# 目標人数を超えないよう切る (既存が quota を上回っているポジションがある場合)。
	while roster.size() + wanted.size() > ROSTER_TARGET and not wanted.is_empty():
		wanted.remove_at(wanted.size() - 1)
	if wanted.is_empty():
		return 0

	# 生成は**共有 Rng の乱数列を消費しない専用ストリーム**で行う。世界生成時に約96人を作るため、
	# 共有 generator を使うと以後の抽選が全部ずれて既存の seed ベースライン (balance report の
	# SHA ゲート等) が壊れる。Rng のレーン機構をメインスレッドで一時的に使って隔離する。
	var stream_base: int = seed_base if seed_base != 0 else Rng.current_seed
	var seed_key: int = hash([stream_base, "farm_club_supply", year, club_id, roster.size()])
	Rng.begin_game_stream(-1, seed_key)
	var next_id: int = _max_player_id(players) + 1
	var generated: int = 0
	for position_value in wanted:
		players.append(_generate_player(next_id, int(position_value), club_id, year))
		next_id += 1
		generated += 1
	Rng.end_game_stream()
	return generated


static func _generate_player(player_id: int, position: int, club_id: int, year: int) -> PSPlayer:
	var age: int = Rng.range_int(GENERATED_MIN_AGE, GENERATED_MAX_AGE)
	var center: int = Rng.range_int(GENERATED_CENTER_MIN, GENERATED_CENTER_MAX)
	var z_abilities: Dictionary = Offseason.generated_z_abilities(
		position, center, GENERATED_MAX_DISPLAY, GENERATED_ABILITY_VARIANCE
	)
	var data: Dictionary = {
		"id": player_id,
		"sensyu_num": player_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": club_id,
		"name": NamePool.pick_japanese_name(),
		"age": age,
		"years": 1,
		"height": Rng.range_int(168, 190),
		"weight": Rng.range_int(68, 98),
		"position": position,
		"role": "" if position == 1 else "fielder",
		"throws": "L" if Rng.roll_percent() <= 25 else "R",
		"bats": "L" if Rng.roll_percent() <= 35 else "R",
		"salary": SALARY,
		"draft_round": 0,
		"hometown": "",
		"registered_roster": REGISTERED_ROSTER,
		"contract_status": "通常",
		"foreign_player": false,
		"position_aptitudes": Draft._candidate_position_aptitudes(position),
		"source_data": {
			"farm_club_origin_year": year,
			# 生成組は NPB 未経験 = Phase 6 のドラフト指名対象。
			"npb_experienced": false,
		},
		"fatigue": 0,
		"injury_days": 0,
		"z_abilities": z_abilities,
		"raw_abilities": Offseason.generated_raw_abilities(position, z_abilities),
		"arsenal": Offseason.generated_arsenal(position, z_abilities),
	}
	if position == 1:
		var neutral: Dictionary = data.duplicate(true)
		neutral["role"] = ""
		data["role"] = PitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral))
	return PSPlayer.from_dict(data)


# ---- 補助 ------------------------------------------------------------------

static func _roster_summary(players: Array) -> Dictionary:
	var summary: Dictionary = {}
	for club_id in PSFarmLeague.farm_club_ids():
		summary[int(club_id)] = roster_count(players, int(club_id))
	return summary


static func _max_player_id(players: Array) -> int:
	var max_id: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player != null:
			max_id = max(max_id, player.id)
	return max_id
