extends Node

# ゲーム全体で共有する乱数源。
# seed を固定すればドラフト生成や試合シミュレーションの再現性を取りやすくなる。
signal seed_changed(seed_value: int)

var generator: RandomNumberGenerator = RandomNumberGenerator.new()
var current_seed: int = 1


func _ready() -> void:
	randomize_seed()


# 現在時刻由来で seed を初期化する通常プレイ用の入口。
func randomize_seed() -> void:
	generator.randomize()
	current_seed = generator.seed
	seed_changed.emit(current_seed)


# テスト/レポート/再現調査用に seed を明示設定する。
func set_seed_value(seed_value: int) -> void:
	current_seed = seed_value
	generator.seed = seed_value
	seed_changed.emit(current_seed)


# 0.0 <= x < 1.0 の一様乱数。
func roll_float() -> float:
	return generator.randf()


# 1〜100 の整数ロール。確率判定で「percent 以下なら成功」の形に使う。
func roll_percent() -> int:
	return generator.randi_range(1, 100)


# 両端を含む整数範囲乱数。
func range_int(min_value: int, max_value: int) -> int:
	return generator.randi_range(min_value, max_value)
