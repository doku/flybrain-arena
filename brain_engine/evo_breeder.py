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

# Adjective pool: '<Adjective> <Callsign> G<gen>' reads like a fighter
# handle on the bracket/HUD. Kept short and punch-only; draw order
# (adjective, then callsign) is part of the deterministic contract.
WILD_ADJECTIVES = [
    "Ashen", "Brisk", "Cinder", "Dusky", "Ember", "Flint",
    "Grizzled", "Hasty", "Iron", "Jagged", "Keen", "Lithe",
    "Mottled", "Nimble", "Onyx", "Peppery", "Rusty", "Savage",
    "Tawny", "Umber", "Velvet", "Wily", "Zephyr", "Copper",
    "Slate", "Stormy", "Feral", "Bristle", "Gauzy", "Peppy",
]


def wild_name(rng, generation):
    """Deterministic wild-offspring display name from a seedable rng
    (anything with .choice, e.g. random.Random):
    '<Adjective> <Callsign> G<gen>'."""
    return (f"{rng.choice(WILD_ADJECTIVES)} "
            f"{rng.choice(WILD_CALLSIGNS)} G{int(generation)}")


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


def breed_clone(parent_id, name, seed, episodes=50, noise=0.05,
                mapping=None, progress_cb=None):
    """Clone a winner: weight copy + Gaussian noise, fresh seed, full
    training. mapping=None inherits the parent's stack. Returns
    (record, weights, summary) like train_job."""
    from train_job import train_brain
    rec, weights = vault.load_brain(parent_id)
    gp = dict(rec.get("generator_params", {}) or {})
    params = {
        "variant": gp.get("variant", "custom"),
        "seed": int(seed),
        "learning_rate": gp.get("learning_rate", 0.008),
        "dist_gain": gp.get("dist_gain", 0.15),
        "align_bonus": list(gp.get("align_bonus", [0.5, 0.2, -0.3])),
        "evasion": gp.get("evasion", 0.2),
        "experiment": gp.get("experiment"),
        "genome": gp.get("genome"),
        "mapping": gp.get("mapping") if mapping is None else mapping,
        "yaw_bias": gp.get("yaw_bias"),
    }
    child = vault.new_record(name, params)
    child["lineage"] = {"parent_ids": [rec.get("id", "")],
                        "source": f"clone:{rec.get('id', '')}"}
    rng = np.random.default_rng(int(seed))
    noisy = np.ascontiguousarray(
        np.asarray(weights, dtype=np.float32)
        * (1.0 + rng.normal(0.0, float(noise), size=len(weights))).astype(np.float32))
    return train_brain(child, noisy, int(episodes), params,
                       progress_cb=progress_cb,
                       notes=f"evo clone of {rec.get('name', '?')}",
                       save=True)


def breed_random(name, seed, episodes=50, progress_cb=None, generation=1):
    """Fresh random brain: random wiring GENOME (grammar-constrained
    projection rules over the pool registry) with its mapping DERIVED
    from the genome's efferents, plus random yaw_bias + rates. Lineage
    source set to random. Empty name auto-generates a deterministic
    callsign (wild_name from the same seed), so callers that can't see
    the pool still get good names. Deterministic in seed end to end
    (dedicated np stream for the genome); seed draws for rates below
    use the legacy random stream (its positions shifted vs pre-genome
    code, which sampled mixes/stacks from it - seeds are not a stable
    API across breeder versions)."""
    import random as _random
    import numpy as _np
    from sensory_motor import draw_yaw_bias
    from train_job import generate_and_train
    from experimental_wiring import generate_genome, derive_mapping
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
        "genome": genome,
        "mapping": stack if stack else None,
        "yaw_bias": draw_yaw_bias(r),
    }
    record, weights, summary = generate_and_train(
        name, int(episodes), params, progress_cb=progress_cb)
    record["lineage"] = {"parent_ids": [], "source": "evo-random"}
    vault.save_brain(record, weights)
    return record, weights, summary
