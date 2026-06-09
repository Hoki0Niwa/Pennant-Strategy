extends RefCounted
class_name PSPlayer

const POSITION_NAMES = {
	1: "投手",
	2: "捕手",
	3: "一塁手",
	4: "二塁手",
	5: "三塁手",
	6: "遊撃手",
	7: "左翼手",
	8: "中堅手",
	9: "右翼手",
	10: "DH",
}

# R4 Step1: FA権/保有権。在籍年数 (years) が閾値に達するまで球団が保有権を持つ。
# 高卒は8年、その他 (大学/社会人/独立/外国人) は7年 (NPB 国内FA 準拠の簡易値)。
const FA_ELIGIBLE_YEARS_HIGH_SCHOOL: int = 8
const FA_ELIGIBLE_YEARS_OTHER: int = 7
# 高卒のデビュー年齢 (これ以下なら高卒出身と推定)。初期シード選手は draft_source 列が無いため。
const HIGH_SCHOOL_DEBUT_AGE: int = 18

# File 2 §5: z-score 内部能力値（旧 batting_abilities/pitching_abilities を置換済み・現行の正準）
const Z_BATTER_ABILITY_KEYS = {
	"Bat_KAvoid": true,
	"Bat_BBCreate": true,
	"Bat_Impact": true,
	"Bat_Loft": true,
	"Bat_Barrel": true,
	"Bat_Spray": true,
	"Bat_Aggression": true,
	"Bat_Platoon": true,
}

const Z_PITCHER_ABILITY_KEYS = {
	"Pit_KCreate": true,
	"Pit_BBPrevent": true,
	"Pit_ImpactLimit": true,
	"Pit_LoftControl": true,
	"Pit_BarrelDeny": true,
	"Pit_Efficiency": true,
	"Pit_Stamina": true,
	"Pit_FatigueResist": true,
	"Pit_HoldRunner": true,
	"Pit_EdgeRate": true,
}

const Z_CATCHER_ABILITY_KEYS = {
	"C_Framing": true,
	"C_Blocking": true,
	"C_Throw": true,
	"C_GameCall": true,
	"C_FieldSecure": true,
}

const Z_INFIELD_ABILITY_KEYS = {
	"IF_Reach": true,
	"IF_Secure": true,
	"IF_ThrowPower": true,
	"IF_ThrowAccuracy": true,
	"IF_Exchange": true,
	"IF_PositionFit": true,
}

const Z_OUTFIELD_ABILITY_KEYS = {
	"OF_Reach": true,
	"OF_Route": true,
	"OF_Secure": true,
	"OF_ArmPower": true,
	"OF_ArmAccuracy": true,
	"OF_Release": true,
	"OF_PositionFit": true,
}

const Z_RUNNING_ABILITY_KEYS = {
	"Run_Speed": true,
	"Run_Judgment": true,
	"Run_Steal": true,
}

# 投手守備 (PFP)。位置1の打球処理 (play_resolver / fielding_model) で使う。
const Z_PITCHER_FIELDING_ABILITY_KEYS = {
	"PF_Reach": true,
	"PF_Secure": true,
	"PF_Throw": true,
}

const Z_ABILITY_GROUPS = {
	"batter": Z_BATTER_ABILITY_KEYS,
	"pitcher": Z_PITCHER_ABILITY_KEYS,
	"catcher": Z_CATCHER_ABILITY_KEYS,
	"infield": Z_INFIELD_ABILITY_KEYS,
	"outfield": Z_OUTFIELD_ABILITY_KEYS,
	"running": Z_RUNNING_ABILITY_KEYS,
	"pitcher_fielding": Z_PITCHER_FIELDING_ABILITY_KEYS,
}

# 旧 ability キー → z-key の対応表 (LEGACY_KEY_TO_Z) と ability()/ability_value() は撤去した。
# ゲーム本体は z 能力 (z_ability / z_display) のみを使う。

# max_velocity は raw_abilities["max_velocity"] に生値(km/h)で保持する。

# File 1 §6.5: 調子段階（-2:絶不調 〜 +2:絶好調）
const CONDITION_MIN: int = -2
const CONDITION_MAX: int = 2

const POSITION_EXPERIENCE_KEYS = {
	2: "catcher",
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}

const FIELDING_ABILITY_CATEGORY_BY_POSITION = {
	1: "pitcher",
	2: "catcher",
	3: "infield",
	4: "infield",
	5: "infield",
	6: "infield",
	7: "outfield",
	8: "outfield",
	9: "outfield",
}

var id: int
var sensyu_num: int
var jersey_number: int
var development_player: bool
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
# R4 Step1: FA権を得る在籍年数 (8=高卒 / 7=その他)。0 以下なら apply_dict が出身から既定値を計算。
var fa_eligible_years: int = 0
var position_aptitudes: Dictionary = {}
var position_experience: Dictionary = {}
var source_data: Dictionary = {}
# File 2 §5: z-score 内部能力値（Bat_*, Pit_*, C_*, IF_*, OF_*, Run_*）が唯一の正準能力値。
# display スケールが必要なシミュ/UI 計算式は z_display() を使う。
var z_abilities: Dictionary = {}
var raw_abilities: Dictionary = {}
# 変化球(球種)アーセナル: [{ "type": <String>, "mastery": <float z> }, ...]。
# 空の場合は record 側 arsenal_or_derived() が z から派生する (後方互換)。詳細 PSPitchTypes。
var arsenal: Array = []
var fatigue: int
var injury_days: int
# File 1 §4.1, §6.5: 当日状態 + 打順制約
var condition: int = 0
var fixed_slot: int = 0
var allowed_slots: Array[int] = []
var preferred_slots: Array[int] = []


static func from_dict(data: Dictionary) -> PSPlayer:
	var player: PSPlayer = PSPlayer.new()
	player.apply_dict(data)
	return player


func apply_dict(data: Dictionary) -> void:
	id = int(data.get("id", 0))
	sensyu_num = int(data.get("sensyu_num", 0))
	jersey_number = int(data.get("jersey_number", 0))
	development_player = bool(data.get("development_player", false))
	team_id = int(data.get("team_id", 0))
	name = str(data.get("name", ""))
	age = int(data.get("age", 18))
	years = int(data.get("years", 1))
	height = int(data.get("height", 180))
	weight = int(data.get("weight", 80))
	position = int(data.get("position", 1))
	role = str(data.get("role", "fielder"))
	throwing_hand = str(data.get("throws", "R"))
	batting_side = str(data.get("bats", "R"))
	salary = int(data.get("salary", 1000))
	draft_round = int(data.get("draft_round", 0))
	hometown = str(data.get("hometown", ""))
	registered_roster = str(data.get("registered_roster", "支配下"))
	contract_status = str(data.get("contract_status", "通常"))
	foreign_player = bool(data.get("foreign_player", false))
	position_aptitudes = (data.get("position_aptitudes", {}) as Dictionary).duplicate(true)
	position_experience = normalized_position_experience((data.get("position_experience", {}) as Dictionary), position, position_aptitudes)
	source_data = (data.get("source_data", {}) as Dictionary).duplicate(true)
	z_abilities = (data.get("z_abilities", {}) as Dictionary).duplicate(true)
	raw_abilities = (data.get("raw_abilities", {}) as Dictionary).duplicate(true)
	arsenal = (data.get("arsenal", []) as Array).duplicate(true)
	fatigue = int(data.get("fatigue", 0))
	injury_days = int(data.get("injury_days", 0))
	condition = clampi(int(data.get("condition", 0)), CONDITION_MIN, CONDITION_MAX)
	fixed_slot = int(data.get("fixed_slot", 0))
	allowed_slots = _normalize_slot_array(data.get("allowed_slots", []))
	preferred_slots = _normalize_slot_array(data.get("preferred_slots", []))
	# FA閾値: 保存値があれば尊重、無ければ (初期シード/旧セーブ) 出身から既定計算。
	fa_eligible_years = int(data.get("fa_eligible_years", 0))
	if fa_eligible_years <= 0:
		fa_eligible_years = _default_fa_eligible_years()


func is_pitcher() -> bool:
	return position == 1 or role == "starter" or role == "reliever" or role == "closer"


func is_manager_candidate() -> bool:
	return bool(source_data.get("manager_candidate", false)) or str(source_data.get("personnel_role", "")) == "manager_candidate"


func is_retired() -> bool:
	return bool(source_data.get("retired", false))


# R4 Step1: 出身から FA閾値 (8=高卒 / 7=その他) を推定する。
#  - 生成選手は source_data["draft_source"] に出身種別が入る。
#  - 初期シード選手は列が無いため、デビュー年齢 (age - years + 1) が18以下なら高卒と推定。
#  - 外国人は当面その他 (7) 扱い。
func _default_fa_eligible_years() -> int:
	return default_fa_eligible_years(foreign_player, age, years, source_data)


# 出身から FA閾値 (8=高卒 / 7=その他) を推定する static 版。PSPlayerSeasonRecord からも再利用。
static func default_fa_eligible_years(is_foreign: bool, player_age: int, service_years: int, src_data: Dictionary) -> int:
	if is_foreign:
		return FA_ELIGIBLE_YEARS_OTHER
	var draft_source: String = str(src_data.get("draft_source", ""))
	if draft_source == "high_school":
		return FA_ELIGIBLE_YEARS_HIGH_SCHOOL
	if not draft_source.is_empty():
		return FA_ELIGIBLE_YEARS_OTHER
	var debut_age: int = player_age - service_years + 1
	if debut_age <= HIGH_SCHOOL_DEBUT_AGE:
		return FA_ELIGIBLE_YEARS_HIGH_SCHOOL
	return FA_ELIGIBLE_YEARS_OTHER


# FA権取得までの残り在籍年数 (0 = 既に取得済み = 保有権消滅)。
func fa_remaining_years() -> int:
	return maxi(0, fa_eligible_years - years)


# 在籍年数が閾値に達し、自由移籍可能 (FA権取得済み) か。
func is_fa_eligible() -> bool:
	return years >= fa_eligible_years


static func fielding_ability_category_for_position(position_id: int) -> String:
	return str(FIELDING_ABILITY_CATEGORY_BY_POSITION.get(position_id, ""))


static func position_experience_key(position_id: int) -> String:
	return str(POSITION_EXPERIENCE_KEYS.get(position_id, ""))


static func default_position_experience(position_id: int = 0, position_aptitudes: Dictionary = {}) -> Dictionary:
	var experience: Dictionary = {}
	for key_value in POSITION_EXPERIENCE_KEYS.values():
		var key: String = str(key_value)
		experience[key] = int(position_aptitudes.get(key, 0))

	var primary_key: String = position_experience_key(position_id)
	if not primary_key.is_empty() and int(experience.get(primary_key, 0)) <= 0:
		experience[primary_key] = 100
	return experience


static func normalized_position_experience(source: Dictionary, position_id: int = 0, position_aptitudes: Dictionary = {}) -> Dictionary:
	var experience: Dictionary = default_position_experience(position_id, position_aptitudes)
	for key_value in source.keys():
		var key: String = str(key_value)
		if POSITION_EXPERIENCE_KEYS.values().has(key):
			experience[key] = int(source.get(key_value, 0))
	return experience


func position_experience_value(position_id: int, default_value: int = 0) -> int:
	var key: String = position_experience_key(position_id)
	if key.is_empty():
		return default_value
	return int(position_experience.get(key, default_value))


func fielding_ability_category() -> String:
	return fielding_ability_category_for_position(position)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"sensyu_num": sensyu_num,
		"jersey_number": jersey_number,
		"development_player": development_player,
		"team_id": team_id,
		"name": name,
		"age": age,
		"years": years,
		"height": height,
		"weight": weight,
		"position": position,
		"role": role,
		"throws": throwing_hand,
		"bats": batting_side,
		"salary": salary,
		"draft_round": draft_round,
		"hometown": hometown,
		"registered_roster": registered_roster,
		"contract_status": contract_status,
		"foreign_player": foreign_player,
		"fa_eligible_years": fa_eligible_years,
		"position_aptitudes": position_aptitudes,
		"position_experience": position_experience,
		"source_data": source_data,
		"z_abilities": z_abilities,
		"raw_abilities": raw_abilities,
		"arsenal": arsenal.duplicate(true),
		"fatigue": fatigue,
		"injury_days": injury_days,
		"condition": condition,
		"fixed_slot": fixed_slot,
		"allowed_slots": allowed_slots.duplicate(),
		"preferred_slots": preferred_slots.duplicate(),
	}


# File 2 §5: z-score 内部能力値の読み取り（リーグ平均=0.0）
func z_ability(key: String, default_value: float = 0.0) -> float:
	return float(z_abilities.get(key, default_value))


func raw_ability(key: String, default_value: float = 0.0) -> float:
	return float(raw_abilities.get(key, default_value))


# File 2 §4.1: z-score → 1〜100 表示値 (シミュ用線形マッピング)。
# UI 表示は別途 player_visible_ratings で非線形シフトする。
func z_display(key: String, default_z: float = 0.0) -> int:
	return PSAbilityScale.z_to_display(z_ability(key, default_z))


# 先発/リリーフ判定: スタミナ z (Pit_Stamina) が閾値以上の投手を先発とする。
const STARTER_STAMINA_Z_THRESHOLD: float = 1.0
func is_starter_pitcher() -> bool:
	return is_pitcher() and z_ability("Pit_Stamina", 0.0) >= STARTER_STAMINA_Z_THRESHOLD


# 特例: max_velocity は raw 値 or Pit_KCreate proxy。
func max_velocity_display() -> int:
	return _max_velocity_display_value(0)


# 内部スロット配列の正規化（重複除去 + 1〜9のみ受理）
static func _normalize_slot_array(source: Variant) -> Array[int]:
	var result: Array[int] = []
	if not (source is Array):
		return result
	for raw in source:
		var slot: int = int(raw)
		if slot >= 1 and slot <= 9 and not result.has(slot):
			result.append(slot)
	return result


func _max_velocity_display_value(default_value: Variant) -> int:
	if raw_abilities.has("max_velocity"):
		var raw_velocity: int = int(round(float(raw_abilities.get("max_velocity", 0.0))))
		if raw_velocity > 0:
			return raw_velocity
	return 0 if default_value == null else int(default_value)


# 旧 ability → z 変換 (convert_legacy_to_z / convert_legacy_to_raw) は撤去した。
# z_abilities / raw_abilities はシード CSV・ドラフト生成・セーブデータが直接保持する。
