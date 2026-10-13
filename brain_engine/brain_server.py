import atexit
import os
import sys
import json
import time
import socket
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import numpy as np

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from sensory_motor import (SensoryEncoder, MotorDecoder, normalize_mapping,
                             normalize_yaw_bias, is_legacy_record)
from evolution_engine import EvolutionManager
from dopamine_learning import DopamineReinforcement
from experimental_wiring import (experiment_arrays, experiment_suffix,
                                   normalize_experiment, mix_label,
                                   build_genome_arrays, genome_label)


def _load_variant_weights(checkpoints_dir, names, fallback):
    """Loads the first existing variant file, else fallback array."""
    for name in names:
        path = os.path.join(checkpoints_dir, name)
        if os.path.exists(path):
            print(f"[Server] Loading variant weights from {path}...")
            return np.load(path)["weights"], name
    return fallback, None


def _pool_index(pops):
    """Named-pool id sets for the brain-view stream (built once per boot;
    stale-cache safe: absent pools read empty). A parallel flat-array
    dict ("__flat") backs the vectorized per-tick pool counts (spikes
    are few per tick; np.isin over ~7k-member sets beats that many dict
    lookups per pool per tick per brain)."""
    idx = {}
    for key in ("pheromone_da1", "pheromone_va1v", "visual_lc10",
                "visual_lc4", "visual_lplc2", "visual_lc11", "visual_lc15",
                "visual_lc17", "visual_lc18", "gyro_jo",
                "visual_t4a", "visual_t4b", "visual_t4c", "visual_t4d",
                "visual_t5a", "visual_t5b", "visual_t5c", "visual_t5d",
                "motor_thrust_dnp09", "motor_turn_dnp20",
                "motor_giant_fiber", "motor_ram_dnpe017", "motor_mouth",
                "motor_flight_thrust", "motor_steer", "flow_vs", "flow_hs",
                "mbon_app", "mbon_av"):
        p = pops.get(key, {})
        ids = set(p.get("all", [])) if isinstance(p, dict) else set()
        idx[key] = ids
    dn = pops.get("descending_all", {})
    idx["dn_left"] = set(dn.get("left", []))
    idx["dn_right"] = set(dn.get("right", []))
    flat = {}
    for key, ids in idx.items():
        flat[key] = np.asarray(sorted(ids), dtype=np.int64) if ids \
            else np.empty(0, dtype=np.int64)
    idx["__flat"] = flat
    return idx


RASTER_CAP = 128
# Multi-part round-report reassembly: oversize banks arrive as
# round_report_part messages (same nonce, part_idx/part_count) and
# process EXACTLY once, whole, through the normal handler - atomicity
# and the nonce contract are untouched. Bounded so a hostile or
# wedged client cannot grow memory: oldest incomplete nonce drops.
_ROUND_PART_STASH = {}
_ROUND_PART_STASH_MAX = 8


def _assemble_round_parts(nonce, entry):
    """Rebuild one round_report from completed parts, or None while
    incomplete. Match order follows first-seen parts; a match split
    across parts concatenates its battle slices in part order.
    Pure (unit-tested)."""
    parts = entry.get("parts", {})
    if not parts or len(parts) != entry.get("count", 0):
        return None
    first = parts[min(parts)]
    out_matches = []
    seen = {}
    for i in sorted(parts):
        for m in parts[i].get("matches", []):
            if not isinstance(m, dict):
                continue
            mid = str(m.get("match_id", "") or ("#%d" % len(seen)))
            if mid in seen:
                seen[mid]["battles"].extend(m.get("battles", []))
            else:
                nm = dict(m)
                nm["battles"] = list(m.get("battles", []))
                seen[mid] = nm
                out_matches.append(nm)
    return {"type": "round_report", "round_nonce": nonce,
            "tournament_id": str(first.get("tournament_id", "")),
            "match": str(first.get("match", "")),
            "group": bool(first.get("group", False)),
            "matches": out_matches}


def _run_side_integrate(dec, brain, stim, sens, pops, pool_idx, detail):
    """Integrate->decode->stats for one fighter. Pure function of its
    inputs (distinct brain object, read-only decoder): safe on worker
    threads. Encoding stays on the main thread deliberately: the
    Poisson sampler uses the shared global RandomState, which must
    never be touched from two threads at once."""
    spikes = brain.integrate_50ms(stim)
    counts = {}
    ctrl = dec.decode(spikes, sensory_hint=sens, _counts_out=counts)
    stats = _spike_stats(spikes, pops, pool_idx, detail, _counts=counts)
    return ctrl, stats, sens, spikes


def _raster_ids(pool_idx, pool, cap=RASTER_CAP):
    """Deterministic neuron-id slice for raster drill-down: sorted ids,
    capped (big pools show the first N cells), plus the pool total."""
    ids = sorted(pool_idx.get(pool, set()))
    return ids[:cap], len(ids)


def _spike_stats(spikes, pops, pool_idx=None, detail=0, _counts=None):
    """Compact brain-activation summary for the HUD + brain view.

    Always carries the legacy HUD keys plus a per-pool count dict
    (~20 ints, cheap). detail>=2 additionally carries capped raw spike
    ids for raster drill-down (truncation-guarded for UDP size).
    _counts: prebuilt spike->count dict from decode (skips its build).
    """
    if len(spikes) == 0:
        base = {"spikes": 0, "dn_left": 0, "dn_right": 0, "lplc2": 0,
                "mn_thrust": 0, "vs_flow": 0, "pools": {}}
        if detail >= 2:
            base["spike_ids"] = []
        return base
    if pool_idx is None:
        dn_left = set(pops.get("descending_all", {}).get("left", []))
        dn_right = set(pops.get("descending_all", {}).get("right", []))
        lplc2 = set(pops.get("visual_lplc2", {}).get("all", []))
        mn_thrust = set(pops.get("motor_flight_thrust", {}).get("all", []))
        vs_flow = set(pops.get("flow_vs", {}).get("all", [])) | set(
            pops.get("flow_hs", {}).get("all", []))
    else:
        dn_left = pool_idx["dn_left"]
        dn_right = pool_idx["dn_right"]
        lplc2 = pool_idx["visual_lplc2"]
        mn_thrust = pool_idx["motor_flight_thrust"]
        vs_flow = pool_idx["flow_vs"] | pool_idx["flow_hs"]
    if _counts is None:
        _counts = {}
        for s in spikes:
            s = int(s)
            _counts[s] = _counts.get(s, 0) + 1
    counts = _counts
    out = {
        "spikes": int(len(spikes)),
        "dn_left": int(sum(counts.get(s, 0) for s in dn_left)),
        "dn_right": int(sum(counts.get(s, 0) for s in dn_right)),
        "lplc2": int(sum(counts.get(s, 0) for s in lplc2)),
        "mn_thrust": int(sum(counts.get(s, 0) for s in mn_thrust)),
        "vs_flow": int(sum(counts.get(s, 0) for s in vs_flow)),
    }
    if pool_idx is not None and isinstance(pool_idx.get("__flat"), dict):
        # Vectorized per-pool counts (flat arrays built once per boot):
        # one np.isin pass per pool instead of a ~7k-iteration dict loop.
        flat = pool_idx["__flat"]
        pools = {}
        for key, ids in pool_idx.items():
            if key in ("dn_left", "dn_right", "__flat"):
                continue
            pools[key] = int(np.isin(spikes, flat[key]).sum())
        out["pools"] = pools
    elif pool_idx is not None:
        pools = {}
        for key, ids in pool_idx.items():
            if key in ("dn_left", "dn_right"):
                continue
            pools[key] = int(sum(counts.get(s, 0) for s in ids))
        out["pools"] = pools
    else:
        out["pools"] = {}
    if detail >= 2:
        # Truncation guard: UDP packets cap at 64 KB; spike ids are
        # small ints but a hot tick could still overflow it.
        ids = [int(s) for s in spikes[:3000]]
        out["spike_ids"] = ids
        out["spike_ids_truncated"] = bool(len(spikes) > 3000)
    return out


# Last free-battle verdict (in-memory only): free round_overs carry
# unique battle ids, so a watchdog retry resends the stored verdict
# instead of advancing a second generation. Tournament battles use the
# journaled verdict on disk; free battles bank no vault records, so
# memory suffices (a crash loses the free session's brains anyway).
_last_free_verdict = {"key": None, "result": None}


def _handle_free_round_over(sock, client_addr, msg, evo_mgr,
                            brain_alpha, brain_beta, winner,
                            fit_a, fit_b, battle_id, target_pathways):
    """Free-battle verdict: dopamine already applied by the caller;
    advances one generation and replies. A repeated battle id resends
    the stored verdict without re-advancing. Returns the reply dict."""
    global _last_free_verdict
    if battle_id and battle_id == _last_free_verdict.get("key"):
        resp = _last_free_verdict["result"]
        print(f"[Server] Duplicate free {battle_id}: resending stored "
              f"verdict, no re-advance.", flush=True)
        try:
            sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return resp
    evo_mgr.advance_generation(brain_alpha, brain_beta, winner,
                               target_pathways)
    resp = {
        "status": "generation_advanced",
        "new_generation": evo_mgr.generation,
        "previous_winner": winner,
    }
    if battle_id:
        _last_free_verdict = {"key": battle_id, "result": dict(resp)}
    sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    return resp


def _handle_tournament_round_over(sock, client_addr, msg, winner, fit_a, fit_b,
                                   tourney_a, tourney_b, tourney_tag,
                                   tournament_lr_scale, pulse, tourney_note,
                                   battle_id="", battle_key=None):
    """Tournament battle verdict. Identities survive: no clone/mutate, no
    generation++. Updated weights + records are persisted straight back
    to the vault (the arena/GDScript side can't write zips). Persistence
    is journal-first: the full transaction (post-learning weights + bumped
    records + reply verdict) is fsynced to tournaments/_pending_battle.npz
    and then replayed by _recover_pending_battle, which saves both vault
    files and only afterwards persists the verdict to
    tournaments/_last_battle_verdict.json BEFORE the reply goes out. A
    crash anywhere mid-save leaves the journal behind, and the next
    message (or server boot) replays the SAME record bumps instead of
    re-banking, so a resent round_over (same battle_key) is answered
    from the stored verdict and never banked twice."""
    import brain_package as vault_pkg
    arena_draw = bool(msg.get("arena_draw", False))
    draw_penalty = bool(msg.get("draw_penalty", False))
    # Arena verdict: how the battle ended + the killing blow (absent on
    # old clients/tests - .get defaults keep those paths working).
    end_reason = str(msg.get("end_reason", "") or "")
    verdict = msg.get("verdict", None) or {}
    if not isinstance(verdict, dict):
        verdict = {}
    # Arena-decided outcomes (KO killing blow, timeout by remaining
    # health) arrive in verdict.winner_slot and bank as declared — the
    # server records and trains, it does not re-decide. Empty slot
    # keeps the message-loop fitness verdict for old clients. Draws
    # are untouched (battle_winner stays "draw" below regardless).
    if not arena_draw:
        _forced = str(verdict.get("winner_slot", "") or "")
        if _forced in ("alpha", "beta"):
            winner = _forced
    battle_winner = "draw" if arena_draw else winner
    if arena_draw:
        report = ("draw (3rd, both ELOs docked)" if draw_penalty
                  else "draw (clean, replay)")
    elif end_reason == "ko":
        blow = str(verdict.get("blow_source", "") or "?")
        amt = float(verdict.get("blow_amount", 0.0) or 0.0)
        loser = str(verdict.get("loser_slot", "") or "?")
        report = (f"KO ({blow} {amt:.1f} on {loser})"
                  if amt > 0.0 else f"KO ({blow} finisher on {loser})")
    elif end_reason == "time":
        da = float(verdict.get("dmg_a", 0.0) or 0.0)
        db = float(verdict.get("dmg_b", 0.0) or 0.0)
        wslot = str(verdict.get("winner_slot", "") or "")
        if wslot in ("alpha", "beta"):
            report = (f"TIME ({wslot} wins on health, "
                      f"damage {da:.0f}-{db:.0f})")
        else:
            report = f"TIME (damage {da:.0f}-{db:.0f}, fitness decides)"
    else:
        sa = msg.get("stats_alpha", None) or {}
        sb = msg.get("stats_beta", None) or {}
        report = ("KO" if (sa.get("kills") or sb.get("kills"))
                  else "decided")
    records = []
    weights = {}
    for side, st in (("alpha", tourney_a), ("beta", tourney_b)):
        if st["rec"] is None:
            continue
        rec = deepcopy(st["rec"])
        outcome = "draw" if arena_draw else ("win" if side == winner else "loss")
        vault_pkg.record_battle_result(rec, outcome)
        # Career KO wins (baked into the journaled record, so retries
        # replay the same value, never double-count). Old records lack
        # the key and start at 0 going forward.
        if not arena_draw and end_reason == "ko" and side == winner:
            rec["record"]["ko"] = int(rec["record"].get("ko", 0)) + 1
        # Career wander mark (journaled with the records, so retries
        # replay the same value). Old records lack the key (start 0).
        if arena_draw:
            drift = float(((msg.get("stats_alpha", {}) if side == "alpha"
                            else msg.get("stats_beta", {})) or {}).get(
                                "center_drift", 0.0))
            if drift >= vault_pkg.WANDER_MARK_M:
                rec["record"]["wander"] = int(
                    rec["record"].get("wander", 0)) + 1
        if not arena_draw:
            vault_pkg.log_training_session(
                rec, 0,
                {"lr_scale": tournament_lr_scale,
                 "pulse": pulse if outcome == "win" else -0.8 * pulse,
                 "outcome": outcome},
                f"tournament battle {outcome} ({tourney_note()})")
        records.append({"side": side, "record": rec})
        weights[side] = st["brain"].weights
    # ELO per battle (lands in the journaled records above, so retries
    # can never double-apply it). Third-draw stall penalty on top.
    ra = next((r["record"] for r in records if r["side"] == "alpha"), None)
    rb = next((r["record"] for r in records if r["side"] == "beta"), None)
    if ra is not None and rb is not None:
        out_a = "draw" if arena_draw else ("win" if winner == "alpha" else "loss")
        vault_pkg.apply_elo(ra, rb, out_a, vault_pkg.ELO_K_BATTLE)
        if arena_draw and draw_penalty:
            vault_pkg.apply_draw3_penalty(ra, rb)
    fit_a, fit_b = _sanitize_fit(fit_a), _sanitize_fit(fit_b)
    print(f"[Server] Tournament battle done id={battle_id or '?'} "
          f"({tourney_note()}) winner={battle_winner} by {report} "
          f"fit {fit_a:.1f}-{fit_b:.1f}", flush=True)
    resp = {
        "status": "tournament_battle",
        "battle_winner": battle_winner,
        "fitness_alpha": fit_a,
        "fitness_beta": fit_b,
        "battle_id": battle_id,
        "end_reason": end_reason,
        "verdict": verdict,
        "report": (f"{battle_winner} wins by {report}"
                   if not arena_draw else f"draw ({report})"),
    }
    # Journal-first, records-only: the journal carries the bumped records
    # (idempotent replay) but no weight payloads — ~200 MB of fsync'd
    # writes saved per battle. Post-learning weights persist on the live
    # path below; a crash between journal and weight save falls back to
    # pre-battle weights while records still replay exactly once.
    # (Draws were already records-only: no plasticity, weights identical.)
    for r in records:
        r["weights_unchanged"] = True
    live_weights = weights
    weights = {}
    _t_journal = time.perf_counter()
    _emit_progress(sock, client_addr, battle_id, "journal")
    _write_pending_battle(battle_key, resp, records, weights)
    # Live path: bank post-learning weights while the journal still
    # guards the records. Crash here replays the bumped records (sidecar
    # path) while weights fall back to pre-battle — approved tradeoff.
    # st["rec"] sync + verdict land in recover below.
    _t_weights = time.perf_counter()
    _emit_progress(sock, client_addr, battle_id, "weights")
    for entry in records:
        side = entry["side"]
        if side in live_weights:
            # Compressed (~19 MB, single-deflate): laptop disks stall
            # on 100 MB uncompressed writes and blow the confirm
            # deadline; a couple of CPU seconds is the cheaper trade.
            vault_pkg.save_brain(entry["record"], live_weights[side],
                                 backup=False, fast=False)
    _t_recover = time.perf_counter()
    _emit_progress(sock, client_addr, battle_id, "recover")
    _recover_pending_battle((tourney_a, tourney_b))
    print(f"[Server] battle {battle_id or '?'}: journal "
          f"{_t_weights - _t_journal:.1f}s + weights "
          f"{_t_recover - _t_weights:.1f}s + recover+verdict "
          f"{time.perf_counter() - _t_recover:.1f}s", flush=True)
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        # Dead client port (arena changed scenes): the verdict is already
        # persisted, so the arena's retry will be answered from disk.
        print(f"[Server] send tournament_battle failed (kept verdict): {e}",
              flush=True)


_last_title_banked = {"key": None}


class _WeightsBox:
    """Minimal brain stand-in so id-based title banking can reuse
    _bank_title (which only touches rec + brain.weights)."""
    def __init__(self, weights):
        self.weights = weights


def _bank_title(side_state, champ_label, key=None):
    """Crown the champion: tournaments_won += 1 + vault save. A repeat
    call with the same key is a no-op (duplicate crowns must not stack
    titles). Returns True when anything was banked."""
    global _last_title_banked
    if key is not None and _last_title_banked.get("key") == key:
        return False
    import brain_package as vault_pkg
    st = side_state
    if st["rec"] is None:
        return False
    st["rec"]["record"]["tournaments_won"] += 1
    vault_pkg.save_brain(st["rec"], st["brain"].weights,
                         backup=False, fast=False)
    if key is not None:
        _last_title_banked = {"key": key}
    return True


def _bank_match_result(tourney_a, tourney_b, match_winner):
    """Match verdict banking as one unit (counters + match ELO + saves)
    so the message loop and tests share it. match_winner="draw" (group
    splits): matches bump for both, no won/lost side, ELO draw update
    (ratings move toward each other). Returns True when anything was
    banked."""
    import brain_package as vault_pkg
    banked = False
    recs = {}
    for side, st in (("alpha", tourney_a), ("beta", tourney_b)):
        if st["rec"] is None:
            continue
        outcome = "draw" if match_winner == "draw" else (
            "win" if side == match_winner else "loss")
        vault_pkg.record_match_result(st["rec"], outcome)
        recs[side] = st["rec"]
        banked = True
    if "alpha" in recs and "beta" in recs:
        vault_pkg.apply_elo(recs["alpha"], recs["beta"],
                            match_winner if match_winner == "draw" else (
                                "win" if match_winner == "alpha" else "loss"),
                            vault_pkg.ELO_K_MATCH)
    for side, st in (("alpha", tourney_a), ("beta", tourney_b)):
        if st["rec"] is None:
            continue
        vault_pkg.save_brain(st["rec"], st["brain"].weights,
                             backup=False, fast=False)
    return banked


def _handle_match_report(sock, client_addr, msg, tourney_tag,
                         tournament_lr_scale, tournament_mode, evo_mgr,
                         dopamine_rl, base_lr, tourney_note, csr, pops,
                         struct_cache):
    """ONE bank per match: the arena cached every battle's stats/verdicts
    and reports the whole match at match over. Fighters resolve from the
    message paths (never the live pair), then the SHARED replay core
    runs (_replay_round_match: battles in order, dopamine+pin,
    K_BATTLE chain, records/ko/wander/sessions, match bank) - parity
    with round reports by construction. One journal (records-only) +
    one save pair; the reply echoes every battle. A partial report
    (quit flush) banks battles only - the match result stays undecided
    ("pending" skips the match bank inside the core)."""
    import brain_package as vault_pkg
    battles = msg.get("battles", [])
    if not isinstance(battles, list) or not battles:
        sock.sendto(json.dumps({"status": "error",
                                "error": "match_report: no battles"}
                               ).encode("utf-8"), client_addr)
        return
    match_id = str(msg.get("match_id", ""))
    tid = str(msg.get("tournament_id", "")
              or tourney_tag.get("tournament_id") or "")
    mlabel = str(msg.get("match", "") or tourney_tag.get("match") or "")
    match_winner = str(msg.get("match_winner", "") or "pending")
    # Exact-resend dedup: the same match nonce was banked already ->
    # resend the stored result, no re-bank. Fresh-nonce reports of the
    # same match bank fresh (quit-resume partials are continuations,
    # not replays - the resumed battles are new fights).
    match_key = {"tournament_id": tid, "match": mlabel, "battle_id": match_id}
    stored = _read_last_verdict()
    if stored is not None and stored.get("key") == match_key:
        print(f"[Server] Duplicate match report {mlabel}-{match_id}: "
              f"resending stored result, no re-bank.", flush=True)
        try:
            sock.sendto(json.dumps(stored["result"]).encode("utf-8"),
                        client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return
    _side = _read_match_verdict(match_key)
    if _side is not None:
        # An older bank whose verdict rotated out of the single slot
        # (later matches banked since): re-ack, never re-bank.
        print(f"[Server] Duplicate match report {mlabel}-{match_id} "
              f"(sidecar): resending stored result, no re-bank.", flush=True)
        try:
            sock.sendto(json.dumps(_side["result"]).encode("utf-8"),
                        client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return
    if not tournament_mode:
        # Match reports are tournament-shaped: refuse loudly in free
        # mode (the arena heals via QUIT TO MENU + RESUME). Silently
        # banking one would evolve boot brains.
        print(f"[Server] ERROR: match_report {match_id} while in FREE "
              f"mode ({tourney_note()}). Refused.", flush=True)
        sock.sendto(json.dumps({"status": "error",
                                "error": "match_report while in FREE mode "
                                         "- QUIT TO MENU + RESUME"
                               }).encode("utf-8"), client_addr)
        return
    alpha_path = str(msg.get("alpha_path", ""))
    beta_path = str(msg.get("beta_path", ""))
    if not alpha_path or not beta_path:
        # Never fall back to the live pair: a late resend landing
        # mid-tournament would learn one match's battles onto another
        # match's brains and save them under the wrong records.
        print(f"[Server] ERROR: match_report {mlabel}-{match_id} with no "
              f"fighter paths. Refused.", flush=True)
        sock.sendto(json.dumps({"status": "error",
                                "error": "match_report: no fighter paths"}
                               ).encode("utf-8"), client_addr)
        return
    t_start = time.perf_counter()
    ctx = {"evo_mgr": evo_mgr, "dopamine_rl": dopamine_rl,
           "base_lr": base_lr, "tournament_lr_scale": tournament_lr_scale,
           "tourney_note": tourney_note, "sock": sock,
           "client_addr": client_addr, "round_id": match_id,
           "csr": csr, "pops": pops, "struct_cache": struct_cache,
           "echoes": [], "final_records": [], "final_weights": {}}
    m = {"match_id": match_id, "match_winner": match_winner,
         "alpha_path": alpha_path, "beta_path": beta_path,
         "battles": battles}
    try:
        won = _replay_round_match(0, m, ctx, _resolve_fresh)
    except _ResolveError as e:
        sock.sendto(json.dumps({"status": "error",
                                "error": str(e.error).replace(
                                    "round_report:", "match_report:", 1)}
                               ).encode("utf-8"), client_addr)
        return
    bechoes = (ctx["echoes"] or [{}])[0].get("battles", [])
    resp = {
        "status": "tournament_match_battled",
        "match_winner": won,
        "fitness_alpha": 0.0,
        "fitness_beta": 0.0,
        "battle_id": match_id,
        "tournament_id": tid,
        "match": mlabel,
        "battles": bechoes,
        "report": (f"match banked: {len(bechoes)} battles "
                   f"(winner {won})"),
    }
    final_weights = ctx["final_weights"]
    _t_journal = time.perf_counter()
    _emit_progress(sock, client_addr, match_id, "journal")
    _write_pending_battle(match_key, resp, ctx["final_records"], {})
    _t_weights = time.perf_counter()
    _emit_progress(sock, client_addr, match_id, "weights")
    for entry in ctx["final_records"]:
        rec = entry["record"]
        bid = str(rec.get("id", ""))
        if bid in final_weights:
            vault_pkg.save_brain(rec, final_weights[bid],
                                 backup=False, fast=False)
            del final_weights[bid]
    _t_recover = time.perf_counter()
    _emit_progress(sock, client_addr, match_id, "recover")
    _recover_pending_battle(())
    _write_match_verdict(match_key, resp)
    print(f"[Server] match {match_id}: journal "
          f"{_t_weights - _t_journal:.1f}s + weights "
          f"{_t_recover - _t_weights:.1f}s + recover+verdict "
          f"{time.perf_counter() - _t_recover:.1f}s", flush=True)
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        print(f"[Server] send tournament_match_battled failed "
              f"(kept verdict): {e}", flush=True)


class _ResolveError(Exception):
    """Match-state resolver failure carrying the arena-facing error
    string. The handler sends it and returns; nothing banks."""
    def __init__(self, error):
        super().__init__(error)
        self.error = error


def _replay_round_match(mi, m, ctx, resolve):
    """Replays ONE round-report match onto resolved brain state: battles
    in order (evaluate, dopamine+pin with shipped sens/ctrl, K_BATTLE
    ELO chain, records/ko/wander/sessions) plus the match bank, then
    collects absolute snapshots for the journal. The ONLY per-path
    difference is resolve() (fresh vault load vs pinned group brains);
    every arithmetic line below runs identically in both, so group and
    per-round banking agree by construction. Returns the match winner
    string ("alpha"/"beta"/"draw"/"pending")."""
    import brain_package as vault_pkg
    mbattles = m.get("battles", []) or []
    mwinner = str(m.get("match_winner", "") or "pending")
    ra, rb, m_brain_a, m_brain_b, schemes_a, schemes_b, legacy_a, \
        legacy_b = resolve(mi, m, ctx)
    evo_mgr = ctx["evo_mgr"]
    dopamine_rl = ctx["dopamine_rl"]
    base_lr = ctx["base_lr"]
    tournament_lr_scale = ctx["tournament_lr_scale"]
    tourney_note = ctx["tourney_note"]
    sock, client_addr, round_id = ctx["sock"], ctx["client_addr"], \
        ctx["round_id"]
    bechoes = []
    for bi, b in enumerate(mbattles):
        if not isinstance(b, dict):
            continue
        bstats_a = b.get("stats_a", {}) or {}
        bstats_b = b.get("stats_b", {}) or {}
        bverdict = b.get("verdict", {}) or {}
        if not isinstance(bverdict, dict):
            bverdict = {}
        bdraw = bool(b.get("draw", False))
        bdraw_penalty = bool(b.get("draw_penalty", False))
        bend = str(b.get("end_reason", "") or "")
        winner, _fit_a, _fit_b = evo_mgr.evaluate_match(
            bstats_a, bstats_b, rec_a=ra, rec_b=rb)
        _forced = str(bverdict.get("winner_slot", "") or "")
        if not bdraw and _forced in ("alpha", "beta"):
            winner = _forced
        ko_win = bool(bstats_a.get("kills") or bstats_b.get("kills"))
        pulse = 1.0 if ko_win else 0.5
        dopamine_rl.lr = base_lr * tournament_lr_scale
        try:
            _emit_progress(sock, client_addr, round_id,
                           "match %d battle %d" % (mi + 1, bi + 1))
            _apply_round_learning(
                dopamine_rl, m_brain_a, m_brain_b, winner,
                b.get("sens_a", {}) or {}, b.get("sens_b", {}) or {},
                b.get("ctrl_a", {}) or {}, b.get("ctrl_b", {}) or {},
                pulse, schemes_a, schemes_b, legacy_a, legacy_b,
                arena_draw=bdraw)
        finally:
            dopamine_rl.lr = base_lr
        out_a = "draw" if bdraw else ("win" if winner == "alpha" else "loss")
        out_b = "draw" if bdraw else ("loss" if winner == "alpha" else "win")
        vault_pkg.record_battle_result(ra, out_a)
        vault_pkg.record_battle_result(rb, out_b)
        if not bdraw and bend == "ko" and winner == "alpha":
            ra["record"]["ko"] = int(ra["record"].get("ko", 0)) + 1
        if not bdraw and bend == "ko" and winner == "beta":
            rb["record"]["ko"] = int(rb["record"].get("ko", 0)) + 1
        if bdraw:
            da = float(bstats_a.get("center_drift", 0.0) or 0.0)
            db = float(bstats_b.get("center_drift", 0.0) or 0.0)
            if da >= vault_pkg.WANDER_MARK_M:
                ra["record"]["wander"] = int(
                    ra["record"].get("wander", 0)) + 1
            if db >= vault_pkg.WANDER_MARK_M:
                rb["record"]["wander"] = int(
                    rb["record"].get("wander", 0)) + 1
        if not bdraw:
            vault_pkg.log_training_session(
                ra, 0, {"lr_scale": tournament_lr_scale,
                        "pulse": pulse,
                        "outcome": out_a},
                f"tournament battle {out_a} ({tourney_note()})")
            vault_pkg.log_training_session(
                rb, 0, {"lr_scale": tournament_lr_scale,
                        "pulse": -0.8 * pulse,
                        "outcome": out_b},
                f"tournament battle {out_b} ({tourney_note()})")
        vault_pkg.apply_elo(ra, rb, out_a, vault_pkg.ELO_K_BATTLE)
        if bdraw and bdraw_penalty:
            vault_pkg.apply_draw3_penalty(ra, rb)
        bechoes.append({"battle_id": str(b.get("battle_id", "")),
                        "battle_winner": ("draw" if bdraw else winner)})
    # Match bank (skipped for pending flush strays): counters +
    # K_MATCH ELO on this match's copies.
    if mwinner in ("alpha", "beta", "draw"):
        out_a = ("win" if mwinner == "alpha"
                 else "loss" if mwinner == "beta" else "draw")
        vault_pkg.record_match_result(ra, out_a)
        vault_pkg.record_match_result(rb, "draw" if mwinner == "draw"
                                      else ("loss" if mwinner == "alpha"
                                            else "win"))
        vault_pkg.apply_elo(ra, rb, out_a, vault_pkg.ELO_K_MATCH)
    ctx["echoes"].append({"match_id": str(m.get("match_id", "")),
                         "match_winner": mwinner, "battles": bechoes})
    for side, rec, brain in (("alpha", ra, m_brain_a),
                             ("beta", rb, m_brain_b)):
        ctx["final_records"].append({"side": side, "record": rec,
                                    "weights_unchanged": True})
        ctx["final_weights"][str(rec.get("id", ""))] = brain.weights
    return mwinner


def _resolve_fresh(mi, m, ctx):
    """Pre-round vault state per match (the classic path): full disk
    load + bind per side, fresh record copies. Brain files on disk are
    the previous round's post-bank state, so matches never share
    fighters and no cross-match accumulation is needed."""
    import brain_package as vault_pkg
    try:
        rec_a, w_a = vault_pkg.load_brain(m.get("alpha_path", ""))
        rec_b, w_b = vault_pkg.load_brain(m.get("beta_path", ""))
        m_brain_a = _bind_brain(rec_a, w_a, ctx["csr"], ctx["pops"],
                                ctx["struct_cache"])
        m_brain_b = _bind_brain(rec_b, w_b, ctx["csr"], ctx["pops"],
                                ctx["struct_cache"])
    except Exception as e:
        print(f"[Server] round {ctx['round_id']} match {mi}: brain load "
              f"failed: {e}", flush=True)
        raise _ResolveError("round_report: brain load failed: %s" % e)
    ra = deepcopy(rec_a)
    rb = deepcopy(rec_b)
    schemes_a = normalize_mapping(
        ((rec_a or {}).get("generator_params", {}) or {}).get("mapping", None))
    schemes_b = normalize_mapping(
        ((rec_b or {}).get("generator_params", {}) or {}).get("mapping", None))
    legacy_a = is_legacy_record(rec_a)
    legacy_b = is_legacy_record(rec_b)
    return ra, rb, m_brain_a, m_brain_b, schemes_a, schemes_b, \
        legacy_a, legacy_b


def _group_pin_brain(bid, path, ctx):
    """Full load + bind + pin for one group fighter (first sighting
    only), snapshotting its vault record as the pre-group base. The
    pre-group snapshot is ALWAYS exact: vault records mutate only for
    fighters, and a fighter pins on its first fight - at which point
    its vault state is untouched by this group. Enforces GROUP_PIN_MAX
    instead of eating unbounded RAM."""
    import brain_package as vault_pkg
    pinned = _group_pinned["brains"]
    if len(pinned) >= GROUP_PIN_MAX and bid not in pinned:
        raise _ResolveError(
            "group pin cap exceeded (%d brains)" % GROUP_PIN_MAX)
    try:
        rec, w = vault_pkg.load_brain(path)
        brain = _bind_brain(rec, w, ctx["csr"], ctx["pops"],
                            ctx["struct_cache"])
        enc, dec = _bind_codecs(rec, ctx["pops"], ctx["codec_cache"])
    except Exception as e:
        raise _ResolveError("group pin load failed: %s" % e)
    gp = (rec.get("generator_params", {}) or {})
    pinned[bid] = {
        "rec": deepcopy(rec),
        "brain": brain, "enc": enc, "dec": dec,
        "schemes": normalize_mapping(gp.get("mapping", None)),
        "legacy": is_legacy_record(rec),
        "wiring": mix_label(gp.get("experiment", None)),
        "mapping": list(normalize_mapping(gp.get("mapping", None))),
        "pregroup": deepcopy(rec),
    }
    return pinned[bid]


def _group_resolve(mi, m, ctx):
    """Pinned group brains per match: record-only vault reads resolve
    ids, bound objects + working records come from the pin (RAM-only,
    accumulating across rounds). First sighting full-loads + pins."""
    import brain_package as vault_pkg
    out = {}
    for side, path in (("alpha", m.get("alpha_path", "")),
                       ("beta", m.get("beta_path", ""))):
        try:
            rec0 = vault_pkg.load_brain_record(path)
        except Exception as e:
            raise _ResolveError("group record lookup failed: %s" % e)
        bid = str((rec0 or {}).get("id", ""))
        if not bid:
            raise _ResolveError("group record lookup failed: no id")
        ent = _group_pinned["brains"].get(bid)
        if ent is None:
            try:
                ent = _group_pin_brain(bid, path, ctx)
            except _ResolveError:
                raise
            except Exception as e:
                raise _ResolveError("group pin load failed: %s" % e)
        out[side] = ent
    ea, eb = out["alpha"], out["beta"]
    return (ea["rec"], eb["rec"], ea["brain"], eb["brain"],
            ea["schemes"], eb["schemes"], ea["legacy"], eb["legacy"])


def _rebuild_group_session(ctx):
    """Restart-mid-group recovery: the pinned dict is gone but the
    inputs journal holds pre-group records + every banked round's
    deterministic replay inputs. Full vault loads (weights are
    pre-group: no mid-group saves exist), restore pre-group records,
    then replay all journaled rounds in order. evo-side counters
    (history/pool novelty) are snapshotted around the replay so the
    rebuild is side-effect-free there too. Returns True when a session
    was rebuilt (caller then processes the new round normally)."""
    import brain_package as vault_pkg
    doc = _group_inputs_read()
    if doc is None:
        return False
    # Restore exact-resend coverage too: without the banked round
    # resps, a post-restart stale retry would replay instead of
    # resending (double-bank). The journal carries every ack.
    _group_pinned["round_resps"] = {
        str(r.get("nonce", "")): r.get("resp", {})
        for r in doc.get("rounds", []) if isinstance(r, dict)}
    evo_mgr = ctx["evo_mgr"]
    saved_history = list(getattr(evo_mgr, "history", []))
    saved_pools = dict(getattr(evo_mgr, "pool_counts", {}))
    try:
        for bid, prec in (doc.get("pregroup", {}) or {}).items():
            rec, w = vault_pkg.load_brain(
                vault_pkg.package_path(prec.get("filename", "")))
            brain = _bind_brain(rec, w, ctx["csr"], ctx["pops"],
                                ctx["struct_cache"])
            enc, dec = _bind_codecs(rec, ctx["pops"], ctx["codec_cache"])
            gp = (rec.get("generator_params", {}) or {})
            _group_pinned["brains"][str(bid)] = {
                "rec": deepcopy(prec),
                "brain": brain, "enc": enc, "dec": dec,
                "schemes": normalize_mapping(gp.get("mapping", None)),
                "legacy": is_legacy_record(rec),
                "wiring": mix_label(gp.get("experiment", None)),
                "mapping": list(normalize_mapping(gp.get("mapping", None))),
                "pregroup": deepcopy(prec),
            }
        for rnd in doc.get("rounds", []):
            # Scratch collections: the rebuild must not pollute the
            # live round's echoes/snapshots (same helper, throwaway ctx).
            re_ctx = dict(ctx)
            re_ctx["echoes"] = []
            re_ctx["final_records"] = []
            re_ctx["final_weights"] = {}
            for mi, m in enumerate(rnd.get("matches", [])):
                if not isinstance(m, dict):
                    continue
                _replay_round_match(mi, m, re_ctx, _group_resolve_quiet)
        return True
    finally:
        try:
            evo_mgr.history = saved_history
            evo_mgr.pool_counts = saved_pools
            evo_mgr._save_pool_counts()
        except Exception:
            pass


def _group_resolve_quiet(mi, m, ctx):
    """Rebuild-path resolver: identical to _group_resolve but the pins
    are guaranteed present (pregroup pass just created them), so a
    miss is a corrupt journal, not a load."""
    bid_a = bid_b = ""
    import brain_package as vault_pkg
    for side, path in (("alpha", m.get("alpha_path", "")),
                       ("beta", m.get("beta_path", ""))):
        rec0 = vault_pkg.load_brain_record(path)
        if side == "alpha":
            bid_a = str((rec0 or {}).get("id", ""))
        else:
            bid_b = str((rec0 or {}).get("id", ""))
    try:
        ea = _group_pinned["brains"][bid_a]
        eb = _group_pinned["brains"][bid_b]
    except KeyError as e:
        raise _ResolveError("group rebuild pin miss: %s" % e)
    return (ea["rec"], eb["rec"], ea["brain"], eb["brain"],
            ea["schemes"], eb["schemes"], ea["legacy"], eb["legacy"])


def _handle_round_report(sock, client_addr, msg, tourney_a, tourney_b,
                         tourney_tag, tournament_lr_scale, tournament_mode,
                         evo_mgr, dopamine_rl, base_lr, tourney_note,
                         csr, pops, struct_cache, codec_cache=None):
    """ONE bank per round: matches replay in order (evaluate,
    dopamine+pin with shipped sens/ctrl, K_BATTLE ELO chain,
    records/ko/wander/sessions), then ONE journal (absolute final
    snapshots) + ONE save set (each brain fought once, saved once).
    Crash windows match the per-battle protocol exactly
    (journal-first, atomic replace, preamble recover, exact-nonce
    dedup), so retries never double-bank. Pending matches (quit-flush
    strays) bank battles only. NOTE: transient RAM holds all replayed
    weight arrays (~100 MB per brain) until the save loop frees them;
    the tradeoff for journal-first crash safety.
    GROUP MODE (msg group=true, group files only): brains stay pinned
    in RAM across rounds (no vault reloads, no weight saves); each
    round replays onto pinned state, journals records-only, recovers
    (cheap record flushes), and appends deterministic replay inputs
    to the group-inputs journal. The group bank (group_report) seals
    once. Crash windows: pre-group drive state + inputs journal =
    exact rebuild (see _rebuild_group_session); same nonce contract."""
    import brain_package as vault_pkg
    if codec_cache is None:
        codec_cache = {}
    matches = msg.get("matches", [])
    if not isinstance(matches, list) or not matches:
        sock.sendto(json.dumps({"status": "error",
                                "error": "round_report: no matches"}
                               ).encode("utf-8"), client_addr)
        return
    round_id = str(msg.get("round_nonce", ""))
    tid = str(msg.get("tournament_id", "")
              or tourney_tag.get("tournament_id") or "")
    mlabel = str(msg.get("match", "") or tourney_tag.get("match") or "")
    round_key = {"tournament_id": tid, "match": mlabel, "battle_id": round_id}
    stored = _read_last_verdict()
    if stored is not None and stored.get("key") == round_key:
        print(f"[Server] Duplicate round report {mlabel}-{round_id}: "
              f"resending stored result, no re-bank.", flush=True)
        try:
            sock.sendto(json.dumps(stored["result"]).encode("utf-8"),
                        client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return
    if not tournament_mode:
        print(f"[Server] ERROR: round_report {round_id} while in FREE "
              f"mode ({tourney_note()}). Refused.", flush=True)
        sock.sendto(json.dumps({"status": "error",
                                "error": "round_report while in FREE mode "
                                         "- QUIT TO MENU + RESUME"
                               }).encode("utf-8"), client_addr)
        return
    if bool(msg.get("group", False)):
        _handle_group_round(sock, client_addr, msg, round_id, tid, mlabel,
                            round_key, matches, tourney_a, tourney_b,
                            tourney_tag, tournament_lr_scale, evo_mgr,
                            dopamine_rl, base_lr, tourney_note,
                            csr, pops, struct_cache, codec_cache)
        return
    t_start = time.perf_counter()
    # Final absolute record snapshots (one entry per fighter) + final
    # weight refs (freed progressively by the save loop below).
    final_records = []
    final_weights = {}
    echoes = []
    fit_a, fit_b = 0.0, 0.0
    ctx = {"evo_mgr": evo_mgr, "dopamine_rl": dopamine_rl,
           "base_lr": base_lr, "tournament_lr_scale": tournament_lr_scale,
           "tourney_note": tourney_note, "sock": sock,
           "client_addr": client_addr, "round_id": round_id,
           "echoes": echoes, "final_records": final_records,
           "final_weights": final_weights, "csr": csr, "pops": pops,
           "struct_cache": struct_cache}
    for mi, m in enumerate(matches):
        if not isinstance(m, dict):
            continue
        try:
            _replay_round_match(mi, m, ctx, _resolve_fresh)
        except _ResolveError as e:
            sock.sendto(json.dumps({"status": "error", "error": e.error}
                                   ).encode("utf-8"), client_addr)
            return
    fit_a, fit_b = _sanitize_fit(fit_a), _sanitize_fit(fit_b)
    print(f"[Server] Round report banked {mlabel}-{round_id} "
          f"({tourney_note()}): {len(echoes)} matches, "
          f"dopamine+records {time.perf_counter() - t_start:.1f}s "
          f"(vault save next)", flush=True)
    resp = {
        "status": "round_banked",
        "battle_id": round_id,
        "tournament_id": tid,
        "match": mlabel,
        "matches": echoes,
        "report": (f"round banked: {len(echoes)} matches"),
    }
    _t_journal = time.perf_counter()
    _emit_progress(sock, client_addr, round_id, "journal")
    _write_pending_battle(round_key, resp, final_records, {})
    _t_weights = time.perf_counter()
    _emit_progress(sock, client_addr, round_id, "weights")
    for entry in final_records:
        rec = entry["record"]
        bid = str(rec.get("id", ""))
        if bid in final_weights:
            vault_pkg.save_brain(rec, final_weights[bid],
                                 backup=False, fast=False)
            del final_weights[bid]
    _t_recover = time.perf_counter()
    _emit_progress(sock, client_addr, round_id, "recover")
    _recover_pending_battle((tourney_a, tourney_b))
    print(f"[Server] round {round_id}: journal "
          f"{_t_weights - _t_journal:.1f}s + weights "
          f"{_t_recover - _t_weights:.1f}s + recover+verdict "
          f"{time.perf_counter() - _t_recover:.1f}s", flush=True)
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        print(f"[Server] send round_banked failed "
              f"(kept verdict): {e}", flush=True)


def _handle_group_round(sock, client_addr, msg, round_id, tid, mlabel,
                        round_key, matches, tourney_a, tourney_b,
                        tourney_tag, tournament_lr_scale, evo_mgr,
                        dopamine_rl, base_lr, tourney_note,
                        csr, pops, struct_cache, codec_cache):
    """Group-mode round: pinned brains replay in order (same arithmetic
    as the classic path, zero vault reloads), journal records-only +
    recover (cheap record flushes, verdict slot for the retry
    contract), append deterministic replay inputs to the group-inputs
    journal, ack fast. NO weight saves - those wait for group_report.
    Crash windows: the inputs journal + pre-group records rebuild the
    session exactly (see _rebuild_group_session); same-nonce resends
    replay nothing (session banked-set + stored resps, journal-backed
    across restarts)."""
    import brain_package as vault_pkg
    if _group_pinned["tournament_id"] not in ("", tid):
        _group_session_start(tid)
    elif _group_pinned["tournament_id"] == "":
        _group_session_start(tid)
    # Stale round after a banked group (same file, e.g. late retry):
    # the group verdict owns this file now - refuse loudly instead of
    # replaying onto banked state.
    stored_v = _read_last_verdict()
    if stored_v is not None \
            and stored_v.get("key", {}).get("tournament_id") == tid \
            and stored_v.get("result", {}).get("status") == "group_banked":
        print(f"[Server] Stale round {mlabel}-{round_id} for banked "
              f"group {tid}: refused.", flush=True)
        sock.sendto(json.dumps({"status": "error",
                                "error": "round_report: group already "
                                         "banked - QUIT TO MENU + RESUME"}
                               ).encode("utf-8"), client_addr)
        return
    # Empty session with journaled rounds = restart mid-group:
    # rebuild deterministically FIRST (it also restores exact-resend
    # coverage), so a stale retry arriving as the first post-restart
    # message resends stored instead of replaying.
    if not _group_pinned["brains"]:
        doc = _group_inputs_read()
        if doc is not None and doc.get("tournament_id", "") == tid:
            t_start = time.perf_counter()
            ctx0 = {"evo_mgr": evo_mgr, "dopamine_rl": dopamine_rl,
                    "base_lr": base_lr,
                    "tournament_lr_scale": tournament_lr_scale,
                    "tourney_note": tourney_note, "sock": sock,
                    "client_addr": client_addr, "round_id": round_id,
                    "echoes": [], "final_records": [],
                    "final_weights": {},
                    "csr": csr, "pops": pops,
                    "struct_cache": struct_cache,
                    "codec_cache": codec_cache}
            if _rebuild_group_session(ctx0):
                print(f"[Server] Rebuilt group session {tid} from "
                      f"journal in {time.perf_counter() - t_start:.1f}s.",
                      flush=True)
    banked = _group_pinned.get("round_resps", {})
    if round_id in banked:
        print(f"[Server] Duplicate group round {mlabel}-{round_id}: "
              f"resending stored result, no re-bank.", flush=True)
        try:
            sock.sendto(json.dumps(banked[round_id]).encode("utf-8"),
                        client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return
    t_start = time.perf_counter()
    echoes = []
    final_records = []
    final_weights = {}
    ctx = {"evo_mgr": evo_mgr, "dopamine_rl": dopamine_rl,
           "base_lr": base_lr, "tournament_lr_scale": tournament_lr_scale,
           "tourney_note": tourney_note, "sock": sock,
           "client_addr": client_addr, "round_id": round_id,
           "echoes": echoes, "final_records": final_records,
           "final_weights": final_weights, "csr": csr, "pops": pops,
           "struct_cache": struct_cache, "codec_cache": codec_cache}
    for mi, m in enumerate(matches):
        if not isinstance(m, dict):
            continue
        try:
            _replay_round_match(mi, m, ctx, _group_resolve)
        except _ResolveError as e:
            sock.sendto(json.dumps({"status": "error", "error": e.error}
                                   ).encode("utf-8"), client_addr)
            return
    print(f"[Server] Group round banked (pinned, no save) "
          f"{mlabel}-{round_id} ({tourney_note()}): {len(echoes)} "
          f"matches, dopamine+records "
          f"{time.perf_counter() - t_start:.1f}s.", flush=True)
    resp = {
        "status": "round_banked",
        "battle_id": round_id,
        "tournament_id": tid,
        "match": mlabel,
        "matches": echoes,
        "report": (f"round banked: {len(echoes)} matches"),
    }
    _t_journal = time.perf_counter()
    _emit_progress(sock, client_addr, round_id, "journal")
    _write_pending_battle(round_key, resp, final_records, {})
    _t_recover = time.perf_counter()
    _emit_progress(sock, client_addr, round_id, "recover")
    pinned_states = [{"rec": ent["rec"], "brain": ent["brain"]}
                     for ent in _group_pinned["brains"].values()]
    _recover_pending_battle(pinned_states)
    banked[round_id] = resp
    _group_pinned["round_resps"] = banked
    # Append deterministic replay inputs (full battle payloads) +
    # pre-group record bases for any fighter pinned this round.
    doc = _group_inputs_read()
    if doc is None or doc.get("tournament_id", "") != tid:
        doc = {"tournament_id": tid, "pregroup": {}, "rounds": []}
    for bid, ent in _group_pinned["brains"].items():
        if bid not in doc["pregroup"]:
            doc["pregroup"][bid] = deepcopy(ent["pregroup"])
    doc["rounds"].append({"nonce": round_id, "resp": resp,
                          "matches": matches})
    _group_inputs_write(doc)
    print(f"[Server] group round {round_id}: journal "
          f"{_t_recover - _t_journal:.1f}s + recover "
          f"{time.perf_counter() - _t_recover:.1f}s (no weight save).",
          flush=True)
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        print(f"[Server] send round_banked failed "
              f"(kept verdict): {e}", flush=True)


def _handle_warm_wirings(sock, client_addr, msg, csr, pops,
                         struct_cache, codec_cache):
    """Bind-only pre-warm for a roster: meta first (skip cached
    wirings), full load+bind only for novel ones, objects discarded.
    No slot, no retention, no watch - the client fires it under
    intermissions so compiles don't land post-ack. Bad files skip
    loudly (they refuse at load time anyway). Returns (warmed,
    skipped)."""
    import brain_package as vault_pkg
    warmed = 0
    skipped = 0
    wpaths = msg.get("paths", []) or []
    for _wi, _wp in enumerate(wpaths):
        try:
            _wrec = vault_pkg.load_brain_record(str(_wp))
        except Exception:
            continue
        if not isinstance(_wrec, dict):
            continue
        try:
            _sk, _ck = _wiring_cache_keys(_wrec)
        except Exception:
            continue
        if _sk in struct_cache and _ck in codec_cache:
            skipped += 1
            continue
        try:
            _rec_w, _w = vault_pkg.load_brain(str(_wp))
            _bind_brain(_rec_w, _w, csr, pops, struct_cache)
            _bind_codecs(_rec_w, pops, codec_cache)
            warmed += 1
            _emit_progress(sock, client_addr, "warm",
                           "fighter %d/%d" % (_wi + 1, len(wpaths)))
        except Exception as e:
            print(f"[Server] warm failed for {_wp}: {e}", flush=True)
    print(f"[Server] Wirings warm: {warmed} bound, "
          f"{skipped} cached.", flush=True)
    try:
        sock.sendto(json.dumps({"status": "wirings_warm",
                                "warmed": warmed,
                                "skipped": skipped}).encode("utf-8"),
                    client_addr)
    except OSError as e:
        print(f"[Server] warm reply failed: {e}", flush=True)
    return warmed, skipped


def _handle_group_report(sock, client_addr, msg, tourney_a, tourney_b,
                         tourney_tag, tournament_lr_scale, evo_mgr,
                         dopamine_rl, base_lr, tourney_note,
                         csr, pops, struct_cache, codec_cache):
    """ONE bank per group: seal the group verdict, save each pinned
    brain exactly once (weights land here and only here), flush
    records, remove the inputs journal, unpin. Same nonce/verdict
    contract as every other bank (exact resend, quarantine on torn
    journal). Crash mid-saves accepts the same window as round
    banking (records+verdict exact, weights best-effort across the
    sequential saves). A group verdict already banked for this file
    resends stored (never replays)."""
    import brain_package as vault_pkg
    group_id = str(msg.get("group_nonce", ""))
    tid = str(msg.get("tournament_id", "")
              or tourney_tag.get("tournament_id") or "")
    if not group_id:
        sock.sendto(json.dumps({"status": "error",
                                "error": "group_report: no group_nonce"}
                               ).encode("utf-8"), client_addr)
        return
    group_key = {"tournament_id": tid, "match": "group",
                 "battle_id": group_id}
    stored = _read_last_verdict()
    if stored is not None and stored.get("key") == group_key:
        print(f"[Server] Duplicate group report {tid}-{group_id}: "
              f"resending stored result, no re-bank.", flush=True)
        try:
            sock.sendto(json.dumps(stored["result"]).encode("utf-8"),
                        client_addr)
        except OSError as e:
            print(f"[Server] resend failed: {e}", flush=True)
        return
    t_start = time.perf_counter()
    # Session gone (e.g. retry after a restart): rebuild from the
    # inputs journal when one exists for this file, then seal
    # normally. Truly nothing to bank (no journal) refuses loudly.
    if _group_pinned["tournament_id"] != tid \
            or not _group_pinned["brains"]:
        _group_session_start(tid)
        doc = _group_inputs_read()
        if doc is None or doc.get("tournament_id", "") != tid:
            print(f"[Server] ERROR: group_report {tid}-{group_id} with no "
                  f"pinned session. Refused.", flush=True)
            sock.sendto(json.dumps({"status": "error",
                                    "error": "group_report: no pinned group "
                                             "session - QUIT TO MENU + RESUME"}
                                   ).encode("utf-8"), client_addr)
            return
        ctx0 = {"evo_mgr": evo_mgr, "dopamine_rl": dopamine_rl,
                "base_lr": base_lr,
                "tournament_lr_scale": tournament_lr_scale,
                "tourney_note": tourney_note, "sock": sock,
                "client_addr": client_addr, "round_id": group_id,
                "echoes": [], "final_records": [],
                "final_weights": {},
                "csr": csr, "pops": pops,
                "struct_cache": struct_cache,
                "codec_cache": codec_cache}
        if not _rebuild_group_session(ctx0):
            print(f"[Server] ERROR: group_report {tid}-{group_id}: "
                  f"rebuild failed. Refused.", flush=True)
            sock.sendto(json.dumps({"status": "error",
                                    "error": "group_report: rebuild failed "
                                             "- QUIT TO MENU + RESUME"}
                                   ).encode("utf-8"), client_addr)
            return
    final_records = []
    final_weights = {}
    for bid, ent in _group_pinned["brains"].items():
        final_records.append({"side": "pinned", "record": ent["rec"],
                              "weights_unchanged": True})
        final_weights[bid] = ent["brain"].weights
    print(f"[Server] Group report sealing {tid}-{group_id}: "
          f"{len(final_records)} fighters banked.", flush=True)
    resp = {
        "status": "group_banked",
        "battle_id": group_id,
        "tournament_id": tid,
        "match": "group",
        "fighters": len(final_records),
        "report": (f"group banked: {len(final_records)} fighters"),
    }
    _write_pending_battle(group_key, resp, final_records, {})
    _t_save = time.perf_counter()
    for entry in final_records:
        rec = entry["record"]
        bid = str(rec.get("id", ""))
        if bid in final_weights:
            _emit_progress(sock, client_addr, group_id, "save %s" % bid[:8])
            vault_pkg.save_brain(rec, final_weights[bid],
                                 backup=False, fast=False)
            del final_weights[bid]
    pinned_states = [{"rec": ent["rec"], "brain": ent["brain"]}
                     for ent in _group_pinned["brains"].values()]
    _recover_pending_battle(pinned_states)
    _group_session_end("group %s banked" % group_id)
    print(f"[Server] group {group_id}: sealed in "
          f"{time.perf_counter() - t_start:.1f}s.", flush=True)
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        print(f"[Server] send group_banked failed "
              f"(kept verdict): {e}", flush=True)


def _norm_experiment(value):
    """Canonical wiring key: None for base, else a sorted tuple of names
    (additive mixes; see experimental_wiring.normalize_experiment)."""
    return normalize_experiment(value)


def _wiring_cache_keys(rec):
    """(struct_key, codec_key) for a record from META ONLY (no weights).
    Same keys _bind_brain/_bind_codecs insert: a fighter warm-then-bound
    must agree with a fighter bound directly (a test locks the
    agreement). Raises ValueError on bad wiring, like the binds."""
    from sensory_motor import BLEND_DEFAULTS
    gp = rec.get("generator_params", {}) or {}
    genome = gp.get("genome", None)
    if genome is not None:
        skey = "genome:" + genome_label(genome)
    else:
        skey = _norm_experiment(gp.get("experiment", None))
    m = normalize_mapping(gp.get("mapping", None))
    yb = normalize_yaw_bias(gp.get("yaw_bias", None))
    legacy = is_legacy_record(rec)
    blends = {}
    for _bk, _bd in BLEND_DEFAULTS.items():
        try:
            blends[_bk] = max(0.0, min(1.0, float(gp.get(_bk, _bd))))
        except (TypeError, ValueError):
            blends[_bk] = _bd
    return skey, (m, legacy, yb, tuple(sorted(blends.items())))


def _bind_brain(rec, weights, csr, pops, struct_cache):
    """Builds a FlyBrain on the wiring its record declares (genome, base,
    or experimental overlay), validating the file's arity. Genome wins
    when a record carries both. Raises ValueError on unknown wirings or
    corrupt/mislabeled files."""
    gp = rec.get("generator_params", {}) or {}
    genome = gp.get("genome", None)
    if genome is not None:
        try:
            glabel = genome_label(genome)
        except ValueError as e:
            raise ValueError(
                f"brain '{rec.get('name')}' declares a bad genome: {e}")
        key = "genome:" + glabel
        if key not in struct_cache:
            indptr, indices, _data = build_genome_arrays(genome, csr, pops)
            struct_cache[key] = (indptr, indices)
            print(f"[Server] Cached {len(indices):,} synapse wiring for "
                  f"genome={glabel}")
        label = "genome " + glabel
    else:
        exp = _norm_experiment(gp.get("experiment", None))
        key = exp
        if exp not in struct_cache:
            indptr, indices, _data = experiment_arrays(exp, csr, pops)
            struct_cache[exp] = (indptr, indices)
            print(f"[Server] Cached {len(indices):,} synapse wiring for "
                  f"experiment={mix_label(exp)}")
        label = mix_label(exp)
    indptr, indices = struct_cache[key]
    if len(weights) != len(indices):
        raise ValueError(
            f"brain '{rec.get('name')}' declares wiring '{label}' "
            f"but carries arity {len(weights)} != {len(indices)}; "
            f"file corrupt or mislabeled")
    # Degenerate weights: an all-zero or non-finite vector passes arity
    # and loads "successfully" - then nothing propagates (NaN defeats
    # every comparison) and the round runs as a reflex zombie with zero
    # brain activity. Refuse loudly instead of announcing a bad load.
    w = np.asarray(weights, dtype=np.float32)
    if not np.isfinite(w).all():
        raise ValueError(
            f"brain '{rec.get('name')}' weights contain non-finite values; "
            f"file corrupt")
    if not np.any(w):
        raise ValueError(
            f"brain '{rec.get('name')}' weights are all zero; file corrupt")
    # Neuron model: "lif" (default, legacy kernel, bit-identical) or
    # "adaptive" (threshold-adapting kernel). Unknown names refuse
    # loudly - a mislabeled model must never silently run legacy.
    model = str(gp.get("neuron_model", "lif"))
    if model not in ("lif", "adaptive"):
        raise ValueError(
            f"brain '{rec.get('name')}' declares unknown neuron model "
            f"'{model}'; file corrupt or mislabeled")
    return FlyBrain(indptr, indices, np.ascontiguousarray(weights, dtype=np.float32).copy(),
                    model=model)


def _bind_codecs(rec, pops, codec_cache):
    """Returns (encoder, decoder) for the neuro-mapping a record declares.

    Mirrors _bind_brain: each fighter runs the sensorimotor schemes its
    record declares (base when the record predates mappings; stacks like
    ("gyro_flow", "muscles_up") share one cached codec pair), so mixed
    bouts (e.g. muscles_up vs base) each decode natively. Records that
    predate the mapping key entirely run the legacy regime (fused loom
    channel, legacy decoder operating point). Raises ValueError on
    unknown mapping names.
    """
    try:
        m = normalize_mapping((rec.get("generator_params", {}) or {}).get("mapping", None))
    except ValueError:
        raise ValueError(
            f"brain '{rec.get('name')}' declares unknown neuro-mapping "
            f"'{(rec.get('generator_params', {}) or {}).get('mapping', None)}'")
    try:
        yb = normalize_yaw_bias((rec.get("generator_params", {}) or {}).get("yaw_bias", None))
    except ValueError:
        raise ValueError(
            f"brain '{rec.get('name')}' declares bad yaw_bias "
            f"'{(rec.get('generator_params', {}) or {}).get('yaw_bias', None)}'")
    legacy = is_legacy_record(rec)
    from sensory_motor import BLEND_DEFAULTS
    gp = rec.get("generator_params", {}) or {}
    blends = {}
    for _bk, _bd in BLEND_DEFAULTS.items():
        try:
            blends[_bk] = max(0.0, min(1.0, float(gp.get(_bk, _bd))))
        except (TypeError, ValueError):
            blends[_bk] = _bd
    key = (m, legacy, yb, tuple(sorted(blends.items())))
    if key not in codec_cache:
        codec_cache[key] = (SensoryEncoder(pops, mapping=m, legacy=legacy),
                            MotorDecoder(pops, mapping=m, legacy=legacy,
                                         yaw_bias=yb, blends=blends))
        print(f"[Server] Cached {m} sensorimotor codecs (legacy={legacy}, yaw_bias={yb}, blends={blends})")
    return codec_cache[key]


PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Test isolation: FLY_TOURNAMENTS_DIR redirects journals/verdicts (the
# protocol test suite runs its own server so headless suites can never
# touch the live tournament state). Production never sets it.
TOURNAMENTS_DIR = os.environ.get("FLY_TOURNAMENTS_DIR") or os.path.join(
    PROJECT_ROOT, "tournaments")


def _last_verdict_path():
    return os.path.join(TOURNAMENTS_DIR, "_last_battle_verdict.json")


def _read_last_verdict():
    """Returns the persisted {key, result} of the last banked tournament
    battle, or None. Survives server restarts (QUIT/RELAUNCH between the
    bank and the arena's retry), so a resent battle can be answered from
    the stored verdict instead of being banked twice."""
    try:
        with open(_last_verdict_path()) as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("key"), dict) \
                and isinstance(d.get("result"), dict):
            return d
    except (OSError, ValueError):
        pass
    return None


def _write_last_verdict(key, result):
    os.makedirs(os.path.dirname(_last_verdict_path()), exist_ok=True)
    tmp = _last_verdict_path() + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"key": key, "result": result}, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, _last_verdict_path())


def _match_verdict_path(match_id):
    # Per-match verdict sidecar: the single-slot last-verdict only
    # covers the latest bank, but match resends can land after later
    # matches banked (lost ack + next match already through). The
    # nonce alphabet (hex tid, R#label) sanitizes injectively, so the
    # filename names its match. Never cleaned: they ARE the dedup
    # history (~300 bytes per match).
    safe = "".join(c if c.isalnum() else "_" for c in str(match_id))
    return os.path.join(TOURNAMENTS_DIR, "match_verdict_%s.json" % safe)


def _read_match_verdict(match_key):
    """Stored {key, result} for one banked match nonce, or None."""
    try:
        with open(_match_verdict_path(match_key.get("battle_id", ""))) as f:
            d = json.load(f)
        if isinstance(d, dict) and d.get("key", None) == match_key \
                and isinstance(d.get("result"), dict):
            return d
    except (OSError, ValueError):
        pass
    return None


def _write_match_verdict(match_key, result):
    os.makedirs(os.path.dirname(
        _match_verdict_path(match_key.get("battle_id", ""))), exist_ok=True)
    path = _match_verdict_path(match_key.get("battle_id", ""))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"key": match_key, "result": result}, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _report_base(battle_id):
    """Strips the arena's report nonce (R1M1-B7-<msec>-<rand> -> R1M1-B7).
    Anything without a nonce tail passes through untouched."""
    bid = str(battle_id or "")
    if "-B" not in bid:
        return bid
    head, _, tail = bid.rpartition("-B")
    parts = tail.split("-")
    if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
        return "%s-B%s" % (head, parts[0])
    return bid


def _same_battle_slot(stored_key, battle_key):
    """True when a report names the same battle slot as the stored verdict
    (same tournament file, match, base id, draw flag) under a fresh nonce:
    a QUIT+RESUME replay of a banked-but-unconfirmed battle. Genuinely new
    battles always differ in base id, cross-group battles in tournament_id."""
    if not isinstance(stored_key, dict) or not isinstance(battle_key, dict):
        return False
    for f in ("tournament_id", "match", "draw"):
        if stored_key.get(f) != battle_key.get(f):
            return False
    return _report_base(stored_key.get("battle_id")) == \
        _report_base(battle_key.get("battle_id"))


def _prepared_slot_matches(prepare_a, prepare_b, prepare_tag, msg):
    """True when the prepare slot holds THIS match (same tournament,
    match label, both paths): activation swaps it in O(1) instead of
    the full disk load. A server restart empties the slot - the
    official path stays the fallback. Vault mtimes version the slot:
    a bank that landed after the prepare falls through to a fresh
    load instead of fighting on stale weights. Pure (unit-tested)."""
    if not (prepare_a.get("brain") is not None
            and prepare_tag.get("tournament_id") == str(msg.get("tournament_id", ""))
            and prepare_tag.get("match") == str(msg.get("match", ""))
            and prepare_a.get("path") == str(msg.get("alpha_path", ""))
            and prepare_b.get("path") == str(msg.get("beta_path", ""))):
        return False
    for _slot, _field in ((prepare_a, "alpha_path"),
                          (prepare_b, "beta_path")):
        _cur = _vault_mtime(msg.get(_field, ""))
        if _cur is None or _slot.get("mtime", None) != _cur:
            return False
    return True


def _vault_mtime(path):
    """Vault file mtime or None (missing/unreadable): the prepare-slot
    version stamp. Pure (unit-tested)."""
    try:
        return os.path.getmtime(str(path))
    except OSError:
        return None


# Pinned group session (group-bank mode): brains stay bound in RAM for
# the whole group - no vault reloads between rounds, no weight saves
# until the group bank. RAM-only: crash recovery rebuilds it from the
# group-inputs journal (pre-group records + deterministic replay), so
# this dict is NEVER the durability story. Keyed by tournament file;
# a new file abandons the old session (logged).
_group_pinned = {"tournament_id": "", "brains": {}}

# Oversized-group tripwire: 8 pinned fighters x ~100 MB is fine; beyond
# this the session refuses to pin (loud error, arena falls back to
# per-round banking) instead of eating unbounded RAM.
GROUP_PIN_MAX = 8


def _pending_group_path():
    return os.path.join(TOURNAMENTS_DIR, "_pending_group.json")


def _group_session_start(tid):
    """(Re)starts the pinned session for a tournament file, abandoning
    any unbanked predecessor loudly (its battle records already
    flushed per round; only its unbanked weight deltas are lost -
    same exposure as a quit-flushed partial round)."""
    if _group_pinned["tournament_id"] not in ("", tid) \
            and _group_inputs_read() is not None:
        print(f"[Server] Group session { _group_pinned['tournament_id']} "
              f"abandoned with unbanked rounds for {tid}.", flush=True)
    _group_pinned.clear()
    _group_pinned.update({"tournament_id": tid, "brains": {}})


def _group_session_end(reason):
    if _group_pinned["tournament_id"] == "" \
            and not _group_pinned["brains"]:
        return
    _group_pinned.clear()
    _group_pinned.update({"tournament_id": "", "brains": {}})
    try:
        p = _pending_group_path()
        if os.path.exists(p):
            os.remove(p)
    except OSError:
        pass
    print(f"[Server] Group session ended ({reason}).", flush=True)


def _group_inputs_write(doc):
    """Atomically replaces the group-inputs journal: pre-group records
    + every banked round's full battle payloads (deterministic replay
    inputs) and ack responses (exact resends). Small (KBs per round)."""
    import brain_package as _vp
    path = _pending_group_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _group_inputs_read():
    try:
        with open(_pending_group_path()) as f:
            d = json.load(f)
        if isinstance(d, dict) and isinstance(d.get("rounds"), list):
            return d
    except (OSError, ValueError):
        pass
    return None


def _reset_needs_brains(msg, tournament_mode, rec_a, rec_b):
    """True when a tournament-shaped reset would run on NO brains (the
    server restarted, or free_mode mid-event): the handler must fail
    loud instead of answering match_ready off boot brains - that
    silent path was a zero-activity round. Pure (unit-tested)."""
    if not str(msg.get("match", "")):
        return False
    return not tournament_mode or rec_a is None or rec_b is None


# Stable contract: the arena matches this prefix to trigger its
# mid-match auto-reload (see ArenaManager._on_server_error). Rewording
# the head breaks tournament self-healing - pinned by test.
MATCH_RESET_NO_BRAINS_ERROR = ("match_reset: no tournament brains loaded "
                               "(server restarted?) - QUIT TO MENU + RESUME")


def _emit_progress(sock, client_addr, battle_id, stage):
    """Proof-of-life while a battle banks: the arena extends its confirm
    deadline on each heartbeat instead of firing a duplicate report that
    doubles this work. Best-effort (never breaks banking)."""
    try:
        sock.sendto(json.dumps({"status": "battle_progress",
                                "battle_id": battle_id,
                                "stage": stage}).encode("utf-8"), client_addr)
    except OSError:
        pass


def _pending_battle_path():
    return os.path.join(TOURNAMENTS_DIR, "_pending_battle.npz")


def _write_pending_battle(key, result, records, weights):
    path = _pending_battle_path()
    if os.path.exists(path):
        raise RuntimeError("An unfinished battle must be recovered first")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    try:
        with open(tmp, "wb") as f:
            np.savez(f, metadata=json.dumps(
                {"key": key, "result": result, "records": records}), **weights)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def _recover_pending_battle(states=()):
    import brain_package as vault_pkg
    path = _pending_battle_path()
    if not os.path.exists(path):
        return
    # Phase 1: load + validate the journal. A file that fails here is
    # undecodable (torn write, bitrot) and can never be replayed, so
    # quarantine it loudly instead of crash-looping on every boot/message.
    try:
        with np.load(path, allow_pickle=False) as pending:
            transaction = json.loads(str(pending["metadata"].item()))
            if not isinstance(transaction, dict) \
                    or not isinstance(transaction.get("records"), list) \
                    or not isinstance(transaction.get("result"), dict):
                raise ValueError("pending battle journal has bad shape")
            payload = {}
            for entry in transaction["records"]:
                if not isinstance(entry, dict) \
                        or entry.get("side") not in ("alpha", "beta",
                                                     "pinned") \
                        or not isinstance(entry.get("record"), dict):
                    raise ValueError("pending battle journal has bad entry")
                if entry.get("weights_unchanged"):
                    if not os.path.isfile(vault_pkg.package_path(
                            entry["record"].get("filename", ""))):
                        # Records-only entries replay via the package
                        # sidecar, so a missing package can never complete:
                        # quarantine like a torn write instead of failing
                        # every message with battle recovery errors.
                        # (Weight-bearing entries restore FROM the journal
                        # when packages were wiped - the crash case.)
                        raise ValueError(
                            "records-only journal references missing "
                            "package " + str(entry["record"].get("filename", "")))
                    continue
                if entry["side"] not in pending:
                    raise ValueError("pending battle journal has bad entry")
                payload[entry["side"]] = np.array(pending[entry["side"]])
    except Exception as e:
        bad = path + ".corrupt-%d" % int(time.time())
        try:
            os.replace(path, bad)
        except OSError:
            pass
        # Auto-reconcile: a torn journal can never replay, and failing
        # every message on it wedges the server (retries, loads, resets
        # all take the recovery error path). The un-replayed bumps are
        # lost, but the arena's in-flight retry re-banks the battle fresh
        # on the same idempotency key, so serving continues exactly-once.
        print(f"[Server] QUARANTINED unreadable pending battle journal -> "
              f"{bad} ({e}). Its record bumps were NOT replayed; the next "
              f"report for that battle re-banks them. Serving continues.",
              flush=True)
        return
    # Phase 2: replay. Failures here (vault/verdict IO) leave the journal
    # in place so the next message or boot retries the SAME record bumps.
    for entry in transaction["records"]:
        rec = entry["record"]
        if entry.get("weights_unchanged"):
            vault_pkg.save_brain_record_only(rec)
        else:
            weights = payload[entry["side"]]
            vault_pkg.save_brain(rec, weights, backup=False, fast=False)
        for st in states:
            if st["rec"] is not None and st["rec"]["filename"] == rec["filename"]:
                st["rec"] = deepcopy(rec)
                # Marked sides are weight-identical: only the record
                # needs syncing, in-memory weights are already current.
                if not entry.get("weights_unchanged"):
                    st["brain"].weights = weights.copy()
    # Only keyed battles participate in retry idempotency. An
    # unkeyed journal must still replay its vault saves, but writing
    # a key=None verdict here would clobber the previous battle's
    # real verdict and reopen it to double-banking.
    if transaction.get("key") is not None:
        _write_last_verdict(transaction["key"], transaction["result"])
    # A concurrent recover (live server vs test debris in a shared dir)
    # may have replayed + removed this journal first - then the work is
    # done and there is nothing to remove. A *different* journal cannot
    # appear here: a new write is refused while one exists, so absence
    # always means already-recovered, never lost.
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _apply_round_learning(dopamine_rl, brain_alpha, brain_beta, winner,
                          sens_a, sens_b, ctrl_a, ctrl_b, pulse,
                          schemes_a, schemes_b, legacy_a, legacy_b,
                          arena_draw=False):
    """Post-battle dopamine + gain pinning. Arena-declared draws skip the
    whole block: no plasticity for either side and no gain pinning, so a
    draw leaves learned weights byte-identical while only the vault
    draw counters advance."""
    if arena_draw:
        return
    # Per-battle depression budgets (single pulses are too small to bind
    # at 0.7x vs a 0.5 budget, but the books stay balanced if caps ever
    # grow — and mixed-arity bouts must never share one budget).
    dopamine_rl.begin_episode(brain_alpha)
    dopamine_rl.begin_episode(brain_beta)
    if winner == "alpha":
        dopamine_rl.apply_plasticity(brain_alpha, sens_a, ctrl_a, pulse, schemes_a)
        dopamine_rl.apply_plasticity(brain_beta, sens_b, ctrl_b, -0.8 * pulse, schemes_b)
    else:
        dopamine_rl.apply_plasticity(brain_beta, sens_b, ctrl_b, pulse, schemes_b)
        dopamine_rl.apply_plasticity(brain_alpha, sens_a, ctrl_a, -0.8 * pulse, schemes_a)
    dopamine_rl.pin_gains(brain_alpha, legacy=legacy_a)
    dopamine_rl.pin_gains(brain_beta, legacy=legacy_b)


def _sanitize_fit(x):
    """Guards the arena's JSON parser: NaN/Inf fitness would serialize as
    NaN/Infinity (invalid JSON), Godot drops the packet, and the battle
    wedges at REPORTING with no error on either side."""
    try:
        f = float(x)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if f != f or f in (float("inf"), float("-inf")) else f


def run_brain_server(host="127.0.0.1", port=9999):
    print("=" * 60)
    print("   BATTLE FLY ARENA - DUAL CONNECTOME NEURO-SERVER")
    print("=" * 60)
    # Crash forensics: a hard native crash (segfault in compiled
    # kernels, not a Python exception) leaves no traceback - and the
    # log just stops mid-bank. faulthandler dumps the Python stack to
    # a sidecar file on fatal signals (OOM-kill is uncatchable by
    # anything; an absent sidecar + stopped log still says a lot).
    try:
        import faulthandler
        global _fault_handler_file
        _fault_handler_file = open(
            os.path.join(TOURNAMENTS_DIR, "faulthandler_crash.log"), "ab")
        faulthandler.enable(file=_fault_handler_file)
    except Exception as e:
        print(f"[Server] faulthandler unavailable: {e}", flush=True)

    try:
        _recover_pending_battle()
    except Exception as e:
        # Journal-quarantine already logged loudly inside; transient IO
        # here only delays vault writes until the next message's recovery.
        print(f"[Server] Boot battle recovery deferred: {e}", flush=True)

    # 1. Load connectome & populations
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    # One-time ELO migration for pre-rating vault brains (1200 + 25x
    # W/L); stamped brains are never touched again.
    import brain_package as _vault_boot
    _stamped = _vault_boot.backfill_elo()
    if _stamped:
        print(f"[Server] Backfilled ELO on {_stamped} vault brain(s).")
    # Named-pool index for the brain-view stream (built once; detail
    # level arrives per step message from the arena menu setting).
    pool_idx = _pool_index(pops)

    # Experimental wiring (env EXPERIMENT=lplc2_contra_dn, or additive
    # mixes like retina_wide+spear_lunge / comma-separated): injected edges
    # change the brain's arity, so experiment flags load experiment-named
    # checkpoints and NEVER mix base-arity weight arrays into experiment brains.
    experiment = os.environ.get("EXPERIMENT") or None
    wire_boot = mix_label(experiment)
    suffix = experiment_suffix(experiment)
    indptr, indices, wbase = experiment_arrays(experiment, csr, pops)

    # 2. Instantiate Fly Alpha (charger variant A) and Fly Beta (flanker
    # variant B) so the two rivals behave differently from the first round.
    checkpoints_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "checkpoints")
    weights_a, file_a = _load_variant_weights(
        checkpoints_dir, [f"trained_homing_A{suffix}.npz", f"trained_homing_champion{suffix}.npz"], wbase)
    weights_b, file_b = _load_variant_weights(
        checkpoints_dir, [f"trained_homing_B{suffix}.npz", f"trained_homing_champion{suffix}.npz"], wbase)
    weights_a = np.ascontiguousarray(weights_a.copy())
    weights_b = np.ascontiguousarray(weights_b.copy())
    if len(weights_a) != len(wbase):
        raise ValueError(
            f"Checkpoint {file_a} has wrong arity ({len(weights_a)} != {len(wbase)}); "
            "experimental brains need experiment-named checkpoints.")
    if len(weights_b) != len(wbase):
        raise ValueError(
            f"Checkpoint {file_b} has wrong arity ({len(weights_b)} != {len(wbase)}); "
            "experimental brains need experiment-named checkpoints.")
    print(f"[Server] Alpha <- {file_a or 'fresh injected base'}, "
          f"Beta <- {file_b or 'fresh injected base'}, experiment={mix_label(experiment)}")

    print("[Server] Loading dual independent connectomes into RAM...")
    brain_alpha = FlyBrain(indptr, indices, weights_a.copy())
    brain_beta = FlyBrain(indptr, indices, weights_b.copy())
    # JIT warmup: the numba LIF kernel compiles on first integrate (~3 s
    # for both brains). Do it here at boot, not on the first fight step,
    # or the opening seconds of battle one run on a frozen brain.
    _warm = np.zeros(1, dtype=np.int32)
    brain_alpha.integrate_50ms(_warm)
    brain_beta.integrate_50ms(_warm)
    brain_alpha.reset_state()
    brain_beta.reset_state()
    print("[Server] LIF kernel compiled and ready.")
    # Pristine boot state: free_mode rebuilds these when leaving a
    # tournament/quick battle so classic evolution always starts clean
    # (full objects, not just weights: a tournament brain may carry a
    # different wiring, and weights alone would corrupt the shape).
    boot_struct = (indptr, indices)
    boot_weights_a = weights_a.copy()
    boot_weights_b = weights_b.copy()
    # Per-wiring connectome structures. Tournament fighters each run on
    # their NATIVE wiring (base or any experimental overlay), so brains of
    # different arity can share a bracket. Weight vectors stay native
    # end-to-end; vault files never change shape.
    struct_cache = {_norm_experiment(experiment): (indptr, indices)}

    encoder = SensoryEncoder(pops)
    decoder = MotorDecoder(pops)
    # Per-mapping sensorimotor codecs (base pair above serves free battle,
    # which stays on the current stack; tournament fighters bind their own
    # at tournament_load via _bind_codecs, legacy ones included).
    codec_cache = {((), False, 9.0): (encoder, decoder)}
    # Thread-per-brain step workers (njit releases the GIL; per-side
    # work is a pure function of its inputs). FO_SERIAL=1 forces the
    # sequential path. One pool, two workers, owned by the loop.
    # atexit shutdown: worker threads are non-daemon and would wedge
    # interpreter exit (Ctrl+C hang) without it.
    if (os.environ.get("FO_SERIAL", "") == "1"):
        step_executor = None
        print("[Server] Step workers: serial (FO_SERIAL=1).")
    else:
        step_executor = ThreadPoolExecutor(max_workers=2,
                                           thread_name_prefix="side")
        atexit.register(step_executor.shutdown, False)
        print("[Server] Step workers: 2 threads (one per fighter).")
    # Reference wiring for pool-aware gain pinning (wbase of the boot
    # experiment; overlay edge counts shift pool means negligibly).
    dopamine_rl = DopamineReinforcement(
        pops, learning_rate=0.008,
        base=(csr.indptr, csr.indices, np.ascontiguousarray(wbase, dtype=np.float32)))
    evo_mgr = EvolutionManager(checkpoints_dir="checkpoints")
    merge_count = 0
    # Tournament mode: brains are managed .flybrain identities loaded per
    # match. Dopamine learning stays ON (scaled by tournament_lr_scale) but
    # clone/mutate evolution is OFF so identities survive the bracket.
    # Set via env TOURNAMENT_MODE=1 or the tournament_load message.
    tournament_mode = (os.environ.get("TOURNAMENT_MODE", "") == "1")
    tournament_lr_scale = float(os.environ.get("TOURNAMENT_LR_SCALE", "0.5"))
    base_lr = dopamine_rl.lr
    # Loaded managed identities: {"rec": brain.json dict, "path": vault path,
    # "brain": FlyBrain}. Updated + re-saved after every tournament battle.
    # "enc"/"dec" are the fighter's native neuro-mapping codecs (base pair
    # until tournament_load binds them).
    tourney_a = {"rec": None, "path": None, "brain": brain_alpha,
                 "enc": encoder, "dec": decoder}
    tourney_b = {"rec": None, "path": None, "brain": brain_beta,
                 "enc": encoder, "dec": decoder}
    tourney_tag = {"tournament_id": "", "match": ""}
    # Preload slot (tournament_prepare): the NEXT match's brains loaded
    # + bound while the current one plays or a countdown runs. Never
    # touches the live pair; tournament_load activates it in O(1) when
    # the paths match. Lost on server restart (the official load path
    # is the fallback).
    prepare_a = {"rec": None, "path": None, "brain": None,
                 "enc": None, "dec": None}
    prepare_b = {"rec": None, "path": None, "brain": None,
                 "enc": None, "dec": None}
    prepare_tag = {"tournament_id": "", "match": ""}
    # Last banked match verdict (tournament_id, match): duplicate
    # tournament_match messages must not double-bank counters or ELO.
    _last_match_banked = {"key": None}

    def tourney_note():
        tid = tourney_tag.get("tournament_id") or "?"
        m = tourney_tag.get("match") or "?"
        return f"tourney {tid} match {m}"
    # Last-step sensorimotor context for post-battle dopamine updates.
    last_sens_a, last_sens_b = {}, {}
    last_ctrl_a = {"yaw_torque": 0.0, "thrust": 0.2}
    last_ctrl_b = {"yaw_torque": 0.0, "thrust": 0.2}

    # Key sensorimotor pathways for evolution mutations (free battle).
    # Extended with the gyro pools so new input channels evolve too.
    target_pathways = (
        pops["pheromone_da1"]["all"]
        + pops["pheromone_va1v"]["all"]
        + pops["visual_lc10"]["all"]
        + pops["visual_lc4"]["all"]
        + pops["visual_lplc2"]["all"]
        + pops.get("gyro_jo", {}).get("all", [])
    )

    # 3. Setup UDP Server Socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
    sock.bind((host, port))
    print(f"[Server] UDP Listening on {host}:{port}. Waiting for Godot 4 Arena...")
    print("[Server] Step budget: dual-brain LIF costs ~3-4x the 20 Hz tick "
          "on this hardware, so step bursts collapse to newest (stale "
          "controls fly drunk); control messages are never dropped.")

    def _parse_step(data):
        # Single parse per packet (the old _is_step + re-parse decoded
        # every burst packet twice): (is_step, msg_or_None).
        try:
            m = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError, AttributeError):
            return False, None
        return m.get("type", "step") == "step", m

    stash = None  # one-slot buffer for a non-step found mid-drain
    step_dropped = 0
    step_count = 0
    step_ms = 0.0

    while True:
        try:
            if stash is not None:
                data, client_addr = stash
                stash = None
            else:
                data, client_addr = sock.recvfrom(65535)
            msg = json.loads(data.decode("utf-8"))
            msg_type = msg.get("type", "step")
            try:
                _recover_pending_battle((tourney_a, tourney_b))
            except Exception as e:
                sock.sendto(json.dumps(
                    {"status": "error", "error": f"battle recovery: {e}"}
                ).encode("utf-8"), client_addr)
                continue
            if msg_type == "step":
                # Collapse the burst: keep draining while steps arrive and
                # integrate only the newest. A non-step found mid-drain is
                # stashed for the next iteration (never lost, never late).
                # msg already holds the parsed newest packet; drained
                # packets carry their parse along (never decoded twice).
                sock.settimeout(0.0)
                try:
                    while True:
                        try:
                            d2, a2 = sock.recvfrom(65535)
                        except (BlockingIOError, socket.timeout):
                            break
                        is_st, m2 = _parse_step(d2)
                        if is_st:
                            data, client_addr, msg = d2, a2, m2
                            step_dropped += 1
                        else:
                            stash = (d2, a2)
                            break
                finally:
                    sock.settimeout(None)
                msg_type = msg.get("type", "step")
                step_count += 1
                _t_step = time.monotonic()

            if msg_type == "step":
                # Extract sensory state from Godot
                sens_a = msg.get("alpha", {})
                sens_b = msg.get("beta", {})
                # Client step sequence for staleness detection (0/absent
                # = untracked old client): echoed back in the reply stats
                # so the arena can drop widowed replies instead of
                # applying ancient commands.
                try:
                    step_echo = int(msg.get("step_seq", 0))
                except (TypeError, ValueError):
                    step_echo = 0

                # Per-side neuro-mapping codecs in tournament/quick mode;
                # the shared base pair in free battle (no records bound).
                enc_a = tourney_a["enc"] if tournament_mode and tourney_a["rec"] is not None else encoder
                dec_a = tourney_a["dec"] if tournament_mode and tourney_a["rec"] is not None else decoder
                enc_b = tourney_b["enc"] if tournament_mode and tourney_b["rec"] is not None else encoder
                dec_b = tourney_b["dec"] if tournament_mode and tourney_b["rec"] is not None else decoder

                try:
                    detail = int(msg.get("detail", 0))
                except (TypeError, ValueError):
                    detail = 0
                detail = max(0, min(detail, 2))

                # Dual-brain step. Encoding runs serially on the main
                # thread (Poisson sampler owns the shared global
                # RandomState); integrate->decode->stats runs threaded
                # across the two fighters (njit releases the GIL;
                # distinct brain objects, read-only decoders — thread
                # assignment cannot affect outputs). FO_SERIAL=1 forces
                # the legacy sequential path for debugging/comparison.
                stim_a = enc_a.encode(sens_a)
                stim_b = enc_b.encode(sens_b)
                if step_executor is None:
                    ctrl_a, stats_a, _, _ = _run_side_integrate(
                        dec_a, brain_alpha, stim_a, sens_a, pops,
                        pool_idx, detail)
                    ctrl_b, stats_b, _, _ = _run_side_integrate(
                        dec_b, brain_beta, stim_b, sens_b, pops,
                        pool_idx, detail)
                else:
                    fut_a = step_executor.submit(
                        _run_side_integrate, dec_a, brain_alpha,
                        stim_a, sens_a, pops, pool_idx, detail)
                    fut_b = step_executor.submit(
                        _run_side_integrate, dec_b, brain_beta,
                        stim_b, sens_b, pops, pool_idx, detail)
                    ctrl_a, stats_a, _, _ = fut_a.result()
                    ctrl_b, stats_b, _, _ = fut_b.result()
                last_sens_a, last_sens_b = sens_a, sens_b
                last_ctrl_a, last_ctrl_b = ctrl_a, ctrl_b
                # Wiring/mapping labels are bound once per fighter (see
                # tournament_load / boot); the hot loop only reads them.
                if tournament_mode:
                    wire_a = tourney_a.get("wiring", mix_label(experiment))
                    wire_b = tourney_b.get("wiring", mix_label(experiment))
                    map_a = tourney_a.get("mapping", [])
                    map_b = tourney_b.get("mapping", [])
                else:
                    wire_a = wire_b = wire_boot
                    map_a = map_b = []
                response = {
                    "status": "ok",
                    "alpha": ctrl_a,
                    "beta": ctrl_b,
                    "generation": evo_mgr.generation,
                    "stats": {
                        "alpha": stats_a,
                        "beta": stats_b,
                        "wiring": {"alpha": wire_a, "beta": wire_b},
                        "mapping": {"alpha": map_a, "beta": map_b},
                        # Lockstep proof for the arena HUD (see
                        # ArenaManager _update_ctrl_label): session-
                        # cumulative steps integrated. The arena
                        # displays n (pairs applied) vs srv (this
                        # number); srv - n == replies lost in flight.
                        # Never reset this counter mid-session or the
                        # HUD gap becomes meaningless.
                        "step_seq": step_count,
                        # Echo of the client's step_seq (0 when the
                        # client didn't tag): lets the arena drop a
                        # widowed reply to an older send.
                        "step_echo": step_echo,
                    },
                }
                try:
                    sock.sendto(json.dumps(response).encode("utf-8"), client_addr)
                except OSError as e:
                    # A reply to a client port that just rebound (watchdog
                    # reconnect) earns ICMP unreachable on Windows; the
                    # arena already moved on, so drop it quietly instead
                    # of tripping the outer handler.
                    print(f"[Server Error] step reply send failed: {e}", flush=True)
                step_ms += (time.monotonic() - _t_step) * 1000.0
                if step_count % 50 == 0:
                    print(f"[Server] step ~{step_ms / 50.0:.0f}ms "
                          f"(dropped {step_dropped} stale)", flush=True)
                    step_ms = 0.0

            elif msg_type == "raster_map":
                # Brain-view drill-down: id list for one pool so the
                # arena can render per-neuron rasters. Mode-independent,
                # read-only (never touches brains or weights).
                pool = str(msg.get("pool", ""))
                side = str(msg.get("side", ""))
                ids, total = _raster_ids(pool_idx, pool)
                sock.sendto(json.dumps({
                    "status": "raster_map",
                    "side": side,
                    "pool": pool,
                    "ids": ids,
                    "total": total,
                }).encode("utf-8"), client_addr)

            elif msg_type == "round_over":
                # Any failure here must still answer the arena: a silent drop
                # (no tournament_battle / generation_advanced reply) wedges
                # the game at a stale banner with live animations and no
                # error text. The inner except reports visibly instead.
                original_weights = None
                try:
                    stats_a = msg.get("stats_alpha", {})
                    stats_b = msg.get("stats_beta", {})
                    battle_id = str(msg.get("battle_id", ""))
                    t_round = time.perf_counter()
                    if battle_id and not tournament_mode:
                        # Tournament-shaped report with no tournament
                        # loaded (server restarted, or the arena sent
                        # free_mode mid-event): banking as free, but LOUD,
                        # so the arena log explains the desync instead of
                        # silently evolving boot brains. Arena heals via
                        # QUIT TO MENU + RESUME (re-sends tournament_load).
                        print(f"[Server] WARNING: tournament-shaped report "
                              f"{battle_id} while in FREE mode "
                              f"({tourney_note()}). Banking as free; arena "
                              f"should QUIT TO MENU + RESUME to reload.",
                              flush=True)
                    print(f"[Server] round_over received id={battle_id or '?'} "
                          f"({tourney_note()}) draw={bool(msg.get('arena_draw', False))} "
                          f"end={str(msg.get('end_reason', '') or '?')}",
                          flush=True)
                    if tournament_mode and battle_id:
                        # Idempotent retry: same (tournament, match, battle)
                        # already banked -> resend the stored verdict without
                        # touching dopamine, records, or vault weights.
                        battle_key = {
                            "tournament_id": str(msg.get("tournament_id")
                                                 or tourney_tag.get("tournament_id") or ""),
                            "match": str(msg.get("match")
                                         or tourney_tag.get("match") or ""),
                            "battle_id": battle_id,
                            "draw": bool(msg.get("arena_draw", False)),
                        }
                        stored = _read_last_verdict()
                        if stored is not None and stored.get("key") == battle_key:
                            print(f"[Server] Duplicate {battle_key['match']}-"
                                  f"{battle_id} ({battle_key['tournament_id']}): "
                                  f"resending stored verdict, no re-bank.",
                                  flush=True)
                            try:
                                sock.sendto(json.dumps(
                                    stored["result"]).encode("utf-8"), client_addr)
                            except OSError as e:
                                print(f"[Server] resend failed: {e}", flush=True)
                            continue
                        if stored is not None and _same_battle_slot(
                                stored.get("key"), battle_key):
                            print(f"[Server] Replay {battle_key['match']}-"
                                  f"{_report_base(battle_id)} "
                                  f"({battle_key['tournament_id']}) under a fresh "
                                  f"nonce: banked already, resending stored "
                                  f"verdict, no re-bank.", flush=True)
                            try:
                                sock.sendto(json.dumps(
                                    stored["result"]).encode("utf-8"), client_addr)
                            except OSError as e:
                                print(f"[Server] resend failed: {e}", flush=True)
                            continue
                    else:
                        battle_key = None
                    if tournament_mode:
                        # Genome novelty joins fitness: records bound, so
                        # rare wiring pools pay (frequency-dependent
                        # selection for exploration). Free battles pass no
                        # records and score exactly as before.
                        winner, fit_a, fit_b = evo_mgr.evaluate_match(
                            stats_a, stats_b,
                            rec_a=tourney_a.get("rec"),
                            rec_b=tourney_b.get("rec"))
                    else:
                        winner, fit_a, fit_b = evo_mgr.evaluate_match(
                            stats_a, stats_b)
                    # Dominance-scaled dopamine: a real kill rewrites the brain at
                    # full strength, a timeout-fitness win at half. Draws (no
                    # damage either side) carry no update.
                    ko_win = bool(stats_a.get("kills") or stats_b.get("kills"))
                    pulse = 1.0 if (ko_win or not tournament_mode) else 0.5
                    lr_scale = tournament_lr_scale if tournament_mode else 1.0
                    dopamine_rl.lr = base_lr * lr_scale
                    try:
                        # Per-side neuro-mapping schemes: new plasticity
                        # branches (JO roll, KC->MBON) run only for brains
                        # generated from those schemes; base brains keep
                        # byte-identical updates. Free battle has no
                        # records bound, so both sides run base ().
                        if tournament_mode:
                            schemes_a = normalize_mapping(
                                ((tourney_a["rec"] or {}).get("generator_params", {}) or {}).get("mapping", None))
                            schemes_b = normalize_mapping(
                                ((tourney_b["rec"] or {}).get("generator_params", {}) or {}).get("mapping", None))
                            # Pre-mapping brains (no mapping key) skip gain
                            # pinning: their regime never had it, so their
                            # learned magnitudes must not be re-normalized.
                            legacy_a = is_legacy_record(tourney_a["rec"])
                            legacy_b = is_legacy_record(tourney_b["rec"])
                        else:
                            schemes_a, schemes_b = (), ()
                            legacy_a, legacy_b = False, False
                        if tournament_mode:
                            original_weights = (brain_alpha.weights.copy(),
                                                brain_beta.weights.copy())
                        # Arena-declared draws carry no dopamine in any mode:
                        # evaluate_match still names a fitness "winner" on
                        # ties, and banking +pulse/-0.8*pulse on that basis
                        # would teach a win/loss split for a drawn fight.
                        if tournament_mode and battle_id:
                            _emit_progress(sock, client_addr, battle_id,
                                           "dopamine")
                        _apply_round_learning(
                            dopamine_rl, brain_alpha, brain_beta, winner,
                            last_sens_a, last_sens_b, last_ctrl_a, last_ctrl_b,
                            pulse, schemes_a, schemes_b, legacy_a, legacy_b,
                            arena_draw=bool(msg.get("arena_draw", False)))
                    finally:
                        dopamine_rl.lr = base_lr
                    print(f"[Server] battle {battle_id or '?'}: dopamine+pin "
                          f"{time.perf_counter() - t_round:.1f}s (vault save next)",
                          flush=True)
                    if tournament_mode:
                        _handle_tournament_round_over(
                            sock, client_addr, msg, winner, fit_a, fit_b,
                            tourney_a, tourney_b, tourney_tag,
                            tournament_lr_scale, pulse, tourney_note,
                            battle_id, battle_key)
                        continue
                    _handle_free_round_over(
                        sock, client_addr, msg, evo_mgr,
                        brain_alpha, brain_beta, winner, fit_a, fit_b,
                        battle_id, target_pathways)
                except Exception as e:
                    if original_weights is not None and not os.path.exists(_pending_battle_path()):
                        brain_alpha.weights, brain_beta.weights = original_weights
                    print(f"[Server Error] round_over failed: {e}")
                    try:
                        sock.sendto(json.dumps(
                            {"status": "error",
                             "error": f"round_over: {e}"}).encode("utf-8"), client_addr)
                    except Exception:
                        pass
                finally:
                    original_weights = None

            elif msg_type == "tournament_load":
                # Load two managed brains by weight array (base64-free: the
                # arena sends a vault path readable by the server process).
                import brain_package as vault_pkg
                t_load_start = time.perf_counter()
                load_dbg = "[%s %s]" % (str(msg.get("tournament_id", "?")),
                                        str(msg.get("match", "?")))
                tournament_mode = True
                if "lr_scale" in msg:
                    try:
                        tournament_lr_scale = float(msg["lr_scale"])
                    except (TypeError, ValueError):
                        pass
                # Preload activation: the prepare slot holding THIS match
                # (same tournament, match label, both paths) swaps in O(1)
                # - no disk, no re-binding. A miss (no prepare was sent, or
                # a server restart lost the slot) falls through to the
                # full disk load as before - the official path stays the
                # fallback.
                want_a = str(msg.get("alpha_path", ""))
                want_b = str(msg.get("beta_path", ""))
                # New tournament file abandons any pinned group session
                # (its rounds never banked as a group; per-round records
                # already flushed). The new file pins fresh on demand.
                load_tid = str(msg.get("tournament_id", "") or "")
                if load_tid != "" and _group_pinned["tournament_id"] \
                        not in ("", load_tid):
                    _group_session_start(load_tid)
                # Pinned-group activation: both fighters already bound in
                # RAM with current weights - point the live slots at them
                # (O(1), no disk, fights track banked learning). Falls
                # through to prepare/disk on any miss.
                pinned_hit = False
                if _group_pinned["brains"]:
                    try:
                        rec_wa = vault_pkg.load_brain_record(want_a)
                        rec_wb = vault_pkg.load_brain_record(want_b)
                        ent_a = _group_pinned["brains"].get(
                            str((rec_wa or {}).get("id", "")))
                        ent_b = _group_pinned["brains"].get(
                            str((rec_wb or {}).get("id", "")))
                        if ent_a is not None and ent_b is not None:
                            brain_alpha = ent_a["brain"]
                            brain_beta = ent_b["brain"]
                            rec_a, rec_b = ent_a["rec"], ent_b["rec"]
                            enc_a, dec_a = ent_a["enc"], ent_a["dec"]
                            enc_b, dec_b = ent_b["enc"], ent_b["dec"]
                            pinned_hit = True
                            print("[Server] Pinned group brains activated "
                                  "(no disk load, %.1fs) %s." % (
                                      time.perf_counter() - t_load_start,
                                      load_dbg), flush=True)
                    except Exception as e:
                        print(f"[Server] pinned activation failed ({e}), "
                              f"falling through.", flush=True)
                if not pinned_hit and _prepared_slot_matches(
                        prepare_a, prepare_b, prepare_tag, msg):
                    brain_alpha = prepare_a["brain"]
                    brain_beta = prepare_b["brain"]
                    rec_a, rec_b = prepare_a["rec"], prepare_b["rec"]
                    enc_a, dec_a = prepare_a["enc"], prepare_a["dec"]
                    enc_b, dec_b = prepare_b["enc"], prepare_b["dec"]
                    prepare_a.update(rec=None, path=None, brain=None,
                                     enc=None, dec=None)
                    prepare_b.update(rec=None, path=None, brain=None,
                                     enc=None, dec=None)
                    print("[Server] Preloaded brains activated (no disk load, %.1fs) %s." % (
                        time.perf_counter() - t_load_start, load_dbg),
                          flush=True)
                else:
                    try:
                        rec_a, w_a = vault_pkg.load_brain(msg["alpha_path"])
                        rec_b, w_b = vault_pkg.load_brain(msg["beta_path"])
                    except Exception as e:
                        sock.sendto(json.dumps(
                            {"status": "error", "error": f"tournament_load: {e}"}).encode("utf-8"),
                            client_addr)
                        continue
                    # Per-side native wiring: each fighter runs on the connectome
                    # its record declares (base or experimental overlay), so any
                    # two vault brains can share a bracket. Weight vectors stay
                    # native end-to-end; vault files never change shape.
                    try:
                        new_alpha = _bind_brain(rec_a, w_a, csr, pops, struct_cache)
                        new_beta = _bind_brain(rec_b, w_b, csr, pops, struct_cache)
                        enc_a, dec_a = _bind_codecs(rec_a, pops, codec_cache)
                        enc_b, dec_b = _bind_codecs(rec_b, pops, codec_cache)
                    except Exception as e:
                        sock.sendto(json.dumps(
                            {"status": "error",
                             "error": f"tournament_load: {e}"}
                        ).encode("utf-8"), client_addr)
                        continue
                    brain_alpha, brain_beta = new_alpha, new_beta
                # Brain-view labels bound once here (never in the step
                # hot loop): wiring mix + mapping per fighter.
                tourney_a.update(rec=rec_a, path=msg["alpha_path"], brain=brain_alpha,
                                 enc=enc_a, dec=dec_a,
                                 wiring=mix_label((rec_a.get("generator_params", {}) or {}).get("experiment", None)),
                                 mapping=list(normalize_mapping(((rec_a.get("generator_params", {}) or {})).get("mapping", None))))
                tourney_b.update(rec=rec_b, path=msg["beta_path"], brain=brain_beta,
                                 enc=enc_b, dec=dec_b,
                                 wiring=mix_label((rec_b.get("generator_params", {}) or {}).get("experiment", None)),
                                 mapping=list(normalize_mapping(((rec_b.get("generator_params", {}) or {})).get("mapping", None))))
                if "tournament_id" in msg:
                    tourney_tag["tournament_id"] = str(msg["tournament_id"])
                if "match" in msg:
                    tourney_tag["match"] = str(msg["match"])
                print(f"[Server] Tournament brains loaded: "
                      f"Alpha <- {rec_a.get('name')} ({rec_a.get('id')}, "
                      f"{len(brain_alpha.weights):,} syn) vs "
                      f"Beta <- {rec_b.get('name')} ({rec_b.get('id')}, "
                      f"{len(brain_beta.weights):,} syn) "
                      f"(disk load {time.perf_counter() - t_load_start:.1f}s) "
                      f"{load_dbg}", flush=True)
                # Match echo: the arena validates WHICH load this answers -
                # a stale/late reply must never start a round on the
                # wrong brains.
                sock.sendto(json.dumps({
                    "status": "brains_loaded",
                    "alpha": {"name": rec_a.get("name"), "id": rec_a.get("id")},
                    "beta": {"name": rec_b.get("name"), "id": rec_b.get("id")},
                    "tournament_id": tourney_tag["tournament_id"],
                    "match": tourney_tag["match"],
                }).encode("utf-8"), client_addr)

            elif msg_type == "tournament_prepare":
                # Preload the NEXT match's brains into the prepare slot
                # while the current one plays (or a countdown runs): the
                # ~5-20 s disk+binding load hides under the wait. NEVER
                # touches the live pair - a mid-battle load would clobber
                # the live fight and bank the wrong identities.
                # Pinned-group shortcut: the brains are already bound -
                # point the prepare slot at them (instant, no disk).
                import brain_package as vault_pkg
                t_prep_start = time.perf_counter()
                prep_dbg = "[%s %s]" % (str(msg.get("tournament_id", "?")),
                                        str(msg.get("match", "?")))
                pinned_prep = False
                if _group_pinned["brains"]:
                    try:
                        rec_pa = vault_pkg.load_brain_record(
                            msg["alpha_path"])
                        rec_pb = vault_pkg.load_brain_record(
                            msg["beta_path"])
                        ent_pa = _group_pinned["brains"].get(
                            str((rec_pa or {}).get("id", "")))
                        ent_pb = _group_pinned["brains"].get(
                            str((rec_pb or {}).get("id", "")))
                        if ent_pa is not None and ent_pb is not None:
                            prepare_a.update(
                                rec=ent_pa["rec"],
                                path=str(msg.get("alpha_path", "")),
                                mtime=_vault_mtime(msg.get("alpha_path", "")),
                                brain=ent_pa["brain"],
                                enc=ent_pa["enc"], dec=ent_pa["dec"])
                            prepare_b.update(
                                rec=ent_pb["rec"],
                                path=str(msg.get("beta_path", "")),
                                mtime=_vault_mtime(msg.get("beta_path", "")),
                                brain=ent_pb["brain"],
                                enc=ent_pb["enc"], dec=ent_pb["dec"])
                            prepare_tag["tournament_id"] = str(
                                msg.get("tournament_id", ""))
                            prepare_tag["match"] = str(msg.get("match", ""))
                            pinned_prep = True
                            print("[Server] Prepared next match "
                                  f"{prepare_tag['match']} (pinned, no "
                                  f"disk load, {time.perf_counter() - t_prep_start:.1f}s) "
                                  f"{prep_dbg}.", flush=True)
                            sock.sendto(json.dumps({
                                "status": "prepared",
                                "alpha": {"name": ent_pa["rec"].get("name"),
                                          "id": ent_pa["rec"].get("id")},
                                "beta": {"name": ent_pb["rec"].get("name"),
                                         "id": ent_pb["rec"].get("id")},
                                "tournament_id": prepare_tag["tournament_id"],
                                "match": prepare_tag["match"],
                            }).encode("utf-8"), client_addr)
                            continue
                    except Exception as e:
                        print(f"[Server] pinned prepare failed ({e}), "
                              f"falling through.", flush=True)
                if not pinned_prep:
                    try:
                        rec_a, w_a = vault_pkg.load_brain(msg["alpha_path"])
                        rec_b, w_b = vault_pkg.load_brain(msg["beta_path"])
                        new_alpha = _bind_brain(rec_a, w_a, csr, pops, struct_cache)
                        new_beta = _bind_brain(rec_b, w_b, csr, pops, struct_cache)
                        enc_a, dec_a = _bind_codecs(rec_a, pops, codec_cache)
                        enc_b, dec_b = _bind_codecs(rec_b, pops, codec_cache)
                    except Exception as e:
                        print(f"[Server] prepare failed: {e}", flush=True)
                        sock.sendto(json.dumps({
                            "status": "error",
                            "error": f"tournament_prepare: {e}"}).encode("utf-8"),
                            client_addr)
                        continue
                prepare_a.update(rec=rec_a, path=str(msg.get("alpha_path", "")),
                                 mtime=_vault_mtime(msg.get("alpha_path", "")),
                                 brain=new_alpha, enc=enc_a, dec=dec_a)
                prepare_b.update(rec=rec_b, path=str(msg.get("beta_path", "")),
                                 mtime=_vault_mtime(msg.get("beta_path", "")),
                                 brain=new_beta, enc=enc_b, dec=dec_b)
                prepare_tag["tournament_id"] = str(msg.get("tournament_id", ""))
                prepare_tag["match"] = str(msg.get("match", ""))
                print(f"[Server] Prepared next match {prepare_tag['match']}: "
                      f"Alpha <- {rec_a.get('name')} vs "
                      f"Beta <- {rec_b.get('name')} "
                      f"(disk load {time.perf_counter() - t_prep_start:.1f}s) "
                      f"{prep_dbg}", flush=True)
                sock.sendto(json.dumps({
                    "status": "prepared",
                    "alpha": {"name": rec_a.get("name"), "id": rec_a.get("id")},
                    "beta": {"name": rec_b.get("name"), "id": rec_b.get("id")},
                    "tournament_id": prepare_tag["tournament_id"],
                    "match": prepare_tag["match"],
                }).encode("utf-8"), client_addr)

            elif msg_type == "warm_wirings":
                # Bind-only pre-warm (no slot, no retention, no watch).
                _handle_warm_wirings(sock, client_addr, msg, csr, pops,
                                     struct_cache, codec_cache)
                continue

            elif msg_type == "match_reset":
                # Clean LIF state between tournament battles. Weights (the
                # learned memory) are NEVER touched here.
                print(f"[Server] match_reset "
                      f"({tourney_note()} match={msg.get('match', '')})", flush=True)
                # Zero-activity gate: a tournament-shaped reset with no
                # brains loaded (server restarted, or free_mode mid-event)
                # would answer match_ready off boot brains - a silent
                # reflex-zombie round. Fail loud instead; the arena's
                # error path self-heals via reload (or lands QUIT TO
                # MENU + RESUME past the cap). The message prefix is a
                # stable contract (arena matches it; pinned by test).
                if _reset_needs_brains(msg, tournament_mode,
                                       tourney_a["rec"], tourney_b["rec"]):
                    sock.sendto(json.dumps(
                        {"status": "error",
                         "error": MATCH_RESET_NO_BRAINS_ERROR
                        }).encode("utf-8"), client_addr)
                    continue
                brain_alpha.reset_state()
                brain_beta.reset_state()
                # Fresh noses: encoder habituation must not carry a
                # saturated gain across battles.
                for _enc, _dec in codec_cache.values():
                    _enc.reset_odor()
                if "match" in msg:
                    tourney_tag["match"] = str(msg["match"])
                sock.sendto(json.dumps({"status": "match_ready"}).encode("utf-8"), client_addr)

            elif msg_type == "free_mode":
                # Leave tournament/quick mode: rebuild pristine boot brains
                # (full objects: a tournament brain may carry a different
                # wiring, so restoring weights alone would corrupt the shape).
                # Attribution: a mid-tournament free_mode is the classic
                # wedge trigger, so the SENDER is logged - a stale client
                # (old test boot, zombie process) is then identifiable.
                print(f"[Server] free_mode from {client_addr}: "
                      + (f"leaving tournament ({tourney_note()}), "
                         f"boot brains restored." if tournament_mode
                         else "already free (boot/duplicate)."),
                      flush=True)
                if tournament_mode:
                    tournament_mode = False
                    brain_alpha = FlyBrain(boot_struct[0], boot_struct[1],
                                           boot_weights_a.copy())
                    brain_beta = FlyBrain(boot_struct[0], boot_struct[1],
                                          boot_weights_b.copy())
                    tourney_a.update(rec=None, path=None, brain=brain_alpha,
                                     enc=encoder, dec=decoder)
                    tourney_b.update(rec=None, path=None, brain=brain_beta,
                                     enc=encoder, dec=decoder)
                    # Leaving a tournament abandons any pinned group
                    # (its rounds never bank as a group; per-round
                    # battle records already flushed).
                    _group_session_end("free mode")
                brain_alpha.reset_state()
                brain_beta.reset_state()
                sock.sendto(json.dumps({"status": "free_ready"}).encode("utf-8"), client_addr)

            elif msg_type == "match_report":
                # ONE bank per match: fighters resolve from the message
                # (never the live pair), then the shared replay core
                # runs - parity with round reports by construction.
                _handle_match_report(
                    sock, client_addr, msg, tourney_tag,
                    tournament_lr_scale, tournament_mode, evo_mgr,
                    dopamine_rl, base_lr, tourney_note, csr, pops,
                    struct_cache)
                continue

            elif msg_type == "get_server_state":
                # Proactive desync check: the arena polls before/while
                # waiting so a restarted (FREE-mode) server is caught
                # BEFORE the battle/bank fails, not after.
                sock.sendto(json.dumps({
                    "status": "server_state",
                    "tournament_mode": tournament_mode,
                    "tournament_id": tourney_tag.get("tournament_id", ""),
                    "match": tourney_tag.get("match", ""),
                }).encode("utf-8"), client_addr)

            elif msg_type == "round_report_part":
                # One slice of an oversize bank (see BrainClient
                # split_report_parts): stash by nonce, process whole
                # once complete. Retried slices overwrite the same
                # index (idempotent); the stash is bounded.
                _pnonce = str(msg.get("round_nonce", ""))
                try:
                    _pidx, _pcount = int(msg.get("part_idx", -1)), int(msg.get("part_count", 0))
                except (TypeError, ValueError):
                    _pidx, _pcount = -1, 0
                if _pnonce and 0 <= _pidx < _pcount:
                    _pent = _ROUND_PART_STASH.get(_pnonce)
                    if _pent is None:
                        if len(_ROUND_PART_STASH) >= _ROUND_PART_STASH_MAX:
                            _oldest = min(_ROUND_PART_STASH,
                                          key=lambda k: _ROUND_PART_STASH[k].get("first_seen", 0.0))
                            del _ROUND_PART_STASH[_oldest]
                        _pent = {"count": _pcount, "parts": {},
                                 "first_seen": time.monotonic()}
                        _ROUND_PART_STASH[_pnonce] = _pent
                    elif _pent.get("count", 0) != _pcount:
                        _pent["count"] = _pcount
                        _pent["parts"] = {}
                    _pent["parts"][_pidx] = msg
                    _whole = _assemble_round_parts(_pnonce, _pent)
                    if _whole is not None:
                        del _ROUND_PART_STASH[_pnonce]
                        print(f"[Server] Round report reassembled: "
                              f"{_pnonce} ({_pcount} parts).", flush=True)
                        _handle_round_report(
                            sock, client_addr, _whole, tourney_a, tourney_b,
                            tourney_tag, tournament_lr_scale, tournament_mode,
                            evo_mgr, dopamine_rl, base_lr, tourney_note,
                            csr, pops, struct_cache, codec_cache)
                else:
                    print(f"[Server] round_report_part: bad index "
                          f"for nonce={_pnonce}.", flush=True)
                continue

            elif msg_type == "round_report":
                # ONE bank per round: matches replay in order (per-match
                # vault reload, battles in order, ELO chains, records),
                # then one journal + one save set. The arena overlaps
                # the bank with the next round's intermission; loads gate
                # on the ack.
                _handle_round_report(
                    sock, client_addr, msg, tourney_a, tourney_b,
                    tourney_tag, tournament_lr_scale, tournament_mode,
                    evo_mgr, dopamine_rl, base_lr, tourney_note,
                    csr, pops, struct_cache, codec_cache)
                continue

            elif msg_type == "group_report":
                # ONE bank per group (groups only): seal the journal,
                # save each pinned brain once. The arena overlaps it
                # with the group-to-final intermission; final loads
                # gate on the ack.
                _handle_group_report(
                    sock, client_addr, msg, tourney_a, tourney_b,
                    tourney_tag, tournament_lr_scale, evo_mgr,
                    dopamine_rl, base_lr, tourney_note,
                    csr, pops, struct_cache, codec_cache)
                continue

            elif msg_type == "tournament_match":
                # Match verdict: bump match counters + match ELO on both
                # identities. Duplicate messages (same id) resend the ack
                # without re-banking.
                mw = msg.get("match_winner", "")
                mkey = (str(msg.get("tournament_id", "")),
                        str(msg.get("match", "")))
                if not (all(mkey) and mkey == _last_match_banked["key"]):
                    _bank_match_result(tourney_a, tourney_b, mw)
                    if all(mkey):
                        _last_match_banked["key"] = mkey
                sock.sendto(json.dumps({"status": "match_recorded"}).encode("utf-8"), client_addr)

            elif msg_type == "tournament_end":
                # Crown the champion: tournaments_won += 1. Duplicate
                # crowns (same tournament+champion) resend the ack.
                # Banked BY VAULT ID: by close time the slot holders
                # are consolation fighters, not the champion, so the
                # legacy slot alone crowned the wrong brain. Falls
                # back to the slot when no id is given (old clients).
                champ = msg.get("champion", "")
                champ_id = str(msg.get("champion_id", "") or "")
                import brain_package as vault_pkg
                st = tourney_a if champ == "alpha" else tourney_b
                tkey = (tourney_tag.get("tournament_id") or "", champ)
                if champ_id:
                    tkey = (tourney_tag.get("tournament_id") or "",
                            champ_id)
                    try:
                        crec, cweights = vault_pkg.load_brain(champ_id)
                        st = {"rec": crec,
                              "brain": _WeightsBox(cweights)}
                    except Exception as e:
                        print(f"[Server] Crown {champ_id}: vault load "
                              f"failed ({e}), falling back to slot.",
                              flush=True)
                if tkey == _last_title_banked.get("key"):
                    print(f"[Server] Duplicate crown {tkey[0]} {champ}: "
                          f"title already banked.", flush=True)
                elif _bank_title(st, champ, key=tkey):
                    print(f"[Server] Crowned {champ} champion of {tkey[0]} "
                          f"(titles={st['rec']['record']['tournaments_won']}).",
                          flush=True)
                else:
                    print(f"[Server] Crown {tkey[0]} {champ}: no record "
                          f"bound, title skipped.", flush=True)
                # A tournament close ends any pinned group session (its
                # rounds either banked as a group already or never will).
                _group_session_end("tournament end")
                sock.sendto(json.dumps({"status": "tournament_closed"}).encode("utf-8"), client_addr)

            elif msg_type == "tournament_weights":
                # Arena pushes post-battle weights back (it owns the vault).
                # Kept for symmetry/debugging; server keeps training in-RAM.
                sock.sendto(json.dumps({"status": "weights_ack"}).encode("utf-8"), client_addr)

            elif msg_type == "merge":
                # Manual merge button: archive Beta (loser) then turn Beta
                # into a mutated Alpha x Beta hybrid. Alpha (champion) kept.
                merge_count += 1
                archive_dir = os.path.join(checkpoints_dir, "archived")
                os.makedirs(archive_dir, exist_ok=True)
                loser_path = os.path.join(
                    archive_dir, f"loser_gen{evo_mgr.generation:04d}_merge{merge_count:02d}.npz")
                np.savez_compressed(loser_path, weights=brain_beta.weights)
                blended = (brain_alpha.weights * 0.5 + brain_beta.weights * 0.5)
                blended *= (1.0 + np.random.normal(0.0, 0.03, size=blended.shape).astype(np.float32))
                brain_beta.weights = np.clip(blended, -3000.0, 3000.0)
                brain_alpha.reset_state()
                brain_beta.reset_state()
                print(f"[Server] Merged Alpha x Beta -> Beta (archived loser to {loser_path})")
                sock.sendto(json.dumps({
                    "status": "merged",
                    "merge_count": merge_count,
                    "archived_loser": os.path.basename(loser_path),
                }).encode("utf-8"), client_addr)

            elif msg_type == "restart":
                # Manual restart: bank the fight so far as dopamine (winner
                # reward / loser aversive) but KEEP both brains intact. Unlike
                # round_over, this does NOT clone/mutate or advance the
                # generation, so trained variant personalities survive restarts.
                stats_a = msg.get("stats_alpha", {})
                stats_b = msg.get("stats_beta", {})
                fit_a = evo_mgr.calc_fitness(stats_a)
                fit_b = evo_mgr.calc_fitness(stats_b)
                winner = "alpha" if fit_a >= fit_b else "beta"
                if tournament_mode:
                    schemes_a = normalize_mapping(
                        ((tourney_a["rec"] or {}).get("generator_params", {}) or {}).get("mapping", None))
                    schemes_b = normalize_mapping(
                        ((tourney_b["rec"] or {}).get("generator_params", {}) or {}).get("mapping", None))
                    legacy_a = is_legacy_record(tourney_a["rec"])
                    legacy_b = is_legacy_record(tourney_b["rec"])
                else:
                    schemes_a, schemes_b = (), ()
                    legacy_a, legacy_b = False, False
                if winner == "alpha":
                    dopamine_rl.apply_plasticity(brain_alpha, last_sens_a, last_ctrl_a, +1.0, schemes_a)
                    dopamine_rl.apply_plasticity(brain_beta, last_sens_b, last_ctrl_b, -0.8, schemes_b)
                else:
                    dopamine_rl.apply_plasticity(brain_beta, last_sens_b, last_ctrl_b, +1.0, schemes_b)
                    dopamine_rl.apply_plasticity(brain_alpha, last_sens_a, last_ctrl_a, -0.8, schemes_a)
                # Pool-aware gain pinning: preserve learned ratios, pin
                # magnitudes (manual restarts bank dopamine too). Legacy
                # brains pin runaway pools only.
                dopamine_rl.pin_gains(brain_alpha, legacy=legacy_a)
                dopamine_rl.pin_gains(brain_beta, legacy=legacy_b)
                brain_alpha.reset_state()
                brain_beta.reset_state()
                print(f"[Server] Restart banked: {winner.upper()} led "
                      f"(Alpha: {fit_a:.1f}, Beta: {fit_b:.1f}). Weights preserved.")
                sock.sendto(json.dumps({
                    "status": "restarted",
                    "round_winner": winner,
                    "fitness_alpha": fit_a,
                    "fitness_beta": fit_b,
                }).encode("utf-8"), client_addr)

            elif msg_type == "reset":
                brain_alpha.reset_state()
                brain_beta.reset_state()
                sock.sendto(json.dumps({"status": "reset_complete"}).encode("utf-8"), client_addr)

        except KeyboardInterrupt:
            print("\n[Server] Shutting down...")
            break
        except Exception as e:
            # Windows UDP: a reply to a now-closed arena port earns an ICMP
            # Port Unreachable, and each pending notification makes the next
            # recvfrom raise 10054 (typically in bursts across scene
            # changes). Back off instead of tight-looping the log: pending
            # datagrams are still read once the notifications drain.
            if "10054" in str(e):
                # Counted, not muted: storm SIZE was invisible before -
                # a burst of N dead-port replies is a different diagnosis
                # than a stray one.
                run_brain_server._n10054 = getattr(
                    run_brain_server, "_n10054", 0) + 1
                now = time.monotonic()
                if now - getattr(run_brain_server, "_last_10054", 0.0) > 5.0:
                    print(f"[Server Error] {e} ({run_brain_server._n10054}x "
                          f"in the last 5s)", flush=True)
                    run_brain_server._last_10054 = now
                    run_brain_server._n10054 = 0
                time.sleep(0.05)
            else:
                print(f"[Server Error] {e} {_disk_note()}", flush=True)


def _disk_note():
    """Free-space attribution for IO failure logs (rare path only): a
    full disk reads identically to a locked-file race without this."""
    try:
        import shutil
        free_gb = shutil.disk_usage(PROJECT_ROOT).free / 1e9
        return f"(disk free {free_gb:.1f} GB)"
    except Exception:
        return ""


class _StampedStdout:
    """Per-line wall-clock stamps for server_log.txt: previously only
    boot banners carried a time, so gap lengths between events were
    unmeasurable. Line-buffered - a partial trailing chunk holds until
    its newline arrives, then flushes stamped."""

    def __init__(self, inner):
        self._inner = inner
        self._pending = ""

    def write(self, s):
        self._pending += s
        while "\n" in self._pending:
            line, self._pending = self._pending.split("\n", 1)
            self._inner.write(time.strftime("[%H:%M:%S] ") + line + "\n")
        return len(s)

    def flush(self):
        if self._pending:
            self._inner.write(time.strftime("[%H:%M:%S] ") + self._pending)
            self._pending = ""
        self._inner.flush()

    def __getattr__(self, name):
        return getattr(self._inner, name)


if __name__ == "__main__":
    # Test isolation: BRAIN_PORT moves the server off 9999 (the
    # protocol suite runs its own instance; production never sets it).
    if os.environ.get("FLY_LOG_STAMPS", "1") != "0":
        sys.stdout = _StampedStdout(sys.stdout)
    run_brain_server(port=int(os.environ.get("BRAIN_PORT", "9999")))
