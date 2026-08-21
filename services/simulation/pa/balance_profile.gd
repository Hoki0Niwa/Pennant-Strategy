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


# 対戦優位 (打者項 - 投手項) を pivot 超過分だけ tanh で飽和させる。
# compress_z_tail との違い: **個々の能力ではなく投打の差に掛ける**。
# 両者が同じだけ弱くなっても差は動かないので、
#   - リーグ全体の水準が下がっても得点環境は動かない (レベル不変性が構造的に保たれる)
#   - 同水準どうしのリーグ内部の能力差はそのまま残る (二軍の中の優劣が潰れない)
#   - 極端なミスマッチ (専用球団 vs 12球団、エース vs 弱打者) だけが飽和する
# という3つが同時に成り立つ。個々の能力に下側圧縮を掛ける方式ではこれが両立しない。
#
# 天井は正負で別に持てる。**符号の意味は呼び出し側の delta の作り方で決まる** ので、
# 非対称にするなら呼び出し側の向きを確認すること (打球品質は正 = 打者優位)。
# 非対称にする理由: 失点は 0 で下げ止まるので投手優位の効果は早く飽和するが、打撃の上振れには
# 同じ頭打ちが無い。実 NPB でも「規定投手の防御率下限 ~1.2」に対し「本塁打王 40-56」と応答が
# 非対称になる。両側を同じ天井にすると、本塁打王を戻すと同時に 1 点台の投手が増えすぎる。
static func compress_matchup_advantage(
	delta: float,
	pivot: float,
	span: float,
	negative_pivot: float = -1.0,
	negative_span: float = -1.0
) -> float:
	var side_pivot: float = pivot
	var side_span: float = span
	if delta < 0.0 and negative_pivot >= 0.0 and negative_span >= 0.0:
		side_pivot = negative_pivot
		side_span = negative_span
	var magnitude: float = absf(delta)
	if magnitude <= side_pivot:
		return delta
	var excess: float = magnitude - side_pivot
	return signf(delta) * (side_pivot + side_span * tanh(excess / max(0.001, side_span)))


static func sigmoid(logit_value: float) -> float:
	return 1.0 / (1.0 + exp(-clamp(logit_value, -12.0, 12.0)))


static func logit(probability: float) -> float:
	var p: float = clamp(probability, 0.000001, 0.999999)
	return log(p / (1.0 - p))


