"""Diagnose dead pools: per-pool mean |w| vs native reference for one brain.

Read-only (never saves). Usage from project root:
  python brain_engine/diagnose_pools.py Eye3_af1ec1bb.flybrain
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import brain_package as vault
from connectome_loader import load_or_build_csr, load_or_extract_populations
from dopamine_learning import DopamineReinforcement
from experimental_wiring import experiment_arrays, normalize_experiment


def pool_mean(w, indptr, pre_ids):
    tot = []
    for pre in pre_ids:
        s, e = int(indptr[pre]), int(indptr[pre + 1])
        if e > s:
            tot.append(np.abs(w[s:e]))
    if not tot:
        return 0.0
    return float(np.concatenate(tot).mean())


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "Eye3_af1ec1bb.flybrain"
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    rec, w = vault.load_brain(path)
    gp = rec.get("generator_params", {}) or {}
    exp = normalize_experiment(gp.get("experiment"))
    indptr, indices, wbase = experiment_arrays(exp, csr, pops)
    wbase = np.ascontiguousarray(np.asarray(wbase, dtype=np.float32))
    assert len(w) == len(indices), "arity mismatch"
    rl = DopamineReinforcement(pops, base=(indptr, indices, wbase))
    ref = rl._base_means

    def row_mean(weights, pre_ids):
        return pool_mean(weights, indptr, pre_ids)

    lc11 = pops.get("visual_lc11", {})
    feat = []
    for k in ("visual_lc15", "visual_lc17", "visual_lc18"):
        p = pops.get(k, {})
        feat += list(p.get("left", [])) + list(p.get("right", []))
    pos_app, pos_av = rl._ensure_kc_mbon(
        type("B", (), {"indptr": indptr, "indices": indices,
                       "weights": w})())

    def _all(p, side=None):
        # Deduplicated: "all" already contains the sided members, and
        # duplicates would tilt the mean toward the sided rows.
        if side:
            return list(p.get(side, []))
        return sorted(set(list(p.get("left", [])) + list(p.get("right", []))
                          + list(p.get("all", []))))
    pools = [
        ("sens", list(pops["pheromone_da1"]["left"]) + list(pops["pheromone_da1"]["right"])
         + list(pops["pheromone_va1v"]["left"]) + list(pops["pheromone_va1v"]["right"])
         + list(pops["visual_lc10"]["left"]) + list(pops["visual_lc10"]["right"])
         + list(pops["visual_lc4"]["left"]) + list(pops["visual_lc4"]["right"])
         + list(pops["visual_lplc2"]["left"]) + list(pops["visual_lplc2"]["right"])
         + list(lc11.get("left", [])) + list(lc11.get("right", [])) + feat,
         ref.get("sens", 0.0), True),
        ("da1", _all(pops["pheromone_da1"]), ref.get("sens", 0.0), True),
        ("va1v", _all(pops["pheromone_va1v"]), ref.get("sens", 0.0), True),
        ("lc10", _all(pops["visual_lc10"]), ref.get("sens", 0.0), True),
        ("lc4", _all(pops["visual_lc4"]), ref.get("sens", 0.0), True),
        ("lplc2", _all(pops["visual_lplc2"]), ref.get("sens", 0.0), True),
        ("lc11", list(lc11.get("left", [])) + list(lc11.get("right", [])),
         ref.get("sens", 0.0), True),
        ("lc_feat(15/17/18)", feat, ref.get("sens", 0.0), True),
        ("kc->mbon_app", None, ref.get("kcmbon", 0.0), False),
        ("kc->mbon_av", None, ref.get("kcmbon", 0.0), False),
    ]
    print(f"[{rec.get('name')}] pool mean|w| vs native reference:")
    print("  (ref = pooled sens mean AND subset-native mean; the pooled "
          "ref misleads on small-native pools like ORNs)")
    for name, ids, r, rows in pools:
        if rows:
            cur = row_mean(w, ids)
            nat = row_mean(wbase, ids)
        else:
            pos = pos_app if name.endswith("app") else pos_av
            cur = float(np.abs(w[pos]).mean()) if len(pos) else 0.0
            nat = float(np.abs(wbase[pos]).mean()) if len(pos) else 0.0
        flag = "  <-- DUST (<10% of subset-native)" \
            if nat > 0 and cur < 0.10 * nat else ""
        print(f"  {name:18s} cur={cur:.4f} pooled={cur / r if r else 0:.3f} "
              f"subset-native={cur / nat if nat else 0:.3f}{flag}")


def census(path, steps=30):
    """Tally spikes per key pool over climb-scenario steps (finds the
    silent layer). Read-only."""
    import train_homing as th
    from brain_server import _bind_brain, _bind_codecs
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    th.TREES = []
    rec, w = vault.load_brain(path)
    brain = _bind_brain(rec, np.ascontiguousarray(
        np.asarray(w, dtype=np.float32)), csr, pops, {})
    enc, dec = _bind_codecs(rec, pops, {})
    pools = {
        "KC": list(pops.get("mushroom_body_kc", [])),
        "MBON_app": list(pops.get("mbon_app", {}).get("all", [])),
        "MBON_av": list(pops.get("mbon_av", {}).get("all", [])),
        "LC11": list(pops.get("visual_lc11", {}).get("all", [])),
        "LC10": list(pops.get("visual_lc10", {}).get("all", [])),
        "DA1": list(pops.get("pheromone_da1", {}).get("all", [])),
        "MNxm": list(pops.get("motor_mouth", {}).get("all", [])),
        "DN": list(pops.get("descending_all", {}).get("all", [])),
    }
    sets = {k: set(v) for k, v in pools.items()}
    counts = {k: 0 for k in pools}
    fly = th.KinematicFly(x=-14.0, y=7.0, z=0.0, heading_rad=0.0)
    tgt = th.KinematicFly(x=15.0, y=14.0, z=2.0)
    _, prev_dist = th.compute_agent_senses(fly, tgt)
    for _ in range(steps):
        senses, dist = th.compute_agent_senses(fly, tgt, prev_dist=prev_dist)
        stim = enc.encode(senses)
        spikes = brain.integrate_50ms(stim)
        for s in spikes:
            for k, st in sets.items():
                if int(s) in st:
                    counts[k] += 1
        ctrl = dec.decode(spikes, sensory_hint=senses)
        th.apply_arena_controls(fly, ctrl, senses, dist, dt=0.05)
        prev_dist = dist
    print(f"[{rec.get('name')}] spikes over {steps} climb steps "
          f"(pool size -> total):")
    for k in pools:
        print(f"  {k:9s} n={len(pools[k]):5d} spikes={counts[k]:6d} "
              f"({counts[k] / max(len(pools[k]), 1) / steps:.2f}/cell/step)")


def subset_ratios(weights, indptr, pops, wbasis):
    """Subset-native ratios for every driver pool (the collapse census)."""
    from dopamine_learning import DopamineReinforcement
    out = {}

    def _all(key):
        p = pops.get(key, {})
        return sorted(set(list(p.get("left", [])) + list(p.get("right", []))
                          + list(p.get("all", []))))

    feat = []
    for key in ("visual_lc15", "visual_lc17", "visual_lc18"):
        feat += _all(key)
    lc11 = pops.get("visual_lc11", {})
    groups = {
        "da1": _all("pheromone_da1"),
        "va1v": _all("pheromone_va1v"),
        "lc10": _all("visual_lc10"),
        "lc4": _all("visual_lc4"),
        "lplc2": _all("visual_lplc2"),
        "lc11": sorted(set(list(lc11.get("left", [])) + list(lc11.get("right", [])))),
        "lcfeat": sorted(set(feat)),
    }
    for name, ids in groups.items():
        pos = DopamineReinforcement._row_positions(np.asarray(indptr), ids)
        if len(pos) == 0:
            continue
        cur = float(np.abs(weights[pos]).mean())
        nat = float(np.abs(wbasis[pos]).mean())
        out[name] = cur / nat if nat > 0 else 1.0
    return out


def sweep():
    """Vault-wide collapse census: every brain, every driver pool,
    flags dust (<0.10) and weak (<0.20). Read-only."""
    import glob
    from experimental_wiring import normalize_experiment, experiment_arrays
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    for path in sorted(glob.glob(os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "brains", "*.flybrain"))):
        try:
            rec, w = vault.load_brain(path)
        except Exception as e:
            print(f"{os.path.basename(path):32s} UNREADABLE: {e}")
            continue
        gp = rec.get("generator_params", {}) or {}
        exp = normalize_experiment(gp.get("experiment"))
        try:
            indptr, indices, wbasis = experiment_arrays(exp, csr, pops)
        except Exception as e:
            print(f"{os.path.basename(path):32s} WIRING ERROR: {e}")
            continue
        if len(w) != len(indices):
            print(f"{os.path.basename(path):32s} arity mismatch")
            continue
        w = np.ascontiguousarray(np.asarray(w, dtype=np.float32))
        wbasis = np.ascontiguousarray(np.asarray(wbasis, dtype=np.float32))
        ratios = subset_ratios(w, indptr, pops, wbasis)
        dust = sorted(k for k, v in ratios.items() if v < 0.10)
        weak = sorted(k for k, v in ratios.items() if 0.10 <= v < 0.20)
        detail = " ".join(f"{k}={ratios[k]:.2f}" for k in sorted(ratios))
        if dust:
            print(f"{rec.get('name', '?'):12s} DUST {dust} | {detail}")
        elif weak:
            print(f"{rec.get('name', '?'):12s} weak {weak} | {detail}")
        else:
            print(f"{rec.get('name', '?'):12s} ok")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--census":
        census(sys.argv[1])
    elif len(sys.argv) > 1 and sys.argv[1] == "--sweep":
        sweep()
    else:
        main()
