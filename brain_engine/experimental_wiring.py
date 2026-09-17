import os
import numpy as np
from scipy import sparse

# Experimental synaptic wirings injected on top of the frozen MaleCNS CSR
# baseline. Each experiment is a small, deterministic set of ADDED edges
# (presynaptic neuron, postsynaptic neuron, weight) tuned so that sensory
# pools reach descending motor readouts the base connectome doesn't route
# strongly. Brains built from an experiment use their own indptr/indices/data
# (arity changes), so checkpoints for experimental brains are named
# ``trained_homing_<variant>__exp_<name>.npz`` and files always keep their
# native arity end-to-end. BATTLES may freely mix wirings: the server runs
# each fighter on its native structure. Keep base CSR + base checkpoints
# untouched.

EXPERIMENTS = {}


def _register(name):
    def deco(fn):
        EXPERIMENTS[name] = fn
        return fn
    return deco


@_register("lplc2_contra_dn")
def lplc2_contra_dn(pops, fanout=16, weight=260.0):
    """Contralateral LPLC2 -> DN steering.

    Tree loom on the LEFT fires LPLC2-L (the arena/trainer encoders pool that
    by side); this wiring sends every LPLC2-L cell to a spread of RIGHT
    descending neurons and every LPLC2-R cell to LEFT DNs. Because the motor
    readout steers by DN-left vs DN-right population counts, a left tree now
    drives DN-R -> yaw right -> AWAY from the tree, and vice versa. This is
    the pathway the base connectome does NOT have: its own LPLC2->DN edges
    are nearly all ipsilateral (LPLC2-L->DN-L, ~11 mean weight) which would
    turn a fly INTO the looming side.

    Edges are excitatory (+weight). fanout is how many contralateral DNs each
    LPLC2 cell innervates; weight is tuned by phase-0 probe vs the DN readout
    sensitivity (dnR-dnL ~ 9 bias, tanh /15).
    """
    lp_l = np.asarray(pops["visual_lplc2"]["left"], dtype=np.int64)
    lp_r = np.asarray(pops["visual_lplc2"]["right"], dtype=np.int64)
    dn_r = np.asarray(pops["descending_all"]["right"], dtype=np.int64)
    dn_l = np.asarray(pops["descending_all"]["left"], dtype=np.int64)
    rng = np.random.default_rng(0)  # deterministic wiring across runs
    pre, post, w = [], [], []
    for src, tgt in ((lp_l, dn_r), (lp_r, dn_l)):
        for s in src:
            picks = rng.choice(tgt, size=min(fanout, len(tgt)), replace=False)
            pre.append(np.full(len(picks), s))
            post.append(picks)
            w.append(np.full(len(picks), float(weight)))
    if not pre:
        return None
    return (np.concatenate(pre).astype(np.int32),
            np.concatenate(post).astype(np.int32),
            np.concatenate(w).astype(np.float32))


@_register("retina_wide")
def retina_wide(pops, fanout=6, weight=200.0):
    """Ipsilateral feature->DN assist for the retina scheme.

    Lobula feature pools (LC11 presence/size, LC15/17/18 loom) barely
    recruit descending neurons through base wiring (measured ~0 DN spikes
    per volley vs ~36/tick odor-driven), so the panoramic field would be
    mute downstream. This overlay gives every LC11/15/17/18 cell a small
    excitatory fanout to SAME-side DNs: left-field features drive DN-L
    (yaw left, toward the object), right-field DN-R. Same-side keeps
    pursuit toward (contrast the contra tree-avoidance wiring), and the
    overlay is small enough that the standard DN readout and dopamine
    keep working on top.
    """
    pre, post, w = [], [], []
    rng = np.random.default_rng(7)  # deterministic wiring across runs
    dn_l = np.asarray(pops["descending_all"]["left"], dtype=np.int64)
    dn_r = np.asarray(pops["descending_all"]["right"], dtype=np.int64)
    for key in ("visual_lc11", "visual_lc15", "visual_lc17", "visual_lc18"):
        pool = pops.get(key, {})
        for src, tgt in ((np.asarray(pool.get("left", []), dtype=np.int64), dn_l),
                         (np.asarray(pool.get("right", []), dtype=np.int64), dn_r)):
            if len(src) == 0 or len(tgt) == 0:
                continue
            for s in src:
                picks = rng.choice(tgt, size=min(fanout, len(tgt)), replace=False)
                pre.append(np.full(len(picks), s))
                post.append(picks)
                w.append(np.full(len(picks), float(weight)))
    if not pre:
        return None
    return (np.concatenate(pre).astype(np.int32),
            np.concatenate(post).astype(np.int32),
            np.concatenate(w).astype(np.float32))


def apply_overlay(csr, pre, post, w):
    """Merges added edges into the base CSR. Returns contiguous int32
    indptr/indices + float32 data ready for FlyBrain."""
    if pre is None or len(pre) == 0:
        return (np.ascontiguousarray(csr.indptr, dtype=np.int32),
                np.ascontiguousarray(csr.indices, dtype=np.int32),
                np.ascontiguousarray(csr.data, dtype=np.float32))
    overlay = sparse.csr_matrix(
        (w, (pre.astype(np.int32), post.astype(np.int32))), shape=csr.shape)
    merged = csr + overlay  # overlapping (pre, post) entries sum in place
    return (np.ascontiguousarray(merged.indptr, dtype=np.int32),
            np.ascontiguousarray(merged.indices, dtype=np.int32),
            np.ascontiguousarray(merged.data, dtype=np.float32))


def experiment_arrays(experiment, csr, pops):
    """Returns (indptr, indices, data) for an experiment, or base CSR arrays
    when experiment is None/'none'. Unknown experiments raise.

    This is the single funnel every FlyBrain constructor should use so the
    arity of a brain always matches its checkpoint namespace."""
    if experiment is None or str(experiment).strip().lower() in ("", "none"):
        return (np.ascontiguousarray(csr.indptr, dtype=np.int32),
                np.ascontiguousarray(csr.indices, dtype=np.int32),
                np.ascontiguousarray(csr.data, dtype=np.float32))
    name = str(experiment).strip()
    if name not in EXPERIMENTS:
        raise ValueError(
            f"Unknown experimental wiring '{name}'. Available: {sorted(EXPERIMENTS)}")
    pre, post, w = EXPERIMENTS[name](pops)
    print(f"[ExpWiring] {name}: injecting {len(pre):,} edges "
          f"(fanout per cell, weight {w[0]:.0f})")
    return apply_overlay(csr, pre, post, w)


def experiment_suffix(experiment):
    """Filename suffix for experiment checkpoints (empty for base runs)."""
    if experiment is None or str(experiment).strip().lower() in ("", "none"):
        return ""
    return f"__exp_{str(experiment).strip()}"