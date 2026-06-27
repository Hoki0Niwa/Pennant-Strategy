extends RefCounted
class_name OffseasonService

const PlayerValueEvaluator = preload("res://services/simulation/player_value_evaluator.gd")
const WarCalculator = preload("res://services/reports/war_calculator.gd")

# 引退は「年齢による自然減」と「高齢かつ低稼働」を併用する。
# 出場機会を維持している選手でも40歳以降は毎年確率が上がり、48歳で必ず引退する。
# 38歳以上で役割別の少試合基準を満たす選手は、強制年齢に達する前でも引退候補になる。
const RETIREMENT_AGE_THRESHOLD: int = 38
const FORCED_RETIREMENT_RAMP_START_AGE: int = 40
const FORCED_RETIREMENT_CERTAIN_AGE: int = 48

# 自動戦力外通告(CPU/自軍ボタン共通)は、固定人数ではなくロスターの弱点に応じて放出数が変わる。
# まず高齢・少稼働の選手を常時候補にし、ロスターが厚いときだけ年齢/実績/能力の下位へ段階的に広げる。
# cut_score がキーパー水準以上の選手と若手プロスペクトは残し、CPU_ROSTER_MIN 未満には削らない。
# ここで空いた支配下枠は、ドラフトの need-driven target と後続の補強枠予約に反映される。
const CPU_ROSTER_MIN: int = 55
# これ未満の cut_score の非保護選手のみ放出対象 (= 代替が利きやすい控え以下)。以上はキーパーとして残す。
const RELEASE_KEEPER_CUT_SCORE: float = 42.0
const CPU_RELEASE_ROOKIE_PROTECTION_YEARS: int = 2
const CPU_RELEASE_PHASE1_AGE: int = 30
const CPU_RELEASE_AGE_FLOOR: int = 27
# Phase 1 の役割別「少試合」上限 (出場0も含む)。tier 0 と同じ値だが Phase 1 独立で持つ。
const CPU_RELEASE_PHASE1_STARTER_MAX: int = 3
const CPU_RELEASE_PHASE1_RELIEVER_MAX: int = 10
const CPU_RELEASE_PHASE1_FIELDER_MAX: int = 20
const CPU_RELEASE_TIERS: Array = [
	{"age": 32, "starter": 3, "reliever": 10, "fielder": 20},
	{"age": 31, "starter": 4, "reliever": 12, "fielder": 24},
	{"age": 30, "starter": 5, "reliever": 15, "fielder": 30},
	{"age": 29, "starter": 6, "reliever": 17, "fielder": 34},
	{"age": 28, "starter": 6, "reliever": 20, "fielder": 40},
	{"age": 27, "starter": 8, "reliever": 25, "fielder": 50},
]

# 戦力外プロテクト: 一定以上稼働した選手は全フェーズで保護対象 (cut 候補から除外)。
# 野手=出場試合数、先発=先発登板数、中継ぎ=救援登板数 (どちらか満たせば投手は保護)。
# 投手はリリーフ 15 登板 / 先発はその半分の 8 登板 で概ね戦力外を回避できる水準に設定。
const RELEASE_PROTECT_FIELDER_GAMES: int = 80
const RELEASE_PROTECT_STARTER_STARTS: int = 8
const RELEASE_PROTECT_RELIEVER_APPEARANCES: int = 15
# 出場数プロテクトの能力下限。総合がこれ未満なら、いくら出場しても保護しない (居座り防止)。
const RELEASE_PROTECT_MIN_OVERALL: int = 30
# 投手は「26歳以上で登板ゼロ」を最優先で戦力外にする (Phase 1 で年齢30未満でもカット)。
const CPU_RELEASE_PITCHER_NOSHOW_AGE: int = 26
# 能力プロテクトは「高能力 かつ 怪我で出場できなかった」場合のみ発動 (無条件の総合値フロアは設けない)。
const RELEASE_PROTECT_INJURY_OVERALL: int = 70
const RELEASE_PROTECT_INJURY_DAYS: int = 30

# 本職保護: 各守備位置で戦力外から守る上位人数 (overall 順)。野手 2 / 捕手 6。
const PRIMARY_PROTECT_FIELDER: int = 2
const PRIMARY_PROTECT_CATCHER: int = 6
const PRIMARY_PROTECT_MIN_OVERALL: int = 45
const RELEASE_YOUNG_PROTECT_AGE: int = 23
const RELEASE_DEVELOPMENT_PROTECT_MAX_AGE: int = 26
const RELEASE_DEVELOPMENT_PROTECT_BONUS: float = 5.0
const RELEASE_DEVELOPMENT_PROTECT_MIN_OVERALL: int = 38
const RELEASE_DEVELOPMENT_SCORE_WEIGHT: float = 5.0
const RELEASE_MIDCAREER_NOSHOW_MIN_AGE: int = 27
const RELEASE_MIDCAREER_NOSHOW_MAX_AGE: int = 32
const RELEASE_MIDCAREER_NOSHOW_MAX_OVERALL: int = 55
const RELEASE_MIDCAREER_NOSHOW_PENALTY: float = 24.0

# roadmap #3 育成制度に合わせたロスター判定 (支配下→育成 / 育成→戦力外 / 育成→支配下)。
# 「今後2〜3年の期待価値」を future_value_score に一本化し、相対値・代替差で段階判定する。
#
# 統一スコア future_value_score = 現在能力 (player_value_score)
#   + 成長期待 (expected_development_score_bonus * FUTURE_GROWTH_WEIGHT) − 故障リスク (injury_value_penalty)。
# 希少性・編成適合は本職プロテクト (_compute_primary_protected_ids) / draft の need で構造的に担保し、
# スコアには混ぜない (二重評価回避)。
const FUTURE_GROWTH_WEIGHT: float = 1.0
# 故障リスク減点: injury_days 30日ごとに ~1 点、上限 INJURY_PENALTY_CAP。恒久能力低下は既に z へ
# 反映済みなので二重減点しない (残存離脱日数の機会損失だけを軽く引く)。
const INJURY_PENALTY_PER_30D: float = 1.0
const INJURY_PENALTY_CAP: float = 6.0

# --- 支配下→育成 降格 (CPU 自動戦力外で release の代わりに振り分け) ---
# 戦力外候補 (= 現在価値が支配下水準未満) のうち、将来価値が残るなら育成降格に回す。
#  類型1 素材保持型: 育成は26歳未満の素材向け (age≤PROSPECT_MAX) で future_value が残り、成長余地がある。
#  類型2 長期故障/再調整型: 越冬で治らない長期故障 (injury_days≥LONG)。29以下は長期故障で可、
#    **30歳以上は大怪我 (重傷以上) のみ** (それより高齢=SERIOUS_MAX 超は対象外)。
const DEMOTE_PROSPECT_MAX_AGE: int = 25
const DEMOTE_MIN_FUTURE_VALUE: float = 34.0
const DEMOTE_MIN_GROWTH: float = 1.0
const DEMOTE_INJURY_LONG_MAX_AGE: int = 29
const DEMOTE_INJURY_SERIOUS_MAX_AGE: int = 31
const DEMOTE_INJURY_DAYS_LONG: int = 120
const DEMOTE_INJURY_MIN_FUTURE_VALUE: float = 40.0
# 判定のゆらぎ (5〜10%)。future_value 閾値を ±DEMOTE_JITTER 揺らし全球団が同一評価にならないように。
# marginal 層のみに効くため主力の突発降格は起きない。
const DEMOTE_JITTER: float = 0.07

# 育成→支配下 昇格 (CPU 自動): 「現在能力」value が即戦力水準に達した育成を支配下に空きがある範囲で昇格。
# 昇格は将来性ではなく「支配下で通用する準備度」= 現在能力で判断する。
# 即戦力水準は **絶対値ではなく球団ごとの相対値** (first_team_ready_threshold): 自軍の一軍相当
# (支配下を value 降順で並べた FIRST_TEAM_SIZE 番目=一軍下位レベル) と比較し、強豪は基準↑/再建は基準↓。
# PROMOTE_TO_SHIENKA_MIN_VALUE は支配下が居ない時のフォールバック基準値。
const PROMOTE_TO_SHIENKA_MIN_VALUE: int = 48
const FIRST_TEAM_SIZE: int = 31   # 一軍登録上限 (active_roster_screen ROSTER_MAX と一致)
# 相対基準のクランプ (極端化防止)。再建球団でも最低限の質を要求し、強豪でも青天井にしない。
const PROMOTE_READY_FLOOR: float = 42.0
const PROMOTE_READY_CEILING: float = 56.0

# --- 育成→戦力外 整理 (CPU 自動): 育成は人数無制限。抱え込みは枠でなく見込みベースで抑制する ---
# 在籍年数 (player.years を育成年数の代理) と出身 (高卒は猶予長め) で段階化する。
#  - 1年目 (降格/入団直後): 原則保持。
#  - 猶予年数未満: 明確に見込み薄 (future_value < FAIL ∧ 成長余地ほぼ無し) のみ放出。
#  - 猶予年数到達以降: 即戦力に届く見込み無し (future_value < 相対基準) なら放出 (厳しめ)。
#  - 別途 26歳以上の非即戦力は aged_out で優先放出。枠超過 over_cap は廃止。
const DEV_RELEASE_GRACE_HS: int = 4
const DEV_RELEASE_GRACE_OTHER: int = 3
const DEV_FAIL_FUTURE_VALUE: float = 36.0
# 育成は26歳未満の素材向け。**26歳以上で当季に支配下昇格が無ければ優先的に戦力外** にする。
# 例外: 故障リハビリ中 (injury_days≥DEMOTE_INJURY_DAYS_LONG) と、入団/降格1年目 (years<1)。
const DEV_RELEASE_AGE_LIMIT: int = 26

const POSITION_NAME_BY_ID: Dictionary = {
	1: "pitcher", 2: "catcher", 3: "first", 4: "second", 5: "third",
	6: "shortstop", 7: "left", 8: "center", 9: "right",
}

const GROWTH_KIND_AWAKENING: String = "awakening"
const GROWTH_KIND_GROWTH: String = "growth"
const GROWTH_KIND_STAGNATION: String = "stagnation"
const GROWTH_KIND_DECLINE: String = "decline"
const GROWTH_KIND_MAJOR_DECLINE: String = "major_decline"
const GROWTH_KIND_ORDER: Array = [
	GROWTH_KIND_AWAKENING,
	GROWTH_KIND_GROWTH,
	GROWTH_KIND_STAGNATION,
	GROWTH_KIND_DECLINE,
	GROWTH_KIND_MAJOR_DECLINE,
]
const GROWTH_KIND_LABELS: Dictionary = {
	"awakening": "覚醒",
	"growth": "成長",
	"stagnation": "停滞",
	"decline": "劣化",
	"major_decline": "大幅劣化",
}
# 成長/衰え時の 1 キーあたり z 変化量の一律スケール。値を上げるほどオフごとの能力の振れが大きくなる。
# z は Z_ABILITY_MIN/MAX (±4) でクランプされるため暴走しない。年齢別の成長/劣化バランス
# (_growth_kind_probabilities) は確率側で決まり、このスケールには線形なので交差年齢は変わらない。
const GROWTH_DELTA_SCALE: float = 1.8
const Z_ABILITY_MIN: float = -4.0
const Z_ABILITY_MAX: float = 4.0

# 越冬 (シーズン終了〜翌春キャンプ) で回復する怪我日数。長期離脱 (トミー・ジョン等) を
# 翌季へ正しく持ち越すための減算量。tunable (較正フェーズで調整)。詳細 [[project_injury_system]]。
const OFFSEASON_RECOVERY_DAYS: int = 120

# 守備適性のオフシーズン成長 (apply_position_aptitude_growth)。上限 100。
# 本職: 毎オフ一定値だけ習熟 (70→100 ≒6年, 85→100 ≒3年)。
# 別ポジ: そのシーズンに守った守備イニングに比例 (フル1シーズン専念 ≒ +15)。
const CAMP_PRIMARY_APTITUDE_GAIN: int = 5
const FULL_SEASON_DEF_INNINGS: float = 1287.0   # 143 試合 * 9 回
const FULL_SEASON_SECONDARY_GAIN: float = 15.0
const APTITUDE_GAIN_PER_INNING: float = FULL_SEASON_SECONDARY_GAIN / FULL_SEASON_DEF_INNINGS  # ≒0.01166
const APTITUDE_MAX: int = 100
const RAW_MAX_VELOCITY_MIN: int = 128
const RAW_MAX_VELOCITY_MAX: int = 165
# 新規生成時の球速レンジ。大半が 140〜150、155 はかなり少なく、160 は非常に稀。
# 成長による上振れは RAW_MAX_VELOCITY_MAX (=165) まで許容するが、初期生成はここに収める。
const GEN_MAX_VELOCITY_MIN: int = 140
const GEN_MAX_VELOCITY_MAX: int = 160


# --- STEP 1 (user-driven): Release ---

static func process_release(players: Array, team_id: int, player_ids: Array) -> Dictionary:
	var release_set: Dictionary = {}
	for id_value in player_ids:
		release_set[int(id_value)] = true

	var released: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not release_set.has(player.id):
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		var original_team_id: int = player.team_id
		_apply_release_mutation(player)
		released.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": original_team_id,
			"position": player.position,
			"role": player.role,
			"overall": player_value_score(player),
			"years": player.years,
			"salary": player.salary,
		})

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)

	return {
		"released": released,
		"released_count": released.size(),
	}


# --- 自動戦力外通告: CPU球団一括 ---

# CPU球団全部に対し、cut_score の低い順に target_size を超えた分を release。
# 既存の process_release と同じ mutation を適用し、結果配列を返す(同じ shape)。
static func process_cpu_releases(players: Array, teams: Array, user_team_id: int, season: PSSeason) -> Dictionary:
	var released: Array = []
	var demoted: Array = []
	var by_team_counts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if team.id == user_team_id:
			continue
		var cut_ids: Array = compute_release_candidates_for_team(players, team.id, season)
		var team_released_count: int = 0
		for pid_v in cut_ids:
			var pid: int = int(pid_v)
			var player: PSPlayer = _find_player_by_id(players, pid)
			if player == null:
				continue
			if player.team_id != team.id:
				continue
			if player.is_retired():
				continue
			var entry: Dictionary = {
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": team.id,
				"position": player.position,
				"role": player.role,
				"overall": player_value_score(player),
				"years": player.years,
				"salary": player.salary,
			}
			# roadmap #3: 若く価値の残る選手は release ではなく育成降格 (育成枠に空きがある間)。
			if _should_demote_to_development(player) and TeamFinance.has_development_room(players, team.id):
				_apply_demotion_to_development(player)
				demoted.append(entry)
			else:
				_apply_release_mutation(player)
				team_released_count += 1
				released.append(entry)
		if team_released_count > 0:
			by_team_counts[team.id] = team_released_count

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)

	return {
		"released": released,
		"released_count": released.size(),
		"demoted": demoted,
		"demoted_count": demoted.size(),
		"by_team": by_team_counts,
	}


# --- 外国人の戦力外 (通常とは別基準) ---
# 支配下 70 = 日本人 66 枠 + 外国人 4 枠。外国人は「即戦力前提の高年俸枠」なので、通常の
# 年齢・出場数ベースではなく value (能力) ベースで判定する:
#   - value 上位 FOREIGN_ROSTER_LIMIT(4) を超える外国人は放出 (枠オーバー)。
#   - value が FOREIGN_RELEASE_MIN_VALUE 未満の外国人は枠内でも放出 (当たり外れの「外れ」)。
#   - 外国人枠は即戦力前提なので、野手150PA以下 / 先発10登板以下 / 救援20登板以下の
#     低稼働シーズンも放出候補にする。
# CPU は自動。自軍は戦力外エディタの自動選択に候補として出し、確定時は選択された選手だけ切る。
const FOREIGN_ROSTER_LIMIT: int = 4
const FOREIGN_RELEASE_MIN_VALUE: int = 52
const FOREIGN_RELEASE_FIELDER_MAX_PA: int = 150
const FOREIGN_RELEASE_STARTER_MAX_STARTS: int = 10
const FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES: int = 20

static func process_foreign_releases(players: Array, teams: Array, season: PSSeason, excluded_team_id: int = 0) -> Dictionary:
	var released: Array = []
	var by_team_counts: Dictionary = {}
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null:
			continue
		if excluded_team_id > 0 and team.id == excluded_team_id:
			continue
		var team_released: int = 0
		for entry_row in _foreign_release_entries_for_team(players, team.id, season):
			var entry: Dictionary = entry_row as Dictionary
			var player: PSPlayer = entry["player"] as PSPlayer
			_apply_release_mutation(player)
			team_released += 1
			released.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": team.id,
				"position": player.position,
				"role": player.role,
				"overall": int(entry["value"]),
				"years": player.years,
				"salary": player.salary,
				"reason": str(entry.get("reason", "")),
			})
		if team_released > 0:
			by_team_counts[team.id] = team_released

	released.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
	)
	return {
		"released": released,
		"released_count": released.size(),
		"by_team": by_team_counts,
	}


static func compute_foreign_release_candidates_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var ids: Array = []
	for entry_row in _foreign_release_entries_for_team(players, team_id, season):
		var entry: Dictionary = entry_row as Dictionary
		var player: PSPlayer = entry.get("player", null) as PSPlayer
		if player != null:
			ids.append(player.id)
	return ids


static func _foreign_release_entries_for_team(players: Array, team_id: int, season: PSSeason) -> Array:
	var foreigners: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player == null or player.team_id != team_id or not player.foreign_player:
			continue
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		foreigners.append({"player": player, "value": player_value_score(player), "record": record})
	if foreigners.is_empty():
		return []
	foreigners.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["value"]) > int((b as Dictionary)["value"])
	)
	var entries: Array = []
	for i in range(foreigners.size()):
		var entry: Dictionary = foreigners[i] as Dictionary
		var player: PSPlayer = entry["player"] as PSPlayer
		var over_slot: bool = i >= FOREIGN_ROSTER_LIMIT
		var underperform: bool = int(entry["value"]) < FOREIGN_RELEASE_MIN_VALUE
		var low_usage: bool = _is_low_usage_foreign(player, entry.get("record", null) as PSPlayerSeasonRecord)
		if not (over_slot or underperform or low_usage):
			continue
		var reason: String = "低稼働"
		if over_slot:
			reason = "枠超過"
		elif underperform:
			reason = "能力不足"
		var copy: Dictionary = entry.duplicate()
		copy["reason"] = reason
		entries.append(copy)
	return entries


static func _is_low_usage_foreign(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player == null or not player.foreign_player:
		return false
	if record == null:
		return false
	if record.is_pitcher():
		if record.is_starter_pitcher():
			return record.pitcher_stats.starts <= FOREIGN_RELEASE_STARTER_MAX_STARTS
		return record.pitcher_stats.relief_appearances <= FOREIGN_RELEASE_RELIEVER_MAX_APPEARANCES
	return record.batter_stats.plate_appearances <= FOREIGN_RELEASE_FIELDER_MAX_PA


# 指定球団について戦力外候補を選んで player_ids[] を返す。
# 自軍「自動で決める」ボタンと CPU 自動戦力外 (process_cpu_releases) 共通アルゴリズム。
#
# 設計:
#  - team_count = 球団の合計人数 (retired 除外)。この値が常に「現在のチーム人数」
#  - rookie protection はドラフト入団かつ years <= ROOKIE_PROTECTION_YEARS の選手だけを
#    カット対象から外す保護フィルタであり、
#    team_count には含める (チーム合計を正しく反映するため)。これが Phase 2-4 トリガ条件と一致する。
# Phase 1 (常時): age >= 30 AND 少試合 AND years > 2 → カット
# Phase 2 (team_count > 60): tier 候補プール (years > 2) → 複合キーで切る
# Phase 3 (team_count > 60): age >= 27 (years > 2) で cut_score 下位を切る
# Phase 4 (team_count > 60): age フロアも撤廃 (years > 2 は維持) で cut_score 下位を切る
# 保護: is_retired / ドラフト入団 years <= 2 (rookie 流出防止)
static func compute_release_candidates_for_team(players: Array, team_id: int, season: PSSeason, include_foreign_release_candidates: bool = false) -> Array:
	# (1) チーム全員 (非引退非マネージャー候補) を集める。rookie protection はここでは適用しない。
	var roster_records_all: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.team_id != team_id:
			continue
		if player.is_retired():
			continue
		# roadmap #3: 育成選手は支配下枠外。戦力外候補にも 60 目標の母数にも含めない。
		if player.development_player:
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		roster_records_all.append({"player": player, "record": record})
	if roster_records_all.is_empty():
		return []

	var foreign_release_set: Dictionary = {}
	if include_foreign_release_candidates:
		for pid_v in compute_foreign_release_candidates_for_team(players, team_id, season):
			foreign_release_set[int(pid_v)] = true

	# 本職保護: 各守備位置の上位 (野手2 / 捕手6) 名を戦力外対象から除外し、球団全体で
	# 常に本職が最低数いるようにする (draft_service の本職補強と対)。
	var protected_primary_ids: Dictionary = _compute_primary_protected_ids(roster_records_all)
	# 外国人は通常の戦力外では基本的に保護する。ただし自軍自動選択では、外国人専用条件
	# (4枠超過 / 能力不足 / 低稼働) に該当する選手だけ候補に入れる。
	for row in roster_records_all:
		var fp: PSPlayer = (row as Dictionary)["player"] as PSPlayer
		if fp.foreign_player and not foreign_release_set.has(fp.id):
			protected_primary_ids[fp.id] = true

	var cut_ids: Array = []
	var cut_set: Dictionary = {}
	var team_count: int = roster_records_all.size()
	if include_foreign_release_candidates:
		for row in roster_records_all:
			var fp: PSPlayer = (row as Dictionary)["player"] as PSPlayer
			if not foreign_release_set.has(fp.id):
				continue
			cut_ids.append(fp.id)
			cut_set[fp.id] = true
			team_count -= 1

	# (2) Phase 1: 最優先カット (years > 2 のみ)。
	#   - 投手 26歳以上で登板ゼロ → 年齢30未満でも最優先カット
	#   - それ以外は従来どおり age >= 30 AND 少試合
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
		if _has_rookie_release_protection(player):
			continue
		if _is_young_development_protected(player):
			continue
		if _is_protected_from_release(player, record) or protected_primary_ids.has(player.id):
			continue
		if not _is_pitcher_noshow(player, record):
			if player.age < CPU_RELEASE_PHASE1_AGE:
				continue
			if not _has_low_appearance_phase1(record):
				continue
		if cut_set.has(player.id):
			continue
		cut_ids.append(player.id)
		cut_set[player.id] = true
		team_count -= 1

	# (3) Phase 2: ROSTER_MIN 超過時、tier プールから複合キーで切る (キーパー水準は残す)
	if team_count > CPU_ROSTER_MIN:
		var candidates: Array = []
		for row in roster_records_all:
			var data: Dictionary = row as Dictionary
			var player: PSPlayer = data["player"] as PSPlayer
			var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
			if cut_set.has(player.id):
				continue
			if _has_rookie_release_protection(player):
				continue
			if _is_young_development_protected(player):
				continue
			if _is_protected_from_release(player, record) or protected_primary_ids.has(player.id):
				continue
			if not _qualifies_for_any_tier(player, record):
				continue
			candidates.append({
				"player": player,
				"record": record,
				"zero_app": _zero_appearances(record),
				"age": player.age,
				"games": _appearance_count(record),
				"cut_score": _release_cut_score(player, record),
			})

		# 複合キー: (zero_app desc, cut_score asc) — 未出場を最優先で切り、以降は能力+実績の低い順。
		candidates.sort_custom(_phase2_sort_cmp)

		for cand_row in candidates:
			if team_count <= CPU_ROSTER_MIN:
				break
			var cand: Dictionary = cand_row as Dictionary
			# キーパー水準 (代替が利かない控え以上) は放出しない。
			if float(cand["cut_score"]) >= RELEASE_KEEPER_CUT_SCORE:
				continue
			var pid: int = int((cand["player"] as PSPlayer).id)
			if cut_set.has(pid):
				continue
			cut_ids.append(pid)
			cut_set[pid] = true
			team_count -= 1

	# (4) Phase 3 (フォールバック): age >= 27 で perf 下位を切る (years > 2, キーパー水準は残す)
	if team_count > CPU_ROSTER_MIN:
		var pool: Array = []
		for row in roster_records_all:
			var data: Dictionary = row as Dictionary
			var player: PSPlayer = data["player"] as PSPlayer
			if cut_set.has(player.id):
				continue
			if _has_rookie_release_protection(player):
				continue
			var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
			if _is_young_development_protected(player):
				continue
			if _is_protected_from_release(player, record) or protected_primary_ids.has(player.id):
				continue
			if player.age < CPU_RELEASE_AGE_FLOOR:
				continue
			pool.append({
				"player": player,
				"record": record,
				"score": _release_cut_score(player, record),
			})
		pool.sort_custom(func(a, b) -> bool:
			return float((a as Dictionary)["score"]) < float((b as Dictionary)["score"])
		)
		for cand_row in pool:
			if team_count <= CPU_ROSTER_MIN:
				break
			var cand: Dictionary = cand_row as Dictionary
			if float(cand["score"]) >= RELEASE_KEEPER_CUT_SCORE:
				break  # 昇順ソート: 以降は全てキーパー水準
			var pid: int = int((cand["player"] as PSPlayer).id)
			if cut_set.has(pid):
				continue
			cut_ids.append(pid)
			cut_set[pid] = true
			team_count -= 1

	# (5) Phase 4 (最終手段): age フロアを撤廃 (years > 2 は維持) で perf 下位を切る (キーパー水準は残す)
	if team_count > CPU_ROSTER_MIN:
		var pool: Array = []
		for row in roster_records_all:
			var data: Dictionary = row as Dictionary
			var player: PSPlayer = data["player"] as PSPlayer
			if cut_set.has(player.id):
				continue
			if _has_rookie_release_protection(player):
				continue
			var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
			if _is_young_development_protected(player):
				continue
			if _is_protected_from_release(player, record) or protected_primary_ids.has(player.id):
				continue
			pool.append({
				"player": player,
				"record": record,
				"score": _release_cut_score(player, record),
			})
		pool.sort_custom(func(a, b) -> bool:
			return float((a as Dictionary)["score"]) < float((b as Dictionary)["score"])
		)
		for cand_row in pool:
			if team_count <= CPU_ROSTER_MIN:
				break
			var cand: Dictionary = cand_row as Dictionary
			if float(cand["score"]) >= RELEASE_KEEPER_CUT_SCORE:
				break  # 昇順ソート: 以降は全てキーパー水準
			var pid: int = int((cand["player"] as PSPlayer).id)
			if cut_set.has(pid):
				continue
			cut_ids.append(pid)
			cut_set[pid] = true
			team_count -= 1

	if cut_ids.is_empty():
		return []

	# (6) UI 表示用に cut_score 昇順で並び替えて返す
	var scored: Array = []
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if not cut_set.has(player.id):
			continue
		var record: PSPlayerSeasonRecord = data["record"] as PSPlayerSeasonRecord
		scored.append({"player_id": player.id, "score": _release_cut_score(player, record)})
	scored.sort_custom(func(a, b) -> bool:
		return float((a as Dictionary)["score"]) < float((b as Dictionary)["score"])
	)
	var result_ids: Array = []
	for entry in scored:
		result_ids.append(int((entry as Dictionary)["player_id"]))
	return result_ids


# 投手 = pitcher_stats.games == 0、野手 = batter_stats.games == 0、record null も true。
static func _zero_appearances(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return true
	if record.is_pitcher():
		return record.pitcher_stats.games <= 0
	return record.batter_stats.games <= 0


# 戦力外プロテクト判定。true なら全フェーズで cut 候補から除外する。
#  (1) 出場数プロテクト: 野手 games / 先発 starts / 中継ぎ relief_appearances が基準以上。
#      投手は starts か relief_appearances のどちらかを満たせば保護 (スイングマンも救済)。
#      **ただし能力下限 (総合 >= RELEASE_PROTECT_MIN_OVERALL) を満たす場合のみ**。
#      消去法で出続けるだけの能力一桁の老選手が「出場数で保護され続けて居座る」ループを防ぐ。
#  (2) 能力プロテクト: 高能力 (表示総合値 >= 閾値) かつ 累積怪我日数が閾値以上のときのみ。
#      = 本来レギュラー級だが怪我で出場が伸びなかった選手を救済。怪我無しの低出場控えは保護しない。
static func _is_protected_from_release(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return false
	var overall: int = player_value_score(player)
	# (1) 出場数プロテクト (能力下限を満たす場合のみ)
	if overall >= RELEASE_PROTECT_MIN_OVERALL:
		if record.is_pitcher():
			if record.pitcher_stats.starts >= RELEASE_PROTECT_STARTER_STARTS:
				return true
			if record.pitcher_stats.relief_appearances >= RELEASE_PROTECT_RELIEVER_APPEARANCES:
				return true
		elif record.batter_stats.games >= RELEASE_PROTECT_FIELDER_GAMES:
			return true
	# (2) 怪我ゲート能力プロテクト (高能力かつ累積怪我)
	if record.season_injury_days >= RELEASE_PROTECT_INJURY_DAYS:
		if overall >= RELEASE_PROTECT_INJURY_OVERALL:
			return true
	return false


static func _is_young_development_protected(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.age <= RELEASE_YOUNG_PROTECT_AGE:
		return true
	if player.age > RELEASE_DEVELOPMENT_PROTECT_MAX_AGE:
		return false
	var overall: int = player_value_score(player)
	if overall < RELEASE_DEVELOPMENT_PROTECT_MIN_OVERALL:
		return false
	return expected_development_score_bonus(player.age, 6, player.position) >= RELEASE_DEVELOPMENT_PROTECT_BONUS


static func _has_rookie_release_protection(player: PSPlayer) -> bool:
	if player == null:
		return false
	if player.years > CPU_RELEASE_ROOKIE_PROTECTION_YEARS:
		return false
	if player.foreign_player:
		return false
	var source: Dictionary = player.source_data
	if bool(source.get("draft_candidate", false)):
		return true
	if source.has("draft_year") or source.has("draft_year_round") or source.has("draft_overall_pick"):
		return true
	return player.draft_round > 0 and not bool(source.get("foreign_scout", false)) and not bool(source.get("fa_signed_year", false))


static func _release_cut_score(player: PSPlayer, record: PSPlayerSeasonRecord) -> float:
	var score: float = TeamAutoAI.cut_score(player, record)
	var development_bonus: float = expected_development_score_bonus(player.age, 6, player.position)
	if player.age <= RELEASE_DEVELOPMENT_PROTECT_MAX_AGE:
		score += development_bonus * RELEASE_DEVELOPMENT_SCORE_WEIGHT
	var overall: int = player_value_score(player)
	if player.age >= RELEASE_MIDCAREER_NOSHOW_MIN_AGE and player.age <= RELEASE_MIDCAREER_NOSHOW_MAX_AGE:
		if overall <= RELEASE_MIDCAREER_NOSHOW_MAX_OVERALL and _zero_appearances(record):
			score -= RELEASE_MIDCAREER_NOSHOW_PENALTY
	return score


# 各守備位置の本職 (primary position) 上位 N 名 (overall 順) を戦力外保護する。
# 野手は各位置 2 名、捕手は 6 名。これにより球団全体で常に本職が最低数残るよう保証する
# (在籍数がそれ未満ならいる全員を保護)。draft_service の本職補強 (_primary_position_need_bonus) と対。
static func _compute_primary_protected_ids(roster_records_all: Array) -> Dictionary:
	var by_position: Dictionary = {}
	for row in roster_records_all:
		var data: Dictionary = row as Dictionary
		var player: PSPlayer = data["player"] as PSPlayer
		if player == null or player.is_pitcher():
			continue
		var pos: int = player.position
		if not by_position.has(pos):
			by_position[pos] = []
		(by_position[pos] as Array).append({"id": player.id, "overall": player_value_score(player), "age": player.age})
	var protected: Dictionary = {}
	for pos in by_position.keys():
		var arr: Array = by_position[pos] as Array
		arr.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary)["overall"]) > int((b as Dictionary)["overall"])
		)
		var keep: int = PRIMARY_PROTECT_CATCHER if int(pos) == 2 else PRIMARY_PROTECT_FIELDER
		for i in range(min(keep, arr.size())):
			var entry: Dictionary = arr[i] as Dictionary
			# 在籍数が最低数以下なら全員を守る。余裕がある位置では、低能力の中堅を
			# 「本職人数だけ」で固定保護せず、若手か一定以上の現在価値がある選手に絞る。
			if arr.size() <= keep or int(entry.get("overall", 0)) >= PRIMARY_PROTECT_MIN_OVERALL or int(entry.get("age", 99)) <= RELEASE_YOUNG_PROTECT_AGE:
				protected[int(entry["id"])] = true
	return protected


# 投手 26歳以上で今季登板ゼロか。Phase 1 で年齢30未満でも最優先カットするための判定。
# record null (今季記録なし=登板ゼロ) でも投手かつ26歳以上なら true。
static func _is_pitcher_noshow(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player.age < CPU_RELEASE_PITCHER_NOSHOW_AGE:
		return false
	if record == null:
		return player.is_pitcher()
	if not record.is_pitcher():
		return false
	return record.pitcher_stats.games <= 0


# Phase 1 の「少試合」判定。record null も true (出場ゼロ扱い)。
# 役割別: 先発 starts ≤ 3、リリーフ games ≤ 10、野手 games ≤ 20。
static func _has_low_appearance_phase1(record: PSPlayerSeasonRecord) -> bool:
	if record == null:
		return true
	if record.is_pitcher():
		if record.is_starter_pitcher():
			return record.pitcher_stats.starts <= CPU_RELEASE_PHASE1_STARTER_MAX
		return record.pitcher_stats.games <= CPU_RELEASE_PHASE1_RELIEVER_MAX
	return record.batter_stats.games <= CPU_RELEASE_PHASE1_FIELDER_MAX


# tier 表の少なくとも 1 段で (age 下限 AND role-games 上限) を満たすか。
# (= 最も緩い tier に該当するか) 該当しない選手は Phase 2 候補プールに入らない。
static func _qualifies_for_any_tier(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	if player.age < CPU_RELEASE_AGE_FLOOR:
		return false
	var role: String = _player_role(record)
	var games: int = _appearance_count(record) if role != "starter" else _starts_count(record)
	for tier_row in CPU_RELEASE_TIERS:
		var tier: Dictionary = tier_row as Dictionary
		if player.age < int(tier.get("age", 0)):
			continue
		var max_games: int = int(tier.get(role, 0))
		if games <= max_games:
			return true
	return false


# 役割文字列 "starter" / "reliever" / "fielder"
static func _player_role(record: PSPlayerSeasonRecord) -> String:
	if record == null:
		return "fielder"
	if record.is_pitcher():
		return "starter" if record.is_starter_pitcher() else "reliever"
	return "fielder"


# Phase 2 ソート用の出場試合数。投手も野手も games を返す。
static func _appearance_count(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	if record.is_pitcher():
		return record.pitcher_stats.games
	return record.batter_stats.games


# 先発投手用の先発登板数 (tier 判定で使う)
static func _starts_count(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	if record.is_pitcher():
		return record.pitcher_stats.starts
	return 0


# 複合ソート用比較。a が先頭側 (=先に切られるべき) ならば true。
# 優先度: zero_app True が先 (シーズン通して未出場) → cut_score 小が先 (能力+実績が低い順)。
# 旧実装は age/games のみで能力を無視していたため、高総合値の低出場選手が先に切られていた。
static func _phase2_sort_cmp(a: Dictionary, b: Dictionary) -> bool:
	var az: bool = bool(a.get("zero_app", false))
	var bz: bool = bool(b.get("zero_app", false))
	if az != bz:
		return az  # True が前
	return float(a.get("cut_score", 0.0)) < float(b.get("cut_score", 0.0))


static func _find_player_by_id(players: Array, pid: int) -> PSPlayer:
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.id == pid:
			return player
	return null


static func _apply_release_mutation(player: PSPlayer) -> void:
	player.source_data["released"] = true
	player.source_data["retired"] = true
	player.source_data["retired_age"] = player.age
	player.team_id = 0


# roadmap #3: 育成降格。release せず育成選手化し、支配下枠を空けつつ org に残す。
# team_id は維持 (引退/release と異なる)。一軍登録不可・成長/怪我は通常どおり。
static func _apply_demotion_to_development(player: PSPlayer) -> void:
	player.development_player = true
	player.registered_roster = "育成"


# CPU 自動: 戦力外候補のうち、若く一定の価値が残る選手を育成降格に回すか判定。
# roadmap #3: 戦力外候補のうち、release ではなく育成降格に回すべきか判定する。
# 現在価値が支配下水準未満 (= 戦力外候補に挙がっている) 前提で、将来価値が残るなら育成へ。
# 類型1 素材保持型 / 類型2 長期故障・再調整型。いずれか成立で true。
# (ベテラン実績者は戦力外プロテクトで候補に来ないため、自然と降格対象から外れる。)
# 育成枠の空きは呼び出し側 (process_cpu_releases / has_development_room) で確認済み。
static func _should_demote_to_development(player: PSPlayer) -> bool:
	if player == null or player.foreign_player:
		return false
	var future_value: float = future_value_score(player)
	# 全球団が同一評価にならないよう、比較閾値を ±DEMOTE_JITTER 揺らす (marginal 層のみ)。
	var jitter: float = 1.0 + (Rng.roll_float() - 0.5) * 2.0 * DEMOTE_JITTER
	# 類型1: 素材保持型 (26歳未満・将来価値あり・まだ成長余地)。
	if player.age <= DEMOTE_PROSPECT_MAX_AGE:
		if future_value >= DEMOTE_MIN_FUTURE_VALUE * jitter:
			if expected_development_score_bonus(player.age, 6, player.position) >= DEMOTE_MIN_GROWTH:
				return true
	# 類型2: 長期故障 / 再調整型 (越冬で治らない長期故障で、復帰すれば戦力)。
	# 29歳以下は長期故障で降格可。30歳以上は大怪我 (重傷以上) のみ (それ以上の高齢は対象外)。
	if player.injury_days >= DEMOTE_INJURY_DAYS_LONG and future_value >= DEMOTE_INJURY_MIN_FUTURE_VALUE * jitter:
		if player.age <= DEMOTE_INJURY_LONG_MAX_AGE:
			return true
		if player.age <= DEMOTE_INJURY_SERIOUS_MAX_AGE and _is_serious_injury(player):
			return true
	return false


# 大怪我 (重傷=シーズン終了級 以上) か。明示 severity が無い旧データは日数から推定する。
static func _is_serious_injury(player: PSPlayer) -> bool:
	if player == null or player.injury_days <= 0:
		return false
	var severity: int = player.injury_severity
	if severity <= 0:
		severity = PSInjuryModel.severity_from_days(player.injury_days)
	return severity >= PSInjuryModel.TIER_MAJOR


# 育成整理での保護判定。「今なお育成保持に値するプロスペクト」なら failed_prospect 放出しない。
# _should_demote_to_development と同じ基準 (jitter 抜き) を使い、降格した選手が同オフに即放出される
# のを防ぐ (=「降格年の保持」を構造的に担保)。
static func _is_viable_development_prospect(player: PSPlayer, fv: float) -> bool:
	if player == null:
		return false
	# 素材保持型: 若く・将来価値があり・まだ成長余地がある。
	if player.age <= DEMOTE_PROSPECT_MAX_AGE and fv >= DEMOTE_MIN_FUTURE_VALUE:
		if expected_development_score_bonus(player.age, 6, player.position) >= DEMOTE_MIN_GROWTH:
			return true
	# 故障回復待ち: まだ離脱中で復帰すれば戦力。
	if player.injury_days > 0 and player.age <= DEMOTE_INJURY_SERIOUS_MAX_AGE and fv >= DEMOTE_INJURY_MIN_FUTURE_VALUE:
		return true
	return false


# 出身が高卒か (育成放出の猶予年数を長くする)。生成選手は source_data["draft_source"]、
# 初期シードはデビュー年齢から PSPlayer.default_fa_eligible_years が推定する (==8 が高卒)。
static func _is_high_school_origin(player: PSPlayer) -> bool:
	if player == null:
		return false
	var eligible: int = PSPlayer.default_fa_eligible_years(player.foreign_player, player.age, player.years, player.source_data)
	return eligible == PSPlayer.FA_ELIGIBLE_YEARS_HIGH_SCHOOL


# roadmap #3: 支配下登録 (昇格)。育成選手を支配下に戻す。一軍登録可・70枠を消費する。
static func _apply_promotion_to_shienka(player: PSPlayer) -> void:
	player.development_player = false
	player.registered_roster = "支配下"


# CPU 自動: 育成選手のうち value が閾値以上の者を、支配下に空きがある範囲で昇格する。
# excluded_team_id (自軍) は対話プレイではユーザーが手動昇格するため除外する。
static func process_development_promotions(players: Array, teams: Array, excluded_team_id: int = 0) -> Dictionary:
	var promoted: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == excluded_team_id:
			continue
		# 即戦力基準は球団ごとの相対値 (一軍下位レベル)。1度だけ算出して使い回す。
		var ready_threshold: float = first_team_ready_threshold(players, team.id)
		var devs: Array = []
		for player_row in players:
			var player: PSPlayer = player_row as PSPlayer
			if player == null or player.team_id != team.id:
				continue
			if player.is_retired() or not player.development_player:
				continue
			if float(player_value_score(player)) < ready_threshold:
				continue
			devs.append(player)
		devs.sort_custom(func(a, b) -> bool:
			return player_value_score(a as PSPlayer) > player_value_score(b as PSPlayer)
		)
		for dev_row in devs:
			var dev: PSPlayer = dev_row as PSPlayer
			# オフの自動昇格は soft 目標 (67) で止め、シーズン中の昇格用に枠を残す。
			if not TeamFinance.has_shienka_soft_room(players, team.id):
				break
			_apply_promotion_to_shienka(dev)
			promoted.append({
				"player_id": dev.id,
				"name": dev.name,
				"age": dev.age,
				"team_id": team.id,
				"position": dev.position,
				"role": dev.role,
				"overall": player_value_score(dev),
				"years": dev.years,
				"salary": dev.salary,
			})
	return {
		"promoted": promoted,
		"promoted_count": promoted.size(),
	}


# CPU 自動: 育成選手の整理 (pipeline 循環)。放出 = 26歳以上で当季昇格無し (aged_out) /
# 失敗プロスペクト (在籍年数が出身別猶予を超え昇格見込み無し)。育成は人数無制限 = 枠超過 over_cap は廃止。
# 1年目とリハビリ中、26歳未満の viable な素材/故障回復待ち、即戦力は保持。昇格処理の直後に実行。
static func process_development_releases(players: Array, teams: Array, excluded_team_id: int = 0) -> Dictionary:
	var released: Array = []
	for team_row in teams:
		var team: PSTeam = team_row as PSTeam
		if team == null or team.id == excluded_team_id:
			continue
		var devs: Array = []
		for player_row in players:
			var player: PSPlayer = player_row as PSPlayer
			if player == null or player.team_id != team.id:
				continue
			if player.is_retired() or not player.development_player:
				continue
			devs.append(player)
		# 即戦力基準は球団ごとの相対値 (一軍下位レベル)。1度だけ算出して使い回す。
		var ready_threshold: float = first_team_ready_threshold(players, team.id)
		for dev_row in devs:
			var dev: PSPlayer = dev_row as PSPlayer
			var fv: float = future_value_score(dev)
			# 育成は人数無制限 (枠数による over_cap 整理は廃止)。抱え込みは下記の放出条件で抑制する。
			# 26歳以上で当季に支配下昇格が無ければ優先放出 (育成は26歳未満の素材向け)。
			# ただし除外: 入団/降格1年目・リハビリ中・**即戦力 (自軍一軍と比べた相対基準以上)**。
			# 即戦力の育成は満枠で昇格できなかっただけなので、シーズン中昇格用に保持する (放出しない)。
			var aged_out: bool = (
				dev.age >= DEV_RELEASE_AGE_LIMIT
				and dev.years >= 1
				and dev.injury_days < DEMOTE_INJURY_DAYS_LONG
				and float(player_value_score(dev)) < ready_threshold
			)
			var failed_prospect: bool = false
			if not aged_out and not _is_viable_development_prospect(dev, fv):
				# 在籍年数 (育成年数の代理) と出身で猶予を変える。高卒は猶予長め。
				var grace: int = DEV_RELEASE_GRACE_HS if _is_high_school_origin(dev) else DEV_RELEASE_GRACE_OTHER
				var growth: float = expected_development_score_bonus(dev.age, 6, dev.position)
				if dev.years <= 1:
					# 1年目 (降格/入団直後) は原則保持。
					failed_prospect = false
				elif dev.years >= grace:
					# 猶予到達以降: 即戦力に届く見込み無し (将来価値が相対基準未満) なら放出 (厳しめ)。
					failed_prospect = fv < ready_threshold
				else:
					# 猶予未満: 明確に見込み薄 (将来価値が下限割れ かつ 成長余地ほぼ無し) のみ放出。
					failed_prospect = fv < DEV_FAIL_FUTURE_VALUE and growth < DEMOTE_MIN_GROWTH
			if not aged_out and not failed_prospect:
				continue
			_apply_release_mutation(dev)
			released.append({
				"player_id": dev.id,
				"name": dev.name,
				"age": dev.age,
				"team_id": team.id,
				"position": dev.position,
				"role": dev.role,
				"overall": player_value_score(dev),
				"years": dev.years,
				"salary": dev.salary,
			})
	return {
		"released": released,
		"released_count": released.size(),
	}


# 自軍の指定選手を育成降格する (戦力外エディタの「育成降格」選択)。育成は人数無制限なので枠制限なし。
static func process_demotion(players: Array, team_id: int, player_ids: Array) -> Dictionary:
	var demote_set: Dictionary = {}
	for id_value in player_ids:
		demote_set[int(id_value)] = true

	var demoted: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if not demote_set.has(player.id):
			continue
		if player.team_id != team_id:
			continue
		if player.is_retired() or player.development_player:
			continue
		_apply_demotion_to_development(player)
		demoted.append({
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": team_id,
			"position": player.position,
			"role": player.role,
			"overall": player_value_score(player),
			"years": player.years,
			"salary": player.salary,
		})

	return {
		"demoted": demoted,
		"demoted_count": demoted.size(),
	}


# --- 引退 (Step 0): 年齢 + 出場ベース ---
# 38歳以上で「役割別少試合」(戦力外 Phase 1 と同じ基準) を満たす選手を引退。
# 強制引退 (hard age) は無し。試合に出続ける限り何歳でも続行。

static func process_retirement(players: Array, season: PSSeason) -> Dictionary:
	var retired: Array = []
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		if _should_retire(player, record):
			# 引退表示のため元の所属を捕捉してから team_id をクリア。
			# _apply_release_mutation (戦力外側) と対称な扱いにすることで、
			# team_id == X で集計する画面に引退選手が残らないようにする。
			var original_team_id: int = player.team_id
			player.source_data["retired"] = true
			player.source_data["retired_age"] = player.age
			player.team_id = 0
			retired.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": original_team_id,
				"position": player.position,
				"role": player.role,
				"overall": player_value_score(player),
				"years": player.years,
			})

	retired.sort_custom(func(a, b) -> bool:
		var data_a: Dictionary = a as Dictionary
		var data_b: Dictionary = b as Dictionary
		if int(data_a["team_id"]) == int(data_b["team_id"]):
			return int(data_a["age"]) > int(data_b["age"])
		return int(data_a["team_id"]) < int(data_b["team_id"])
	)

	return {
		"retired": retired,
		"retired_count": retired.size(),
	}


static func _should_retire(player: PSPlayer, record: PSPlayerSeasonRecord) -> bool:
	# (1) 段階的強制引退: 40歳から確率上昇、48歳で確実。出場数に関係なく適用。
	if player.age >= FORCED_RETIREMENT_CERTAIN_AGE:
		return true
	if player.age >= FORCED_RETIREMENT_RAMP_START_AGE:
		if Rng.roll_float() < _forced_retirement_chance(player.age):
			return true
	# (2) 少出場引退: 38歳以上 かつ 役割別少試合。
	if player.age < RETIREMENT_AGE_THRESHOLD:
		return false
	return _has_low_appearance_phase1(record)


# 段階的強制引退の確率。39歳以下=0、40歳から線形に上昇し48歳で1.0(確実)。
# 例: 40=0.11, 42=0.33, 44=0.56, 46=0.78, 48=1.0。期待引退年齢 ≒ 44。
static func _forced_retirement_chance(age: int) -> float:
	if age < FORCED_RETIREMENT_RAMP_START_AGE:
		return 0.0
	if age >= FORCED_RETIREMENT_CERTAIN_AGE:
		return 1.0
	return clampf(float(age - (FORCED_RETIREMENT_RAMP_START_AGE - 1)) / float(FORCED_RETIREMENT_CERTAIN_AGE - (FORCED_RETIREMENT_RAMP_START_AGE - 1)), 0.0, 1.0)


static func player_value_score(player: PSPlayer) -> int:
	if player == null:
		return 0
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.from_player(player, 0, 0)
	return PlayerValueEvaluator.overall_score(record)


# 「今後2〜3年の期待価値」を 1 スカラーに統一したスコア。
# = 現在能力 + 成長期待 (年齢ベース) − 故障リスク。育成降格 / 育成整理の判定軸に使う。
# 出場ベースの戦力外 *選定* (compute_release_candidates_for_team) はこれを使わず従来どおり
# (主力を1年の不振で切らない方針を維持)。
static func future_value_score(player: PSPlayer) -> float:
	if player == null:
		return 0.0
	var current: float = float(player_value_score(player))
	var growth: float = expected_development_score_bonus(player.age, 6, player.position) * FUTURE_GROWTH_WEIGHT
	return current + growth - injury_value_penalty(player)


# 即戦力 (支配下昇格相当) の球団別**相対**基準。支配下 (非育成・非引退) を value 降順に並べ、
# 一軍枠 FIRST_TEAM_SIZE 番目 (= 一軍下位レベル) の value を基準にする。育成の value がこれ以上なら
# 「自軍の一軍選手たちと比べて即戦力」。支配下が枠数未満なら最弱の value。floor/ceiling でクランプ。
# 同オフの昇格/降格判定中は球団構成がほぼ不変なので、各 process_* で球団ごとに1度算出して使い回す。
static func first_team_ready_threshold(players: Array, team_id: int) -> float:
	var values: Array = []
	for player_row in players:
		var p: PSPlayer = player_row as PSPlayer
		if p == null or p.team_id != team_id:
			continue
		if p.is_retired() or p.development_player:
			continue
		values.append(player_value_score(p))
	if values.is_empty():
		return float(PROMOTE_TO_SHIENKA_MIN_VALUE)
	values.sort()  # 昇順
	# 上位 FIRST_TEAM_SIZE の最下位 = 昇順 index (size - FIRST_TEAM_SIZE)。
	var idx: int = max(0, values.size() - FIRST_TEAM_SIZE)
	return clampf(float(values[idx]), PROMOTE_READY_FLOOR, PROMOTE_READY_CEILING)


# 故障リスク減点。残存離脱日数 (injury_days) 30日ごとに ~1 点、上限 INJURY_PENALTY_CAP。
# 恒久能力低下は既に z 能力へ反映済みなので二重減点しない。
static func injury_value_penalty(player: PSPlayer) -> float:
	if player == null or player.injury_days <= 0:
		return 0.0
	return min(float(player.injury_days) / 30.0 * INJURY_PENALTY_PER_30D, INJURY_PENALTY_CAP)


static func development_kind_label(kind: String) -> String:
	return str(GROWTH_KIND_LABELS.get(kind, kind))


static func expected_development_score_bonus(age: int, horizon: int = 6, _position: int = 0) -> float:
	var total: float = 0.0
	var future_weight: float = 1.0
	for offset in range(max(0, horizon)):
		var projected_age: int = age + offset
		var probabilities: Dictionary = _growth_kind_probabilities(projected_age)
		var year_bonus: float = 0.0
		year_bonus += float(probabilities.get(GROWTH_KIND_AWAKENING, 0.0)) * 8.0
		year_bonus += float(probabilities.get(GROWTH_KIND_GROWTH, 0.0)) * 2.6
		year_bonus -= float(probabilities.get(GROWTH_KIND_DECLINE, 0.0)) * 2.0
		year_bonus -= float(probabilities.get(GROWTH_KIND_MAJOR_DECLINE, 0.0)) * 6.0
		total += (year_bonus / 100.0) * future_weight
		future_weight *= 0.86
	return clamp(total, -8.0, 12.0)


static func generated_z_abilities(position: int, center: int, max_display: int = 88, ability_variance: int = 12) -> Dictionary:
	var z: Dictionary = {}
	var batting_center: int = center - 12 if position == 1 else center
	var core_variance: int = max(1, ability_variance)
	var secondary_variance: int = max(1, ability_variance - 2)
	var style_variance: int = max(1, ability_variance - 4)
	z["Bat_KAvoid"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_BBCreate"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Impact"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Loft"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Barrel"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Bat_Spray"] = _rand_z(batting_center, secondary_variance, 25, max_display)
	z["Bat_Aggression"] = _rand_z(50, style_variance, 25, max_display)
	z["Bat_Platoon"] = _rand_z(50, style_variance, 25, max_display)

	z["Run_Speed"] = _rand_z(batting_center + 5, core_variance, 25, max_display)
	z["Run_Judgment"] = _rand_z(batting_center, core_variance, 25, max_display)
	z["Run_Steal"] = _rand_z(batting_center, core_variance, 25, max_display)

	if position == 1:
		z["Pit_KCreate"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_BBPrevent"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_ImpactLimit"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_LoftControl"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_BarrelDeny"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_Efficiency"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_Stamina"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_FatigueResist"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_HoldRunner"] = _rand_z(center, core_variance, 25, max_display)
		z["Pit_EdgeRate"] = _rand_z(50, style_variance, 25, max_display)
		z["PF_Reach"] = _rand_z(center, secondary_variance, 25, max_display)
		z["PF_Secure"] = _rand_z(center, secondary_variance, 25, max_display)
		z["PF_Throw"] = _rand_z(center, secondary_variance, 25, max_display)

	z["C_Framing"] = _rand_z(center, core_variance, 25, max_display)
	z["C_Blocking"] = _rand_z(center, core_variance, 25, max_display)
	z["C_Throw"] = _rand_z(center, core_variance, 25, max_display)
	z["C_GameCall"] = _rand_z(center, secondary_variance, 25, max_display)
	z["C_FieldSecure"] = _rand_z(center, core_variance, 25, max_display)

	z["IF_Reach"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_Secure"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_ThrowPower"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_ThrowAccuracy"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_Exchange"] = _rand_z(center, core_variance, 25, max_display)
	z["IF_PositionFit"] = _rand_z(center, secondary_variance, 25, max_display)

	z["OF_Reach"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Route"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Secure"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_ArmPower"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_ArmAccuracy"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_Release"] = _rand_z(center, core_variance, 25, max_display)
	z["OF_PositionFit"] = _rand_z(center, secondary_variance, 25, max_display)
	return z


static func generated_raw_abilities(position: int, z_abilities: Dictionary) -> Dictionary:
	var raw: Dictionary = {}
	if position != 1:
		return raw
	raw["max_velocity"] = _generated_max_velocity_from_z(z_abilities)
	return raw


# 投手の変化球アーセナルを生成する。[{ "type": <String>, "mastery": <float z> }, ...]。
#  - 球種数: 持久(=先発度)が高いほど多い (3〜6本)。
#  - 直球を必ず1本含み、残りは投手リーン(K vs ムーブ)に応じた変化球から割当 (PSPitchTypes.assign_types)。
#  - mastery は投手の stuff 系 z (KCreate/BarrelDeny/EdgeRate) にアンカーしノイズを足す
#    (→ エースは良い球種を持ちやすく z と矛盾しない)。スケールは synth mastery と同じ [-2.0, 2.8]。
static func generated_arsenal(position: int, z_abilities: Dictionary) -> Array:
	if position != 1:
		return []
	var k: float = float(z_abilities.get("Pit_KCreate", 0.0))
	var move: float = float(z_abilities.get("Pit_LoftControl", 0.0))
	var barrel_deny: float = float(z_abilities.get("Pit_BarrelDeny", 0.0))
	var edge: float = float(z_abilities.get("Pit_EdgeRate", 0.0))
	var stamina: float = float(z_abilities.get("Pit_Stamina", 0.0))
	# 球種数: 持久連動 (z 0 で約4本、先発級で5〜6、短いリリーフで3) + 軽いジッター。
	var pitch_count: int = clampi(int(round(4.0 + stamina * 0.7 + float(Rng.range_int(-1, 1)))), 3, 6)
	var lean: float = k - move
	var types: Array = PSPitchTypes.assign_types(pitch_count, lean, Rng.range_int(0, 1000000))
	# 出し球(0本目)を最良に、以降は逓減。mastery は stuff 系 z にアンカー。
	var anchor: float = k * 0.5 + barrel_deny * 0.3 + edge * 0.2
	var arsenal: Array = []
	for i in range(pitch_count):
		var noise: float = (Rng.roll_float() - 0.5) * 0.9
		var mastery: float = anchor + 0.35 - float(i) * 0.5 + noise
		arsenal.append({
			"type": str(types[i]) if i < types.size() else PSPitchTypes.FOUR_SEAM,
			"mastery": clampf(mastery, -2.0, 2.8),
		})
	return arsenal


# --- 怪我の繰り越し (越冬回復) ---

# オフシーズンの怪我繰り越し: 当季終了時点の record.injury_days から越冬回復分 (OFFSEASON_RECOVERY_DAYS)
# を引き、残りを持続 player へ書き戻す。翌季の PSPlayerSeasonRecord.from_player が
# injury_days / injury_type / injury_severity をシードするので、長期離脱が翌季へ持ち越される。
# 恒久能力低下は発生時 (PSInjuryModel) に適用済みのため、ここは怪我状態の簿記のみ。
static func process_injury_carryover(players: Array, season: PSSeason) -> Dictionary:
	if season == null:
		return {"carried": 0}
	var carried: int = 0
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
		var current_days: int = record.injury_days if record != null else player.injury_days
		var remaining: int = maxi(0, current_days - OFFSEASON_RECOVERY_DAYS)
		player.injury_days = remaining
		if remaining > 0:
			carried += 1
			if record != null:
				player.injury_type = record.injury_type
				player.injury_severity = record.injury_severity
		else:
			player.injury_type = ""
			player.injury_severity = 0
	return {"carried": carried}


# --- STEP 2: Growth / Decay ---

# 全選手を成長/衰え mutate する。集計 (changes/kind_counts/growers/decayers/pitchers/fielders) は
# user_team_id でスコープを絞る:
#   user_team_id <= 0: 全球団を集計 (= 旧挙動。長期オートプレイ等のレポート用呼び出しと後方互換)
#   user_team_id  > 0: その球団のみ集計し、各選手の表示能力 before/after を abilities[] に持たせる
static func process_growth_decay(players: Array, user_team_id: int = 0, season: PSSeason = null) -> Dictionary:
	var want_abilities: bool = user_team_id > 0
	var changes: Array = []
	var kind_counts: Dictionary = _empty_growth_kind_counts()
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		var aggregated: bool = user_team_id <= 0 or player.team_id == user_team_id
		var before: int = 0
		var before_ratings: Dictionary = {}
		var before_pitch_changes: Array = []
		var before_aptitudes: Dictionary = {}
		if aggregated:
			before = player_value_score(player)
			if want_abilities:
				before_ratings = _capture_display_ratings(player)
				if player.is_pitcher():
					before_pitch_changes = _capture_pitch_mastery_values(player)
				else:
					before_aptitudes = _capture_position_aptitude_values(player)
		var mutation: Dictionary = _mutate_abilities(player)
		# 守備適性の成長 (本職キャンプ + 試合イニング)。season から当該シーズンの record を引いて
		# 守備イニングを参照する。season 無し (レポート/smoke 等) では適性成長はスキップ。
		if season != null:
			var apt_record: PSPlayerSeasonRecord = RecordStore.get_player_record(player.id, season.year, season.season_number)
			apply_position_aptitude_growth(player, apt_record)
		if not aggregated:
			continue
		var growth_kind: String = str(mutation.get("kind", GROWTH_KIND_STAGNATION))
		kind_counts[growth_kind] = int(kind_counts.get(growth_kind, 0)) + 1
		var after: int = player_value_score(player)
		var pitch_changes: Array = []
		var aptitude_changes: Dictionary = {}
		if want_abilities:
			if player.is_pitcher():
				pitch_changes = _build_pitch_mastery_changes(before_pitch_changes, _capture_pitch_mastery_values(player))
			else:
				aptitude_changes = _build_position_aptitude_changes(before_aptitudes, _capture_position_aptitude_values(player))
		var detail_changed: bool = _detail_array_has_delta(pitch_changes) or _detail_dict_has_delta(aptitude_changes)
		if before == after and not detail_changed:
			continue
		var change: Dictionary = {
			"player_id": player.id,
			"name": player.name,
			"age": player.age,
			"team_id": player.team_id,
			"position": player.position,
			"is_pitcher": player.is_pitcher(),
			"before": before,
			"after": after,
			"delta": after - before,
			"growth_kind": growth_kind,
			"growth_label": development_kind_label(growth_kind),
			"changed_keys": int(mutation.get("changed_keys", 0)),
			"net_z_delta": float(mutation.get("net_z_delta", 0.0)),
		}
		if want_abilities:
			change["abilities"] = _build_ability_changes(before_ratings, _capture_display_ratings(player))
			if player.is_pitcher():
				change["pitch_changes"] = pitch_changes
			else:
				change["aptitude_changes"] = aptitude_changes
		changes.append(change)

	var growers: Array = []
	var decayers: Array = []
	var pitchers: Array = []
	var fielders: Array = []
	for change_row in changes:
		var change: Dictionary = change_row as Dictionary
		if int(change["delta"]) > 0:
			growers.append(change)
		elif int(change["delta"]) < 0:
			decayers.append(change)
		if bool(change.get("is_pitcher", false)):
			pitchers.append(change)
		else:
			fielders.append(change)

	var delta_desc: Callable = func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) > int((b as Dictionary)["delta"])
	growers.sort_custom(delta_desc)
	decayers.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) < int((b as Dictionary)["delta"])
	)
	pitchers.sort_custom(delta_desc)
	fielders.sort_custom(delta_desc)

	return {
		"growers": growers.slice(0, 20),
		"decayers": decayers.slice(0, 20),
		"growers_count": growers.size(),
		"decayers_count": decayers.size(),
		"growth_kind_counts": kind_counts,
		"pitchers": pitchers,
		"fielders": fielders,
	}


# 守備適性のオフシーズン成長を player.position_aptitudes に書き戻す。
#  - 本職: 毎オフ +CAMP_PRIMARY_APTITUDE_GAIN (上限 100)。
#  - 各ポジ: そのシーズンに守った守備イニング × APTITUDE_GAIN_PER_INNING (上限 100)。
# record が無い (= 試合をしていない) 場合は本職キャンプ分のみ。投手 (pos 1) は対象外。
static func apply_position_aptitude_growth(player: PSPlayer, record: PSPlayerSeasonRecord) -> void:
	if player == null or player.position == 1:
		return
	var apt: Dictionary = player.position_aptitudes
	var primary_key: String = str(POSITION_NAME_BY_ID.get(player.position, ""))
	if not primary_key.is_empty():
		apt[primary_key] = mini(APTITUDE_MAX, int(apt.get(primary_key, 0)) + CAMP_PRIMARY_APTITUDE_GAIN)
	if record == null:
		return
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var innings: float = record.defensive_innings_at(position)
		if innings <= 0.0:
			continue
		var key: String = str(POSITION_NAME_BY_ID.get(position, ""))
		if key.is_empty():
			continue
		var gain: int = int(round(innings * APTITUDE_GAIN_PER_INNING))
		if gain <= 0:
			continue
		apt[key] = mini(APTITUDE_MAX, int(apt.get(key, 0)) + gain)


# 選手の表示能力 (球速/球質/巧打/長打…) を key -> {label, suffix, value} のマップにする。
static func _capture_display_ratings(player: PSPlayer) -> Dictionary:
	var result: Dictionary = PSPlayerVisibleRatings.ratings_for_player(player)
	var map: Dictionary = {}
	for row_value in result.get("display_ratings", []) as Array:
		var row: Dictionary = row_value as Dictionary
		map[str(row.get("key", ""))] = {
			"label": str(row.get("label", "")),
			"suffix": str(row.get("suffix", "")),
			"value": int(row.get("display_value", row.get("value", 0))),
		}
	return map


# before/after の表示能力マップから [{label, suffix, after, delta}, ...] を after の定義順で組む。
static func _build_ability_changes(before_map: Dictionary, after_map: Dictionary) -> Array:
	var out: Array = []
	for key_value in after_map.keys():
		var key: String = str(key_value)
		var after_entry: Dictionary = after_map[key_value] as Dictionary
		var after_val: int = int(after_entry.get("value", 0))
		var before_val: int = int((before_map.get(key, {}) as Dictionary).get("value", after_val))
		out.append({
			"key": key,
			"label": str(after_entry.get("label", "")),
			"suffix": str(after_entry.get("suffix", "")),
			"after": after_val,
			"delta": after_val - before_val,
		})
	return out


static func _capture_pitch_mastery_values(player: PSPlayer) -> Array:
	var mastery_by_type: Dictionary = {}
	for entry_value in player.arsenal:
		var entry: Dictionary = entry_value as Dictionary
		mastery_by_type[str(entry.get("type", ""))] = float(entry.get("mastery", 0.0))
	var out: Array = []
	for type_value in PSPitchTypes.ALL_TYPES:
		var type_key: String = str(type_value)
		out.append(PSAbilityScale.z_to_display(float(mastery_by_type[type_key])) if mastery_by_type.has(type_key) else -1)
	return out


static func _build_pitch_mastery_changes(before_values: Array, after_values: Array) -> Array:
	var out: Array = []
	for i in range(after_values.size()):
		var after: int = int(after_values[i])
		var before: int = int(before_values[i]) if i < before_values.size() else after
		out.append({"after": after, "delta": (after - before) if after >= 0 and before >= 0 else 0})
	return out


static func _capture_position_aptitude_values(player: PSPlayer) -> Dictionary:
	var out: Dictionary = {}
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var key: String = str(POSITION_NAME_BY_ID.get(position, ""))
		out[position] = int(player.position_aptitudes.get(key, 0)) if not key.is_empty() else 0
	return out


static func _build_position_aptitude_changes(before_values: Dictionary, after_values: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		var after: int = int(after_values.get(position, 0))
		var before: int = int(before_values.get(position, after))
		if after > 0 or after != before:
			out[position] = {"after": after, "delta": after - before}
	return out


static func _detail_array_has_delta(rows: Array) -> bool:
	for row_value in rows:
		if int((row_value as Dictionary).get("delta", 0)) != 0:
			return true
	return false


static func _detail_dict_has_delta(rows: Dictionary) -> bool:
	for row_value in rows.values():
		if int((row_value as Dictionary).get("delta", 0)) != 0:
			return true
	return false


static func _mutate_abilities(player: PSPlayer) -> Dictionary:
	var growth_kind: String = _choose_growth_kind(player)
	var keys_to_mutate: Array = _development_keys_for_player(player)
	var changed_keys: int = 0
	var net_z_delta: float = 0.0
	var raw_velocity_delta: int = 0
	for key_variant in keys_to_mutate:
		var key: String = str(key_variant)
		var d_z: float = _growth_delta_z(growth_kind, player.age, key)
		if absf(d_z) < 0.005:
			continue
		var current: float = float(player.z_abilities.get(key, 0.0))
		player.z_abilities[key] = clamp(current + d_z, Z_ABILITY_MIN, Z_ABILITY_MAX)
		changed_keys += 1
		net_z_delta += d_z
	if player.is_pitcher():
		raw_velocity_delta = _growth_delta_velocity(growth_kind, player.age)
		if raw_velocity_delta != 0:
			var current_velocity: int = int(round(float(player.raw_abilities.get("max_velocity", _generated_max_velocity_from_z(player.z_abilities)))))
			player.raw_abilities["max_velocity"] = clampi(current_velocity + raw_velocity_delta, RAW_MAX_VELOCITY_MIN, RAW_MAX_VELOCITY_MAX)
			changed_keys += 1
	return {
		"kind": growth_kind,
		"label": development_kind_label(growth_kind),
		"changed_keys": changed_keys,
		"net_z_delta": net_z_delta,
		"raw_velocity_delta": raw_velocity_delta,
	}


static func _development_keys_for_player(player: PSPlayer) -> Array:
	var keys_to_mutate: Array = []
	if player.is_pitcher():
		keys_to_mutate.append_array(PSPlayer.Z_PITCHER_ABILITY_KEYS.keys())
	else:
		keys_to_mutate.append_array(PSPlayer.Z_BATTER_ABILITY_KEYS.keys())
		keys_to_mutate.append_array(PSPlayer.Z_RUNNING_ABILITY_KEYS.keys())
	var category: String = PSPlayer.fielding_ability_category_for_position(player.position)
	match category:
		"catcher":
			keys_to_mutate.append_array(PSPlayer.Z_CATCHER_ABILITY_KEYS.keys())
		"infield":
			keys_to_mutate.append_array(PSPlayer.Z_INFIELD_ABILITY_KEYS.keys())
		"outfield":
			keys_to_mutate.append_array(PSPlayer.Z_OUTFIELD_ABILITY_KEYS.keys())
	return keys_to_mutate


static func _choose_growth_kind(player: PSPlayer) -> String:
	var age: int = 0 if player == null else player.age
	var probabilities: Dictionary = _growth_kind_probabilities(age)
	var roll: float = Rng.roll_float() * 100.0
	var acc: float = 0.0
	for kind in GROWTH_KIND_ORDER:
		acc += float(probabilities.get(kind, 0.0))
		if roll <= acc:
			return str(kind)
	return GROWTH_KIND_STAGNATION


static func _growth_kind_probabilities(age: int) -> Dictionary:
	var normalized_age: int = _growth_curve_age(age)
	var major_decline: float = _major_decline_chance(normalized_age)
	var decline: float = _decline_chance(normalized_age)
	var stagnation: float = _stagnation_chance(normalized_age)
	var growth: float = _growth_chance(normalized_age)
	var awakening: float = _awakening_chance(normalized_age)
	return {
		GROWTH_KIND_AWAKENING: awakening,
		GROWTH_KIND_GROWTH: growth,
		GROWTH_KIND_STAGNATION: stagnation,
		GROWTH_KIND_DECLINE: decline,
		GROWTH_KIND_MAJOR_DECLINE: major_decline,
	}


static func _growth_curve_age(age: int) -> int:
	return 19 if age <= 18 else age


static func _major_decline_chance(age: int) -> float:
	if age >= 40:
		return 35.0
	match age:
		29:
			return 1.0
		30:
			return 3.0
		31:
			return 5.0
		32:
			return 8.0
		33:
			return 13.0
		34:
			return 15.0
		35:
			return 18.0
		36:
			return 20.0
		37:
			return 23.0
		38:
			return 27.0
		39:
			return 30.0
	return 0.0


static func _decline_chance(age: int) -> float:
	if age >= 40:
		return 60.0
	match age:
		27:
			return 5.0
		28:
			return 12.0
		29:
			return 19.0
		30:
			return 24.0
		31:
			return 31.0
		32:
			return 37.0
		33:
			return 42.0
		34:
			return 47.0
		35:
			return 50.0
		36, 37, 38, 39:
			return 65.0
	return 0.0


static func _stagnation_chance(age: int) -> float:
	if age >= 40:
		return 5.0
	match age:
		23, 24, 25:
			return 39.0
		27:
			return 45.0
		28:
			return 49.0
		29, 30:
			return 50.0
		31:
			return 49.0
		32:
			return 45.0
		33:
			return 40.0
		34:
			return 35.0
		35:
			return 30.0
		36:
			return 14.0
		37:
			return 12.0
		38:
			return 8.0
		39:
			return 5.0
	return 40.0


static func _growth_chance(age: int) -> float:
	if age >= 40:
		return 0.0
	match age:
		23, 24, 25:
			return 60.0
		27:
			return 49.0
		28:
			return 38.0
		29:
			return 29.0
		30:
			return 23.0
		31:
			return 15.0
		32:
			return 10.0
		33:
			return 5.0
		34:
			return 3.0
		35:
			return 2.0
		36:
			return 1.0
		37, 38, 39:
			return 0.0
	return 59.0


static func _awakening_chance(age: int) -> float:
	return 1.0 if age <= 29 else 0.0


static func _growth_delta_z(kind: String, age: int, key: String) -> float:
	var roll: int = Rng.roll_percent()
	var delta: float = 0.0
	match kind:
		GROWTH_KIND_AWAKENING:
			if roll <= 8:
				delta = -_range_float(0.02, 0.08)
			else:
				delta = _range_float(0.08, 0.28)
				if Rng.roll_percent() <= 20:
					delta += _range_float(0.06, 0.16)
		GROWTH_KIND_GROWTH:
			if roll <= 12:
				delta = -_range_float(0.02, 0.08)
			elif roll <= 28:
				delta = _range_float(-0.015, 0.035)
			elif roll <= 78:
				delta = _range_float(0.035, 0.12)
			else:
				delta = _range_float(0.12, 0.22)
		GROWTH_KIND_STAGNATION:
			if roll <= 12:
				delta = -_range_float(0.01, 0.04)
			elif roll <= 24:
				delta = _range_float(0.01, 0.04)
			else:
				delta = 0.0
		GROWTH_KIND_DECLINE:
			if roll <= 10:
				delta = _range_float(0.01, 0.05)
			elif roll <= 28:
				delta = _range_float(-0.03, 0.02)
			else:
				delta = -_range_float(0.05, 0.18)
		GROWTH_KIND_MAJOR_DECLINE:
			if roll <= 8:
				delta = _range_float(0.01, 0.04)
			elif roll <= 20:
				delta = -_range_float(0.04, 0.10)
			else:
				delta = -_range_float(0.12, 0.36)
		_:
			delta = 0.0
	delta *= _growth_key_multiplier(kind, age, key)
	delta *= GROWTH_DELTA_SCALE
	if absf(delta) < 0.005:
		return 0.0
	return delta


static func _growth_delta_velocity(kind: String, age: int) -> int:
	var roll: int = Rng.roll_percent()
	match kind:
		GROWTH_KIND_AWAKENING:
			if age <= 23 and roll <= 20:
				return 3
			if age <= 25 and roll <= 48:
				return 2
			return 1
		GROWTH_KIND_GROWTH:
			if age <= 26 and roll <= 24:
				return 2
			if age <= 28 and roll <= 18:
				return 1
			if age >= 31 and roll <= 16:
				return -1
		GROWTH_KIND_DECLINE:
			if age >= 33 and roll <= 18:
				return -2
			if age >= 30 and roll <= 34:
				return -1
		GROWTH_KIND_MAJOR_DECLINE:
			if age >= 33 and roll <= 28:
				return -3
			if age >= 29 and roll <= 60:
				return -2
			return -1
	return 0


static func _generated_max_velocity_from_z(z_abilities: Dictionary) -> int:
	# 球速生成: エース度 (Pit_KCreate) を基準に 140 起点で緩やかに上げる。
	# 大半が 140〜150 に収まり、上振れロールでのみ 150台、稀に 155〜160 に届く。
	var k_create_display: int = PSAbilityScale.z_to_display(float(z_abilities.get("Pit_KCreate", 0.0)))
	var velocity: float = 140.0 + float(max(0, k_create_display - 50)) * 0.18 + float(Rng.range_int(-1, 3))
	# 中程度の上振れ: 約12%で +3〜7 (150台前半をそこそこ出す)。
	if Rng.roll_percent() <= 12:
		velocity += float(Rng.range_int(3, 7))
	# 強い上振れ: 約2%で +8〜17 (155〜160 を稀に出す。160 は中程度上振れと重なった時のみ)。
	if Rng.roll_percent() <= 2:
		velocity += float(Rng.range_int(8, 17))
	return clampi(int(round(velocity)), GEN_MAX_VELOCITY_MIN, GEN_MAX_VELOCITY_MAX)


static func _growth_key_multiplier(kind: String, age: int, key: String) -> float:
	var multiplier: float = 1.0
	var is_decline_kind: bool = [GROWTH_KIND_DECLINE, GROWTH_KIND_MAJOR_DECLINE].has(kind)
	if ["Bat_Aggression", "Bat_Platoon", "Pit_EdgeRate", "C_GameCall", "IF_PositionFit", "OF_PositionFit"].has(key):
		multiplier *= 0.75
	if key.begins_with("Run_") and age >= 28:
		multiplier *= 1.25 if is_decline_kind else 0.85
	if ["Pit_Stamina", "Pit_FatigueResist"].has(key) and age >= 31:
		multiplier *= 1.15 if is_decline_kind else 0.90
	if kind == GROWTH_KIND_AWAKENING and ["Bat_Barrel", "Bat_Impact", "Bat_BBCreate", "Pit_KCreate", "Pit_BBPrevent", "Pit_BarrelDeny"].has(key):
		multiplier *= 1.10
	return multiplier


static func _empty_growth_kind_counts() -> Dictionary:
	var counts: Dictionary = {}
	for kind in GROWTH_KIND_ORDER:
		counts[str(kind)] = 0
	return counts


# --- STEP 5 (R4): 契約更新 (年俸再査定 + FA権遷移 + 予算会計) ---

# 在籍年数モデルでは固定複数年契約の年俸ロックは持たず、毎オフの再査定で十分。
# このステップで以下を一括処理する:
#   (1) 年俸の再査定 (_compute_new_salary)
#   (2) FA権/保有権の contract_status 遷移 (1軍登録日数 vs fa_eligible_years * 145)
#   (3) チーム予算 (funds) に対する年俸総額の会計サマリ
# Step1 では FA権取得選手もそのまま球団に残す (auto-retain)。放出先は Step2 設計のみ。
#
# タイミング注意: このステップは finalize 前 (years 加算前) に走る。FA権はこの年の
# 1軍登録日数を source_data.fa_nissuu に加算してから判定する。
static func process_contract_update(players: Array, teams: Array, season: PSSeason) -> Dictionary:
	var changes: Array = []
	var new_fa: Array = []
	# WAR 算出用のリーグコンテキストを 1 度だけ構築 (年俸査定で各選手の WAR を使う)。
	var league_ctx: Dictionary = {}
	if season != null:
		league_ctx = WarCalculator.build_league_context(season.year, season.season_number)
	var year: int = season.year if season != null else 0
	if season != null and teams != null:
		var team_ids: Array = []
		for team_row in teams:
			var team_for_days: PSTeam = team_row as PSTeam
			if team_for_days != null:
				team_ids.append(team_for_days.id)
		season.accrue_all_active_roster_days(team_ids, season.current_day)
	for player_row in players:
		var player: PSPlayer = player_row as PSPlayer
		if player.is_retired():
			continue
		# (1) 年俸再査定: 今季の記録 (WAR + 出場試合数 + 成績) から前年俸を裁定。
		var record: PSPlayerSeasonRecord = null
		if season != null:
			record = RecordStore.get_player_record(player.id, season.year, season.season_number)
		_apply_fa_service_days(player, record, season)
		var war: float = _season_war(record, league_ctx)
		var old_salary: int = player.salary
		var skip_salary_update: bool = year > 0 and int(player.source_data.get("fa_signed_year", 0)) == year and player.source_data.has("fa_contract_salary")
		if not skip_salary_update:
			var new_salary: int = _compute_new_salary(player, record, war)
			if new_salary != old_salary:
				player.salary = new_salary
				changes.append({
					"player_id": player.id,
					"name": player.name,
					"age": player.age,
					"team_id": player.team_id,
					"position": player.position,
					"role": player.role,
					"old_salary": old_salary,
					"new_salary": new_salary,
					"delta": new_salary - old_salary,
				})
		# (2) FA権/保有権の contract_status 遷移
		var was_fa: bool = player.contract_status == "FA可能"
		var new_status: String = _contract_status_for(player)
		if new_status != player.contract_status:
			player.contract_status = new_status
		if new_status == "FA可能" and not was_fa:
			player.source_data["fa_eligible_year"] = year
			player.source_data["fa_pass_count"] = 0
			new_fa.append({
				"player_id": player.id,
				"name": player.name,
				"age": player.age,
				"team_id": player.team_id,
				"position": player.position,
				"role": player.role,
				"years": player.years,
				"fa_eligible_years": player.fa_eligible_years,
				"fa_nissuu": player.fa_service_days(),
			})
		elif new_status == "FA可能" and not player.source_data.has("fa_eligible_year"):
			var years_since_eligible: int = int(floor(float(maxi(0, player.fa_service_days() - player.fa_service_days_required())) / float(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))
			player.source_data["fa_eligible_year"] = year - years_since_eligible
			player.source_data["fa_pass_count"] = maxi(0, years_since_eligible)

	var raises: Array = []
	var cuts: Array = []
	for change_row in changes:
		var change: Dictionary = change_row as Dictionary
		if int(change["delta"]) > 0:
			raises.append(change)
		else:
			cuts.append(change)

	raises.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) > int((b as Dictionary)["delta"])
	)
	cuts.sort_custom(func(a, b) -> bool:
		return int((a as Dictionary)["delta"]) < int((b as Dictionary)["delta"])
	)
	new_fa.sort_custom(func(a, b) -> bool:
		var da: Dictionary = a as Dictionary
		var db: Dictionary = b as Dictionary
		if int(da["team_id"]) == int(db["team_id"]):
			return int(da["age"]) > int(db["age"])
		return int(da["team_id"]) < int(db["team_id"])
	)

	# (3) チーム予算会計
	var team_budgets: Array = []
	var over_budget_count: int = 0
	if teams != null:
		for team_row in teams:
			var team: PSTeam = team_row as PSTeam
			if team == null:
				continue
			var payroll: int = TeamFinance.team_payroll(players, team.id)
			var over: bool = TeamFinance.is_over_budget(team.funds, payroll)
			if over:
				over_budget_count += 1
			team_budgets.append({
				"team_id": team.id,
				"name": team.name,
				"funds": team.funds,
				"payroll": payroll,
				"room": TeamFinance.budget_room(team.funds, payroll),
				"over_budget": over,
			})
		team_budgets.sort_custom(func(a, b) -> bool:
			return int((a as Dictionary)["team_id"]) < int((b as Dictionary)["team_id"])
		)

	return {
		"raises": raises.slice(0, 20),
		"cuts": cuts.slice(0, 20),
		"raises_count": raises.size(),
		"cuts_count": cuts.size(),
		"new_fa": new_fa,
		"new_fa_count": new_fa.size(),
		"team_budgets": team_budgets,
		"over_budget_count": over_budget_count,
	}


# 1軍登録日数と FA閾値から contract_status を決める。
#   fa_nissuu >= fa_eligible_years*145 → "FA可能" (FA権取得済み = 保有権消滅)
#   残り1年相当以下                    → "FA権間近" (延長交渉の起点)
#   それ以外                           → "通常"
static func _contract_status_for(player: PSPlayer) -> String:
	if player.is_fa_eligible():
		return "FA可能"
	if player.fa_remaining_years() == 1:
		return "FA権間近"
	return "通常"


static func _apply_fa_service_days(player: PSPlayer, record: PSPlayerSeasonRecord, season: PSSeason) -> void:
	if player == null:
		return
	if not player.source_data.has("fa_nissuu"):
		var completed_years_estimate: int = maxi(0, player.years)
		if season != null:
			completed_years_estimate = maxi(0, player.years - 1)
		player.source_data["fa_nissuu"] = completed_years_estimate * PSPlayer.FA_SERVICE_DAYS_PER_YEAR
	if season == null or season.year <= 0:
		return
	if int(player.source_data.get("fa_days_accrued_year", 0)) == season.year:
		return
	var service_team_id: int = player.team_id
	if record != null and record.team_id > 0:
		service_team_id = record.team_id
	if service_team_id <= 0:
		player.source_data["fa_days_accrued_year"] = season.year
		player.source_data["fa_active_days_last_season"] = 0
		return
	var season_days: int = season.get_active_roster_days(service_team_id, player.id)
	player.source_data["fa_nissuu"] = int(player.source_data.get("fa_nissuu", 0)) + season_days
	player.source_data["fa_days_accrued_year"] = season.year
	player.source_data["fa_active_days_last_season"] = season_days


# --- 年俸モデル (R4 調整): WAR + 出場試合数ベースの裁定型、現実的スケール (万円) ---
# 参考 (NPB 2024-25 実データ): 支配下平均≈4700万 / 中央値≈1900万 / 最低420万 /
#   1億超≈17% / 上限7-8億。ドラフト1位初年度≈1500万、ブレイクで1500→7000万級。
# 旧モデルは base=overall*1000 で全員 ≈5億になり現実から著しく乖離していたため作り直し。
#
# 仕組み:
#   1. 今季の「市場価値」target を WAR(質) + 出場試合数/投球回(出場) + 主要成績 から算出。
#   2. 前年俸から target へ裁定移動。昇給は速く (ブレイク再現)、減給は NPB 減額制限
#      (1億以下25% / 1億超40%) を上限に緩やかに。これで多年の累積でスター年俸が形成される。
const SALARY_MIN: int = 440              # 支配下最低年俸
const FOREIGN_SALARY_MIN: int = 3000     # 外国人は高め
const SALARY_MAX: int = 80000            # 8億
const SALARY_MARKET_FLOOR: float = 800.0
# 在籍年数 (年功): 出場が少ないベテランも年数に応じてある程度の年俸を得る (NPB の年功的な底上げ)。
# これで中央値が現実 (≈1900万) 寄りに上がる (新人の下限は据え置き)。
const TENURE_PER_YEAR: float = 220.0
const TENURE_CAP_YEARS: int = 12
# 出場 (durability): 出場試合数・投球回で評価 (ユーザー要望: WAR だけでなく出場でも評価)。
const DUR_PER_GAME_BAT: float = 16.0     # 野手 143 試合 ≈ 2288
const DUR_PER_START: float = 44.0
const DUR_PER_IP: float = 11.0
const DUR_PER_RELIEF: float = 32.0
# WAR (質)。スター域は凸加速。
const WAR_LINEAR: float = 2100.0
const WAR_CONVEX_KNEE: float = 4.0
const WAR_CONVEX_EXP: float = 1.8
const WAR_CONVEX_SCALE: float = 550.0
const NEG_WAR_PENALTY: float = 1200.0
# 裁定 (前年俸からの移動量と減額制限)。
const SALARY_RAISE_ALPHA: float = 0.8
const SALARY_CUT_ALPHA: float = 0.5
const SALARY_CUT_LIMIT_LOW: float = 0.25      # 1億以下は最大25%減
const SALARY_CUT_LIMIT_HIGH: float = 0.40     # 1億超は最大40%減
const SALARY_CUT_LIMIT_THRESHOLD: int = 10000 # 1億
const FOREIGN_MARKET_MULT: float = 1.25


# 今季記録の WAR (野手/投手)。記録なしや未出場は 0。
static func _season_war(record: PSPlayerSeasonRecord, league_ctx: Dictionary) -> float:
	if record == null or league_ctx.is_empty():
		return 0.0
	if record.is_pitcher():
		return float(WarCalculator.calculate_pitcher_war(record, league_ctx).get("war", 0.0))
	return float(WarCalculator.calculate_batter_war(record, league_ctx).get("war", 0.0))


# 今季の市場価値 (万円)。出場・WAR・主要成績の合算。
static func _season_market_value(record: PSPlayerSeasonRecord, war: float, is_foreign: bool) -> int:
	if record == null:
		return int(SALARY_MARKET_FLOOR)
	var w: float = maxf(-1.5, war)
	var durability: float = 0.0
	var stats_value: float = 0.0
	if record.is_pitcher():
		var ps: PSPitcherStats = record.pitcher_stats
		var ip: float = ps.innings_pitched()
		if record.is_starter_pitcher():
			durability = float(ps.starts) * DUR_PER_START + ip * DUR_PER_IP
		else:
			durability = float(ps.relief_appearances) * DUR_PER_RELIEF + ip * DUR_PER_IP
		stats_value = float(ps.wins) * 150.0 + float(ps.saves) * 140.0 + float(ps.holds) * 60.0 + float(ps.strikeouts) * 4.0
		if ip >= 140.0 and ps.era() < 3.5:
			stats_value += (3.5 - ps.era()) * 1800.0
	else:
		var bs: PSBatterStats = record.batter_stats
		durability = float(bs.games) * DUR_PER_GAME_BAT
		stats_value = float(bs.home_runs) * 45.0 + float(bs.runs_batted_in) * 6.0 + float(bs.hits) * 3.0 + float(bs.stolen_bases) * 6.0
		if bs.at_bats >= 300 and bs.batting_average() >= 0.300:
			stats_value += (bs.batting_average() - 0.300) * 25000.0
	var war_value: float = 0.0
	if w > 0.0:
		war_value = w * WAR_LINEAR
		if w > WAR_CONVEX_KNEE:
			war_value += pow(w - WAR_CONVEX_KNEE, WAR_CONVEX_EXP) * WAR_CONVEX_SCALE
	else:
		war_value = w * NEG_WAR_PENALTY
	var tenure_value: float = float(mini(record.years, TENURE_CAP_YEARS)) * TENURE_PER_YEAR
	var market: float = SALARY_MARKET_FLOOR + tenure_value + durability + war_value + stats_value
	if is_foreign:
		market *= FOREIGN_MARKET_MULT
	return int(maxf(0.0, market))


# 前年俸 (player.salary) を今季市場価値へ裁定移動する。
static func _compute_new_salary(player: PSPlayer, record: PSPlayerSeasonRecord, war: float) -> int:
	var target: int = _season_market_value(record, war, player.foreign_player)
	var old_salary: int = player.salary
	var new_salary: int
	if target >= old_salary:
		new_salary = old_salary + int(round(float(target - old_salary) * SALARY_RAISE_ALPHA))
	else:
		var blended: int = old_salary - int(round(float(old_salary - target) * SALARY_CUT_ALPHA))
		var cut_rate: float = SALARY_CUT_LIMIT_HIGH if old_salary > SALARY_CUT_LIMIT_THRESHOLD else SALARY_CUT_LIMIT_LOW
		var floor_cut: int = int(round(float(old_salary) * (1.0 - cut_rate)))
		new_salary = maxi(blended, floor_cut)
	var min_sal: int = FOREIGN_SALARY_MIN if player.foreign_player else SALARY_MIN
	return clampi(new_salary, min_sal, SALARY_MAX)


static func _rand_z(center: int, variance: int = 12, min_value: int = 25, max_value: int = 88) -> float:
	# center/variance/min/max は 1-100 の talent authoring 入力。生成される能力値そのものは
	# z 空間で直接抽選し、1-100 の中間能力値を作らない (シミュは z 能力のみ使用)。
	var center_z: float = PSAbilityScale.display_to_z(center)
	var variance_z: float = float(variance) / PSAbilityScale.DISPLAY_STDEV
	var value_z: float = center_z + (Rng.roll_float() * 2.0 - 1.0) * variance_z
	return clampf(value_z, PSAbilityScale.display_to_z(min_value), PSAbilityScale.display_to_z(max_value))


static func _range_float(min_value: float, max_value: float) -> float:
	return min_value + (max_value - min_value) * Rng.roll_float()
