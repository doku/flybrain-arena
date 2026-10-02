extends SceneTree
## Headless menu-page tests: the menu opens on three tabbed pages (fly
## brains / training / tournament) with exactly one visible, tabs
## switch visibility without rebuilding, and every former column
## widget still exists exactly once. _build_layout is pure widgets
## (no vault I/O), so a tree-less instance suffices - _ready never runs.
## Run: godot --headless --path arena -s tests/test_menu_pages.gd
## Exit code = failure count (0 = all green).

var failures := 0
var menu = null


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var scr = load("res://scripts/MainMenu.gd")
	if scr == null or not scr.can_instantiate():
		printerr("FAIL: menu script loads")
		failures += 1
		quit(failures)
		return
	menu = scr.new()
	menu._build_layout()


func _is_on_page(node: Control, page_idx: int) -> bool:
	var p: Control = menu._menu_pages[page_idx]
	return p.is_ancestor_of(node)


func _process(_delta: float) -> bool:
	_check(menu._menu_pages.size() == 3, "three pages")
	_check(menu._page_buttons.size() == 3, "three tab buttons")
	_check((menu._menu_pages[0] as Control).visible
		and not (menu._menu_pages[1] as Control).visible
		and not (menu._menu_pages[2] as Control).visible,
		"first page visible at boot")
	# Every former column landed on its page exactly once.
	_check(_is_on_page(menu.brain_list, 0), "vault list on brains page")
	_check(_is_on_page(menu.archive_list_view, 0), "archive on brains page")
	_check(_is_on_page(menu.detail_label, 0), "detail on brains page")
	_check(_is_on_page(menu.queue_list, 1), "train queue on training page")
	_check(_is_on_page(menu.score_list, 1), "score queue on training page")
	_check(_is_on_page(menu.gen_name, 1), "generate form on training page")
	_check(_is_on_page(menu.player_list, 2), "participants on tournament page")
	_check(_is_on_page(menu.resume_button, 2), "resume on tournament page")
	_check(_is_on_page(menu.quick_button, 2), "quick battle on tournament page")
	_check(_is_on_page(menu.bracket_view, 2), "bracket on tournament page")
	# Two columns per page (vertical fit rework): page = HBox holding
	# two VBox columns.
	for i in 3:
		var pg: Control = menu._menu_pages[i]
		_check(pg is HBoxContainer and pg.get_child_count() == 2,
			"page %d holds two columns" % i)
	# Vertical-fit regression: every page's minimum height must fit
	# the window's page budget. Budget = 720 window - 24 margins -
	# 201 persistent rows - 56 separations (7 gaps x 8, hidden pages
	# take no separation) = 439. Headless probes once measured
	# 505/691/913 and the pages overflowed off-screen.
	for i in 3:
		var h: float = (menu._menu_pages[i] as Control).get_combined_minimum_size().y
		_check(h <= 439.0, "page %d fits vertically (%.0fpx)" % [i, h])
	# Tab switch flips visibility, keeps widgets.
	menu._show_menu_page(2)
	_check((menu._menu_pages[2] as Control).visible
		and not (menu._menu_pages[0] as Control).visible,
		"tournament tab shows")
	_check(_is_on_page(menu.brain_list, 0), "vault list survives switch")
	menu._show_menu_page(1)
	_check((menu._menu_pages[1] as Control).visible
		and not (menu._menu_pages[2] as Control).visible,
		"training tab shows")
	# Persistent footer: settings + launch bar outside the pages.
	_check(menu.bv_enable != null and menu.perf_pip != null
		and menu.sound_voice != null, "settings rows persist")
	# Oct 2026 right-edge overflow regression: live-length SAPI voice
	# names once stretched the SOUND row to 1035px, past the window
	# edge (headless hides it - no voices there). Shortened labels
	# bound the row; the full name rides the tooltip.
	menu._fill_voice_picker(["Microsoft Hazel Desktop - English (Great Britain)",
		"Microsoft David Desktop - English (United States)"])
	var srow: Control = menu.sound_voice_pick.get_parent()
	_check(srow.get_combined_minimum_size().x <= 900.0,
		"live-length voices keep the SOUND row under 900px")
	_check(menu.sound_voice_pick.get_item_text(1)
		== "Microsoft Hazel Desktop...", "voice labels shortened for display")
	_check(str(menu._sound_voice_names[1])
		== "Microsoft Hazel Desktop - English (Great Britain)",
		"full voice name kept for tooltip")
	menu.sound_voice_pick.selected = 1
	menu._sound_voice_tooltip()
	_check(menu.sound_voice_pick.tooltip_text.begins_with("Microsoft Hazel"),
		"tooltip carries the full name")
	_check(menu._short_voice_label("Zira") == "Zira",
		"short labels unchanged")
	if failures == 0:
		print("ALL MENU-PAGE TESTS PASSED")
	else:
		printerr("MENU-PAGE TESTS: %d FAILURES" % failures)
	quit(failures)
	return true
