"""Live verification that reward/punishment signals actually teach.

Replicates Eye3's configuration exactly (full wiring mix + full mapping
stack, same rates) and runs three checks:

1. LEARNING CURVE: fresh brain -> 5/10/15 episodes -> probe approach
   bias / thrust / pursuit success at each checkpoint. Must improve.
2. ZERO-DA CONTROL: fresh brain, learning_rate=0 for 5 episodes ->
   weights must come back byte-identical (curve in (1) is reward-driven,
   not drift or pinning).
3. CRASH CONDITIONING: fresh brain, one -2.0 crash pulse with frontal
   senses -> KC->MBON approach must fall and avoid must rise (the
   Eye3 crash-trauma mechanism, reproduced deliberately).

Usage (from project root):
  python brain_engine/verify_learning.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from connectome_loader import load_or_build_csr, load_or_extract_populations
from dopamine_learning import DopamineReinforcement
from experimental_wiring import experiment_arrays
from probe_flight_style import fly_scenario
from train_homing import run_training

EXPERIMENT = ["lplc2_contra_dn", "retina_wide", "spear_lunge"]
MAPPING = ["muscles_up", "gyro_flow", "mbon", "retina"]
TRAIN_KW = dict(variant="custom", seed=932, learning_rate=0.005,
                dist_gain=0.1, target_evasion=0.2,
                experiment=EXPERIMENT, mapping=MAPPING, legacy=False)


def fresh_weights(csr, pops):
    _ip, _ix, wb = experiment_arrays(EXPERIMENT, csr, pops)
    return np.ascontiguousarray(np.asarray(wb, dtype=np.float32))


def train_block(weights, episodes, **kw):
    params = dict(TRAIN_KW)
    params.update(kw)
    save_path, new_w, summary = run_training(
        num_episodes=episodes, save_name="tmp_verify_learn.npz",
        init_weights=weights, progress_cb=None, return_brain=True,
        **params)
    try:
        if save_path and os.path.isfile(save_path):
            os.remove(save_path)
    except OSError:
        pass
    return new_w, summary


def probe_metrics(rec, weights, csr, pops):
    m = fly_scenario(rec, weights, csr, pops, "climb",
                     episodes=2, steps=40)
    return m["approach_mean"], m["thrust_mean"], m["final_dist"]


def main():
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    import train_homing as th
    th.TREES = []
    rec = {"name": "Verify", "generator_params": {"experiment": EXPERIMENT,
                                                  "mapping": MAPPING}}

    print("=== 1. LEARNING CURVE (Eye3 mix, 0/5/10/15 episodes) ===")
    w = fresh_weights(csr, pops)
    curve = []
    for ep in (0, 5, 10, 15):
        if ep > 0:
            w, summary = train_block(w, 5)
            print(f"  trained -> ep {ep}: successes "
                  f"{summary['successes']}/5", flush=True)
        app, thr, dist = probe_metrics(rec, w, csr, pops)
        curve.append((ep, app, thr, dist))
        print(f"  [ep {ep:2d}] approach={app:+.3f} thrust={thr:.3f} "
              f"final_dist={dist:.2f}m", flush=True)

    print("=== 2. ZERO-DA CONTROL (lr=0, 5 episodes) ===")
    w0 = fresh_weights(csr, pops)
    w1, _s = train_block(w0, 5, learning_rate=0.0)
    identical = np.array_equal(w0, w1)
    print(f"  weights byte-identical after 5 lr=0 episodes: {identical}",
          flush=True)

    print("=== 3. CRASH CONDITIONING (one -2.0 pulse, frontal senses) ===")
    indptr, indices, wbasis = experiment_arrays(EXPERIMENT, csr, pops)
    rl = DopamineReinforcement(pops, learning_rate=0.005,
                               base=(indptr, indices, wbasis))

    class _B:
        pass

    b = _B()
    b.indptr, b.indices = indptr, indices
    b.weights = np.ascontiguousarray(np.asarray(wbasis, dtype=np.float32))
    pos_app, pos_av = rl._ensure_kc_mbon(b)
    app0 = float(np.abs(b.weights[pos_app]).mean())
    av0 = float(np.abs(b.weights[pos_av]).mean())
    senses = {"pheromone_conc_left": 0.5, "pheromone_conc_right": 0.5,
              "visual_target_azimuth": 5.0, "visual_target_visible": True}
    ctrl = {"yaw_torque": 0.0, "roll_torque": 0.0, "spear_thrust": 0.6}
    rl.apply_plasticity(b, senses, ctrl, -2.0,
                        schemes=tuple(MAPPING), gain_cap=0.02)
    app1 = float(np.abs(b.weights[pos_app]).mean())
    av1 = float(np.abs(b.weights[pos_av]).mean())
    print(f"  KC->MBON_app mean |w|: {app0:.4f} -> {app1:.4f} "
          f"({app1 / app0 - 1.0:+.2%})", flush=True)
    print(f"  KC->MBON_av  mean |w|: {av0:.4f} -> {av1:.4f} "
          f"({av1 / av0 - 1.0:+.2%})", flush=True)

    ok_curve = curve[-1][1] > curve[0][1] and curve[-1][2] > curve[0][2]
    ok_crash = app1 < app0 and av1 > av0
    print(f"\nVERDICT: learning_curve_improves={ok_curve} "
          f"zero_da_frozen={identical} crash_depresses_app={ok_crash}",
          flush=True)


if __name__ == "__main__":
    main()
