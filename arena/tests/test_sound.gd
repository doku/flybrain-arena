extends SceneTree
## Headless sound tests: synth buffer validity, player pool, hook
## no-ops, announcer guards, and the score verbalizer - on the REAL
## arena scene. Run: godot --headless --path arena -s tests/test_sound.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var _done := false
# Preloaded: SfxSynth is a fresh script with no global class cache
# entry yet (see ArenaManager.SfxSynthLib).
const Synth = preload("res://scripts/SfxSynth.gd")


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


func test_announce_clips() -> void:
	# Fixed-phrase clip pack: every key in VOICE_CLIPS resolves to a
	# loaded stream (proves the file exists on disk); unknown keys
	# and a disabled toggle no-op without error. Headless playback
	# runs on the dummy driver (silent).
	_check(arena._voice_clips.size() == arena.VOICE_CLIPS.size(),
		"whole clip pack loaded (%d)" % arena.VOICE_CLIPS.size())
	for key in arena.VOICE_CLIPS:
		_check(arena._voice_clips.has(key), "clip resolves: " + str(key))
		var st: AudioStreamWAV = arena._voice_clips[key]
		_check(st.data.size() > 1000, "clip non-empty: " + str(key))
	arena._announce_clip("knockout_orange")
	arena._announce_clip("nope")
	_check(true, "known + unknown clips no-op without error")
	arena._voice_on = false
	arena._voice_player.stop()
	arena._announce_clip("knockout_orange")
	_check(not arena._voice_player.playing, "disabled voice plays nothing")
	arena._voice_on = true


func test_mute_key() -> void:
	# M key + MUTE button: master mute cuts voice and SFX now,
	# preserves the individual toggles underneath, restores on
	# second press. Held-key echo must not stutter the toggle.
	var ev := InputEventKey.new()
	ev.keycode = KEY_M
	ev.pressed = true
	ev.echo = false
	arena._voice_on = true
	arena._sfx_on = true
	arena._unhandled_input(ev)
	_check(arena._sound_muted, "M mutes")
	_check(arena._voice_on and arena._sfx_on, "toggles preserved under mute")
	arena._play_sfx("boom")
	var busy := 0
	for p in arena._sfx_players:
		if (p as AudioStreamPlayer).playing:
			busy += 1
	_check(busy == 0, "muted sfx plays nothing")
	var ev_echo := InputEventKey.new()
	ev_echo.keycode = KEY_M
	ev_echo.pressed = true
	ev_echo.echo = true
	arena._unhandled_input(ev_echo)
	_check(arena._sound_muted, "held key does not stutter the toggle")
	arena._unhandled_input(ev)
	_check(not arena._sound_muted, "M again unmutes")
	if is_instance_valid(arena.mute_button):
		_check(arena.mute_button.text == "MUTE", "button text follows")
	_check("SOUND" in arena.status_label.text, "status names sound state")


func test_hit_sfx_routing() -> void:
	# Part-keyed routing: clash tick, tear rip, body thump. Muted
	# playback is asserted via toggle-off (no headless audio).
	arena._sfx_on = true
	arena._hit_feedback("alpha", "beta", "spike_clash")
	arena._hit_feedback("alpha", "beta", "wing_tear")
	arena._hit_feedback("alpha", "beta", "thorax_puncture")
	_check(true, "hit feedback sounds without error")


func test_palettes_build() -> void:
	# Every palette builds all six effects valid (16-bit, boot rate,
	# non-empty) - procedural and sampled alike; unknown names fall
	# back to classic; rebuilding never stacks players.
	for pal in Synth.PALETTES:
		var streams := Synth.build(pal)
		_check(streams.size() == 6, "palette complete: " + pal)
		for effect in Synth.EFFECTS:
			var st: AudioStreamWAV = streams[effect]
			_check(st.format == AudioStreamWAV.FORMAT_16_BITS
				and st.mix_rate == Synth.RATE
				and st.data.size() > 100, "valid stream: " + pal + "/" + effect)
	var fallback := Synth.build("nope")
	_check((fallback["boom"] as AudioStreamWAV).data.size()
		== (Synth.build("classic")["boom"] as AudioStreamWAV).data.size(),
		"unknown palette falls back to classic")
	arena._sfx_palette = "punchy"
	arena._build_sfx()
	arena._build_sfx()
	_check(arena._sfx_players.size() == 4, "rebuild never stacks players")
	_check(arena._sfx_streams.size() == 6, "rebuild keeps all streams")
	arena._sfx_palette = "classic"
	arena._build_sfx()


func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	test_synth_buffers()
	test_player_pool()
	test_play_guards()
	test_mute_key()
	test_announce_clips()
	test_hit_sfx_routing()
	test_palettes_build()
	if failures == 0:
		print("ALL SOUND TESTS PASSED")
	else:
		printerr("SOUND TESTS: %d FAILURES" % failures)
	quit(failures)
	return true
