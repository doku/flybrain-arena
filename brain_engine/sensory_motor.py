import numpy as np


KNOWN_MAPPINGS = ("base", "muscles_up", "gyro_flow", "mbon")

# Schemes that add encoder/decoder behavior. "base" is the absence of all
# schemes. Mappings stack: a brain may declare any combination, e.g.
# ["muscles_up", "gyro_flow"], and every matching section applies.


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
        # Reference pool sizes: stimulus spike counts scale to the LARGER
        # sibling pool (sampling with replacement past pool size). MaleCNS
        # leaves some pools asymmetric (e.g. ORN_DA1 51L/105R with the rest
        # side-unknown); without this, one antenna would drive half as hard.
        self.da1_ref = max(len(self.da1_left), len(self.da1_right), 1)
        self.va1v_ref = max(len(self.va1v_left), len(self.va1v_right), 1)
        self.lplc2_ref = max(len(self.lplc2_left), len(self.lplc2_right), 1)
        # Antennal gyroscope (JO), gyro_flow scheme only. Stale caches
        # predate these pools: .get keeps old vault tooling importable.
        jo = populations.get("gyro_jo", {})
        self.jo_left = np.array(jo.get("left", []), dtype=np.int32)
        self.jo_right = np.array(jo.get("right", []), dtype=np.int32)
        self.jo_ref = max(len(self.jo_left), len(self.jo_right), 1)

    @staticmethod
    def _sample(pool, k):
        if k <= 0 or len(pool) == 0:
            return []
        return np.random.choice(pool, size=k, replace=k > len(pool))

    def encode(self, sensory_dict, dt=0.5, duration_ms=50.0):
        """
        sensory_dict contains:
          - pheromone_conc_left: float [0.0 .. 1.0] (Rival fly scent on left antenna)
          - pheromone_conc_right: float [0.0 .. 1.0] (Rival fly scent on right antenna)
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

        # Left antenna ORNs
        if c_left > 0.01 and len(self.da1_left) > 0:
            spikes.extend(self._sample(self.da1_left, int(c_left * self.da1_ref)))
            spikes.extend(self._sample(self.va1v_left, int(c_left * self.va1v_ref)))

        # Right antenna ORNs
        if c_right > 0.01 and len(self.da1_right) > 0:
            spikes.extend(self._sample(self.da1_right, int(c_right * self.da1_ref)))
            spikes.extend(self._sample(self.va1v_right, int(c_right * self.va1v_ref)))

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
        if self.legacy:
            tree_l = tree_r = tree_a = 0.0
        if tree_l + tree_r + tree_a > 0.1:
            k_l = int((tree_l + 0.5 * tree_a) * 0.4 * self.lplc2_ref)
            k_r = int((tree_r + 0.5 * tree_a) * 0.4 * self.lplc2_ref)
            if k_l > 0 and len(self.lplc2_left) > 0:
                spikes.extend(np.random.choice(
                    self.lplc2_left, size=min(k_l, len(self.lplc2_left)), replace=False))
            if k_r > 0 and len(self.lplc2_right) > 0:
                spikes.extend(np.random.choice(
                    self.lplc2_right, size=min(k_r, len(self.lplc2_right)), replace=False))

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
    the mushroom-body value readout. Base output is bit-identical to the
    pre-mapping decoder.
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
    def __init__(self, populations, mapping=None, legacy=False):
        self.schemes = normalize_mapping(mapping)
        self.legacy = bool(legacy)
        self._dn_gain = 0.008 if self.legacy else 0.0005
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
        mn_steer = populations.get("motor_steer", {})
        self.mn_steer_left = set(mn_steer.get("left", []))
        self.mn_steer_right = set(mn_steer.get("right", []))
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

    def decode(self, fired_spikes, sensory_hint=None):
        spike_set = list(fired_spikes)
        if len(spike_set) == 0:
            base = {
                "thrust": 0.2,          # Baseline cruise thrust
                "yaw_torque": 0.0,
                "pitch_torque": 0.0,
                "roll_torque": 0.0,     # Wings-level hold (no flow signal)
                "approach_bias": 0.0,   # No learned value without spikes
                "ram_burst": False,
                "emergency_evade": False
            }
            if sensory_hint is None:
                return base
            # No brain spikes: fall back to pure reflex so the fly still homess.
            return {
                "thrust": 0.2,
                "yaw_torque": float(self.reflex_yaw(sensory_hint)),
                "pitch_torque": float(self.reflex_pitch(sensory_hint)),
                "roll_torque": 0.0,
                "approach_bias": 0.0,
                "ram_burst": False,
                "emergency_evade": bool(self.reflex_evade(sensory_hint)
                                        or self.reflex_evade_tree(sensory_hint))
            }

        counts = {}
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
        thrust = float(np.clip(thrust, 0.0, 1.0))

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
        DN_BIAS = 9.0
        yaw_pop = float(np.tanh((dn_right_spikes - dn_left_spikes - DN_BIAS) / 15.0) * 0.9)
        brain_yaw = float(np.clip(yaw_specific + yaw_pop, -1.0, 1.0))
        if "muscles_up" in self.schemes and not self.legacy:
            # Steering-muscle laterality: MNad-R minus MNad-L, normalized so
            # small MN diffs still steer without saturating on DN excitation.
            mn_r = sum(counts.get(s, 0) for s in self.mn_steer_right)
            mn_l = sum(counts.get(s, 0) for s in self.mn_steer_left)
            yaw_mn = float(np.tanh((mn_r - mn_l) / 8.0) * 0.5)
            brain_yaw = float(np.clip(brain_yaw + yaw_mn, -1.0, 1.0))
        if sensory_hint is not None:
            # Parallel olfactory/visual reflex (antenna tropotaxis + visual
            # fixation), blended 30/70 with brain readout. Reflex dominates
            # the TURN SIGN (brain alone has a rightward bias that training
            # only partly removes); brain sets thrust/bursts/variation.
            reflex = self.reflex_yaw(sensory_hint)
            yaw_torque = float(np.clip(0.3 * brain_yaw + 0.7 * reflex, -1.0, 1.0))
        else:
            yaw_torque = brain_yaw

        # 3. High-Speed Ramming Charge (DNpe017)
        ram_spikes = sum(counts.get(s, 0) for s in self.dnpe017_ids)
        ram_burst = ram_spikes >= 2

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
        if sensory_hint is not None:
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

        return {
            "thrust": float(thrust),
            "yaw_torque": float(yaw_torque),
            "pitch_torque": float(self.reflex_pitch(sensory_hint)) if sensory_hint is not None else 0.0,
            "roll_torque": float(roll_torque),
            "approach_bias": float(approach_bias),
            "ram_burst": bool(ram_burst),
            "emergency_evade": bool(emergency_evade)
        }

    @staticmethod
    def reflex_yaw(sensory_dict):
        """Pure sensory tropotaxis prior: >0 right, <0 left."""
        c_l = float(np.clip(sensory_dict.get("pheromone_conc_left", 0.0), 0.0, 1.0))
        c_r = float(np.clip(sensory_dict.get("pheromone_conc_right", 0.0), 0.0, 1.0))
        az = float(sensory_dict.get("visual_target_azimuth", 0.0))
        return float(np.clip((c_r - c_l) * 1.5 + az / 90.0 * 0.8, -1.0, 1.0))

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
