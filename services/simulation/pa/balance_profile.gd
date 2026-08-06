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


static func sigmoid(logit_value: float) -> float:
	return 1.0 / (1.0 + exp(-clamp(logit_value, -12.0, 12.0)))


static func logit(probability: float) -> float:
	var p: float = clamp(probability, 0.000001, 0.999999)
	return log(p / (1.0 - p))


