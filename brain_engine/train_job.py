"""Headless training jobs for managed (.flybrain) brains.

Wraps train_homing.run_training so the vault UI (or a tournament) can:
  - generate fresh weights (base connectome, optional experiment overlay)
  - train an existing brain's weights for X episodes with selectable params
  - report per-episode progress via callback (for progress bars / polling)
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from connectome_loader import load_or_build_csr, load_or_extract_populations
from experimental_wiring import experiment_arrays, build_genome_arrays
from train_homing import run_training
import brain_package as vault


def fresh_weights(experiment=None, genome=None):
    """Untrained starting weights (base connectome + optional overlay or
    genome; genome wins when both are given)."""
    csr = load_or_build_csr()
    pops = load_or_extract_populations()
    if genome is not None:
        _, _, wbasis = build_genome_arrays(genome, csr, pops)
    else:
        _, _, wbasis = experiment_arrays(experiment, csr, pops)
    return np.ascontiguousarray(np.asarray(wbasis, dtype=np.float32).copy())


def train_brain(record, weights, episodes, params=None, progress_cb=None,
                notes="", save=True):
    """Trains weights for `episodes` episodes; returns (record, weights, summary).

    params keys: seed, learning_rate, dist_gain, align_bonus, evasion,
    experiment, mapping, variant. Uses variant='custom' so caller params
    win over the A/B presets in train_homing.VARIANTS. Mapping-less
    records train in the legacy regime unless params carries an explicit
    mapping (which graduates and stamps the record).
    """
    params = dict(params or {})
    params.setdefault("variant", "custom")
    stored = record.get("generator_params", {}) or {}
    # Genome envelope (parallels experiment): explicit params win, else
    # the record's stored genome, else None (base/legacy wiring).
    resolved_genome = params.get("genome", None)
    if resolved_genome is None:
        resolved_genome = stored.get("genome", None)

    def _stored(key, default):
        # Explicit None means "not specified": fall back to the record's
        # stored value. Without this, a caller sending e.g.
        # {"experiment": null} silently retrains an experiment brain on the
        # base wiring, and run_training aborts with an arity mismatch
        # before episode 1 (the stuck-at-0/50 training bug).
        v = params.get(key, None)
        if v is None:
            v = stored.get(key, default)
        return default if v is None else v

    # Regime: brains whose record predates the 'mapping' key train and
    # fight in the legacy regime — unless the caller explicitly passes a
    # mapping, which graduates the brain to the current stack (its record
    # is stamped so battles, retrains, and the menu all agree from then
    # on). This keeps neuro-mappings opt-in for old brains.
    resolved_mapping = _stored("mapping", None)
    if params.get("mapping", None) is not None:
        legacy = False
        record.setdefault("generator_params", {})["mapping"] = params["mapping"]
    else:
        legacy = "mapping" not in stored and resolved_mapping is None
    # Yaw bias graduates the same way: an explicitly passed value stamps
    # the record so training, battles, and the menu agree from then on.
    resolved_bias = _stored("yaw_bias", None)
    if params.get("yaw_bias", None) is not None:
        record.setdefault("generator_params", {})["yaw_bias"] = params["yaw_bias"]
    from train_homing import CHECKPOINTS_DIR
    os.makedirs(os.path.join(CHECKPOINTS_DIR, "tmp"), exist_ok=True)
    tmp_name = os.path.join("tmp", f"train_{record['id']}.npz")
    save_path, new_weights, summary = run_training(
        num_episodes=int(episodes),
        variant=params.get("variant") or "custom",
        save_name=tmp_name,
        # Godot's JSON parser turns every number into a float, so seeds
        # arriving via the menu are e.g. 9999.0; np.random.seed(float)
        # raises "Cannot cast scalar ... 'safe'" on NumPy 2.
        seed=int(_stored("seed", 0)),
        target_evasion=_stored("evasion", 0.2),
        learning_rate=_stored("learning_rate", 0.008),
        dist_gain=_stored("dist_gain", 0.15),
        align_bonus=tuple(_stored("align_bonus", (0.5, 0.2, -0.3))),
        experiment=_stored("experiment", None),
        genome=resolved_genome,
        mapping=resolved_mapping,
        yaw_bias=resolved_bias,
        legacy=legacy,
        init_weights=weights,
        progress_cb=progress_cb,
        return_brain=True,
    )
    vault.log_training_session(record, episodes, params, notes)
    try:
        if save_path and os.path.isfile(save_path):
            os.remove(save_path)
    except OSError:
        pass
    if save:
        vault.save_brain(record, new_weights)
    return record, new_weights, summary


def generate_and_train(name, episodes, params=None, progress_cb=None):
    """Creates a vault brain and trains it from fresh weights."""
    params = dict(params or {})
    record = vault.new_record(name, params)
    weights = fresh_weights(params.get("experiment"), params.get("genome"))
    record, weights, summary = train_brain(
        record, weights, episodes, params,
        progress_cb=progress_cb, notes="initial training", save=True)
    return record, weights, summary
