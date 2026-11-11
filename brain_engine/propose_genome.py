#!/usr/bin/env python3
"""propose_genome.py — AI-assisted fly-brain genome proposer.

Builds a validated wiring genome (projection rules over the mapped MaleCNS
pools) from the two strongest evidence sources in the project:

  1. the current vault leaders (their stored genomes + ELO), and
  2. the tournament attribution miner (which pools/rules actually win).

Output is a genome envelope JSON ready for:
    python vault_cli.py generate --name MyFly --episodes 50 \
        --params '{"genome": <this json>, ...}'
or --genome '<json string>' on the generate subcommand.

Usage:
    python propose_genome.py                     # propose from vault+miner
    python propose_genome.py --n-rules 8 --seed 1234
    python propose_genome.py --parents fb840ce3 c327c1e6   # bias to these brains
    python propose_genome.py --out genome.json --print
"""
import argparse
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import experimental_wiring as ew
from connectome_loader import load_or_extract_populations

PROJECT_ROOT = os.path.dirname(HERE)
VAULT_DIR = os.environ.get("FLY_VAULT_DIR", os.path.join(PROJECT_ROOT, "brains"))
TOURNAMENTS = os.path.join(PROJECT_ROOT, "tournaments")


def load_vault():
    """All vault brain records, sorted by elo desc."""
    brains = []
    for fn in sorted(os.listdir(VAULT_DIR)):
        if not fn.endswith(".record.json"):
            continue
        try:
            with open(os.path.join(VAULT_DIR, fn)) as f:
                rec = json.load(f)
            rec["_file"] = fn
            brains.append(rec)
        except Exception:
            pass
    brains.sort(key=lambda b: float((b.get("record", {}) or {}).get("elo", 0)),
                  reverse=True)
    return brains


def pool_winrates(min_n=3):
    """Run the attribution miner over finished tournaments.

    Returns {pool: winrate} for pools seen in exactly-one-side matches.
    """
    import mine_wiring_fitness as mw
    outcomes = []
    metas = {}
    for fn in sorted(os.listdir(TOURNAMENTS)) if os.path.isdir(TOURNAMENTS) else []:
        if not fn.endswith(".json") or fn.startswith("E") or fn.startswith("_"):
            continue
        try:
            with open(os.path.join(TOURNAMENTS, fn)) as f:
                t = json.load(f)
        except Exception:
            continue
        outcomes.extend(mw.match_outcomes(t))
    for rec in load_vault():
        metas[str(rec.get("id", ""))] = mw.brain_meta(rec)
    stats = mw.tally(outcomes, metas)
    rates = {}
    for pool, (w, n) in stats.get("pools", {}).items():
        if n >= min_n:
            rates[pool] = w / n
    return rates, stats.get("matches", 0)


def parent_genomes(brains, parent_ids, top_k=5):
    """Collect genome rule-sets from the top vault brains (optionally
    restricted to --parents ids)."""
    rules = []
    seen = set()
    chosen = [b for b in brains
              if (not parent_ids or str(b.get("id", "")) in parent_ids)]
    for b in chosen[:top_k]:
        g = ((b.get("generator_params", {}) or {}).get("genome")
             or (b.get("params", {}) or {}).get("genome"))
        if not g:
            continue
        gid = ew.genome_id(g)
        if gid in seen:
            continue
        seen.add(gid)
        rules.extend(g.get("rules", []))
    return rules


def propose(rng, registry, winrates, parent_rules, n_rules):
    """Compose a genome: mix of parent-derived rules (mutated) and
    winrate-biased fresh rules."""
    sensory = sorted(p for p, m in registry.items() if m["role"] == "sensory")
    targets = sorted(p for p, m in registry.items()
                     if m["role"] in ew.GENOME_TARGET_ROLES)

    def fresh_rule(stream_idx):
        # bias source choice by winrate of sensory pools
        src_weights = [0.3 + 2.0 * winrates.get(s, 0.5) for s in sensory]
        src = rng.choices(sensory, weights=src_weights, k=1)[0]
        # bias target choice by winrate of motor/central pools
        tgt_weights = [0.3 + 2.0 * winrates.get(t, 0.5) for t in targets]
        tgt = rng.choices(targets, weights=tgt_weights, k=1)[0]
        return {
            "source": src,
            "source_side": rng.choice(["left", "right"]),
            "target": tgt,
            "target_side": rng.choice(["left", "right"]),
            "sign": 1.0 if rng.random() < 0.85 else -1.0,
            "weight": round(rng.uniform(80.0, 350.0), 1),
            "fanout": rng.randint(3, 13),
            "topography": "random",
            "stream": "g%d" % stream_idx,
            "stream_seed": rng.randrange(0, 2 ** 31),
        }

    def mutate(rule, stream_idx):
        r = dict(rule)
        r["stream"] = "g%d" % stream_idx
        r["stream_seed"] = rng.randrange(0, 2 ** 31)
        if rng.random() < 0.4:
            r["weight"] = round(max(20.0, min(ew.MAX_RULE_WEIGHT,
                                 r["weight"] * rng.uniform(0.7, 1.4))), 1)
        if rng.random() < 0.3:
            r["fanout"] = max(1, min(ew.MAX_RULE_FANOUT,
                              r["fanout"] + rng.randint(-3, 3)))
        if rng.random() < 0.2:
            r["target"] = rng.choice(targets)
        if rng.random() < 0.15:
            r["sign"] = -r["sign"]
        return r

    rules = []
    i = 0
    # 50% mutated parent rules, 50% fresh winrate-biased rules
    n_parent = min(len(parent_rules), n_rules // 2)
    if parent_rules:
        for r in rng.sample(parent_rules, k=n_parent):
            rules.append(mutate(r, i)); i += 1
    while len(rules) < n_rules:
        rules.append(fresh_rule(i)); i += 1
    rng.shuffle(rules)
    for j, r in enumerate(rules):  # renumber streams in final order
        r["stream"] = "g%d" % j
    return {"name": "ai-proposed", "rules": rules}


def main():
    ap = argparse.ArgumentParser(description="Propose a wiring genome from vault + tournament evidence")
    ap.add_argument("--n-rules", type=int, default=6)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--parents", nargs="*", default=[], help="vault brain ids to bias toward")
    ap.add_argument("--top-k", type=int, default=5, help="how many top vault brains to mine")
    ap.add_argument("--out", default="", help="write genome JSON here")
    ap.add_argument("--print", action="store_true", help="print genome JSON to stdout")
    args = ap.parse_args()

    seed = args.seed or random.SystemRandom().randrange(1, 2 ** 31)
    rng = random.Random(seed)
    pops = load_or_extract_populations()
    registry = ew.build_pool_registry(pops)

    brains = load_vault()
    print(f"[propose] vault: {len(brains)} brains; top elo: "
          f"{brains[0].get('name')} ({float((brains[0].get('record',{}) or {}).get('elo',0)):.0f})"
          if brains else "[propose] vault empty", file=sys.stderr)

    winrates, n_matches = pool_winrates()
    print(f"[propose] attribution: {n_matches} scored matches, "
          f"{len(winrates)} pools with n>=3", file=sys.stderr)
    if winrates:
        best = sorted(winrates.items(), key=lambda kv: -kv[1])[:5]
        print("[propose] top win-rate pools: " +
              ", ".join(f"{p} {w:.2f}" for p, w in best), file=sys.stderr)

    prules = parent_genomes(brains, set(args.parents), args.top_k)
    print(f"[propose] mined {len(prules)} parent rules from top {args.top_k}",
          file=sys.stderr)

    genome = propose(rng, registry, winrates, prules, args.n_rules)
    # validate through the project's own validator
    genome = ew.validate_genome(genome)
    gid = ew.genome_id(genome)
    mapping = list(ew.derive_mapping(genome))
    print(f"[propose] genome_id={gid} rules={len(genome['rules'])} "
          f"derived_mapping={mapping}", file=sys.stderr)

    text = json.dumps(genome)
    if args.out:
        with open(args.out, "w") as f:
            f.write(json.dumps(genome, indent=2))
        print(f"[propose] wrote {args.out}", file=sys.stderr)
    if args.print or not args.out:
        print(text)


if __name__ == "__main__":
    main()
