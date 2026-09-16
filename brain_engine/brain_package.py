"""Portable fly-brain packages (.flybrain files) + local vault management.

A .flybrain file is a zip containing:
  - weights.npz : numpy archive with a single 'weights' float32 array
  - brain.json  : metadata (name, id, generator params, record, training log)

The vault (PROJECT_ROOT/brains/) is scanned on load: dropping a .flybrain
file in (or restoring one from backup) re-registers it automatically.
All writes are atomic (temp + rename) with a .bak of the previous version.
"""
import io
import json
import os
import re
import shutil
import tempfile
import time
import zipfile
from datetime import datetime, timezone

import numpy as np

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAULT_DIR = os.path.join(PROJECT_ROOT, "brains")
VAULT_INDEX = os.path.join(VAULT_DIR, "vault_index.json")

WEIGHTS_ENTRY = "weights.npz"
META_ENTRY = "brain.json"
PACKAGE_EXT = ".flybrain"

DEFAULT_GENERATOR_PARAMS = {
    "variant": "custom",
    "seed": 0,
    "learning_rate": 0.008,
    "dist_gain": 0.15,
    "align_bonus": [0.5, 0.2, -0.3],
    "evasion": 0.2,
    "experiment": None,
    "mapping": None,
}


def _utcnow():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _new_id():
    return "%08x" % (int(time.time() * 1000) & 0xFFFFFFFF)


def _sanitize_name(name):
    clean = re.sub(r"[^A-Za-z0-9 _-]+", "", (name or "").strip())
    clean = re.sub(r"\s+", "_", clean).strip("_")
    return clean[:40] or "Unnamed"


def new_record(name, params=None):
    """Builds a fresh brain metadata record (no weights)."""
    merged = dict(DEFAULT_GENERATOR_PARAMS)
    if params:
        merged.update({k: v for k, v in params.items() if k in merged})
    brain_id = _new_id()
    safe = _sanitize_name(name)
    return {
        "id": brain_id,
        "name": safe,
        "filename": f"{safe}_{brain_id}{PACKAGE_EXT}",
        "created_utc": _utcnow(),
        "generator_params": merged,
        "record": {"battles": 0, "wins": 0, "losses": 0, "draws": 0,
                   "matches": 0, "matches_won": 0, "matches_lost": 0,
                   "tournaments_won": 0},
        "training": {"episodes": 0, "sessions": []},
        "lineage": {"parent_ids": [], "source": "generated"},
    }


def package_path(record_or_filename):
    name = (record_or_filename.get("filename") if isinstance(record_or_filename, dict)
            else record_or_filename)
    return os.path.join(VAULT_DIR, name)


def save_brain(record, weights, backup=True, fast=False):
    """Atomically writes record+weights to the vault (keeps .bak unless
    backup=False, used for hot per-battle tournament saves). fast=True
    skips deflate (np.savez + ZIP_STORED): ~8x quicker per save on
    25M-synapse brains, which is what keeps battle reporting under the
    arena's confirm deadline. Files are bigger (~100 vs ~19 MB) but load
    identically; cold paths (generate/train) stay compressed."""
    os.makedirs(VAULT_DIR, exist_ok=True)
    path = package_path(record)
    weights = np.ascontiguousarray(np.asarray(weights), dtype=np.float32)

    fd, tmp = tempfile.mkstemp(suffix=".tmp", dir=VAULT_DIR)
    os.close(fd)
    try:
        compression = zipfile.ZIP_STORED if fast else zipfile.ZIP_DEFLATED
        with zipfile.ZipFile(tmp, "w", compression) as zf:
            buf = io.BytesIO()
            if fast:
                np.savez(buf, weights=weights)
            else:
                np.savez_compressed(buf, weights=weights)
            zf.writestr(WEIGHTS_ENTRY, buf.getvalue())
            zf.writestr(META_ENTRY, json.dumps(record, indent=2))
        if os.path.exists(path) and backup:
            shutil.copyfile(path, path + ".bak")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    refresh_index()
    return path


def load_brain(path_or_id):
    """Loads (record, weights) by vault id, filename, or absolute path."""
    path = _resolve(path_or_id)
    with zipfile.ZipFile(path, "r") as zf:
        names = set(zf.namelist())
        if WEIGHTS_ENTRY not in names or META_ENTRY not in names:
            raise ValueError(f"{path} is not a valid .flybrain package "
                             f"(missing {WEIGHTS_ENTRY} or {META_ENTRY})")
        record = json.loads(zf.read(META_ENTRY).decode("utf-8"))
        with zf.open(WEIGHTS_ENTRY) as f:
            weights = np.load(f)["weights"]
    return record, np.ascontiguousarray(weights, dtype=np.float32)


def _resolve(path_or_id):
    if os.path.isfile(str(path_or_id)):
        return str(path_or_id)
    cand = os.path.join(VAULT_DIR, str(path_or_id))
    if os.path.isfile(cand):
        return cand
    # Search by id prefix or filename stem.
    for rec in scan_vault(silent=True):
        if rec["id"].startswith(str(path_or_id)) or rec["filename"] == str(path_or_id):
            return package_path(rec)
    raise FileNotFoundError(f"Brain '{path_or_id}' not found in vault {VAULT_DIR}")


def scan_vault(silent=False):
    """Scans brains/*.flybrain, rebuilds the index, quarantines corrupt files."""
    os.makedirs(VAULT_DIR, exist_ok=True)
    records = []
    for fname in sorted(os.listdir(VAULT_DIR)):
        if not fname.endswith(PACKAGE_EXT):
            continue
        path = os.path.join(VAULT_DIR, fname)
        try:
            with zipfile.ZipFile(path, "r") as zf:
                rec = json.loads(zf.read(META_ENTRY).decode("utf-8"))
            rec["filename"] = fname
            records.append(rec)
        except Exception as e:
            bad = path + ".corrupt"
            try:
                os.replace(path, bad)
            except OSError:
                pass
            if not silent:
                print(f"[Vault] Quarantined corrupt package {fname}: {e}")
    records.sort(key=lambda r: (r.get("name", ""), r.get("id", "")))
    try:
        with open(VAULT_INDEX, "w") as f:
            json.dump({"updated_utc": _utcnow(), "brains": records}, f, indent=2)
    except OSError:
        pass
    return records


def refresh_index():
    try:
        scan_vault(silent=True)
    except OSError:
        pass


def import_legacy_npz(npz_path, name, params=None):
    """Wraps a legacy weights-only .npz (trained_homing_*, gen_*_champion)
    into a managed .flybrain package."""
    arr = np.load(npz_path)["weights"]
    rec = new_record(name, params)
    rec["lineage"] = {"parent_ids": [],
                      "source": f"imported:{os.path.basename(npz_path)}"}
    save_brain(rec, arr)
    return rec


def snapshot_backup(record):
    """Copies the current package to a timestamped pre-event backup."""
    src = package_path(record)
    if not os.path.isfile(src):
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    dst = os.path.join(VAULT_DIR, "backups",
                       f"{record['name']}_{record['id']}_{stamp}{PACKAGE_EXT}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    return dst


def record_battle_result(record, outcome):
    """outcome in {'win','loss','draw'}; bumps battles + result counters."""
    r = record["record"]
    r["battles"] += 1
    if outcome == "win":
        r["wins"] += 1
    elif outcome == "loss":
        r["losses"] += 1
    else:
        r["draws"] += 1
    return record


def record_match_result(record, outcome, tournament_id=None):
    """Match-level result: bumps matches + matches_won/lost (battle wins
    already counted per battle; no double counting)."""
    r = record["record"]
    r["matches"] += 1
    if outcome == "win":
        r["matches_won"] += 1
    elif outcome == "loss":
        r["matches_lost"] += 1
    return record


def log_training_session(record, episodes, params, notes=""):
    record["training"]["episodes"] += int(episodes)
    record["training"]["sessions"].append({
        "utc": _utcnow(), "episodes": int(episodes),
        "params": params, "notes": notes,
    })
    return record


def win_rate(record):
    r = record["record"]
    decided = r["wins"] + r["losses"]
    return (r["wins"] / decided) if decided else 0.5


def match_win_rate(record):
    r = record["record"]
    decided = r.get("matches_won", 0) + r.get("matches_lost", 0)
    return (r.get("matches_won", 0) / decided) if decided else 0.5
