import os
import json
import time
import numpy as np


class EvolutionManager:
    """
    Manages generation tournaments, fitness scoring, and neuroevolutionary mutations
    for the dual battle fly brains.
    """
    def __init__(self, checkpoints_dir="checkpoints"):
        self.checkpoints_dir = checkpoints_dir
        os.makedirs(self.checkpoints_dir, exist_ok=True)
        self.generation = 1
        self.history = []

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

    def evaluate_match(self, stats_alpha, stats_beta):
        """
        Computes fitness score for both combatants:
          stats dict contains:
            - kills: int
            - damage_dealt: float
            - damage_taken: float
            - tracking_time_s: float (sight pursuit)
            - tail_time_s: float (rear-aspect chase: behind victim, facing tail)
            - nectar_consumed: float
        Kill-dominance guarantee: positioning terms are hard-capped
        (tracking <= 80, tail <= 120, damage <= ~160) so no amount of
        looking-like-winning can outscore an actual kill (1000). The chase
        decides who wins *given equal kills*, never instead of a kill.
        """
        fitness_a = self.calc_fitness(stats_alpha)
        fitness_b = self.calc_fitness(stats_beta)

        winner = "alpha" if fitness_a >= fitness_b else "beta"
        
        record = {
            "generation": self.generation,
            "timestamp": time.time(),
            "winner": winner,
            "fitness_alpha": fitness_a,
            "fitness_beta": fitness_b,
            "stats_alpha": stats_alpha,
            "stats_beta": stats_beta
        }
        self.history.append(record)
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
