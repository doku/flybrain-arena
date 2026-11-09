# Contributing

Thanks for your interest in Battle Fly Arena! This is a research-y game:
Python neuro-server + Godot 4 arena, driven by the MaleCNS connectome.

## Getting set up

```bash
git clone <repo-url>
cd flybrain
pip install numpy scipy pandas pyarrow numba
python setup.py        # downloads the ~1.2 GB MaleCNS connectome (once)
python launch_battle.py
```

See the [README](README.md) for the full quickstart and CLI usage.

## Running the tests

```bash
python tests/test_suite.py     # full suite (takes several minutes)
```

Godot-side tests: `arena/tests/`, run headless via
`tools/godot/Godot_v4.7.2-stable_win64_console.exe --path arena --headless`.

## Where things live

| Path | What |
|---|---|
| `brain_engine/` | LIF kernel, connectome loader, learning, evolution, vault CLI |
| `arena/scripts/` | Godot game logic (menu, arena, tournament, physics) |
| `tests/` | Python test suite |
| `docs/` | Neuron survey, post-mortems, screenshots |
| `DOCUMENTATION.md` | Architecture + UDP protocol reference |

## Pull requests

- Keep PRs focused; one change per PR.
- Run `python tests/test_suite.py` before opening — CI runs the same suite.
- **Never commit data**: `brains/`, `checkpoints/`, `connectome_data/`,
  `malecns_csr_base.npz`, tournament state, and logs are gitignored. If your
  change touches them, say so in the PR description.
- GDScript changes: keep style consistent with the surrounding file
  (tabs, snake_case, `_private` prefix for internals).
- Python changes: match the existing style in `brain_engine/`.

## Reporting bugs

Open an issue with:
1. What you did (commands / menu clicks)
2. What you expected vs what happened
3. `python brain_engine/brain_server.py` console output (if server-related)
4. Godot console output (if arena-related)

## Ideas welcome

See `docs/neuron_survey.md` for the current state of the neural pools and
known gaps. Tournament formats, new sensory mappings, and arena features are
all fair game.
