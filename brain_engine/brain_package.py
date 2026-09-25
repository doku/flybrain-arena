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
    "genome": None,
    "genome_id": None,
    "mapping": None,
    "yaw_bias": None,
    "explore_mode": "legacy",
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
                 "tournaments_won": 0, "elo": ELO_DEFAULT},
        "training": {"episodes": 0, "sessions": [], "score": 0.0,
                     "avg_score": 0.0},
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
    update_index_entry(record)
    return path


def save_brain_record_only(record):
    """Rewrites only the meta entry of an existing package, copying the
    weights bytes verbatim (draw path: weights provably unchanged, so no
    numpy work and no recompress). Hot-save semantics: no .bak, then an
    incremental index upsert. Raises on missing/corrupt weights so a
    journal replay leaves the transaction for reconcile instead of
    banking half a battle."""
    os.makedirs(VAULT_DIR, exist_ok=True)
    path = package_path(record)
    with zipfile.ZipFile(path, "r") as zin:
        names = set(zin.namelist())
        if WEIGHTS_ENTRY not in names or META_ENTRY not in names:
            raise ValueError(f"{path} is not a valid .flybrain package "
                             f"(missing {WEIGHTS_ENTRY} or {META_ENTRY})")
        wdata = zin.read(WEIGHTS_ENTRY)
    # Validate the copied payload decodes before touching the file.
    with np.load(io.BytesIO(wdata)) as z:
        z["weights"]
    fd, tmp = tempfile.mkstemp(suffix=".tmp", dir=VAULT_DIR)
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as zf:
            zf.writestr(WEIGHTS_ENTRY, wdata)
            zf.writestr(META_ENTRY, json.dumps(record, indent=2))
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    update_index_entry(record)
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


def _read_index():
    """Parsed index entries, or None when the file is missing/corrupt."""
    try:
        with open(VAULT_INDEX) as f:
            data = json.load(f)
        brains = data.get("brains", [])
        if isinstance(brains, list):
            return brains
    except (OSError, ValueError):
        pass
    return None


def _write_index(brains):
    brains = sorted(brains,
                    key=lambda r: (r.get("name", ""), r.get("id", "")))
    tmp = VAULT_INDEX + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"updated_utc": _utcnow(), "brains": brains}, f, indent=2)
    os.replace(tmp, VAULT_INDEX)


def update_index_entry(record):
    """Upserts one brain's index entry after a save — no vault scan, so
    hot per-battle saves stop re-opening every package. The upserted
    entry is exactly what a scan would produce (stored meta + filename),
    same sort order. Falls back to a full scan when the index is
    missing or corrupt."""
    brains = _read_index()
    if brains is None:
        refresh_index()
        return
    fname = os.path.basename(package_path(record))
    entry = dict(record)
    entry["filename"] = fname
    brains = [b for b in brains if b.get("filename") != fname]
    brains.append(entry)
    _write_index(brains)


def remove_index_entry(filename):
    """Drops one filename from the index after a vault delete/archive/
    rename (no vault scan). Missing index falls back to a full scan;
    an already-absent entry writes nothing at all."""
    brains = _read_index()
    if brains is None:
        refresh_index()
        return
    kept = [b for b in brains if b.get("filename") != filename]
    if len(kept) != len(brains):
        _write_index(kept)


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


# ── ELO ratings ──────────────────────────────────────────────────────
# One rating per brain, updated after every tournament battle (small K)
# and every match verdict (large K). Standard zero-sum math; draws move
# almost nothing between equals. Records predating ELO read the default
# via .get("elo", ELO_DEFAULT), so no schema migration is needed.
ELO_DEFAULT = 1200.0
ELO_K_BATTLE = 10.0
ELO_K_MATCH = 30.0
ELO_DRAW3_PENALTY = 25.0
ELO_INHERIT = 0.7


def apply_elo(rec_a, rec_b, outcome_a, k):
    """Zero-sum ELO update on both records' record["elo"].
    outcome_a in {'win','loss','draw'} from alpha's perspective.
    Returns (new_elo_a, new_elo_b)."""
    ra = float(rec_a["record"].get("elo", ELO_DEFAULT))
    rb = float(rec_b["record"].get("elo", ELO_DEFAULT))
    if outcome_a == "win":
        actual = 1.0
    elif outcome_a == "loss":
        actual = 0.0
    elif outcome_a == "draw":
        actual = 0.5
    else:
        raise ValueError(f"bad ELO outcome '{outcome_a}' (win|loss|draw)")
    expected = 1.0 / (1.0 + 10.0 ** ((rb - ra) / 400.0))
    delta = float(k) * (actual - expected)
    rec_a["record"]["elo"] = ra + delta
    rec_b["record"]["elo"] = rb - delta
    return ra + delta, rb - delta


def apply_draw3_penalty(rec_a, rec_b):
    """Third-draw resolution penalty: both sides lose a flat amount on
    top of the normal draw update, so stalling out a match costs rating
    for favorite and underdog alike."""
    rec_a["record"]["elo"] = float(
        rec_a["record"].get("elo", ELO_DEFAULT)) - ELO_DRAW3_PENALTY
    rec_b["record"]["elo"] = float(
        rec_b["record"].get("elo", ELO_DEFAULT)) - ELO_DRAW3_PENALTY
    return (rec_a["record"]["elo"], rec_b["record"]["elo"])


def backfill_elo():
    """One-time migration: stamp missing ELO from W/L history
    (1200 + 25 x (battle wins - losses)). Records that already carry
    the key are never touched. Returns the count stamped."""
    stamped = 0
    for rec in scan_vault(silent=True):
        r = rec.get("record", {})
        if "elo" in r:
            continue
        r["elo"] = ELO_DEFAULT + 25.0 * (
            int(r.get("wins", 0)) - int(r.get("losses", 0)))
        try:
            weights = load_brain(rec.get("id", ""))[1]
        except Exception:
            continue
        save_brain(rec, weights)
        stamped += 1
    return stamped


def log_training_session(record, episodes, params, notes=""):
    record["training"]["episodes"] += int(episodes)
    record["training"]["sessions"].append({
        "utc": _utcnow(), "episodes": int(episodes),
        "params": params, "notes": notes,
    })
    return record


ARCHIVE_DIR = os.path.join(VAULT_DIR, "archive")
ARCHIVE_LOG = os.path.join(ARCHIVE_DIR, "log.json")


def _read_archive_log():
    try:
        with open(ARCHIVE_LOG) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def _write_archive_log(entries):
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(suffix=".tmp", dir=ARCHIVE_DIR)
    os.close(fd)
    try:
        with open(tmp, "w") as f:
            json.dump(entries, f, indent=2)
        os.replace(tmp, ARCHIVE_LOG)
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass


def archive_brain(path_or_id, reason=""):
    """Retires a brain to brains/archive/ (the vault scanner globs
    non-recursively, so archived files drop out of the roster with no
    code changes). Appends to the archive log; refreshes the index.
    Returns the log entry."""
    rec, _w = load_brain(path_or_id)  # validates the package first
    src = _resolve(path_or_id)
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    dst = os.path.join(ARCHIVE_DIR, os.path.basename(src))
    shutil.move(src, dst)
    bak = src + ".bak"
    if os.path.isfile(bak):
        shutil.move(bak, dst + ".bak")
    entry = {"id": rec.get("id", ""), "name": rec.get("name", "?"),
             "filename": os.path.basename(dst),
             "archived_utc": _utcnow(), "reason": reason,
             "record": rec.get("record", {}),
             "generator_params": rec.get("generator_params", {})}
    log = _read_archive_log()
    log.append(entry)
    _write_archive_log(log)
    remove_index_entry(os.path.basename(dst))
    return entry


def _find_archive_match(key):
    """Unique archived filename matching an id/name substring (shared by
    restore and delete so both fail loud on ambiguity)."""
    key = str(key)
    cands = []
    if os.path.isdir(ARCHIVE_DIR):
        for fname in sorted(os.listdir(ARCHIVE_DIR)):
            if not fname.endswith(PACKAGE_EXT):
                continue
            if key.lower() in fname.lower():
                cands.append(fname)
    if not cands:
        raise FileNotFoundError(f"No archived brain matches '{key}'")
    if len(cands) > 1:
        raise ValueError(f"Ambiguous archive match '{key}': {cands}")
    return cands[0]


def restore_brain(name_or_id):
    """Brings an archived brain back to the vault (re-indexed on next
    scan). Returns the record."""
    fname = _find_archive_match(name_or_id)
    src = os.path.join(ARCHIVE_DIR, fname)
    dst = os.path.join(VAULT_DIR, fname)
    if os.path.exists(dst):
        raise FileExistsError(f"Vault already holds {cands[0]}")
    shutil.move(src, dst)
    bak = src + ".bak"
    if os.path.isfile(bak):
        shutil.move(bak, dst + ".bak")
    rec, _w = load_brain(dst)
    update_index_entry(rec)
    # No longer archived: drop the log entry so the Hall of Shame stops
    # listing the restored brain (previously it lingered as "(missing)").
    log = _read_archive_log()
    kept = [e for e in log if str(e.get("filename", "")) != fname]
    if len(kept) != len(log):
        _write_archive_log(kept)
    return rec


def list_archive():
    """Archive log entries, newest last, each with `present` and
    `size_mb` (0.0 when the file is gone) so space-hunters can sort
    the fattest losers first."""
    out = []
    for e in _read_archive_log():
        e = dict(e)
        fpath = os.path.join(ARCHIVE_DIR, str(e.get("filename", "")))
        try:
            e["present"] = os.path.isfile(fpath)
            e["size_mb"] = round(os.path.getsize(fpath) / 1e6, 1) \
                if e["present"] else 0.0
        except OSError:
            e["present"] = False
            e["size_mb"] = 0.0
        out.append(e)
    return out


def delete_archived(name_or_id):
    """Permanently deletes an archived brain (package file + .bak +
    log entry) to free disk space. Also prunes orphan log entries
    whose file is already gone. Returns {"id", "name", "filename",
    "freed_bytes"}."""
    key = str(name_or_id)
    try:
        fname = _find_archive_match(key)
    except ValueError:
        raise
    except FileNotFoundError:
        fname = None
    log = _read_archive_log()
    fnames = []
    if fname is None:
        # File already gone: match orphan log rows by id/name. An exact
        # id or filename hits first; one brain archived twice leaves
        # duplicate rows, and deleting the brain clears all of them
        # together (that used to fail as "ambiguous", stranding every
        # "(missing)" row the Delete button was asked to remove).
        cands = [e for e in log
                 if key == str(e.get("id", ""))
                 or key == str(e.get("filename", ""))]
        if not cands:
            cands = [e for e in log
                     if key.lower() in str(e.get("id", "")).lower()
                     or key.lower() in str(e.get("name", "")).lower()]
        if not cands:
            raise FileNotFoundError(f"No archived brain matches '{key}'")
        if len({str(e.get("id", "")) for e in cands}) > 1:
            raise ValueError(f"Ambiguous archive match '{key}'")
        entry = cands[0]
        fnames = sorted({str(e.get("filename", "")) for e in cands})
        fname = fnames[0] if fnames else ""
    else:
        hits = [e for e in log if str(e.get("filename", "")) == fname]
        entry = hits[0] if hits else {}
        fnames = [fname]
    freed = 0
    for fn in fnames:
        path = os.path.join(ARCHIVE_DIR, fn)
        for cand in (path, path + ".bak"):
            try:
                if os.path.isfile(cand):
                    freed += os.path.getsize(cand)
                    os.remove(cand)
            except OSError:
                pass
    _write_archive_log(
        [e for e in log if str(e.get("filename", "")) not in fnames])
    return {"id": entry.get("id", ""), "name": entry.get("name", "?"),
            "filename": fname, "freed_bytes": freed}


def win_rate(record):
    r = record["record"]
    decided = r["wins"] + r["losses"]
    return (r["wins"] / decided) if decided else 0.5


def match_win_rate(record):
    r = record["record"]
    decided = r.get("matches_won", 0) + r.get("matches_lost", 0)
    return (r.get("matches_won", 0) / decided) if decided else 0.5
