"""CLI for vault mutations + training jobs (driven by the Godot menu or shell).

Usage:
  python vault_cli.py list
  python vault_cli.py info --id <id>
  python vault_cli.py generate --name Viper --params '{"seed":11,...}'
  python vault_cli.py train --id <id> --episodes 50 [--params '{...}'] [--progress path.json]
  python vault_cli.py delete --id <id>
  python vault_cli.py score --id <id> [--episodes 6] [--seed 7]
  python vault_cli.py archive-list
  python vault_cli.py archive-delete --id <id>
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


def cmd_derive_mapping(a):
    """Resolves a genome to its mapping without touching the CSR:
    --genome '{envelope}' or --genome-seed N [--genome-rules M].
    Returns {mapping, genome_id, genome_label, n_rules} for menu display
    and record stamping (menus never hash genomes themselves)."""
    import experimental_wiring as ew
    try:
        genome = None
        if getattr(a, "genome", ""):
            import json as _json
            genome = _json.loads(a.genome)
        else:
            genome = ew.genome_from_seed(
                int(getattr(a, "genome_seed", 0) or 0),
                int(getattr(a, "genome_rules", 3) or 3))
        mapping = list(ew.derive_mapping(genome))
        return out({"ok": True, "mapping": mapping,
                    "genome_id": ew.genome_id(genome),
                    "genome_label": ew.genome_label(genome),
                    "n_rules": len(ew.validate_genome(genome)["rules"])},
                   a.result_file)
    except Exception as e:
        return err(str(e))


def cmd_generate(a):
    params = _parse_params(a)
    if isinstance(params, dict) and params.get("__error"):
        return err(params["__error"])
    from train_job import fresh_weights
    try:
        import experimental_wiring as ew
        genome = params.get("genome", None)
        if genome is None and params.get("genome_seed", None) is not None:
            genome = ew.genome_from_seed(params.get("genome_seed"),
                                         params.get("genome_rules", 3))
            ew.attach_genome(params, genome)
        if genome is not None:
            # Raw envelopes (menu-forwarded, never hashed menu-side):
            # stamp the id and derive the mapping when the caller left
            # them out. Explicit values are never overwritten.
            if params.get("genome_id", None) is None:
                ew.attach_genome(params, genome)
            if not params.get("mapping"):
                stack = list(ew.derive_mapping(genome))
                params["mapping"] = stack if stack else None
        if params.get("reference_stock"):
            gid = ew.genome_label(genome) if genome is not None else ""
            for rec in vault.scan_vault(silent=True):
                gp = rec.get("generator_params", {}) or {}
                if gid != "" and str(gp.get("genome_id", "")) == gid:
                    return err(
                        f"reference stock already in vault: "
                        f"{rec.get('name')} ({rec.get('id')})")
        weights = fresh_weights(params.get("experiment"), genome)
        rec = vault.new_record(a.name, params)
        if params.get("reference_stock"):
            rec["lineage"] = {"parent_ids": [], "source": "reference",
                              "explore_mode": "reference",
                              "provenance": {
                                  "mode": "reference",
                                  "reference_id": params.get("genome_id")}}
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


def cmd_score(a):
    """Eval-only probe: school scenarios under the identical scoring
    rules as training, weights untouched. Banks the probe points into
    the single training.score odometer (plus its episodes, so the
    average stays honest) - one value called score, one system."""
    from train_homing import run_training
    from train_job import stamp_train_score
    try:
        rec, weights = vault.load_brain(a.id)
    except Exception as e:
        return err(str(e))
    gp = rec.get("generator_params", {}) or {}
    eps = int(getattr(a, "episodes", 6) or 6)
    seed = int(float(getattr(a, "seed", 7) or 7))
    try:
        _save, _w, summary = run_training(
            num_episodes=eps, variant="custom", seed=seed,
            save_name="score_tmp.npz",
            experiment=gp.get("experiment"), mapping=gp.get("mapping"),
            yaw_bias=gp.get("yaw_bias"), genome=gp.get("genome"),
            legacy=("mapping" not in gp), init_weights=weights,
            curriculum={}, return_brain=True, eval_only=True)
    except Exception as e:
        return err(str(e))
    gained = round(float(summary.get("score", 0.0)), 1)
    stamp_train_score(rec, {"score": gained})
    tr = rec.setdefault("training", {})
    tr["episodes"] = int(tr.get("episodes", 0)) + eps
    tr["avg_score"] = (float(tr.get("score", 0.0)) / max(tr["episodes"], 1))
    try:
        vault.save_brain(rec, weights)
    except OSError as e:
        return err(str(e))
    return out({"ok": True, "eval_score": gained,
                "summary": summary}, getattr(a, "result_file", None))


def cmd_delete(a):
    try:
        path = vault.package_path(vault.load_brain(a.id)[0])
    except Exception as e:
        return err(str(e))
    try:
        os.remove(path)
        vault.remove_index_entry(os.path.basename(path))
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
            vault.remove_index_entry(os.path.basename(old_path))
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


def cmd_archive_delete(a):
    try:
        info = vault.delete_archived(a.id)
    except Exception as e:
        return err(str(e))
    info["freed_mb"] = round(info["freed_bytes"] / 1e6, 1)
    return out({"ok": True, **info})


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
                # Flush per write: without this, Python block-buffers the
                # redirected stdout, so a still-running worker's log shows
                # only the explicitly-flushed banner - a legit 40-min
                # training run looked like an instant silent death.
                self.fh.write(text)
                self.fh.flush()
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
                progress_cb=prog, episodes2=ep2 or None, params2=params2,
                mutate_traits=int(float(
                    getattr(a, "mutate_traits", 1) or 0)))
        elif a.strategy == "random":
            rec, _w, summary = evo_breeder.breed_random(
                a.name, int(a.seed), int(a.episodes), progress_cb=prog,
                generation=int(getattr(a, "gen", 1) or 1),
                episodes2=ep2 or None, params2=params2,
                mode=str(getattr(a, "explore_mode", "graft") or "graft"))
        elif a.strategy == "crossover":
            rec, _w, summary = evo_breeder.breed_crossover(
                a.parent, str(getattr(a, "parent2", "") or ""), a.name,
                int(a.seed), int(a.episodes),
                noise=float(getattr(a, "noise", 0.05) or 0.05),
                progress_cb=prog, episodes2=ep2 or None, params2=params2,
                mutate_traits=int(float(
                    getattr(a, "mutate_traits", 1) or 0)))
        elif a.strategy == "reference":
            rec, _w, summary = evo_breeder.breed_reference(
                a.name, int(a.seed), int(a.episodes),
                progress_cb=prog, episodes2=ep2 or None, params2=params2)
        else:
            return err("unknown strategy '%s' "
                       "(clone|random|crossover|reference)"
                       % str(a.strategy))
        print(f"[breed] done: {rec.get('name')} ({rec.get('id')}) "
              f"traits={((rec.get('lineage', {}) or {}).get('trait_mutations', {}))} "
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
    q = sub.add_parser("score"); q.add_argument("--id", required=True)
    q.add_argument("--episodes", type=int, default=6)
    q.add_argument("--seed", default=7)
    q.add_argument("--result-file", default="")
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
    q = sub.add_parser("archive-delete"); q.add_argument("--id", required=True)
    q = sub.add_parser("derive-mapping")
    q.add_argument("--genome", default="")
    q.add_argument("--genome-seed", type=int, default=0)
    q.add_argument("--genome-rules", type=int, default=3)
    q.add_argument("--result-file", default="")
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
    q.add_argument("--mutate-traits", default=1)
    q.add_argument("--explore-mode", default="graft")
    q.add_argument("--parent2", default="")
    q.add_argument("--progress", default=""); q.add_argument("--result-file", default="")
    q.add_argument("--log-file", default=""); q.add_argument("--gen", type=int, default=1)
    a = p.parse_args()
    fn = {"list": cmd_list, "info": cmd_info, "generate": cmd_generate,
           "train": cmd_train, "delete": cmd_delete, "score": cmd_score,
           "rename": cmd_rename,
           "export": cmd_export, "import": cmd_import, "archive": cmd_archive,
           "restore": cmd_restore, "archive-list": cmd_archive_list,
           "archive-delete": cmd_archive_delete,
           "derive-mapping": cmd_derive_mapping,
           "breed": cmd_breed}[a.cmd]
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
