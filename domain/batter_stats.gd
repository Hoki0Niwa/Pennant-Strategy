extends RefCounted
class_name PSBatterStats

var games: int
var plate_appearances: int
var at_bats: int
var hits: int
var doubles: int
var triples: int
var home_runs: int
var runs_batted_in: int
var runs: int
var walks: int
var hit_by_pitches: int
var strikeouts: int
var pitches_seen: int
var stolen_base_attempts: int
var stolen_bases: int
var sacrifices: int
var sacrifice_flies: int
var double_plays: int
var errors: int


static func from_dict(data: Dictionary) -> PSBatterStats:
	var stats: PSBatterStats = PSBatterStats.new()
	stats.games = int(data.get("games", 0))
	stats.plate_appearances = int(data.get("plate_appearances", 0))
	stats.at_bats = int(data.get("at_bats", 0))
	stats.hits = int(data.get("hits", 0))
	stats.doubles = int(data.get("doubles", 0))
	stats.triples = int(data.get("triples", 0))
	stats.home_runs = int(data.get("home_runs", 0))
	stats.runs_batted_in = int(data.get("runs_batted_in", 0))
	stats.runs = int(data.get("runs", 0))
	stats.walks = int(data.get("walks", 0))
	stats.hit_by_pitches = int(data.get("hit_by_pitches", 0))
	stats.strikeouts = int(data.get("strikeouts", 0))
	stats.pitches_seen = int(data.get("pitches_seen", 0))
	stats.stolen_base_attempts = int(data.get("stolen_base_attempts", 0))
	stats.stolen_bases = int(data.get("stolen_bases", 0))
	stats.sacrifices = int(data.get("sacrifices", 0))
	stats.sacrifice_flies = int(data.get("sacrifice_flies", 0))
	stats.double_plays = int(data.get("double_plays", 0))
	stats.errors = int(data.get("errors", 0))
	return stats


func add_from(other: PSBatterStats) -> void:
	games += other.games
	plate_appearances += other.plate_appearances
	at_bats += other.at_bats
	hits += other.hits
	doubles += other.doubles
	triples += other.triples
	home_runs += other.home_runs
	runs_batted_in += other.runs_batted_in
	runs += other.runs
	walks += other.walks
	hit_by_pitches += other.hit_by_pitches
	strikeouts += other.strikeouts
	pitches_seen += other.pitches_seen
	stolen_base_attempts += other.stolen_base_attempts
	stolen_bases += other.stolen_bases
	sacrifices += other.sacrifices
	sacrifice_flies += other.sacrifice_flies
	double_plays += other.double_plays
	errors += other.errors


# 自分から other を差し引いた新インスタンスを返す。期間差分計算 (月別 stats 等) で使う。
func subtract_from(other: PSBatterStats) -> PSBatterStats:
	var diff: PSBatterStats = PSBatterStats.new()
	diff.games = games - other.games
	diff.plate_appearances = plate_appearances - other.plate_appearances
	diff.at_bats = at_bats - other.at_bats
	diff.hits = hits - other.hits
	diff.doubles = doubles - other.doubles
	diff.triples = triples - other.triples
	diff.home_runs = home_runs - other.home_runs
	diff.runs_batted_in = runs_batted_in - other.runs_batted_in
	diff.runs = runs - other.runs
	diff.walks = walks - other.walks
	diff.hit_by_pitches = hit_by_pitches - other.hit_by_pitches
	diff.strikeouts = strikeouts - other.strikeouts
	diff.pitches_seen = pitches_seen - other.pitches_seen
	diff.stolen_base_attempts = stolen_base_attempts - other.stolen_base_attempts
	diff.stolen_bases = stolen_bases - other.stolen_bases
	diff.sacrifices = sacrifices - other.sacrifices
	diff.sacrifice_flies = sacrifice_flies - other.sacrifice_flies
	diff.double_plays = double_plays - other.double_plays
	diff.errors = errors - other.errors
	return diff


func batting_average() -> float:
	if at_bats == 0:
		return 0.0
	return float(hits) / float(at_bats)


func on_base_percentage() -> float:
	var denominator: int = at_bats + walks + hit_by_pitches + sacrifice_flies
	if denominator == 0:
		return 0.0
	return float(hits + walks + hit_by_pitches) / float(denominator)


func slugging_percentage() -> float:
	if at_bats == 0:
		return 0.0
	var singles: int = hits - doubles - triples - home_runs
	var total_bases: int = singles + doubles * 2 + triples * 3 + home_runs * 4
	return float(total_bases) / float(at_bats)


func ops() -> float:
	return on_base_percentage() + slugging_percentage()


func to_dict() -> Dictionary:
	return {
		"games": games,
		"plate_appearances": plate_appearances,
		"at_bats": at_bats,
		"hits": hits,
		"doubles": doubles,
		"triples": triples,
		"home_runs": home_runs,
		"runs_batted_in": runs_batted_in,
		"runs": runs,
		"walks": walks,
		"hit_by_pitches": hit_by_pitches,
		"strikeouts": strikeouts,
		"pitches_seen": pitches_seen,
		"stolen_base_attempts": stolen_base_attempts,
		"stolen_bases": stolen_bases,
		"sacrifices": sacrifices,
		"sacrifice_flies": sacrifice_flies,
		"double_plays": double_plays,
		"errors": errors,
	}
