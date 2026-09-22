import os
import json
import time
import numpy as np


class EvolutionManager:
    """
    Manages generation tournaments, fitness scoring, and neuroevolutionary mutations
    for the dual battle fly brains.
    """
    # Genome novelty: frequency-dependent selection for wiring
    # exploration. Pools touched by few past winners pay a bonus, so
    # selection keeps probing new neuro groups instead of fixing the
    # first working wiring. Capped like tracking (never outscores
    # positioning, let alone kills). Counts persist next to checkpoints.
    NOVELTY_PER_POOL = 8.0
    NOVELTY_CAP = 80.0
    NOVELTY_RARE = 3
    POOL_COUNTS_FILE = "evo_pool_counts.json"

    def __init__(self, checkpoints_dir="checkpoints"):
        self.checkpoints_dir = checkpoints_dir
        os.makedirs(self.checkpoints_dir, exist_ok=True)
        self.generation = 1
        self.history = []
        self.pool_counts = self._load_pool_counts()

    def calc_fitness(self, s):
        """Pure fitness score (no history side effects) for mid-round reads."""
        return (
            s.get("kills", 0) * 1000.0
            + min(s.get("damage_dealt", 0.0), 80.0) * 2.0
            - min(s.get("damage_taken", 0.0), 80.0) * 3.0
            + min(s.get("tracking_time_s", 0.0), 10.0) * 8.0
            + min(s.get("tail_time_s", 0.0), 10.0) * 12.0
            + s.get("nectar_consumed", 0.0) * 2.0
        )

    @staticmethod
    def wiring_pools(record_or_params):
        """Connectome pools a brain's wiring touches: genome rule
        sources+targets, frozen-rule expansion of a legacy mix, or empty
        for base. Accepts a vault record or a generator_params dict."""
        gp = (record_or_params.get("generator_params", {})
              if "generator_params" in record_or_params
              else record_or_params) or {}
        pools = set()
        genome = gp.get("genome", None)
        if genome is not None:
            for r in genome.get("rules", []) or []:
                pools.add(str(r.get("source", "")))
                pools.add(str(r.get("target", "")))
            pools.discard("")
            return pools
        from experimental_wiring import FROZEN_GENOMES
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
            for r in frozen["rules"]:
                pools.add(str(r["source"]))
                pools.add(str(r["target"]))
        pools.discard("")
        return pools

    def genome_novelty_bonus(self, pools):
        """+NOVELTY_PER_POOL per touched pool seen <= NOVELTY_RARE times
        in past winners, capped at NOVELTY_CAP."""
        novel = sum(1 for p in pools
                    if self.pool_counts.get(p, 0) <= self.NOVELTY_RARE)
        return min(novel * self.NOVELTY_PER_POOL, self.NOVELTY_CAP)

    def _pool_counts_path(self):
        return os.path.join(self.checkpoints_dir, self.POOL_COUNTS_FILE)

    def _load_pool_counts(self):
        try:
            with open(self._pool_counts_path()) as f:
                data = json.load(f)
            if isinstance(data, dict):
                return {str(k): int(v) for k, v in data.items()}
        except (OSError, ValueError):
            pass
        return {}

    def _save_pool_counts(self):
        try:
            with open(self._pool_counts_path(), "w") as f:
                json.dump(self.pool_counts, f, indent=2)
        except OSError:
            pass

    def evaluate_match(self, stats_alpha, stats_beta, rec_a=None, rec_b=None):
        """
        Computes fitness score for both combatants:
          stats dict contains:
            - kills: int
            - damage_dealt: float
            - damage_taken: float
            - tracking_time_s: float (sight pursuit)
            - tail_time_s: float (rear-aspect chase: behind victim, facing tail)
            - nectar_consumed: float
        Optional rec_a/rec_b vault records add the genome novelty bonus
        (rare pools in past winners pay, capped); omitted records behave
        exactly as before. Kill-dominance guarantee: positioning terms are hard-capped
        (tracking <= 80, tail <= 120, damage <= ~160) so no amount of
        looking-like-winning can outscore an actual kill (1000). The chase
        decides who wins *given equal kills*, never instead of a kill.
        """
        fitness_a = self.calc_fitness(stats_alpha)
        fitness_b = self.calc_fitness(stats_beta)
        nov_a, nov_b = 0.0, 0.0
        if rec_a is not None or rec_b is not None:
            pools_a = self.wiring_pools(rec_a or {})
            pools_b = self.wiring_pools(rec_b or {})
            nov_a = self.genome_novelty_bonus(pools_a)
            nov_b = self.genome_novelty_bonus(pools_b)
            fitness_a += nov_a
            fitness_b += nov_b

        winner = "alpha" if fitness_a >= fitness_b else "beta"

        record = {
            "generation": self.generation,
            "timestamp": time.time(),
            "winner": winner,
            "fitness_alpha": fitness_a,
            "fitness_beta": fitness_b,
            "novelty_alpha": nov_a,
            "novelty_beta": nov_b,
            "stats_alpha": stats_alpha,
            "stats_beta": stats_beta
        }
        self.history.append(record)
        if rec_a is not None or rec_b is not None:
            won_pools = self.wiring_pools(
                rec_a if winner == "alpha" else rec_b or {})
            for p in won_pools:
                self.pool_counts[p] = self.pool_counts.get(p, 0) + 1
            self._save_pool_counts()
        print(f"[Evolution] Gen {self.generation} Finished! Winner: {winner.upper()} "
              f"(Alpha: {fitness_a:.1f}, Beta: {fitness_b:.1f})")

        return winner, fitness_a, fitness_b

    def advance_generation(self, brain_alpha, brain_beta, winner, target_pathway_indices):
        """
        Retains the winning champion brain, creates a mutated offspring,
        and sets up the next 1v1 generation duel.
        """
        if winner == "alpha":
            champion = brain_alpha
            challenger = brain_beta
        else:
            champion = brain_beta
            challenger = brain_alpha

        # Save champion checkpoint
        checkpoint_path = os.path.join(self.checkpoints_dir, f"gen_{self.generation:04d}_champion.npz")
        np.savez_compressed(checkpoint_path, weights=champion.weights)
        print(f"[Evolution] Saved Gen {self.generation} champion to {checkpoint_path}")

        # Reproduce: Challenger inherits Champion's weights with mutations
        challenger.weights = champion.weights.copy()
        challenger.mutate_weights(
            target_pathway_indices,
            mutation_rate=0.08,
            sigma=0.15
        )

        # Reset states for the new round
        champion.reset_state()
        challenger.reset_state()

        self.generation += 1
        print(f"[Evolution] Starting Generation {self.generation}!")

    def save_history(self, filepath="evolution_history.json"):
        with open(filepath, "w") as f:
            json.dump(self.history, f, indent=2)
