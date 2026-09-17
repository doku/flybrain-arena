# Battle Fly Arena — Comprehensive Documentation

Whole-connectome (166,700-neuron MaleCNS) fighting flies. Two flies, each driven
by its own independent spiking brain, duel in a 3D forest arena: scent tracking,
visual pursuit, spike jousting, wing tears, knockouts — with dopamine learning
after every battle, tournaments, and a managed vault of evolving brains.

## 1. Quickstart

- **Play:** `launch_battle.bat` (or `python launch_battle.py`). Boots the Python
  neuro-server, then the Godot 4 arena at the vault menu.
- **Free battle:** classic evolution — generational clone/mutate duels, no vault identities.
- **Tournament:** pick ≥2 brains, single elimination, best-of-N per match. Quick
  battle = best-of-1 exhibition between 2 brains.
- **Generate / Train:** menu creates brains (variant, seed, wiring, mapping) and
  trains them headlessly (menu shows progress; failures report in the job label).
- **Retrain:** TRAIN SELECTED reuses the brain's own stored settings (wiring,
  seed, rates). Passing an explicit `mapping` graduates a pre-mapping brain to
  the current regime and stamps its record.

## 2. Architecture

```
Godot 4 arena (ArenaGlade.tscn)  <--UDP 127.0.0.1:9999-->  Python neuro-server
  FlyPhysics × 2 (bodies)              20 Hz sensory steps  brain_engine/brain_server.py
  ArenaManager (sequencing)            per-battle reports   2× FlyBrain (LIF, 25.6M synapses)
  TournamentDirector (autoload)        tournament protocol  dopamine + evolution + vault I/O
```

- **Tick:** 50 ms brain ticks at 20 Hz. A dual-brain step costs ~140–210 ms on
  reference hardware, so the server **collapses queued steps to newest**
  (control messages are never dropped); effective control rate ≈ 5 Hz.
- **Server launch:** `launch_battle.py` refuses to start if UDP 9999 is held
  (stale server would steal replies), drains server stdout to `server_log.txt`
  (unbuffered `-u`), and shuts the server down with Godot.
- **Scenes:** `MainMenu` (vault/tournament UI), `ArenaGlade` (fight),
  `FlyEntity` (body + hurtboxes + spear). All arena UI beyond the base layout
  is built procedurally in `ArenaManager.gd` (health HUD, winner overlay,
  bracket overlay, bottom menu bar).

## 3. The brain

- **Model:** leaky integrate-and-fire, sparse active-set kernel (`lif_brain.py`,
  numba-compiled; warmed up at server boot so battle one doesn't freeze).
  Rest −52 mV, threshold −45 mV, refractory, potassium reset, synaptic current
  caps. State resets (`reset_state`) between battles; **weights are the
  long-term memory** and are never reset by match flow.
- **Connectome:** MaleCNS CSR, 166,700 × 166,700, ~25.6M synapses, signed by
  presynaptic consensus neurotransmitter (GABA/glutamate inhibitory, rest
  excitatory). Cached at `malecns_csr_base.npz`; populations at
  `populations_mapped.json` (regenerated from `connectome_data/malecns_v1/`
  feather tables on demand).
- **Per-brain independence:** each fighter owns full weight/state copies;
  tournament fighters additionally run on their **native wiring** (base or
  experimental overlay), so mixed brackets work with vault files unchanged.

## 4. Neuron reference (named pools)

Source: `connectome_loader.py` over the MaleCNS annotation + NT tables.
Side splits use somaSide → instance `_L/_R` → rootSide; leftovers are
side-unknown and never driven. Cross-checked against FlyWire/MANC publications
(1314 descending_neuron rows vs 1328 paper DNs; 97 MBONs with full NT coverage;
166,700 shape matches the whole-CNS count).

### 4.1 Sensory input pools

| Pool | All | L / R | Source types | Role |
|---|---|---|---|---|
| `pheromone_da1` | 204 | 51 / 105 | ORN_DA1 (48 side-unknown) | Rival scent, bilateral antennae. Real 51/105 asymmetry from instance suffixes (somaSide empty on ORNs); encoder equalizes counts via sibling-max refs |
| `pheromone_va1v` | 130 | 15 / 73 | ORN_VA1v | Food-odor ORNs; rides with DA1 in all odor logic |
| `visual_lc10` | 960 | 479 / 481 | LC10a–e + unclear | Small-target tracking, side-gated by azimuth sign |
| `visual_lc4` | 126 | 71 / 55 | LC4 exact (LC40/41/43/44/46b + LPLC4 excluded — they are different types) | Rival looming (expansion rate) |
| `visual_lplc2` | 185 | 94 / 91 | LPLC2 | Tree looming, side-gated wood |
| `visual_lc11` | 143 | 68 / 75 | LC11 (retina scheme) | Small-object presence/size per sector |
| `visual_lc15` | 126 | 61 / 65 | LC15 (retina) | Loom-feature readout |
| `visual_lc17` | 353 | 178 / 175 | LC17 (retina) | Loom-feature readout |
| `visual_lc18` | 208 | 104 / 104 | LC18 (retina) | Loom-feature readout |
| `gyro_jo` | 672 | 348 / 324 | JO (Johnston's organ; sides from instance suffix) | Antennal gyroscope, gyro_flow only |

### 4.2 Motor readout pools

| Pool | All | L / R | Role |
|---|---|---|---|
| `descending_all` | 1314 | 656 / 648 | Full DN population vector: thrust (rate) + yaw (L/R balance) |
| `motor_thrust_dnp09` | 2 | 1 / 1 | DNp09 thrust kick |
| `motor_turn_dnp20` | 2 | 1 / 1 | DNp20 steering pair |
| `motor_giant_fiber` | 2 | 1 / 1 | DNp01 escape dive (gated: visible + frontal) |
| `motor_ram_dnpe017` | 2 | 1 / 1 | Ram burst (≥2 spikes) |
| `motor_mouth` | 6 | 3 / 3 | MNxm01–03 maxillary mouth motor neurons; centrally near-silent, driven by the `spear_lunge` wiring, read as spear-thrust lunge |
| `motor_flight_thrust` | 24 | 12 / 12 | DLMn/DVMn wing-power (muscles_up) |
| `motor_steer` | 214 | 107 / 107 | MNad steering muscles (muscles_up) |
| `flow_vs` | 34 | 16 / 18 | VS optic flow → roll (gyro_flow; per-side normalized) |
| `flow_hs` | 8 | 4 / 4 | HS flow, half weight (gyro_flow) |

### 4.3 Learning / value pools

| Pool | All | Role |
|---|---|---|
| `dopamine_pam` | 316 | Appetitive DA (loaded; scalar DA signal used) |
| `dopamine_ppl1` | 16 | Aversive DA (loaded; scalar DA signal used) |
| `mushroom_body_kc` | 4064 (flat list) | Kenyon cells (KC→MBON plasticity) |
| `mbon` | 97 (48 / 49) | All MBONs |
| `mbon_app` | 50 (25 / 25) | ACh (excitatory) MBONs = approach |
| `mbon_av` | 47 (23 / 24) | Glu/GABA (inhibitory) MBONs = avoid |

NT-sign split is per-cell consensus NT, uniform per type (verified, zero
fallbacks to the excitatory default).

## 5. Sensorimotor codecs (`sensory_motor.py`)

### 5.1 Encoder (world → spikes, per 50 ms tick)

- **Pheromone:** bilateral concentrations × head-shadow antenna factors;
  strength follows nose direction (directional smelling: full nose-on, faint
  trace behind).
- **LC10 tracking:** gated on target-visible; side by azimuth sign (dead-ahead
  splits both sides); intensity falls off toward the periphery.
- **LC4:** rival-loom scalar drives both sides (non-spatial); legacy brains use
  the fused `visual_looming_rate` key instead.
- **LPLC2:** three nose rays (−35°/0°/+35°) side-gated (left→L, right→R,
  ahead splits); retina brains read the 7-ray panoramic sector grid instead.
- **JO:** body angular rates, gyro_flow only, ipsilateral-dominant.
- **Retina (3d):** 7 azimuth columns (−150…+150°) × 3 elevation bands = 21
  cells; rival presence/size → LC11 (rear included), frontal loom → LC15/17/18,
  wood → LPLC2 sides. Rear cells track only — nothing here feeds evade gates.

### 5.2 Decoder (spikes → flight controls)

- **Thrust:** 0.2 baseline + DN-population rate (gain 0.0005; legacy 0.008) +
  DNp09 kick + MN votes (muscles_up) + LC11/loom urgency (retina).
- **Yaw:** normalized DN population vector (intrinsic +9 R-bias subtracted)
  + DNp20 + MN laterality (muscles_up) + LC11 fixation (retina), blended
  30/70 with the olfactory/visual reflex (reflex leads the sign).
- **Pitch:** reflex-driven (elevation tracking + altitude hold).
- **Roll:** VS/HS balance, gyro_flow only.
- **Bursts:** ram (DNpe017 ≥ 2), emergency evade (giant fiber gated on visible
  frontal rival, plus looming reflexes), spear thrust (MNxm ≥ 3 spikes +
  visible frontal aim gate → 0..1 lunge command; unwired brains read 0).
- **Approach bias:** MBON balance, mbon only (scales thrust/yaw, never flips).
- Empty spike sets fall back to pure reflex so the fly still homes.

## 6. Neuro-mapping schemes and regimes

`mapping` is a stackable generator param (`normalize_mapping`; unknown names
raise, never silently degrade). Menu checkboxes: muscles_up, gyro_flow, mbon,
retina.

- **base** (key present, null): current stack, no extra channels.
- **legacy** (key ABSENT — all pre-mapping brains): fused loom channel, legacy
  thrust gain, no gain pinning erosion, no scheme branches. Mappings stay
  opt-in; old training is never re-normalized.
- **muscles_up**: +MN thrust/steering votes. **gyro_flow**: +JO input, VS/HS
  roll. **mbon**: +MBON approach/avoid readout.
- **retina**: +21-sector panoramic eye (LC11 tracking + LC15/17/18 loom
  features + 7-ray wood); pairs with `retina_wide` wiring. Rear sectors track
  only — evade/parry paths untouched, rear-aspect kills preserved.
- Explicit `mapping` in train params graduates a legacy brain (record stamped).
- Free battle (no vault identities) always runs the current stack.

## 7. Experimental wirings (`experimental_wiring.py`)

Deterministic injected-edge overlays (seeded RNG); each changes arity, so each
has its own checkpoint namespace (`__exp_<name>`); vault files keep native
arity end-to-end; mixed brackets supported.

- **base**: the frozen connectome, no edges added.
- **lplc2_contra_dn** (fanout 16, weight 260): every LPLC2 cell → spread of
  *contralateral* DNs. Justification measured on raw edges: base LPLC2→DN is
  24,499 ipsilateral vs 20 contralateral by weight (99.9%), which would steer
  flies *into* looming trees; contra wiring steers away.
- **retina_wide** (fanout 6, weight 200): every LC11/15/17/18 cell → spread of
  *ipsilateral* DNs (pursuit-toward). Tuned by measurement: base wiring
  carries ~0 visual→DN spikes per volley (vs ~36/tick odor-driven); the
  overlay recruits tens per volley — comparable, far from saturating.
- **spear_lunge** (fanout 3, weight 200): frontal LC11/15/17/18 volleys onto
  all six MNxm mouth motor neurons. Measured: ~0 MNxm spikes base wiring vs
  ~6/tick (all cells) on strong frontal input — clean strike signal with
  its own checkpoint namespace.

## 8. Dopamine learning (`dopamine_learning.py`)

- **Rule:** signed dopamine (closing/gaze/tail-chase reward, retreat/crash
  punishment) scales ALL efferents of the active sensory pool (polysynaptic
  paths; direct sensory→DN edges are ~0) plus direct DN-incoming steering
  correction. Branches: LPLC2 tree avoidance, JO roll (gyro_flow only),
  KC→MBON value (mbon only), LC11 pursuit (retina only). Base brains get
  byte-identical updates regardless of era.
- **Caps:** per-call gain caps (battles 0.3, trainer micro-steps 0.02).
- **Depression floor:** down-scaling is refused once a pool sits at/below ~12%
  of reference — multiplicative updates otherwise grind channels to exact
  zero (measured: whole steering sides at 0.0). Potentiation is never blocked.
- **Gain pinning:** one factor per pool toward reference magnitudes (ratios
  preserved). Current brains: full bands. Legacy brains: runaway-only (>2×).
  Numerical-dust pools are left for the repair tool.
- **Vault repair** (`repair_vault.py`, snapshots + `.bak` always):
  `--dust-only` (restore <10%-of-reference pools to native, per side),
  `--runaway-only` (pin >2× pools for every brain), full mode (legacy skipped).

## 9. Trainer (`train_homing.py`)

Headless kinematic pursuit: randomized spawns (half are knock-recovery
upsets), OPEN/SLALOM/FOREST encounter curriculum over a trunk field mirroring
the arena forest, strike range 3.5 m, crash tiers mirroring the arena.
Transfer contract with the arena is machine-tested: identical key sets, sign
conventions (+yaw = right), thrust→speed and turn/pitch rates, gyro
normalization spanning the full live range, rival loom from distance deltas.
Known shaping simplifications: kinematic (no momentum), scripted target, no
combat rules, 6 s episodes vs 40 s rounds, no roll axis (JO-roll learns live).

## 10. Arena (`arena/`)

- **Flight** (`FlyPhysics.gd`): base 3 / max 12 m/s (+1.5× ram), 8 rad/s yaw,
  frame-rate-independent damping + low-thrust braking (agile, stops in place),
  ceiling 30 / floor 0.5, 55 m soft boundary, altitude trim.
- **Senses** (`get_sensory_data`, 60 Hz; sent at 20 Hz): dual-antenna
  pheromone with head-shadow + directional smelling, 168° visual cone
  (azimuth/elevation/visibility), rival/tree looming split, 3+7 tree rays to
  14 m, body angular rates, tail-chase, panoramic sector grid.
- **Combat:** rear-aspect thorax puncture kills (frontal hits parry into spike
  clashes), wing impales tear (60 + 15 wound; torn wing forfeits), spike-clash
  wounds both + knockback with cooldown dedup, tree slams (>11 tear + 50 dmg;
  >6.5 clip + 15), health/bleed-out KOs.
- **Jousting spear:** couched right-side lance (shaft + steel tip +
  crossguard); FrontSpikeArea sphere sits on the tip — what you see is
  what hits. Fires forward on mouth-motor command: short velocity impulse
  plus a visible 0.35 m thrust animation on a 1.2 s cooldown.
- **Forest:** 16 procedural trunks (seed 777) + 4 hand-placed + horizon ring +
  underbrush; camera-following fade keeps the fight visible; PiP eye views.

## 11. Tournament protocol (UDP)

Messages: `step` (20 Hz senses → controls + brain stats), `round_over`
(stats + arena_draw + battle/tournament/match ids), `tournament_load`
(vault paths → per-side native brains + codecs), `match_reset` (LIF reset
only — weights/learning never touched), `tournament_match` (match counters),
`tournament_end` (title), `tournament_weights` (ack), `merge`, `restart`,
`reset`, `free_mode` (rebuild pristine boots).
Reliability: battles are **idempotent** — verdicts persist to
`tournament/_last_battle_verdict.json` before replying, so a resent report
re-sends the stored verdict instead of banking twice. Sequencing watchdogs:
load/reset retry once; battle retries once with the same id, then fail-loud
(never blind-resend). Server answers NaN-safe fitness (invalid JSON wedges
Godot silently).

## 12. Vault (`.flybrain` packages)

Zip of `weights.npz` + `brain.json` (id, name, generator params incl.
variant/seed/rates/wiring/mapping, battle/match/title records, training
sessions, lineage). Atomic writes (temp + rename, `.bak` kept);
`tournament/` holds bracket JSON after every battle; `brains/backups/` holds
pre-training snapshots. Fast uncompressed saves for hot per-battle writes,
compressed for menu operations — both load identically.

## 13. Testing (`tests/test_suite.py`, 99 tests)

Connectome data, LIF dynamics, sensory-motor, all four mapping schemes,
mbon/MBOn branches, experimental wirings (generic per-experiment loop),
cross-arity battles, evolution, UDP integration, live tournament protocol
(KO/draw/match/title/no-double-count), vault packaging, legacy compat
(marker, fused loom, thrust gain, runaway-only pin, floor guard, graduation),
external mapping vs annotation tables (pool purity, DN counts, NT valence,
LPLC2 ipsilateral wiring), wiring×mapping certification matrix (incl.
mirror-direction readouts, ram threshold), trainer↔arena contract
(key equality, stale-cache fallbacks, legacy+scheme inertness, gyro scale),
retina vision + wiring, Godot headless scene runs.

## 14. Data & git policy

`.gitignore` versions code + config only (`arena/`, `brain_engine/`,
`tests/`, launchers, regenerated `populations_mapped.json`). Never committed:
raw/archived data, feathers, CSR cache, checkpoints, vault contents,
tournament state, Godot binaries, logs. Back up data folders by copying them.
