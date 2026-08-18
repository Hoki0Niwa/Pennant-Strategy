extends RefCounted
class_name PSBalanceProfile

# 打席計算用の純粋数式ヘルパー集（確率・logit・softmax・能力カーブ）。
# ここにはチューニング値を置かず、各計算ファイルの const がバランス調整ノブを持つ。


# 能力 z を [-1, 1] のS字カーブへ写す。center が中立点、width が立ち上がりの広がり。
static func ability_curve_z(z: float, center: float = 0.4, width: float = 1.6) -> float:
	var x: float = clamp((z - center) / max(0.001, width), -4.0, 4.0)
	return 2.0 / (1.0 + exp(-2.0 * x)) - 1.0


# z の pivot 超過分を tanh で漸近圧縮する。pivot 以下は不変、超過分は span を漸近上限に飽和。
# 集団平均帯の能力差は保ったまま、テール(エース級)が logit へ線形に効き続けるのを止める用途。
static func compress_z_tail(z: float, pivot: float, span: float) -> float:
	if z <= pivot:
		return z
	return pivot + span * tanh((z - pivot) / max(0.001, span))


# 対戦優位 (打者項 - 投手項) を pivot 超過分だけ tanh で両側に飽和させる。
# compress_z_tail との違い: **個々の能力ではなく投打の差に掛ける**。
# 両者が同じだけ弱くなっても差は動かないので、
#   - リーグ全体の水準が下がっても得点環境は動かない (レベル不変性が構造的に保たれる)
#   - 同水準どうしのリーグ内部の能力差はそのまま残る (二軍の中の優劣が潰れない)
#   - 極端なミスマッチ (専用球団 vs 12球団、エース vs 弱打者) だけが飽和する
# という3つが同時に成り立つ。個々の能力に下側圧縮を掛ける方式ではこれが両立しない。
static func compress_matchup_advantage(delta: float, pivot: float, span: float) -> float:
	var magnitude: float = absf(delta)
	if magnitude <= pivot:
		return delta
	var excess: float = magnitude - pivot
	return signf(delta) * (pivot + span * tanh(excess / max(0.001, span)))


static func sigmoid(logit_value: float) -> float:
	return 1.0 / (1.0 + exp(-clamp(logit_value, -12.0, 12.0)))


static func logit(probability: float) -> float:
	var p: float = clamp(probability, 0.000001, 0.999999)
	return log(p / (1.0 - p))


