"""Per-position UZR and per-zone OAA aggregation from balance_report JSON.

Usage: python tools/analyze_position_uzr.py [path/to/balance_report_latest.json]
"""
import json
import sys
from collections import defaultdict

DEFAULT_PATH = "reports/balance_report_latest.json"


def main(path: str) -> None:
    with open(path, "r", encoding="utf-8") as f:
        report = json.load(f)

    # Look at player_stats.batters list.
    batters = report.get("player_stats", {}).get("batters", [])
    print(f"Total batter player rows: {len(batters)}")

    # UZR is position-relative, so aggregate only inside the same position.
    position_sums = defaultdict(lambda: {
        "rngr": 0.0,
        "errr": 0.0,
        "dpr": 0.0,
        "uzr": 0.0,
        "drs": 0.0,
        "chances": 0,
        "outs": 0,
    })
    oaa_sums = defaultdict(lambda: {"oaa": 0.0, "chances": 0, "outs": 0})
    for row in batters:
        chances_by_position = row.get("fielding_chances_by_position", {})
        outs_by_position = row.get("defensive_outs_by_position", {})
        for pos, uzr in row.get("uzr_by_position", {}).items():
            position_sums[pos]["uzr"] += float(uzr)
            position_sums[pos]["rngr"] += float(row.get("rngr_by_position", {}).get(pos, 0.0))
            position_sums[pos]["errr"] += float(row.get("errr_by_position", {}).get(pos, 0.0))
            position_sums[pos]["dpr"] += float(row.get("dpr_by_position", {}).get(pos, 0.0))
            position_sums[pos]["drs"] += float(row.get("drs_by_position", {}).get(pos, uzr))
            position_sums[pos]["chances"] += int(chances_by_position.get(pos, 0))
            position_sums[pos]["outs"] += int(outs_by_position.get(pos, 0))

        chances_by_zone = row.get("fielding_chances_by_oaa_zone", {})
        outs_by_zone = row.get("defensive_outs_by_oaa_zone", {})
        for zone, oaa in row.get("oaa_by_zone", {}).items():
            oaa_sums[zone]["oaa"] += float(oaa)
            oaa_sums[zone]["chances"] += int(chances_by_zone.get(zone, 0))
            oaa_sums[zone]["outs"] += int(outs_by_zone.get(zone, 0))

    print("\nPer-position UZR totals:")
    print(f"{'Pos':<5} {'Outs':>8} {'Chances':>8} {'RngR':>10} {'ErrR':>10} {'DPR':>10} {'UZR':>10} {'DRS':>10}")
    for pos in sorted(position_sums.keys(), key=lambda value: int(value)):
        v = position_sums[pos]
        print(
            f"{pos:<5} {v['outs']:>8} {v['chances']:>8} {v['rngr']:>10.2f} "
            f"{v['errr']:>10.2f} {v['dpr']:>10.2f} {v['uzr']:>10.2f} {v['drs']:>10.2f}"
        )

    print("\nOAA by zone:")
    print(f"{'Zone':<10} {'Outs':>8} {'Chances':>8} {'OAA':>10}")
    for zone in sorted(oaa_sums.keys()):
        v = oaa_sums[zone]
        print(f"{zone:<10} {v['outs']:>8} {v['chances']:>8} {v['oaa']:>10.2f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH)
