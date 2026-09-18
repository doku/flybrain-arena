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

# Conflict priority for additive mixes (higher wins on exact-edge weight
# clashes; ties reject loudly). Order: lplc2_contra_dn < retina_wide <
# spear_lunge. Shared downstream pools (e.g. DNs driven by both contra and
# wide wirings) are NOT conflicts — only identical (pre, post) edges with
# different weights clash.
WIRING_PRIORITY = {
    "lplc2_contra_dn": 10,
    "retina_wide": 20,
    "spear_lunge": 30,
}

# One-line descriptions for the menu configurator.
WIRING_DESCRIPTIONS = {
    "lplc2_contra_dn": "Tree avoidance: LPLC2 loom steers AWAY (contralateral DNs).",
    "retina_wide": "Visual pursuit assist: LC features drive same-side DNs.",
    "spear_lunge": "Spear attack: frontal LC volleys drive mouth motor neurons.",
}


def _register(name):
    def deco(fn):
        EXPERIMENTS[name] = fn
        WIRING_PRIORITY.setdefault(name, 0)
        return fn
    return deco


def normalize_experiment(value):
    """Canonical wiring key: None for base, else a sorted tuple of names.

    Accepts None, 'base'/'none'/'', a single name, a '+'- or ','-joined
    string, or a list/tuple of any of those. Unknown names raise (never
    silently degrade). 'base' inside a mix is ignored (base = absence).
    """
    if value is None:
        return None
    items = value if isinstance(value, (list, tuple)) else [value]
    names = set()
    for item in items:
        for part in str(item).replace(",", "+").split("+"):
            s = part.strip()
            if not s or s.lower() in ("none", "base"):
                continue
            if s not in EXPERIMENTS:
                raise ValueError(
                    f"Unknown experimental wiring '{s}'. "
                    f"Available: {sorted(EXPERIMENTS)}")
            names.add(s)
    if not names:
        return None
    return tuple(sorted(names))


def mix_label(experiment):
    """Human/canonical label: 'base' or 'a+b' (sorted)."""
    mix = normalize_experiment(experiment)
    if mix is None:
        return "base"
    return "+".join(mix)


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


@_register("spear_lunge")
def spear_lunge(pops, fanout=3, weight=200.0):
    """Mouth-motor drive for the spear attack.

    MNxm (maxillary mouthpart motor neurons, 3L/3R) are centrally
    near-silent (0-7 weak inputs each), so nothing ever reads them.
    This overlay routes lobula feature volleys (LC11 presence/size,
    LC15/17/18 loom) onto all six MNxm cells, giving the decoder a
    genuine mouth-motor signal to fire the spear thrust from. Aimed in
    the decoder (visible + frontal gate), so rear tracking never lunges.
    """
    pre, post, w = [], [], []
    rng = np.random.default_rng(21)  # deterministic wiring across runs
    mx = np.asarray(pops.get("motor_mouth", {}).get("all", []), dtype=np.int64)
    if len(mx) == 0:
        return None
    drivers = []
    for key in ("visual_lc11", "visual_lc15", "visual_lc17", "visual_lc18"):
        pool = pops.get(key, {})
        drivers += list(pool.get("left", [])) + list(pool.get("right", []))
    drivers = np.asarray(drivers, dtype=np.int64)
    if len(drivers) == 0:
        return None
    for s in drivers:
        picks = rng.choice(mx, size=min(fanout, len(mx)), replace=False)
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


def combine_overlays(mix, pops):
    """Merges the overlays of a normalized mix into one edge dict.

    Returns {(pre, post): (weight, winner_name)}. Identical (pre, post,
    weight) edges from two wirings are kept once; same (pre, post) with
    different weights is resolved by WIRING_PRIORITY (higher wins, winner
    logged); equal priority raises a hard conflict error. Sorted output
    keeps the product deterministic regardless of input order.
    """
    edges = {}
    post_sets = {}
    for name in mix:
        pre, post, w = EXPERIMENTS[name](pops)
        post_sets[name] = set(int(q) for q in post.tolist())
        for s, q, v in zip(pre.tolist(), post.tolist(), w.tolist()):
            key = (int(s), int(q))
            if key in edges:
                old_v, old_name = edges[key]
                if float(v) == float(old_v):
                    continue
                p_new = WIRING_PRIORITY.get(name, 0)
                p_old = WIRING_PRIORITY.get(old_name, 0)
                if p_new == p_old:
                    raise ValueError(
                        f"Wiring conflict: '{name}' and '{old_name}' both "
                        f"drive edge {key} with different weights "
                        f"({v} vs {old_v}) at equal priority. "
                        f"Drop one of them from the mix.")
                winner = name if p_new > p_old else old_name
                edges[key] = (float(v) if p_new > p_old else old_v, winner)
                print(f"[ExpWiring] conflict on edge {key}: "
                      f"'{winner}' wins by priority "
                      f"({name}={p_new} vs {old_name}={p_old})")
            else:
                edges[key] = (float(v), name)
    # Shared-downstream warning (not a conflict): two wirings driving the
    # same postsynaptic cells stack their drive and may saturate a readout.
    names = list(mix)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            shared = post_sets[names[i]] & post_sets[names[j]]
            if shared:
                print(f"[ExpWiring] note: '{names[i]}'+'{names[j]}' share "
                      f"{len(shared)} postsynaptic targets; combined drive "
                      f"may saturate — retune if the readout saturates.")
    keys = sorted(edges.keys())
    pre = np.array([k[0] for k in keys], dtype=np.int32)
    post = np.array([k[1] for k in keys], dtype=np.int32)
    w = np.array([edges[k][0] for k in keys], dtype=np.float32)
    return pre, post, w


def experiment_arrays(experiment, csr, pops):
    """Returns (indptr, indices, data) for a wiring mix, or base CSR arrays
    when experiment is None/'none'/'base'. Unknown names raise.

    This is the single funnel every FlyBrain constructor should use so the
    arity of a brain always matches its checkpoint namespace."""
    mix = normalize_experiment(experiment)
    if mix is None:
        return (np.ascontiguousarray(csr.indptr, dtype=np.int32),
                np.ascontiguousarray(csr.indices, dtype=np.int32),
                np.ascontiguousarray(csr.data, dtype=np.float32))
    pre, post, w = combine_overlays(mix, pops)
    print(f"[ExpWiring] {'+'.join(mix)}: injecting {len(pre):,} edges "
          f"(combined additive overlay)")
    return apply_overlay(csr, pre, post, w)


def experiment_suffix(experiment):
    """Filename suffix for experiment checkpoints (empty for base runs).

    Filename-safe: mix names joined with '__', e.g.
    '__exp_retina_wide__spear_lunge'. Single names keep the legacy form.
    """
    mix = normalize_experiment(experiment)
    if mix is None:
        return ""
    return "__exp_" + "__".join(mix)