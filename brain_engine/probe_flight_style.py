"""Headless flight-style probe: fly two vault brains against scripted
targets (climb / level / dive) and compare altitude, thrust, pitch,
evade exposure, lunges, and MBON approach bias.

Usage (from project root):
  python brain_engine/probe_flight_style.py Eye2 Eye3
  python brain_engine/probe_flight_style.py Eye2 Eye3 --episodes 4 --steps 60

Answers "why won't it climb?" without running the arena: each brain runs
its NATIVE wiring + codecs on the shared kinematic trainer physics, so
differences come from the brains, not the scene.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import brain_package as vault
import train_homing as th
from brain_server import _bind_brain, _bind_codecs
from connectome_loader import load_or_build_csr, load_or_extract_populations

SCENARIOS = {
    # target offsets relative to the fly spawn (-14, 7, 0)
    "climb": dict(tx=15.0, ty=14.0, tz=2.0),
    "level": dict(tx=15.0, ty=7.0, tz=2.0),
    "dive": dict(tx=15.0, ty=2.0, tz=2.0),
}


def load_brain_by_name(name):
    for rec in vault.scan_vault():
        if rec.get("name") == name:
            rec, w = vault.load_brain(rec["filename"])
            return rec, w
    raise SystemExit(f"Brain '{name}' not found in vault.")


def fly_scenario(rec, weights, csr, pops, scenario, episodes, steps):
    indptr = indices = None
    struct_cache = {}
    brain = _bind_brain(rec, np.ascontiguousarray(
        np.asarray(weights, dtype=np.float32)), csr, pops, struct_cache)
    enc, dec = _bind_codecs(rec, pops, {})
    sc = SCENARIOS[scenario]
    agg = {"alt": [], "thrust": [], "pitch": [], "approach": [],
           "evade": 0, "steps": 0, "lunges": 0, "final_dist": []}
    for _ in range(episodes):
        brain.reset_state()
        fly = th.KinematicFly(x=-14.0, y=7.0, z=0.0, heading_rad=0.0)
        tgt = th.KinematicFly(x=sc["tx"], y=sc["ty"], z=sc["tz"])
        _, prev_dist = th.compute_agent_senses(fly, tgt)
        for _ in range(steps):
            senses, dist = th.compute_agent_senses(fly, tgt, prev_dist=prev_dist)
            stim = enc.encode(senses)
            spikes = brain.integrate_50ms(stim)
            ctrl = dec.decode(spikes, sensory_hint=senses)
            th.apply_arena_controls(fly, ctrl, senses, dist, dt=0.05)
            agg["alt"].append(float(fly.pos[1]))
            agg["thrust"].append(float(ctrl.get("thrust", 0.2)))
            agg["pitch"].append(float(ctrl.get("pitch_torque", 0.0)))
            agg["approach"].append(float(ctrl.get("approach_bias", 0.0)))
            agg["evade"] += int(bool(ctrl.get("emergency_evade", False)))
            agg["steps"] += 1
            prev_dist = dist
        agg["lunges"] += fly.lunge_count
        agg["final_dist"].append(dist)
    n = max(agg["steps"], 1)
    return {
        "alt_mean": float(np.mean(agg["alt"])),
        "alt_min": float(np.min(agg["alt"])),
        "alt_max": float(np.max(agg["alt"])),
        "thrust_mean": float(np.mean(agg["thrust"])),
        "pitch_mean": float(np.mean(agg["pitch"])),
        "approach_mean": float(np.mean(agg["approach"])),
        "evade_frac": agg["evade"] / n,
        "lunges": agg["lunges"],
        "final_dist": float(np.mean(agg["final_dist"])),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("brains", nargs=2, help="Two vault brain names to compare")
    ap.add_argument("--episodes", type=int, default=4)
    ap.add_argument("--steps", type=int, default=60)
    ap.add_argument("--fresh", action="store_true",
                    help="Compare FRESH (untrained) brains with each brain's "
                    "own wiring+mapping instead of vault weights: separates "
                    "wiring effects from learned effects.")
    args = ap.parse_args()

    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    th.TREES = []  # open sky: isolate vertical behavior from tree dodging

    if args.fresh:
        from experimental_wiring import experiment_arrays
        recs = []
        for n in args.brains:
            rec, _w = load_brain_by_name(n)
            gp = rec.get("generator_params", {}) or {}
            _ip, _ix, wb = experiment_arrays(gp.get("experiment"), csr, pops)
            recs.append((rec, np.ascontiguousarray(
                np.asarray(wb, dtype=np.float32))))
            print(f"[{n}] FRESH weights on wiring={gp.get('experiment', 'base')}")
    else:
        recs = [load_brain_by_name(n) for n in args.brains]
    for (rec, _w) in recs:
        gp = rec.get("generator_params", {}) or {}
        print(f"[{rec['name']}] wiring={gp.get('experiment', 'base')} "
              f"mapping={gp.get('mapping', 'base')} "
              f"episodes={rec.get('training', {}).get('episodes', '?')}")

    results = {}
    for (rec, w), name in zip(recs, args.brains):
        results[name] = {}
        for sc in SCENARIOS:
            print(f"[{name}] flying {sc} ...", flush=True)
            results[name][sc] = fly_scenario(
                rec, w, csr, pops, sc, args.episodes, args.steps)

    cols = ["alt_mean", "alt_min", "alt_max", "thrust_mean", "pitch_mean",
            "approach_mean", "evade_frac", "lunges", "final_dist"]
    a, b = args.brains
    for sc in SCENARIOS:
        print(f"\n=== {sc.upper()} ({args.episodes}x{args.steps} steps) ===")
        print(f"{'metric':12s} {a:>10s} {b:>10s} {'delta(B-A)':>10s}")
        for c in cols:
            va, vb = results[a][sc][c], results[b][sc][c]
            print(f"{c:12s} {va:10.3f} {vb:10.3f} {vb - va:10.3f}")
    print("\nRead: alt_* = actual elevation behavior; thrust_mean = climb "
          "energy; approach_mean < 0 = MBON avoidance throttling thrust; "
          "evade_frac = time spent in GF dives (pushes DOWN).")


if __name__ == "__main__":
    main()
