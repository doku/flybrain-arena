"""Wiring attribution miner: which neuro groups predict winning?

Reads finished tournament brackets (tournaments/T*.json) plus the vault,
then tallies, per connectome pool, the win rate of fighters whose wiring
touches that pool - the instrument for "what was this group evolved to
do", with the tournament as the fitness assay.

Usage:
    python mine_wiring_fitness.py [--dir tournaments] [--min-n 5]

Only decided, non-bye, non-vacant matches count. A pool (or mapping)
scores only matches where EXACTLY ONE side carries it, so mirror matches
never pad the stats. Base brains (no wiring) contribute as the control:
their pools are untouched, their mappings still score.
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import brain_package as vault
from experimental_wiring import FROZEN_GENOMES


def match_outcomes(tourney):
    """[(winner_id, loser_id)] over decided real matches (no byes,
    vacants, or undecided cards)."""
    out = []
    for rnd in tourney.get("rounds", []):
        if not isinstance(rnd, list):
            continue
        for m in rnd:
            if not isinstance(m, dict):
                continue
            if bool(m.get("bye", False)) or bool(m.get("vacant", False)):
                continue
            w = str(m.get("winner_id", ""))
            a = str(m.get("a_id", ""))
            b = str(m.get("b_id", ""))
            if not w or not a or not b:
                continue
            out.append((w, b if w == a else a))
    return out


def brain_meta(rec):
    """{pools, mapping, n_rules, label} for one vault record.

    pools = connectome pools the wiring touches (genome rule sources +
    targets, or frozen-rule expansion of a legacy experiment mix; empty
    for base brains). mapping = sorted tuple from the record (may be
    empty = base).
    """
    gp = (rec.get("generator_params", {}) or {})
    pools = set()
    n_rules = 0
    label = "base"
    genome = gp.get("genome", None)
    if genome is not None:
        for r in genome.get("rules", []) or []:
            pools.add(str(r.get("source", "")))
            pools.add(str(r.get("target", "")))
        n_rules = len(genome.get("rules", []) or [])
        label = "genome"
    else:
        exp = gp.get("experiment", None)
        names = []
        if isinstance(exp, str) and exp not in ("", "base", "none"):
            names = [p.strip() for p in exp.replace(",", "+").split("+")]
        elif isinstance(exp, (list, tuple)):
            names = [str(x) for x in exp]
        for name in names:
            frozen = FROZEN_GENOMES.get(name, None)
            if frozen is None:
                continue
            label = "mix"
            for r in frozen["rules"]:
                pools.add(str(r["source"]))
                pools.add(str(r["target"]))
    pools.discard("")
    mapping = gp.get("mapping", None)
    if isinstance(mapping, str):
        mapping = [mapping] if mapping not in ("", "base", "none") else []
    mapping = tuple(sorted(str(m) for m in (mapping or [])))
    return {"pools": pools, "mapping": mapping, "n_rules": n_rules,
            "label": label}


def tally(outcomes, metas):
    """Per-pool / per-mapping win stats over exactly-one-side matches.

    Returns {"pools": {pool: (wins, n)}, "mappings": {...},
             "rules_winners": mean n_rules, "rules_losers": mean n_rules,
             "matches": total scored}.
    """
    pools = {}
    mappings = {}
    rw = []
    rl = []
    scored = 0
    for winner, loser in outcomes:
        mw = metas.get(winner, None)
        ml = metas.get(loser, None)
        if mw is None or ml is None:
            continue
        scored += 1
        for pool in (mw["pools"] ^ ml["pools"]):
            w, n = pools.get(pool, (0, 0))
            pools[pool] = (w + (1 if pool in mw["pools"] else 0), n + 1)
        for mp in set([mw["mapping"], ml["mapping"]]):
            if mw["mapping"] == ml["mapping"]:
                continue
            w, n = mappings.get(mp, (0, 0))
            mappings[mp] = (w + (1 if mp == mw["mapping"] else 0), n + 1)
        rw.append(mw["n_rules"])
        rl.append(ml["n_rules"])
    def _mean(xs):
        return sum(xs) / len(xs) if xs else 0.0
    return {"pools": pools, "mappings": mappings,
            "rules_winners": _mean(rw), "rules_losers": _mean(rl),
            "matches": scored}


def report(stats, min_n=5):
    """Human-readable lines, pools sorted by sample size."""
    lines = [f"scored matches: {stats['matches']}"]
    lines.append(f"mean genome rules: winners {stats['rules_winners']:.2f} "
                 f"vs losers {stats['rules_losers']:.2f}")
    rows = [(p, w, n) for p, (w, n) in stats["pools"].items() if n >= min_n]
    rows.sort(key=lambda r: -r[2])
    lines.append("pool: n winrate lift")
    for p, w, n in rows:
        rate = w / n
        lines.append(f"  {p}: n={n} {rate:.2f} {rate - 0.5:+.2f}")
    mrows = [(m, w, n) for m, (w, n) in stats["mappings"].items()
             if n >= min_n]
    mrows.sort(key=lambda r: -r[2])
    lines.append("mapping: n winrate lift")
    for m, w, n in mrows:
        rate = w / n
        lines.append(f"  {'+'.join(m) or 'base'}: n={n} {rate:.2f} "
                     f"{rate - 0.5:+.2f}")
    return "\n".join(lines)


def weak_from_stats(stats, min_n=5, max_rate=0.5):
    """[(pool, wins, n)] below max_rate over min_n+ samples, weakest
    first. Pure (no IO): the novelty mode's graft-target preference."""
    rows = [(p, w, n) for p, (w, n) in stats.get("pools", {}).items()
            if n >= min_n and n > 0 and (w / n) < max_rate]
    rows.sort(key=lambda r: (r[1] / r[2], -r[2]))
    return rows


def weak_bundles(tdir=None, min_n=5, max_rate=0.5):
    """Weak bundles from finished brackets + vault (same assay as the
    CLI report). [] on any IO problem so callers degrade gracefully."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tdir = tdir or os.path.join(root, "tournaments")
    try:
        recs = vault.scan_vault(silent=True)
        metas = {str(r.get("id", "")): brain_meta(r) for r in recs}
        outcomes = []
        for path in sorted(glob.glob(os.path.join(tdir, "*.json"))):
            if os.path.basename(path).startswith("_"):
                continue
            try:
                with open(path) as f:
                    tourney = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(tourney, dict) or "rounds" not in tourney:
                continue
            outcomes.extend(match_outcomes(tourney))
        return weak_from_stats(tally(outcomes, metas), min_n, max_rate)
    except Exception:
        return []


def main():
    ap = argparse.ArgumentParser(description="Mine wiring-vs-fitness "
                                 "attribution from tournament brackets.")
    ap.add_argument("--dir", default=None,
                    help="tournaments dir (default: <root>/tournaments)")
    ap.add_argument("--min-n", type=int, default=5,
                    help="minimum samples per row (default 5)")
    args = ap.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tdir = args.dir or os.path.join(root, "tournaments")
    recs = vault.scan_vault(silent=True)
    metas = {str(r.get("id", "")): brain_meta(r) for r in recs}
    outcomes = []
    files = 0
    for path in sorted(glob.glob(os.path.join(tdir, "*.json"))):
        if os.path.basename(path).startswith("_"):
            continue
        try:
            with open(path) as f:
                tourney = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(tourney, dict) or "rounds" not in tourney:
            continue
        outcomes.extend(match_outcomes(tourney))
        files += 1
    print(f"brackets: {files}, brains: {len(metas)}")
    print(report(tally(outcomes, metas), args.min_n))


if __name__ == "__main__":
    main()
