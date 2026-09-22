import hashlib
import json
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

    Frozen genome: compiles FROZEN_GENOMES["lplc2_contra_dn"] (byte-identical
    to the historical implementation).
    """
    return _frozen("lplc2_contra_dn", pops, fanout, weight)


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

    Frozen genome: compiles FROZEN_GENOMES["retina_wide"] (byte-identical
    to the historical implementation).
    """
    return _frozen("retina_wide", pops, fanout, weight)


@_register("spear_lunge")
def spear_lunge(pops, fanout=3, weight=200.0):
    """Mouth-motor drive for the spear attack.

    MNxm (maxillary mouthpart motor neurons, 3L/3R) are centrally
    near-silent (0-7 weak inputs each), so nothing ever reads them.
    This overlay routes lobula feature volleys (LC11 presence/size,
    LC15/17/18 loom) onto all six MNxm cells, giving the decoder a
    genuine mouth-motor signal to fire the spear thrust from. Aimed in
    the decoder (visible + frontal gate), so rear tracking never lunges.

    Frozen genome: compiles FROZEN_GENOMES["spear_lunge"] (byte-identical
    to the historical implementation).
    """
    return _frozen("spear_lunge", pops, fanout, weight)


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


# ── Genome layer: parameterized projection rules ─────────────────────
# A wiring genome is a small list of projection RULES instead of a toggle
# over hand-written overlays. Each rule names source/target pools (+side),
# polarity, weight, fanout, topography, and the rng stream it draws from.
# The compiler below materializes rules to the same (pre, post, w) edge
# arrays the legacy overlay functions return, so combine_overlays,
# apply_overlay, arity handling, and the vault all work unchanged. The
# three legacy wirings are frozen genomes (byte-identical output, proven
# by tests/fixtures/frozen_genome_hashes.json); new neuron groups become
# explorable by adding rows to the pool registry, not overlay code.

ROLE_BY_PREFIX = (
    ("visual_", "sensory"),
    ("pheromone_", "sensory"),
    ("gyro_", "sensory"),
    ("flow_", "sensory"),
    ("motor_", "motor"),
    ("descending_", "motor"),
    ("dopamine_", "modulatory"),
    ("mbon_", "central"),
    ("mushroom_body_", "central"),
)

GENOME_SIDES = ("left", "right", "all")
GENOME_TOPOGRAPHIES = ("random",)
MAX_RULE_WEIGHT = 2000.0
MAX_RULE_FANOUT = 64

# Generator marriages: which target roles a sensory source may innervate.
# motor = readout drive, central = association readout. modulatory pools
# are never wiring targets (dopamine arrives via plasticity, not edges).
GENOME_TARGET_ROLES = ("motor", "central")


def pool_role(name):
    """Role of a connectome pool for wiring constraints (prefix table)."""
    for prefix, role in ROLE_BY_PREFIX:
        if str(name).startswith(prefix):
            return role
    return "central"


def build_pool_registry(pops):
    """{pool: {role, sides: {side: size}}} for pools with any members."""
    reg = {}
    for key, pool in pops.items():
        if not isinstance(pool, dict):
            continue
        sides = {}
        for side in ("left", "right", "all"):
            try:
                n = len(pool.get(side, []))
            except TypeError:
                n = 0
            if n:
                sides[side] = n
        if sides:
            reg[str(key)] = {"role": pool_role(key), "sides": sides}
    return reg


_RULE_KEYS = ("source", "source_side", "target", "target_side", "sign",
              "weight", "fanout", "topography", "stream", "stream_seed")


def validate_rule(rule):
    """Canonicalize one projection rule (raises ValueError on anything
    malformed). Returns a normalized copy; never mutates the input."""
    if not isinstance(rule, dict):
        raise ValueError(f"rule must be a dict, got {type(rule).__name__}")
    missing = [k for k in _RULE_KEYS if k not in rule]
    if missing:
        raise ValueError(f"rule missing keys {missing}: {rule}")
    src, tgt = str(rule["source"]), str(rule["target"])
    if not src or not tgt:
        raise ValueError(f"rule needs non-empty source/target: {rule}")
    ss, ts = str(rule["source_side"]), str(rule["target_side"])
    if ss not in GENOME_SIDES or ts not in GENOME_SIDES:
        raise ValueError(f"rule sides must be in {GENOME_SIDES}: {rule}")
    try:
        sign = float(rule["sign"])
    except (TypeError, ValueError):
        raise ValueError(f"rule sign must be numeric (+1/-1): {rule}")
    if sign not in (1.0, -1.0):
        raise ValueError(f"rule sign must be +1 or -1: {rule}")
    try:
        weight = float(rule["weight"])
    except (TypeError, ValueError):
        raise ValueError(f"rule weight must be numeric: {rule}")
    if not 0.0 < weight <= MAX_RULE_WEIGHT:
        raise ValueError(
            f"rule weight must be in (0, {MAX_RULE_WEIGHT}]: {rule}")
    fanout = rule["fanout"]
    if isinstance(fanout, bool) or not isinstance(fanout, int):
        raise ValueError(f"rule fanout must be an int: {rule}")
    if not 1 <= fanout <= MAX_RULE_FANOUT:
        raise ValueError(
            f"rule fanout must be in [1, {MAX_RULE_FANOUT}]: {rule}")
    topo = str(rule["topography"])
    if topo not in GENOME_TOPOGRAPHIES:
        raise ValueError(
            f"rule topography must be in {GENOME_TOPOGRAPHIES}: {rule}")
    stream = str(rule["stream"])
    if not stream:
        raise ValueError(f"rule stream must be a non-empty name: {rule}")
    seed = rule["stream_seed"]
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError(f"rule stream_seed must be an int: {rule}")
    if not 0 <= seed < 2 ** 32:
        raise ValueError(f"rule stream_seed must be in [0, 2**32): {rule}")
    return {"source": src, "source_side": ss, "target": tgt,
            "target_side": ts, "sign": sign, "weight": weight,
            "fanout": fanout, "topography": topo, "stream": stream,
            "stream_seed": seed}


def validate_genome(genome, pops=None):
    """Canonicalize a genome envelope {"name": str|None, "rules": [...]};
    duplicate (source, side, target, side) pairs are rejected (the
    compiler keeps first-wins, so dupes are almost always a mistake).
    With pops given, unknown pool names are also rejected (typo guard);
    without pops only rule shapes are checked, so stale caches with
    missing pools still compile (the compiler skips them like the
    legacy retina overlay always did)."""
    if not isinstance(genome, dict) or not isinstance(
            genome.get("rules"), list) or not genome["rules"]:
        raise ValueError("genome needs a non-empty 'rules' list")
    name = genome.get("name", None)
    if name is not None and not isinstance(name, str):
        raise ValueError("genome name must be a string or None")
    rules = [validate_rule(r) for r in genome["rules"]]
    seen = set()
    for r in rules:
        pair = (r["source"], r["source_side"], r["target"], r["target_side"])
        if pair in seen:
            raise ValueError(f"duplicate rule pair {pair} in genome")
        seen.add(pair)
    if pops is not None:
        registry = build_pool_registry(pops)
        for r in rules:
            for pool_key in ("source", "target"):
                if r[pool_key] not in registry:
                    raise ValueError(
                        f"unknown {pool_key} pool '{r[pool_key]}' "
                        f"(registry has {sorted(registry)})")
    return {"name": name, "rules": rules}


def compile_rules(rules, pops):
    """Materialize validated rule dicts to (pre, post, w) edge arrays.

    Rules sharing a (stream, stream_seed) draw from one rng in rule
    order (this is how the frozen legacy genomes reproduce their exact
    historical edge sets). Exact-duplicate edges keep the first
    occurrence. Returns None when nothing innervates (same contract as
    the legacy overlay functions). Missing/empty pools are skipped.
    """
    streams = {}
    order = []
    for r in rules:
        key = (r["stream"], r["stream_seed"])
        if key not in streams:
            streams[key] = []
            order.append(key)
        streams[key].append(r)
    pre, post, w = [], [], []
    seen = set()
    for key in order:
        rng = np.random.default_rng(key[1])
        for r in streams[key]:
            src = np.asarray(pops.get(r["source"], {}).get(
                r["source_side"], []), dtype=np.int64)
            tgt = np.asarray(pops.get(r["target"], {}).get(
                r["target_side"], []), dtype=np.int64)
            if len(src) == 0 or len(tgt) == 0:
                continue
            for s in src:
                picks = rng.choice(
                    tgt, size=min(r["fanout"], len(tgt)), replace=False)
                for q in picks.tolist():
                    edge = (int(s), int(q))
                    if edge in seen:
                        continue
                    seen.add(edge)
                    pre.append(edge[0])
                    post.append(edge[1])
                    w.append(float(r["sign"]) * float(r["weight"]))
    if not pre:
        return None
    return (np.array(pre, dtype=np.int32),
            np.array(post, dtype=np.int32),
            np.array(w, dtype=np.float32))


def compile_genome(genome, pops):
    """Validate + compile a genome envelope to edge arrays (None if empty)."""
    return compile_rules(validate_genome(genome)["rules"], pops)


def genome_id(genome):
    """Stable id for a genome: sha1 of canonical rules, 10 hex chars.
    Renames don't change it (name excluded); rule ORDER does (streams
    draw in rule order, so reordered rules are a different genome)."""
    rules = validate_genome(genome)["rules"]
    canon = json.dumps(rules, sort_keys=True, separators=(",", ":"))
    return hashlib.sha1(canon.encode("utf-8")).hexdigest()[:10]


def genome_label(genome):
    """Filename-safe arity-namespace label for genome checkpoints."""
    return "g" + genome_id(genome)


def generate_genome(rng, pops, n_rules=3, name=None):
    """Sample a random wiring genome. rng is np.random.Generator (use
    np.random.default_rng(seed) for reproducibility); sources are
    sensory-role pools, targets motor/central; signs mostly excitatory;
    each rule gets its own draw stream. Raises on tiny registries that
    can't supply n_rules distinct pairs."""
    if n_rules < 1:
        raise ValueError("generate_genome needs n_rules >= 1")
    registry = build_pool_registry(pops)
    sources = sorted(p for p, m in registry.items() if m["role"] == "sensory")
    targets = sorted(p for p, m in registry.items()
                     if m["role"] in GENOME_TARGET_ROLES)
    if not sources or not targets:
        raise ValueError(
            "genome generation needs sensory sources and motor/central targets")
    rules = []
    seen_pairs = set()
    tries = 0
    while len(rules) < n_rules and tries < 50 * n_rules:
        tries += 1
        src = str(rng.choice(sources))
        tgt = str(rng.choice(targets))
        ss = str(rng.choice(["left", "right"]))
        ts = str(rng.choice(["left", "right"]))
        if (src, ss, tgt, ts) in seen_pairs:
            continue
        seen_pairs.add((src, ss, tgt, ts))
        sign = 1.0 if float(rng.random()) < 0.8 else -1.0
        rules.append({
            "source": src, "source_side": ss, "target": tgt,
            "target_side": ts, "sign": sign,
            "weight": round(float(rng.uniform(50.0, 400.0)), 1),
            "fanout": int(rng.integers(2, 17)),
            "topography": "random",
            "stream": "g%d" % len(rules),
            "stream_seed": int(rng.integers(0, 2 ** 31)),
        })
    if len(rules) < n_rules:
        raise ValueError(
            f"registry too small for {n_rules} distinct rule pairs")
    return validate_genome({"name": name, "rules": rules}, pops)


# Frozen legacy genomes: the three historical overlays re-expressed as
# rules. Stream seeds reproduce each overlay's original rng stream, so
# compiled output is byte-identical to the pre-genome functions (gated
# by tests/fixtures/frozen_genome_hashes.json). Rule order mirrors the
# original loops exactly - do not reorder.
FROZEN_GENOMES = {
    "lplc2_contra_dn": {"name": "lplc2_contra_dn", "rules": [
        {"source": "visual_lplc2", "source_side": "left",
         "target": "descending_all", "target_side": "right",
         "sign": 1.0, "weight": 260.0, "fanout": 16,
         "topography": "random", "stream": "lplc2_contra_dn",
         "stream_seed": 0},
        {"source": "visual_lplc2", "source_side": "right",
         "target": "descending_all", "target_side": "left",
         "sign": 1.0, "weight": 260.0, "fanout": 16,
         "topography": "random", "stream": "lplc2_contra_dn",
         "stream_seed": 0},
    ]},
    "retina_wide": {"name": "retina_wide", "rules": [
        {"source": pool, "source_side": side,
         "target": "descending_all", "target_side": side,
         "sign": 1.0, "weight": 200.0, "fanout": 6,
         "topography": "random", "stream": "retina_wide",
         "stream_seed": 7}
        for pool in ("visual_lc11", "visual_lc15", "visual_lc17",
                     "visual_lc18")
        for side in ("left", "right")
    ]},
    "spear_lunge": {"name": "spear_lunge", "rules": [
        {"source": pool, "source_side": side,
         "target": "motor_mouth", "target_side": "all",
         "sign": 1.0, "weight": 200.0, "fanout": 3,
         "topography": "random", "stream": "spear_lunge",
         "stream_seed": 21}
        for pool in ("visual_lc11", "visual_lc15", "visual_lc17",
                     "visual_lc18")
        for side in ("left", "right")
    ]},
}


def _frozen(name, pops, fanout=None, weight=None):
    """Compile a frozen genome, optionally overriding fanout/weight."""
    rules = []
    for r in FROZEN_GENOMES[name]["rules"]:
        rr = dict(r)
        if fanout is not None:
            rr["fanout"] = fanout
        if weight is not None:
            rr["weight"] = weight
        rules.append(rr)
    return compile_rules(rules, pops)


# Schemes whose sensory pools a genome drives (mapping derivation).
SCHEME_SOURCES = {
    "retina": ("visual_lc11", "visual_lc15", "visual_lc17",
               "visual_lc18"),
    "flow_trans": ("visual_t4a", "visual_t4b", "visual_t4c",
                   "visual_t4d", "visual_t5a", "visual_t5b",
                   "visual_t5c", "visual_t5d"),
    "gyro_flow": ("gyro_jo",),
    "mbon": ("mushroom_body_kc",),
}
# Schemes whose readout pools a genome drives.
SCHEME_TARGETS = {
    "muscles_up": ("motor_flight_thrust", "motor_steer"),
    "gyro_flow": ("flow_vs", "flow_hs"),
    "mbon": ("mbon_app", "mbon_av"),
}


def derive_mapping(genome):
    """Derive a neuro-mapping stack from a genome's efferents: a scheme
    is live when the genome drives its sensory pools (sources) or its
    readout pools (targets). Returns a sorted tuple shaped like
    normalize_mapping output (() = base). Mouth-target rules (spear)
    derive nothing - the spear readout is always active. Presence-based
    only; strength-weighted derivation is future work (see the
    attribution miner)."""
    rules = validate_genome(genome)["rules"]
    srcs = {r["source"] for r in rules}
    tgts = {r["target"] for r in rules}
    out = set()
    for scheme, pools in SCHEME_SOURCES.items():
        if srcs & set(pools):
            out.add(scheme)
    for scheme, pools in SCHEME_TARGETS.items():
        if tgts & set(pools):
            out.add(scheme)
    return tuple(sorted(out))


def build_genome_arrays(genome, csr, pops):
    """(indptr, indices, data) for a genome envelope (None envelope =
    base CSR arrays, mirroring experiment_arrays)."""
    if genome is None:
        return (np.ascontiguousarray(csr.indptr, dtype=np.int32),
                np.ascontiguousarray(csr.indices, dtype=np.int32),
                np.ascontiguousarray(csr.data, dtype=np.float32))
    edges = compile_genome(genome, pops)
    if edges is None:
        return (np.ascontiguousarray(csr.indptr, dtype=np.int32),
                np.ascontiguousarray(csr.indices, dtype=np.int32),
                np.ascontiguousarray(csr.data, dtype=np.float32))
    pre, post, w = edges
    print(f"[ExpWiring] genome {genome_label(genome)}: injecting "
          f"{len(pre):,} edges (compiled genome)")
    return apply_overlay(csr, pre, post, w)


def genome_suffix(genome):
    """Filename suffix for genome checkpoints (empty when None)."""
    if genome is None:
        return ""
    return "__gen_" + genome_label(genome)