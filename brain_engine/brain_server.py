import os
import sys
import json
import time
import socket
from copy import deepcopy
import numpy as np

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from sensory_motor import SensoryEncoder, MotorDecoder, normalize_mapping, is_legacy_record
from evolution_engine import EvolutionManager
from dopamine_learning import DopamineReinforcement
from experimental_wiring import (experiment_arrays, experiment_suffix,
                                   normalize_experiment, mix_label)


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
    stale-cache safe: absent pools read empty)."""
    idx = {}
    for key in ("pheromone_da1", "pheromone_va1v", "visual_lc10",
                "visual_lc4", "visual_lplc2", "visual_lc11", "visual_lc15",
                "visual_lc17", "visual_lc18", "gyro_jo",
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
    return idx


RASTER_CAP = 128


def _raster_ids(pool_idx, pool, cap=RASTER_CAP):
    """Deterministic neuron-id slice for raster drill-down: sorted ids,
    capped (big pools show the first N cells), plus the pool total."""
    ids = sorted(pool_idx.get(pool, set()))
    return ids[:cap], len(ids)


def _spike_stats(spikes, pops, pool_idx=None, detail=0):
    """Compact brain-activation summary for the HUD + brain view.

    Always carries the legacy HUD keys plus a per-pool count dict
    (~20 ints, cheap). detail>=2 additionally carries capped raw spike
    ids for raster drill-down (truncation-guarded for UDP size).
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
    counts = {}
    for s in spikes:
        s = int(s)
        counts[s] = counts.get(s, 0) + 1
    out = {
        "spikes": int(len(spikes)),
        "dn_left": int(sum(counts.get(s, 0) for s in dn_left)),
        "dn_right": int(sum(counts.get(s, 0) for s in dn_right)),
        "lplc2": int(sum(counts.get(s, 0) for s in lplc2)),
        "mn_thrust": int(sum(counts.get(s, 0) for s in mn_thrust)),
        "vs_flow": int(sum(counts.get(s, 0) for s in vs_flow)),
    }
    if pool_idx is not None:
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
    battle_winner = "draw" if arena_draw else winner
    records = []
    weights = {}
    for side, st in (("alpha", tourney_a), ("beta", tourney_b)):
        if st["rec"] is None:
            continue
        rec = deepcopy(st["rec"])
        outcome = "draw" if arena_draw else ("win" if side == winner else "loss")
        vault_pkg.record_battle_result(rec, outcome)
        if not arena_draw:
            vault_pkg.log_training_session(
                rec, 0,
                {"lr_scale": tournament_lr_scale,
                 "pulse": pulse if outcome == "win" else -0.8 * pulse,
                 "outcome": outcome},
                f"tournament battle {outcome} ({tourney_note()})")
        records.append({"side": side, "record": rec})
        weights[side] = st["brain"].weights
    fit_a, fit_b = _sanitize_fit(fit_a), _sanitize_fit(fit_b)
    print(f"[Server] Tournament battle done id={battle_id or '?'} "
          f"({tourney_note()}) winner={battle_winner} "
          f"fit {fit_a:.1f}-{fit_b:.1f}", flush=True)
    resp = {
        "status": "tournament_battle",
        "battle_winner": battle_winner,
        "fitness_alpha": fit_a,
        "fitness_beta": fit_b,
        "battle_id": battle_id,
    }
    _write_pending_battle(battle_key, resp, records, weights)
    _recover_pending_battle((tourney_a, tourney_b))
    try:
        sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
    except OSError as e:
        # Dead client port (arena changed scenes): the verdict is already
        # persisted, so the arena's retry will be answered from disk.
        print(f"[Server] send tournament_battle failed (kept verdict): {e}",
              flush=True)


def _norm_experiment(value):
    """Canonical wiring key: None for base, else a sorted tuple of names
    (additive mixes; see experimental_wiring.normalize_experiment)."""
    return normalize_experiment(value)


def _bind_brain(rec, weights, csr, pops, struct_cache):
    """Builds a FlyBrain on the wiring its record declares (base or
    experimental overlay), validating the file's arity. Raises ValueError
    on unknown wirings or corrupt/mislabeled files."""
    exp = _norm_experiment((rec.get("generator_params", {}) or {}).get("experiment", None))
    if exp not in struct_cache:
        indptr, indices, _data = experiment_arrays(exp, csr, pops)
        struct_cache[exp] = (indptr, indices)
        print(f"[Server] Cached {len(indices):,} synapse wiring for "
              f"experiment={mix_label(exp)}")
    indptr, indices = struct_cache[exp]
    if len(weights) != len(indices):
        raise ValueError(
            f"brain '{rec.get('name')}' declares wiring '{mix_label(exp)}' "
            f"but carries arity {len(weights)} != {len(indices)}; "
            f"file corrupt or mislabeled")
    return FlyBrain(indptr, indices, np.ascontiguousarray(weights, dtype=np.float32).copy())


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
    legacy = is_legacy_record(rec)
    key = (m, legacy)
    if key not in codec_cache:
        codec_cache[key] = (SensoryEncoder(pops, mapping=m, legacy=legacy),
                            MotorDecoder(pops, mapping=m, legacy=legacy))
        print(f"[Server] Cached {m} sensorimotor codecs (legacy={legacy})")
    return codec_cache[key]


PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _last_verdict_path():
    return os.path.join(PROJECT_ROOT, "tournaments", "_last_battle_verdict.json")


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


def _pending_battle_path():
    return os.path.join(PROJECT_ROOT, "tournaments", "_pending_battle.npz")


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
                        or entry.get("side") not in ("alpha", "beta") \
                        or not isinstance(entry.get("record"), dict) \
                        or entry["side"] not in pending:
                    raise ValueError("pending battle journal has bad entry")
                payload[entry["side"]] = np.array(pending[entry["side"]])
    except Exception as e:
        bad = path + ".corrupt-%d" % int(time.time())
        try:
            os.replace(path, bad)
        except OSError:
            pass
        print(f"[Server] QUARANTINED unreadable pending battle journal -> "
              f"{bad} ({e}). Vault files may be half-written; reconcile "
              f"before resuming.", flush=True)
        raise
    # Phase 2: replay. Failures here (vault/verdict IO) leave the journal
    # in place so the next message or boot retries the SAME record bumps.
    for entry in transaction["records"]:
        rec = entry["record"]
        weights = payload[entry["side"]]
        vault_pkg.save_brain(rec, weights, backup=False, fast=True)
        for st in states:
            if st["rec"] is not None and st["rec"]["filename"] == rec["filename"]:
                st["rec"] = deepcopy(rec)
                st["brain"].weights = weights.copy()
    # Only keyed battles participate in retry idempotency. An
    # unkeyed journal must still replay its vault saves, but writing
    # a key=None verdict here would clobber the previous battle's
    # real verdict and reopen it to double-banking.
    if transaction.get("key") is not None:
        _write_last_verdict(transaction["key"], transaction["result"])
    os.remove(path)


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

    try:
        _recover_pending_battle()
    except Exception as e:
        # Journal-quarantine already logged loudly inside; transient IO
        # here only delays vault writes until the next message's recovery.
        print(f"[Server] Boot battle recovery deferred: {e}", flush=True)

    # 1. Load connectome & populations
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
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
    codec_cache = {((), False): (encoder, decoder)}
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

    def _is_step(data):
        try:
            return json.loads(data.decode("utf-8")).get("type", "step") == "step"
        except (ValueError, UnicodeDecodeError, AttributeError):
            return False

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
                sock.settimeout(0.0)
                try:
                    while True:
                        try:
                            d2, a2 = sock.recvfrom(65535)
                        except (BlockingIOError, socket.timeout):
                            break
                        if _is_step(d2):
                            data, client_addr = d2, a2
                            step_dropped += 1
                        else:
                            stash = (d2, a2)
                            break
                finally:
                    sock.settimeout(None)
                msg = json.loads(data.decode("utf-8"))
                msg_type = msg.get("type", "step")
                step_count += 1
                _t_step = time.monotonic()

            if msg_type == "step":
                # Extract sensory state from Godot
                sens_a = msg.get("alpha", {})
                sens_b = msg.get("beta", {})

                # Per-side neuro-mapping codecs in tournament/quick mode;
                # the shared base pair in free battle (no records bound).
                enc_a = tourney_a["enc"] if tournament_mode and tourney_a["rec"] is not None else encoder
                dec_a = tourney_a["dec"] if tournament_mode and tourney_a["rec"] is not None else decoder
                enc_b = tourney_b["enc"] if tournament_mode and tourney_b["rec"] is not None else encoder
                dec_b = tourney_b["dec"] if tournament_mode and tourney_b["rec"] is not None else decoder

                # Encode sensory states into Poisson spikes
                stim_a = enc_a.encode(sens_a)
                stim_b = enc_b.encode(sens_b)

                # Integrate 50 ms in biological LIF connectomes
                spikes_a = brain_alpha.integrate_50ms(stim_a)
                spikes_b = brain_beta.integrate_50ms(stim_b)

                # Decode descending motor spikes into flight controls
                # (brain readout blended with sensory reflex for reliable sign).
                ctrl_a = dec_a.decode(spikes_a, sensory_hint=sens_a)
                ctrl_b = dec_b.decode(spikes_b, sensory_hint=sens_b)
                last_sens_a, last_sens_b = sens_a, sens_b
                last_ctrl_a, last_ctrl_b = ctrl_a, ctrl_b

                try:
                    detail = int(msg.get("detail", 0))
                except (TypeError, ValueError):
                    detail = 0
                detail = max(0, min(detail, 2))
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
                        "alpha": _spike_stats(spikes_a, pops, pool_idx,
                                              detail),
                        "beta": _spike_stats(spikes_b, pops, pool_idx,
                                             detail),
                        "wiring": {"alpha": wire_a, "beta": wire_b},
                        "mapping": {"alpha": map_a, "beta": map_b},
                    },
                }
                sock.sendto(json.dumps(response).encode("utf-8"), client_addr)
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
                    print(f"[Server] round_over received id={battle_id or '?'} "
                          f"({tourney_note()}) draw={bool(msg.get('arena_draw', False))}",
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
                    else:
                        battle_key = None
                    winner, fit_a, fit_b = evo_mgr.evaluate_match(stats_a, stats_b)
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
                        _apply_round_learning(
                            dopamine_rl, brain_alpha, brain_beta, winner,
                            last_sens_a, last_sens_b, last_ctrl_a, last_ctrl_b,
                            pulse, schemes_a, schemes_b, legacy_a, legacy_b,
                            arena_draw=bool(msg.get("arena_draw", False)))
                    finally:
                        dopamine_rl.lr = base_lr
                    if tournament_mode:
                        _handle_tournament_round_over(
                            sock, client_addr, msg, winner, fit_a, fit_b,
                            tourney_a, tourney_b, tourney_tag,
                            tournament_lr_scale, pulse, tourney_note,
                            battle_id, battle_key)
                        continue
                    evo_mgr.advance_generation(brain_alpha, brain_beta, winner, target_pathways)

                    resp = {
                        "status": "generation_advanced",
                        "new_generation": evo_mgr.generation,
                        "previous_winner": winner
                    }
                    sock.sendto(json.dumps(resp).encode("utf-8"), client_addr)
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
                tournament_mode = True
                if "lr_scale" in msg:
                    try:
                        tournament_lr_scale = float(msg["lr_scale"])
                    except (TypeError, ValueError):
                        pass
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
                      f"{len(new_alpha.weights):,} syn) vs "
                      f"Beta <- {rec_b.get('name')} ({rec_b.get('id')}, "
                      f"{len(new_beta.weights):,} syn)", flush=True)
                sock.sendto(json.dumps({
                    "status": "brains_loaded",
                    "alpha": {"name": rec_a.get("name"), "id": rec_a.get("id")},
                    "beta": {"name": rec_b.get("name"), "id": rec_b.get("id")},
                }).encode("utf-8"), client_addr)

            elif msg_type == "match_reset":
                # Clean LIF state between tournament battles. Weights (the
                # learned memory) are NEVER touched here.
                print(f"[Server] match_reset "
                      f"({tourney_note()} match={msg.get('match', '')})", flush=True)
                brain_alpha.reset_state()
                brain_beta.reset_state()
                if "match" in msg:
                    tourney_tag["match"] = str(msg["match"])
                sock.sendto(json.dumps({"status": "match_ready"}).encode("utf-8"), client_addr)

            elif msg_type == "free_mode":
                # Leave tournament/quick mode: rebuild pristine boot brains
                # (full objects: a tournament brain may carry a different
                # wiring, so restoring weights alone would corrupt the shape).
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
                brain_alpha.reset_state()
                brain_beta.reset_state()
                sock.sendto(json.dumps({"status": "free_ready"}).encode("utf-8"), client_addr)

            elif msg_type == "tournament_match":
                # Match verdict: bump match counters on both identities.
                import brain_package as vault_pkg
                mw = msg.get("match_winner", "")
                for side, st in (("alpha", tourney_a), ("beta", tourney_b)):
                    if st["rec"] is None:
                        continue
                    outcome = "win" if side == mw else "loss"
                    vault_pkg.record_match_result(st["rec"], outcome)
                    vault_pkg.save_brain(st["rec"], st["brain"].weights,
                                         backup=False, fast=True)
                sock.sendto(json.dumps({"status": "match_recorded"}).encode("utf-8"), client_addr)

            elif msg_type == "tournament_end":
                # Crown the champion: tournaments_won += 1.
                import brain_package as vault_pkg
                champ = msg.get("champion", "")
                st = tourney_a if champ == "alpha" else tourney_b
                if st["rec"] is not None:
                    st["rec"]["record"]["tournaments_won"] += 1
                    vault_pkg.save_brain(st["rec"], st["brain"].weights,
                                         backup=False, fast=True)
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
                now = time.monotonic()
                if now - getattr(run_brain_server, "_last_10054", 0.0) > 5.0:
                    print(f"[Server Error] {e} (further repeats muted 5s)",
                          flush=True)
                    run_brain_server._last_10054 = now
                time.sleep(0.05)
            else:
                print(f"[Server Error] {e}", flush=True)


if __name__ == "__main__":
    run_brain_server()
