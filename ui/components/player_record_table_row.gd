extends RefCounted
class_name PSPlayerRecordTableRow


# 名簿と指定期間の集計値だけから表示行を作り、現役名簿や成績台帳へは登録しない。
static func from_history(identity: Dictionary, totals: Dictionary = {}) -> Dictionary:
	var record: PSPlayerSeasonRecord = PSPlayerSeasonRecord.new()
	record.player_id = int(identity["player_id"])
	record.team_id = int(identity.get("team_id", 0))
	record.name = str(identity.get("name", ""))
	record.age = int(identity.get("age", 0))
	record.position = int(identity.get("position", 0))
	record.role = str(identity.get("role", ""))
	record.year = int(identity.get("year", 0))
	record.season_number = int(identity.get("season_number", 0))
	record.development_player = bool(identity.get("development", identity.get("development_player", false)))
	record.batter_stats = PSBatterStats.from_dict(totals.get("batter_stats", {}) as Dictionary)
	record.pitcher_stats = PSPitcherStats.from_dict(totals.get("pitcher_stats", {}) as Dictionary)
	var metrics: Dictionary = {}
	for key: String in ["war", "fip", "wrc_plus", "woba", "oaa"]:
		if totals.has(key) and totals[key] != null:
			metrics[key] = float(totals[key])
	if totals.is_empty():
		metrics["war"] = 0.0
	return {"record": record, "player": null, "entry": identity.duplicate(true),
		"presentation": "historical", "metrics": metrics}


# 高度指標の欠測は現在の通算値で補完しない。件数と率の分母は渡された期間だけに限定する。
static func historical_values(row: Dictionary) -> Dictionary:
	var record: PSPlayerSeasonRecord = row["record"] as PSPlayerSeasonRecord
	var metrics: Dictionary = row.get("metrics", {}) as Dictionary
	return {
		"batter_stats": record.batter_stats, "pitcher_stats": record.pitcher_stats,
		"advanced_stats": null,
		"war_value": float(metrics.get("war", 0.0)),
		"war_text": "%.1f" % float(metrics["war"]) if metrics.has("war") else "-",
		"fip_text": "%.2f" % float(metrics["fip"]) if metrics.has("fip") and record.pitcher_stats.outs_pitched > 0 else "-",
		"wrc_text": str(int(round(float(metrics["wrc_plus"])))) if metrics.has("wrc_plus") and record.batter_stats.plate_appearances > 0 else "-",
		"woba_text": _rate(float(metrics["woba"])) if metrics.has("woba") and record.batter_stats.plate_appearances > 0 else "-",
		"oaa_text": "%+.1f" % float(metrics["oaa"]) if metrics.has("oaa") else "-",
		"oaa_value": float(metrics.get("oaa", 0.0)),
	}


static func _rate(value: float) -> String:
	var result: String = "%.3f" % value
	return result.substr(1) if result.begins_with("0.") else result
