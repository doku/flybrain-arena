extends SceneTree
## Headless tournament-guard tests: a free-mode generation_advanced reply
## arriving mid-tournament must NEVER self-advance (that refought the
## same battle id and multi-banked one fight into many generations).
## Run: godot --headless --path arena -s tests/test_tourney_guard.gd
## Exit code = failure count (0 = all green).

var failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _new_arena():
	# Bare instance: _ready never runs, so only the guarded handler
	# is exercised (it returns before touching any scene nodes).
	return load("res://scripts/ArenaManager.gd").new()


func test_ignores_free_reply_mid_tournament() -> void:
	var a = _new_arena()
	a.tournament_active = true
	a._tourney_awaiting_battle = true
	a.current_generation = 7
	a._on_generation_advanced(50, "alpha")
	_check(a.current_generation == 7, "generation untouched by wrong-mode reply")
	_check(a._tourney_awaiting_battle, "still awaiting the real verdict")
	_check(a.wins_alpha == 0 and a.wins_beta == 0, "no win tallied")
	a.queue_free()


func _initialize() -> void:
	test_ignores_free_reply_mid_tournament()
	if failures == 0:
		print("ALL TOURNEY-GUARD TESTS PASSED")
	else:
		printerr("TOURNEY-GUARD TESTS: %d FAILURES" % failures)
	quit(failures)
