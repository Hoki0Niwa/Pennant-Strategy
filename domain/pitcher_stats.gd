extends RefCounted
class_name PSPitcherStats

var games: int
var starts: int
var relief_appearances: int
var wins: int
var losses: int
var holds: int
var saves: int
var outs_pitched: int
var batters_faced: int
var pitches_thrown: int
var hits_allowed: int
var home_runs_allowed: int
var walks: int
var hit_batters: int
var strikeouts: int
var runs_allowed: int
var earned_runs: int
var complete_games: int
var shutouts: int
var quality_starts: int


static func from_dict(data: Dictionary) -> PSPitcherStats:
	var stats: PSPitcherStats = PSPitcherStats.new()
	stats.games = int(data.get("games", 0))
	stats.starts = int(data.get("starts", 0))
	stats.relief_appearances = int(data.get("relief_appearances", 0))
	stats.wins = int(data.get("wins", 0))
	stats.losses = int(data.get("losses", 0))
	stats.holds = int(data.get("holds", 0))
	stats.saves = int(data.get("saves", 0))
	stats.outs_pitched = int(data.get("outs_pitched", 0))
	stats.batters_faced = int(data.get("batters_faced", 0))
	stats.pitches_thrown = int(data.get("pitches_thrown", 0))
	stats.hits_allowed = int(data.get("hits_allowed", 0))
	stats.home_runs_allowed = int(data.get("home_runs_allowed", 0))
	stats.walks = int(data.get("walks", 0))
	stats.hit_batters = int(data.get("hit_batters", 0))
	stats.strikeouts = int(data.get("strikeouts", 0))
	stats.runs_allowed = int(data.get("runs_allowed", 0))
	stats.earned_runs = int(data.get("earned_runs", 0))
	stats.complete_games = int(data.get("complete_games", 0))
	stats.shutouts = int(data.get("shutouts", 0))
	stats.quality_starts = int(data.get("quality_starts", 0))
	return stats


func add_from(other: PSPitcherStats) -> void:
	games += other.games
	starts += other.starts
	relief_appearances += other.relief_appearances
	wins += other.wins
	losses += other.losses
	holds += other.holds
	saves += other.saves
	outs_pitched += other.outs_pitched
	batters_faced += other.batters_faced
	pitches_thrown += other.pitches_thrown
	hits_allowed += other.hits_allowed
	home_runs_allowed += other.home_runs_allowed
	walks += other.walks
	hit_batters += other.hit_batters
	strikeouts += other.strikeouts
	runs_allowed += other.runs_allowed
	earned_runs += other.earned_runs
	complete_games += other.complete_games
	shutouts += other.shutouts
	quality_starts += other.quality_starts


# 自分から other を差し引いた新インスタンスを返す。期間差分計算 (月別 stats 等) で使う。
func subtract_from(other: PSPitcherStats) -> PSPitcherStats:
	var diff: PSPitcherStats = PSPitcherStats.new()
	diff.games = games - other.games
	diff.starts = starts - other.starts
	diff.relief_appearances = relief_appearances - other.relief_appearances
	diff.wins = wins - other.wins
	diff.losses = losses - other.losses
	diff.holds = holds - other.holds
	diff.saves = saves - other.saves
	diff.outs_pitched = outs_pitched - other.outs_pitched
	diff.batters_faced = batters_faced - other.batters_faced
	diff.pitches_thrown = pitches_thrown - other.pitches_thrown
	diff.hits_allowed = hits_allowed - other.hits_allowed
	diff.home_runs_allowed = home_runs_allowed - other.home_runs_allowed
	diff.walks = walks - other.walks
	diff.hit_batters = hit_batters - other.hit_batters
	diff.strikeouts = strikeouts - other.strikeouts
	diff.runs_allowed = runs_allowed - other.runs_allowed
	diff.earned_runs = earned_runs - other.earned_runs
	diff.complete_games = complete_games - other.complete_games
	diff.shutouts = shutouts - other.shutouts
	diff.quality_starts = quality_starts - other.quality_starts
	return diff


func innings_pitched() -> float:
	return float(outs_pitched) / 3.0


func era() -> float:
	if outs_pitched == 0:
		return 0.0
	return float(earned_runs) * 27.0 / float(outs_pitched)


func whip() -> float:
	if outs_pitched == 0:
		return 0.0
	return float(hits_allowed + walks) * 3.0 / float(outs_pitched)


func strikeouts_per_nine() -> float:
	if outs_pitched == 0:
		return 0.0
	return float(strikeouts) * 27.0 / float(outs_pitched)


func to_dict() -> Dictionary:
	return {
		"games": games,
		"starts": starts,
		"relief_appearances": relief_appearances,
		"wins": wins,
		"losses": losses,
		"holds": holds,
		"saves": saves,
		"outs_pitched": outs_pitched,
		"batters_faced": batters_faced,
		"pitches_thrown": pitches_thrown,
		"hits_allowed": hits_allowed,
		"home_runs_allowed": home_runs_allowed,
		"walks": walks,
		"hit_batters": hit_batters,
		"strikeouts": strikeouts,
		"runs_allowed": runs_allowed,
		"earned_runs": earned_runs,
		"complete_games": complete_games,
		"shutouts": shutouts,
		"quality_starts": quality_starts,
	}
