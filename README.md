# Battle Fly Arena

Two fruit flies, each driven by its own **whole-brain spiking neural network** —
the complete 166,700-neuron, ~25.6M-synapse **MaleCNS connectome** of *Drosophila
melanogaster* — duel in a 3D forest arena. Scent tracking, visual pursuit, spike
jousting, wing tears, knockouts. After every battle, dopamine reinforcement
rewires the loser's synapses, and an evolution loop breeds the next generation.

```
Godot 4 arena (arena/)  <-- UDP 127.0.0.1:9999 -->  Python neuro-server (brain_engine/)
  FlyPhysics x2 (bodies)        20 Hz sensory steps    2x LIF brain (166,700 neurons each)
  ArenaManager / TournamentDirector                   dopamine learning + evolution + vault
```

## Quickstart

```bat
:: Windows — boots the neuro-server, then the Godot arena at the vault menu
launch_battle.bat
:: or
python launch_battle.py
```

- **Free battle** — classic evolution: generational clone/mutate duels.
- **Tournament** — pick >= 2 brains from the vault, single elimination, best-of-N
  per match (optional losers bracket).
- **Generate / Train** — mint new brains (variant, seed, wiring mix, mapping) and
  train them headlessly; the menu shows live progress.
- **Continuous mode** — eternal back-to-back tournaments: each generation archives
  the biggest loser and breeds a winner-clone plus a random wildcard.

Full mechanics, protocol, and pool reference: [`DOCUMENTATION.md`](DOCUMENTATION.md).

## Requirements

| Component | Version | Notes |
|---|---|---|
| Python | 3.10+ | `numpy`, `scipy`, `pandas`, `pyarrow`, `numba` |
| Godot | 4.7.2 | Windows binaries bundled in `tools/godot/` (gitignored; download from godotengine.org for other platforms) |
| Connectome data | MaleCNS v1.0 | ~1.1 GB of feather tables, see below |
| RAM / CPU | ~8+ GB RAM | a dual-brain tick costs ~140-210 ms on reference hardware |

```bash
pip install numpy scipy pandas pyarrow numba
```

## Connectome data (not in this repo)

The brain is built from the **MaleCNS v1.0** connectome (Berg et al., *Cell* 2026;
166,700 neurons, 25.6M edges). Download the flat-connectome tables and place them in
`connectome_data/malecns_v1/`:

```
connectome_data/malecns_v1/
  annotations.feather        # cell type, side, ROI per neuron
  neurotransmitters.feather  # consensus neurotransmitter per neuron
  edges.feather              # synaptic edges (pre, post, weight)
```

Sources:
- https://male-cns.janelia.org/download (primary, `gs://flyem-male-cns/v1.0/connectome-data/flat-connectome/`)
- https://github.com/flyconnectome/2025malecns (derived data for the paper)
- Interactive: https://neuprint.janelia.org (dataset `male-cns:v1.0`)

On first run the loader builds a cached CSR matrix (`malecns_csr_base.npz`, ~83 MB,
gitignored) and the derived `populations_mapped.json` (tracked, regenerable).

## Repository layout

```
arena/            Godot 4 project: scenes, scripts (GDScript), shaders, audio, models
brain_engine/     Python neuro-server: LIF kernel, connectome loader, sensory/motor
                  codecs, dopamine learning, evolution, vault (.flybrain packages)
tests/            Python test suite (tests/test_suite.py)
docs/             Neuron survey + post-mortems
launch_battle.py  One-command launcher (server + arena)
DOCUMENTATION.md  Full architecture, protocol, and neuron-pool reference
```

**Data policy:** git tracks code and config only. Raw connectome data, the CSR
cache, checkpoints, the brain vault (`brains/`), tournament state, Godot binaries,
and logs are all gitignored — back them up by copying the folders.

## Testing

```bash
python tests/test_suite.py        # connectome, LIF, sensory-motor, mappings,
                                  # evolution, UDP integration, vault, trainer contract
```

Godot-side tests live in `arena/tests/` and run via headless scene runs.

## Credits & licenses

- **Connectome:** Berg et al. 2025, MaleCNS v1.0 — CC-BY (https://male-cns.janelia.org)
- **Fly body meshes:** derived from TuragaLab/flybody, Apache-2.0 — see
  [`arena/models/ATTRIBUTION.md`](arena/models/ATTRIBUTION.md)
- **Audio:** Kenny.nl SFX pack (CC0) — see `arena/audio/`
- This project's code: MIT
