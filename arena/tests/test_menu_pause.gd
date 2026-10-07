extends SceneTree
## Headless pause-overlay tests: MENU button + training panel standalone
## (no scene swap), pause/unpause with wall-clock deadline rebase, and
## the quit teardown. Quarantined (test_mute) like every arena suite.
## Tests run in _process (frames exist: the arena is in the tree only
## after the first frame - _initialize-time probes see a dead tree).
## Run: godot --headless --path arena -s tests/test_menu_pause.gd
## Exit code = failure count (0 = all green).

var failures := 0
var arena = null
var _stage := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func test_standalone_panel() -> void:
	# The training page builds standalone (no _ready scene-boot flow,
	# no FO_DIRECT bypass): queue widgets exist, handlers work. The
	# roster stub is injected (no vault dependency). Read-only.
	var scr = load("res://scripts/MainMenu.gd")
	var menu = scr.new()
	var box: Control = menu.build_standalone_training()
	_check(box != null and box.get_child_count() >= 3, "standalone panel builds")
	_check(menu.standalone, "standalone flag set")
	_check(menu.queue_list != null and menu.score_list != null,
		"queue lists built")
	_check(menu.train_brain_list != null, "brain picker built")
	_check(menu.log_label != null and menu.detail_label != null,
		"feedback labels scaffolded")
	_check(menu.gen_name != null and menu.gen_episodes != null,
		"generate form built")
	menu.brains = [{"id": "a1", "name": "Alpha",
		"record": {"elo": 1300.0}, "training": {}}]
	menu.selected_brain = {}
	menu._fill_brain_lists()
	_check(menu.train_brain_list.item_count == 1, "roster fills standalone")
	menu._on_brain_selected(0)
	_check(str(menu.selected_brain.get("id", "")) == "a1",
		"picker selects standalone")
	menu._standalone_refresh()
	_check(true, "standalone refresh runs")
	menu.queue_free()


func test_scene_menu_untouched() -> void:
	var scr = load("res://scripts/MainMenu.gd")
	var menu = scr.new()
	_check(not menu.standalone, "standalone defaults false")
	menu.queue_free()


func test_overlay_lifecycle() -> void:
	# MENU builds the overlay hidden with ALWAYS mode (buttons alive
	# while paused); pause sets the tree flag + stamps the clock;
	# resume rebases the wall-clock deadlines by the pause duration
	# and unpauses; the arena stays INHERIT (freezes beneath).
	arena._build_menu_overlay()
	_check(is_instance_valid(arena.menu_overlay), "overlay builds")
	_check(not arena.menu_overlay.visible, "overlay hidden at build")
	_check(arena.menu_overlay.process_mode == Node.PROCESS_MODE_ALWAYS,
		"overlay runs while paused")
	_check(arena.process_mode == Node.PROCESS_MODE_INHERIT,
		"arena freezes beneath (INHERIT)")
	var bars := []
	for c in arena.get_node("HUD").get_children():
		if str(c.name) == "MenuBar":
			bars.append(c)
	var found := false
	for bar in bars:
		for b in (bar as Control).get_children():
			if b is Button and str((b as Button).text) == "MENU":
				found = true
	_check(found and bars.size() >= 1, "MENU button in the menu bar")
	# Pause: flag + stamp (synchronous; no awaits while paused).
	arena._on_menu_pause()
	_check(paused, "pause sets the tree flag")
	_check(arena._pause_started_msec > 0, "pause stamps the clock")
	_check(arena.menu_overlay.visible, "overlay shows while paused")
	# Resume rebase: deadlines armed pre-pause advance by the pause.
	arena._seq_deadline_msec = 1000
	arena._step_deadline_msec = 2000
	arena._bank_last_send_msec = 3000
	arena._load_stall_since_msec = 4000
	arena._pause_started_msec = Time.get_ticks_msec() - 5000
	arena._on_menu_resume()
	_check(not paused, "resume unpauses")
	_check(not arena.menu_overlay.visible, "overlay hides on resume")
	_check(arena._seq_deadline_msec == 6000, "seq deadline rebased")
	_check(arena._step_deadline_msec == 7000, "step deadline rebased")
	_check(arena._bank_last_send_msec == 8000, "bank tick rebased")
	_check(arena._load_stall_since_msec == 9000, "load supervisor rebased")
	_check(arena._pause_started_msec == 0, "clock cleared on resume")
	# Disarmed deadlines stay 0 (a rebased zero would arm spuriously).
	arena._pause_started_msec = Time.get_ticks_msec() - 5000
	arena._seq_deadline_msec = 0
	arena._step_deadline_msec = 0
	arena._bank_last_send_msec = 0
	arena._load_stall_since_msec = 0
	arena._on_menu_resume()
	_check(arena._seq_deadline_msec == 0, "disarmed seq stays disarmed")
	_check(arena._step_deadline_msec == 0, "disarmed step stays disarmed")


func test_menu_quit_unpauses() -> void:
	# QUIT in the overlay unpauses BEFORE the teardown (a scene change
	# under a paused tree would boot the menu frozen). The scene change
	# is deferred: assertions run same-frame; the suite quits right
	# after (the harness never completes the change).
	arena._on_menu_pause()
	_check(paused, "paused for quit test")
	arena._pause_started_msec = 123
	arena._on_menu_quit()
	_check(not paused, "quit unpauses first")
	_check(arena._pause_started_msec == 0, "quit clears the clock")
	_check(not arena.menu_overlay.visible, "quit hides the overlay")


func _initialize() -> void:
	load("res://scripts/BrainClient.gd").test_mute = true
	var scene = load("res://scenes/ArenaGlade.tscn")
	arena = scene.instantiate()
	root.add_child(arena)


func _process(_delta: float) -> bool:
	if _stage == 0:
		_stage = 1
		test_standalone_panel()
		test_scene_menu_untouched()
		test_overlay_lifecycle()
		test_menu_quit_unpauses()
		paused = false
		arena.queue_free()
		if failures == 0:
			print("ALL MENU-PAUSE TESTS PASSED")
		else:
			printerr("MENU-PAUSE TESTS: %d FAILURES" % failures)
		quit(failures)
	return true
