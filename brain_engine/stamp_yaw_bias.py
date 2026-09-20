"""Stamp per-brain yaw_bias into vault records (decode-only change:
weights untouched). Usage from project root:
  python brain_engine/stamp_yaw_bias.py Eye2_ae6e6a27.flybrain 2.9 [...]
Saves with .bak via vault.save_brain.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import brain_package as vault
from sensory_motor import normalize_yaw_bias

args = sys.argv[1:]
assert len(args) % 2 == 0 and args, "want filename value pairs"
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "brains"))
for fn, val in zip(args[::2], args[1::2]):
    yb = normalize_yaw_bias(float(val))
    rec, w = vault.load_brain(fn)
    rec.setdefault("generator_params", {})["yaw_bias"] = yb
    vault.save_brain(rec, w, backup=True)
    print(f"{fn}: stamped yaw_bias = {yb} (weights untouched)")
