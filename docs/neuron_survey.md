# Neuron Survey — how the neurons work and what structures are identifiable

Reference census of the MaleCNS-based brain, measured live on the base
connectome 2026-10-16. Companion to `DOCUMENTATION.md` §3–4 (model and pool
reference); everything below was verified by executing against
`malecns_csr_base.npz` + `populations_mapped.json`, not copied from prose.

## 1. What a neuron is here

Point leaky integrate-and-fire, sparse active-set kernel
(`brain_engine/lif_brain.py:9`, numba-compiled):

- `V_rest −52 mV, V_th −45 mV, V_reset −52 mV, tau_m 20 ms, tau_s 5 ms`
- `dt 0.5 ms × 100 steps` = one 50 ms brain tick; 4-step refractory
- Potassium reset (`Isyn = 0` on spike), synaptic current clamped at ±2.0
- Only `is_active` + stimulated cells are integrated; the rest sit at rest.
  That is what makes 25.6M synapses runnable at ~5 Hz effective control.
- `lif_adaptive_sparse` variant adds per-cell threshold fatigue
  (`adapt_jump/decay/max`); legacy brains never touch it (bit-identical).
- Synapse sign = presynaptic consensus neurotransmitter
  (`brain_engine/connectome_loader.py:19`): GABA/glutamate inhibitory,
  everything else excitatory.
- Weights are the long-term memory; `reset_state()` clears `V/Isyn`, never
  weights. Each fighter owns full weight/state copies.

World → spikes → flight lives in `brain_engine/sensory_motor.py`: the
encoder injects Poisson volleys into sensory pools per 50 ms tick, the
`MotorDecoder` reads motor pools for thrust/yaw/pitch/roll/ram/evade/spear.

What is NOT modeled: morphology, dendritic compartments, gap junctions,
single-cell identity beyond type/side pools. All plasticity is scalar
dopamine scaling of pool efferents, not STDP.

## 2. Identifiable structures (36 pools)

Built by `load_or_extract_populations`
(`brain_engine/connectome_loader.py:77`) from
`connectome_data/malecns_v1/annotations.feather` +
`neurotransmitters.feather`. Side split per row: somaSide → instance
`_L/_R` suffix → rootSide; leftovers are side-unknown and never driven.
Type matches are anchored/exact (`^LC4$`, `^T4a$`, …) so LC40/LPLC4 and
unclear rows can never leak in. Cross-checked vs FlyWire/MANC papers:
1314 DN rows vs 1328 paper DNs, 97 MBONs with full NT coverage, 166,700 =
whole-CNS count.

Counts measured 2026-10-16 (`populations_mapped.json`), with base-wiring
mean |weight| per pool (outgoing-edge magnitudes off the cached CSR):

| System | Pool | Cells (L/R) | Mean |w| |
|---|---|---|---|
| Scent | ORN_DA1 (rival) | 204 (51/105, rest side-unknown) | 4.9 |
| Scent | ORN_VA1v (food odor) | 130 (15/73) | 5.0 |
| Vision | LC10 (target track) | 960 (479/481) | 5.8 |
| Vision | LC4 (rival loom, exact) | 126 (71/55) | 5.7 |
| Vision | LPLC2 (tree loom) | 185 (94/91) | 4.4 |
| Vision | LC11 (small object) | 143 (68/75) | 3.9 |
| Vision | LC15 (loom feature) | 126 (61/65) | 4.1 |
| Vision | LC17 (loom feature) | 353 (178/175) | 7.9 |
| Vision | LC18 (loom feature) | 208 (104/104) | 3.8 |
| Vision | T4a/b/c/d + T5a/b/c/d (flow) | ~1700 each, clean bilateral | ~4.1 |
| Gyro | JO (Johnston's organ) | 672 (348/324, via instance suffix) | 5.2 |
| Motor | descending_all (DN vector) | 1314 (656/648) | 8.1 incoming |
| Motor | DNp09 thrust / DNp20 steer / DNp01 giant fiber / DNpe017 ram | 2 each (1/1) | — |
| Motor | MNad steering | 214 (107/107) | 4.4 |
| Motor | DLMn/DVMn wing power | 24 (12/12) | 1.7 |
| Motor | MNxm mouth (spear) | 6 (3/3) | 1.2 (near-silent) |
| Motor | MNhl roll (haltere) | 21 (11/10) | 1.2 (near-silent) |
| Motor | DNa01-09 ambush poise | 18 (9/9) | 9.1 |
| Motor | VS / HS (wide-field flow) | 34 (16/18) / 8 (4/4) | 6.0 (VS) |
| Value | PAM (appetitive DA) | 316 (158/158) | — |
| Value | PPL1 (aversive DA) | 16 (8/8) | — |
| Value | Kenyon cells | 4064 (flat list) | — |
| Value | MBON all | 97 (48/49) | 6.6–6.8 |
| Value | MBON approach (ACh) / avoid (Glu/GABA) | 50 / 47 | 6.8 / 6.6 |

## 3. Live fire: whole-pool stimulus → one 50 ms tick, base wiring

Method: `FlyBrain` on the cached CSR, `reset_state()`, stimulate with the
full pool id list, `integrate_50ms`, census spikes in DN-L/R, KC, MBON,
MNxm, MN-steer. Measured 2026-10-16:

| Stim (cells) | Spikes | DN L/R | KC | MBON | Mouth/Steer |
|---|---|---|---|---|---|
| DA1 (204) | 1601 | 10/14 | 22 | 2 | 0/0 |
| VA1v (130) | 152 | 0/0 | 0 | 0 | — |
| LC10 (960) | 1170 | 5/4 | 0 | 1 | 0/0 |
| LC4 (126) | 187 | 8/6 | 0 | 0 | 0/0 |
| LPLC2 (185) | 274 | 14/14 | 0 | 0 | 0/0 |
| LC11 (143) | 202 | 0/1 | 0 | 0 | 0/0 |
| LC17 (353) | 445 | 1/2 | 0 | 0 | 0/0 |
| JO (672) | 760 | 12/6 | 0 | 0 | 0/0 |
| T4a (1684) | 1718 | 0/0 | 0 | 0 | 0/0 |
| DN all (1314, control) | 1848 | — | 0 | 0 | — |

Reading: **odor (DA1) is the only input that reaches DNs, KCs, and MBONs
on base wiring** — an unwired fly homes on scent but cannot fight
visually. Motor readouts (mouth/steer) are silent under every probe.

## 4. Direct-edge anatomy (measured on the CSR)

- **LPLC2→DN is 99.9% ipsilateral** (L→L 1109 vs L→R 12; R→R 1059 vs
  R→L 2). Ipsilateral tree-loom drive would steer *into* trees — this
  measurement is the entire justification for the `lplc2_contra_dn`
  overlay (contralateral fanout-16).
- **LC11→DN ≈ 200 sparse edges, mostly ipsilateral; LC11→mouth = 0.**
  Retina features barely touch the motor system (0–1 DN spikes above) —
  hence `retina_wide` (ipsilateral pursuit fanout) and `spear_lunge`
  (frontal lobula → all six MNxm) overlays.
- **DA1→DN = 39 edges; DA1→KC = 0.** KC ignition is indirect (via PNs),
  so it needs convergent drive — consistent with the abandonment-gap
  pattern where 0.1–0.2× sensory pools leave KC/DN silent.
- **T4a→DN = 16 edges; JO→DN = 7614 edges.** Flow cells do not steer
  descending neurons directly at all, while the antennal gyroscope does
  heavily — the `flow_trans` (cruise-trim) vs `gyro_flow` (roll/JO) split
  mirrors this.
- **LC10→DN = 678 direct edges**, yet only 9 DN spikes under full-pool
  stim: edges exist but are weak/subthreshold without convergence.
- **KC→MBON = 61,210 dense edges** — the learned value path is the
  best-wired structure in the brain, which is why dopamine training has
  something to work with even when sensors are weak.

Design rule that falls out: scent and gyro have genuine base-wiring
authority over the descending neurons; vision and flow are anatomically
present but motor-orphaned, and every experimental overlay in
`experimental_wiring.py` exists to repair exactly one of those measured
gaps.

## 5. Caveats

- Whole-pool simultaneous stimulation is saturating, not a natural
  per-tick volley — treat DN counts as upper bounds (the "~0 visual→DN
  spikes per volley" figure in `DOCUMENTATION.md` §5 refers to
  encoder-scale drive, not full-pool stim).
- Single-pool probes miss convergent ignition: dead odor + live vision can
  still leave everything silent together (see `DOCUMENTATION.md` §8,
  abandonment gap).
- VA1v is nearly inert on base wiring (152 spikes, zero downstream) even
  at full-pool scale — odor authority is DA1 specifically.

## 6. Reproducing

```powershell
cd <repo>
# pool sizes:
python -c "import json; p=json.load(open('populations_mapped.json')); ..."
# base mean|w| per pool + live census: brain_engine path on sys.path,
# load_or_build_csr() + load_or_extract_populations(), FlyBrain on the
# cached CSR, reset_state() per probe, integrate_50ms(full pool ids).
# Direct edges: for pre in pool: posts = indices[indptr[pre]:indptr[pre+1]],
# count posts in the target set (single quotes only; PowerShell mangles
# nested double quotes inside python -c).
```

Related: `DOCUMENTATION.md` §3–5 (model, pools, codecs), §7/7b
(wirings/genomes), §8 (dopamine), `brain_engine/diagnose_pools.py`
(vault-wide census), `brain_engine/probe_flight_style.py` (wiring-vs-learned
separation).
