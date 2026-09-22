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


def _parse_params2(a):
    """Stage-2 (flight school) params: --params2/--params2-file mirror
    --params/--params-file. Absent means single-stage."""
    if getattr(a, "params2_file", ""):
        try:
            with open(a.params2_file) as f:
                return json.load(f)
        except Exception as e:
            return {"__error": f"bad --params2-file: {e}"}
    if getattr(a, "params2", ""):
        try:
            return json.loads(a.params2)
        except json.JSONDecodeError as e:
            return {"__error": f"bad --params2 JSON: {e}"}
    return None


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
    from train_job import train_brain, train_staged, merge_summaries
    ep2 = int(getattr(a, "episodes2", 0) or 0)
    try:
        if ep2 > 0:
            params2 = _parse_params2(a)
            if isinstance(params2, dict) and params2.get("__error"):
                return err(params2["__error"])
            prog = (lambda ep, total: _write_progress(a.progress, ep, total)) \
                if getattr(a, "progress", "") else None
            rec, _w, summaries = train_staged(
                rec, weights,
                [(int(a.episodes), params, f"menu training x{a.episodes}"),
                 (ep2, params2, f"menu school x{ep2}")],
                progress_cb=prog, save=True)
            summary = merge_summaries(summaries)
            total = int(a.episodes) + ep2
        else:
            rec, _w, summary = train_brain(
                rec, weights, int(a.episodes), params,
                progress_cb=(lambda ep, total: _write_progress(a.progress, ep, total)),
                notes=f"menu training x{a.episodes}", save=True)
            total = int(a.episodes)
    except Exception as e:
        return out({"ok": False, "error": str(e)}, a.result_file)
    if a.progress:
        _write_progress(a.progress, total, total)
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


def cmd_archive(a):
    try:
        entry = vault.archive_brain(a.id, reason=getattr(a, "reason", ""))
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "archived": entry})


def cmd_restore(a):
    try:
        rec = vault.restore_brain(a.id)
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "brain": rec})


def cmd_archive_list(_a):
    try:
        entries = vault.list_archive()
    except Exception as e:
        return err(str(e))
    return out({"ok": True, "archived": entries})


class _TeeLog:
    # Duplicates prints to a log file (spawned workers have no console,
    # so silent deaths would otherwise leave zero evidence).
    def __init__(self, path):
        self.path = path
        self.term = sys.stdout
        self.fh = open(path, "w") if path else None

    def write(self, text):
        self.term.write(text)
        if self.fh is not None:
            try:
                self.fh.write(text)
            except OSError:
                pass

    def flush(self):
        self.term.flush()
        if self.fh is not None:
            try:
                self.fh.flush()
            except OSError:
                pass

    def close(self):
        if self.fh is not None:
            try:
                self.fh.close()
            except OSError:
                pass
            self.fh = None


def cmd_breed(a):
    import evo_breeder
    import traceback
    log = _TeeLog(getattr(a, "log_file", "") or "")
    old_stdout = sys.stdout
    sys.stdout = log
    try:
        print(f"[breed] strategy={a.strategy} name={a.name} "
              f"episodes={a.episodes} seed={a.seed}", flush=True)
        prog = (lambda ep, total: _write_progress(a.progress, ep, total)) \
            if getattr(a, "progress", "") else None
        ep2 = int(getattr(a, "episodes2", 0) or 0)
        params2 = _parse_params2(a) if ep2 > 0 else None
        if isinstance(params2, dict) and params2.get("__error"):
            return err(params2["__error"])
        if a.strategy == "clone":
            rec, _w, summary = evo_breeder.breed_clone(
                a.parent, a.name, int(a.seed), int(a.episodes),
                noise=float(getattr(a, "noise", 0.05) or 0.05),
                progress_cb=prog, episodes2=ep2 or None, params2=params2)
        elif a.strategy == "random":
            rec, _w, summary = evo_breeder.breed_random(
                a.name, int(a.seed), int(a.episodes), progress_cb=prog,
                generation=int(getattr(a, "gen", 1) or 1),
                episodes2=ep2 or None, params2=params2)
        else:
            return err(f"unknown strategy '{a.strategy}' (clone|random)")
        print(f"[breed] done: {rec.get('name')} ({rec.get('id')}) "
              f"summary={summary}", flush=True)
    except Exception as e:
        print(f"[breed] FAILED: {e}\n{traceback.format_exc()}", flush=True)
        return out({"ok": False, "error": str(e)}, a.result_file)
    finally:
        sys.stdout = old_stdout
        log.close()
    return out({"ok": True, "brain": rec, "summary": summary},
               a.result_file)


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
    q.add_argument("--episodes2", type=int, default=0)
    q.add_argument("--params2", default=""); q.add_argument("--params2-file", default="")
    q.add_argument("--progress", default=""); q.add_argument("--result-file", default="")
    q = sub.add_parser("delete"); q.add_argument("--id", required=True)
    q = sub.add_parser("rename"); q.add_argument("--id", required=True)
    q.add_argument("--name", required=True)
    q = sub.add_parser("export"); q.add_argument("--id", required=True)
    q.add_argument("--out", required=True)
    q = sub.add_parser("import"); q.add_argument("--npz", required=True)
    q.add_argument("--name", required=True); q.add_argument("--params", default="")
    q.add_argument("--params-file", default="")
    q = sub.add_parser("archive"); q.add_argument("--id", required=True)
    q.add_argument("--reason", default="")
    q = sub.add_parser("restore"); q.add_argument("--id", required=True)
    q = sub.add_parser("archive-list")
    q = sub.add_parser("breed"); q.add_argument("--strategy", required=True)
    # --name is optional-value: empty string (wild auto-christen) must
    # survive even when the launcher drops empty argv elements
    # (Godot OS.create_process on Windows), leaving a bare `--name`
    # followed by the next option. nargs="?" maps that to "" too.
    q.add_argument("--name", nargs="?", default="", const="");
    q.add_argument("--episodes", type=int, required=True)
    q.add_argument("--parent", default=""); q.add_argument("--seed", type=int, required=True)
    q.add_argument("--episodes2", type=int, default=0)
    q.add_argument("--params2", default=""); q.add_argument("--params2-file", default="")
    q.add_argument("--noise", type=float, default=0.05)
    q.add_argument("--progress", default=""); q.add_argument("--result-file", default="")
    q.add_argument("--log-file", default=""); q.add_argument("--gen", type=int, default=1)
    a = p.parse_args()
    fn = {"list": cmd_list, "info": cmd_info, "generate": cmd_generate,
          "train": cmd_train, "delete": cmd_delete, "rename": cmd_rename,
          "export": cmd_export, "import": cmd_import, "archive": cmd_archive,
          "restore": cmd_restore, "archive-list": cmd_archive_list,
          "breed": cmd_breed}[a.cmd]
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
