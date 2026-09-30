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
  battle = best-of-1 exhibition between 2 brains. Optional losers bracket
  (default on): round-0 losers play their own bracket (needs 2/4/8, else
  skipped with a log line) — its final loser is last place, backed by two
  losses against fellow losers instead of one random loss. Evo mode always
  runs it and archives that fly.
- **Generate / Train:** menu creates brains (variant, seed, additive wiring
  mix, mapping) and trains them headlessly (menu shows progress; failures
  report in the job label). Wiring/mapping/hyperparams live in the
  Configure dialog; the main column shows a one-line summary.
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
- **Fairness contract (identical conditions, both brains):** the two
  fighters integrate on twin worker threads (thread-per-brain;
  `FO_SERIAL=1` forces sequential) — equal compute, bit-identical
  outputs either way (encoding stays serial: the Poisson sampler owns
  the shared global RandomState and never runs on workers; worker
  threads are non-daemon, shut down via atexit so Ctrl+C exits cleanly)
  — and both commands arrive in one packet, so both
  flies share one reply cadence and one torque-hold tau: `shared_tau =
  clamp(0.75 × interval, 0.10, 0.40)`, set identically every reply
  (per-side taus are forbidden: they'd hand one fly crisper handling).
  The top-center strip shows live `CTRL Hz τ`, and every battle banks
  `ctrl_hz`/`tau` means in its `flights` entry as a conditions ledger.
  The headless trainer (fixed-dt, seeded) remains the
  cadence-independent reference.
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
| `visual_t4a/b/c/d` | 1684/1690/1778/1709 | ~840 / ~850 each | T4 progressive/regressive/up/down (flow_trans) | Translational flow, signed by subtype |
| `visual_t5a/b/c/d` | 1664/1715/1720/1620 | ~830 / ~855 each | T5 progressive/regressive/up/down (flow_trans) | Translational flow, signed by subtype |
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
  trace behind). The gradient floor never dies (lost flies must re-acquire);
  ORN drive habituates above the floor knee (gain → 0.3 sustained, ~20 s
  recovery, fresh nose per episode/battle). Yaw reflex reads lateral
  CONTRAST (R−L)/(R+L), so faint traces steer as decisively as strong ones.
  Scent dynamics keys (`scent_lost`/`scent_cast`/`scent_surge`) drive search
  steering (lost 3+ s + blind → cast sweeps) and closing surge (+0.25 thrust).
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
  30/70 with the olfactory/visual reflex (reflex leads the sign; reflex
  yaw is lateral-contrast normalized, and blends toward cast sweeps when
  scent is lost 3+ s with nothing visible).
- **Pitch:** reflex-driven (elevation tracking + altitude hold).
- **Roll:** VS/HS balance, gyro_flow only.
- **Bursts:** ram (DNpe017 ≥ 2), emergency evade (giant fiber gated on visible
  frontal rival, plus looming reflexes), spear thrust (MNxm ≥ 3 spikes +
  visible frontal aim gate → lunge command, effective max 0.6 at full
  6-cell recruitment; unwired brains read 0).
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
- **flow_trans**: +translational optic flow (T4/T5 direction cells).
  Arena and trainer derive ventral flow (groundspeed ÷ altitude, cruise
  reads ~0.35), lateral slip (signed; trainer synthesizes crosswind gust
  windows since its kinematic fly has no sideslip axis), expansion/climb
  on descent/ascent. Windup guards: saccade gate (spin quiets T4 drive),
  per-direction habituation (floor 0.3), drift trim disengages when
  lateral pegs (saturated direction is untrustworthy). Decoder:
  cruise-control thrust trim toward target flow, small drift yaw trim,
  landing flare (thrust cut on expansion). Dopamine: cruise steadiness
  bonus + direction-pool credit, scheme-gated; T4/T5 efferents sit in the
  pinned sens pool so runaway potentiation gets pinned like the rest.
- **yaw_bias**: per-brain DN lateralization correction (default 9.0,
  measured range 6–12, ceiling 25 for hot mixes). Menu spinbox +
  randomize draw; stamped in generator params, retrain-graduatable.
  Diagnose with `probe_flight_style.py --bias` before tuning blind.
  Limit: fixed subtraction can't center a saturated readout — full-mix
  brains pin the DN population term near +0.9 on every stimulus (their
  steering vote is nearly constant; they fly on reflex plus a rightward
  offset). Centering those needs activity-relative readout
  normalization, not a bigger constant.
- Explicit `mapping` in train params graduates a legacy brain (record stamped).
- Free battle (no vault identities) always runs the current stack.

## 7. Experimental wirings (`experimental_wiring.py`)

Deterministic injected-edge overlays (seeded RNG). Wirings are **additive**:
a brain may carry any mix (e.g. `retina_wide + spear_lunge`); the overlays
merge into one edge set before touching the base CSR. Each mix changes arity,
so each has its own checkpoint namespace (`__exp_<a>__<b>`, filename-safe
double-underscore joins; single wirings keep the legacy `__exp_<name>`
form). Vault files keep native arity end-to-end; mixed brackets supported
(each fighter runs its native mix).

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
- **Mixing & conflicts:** identical `(pre, post, weight)` edges from two
  wirings are kept once; the same edge with different weights resolves by
  priority (`lplc2_contra_dn` 10 < `retina_wide` 20 < `spear_lunge` 30,
  higher wins, winner logged); equal-priority clashes reject loudly.
  Sharing a downstream pool (e.g. both tree-contra and retina-wide driving
  DNs) is allowed with a saturation warning, not an error.

## 7b. Wiring genomes (replaces hand overlays for new brains)

A genome is a list of projection **rules**
`{source, source_side, target, target_side, sign, weight, fanout,
topography, stream, stream_seed}` compiled to the same edge arrays the
overlays return — the three legacy wirings above are frozen genomes
(byte-identical output, gated by `frozen_genome_hashes.json`). New neuron
groups become explorable by existing in the pool registry (34 pools:
sensory/motor/modulatory/central roles), not by writing overlay code.
- **Generation** (`generate_genome`): sensory sources → motor/central
  targets, 80% excitatory, deterministic per seed; each rule its own draw
  stream. Wild (`breed_random`) brains are born from fresh genomes.
- **Mapping derivation** (`derive_mapping`): schemes go live from genome
  efferents (retina←LC, flow_trans←T4/T5, gyro_flow←JO/VS/HS,
  muscles_up←MN, mbon←KC/MBON) — no more silent wiring/mapping pairs.
- **Structural mutation** (`mutate_genome`, clones only, ≤1 change/gen by
  default): weight/fanout jitter, target rewire, rule add/drop, sign flip;
  `remap_weights` carries surviving trained weights over and inits new
  edges from the parent scale. Genome-less parents clone unchanged.
- **Checkpoints:** `__gen_<id>` namespace (`genome_id` = sha1 of canonical
  rules); records carry the envelope in `generator_params.genome`.
- **Fitness:** genome novelty bonus in `EvolutionManager` (+8 per pool
  touched by ≤3 past winners, capped at 80 — kill-dominance preserved;
  counts persist in `evo_pool_counts.json`). Pool-level win rates mineable
  via `mine_wiring_fitness.py` over finished brackets.

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
  `--dust-only` (restore <10%-of-**subset-native**-reference pools to
  native, per driver subset — DA1/VA1v/LC10/LC4/LPLC2/LC11/loom/JO/DN/
  MBON-arms — plus `--brain <name>` to scope one identity),
  `--runaway-only` (pin >2× pools for every brain), full mode (legacy skipped).
- **Depression budget (permanent collapse guard):** between
  `begin_episode()` calls (each trainer episode, each battle) a pool may
  lose at most half its magnitude — tracked as an exact cumulative
  product per brain, since uniform row scaling moves the mean exactly.
  Potentiation never consumes budget; untracked legacy paths stay
  unbudgeted. One bad episode can no longer strand a channel in the
  abandonment gap.
- **Collapse post-mortem pattern:** dead odor rows (DA1/VA1v ~0.15×) with
  live LC10 still leave KCs/DN silent — ignition needs convergent drive,
  so 0.1–0.2× sensory pools are marginal even above the dust line; probe
  before trusting them. High `dist_gain` (0.5) amplifies dopamine swings
  and collapses pools faster; prefer 0.1–0.2 for full-mix training.
  Vault-wide census: `diagnose_pools.py --sweep`.
- **Abandonment-gap lesson (measured):** one bad episode (120 micro-steps
  at 0.98×) or one big battle pulse (0.7×) can grind a pool below the
  pin-abandon line (0.1×) while the depression floor (0.12×) refuses
  further change — dead channels earn no spikes, so potentiation never
  fires and retraining cannot escape. Symptom: whole downstream pools
  (KC, DN) silent despite live sensors; both full-mix Eye brains hit it
  (surviving on one overlay-fed channel each). An automatic resurrection
  in `pin_gains` was tried and reverted: dust in healthy winners is
  usually learned irrelevance, and re-animating it mid-tournament
  scrambles learned policies. Dead channels stay dead until a human
  runs the scoped repair tool (`--brain`), which restores dead subsets
  to native mix values.

## 9. Trainer (`train_homing.py`)

Headless kinematic pursuit: randomized spawns (half are knock-recovery
upsets), OPEN/SLALOM/FOREST encounter curriculum over a trunk field mirroring
the arena forest, strike range 3.5 m, crash tiers mirroring the arena.
Transfer contract with the arena is machine-tested: identical sensory key
sets, full control-key consumption (thrust/yaw/pitch, ram, evade, spear),
sign conventions (+yaw = right), thrust→speed and turn/pitch rates, gyro
normalization spanning the full live range, rival loom from distance
deltas. The trainer mirrors the arena's spear strike (same trigger, aim
gate, 1.2 s cooldown, 0.35 s extension window, kick scale, contact reach):
aimed committed lunges earn shaping reward, blind/wild lunges cost, and
contact ends the episode as a strike kill; dopamine credits the
lobula-feature→mouth efferents on paid-off lunges. Translational flow
channels are computed kinematically (ventral/expansion exact; lateral
from crosswind gust windows so drift-cancel trains before arena day)
with a cruise steadiness reward for flow_trans runs. Known shaping simplifications:
kinematic (no momentum), scripted target, 6 s episodes vs 40 s rounds,
no roll axis (JO-roll learns live).

## 10. Arena (`arena/`)

- **Flight** (`FlyPhysics.gd`): base 3 / max 12 m/s (+1.5× ram), 8 rad/s yaw,
  frame-rate-independent damping + low-thrust braking (agile, stops in place),
  ceiling 30 / floor 0.5, 55 m soft boundary, altitude trim. Leaky command
  hold: the brain answers at ~5 Hz, so yaw/pitch/roll torques decay
  (τ 0.15 s) between updates — a held-full-torque command would otherwise
  steer ~1 rad on 200 ms-old senses and wind up the spin-then-spin-back
  wobble. Thrust is sustained (speed continuity).
- **Senses** (`get_sensory_data`, 60 Hz; sent at 20 Hz): dual-antenna
  pheromone with head-shadow + directional smelling, 168° visual cone
  (azimuth/elevation/visibility), rival/tree looming split, 3+7 tree rays to
  14 m, body angular rates, tail-chase, panoramic sector grid.
- **Combat:** rear-aspect thorax puncture kills (frontal hits parry into spike
  clashes), wing impales tear (60 + 15 wound; torn wing forfeits), spike-clash
  wounds both + knockback with cooldown dedup, tree slams (>11 tear + 50 dmg;
  >6.5 clip + 15), health/bleed-out KOs. End-of-round landing ceremony:
  loser drops belly-up, winner lowers onto its feet (draws: both upright);
  the next round waits for touchdown (8 s cap).
- **Flight telemetry:** every control step accumulates altitude profile,
  thrust/pitch/yaw means, evade/ram exposure, spear demand, and lunge
  count per fly. The summary rides with the battle report (printed to
  console, sent to the server) and is banked per-battle on the tournament
  match (`flights` list) — flight-style questions get recorded evidence.
- **Session WINS tally:** the HUD wins label records free-battle and
  tournament/quick-battle wins alike (draws record nothing) and resets
  per tournament match.
- **Jousting spear:** couched right-side lance (shaft + steel tip +
  crossguard); FrontSpikeArea sphere sits on the tip — what you see is
  what hits. Fires forward on mouth-motor command: short velocity impulse
  plus a visible 0.35 m thrust animation on a 1.2 s cooldown.
- **Forest:** 16 procedural trunks (seed 777) + 4 hand-placed + horizon ring +
  underbrush; camera-following fade keeps the fight visible; PiP eye views.
- **Brain view (in-arena activation overlay):** the server streams per-pool
  spike counts with every motor reply (legacy HUD keys untouched); detail
  0/1/2 gates payload size (counts / +context / +capped spike ids for
  raster, truncation-guarded for UDP). L0 pool-rate bars per fly (EMA,
  ~5 Hz) ride the screen edges; toggles: menu BRAIN VIEW row (show,
  layer, detail, replay-record), `BRAIN` menu-bar button cycles every
  representation (bars/flow/raster/3D), `B` toggles visibility, `N`
  cycles layers live too (all sync back to the menu bus).
  L1 flow diagram (`BrainView.gd`, custom-drawn): pool nodes in
  sense/value/descending/motor columns light with live rate; edges glow
  with presynaptic drive and resolve from each fighter's real wiring mix
  + mapping (server labels ride the stats envelope), so different brains
  show different lit paths (MBON edges only render under the mbon
  scheme, since only those brains read the value readout). Click a node
  to arm the raster drill-down.
  L2 raster (`BrainRaster.gd`): per-neuron grid (columns = recent ~5 Hz
  steps, rows = first 128 cells) for the clicked pool; selecting
  auto-escalates UDP detail to 2 and drops back on deselect. Pool id
  lists come from a read-only `raster_map` server message; raster swaps
  into the diagram rect on layer "raster" (diagram returns on
  deselect); selections clear on new matches, buffers on round reset.
  L4 replay: every reply banks per-pool counts (~5 Hz, 600-step cap);
  the menu record toggle banks the stream into the match `flights`
  entry (~50 KB/battle) and keeps an in-memory copy. Post-battle REPLAY
  button (both modes) opens play/pause + scrub through the same bars +
  diagram renderers (raster stays live-only). Banked streams are plain
  JSON for later probe-script analysis.
  L5 3D soma cloud (`BrainCloud.gd` + `brain_cloud.gdshader`): all
  mapped-pool neurons with known MaleCNS soma positions render as one
  MultiMesh (single draw call), pool-colored; spikes flash white-hot
  with shader-side decay, so the CPU only timestamps cells that fired.
  Asset built by `brain_engine/export_brain_cloud.py` (3.7k cells,
  0.2 MB; spikes outside mapped pools don't flash). Clouds ride the
  camera (alpha left, beta right, slow spin); layer `brain3d`
  auto-escalates UDP detail for spike ids. Pool-to-pool network lines
  connect real centroid positions and light with presynaptic drive,
  gated per fighter like the flow diagram — the active networks glow
   inside the flashing cloud.

### Battle rules: DNF, overtime, wander dock

  A battle that times out with neither fly damaged is a **DNF (did not
  finish)** — no winner, no dopamine, both records bank a draw, and the
  pairing replays. The first replay runs at **1.5x** the designated
  time, the second at **2x**; a third DNF ends the pairing by the
  standard resolution (prior match-wins, group split, ELO fallback).
  The white outer arena ring sits 30 m from center
  (`glade_ground.gdshader`); at every DNF the arena measures each
  fly's meters past that ring (**drift**). Why: a fly that finishes a
  battle deep in the forest fringe was most likely confused or evading
  rather than fighting, and a plain replay would likely tie again.
  So the overtime battle docks starting health by drift —
  `min(drift x 4 HP/m, 50 HP)` per fly, zero drift docks zero — which
  converts wandering into a concrete disadvantage: unequal health
  produces unequal damage, and the timeout/KO verdict almost never
  ties a second time. Drift past 5 m also banks a career **wander**
  mark (`record.wander`, shown in stats/gallery); the overtime callout
  previews each side's dock, and the timer reads `(OVERTIME x1.5)`.

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

## 13. Testing (`tests/test_suite.py`)

Connectome data, LIF dynamics, sensory-motor, all four mapping schemes,
mbon/MBOn branches, experimental wirings (generic per-experiment loop),
additive wiring mixes (normalization, filename-safe suffixes,
order-independence, edge-union integrity, priority/conflict resolution),
cross-arity battles, evolution, UDP integration, live tournament protocol
(KO/draw/match/title/no-double-count), vault packaging, legacy compat
(marker, fused loom, thrust gain, runaway-only pin, floor guard, graduation),
external mapping vs annotation tables (pool purity, DN counts, NT valence,
LPLC2 ipsilateral wiring), wiring×mapping certification matrix (incl.
mirror-direction readouts, ram threshold, mix integration), trainer↔arena
contract (key equality, full control-key consumption, trainer lunge
trigger/contact/cooldown/aim, dopamine spear credit, stale-cache fallbacks,
legacy+scheme inertness, gyro scale), retina vision + wiring, brain-view
stream (pool keys, detail gating, truncation guard, raster id slices,
soma-cloud asset schema), subfloor abandonment, evo loop (biggest-loser
query incl. tie-breaks, archive/restore round-trip, breeder param
validity), Godot headless scene runs, flight-style probe
(`brain_engine/probe_flight_style.py`: two vault
brains, real or fresh weights, against climb/level/dive targets —
separates wiring effects from learned effects), learning verification
(`brain_engine/verify_learning.py`: curve, zero-DA control, crash
conditioning), pool diagnostics (`brain_engine/diagnose_pools.py`:
weight ratios, spike census).

## 14. Continuous tournament mode (eternal loop)

`START CONTINUOUS` runs tournaments back-to-back forever (until
STOP CONTINUOUS or quit): each generation archives the single biggest
loser (earliest
exit + fewest battle wins, random tie-break) to `brains/archive/` —
invisible to the roster, listed in the menu hall of shame with per-brain
Restore — then breeds 1 winner-clone (weight copy + noise, **fresh
seed**, full 50-episode training, lineage stamped) + 1 random (random
wiring mix/mapping/yaw-bias/rates, 50 eps) and rebuilds at constant
roster size (extras trimmed worst-first, logged distinctly). State rides
in the tournament JSON (`evo.active/generation/episodes`), so the loop
survives quit/resume; failures disable evo loudly instead of looping
broken. Elimination skips brains missing from the vault (resumed old
brackets, mid-event deletes) and falls through to the next-worst
present fighter. Breeding shows a centered phase panel (title, status,
progress, spinner); each attempt writes a per-job log file, dead
workers fail fast with their last episode, and one automatic retry
covers transient worker deaths before the generation aborts. STOP and breed timeouts free the shared vault-async slot at
once (quitting mid-breed orphans the job: it finishes into the vault
as a harmless stray). Pace is honest: ~15–25 min per generation,
unattended. Budget: `evo_breeder.py` (`breed_clone`/`breed_random`,
`biggest_loser`), `vault_cli.py breed/archive/restore/archive-list`.
Deep-tested: loser query incl. byes/vacants/draws/quick/tie-breaks,
archive/restore round-trips/ambiguity/double-restore, live 1-episode
clone+random breeds (lineage, fresh seeds, divergent weights, vault
restored afterwards).

## 15. Data & git policy

`.gitignore` versions code + config only (`arena/`, `brain_engine/`,
`tests/`, launchers, regenerated `populations_mapped.json`). Never committed:
raw/archived data, feathers, CSR cache, checkpoints, vault contents,
tournament state, Godot binaries, logs. Back up data folders by copying them.
