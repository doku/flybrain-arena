"""Exports the brain-cloud asset for the in-arena 3D soma view.

Reads MaleCNS soma coordinates + mapped populations, writes
arena/models/brain_cloud.json: every mapped-pool neuron with a known
soma location as [retained_idx, x, y, z, pool_key], coordinates
normalized to a unit box, plus pool centroids. Spikes outside mapped
pools simply don't flash (documented).

Usage (from project root): python brain_engine/export_brain_cloud.py
"""
import json
import os
import sys

import numpy as np
import pyarrow.feather as feather

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANNOT = os.path.join(PROJECT_ROOT, "connectome_data", "malecns_v1",
                     "annotations.feather")
POPS = os.path.join(PROJECT_ROOT, "populations_mapped.json")
OUT = os.path.join(PROJECT_ROOT, "arena", "models", "brain_cloud.json")

POOL_ORDER = ["pheromone_da1", "pheromone_va1v", "visual_lc10",
              "visual_lc4", "visual_lplc2", "visual_lc11", "visual_lc15",
              "visual_lc17", "visual_lc18", "gyro_jo",
              "visual_t4a", "visual_t4b", "visual_t4c", "visual_t4d",
              "visual_t5a", "visual_t5b", "visual_t5c", "visual_t5d",
              "motor_thrust_dnp09", "motor_turn_dnp20", "motor_giant_fiber",
              "motor_ram_dnpe017", "motor_mouth", "motor_flight_thrust",
              "motor_steer", "flow_vs", "flow_hs", "mbon_app", "mbon_av",
              "descending_all"]


def main():
    pops = json.load(open(POPS))
    cell_pool = {}
    for key in POOL_ORDER:
        p = pops.get(key, {})
        if not isinstance(p, dict):
            continue
        for side in ("all", "left", "right"):
            for idx in p.get(side, []):
                cell_pool.setdefault(int(idx), key)
    df = feather.read_table(
        ANNOT, columns=["bodyId", "somaLocation"]).to_pandas()
    body_ids = df["bodyId"].values.astype(np.int64)
    locs = df["somaLocation"].tolist()
    cells = []
    pts = []
    for pos, (body, loc) in enumerate(zip(body_ids.tolist(), locs)):
        if loc is None or pos not in cell_pool:
            continue
        pts.append([float(loc[0]), float(loc[1]), float(loc[2])])
        cells.append([pos, cell_pool[pos]])
    pts = np.array(pts, dtype=np.float64)
    lo, hi = pts.min(0), pts.max(0)
    norm = (pts - lo) / np.maximum(hi - lo, 1e-9) - 0.5
    out_cells = [[c[0], round(float(n[0]), 4), round(float(n[1]), 4),
                  round(float(n[2]), 4), c[1]]
                 for c, n in zip(cells, norm.tolist())]
    centroids = {}
    acc = {}
    for c, n in zip(cells, norm.tolist()):
        acc.setdefault(c[1], []).append(n)
    for k, v in acc.items():
        m = np.mean(np.array(v), axis=0)
        centroids[k] = [round(float(m[0]), 4), round(float(m[1]), 4),
                        round(float(m[2]), 4)]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump({"bbox": [lo.tolist(), hi.tolist()], "pools": POOL_ORDER,
               "centroids": centroids, "cells": out_cells},
              open(OUT, "w"))
    print(f"[BrainCloud] {len(out_cells):,} mapped cells "
          f"({len(centroids)} pools) -> {OUT} "
          f"({os.path.getsize(OUT) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
