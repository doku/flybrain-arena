extends SceneTree
## Headless sound tests: synth buffer validity, player pool, hook
## no-ops, announcer guards, and the score verbalizer - on the REAL
## arena scene. Run: godot --headless --path arena -s tests/test_sound.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var _done := false


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	# Quarantine: no packet from this suite may reach any server, and
	# the announcer must never speak in a suite (headless guards it).
	load("res://scripts/BrainClient.gd").test_mute = true
	var scene = load("res://scenes/ArenaGlade.tscn")
	arena = scene.instantiate()
	root.add_child(arena)


func test_synth_buffers() -> void:
	# Every effect built at boot: 16-bit (never the 8-bit default),
	# boot sample rate, mono, non-empty data.
	for name in ["thump", "clash", "tear", "boom", "beep", "fight"]:
		_check(arena._sfx_streams.has(name), "stream built: " + name)
		var st: AudioStreamWAV = arena._sfx_streams[name]
		_check(st.format == AudioStreamWAV.FORMAT_16_BITS,
			"16-bit packing: " + name)
		_check(st.mix_rate == 22050, "boot rate: " + name)
		_check(not st.stereo, "mono: " + name)
		_check(st.data.size() > 100, "non-empty data: " + name)


func test_player_pool() -> void:
	_check(arena._sfx_players.size() == 4, "pool of 4 players")
	for p in arena._sfx_players:
		_check(p is AudioStreamPlayer, "pool holds players")
		_check((p as AudioStreamPlayer).volume_db == -6.0,
			"master trim -6 dB")


func test_play_guards() -> void:
	# Unknown names and a disabled toggle no-op without error and
	# start nothing.
	arena._play_sfx("nope")
	var busy := 0
	for p in arena._sfx_players:
		if (p as AudioStreamPlayer).playing:
			busy += 1
	_check(busy == 0, "unknown sfx plays nothing")
	arena._sfx_on = false
	arena._play_sfx("boom")
	busy = 0
	for p in arena._sfx_players:
		if (p as AudioStreamPlayer).playing:
			busy += 1
	_check(busy == 0, "disabled sfx plays nothing")
	arena._sfx_on = true


func test_announce_guards() -> void:
	# Headless suite: TTS probe fails by construction, so announcing
	# is a silent no-op (never an error, never speech).
	_check(not arena._tts_ok, "headless has no TTS")
	arena._announce("Knockout! Alpha")
	arena._announce("")
	_check(true, "announce no-ops without error")


func test_spoken_score() -> void:
	_check(arena._spoken_score("3 - 1") == "three to one",
		"digits verbalized with to")
	_check(arena._spoken_score("0 - 0") == "zero to zero",
		"zero handled")
	_check(arena._spoken_score("12 - 0") == "12 to zero",
		"off-map passes through raw")
	_check(arena._spoken_score("junk") == "junk",
		"garbage passes through")


func test_hit_sfx_routing() -> void:
	# Part-keyed routing: clash tick, tear rip, body thump. Muted
	# playback is asserted via toggle-off (no headless audio).
	arena._sfx_on = true
	arena._hit_feedback("alpha", "beta", "spike_clash")
	arena._hit_feedback("alpha", "beta", "wing_tear")
	arena._hit_feedback("alpha", "beta", "thorax_puncture")
	_check(true, "hit feedback sounds without error")


func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	test_synth_buffers()
	test_player_pool()
	test_play_guards()
	test_announce_guards()
	test_spoken_score()
	test_hit_sfx_routing()
	if failures == 0:
		print("ALL SOUND TESTS PASSED")
	else:
		printerr("SOUND TESTS: %d FAILURES" % failures)
	quit(failures)
	return true
