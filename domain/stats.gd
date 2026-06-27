extends RefCounted
class_name PSStats

# チーム成績の基本集計。順位表、履歴、ゲーム差計算で共通して使う最小単位。
var games: int
var wins: int
var losses: int
var draws: int
var runs_scored: int
var runs_allowed: int


static func from_dict(data: Dictionary) -> PSStats:
	var stats: PSStats = PSStats.new()
	stats.games = int(data.get("games", 0))
	stats.wins = int(data.get("wins", 0))
	stats.losses = int(data.get("losses", 0))
	stats.draws = int(data.get("draws", 0))
	stats.runs_scored = int(data.get("runs_scored", 0))
	stats.runs_allowed = int(data.get("runs_allowed", 0))
	return stats


# 引き分けは勝率の分母に含めない。
func win_rate() -> float:
	var decisions: int = wins + losses
	if decisions == 0:
		return 0.0
	return float(wins) / float(decisions)


func to_dict() -> Dictionary:
	return {
		"games": games,
		"wins": wins,
		"losses": losses,
		"draws": draws,
		"runs_scored": runs_scored,
		"runs_allowed": runs_allowed,
	}
