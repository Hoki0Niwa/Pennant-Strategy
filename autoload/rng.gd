extends Node

# ゲーム全体で共有する乱数源。
# seed を固定すればドラフト生成や試合シミュレーションの再現性を取りやすくなる。
signal seed_changed(seed_value: int)

var generator: RandomNumberGenerator = RandomNumberGenerator.new()
var current_seed: int = 1

# 試合の並列実行用レーン機構(計測実験: ロックフリー版)。
# OS.get_thread_caller_id() % MAX_LANES を直接インデックスにした専用スロットを各スレッドが
# 排他的に読み書きする。Godotの WorkerThreadPool は物理スレッド数が起動時に固定・再利用される
# ため(このマシンでは12コア)、MAX_LANES=64 は衝突の実用上のリスクがない。配列は _ready() で
# 事前確保して以後リサイズしないため、異なるスロットへの並行アクセスはロック不要
# (Thread-safe APIs: 「サイズを変える操作」だけがロック必須という規定に合致)。
# レーンを登録しない全ての既存呼び出し元(ドラフト・オフシーズン・トレード・単発試合デバッグ等)
# は自スロットが非activeのため従来通り共有 generator を使う。
const MAX_LANES: int = 64
var _lane_generators: Array[RandomNumberGenerator] = []
var _lane_active: Array[bool] = []


func _ready() -> void:
	randomize_seed()
	_lane_generators.resize(MAX_LANES)
	_lane_active.resize(MAX_LANES)
	for i in range(MAX_LANES):
		_lane_generators[i] = RandomNumberGenerator.new()
		_lane_active[i] = false


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


# 呼び出し中のスレッド専用スロットへ seed を設定し active にする。lane_id は
# WorkerThreadPool のグループ内相対インデックス(呼び出し元の識別用、スロット選択には使わない)。
# seed_key は世界seed+試合の一意識別子から呼び出し側が決定論的に合成する
# (例: hash([Rng.current_seed, season.year, season.season_number, game_index]))。
# これにより並列実行と逐次実行で同一試合が完全に同一の乱数列を得る。
func begin_game_stream(_lane_id: int, seed_key: int) -> void:
	var slot: int = _slot_for_current_thread()
	_lane_generators[slot].seed = hash(seed_key)
	_lane_active[slot] = true


# レーン登録を解除する。呼び出し中のスレッドがそのレーンの試合計算を終えた直後に呼ぶ。
func end_game_stream() -> void:
	_lane_active[_slot_for_current_thread()] = false


func _slot_for_current_thread() -> int:
	return int(OS.get_thread_caller_id() % MAX_LANES)


# 呼び出し中のスレッド専用スロットが active ならそこの generator を返す。非active(メインスレッドの
# 通常処理等)なら従来の共有 generator にフォールバックし、挙動は一切変わらない。
func _generator_for_current_thread() -> RandomNumberGenerator:
	var slot: int = _slot_for_current_thread()
	if _lane_active[slot]:
		return _lane_generators[slot]
	return generator


# 0.0 <= x < 1.0 の一様乱数。
func roll_float() -> float:
	return _generator_for_current_thread().randf()


# 1〜100 の整数ロール。確率判定で「percent 以下なら成功」の形に使う。
func roll_percent() -> int:
	return _generator_for_current_thread().randi_range(1, 100)


# 両端を含む整数範囲乱数。
func range_int(min_value: int, max_value: int) -> int:
	return _generator_for_current_thread().randi_range(min_value, max_value)
