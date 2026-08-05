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

# FA権/保有権の基準値。1軍登録日数を145日=1年相当に換算し、
# 高卒は8年、その他は7年に達するまで現在球団が保有権を持つ。
const FA_ELIGIBLE_YEARS_HIGH_SCHOOL: int = 8
const FA_ELIGIBLE_YEARS_OTHER: int = 7
const FA_SERVICE_DAYS_PER_YEAR: int = 145
# 高卒のデビュー年齢 (これ以下なら高卒出身と推定)。初期シード選手は draft_source 列が無いため。
const HIGH_SCHOOL_DEBUT_AGE: int = 18

# z-score 内部能力値の正準キー。能力計算は raw z を直接読み、UI 表示だけ z_display() で変換する。
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

# ゲーム本体は z 能力 (z_ability / z_display) のみを使う。

# 球速は z ではなく raw_abilities["max_velocity"] に km/h の生値で保持する。

# 調子段階。負数ほど不調、正数ほど好調として一部の自動起用ロジックが参照する。
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
# 初期シード投手は読み込み時に backfill され、ドラフト/外国人の生成投手は生成時に埋まるので通常は非空。
# 空の場合(旧セーブ等)は record 側 arsenal_or_derived() が z から派生する。詳細 PSPitchTypes。
var arsenal: Array = []
var fatigue: int
var injury_days: int
# 怪我の種類(部位/病名ラベル)と重症度ティア(0=軽傷..3=重大手術)。injury_days>0 のとき有効。PSInjuryModel が設定。
var injury_type: String = ""
var injury_severity: int = 0
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
	injury_type = str(data.get("injury_type", ""))
	injury_severity = int(data.get("injury_severity", 0))
	condition = clampi(int(data.get("condition", 0)), CONDITION_MIN, CONDITION_MAX)
	fixed_slot = int(data.get("fixed_slot", 0))
	allowed_slots = _normalize_slot_array(data.get("allowed_slots", []))
	preferred_slots = _normalize_slot_array(data.get("preferred_slots", []))
	# FA閾値: 保存値があれば尊重、無ければ (初期シード CSV は列を持たない) 出身から既定計算。
	fa_eligible_years = int(data.get("fa_eligible_years", 0))
	if fa_eligible_years <= 0:
		fa_eligible_years = _default_fa_eligible_years()


func is_pitcher() -> bool:
	return position == 1 or role == "starter" or role == "reliever" or role == "closer"


func is_retired() -> bool:
	return bool(source_data.get("retired", false))


# 複数年契約は source_data.contract_end_year (契約がカバーする最終シーズン年) で表す。
# 0 は無契約 (単年契約扱い)。締結年・表示用の総年数は contract_signed_year / contract_total_years。
#
# シーズン中の操作 (トレード判定): 契約最終年もロック対象に含める (>=)。
func is_multi_year_locked_in_season(season_year: int) -> bool:
	return int(source_data.get("contract_end_year", 0)) >= season_year


# オフの操作 (年俸査定/FA宣言/戦力外/育成降格の判定): 契約最終年のオフは契約満了扱いで
# ロック対象から外れる (>)。NPB実態 (複数年契約の最終年オフに FA 宣言できる) に合わせている。
func is_multi_year_locked_offseason(offseason_year: int) -> bool:
	return int(source_data.get("contract_end_year", 0)) > offseason_year


# 表示用の残り年数 (オフ時点)。契約満了/無契約なら 0。
func contract_years_remaining(offseason_year: int) -> int:
	return maxi(0, int(source_data.get("contract_end_year", 0)) - offseason_year)


# 今オフ FA宣言したか。宣言はオフ冒頭の FA宣言ステップで決まるが、ロースターからの離脱
# (team_id=0) は FA市場ステップまで起きない。その間に戦力外/現役ドラフト/引退で消えないよう、
# 各ステップはこのフラグで宣言者を対象外にする。
func is_fa_declared(offseason_year: int) -> bool:
	return offseason_year > 0 and int(source_data.get("fa_declared_year", 0)) == offseason_year


# 今オフ FA権を新規取得したか。取得したてのFA権者は戦力外/育成降格の対象にしない。
func is_new_fa_holder(offseason_year: int) -> bool:
	return offseason_year > 0 and int(source_data.get("fa_eligible_year", 0)) == offseason_year


# 支配下経験のある育成選手か。NPB の規約は「支配下選手登録されたことのある者が育成選手として
# 契約した次年度に支配下契約されなければ自由契約」で、新規の育成選手 (3年) より契約が短い。
# 育成降格と、戦力外からの育成track再契約 (元支配下) で立つ。
func is_development_from_controlled() -> bool:
	return development_player and bool(source_data.get("dev_from_controlled", false))


# 育成契約のまま消化したシーズン数 (育成でなければ 0)。`development_since_year` は
# 育成になったオフの年 (育成ドラフト指名年 / 降格したオフ / 育成trackでの獲得年) で、
# 支配下登録 (昇格) で消える。NPB の育成契約の年数上限に相当する判定に使う。
#   育成になったオフ = 0 / その翌オフ = 1 / …
func development_seasons_completed(offseason_year: int) -> int:
	if not development_player or offseason_year <= 0:
		return 0
	var since: int = int(source_data.get("development_since_year", 0))
	if since <= 0:
		return 0
	return maxi(0, offseason_year - since)


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


# FA権取得までの残り年数相当 (0 = 既に取得済み = 保有権消滅)。
func fa_remaining_years() -> int:
	var remaining_days: int = maxi(0, fa_service_days_required() - fa_service_days())
	return int(ceil(float(remaining_days) / float(FA_SERVICE_DAYS_PER_YEAR)))


# 1軍登録日数が閾値に達し、自由移籍可能 (FA権取得済み) か。
func is_fa_eligible() -> bool:
	return fa_service_days() >= fa_service_days_required()


func fa_service_days_required() -> int:
	return maxi(1, fa_eligible_years) * FA_SERVICE_DAYS_PER_YEAR


func fa_service_days() -> int:
	if source_data.has("fa_nissuu"):
		return maxi(0, int(source_data.get("fa_nissuu", 0)))
	return maxi(0, years) * FA_SERVICE_DAYS_PER_YEAR


static func fielding_ability_category_for_position(position_id: int) -> String:
	return str(FIELDING_ABILITY_CATEGORY_BY_POSITION.get(position_id, ""))


static func position_experience_key(position_id: int) -> String:
	return str(POSITION_EXPERIENCE_KEYS.get(position_id, ""))


static func default_position_experience(position_id: int = 0, p_position_aptitudes: Dictionary = {}) -> Dictionary:
	var experience: Dictionary = {}
	for key_value in POSITION_EXPERIENCE_KEYS.values():
		var key: String = str(key_value)
		experience[key] = int(p_position_aptitudes.get(key, 0))

	var primary_key: String = position_experience_key(position_id)
	if not primary_key.is_empty() and int(experience.get(primary_key, 0)) <= 0:
		experience[primary_key] = 100
	return experience


static func normalized_position_experience(source: Dictionary, position_id: int = 0, p_position_aptitudes: Dictionary = {}) -> Dictionary:
	var experience: Dictionary = default_position_experience(position_id, p_position_aptitudes)
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
		"injury_type": injury_type,
		"injury_severity": injury_severity,
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


func is_starter_pitcher() -> bool:
	var model: GDScript = load("res://services/simulation/models/pitcher_role_model.gd") as GDScript
	return model.is_starter_player(self)


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
