extends RefCounted
class_name FarmClubService

# ファーム専用球団 (一軍を持たない2球団) の選手供給。
#
# 専用球団は NPB 球団ではないので、支配下枠・予算・FA・契約更改・戦力外・トレード・表彰・WAR の
# どれも通らない。そのぶんロスターを維持する仕組みを自前で持つ必要がある。
#
# **ロスター像 (2026-08-16 ユーザー方針)**: 主力は **NPB を戦力外になった中堅〜ベテラン**、
# その下に NPB 未経験の若手が付く。若手の水準は**育成指名レベル**が基準で、上振れは作らない。
# 流入2チャネルがそのままこの2層に対応する。
#
# 流入は2チャネル、流出は3経路:
#
#   流入 ① 戦力外から一定数獲得 — NPB12球団の獲得フェーズが終わった後の残り物を拾う
#          (実際の受け皿としての位置づけ)。**主力の供給経路**で、目標は VETERAN_TARGET 人。
#          専用球団には枠制約が一切効かないので、目標と1オフの上限の両方で必ず縛る。
#   流入 ② 自動生成 — 育成指名レベルの若手を目標人数まで作る (下振れ寄り)。
#          ※ 初期ワールドだけは戦力外市場が存在しないので、①の層もここで作る (VETERAN_*)。
#
#   流出 ① 退団 — **年齢に依らないランダム離脱 (`DEPARTURE_RATE`) + 高齢引退 (`ATTRITION_*`)**。
#          供給元では分けない (下記の退団ブロック参照)。
#   流出 ② NPB のドラフト指名 (実装済。生成組=NPB経験なし日本人のみが対象。
#          `DraftService._farm_club_candidates` がボードへ載せる)
#   流出 ③ 7/31 までの直接移籍 (未実装。戦力外獲得組=ドラフト指名歴ありが対象)
#
# **供給元が指名資格を決める**のは実ルールがそうなっているため:
#   戦力外獲得組 = ドラフト指名歴あり → ドラフト不要で移籍できる
#   自動生成組   = NPB経験なし日本人 → ドラフト指名を受ける必要がある
# その判別のために `PSFarmLeague.SOURCE_KEY_NPB_EXPERIENCED` を立てる (DraftService が読む)。
#
# ⚠️ 補充 (`process_offseason`) は**ドラフトより後のステップ (growth) で走る**。指名で抜けた穴は
#    そのオフのうちに埋まる = 指名が専用球団を痩せさせない。
#
# 詳細は docs/agent_memory/project_farm_system_design.md。

const Offseason = preload("res://services/season/offseason_service.gd")
const Draft = preload("res://services/season/draft_service.gd")
const PitcherRoleModel = preload("res://services/simulation/models/pitcher_role_model.gd")

# 目標ロスター人数。実クラブ相当 (オイシックス新潟の2026年登録は50人)。一軍を持たず
# 二軍1チーム分を故障込みで回す規模。
const ROSTER_TARGET: int = 50

# **ロスターの性格 (2026-08-16 ユーザー方針)**: 専用球団の主力は **NPB を戦力外になった
# 中堅〜ベテラン**。NPB 未経験の生成組はその下に付く若手層で、水準は**育成指名レベル**が基準。
# 思想は「普通に有能ならこの球団に来る前に指名されているはず」 — だから生成組に上振れは作らない。
# 2チャネル (戦力外獲得 / 自動生成) の役割分担がそのままこの構図になる。
#
# 元NPB (= `npb_experienced`) の目標人数。ロスター 50 のうちこれだけを中堅〜ベテランで占め、
# 残りを生成組の若手で埋める。実測の初期ロスターは 元NPB overall p50=64 / 生成組 p50=45〜47 で、
# **評価上位10人はすべて元NPB** = 文字どおりの主力になる。
#
# ⚠️ **この人数と `VETERAN_SOURCE_PCT_*` (帯の位置) が専用球団の強さを決める最重要ノブ。**
# 生成組は指名漏れ層に固定されるので、球団が二軍リーグで成立するかはベテラン層だけが担う。
# 1シーズン実測 (seed 12345) の勝率: 22人 → .033/.114 (壊滅) / 30人 → .136 /
# **34人 → .191 (長野) / .293 (大分)**。実 NPB のファーム専用球団は 2024年で
# ハヤテ .315 / オイシックス .358 なので、勝率としては最下位2球団の妥当な帯。
#
# ⚠️ **ただし実クラブの元NPB比率は 21〜24%** (2026-08-16 調査: ハヤテ 8/38・オイシックス 11/45)
# で、34/50 = 68% は**実態と逆**。人数を強さのレバーに使っているのが原因で、
# 比率を実態へ寄せるなら**帯の位置 (`VETERAN_SOURCE_PCT_*`) 側で強さを作り直す**必要がある。
const VETERAN_TARGET: int = 12
# 1オフあたり1球団が戦力外から獲れる上限 (急な入れ替わりを避けるレート制限)。
# 目標を割っているときだけ効き、埋まっていれば獲得は止まる。
# ⚠️ 年間の離脱 (下の `DEPARTURE_RATE` + 高齢引退) は1球団あたり約8.7人で、その約7割が元NPB組。
# ここを離脱数より小さくすると**ベテラン層が毎年痩せていく**ので、余裕を持たせること
# (3シーズン実測で元NPB34人が維持されることを確認済み)。
const MAX_RELEASED_SIGNINGS_PER_CLUB: int = 12
# 戦力外獲得の年齢上限。高齢引退 (ATTRITION_START_AGE) の手前まで拾う。
const RELEASED_SIGNING_MAX_AGE: int = 32

# ---- 流出: 退団 ------------------------------------------------------------
#
# NPB の引退判定 (`OffseasonService.process_retirement`) は**一軍成績**を見るので専用球団には
# 意味を持たない。そのため専用球団は retirement ステップから除外し、ここで独自に流出させる。
#
# 抜ける理由は2つで、**どちらも供給元 (元NPB / 未経験) で分けない**:
#   ① `DEPARTURE_RATE` — **年齢に依らないランダム離脱**。専用球団は NPB の契約・年俸の枠組みの
#      外にあり、現役続行は個人の事情で決まる (引退・社会人/独立リーグへの移籍・自己都合)。
#      ロスターの年間入れ替わりが実クラブ並み (2〜3割) になる主因。
#   ② `ATTRITION_*` — 高齢による引退。START から確率が立ち上がり CERTAIN で必ず抜ける。
#
# ⚠️ 2026-08-16 に「NPB未経験者は27歳から整理が始まり32で必ず去る」= **指名されなければ消える**
#    仕様を廃止した (ユーザー指示)。在籍は指名の有無と無関係で、年齢の扱いも供給元で分けない。
#    抜けた分は戦力外の獲得 (流入①) と生成 (流入②) で補う。
#
# 実測 (初期ロスターの年齢分布・10試行) の年間離脱は **1球団あたり 8.7人 = ロスターの17%**
# (内訳: ランダム 7.7 / 高齢 1.0)。年を追うと年齢分布が上がるので高齢ぶんは増える。
# 実クラブの入れ替わり (2〜3割) よりやや緩いが、3シーズン回して**元NPB34人の構成と勝率が
# 安定する**ことを優先した値。入れ替わりを速めたいときはここを上げる
# (`MAX_RELEASED_SIGNINGS_PER_CLUB` が離脱数を下回らないよう合わせて確認すること)。
const DEPARTURE_RATE: float = 0.16
const ATTRITION_START_AGE: int = 33
const ATTRITION_CERTAIN_AGE: int = 38

# ---- 生成の基準は「その世界で実際にそうなった選手」 --------------------------
#
# ⚠️ **表示能力の固定値 (center / max_display / variance) で水準を決めるのは廃止した
#    (2026-08-16 ユーザー指示)。** 固定値は母集団が変われば意味を失い、較正が孤児になる
#    ([[feedback_cap_saturation_pattern]] と同じ罠)。基準は毎回**実測**する:
#
#      ベテラン組 (元NPB) = **実際に戦力外になる側の選手**
#      生成組 (未経験)    = **実際にドラフトで指名漏れした候補**
#
# 生成方法も「center から作る」のではなく **参照選手の z 能力を複製して少し揺らす**。
# これで水準だけでなく能力どうしの相関構造も母集団から来る (投手なら球威と制球の噛み合い等)。
# 投打で overall のスケールがずれる問題も、参照が同じ守備位置区分から来るので自然に消える。
#
# ノブは固定値ではなく **「母集団のどの帯から採るか」** (評価降順の分位点。0.0 = 母集団の最上位)。
const ABILITY_JITTER_Z: float = 0.25

# ベテラン組の参照母集団 = NPB12球団の VETERAN_MIN_AGE 以上。そのうち**評価下位の帯**が
# 「一軍から弾かれて戦力外になる側」。専用球団は市場に出た中では良い方を拾うので、
# 帯の中でも上端寄りを採る = 下位10〜20パーセンタイル。
# ※ プレイ中は流入① が**実在の戦力外選手**をそのまま獲るので、この生成は初期ワールド専用
#   (世界生成の時点では市場が存在しないため)。
const VETERAN_SOURCE_PCT_LOW: float = 0.75
const VETERAN_SOURCE_PCT_HIGH: float = 0.90
const VETERAN_MIN_AGE: int = 27
const VETERAN_MAX_AGE: int = 33

# 生成組の参照母集団 = **ドラフトで指名漏れした候補**。指名された層 (育成指名以上) は含めない。
# 専用球団は独立リーグ等から**指名漏れ組の中の良い選手を拾い上げる**立場なので、その上位帯を採る。
#
# ⚠️ **帯を広く (下へ) 取ると年1人も指名されなくなる。** 指名漏れ層は定義上ドラフトの
# 足切りより下なので、帯を下げるほど「二軍で数年育ってから指名される」だけの経路になる。
# 実測: 上位40%帯 → 初年度の指名 0人 / **上位15%帯 → 1〜3人** (足切り直下から拾うため)。
const PROSPECT_SOURCE_PCT_LOW: float = 0.00
const PROSPECT_SOURCE_PCT_HIGH: float = 0.15
# 入団までに積む育成の量 (NPB の育成環境に対する割引)。詳細は `_apply_development_years`。
const PROSPECT_DEVELOPMENT_RATE: float = 0.5
const GENERATED_MIN_AGE: int = 18
const GENERATED_MAX_AGE: int = 24

# 専用球団の年俸は固定 (NPB の年俸査定・契約更改の外)。
const SALARY: int = 400
const REGISTERED_ROSTER: String = "ファーム"

# ロスター構成。二軍戦を必ず組めるように守備位置を明示的に割り当てる
# (ドラフト候補の分布をそのまま使うと捕手や内野の頭数が保証されない)。合計 = ROSTER_TARGET。
const POSITION_QUOTA: Dictionary = {
	1: 24,  # 投手
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


# 元NPB (= 戦力外から拾った / 初期ワールドのベテラン生成) の在籍数。主力層の頭数。
static func veteran_count(players: Array, club_id: int) -> int:
	var count: int = 0
	for player_row in roster_players(players, club_id):
		if has_npb_experience(player_row as PSPlayer):
			count += 1
	return count


# 専用球団に所属する選手か。ドラフトで NPB へ移った瞬間に false になる (team_id で判定するため)。
static func is_farm_club_player(player: PSPlayer) -> bool:
	return player != null and PSFarmLeague.is_farm_club_id(player.team_id)


# NPB でのプレー経験 (= ドラフト指名歴) があるか。判定の実体は `PSFarmLeague` 側
# (`DraftService` が同じ規則を読むため。サービス同士が互いを preload しないよう domain に置く)。
static func has_npb_experience(player: PSPlayer) -> bool:
	return PSFarmLeague.has_npb_experience(player)


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
# **VETERAN_TARGET 人は元NPB相当のベテラン**として作る (プレイ中は戦力外市場から拾う層だが、
# 世界生成の時点では市場が存在しないため)。残りが NPB 未経験の若手 = 初回ドラフトの指名対象。
static func ensure_initial_rosters(players: Array, year: int) -> Dictionary:
	var generated_total: int = 0
	for club_id in PSFarmLeague.farm_club_ids():
		generated_total += _fill_to_target(
			players, int(club_id), year, INITIAL_ROSTER_SEED, VETERAN_TARGET, false
		)
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
		var reason: String = _departure_reason(player.age)
		if reason.is_empty():
			continue
		player.source_data["retired"] = true
		player.source_data["retired_age"] = player.age
		player.source_data["farm_club_released_year"] = year
		player.source_data["farm_club_departure_reason"] = reason
		player.team_id = 0
		released.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"club_id": club_id,
			"npb_experienced": has_npb_experience(player),
			"reason": reason,
		})
	return released


# 退団するか。空文字なら残留。**供給元 (元NPB / 未経験) では分けない**。
# ランダム離脱を先に引くので、若い選手でも一定確率で抜ける。
static func _departure_reason(age: int) -> String:
	if age >= ATTRITION_CERTAIN_AGE:
		return "age"
	if Rng.roll_float() < DEPARTURE_RATE:
		return "random"
	if age < ATTRITION_START_AGE:
		return ""
	var span: float = float(ATTRITION_CERTAIN_AGE - ATTRITION_START_AGE)
	var chance: float = float(age - ATTRITION_START_AGE + 1) / (span + 1.0)
	return "age" if Rng.roll_float() < chance else ""


# ---- 流入①: 戦力外からの獲得 ----------------------------------------------

# NPB の獲得フェーズを通り抜けて残った戦力外選手 (team_id==0 かつ released) を、
# 価値の高い順に球団へ交互配分する。**これが専用球団の主力の供給経路**。
# 1球団あたりの獲得数は「VETERAN_TARGET までの不足分」と MAX_RELEASED_SIGNINGS_PER_CLUB の
# 小さい方。目標が埋まっていれば1人も獲らない (残りは生成組の若手で埋める)。
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
	# 球団ごとの獲得枠 = ベテラン目標までの不足分 (1オフの上限で頭打ち)。
	var quota_by_club: Dictionary = {}
	for club_id in club_ids:
		var short_of_target: int = VETERAN_TARGET - veteran_count(players, int(club_id))
		quota_by_club[int(club_id)] = clampi(short_of_target, 0, MAX_RELEASED_SIGNINGS_PER_CLUB)

	var signings: Array = []
	var club_cursor: int = 0
	for candidate_row in candidates:
		var remaining_capacity: bool = false
		for club_id in club_ids:
			if int(quota_by_club[int(club_id)]) > 0:
				remaining_capacity = true
				break
		if not remaining_capacity:
			break

		# 空きのある球団を交互に選ぶ。
		var club_id: int = 0
		for _attempt in range(club_ids.size()):
			var candidate_club: int = int(club_ids[posmod(club_cursor, club_ids.size())])
			club_cursor += 1
			if int(quota_by_club[candidate_club]) > 0:
				club_id = candidate_club
				break
		if club_id == 0:
			break
		if roster_count(players, club_id) >= ROSTER_TARGET:
			quota_by_club[club_id] = 0
			continue

		var player: PSPlayer = candidate_row as PSPlayer
		_apply_farm_club_signing(player, club_id, year)
		quota_by_club[club_id] = int(quota_by_club[club_id]) - 1
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
	# 戦力外組はドラフト指名歴があるので、ドラフトを経ずに移籍できる側になる (= 指名対象外)。
	player.source_data[PSFarmLeague.SOURCE_KEY_NPB_EXPERIENCED] = true


# ---- 流入②: 自動生成 ------------------------------------------------------

# 目標人数まで生成する。守備位置は POSITION_QUOTA の不足分から埋め、
# 余りは投手と野手を交互に足して構成の偏りを防ぐ。
# seed_base は乱数ストリームの起点。初期ワールド生成は固定値 (INITIAL_ROSTER_SEED)、
# オフの補充はプレイ中なので `Rng.current_seed` (ワールドの seed) を使う。
# veteran_quota は元NPB相当で作る人数 (初期ワールドのみ > 0)。守備位置に偏らないよう
# wanted 全体へ等間隔に散らす — POSITION_QUOTA 順の先頭から取ると全員が投手になる。
static func _fill_to_target(
	players: Array, club_id: int, year: int, seed_base: int = 0, veteran_quota: int = 0,
	from_last_draft: bool = true
) -> int:
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
	# 能力の基準になる参照母集団を実測で切り出す (固定値は使わない。上の const ブロック参照)。
	var veteran_reference: Dictionary = _veteran_reference_pool(players) if veteran_quota > 0 else {}
	var prospect_reference: Dictionary = _prospect_reference_pool(from_last_draft)
	var next_id: int = _max_player_id(players) + 1
	var generated: int = 0
	# ベテラン枠を wanted 全体へ等間隔に配る (Bresenham 式の累積)。ちょうど veteran_quota 人になる。
	var slot_count: int = wanted.size()
	var quota: int = clampi(veteran_quota, 0, slot_count)
	var spread: int = 0
	for position_value in wanted:
		spread += quota
		var as_veteran: bool = spread >= slot_count
		if as_veteran:
			spread -= slot_count
		var reference: Dictionary = veteran_reference if as_veteran else prospect_reference
		players.append(_generate_player(next_id, int(position_value), club_id, year, as_veteran, reference))
		next_id += 1
		generated += 1
	Rng.end_game_stream()
	return generated


# ---- 能力の基準 (実測) ------------------------------------------------------
#
# 返すのは {1: [z_abilities...], 0: [z_abilities...]} (投手 / 野手)。
# 投手と野手では z のキー集合そのものが違う (投手だけ Pit_* / PF_* を持つ) ので必ず分ける。

# ベテラン組の基準 = NPB12球団で**戦力外になる側**の帯 (評価下位 VETERAN_SOURCE_PCT_*)。
static func _veteran_reference_pool(players: Array) -> Dictionary:
	var pitchers: Array = []
	var fielders: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.is_retired() or player.team_id <= 0:
			continue
		if PSFarmLeague.is_farm_club_id(player.team_id):
			continue
		if player.age < VETERAN_MIN_AGE:
			continue
		var entry: Dictionary = {"z": player.z_abilities, "v": Offseason.player_value_score(player)}
		if player.position == 1:
			pitchers.append(entry)
		else:
			fielders.append(entry)
	return {
		1: _band_of(pitchers, VETERAN_SOURCE_PCT_LOW, VETERAN_SOURCE_PCT_HIGH),
		0: _band_of(fielders, VETERAN_SOURCE_PCT_LOW, VETERAN_SOURCE_PCT_HIGH),
	}


# 生成組の基準 = **ドラフトで指名漏れした候補**の上位帯 (PROSPECT_SOURCE_PCT_*)。
# オフの補充は直近のドラフトが実際に残した未指名候補、世界生成時は候補モデルからのサンプル。
# どちらも「その世界のドラフト候補分布」から来るので、固定値には戻らない。
# ⚠️ 世界生成時に直近ドラフトを読むと**プロセスに残った前の世界の結果が混ざり非決定になる**
#    (`DraftService.undrafted_candidate_templates` のコメント参照)。
static func _prospect_reference_pool(from_last_draft: bool) -> Dictionary:
	var templates: Array = Draft.undrafted_candidate_templates(from_last_draft)
	var pitchers: Array = []
	var fielders: Array = []
	for row in templates:
		var template: Dictionary = row as Dictionary
		var z: Dictionary = template.get("z_abilities", {}) as Dictionary
		if z.is_empty():
			continue
		var entry: Dictionary = {"z": z, "v": float(template.get("grade", 0.0))}
		if int(template.get("position", 0)) == 1:
			pitchers.append(entry)
		else:
			fielders.append(entry)
	return {
		1: _band_of(pitchers, PROSPECT_SOURCE_PCT_LOW, PROSPECT_SOURCE_PCT_HIGH),
		0: _band_of(fielders, PROSPECT_SOURCE_PCT_LOW, PROSPECT_SOURCE_PCT_HIGH),
	}


# 評価降順に並べ、[low, high] の分位点帯 (0.0 = 最上位) の z だけを返す。
static func _band_of(entries: Array, low_pct: float, high_pct: float) -> Array:
	if entries.is_empty():
		return []
	entries.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["v"]) > float((b as Dictionary)["v"])
	)
	var count: int = entries.size()
	var from_index: int = clampi(int(floor(low_pct * float(count))), 0, count - 1)
	var to_index: int = clampi(int(ceil(high_pct * float(count))), from_index + 1, count)
	var band: Array = []
	for i in range(from_index, to_index):
		band.append((entries[i] as Dictionary)["z"])
	return band


# 参照帯から1人ぶんの z を引いて複製し、わずかに揺らす。帯が空なら {} (呼び出し側で扱う)。
static func _sample_z_abilities(reference: Dictionary, position: int) -> Dictionary:
	var band: Array = reference.get(1 if position == 1 else 0, []) as Array
	if band.is_empty():
		return {}
	var source: Dictionary = band[Rng.range_int(0, band.size() - 1)] as Dictionary
	var z: Dictionary = {}
	for key in source.keys():
		z[key] = float(source[key]) + (Rng.roll_float() * 2.0 - 1.0) * ABILITY_JITTER_Z
	return z


# veteran=true は元NPB相当 (初期ワールドのみ)。年齢・能力帯・`npb_experienced` が変わり、
# 指名対象から外れる = 実ルールの「指名歴がある選手はドラフトを経ずに移籍できる」側になる。
static func _generate_player(
	player_id: int, position: int, club_id: int, year: int, veteran: bool = false,
	reference: Dictionary = {}
) -> PSPlayer:
	var age: int = (
		Rng.range_int(VETERAN_MIN_AGE, VETERAN_MAX_AGE) if veteran
		else Rng.range_int(GENERATED_MIN_AGE, GENERATED_MAX_AGE)
	)
	# 能力は**参照母集団の実測**から複製する (固定の center は使わない。上の const ブロック参照)。
	var z_abilities: Dictionary = _sample_z_abilities(reference, position)
	if z_abilities.is_empty():
		# 参照が空になるのは母集団がまだ存在しない異常系だけ。世界を壊さないための保険として
		# ドラフト候補の中央値付近で作る (通常経路では通らない)。
		z_abilities = Offseason.generated_z_abilities(position, 50, 70, 8)
	# 参照が別の守備位置から来ることがあるので、捕手/遊撃の打撃テール上限を貼り直す。
	Offseason.apply_fielder_bat_spectrum_cap(z_abilities, position)
	var data: Dictionary = {
		"id": player_id,
		"sensyu_num": player_id,
		"jersey_number": 0,
		"development_player": false,
		"team_id": club_id,
		"name": NamePool.pick_japanese_name(),
		"age": age,
		"years": (age - VETERAN_MIN_AGE + 2) if veteran else 1,
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
			# 生成組は NPB 未経験 = ドラフト指名の対象 (DraftService の 6c)。
			# ベテラン組は「戦力外になって流れてきた元NPB」なので指名対象外 (実ルール準拠)。
			PSFarmLeague.SOURCE_KEY_NPB_EXPERIENCED: veteran,
		},
		"fatigue": 0,
		"injury_days": 0,
		"z_abilities": z_abilities,
		"raw_abilities": Offseason.generated_raw_abilities(position, z_abilities),
		"arsenal": Offseason.generated_arsenal(position, z_abilities),
	}
	var player: PSPlayer = PSPlayer.from_dict(data)
	if not veteran:
		_apply_development_years(player, age)
	if position == 1:
		var neutral: Dictionary = player.to_dict()
		neutral["role"] = ""
		player.role = PitcherRoleModel.role_for_player(PSPlayer.from_dict(neutral))
	return player


# 生成組の参照は「**指名漏れしたその時点**」の能力なので、そのままだと 24歳でも 18歳と同じ水準に
# なってしまう。実際に専用球団へ来るのは独立リーグ等で数年鍛えられた選手なので、
# 経過年数ぶんの育成を**ゲーム本体の成長モデルで積む** (固定の下駄は履かせない)。
# 役割判定より前に呼ぶこと — 投手の先発/救援は成長後の能力で決まるべきなので。
#
# ⚠️ `PROSPECT_DEVELOPMENT_RATE` は **NPB の育成環境に対する割引**。1.0 (=満額) にすると
# 24歳の生成組が overall 71 まで伸び、**ボード全体の最上位 (70) を超えて10人中5人が指名される**
# = 2026-08-16 に潰した「専用球団がドラフトの目玉を出す」問題が再発する (実測)。
# 「普通に有能ならこの球団に来る前に指名されている」という前提を、成長側でも守るためのノブ。
static func _apply_development_years(player: PSPlayer, target_age: int) -> void:
	var years: int = int(round(float(target_age - GENERATED_MIN_AGE) * PROSPECT_DEVELOPMENT_RATE))
	if years <= 0:
		return
	player.age = GENERATED_MIN_AGE
	for _i in range(years):
		Offseason._mutate_abilities(player)
		player.age += 1
	player.age = target_age


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
