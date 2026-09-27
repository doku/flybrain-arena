import numpy as np


KNOWN_MAPPINGS = ("base", "muscles_up", "gyro_flow", "mbon", "retina",
                  "flow_trans")

# Schemes that add encoder/decoder behavior. "base" is the absence of all
# schemes. Mappings stack: a brain may declare any combination, e.g.
# ["muscles_up", "gyro_flow"], and every matching section applies.


# Yaw-bias randomization window (centers the measured ~9.0, spans the
# observed 7-10 directional spread). Menu randomize draws uniform here.
YAW_BIAS_LO = 6.0
YAW_BIAS_HI = 12.0
YAW_BIAS_DEFAULT = 9.0


def draw_yaw_bias(rng=None):
    """Draws a per-brain yaw-bias correction. Uniform over the measured
    window; stamped into the record so it's reproducible, never
    re-rolled silently."""
    import random as _random
    r = _random if rng is None else rng
    return round(float(r.uniform(YAW_BIAS_LO, YAW_BIAS_HI)), 1)


def normalize_yaw_bias(value):
    """Canonical yaw bias: None -> default 9.0, else a float in [0, 25].
    The ceiling covers strongly-driven mixes (full-mix Eye3 measured
    +20.8). Garbage raises (a typo'd bias must not train as default
    while the record claims otherwise)."""
    if value is None:
        return YAW_BIAS_DEFAULT
    try:
        v = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"Bad yaw_bias {value!r}: want a number in [0, 25]")
    if not 0.0 <= v <= 25.0:
        raise ValueError(f"Bad yaw_bias {v}: want a number in [0, 25]")
    return v


def is_legacy_record(rec):
    """True for pre-mapping vault brains: their generator_params predate
    the 'mapping' key entirely (it is ABSENT, not None). New brains always
    carry the key (None = current-stack base), so absence cleanly marks
    brains trained before the neuro-mapping session. Legacy brains run the
    pre-mapping sensorimotor regime (fused loom channel, legacy decoder
    operating point, no gain pinning) so the mapping work stays opt-in
    for new flies without rewriting old training."""
    if not isinstance(rec, dict):
        return False
    return "mapping" not in (rec.get("generator_params") or {})


def normalize_mapping(value):
    """Canonical neuro-mapping: None/''/'base' -> (), else a sorted tuple
    of scheme names. Accepts a single name, a list of names, or None.

    'base' (()) is today's exact sensorimotor behavior. Unknown names
    raise here, never silently degrade (a typo'd scheme must not train
    as base while the record claims otherwise).
    """
    if value is None:
        return ()
    items = value if isinstance(value, (list, tuple)) else [value]
    schemes = set()
    for item in items:
        s = str(item).strip()
        if s.lower() in ("", "none", "base"):
            continue
        if s not in KNOWN_MAPPINGS:
            raise ValueError(f"Unknown neuro-mapping '{s}'. Known: {KNOWN_MAPPINGS}")
        schemes.add(s)
    return tuple(sorted(schemes))


# Translational-flow cruise target (ventral flow units): the decoder
# trims thrust to hold this. Cruise 5 m/s at 7 m altitude reads ~0.36.
FLOW_CRUISE = 0.35
# Full-scale T4/T5 spike volley: the encoder injects up to 30 cells per
# pool over the 4 pools of a direction group at magnitude 1.0, so
# counts / FLOW_FULL_SCALE estimates the flow magnitude back.
FLOW_FULL_SCALE = 120.0

# Reflex authority defaults (heritable evolvable control traits; the
# legacy operating point, bit-identical when untouched).
BLEND_DEFAULTS = {
    "yaw_blend": 0.3,
    "evade_backup": 1.0,
    "flow_authority": 1.0,
    "search_blend": 0.5,
    "pitch_blend": 1.0,
}

# Control-channel audit: every MotorDecoder output and what drives it.
# "pools" = spiking neuron pools that vote; "reflex" = hardwired
# sensory-math contributors (no neurons); "gate" = sensory conditions
# that enable a neural drive without steering it. The audit test
# asserts every decoded output appears here with at least one pool,
# so reflex-only control can never slip in silently again.
CONTROL_CHANNELS = {
    "thrust": {"pools": ["motor_thrust_dnp09", "descending_all",
                         "motor_flight_thrust"],
               "reflex": [], "gate": []},
    "yaw_torque": {"pools": ["motor_turn_dnp20", "descending_all",
                             "motor_steer", "visual_lc11"],
                   "reflex": ["reflex_yaw", "lost_search"],
                   "gate": []},
    "pitch_torque": {"pools": ["visual_t4c", "visual_t5c",
                               "visual_t4d", "visual_t5d"],
                     "reflex": ["reflex_pitch"], "gate": []},
    "roll_torque": {"pools": ["flow_vs", "flow_hs", "motor_roll_mnhl"],
                    "reflex": [], "gate": []},
    "approach_bias": {"pools": ["mbon_app", "mbon_av"],
                      "reflex": [], "gate": []},
    "ram_burst": {"pools": ["motor_ram_dnpe017"], "reflex": [], "gate": []},
    "emergency_evade": {"pools": ["motor_giant_fiber"],
                        "reflex": ["reflex_evade", "reflex_evade_tree"],
                        "gate": ["visibility"]},
    "spear_thrust": {"pools": ["motor_mouth"], "reflex": [],
                     "gate": ["aim"]},
}


def _side_pair(populations, key):
    """(left, right) int32 arrays for a bilateral pool (stale-cache safe)."""
    pool = populations.get(key, {})
    return (np.array(pool.get("left", []), dtype=np.int32),
            np.array(pool.get("right", []), dtype=np.int32))


class SensoryEncoder:
    """
    Translates Godot 3D battle arena physical world state into Poisson spike trains
    injected directly into biological sensory receptor neurons.
    mapping selects the neuro-mapping scheme ('base' default). Only the
    'gyro_flow' scheme drives the antennal-gyroscope (JO) channel; every
    other scheme encodes exactly the base channels. legacy=True restores
    the pre-mapping regime for old brains: the fused looming key drives
    LC4 and the split tree/rival keys plus JO are ignored.
    """
    def __init__(self, populations, mapping=None, legacy=False):
        self.schemes = normalize_mapping(mapping)
        self.legacy = bool(legacy)
        self.da1_left = np.array(populations["pheromone_da1"]["left"], dtype=np.int32)
        self.da1_right = np.array(populations["pheromone_da1"]["right"], dtype=np.int32)
        self.va1v_left = np.array(populations["pheromone_va1v"]["left"], dtype=np.int32)
        self.va1v_right = np.array(populations["pheromone_va1v"]["right"], dtype=np.int32)

        self.lc10_left = np.array(populations["visual_lc10"]["left"], dtype=np.int32)
        self.lc10_right = np.array(populations["visual_lc10"]["right"], dtype=np.int32)
        self.lc4_left = np.array(populations["visual_lc4"]["left"], dtype=np.int32)
        self.lc4_right = np.array(populations["visual_lc4"]["right"], dtype=np.int32)
        # Tree-looming columnar pool (free in the base connectome; never
        # driven until the rival-vs-tree split). Side-gated exactly like LC10:
        # a tree on the LEFT fires LPLC2-L, right fires LPLC2-R.
        self.lplc2_left = np.array(populations["visual_lplc2"]["left"], dtype=np.int32)
        self.lplc2_right = np.array(populations["visual_lplc2"]["right"], dtype=np.int32)
        # Retina feature pools (stale-cache safe: absent pools read empty
        # and contribute nothing, so old caches keep working).
        lc11 = populations.get("visual_lc11", {})
        self.lc11_left = np.array(lc11.get("left", []), dtype=np.int32)
        self.lc11_right = np.array(lc11.get("right", []), dtype=np.int32)
        lc15 = populations.get("visual_lc15", {})
        self.lc15_left = np.array(lc15.get("left", []), dtype=np.int32)
        self.lc15_right = np.array(lc15.get("right", []), dtype=np.int32)
        lc17 = populations.get("visual_lc17", {})
        self.lc17_left = np.array(lc17.get("left", []), dtype=np.int32)
        self.lc17_right = np.array(lc17.get("right", []), dtype=np.int32)
        lc18 = populations.get("visual_lc18", {})
        self.lc18_left = np.array(lc18.get("left", []), dtype=np.int32)
        self.lc18_right = np.array(lc18.get("right", []), dtype=np.int32)
        # Translational optic flow (T4/T5 direction cells, flow_trans
        # scheme only; stale-cache safe like the rest).
        self.t4a_left, self.t4a_right = _side_pair(populations, "visual_t4a")
        self.t4b_left, self.t4b_right = _side_pair(populations, "visual_t4b")
        self.t4c_left, self.t4c_right = _side_pair(populations, "visual_t4c")
        self.t4d_left, self.t4d_right = _side_pair(populations, "visual_t4d")
        self.t5a_left, self.t5a_right = _side_pair(populations, "visual_t5a")
        self.t5b_left, self.t5b_right = _side_pair(populations, "visual_t5b")
        self.t5c_left, self.t5c_right = _side_pair(populations, "visual_t5c")
        self.t5d_left, self.t5d_right = _side_pair(populations, "visual_t5d")
        # Panoramic column centers shared with the arena/trainer grids.
        self.sec_az = (-150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0)
        # Reference pool sizes: stimulus spike counts scale to the LARGER
        # sibling pool (sampling with replacement past pool size). MaleCNS
        # leaves some pools asymmetric (e.g. ORN_DA1 51L/105R with the rest
        # side-unknown); without this, one antenna would drive half as hard.
        self.da1_ref = max(len(self.da1_left), len(self.da1_right), 1)
        self.va1v_ref = max(len(self.va1v_left), len(self.va1v_right), 1)
        # ORN habituation state: sustained odor adapts the encoder gain
        # down so glued-on smells don't saturate the ORNs. Totals below
        # HAB_KNEE (the far-field floor zone) never habituate, so the
        # trace that guarantees re-acquisition survives; recovery is slow
        # (tens of seconds of battle time). Fresh encoders start at 1.0,
        # so single-shot tests and first encounters are unaffected; call
        # reset_odor() at episode/battle boundaries for a fresh nose.
        self.odor_gain = 1.0
        # Optic-flow habituation + saccade gate (T4/T5 windup guard):
        # per-direction gains adapt down under sustained saturating flow
        # (same leaky mechanics as odor, no knee - flow legitimately reads
        # zero), while the spin gate scales all flow drive by present
        # angular rate (saccade suppression: vision goes quiet mid-spin,
        # cutting the spin->flow->spin loop at its source).
        self.flow_hab = {"a": 1.0, "b": 1.0, "c": 1.0, "d": 1.0}
        self.lplc2_ref = max(len(self.lplc2_left), len(self.lplc2_right), 1)
        # Antennal gyroscope (JO), gyro_flow scheme only. Stale caches
        # predate these pools: .get keeps old vault tooling importable.
        jo = populations.get("gyro_jo", {})
        self.jo_left = np.array(jo.get("left", []), dtype=np.int32)
        self.jo_right = np.array(jo.get("right", []), dtype=np.int32)
        self.jo_ref = max(len(self.jo_left), len(self.jo_right), 1)

    # Habituation tuning (per 50 ms encode tick): attack ~3 s,
    # recover ~20 s. Floor at 0.3 keeps a saturated nose 30% awake.
    HAB_KNEE = 0.3
    HAB_FLOOR = 0.3
    HAB_ATTACK = 1.0 / 60.0
    HAB_RECOVER = 1.0 / 400.0
    # Flow habituation uses the same rates/floor; spin gate halves drive
    # at |yaw|+|roll| == 1/3 and quarters it at full spin.
    FLOW_SPIN_GAIN = 3.0

    @staticmethod
    def _sample(pool, k):
        if k <= 0 or len(pool) == 0:
            return []
        return np.random.choice(pool, size=k, replace=k > len(pool))

    def reset_odor(self):
        """Fresh-nose reset for episode/battle boundaries (also clears
        flow habituation - same call, one reset path)."""
        self.odor_gain = 1.0
        self.flow_hab = {"a": 1.0, "b": 1.0, "c": 1.0, "d": 1.0}

    def encode(self, sensory_dict, dt=0.5, duration_ms=50.0):
        """
        sensory_dict contains:
          - pheromone_conc_left: float [0.0 .. 1.0] (Rival fly scent on left antenna)
          - pheromone_conc_right: float [0.0 .. 1.0] (Rival fly scent on right antenna)
          - scent_lost: float seconds since usable scent (floor-relative;
            drives search steering when > 3 with nothing visible)
          - scent_cast: float [-1.0 .. 1.0] slow cast bias for search sweeps
          - scent_surge: float [0.0 .. 1.0] rising-total-conc surge (chemo-
            taxis thrust). All three default to found/calm when absent.
          - visual_target_azimuth: float [-180 .. +180] deg (0 = directly ahead, - = left, + = right)
          - visual_target_elevation: float [-90 .. +90] deg
          - visual_target_visible: bool
          - visual_rival_looming: float [0.0 .. 1.0] (angular expansion of the rival)
          - visual_tree_left/ahead/right_looming: float [0.0 .. 1.0] (side-gated wood)
          - visual_tree_looming: float [0.0 .. 1.0] (max over the tree directions)
          - visual_looming_rate: float [0.0 .. 1.0] (LEGACY fused max(rival, tree))
          - angular_yaw_rate: float [-1.0 .. 1.0] (body yaw rate, + = right;
            gyro_flow only, drives JO)
          - angular_pitch_rate: float [-1.0 .. 1.0] (nose-up rate; gyro_flow)
          - angular_roll_rate: float [-1.0 .. 1.0] (bank rate, + = right;
            gyro_flow only, drives JO)
        Legacy dicts without the split keys keep the old behavior exactly:
        visual_looming_rate drives LC4 for anything looming (backward compat).
        Dicts without angular_* keys drive no JO spikes (trainer/arena-old).
        """
        spikes = []
        n_steps = int(duration_ms / dt)

        # 1. Pheromone Encoding (ORN_DA1 and ORN_VA1v)
        c_left = np.clip(sensory_dict.get("pheromone_conc_left", 0.0), 0.0, 1.0)
        c_right = np.clip(sensory_dict.get("pheromone_conc_right", 0.0), 0.0, 1.0)

        # ORN habituation: adapt the drive gain to sustained odor above
        # the floor knee; recover slowly in clean air. The floor zone
        # never adapts (gain target 1.0 there).
        total_odor = float(c_left + c_right)
        excess = max(0.0, total_odor - self.HAB_KNEE)
        target = max(self.HAB_FLOOR, 1.0 / (1.0 + 2.0 * excess))
        rate = self.HAB_ATTACK if target < self.odor_gain else self.HAB_RECOVER
        self.odor_gain += (target - self.odor_gain) * rate
        g = self.odor_gain

        # Left antenna ORNs
        if c_left > 0.01 and len(self.da1_left) > 0:
            spikes.extend(self._sample(self.da1_left, int(c_left * self.da1_ref * g)))
            spikes.extend(self._sample(self.va1v_left, int(c_left * self.va1v_ref * g)))

        # Right antenna ORNs
        if c_right > 0.01 and len(self.da1_right) > 0:
            spikes.extend(self._sample(self.da1_right, int(c_right * self.da1_ref * g)))
            spikes.extend(self._sample(self.va1v_right, int(c_right * self.va1v_ref * g)))

        # 2. Visual Small Target Tracking (LC10)
        # Fires when target fly is within forward visual hemisphere
        if sensory_dict.get("visual_target_visible", False):
            azimuth = sensory_dict.get("visual_target_azimuth", 0.0)
            # If target is to the left (-), drive left LC10; if right (+), drive right LC10.
            # Dead-ahead (== 0) splits half drive to each side: steering
            # toward a head-on target has no preferred handedness, and the
            # old >= 0 rule fed a systematic rightward bias.
            if azimuth < 0 and len(self.lc10_left) > 0:
                intensity = np.clip((azimuth + 90.0) / 90.0, 0.2, 1.0)
                k = int(intensity * min(30, len(self.lc10_left)))
                if k > 0:
                    spikes.extend(np.random.choice(self.lc10_left, size=k, replace=False))
            elif azimuth > 0 and len(self.lc10_right) > 0:
                intensity = np.clip((90.0 - azimuth) / 90.0, 0.2, 1.0)
                k = int(intensity * min(30, len(self.lc10_right)))
                if k > 0:
                    spikes.extend(np.random.choice(self.lc10_right, size=k, replace=False))
            elif azimuth == 0 and (len(self.lc10_left) > 0 or len(self.lc10_right) > 0):
                if len(self.lc10_left) > 0:
                    k = int(0.5 * min(30, len(self.lc10_left)))
                    if k > 0:
                        spikes.extend(np.random.choice(self.lc10_left, size=k, replace=False))
                if len(self.lc10_right) > 0:
                    k = int(0.5 * min(30, len(self.lc10_right)))
                    if k > 0:
                        spikes.extend(np.random.choice(self.lc10_right, size=k, replace=False))

        # 3. Visual Rival Looming (LC4) - rapid optical expansion of the target.
        # Split from wood: trees drive LPLC2 (below), rivals drive LC4, so the
        # two no longer share a channel and dopamine can train them apart.
        # Legacy brains predate the split: the fused key they trained on
        # drives LC4, and the split keys are ignored (the arena still sends
        # the fused key, so old tree-dodge training applies again).
        if self.legacy:
            rival_loom = np.clip(sensory_dict.get("visual_looming_rate", 0.0), 0.0, 1.0)
        else:
            rival_loom = np.clip(sensory_dict.get(
                "visual_rival_looming", sensory_dict.get("visual_looming_rate", 0.0)), 0.0, 1.0)
        if rival_loom > 0.1:
            # Per-side sizing: each pool is sampled against its own size
            # (a shared cap silently clips the larger pool if counts shift).
            k_l = int(rival_loom * min(40, len(self.lc4_left)))
            k_r = int(rival_loom * min(40, len(self.lc4_right)))
            if k_l > 0 and len(self.lc4_left) > 0:
                spikes.extend(np.random.choice(self.lc4_left, size=k_l, replace=False))
            if k_r > 0 and len(self.lc4_right) > 0:
                spikes.extend(np.random.choice(self.lc4_right, size=k_r, replace=False))

        # 3b. Visual Tree Looming (LPLC2) - side-gated avoidance channel.
        # Left/ahead/right nose rays. A dead-ahead tree splits half its drive
        # to each side (steering away has no preferred handedness head-on),
        # while a side tree fires the corresponding LPLC2 pool, which via the
        # experiment's contralateral wiring steers AWAY from the bark.
        tree_l = np.clip(sensory_dict.get("visual_tree_left_looming", 0.0), 0.0, 1.0)
        tree_r = np.clip(sensory_dict.get("visual_tree_right_looming", 0.0), 0.0, 1.0)
        tree_a = np.clip(sensory_dict.get("visual_tree_ahead_looming", 0.0), 0.0, 1.0)
        # Retina brains read wood from the panoramic sector grid instead
        # (7 rays, full circle); the 3-ray fan stays for all other regimes.
        use_sector_wood = "retina" in self.schemes and not self.legacy
        if self.legacy:
            tree_l = tree_r = tree_a = 0.0
        if tree_l + tree_r + tree_a > 0.1 and not use_sector_wood:
            k_l = int((tree_l + 0.5 * tree_a) * 0.4 * self.lplc2_ref)
            k_r = int((tree_r + 0.5 * tree_a) * 0.4 * self.lplc2_ref)
            if k_l > 0 and len(self.lplc2_left) > 0:
                spikes.extend(np.random.choice(
                    self.lplc2_left, size=min(k_l, len(self.lplc2_left)), replace=False))
            if k_r > 0 and len(self.lplc2_right) > 0:
                spikes.extend(np.random.choice(
                    self.lplc2_right, size=min(k_r, len(self.lplc2_right)), replace=False))

        # 3d. Panoramic sector grid (retina scheme only): 7 azimuth
        # columns x 3 elevation bands = 21 cells (bands 0/1/2 = up/level/
        # down, columns match sec_az). Rival presence+size drives LC11
        # (small-object tracking, side-gated, rear included); frontal
        # loom (|col| <= 100) drives the LC15/17/18 loom-feature pools;
        # wood occupancy drives LPLC2 sides (max per hemifield). Rear
        # cells track only: nothing here feeds evade gates.
        if "retina" in self.schemes and not self.legacy:
            pres = list(sensory_dict.get("visual_sec_presence", []) or [])
            size = list(sensory_dict.get("visual_sec_size", []) or [])
            loom = list(sensory_dict.get("visual_sec_loom", []) or [])
            wood = list(sensory_dict.get("visual_sec_tree", []) or [])
            if len(pres) == 21 and len(size) == 21 \
                    and len(loom) == 21 and len(wood) == 21:
                for band in range(3):
                    for ci in range(7):
                        idx = band * 7 + ci
                        col = self.sec_az[ci]
                        frontal = abs(col) <= 100.0
                        pools_l = [(self.lc11_left, size[idx], 30),
                                   (self.lc15_left, loom[idx] if frontal else 0.0, 20),
                                   (self.lc17_left, loom[idx] if frontal else 0.0, 20),
                                   (self.lc18_left, loom[idx] if frontal else 0.0, 20)]
                        pools_r = [(self.lc11_right, size[idx], 30),
                                   (self.lc15_right, loom[idx] if frontal else 0.0, 20),
                                   (self.lc17_right, loom[idx] if frontal else 0.0, 20),
                                   (self.lc18_right, loom[idx] if frontal else 0.0, 20)]
                        if pres[idx] > 0.5:
                            if col < 0:
                                targets = pools_l
                            elif col > 0:
                                targets = pools_r
                            else:
                                targets = pools_l + pools_r
                            for pool, mag, gain in targets:
                                if len(pool) > 0 and mag > 0.01:
                                    k = min(int(mag * gain), len(pool))
                                    if k > 0:
                                        spikes.extend(np.random.choice(
                                            pool, size=k, replace=False))
                        _w = wood[idx]
                        if _w > 0.05:
                            if col < 0:
                                tgts = (self.lplc2_left,)
                            elif col > 0:
                                tgts = (self.lplc2_right,)
                            else:
                                tgts = (self.lplc2_left, self.lplc2_right)
                            for tgt in tgts:
                                if len(tgt) > 0:
                                    k = min(int(_w * (37 if len(tgts) == 1 else 18)),
                                            len(tgt))
                                    if k > 0:
                                        spikes.extend(np.random.choice(
                                            tgt, size=k, replace=False))

        # 3c. Antennal gyroscope (JO) - body angular rates, gyro_flow only.
        # Real JO afferents are bilateral with ipsilateral dominance: a
        # rightward yaw/roll spins JO-R hard and JO-L weakly, pitch spins
        # both (no handedness). Base scheme skips this section entirely,
        # as does legacy mode (pre-mapping brains never drove JO).
        if "gyro_flow" in self.schemes and not self.legacy:
            yaw_rate = float(np.clip(sensory_dict.get("angular_yaw_rate", 0.0), -1.0, 1.0))
            roll_rate = float(np.clip(sensory_dict.get("angular_roll_rate", 0.0), -1.0, 1.0))
            pitch_rate = float(np.clip(sensory_dict.get("angular_pitch_rate", 0.0), -1.0, 1.0))
            spin = abs(yaw_rate) + abs(roll_rate)
            if spin + abs(pitch_rate) > 0.05 and self.jo_ref > 0:
                strong = int(np.clip(spin, 0.0, 1.0) * 0.4 * self.jo_ref)
                weak = int(np.clip(spin, 0.0, 1.0) * 0.1 * self.jo_ref)
                pitch_k = int(np.clip(abs(pitch_rate), 0.0, 1.0) * 0.3 * self.jo_ref)
                if yaw_rate + roll_rate >= 0.0:
                    k_r, k_l = strong + pitch_k, weak + pitch_k
                else:
                    k_r, k_l = weak + pitch_k, strong + pitch_k
                if k_l > 0 and len(self.jo_left) > 0:
                    spikes.extend(np.random.choice(
                        self.jo_left, size=min(k_l, len(self.jo_left)), replace=False))
                if k_r > 0 and len(self.jo_right) > 0:
                    spikes.extend(np.random.choice(
                        self.jo_right, size=min(k_r, len(self.jo_right)), replace=False))

        # 3e. Translational optic flow (T4/T5) - ground-relative motion,
        # flow_trans scheme only. Ventral (forward) flow drives the
        # progressive pools (a), lateral slip the regressive pools (b),
        # expansion-on-descent the downward pools (d), climbs the upward
        # pools (c). Symmetric (both sides, no handedness) except the
        # decoder's drift trim, which reads the signed key, not the
        # spikes. Base scheme and legacy mode skip this section.
        if "flow_trans" in self.schemes and not self.legacy:
            ventral = float(np.clip(sensory_dict.get(
                "visual_flow_ventral", 0.0), 0.0, 1.0))
            lateral = float(np.clip(sensory_dict.get(
                "visual_flow_lateral", 0.0), -1.0, 1.0))
            expansion = float(np.clip(sensory_dict.get(
                "visual_flow_expansion", 0.0), 0.0, 1.0))
            climb = float(np.clip(sensory_dict.get(
                "visual_flow_climb", 0.0), 0.0, 1.0))
            # Saccade gate: present angular rate quiets all flow drive
            # (vision suppresses mid-spin, cutting spin->flow->spin).
            # Absent keys read 0, so single-shot and legacy-adjacent
            # callers see gain exactly 1.0.
            spin = abs(float(sensory_dict.get("angular_yaw_rate", 0.0))) \
                + abs(float(sensory_dict.get("angular_roll_rate", 0.0)))
            spin_gate = 1.0 / (1.0 + self.FLOW_SPIN_GAIN * spin)
            flow_groups = [
                ("a", ventral, (self.t4a_left, self.t4a_right,
                                self.t5a_left, self.t5a_right)),
                ("b", abs(lateral), (self.t4b_left, self.t4b_right,
                                     self.t5b_left, self.t5b_right)),
                ("d", expansion, (self.t4d_left, self.t4d_right,
                                  self.t5d_left, self.t5d_right)),
                ("c", climb, (self.t4c_left, self.t4c_right,
                              self.t5c_left, self.t5c_right)),
            ]
            for gkey, mag, pools in flow_groups:
                # Per-direction habituation: sustained saturating flow
                # adapts that group down (floor 0.3, slow recovery).
                target = max(self.HAB_FLOOR, 1.0 / (1.0 + 2.0 * mag))
                rate = self.HAB_ATTACK if target < self.flow_hab[gkey] \
                    else self.HAB_RECOVER
                self.flow_hab[gkey] += (target - self.flow_hab[gkey]) * rate
                g = self.flow_hab[gkey] * spin_gate
                if mag > 0.05:
                    for pool in pools:
                        if len(pool) == 0:
                            continue
                        k = min(int(mag * 30 * g), len(pool))
                        if k > 0:
                            spikes.extend(np.random.choice(
                                pool, size=k, replace=False))

        return np.array(spikes, dtype=np.int32)


class MotorDecoder:
    """
    Decodes descending neuron spike counts over a 50 ms tick into physical flight controls:
      - forward_thrust: float [0.0 .. 1.0] (DN population rate + DNp09)
      - yaw_torque: float [-1.0 .. +1.0] (DN left-vs-right population vector + DNp20)
      - ram_burst: bool (from high-frequency DNpe017)
      - emergency_evade: bool (from Giant Fiber DNp01)
      - roll_torque: float [-1.0 .. +1.0] (VS/HS optic-flow balance; gyro_flow
        scheme only, 0.0 otherwise)
      - approach_bias: float [-1.0 .. +1.0] (MBON approach/avoid balance;
        mbon scheme only, 0.0 otherwise). Positive scales thrust/pursuit
        up (close in), negative scales them down (break off).
    mapping selects the neuro-mapping scheme ('base' default). The
    'muscles_up' scheme adds flight-muscle (MN) votes to thrust/yaw; the
    'gyro_flow' scheme adds the VS/HS roll output; the 'mbon' scheme adds
    the mushroom-body value readout; 'flow_trans' adds T4/T5 cruise
    control, drift trim, and landing flare. Base output is bit-identical
    to the pre-mapping decoder.
    Uses the full ~1303 descending neuron pool for robustness: single-cell
    DNp09/DNp20 readouts are too sparse (2 cells) and drown in noise.
    Sign convention: yaw > 0 = turn right, yaw < 0 = turn left.
    Roll convention mirrors yaw: roll > 0 = bank right.
    legacy=True restores the pre-mapping operating point for old brains:
    stronger DN thrust gain (their weights were tuned for it, and the
    recalibrated gain leaves their thrust flat at baseline). Steering
    readout is deliberately UNCHANGED: measured old-brain spikes show a
    silent left-DN pool (no decoder can extract left steering from zero
    spikes), so the bias-corrected reflex-led readout — whose signs
    validate correct — stays for both regimes.
    """
    def __init__(self, populations, mapping=None, legacy=False,
                 yaw_bias=None, blends=None):
        self.schemes = normalize_mapping(mapping)
        self.legacy = bool(legacy)
        self._dn_gain = 0.008 if self.legacy else 0.0005
        # Reflex authority per channel (heritable evolvable traits;
        # defaults reproduce the legacy operating point exactly):
        # yaw_blend = brain share of yaw (legacy 0.3 brain / 0.7 reflex),
        # evade_backup = reflex evade backup on (>0.5) or pure GF,
        # flow_authority = cruise/drift/flare trim gain, search_blend =
        # lost-search cast share, pitch_blend = reflex share of pitch.
        self._blends = dict(BLEND_DEFAULTS)
        for k, v in (blends or {}).items():
            if k in self._blends:
                try:
                    self._blends[k] = max(0.0, min(1.0, float(v)))
                except (TypeError, ValueError):
                    pass
        # Per-brain intrinsic DN lateralization correction (default 9.0:
        # measured dnR-dnL on symmetric input). A single constant
        # over-steers brains whose true bias runs lower (constant left
        # crawl), so records may stamp their own value (vault
        # generator_params["yaw_bias"], menu spinbox + randomize).
        self._dn_bias = normalize_yaw_bias(yaw_bias)
        self.dnp09_ids = set(populations["motor_thrust_dnp09"]["all"])
        self.dnp20_left = set(populations["motor_turn_dnp20"]["left"])
        self.dnp20_right = set(populations["motor_turn_dnp20"]["right"])
        self.gf_ids = set(populations["motor_giant_fiber"]["all"])
        self.dnpe017_ids = set(populations["motor_ram_dnpe017"]["all"])
        # Full DN population vector (robust steering/thrust readout).
        # Fall back to specific DNs if cache is stale.
        desc = populations.get("descending_all", {})
        self.dn_left = set(desc.get("left", []))
        self.dn_right = set(desc.get("right", []))
        self.dn_all = set(desc.get("all", []))
        if not self.dn_all:
            self.dn_left = set(populations["motor_turn_dnp20"]["left"])
            self.dn_right = set(populations["motor_turn_dnp20"]["right"])
            self.dn_all = self.dnp09_ids | self.dnp20_left | self.dnp20_right
        # Neuro-mapping readout pools (stale-cache safe: missing pools read
        # as empty, which contributes zero votes).
        mn_thrust = populations.get("motor_flight_thrust", {})
        self.mn_thrust_ids = set(mn_thrust.get("all", []))
        # Mouth-motor readout (spear lunge; stale-cache safe). Silent
        # pools read 0 = no lunge, so brains without the spear_lunge
        # wiring are unaffected by this readout existing.
        mouth = populations.get("motor_mouth", {})
        self.mouth_ids = set(mouth.get("all", []))
        # Retina feature readout pools (stale-cache safe like the rest).
        lc11 = populations.get("visual_lc11", {})
        self.lc11_left = set(lc11.get("left", []))
        self.lc11_right = set(lc11.get("right", []))
        self.lc11_all = set(lc11.get("all", []))
        self.lc_loom_ids = set()
        for _lk in ("visual_lc15", "visual_lc17", "visual_lc18"):
            self.lc_loom_ids |= set(populations.get(_lk, {}).get("all", []))
        mn_steer = populations.get("motor_steer", {})
        self.mn_steer_left = set(mn_steer.get("left", []))
        self.mn_steer_right = set(mn_steer.get("right", []))
        # Haltere roll-motor readout (learned banks; stale-cache safe).
        # Silent pools read 0 = wings level, so brains without roll
        # wiring fly exactly as before.
        mnhl = populations.get("motor_roll_mnhl", {})
        self.mnhl_left = set(mnhl.get("left", []))
        self.mnhl_right = set(mnhl.get("right", []))
        flow_vs = populations.get("flow_vs", {})
        self.vs_left = set(flow_vs.get("left", []))
        self.vs_right = set(flow_vs.get("right", []))
        flow_hs = populations.get("flow_hs", {})
        self.hs_left = set(flow_hs.get("left", []))
        self.hs_right = set(flow_hs.get("right", []))
        # Reference pool sizes for the roll balance: raw spike counts
        # would hand the larger sibling pool (VS 18R vs 16L) a built-in
        # ~0.26 right-roll bias at equal drive. Each side is normalized
        # to its own pool, then scaled back to the legacy operating
        # point (mean pool size), so symmetric drive reads exactly zero.
        self.vs_ref = (len(self.vs_left) + len(self.vs_right)) / 2.0 or 1.0
        self.hs_ref = (len(self.hs_left) + len(self.hs_right)) / 2.0 or 1.0
        # Mushroom-body valence readout (stale-cache safe like the rest).
        mbon_app = populations.get("mbon_app", {})
        self.mbon_app_ids = set(mbon_app.get("all", []))
        mbon_av = populations.get("mbon_av", {})
        self.mbon_av_ids = set(mbon_av.get("all", []))
        # Translational-flow direction groups for the neural cruise/
        # flare/pitch votes (flow_trans encoder drives these; silent
        # pools read 0 = no vote, so unwired brains fly as before).
        self.t4a_ids = set()
        self.t4c_ids = set()
        self.t4d_ids = set()
        for _key, _dest in (("visual_t4a", "t4a_ids"),
                            ("visual_t5a", "t4a_ids"),
                            ("visual_t4c", "t4c_ids"),
                            ("visual_t5c", "t4c_ids"),
                            ("visual_t4d", "t4d_ids"),
                            ("visual_t5d", "t4d_ids")):
            getattr(self, _dest).update(
                populations.get(_key, {}).get("all", []))
        # ORN pools for the neural lost-search vote (encoder-driven;
        # silent = fall back to the arena cast sweep, as before).
        da1 = populations.get("pheromone_da1", {})
        va1v = populations.get("pheromone_va1v", {})
        self.orn_left = set(da1.get("left", [])) | set(va1v.get("left", []))
        self.orn_right = set(da1.get("right", [])) | set(va1v.get("right", []))

    def decode(self, fired_spikes, sensory_hint=None, _counts_out=None):
        # _counts_out: optional caller-owned dict to fill instead of a
        # fresh one (the live loop reuses it for stats: one count build
        # per brain per tick instead of two). Omit it and behavior is
        # exactly as before.
        spike_set = list(fired_spikes)
        if len(spike_set) == 0:
            base = {
                "thrust": 0.2,          # Baseline cruise thrust
                "yaw_torque": 0.0,
                "pitch_torque": 0.0,
                "roll_torque": 0.0,     # Wings-level hold (no flow signal)
                "approach_bias": 0.0,   # No learned value without spikes
                "ram_burst": False,
                "emergency_evade": False,
                "spear_thrust": 0.0
            }
            if sensory_hint is None:
                return base
            # No brain spikes: fall back to pure reflex so the fly still homess.
            # Dead-brain failsafe, blend-exempt by design: with no neural
            # activity there is no brain vote to arbitrate, so reflex owns
            # every channel (see CONTROL_CHANNELS). Surge applies here too:
            # a homing fly spends extra thrust closing.
            fb_surge = float(np.clip(sensory_hint.get("scent_surge", 0.0), 0.0, 1.0))
            return {
                "thrust": float(np.clip(0.2 + fb_surge * 0.25, 0.0, 1.0)),
                "yaw_torque": float(self._lost_search_yaw(
                    sensory_hint, self.reflex_yaw(sensory_hint))),
                "pitch_torque": float(self.reflex_pitch(sensory_hint)),
                "roll_torque": 0.0,
                "approach_bias": 0.0,
                "ram_burst": False,
                "emergency_evade": bool(self.reflex_evade(sensory_hint)
                                        or self.reflex_evade_tree(sensory_hint)),
                "spear_thrust": 0.0
            }

        counts = _counts_out if _counts_out is not None else {}
        for s in spike_set:
            counts[s] = counts.get(s, 0) + 1

        # 1. Forward Thrust: DN population rate + DNp09 kick.
        # Recalibrated for the living network (post-continuity fix the DN
        # pool fires ~100 spikes/tick steady): each spike ~0.0005 thrust so
        # cruise trims +0.05 over baseline instead of pinning at max.
        # Surges still come from DNp09 kicks and MN votes (capped). Legacy
        # brains keep the pre-mapping gain their weights were tuned for.
        dnp09_spikes = sum(counts.get(s, 0) for s in self.dnp09_ids)
        dn_total = sum(counts.get(s, 0) for s in self.dn_all)
        thrust = 0.2 + np.clip(dn_total * self._dn_gain, 0.0, 0.6) + np.clip(dnp09_spikes * 0.15, 0.0, 0.4)
        if "muscles_up" in self.schemes and not self.legacy:
            mn_thrust_spikes = sum(counts.get(s, 0) for s in self.mn_thrust_ids)
            thrust += np.clip(mn_thrust_spikes * 0.015, 0.0, 0.25)
        if "retina" in self.schemes and not self.legacy:
            # Panoramic feature drive: LC11 presence/size pushes pursuit
            # thrust, loom-feature spikes add urgency. Pursuit-only path:
            # nothing here touches evade, so rear tracking stays safe.
            lc11_spikes = sum(counts.get(s, 0) for s in self.lc11_all)
            thrust += np.clip(lc11_spikes * 0.006, 0.0, 0.2)
            loom_spikes = sum(counts.get(s, 0) for s in self.lc_loom_ids)
            thrust += np.clip(loom_spikes * 0.004, 0.0, 0.15)
        thrust = float(np.clip(thrust, 0.0, 1.0))
        if sensory_hint is not None:
            # Chemotaxis surge: rising total scent means closing - spend
            # up to +0.25 extra thrust on it. Absent key reads 0.
            surge = float(np.clip(sensory_hint.get("scent_surge", 0.0), 0.0, 1.0))
            thrust = float(np.clip(thrust + surge * 0.25, 0.0, 1.0))

        # 2. Steering / Yaw Torque: normalized DN population vector + DNp20.
        # Normalized (tanh) so small lateral diffs still steer and total
        # excitation level doesn't saturate yaw. Preserves DNp20 compat.
        turn_left = sum(counts.get(s, 0) for s in self.dnp20_left)
        turn_right = sum(counts.get(s, 0) for s in self.dnp20_right)
        dn_left_spikes = sum(counts.get(s, 0) for s in self.dn_left)
        dn_right_spikes = sum(counts.get(s, 0) for s in self.dn_right)
        yaw_specific = (turn_right - turn_left) * 0.25
        # Intrinsic connectome bias (dnR-dnL ~+9 on symmetric input;
        # LEFT +7 / RIGHT +10 / AHEAD +10 avg over 5 trials post-continuity)
        # is subtracted so LEFT goes negative, RIGHT positive, AHEAD ~= 0.
        # Per-brain override lives in self._dn_bias (default 9.0).
        yaw_pop = float(np.tanh((dn_right_spikes - dn_left_spikes - self._dn_bias) / 15.0) * 0.9)
        brain_yaw = float(np.clip(yaw_specific + yaw_pop, -1.0, 1.0))
        if "muscles_up" in self.schemes and not self.legacy:
            # Steering-muscle laterality: MNad-R minus MNad-L, normalized so
            # small MN diffs still steer without saturating on DN excitation.
            mn_r = sum(counts.get(s, 0) for s in self.mn_steer_right)
            mn_l = sum(counts.get(s, 0) for s in self.mn_steer_left)
            yaw_mn = float(np.tanh((mn_r - mn_l) / 8.0) * 0.5)
            brain_yaw = float(np.clip(brain_yaw + yaw_mn, -1.0, 1.0))
        if "retina" in self.schemes and not self.legacy:
            # Small-object fixation: LC11-R minus LC11-L steers toward the
            # seen object (sign-correct pursuit, rear-safe: never evades).
            lc11_r = sum(counts.get(s, 0) for s in self.lc11_right)
            lc11_l = sum(counts.get(s, 0) for s in self.lc11_left)
            yaw_lc = float(np.tanh((lc11_r - lc11_l) / 8.0) * 0.5)
            brain_yaw = float(np.clip(brain_yaw + yaw_lc, -1.0, 1.0))
        if sensory_hint is not None:
            # Parallel olfactory/visual reflex (antenna tropotaxis + visual
            # fixation), blended with brain readout. Legacy 30/70: reflex
            # dominates the TURN SIGN (brain alone has a rightward bias
            # that training only partly removes); brain sets
            # thrust/bursts/variation. yaw_blend is heritable, so
            # evolution can migrate the turn vote onto neurons.
            w = float(self._blends["yaw_blend"])
            reflex = self.reflex_yaw(sensory_hint)
            yaw_torque = float(np.clip(
                w * brain_yaw + (1.0 - w) * reflex, -1.0, 1.0))
            yaw_torque = self._lost_search_yaw(
                sensory_hint, yaw_torque, self._search_dir(counts))
        else:
            yaw_torque = brain_yaw

        # 3. High-Speed Ramming Charge (DNpe017)
        ram_spikes = sum(counts.get(s, 0) for s in self.dnpe017_ids)
        ram_burst = ram_spikes >= 2

        # 3b. Spear thrust (MNxm mouth motor readout). Fires the couched
        # lance forward when the mouth circuit votes strongly AND the
        # rival is visibly frontal (aim gate shared with the GF evade, so
        # rear tracking can never trigger a lunge). Read for every brain;
        # pools without the spear_lunge wiring stay silent and read 0.
        mouth_spikes = sum(counts.get(s, 0) for s in self.mouth_ids)
        spear_thrust = 0.0
        if mouth_spikes >= 3:
            aimed = True
            if sensory_hint is not None:
                aimed = bool(sensory_hint.get("visual_target_visible", False)) \
                    and abs(float(sensory_hint.get("visual_target_azimuth", 0.0))) < 50.0
            if aimed:
                spear_thrust = float(np.clip((mouth_spikes - 2) * 0.15, 0.0, 1.0))

        # 4. Emergency Evasive Roll / Dive (Giant Fiber + looming reflexes).
        # The connectome LC4 -> GF path fires (both GF cells, sustained;
        # verified after the LIF continuity fix); parallel reflexes stay as
        # backup so the fly still reacts on ticks the GF pool misses.
        # GF evade is gated on a visibly frontal rival: the arena reports
        # rival loom from distance change alone, so an unseen rival (or
        # legacy fused tree loom) would otherwise roll/dive the fly for no
        # visible reason. Hint-less diagnostic calls keep the raw readout.
        gf_spikes = sum(counts.get(s, 0) for s in self.gf_ids)
        emergency_evade = (gf_spikes >= 1)
        if emergency_evade and sensory_hint is not None:
            vis = bool(sensory_hint.get("visual_target_visible", False))
            az = abs(float(sensory_hint.get("visual_target_azimuth", 0.0)))
            emergency_evade = bool(vis and az < 50.0)
        # Reflex backup is heritable (legacy on): evade_backup above
        # 0.5 keeps the loom reflexes behind the GF drive; at or below,
        # the fly trusts its giant fiber alone.
        if sensory_hint is not None \
                and float(self._blends["evade_backup"]) > 0.5:
            emergency_evade = emergency_evade or bool(self.reflex_evade(sensory_hint)) \
                or bool(self.reflex_evade_tree(sensory_hint))

        # 5. Roll torque (VS/HS optic-flow balance): gyro_flow scheme only.
        # Right-side tangential spikes bank right; HS counts half weight
        # (8 cells vs 34 VS). Base scheme holds wings level (0.0), as does
        # legacy mode.
        roll_torque = 0.0
        if "gyro_flow" in self.schemes and not self.legacy:
            vs_r = sum(counts.get(s, 0) for s in self.vs_right)
            vs_l = sum(counts.get(s, 0) for s in self.vs_left)
            hs_r = sum(counts.get(s, 0) for s in self.hs_right)
            hs_l = sum(counts.get(s, 0) for s in self.hs_left)
            n_vs_l = max(len(self.vs_left), 1)
            n_vs_r = max(len(self.vs_right), 1)
            n_hs_l = max(len(self.hs_left), 1)
            n_hs_r = max(len(self.hs_right), 1)
            flow = ((vs_r / n_vs_r - vs_l / n_vs_l) * self.vs_ref
                    + 0.5 * (hs_r / n_hs_r - hs_l / n_hs_l) * self.hs_ref)
            roll_torque = float(np.clip(np.tanh(flow / 6.0) * 0.8, -1.0, 1.0))
        # Learned banks: haltere-motor laterality under muscles_up, same
        # sign convention as the MNad yaw vote (R-L positive = right).
        # The VS/HS closed-loop trim above stays untouched.
        if "muscles_up" in self.schemes and not self.legacy:
            mnhl_r = sum(counts.get(s, 0) for s in self.mnhl_right)
            mnhl_l = sum(counts.get(s, 0) for s in self.mnhl_left)
            roll_mn = float(np.tanh((mnhl_r - mnhl_l) / 8.0) * 0.5)
            roll_torque = float(np.clip(roll_torque + roll_mn, -1.0, 1.0))

        # 6. Learned value (MBON balance): mbon scheme only. Approach
        # (ACh MBONs) over avoid (Glu/GABA MBONs) scales thrust up and
        # sharpens pursuit; the reverse throttles back to break off.
        # Magnitude-only scaling: the sign of yaw is never flipped.
        # Legacy mode never takes this branch (pre-mapping brains never
        # drove the MBON readout).
        approach_bias = 0.0
        if "mbon" in self.schemes and not self.legacy:
            app = sum(counts.get(s, 0) for s in self.mbon_app_ids)
            avv = sum(counts.get(s, 0) for s in self.mbon_av_ids)
            approach_bias = float(np.clip(np.tanh((app - avv) / 8.0), -1.0, 1.0))
            thrust = float(np.clip(thrust * (1.0 + 0.3 * approach_bias), 0.0, 1.0))
            yaw_torque = float(np.clip(yaw_torque * (1.0 + 0.2 * approach_bias), -1.0, 1.0))

        # 7. Translational optic flow (T4/T5): flow_trans scheme only.
        # Cruise control holds ventral flow near target by trimming
        # thrust; lateral drift trims yaw toward the slip (small,
        # magnitude-only authority, never flips the sign); expansion on
        # descent flares (thrust cut). A pegged lateral reading is
        # declared untrustworthy and the drift trim disengages (a
        # saturated direction signal steered spins, not slips). Legacy
        # mode never takes this branch (pre-mapping brains never
        # drove T4/T5).
        if "flow_trans" in self.schemes and not self.legacy \
                and sensory_hint is not None:
            # Cruise + flare read the T4/T5 spike volleys (the encoder
            # drives them from these same flow magnitudes); silent pools
            # fall back to the hint magnitudes, as before. Drift keeps
            # the signed hint key: the T4b pools have no handedness, so
            # spikes alone cannot tell left slip from right slip.
            # flow_authority scales the whole trim block (legacy 1.0).
            auth = float(self._blends["flow_authority"])
            a_counts = sum(counts.get(s, 0) for s in self.t4a_ids)
            d_counts = sum(counts.get(s, 0) for s in self.t4d_ids)
            if a_counts > 0:
                ventral = min(a_counts / FLOW_FULL_SCALE, 1.0)
            else:
                ventral = float(np.clip(sensory_hint.get(
                    "visual_flow_ventral", 0.0), 0.0, 1.0))
            lateral = float(np.clip(sensory_hint.get(
                "visual_flow_lateral", 0.0), -1.0, 1.0))
            if d_counts > 0:
                expansion = min(d_counts / FLOW_FULL_SCALE, 1.0)
            else:
                expansion = float(np.clip(sensory_hint.get(
                    "visual_flow_expansion", 0.0), 0.0, 1.0))
            thrust = float(np.clip(
                thrust + np.clip((FLOW_CRUISE - ventral) * 0.5,
                                 -0.15, 0.15) * auth,
                0.0, 1.0))
            if abs(lateral) < 0.95:
                yaw_torque = float(np.clip(
                    yaw_torque + np.clip(lateral * 0.2, -0.15, 0.15) * auth,
                    -1.0, 1.0))
            thrust = float(np.clip(thrust * (1.0 - 0.4 * expansion),
                                   0.0, 1.0))

        return {
            "thrust": float(thrust),
            "yaw_torque": float(yaw_torque),
            "pitch_torque": self._pitch_torque(counts, sensory_hint) \
                if sensory_hint is not None else 0.0,
            "roll_torque": float(roll_torque),
            "approach_bias": float(approach_bias),
            "ram_burst": bool(ram_burst),
            "emergency_evade": bool(emergency_evade),
            "spear_thrust": float(spear_thrust)
        }

    def _search_dir(self, counts):
        """Neural lost-search vote: ORN L/R contrast while the antennae
        still whisper (faint traces below the lost threshold), else None
        (caller falls back to the arena cast sweep, as before)."""
        l = sum(counts.get(s, 0) for s in self.orn_left)
        r = sum(counts.get(s, 0) for s in self.orn_right)
        if l + r <= 0:
            return None
        return float(np.clip((r - l) / (r + l + 1e-6) * 1.5, -1.0, 1.0))

    def _lost_search_yaw(self, sensory_hint, yaw_torque, cast_dir=None):
        """Floor-relative lost-scent search: usable scent gone 3+ s with
        nothing visible -> blend toward the slow cast sweep instead of
        coasting straight. cast_dir carries the neural ORN vote when the
        antennae still whisper; None keeps the legacy arena sweep.
        search_blend is heritable (legacy 0.5/0.5). Keys default to
        found, so legacy/partial dicts behave exactly as before."""
        if sensory_hint is None:
            return yaw_torque
        if float(sensory_hint.get("scent_lost", 0.0)) <= 3.0:
            return yaw_torque
        if bool(sensory_hint.get("visual_target_visible", False)):
            return yaw_torque
        if cast_dir is None:
            cast_dir = float(np.clip(
                sensory_hint.get("scent_cast", 0.0), -1.0, 1.0))
        s = float(self._blends["search_blend"])
        return float(np.clip((1.0 - s) * yaw_torque + s * cast_dir * 0.8,
                             -1.0, 1.0))

    @staticmethod
    def reflex_yaw(sensory_dict):
        """Pure sensory tropotaxis prior: >0 right, <0 left. Lateral
        CONTRAST (R-L)/(R+L): bearing reads the same faint or strong,
        so far-faint traces steer decisively and glued-on saturation
        no longer flattens the turn. Sign and silence preserved: equal
        inputs (incl. double-zero floor) still read exactly 0."""
        c_l = float(np.clip(sensory_dict.get("pheromone_conc_left", 0.0), 0.0, 1.0))
        c_r = float(np.clip(sensory_dict.get("pheromone_conc_right", 0.0), 0.0, 1.0))
        az = float(sensory_dict.get("visual_target_azimuth", 0.0))
        contrast = (c_r - c_l) / (c_r + c_l + 1e-6)
        return float(np.clip(contrast * 1.5 + az / 90.0 * 0.8, -1.0, 1.0))

    @staticmethod
    def reflex_evade(sensory_dict):
        """FRONTAL RIVAL escape prior: target visible in front + expanding.
        Threshold sits at ~9m on the 14m approach: early enough to dodge at
        30m/s. Uses the split rival channel when present, else the legacy
        fused looming rate. Tree escape is handled separately (any-side)."""
        if not sensory_dict.get("visual_target_visible", False):
            return False
        az = abs(float(sensory_dict.get("visual_target_azimuth", 0.0)))
        loom = float(np.clip(sensory_dict.get(
            "visual_rival_looming", sensory_dict.get("visual_looming_rate", 0.0)), 0.0, 1.0))
        return bool(az < 50.0 and loom > 0.4)

    @staticmethod
    def reflex_evade_tree(sensory_dict):
        """BARK escape prior: looming trunk from ANY side (no target-visibility
        gate). In the old single merged channel a dead-ahead tree only escaped
        when the rival happened to be visible too - trees were covertly coupled
        to rival sight. The split fixes that: wood always gets a dodge."""
        loom = float(np.clip(sensory_dict.get(
            "visual_tree_looming", sensory_dict.get("visual_looming_rate", 0.0)), 0.0, 1.0))
        return bool(loom > 0.4)

    def _pitch_torque(self, counts, sensory_hint):
        """Nose control: T4c (climb) vs T4d (descent) spike vote blended
        with the reflex tracker. pitch_blend is the reflex share
        (legacy 1.0 = pure reflex, bit-identical); silent flow pools
        read 0, so unwired brains fly exactly as before. No new pools
        were needed: the annotation table carries no labeled pitch
        (dorsal/ventral) descending neurons, so climb/descent flow is
        the honest neural pitch signal available."""
        reflex = float(self.reflex_pitch(sensory_hint))
        c = sum(counts.get(s, 0) for s in self.t4c_ids)
        d = sum(counts.get(s, 0) for s in self.t4d_ids)
        neural = float(np.tanh((c - d) / 30.0))
        w = float(self._blends["pitch_blend"])
        return float(np.clip(w * reflex + (1.0 - w) * neural, -1.0, 1.0))

    @staticmethod
    def reflex_pitch(sensory_dict):
        """Nose-relative elevation tracking + altitude hold. >0 climbs, <0 dives.
        Pitch is reflex-driven: the mapped DN pools carry no labeled pitch
        (dorsal/ventral) readout, so the brain votes thrust/yaw while this
        channel keeps the nose on the target and recovers level flight."""
        elev = float(sensory_dict.get("visual_target_elevation", 0.0))
        alt = float(sensory_dict.get("altitude", 7.0))
        track = elev / 45.0 * 0.8
        if alt < 4.0:
            hold = 0.7
        elif alt > 24.0:
            hold = -0.7
        else:
            hold = 0.0
        return float(np.clip(track + hold, -1.0, 1.0))
