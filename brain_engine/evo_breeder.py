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


def breed_clone(parent_id, name, seed, episodes=50, noise=0.05,
                mapping=None, progress_cb=None, mutate_structure=True,
                max_changes=1, episodes2=None, params2=None):
    """Clone a winner: weight copy + Gaussian noise, fresh seed, full
    training. mapping=None inherits the parent's stack. Genome parents
    additionally undergo structural mutation (mutate_structure, bounded
    by max_changes; arity surgery carries surviving weights over and
    inits new edges from the parent scale) and the child's mapping is
    re-derived from the mutated genome unless mapping is explicit.
    Genome-less parents (base/legacy) clone structurally identical.
    episodes2/params2 run a second stage (flight school) back-to-back
    via train_staged (unset stage-2 keys inherit stage 1); omitted
    means single-stage. Returns (record, weights, summary) like
    train_job (multi-stage summary when staged)."""
    from train_job import train_brain
    from experimental_wiring import (mutate_genome, remap_for_genome,
                                     derive_mapping, attach_genome)
    from connectome_loader import load_or_extract_populations
    rec, weights = vault.load_brain(parent_id)
    gp = dict(rec.get("generator_params", {}) or {})
    genome = gp.get("genome", None)
    child_mapping = gp.get("mapping") if mapping is None else mapping
    start_weights = np.ascontiguousarray(
        np.asarray(weights, dtype=np.float32))
    if genome is not None and mutate_structure:
        pops = load_or_extract_populations()
        mrng = np.random.default_rng(int(seed) ^ 0x5EED)
        new_genome = mutate_genome(mrng, genome, pops, max_changes)
        start_weights = remap_for_genome(
            gp.get("experiment"), genome, new_genome,
            np.asarray(weights, dtype=np.float32), mrng, pops)
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
    if genome is not None:
        attach_genome(params, genome)
    child = vault.new_record(name, params)
    child["lineage"] = {"parent_ids": [rec.get("id", "")],
                        "source": f"clone:{rec.get('id', '')}"}
    rng = np.random.default_rng(int(seed))
    noisy = np.ascontiguousarray(
        start_weights
        * (1.0 + rng.normal(0.0, float(noise), size=len(start_weights))).astype(np.float32))
    cname = rec.get('name', '?')
    return _staged_or_single(
        child, noisy, episodes, params, f"evo clone of {cname} (pre-train)",
        episodes2, params2, f"evo clone of {cname} (flight school)",
        progress_cb)


def breed_random(name, seed, episodes=50, progress_cb=None, generation=1,
                 episodes2=None, params2=None):
    """Fresh random brain: random wiring GENOME (grammar-constrained
    projection rules over the pool registry) with its mapping DERIVED
    from the genome's efferents, plus random yaw_bias + rates. Lineage
    source set to random. Empty name auto-generates a deterministic
    callsign (wild_name from the same seed), so callers that can't see
    the pool still get good names. Deterministic in seed end to end
    (dedicated np stream for the genome); seed draws for rates below
    use the legacy random stream (its positions shifted vs pre-genome
    code, which sampled mixes/stacks from it - seeds are not a stable
    API across breeder versions). episodes2/params2 run a flight-school
    second stage back-to-back (see breed_clone); omitted is single-stage."""
    import random as _random
    import numpy as _np
    from sensory_motor import draw_yaw_bias
    from experimental_wiring import (generate_genome, derive_mapping,
                                     attach_genome)
    from connectome_loader import load_or_extract_populations
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
    genome = generate_genome(grng, pops, 1 + int(grng.integers(0, 4)))
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
    }
    attach_genome(params, genome)
    from train_job import fresh_weights
    record = vault.new_record(name, params)
    weights = fresh_weights(params.get("experiment"), params.get("genome"))
    record, weights, summary = _staged_or_single(
        record, weights, episodes, params, "evo wild pre-train",
        episodes2, params2, "evo wild flight school", progress_cb)
    record["lineage"] = {"parent_ids": [], "source": "evo-random"}
    vault.save_brain(record, weights)
    return record, weights, summary
