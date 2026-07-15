extends RefCounted
class_name PSPlayerValueEvaluator


const MIN_VISIBLE_SCORE: int = 1
const MAX_VISIBLE_SCORE: int = 99
const ZERO_APTITUDE_SCORE: int = -999999

# 守備適性が 100 でないポジションを守るときの守備能力ペナルティ。
# 適性 100 で gap=0 → 無ペナルティ。適性が低いほど、また守備の難しいポジションほど大きく減点。
# 難易度は FieldingModel.POSITION_AVG_ABILITY_SCORE から導出 (_position_difficulty)。
const MAX_OFF_POSITION_PENALTY: float = 22.0   # 難易度 1.0 (CF) ・適性 0 で最大
const MIN_OFF_POSITION_PENALTY: float = 6.0    # 易しいポジ (1B) でも適性 0 なら最低これだけ減点
const POSITION_DIFFICULTY_MIN_AVG: float = 0.20   # POSITION_AVG_ABILITY_SCORE の最小 (1B, z)
const POSITION_DIFFICULTY_MAX_AVG: float = 2.16   # POSITION_AVG_ABILITY_SCORE の最大 (SS, z)

# スタメン選出 (starter_assignment_score) で使う打撃/守備のブレンド比率。
# fallback は全体集計の 76/24。守備位置ごとの評価では下の position 別比率を使う。
# 守備のみで選ぶと選手 1 人あたり ~16 runs/season の機会損失が出ることが
# バランス調査で判明したため、打撃を主軸にした総合力でスタメンを決める。
const STARTER_OFFENSE_WEIGHT: float = 0.76
const STARTER_DEFENSE_WEIGHT: float = 0.24
const STARTER_OFFENSE_WEIGHT_BY_POSITION: Dictionary = {
	2: 0.80,
	3: 0.84,
	4: 0.77,
	5: 0.84,
	6: 0.81,
	7: 0.76,
	8: 0.70,
	9: 0.68,
}

const POSITION_APTITUDE_KEYS: Dictionary = {
	2: "catcher",
	3: "first",
	4: "second",
	5: "third",
	6: "shortstop",
	7: "left",
	8: "center",
	9: "right",
}

# --- 守備実績 (シーズン累積 OAA) の配置反映 ---
# 能力推定ではなく「その守備位置で実際に出た OAA」を配置スコアへ加減算する。
# 生 OAA には小さな残バイアス (2026-07-06 実測 ≈ -0.004/機会) があるが、rating 換算 ~1 点なので
# センタリングなしで使う (WAR 側は従来どおり recenter_fielding 経由)。
# サンプル不足の暴れは prior chances で縮約し、FIELDING_RESULT_MIN_CHANCES 未満は無視する
# (up-the-middle の守備機会は年 ~1000-1200 なので 120 は 2-3 週間相当)。
const FIELDING_RESULT_MIN_CHANCES: int = 120
const FIELDING_RESULT_PRIOR_CHANCES: float = 150.0
const FIELDING_RESULT_RATING_SCALE: float = 300.0
const FIELDING_RESULT_RATING_MIN: float = -8.0
const FIELDING_RESULT_RATING_MAX: float = 5.0
# 実績が「崩壊」とみなす rating 換算値 (フルシーズン OAA -13 前後に相当) と、
# 崩壊時に配置 AI が自動降格の対象にする守備負荷の高い位置 (C/2B/SS/CF)。
const FIELDING_COLLAPSE_RATING_DELTA: float = -6.0
const FIELDING_COLLAPSE_POSITIONS: Dictionary = {2: true, 4: true, 6: true, 8: true}


# 当該守備位置でのシーズン実績 OAA を rating 点 (blend と同スケール) へ換算する。
static func realized_fielding_rating_delta(record: PSPlayerSeasonRecord, position: int) -> float:
	if record == null or record.advanced_stats == null:
		return 0.0
	var key: String = str(position)
	var chances: int = int(record.advanced_stats.fielding_chances_by_position.get(key, 0))
	if chances < FIELDING_RESULT_MIN_CHANCES:
		return 0.0
	var oaa: float = float(record.advanced_stats.oaa_by_position.get(key, 0.0))
	var delta: float = oaa / (float(chances) + FIELDING_RESULT_PRIOR_CHANCES) * FIELDING_RESULT_RATING_SCALE
	return clampf(delta, FIELDING_RESULT_RATING_MIN, FIELDING_RESULT_RATING_MAX)


# 守備負荷の高い位置で実績が崩壊しているか。配置 AI (ai_generated usage) の自動降格と
# オフのコンバート AI が共有する判定。
static func fielding_collapsed_at_position(record: PSPlayerSeasonRecord, position: int) -> bool:
	if not FIELDING_COLLAPSE_POSITIONS.has(position):
		return false
	return realized_fielding_rating_delta(record, position) <= FIELDING_COLLAPSE_RATING_DELTA


# 画面表示・ロスター査定で使う基礎評価。累積疲労による一時的な低下は含めない。
static func overall_score(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	if record.is_pitcher():
		return _pitcher_eval_score(record, false)
	return _fielder_starter_score(record, false)


static func overall_score_with_fatigue(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 0
	if record.is_pitcher():
		return _pitcher_eval_score(record, true)
	return _fielder_starter_score(record, true)


# 旧呼び名との互換 alias。新規コードでは overall_score を使う。
static func overall_score_without_fatigue(record: PSPlayerSeasonRecord) -> int:
	return overall_score(record)


static func fielder_starter_score(record: PSPlayerSeasonRecord) -> int:
	return _fielder_starter_score(record, true)


static func _fielder_starter_score(record: PSPlayerSeasonRecord, apply_fatigue_penalty: bool) -> int:
	if record == null:
		return 0
	var best: Dictionary = best_defensive_fit(record)
	var best_position: int = int(best.get("position", 0))
	var best_defense: int = int(best.get("score", 0))
	var offense: int = _batting_score(record, apply_fatigue_penalty)
	var offense_weight: float = starter_offense_weight_for_position(best_position)
	var defense_weight: float = starter_defense_weight_for_position(best_position)
	return _visible_score(float(offense) * offense_weight + float(best_defense) * defense_weight)


static func batting_score(record: PSPlayerSeasonRecord) -> int:
	return _batting_score(record, true)


static func batting_score_without_fatigue(record: PSPlayerSeasonRecord) -> int:
	return _batting_score(record, false)


static func _batting_score(record: PSPlayerSeasonRecord, apply_fatigue_penalty: bool) -> int:
	if record == null:
		return 0
	# fatigue は display 点で減点していた値を z 換算 (÷12.5)。能力下限は display 1 = z -3.92。
	var fatigue_penalty: float = ((float(record.fatigue) / 5.0) / 12.5) if apply_fatigue_penalty else 0.0
	var contact: float = max(-3.92, _batting(record, "contact") - fatigue_penalty)
	var eye: float = max(-3.92, _batting(record, "eye") - fatigue_penalty)
	var avoid_k: float = max(-3.92, record.z_ability("Bat_KAvoid", 0.0) - fatigue_penalty)
	var gap_power: float = max(-3.92, _batting(record, "gap_power") - fatigue_penalty)
	var home_run_power: float = max(-3.92, _batting(record, "home_run_power") - fatigue_penalty)
	var speed: float = max(-3.92, record.z_ability("Run_Speed", 0.0) - fatigue_penalty)

	var contact_curve: float = _ability_curve(contact, 0.4, 1.6)
	var eye_curve: float = _ability_curve(eye, 0.4, 1.44)
	var avoid_k_curve: float = _ability_curve(avoid_k, 0.4, 1.44)
	var gap_curve: float = _ability_curve(gap_power, 0.4, 1.6)
	var home_run_curve: float = _ability_curve(home_run_power, 0.4, 1.6)
	var speed_curve: float = _ability_curve(speed, 0.4, 1.6)

	var score: float = 50.0
	score += contact_curve * 18.0
	score += eye_curve * 8.0
	score += avoid_k_curve * 7.0
	score += gap_curve * 7.0
	score += home_run_curve * 12.0
	score += speed_curve * 4.0
	if record.is_pitcher():
		score -= 18.0
	return _visible_score(score)


static func pitching_score(record: PSPlayerSeasonRecord) -> int:
	return _pitching_score(record, true)


static func pitching_score_without_fatigue(record: PSPlayerSeasonRecord) -> int:
	return _pitching_score(record, false)


static func _pitching_score(record: PSPlayerSeasonRecord, apply_fatigue_penalty: bool) -> int:
	if record == null:
		return 0
	# breaking(45-160) と velocity(球速) は例外スケールのため display 点の fatigue を維持。
	# z 能力には z 換算 (÷12.5) の penalty を使う。能力下限は display 1 = z -3.92。
	@warning_ignore("integer_division")
	var fatigue_penalty: int = int(record.fatigue / 4) if apply_fatigue_penalty else 0
	var fatigue_penalty_z: float = float(fatigue_penalty) / 12.5
	var control: float = max(-3.92, record.z_ability("Pit_BBPrevent", 0.0) - fatigue_penalty_z)
	var stuff: float = max(-3.92, record.z_ability("Pit_KCreate", 0.0) - fatigue_penalty_z)
	var movement: float = max(-3.92, record.z_ability("Pit_LoftControl", 0.0) - fatigue_penalty_z)
	var stamina: float = max(-3.92, record.z_ability("Pit_Stamina", 0.0) - fatigue_penalty_z)
	var velocity: int = _max_velocity(record)
	var breaking: int = max(1, record.breaking_score() - fatigue_penalty * 3)

	var control_curve: float = _ability_curve(control, 0.4, 1.52)
	var stuff_curve: float = _ability_curve(stuff, 0.4, 1.6)
	var movement_curve: float = _ability_curve(movement, 0.4, 1.6)
	var stamina_curve: float = _ability_curve(stamina, 0.4, 1.6)
	var velocity_curve: float = _ability_curve(float(velocity), 145.0, 8.0)
	var breaking_curve: float = _ability_curve(float(breaking), 105.0, 28.0)

	var score: float = 50.0
	score += control_curve * 15.0
	score += stuff_curve * 13.0
	score += movement_curve * 13.0
	score += velocity_curve * 5.0
	score += breaking_curve * 10.0
	score += stamina_curve * 5.0
	return _visible_score(score)


# 投手評価値は役割別に算出する。pitching_score (継投選抜用の素の投手力) は変えない。
# 先発: pitching_score と同じ要素だが係数を圧縮し、野手 (fielder_starter_score) と同スケールにする。
# 中継: 持久を外し、奪三振 (stuff) / 球速 / 際どさ (edge) を強調。先発=野手と同スケールに較正。
# 初期選手母集団で投手・野手の平均評価が同じ尺度になる基準点。
const PITCHER_EVAL_BASE: float = 49.0
const STARTER_EVAL_WEIGHTS: Dictionary = {
	"control": 11.1, "stuff": 9.6, "movement": 9.6,
	"velocity": 3.7, "breaking": 7.4, "stamina": 3.7, "edge": 0.0,
}
const RELIEVER_EVAL_WEIGHTS: Dictionary = {
	"control": 8.4, "stuff": 12.6, "movement": 8.4,
	"velocity": 6.0, "breaking": 7.2, "stamina": 0.0, "edge": 6.0,
}


static func starter_eval_score(record: PSPlayerSeasonRecord) -> int:
	return _pitcher_eval_score(record, true, STARTER_EVAL_WEIGHTS)


static func reliever_eval_score(record: PSPlayerSeasonRecord) -> int:
	return _pitcher_eval_score(record, true, RELIEVER_EVAL_WEIGHTS)


# 役割で重みを切り替える表示評価値。weights 省略時は保存 role から先発/中継を判定する。
static func _pitcher_eval_score(record: PSPlayerSeasonRecord, apply_fatigue_penalty: bool, weights: Dictionary = {}) -> int:
	if record == null:
		return 0
	if weights.is_empty():
		weights = STARTER_EVAL_WEIGHTS if record.is_starter_pitcher() else RELIEVER_EVAL_WEIGHTS
	@warning_ignore("integer_division")
	var fatigue_penalty: int = int(record.fatigue / 4) if apply_fatigue_penalty else 0
	var fatigue_penalty_z: float = float(fatigue_penalty) / 12.5
	var control: float = max(-3.92, record.z_ability("Pit_BBPrevent", 0.0) - fatigue_penalty_z)
	var stuff: float = max(-3.92, record.z_ability("Pit_KCreate", 0.0) - fatigue_penalty_z)
	var movement: float = max(-3.92, record.z_ability("Pit_LoftControl", 0.0) - fatigue_penalty_z)
	var stamina: float = max(-3.92, record.z_ability("Pit_Stamina", 0.0) - fatigue_penalty_z)
	var edge: float = max(-3.92, record.z_ability("Pit_EdgeRate", 0.0) - fatigue_penalty_z)
	var velocity: int = _max_velocity(record)
	var breaking: int = max(1, record.breaking_score() - fatigue_penalty * 3)

	var score: float = PITCHER_EVAL_BASE
	score += _ability_curve(control, 0.4, 1.52) * float(weights.get("control", 0.0))
	score += _ability_curve(stuff, 0.4, 1.6) * float(weights.get("stuff", 0.0))
	score += _ability_curve(movement, 0.4, 1.6) * float(weights.get("movement", 0.0))
	score += _ability_curve(stamina, 0.4, 1.6) * float(weights.get("stamina", 0.0))
	score += _ability_curve(edge, 0.4, 1.6) * float(weights.get("edge", 0.0))
	score += _ability_curve(float(velocity), 145.0, 8.0) * float(weights.get("velocity", 0.0))
	score += _ability_curve(float(breaking), 105.0, 28.0) * float(weights.get("breaking", 0.0))
	return _visible_score(score)


static func defensive_score_for_position(record: PSPlayerSeasonRecord, position: int) -> int:
	if record == null:
		return 0
	var skill: float = FieldingModel.fielding_score_for_position(record, position)
	var average: float = FieldingModel.position_average_ability_score(position)
	# skill/average は raw z スケール。出力 rating(≈50基準) を保つため係数を ×12.5 (0.85→10.625)。
	var score: float = 50.0 + (skill - average) * 10.625
	if position >= 2 and position <= 9:
		# 適性 100 でのみ無ペナルティ。未満は適性ギャップ × ポジション難易度に比例して減点。
		var aptitude: int = position_aptitude(record, position)
		var gap: float = float(100 - clampi(aptitude, 0, 100)) / 100.0
		var weight: float = MIN_OFF_POSITION_PENALTY + (MAX_OFF_POSITION_PENALTY - MIN_OFF_POSITION_PENALTY) * _position_difficulty(position)
		score -= weight * gap
	return _visible_score(score)


# ポジション難易度 0.0 (易) 〜 1.0 (難)。FieldingModel.POSITION_AVG_ABILITY_SCORE が高いほど難しい。
# 1B=0.0, LF=0.19, SS=0.58, 2B=0.92, CF=1.0。
static func _position_difficulty(position: int) -> float:
	var avg: float = FieldingModel.position_average_ability_score(position)
	var span: float = POSITION_DIFFICULTY_MAX_AVG - POSITION_DIFFICULTY_MIN_AVG
	if span <= 0.0:
		return 0.0
	return clamp((avg - POSITION_DIFFICULTY_MIN_AVG) / span, 0.0, 1.0)


static func defensive_assignment_score(record: PSPlayerSeasonRecord, position: int, require_aptitude: bool = true) -> int:
	if record == null:
		return ZERO_APTITUDE_SCORE
	var aptitude: int = position_aptitude(record, position)
	if require_aptitude and position >= 2 and position <= 9 and aptitude <= 0:
		return ZERO_APTITUDE_SCORE
	var score: int = defensive_score_for_position(record, position) * 100
	score += aptitude
	if record.position == position:
		score += 1500
	elif aptitude >= 90:
		score += 60
	if position >= 2 and position <= 9 and aptitude <= 0:
		score -= 6000
	return score


# スタメン選出用のスコア。defensive_assignment_score と同じ aptitude チェック /
# primary bonus / penalty を踏襲しつつ、コア部分を「打撃 + 守備」の
# position 別ブレンドに置き換える。
# DefenseAlignmentService と team_setup_builder の saved-lineup fallback で使う。
# defensive_assignment_score は純守備指標として残してあるので、将来「守備固め」など
# 純守備で選びたいケースは引き続きそちらを使える。
#
# batting_score_override: 0 以上を渡すと batting_score(record) の再計算を省略する。
# 同じ候補が 8 ポジション × N 候補のループ中で何度も評価されるため、呼び出し側で
# 1 度だけ batting_score を計算してキャッシュしてから渡すことで重複計算を避けられる。
static func starter_assignment_score(
	record: PSPlayerSeasonRecord,
	position: int,
	_require_aptitude: bool = true,
	batting_score_override: int = -1,
) -> int:
	if record == null:
		return ZERO_APTITUDE_SCORE
	var aptitude: int = position_aptitude(record, position)
	if position >= 2 and position <= 9 and aptitude <= 0:
		return ZERO_APTITUDE_SCORE
	# 「best-fit 守備込みの総合値」ではなく、割り当て position での守備力
	# (defensive_score_for_position = 適性ペナルティ込み) と打撃を position 別比率で
	# ブレンドした「その守備位置での総合力」をコアにする。これにより適性の低いポジに
	# 置かれた選手は守備ペナルティ分だけ選出スコアが下がり、単純な総合値だけで決まらない。
	var offense: int = batting_score_override if batting_score_override >= 0 else batting_score(record)
	var position_defense: int = defensive_score_for_position(record, position)
	var offense_weight: float = starter_offense_weight_for_position(position)
	var defense_weight: float = starter_defense_weight_for_position(position)
	var position_overall: float = float(offense) * offense_weight + float(position_defense) * defense_weight
	var score: int = int(round(position_overall * 100.0))
	# 守備実績: その位置で実際に出た OAA (縮約済み) を rating 点のまま加減算する。
	# 能力ブレンドの defense weight は掛けない — 実績はその位置で失った/稼いだ run の直接証拠のため。
	score += int(round(realized_fielding_rating_delta(record, position) * 100.0))
	score += aptitude
	# 在籍(同一守備位置)ボーナスはタイブレーク規模 (+250 ≒ 2.5 ブレンド点) に留める。
	# 旧 +1500 は格下の現レギュラーを固定し「惰性」を生んでいた。挑戦者が ~2.5 点以上
	# 明確に上なら定位置を奪い、同程度なら現レギュラーが残る (実績+能力が拮抗なら現役優先)。
	if record.position == position:
		score += 250
	elif aptitude >= 90:
		score += 60
	return score


static func starter_offense_weight_for_position(position: int) -> float:
	return clamp(float(STARTER_OFFENSE_WEIGHT_BY_POSITION.get(position, STARTER_OFFENSE_WEIGHT)), 0.0, 1.0)


static func starter_defense_weight_for_position(position: int) -> float:
	if STARTER_OFFENSE_WEIGHT_BY_POSITION.has(position):
		return 1.0 - starter_offense_weight_for_position(position)
	return STARTER_DEFENSE_WEIGHT


static func best_defensive_fit(record: PSPlayerSeasonRecord) -> Dictionary:
	var best_position: int = 0
	var best_score: int = 0
	for position in [2, 3, 4, 5, 6, 7, 8, 9]:
		if position_aptitude(record, position) <= 0:
			continue
		var score: int = defensive_score_for_position(record, position)
		if best_position == 0 or score > best_score:
			best_position = position
			best_score = score
	if best_position == 0 and record.position >= 2 and record.position <= 9:
		best_position = record.position
		best_score = defensive_score_for_position(record, record.position)
	return {
		"position": best_position,
		"score": best_score,
	}


static func position_aptitude(record: PSPlayerSeasonRecord, position: int) -> int:
	if record == null:
		return 0
	var key: String = str(POSITION_APTITUDE_KEYS.get(position, ""))
	if key.is_empty():
		return 0
	if record.position_aptitudes_snapshot.is_empty():
		return 100 if record.position == position else 0
	return int(record.position_aptitudes_snapshot.get(key, 0))


static func _batting(record: PSPlayerSeasonRecord, key: String, default_value: float = 0.0) -> float:
	if record == null:
		return default_value
	match key:
		"contact":
			return record.z_ability("Bat_Barrel", 0.0)
		"eye":
			return record.z_ability("Bat_BBCreate", 0.0)
		"gap_power":
			return record.z_ability("Bat_Impact", 0.0)
		"home_run_power":
			return record.z_ability("Bat_Impact", 0.0)
	return default_value


static func _max_velocity(record: PSPlayerSeasonRecord) -> int:
	if record == null:
		return 142
	var max_velocity: int = record.max_velocity_display()
	if max_velocity > 0:
		return max_velocity
	return record.z_display("Pit_KCreate", 2.0) + 70


static func _visible_score(value: float) -> int:
	return int(clamp(round(value), float(MIN_VISIBLE_SCORE), float(MAX_VISIBLE_SCORE)))


static func _ability_curve(value: float, center: float = 0.4, width: float = 1.6) -> float:
	var x: float = clamp((value - center) / max(1.0, width), -4.0, 4.0)
	return 2.0 / (1.0 + exp(-2.0 * x)) - 1.0
