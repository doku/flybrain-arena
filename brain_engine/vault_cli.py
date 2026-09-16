"""CLI for vault mutations + training jobs (driven by the Godot menu or shell).

Usage:
  python vault_cli.py list
  python vault_cli.py info --id <id>
  python vault_cli.py generate --name Viper --params '{"seed":11,...}'
  python vault_cli.py train --id <id> --episodes 50 [--params '{...}'] [--progress path.json]
  python vault_cli.py delete --id <id>
  python vault_cli.py rename --id <id> --name NewName
  python vault_cli.py export --id <id> --out path.flybrain
  python vault_cli.py import --npz path.npz --name Name

All commands print JSON to stdout (except train progress, which goes to
--progress file when given). Exit code 0 on success.
"""
import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain_package as vault


def out(obj, result_file=None):
    text = json.dumps(obj)
    print(text, flush=True)
    if result_file:
        _atomic_write(result_file, text)
    return 0


def _atomic_write(path, text):
    # Temp + rename so concurrent readers (Godot poll) never see partial JSON.
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def err(msg):
    print(json.dumps({"ok": False, "error": msg}))
    return 1


def cmd_list(_a):
    return out({"ok": True, "brains": vault.scan_vault()})


def cmd_info(a):
    try:
        rec, _w = vault.load_brain(a.id)
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "brain": rec})


def cmd_generate(a):
    params = _parse_params(a)
    if isinstance(params, dict) and params.get("__error"):
        return err(params["__error"])
    from train_job import fresh_weights
    try:
        weights = fresh_weights(params.get("experiment"))
        rec = vault.new_record(a.name, params)
        vault.save_brain(rec, weights)
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "brain": rec}, a.result_file)


def _parse_params(a):
    if getattr(a, "params_file", ""):
        try:
            with open(a.params_file) as f:
                return json.load(f)
        except Exception as e:
            return {"__error": f"bad --params-file: {e}"}
    if getattr(a, "params", ""):
        try:
            return json.loads(a.params)
        except json.JSONDecodeError as e:
            return {"__error": f"bad --params JSON: {e}"}
    return {}


def _write_progress(path, ep, total):
    if not path:
        return
    _atomic_write(path, json.dumps({"episode": ep, "total": total,
                                    "pct": round(100.0 * ep / max(total, 1), 1)}))


def cmd_train(a):
    params = _parse_params(a)
    if isinstance(params, dict) and params.get("__error"):
        return err(params["__error"])
    from train_job import train_brain
    try:
        rec, weights = vault.load_brain(a.id)
    except Exception as e:
        return out({"ok": False, "error": str(e)}, a.result_file)
    vault.snapshot_backup(rec)
    notes = f"menu training x{a.episodes}"
    try:
        rec, _w, summary = train_brain(
            rec, weights, int(a.episodes), params,
            progress_cb=(lambda ep, total: _write_progress(a.progress, ep, total)),
            notes=notes, save=True)
    except Exception as e:
        return out({"ok": False, "error": str(e)}, a.result_file)
    if a.progress:
        _write_progress(a.progress, int(a.episodes), int(a.episodes))
    return out({"ok": True, "brain": rec, "summary": summary}, a.result_file)


def cmd_delete(a):
    try:
        path = vault.package_path(vault.load_brain(a.id)[0])
    except Exception as e:
        return err(str(e))
    try:
        os.remove(path)
        vault.refresh_index()
    except OSError as e:
        return err(str(e))
    return out({"ok": True, "deleted": os.path.basename(path)})


def cmd_rename(a):
    try:
        rec, weights = vault.load_brain(a.id)
    except Exception as e:
        return err(str(e))
    old_path = vault.package_path(rec)
    rec["name"] = vault._sanitize_name(a.name)
    rec["filename"] = f"{rec['name']}_{rec['id']}{vault.PACKAGE_EXT}"
    try:
        vault.save_brain(rec, weights)
        if os.path.abspath(old_path) != os.path.abspath(vault.package_path(rec)):
            os.remove(old_path)
    except OSError as e:
        return err(str(e))
    return out({"ok": True, "brain": rec})


def cmd_export(a):
    try:
        rec, _w = vault.load_brain(a.id)
        src = vault.package_path(rec)
    except Exception as e:
        return err(str(e))
    try:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        shutil.copyfile(src, a.out)
    except OSError as e:
        return err(str(e))
    return out({"ok": True, "exported": a.out})


def cmd_import(a):
    try:
        params = _parse_params(a)
        if isinstance(params, dict) and params.get("__error"):
            return err(params["__error"])
        rec = vault.import_legacy_npz(a.npz, a.name, params)
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "brain": rec})


def main():
    p = argparse.ArgumentParser(description="Fly-brain vault CLI")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    q = sub.add_parser("info"); q.add_argument("--id", required=True)
    q = sub.add_parser("generate"); q.add_argument("--name", required=True)
    q.add_argument("--params", default=""); q.add_argument("--params-file", default="")
    q.add_argument("--result-file", default="")
    q = sub.add_parser("train"); q.add_argument("--id", required=True)
    q.add_argument("--episodes", type=int, required=True)
    q.add_argument("--params", default=""); q.add_argument("--params-file", default="")
    q.add_argument("--progress", default=""); q.add_argument("--result-file", default="")
    q = sub.add_parser("delete"); q.add_argument("--id", required=True)
    q = sub.add_parser("rename"); q.add_argument("--id", required=True)
    q.add_argument("--name", required=True)
    q = sub.add_parser("export"); q.add_argument("--id", required=True)
    q.add_argument("--out", required=True)
    q = sub.add_parser("import"); q.add_argument("--npz", required=True)
    q.add_argument("--name", required=True); q.add_argument("--params", default="")
    q.add_argument("--params-file", default="")
    a = p.parse_args()
    fn = {"list": cmd_list, "info": cmd_info, "generate": cmd_generate,
          "train": cmd_train, "delete": cmd_delete, "rename": cmd_rename,
          "export": cmd_export, "import": cmd_import}[a.cmd]
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
