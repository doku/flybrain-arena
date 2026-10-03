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
    # Reflex authority rides the record (breeder-stamped for evo brains,
    # legacy defaults otherwise); training and battles then agree.
    from sensory_motor import BLEND_DEFAULTS
    resolved_blends = {}
    for _bk, _bd in BLEND_DEFAULTS.items():
        resolved_blends[_bk] = _stored(_bk, _bd)
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
        curriculum=_stored("curriculum", None),
        mapping=resolved_mapping,
        yaw_bias=resolved_bias,
        blends=resolved_blends,
        legacy=legacy,
        init_weights=weights,
        progress_cb=progress_cb,
        return_brain=True,
    )
    vault.log_training_session(record, episodes, params, notes)
    # Pre-training score banks here (after episodes update, so avg spans
    # cumulative sessions); scores ride the summary already.
    stamp_train_score(record, summary)
    try:
        if save_path and os.path.isfile(save_path):
            os.remove(save_path)
    except OSError:
        pass
    if save:
        vault.save_brain(record, new_weights)
    return record, new_weights, summary


def train_staged(record, weights, stages, progress_cb=None, save=True):
    """Back-to-back training stages on one record (pre-train, then
    Advanced Flight School, ...).

    stages = [(episodes, params, notes), ...]. Each stage runs train_brain
    on the previous stage's weights, so sessions accumulate on the
    record and the vault saves per stage (earlier work survives a later
    failure; the exception still propagates after banking). Progress is
    rescaled to the combined episode total. Returns
    (record, weights, [summaries]).
    """
    stages = list(stages or [])
    if not stages:
        raise ValueError("train_staged needs at least one stage")
    total = sum(int(ep) for ep, _p, _n in stages)
    done = 0
    summaries = []
    for episodes, params, notes in stages:
        episodes = int(episodes)
        if episodes <= 0:
            continue
        base = done

        def _cb(ep, _total, _base=base):
            if progress_cb is not None:
                progress_cb(_base + ep, total)

        record, weights, summary = train_brain(
            record, weights, episodes, params,
            progress_cb=_cb if progress_cb is not None else None,
            notes=notes, save=save)
        done += episodes
        summaries.append(summary)
    if not summaries:
        raise ValueError("train_staged needs at least one nonzero stage")
    return record, weights, summaries


def _merge_cells(into, table):
    """Sums per-family by_scenario/by_archetype cells across stages
    ({episodes, successes, takedowns, score} each)."""
    if not isinstance(table, dict):
        return
    for fam, cell in table.items():
        if not isinstance(cell, dict):
            continue
        acc = into.setdefault(fam, {"episodes": 0, "successes": 0,
                                    "takedowns": 0, "score": 0.0})
        for k in ("episodes", "successes", "takedowns"):
            try:
                acc[k] = int(acc.get(k, 0)) + int(cell.get(k, 0))
            except (TypeError, ValueError):
                pass
        try:
            acc["score"] = float(acc.get("score", 0.0)) + float(
                cell.get("score", 0.0))
        except (TypeError, ValueError):
            pass


def merge_summaries(summaries):
    """Combined multi-stage verdict summary: summed episodes/successes
    (plus any takedown/strike counters and pre-training scores stages
    report), merged per-scenario cells across stages (both stages
    schooled, so both count), and the per-stage list."""
    out = {"stages": list(summaries), "episodes": 0, "successes": 0,
           "score": 0.0, "by_scenario": {}, "by_archetype": {}}
    for s in summaries:
        if not isinstance(s, dict):
            continue
        out["episodes"] += int(s.get("episodes", 0))
        out["successes"] += int(s.get("successes", 0))
        out["score"] += float(s.get("score", 0.0))
        for k in ("takedowns", "strikes", "crashes"):
            if k in s:
                out[k] = int(out.get(k, 0)) + int(s.get(k, 0))
        _merge_cells(out["by_scenario"], s.get("by_scenario"))
        _merge_cells(out["by_archetype"], s.get("by_archetype"))
    out["avg_score"] = out["score"] / max(out["episodes"], 1)
    return out


def stamp_scenario_scores(record, by_scenario):
    """Accumulates per-family scenario points onto the record
    (training["scenario_scores"][family] = {score, episodes}), so
    later probes enrich rather than overwrite. Returns the record."""
    if not isinstance(by_scenario, dict):
        return record
    training = record.setdefault("training", {})
    table = training.setdefault("scenario_scores", {})
    for combo, cell in by_scenario.items():
        if not isinstance(cell, dict):
            continue
        try:
            eps = int(cell.get("episodes", 0))
            sc = float(cell.get("score", 0.0))
        except (TypeError, ValueError):
            continue
        if eps <= 0:
            continue
        for part in str(combo).upper().split("+"):
            part = part.strip()
            if not part:
                continue
            acc = table.setdefault(part, {"score": 0.0, "episodes": 0})
            try:
                acc["score"] = float(acc.get("score", 0.0)) + sc
                acc["episodes"] = int(acc.get("episodes", 0)) + eps
            except (TypeError, ValueError):
                pass
    return record


def stamp_train_score(record, summary):
    """Banks the pre-training score on the record: score accumulates
    across training sessions (like episodes), avg_score is recomputed
    over cumulative episodes, recent form tracks the last
    RECENT_EPISODES episodes, and per-scenario cells accumulate into
    training["scenario_scores"] when the summary carries them.
    Pre-score records (no score key) tolerate missing summaries (score
    unchanged). Returns the record."""
    if not isinstance(summary, dict):
        return record
    training = record.setdefault("training", {})
    gained = float(summary.get("score", 0.0))
    training["score"] = float(training.get("score", 0.0)) + gained
    episodes = int(training.get("episodes", 0))
    training["avg_score"] = (float(training["score"]) / max(episodes, 1))
    session_eps = int(summary.get("episodes", 0) or 0)
    if session_eps > 0:
        _roll_recent_form(training, session_eps,
                          gained / max(session_eps, 1))
    stamp_scenario_scores(record, summary.get("by_scenario"))
    return record


RECENT_EPISODES = 20  # recent-form window: mean over the last N eps.


def _roll_recent_form(training, session_episodes, session_avg):
    # Exact window mean: filling each banked episode with its session
    # mean keeps the window sum exact (within-session variance is
    # invisible at this granularity - the stamping layer only ever
    # sees session totals). Degenerate sessions (0 eps) never reach
    # here; legacy rings self-heal to a list below.
    ring = training.get("recent")
    if not isinstance(ring, list):
        ring = []
    ring.extend([float(session_avg)] * int(session_episodes))
    del ring[:-RECENT_EPISODES]
    training["recent"] = ring
    if ring:
        training["recent_avg"] = sum(ring) / len(ring)


def generate_and_train(name, episodes, params=None, progress_cb=None):
    """Creates a vault brain and trains it from fresh weights."""
    params = dict(params or {})
    record = vault.new_record(name, params)
    weights = fresh_weights(params.get("experiment"), params.get("genome"))
    record, weights, summary = train_brain(
        record, weights, episodes, params,
        progress_cb=progress_cb, notes="initial training", save=True)
    return record, weights, summary
