# Fruit-fly body mesh attribution

The file `flybody_manifest.json` in this folder contains decimated,
game-scaled body-part meshes derived from the **TuragaLab/flybody**
fruit-fly body model:

- Source: https://github.com/TuragaLab/flybody
  (`flybody/fruitfly/assets/*.obj`, assembled per `fruitfly.xml`)
- License: **Apache License 2.0** (see the `LICENSE` file at the repo root
  of TuragaLab/flybody; the same license covers its model assets)
- Copyright: the flybody contributors (Google DeepMind + HHMI Janelia,
  Vaxenburg et al.)
- Paper: Vaxenburg et al., "Whole-body simulation of realistic fruit fly
  locomotion with deep reinforcement learning" (2024/2025)

What was changed for this game (build script kept outside the repo):
- Parts fused into material groups (cuticle / dark bristles / thorax /
  eyes / halteres / wing membranes + veins), decimated with quadric
  simplification (~106k tris total), converted from MuJoCo cm/Z-up/+X-fwd
  to game units (Y-up/-Z-fwd, torso ~= 1.35 units, recentered on the
  collision capsule), wings re-based to hinge pivots.
- Legs are NOT from flybody (the scan legs stand in a walking pose):
  the game uses procedural tucked flight legs. The combat horn is an
  original game weapon, not part of the fly.

Apache-2.0 requires this notice; no other action needed. If you
redistribute this game, keep this file alongside the manifest.
