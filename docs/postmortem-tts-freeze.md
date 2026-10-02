# Post-mortem: hard freeze after the first battle (Oct 2026)

## Incident

After the first battle of a tournament ended, the game window became
fully unresponsive (no bracket, no banner movement) and had to be
force-quit. Build contained round-batch banking (`3882d8b`), stop-and-wait
pacing (`160c833`), and the new TTS announcer + procedural SFX (`38ba972`).

## Timeline (from logs)

| Time | Source | Event |
|---|---|---|
| 15:13:11 | arena_log | Intermission TIP-OFF 30 s |
| 15:13:42 | arena_log + server_log | Brains loaded, R1M1 Umber vs ProtoB |
| ~15:13:56 | tournaments/T6ABF5985.json | Bracket advanced (battle ended, match over) |
| 15:13:58 | server_log | R1M2 preload received (`tournament_prepare`) |
| after | — | Silence. Arena wedged inside `_on_match_over`, after the preload, before any further server message. Server healthy and idle. |

## Investigation

Ruled out, with evidence:

- **Server fault:** no — it processed the preload at 15:13:58 and waited correctly afterwards.
- **Slow motion stuck on:** no — `_restore_timescale` sets 1.0 unconditionally.
- **Dead UDP link:** no — the R1M2 preload was delivered; the link was alive.
- **Missing control steps:** no anomaly — the battle ran ~14 s (< 50 total steps), so the server's 50-step `step ~Nms` line never tripped. Short battle, not a silent link.
- **Broken timer/await:** no — `create_timer(6.0)` with timescale 1.0 fires reliably; nothing else in that window can block.

Remaining suspect: the only call in the freeze window that can block
the main thread indefinitely — `_announce()` → `DisplayServer.tts_speak(..., interrupt=true)`,
new in this build, first exercised at battle end. SAPI purge-before-speak
on a busy voice is a known main-thread deadlock shape, matching every
observed fact (dead window, no bracket yet, force-quit required, server
idle, earlier SFX proven working mid-battle).

## Fix (commit `3a024f8`)

`_announce` now speaks **only when the voice reports idle**
(`tts_is_speaking()` guard); a colliding line is dropped and logged,
never forced through. `interrupt=true` removed. Every attempt writes to
`arena_log.txt` (`announce:` / `announce dropped (voice busy):`), so the
next log names the exact call if it ever wedges again. Status: user
confirmed the game "runs better now" after pulling the fix.

## Contributing factors

1. **Headless-vs-live behavioral gaps.** Two in one week: `get_meta` with
   a default errors on the live build but not headless (gallery crash,
   `2fc198d`); OS speech exists only live, so no suite could ever
   exercise the TTS path. Anything OS-backed must be distrusted by
   default and guarded at runtime.
2. **Harness blindness.** `test_menu_prefill` printed PASSED while its
   subject failed to load (`load()` → null → `.new()` aborts silently,
   exit 0). Fixed same day: suites now assert their subject loads
   (`86e7970`).
3. **No announce trace logging.** The battle-end path logged to console
   only, and the user's console was closed — diagnosis rested on
   timestamp correlation. All future OS-blocking calls must leave a
   before/after trace in a persisted log.

## Follow-ups

- Audio quality review (user dislikes SAPI voice + synth SFX): see
  voice/SFX options evaluation; candidate is an async neural engine
  (Kokoro GDExtension) and/or real sampled SFX, both of which also
  retire the SAPI deadlock class architecturally.
- Stale `matchbank` references in `test_event_groups` / `test_combat_fx`
  emit benign `SCRIPT ERROR` noise (leftover from round-batch).
- Consider load-guards in every suite that `load()`s a script.
