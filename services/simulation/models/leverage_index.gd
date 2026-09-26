extends RefCounted
class_name PSLeverageIndex

# 場面の Leverage Index を引く。LI は次の 1 打席で勝敗がどれだけ動きうるかを、全打席平均 = 1.0 に
# 正規化した値 (9 回裏 1 点ビハインド満塁 2 死で約 11、大差の序盤で 0.1 前後)。
# 救援投手の gmLI (登板時点の LI の平均) を測り、WAR の救援レバレッジ補正に使う。
# 表は tools/gen_leverage_index_table.py が生成する。12 回を超える回と ±DIFF_LIMIT を超える点差は端の値で引く。

const Table = preload("res://services/simulation/models/leverage_index_table.gd")

const STATES_PER_DIFF: int = 24 # アウト 0..2 × 走者 0..7


# inning は 1 始まり、home_minus_away はその時点のホーム - ビジターの得点差。
# bases_mask は 一塁=1 / 二塁=2 / 三塁=4 のビット和。
static func for_state(inning: int, is_bottom: bool, home_minus_away: int, outs: int, bases_mask: int) -> float:
	var diff_count: int = Table.DIFF_LIMIT * 2 + 1
	var inning_index: int = clampi(inning, 1, Table.MAX_INNING) - 1
	var half_index: int = 1 if is_bottom else 0
	var diff_index: int = clampi(home_minus_away, -Table.DIFF_LIMIT, Table.DIFF_LIMIT) + Table.DIFF_LIMIT
	var state_index: int = clampi(outs, 0, 2) * 8 + (bases_mask & 7)
	var index: int = ((inning_index * 2 + half_index) * diff_count + diff_index) * STATES_PER_DIFF + state_index
	return Table.VALUES[index]


# 試合ループの塁配列 (走者の record、空塁は null) をビット和へ変換する。
static func occupied_bases_mask(bases: Array) -> int:
	var mask: int = 0
	for index in range(mini(3, bases.size())):
		if bases[index] != null:
			mask |= 1 << index
	return mask
