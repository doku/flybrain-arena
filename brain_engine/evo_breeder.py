"""Evolutionary breeding: biggest-loser query + offspring generation.

- biggest_loser(tourney): worst score = earliest exit + fewest battle
  wins (random tie-break). Pure function over a tournament JSON dict.
- breed_clone(): copy a winner's weights + pool-aware noise, FRESH seed
  (same start, divergent curriculum), train, stamp lineage.
- breed_random(): random wiring mix + mapping + yaw_bias + rates, train.

All offspring train through train_job (same pipeline as the menu), so
checkpoints, arity rules, and vault packaging behave identically.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import brain_package as vault


# Callsign pool for wild offspring names. Short, HUD/bracket-readable;
# vault filenames carry unique ids so display collisions are harmless
# (and unique_wild_name de-dupes against the live vault anyway).
WILD_CALLSIGNS = [
    "Rook", "Sable", "Junebug", "Tabanus", "Vespa", "Mantis",
    "Cicada", "Kestrel", "Pip", "Wasp", "Hornet", "Darter",
    "Skimmer", "Hawker", "Gnat", "Midge", "Locust", "Katydid",
    "Cricket", "Beetle", "Stag", "Rhino", "Atlas", "Luna",
]

# Adjective pool (kept for pool depth; wild names draw a single stem
# from the combined pool below).
WILD_ADJECTIVES = [
    "Ashen", "Brisk", "Cinder", "Dusky", "Ember", "Flint",
    "Grizzled", "Hasty", "Iron", "Jagged", "Keen", "Lithe",
    "Mottled", "Nimble", "Onyx", "Peppery", "Rusty", "Savage",
    "Tawny", "Umber", "Velvet", "Wily", "Zephyr", "Copper",
    "Slate", "Stormy", "Feral", "Bristle", "Gauzy", "Peppy",
]

# Single-word stems: one draw names the brain ("Kestrel G2", never
# "Peppery_Rhino_G2"). Combined pool maximizes uniqueness; collisions
# still de-dupe via unique_wild_name (Mk suffix).
WILD_STEMS = WILD_ADJECTIVES + WILD_CALLSIGNS


def wild_name(rng, generation):
    """Deterministic wild-offspring display name from a seedable rng
    (anything with .choice, e.g. random.Random):
    '<Stem> G<gen>' (one word plus generation tag)."""
    return f"{rng.choice(WILD_STEMS)} G{int(generation)}"


def unique_wild_name(rng, generation, taken):
    """wild_name, de-duped against a set of taken display names.

    First try is the plain deterministic name (no extra rng draws, so
    repeat calls with the same seed agree); on collision append a
    deterministic Mk numeral (Mk2, Mk3, ...) instead of burning more
    rng state. Caps at Mk99, then falls back to a seed-hash suffix
    that cannot realistically collide."""
    base = wild_name(rng, generation)
    if base not in taken:
        return base
    for n in range(2, 100):
        cand = f"{base} Mk{n}"
        if cand not in taken:
            return cand
    import hashlib as _hashlib
    digest = _hashlib.sha1(repr(sorted(taken)).encode()).hexdigest()[:6]
    return f"{base} X{digest}"


def biggest_loser(tourney, rng=None):
    """Returns (player_id, info) for the worst tournament score:
    earliest exit round, then fewest battle wins. Ties broken randomly
    (pass a seeded rng for reproducibility)."""
    import random as _random
    r = _random if rng is None else rng
    last_round = {}
    bwins = {}
    for ri, rnd in enumerate(tourney.get("rounds", [])):
        for m in rnd:
            if not isinstance(m, dict):
                continue
            for side, key in (("a", "a_id"), ("b", "b_id")):
                pid = str(m.get(key, ""))
                if not pid:
                    continue
                last_round[pid] = ri
                wkey = "wins_a" if side == "a" else "wins_b"
                try:
                    w = int(m.get(wkey, 0))
                except (TypeError, ValueError):
                    w = 0
                bwins[pid] = bwins.get(pid, 0) + w
    if not last_round:
        raise ValueError("tournament has no played matches")
    def _score(pid):
        return (last_round[pid], bwins.get(pid, 0))
    worst_key = min(_score(p) for p in last_round)
    tied = [p for p in last_round if _score(p) == worst_key]
    pick = r.choice(sorted(tied))
    return pick, {"last_round": last_round[pick],
                  "battle_wins": bwins.get(pick, 0),
                  "tied": sorted(tied)}


def _staged_or_single(child, start_weights, ep1, params, note1,
                      ep2, params2, note2, progress_cb):
    """Runs stage 1 (pre-train), then stage 2 (flight school) when ep2
    is set, on the same record. Stage-2 params inherit unset keys from
    stage 1 (same fallback philosophy as train_brain's record fallback;
    genome/mapping carry over so arity can never mismatch). Returns
    (record, weights, summary) with a merged multi-stage summary."""
    from train_job import train_brain, train_staged, merge_summaries
    ep2 = int(ep2 or 0)
    if ep2 <= 0:
        return train_brain(child, start_weights, int(ep1), params,
                           progress_cb=progress_cb, notes=note1, save=True)
    p2 = dict(params2 or {})
    for k, v in params.items():
        p2.setdefault(k, v)
    record, weights, summaries = train_staged(
        child, start_weights,
        [(int(ep1), params, note1), (ep2, p2, note2)],
        progress_cb=progress_cb, save=True)
    return record, weights, merge_summaries(summaries)


# Kin trait mutation: each clone re-rolls up to N hyperparameters
# (genes mutate separately via structural genome mutation). Fresh draws
# use the same ranges as wilds so mutants stay in-distribution.
# align_bonus keeps its pursuit shaping; yaw_bias only mutates when the
# parent carries one (None stays ungraduated).
TRAIT_RANGES = {
    "learning_rate": (0.003, 0.010),
    "dist_gain": (0.05, 0.30),
    "evasion": (0.0, 0.6),
}


def mutate_kin_traits(params, seed, n=1):
    """Re-roll up to n trait keys in place on a dedicated seed stream
    (deterministic per seed, never shifts other draws). Returns
    {key: [old, new]} for the lineage stamp."""
    import random as _random
    r = _random.Random(int(seed) ^ 0x7A17)
    cands = [k for k in ("learning_rate", "dist_gain", "evasion")
             if k in params]
    if params.get("yaw_bias", None) is not None:
        cands.append("yaw_bias")
    mutated = {}
    for key in r.sample(cands, max(0, min(int(n), len(cands)))):
        old = params[key]
        if key in TRAIT_RANGES:
            lo, hi = TRAIT_RANGES[key]
            prec = 4 if key == "learning_rate" else 2
            new = round(r.uniform(lo, hi), prec)
        elif key == "yaw_bias":
            from sensory_motor import draw_yaw_bias
            new = draw_yaw_bias(r)
        else:
            continue
        params[key] = new
        mutated[key] = [old, new]
    return mutated


def inherit_elo(parent_elo):
    """Clone ELO with regression to the mean: child starts strong but
    below the parent (default-rated parents breed default children)."""
    return vault.ELO_DEFAULT + (
        float(parent_elo) - vault.ELO_DEFAULT) * vault.ELO_INHERIT


# Reflex-blend traits (see sensory_motor.BLEND_DEFAULTS): how much of
# each control channel the reflexes own. Inherited ± a delta (fresh
# ranges for wilds) on a dedicated seed stream, stamped into
# trait_mutations alongside the hyperparameter traits, so evolution
# can migrate control from reflex to neurons and ELO proves it.
BLEND_KEYS = ("yaw_blend", "evade_backup", "flow_authority",
              "search_blend", "pitch_blend")
BLEND_DELTAS = {"yaw_blend": 0.15, "evade_backup": 0.3,
                "flow_authority": 0.2, "search_blend": 0.15,
                "pitch_blend": 0.2}
BLEND_STREAM = 0xB1ED


def fresh_blends(seed):
    """Fresh reflex authority for parent-less brains (wilds). Ranges
    stay near the flyable regime: brain-led yaw is allowed, pitch
    keeps at least half reflex (altitude is safety-critical)."""
    import random as _random
    r = _random.Random(int(seed) ^ BLEND_STREAM)
    return {
        "yaw_blend": round(r.uniform(0.0, 0.6), 2),
        "evade_backup": float(r.random() < 0.5),
        "flow_authority": round(r.uniform(0.0, 1.0), 2),
        "search_blend": round(r.uniform(0.2, 0.8), 2),
        "pitch_blend": round(r.uniform(0.5, 1.0), 2),
    }


def inherit_blends(parent_gp, seed):
    """Child blends = parent blends ± a bounded delta per knob.
    Returns (blends, mutated) with mutated = {key: [old, new]}."""
    import random as _random
    from sensory_motor import BLEND_DEFAULTS
    r = _random.Random(int(seed) ^ BLEND_STREAM)
    base = dict(BLEND_DEFAULTS)
    for k in BLEND_KEYS:
        try:
            base[k] = max(0.0, min(1.0, float((parent_gp or {}).get(
                k, base[k]))))
        except (TypeError, ValueError):
            pass
    blends, mutated = {}, {}
    for k in BLEND_KEYS:
        old = base[k]
        new = round(max(0.0, min(1.0, old + r.uniform(
            -BLEND_DELTAS[k], BLEND_DELTAS[k]))), 2)
        blends[k] = new
        if new != old:
            mutated[k] = [old, new]
    return blends, mutated


# Heritable training recipe: how LONG/HARD a brain is schooled is a
# rearing trait, inherited ± a random delta (never a fresh draw), so
# lineages explore training regimes and ELO selects what works. Stored
# on lineage["training"] (a biography entry, not a brain trait) with
# per-key [old, new] stamps in lineage["training_mutations"].
# Wilds (no parents) draw fresh from the same ranges.
TRAINING_RANGES = {
    "episodes_total": (20, 80),
    "stage_split": (0.25, 0.75),
    "noise": (0.0, 0.15),
    "max_changes": (0, 3),
}
TRAINING_DELTAS = {
    "episodes_total": 10.0,
    "stage_split": 0.1,
    "noise": 0.02,
    "max_changes": 1.0,
}
RECIPE_DEFAULTS = {
    "episodes_total": 50,
    "stage_split": 0.5,
    "noise": 0.05,
    "max_changes": 1,
}
RECIPE_STREAM = 0x7E21


def _clamp_recipe(key, value):
    lo, hi = TRAINING_RANGES[key]
    v = max(lo, min(hi, float(value)))
    if key == "episodes_total":
        return int(round(v / 5.0) * 5)
    if key == "max_changes":
        return int(round(v))
    if key == "stage_split":
        return round(v, 2)
    return round(v, 3)


def fresh_recipe(seed):
    """Fresh training recipe for parent-less brains (wilds): uniform
    draws from TRAINING_RANGES on a dedicated seed stream."""
    import random as _random
    r = _random.Random(int(seed) ^ RECIPE_STREAM)
    recipe = {}
    for key in ("episodes_total", "stage_split", "noise", "max_changes"):
        lo, hi = TRAINING_RANGES[key]
        recipe[key] = _clamp_recipe(key, r.uniform(lo, hi))
    return recipe


def inherit_recipe(parent_recipe, seed):
    """Child recipe = parent recipe ± a bounded random delta per knob
    (dedicated seed stream; deterministic per seed). Returns
    (recipe, mutated) with mutated = {key: [old, new]} for nonzero
    deltas, mirroring the trait_mutations stamp."""
    import random as _random
    r = _random.Random(int(seed) ^ RECIPE_STREAM)
    base = dict(RECIPE_DEFAULTS)
    for k, v in (parent_recipe or {}).items():
        if k in base:
            try:
                base[k] = _clamp_recipe(k, v)
            except (TypeError, ValueError):
                pass
    recipe, mutated = {}, {}
    for key in ("episodes_total", "stage_split", "noise", "max_changes"):
        old = base[key]
        new = _clamp_recipe(key, old + r.uniform(
            -TRAINING_DELTAS[key], TRAINING_DELTAS[key]))
        recipe[key] = new
        if new != old:
            mutated[key] = [old, new]
    return recipe, mutated


def _resolve_recipe(parent_recipe, seed, episodes, episodes2, noise,
                    max_changes):
    """Merges explicit caller overrides over the inherited recipe.
    Returns (recipe, mutated, ep1, ep2, noise, max_changes): stage
    episode counts derive from total × split unless explicitly given
    (explicit episodes without episodes2 keeps the legacy single-stage
    path)."""
    recipe, mutated = inherit_recipe(parent_recipe, seed)
    if episodes is not None:
        recipe["episodes_total"] = max(1, int(episodes))
    if noise is not None:
        recipe["noise"] = max(0.0, float(noise))
    if max_changes is not None:
        recipe["max_changes"] = max(0, int(max_changes))
    total = int(recipe["episodes_total"])
    if episodes is None and episodes2 is None:
        ep1 = max(5, int(round(total * float(recipe["stage_split"]) / 5.0) * 5))
        ep1 = min(ep1, total - 5) if total > 10 else total
        ep2 = total - ep1
    else:
        ep1 = total if episodes is None else max(1, int(episodes))
        ep2 = episodes2
    return recipe, mutated, ep1, ep2, recipe["noise"], recipe["max_changes"]


def breed_clone(parent_id, name, seed, episodes=None, noise=None,
                mapping=None, progress_cb=None, mutate_structure=True,
                max_changes=None, episodes2=None, params2=None,
                mutate_traits=1):
    """Clone a winner: weight copy + Gaussian noise, fresh seed, full
    training. mapping=None inherits the parent's stack. Genome parents
    additionally undergo structural mutation (mutate_structure, bounded
    by max_changes; arity surgery carries surviving weights over and
    inits new edges from the parent scale) and the child's mapping is
    re-derived from the mutated genome unless mapping is explicit.
    Genome-less parents (base/legacy) clone structurally identical.
    mutate_traits re-rolls that many hyperparameter traits at random
    (learning_rate/dist_gain/evasion, plus yaw_bias when carried; 0
    disables) with the change stamped into the lineage.
    Training recipe (episodes/noise/max_changes) inherits ± a delta
    from the parent's lineage["training"] unless explicitly passed;
    derived stage counts feed _staged_or_single, and the recipe lands
    in lineage["training"] with lineage["training_mutations"].
    episodes2/params2 run a second stage (flight school) back-to-back
    via train_staged (unset stage-2 keys inherit stage 1); explicit
    episodes without episodes2 keeps the single-stage path. Returns
    (record, weights, summary) like train_job (multi-stage summary
    when staged)."""
    from train_job import train_brain
    from experimental_wiring import (mutate_genome, remap_for_genome,
                                     derive_mapping, attach_genome)
    from connectome_loader import (load_or_extract_populations,
                                   load_or_build_csr)
    rec, weights = vault.load_brain(parent_id)
    gp = dict(rec.get("generator_params", {}) or {})
    parent_recipe = ((rec.get("lineage", {}) or {}).get("training", {}) or {})
    recipe, recipe_mut, ep1, ep2, noise, max_changes = _resolve_recipe(
        parent_recipe, seed, episodes, episodes2, noise, max_changes)
    genome = gp.get("genome", None)
    child_mapping = gp.get("mapping") if mapping is None else mapping
    start_weights = np.ascontiguousarray(
        np.asarray(weights, dtype=np.float32))
    # max_changes = 0 (a legal inherited recipe) means a structurally
    # identical clone: skip mutate_genome, which requires >= 1. The
    # child still varies by weight noise, traits, blends and recipe.
    if genome is not None and mutate_structure and max_changes >= 1:
        pops = load_or_extract_populations()
        csr = load_or_build_csr()
        mrng = np.random.default_rng(int(seed) ^ 0x5EED)
        new_genome = mutate_genome(mrng, genome, pops, max_changes)
        start_weights = remap_for_genome(
            gp.get("experiment"), genome, new_genome,
            np.asarray(weights, dtype=np.float32), mrng, pops, csr)
        genome = new_genome
        if mapping is None:
            child_mapping = list(derive_mapping(genome))
    params = {
        "variant": gp.get("variant", "custom"),
        "seed": int(seed),
        "learning_rate": gp.get("learning_rate", 0.008),
        "dist_gain": gp.get("dist_gain", 0.15),
        "align_bonus": list(gp.get("align_bonus", [0.5, 0.2, -0.3])),
        "evasion": gp.get("evasion", 0.2),
        "experiment": gp.get("experiment"),
        "mapping": child_mapping,
        "yaw_bias": gp.get("yaw_bias"),
    }
    mutated = {}
    if int(mutate_traits or 0) > 0:
        mutated = mutate_kin_traits(params, int(seed), int(mutate_traits))
    blend_vals, blend_mut = inherit_blends(gp, int(seed))
    params.update(blend_vals)
    mutated.update(blend_mut)
    if genome is not None:
        attach_genome(params, genome)
    child = vault.new_record(name, params)
    recipe["inherited_from"] = rec.get("id", "")
    child["lineage"] = {"parent_ids": [rec.get("id", "")],
                        "source": f"clone:{rec.get('id', '')}",
                        "trait_mutations": mutated,
                        "training": dict(recipe),
                        "training_mutations": recipe_mut}
    # ELO inheritance with regression to the mean: the child starts
    # strong but below the parent (wilds take the new_record default).
    parent_elo = float((rec.get("record", {}) or {}).get(
        "elo", vault.ELO_DEFAULT))
    child["record"]["elo"] = inherit_elo(parent_elo)
    rng = np.random.default_rng(int(seed))
    noisy = np.ascontiguousarray(
        start_weights
        * (1.0 + rng.normal(0.0, float(noise), size=len(start_weights))).astype(np.float32))
    cname = rec.get('name', '?')
    return _staged_or_single(
        child, noisy, ep1, params, f"evo clone of {cname} (pre-train)",
        ep2, params2, f"evo clone of {cname} (flight school)",
        progress_cb)


def breed_random(name, seed, episodes=None, progress_cb=None, generation=1,
                 episodes2=None, params2=None, mode="graft"):
    """Fresh random brain: wiring genome plus random yaw_bias + rates.
    mode="legacy" keeps the exact historical behavior (1-4 fully random
    rules); graft/shuffle/novelty explore around the pinned reference
    fly (see experimental_wiring) with a generation-ramped rule budget,
    so every novel feature stays attached to a neuron bundle. Empty
    name auto-generates a deterministic callsign (wild_name from the
    same seed), so callers that can't see the pool still get good
    names. Deterministic in seed end to end (dedicated np stream for
    the genome); rate draws use the legacy random stream (positions
    shifted vs pre-genome code - seeds are not a stable API across
    breeder versions). Training recipe draws fresh from TRAINING_RANGES
    (no parents to inherit from) unless episodes are explicit;
    stamped in lineage["training"]. episodes2/params2 run a
    flight-school second stage back-to-back (see breed_clone);
    explicit episodes without episodes2 keeps the single-stage path."""
    import random as _random
    import numpy as _np
    from sensory_motor import draw_yaw_bias
    from experimental_wiring import (
        generate_genome, derive_mapping, attach_genome,
        generate_exploratory_genome, rule_budget, EXPLORE_MODES)
    from connectome_loader import load_or_extract_populations
    if mode not in EXPLORE_MODES:
        raise ValueError(f"unknown explore mode '{mode}' {EXPLORE_MODES}")
    if mode == "crossover":
        raise ValueError("crossover needs two parents: use breed_crossover")
    r = _random.Random(int(seed))
    if not (name or "").strip():
        # Dedicated naming stream: extra adjective/callsign draws must
        # not shift the wiring/rate draws below for a given seed.
        nr = _random.Random(f"wild-name:{int(seed)}")
        taken = {str(rec.get("name", ""))
                 for rec in vault.scan_vault(silent=True)}
        name = unique_wild_name(nr, generation, taken)
    grng = _np.random.default_rng(int(seed))
    pops = load_or_extract_populations()
    provenance = {"mode": "legacy"}
    if mode == "legacy":
        genome = generate_genome(grng, pops, 1 + int(grng.integers(0, 4)))
    else:
        budget = rule_budget(generation)
        genome, provenance = generate_exploratory_genome(
            grng, pops, mode, budget)
        provenance = dict(provenance)
        provenance["budget"] = budget
        provenance["generation"] = int(generation)
    stack = list(derive_mapping(genome))
    params = {
        "variant": "custom",
        "seed": int(seed),
        "learning_rate": round(r.uniform(0.003, 0.010), 4),
        "dist_gain": round(r.uniform(0.05, 0.30), 2),
        "align_bonus": [0.5, 0.2, -0.3],
        "evasion": round(r.uniform(0.0, 0.6), 2),
        "experiment": None,
        "mapping": stack if stack else None,
        "yaw_bias": draw_yaw_bias(r),
        "explore_mode": mode,
    }
    attach_genome(params, genome)
    params.update(fresh_blends(int(seed)))
    from train_job import fresh_weights
    recipe = fresh_recipe(seed)
    if episodes is not None:
        recipe["episodes_total"] = max(5, int(episodes))
    total = int(recipe["episodes_total"])
    if episodes is None and episodes2 is None:
        ep1 = max(5, int(round(total * 0.5 / 5.0) * 5))
        ep1 = min(ep1, total - 5) if total > 10 else total
        ep2 = total - ep1
    else:
        ep1 = total if episodes is None else max(5, int(episodes))
        ep2 = episodes2
    record = vault.new_record(name, params)
    weights = fresh_weights(params.get("experiment"), params.get("genome"))
    record, weights, summary = _staged_or_single(
        record, weights, ep1, params, "evo wild pre-train",
        ep2, params2, "evo wild flight school", progress_cb)
    recipe["inherited_from"] = None
    record["lineage"] = {"parent_ids": [], "source": "evo-random",
                         "explore_mode": mode, "provenance": provenance,
                         "training": dict(recipe), "training_mutations": {}}
    vault.save_brain(record, weights)
    return record, weights, summary


REFERENCE_BRAIN_NAME = "Reference"


def breed_reference(name="Reference", seed=7, episodes=50,
                    progress_cb=None, episodes2=None, params2=None):
    """Canonical breeding stock: the pinned reference genome, derived
    mapping, FIXED canonical rates (stock is reproducible, not another
    roll), full training pipeline. Refuses when the vault already holds
    the reference genome (one canonical stock). Lineage source
    "reference". Returns (record, weights, summary) like breed_random."""
    from experimental_wiring import (reference_genome, derive_mapping,
                                     attach_genome, genome_label)
    from sensory_motor import YAW_BIAS_DEFAULT
    genome = reference_genome()
    gid = genome_label(genome)
    for rec in vault.scan_vault(silent=True):
        gp = rec.get("generator_params", {}) or {}
        if str(gp.get("genome_id", "")) == gid:
            raise ValueError(
                f"reference stock already in vault: {rec.get('name')} "
                f"({rec.get('id')})")
    stack = list(derive_mapping(genome))
    params = {
        "variant": "custom",
        "seed": int(seed),
        "learning_rate": 0.008,
        "dist_gain": 0.15,
        "align_bonus": [0.5, 0.2, -0.3],
        "evasion": 0.2,
        "experiment": None,
        "mapping": stack if stack else None,
        "yaw_bias": float(YAW_BIAS_DEFAULT),
        "explore_mode": "reference",
    }
    attach_genome(params, genome)
    from train_job import fresh_weights
    record = vault.new_record((name or "").strip() or REFERENCE_BRAIN_NAME,
                              params)
    weights = fresh_weights(None, genome)
    record, weights, summary = _staged_or_single(
        record, weights, episodes, params, "reference pre-train",
        episodes2, params2, "reference flight school", progress_cb)
    record["lineage"] = {"parent_ids": [], "source": "reference",
                         "explore_mode": "reference",
                         "provenance": {"mode": "reference",
                                        "reference_id": gid}}
    vault.save_brain(record, weights)
    return record, weights, summary


def _crossover_parent_genome(gp):
    """Envelope for a crossover parent: its genome, else its frozen
    experiment mix expanded to rules. Base/legacy parents carry no
    crossable content (ValueError - the caller falls back to clone)."""
    from experimental_wiring import FROZEN_GENOMES
    genome = gp.get("genome", None)
    if genome is not None:
        return genome
    exp = gp.get("experiment", None)
    names = []
    if isinstance(exp, str) and exp not in ("", "base", "none"):
        names = [exp]
    elif isinstance(exp, (list, tuple)) and len(exp) == 1:
        names = [str(exp[0])]
    if len(names) == 1 and names[0] in FROZEN_GENOMES:
        frozen = FROZEN_GENOMES[names[0]]
        return {"name": frozen["name"],
                "rules": [dict(r) for r in frozen["rules"]]}
    raise ValueError("crossover parent has no genome content "
                     "(base/legacy/multi-mix)")


def breed_crossover(parent_a_id, parent_b_id, name, seed, episodes=None,
                    noise=None, progress_cb=None, mutate_traits=1,
                    episodes2=None, params2=None):
    """Sexual reproduction: rule-level uniform crossover of two parents'
    genomes plus one structural mutation step, weights remapped from
    parent A (donor) with Gaussian noise, fresh seed, full training.
    ELO regresses from the parents' mean. Genome-less base/legacy
    parents (or multi-mixes) raise ValueError - breed_clone instead.
    Mapping derives from the child genome; traits mutate like a clone.
    Training recipe inherits ± a delta from the parents' MEAN recipe
    unless explicitly passed (lineage["training"], stamped).
    Returns (record, weights, summary) like breed_clone."""
    import numpy as _np
    from experimental_wiring import (
        crossover_genomes, remap_for_genome, derive_mapping,
        attach_genome)
    from connectome_loader import (load_or_extract_populations,
                                   load_or_build_csr)
    rec_a, weights_a = vault.load_brain(parent_a_id)
    rec_b, weights_b = vault.load_brain(parent_b_id)
    gp_a = dict(rec_a.get("generator_params", {}) or {})
    gp_b = dict(rec_b.get("generator_params", {}) or {})
    ra = ((rec_a.get("lineage", {}) or {}).get("training", {}) or {})
    rb = ((rec_b.get("lineage", {}) or {}).get("training", {}) or {})
    mean_recipe = {}
    for k in RECIPE_DEFAULTS:
        va = ra.get(k, RECIPE_DEFAULTS[k])
        vb = rb.get(k, RECIPE_DEFAULTS[k])
        try:
            mean_recipe[k] = _clamp_recipe(k, (float(va) + float(vb)) / 2.0)
        except (TypeError, ValueError):
            mean_recipe[k] = RECIPE_DEFAULTS[k]
    recipe, recipe_mut, ep1, ep2, noise, _mc = _resolve_recipe(
        mean_recipe, seed, episodes, episodes2, noise, None)
    genome_a = _crossover_parent_genome(gp_a)
    genome_b = _crossover_parent_genome(gp_b)
    pops = load_or_extract_populations()
    csr = load_or_build_csr()
    rng = _np.random.default_rng(int(seed))
    genome, provenance = crossover_genomes(rng, genome_a, genome_b, pops)
    mrng = _np.random.default_rng(int(seed) ^ 0xC205E)
    start_weights = remap_for_genome(
        gp_a.get("experiment"), gp_a.get("genome"), genome,
        _np.asarray(weights_a, dtype=_np.float32), mrng, pops, csr)
    child_mapping = list(derive_mapping(genome))
    params = {
        "variant": gp_a.get("variant", "custom"),
        "seed": int(seed),
        "learning_rate": gp_a.get("learning_rate", 0.008),
        "dist_gain": gp_a.get("dist_gain", 0.15),
        "align_bonus": list(gp_a.get("align_bonus", [0.5, 0.2, -0.3])),
        "evasion": gp_a.get("evasion", 0.2),
        "experiment": None,
        "mapping": child_mapping,
        "yaw_bias": gp_a.get("yaw_bias"),
        "explore_mode": "crossover",
    }
    mutated = {}
    if int(mutate_traits or 0) > 0:
        mutated = mutate_kin_traits(params, int(seed), int(mutate_traits))
    from sensory_motor import BLEND_DEFAULTS as _bd
    mean_blends = {}
    for k in BLEND_KEYS:
        try:
            va = float(gp_a.get(k, _bd[k]))
            vb = float(gp_b.get(k, _bd[k]))
            mean_blends[k] = max(0.0, min(1.0, (va + vb) / 2.0))
        except (TypeError, ValueError):
            pass
    blend_vals, blend_mut = inherit_blends(mean_blends, int(seed))
    params.update(blend_vals)
    mutated.update(blend_mut)
    attach_genome(params, genome)
    child = vault.new_record(name, params)
    recipe["inherited_from"] = [rec_a.get("id", ""), rec_b.get("id", "")]
    child["lineage"] = {
        "parent_ids": [rec_a.get("id", ""), rec_b.get("id", "")],
        "source": f"crossover:{rec_a.get('id', '')}x{rec_b.get('id', '')}",
        "trait_mutations": mutated, "explore_mode": "crossover",
        "provenance": provenance, "training": dict(recipe),
        "training_mutations": recipe_mut}
    elo_a = float((rec_a.get("record", {}) or {}).get(
        "elo", vault.ELO_DEFAULT))
    elo_b = float((rec_b.get("record", {}) or {}).get(
        "elo", vault.ELO_DEFAULT))
    child["record"]["elo"] = inherit_elo((elo_a + elo_b) / 2.0)
    noisy = _np.ascontiguousarray(
        start_weights
        * (1.0 + rng.normal(0.0, float(noise),
                            size=len(start_weights))).astype(_np.float32))
    cname = "%s x %s" % (rec_a.get("name", "?"), rec_b.get("name", "?"))
    return _staged_or_single(
        child, noisy, ep1, params, f"evo crossover of {cname} (pre-train)",
        ep2, params2, f"evo crossover of {cname} (flight school)",
        progress_cb)
