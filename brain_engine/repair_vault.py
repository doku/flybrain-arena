"""One-shot vault repair: pin every brain's plastic pools to reference
magnitudes (fixes localized dopamine runaway and global drift). Vault
files are snapshotted first; saves keep .bak. Run from the project root:
python brain_engine\repair_vault.py
"""
import os
import sys
import glob
import shutil
import tempfile
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from dopamine_learning import DopamineReinforcement
import brain_package as vault
from experimental_wiring import experiment_arrays


def _norm_experiment(value):
    if value is None:
        return None
    s = str(value).strip()
    return None if s.lower() in ("", "none") else s


def pool_mean(w, indptr, pre_ids):
    tot_n, tot_s = 0, 0.0
    for pre in pre_ids:
        s, e = int(indptr[pre]), int(indptr[pre + 1])
        if e > s:
            tot_s += float(np.abs(w[s:e]).sum())
            tot_n += (e - s)
    return tot_s / max(tot_n, 1)


def main(dust_only=False, runaway_only=False):
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    snap = tempfile.mkdtemp(prefix="vault_snapshot_")
    for p in sorted(glob.glob(vault.VAULT_DIR + "/*.flybrain")):
        shutil.copyfile(p, os.path.join(snap, os.path.basename(p)))
    print(f"[Repair] Snapshotted vault to {snap}")
    if dust_only:
        print("[Repair] DUST-ONLY mode: no pinning; pools under 10% of "
              "reference get native values back, everything else untouched.")
    if runaway_only:
        print("[Repair] RUNAWAY-ONLY mode: pin pools over 2x reference "
              "(ratio-preserving), leave everything else exactly as learned.")
    rl = DopamineReinforcement(
        pops, base=(csr.indptr, csr.indices,
                    np.ascontiguousarray(csr.data, dtype=np.float32)))
    sens_ids = (pops["pheromone_da1"]["all"] + pops["pheromone_va1v"]["all"]
                + pops["visual_lc10"]["all"] + pops["visual_lc4"]["all"]
                + pops["visual_lplc2"]["all"]
                + pops.get("visual_lc11", {}).get("all", [])
                + pops.get("visual_lc15", {}).get("all", [])
                + pops.get("visual_lc17", {}).get("all", [])
                + pops.get("visual_lc18", {}).get("all", []))
    jo_ids = pops["gyro_jo"]["all"]
    # Native reference weights per wiring (for dust restoration below).
    wbase_cache = {}
    DUST_ABS = 0.02  # below this a pool holds no learnable ratios, only dust
    from sensory_motor import is_legacy_record
    for path in sorted(glob.glob(vault.VAULT_DIR + "/*.flybrain")):
        rec, w = vault.load_brain(path)
        if is_legacy_record(rec) and not dust_only and not runaway_only:
            print(f"[Repair] SKIP {os.path.basename(path)}: legacy "
                  f"pre-mapping brain (pinning would rewrite its regime)")
            continue
        exp = _norm_experiment((rec.get("generator_params", {}) or {}).get("experiment"))
        # Native wiring per brain (overlays change arity; wrapping in the
        # wrong structure would misalign every row).
        indptr, indices, _w = experiment_arrays(exp, csr, pops)
        if len(w) != len(indices):
            print(f"[Repair] SKIP {os.path.basename(path)}: arity {len(w)} != {len(indices)}")
            continue
        if exp not in wbase_cache:
            _i, _j, wb = experiment_arrays(exp, csr, pops)
            wbase_cache[exp] = np.ascontiguousarray(np.asarray(wb, dtype=np.float32))
        wbase = wbase_cache[exp]
        brain = FlyBrain(indptr, indices,
                         np.ascontiguousarray(np.asarray(w, dtype=np.float32)))
        before = pool_mean(brain.weights, brain.indptr, sens_ids)
        if not dust_only:
            # Runaway-only mode pins >2x pools for every brain this run
            # (ratio-preserving); default full mode pins non-legacy brains.
            rl.pin_gains(brain, legacy=runaway_only)
        # Dust restoration: pools whose mean is numerical dust carry no
        # learnable ratios (rescaling only amplifies noise), so copy the
        # native reference values back. Mild suppression is left alone.
        n = len(indptr) - 1
        brows = np.repeat(np.arange(n, dtype=np.int32),
                          np.diff(np.asarray(indptr)).astype(np.int64))
        dn_ids = np.concatenate([
            np.asarray(pops["descending_all"].get("left", []), dtype=np.int32),
            np.asarray(pops["descending_all"].get("right", []), dtype=np.int32)])
        is_dn = np.zeros(n, dtype=bool)
        if len(dn_ids):
            is_dn[dn_ids] = True
        post = np.asarray(indices)
        dn_pos = np.where(is_dn[post])[0].astype(np.int32)
        # Per-side steering channels: a dead-left/hot-right readout hides
        # inside the combined dn mean, so dust-only mode checks each side
        # separately (a one-sided dead channel is exactly the aimless-
        # circling pathology).
        dn_l_ids = np.asarray(pops["descending_all"].get("left", []),
                              dtype=np.int32)
        dn_r_ids = np.asarray(pops["descending_all"].get("right", []),
                              dtype=np.int32)
        is_dn_l = np.zeros(n, dtype=bool)
        is_dn_r = np.zeros(n, dtype=bool)
        if len(dn_l_ids):
            is_dn_l[dn_l_ids] = True
        if len(dn_r_ids):
            is_dn_r[dn_r_ids] = True
        dn_l_pos = np.where(is_dn_l[post])[0].astype(np.int32)
        dn_r_pos = np.where(is_dn_r[post])[0].astype(np.int32)
        kc_all = np.asarray(pops["mushroom_body_kc"], dtype=np.int32)
        is_kc = np.zeros(n, dtype=bool)
        if len(kc_all):
            is_kc[kc_all] = True
        mbon_all = np.concatenate([
            np.asarray(pops.get("mbon_app", {}).get("all", []), dtype=np.int32),
            np.asarray(pops.get("mbon_av", {}).get("all", []), dtype=np.int32)])
        is_mbon = np.zeros(n, dtype=bool)
        if len(mbon_all):
            is_mbon[mbon_all] = True
        kc_pos = np.where(is_kc[brows] & is_mbon[post])[0].astype(np.int32)
        del brows
        dusted = []
        # Relative dust criterion in dust-only mode (absolute DUST_ABS
        # misses pools like a 0.1-vs-8.1 steering channel: numerically
        # dead yet above the absolute floor).
        pool_base = {"sens": rl._base_means.get("sens", 0.0),
                     "dn": rl._base_means.get("dn_in", 0.0),
                     "dn_left": rl._base_means.get("dn_in", 0.0),
                     "dn_right": rl._base_means.get("dn_in", 0.0)}
        sens_l_ids = (pops["pheromone_da1"]["left"] + pops["pheromone_va1v"]["left"]
                      + pops["visual_lc10"]["left"] + pops["visual_lc4"]["left"]
                      + pops["visual_lplc2"]["left"]
                      + pops.get("visual_lc11", {}).get("left", [])
                      + pops.get("visual_lc15", {}).get("left", [])
                      + pops.get("visual_lc17", {}).get("left", [])
                      + pops.get("visual_lc18", {}).get("left", []))
        sens_r_ids = (pops["pheromone_da1"]["right"] + pops["pheromone_va1v"]["right"]
                      + pops["visual_lc10"]["right"] + pops["visual_lc4"]["right"]
                      + pops["visual_lplc2"]["right"]
                      + pops.get("visual_lc11", {}).get("right", [])
                      + pops.get("visual_lc15", {}).get("right", [])
                      + pops.get("visual_lc17", {}).get("right", [])
                      + pops.get("visual_lc18", {}).get("right", []))
        pool_base["sens_left"] = pool_base["sens"]
        pool_base["sens_right"] = pool_base["sens"]
        pools = [("sens", sens_ids), ("jo", jo_ids), ("dn", None),
                 ("kcmbon", None)]
        if dust_only:
            # Dust-only checks each side separately: one-sided dead
            # channels (the aimless-circling pathology) hide inside
            # combined means. 10% threshold sits in the measured gap
            # between dead (<7%) and weak-but-alive (>30%) pools.
            pools = [("sens_left", sens_l_ids), ("sens_right", sens_r_ids),
                     ("dn_left", None), ("dn_right", None)]
        for name, ids in pools:
            if dust_only and name in ("jo", "kcmbon"):
                continue
            if name == "dn":
                pos = dn_pos
            elif name == "dn_left":
                pos = dn_l_pos
            elif name == "dn_right":
                pos = dn_r_pos
            elif name == "sens_left":
                pos = DopamineReinforcement._row_positions(
                    np.asarray(indptr), sens_l_ids)
            elif name == "sens_right":
                pos = DopamineReinforcement._row_positions(
                    np.asarray(indptr), sens_r_ids)
            elif name == "kcmbon":
                pos = kc_pos
            else:
                tot = []
                for pre in ids:
                    s, e = int(indptr[pre]), int(indptr[pre + 1])
                    if e > s:
                        tot.append(np.arange(s, e))
                pos = np.concatenate(tot).astype(np.int32) if tot else np.array([], dtype=np.int32)
            if len(pos) == 0:
                continue
            cur = float(np.abs(brain.weights[pos]).mean())
            is_dust = cur < DUST_ABS if not dust_only else (
                pool_base.get(name, 0.0) > 0.0
                and cur < 0.10 * pool_base[name])
            if is_dust:
                brain.weights[pos] = wbase[pos]
                dusted.append(f"{name} {cur:.1e}->base")
        if dusted:
            print(f"[Repair] {os.path.basename(path):28s} dust-restored: {', '.join(dusted)}")
            if not dust_only:
                rl.pin_gains(brain, legacy=runaway_only)
        after = pool_mean(brain.weights, brain.indptr, sens_ids)
        vault.save_brain(rec, brain.weights, backup=True)
        print(f"[Repair] {os.path.basename(path):28s} exp={str(exp):16s} "
              f"sens {before:8.1f} -> {after:6.2f} (base {rl._base_means['sens']:.2f})")
    print("[Repair] Done. Snapshots + .bak files retained for rollback.")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Vault repair (snapshots first)")
    ap.add_argument("--dust-only", action="store_true",
                    help="only restore numerical-dust pools to reference, "
                         "never rescale anything else")
    ap.add_argument("--runaway-only", action="store_true",
                    help="pin pools over 2x reference (ratio-preserving) "
                         "for every brain, leave everything else as learned")
    args = ap.parse_args()
    main(dust_only=args.dust_only, runaway_only=args.runaway_only)
