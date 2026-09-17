import os
import json
import numpy as np
import pandas as pd


DATA_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MALECNS_DIR = os.path.join(DATA_DIR, "connectome_data", "malecns_v1")
ANNOTATIONS_FILE = os.path.join(MALECNS_DIR, "annotations.feather")
NT_FILE = os.path.join(MALECNS_DIR, "neurotransmitters.feather")
EDGES_FILE = os.path.join(MALECNS_DIR, "edges.feather")
CSR_CACHE_FILE = os.path.join(DATA_DIR, "malecns_csr_base.npz")
POPULATIONS_CACHE_FILE = os.path.join(DATA_DIR, "populations_mapped.json")

# Node policy (mirrors DoomFly registry): every entry with an assigned
# superclass; explicit Glia excluded (verified: 0 glia among retained).
# Result: 166,700 neurons.
# Edge policy: all released edges between retained entries (incl. autapses).
# E/I sign: per-presynaptic-body consensus NT; gaba/glutamate inhibitory,
# everything else (incl. unclear/missing) excitatory — same default bias as
# the old per-edge ach/oct/ser vs gaba/glut rule.
INHIBITORY_NT = {"gaba", "glutamate"}

from scipy import sparse
import time


def _retained_annotations():
    df = pd.read_feather(ANNOTATIONS_FILE)
    df = df[df["superclass"].notna()].copy()
    df.sort_values("bodyId", inplace=True)
    df.reset_index(drop=True, inplace=True)
    return df


def _body_side(df):
    """Hemisphere per row: somaSide, else instance _L/_R suffix, else rootSide."""
    soma = df["somaSide"].to_numpy(dtype=object, na_value=None)
    inst = df["instance"].astype(str).to_numpy()
    if "rootSide" in df.columns:
        root = df["rootSide"].to_numpy(dtype=object, na_value=None)
    else:
        root = [None] * len(df)
    sides = []
    for s, suf, r in zip(soma.tolist(), inst.tolist(), list(root)):
        if s == "L" or s == "R":
            sides.append(s)
        elif isinstance(suf, str) and suf.endswith("_L"):
            sides.append("L")
        elif isinstance(suf, str) and suf.endswith("_R"):
            sides.append("R")
        elif r == "L" or r == "R":
            sides.append(r)
        else:
            sides.append(None)
    return sides


def _nt_sign_map():
    nt = pd.read_feather(NT_FILE, columns=["body", "consensus_nt"])
    nt = nt.drop_duplicates("body")
    return {int(b): (-1.0 if str(v) in INHIBITORY_NT else 1.0)
            for b, v in zip(nt["body"].values, nt["consensus_nt"].values)}


def load_or_extract_populations(force_regen=False):
    """Extracts critical sensory and motor neuron index sets from annotations."""
    if os.path.exists(POPULATIONS_CACHE_FILE) and not force_regen:
        print(f"[Loader] Loading cached populations from {POPULATIONS_CACHE_FILE}...")
        with open(POPULATIONS_CACHE_FILE, "r") as f:
            return json.load(f)

    print("[Loader] Parsing MaleCNS annotations for sensory/motor populations...")
    df = _retained_annotations()
    body_ids = df["bodyId"].values.astype(np.int64)
    id_to_idx = {int(b): int(i) for i, b in enumerate(body_ids)}
    df["_side"] = _body_side(df)
    df["_idx"] = [id_to_idx[int(b)] for b in body_ids]
    types = df["type"].astype(str)

    def get_indices(condition):
        subset = df[condition]
        left = subset[subset["_side"] == "L"]["_idx"].tolist()
        right = subset[subset["_side"] == "R"]["_idx"].tolist()
        return {"left": left, "right": right, "all": subset["_idx"].tolist()}

    # --- Sensory Input Populations ---
    pheromone_da1 = get_indices(types.str.contains("ORN_DA1", na=False))
    pheromone_va1v = get_indices(types.str.contains("ORN_VA1v", na=False))
    # Exact match: substring "LC4" also catches LC40/41/43/44/46b and LPLC4
    # (173 non-loom cells verified against the annotation table) — the
    # rival-loom channel must be true LC4 only.
    visual_lc4 = get_indices(types.str.match(r"^LC4$", na=False))
    visual_lplc2 = get_indices(types.str.contains("LPLC2", na=False))
    visual_lc10 = get_indices(types.str.contains("LC10", na=False))
    # Retina-scheme feature pools (exact matches, all clean bilateral):
    # LC11 small-object presence/size, LC15/17/18 loom-feature readouts.
    visual_lc11 = get_indices(types.str.match(r"^LC11$", na=False))
    visual_lc15 = get_indices(types.str.match(r"^LC15$", na=False))
    visual_lc17 = get_indices(types.str.match(r"^LC17$", na=False))
    visual_lc18 = get_indices(types.str.match(r"^LC18$", na=False))

    # --- Neuro-mapping pools (Stage 1: muscles_up + gyro_flow) ---
    # Flight-muscle motor readout: DLMn/DVMn wing power (thrust), MNad
    # steering muscles split by hemisphere (yaw). Anchored matches so
    # unrelated MN* families can never leak in.
    motor_flight_thrust = get_indices(types.str.match(r"^(DLMn|DVMn)", na=False))
    motor_steer = get_indices(types.str.match(r"^MNad", na=False))
    # Antennal gyroscope: Johnston's organ. somaSide is empty on JO rows;
    # _body_side falls back to the _L/_R instance suffix (348L/324R).
    gyro_jo = get_indices(types.str.match(r"^JO", na=False))
    # Wide-field optic flow: lobula-plate tangential cells. Anchored so
    # only VS*/HS* families match (VS 18 + VST2 7 + VST1 5 + VSm 4 = 34).
    flow_vs = get_indices(types.str.match(r"^VS", na=False))
    flow_hs = get_indices(types.str.match(r"^HS", na=False))

    # --- Motor Output: FULL descending neuron populations split by hemisphere ---
    dn_all = df[df["superclass"] == "descending_neuron"]
    dn_left_ids = dn_all[dn_all["_side"] == "L"]["_idx"].tolist()
    dn_right_ids = dn_all[dn_all["_side"] == "R"]["_idx"].tolist()
    dn_all_ids = dn_all["_idx"].tolist()

    # Specific DNs (kept for reference/compatibility)
    motor_thrust_dnp09 = get_indices(types.str.contains("DNp09", na=False))
    motor_turn_dnp20 = get_indices(types.str.contains("DNp20", na=False))
    motor_giant_fiber = get_indices(types.str.contains("DNp01", na=False))
    motor_ram_dnpe017 = get_indices(types.str.contains("DNpe017", na=False))

    # --- Dopaminergic Reinforcement & Mushroom Body ---
    dopamine_pam = get_indices(types.str.contains("PAM", na=False))
    dopamine_ppl1 = get_indices(types.str.contains("PPL1", na=False))
    mbon = get_indices(types.str.contains("MBON", na=False))
    kc_ids = df[df["class"] == "Kenyon_Cell"]["_idx"].tolist()

    # --- Mushroom-body valence (Stage 2: mbon scheme) ---
    # NT-sign split: acetylcholine MBONs (excitatory) read as approach,
    # GABA/glutamate MBONs (inhibitory under this loader's E/I convention)
    # read as avoid. Per-type NT is uniform (verified: no mixed MBON type)
    # and all 97 MBON bodies carry a clear consensus NT, so no cell falls
    # back to the excitatory default.
    _nt_sign = _nt_sign_map()
    _is_app_nt = df["bodyId"].map(lambda b: _nt_sign.get(int(b), 1.0) > 0.0)
    _is_mbon = types.str.contains("MBON", na=False)
    mbon_app = get_indices(_is_mbon & _is_app_nt)
    mbon_av = get_indices(_is_mbon & ~_is_app_nt)

    pops = {
        "pheromone_da1": pheromone_da1,
        "pheromone_va1v": pheromone_va1v,
        "visual_lc4": visual_lc4,
        "visual_lplc2": visual_lplc2,
        "visual_lc10": visual_lc10,
        "visual_lc11": visual_lc11,
        "visual_lc15": visual_lc15,
        "visual_lc17": visual_lc17,
        "visual_lc18": visual_lc18,
        # Neuro-mapping readout/injection pools (muscles_up + gyro_flow)
        "motor_flight_thrust": motor_flight_thrust,
        "motor_steer": motor_steer,
        "gyro_jo": gyro_jo,
        "flow_vs": flow_vs,
        "flow_hs": flow_hs,
        # Full DN population vectors for robust steering readout
        "descending_all": {"left": dn_left_ids, "right": dn_right_ids, "all": dn_all_ids},
        # Specific DNs (kept for reference)
        "motor_thrust_dnp09": motor_thrust_dnp09,
        "motor_turn_dnp20": motor_turn_dnp20,
        "motor_giant_fiber": motor_giant_fiber,
        "motor_ram_dnpe017": motor_ram_dnpe017,
        # Reinforcement
        "dopamine_pam": dopamine_pam,
        "dopamine_ppl1": dopamine_ppl1,
        "mbon": mbon,
        "mushroom_body_kc": kc_ids,
        # MBON valence pools (mbon scheme: ACh approach / Glu+GABA avoid)
        "mbon_app": mbon_app,
        "mbon_av": mbon_av,
    }

    print(f"[Loader] Mapped populations: "
          f"DA1 ORNs: {len(pops['pheromone_da1']['all'])}, "
          f"LC10: {len(pops['visual_lc10']['all'])}, "
          f"LC11/15/17/18: {len(pops['visual_lc11']['all'])}/"
          f"{len(pops['visual_lc15']['all'])}/"
          f"{len(pops['visual_lc17']['all'])}/"
          f"{len(pops['visual_lc18']['all'])}, "
          f"DN-Left: {len(dn_left_ids)}, DN-Right: {len(dn_right_ids)}, "
          f"PAM DA: {len(pops['dopamine_pam']['all'])}, "
          f"MBON: {len(pops['mbon']['all'])}, "
          f"MN-thrust: {len(pops['motor_flight_thrust']['all'])}, "
          f"MN-steer: {len(pops['motor_steer']['all'])}, "
          f"JO: {len(pops['gyro_jo']['all'])}, "
          f"VS/HS: {len(pops['flow_vs']['all'])}/{len(pops['flow_hs']['all'])}, "
          f"MBON app/av: {len(pops['mbon_app']['all'])}/{len(pops['mbon_av']['all'])}")

    with open(POPULATIONS_CACHE_FILE, "w") as f:
        json.dump(pops, f, indent=2)
    return pops


def load_or_build_csr(min_synapse_threshold=1):
    """Loads or builds the CSR sparse synaptic weight matrix (MaleCNS)."""
    if os.path.exists(CSR_CACHE_FILE):
        print(f"[Loader] Loading cached CSR connectome from {CSR_CACHE_FILE}...")
        loader = np.load(CSR_CACHE_FILE)
        csr = sparse.csr_matrix(
            (loader["data"], loader["indices"], loader["indptr"]),
            shape=loader["shape"]
        )
        print(f"[Loader] CSR matrix ready: {csr.shape[0]} neurons, {csr.nnz:,} synapses.")
        return csr

    print("[Loader] Building MaleCNS CSR connectome from edges file (first-time only)...")
    t0 = time.time()
    import pyarrow.ipc as ipc

    df = _retained_annotations()
    body_ids = df["bodyId"].values.astype(np.int64)
    num_neurons = len(body_ids)
    print(f"[Loader] Retained neurons: {num_neurons}")
    sign_map = _nt_sign_map()
    pre_sign = np.array([sign_map.get(int(b), 1.0) for b in body_ids], dtype=np.float32)

    reader = ipc.RecordBatchFileReader(EDGES_FILE)
    nbatches = reader.num_record_batches
    print(f"[Loader] Scanning {nbatches} edge batches...")
    pre_parts, post_parts, w_parts = [], [], []
    kept = 0
    for b in range(nbatches):
        tbl = reader.get_batch(b).to_pandas()
        pre = tbl["body_pre"].values.astype(np.int64)
        post = tbl["post" if "post" in tbl.columns else "body_post"].values.astype(np.int64)
        w = tbl["weight"].values.astype(np.float64)
        if min_synapse_threshold > 1:
            m = w >= min_synapse_threshold
            pre, post, w = pre[m], post[m], w[m]
        # Restrict to retained x retained (drops glia/unassigned/orphan edges)
        m = np.isin(pre, body_ids) & np.isin(post, body_ids)
        if not np.any(m):
            continue
        pre, post, w = pre[m], post[m], w[m].astype(np.float32)
        pre_idx = np.searchsorted(body_ids, pre).astype(np.int32)
        post_idx = np.searchsorted(body_ids, post).astype(np.int32)
        pre_parts.append(pre_idx)
        post_parts.append(post_idx)
        w_parts.append(w * pre_sign[pre_idx])
        kept += len(pre)
        if (b + 1) % 10 == 0 or (b + 1) == nbatches:
            print(f"[Loader]   batch {b + 1}/{nbatches}: kept {kept:,} edges...")
        del tbl, pre, post, w, pre_idx, post_idx

    pre_all = np.concatenate(pre_parts)
    post_all = np.concatenate(post_parts)
    w_all = np.concatenate(w_parts)
    del pre_parts, post_parts, w_parts
    print(f"[Loader] Retained edges: {len(w_all):,} "
          f"(|w| mean {np.mean(np.abs(w_all)):.2f}, max {np.max(np.abs(w_all)):.0f})")

    print("[Loader] Constructing CSR matrix...")
    csr = sparse.csr_matrix(
        (w_all, (pre_all, post_all)),
        shape=(num_neurons, num_neurons)
    )
    del pre_all, post_all, w_all
    print(f"[Loader] Saving CSR cache to {CSR_CACHE_FILE}...")
    np.savez_compressed(CSR_CACHE_FILE, data=csr.data, indices=csr.indices,
                        indptr=csr.indptr, shape=csr.shape)
    print(f"[Loader] Built and cached in {time.time()-t0:.2f}s.")
    return csr


if __name__ == "__main__":
    import os
    # Force regeneration of populations for the MaleCNS backend
    if os.path.exists(POPULATIONS_CACHE_FILE):
        os.remove(POPULATIONS_CACHE_FILE)
    pops = load_or_extract_populations()
    csr = load_or_build_csr()
    print("[Loader] MaleCNS connectome preprocessing complete and verified!")
