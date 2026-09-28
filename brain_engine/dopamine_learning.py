import numpy as np

# Ground-scrape aversive per step at full ground signal (moderate:
# clear discouragement, capped by the [-2, 2] DA window; kill pulses
# (+1.0 dominance) still dominate any scrape).
GROUND_DA = 0.5
from sensory_motor import FLOW_CRUISE


class DopamineReinforcement:
    """
    Bio-inspired Dopamine-Gated Three-Factor Plasticity Engine.
    Models PAM (appetitive/reward) and PPL1 (aversive/punishment) dopamine circuits
    innervating the sensorimotor and mushroom body pathways.
    """
    def __init__(self, populations, learning_rate=0.01, dist_gain=0.15, align_bonus=(0.5, 0.2, -0.3),
                 base=None):
        self.lr = learning_rate
        self.dist_gain = dist_gain
        self.align_bonus = align_bonus
        self.pam_ids = np.array(populations.get("dopamine_pam", {}).get("all", []), dtype=np.int32)
        self.ppl1_ids = np.array(populations.get("dopamine_ppl1", {}).get("all", []), dtype=np.int32)
        # Reference connectome for pool-aware gain pinning: base =
        # (indptr, indices, weights) of the native wiring. pin_gains()
        # rescales each plastic pool toward its base magnitude (one factor
        # per pool, so all learned ratios survive) to stop the localized
        # runaway that repeated potentiation causes in frequently-scaled
        # rows (measured: sensory efferents at 100x base). None disables
        # pinning (unit tests, diagnose scripts).
        self._base_means = None
        if base is not None:
            self._base_means = self._compute_base_means(populations, *base)

        # Sensory pools as lists for fast iteration (gain modulation acts on
        # ALL efferents from these pools, not just monosynaptic sensory->DN
        # edges, which are ~0 in the full connectome).
        self.da1_left = list(populations["pheromone_da1"]["left"])
        self.da1_right = list(populations["pheromone_da1"]["right"])
        # VA1v food-odor ORNs ride with DA1 (same lateralized odor logic).
        self.va1v_left = list(populations["pheromone_va1v"]["left"])
        self.va1v_right = list(populations["pheromone_va1v"]["right"])
        self.lc10_left = list(populations["visual_lc10"]["left"])
        self.lc10_right = list(populations["visual_lc10"]["right"])
        # LC4 rival-loom cells: pinned/guarded like the other sensory
        # pools (their efferents were falling into untracked bulk).
        self.lc4_left = list(populations["visual_lc4"]["left"])
        self.lc4_right = list(populations["visual_lc4"]["right"])
        # Retina feature pools (stale-cache safe): LC11 presence/size
        # learns pursuit; LC15/17/18 loom features are pinned/guarded
        # (their outcomes aren't scored, so no active branches for them).
        lc11 = populations.get("visual_lc11", {})
        self.lc11_left = list(lc11.get("left", []))
        self.lc11_right = list(lc11.get("right", []))
        self._retina_feat = []
        for _rk in ("visual_lc15", "visual_lc17", "visual_lc18"):
            _rp = populations.get(_rk, {})
            self._retina_feat += list(_rp.get("left", [])) + list(_rp.get("right", []))
        # Tree-looming pools (LPLC2, side-gated wood). With the experimental
        # contralateral wiring, a LEFT tree fires LPLC2-L which steers right
        # (yaw>0 = away); these branches train that mapping up/down.
        self.lplc2_left = list(populations["visual_lplc2"]["left"])
        self.lplc2_right = list(populations["visual_lplc2"]["right"])
        # Antennal-gyro pools (JO, gyro_flow scheme). Stale-cache safe.
        jo = populations.get("gyro_jo", {})
        self.jo_left = list(jo.get("left", []))
        # Haltere roll-motor pools (learned banks, muscles_up scheme).
        # Stale-cache safe: empty lists scale nothing.
        mnhl = populations.get("motor_roll_mnhl", {})
        self.mnhl_left = list(mnhl.get("left", []))
        self.mnhl_right = list(mnhl.get("right", []))
        self.jo_right = list(jo.get("right", []))
        # Translational-flow pools (T4/T5, flow_trans scheme). Direction
        # groups combine T4+T5 of one tuning (a progressive, b
        # regressive, c up, d down), both sides; stale-cache safe.
        self.t4 = {}
        for _dk, _tk in (("a", ("visual_t4a", "visual_t5a")),
                         ("b", ("visual_t4b", "visual_t5b")),
                         ("c", ("visual_t4c", "visual_t5c")),
                         ("d", ("visual_t4d", "visual_t5d"))):
            _cells = []
            for _pk in _tk:
                _pp = populations.get(_pk, {})
                _cells += list(_pp.get("left", [])) + list(_pp.get("right", []))
            self.t4[_dk] = _cells
        # Mushroom-body value pools (mbon scheme): Kenyon cells + NT-sign
        # valence MBONs (ACh approach / Glu+GABA avoid). Stale-cache safe.
        self.kc_ids = np.array(populations.get("mushroom_body_kc", []), dtype=np.int32)
        self.mbon_app_ids = np.array(
            populations.get("mbon_app", {}).get("all", []), dtype=np.int32)
        self.mbon_av_ids = np.array(
            populations.get("mbon_av", {}).get("all", []), dtype=np.int32)
        # Motor pools for direct steering-bias plasticity (corrects intrinsic
        # connectome lateralization bias that sensory gain alone can't flip).
        desc = populations.get("descending_all", {})
        self.dn_left_ids = np.array(desc.get("left", populations["motor_turn_dnp20"]["left"]), dtype=np.int32)
        self.dn_right_ids = np.array(desc.get("right", populations["motor_turn_dnp20"]["right"]), dtype=np.int32)
        self._mask_left = None
        self._mask_right = None
        # Per-call gain cap (see apply_plasticity): bounds single-call
        # factors to [1-cap, 1+cap]. Server battles keep 0.3 (proven
        # pace, one call per battle); the trainer passes 0.02 (6000
        # calls/session would otherwise compound thermonuclear gains at
        # high learning rates: Ram hit 224x on KC->MBON in 6 sessions).
        self._gain_cap = 0.3
        # Depression floor guard: multiplicative down-scaling compounds
        # toward numerical zero over thousands of calls (measured: whole
        # steering sides at exactly 0.0), killing the channel. Depression
        # refused once a pool sits at/below ~12% of its reference mean;
        # potentiation is always allowed, so suppressed pools can still
        # learn back up. Pool identity is inferred from the target cells
        # (all scaling targets are sens/jo subsets); DN and KC-MBON paths
        # pass their reference directly.
        self._sens_pref = frozenset(
            self.da1_left + self.da1_right + self.va1v_left
            + self.va1v_right + self.lc10_left + self.lc10_right
            + self.lc4_left + self.lc4_right + self.lplc2_left
            + self.lplc2_right + self.lc11_left + self.lc11_right
            + self._retina_feat + self.t4["a"] + self.t4["b"]
            + self.t4["c"] + self.t4["d"])
        self._jo_pref = frozenset(self.jo_left + self.jo_right)
        # Depression floor: refuse to scale a pool that is already at or
        # below this fraction of its reference mean. Potentiation (factor
        # > 1) is never blocked.
        self._floor_frac = 0.12
        # Per-episode depression budget: even above the floor, one bad
        # episode (120 micro-steps at 0.98x = 0.088x) or one big battle
        # pulse can strand a pool in the abandonment gap faster than any
        # guard reacts. Between begin_episode() calls a pool may lose at
        # most this fraction of its magnitude (uniform row scaling means
        # the cumulative product tracks the mean ratio exactly).
        # Potentiation never consumes budget. Trainer calls
        # begin_episode() per episode; server per battle.
        self._ep_budget = 0.5
        self._cum = {}
        # Canonical pool lists (object identity -> budget name). Combo
        # lists built per call (e.g. spear_feat) register themselves in
        # apply_plasticity before scaling.
        self._pool_of = {}
        for _name, _lst in (("da1", self.da1_left), ("da1", self.da1_right),
                            ("va1v", self.va1v_left), ("va1v", self.va1v_right),
                            ("lc10", self.lc10_left), ("lc10", self.lc10_right),
                            ("lplc2", self.lplc2_left), ("lplc2", self.lplc2_right),
                            ("lc11", self.lc11_left), ("lc11", self.lc11_right),
                            ("jo", self.jo_left), ("jo", self.jo_right),
                            ("mnhl", self.mnhl_left),
                            ("mnhl", self.mnhl_right),
                            ("t4a", self.t4["a"]), ("t4b", self.t4["b"]),
                            ("t4c", self.t4["c"]), ("t4d", self.t4["d"])):
            self._pool_of[id(_lst)] = _name

    def begin_episode(self, brain):
        """Resets per-pool depression budgets for one brain. Call at each
        episode (trainer) or battle (server) start."""
        bid = id(brain)
        for k in [k for k in self._cum if k[0] == bid]:
            del self._cum[k]

    def _within_budget(self, brain, pools, factor):
        """True if applying factor keeps every named pool within its
        per-episode depression budget (also records it). Potentiation
        and untracked pools always pass."""
        if factor >= 1.0:
            return True
        if isinstance(pools, str):
            pools = (pools,)
        if not pools:
            return True
        bid = id(brain)
        keys = [(bid, p) for p in pools]
        for key in keys:
            if self._cum.get(key, 1.0) * factor < 1.0 - self._ep_budget:
                return False
        for key in keys:
            self._cum[key] = self._cum.get(key, 1.0) * factor
        return True

    @staticmethod
    def _row_positions(indptr, pre_list):
        """Flat synapse positions for rows whose presynaptic cell is listed."""
        n = len(indptr) - 1
        ids = np.asarray(list(pre_list), dtype=np.int32)
        if len(ids) == 0:
            return np.empty(0, dtype=np.int32)
        lut = np.zeros(n, dtype=bool)
        lut[ids[ids < n]] = True
        rows = np.repeat(np.arange(n, dtype=np.int32),
                         np.diff(np.asarray(indptr)).astype(np.int64))
        pos = np.where(lut[rows])[0].astype(np.int32)
        del rows
        return pos

    def _compute_base_means(self, populations, bindptr, bindices, bweights):
        """Mean |w| per plastic pool on the reference connectome. One factor
        per pool (never per row/side) so every learned ratio survives."""
        bindptr = np.asarray(bindptr)
        bindices = np.asarray(bindices)
        bweights = np.asarray(bweights, dtype=np.float32)
        sens_ids = (list(populations["pheromone_da1"]["left"])
                    + list(populations["pheromone_da1"]["right"])
                    + list(populations["pheromone_va1v"]["left"])
                    + list(populations["pheromone_va1v"]["right"])
                    + list(populations["visual_lc10"]["left"])
                    + list(populations["visual_lc10"]["right"])
                    + list(populations["visual_lc4"]["left"])
                    + list(populations["visual_lc4"]["right"])
                    + list(populations["visual_lplc2"]["left"])
                    + list(populations["visual_lplc2"]["right"])
                    + list(populations.get("visual_lc11", {}).get("left", []))
                    + list(populations.get("visual_lc11", {}).get("right", []))
                    + list(populations.get("visual_lc15", {}).get("left", []))
                    + list(populations.get("visual_lc15", {}).get("right", []))
                    + list(populations.get("visual_lc17", {}).get("left", []))
                    + list(populations.get("visual_lc17", {}).get("right", []))
                    + list(populations.get("visual_lc18", {}).get("left", []))
                    + list(populations.get("visual_lc18", {}).get("right", []))
                    + list(populations.get("visual_t4a", {}).get("left", []))
                    + list(populations.get("visual_t4a", {}).get("right", []))
                    + list(populations.get("visual_t4b", {}).get("left", []))
                    + list(populations.get("visual_t4b", {}).get("right", []))
                    + list(populations.get("visual_t4c", {}).get("left", []))
                    + list(populations.get("visual_t4c", {}).get("right", []))
                    + list(populations.get("visual_t4d", {}).get("left", []))
                    + list(populations.get("visual_t4d", {}).get("right", []))
                    + list(populations.get("visual_t5a", {}).get("left", []))
                    + list(populations.get("visual_t5a", {}).get("right", []))
                    + list(populations.get("visual_t5b", {}).get("left", []))
                    + list(populations.get("visual_t5b", {}).get("right", []))
                    + list(populations.get("visual_t5c", {}).get("left", []))
                    + list(populations.get("visual_t5c", {}).get("right", []))
                    + list(populations.get("visual_t5d", {}).get("left", []))
                    + list(populations.get("visual_t5d", {}).get("right", [])))
        jo_ids = list(populations.get("gyro_jo", {}).get("left", [])) \
            + list(populations.get("gyro_jo", {}).get("right", []))
        n = len(bindptr) - 1
        dn_ids = np.concatenate([
            np.asarray(populations.get("descending_all", {}).get("left", []), dtype=np.int32),
            np.asarray(populations.get("descending_all", {}).get("right", []), dtype=np.int32)])
        kc_ids = np.asarray(populations.get("mushroom_body_kc", []), dtype=np.int32)
        mbon_ids = np.concatenate([
            np.asarray(populations.get("mbon_app", {}).get("all", []), dtype=np.int32),
            np.asarray(populations.get("mbon_av", {}).get("all", []), dtype=np.int32)])
        pos_sens = self._row_positions(bindptr, sens_ids)
        pos_jo = self._row_positions(bindptr, jo_ids)
        pos_dn = np.where(np.isin(bindices, dn_ids))[0].astype(np.int32) if len(dn_ids) else np.empty(0, dtype=np.int32)
        brows = np.repeat(np.arange(n, dtype=np.int32), np.diff(bindptr).astype(np.int64))
        is_kc = np.zeros(n, dtype=bool)
        if len(kc_ids):
            is_kc[kc_ids[kc_ids < n]] = True
        is_mbon = np.zeros(n, dtype=bool)
        if len(mbon_ids):
            is_mbon[mbon_ids[mbon_ids < n]] = True
        pos_kcm = np.where(is_kc[brows] & is_mbon[bindices])[0].astype(np.int32)
        del brows
        # Bulk = everything outside the pinned pools. Tracked separately
        # because the global mean masks composition: hot pools plus
        # crushed bulk cancel out (measured: 22x pools with 0.04x bulk
        # reads as a healthy global). Bulk collapse is always drift -
        # nothing in the engine learns by suppressing all non-pool
        # synapses - so bulk gets bands but no suppression floor.
        covered = np.zeros(len(bweights), dtype=bool)
        for pos in (pos_sens, pos_jo):
            if len(pos):
                covered[pos] = True
        dn_cov = np.isin(bindices, dn_ids) if len(dn_ids) else np.zeros(len(bweights), dtype=bool)
        covered |= dn_cov
        if len(pos_kcm):
            covered[pos_kcm] = True
        pos_bulk = np.where(~covered)[0].astype(np.int32)
        del covered
        means = {}
        for name, pos in (("sens", pos_sens), ("jo", pos_jo), ("dn_in", pos_dn),
                          ("kcmbon", pos_kcm), ("bulk", pos_bulk)):
            if len(pos) == 0:
                means[name] = 0.0
            else:
                means[name] = float(np.abs(bweights[pos]).mean())
        means["global"] = float(np.abs(bweights).mean())
        return means

    def _ensure_pin_positions(self, brain):
        """Flat positions for the pinned pools on this brain's wiring.
        Length-tagged cache on the brain (mixed-arity safe)."""
        cached = getattr(brain, "_pin_pos", None)
        if cached is None or cached[0] != len(brain.weights):
            indptr = np.asarray(brain.indptr)
            sens_ids = self.da1_left + self.da1_right + self.va1v_left \
                + self.va1v_right + self.lc10_left + self.lc10_right \
                + self.lc4_left + self.lc4_right + self.lplc2_left \
                + self.lplc2_right + self.lc11_left + self.lc11_right \
                + self._retina_feat + self.t4["a"] + self.t4["b"] \
                + self.t4["c"] + self.t4["d"]
            jo_ids = self.jo_left + self.jo_right
            cached = (len(brain.weights),
                      self._row_positions(indptr, sens_ids),
                      self._row_positions(indptr, jo_ids))
            try:
                brain._pin_pos = cached
            except AttributeError:
                pass
        return cached[1], cached[2]

    def pin_gains(self, brain, legacy=False):
        """Pool-aware gain pinning: rescale each plastic pool toward its
        reference magnitude with ONE factor per pool, so every learned
        ratio (left/right, app/avoid, pool-to-pool) survives while
        absolute drift cannot compound across battles/episodes. No-op
        without a reference connectome (base=None).
        Conservative by design: pools within 2x of reference are left
        alone, as are pools suppressed below a tenth of reference (mild
        down-regulation is legitimate learning; amplifying near-zero
        noise 1000x would be worse than leaving it, and dust in winners
        is usually learned irrelevance — re-animating it scrambles
        learned policies). Only clear pathology is corrected. Bulk
        (all non-pool synapses) runs first with bands but
        no suppression floor: the global mean masks composition (hot
        pools plus crushed bulk cancel out), while bulk collapse is
        always drift - nothing learns by suppressing every non-pool
        synapse at once.
        legacy=True pins RUNAWAY pools only (>2x reference): pre-mapping
        brains were trained in a regime without suppression-side
        re-normalization, so anything at/under reference is left exactly
        as learned, while genuine runaway (measured up to 260x) is still
        corrected. Numerical-dust pools are left for the repair tool
        (zero holds no ratios to preserve)."""
        if not self._base_means:
            return
        w = brain.weights

        def _pin(name, pos, base_mean):
            if base_mean <= 0.0 or len(pos) == 0:
                return
            cur = float(np.abs(w[pos]).mean())
            if cur <= 0.0:
                return
            ratio = cur / base_mean
            if legacy and ratio <= 2.0:
                return
            if ratio < 0.1:
                # Abandoned for both regimes. A prior build lifted
                # sub-floor pools back to the floor automatically, and
                # live battles showed why that is wrong: dust pools in
                # healthy winners are usually LEARNED IRRELEVANCE
                # (channels the brain learned to fly without), and
                # re-animating them mid-tournament scrambles learned
                # policies. Dead channels are a human decision now:
                # diagnose, then run the repair tool scoped to that
                # brain. A pool that collapses mid-training stays
                # collapsed (retraining cannot earn it back), which the
                # probe makes visible instead of hiding it.
                print(f"[Dopamine] pin_gains: pool {name} at {ratio:.3g}x "
                      f"reference; leaving suppressed pool alone.")
                return
            if 0.5 <= ratio <= 2.0:
                return
            factor = float(np.clip(base_mean / cur, 1e-3, 1e3))
            w[pos] = np.clip(w[pos] * factor, -3000.0, 3000.0)
            print(f"[Dopamine] pin_gains: pool {name} {ratio:.2f}x -> pinned.")

        pos_sens, pos_jo = self._ensure_pin_positions(brain)
        self._ensure_motor_masks(brain)
        dn_idx = np.array([], dtype=np.int32)
        if self._mask_left is not None:
            dn_mask = self._mask_left | self._mask_right
            if np.any(dn_mask):
                dn_idx = np.where(dn_mask)[0].astype(np.int32)
        pos_app, pos_av = self._ensure_kc_mbon(brain)
        kc_idx = np.array([], dtype=np.int32)
        if len(pos_app) + len(pos_av) > 0:
            kc_idx = np.concatenate([pos_app, pos_av]).astype(np.int32)
        # Bulk = everything outside the pinned pools. It replaces the old
        # global job: the global mean masks composition (hot pools plus
        # crushed bulk cancel out), while bulk collapse is always drift -
        # nothing learns by suppressing all non-pool synapses - so bulk
        # gets bands but no suppression floor.
        covered = np.zeros(len(w), dtype=bool)
        for pos in (pos_sens, pos_jo, dn_idx, kc_idx):
            if len(pos):
                covered[pos] = True
        del dn_idx, kc_idx
        pos_bulk = np.where(~covered)[0].astype(np.int32)
        del covered
        bbase = self._base_means.get("bulk", 0.0)
        if bbase > 0.0 and len(pos_bulk) > 0:
            cur = float(np.abs(w[pos_bulk]).mean())
            if cur > 0.0:
                ratio = cur / bbase
                if (ratio > 2.0) if legacy else (ratio < 0.5 or ratio > 2.0):
                    factor = float(np.clip(bbase / cur, 1e-3, 1e3))
                    w[pos_bulk] = np.clip(w[pos_bulk] * factor, -3000.0, 3000.0)
                    print(f"[Dopamine] pin_gains: bulk {ratio:.2f}x -> pinned.")
        _pin("sens", pos_sens, self._base_means.get("sens", 0.0))
        _pin("jo", pos_jo, self._base_means.get("jo", 0.0))
        if self._mask_left is not None:
            dn_mask = self._mask_left | self._mask_right
            if np.any(dn_mask):
                _pin("dn_in", np.where(dn_mask)[0].astype(np.int32),
                     self._base_means.get("dn_in", 0.0))
        pos_app, pos_av = self._ensure_kc_mbon(brain)
        if len(pos_app) + len(pos_av) > 0:
            _pin("kcmbon", np.concatenate(
                [pos_app, pos_av]).astype(np.int32),
                self._base_means.get("kcmbon", 0.0))

    def compute_reward(self, current_dist, prev_dist, azimuth_deg, dt=0.05, tail_chase=0.0,
                       ventral=0.0, schemes=(), scent_now=0.0, scent_prev=0.0,
                       ground=0.0):
        """
        Computes the net dopamine neuromodulatory signal:
          - Closing distance (prev_dist > current_dist) -> PAM reward (positive DA)
          - Drifting away (prev_dist < current_dist) -> PPL1 aversive (negative DA)
          - Target heading alignment -> gaze bonus
          - Tail chase (behind victim, facing its tail) -> small position bonus
          - Steady cruise (flow_trans brains only): ventral flow near the
            cruise target earns a small bonus, so speed regulation itself
            is worth something, not just closing.
          - Scent gradient ascent (optional scent_now/scent_prev totals):
            rising total concentration pays up to +0.5, falling costs the
            same - smelling the approach is worth something even when the
            eyes haven't found the rival yet. Defaults 0.0 keep legacy
            callers (and the server battle loop) exactly unchanged.
        The tail bonus is deliberately small (+0.4 max): positioning is shaping
        for the kill, never worth more than the kill itself.
        """
        delta_dist = prev_dist - current_dist
        closing_speed = delta_dist / dt

        # 1. Distance shaping reward: rewards positive closing velocity
        r_dist = np.clip(closing_speed * self.dist_gain, -2.0, 2.0)

        # 1b. Scent gradient ascent: rising total odor concentration.
        scent_rate = (float(scent_now) - float(scent_prev)) / max(dt, 1e-6)
        r_scent = 0.5 * float(np.clip(scent_rate * 2.0, -1.0, 1.0))

        # 2. Heading alignment reward: bonus if facing toward opponent
        abs_azimuth = abs(azimuth_deg)
        good, ok, bad = self.align_bonus
        if abs_azimuth < 35.0:
            r_align = good
        elif abs_azimuth < 75.0:
            r_align = ok
        else:
            r_align = bad

        # 3. Cruise steadiness (flow_trans only): ventral flow near target.
        r_flow = 0.0
        if "flow_trans" in (schemes or ()):
            v = float(np.clip(ventral, 0.0, 1.0))
            r_flow = 0.2 * (1.0 - min(abs(v - FLOW_CRUISE) / FLOW_CRUISE, 1.0))

        # Net dopamine concentration (PAM > 0 vs PPL1 < 0). ground is
        # the per-step ground-scrape signal in [0, 1] (train loop only;
        # default 0.0 keeps every legacy caller bit-identical): bumping
        # the floor or nose-diving into it pays aversive, so ground-
        # clipping behavior is discouraged where it learns.
        da_signal = np.clip(
            r_dist + r_align + 0.4 * float(np.clip(tail_chase, 0.0, 1.0))
            + r_flow + r_scent
            - GROUND_DA * float(np.clip(ground, 0.0, 1.0)),
            -2.0, 2.0)
        return float(da_signal)

    def apply_plasticity(self, brain, sensory_dict, motor_dict, da_signal, schemes=(),
                         gain_cap=0.3):
        """
        Sensory-gain dopamine-gated plasticity (works on polysynaptic paths).
        Direct ORN->DN edges are ~0, so instead of scaling only direct
        sensory->motor synapses (old no-op), scale ALL efferents from the
        active sensory pool. Laterality is preserved by the connectome's own
        wiring: boosting left-sensor efferents boosts left-driven downstream
        pathways more than right ones.
        Correct turns are reinforced with signed DA (approach potentiates,
        retreat depresses); wrong turns are mildly depressed.
        schemes is the fighter's normalized mapping tuple: the JO roll
        branch runs only for gyro_flow brains and the KC->MBON branch only
        for mbon brains, so brains from before mappings keep byte-identical
        weight updates to the base branches.
        gain_cap bounds every single-call factor (server battles: 0.3;
        trainer steps: 0.02). Episode/battle-level pin_gains bounds the
        rest; without the trainer cap, high learning rates compound
        per-step gains into runaway mid-episode.
        """
        self._gain_cap = gain_cap
        if abs(da_signal) < 0.05:
            return

        c_left = sensory_dict.get("pheromone_conc_left", 0.0)
        c_right = sensory_dict.get("pheromone_conc_right", 0.0)
        azimuth = sensory_dict.get("visual_target_azimuth", 0.0)

        yaw = motor_dict.get("yaw_torque", 0.0)
        roll = motor_dict.get("roll_torque", 0.0)

        left_active = (c_left > c_right + 0.03) or (azimuth < -15.0)
        right_active = (c_right > c_left + 0.03) or (azimuth > 15.0)

        # Motor-side steering correction (directly fixes direction bias).
        # Potentiate incoming to the CORRECT DN pool, depress the wrong one.
        if left_active and not right_active:
            if yaw < -0.05 and da_signal > 0:
                self._scale_incoming(brain, "left", 1.0 + self.lr * da_signal * 0.5)
                self._scale_incoming(brain, "right", 1.0 - self.lr * da_signal * 0.25)
            elif yaw > 0.05:
                # Wrong-way right turn on left stimulus: suppress right DN
                # drive, boost left DN drive regardless of DA sign.
                mag = self.lr * max(abs(da_signal), 0.3)
                self._scale_incoming(brain, "right", 1.0 - mag * 0.5)
                self._scale_incoming(brain, "left", 1.0 + mag * 0.5)
        elif right_active and not left_active:
            if yaw > 0.05 and da_signal > 0:
                self._scale_incoming(brain, "right", 1.0 + self.lr * da_signal * 0.5)
                self._scale_incoming(brain, "left", 1.0 - self.lr * da_signal * 0.25)
            elif yaw < -0.05:
                mag = self.lr * max(abs(da_signal), 0.3)
                self._scale_incoming(brain, "left", 1.0 - mag * 0.5)
                self._scale_incoming(brain, "right", 1.0 + mag * 0.5)

        # Haltere roll-motor credit (learned banks): coordinated turns
        # bank into the yaw. Correct-side roll with a correct turn
        # potentiates that side's MNhl drive; fighting roll depresses
        # it. Empty pools (unwired/stale-cache brains) scale nothing.
        if left_active and not right_active:
            if yaw < -0.05 and roll < -0.05:
                self._scale_outgoing(brain, self.mnhl_left,
                                     1.0 + self.lr * da_signal)
            elif yaw < -0.05 and roll > 0.05:
                dep = 1.0 - self.lr * abs(da_signal) * 0.5
                self._scale_outgoing(brain, self.mnhl_left, dep)
        elif right_active and not left_active:
            if yaw > 0.05 and roll > 0.05:
                self._scale_outgoing(brain, self.mnhl_right,
                                     1.0 + self.lr * da_signal)
            elif yaw > 0.05 and roll < -0.05:
                dep = 1.0 - self.lr * abs(da_signal) * 0.5
                self._scale_outgoing(brain, self.mnhl_right, dep)

        # Lateralized case: stimulus clearly on one side
        if left_active and not right_active:
            if yaw < -0.05:
                # Correct left turn: signed DA update
                self._scale_outgoing(brain, self.da1_left, 1.0 + self.lr * da_signal)
                self._scale_outgoing(brain, self.va1v_left, 1.0 + self.lr * da_signal)
                self._scale_outgoing(brain, self.lc10_left, 1.0 + self.lr * da_signal)
            elif yaw > 0.05:
                # Wrong-way turn: depress the misleading mapping
                dep = 1.0 - self.lr * abs(da_signal) * 0.5
                self._scale_outgoing(brain, self.da1_left, dep)
                self._scale_outgoing(brain, self.va1v_left, dep)
                self._scale_outgoing(brain, self.lc10_left, dep)
            elif da_signal > 0:
                # No turn but closing: gently boost salience
                self._scale_outgoing(brain, self.da1_left, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.va1v_left, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.lc10_left, 1.0 + self.lr * da_signal * 0.5)
        elif right_active and not left_active:
            if yaw > 0.05:
                self._scale_outgoing(brain, self.da1_right, 1.0 + self.lr * da_signal)
                self._scale_outgoing(brain, self.va1v_right, 1.0 + self.lr * da_signal)
                self._scale_outgoing(brain, self.lc10_right, 1.0 + self.lr * da_signal)
            elif yaw < -0.05:
                dep = 1.0 - self.lr * abs(da_signal) * 0.5
                self._scale_outgoing(brain, self.da1_right, dep)
                self._scale_outgoing(brain, self.va1v_right, dep)
                self._scale_outgoing(brain, self.lc10_right, dep)
            elif da_signal > 0:
                self._scale_outgoing(brain, self.da1_right, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.va1v_right, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.lc10_right, 1.0 + self.lr * da_signal * 0.5)
        else:
            # Bilateral/ahead or weak stimulus: general pursuit gain
            if abs(azimuth) < 30.0 and da_signal > 0:
                self._scale_outgoing(brain, self.da1_left, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.da1_right, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.va1v_left, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.va1v_right, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.lc10_left, 1.0 + self.lr * da_signal * 0.5)
                self._scale_outgoing(brain, self.lc10_right, 1.0 + self.lr * da_signal * 0.5)
            elif da_signal < -0.2:
                # Retreating: mild global depression of active pools
                dep = 1.0 + self.lr * da_signal * 0.5  # da<0 -> factor<1
                if left_active:
                    self._scale_outgoing(brain, self.da1_left, dep)
                    self._scale_outgoing(brain, self.va1v_left, dep)
                if right_active:
                    self._scale_outgoing(brain, self.da1_right, dep)
                    self._scale_outgoing(brain, self.va1v_right, dep)

        # Retina channel (LC11 small-object pursuit, retina scheme only):
        # mirrors the LC10 lateralized structure - correct turns toward
        # the seen side potentiate under signed DA, wrong-way turns are
        # depressed. LC15/17/18 loom features have no scored outcome, so
        # they are pinned/guarded but never actively scaled here.
        if "retina" in schemes:
            if left_active and not right_active:
                if yaw < -0.05:
                    self._scale_outgoing(brain, self.lc11_left,
                                         1.0 + self.lr * da_signal)
                elif yaw > 0.05:
                    dep = 1.0 - self.lr * abs(da_signal) * 0.5
                    self._scale_outgoing(brain, self.lc11_left, dep)
            elif right_active and not left_active:
                if yaw > 0.05:
                    self._scale_outgoing(brain, self.lc11_right,
                                         1.0 + self.lr * da_signal)
                elif yaw < -0.05:
                    dep = 1.0 - self.lr * abs(da_signal) * 0.5
                    self._scale_outgoing(brain, self.lc11_right, dep)

        # Spear-strike channel: an aimed lunge that pays off potentiates
        # the lobula-feature efferents driving the mouth motor neurons
        # (spear_lunge wiring: LC11/15/17/18 -> MNxm); a punished lunge
        # depresses them. Gated on the same visible+frontal aim as the
        # decoder, and silent by construction when the pool never fires.
        spear = float(motor_dict.get("spear_thrust", 0.0) or 0.0)
        if spear > 0.4:
            spear_vis = bool(sensory_dict.get("visual_target_visible", False))
            spear_az = abs(float(sensory_dict.get("visual_target_azimuth", 0.0) or 0.0))
            if spear_vis and spear_az < 50.0:
                spear_feat = self.lc11_left + self.lc11_right + self._retina_feat
                # Register the combo list so the depression budget sees
                # both member pools (these rows also feed pursuit thrust
                # on retina_wide brains — halve magnitudes so strikes
                # can't tax pursuit into the ground).
                self._pool_of[id(spear_feat)] = ("lc11", "lcfeat")
                try:
                    if da_signal > 0:
                        self._scale_outgoing(brain, spear_feat,
                                             1.0 + self.lr * da_signal * 0.25)
                    elif da_signal < -0.2:
                        dep = 1.0 + self.lr * da_signal * 0.25  # da<0 -> factor<1
                        self._scale_outgoing(brain, spear_feat, dep)
                finally:
                    del self._pool_of[id(spear_feat)]

        # Tree channel (LPLC2): side-gated avoidance. With the contra wiring a
        # lever, steering AWAY from the looming side is the correct answer -
        # potentiate it under positive dopamine; turning INTO the bark is
        # depressed regardless of DA sign (a crash / near-miss is our proof).
        tree_l = sensory_dict.get("visual_tree_left_looming", 0.0)
        tree_r = sensory_dict.get("visual_tree_right_looming", 0.0)
        if tree_l > 0.2 and tree_r <= 0.2:
            if yaw > 0.05:
                self._scale_outgoing(brain, self.lplc2_left,
                                     1.0 + self.lr * max(da_signal, 0.0) * 0.5)
            elif yaw < -0.05:
                dep = 1.0 - self.lr * max(abs(da_signal), 0.3) * 0.5
                self._scale_outgoing(brain, self.lplc2_left, dep)
        elif tree_r > 0.2 and tree_l <= 0.2:
            if yaw < -0.05:
                self._scale_outgoing(brain, self.lplc2_right,
                                     1.0 + self.lr * max(da_signal, 0.0) * 0.5)
            elif yaw > 0.05:
                dep = 1.0 - self.lr * max(abs(da_signal), 0.3) * 0.5
                self._scale_outgoing(brain, self.lplc2_right, dep)

        # Roll channel (JO, gyro_flow brains only): banked rotation with
        # matching roll torque is the correct answer - potentiate it under
        # positive dopamine; torque that fights the measured spin is
        # depressed regardless of DA sign. Mirrors the yaw/LPLC2 structure.
        # Both arms require torque authority (|roll|): with no roll output
        # (VS silent) there is no information, and the depress arm would
        # otherwise erode JO efferents toward zero on every spin.
        roll_rate = float(sensory_dict.get("angular_roll_rate", 0.0))
        roll = float(motor_dict.get("roll_torque", 0.0))
        if "gyro_flow" in schemes and abs(roll_rate) > 0.1 and abs(roll) > 0.05:
            pool = self.jo_right if roll_rate > 0.0 else self.jo_left
            if roll * roll_rate > 0.02:
                self._scale_outgoing(brain, pool,
                                     1.0 + self.lr * max(da_signal, 0.0) * 0.5)
            elif roll * roll_rate < -0.02:
                dep = 1.0 - self.lr * max(abs(da_signal), 0.3) * 0.5
                self._scale_outgoing(brain, pool, dep)

        # Translational-flow channel (flow_trans brains only): the
        # direction pools actually driven this tick learn under signed
        # DA — potentiation when paying off, depression when punished.
        # Threshold-gated on stimulus presence (no drive = no scaling),
        # mirroring the JO torque-authority guard.
        if "flow_trans" in schemes:
            _flow_drives = []
            if float(sensory_dict.get("visual_flow_ventral", 0.0)) > 0.2:
                _flow_drives.append("a")
            if abs(float(sensory_dict.get("visual_flow_lateral", 0.0))) > 0.2:
                _flow_drives.append("b")
            if float(sensory_dict.get("visual_flow_expansion", 0.0)) > 0.2:
                _flow_drives.append("d")
            if float(sensory_dict.get("visual_flow_climb", 0.0)) > 0.2:
                _flow_drives.append("c")
            for _dk in _flow_drives:
                if da_signal > 0:
                    self._scale_outgoing(brain, self.t4[_dk],
                                         1.0 + self.lr * da_signal * 0.5)
                elif da_signal < -0.2:
                    dep = 1.0 + self.lr * da_signal * 0.5  # da<0 -> factor<1
                    self._scale_outgoing(brain, self.t4[_dk], dep)

        # Mushroom-body value pathway (mbon brains only): reward writes
        # approach, punishment writes avoidance. Potentiate KC->MBON_app
        # under DA>0 (and KC->MBON_av under DA<0), depress the opposite
        # arm mildly. Without this the learned will could never learn:
        # the sensory/DN branches above never touch KC->MBON edges.
        if "mbon" in schemes and abs(da_signal) >= 0.05 and len(self.mbon_app_ids) > 0:
            if da_signal > 0:
                self._scale_kc_mbon(brain,
                                    1.0 + self.lr * da_signal * 0.5,
                                    1.0 - self.lr * da_signal * 0.25)
            else:
                self._scale_kc_mbon(brain,
                                    1.0 + self.lr * da_signal * 0.25,
                                    1.0 - self.lr * da_signal * 0.5)

    def _outgoing_ref(self, pre_list):
        """Reference mean for the pool being scaled, or 0.0 (guard off)
        when the target isn't a known sensory/gyro pool."""
        if not self._base_means:
            return 0.0
        try:
            ids = set(int(p) for p in pre_list)
        except (TypeError, ValueError):
            return 0.0
        if ids and ids <= self._sens_pref:
            return self._base_means.get("sens", 0.0)
        if ids and ids <= self._jo_pref:
            return self._base_means.get("jo", 0.0)
        return 0.0

    def _scale_outgoing(self, brain, pre_list, factor, cap=None):
        """Scale ALL outgoing weights from each pre neuron (vectorized)."""
        cap = self._gain_cap if cap is None else cap
        factor = float(np.clip(factor, 1.0 - cap, 1.0 + cap))
        if factor == 1.0 or not pre_list:
            return
        if not self._within_budget(
                brain, self._pool_of.get(id(pre_list)), factor):
            return
        if factor < 1.0:
            ref = self._outgoing_ref(pre_list)
            if ref > 0.0 and self._pool_cur(brain, pre_list) < self._floor_frac * ref:
                return
        for pre in pre_list:
            start = int(brain.indptr[pre])
            end = int(brain.indptr[pre + 1])
            if end > start:
                brain.weights[start:end] = np.clip(
                    brain.weights[start:end] * factor, -3000.0, 3000.0)

    def scent_acuity(self, brain):
        """Olfactory acuity lineage metric: mean |w| over DA1+VA1v
        outgoing synapses (both sides). Rises when pursuit training
        potentiates the nose, falls when wrong-way turns depress it.
        Read-only measurement for breeding records and selection design;
        fitness integration needs arena->server stats plumbing (follow-up).
        Returns 0.0 when the brain has no ORN efferents yet."""
        return float(np.mean([
            self._pool_cur(brain, self.da1_left + self.da1_right),
            self._pool_cur(brain, self.va1v_left + self.va1v_right),
        ]))

    @staticmethod
    def _pool_cur(brain, pre_list):
        """Mean |w| over outgoing synapses of the listed presynaptic cells."""
        tot_n, tot_s = 0, 0.0
        for pre in pre_list:
            start = int(brain.indptr[pre])
            end = int(brain.indptr[pre + 1])
            if end > start:
                tot_s += float(np.abs(brain.weights[start:end]).sum())
                tot_n += (end - start)
        return tot_s / max(tot_n, 1)

    def _ensure_motor_masks(self, brain):
        """Lazily build boolean masks over synapses incoming to DN pools.
        Cached ON THE BRAIN (not self): mixed-arity bouts alternate between
        different wiring lengths, and a single shared slot would rebuild on
        every call. Length-tagged so a stale cache can never apply."""
        cached = getattr(brain, "_dn_masks", None)
        if cached is None or cached[0] != len(brain.weights):
            idx = np.asarray(brain.indices)
            cached = (len(brain.weights),
                      np.isin(idx, self.dn_left_ids),
                      np.isin(idx, self.dn_right_ids))
            try:
                brain._dn_masks = cached
            except AttributeError:
                pass
        self._mask_left, self._mask_right = cached[1], cached[2]

    def _ensure_kc_mbon(self, brain):
        """Lazily build flat synapse positions for KC->MBON_app/_av edges.

        Same length-tagged on-brain cache pattern as _ensure_motor_masks
        (mixed-arity bouts alternate wiring lengths). Lookup tables keep
        the build O(nnz); positions are int32 flat indices into
        brain.weights, so each scaling call is two vector multiplies.
        """
        cached = getattr(brain, "_kc_mbon", None)
        if cached is None or cached[0] != len(brain.weights):
            n = len(brain.indptr) - 1
            rows = np.repeat(np.arange(n, dtype=np.int32),
                             np.diff(brain.indptr).astype(np.int64))
            is_kc = np.zeros(n, dtype=bool)
            if len(self.kc_ids) > 0:
                is_kc[self.kc_ids] = True
            is_app = np.zeros(n, dtype=bool)
            if len(self.mbon_app_ids) > 0:
                is_app[self.mbon_app_ids] = True
            is_av = np.zeros(n, dtype=bool)
            if len(self.mbon_av_ids) > 0:
                is_av[self.mbon_av_ids] = True
            post = np.asarray(brain.indices)
            pre_kc = is_kc[rows]
            del rows
            pos_app = np.where(pre_kc & is_app[post])[0].astype(np.int32)
            pos_av = np.where(pre_kc & is_av[post])[0].astype(np.int32)
            del pre_kc
            cached = (len(brain.weights), pos_app, pos_av)
            try:
                brain._kc_mbon = cached
            except AttributeError:
                pass
        return cached[1], cached[2]

    def _scale_kc_mbon(self, brain, factor_app, factor_av, cap=None):
        """Scale KC->MBON_app/_av synapses (vectorized, cached positions)."""
        cap = self._gain_cap if cap is None else cap
        factor_app = float(np.clip(factor_app, 1.0 - cap, 1.0 + cap))
        factor_av = float(np.clip(factor_av, 1.0 - cap, 1.0 + cap))
        if factor_app == 1.0 and factor_av == 1.0:
            return
        if not self._within_budget(brain, "kc_app", factor_app):
            factor_app = 1.0
        if not self._within_budget(brain, "kc_av", factor_av):
            factor_av = 1.0
        if factor_app == 1.0 and factor_av == 1.0:
            return
        pos_app, pos_av = self._ensure_kc_mbon(brain)
        ref = (self._base_means or {}).get("kcmbon", 0.0)
        if len(pos_app) > 0 and factor_app != 1.0:
            if not (factor_app < 1.0 and ref > 0.0 and self._pos_cur(
                    brain, pos_app) < self._floor_frac * ref):
                brain.weights[pos_app] = np.clip(
                    brain.weights[pos_app] * factor_app, -3000.0, 3000.0)
        if len(pos_av) > 0 and factor_av != 1.0:
            if not (factor_av < 1.0 and ref > 0.0 and self._pos_cur(
                    brain, pos_av) < self._floor_frac * ref):
                brain.weights[pos_av] = np.clip(
                    brain.weights[pos_av] * factor_av, -3000.0, 3000.0)

    @staticmethod
    def _pos_cur(brain, pos):
        """Mean |w| over flat synapse positions (empty -> 0.0)."""
        if len(pos) == 0:
            return 0.0
        return float(np.abs(brain.weights[pos]).mean())

    def _scale_incoming(self, brain, side, factor, cap=None):
        """Scale ALL synapses incoming to left/right DN pool (numpy-fast)."""
        cap = self._gain_cap if cap is None else cap
        factor = float(np.clip(factor, 1.0 - cap, 1.0 + cap))
        if factor == 1.0:
            return
        if not self._within_budget(brain, "dn_" + side, factor):
            return
        self._ensure_motor_masks(brain)
        mask = self._mask_left if side == "left" else self._mask_right
        if mask is None or not np.any(mask):
            return
        if factor < 1.0:
            ref = (self._base_means or {}).get("dn_in", 0.0)
            if ref > 0.0 and self._pos_cur(brain, mask) < self._floor_frac * ref:
                return
        brain.weights[mask] = np.clip(brain.weights[mask] * factor, -3000.0, 3000.0)

    def _modulate_pathway(self, brain, pre_set, post_set, factor):
        """Legacy direct-edge API kept for compat; now scales outgoing."""
        self._scale_outgoing(brain, list(pre_set), factor)
