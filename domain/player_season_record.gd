extends RefCounted
class_name PSPlayerSeasonRecord

const AdvancedStatsRecord = preload("res://services/simulation/reducers/advanced_stats_record.gd")

var player_id: int
var sensyu_num: int
var jersey_number: int
var development_player: bool
var year: int
var season_number: int
var team_id: int
var name: String
var age: int
var years: int
var height: int
var weight: int
var position: int
var role: String
var throwing_hand: String
var batting_side: String
var salary: int
var draft_round: int
var hometown: String
var registered_roster: String
var contract_status: String
var foreign_player: bool
# FA権取得に必要な1軍登録年数相当のスナップショット。出身により 8 または 7 が入る。
var fa_eligible_years: int = 0
# 累積疲労。試合後に球数比例で加算され、休養日で減衰する。
# 0=元気, 200=飽和。PSFatigueCalculator は当試合の outing pitches を別途参照する。
var fatigue: int
var injury_days: int
# そのシーズンに被った怪我日数の累計 (maybe_injure で発生日数を加算)。毎シーズン from_player で 0 リセット。
# 戦力外の「高能力かつ怪我で出場できなかった」判定に使う。
var season_injury_days: int = 0
# 怪我日数が 0 に戻った日。投手の怪我明け登板制限に使う。
var injury_return_day: int = 0
# 怪我の種類(部位/病名ラベル)と重症度ティア(0=軽傷..3=重大手術)。PSInjuryModel が発生時に設定し、
# from_player で持続 player から引き継ぐ (長期離脱のシーズン跨ぎ表示用)。
var injury_type: String = ""
var injury_severity: int = 0
var consecutive_appearances: int = 0
var last_pitched_team_game: int = 0
var position_aptitudes_snapshot: Dictionary = {}
var position_experience_snapshot: Dictionary = {}
var source_data: Dictionary = {}
# z-score 能力値のシーズン開始時スナップショット。シミュレーションはこの raw z を正準能力値として読む。
# UI など display スケールが必要な箇所は z_display() で変換する。
var z_abilities_snapshot: Dictionary = {}
var raw_abilities_snapshot: Dictionary = {}
# 変化球アーセナルのスナップショット: [{ "type": <String>, "mastery": <float z> }, ...]。
# 空なら arsenal_or_derived() が z 能力から決定論的に派生する。
var arsenal_snapshot: Array = []
var batter_stats: PSBatterStats = PSBatterStats.new()
var pitcher_stats: PSPitcherStats = PSPitcherStats.new()
# 高度統計のシーズン累積。1 試合ごとに game_result.advanced_stats からマージされる。
# WAR / FIP / OAA / wRAA / BSR の算出元。
var advanced_stats: PSAdvancedStats = PSAdvancedStats.new()

# ---- 二軍 (ファーム) 成績 --------------------------------------------------
# **一軍成績と同じ器を別インスタンスで持つ。** 1選手1シーズン = 1レコードのまま
# (疲労・怪我・能力スナップショットは選手につき1個でなければならないため、
# レベルごとにレコードを分けてはいけない)。
#
# ⚠️ **二軍成績は一軍成績と混ぜてはいけない。** タイトル・表彰・WAR・年俸査定・引退判定・
# 規定到達・通算記録はすべて一軍のみ。既存コードがこのフィールドを読まないことで
# 構造的に保証される ([[project_farm_system_design]])。
var farm_batter_stats: PSBatterStats = PSBatterStats.new()
var farm_pitcher_stats: PSPitcherStats = PSPitcherStats.new()
# 二軍の advanced stats は**守備イニングだけ**保持する (WAR/OAA/wRAA は二軍では算出しない)。
# オフの守備適性成長が守備イニングを入力に使うため、ここを捨てると
# 「二軍でコンバートを試している選手の適性が伸びない」という実害が出る。
# 形は advanced_stats.defensive_outs_by_position と同じ { "<position_id>": outs }。
var farm_defensive_outs_by_position: Dictionary = {}


static func from_player(player: PSPlayer, p_year: int, p_season_number: int) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = player.id
	record.sensyu_num = player.sensyu_num
	record.jersey_number = player.jersey_number
	record.development_player = player.development_player
	record.year = p_year
	record.season_number = p_season_number
	record.team_id = player.team_id
	record.name = player.name
	record.age = player.age
	record.years = player.years
	record.height = player.height
	record.weight = player.weight
	record.position = player.position
	record.role = player.role
	record.throwing_hand = player.throwing_hand
	record.batting_side = player.batting_side
	record.salary = player.salary
	record.draft_round = player.draft_round
	record.hometown = player.hometown
	record.registered_roster = player.registered_roster
	record.contract_status = player.contract_status
	record.foreign_player = player.foreign_player
	record.fa_eligible_years = player.fa_eligible_years
	record.fatigue = player.fatigue
	record.injury_days = player.injury_days
	record.season_injury_days = 0
	record.injury_return_day = 0
	record.injury_type = player.injury_type
	record.injury_severity = player.injury_severity
	record.consecutive_appearances = 0
	record.last_pitched_team_game = 0
	record.position_aptitudes_snapshot = player.position_aptitudes.duplicate(true)
	record.position_experience_snapshot = player.position_experience.duplicate(true)
	record.source_data = player.source_data.duplicate(true)
	record.z_abilities_snapshot = player.z_abilities.duplicate(true)
	record.raw_abilities_snapshot = player.raw_abilities.duplicate(true)
	record.arsenal_snapshot = player.arsenal.duplicate(true)
	return record


static func from_dict(data: Dictionary) -> PSPlayerSeasonRecord:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = int(data.get("player_id", 0))
	record.sensyu_num = int(data.get("sensyu_num", 0))
	record.jersey_number = int(data.get("jersey_number", 0))
	record.development_player = bool(data.get("development_player", false))
	record.year = int(data.get("year", 0))
	record.season_number = int(data.get("season_number", 0))
	record.team_id = int(data.get("team_id", 0))
	record.name = str(data.get("name", ""))
	record.age = int(data.get("age", 0))
	record.years = int(data.get("years", 0))
	record.height = int(data.get("height", 0))
	record.weight = int(data.get("weight", 0))
	record.position = int(data.get("position", 0))
	record.role = str(data.get("role", "fielder"))
	record.throwing_hand = str(data.get("throwing_hand", "R"))
	record.batting_side = str(data.get("batting_side", "R"))
	record.salary = int(data.get("salary", 0))
	record.draft_round = int(data.get("draft_round", 0))
	record.hometown = str(data.get("hometown", ""))
	record.registered_roster = str(data.get("registered_roster", "支配下"))
	record.contract_status = str(data.get("contract_status", "通常"))
	record.foreign_player = bool(data.get("foreign_player", false))
	record.fatigue = int(data.get("fatigue", 0))
	record.injury_days = int(data.get("injury_days", 0))
	record.season_injury_days = int(data.get("season_injury_days", 0))
	record.injury_return_day = int(data.get("injury_return_day", 0))
	record.injury_type = str(data.get("injury_type", ""))
	record.injury_severity = int(data.get("injury_severity", 0))
	record.consecutive_appearances = int(data.get("consecutive_appearances", 0))
	record.last_pitched_team_game = int(data.get("last_pitched_team_game", 0))
	record.position_aptitudes_snapshot = (data.get("position_aptitudes_snapshot", {}) as Dictionary).duplicate(true)
	record.position_experience_snapshot = PSPlayer.normalized_position_experience((data.get("position_experience_snapshot", {}) as Dictionary), record.position, record.position_aptitudes_snapshot)
	record.source_data = (data.get("source_data", {}) as Dictionary).duplicate(true)
	record.fa_eligible_years = int(data.get("fa_eligible_years", 0))
	if record.fa_eligible_years <= 0:
		record.fa_eligible_years = PSPlayer.default_fa_eligible_years(record.foreign_player, record.age, record.years, record.source_data)
	record.z_abilities_snapshot = (data.get("z_abilities_snapshot", {}) as Dictionary).duplicate(true)
	record.raw_abilities_snapshot = (data.get("raw_abilities_snapshot", {}) as Dictionary).duplicate(true)
	record.arsenal_snapshot = (data.get("arsenal_snapshot", []) as Array).duplicate(true)
	record.batter_stats = PSBatterStats.from_dict(data.get("batter_stats", {}) as Dictionary)
	record.pitcher_stats = PSPitcherStats.from_dict(data.get("pitcher_stats", {}) as Dictionary)
	record.farm_batter_stats = PSBatterStats.from_dict(data.get("farm_batter_stats", {}) as Dictionary)
	record.farm_pitcher_stats = PSPitcherStats.from_dict(data.get("farm_pitcher_stats", {}) as Dictionary)
	record.farm_defensive_outs_by_position = (data.get("farm_defensive_outs_by_position", {}) as Dictionary).duplicate(true)
	var advanced_payload: Dictionary = data.get("advanced_stats", {}) as Dictionary
	record.advanced_stats = AdvancedStatsRecord.new()
	if not advanced_payload.is_empty():
		record.advanced_stats.load_from_dict(advanced_payload)
	if record.advanced_stats.player_id == 0:
		record.advanced_stats.player_id = record.player_id
	return record


func is_pitcher() -> bool:
	return position == 1 or role == "starter" or role == "reliever" or role == "closer"


func position_experience_value(position_id: int, default_value: int = 0) -> int:
	var key: String = PSPlayer.position_experience_key(position_id)
	if key.is_empty():
		return default_value
	return int(position_experience_snapshot.get(key, default_value))


# このシーズンに position_id を守った守備イニング数 (= 守備アウト / 3、IP=outs/3 の野球的定義)。
# advanced_stats.defensive_outs_by_position は守備交代も正確に反映 (alignment はプレー毎に再構築)。
# オフシーズンの守備適性成長 (apply_position_aptitude_growth) の入力に使う。
func defensive_innings_at(position_id: int) -> float:
	if advanced_stats == null:
		return 0.0
	var outs: int = int(advanced_stats.defensive_outs_by_position.get(str(position_id), 0))
	return float(outs) / 3.0


# 二軍で position_id を守った守備イニング数。
func farm_defensive_innings_at(position_id: int) -> float:
	return float(int(farm_defensive_outs_by_position.get(str(position_id), 0))) / 3.0


# 一軍 + 二軍の守備イニング。**守備適性の成長だけがこれを使う** — 二軍でコンバートを試した
# 分も適性に反映させたいため。既定 (`defensive_innings_at`) を一軍のみに保つのは、
# ゴールデングラブなど「一軍の表彰」が二軍のイニングを数えてしまう事故を防ぐため。
func total_defensive_innings_at(position_id: int) -> float:
	return defensive_innings_at(position_id) + farm_defensive_innings_at(position_id)


func fielding_ability_category() -> String:
	return PSPlayer.fielding_ability_category_for_position(position)


func breaking_score() -> int:
	# pitch_values は廃止（常に空）。投球 z があれば z 由来、無ければ既定 50。
	return _z_breaking_score() if _has_pitching_z() else 50


# 変化球アーセナルを返す。明示的に持っていればそれを、無ければ z から派生する。
# (現行の投手は初期シード backfill / 生成時に明示値を持つ。派生は旧セーブ等のフォールバック。)
# derive_from_z は決定論的なので呼ぶたびに同じ結果になる (role 適性が安定する)。
func arsenal_or_derived() -> Array:
	if not arsenal_snapshot.is_empty():
		return arsenal_snapshot
	return PSPitchTypes.derive_from_z(self)


# 怪我の表示ラベル ("部位名(重症度)")。健康なら空文字。
func injury_display_label() -> String:
	return PSInjuryModel.display_label(injury_type, injury_severity, injury_days)


func _max_velocity() -> int:
	var max_velocity: int = max_velocity_display()
	if max_velocity > 0:
		return max_velocity
	return z_display("Pit_KCreate", 2.0) + 70


func _has_pitching_z() -> bool:
	return z_abilities_snapshot.has("Pit_BarrelDeny") or z_abilities_snapshot.has("Pit_KCreate") or z_abilities_snapshot.has("Pit_LoftControl")


func _z_breaking_score() -> int:
	var barrel_deny: float = z_ability("Pit_BarrelDeny", 0.0)
	var k_create: float = z_ability("Pit_KCreate", 0.0)
	var loft_control: float = z_ability("Pit_LoftControl", 0.0)
	var blended: float = barrel_deny * 0.55 + k_create * 0.25 + loft_control * 0.20
	return clampi(100 + int(round(blended * 12.0)), 45, 160)


func to_dict() -> Dictionary:
	return {
		"player_id": player_id,
		"sensyu_num": sensyu_num,
		"jersey_number": jersey_number,
		"development_player": development_player,
		"year": year,
		"season_number": season_number,
		"team_id": team_id,
		"name": name,
		"age": age,
		"years": years,
		"height": height,
		"weight": weight,
		"position": position,
		"role": role,
		"throwing_hand": throwing_hand,
		"batting_side": batting_side,
		"salary": salary,
		"draft_round": draft_round,
		"hometown": hometown,
		"registered_roster": registered_roster,
		"contract_status": contract_status,
		"foreign_player": foreign_player,
		"fa_eligible_years": fa_eligible_years,
		"fatigue": fatigue,
		"injury_days": injury_days,
		"season_injury_days": season_injury_days,
		"injury_return_day": injury_return_day,
		"injury_type": injury_type,
		"injury_severity": injury_severity,
		"consecutive_appearances": consecutive_appearances,
		"last_pitched_team_game": last_pitched_team_game,
		"position_aptitudes_snapshot": position_aptitudes_snapshot,
		"position_experience_snapshot": position_experience_snapshot,
		"source_data": source_data,
		"z_abilities_snapshot": z_abilities_snapshot,
		"raw_abilities_snapshot": raw_abilities_snapshot,
		"arsenal_snapshot": arsenal_snapshot.duplicate(true),
		"batter_stats": batter_stats.to_dict(),
		"pitcher_stats": pitcher_stats.to_dict(),
		"advanced_stats": advanced_stats.to_dict() if advanced_stats != null else {},
		"farm_batter_stats": farm_batter_stats.to_dict(),
		"farm_pitcher_stats": farm_pitcher_stats.to_dict(),
		"farm_defensive_outs_by_position": farm_defensive_outs_by_position.duplicate(true),
	}


# R4 Step1: FA権取得までの残り年数相当 (0 = 取得済み = 保有権消滅)。
func fa_remaining_years() -> int:
	var remaining_days: int = maxi(0, fa_service_days_required() - fa_service_days())
	return int(ceil(float(remaining_days) / float(PSPlayer.FA_SERVICE_DAYS_PER_YEAR)))


# 1軍登録日数が閾値に達し、自由移籍可能 (FA権取得済み) か。
func is_fa_eligible() -> bool:
	return fa_service_days() >= fa_service_days_required()


func fa_service_days_required() -> int:
	return maxi(1, fa_eligible_years) * PSPlayer.FA_SERVICE_DAYS_PER_YEAR


func fa_service_days() -> int:
	if source_data.has("fa_nissuu"):
		return maxi(0, int(source_data.get("fa_nissuu", 0)))
	return maxi(0, years) * PSPlayer.FA_SERVICE_DAYS_PER_YEAR


# File 2 §5: z-score 内部能力値の読み取り（リーグ平均=0.0）
func z_ability(key: String, default_value: float = 0.0) -> float:
	return float(z_abilities_snapshot.get(key, default_value))


# z-score → display(1〜100) 線形マッピング。シミュ/UI の display ベース計算式が使う。
func z_display(key: String, default_z: float = 0.0) -> int:
	return PSAbilityScale.z_to_display(z_ability(key, default_z))


func is_starter_pitcher() -> bool:
	var model: GDScript = load("res://services/simulation/models/pitcher_role_model.gd") as GDScript
	return model.is_starter_record(self)


# 特例: max_velocity は raw 値。
func max_velocity_display() -> int:
	return _max_velocity_display_value(0)


func raw_ability(key: String, default_value: float = 0.0) -> float:
	return float(raw_abilities_snapshot.get(key, default_value))


func _max_velocity_display_value(default_value: Variant) -> int:
	if raw_abilities_snapshot.has("max_velocity"):
		var raw_velocity: int = int(round(float(raw_abilities_snapshot.get("max_velocity", 0.0))))
		if raw_velocity > 0:
			return raw_velocity
	return 0 if default_value == null else int(default_value)
