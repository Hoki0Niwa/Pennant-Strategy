"""Leverage Index (LI) 表を生成して services/simulation/models/leverage_index_table.gd を書き出す。

LI は「その場面の次の 1 打席で、勝利確率がどれだけ動きうるか」を全打席平均 = 1.0 に正規化した値
(Tom Tango の定義)。救援投手の gmLI (登板時点の LI の平均) を試合中に測るために使う。

手順:
  1. 打席イベント率 (PA_EVENTS) と走者の進塁ルールから、24 の塁・アウト状態ごとに
     「イニング終了までの得点分布」をマルコフ連鎖で求める。
  2. 回・表裏・点差ごとのホーム勝率 (WE) を後ろ向きに求める。9 回以降のサヨナラ・
     12 回終了で同点なら引き分け (勝率 0.5 扱い) を反映する。
  3. 各状態の「次の 1 打席での |ΔWE| の期待値」を、試合中に各状態を通る頻度で加重平均して 1.0 に正規化し、
     さらに試合シムでの実測平均 (SIM_MEAN_LI) で割って、シムの全打席平均が 1.0 になるように揃える。

使い方: python tools/gen_leverage_index_table.py
PA_EVENTS はリーグの打席結果の構成比。リーグの得点環境が大きく変わったら実測値に合わせて再生成する。
"""

from __future__ import annotations

import os
from functools import lru_cache

# 打席結果の構成比 (1 打席あたり)。seed12345 の 2 季実測 (R/G 3.9) から。
PA_EVENTS = {
    "walk": 0.0836,   # 四球 + 死球
    "single": 0.1620,
    "double": 0.0400,
    "triple": 0.0039,
    "home_run": 0.0209,
    "strikeout": 0.1855,
    "error": 0.0096,  # 失策出塁。走者は単打と同じに進む
}
PA_EVENTS["in_play_out"] = 1.0 - sum(PA_EVENTS.values())

# 走者の進塁 (安打時)。
SINGLE_SCORE_FROM_SECOND = 0.60   # 単打で二塁走者が生還する割合
SINGLE_FIRST_TO_THIRD = 0.28      # 単打で一塁走者が三塁まで進む割合 (三塁が空くときだけ)
DOUBLE_SCORE_FROM_FIRST = 0.40    # 二塁打で一塁走者が生還する割合
# 走者の進塁 (凡打時、2 アウト未満)。
DOUBLE_PLAY_WITH_RUNNER_ON_FIRST = 0.22  # 一塁走者ありの凡打が併殺になる割合
OUT_SCORE_FROM_THIRD = 0.40       # 凡打・犠飛で三塁走者が生還する割合
OUT_SECOND_TO_THIRD = 0.30        # 凡打で二塁走者が三塁へ進む割合 (三塁が空くときだけ)
OUT_FIRST_TO_SECOND = 0.15        # 凡打で一塁走者が二塁へ進む割合 (二塁が空くときだけ)

# 試合シムの全打席で測った平均 LI (このモデルの正規化のまま引いた値)。シムは大差の試合がモデルより多く
# 平均が 1.0 を下回るので、表全体をこの値で割ってシムの全打席平均を 1.0 に揃える。
# 測り方: 一軍戦の各打席の直前状態で PSLeverageIndex.for_state を引いて平均する (二軍戦は含めない)。
SIM_MEAN_LI = 0.950

REGULATION_INNINGS = 9
MAX_INNINGS = 12        # NPB 公式戦は 12 回で打ち切り
TIE_VALUE = 0.5         # 引き分けの勝率換算
MAX_RUNS = 24           # 1 イニングの得点分布の上限
DIFF_LIMIT = 30         # 勝率計算で保持する点差の範囲 (±)
TABLE_DIFF_LIMIT = 6    # 出力する点差の範囲 (±)。範囲外は端の値で引く

OUTPUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "services", "simulation", "models", "leverage_index_table.gd",
)

FIRST, SECOND, THIRD = 1, 2, 4


def _branch(outcomes, prob, outs, mask, runs):
    outcomes.append((prob, outs, mask, runs))


def transitions(outs: int, mask: int):
    """(outs, mask) から 1 打席後の (確率, outs, mask, 得点) の一覧を返す。"""
    result = []
    on1, on2, on3 = bool(mask & FIRST), bool(mask & SECOND), bool(mask & THIRD)

    # 四死球: 押し出しの連鎖だけ進む。
    p = PA_EVENTS["walk"]
    if not on1:
        _branch(result, p, outs, mask | FIRST, 0)
    elif not on2:
        _branch(result, p, outs, mask | FIRST | SECOND, 0)
    elif not on3:
        _branch(result, p, outs, FIRST | SECOND | THIRD, 0)
    else:
        _branch(result, p, outs, FIRST | SECOND | THIRD, 1)

    # 単打・失策出塁: 三塁走者は生還、二塁走者は一部生還、一塁走者は三塁が空けば一部三塁へ。
    p = PA_EVENTS["single"] + PA_EVENTS["error"]
    base_runs = 1 if on3 else 0
    second_cases = [(1.0, False)] if not on2 else [
        (SINGLE_SCORE_FROM_SECOND, True), (1.0 - SINGLE_SCORE_FROM_SECOND, False)]
    for p2, second_scores in second_cases:
        runs = base_runs + (1 if on2 and second_scores else 0)
        third_taken = on2 and not second_scores
        if on1:
            first_cases = [(1.0, False)] if third_taken else [
                (SINGLE_FIRST_TO_THIRD, True), (1.0 - SINGLE_FIRST_TO_THIRD, False)]
            for p1, to_third in first_cases:
                new_mask = FIRST | (THIRD if (to_third or third_taken) else 0) | (0 if to_third else SECOND)
                _branch(result, p * p2 * p1, outs, new_mask, runs)
        else:
            _branch(result, p * p2, outs, FIRST | (THIRD if third_taken else 0), runs)

    # 二塁打: 二・三塁走者は生還、一塁走者は一部生還・残りは三塁。
    p = PA_EVENTS["double"]
    runs = (1 if on2 else 0) + (1 if on3 else 0)
    if on1:
        _branch(result, p * DOUBLE_SCORE_FROM_FIRST, outs, SECOND, runs + 1)
        _branch(result, p * (1.0 - DOUBLE_SCORE_FROM_FIRST), outs, SECOND | THIRD, runs)
    else:
        _branch(result, p, outs, SECOND, runs)

    # 三塁打・本塁打。
    runners = int(on1) + int(on2) + int(on3)
    _branch(result, PA_EVENTS["triple"], outs, THIRD, runners)
    _branch(result, PA_EVENTS["home_run"], outs, 0, runners + 1)

    # 三振: 進塁なし。
    _branch(result, PA_EVENTS["strikeout"], outs + 1, mask, 0)

    # 凡打。
    p = PA_EVENTS["in_play_out"]
    if outs == 2:
        _branch(result, p, 3, 0, 0)
    else:
        normal_p = p
        if on1:
            dp_p = p * DOUBLE_PLAY_WITH_RUNNER_ON_FIRST
            normal_p = p - dp_p
            new_outs = outs + 2
            if new_outs >= 3:
                _branch(result, dp_p, 3, 0, 0)
            else:
                dp_runs = 1 if on3 else 0
                _branch(result, dp_p, new_outs, THIRD if on2 else 0, dp_runs)
        new_outs = outs + 1
        third_cases = [(1.0, False)] if not on3 else [
            (OUT_SCORE_FROM_THIRD, True), (1.0 - OUT_SCORE_FROM_THIRD, False)]
        for p3, third_scores in third_cases:
            third_free = (not on3) or third_scores
            second_cases = [(1.0, False)] if not (on2 and third_free) else [
                (OUT_SECOND_TO_THIRD, True), (1.0 - OUT_SECOND_TO_THIRD, False)]
            for p2, second_advances in second_cases:
                second_free = (not on2) or second_advances
                first_cases = [(1.0, False)] if not (on1 and second_free) else [
                    (OUT_FIRST_TO_SECOND, True), (1.0 - OUT_FIRST_TO_SECOND, False)]
                for p1, first_advances in first_cases:
                    new_mask = 0
                    if on3 and not third_scores:
                        new_mask |= THIRD
                    if on2:
                        new_mask |= THIRD if second_advances else SECOND
                    if on1:
                        new_mask |= SECOND if first_advances else FIRST
                    _branch(result, normal_p * p3 * p2 * p1, new_outs, new_mask, 1 if third_scores else 0)
    return result


TRANSITIONS = {(o, m): transitions(o, m) for o in range(3) for m in range(8)}


def inning_run_distributions():
    """dist[(outs, mask)] = イニング終了までの得点分布 (長さ MAX_RUNS + 1)。"""
    dist = {}
    for outs in (2, 1, 0):
        current = {m: [0.0] * (MAX_RUNS + 1) for m in range(8)}
        for _ in range(200):
            nxt = {}
            for mask in range(8):
                acc = [0.0] * (MAX_RUNS + 1)
                for prob, o2, m2, runs in TRANSITIONS[(outs, mask)]:
                    if o2 >= 3:
                        src = [1.0] + [0.0] * MAX_RUNS
                    elif o2 == outs:
                        src = current[m2]
                    else:
                        src = dist[(o2, m2)]
                    for r, v in enumerate(src):
                        if v:
                            acc[min(MAX_RUNS, r + runs)] += prob * v
                nxt[mask] = acc
            current = nxt
        for mask in range(8):
            dist[(outs, mask)] = current[mask]
    return dist


RUN_DIST = inning_run_distributions()


def clamp_diff(d: int) -> int:
    return max(-DIFF_LIMIT, min(DIFF_LIMIT, d))


@lru_cache(maxsize=None)
def end_of_half(inning: int, bottom: bool, diff: int) -> float:
    """半イニング終了時点 (ホーム - ビジター = diff) のホーム勝率。"""
    diff = clamp_diff(diff)
    if not bottom:
        if inning >= REGULATION_INNINGS and diff > 0:
            return 1.0
        return mid(inning, True, diff, 0, 0)
    if inning >= REGULATION_INNINGS:
        if diff > 0:
            return 1.0
        if diff < 0:
            return 0.0
        if inning >= MAX_INNINGS:
            return TIE_VALUE
    return mid(inning + 1, False, diff, 0, 0)


@lru_cache(maxsize=None)
def mid(inning: int, bottom: bool, diff: int, outs: int, mask: int) -> float:
    """半イニングの途中 (outs, mask) のホーム勝率。"""
    diff = clamp_diff(diff)
    if bottom and inning >= REGULATION_INNINGS and diff > 0:
        return 1.0
    total = 0.0
    for runs, prob in enumerate(RUN_DIST[(outs, mask)]):
        if prob:
            total += prob * end_of_half(inning, bottom, diff + runs if bottom else diff - runs)
    return total


def after_event(inning, bottom, diff, o2, m2, runs):
    new_diff = diff + runs if bottom else diff - runs
    if o2 >= 3:
        return end_of_half(inning, bottom, new_diff)
    return mid(inning, bottom, new_diff, o2, m2)


@lru_cache(maxsize=None)
def raw_swing(inning: int, bottom: bool, diff: int, outs: int, mask: int) -> float:
    """次の 1 打席での |ΔWE| の期待値 (正規化前の LI)。"""
    here = mid(inning, bottom, diff, outs, mask)
    return sum(
        prob * abs(after_event(inning, bottom, diff, o2, m2, runs) - here)
        for prob, o2, m2, runs in TRANSITIONS[(outs, mask)]
    )


def game_over_after_half(inning, bottom, diff):
    if not bottom:
        return inning >= REGULATION_INNINGS and diff > 0
    if inning >= REGULATION_INNINGS:
        return diff != 0 or inning >= MAX_INNINGS
    return False


def average_raw_swing() -> float:
    """試合中に各状態を通る頻度 (打席数) で raw_swing を加重平均する。"""
    weighted = 0.0
    plate_appearances = 0.0
    starts = {0: 1.0}  # 半イニング開始時点の点差ごとの確率
    for inning in range(1, MAX_INNINGS + 1):
        for bottom in (False, True):
            ends = {}
            state = {(d, 0, 0): m for d, m in starts.items()}
            while state:
                nxt = {}
                for (d, outs, mask), mass in state.items():
                    if mass < 1e-12:
                        continue
                    weighted += mass * raw_swing(inning, bottom, d, outs, mask)
                    plate_appearances += mass
                    for prob, o2, m2, runs in TRANSITIONS[(outs, mask)]:
                        d2 = clamp_diff(d + runs if bottom else d - runs)
                        m = mass * prob
                        if bottom and inning >= REGULATION_INNINGS and d2 > 0:
                            continue  # サヨナラ
                        if o2 >= 3:
                            ends[d2] = ends.get(d2, 0.0) + m
                        else:
                            key = (d2, o2, m2)
                            nxt[key] = nxt.get(key, 0.0) + m
                state = nxt
            starts = {d: m for d, m in ends.items() if not game_over_after_half(inning, bottom, d)}
    return weighted / plate_appearances


def runs_per_nine() -> float:
    return 9.0 * sum(r * p for r, p in enumerate(RUN_DIST[(0, 0)]))


def main():
    norm = average_raw_swing() * SIM_MEAN_LI
    diffs = list(range(-TABLE_DIFF_LIMIT, TABLE_DIFF_LIMIT + 1))
    lines = []
    for inning in range(1, MAX_INNINGS + 1):
        for bottom in (False, True):
            for d in diffs:
                values = [
                    raw_swing(inning, bottom, d, outs, mask) / norm
                    for outs in range(3) for mask in range(8)
                ]
                lines.append(
                    "\t%s,  # %d回%s ホーム%+d" % (
                        ", ".join("%.2f" % v for v in values), inning, "裏" if bottom else "表", d)
                )
    body = "\n".join(lines)
    header = (
        "extends RefCounted\n\n"
        "# このファイルは tools/gen_leverage_index_table.py が生成する。手で編集しない。\n"
        "# Leverage Index 表。並びは [回 1..%d][表, 裏][ホーム - ビジター %d..%d][アウト 0..2][走者 0..7]。\n"
        "# 走者は 一塁=1 / 二塁=2 / 三塁=4 のビット和。試合シムの全打席の平均が 1.0 になるよう正規化してある。\n"
        "# モデルの得点環境: %.2f 点/9回。\n\n"
        "const MAX_INNING: int = %d\n"
        "const DIFF_LIMIT: int = %d\n"
        "const VALUES: Array[float] = [\n%s\n]\n"
    ) % (MAX_INNINGS, -TABLE_DIFF_LIMIT, TABLE_DIFF_LIMIT, runs_per_nine(),
         MAX_INNINGS, TABLE_DIFF_LIMIT, body)
    with open(OUTPUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(header)
    print("runs/9 = %.3f, normalizer = %.5f, entries = %d" % (runs_per_nine(), norm, len(lines) * 24))
    print("wrote", OUTPUT_PATH)


if __name__ == "__main__":
    main()
