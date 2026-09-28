import os
import time
import numpy as np
from numba import njit

from connectome_loader import load_or_build_csr, load_or_extract_populations


@njit(fastmath=True)
def lif_integrate_sparse(
    V, Isyn, refractory, is_active,
    active_buffer,
    indptr, indices, data,
    stim_indices,
    next_buffer,
    current_spikes,
    steps=100,
    dt=0.5,
    tau_m=20.0,
    tau_s=5.0,
    v_rest=-52.0,
    v_th=-45.0,
    v_reset=-52.0,
    ref_steps=4,
    syn_gain=0.008,
    unit_syn_mv=0.275,
    max_isyn=2.0
):
    """
    Simulates discrete time steps (e.g. 100 steps * 0.5 ms = 50 ms).
    Only iterates over actively depolarized or stimulated neurons.
    Includes physiological potassium reset and synaptic current bounds.
    """
    alpha_m = np.exp(-dt / tau_m)
    alpha_s = np.exp(-dt / tau_s)
    weight_scale = unit_syn_mv * syn_gain
    max_buf_len = len(active_buffer)

    n_active = 0
    # Continuity: every cell still flagged from prior ticks rejoins the
    # working set FIRST. The buffer is local per call, so without this only
    # fresh stim ever entered - the network fired one cascade then froze
    # (flags stayed set on 30k+ cells that were never integrated again).
    # O(n) scan, negligible next to the step loop. Buffer holds at most
    # num_neurons entries and flagged cells are at most num_neurons.
    for i in range(len(is_active)):
        if is_active[i]:
            active_buffer[n_active] = np.int32(i)
            n_active += 1
    # Add external stimulus neurons to active set and drive action potentials
    for s in range(len(stim_indices)):
        idx = stim_indices[s]
        V[idx] = v_th + 0.5
        if not is_active[idx]:
            is_active[idx] = True
            active_buffer[n_active] = idx
            n_active += 1

    next_count = 0
    spike_count = 0
    # Scratch buffers arrive preallocated from the brain instance (see
    # FlyBrain.__init__): per-call np.empty of 2 x num_neurons was
    # ~1.3 MB of allocation churn per 50 ms tick.
    spike_record = []

    for step in range(steps):
        next_count = 0
        spike_count = 0

        # 1. Update only active neurons
        for a in range(n_active):
            idx = active_buffer[a]
            if refractory[idx] > 0:
                refractory[idx] -= 1
                V[idx] = v_reset
                Isyn[idx] *= alpha_s
                next_buffer[next_count] = idx
                next_count += 1
            else:
                Isyn[idx] *= alpha_s
                V[idx] = v_rest + (V[idx] - v_rest) * alpha_m + Isyn[idx]

                if V[idx] >= v_th:
                    V[idx] = v_reset
                    Isyn[idx] = 0.0 # Potassium reset
                    refractory[idx] = ref_steps
                    current_spikes[spike_count] = idx
                    spike_count += 1
                    spike_record.append(idx)
                    next_buffer[next_count] = idx
                    next_count += 1
                elif abs(V[idx] - v_rest) > 0.05 or abs(Isyn[idx]) > 0.001:
                    next_buffer[next_count] = idx
                    next_count += 1
                else:
                    # Returned to resting equilibrium
                    V[idx] = v_rest
                    Isyn[idx] = 0.0
                    is_active[idx] = False

        # 2. Propagate spikes to postsynaptic targets
        for s in range(spike_count):
            pre = current_spikes[s]
            start = indptr[pre]
            end = indptr[pre + 1]
            for c in range(start, end):
                post = indices[c]
                w = data[c]
                new_i = Isyn[post] + w * weight_scale
                if new_i > max_isyn:
                    new_i = max_isyn
                elif new_i < -max_isyn:
                    new_i = -max_isyn
                Isyn[post] = new_i

                if not is_active[post] and next_count < max_buf_len:
                    is_active[post] = True
                    next_buffer[next_count] = post
                    next_count += 1

        # Swap buffers for next time step
        n_active = next_count
        for i in range(n_active):
            active_buffer[i] = next_buffer[i]

    return np.array(spike_record, dtype=np.int32)


class FlyBrain:
    """
    Independent Leaky Integrate-and-Fire brain instance for a single fly.
    Uses sparse active-set tracking with physiological potassium reset.
    """
    def __init__(self, indptr, indices, data, num_neurons=166700, dt=0.5):
        self.num_neurons = num_neurons
        self.dt = dt

        # Synaptic connections (independent in-memory copy for evolution)
        self.indptr = np.ascontiguousarray(indptr, dtype=np.int32)
        self.indices = np.ascontiguousarray(indices, dtype=np.int32)
        self.weights = np.ascontiguousarray(data, dtype=np.float32)

        # State vectors
        self.V = np.full(num_neurons, -52.0, dtype=np.float32)
        self.Isyn = np.zeros(num_neurons, dtype=np.float32)
        self.refractory = np.zeros(num_neurons, dtype=np.int16)
        self.is_active = np.zeros(num_neurons, dtype=np.bool_)
        self.active_buffer = np.zeros(num_neurons, dtype=np.int32)
        # Scratch buffers for the integration kernel (preallocated once:
        # per-call np.empty of 2 x num_neurons was churn per 50 ms tick).
        self.next_buffer = np.zeros(num_neurons, dtype=np.int32)
        self.current_spikes = np.zeros(num_neurons, dtype=np.int32)

    def reset_state(self):
        """Reset membrane states back to rest."""
        self.V.fill(-52.0)
        self.Isyn.fill(0.0)
        self.refractory.fill(0)
        self.is_active.fill(False)

    def integrate_50ms(self, stim_indices):
        """Integrates 50 ms of brain activity (100 steps * 0.5 ms)."""
        return lif_integrate_sparse(
            self.V, self.Isyn, self.refractory, self.is_active,
            self.active_buffer,
            self.indptr, self.indices, self.weights,
            stim_indices,
            self.next_buffer, self.current_spikes,
            steps=int(50.0 / self.dt),
            dt=self.dt
        )

    def mutate_weights(self, pathway_presynaptic_indices, mutation_rate=0.08, sigma=0.15):
        """Mutates synaptic weights along targeted pathway neurons."""
        for pre in pathway_presynaptic_indices:
            start = self.indptr[pre]
            end = self.indptr[pre + 1]
            if start < end:
                count = end - start
                mask = np.random.rand(count) < mutation_rate
                if np.any(mask):
                    noise = 1.0 + np.random.normal(0.0, sigma, size=np.sum(mask)).astype(np.float32)
                    target_indices = np.where(mask)[0] + start
                    self.weights[target_indices] *= noise


if __name__ == "__main__":
    print("[FlyBrain] Loading connectome and populations...")
    csr = load_or_build_csr()
    pops = load_or_extract_populations()

    print("[FlyBrain] Instantiating dual independent brains (Fly Alpha & Fly Beta)...")
    t0 = time.time()
    brain_alpha = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
    brain_beta = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
    print(f"[FlyBrain] Both brains instantiated in {time.time()-t0:.2f}s!")

    # JIT Warmup
    print("[FlyBrain] Compiling sparse active Numba kernel...")
    t_compile = time.time()
    warmup_stim = np.array(pops["pheromone_da1"]["left"][:5], dtype=np.int32)
    brain_alpha.integrate_50ms(warmup_stim)
    print(f"[FlyBrain] Compilation finished in {time.time()-t_compile:.2f}s!")

    # Benchmark with active rival pheromone + visual tracking stimulus
    stim_a = np.array(pops["pheromone_da1"]["left"] + pops["visual_lc10"]["left"][:15], dtype=np.int32)
    stim_b = np.array(pops["pheromone_da1"]["right"] + pops["visual_lc10"]["right"][:15], dtype=np.int32)

    print("[FlyBrain] Running benchmark (10 ticks x 50 ms brain time)...")
    times_a = []
    times_b = []
    for tick in range(10):
        t_start = time.time()
        spikes_a = brain_alpha.integrate_50ms(stim_a)
        times_a.append(time.time() - t_start)

        t_start = time.time()
        spikes_b = brain_beta.integrate_50ms(stim_b)
        times_b.append(time.time() - t_start)

    avg_a = np.mean(times_a) * 1000.0
    avg_b = np.mean(times_b) * 1000.0
    print(f"[FlyBrain] Benchmark results with calibrated sparse active-set:")
    print(f"  Fly Alpha: {avg_a:.2f} ms per 50 ms brain tick (Target: <50 ms)")
    print(f"  Fly Beta:  {avg_b:.2f} ms per 50 ms brain tick")
    print(f"  Total dual compute: {avg_a + avg_b:.2f} ms")
