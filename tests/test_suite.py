import os
import sys
import json
import time
import socket
import unittest
import subprocess
import numpy as np

# Add project root and brain_engine to Python path
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAIN_ENGINE_DIR = os.path.join(PROJECT_ROOT, "brain_engine")
sys.path.insert(0, BRAIN_ENGINE_DIR)

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from sensory_motor import SensoryEncoder, MotorDecoder, normalize_mapping
from dopamine_learning import DopamineReinforcement
from evolution_engine import EvolutionManager
from experimental_wiring import EXPERIMENTS, apply_overlay, experiment_arrays
import brain_package as vault_pkg


class TestConnectomeData(unittest.TestCase):
    """Verifies that connectome files and mapped populations are intact and valid."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_csr_properties(self):
        self.assertEqual(self.csr.shape, (166700, 166700))
        self.assertGreater(self.csr.nnz, 25_000_000, "Synapse count should be >25M")
        self.assertEqual(len(self.csr.indptr), 166701)
        self.assertEqual(len(self.csr.indices), self.csr.nnz)
        self.assertEqual(len(self.csr.data), self.csr.nnz)

    def test_populations_validity(self):
        required_pops = [
            "pheromone_da1", "pheromone_va1v",
            "visual_lc4", "visual_lc10", "visual_lplc2",
            "motor_thrust_dnp09", "motor_turn_dnp20", "motor_giant_fiber"
        ]
        for pop_name in required_pops:
            self.assertIn(pop_name, self.pops, f"Missing population: {pop_name}")
            pop_data = self.pops[pop_name]
            self.assertIn("all", pop_data)
            self.assertGreater(len(pop_data["all"]), 0, f"Empty population: {pop_name}")
            for idx in pop_data["all"]:
                self.assertTrue(0 <= idx < 166700, f"Invalid neuron index: {idx} in {pop_name}")


class TestFlyBrainLIF(unittest.TestCase):
    """Verifies dual independent brains, resting stability, and sparse LIF dynamics."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def setUp(self):
        self.brain_a = FlyBrain(self.csr.indptr, self.csr.indices, self.csr.data.copy())
        self.brain_b = FlyBrain(self.csr.indptr, self.csr.indices, self.csr.data.copy())

    def test_dual_independence(self):
        self.assertIsNot(self.brain_a.weights, self.brain_b.weights)
        self.assertIsNot(self.brain_a.V, self.brain_b.V)
        self.assertIsNot(self.brain_a.Isyn, self.brain_b.Isyn)

    def test_resting_state_stability(self):
        empty_stim = np.empty(0, dtype=np.int32)
        spikes = self.brain_a.integrate_50ms(empty_stim)
        self.assertEqual(len(spikes), 0, "Silent brain must not produce spontaneous spikes")
        np.testing.assert_allclose(self.brain_a.V, -52.0, atol=1e-3)
        np.testing.assert_allclose(self.brain_a.Isyn, 0.0, atol=1e-4)

    def test_sensory_activation_and_reset(self):
        da1_stim = np.array(self.pops["pheromone_da1"]["left"][:10], dtype=np.int32)
        spikes = self.brain_a.integrate_50ms(da1_stim)
        self.assertGreater(len(spikes), 0, "Brain must produce spikes upon sensory stimulation")

        self.brain_a.reset_state()
        np.testing.assert_allclose(self.brain_a.V, -52.0, atol=1e-3)
        np.testing.assert_allclose(self.brain_a.Isyn, 0.0, atol=1e-4)
        self.assertFalse(np.any(self.brain_a.is_active))

    def test_mutation_operator(self):
        target_pathway = self.pops["pheromone_da1"]["left"]
        initial_weights_a = self.brain_a.weights.copy()
        initial_weights_b = self.brain_b.weights.copy()

        self.brain_b.mutate_weights(target_pathway, mutation_rate=1.0, sigma=0.2)

        np.testing.assert_array_equal(self.brain_a.weights, initial_weights_a)

        changed_count = 0
        for pre in target_pathway:
            start = self.brain_b.indptr[pre]
            end = self.brain_b.indptr[pre + 1]
            if start < end:
                if not np.array_equal(self.brain_b.weights[start:end], initial_weights_b[start:end]):
                    changed_count += 1
        self.assertGreater(changed_count, 0, "Targeted pathway weights must be mutated")


class TestSensoryMotor(unittest.TestCase):
    """Verifies sensory encoding and motor decoding mappings."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()
        cls.encoder = SensoryEncoder(cls.pops)
        cls.decoder = MotorDecoder(cls.pops)

    def test_sensory_encoder_zero_input(self):
        spikes = self.encoder.encode({})
        self.assertEqual(len(spikes), 0)

    def test_sensory_encoder_bilateral_pheromone(self):
        spikes_left = self.encoder.encode({"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.0})
        self.assertGreater(len(spikes_left), 0)
        da1_left_set = set(self.pops["pheromone_da1"]["left"] + self.pops["pheromone_va1v"]["left"])
        for s in spikes_left:
            self.assertIn(s, da1_left_set)

        spikes_right = self.encoder.encode({"pheromone_conc_left": 0.0, "pheromone_conc_right": 0.9})
        self.assertGreater(len(spikes_right), 0)
        da1_right_set = set(self.pops["pheromone_da1"]["right"] + self.pops["pheromone_va1v"]["right"])
        for s in spikes_right:
            self.assertIn(s, da1_right_set)

    def test_reflex_yaw_contrast(self):
        # Lateral contrast (R-L)/(R+L): bearing reads the same faint or
        # strong; equal inputs (incl. double-zero) stay exactly silent.
        ry = MotorDecoder.reflex_yaw
        self.assertEqual(ry({"pheromone_conc_left": 0.5, "pheromone_conc_right": 0.5}), 0.0)
        self.assertEqual(ry({"pheromone_conc_left": 0.0, "pheromone_conc_right": 0.0}), 0.0)
        faint = ry({"pheromone_conc_left": 0.2, "pheromone_conc_right": 0.05})
        glued = ry({"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.85})
        self.assertLess(faint, 0.0)
        self.assertLess(glued, 0.0)
        # Faint-but-lateral steers harder than strong-but-balanced.
        self.assertLess(faint, glued)
        self.assertGreater(
            ry({"pheromone_conc_left": 0.05, "pheromone_conc_right": 0.2}), 0.0)

    def test_lost_search_and_surge(self):
        # Lost 3+ s with nothing visible: yaw blends toward the cast
        # sweep instead of coasting; eyes or fresh scent disables it.
        dec = MotorDecoder(self.pops)
        lost = {"pheromone_conc_left": 0.05, "pheromone_conc_right": 0.05,
                "visual_target_visible": False, "scent_lost": 10.0,
                "scent_cast": 1.0, "scent_surge": 0.0}
        self.assertGreater(dec.decode([], sensory_hint=lost)["yaw_torque"], 0.0)
        lost["scent_cast"] = -1.0
        self.assertLess(dec.decode([], sensory_hint=lost)["yaw_torque"], 0.0)
        found = dict(lost, scent_lost=0.0, scent_cast=1.0)
        self.assertAlmostEqual(
            dec.decode([], sensory_hint=found)["yaw_torque"],
            dec.reflex_yaw(found), places=6)
        seen = dict(lost, visual_target_visible=True)
        self.assertAlmostEqual(
            dec.decode([], sensory_hint=seen)["yaw_torque"],
            dec.reflex_yaw(seen), places=6)
        # Surge: rising scent spends extra thrust (capped at 1.0).
        calm = {"pheromone_conc_left": 0.5, "pheromone_conc_right": 0.5,
                "visual_target_visible": True, "scent_surge": 0.0}
        rising = dict(calm, scent_surge=1.0)
        t0 = dec.decode([], sensory_hint=calm)["thrust"]
        t1 = dec.decode([], sensory_hint=rising)["thrust"]
        self.assertGreater(t1, t0)
        self.assertLessEqual(t1, 1.0)

    def test_scent_reward_and_acuity(self):
        # Rising total conc pays, falling costs; acuity reads ORN
        # efferent strength and rises with correct-turn potentiation.
        rl = DopamineReinforcement(self.pops)
        up = rl.compute_reward(20.0, 20.0, 0.0, scent_now=0.6, scent_prev=0.4)
        flat = rl.compute_reward(20.0, 20.0, 0.0, scent_now=0.4, scent_prev=0.4)
        down = rl.compute_reward(20.0, 20.0, 0.0, scent_now=0.4, scent_prev=0.6)
        self.assertGreater(up, flat)
        self.assertLess(down, flat)
        # Legacy callers (no scent kwargs) unchanged.
        self.assertEqual(
            rl.compute_reward(20.0, 20.0, 0.0),
            rl.compute_reward(20.0, 20.0, 0.0, scent_now=0.0, scent_prev=0.0))
        # Minimal fake brain: 3 outgoing 0.5-weight edges per ORN.
        # Targets sit past every pool id so motor/KC masks (matched on
        # postsynaptic targets) stay empty and only ORN efferents move.
        import types
        orn = set(self.pops["pheromone_da1"]["left"]
                  + self.pops["pheromone_da1"]["right"]
                  + self.pops["pheromone_va1v"]["left"]
                  + self.pops["pheromone_va1v"]["right"])
        top = max(orn) + 2
        indptr = np.zeros(top + 1, dtype=np.int64)
        tot = 0
        for i in range(top):
            indptr[i] = tot
            if i in orn:
                tot += 3
        indptr[top] = tot
        brain = types.SimpleNamespace(
            indptr=indptr,
            indices=(900000 + np.arange(tot)).astype(np.int32),
            weights=np.full(tot, 0.5, dtype=np.float32))
        a0 = rl.scent_acuity(brain)
        self.assertAlmostEqual(a0, 0.5, places=5)
        sens = {"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.1,
                "visual_target_azimuth": -40.0}
        motor = {"yaw_torque": -0.5, "thrust": 0.3, "pitch_torque": 0.0}
        rl.apply_plasticity(brain, sens, motor, 1.0)
        self.assertGreater(rl.scent_acuity(brain), a0)

    def test_flow_saccade_gate(self):
        # Spin quiets T4 drive (saccade suppression); still air reads full.
        from sensory_motor import SensoryEncoder
        still = SensoryEncoder(self.pops, mapping="flow_trans")
        n_still = len(still.encode({"visual_flow_ventral": 1.0}))
        spin = SensoryEncoder(self.pops, mapping="flow_trans")
        n_spin = len(spin.encode({"visual_flow_ventral": 1.0,
                                  "angular_yaw_rate": 1.0,
                                  "angular_roll_rate": 0.0}))
        self.assertGreater(n_still, 0)
        self.assertLess(n_spin, n_still * 0.5)
        # Absent angular keys behave exactly as before (gain 1.0).
        plain = SensoryEncoder(self.pops, mapping="flow_trans")
        n_plain = len(plain.encode({"visual_flow_ventral": 1.0}))
        self.assertEqual(n_plain, n_still)

    def test_flow_habituation(self):
        # Sustained saturating flow adapts that group down (floor 0.3);
        # clean air recovers; reset restores.
        from sensory_motor import SensoryEncoder
        enc = SensoryEncoder(self.pops, mapping="flow_trans")
        sat = {"visual_flow_ventral": 1.0}
        enc.encode(sat)
        for _ in range(200):
            enc.encode(sat)
        self.assertLess(enc.flow_hab["a"], 1.0)
        self.assertGreaterEqual(enc.flow_hab["a"], 0.3)
        # Untouched groups stay fresh.
        self.assertEqual(enc.flow_hab["b"], 1.0)
        g_low = enc.flow_hab["a"]
        for _ in range(400):
            enc.encode({})
        self.assertGreater(enc.flow_hab["a"], g_low)
        enc.reset_odor()
        self.assertEqual(enc.flow_hab,
                         {"a": 1.0, "b": 1.0, "c": 1.0, "d": 1.0})

    def test_drift_trim_disengages_saturated(self):
        # Pegged lateral (|l|=1) skips the drift trim; mid lateral applies.
        from sensory_motor import MotorDecoder
        dec = MotorDecoder(self.pops, mapping="flow_trans")
        spikes = [1, 2, 3]
        y_sat = dec.decode(spikes, sensory_hint={
            "visual_flow_ventral": 0.35, "visual_flow_lateral": 1.0})["yaw_torque"]
        y_mid = dec.decode(spikes, sensory_hint={
            "visual_flow_ventral": 0.35, "visual_flow_lateral": 0.5})["yaw_torque"]
        self.assertLess(y_sat, y_mid)

    def test_t4_pinned(self):
        # T4/T5 efferent rows belong to the pinned sens pool.
        import types
        import numpy as np
        from dopamine_learning import DopamineReinforcement
        rl = DopamineReinforcement(self.pops)
        need = []
        for k in ("pheromone_da1", "visual_lc10", "visual_t4a",
                  "visual_t5d"):
            need += list(self.pops[k]["left"][:4])
        top = max(need) + 2
        indptr = np.arange(top + 1, dtype=np.int64)
        indptr = np.append(indptr, top + 1)
        fake = types.SimpleNamespace(
            indptr=indptr,
            indices=np.zeros(top + 1, dtype=np.int32),
            weights=np.ones(top + 1, dtype=np.float32))
        pos_sens, _jo = rl._ensure_pin_positions(fake)
        pos_set = set(int(x) for x in np.asarray(pos_sens).tolist())
        t4pre = int(self.pops["visual_t4a"]["left"][0])
        self.assertIn(t4pre, pos_set)

    def test_trainer_gusts(self):
        # Gust windows produce bounded nonzero lateral slip; mechanics
        # are deterministic when preset (no global draws involved).
        import numpy as np
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly()
        tgt = KinematicFly(x=10.0, z=2.0)
        fly.gust_steps = 100
        fly.gust_val = 0.5
        for _ in range(10):
            senses, _d = compute_agent_senses(fly, tgt, prev_dist=15.0)
            self.assertAlmostEqual(senses["visual_flow_lateral"], 0.5)
        self.assertEqual(fly.gust_steps, 90)
        # Fresh flies start calm; gusts appear over long runs, bounded.
        np.random.seed(7)
        peak = 0.0
        f2 = KinematicFly()
        for _ in range(3000):
            s, _d = compute_agent_senses(f2, tgt, prev_dist=15.0)
            peak = max(peak, abs(float(s["visual_flow_lateral"])))
        self.assertLessEqual(peak, 0.61)
        self.assertGreater(peak, 0.0)

    def test_school_score(self):
        # Scenario-weighted: takedown 10, camp 8, reach 6, crash 0,
        # partial = closed fraction * 4 (capped); overrides honored.
        from train_homing import _school_score
        base = {"initial_dist": 20.0}
        self.assertEqual(_school_score(dict(base, takedown=True), {}),
                         10.0)
        self.assertEqual(_school_score(dict(base, camp=True), {}), 8.0)
        self.assertEqual(_school_score(dict(base, success=True), {}), 6.0)
        self.assertEqual(_school_score(dict(base, crashed=True), {}), 0.0)
        # Takedown beats camp beats reach (priority order).
        self.assertEqual(
            _school_score(dict(base, takedown=True, success=True), {}), 10.0)
        # Partial: half-closed = 2.0, overshoot capped at 4.0.
        self.assertAlmostEqual(
            _school_score(dict(base, closed=10.0), {}), 2.0)
        self.assertAlmostEqual(
            _school_score(dict(base, closed=99.0), {}), 4.0)
        # Curriculum override.
        self.assertEqual(
            _school_score(dict(base, success=True),
                          {"score_weights": {"reach": 100.0}}), 100.0)

    def test_score_stamping(self):
        # Score banks on the record, accumulates across sessions, avg
        # spans cumulative episodes; new records default 0. Production
        # ordering: log_training_session (episodes) runs BEFORE the stamp.
        import train_job
        import brain_package as vault
        r = vault.new_record("ScoreTest")
        self.assertEqual(float(r["training"].get("score", 0.0)), 0.0)
        vault.log_training_session(r, 25, {}, "s1")
        train_job.stamp_train_score(r, {"score": 50.0, "episodes": 25})
        self.assertAlmostEqual(float(r["training"]["score"]), 50.0)
        self.assertAlmostEqual(float(r["training"]["avg_score"]), 2.0)
        # Second session accumulates; avg recomputed over cumulative.
        vault.log_training_session(r, 25, {}, "s2")
        train_job.stamp_train_score(r, {"score": 150.0, "episodes": 25})
        self.assertAlmostEqual(float(r["training"]["score"]), 200.0)
        self.assertAlmostEqual(float(r["training"]["avg_score"]),
                               200.0 / 50.0)
        # Missing/None summary tolerated.
        train_job.stamp_train_score(r, None)
        self.assertAlmostEqual(float(r["training"]["score"]), 200.0)
        # merge_summaries carries scores.
        merged = train_job.merge_summaries([
            {"episodes": 25, "successes": 10, "score": 50.0},
            {"episodes": 25, "successes": 8, "score": 150.0}])
        self.assertAlmostEqual(merged["score"], 200.0)
        self.assertAlmostEqual(merged["avg_score"], 4.0)

    def test_odor_habituation(self):
        # Sustained strong odor adapts the drive down (bounded by the
        # floor); clean air recovers slowly; the floor zone never adapts.
        enc = SensoryEncoder(self.pops)
        strong = {"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.9}
        np.random.seed(7)
        n1 = len(enc.encode(strong))
        self.assertGreater(n1, 0)
        for _ in range(200):
            enc.encode(strong)
        self.assertLess(enc.odor_gain, 1.0)
        self.assertGreaterEqual(enc.odor_gain, 0.3)
        np.random.seed(7)
        n2 = len(enc.encode(strong))
        self.assertLess(n2, n1 * 0.7)
        # Floor zone never habituates (re-acquisition trace survives).
        enc2 = SensoryEncoder(self.pops)
        for _ in range(50):
            enc2.encode({"pheromone_conc_left": 0.1, "pheromone_conc_right": 0.1})
        self.assertEqual(enc2.odor_gain, 1.0)
        # Slow recovery in clean air, then fresh-nose reset.
        g_low = enc.odor_gain
        for _ in range(400):
            enc.encode({})
        self.assertGreater(enc.odor_gain, g_low)
        enc.reset_odor()
        self.assertEqual(enc.odor_gain, 1.0)

    def test_sensory_encoder_visual_tracking(self):
        spikes_vis_left = self.encoder.encode({
            "visual_target_visible": True,
            "visual_target_azimuth": -30.0
        })
        self.assertGreater(len(spikes_vis_left), 0)
        lc10_left_set = set(self.pops["visual_lc10"]["left"])
        for s in spikes_vis_left:
            self.assertIn(s, lc10_left_set)

    def test_sensory_encoder_looming(self):
        spikes_loom = self.encoder.encode({"visual_looming_rate": 0.8})
        self.assertGreater(len(spikes_loom), 0)
        lc4_set = set(self.pops["visual_lc4"]["all"])
        for s in spikes_loom:
            self.assertIn(s, lc4_set)

    def test_sensory_encoder_rival_looming_split(self):
        # Split keys present: rival loom drives LC4 only, never LPLC2.
        spikes = self.encoder.encode({
            "visual_rival_looming": 0.8,
            "visual_tree_left_looming": 0.0,
            "visual_tree_right_looming": 0.0,
            "visual_tree_ahead_looming": 0.0,
        })
        lc4_set = set(self.pops["visual_lc4"]["all"])
        lplc2_set = set(self.pops["visual_lplc2"]["left"] + self.pops["visual_lplc2"]["right"])
        self.assertGreater(len(spikes), 0)
        for s in spikes:
            self.assertIn(s, lc4_set)
            self.assertNotIn(s, lplc2_set)

    def test_sensory_encoder_tree_looming_split(self):
        # Left tree loom fires LPLC2-L, not LPLC2-R and not LC4.
        spikes = self.encoder.encode({
            "visual_tree_left_looming": 0.8,
            "visual_tree_right_looming": 0.0,
            "visual_tree_ahead_looming": 0.0,
            "visual_rival_looming": 0.0,
        })
        left_set = set(self.pops["visual_lplc2"]["left"])
        right_set = set(self.pops["visual_lplc2"]["right"])
        lc4_set = set(self.pops["visual_lc4"]["all"])
        self.assertGreater(len(spikes), 0)
        for s in spikes:
            self.assertIn(s, left_set)
            self.assertNotIn(s, right_set)
            self.assertNotIn(s, lc4_set)

    def test_sensory_encoder_tree_ahead_splits_sides(self):
        # Dead-ahead tree drives both LPLC2 pools (steering away has no
        # preferred handedness head-on).
        spikes = self.encoder.encode({"visual_tree_ahead_looming": 0.9})
        sets = set(self.pops["visual_lplc2"]["left"] + self.pops["visual_lplc2"]["right"])
        self.assertGreater(len(spikes), 0)
        for s in spikes:
            self.assertIn(s, sets)

    def test_motor_decoder_baseline(self):
        ctrl = self.decoder.decode([])
        self.assertAlmostEqual(ctrl["thrust"], 0.2)
        self.assertEqual(ctrl["yaw_torque"], 0.0)
        self.assertFalse(ctrl["ram_burst"])
        self.assertFalse(ctrl["emergency_evade"])

    def test_motor_decoder_thrust(self):
        dnp09_neurons = self.pops["motor_thrust_dnp09"]["all"]
        ctrl = self.decoder.decode(dnp09_neurons * 3)
        self.assertGreater(ctrl["thrust"], 0.2)

    def test_motor_decoder_steering(self):
        turn_left_neurons = self.pops["motor_turn_dnp20"]["left"]
        turn_right_neurons = self.pops["motor_turn_dnp20"]["right"]

        ctrl_left = self.decoder.decode(turn_left_neurons * 4)
        self.assertLess(ctrl_left["yaw_torque"], 0.0)

        ctrl_right = self.decoder.decode(turn_right_neurons * 4)
        self.assertGreater(ctrl_right["yaw_torque"], 0.0)

    def test_motor_decoder_giant_fiber(self):
        gf_neurons = self.pops["motor_giant_fiber"]["all"]
        ctrl = self.decoder.decode(gf_neurons)
        self.assertTrue(ctrl["emergency_evade"])

    def test_gf_evade_gated_on_visible_frontal_rival(self):
        # Phantom case: GF spikes from an unseen (or side) rival must NOT
        # roll/dive the fly; the arena reports loom without a visibility
        # gate, and LC4 fires on it since the continuity fix.
        gf_neurons = self.pops["motor_giant_fiber"]["all"]
        phantom = self.decoder.decode(gf_neurons, {
            "visual_target_visible": False,
            "visual_target_azimuth": 180.0,
            "visual_rival_looming": 0.9,
            "visual_tree_looming": 0.0,
        })
        self.assertFalse(phantom["emergency_evade"])
        side = self.decoder.decode(gf_neurons, {
            "visual_target_visible": True,
            "visual_target_azimuth": 90.0,
            "visual_rival_looming": 0.9,
            "visual_tree_looming": 0.0,
        })
        self.assertFalse(side["emergency_evade"])
        # Frontal visible rival: GF evade fires.
        frontal = self.decoder.decode(gf_neurons, {
            "visual_target_visible": True,
            "visual_target_azimuth": 10.0,
            "visual_rival_looming": 0.9,
            "visual_tree_looming": 0.0,
        })
        self.assertTrue(frontal["emergency_evade"])

    def test_motor_decoder_tree_reflex_any_side(self):
        # Tree loom escapes even with NO rival in view (fixes the old covert
        # coupling where a dead-ahead tree only evaded when a rival was seen).
        ctrl = self.decoder.decode([], {
            "visual_tree_looming": 0.7,
            "visual_tree_left_looming": 0.7,
            "visual_target_visible": False,
            "visual_rival_looming": 0.0,
        })
        self.assertTrue(ctrl["emergency_evade"])

    def test_motor_decoder_rival_reflex_needs_sight(self):
        # Rival escape keeps its gaze gate: unseen rival looming is ignored.
        ctrl = self.decoder.decode([], {
            "visual_rival_looming": 0.9,
            "visual_tree_looming": 0.0,
            "visual_target_visible": False,
        })
        self.assertFalse(ctrl["emergency_evade"])

    def test_yaw_bias_override(self):
        # Per-brain DN lateralization correction: default 9.0 pushes a
        # symmetric volley left; bias 0.0 centers it; measured brains
        # take their own value (Eye2 ~3, full-mix Eye3 ~15+).
        from sensory_motor import (MotorDecoder, normalize_yaw_bias,
                                   draw_yaw_bias, YAW_BIAS_DEFAULT,
                                   YAW_BIAS_LO, YAW_BIAS_HI)
        self.assertEqual(normalize_yaw_bias(None), YAW_BIAS_DEFAULT)
        self.assertEqual(normalize_yaw_bias(3.0), 3.0)
        for bad in ("left", [1], -1.0, 25.5):
            with self.assertRaises(ValueError):
                normalize_yaw_bias(bad)
        dn = (list(self.pops["descending_all"]["left"][:20])
              + list(self.pops["descending_all"]["right"][:20]))
        base = MotorDecoder(self.pops).decode(dn)
        self.assertEqual(self.decoder._dn_bias, YAW_BIAS_DEFAULT)
        self.assertLess(base["yaw_torque"], 0.0)
        centered = MotorDecoder(self.pops, yaw_bias=0.0).decode(dn)
        self.assertAlmostEqual(centered["yaw_torque"], 0.0, places=5)
        low = MotorDecoder(self.pops, yaw_bias=3.0).decode(dn)
        self.assertGreater(low["yaw_torque"], base["yaw_torque"])
        for _ in range(50):
            v = draw_yaw_bias()
            self.assertGreaterEqual(v, YAW_BIAS_LO)
            self.assertLessEqual(v, YAW_BIAS_HI)

    def test_bind_codecs_yaw_bias(self):
        import brain_server as bs
        rec = {"name": "Y", "generator_params": {"yaw_bias": 5.0}}
        _enc, dec = bs._bind_codecs(rec, self.pops, {})
        self.assertEqual(dec._dn_bias, 5.0)
        rec2 = {"name": "Y", "generator_params": {}}
        _enc2, dec2 = bs._bind_codecs(rec2, self.pops, {})
        self.assertEqual(dec2._dn_bias, 9.0)
        rec3 = {"name": "Y", "generator_params": {"yaw_bias": "port"}}
        with self.assertRaises(ValueError):
            bs._bind_codecs(rec3, self.pops, {})

    def test_brainview_stream_keys_and_detail(self):
        # Brain-view stream: legacy HUD keys intact, per-pool dict
        # present, spike ids gated on detail with truncation guard.
        import brain_server as bs
        idx = bs._pool_index(self.pops)
        da1 = list(self.pops["pheromone_da1"]["left"][:5])
        dn = list(self.pops["descending_all"]["left"][:4])
        st = bs._spike_stats(np.array(da1 + dn, dtype=np.int32),
                             self.pops, idx, 0)
        for k in ("spikes", "dn_left", "dn_right", "lplc2",
                  "mn_thrust", "vs_flow", "pools"):
            self.assertIn(k, st)
        self.assertNotIn("spike_ids", st)
        self.assertEqual(st["pools"]["pheromone_da1"], 5)
        self.assertEqual(st["dn_left"], 4)
        # dn splits ride top-level (legacy HUD keys), not in pools.
        self.assertNotIn("dn_left", st["pools"])
        self.assertNotIn("dn_right", st["pools"])
        st2 = bs._spike_stats(np.array(da1 + dn, dtype=np.int32),
                              self.pops, idx, 2)
        self.assertIn("spike_ids", st2)
        self.assertFalse(st2["spike_ids_truncated"])
        self.assertEqual(len(st2["spike_ids"]), 9)
        big = bs._spike_stats(np.arange(3100, dtype=np.int32),
                              self.pops, idx, 2)
        self.assertEqual(len(big["spike_ids"]), 3000)
        self.assertTrue(big["spike_ids_truncated"])
        empty = bs._spike_stats(np.empty(0, dtype=np.int32),
                                self.pops, idx, 2)
        self.assertEqual(empty["spikes"], 0)
        self.assertEqual(empty["spike_ids"], [])

    def test_brain_cloud_asset_schema(self):
        # 3D soma-cloud asset: unit-box cells with pool keys, centroids,
        # bbox; regenerate with brain_engine/export_brain_cloud.py.
        path = os.path.join(PROJECT_ROOT, "arena", "models",
                            "brain_cloud.json")
        self.assertTrue(os.path.isfile(path), "missing brain_cloud.json")
        with open(path) as f:
            asset = json.load(f)
        self.assertIn("cells", asset)
        self.assertIn("pools", asset)
        self.assertIn("centroids", asset)
        self.assertGreater(len(asset["cells"]), 1000)
        seen = set()
        for c in asset["cells"][:500]:
            self.assertEqual(len(c), 5)
            for x in c[1:4]:
                self.assertGreaterEqual(x, -0.51)
                self.assertLessEqual(x, 0.51)
            self.assertIn(c[4], asset["pools"])
            seen.add(c[4])
        self.assertGreater(len(seen), 10)

    def test_raster_ids_deterministic_capped(self):
        # Raster drill-down: sorted ids, capped rows, unknown pools empty.
        import brain_server as bs
        idx = bs._pool_index(self.pops)
        ids, total = bs._raster_ids(idx, "pheromone_da1")
        self.assertEqual(total, len(self.pops["pheromone_da1"]["all"]))
        self.assertEqual(ids, sorted(ids))
        self.assertLessEqual(len(ids), bs.RASTER_CAP)
        dn_ids, dn_total = bs._raster_ids(idx, "descending_all")
        self.assertEqual(dn_ids, [])
        self.assertEqual(dn_total, 0)
        big_ids, big_total = bs._raster_ids(idx, "dn_left")
        self.assertEqual(big_total, len(self.pops["descending_all"]["left"]))
        self.assertLessEqual(len(big_ids), bs.RASTER_CAP)
        self.assertEqual(big_ids, sorted(
            self.pops["descending_all"]["left"])[:bs.RASTER_CAP])


class TestNeuroMapping(unittest.TestCase):
    """Verifies the Stage 1 neuro-mapping schemes (muscles_up + gyro_flow):
    new populations, JO gyro encoding, MN thrust/yaw votes, VS/HS roll
    output, per-record codec binding, and trainer angular-rate synth."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def test_mapping_populations_present(self):
        expected = {
            "motor_flight_thrust": 24, "motor_steer": 214,
            "gyro_jo": 672, "flow_vs": 34, "flow_hs": 8,
        }
        for name, count in expected.items():
            self.assertIn(name, self.pops, f"Missing pool: {name}")
            pop = self.pops[name]
            self.assertEqual(len(pop["all"]), count, f"Wrong size: {name}")
            for idx in pop["all"]:
                self.assertTrue(0 <= idx < 166700, f"Bad index in {name}")
        # Anchored families only: every steer cell is an MNad* type.
        self.assertEqual(len(self.pops["motor_steer"]["left"]), 107)
        self.assertEqual(len(self.pops["motor_steer"]["right"]), 107)

    def test_normalize_mapping(self):
        self.assertEqual(normalize_mapping(None), ())
        self.assertEqual(normalize_mapping(""), ())
        self.assertEqual(normalize_mapping("base"), ())
        self.assertEqual(normalize_mapping("muscles_up"), ("muscles_up",))
        self.assertEqual(normalize_mapping(["gyro_flow", "muscles_up"]),
                         ("gyro_flow", "muscles_up"))
        self.assertEqual(normalize_mapping(["base", "mbon"]), ("mbon",))
        with self.assertRaises(ValueError):
            normalize_mapping("nope")
        with self.assertRaises(ValueError):
            normalize_mapping(["muscles_up", "nope"])

    def test_jo_gyro_encoding(self):
        np.random.seed(0)
        spin = {"angular_yaw_rate": 0.8, "angular_pitch_rate": 0.0,
                "angular_roll_rate": 0.0}
        gyro = SensoryEncoder(self.pops, mapping="gyro_flow")
        spikes = gyro.encode(spin)
        jo_all = set(self.pops["gyro_jo"]["all"])
        self.assertGreater(len(spikes), 0, "yaw spin must drive JO")
        for s in spikes:
            self.assertIn(int(s), jo_all)
        jo_r = set(self.pops["gyro_jo"]["right"])
        frac_r = sum(1 for s in spikes if int(s) in jo_r) / max(len(spikes), 1)
        self.assertGreater(frac_r, 0.5, "rightward spin must favor JO-R")
        # Base scheme ignores angular rates entirely.
        base = SensoryEncoder(self.pops, mapping="base")
        self.assertEqual(len(base.encode(spin)), 0)

    def test_muscle_thrust_and_steer_votes(self):
        thrust_pool = self.pops["motor_flight_thrust"]["all"]
        steer_r = self.pops["motor_steer"]["right"]
        stim = thrust_pool * 2 + steer_r * 2
        base = MotorDecoder(self.pops, mapping="base").decode(stim)
        musc = MotorDecoder(self.pops, mapping="muscles_up").decode(stim)
        self.assertGreater(musc["thrust"], base["thrust"],
                           "MN wing-power spikes must add thrust")
        self.assertGreater(musc["yaw_torque"], base["yaw_torque"],
                           "MNad-R spikes must steer right of base")

    def test_vs_roll_output(self):
        vs_r = self.pops["flow_vs"]["right"]
        gyro = MotorDecoder(self.pops, mapping="gyro_flow")
        ctrl = gyro.decode(list(vs_r) * 2)
        self.assertGreater(ctrl["roll_torque"], 0.0,
                           "VS-R spikes must bank right")
        base = MotorDecoder(self.pops, mapping="base")
        self.assertEqual(base.decode(list(vs_r) * 2)["roll_torque"], 0.0)
        self.assertEqual(gyro.decode([])["roll_torque"], 0.0)

    def test_roll_key_always_present(self):
        for m in ("base", "muscles_up", "gyro_flow"):
            dec = MotorDecoder(self.pops, mapping=m)
            self.assertIn("roll_torque", dec.decode([]))
            self.assertIn("roll_torque", dec.decode([1, 2, 3]))

    def test_codec_binding(self):
        import brain_server as bs
        cache = {}
        enc, dec = bs._bind_codecs({"name": "A", "generator_params": {}}, self.pops, cache)
        self.assertEqual((enc.schemes, dec.schemes), ((), ()))
        enc2, dec2 = bs._bind_codecs(
            {"name": "B", "generator_params": {"mapping": "gyro_flow"}}, self.pops, cache)
        self.assertEqual((enc2.schemes, dec2.schemes),
                         (("gyro_flow",), ("gyro_flow",)))
        enc3, dec3 = bs._bind_codecs(
            {"name": "C", "generator_params": {"mapping": ["muscles_up", "mbon"]}},
            self.pops, cache)
        self.assertEqual(enc3.schemes, ("mbon", "muscles_up"))
        with self.assertRaises(ValueError):
            bs._bind_codecs(
                {"name": "D", "generator_params": {"mapping": "nope"}}, self.pops, cache)

    def test_stacked_schemes_compose(self):
        # muscles_up + gyro_flow + mbon together: JO input, MN votes,
        # roll output, and approach bias all live at once.
        enc = SensoryEncoder(self.pops, mapping=["muscles_up", "gyro_flow", "mbon"])
        dec = MotorDecoder(self.pops, mapping=["muscles_up", "gyro_flow", "mbon"])
        spin = {"angular_yaw_rate": 0.8, "angular_pitch_rate": 0.0,
                "angular_roll_rate": 0.0}
        spikes = enc.encode(spin)
        jo_all = set(self.pops["gyro_jo"]["all"])
        self.assertGreater(len(spikes), 0)
        for s in spikes:
            self.assertIn(int(s), jo_all)
        app = self.pops["mbon_app"]["all"]
        vs_r = self.pops["flow_vs"]["right"]
        steer_r = self.pops["motor_steer"]["right"]
        ctrl = dec.decode(list(app) * 3 + list(vs_r) * 2 + steer_r * 2)
        self.assertGreater(ctrl["approach_bias"], 0.0)
        self.assertGreater(ctrl["roll_torque"], 0.0)
        base = MotorDecoder(self.pops).decode(
            list(app) * 3 + list(vs_r) * 2 + steer_r * 2)
        self.assertGreater(ctrl["yaw_torque"], base["yaw_torque"])

    def test_trainer_angular_rates(self):
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly(heading_rad=0.0)
        tgt = KinematicFly(x=10.0, z=0.0)
        fly.step(thrust=0.5, yaw_torque=0.25, pitch_cmd=0.0, dt=0.05)
        self.assertAlmostEqual(fly.yaw_rate, -0.25 * 8.0, places=5)
        senses, _ = compute_agent_senses(fly, tgt)
        # Right turn (yaw_torque>0) must read as a RIGHTWARD spin (+),
        # matching the arena/JO convention (trainer heading decreases on
        # right turns, so the raw dh/dt sign is negated at the synth).
        self.assertAlmostEqual(senses["angular_yaw_rate"], 0.25, places=5)
        self.assertIn("angular_pitch_rate", senses)
        self.assertEqual(senses["angular_roll_rate"], 0.0)

    def test_trainer_rival_looming(self):
        # Closing distance must loom like the arena's formula; without a
        # previous distance (first step, diagnostics) it reports 0.
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly(x=0.0, z=0.0)
        tgt = KinematicFly(x=10.0, z=0.0)
        senses, dist = compute_agent_senses(fly, tgt)
        self.assertEqual(senses["visual_rival_looming"], 0.0)
        closing, dist2 = compute_agent_senses(fly, tgt, prev_dist=dist + 2.0)
        self.assertGreater(closing["visual_rival_looming"], 0.0)
        self.assertLessEqual(closing["visual_rival_looming"], 1.0)
        opening, _ = compute_agent_senses(fly, tgt, prev_dist=dist - 5.0)
        self.assertEqual(opening["visual_rival_looming"], 0.0)

    def test_dopamine_roll_branch(self):
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl = DopamineReinforcement(self.pops)
        w0 = brain.weights.copy()
        rl.apply_plasticity(brain, {"angular_roll_rate": -0.6},
                            {"yaw_torque": 0.0, "roll_torque": -0.5}, 1.0,
                            schemes=("gyro_flow",))
        self.assertTrue(bool((brain.weights != w0).any()),
                        "matching roll torque must potentiate JO efferents")


class TestMbonMapping(unittest.TestCase):
    """Verifies the Stage 2 mushroom-body learned-will scheme (mbon):
    NT-sign valence pools, sustained KC ignition (LIF continuity),
    approach-bias readout, and KC->MBON dopamine plasticity."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def test_mbon_valence_pools(self):
        app = self.pops["mbon_app"]
        avv = self.pops["mbon_av"]
        self.assertEqual(len(app["all"]), 50, "ACh approach MBONs")
        self.assertEqual(len(avv["all"]), 47, "Glu+GABA avoid MBONs")
        self.assertEqual(set(app["all"]) & set(avv["all"]), set())
        self.assertEqual(set(app["all"]) | set(avv["all"]),
                         set(self.pops["mbon"]["all"]))

    def test_kernel_continuity_and_kc_ignition(self):
        # Regression: the LIF kernel once rebuilt its working set from
        # stim-only each call, freezing the network after one cascade
        # (tick0 ~5k spikes, tick1+ ~1). KC must fire on later ticks.
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        orn = np.array(self.pops["pheromone_da1"]["all"]
                       + self.pops["pheromone_va1v"]["all"], dtype=np.int32)
        kc = set(self.pops["mushroom_body_kc"])
        mbon = set(self.pops["mbon"]["all"])
        kc_seen, mbon_seen = 0, 0
        for t in range(4):
            spikes = brain.integrate_50ms(orn)
            s = set(int(x) for x in spikes)
            if t >= 1:
                self.assertGreater(len(spikes), 5,
                                   f"tick {t} must sustain activity (no freeze)")
                kc_seen += len(s & kc)
                mbon_seen += len(s & mbon)
        self.assertGreater(kc_seen, 0, "KC must ignite past tick 0")
        self.assertGreater(mbon_seen, 0, "MBON must fire past tick 0")

    def test_approach_bias_sign_and_blend(self):
        app = self.pops["mbon_app"]["all"]
        avv = self.pops["mbon_av"]["all"]
        mbon_dec = MotorDecoder(self.pops, mapping="mbon")
        base_dec = MotorDecoder(self.pops, mapping="base")
        stim = list(app) * 3
        c_mbon = mbon_dec.decode(stim)
        c_base = base_dec.decode(stim)
        self.assertGreater(c_mbon["approach_bias"], 0.0)
        self.assertGreaterEqual(c_mbon["thrust"], c_base["thrust"])
        stim_av = list(avv) * 3
        c_av = mbon_dec.decode(stim_av)
        self.assertLess(c_av["approach_bias"], 0.0)
        self.assertEqual(base_dec.decode(stim)["approach_bias"], 0.0)

    def test_approach_bias_key_always_present(self):
        for m in ("base", "muscles_up", "gyro_flow", "mbon"):
            dec = MotorDecoder(self.pops, mapping=m)
            self.assertIn("approach_bias", dec.decode([]))
            self.assertIn("approach_bias", dec.decode([1, 2, 3]))

    def test_dopamine_mbon_branch(self):
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl = DopamineReinforcement(self.pops)
        w0 = brain.weights.copy()
        rl.apply_plasticity(brain, {"pheromone_conc_left": 0.8},
                            {"yaw_torque": 0.1, "thrust": 0.4}, 1.0,
                            schemes=("mbon",))
        self.assertTrue(bool((brain.weights != w0).any()),
                        "DA+ must scale KC->MBON synapses")
        pos_app, pos_av = rl._ensure_kc_mbon(brain)
        self.assertGreater(len(pos_app), 1000, "KC->MBON_app edge set")
        self.assertGreater(len(pos_av), 1000, "KC->MBON_av edge set")
        w1 = brain.weights.copy()
        rl.apply_plasticity(brain, {"pheromone_conc_left": 0.8},
                            {"yaw_torque": 0.1, "thrust": 0.4}, -1.0,
                            schemes=("mbon",))
        self.assertTrue(bool((brain.weights != w1).any()),
                        "DA- must scale the opposite arm")

    def test_gain_pinning_repairs_runaway_preserves_ratios(self):
        # Localized runaway (the Flanker pathology: sensory efferents at
        # 100x base) must pin back to reference magnitudes while every
        # learned ratio survives.
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl = DopamineReinforcement(
            self.pops, base=(csr.indptr, csr.indices, csr.data.copy()))
        # Artificially inflate left-sensory rows 40x with a lateral bias.
        # Covers the full sens pool definition (DA1+VA1v+LC10+LC4+LPLC2+
        # LC11/15/17/18+T4a-d/T5a-d left) so the inflated mean still
        # reads runaway.
        left_ids = (self.pops["pheromone_da1"]["left"]
                    + self.pops["pheromone_va1v"]["left"]
                    + self.pops["visual_lc10"]["left"]
                    + self.pops["visual_lc4"]["left"]
                    + self.pops["visual_lplc2"]["left"]
                    + self.pops["visual_lc11"]["left"]
                    + self.pops["visual_lc15"]["left"]
                    + self.pops["visual_lc17"]["left"]
                    + self.pops["visual_lc18"]["left"]
                    + self.pops["visual_t4a"]["left"]
                    + self.pops["visual_t4b"]["left"]
                    + self.pops["visual_t4c"]["left"]
                    + self.pops["visual_t4d"]["left"]
                    + self.pops["visual_t5a"]["left"]
                    + self.pops["visual_t5b"]["left"]
                    + self.pops["visual_t5c"]["left"]
                    + self.pops["visual_t5d"]["left"])
        for pre in left_ids:
            s, e = int(brain.indptr[pre]), int(brain.indptr[pre + 1])
            if e > s:
                brain.weights[s:e] *= 40.0
        before_l = float(np.abs(brain.weights[
            rl._ensure_pin_positions(brain)[0]]).mean())
        self.assertGreater(before_l, 10.0 * rl._base_means["sens"])
        # Fixed-subset ratio: uniform pool scaling must preserve every
        # learned relative pattern exactly.
        pos_all = rl._ensure_pin_positions(brain)[0]
        sub_a, sub_b = pos_all[:1000], pos_all[1000:2000]
        rel_before = (float(np.abs(brain.weights[sub_a]).mean())
                      / max(float(np.abs(brain.weights[sub_b]).mean()), 1e-9))
        rl.pin_gains(brain)
        pos_sens = rl._ensure_pin_positions(brain)[0]
        after = float(np.abs(brain.weights[pos_sens]).mean())
        self.assertAlmostEqual(after / rl._base_means["sens"], 1.0, delta=0.05)
        rel_after = (float(np.abs(brain.weights[sub_a]).mean())
                     / max(float(np.abs(brain.weights[sub_b]).mean()), 1e-9))
        self.assertAlmostEqual(rel_after / rel_before, 1.0, delta=0.05)

    def test_gain_cap_bounds_single_call(self):
        # Trainer micro-gain cap: a 1.3x request under cap 0.02 must move
        # weights by at most 2%; the default server cap passes 1.3x.
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl = DopamineReinforcement(self.pops)
        pool = self.pops["pheromone_da1"]["left"][:10]
        anchor = next(p for p in pool
                      if brain.indptr[p + 1] > brain.indptr[p])
        w0 = brain.weights.copy()
        rl._scale_outgoing(brain, pool, 1.3, cap=0.02)
        s, e = int(brain.indptr[anchor]), int(brain.indptr[anchor + 1])
        ratio = float(np.abs(brain.weights[s:e]).mean()
                      / max(np.abs(w0[s:e]).mean(), 1e-9))
        self.assertLessEqual(ratio, 1.021)
        brain2 = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl._scale_outgoing(brain2, pool, 1.3)
        s, e = int(brain2.indptr[anchor]), int(brain2.indptr[anchor + 1])
        ratio = float(np.abs(brain2.weights[s:e]).mean()
                      / max(np.abs(w0[s:e]).mean(), 1e-9))
        self.assertAlmostEqual(ratio, 1.3, delta=0.01)

    def test_base_brains_untouched_by_new_branches(self):        # Isolation: with base schemes (pre-mapping brains), the JO roll
        # and KC->MBON branches must not move a single weight, even under
        # strong roll + dopamine signals.
        from connectome_loader import load_or_build_csr
        csr = load_or_build_csr()
        brain = FlyBrain(csr.indptr, csr.indices, csr.data.copy())
        rl = DopamineReinforcement(self.pops)
        w0 = brain.weights.copy()
        rl.apply_plasticity(brain, {"angular_roll_rate": -0.6,
                                    "pheromone_conc_left": 0.8},
                            {"yaw_torque": 0.0, "roll_torque": -0.5,
                             "thrust": 0.4}, 1.0)
        pos_app, pos_av = rl._ensure_kc_mbon(brain)
        # JO efferent synapse positions (rows whose presynaptic cell is JO).
        jo_ids = np.array(self.pops["gyro_jo"]["all"], dtype=np.int32)
        is_jo = np.zeros(len(brain.indptr) - 1, dtype=bool)
        is_jo[jo_ids] = True
        rows = np.repeat(np.arange(len(brain.indptr) - 1, dtype=np.int32),
                         np.diff(brain.indptr).astype(np.int64))
        pos_jo = np.where(is_jo[rows])[0]
        changed = brain.weights != w0
        self.assertFalse(bool(changed[pos_jo].any()),
                         "base: JO efferents must not move")
        self.assertFalse(bool(changed[pos_app].any()),
                         "base: KC->MBON_app must not move")
        self.assertFalse(bool(changed[pos_av].any()),
                         "base: KC->MBON_av must not move")


class TestExperimentalWiring(unittest.TestCase):
    """Verifies the injected-edge overlay: deterministic, contra-directional,
    checkpoint-arithmetic safe (arity grows by exactly the added edges)."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_contra_wiring_direction(self):
        self.assertIn("lplc2_contra_dn", EXPERIMENTS)
        pre, post, w = EXPERIMENTS["lplc2_contra_dn"](self.pops)
        lp_l = set(self.pops["visual_lplc2"]["left"])
        lp_r = set(self.pops["visual_lplc2"]["right"])
        dn_l = set(self.pops["descending_all"]["left"])
        dn_r = set(self.pops["descending_all"]["right"])
        self.assertEqual(len(pre), len(post))
        self.assertEqual(len(pre), len(w))
        expect = 16 * (len(lp_l) + len(lp_r))
        self.assertEqual(len(pre), expect)
        for p, q in zip(pre, post):
            if p in lp_l:
                self.assertIn(q, dn_r)  # left tree -> right DN (steer away)
            elif p in lp_r:
                self.assertIn(q, dn_l)  # right tree -> left DN (steer away)
            else:
                self.fail(f"pre {p} is not an LPLC2 neuron")

    def test_overlay_grows_arity_exactly(self):
        pre, post, w = EXPERIMENTS["lplc2_contra_dn"](self.pops)
        indptr, indices, data = apply_overlay(self.csr, pre, post, w)
        # Overlapping (pre, post) pairs COALESCE in scipy (values sum), so
        # arity grows strictly: base <= len <= base + injected. Total weight
        # is conserved additively either way. Float32 accumulation over 25M
        # elements can drift ~1-10 so use a generous absolute tolerance.
        self.assertGreaterEqual(len(data), self.csr.nnz)
        self.assertLessEqual(len(data), self.csr.nnz + len(w))
        self.assertEqual(len(indices), len(data))
        self.assertEqual(len(indptr), len(self.csr.indptr))
        self.assertLess(abs(float(np.sum(data))
                            - (float(np.sum(self.csr.data)) + float(np.sum(w)))),
                        50.0)

    def test_base_arity_preserved(self):
        indptr, indices, data = experiment_arrays(None, self.csr, self.pops)
        self.assertEqual(len(data), self.csr.nnz)
        self.assertEqual(len(indices), self.csr.nnz)

    def test_unknown_experiment_raises(self):
        with self.assertRaises(ValueError):
            experiment_arrays("not_a_real_wiring", self.csr, self.pops)


class TestCrossArityBattles(unittest.TestCase):
    """Per-side native wiring: a base brain and an experiment brain must
    integrate, learn (dopamine), and keep their native arity side by side.
    This is the mixed-bracket contract the live server relies on."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()
        cls.base = experiment_arrays(None, cls.csr, cls.pops)
        cls.exp = experiment_arrays("lplc2_contra_dn", cls.csr, cls.pops)

    def _make(self, struct):
        indptr, indices, data = struct
        return FlyBrain(indptr, indices,
                        np.ascontiguousarray(np.asarray(data).copy(), dtype=np.float32))

    def test_native_structures_share_neurons_differ_in_synapses(self):
        self.assertEqual(len(self.base[0]), len(self.exp[0]))  # same neurons
        self.assertNotEqual(len(self.base[2]), len(self.exp[2]))  # diff arity
        self.assertEqual(len(self.base[1]), len(self.base[2]))
        self.assertEqual(len(self.exp[1]), len(self.exp[2]))

    def test_both_sides_integrate(self):
        stim = np.array(self.pops["pheromone_da1"]["left"][:10], dtype=np.int32)
        spikes_base = self._make(self.base).integrate_50ms(stim)
        spikes_exp = self._make(self.exp).integrate_50ms(stim)
        self.assertGreater(len(spikes_base), 0, "base brain must spike")
        self.assertGreater(len(spikes_exp), 0, "experiment brain must spike")

    def test_threaded_step_matches_serial(self):
        # Thread-per-brain must be bit-identical to the sequential path:
        # fairness demands neither side gain anything from scheduling.
        # Mirrors production structure exactly: encodes serially (shared
        # global RandomState must never be touched from workers), then
        # integrates threaded.
        from concurrent.futures import ThreadPoolExecutor
        import brain_server as bs
        enc = SensoryEncoder(self.pops)
        dec = MotorDecoder(self.pops)
        pool_idx = bs._pool_index(self.pops)
        sens = {"pheromone_conc_left": 0.6, "pheromone_conc_right": 0.3,
                "visual_target_visible": True, "visual_target_azimuth": 10.0,
                "visual_rival_looming": 0.4}
        brains = [self._make(self.base), self._make(self.base)]
        # One shared stimulus (identical weights + identical spikes in:
        # identical everything out, on either path).
        np.random.seed(1234)
        stim = enc.encode(sens)
        ca, sa, _, _ = bs._run_side_integrate(dec, brains[0], stim,
                                              sens, self.pops, pool_idx, 1)
        with ThreadPoolExecutor(max_workers=2) as ex:
            fa = ex.submit(bs._run_side_integrate, dec, brains[1],
                           stim, sens, self.pops, pool_idx, 1)
            cb, sb, _, _ = fa.result()
        self.assertEqual(set(ca.keys()), set(cb.keys()))
        for k in ca:
            va, vb = ca[k], cb[k]
            if isinstance(va, bool):
                self.assertEqual(va, vb)
            else:
                self.assertAlmostEqual(float(va), float(vb), places=5)
        self.assertEqual(sa["spikes"], sb["spikes"])
        self.assertEqual(sa["pools"], sb["pools"])

    def test_dopamine_both_arities_alternating(self):
        rl = DopamineReinforcement(self.pops)
        brain_base = self._make(self.base)
        brain_exp = self._make(self.exp)
        # Left odor + left tree loom, turning left (correct under the
        # contralateral mapping): exercises sensory-outgoing, DN-incoming
        # masks, and the LPLC2 tree branch on both wirings.
        sens = {"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.1,
                "visual_target_azimuth": -40.0,
                "visual_tree_left_looming": 0.9, "visual_tree_right_looming": 0.0}
        motor = {"yaw_torque": -0.5, "thrust": 0.3, "pitch_torque": 0.0}
        w_base0 = brain_base.weights.copy()
        w_exp0 = brain_exp.weights.copy()
        rl.apply_plasticity(brain_base, sens, motor, 1.0)
        rl.apply_plasticity(brain_exp, sens, motor, 1.0)
        rl.apply_plasticity(brain_base, sens, motor, 1.0)  # alternate back
        self.assertEqual(len(brain_base.weights), len(w_base0))
        self.assertEqual(len(brain_exp.weights), len(w_exp0))
        self.assertFalse(np.array_equal(brain_base.weights, w_base0),
                         "base brain must learn")
        self.assertFalse(np.array_equal(brain_exp.weights, w_exp0),
                         "experiment brain must learn")
        # Per-brain mask caches stay tagged to their own wiring length.
        self.assertEqual(brain_base._dn_masks[0], len(brain_base.weights))
        self.assertEqual(brain_exp._dn_masks[0], len(brain_exp.weights))


class TestEvolutionEngine(unittest.TestCase):
    """Verifies tournament scoring, checkpointing, and generational reproduction."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def setUp(self):
        self.test_chk_dir = os.path.join(PROJECT_ROOT, "checkpoints_test")
        self.evo = EvolutionManager(checkpoints_dir=self.test_chk_dir)
        self.brain_a = FlyBrain(self.csr.indptr, self.csr.indices, self.csr.data.copy())
        self.brain_b = FlyBrain(self.csr.indptr, self.csr.indices, self.csr.data.copy())

    def tearDown(self):
        if os.path.exists(self.test_chk_dir):
            for f in os.listdir(self.test_chk_dir):
                os.remove(os.path.join(self.test_chk_dir, f))
            os.rmdir(self.test_chk_dir)

    def test_match_evaluation(self):
        stats_a = { "kills": 1, "damage_dealt": 80.0, "damage_taken": 0.0, "tracking_time_s": 15.0 }
        stats_b = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 80.0, "tracking_time_s": 5.0 }

        winner, fit_a, fit_b = self.evo.evaluate_match(stats_a, stats_b)
        self.assertEqual(winner, "alpha")
        self.assertGreater(fit_a, fit_b)

    def test_advance_generation(self):
        stats_a = { "kills": 1, "damage_dealt": 80.0, "damage_taken": 0.0, "tracking_time_s": 10.0 }
        stats_b = { "kills": 0, "damage_dealt": 0.0, "damage_taken": 80.0, "tracking_time_s": 2.0 }
        winner, _, _ = self.evo.evaluate_match(stats_a, stats_b)

        target_pathways = self.pops["pheromone_da1"]["all"]
        self.evo.advance_generation(self.brain_a, self.brain_b, winner, target_pathways)

        self.assertEqual(self.evo.generation, 2)
        chk_file = os.path.join(self.test_chk_dir, "gen_0001_champion.npz")
        self.assertTrue(os.path.exists(chk_file))

        loaded = np.load(chk_file)
        self.assertIn("weights", loaded)
        self.assertEqual(len(loaded["weights"]), len(self.brain_a.weights))


class TestUDPServerIntegration(unittest.TestCase):
    """Verifies end-to-end UDP network protocol with the Brain Server."""
    @classmethod
    def setUpClass(cls):
        cls.server_proc = subprocess.Popen(
            [sys.executable, "-u", "brain_server.py"],
            cwd=BRAIN_ENGINE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT
        )
        time.sleep(5.0) # Allow server to bind and load graph (boot is heavy)

    @classmethod
    def tearDownClass(cls):
        cls.server_proc.terminate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    def test_udp_step_and_round_over(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2.0)
        # Windows UDP port reset fix
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            sock.ioctl(socket.SIO_UDP_CONNRESET, False)

        server_addr = ("127.0.0.1", 9999)

        # Ensure server is listening
        step_packet = {
            "type": "step",
            "alpha": {
                "pheromone_conc_left": 0.7,
                "pheromone_conc_right": 0.1,
                "visual_target_azimuth": -15.0,
                "visual_target_visible": True,
                "visual_looming_rate": 0.05
            },
            "beta": {
                "pheromone_conc_left": 0.1,
                "pheromone_conc_right": 0.8,
                "visual_target_azimuth": 20.0,
                "visual_target_visible": True,
                "visual_looming_rate": 0.0
            }
        }

        # Wide retry window: the server loads a 25M-synapse graph at boot and
        # can be slow when the suite runs other CPU-heavy tests concurrently.
        sock.settimeout(4.0)
        res = None
        for attempt in range(30):
            try:
                sock.sendto(json.dumps(step_packet).encode("utf-8"), server_addr)
                data, _ = sock.recvfrom(65535)
                res = json.loads(data.decode("utf-8"))
                break
            except (socket.timeout, ConnectionResetError):
                time.sleep(0.5)

        self.assertIsNotNone(res, "Server failed to respond within retry window")
        self.assertEqual(res["status"], "ok")
        self.assertIn("alpha", res)
        self.assertIn("beta", res)
        self.assertIn("thrust", res["alpha"])
        self.assertIn("yaw_torque", res["alpha"])

        # 2. Test round_over on a FRESH socket: the step socket may still hold
        # stale step responses in its buffer, so reuse would mis-order packets.
        # The server sets SIO_UDP_CONNRESET=False, so closing the step socket
        # won't poison its receive path.
        sock_round = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock_round.settimeout(4.0)
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            sock_round.ioctl(socket.SIO_UDP_CONNRESET, False)
        round_packet = {
            "type": "round_over",
            "stats_alpha": { "kills": 1, "damage_dealt": 80.0, "damage_taken": 0.0, "tracking_time_s": 20.0 },
            "stats_beta": { "kills": 0, "damage_dealt": 0.0, "damage_taken": 80.0, "tracking_time_s": 4.0 }
        }
        round_res = None
        for attempt in range(30):
            try:
                sock_round.sendto(json.dumps(round_packet).encode("utf-8"), server_addr)
                data, _ = sock_round.recvfrom(65535)
                round_res = json.loads(data.decode("utf-8"))
                if round_res.get("status") == "generation_advanced":
                    break
                round_res = None
            except (socket.timeout, ConnectionResetError):
                time.sleep(0.5)

        self.assertIsNotNone(round_res, "Server failed to respond to round_over")
        self.assertEqual(round_res["status"], "generation_advanced")
        self.assertEqual(round_res["previous_winner"], "alpha")
        self.assertGreaterEqual(round_res["new_generation"], 2)
        sock.close()
        sock_round.close()


class TestBrainVault(unittest.TestCase):
    """Verifies .flybrain packaging, vault scan/recovery, and record keeping."""
    @classmethod
    def setUpClass(cls):
        import tempfile
        cls._real_vault = vault_pkg.VAULT_DIR
        cls._real_index = vault_pkg.VAULT_INDEX
        cls.tmp = tempfile.mkdtemp(prefix="vault_test_")
        vault_pkg.VAULT_DIR = cls.tmp
        vault_pkg.VAULT_INDEX = os.path.join(cls.tmp, "vault_index.json")

    @classmethod
    def tearDownClass(cls):
        import shutil
        vault_pkg.VAULT_DIR = cls._real_vault
        vault_pkg.VAULT_INDEX = cls._real_index
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_package_round_trip(self):
        rec = vault_pkg.new_record("Viper", {"seed": 11, "learning_rate": 0.01})
        w = np.random.randn(4096).astype(np.float32)
        vault_pkg.save_brain(rec, w)
        rec2, w2 = vault_pkg.load_brain(rec["id"])
        self.assertEqual(rec2["name"], "Viper")
        self.assertTrue(np.allclose(w, w2))
        self.assertEqual(rec2["generator_params"]["seed"], 11)

    def test_scan_and_records(self):
        rec = vault_pkg.new_record("Hawk", {})
        vault_pkg.save_brain(rec, np.zeros(64, dtype=np.float32))
        found = [r for r in vault_pkg.scan_vault() if r["id"] == rec["id"]]
        self.assertEqual(len(found), 1)
        vault_pkg.record_battle_result(rec, "win")
        vault_pkg.record_battle_result(rec, "draw")
        vault_pkg.record_match_result(rec, "win")
        vault_pkg.log_training_session(rec, 50, {"lr": 0.008}, "test")
        self.assertEqual(rec["record"]["wins"], 1)
        self.assertEqual(rec["record"]["draws"], 1)
        self.assertEqual(rec["record"]["battles"], 2)
        self.assertEqual(rec["record"]["matches"], 1)
        self.assertEqual(rec["record"]["matches_won"], 1)
        self.assertEqual(rec["training"]["episodes"], 50)
        self.assertAlmostEqual(vault_pkg.win_rate(rec), 1.0)
        # Atomic save keeps a backup of the previous version.
        vault_pkg.save_brain(rec, np.zeros(64, dtype=np.float32))
        self.assertTrue(os.path.isfile(vault_pkg.package_path(rec) + ".bak"))

    def test_corrupt_quarantine(self):
        bad = os.path.join(self.tmp, "junk_deadbeef.flybrain")
        with open(bad, "w") as f:
            f.write("not a zip")
        recs = vault_pkg.scan_vault()
        self.assertFalse(any(r["filename"] == "junk_deadbeef.flybrain" for r in recs))
        self.assertTrue(os.path.isfile(bad + ".corrupt"))

    def test_import_legacy_npz(self):
        tmp_npz = os.path.join(self.tmp, "legacy.npz")
        np.savez_compressed(tmp_npz, weights=np.ones(128, dtype=np.float32))
        rec = vault_pkg.import_legacy_npz(tmp_npz, "Legacy")
        _rec2, w2 = vault_pkg.load_brain(rec["id"])
        self.assertTrue(np.allclose(w2, 1.0))
        self.assertTrue(str(rec["lineage"]["source"]).startswith("imported:"))

    def test_progress_file_contract(self):
        # Progress/result files must always be complete JSON objects (the
        # Godot poller skips anything that doesn't start with { / end with }).
        import vault_cli
        pf = os.path.join(self.tmp, "prog.json")
        for ep in range(1, 6):
            vault_cli._write_progress(pf, ep, 10)
            with open(pf) as f:
                raw = f.read().strip()
            self.assertTrue(raw.startswith("{") and raw.endswith("}"))
            body = json.loads(raw)
            self.assertEqual(body["episode"], ep)
            self.assertAlmostEqual(body["pct"], 10.0 * ep)

    def test_params_file_cli(self):
        # vault_cli --params-file (quoting-proof params for Godot spawns).
        import subprocess
        pf = os.path.join(self.tmp, "params.json")
        with open(pf, "w") as f:
            json.dump({"seed": 7, "learning_rate": 0.011}, f)
        tmp_npz = os.path.join(self.tmp, "pf_legacy.npz")
        np.savez_compressed(tmp_npz, weights=np.ones(32, dtype=np.float32))
        r = subprocess.run(
            [sys.executable, "vault_cli.py", "import", "--npz", tmp_npz,
             "--name", "ParamFile", "--params-file", pf],
            cwd=BRAIN_ENGINE_DIR, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, f"stderr: {r.stderr[-500:]}")
        # Last JSON-looking stdout line must be the result (loader prints first).
        lines = [ln for ln in r.stdout.splitlines() if ln.strip().startswith("{")]
        self.assertTrue(lines, f"no JSON in stdout: {r.stdout[-500:]}")
        body = json.loads(lines[-1])
        self.assertTrue(body["ok"])
        self.assertEqual(body["brain"]["generator_params"]["seed"], 7)
        self.assertAlmostEqual(body["brain"]["generator_params"]["learning_rate"], 0.011)
        # Subprocess wrote to the REAL vault: remove the test brain.
        real_path = os.path.join(PROJECT_ROOT, "brains", body["brain"]["filename"])
        if os.path.isfile(real_path):
            os.remove(real_path)


class TestTournamentProtocol(unittest.TestCase):
    """Live server: tournament_load -> battles (KO + draw) -> match/end records."""
    @classmethod
    def setUpClass(cls):
        cls.server_proc = subprocess.Popen(
            [sys.executable, "-u", "brain_server.py"],
            cwd=BRAIN_ENGINE_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT
        )
        time.sleep(5.0)
        # Private test brains (real arity) so the seeded vault stays clean.
        ckpt_a = os.path.join(PROJECT_ROOT, "checkpoints", "trained_homing_A.npz")
        rec_a = vault_pkg.import_legacy_npz(ckpt_a, "ProtoA")
        ckpt_b = os.path.join(PROJECT_ROOT, "checkpoints", "trained_homing_B.npz")
        rec_b = vault_pkg.import_legacy_npz(ckpt_b, "ProtoB")
        cls.id_a, cls.id_b = rec_a["id"], rec_b["id"]
        cls.path_a = vault_pkg.package_path(rec_a)
        cls.path_b = vault_pkg.package_path(rec_b)
        # Mixed-arity pair: fresh base brain + synthetic experiment brain
        # (native overlay arity, flagged in its record like Dodger).
        rec_c = vault_pkg.import_legacy_npz(ckpt_a, "ProtoC")
        cls.id_c = rec_c["id"]
        cls.path_c = vault_pkg.package_path(rec_c)
        csr = load_or_build_csr()
        pops = load_or_extract_populations()
        exp_indptr, exp_indices, exp_data = experiment_arrays(
            "lplc2_contra_dn", csr, pops)
        cls.exp_len = len(exp_data)
        rec_x = vault_pkg.new_record("ProtoX", {"experiment": "lplc2_contra_dn"})
        vault_pkg.save_brain(
            rec_x, np.ascontiguousarray(np.asarray(exp_data), dtype=np.float32))
        cls.id_x = rec_x["id"]
        cls.path_x = vault_pkg.package_path(rec_x)

    @classmethod
    def tearDownClass(cls):
        for bid in (getattr(cls, "id_a", ""), getattr(cls, "id_b", ""),
                    getattr(cls, "id_c", ""), getattr(cls, "id_x", "")):
            try:
                if bid:
                    os.remove(vault_pkg.package_path(vault_pkg.load_brain(bid)[0]))
            except OSError:
                pass
        vault_pkg.refresh_index()
        cls.server_proc.terminate()
        try:
            cls.server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server_proc.kill()

    def _rpc(self, msg, timeout=120.0):
        # Tournament round_overs trigger dopamine + vault saves (~10s), so
        # send ONCE and wait patiently: resending would queue duplicate
        # battles on the single-threaded server.
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(5.0)
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            sock.ioctl(socket.SIO_UDP_CONNRESET, False)
        deadline = time.time() + timeout
        try:
            sock.sendto(json.dumps(msg).encode("utf-8"), ("127.0.0.1", 9999))
            while time.time() < deadline:
                try:
                    data, _ = sock.recvfrom(65535)
                    return json.loads(data.decode("utf-8"))
                except (socket.timeout, ConnectionResetError):
                    pass
        finally:
            sock.close()
        return None

    def test_mixed_arities_battle(self):
        # Base vs experiment wiring in one match: each side must run its
        # native structure (previously rejected with "arity mismatch"), bank
        # records, and keep native file arity. Uses ProtoC/ProtoX only so
        # the base flow test's counters stay untouched.
        res = self._rpc({"type": "tournament_load", "alpha_path": self.path_c,
                         "beta_path": self.path_x, "tournament_id": "UTX",
                         "match": "R1M1", "lr_scale": 0.5})
        self.assertIsNotNone(res)
        self.assertEqual(res.get("status"), "brains_loaded")
        step = self._rpc({"type": "step", "alpha": {}, "beta": {}})
        self.assertEqual(step.get("status"), "ok")
        ko = self._rpc({"type": "round_over",
                        "stats_alpha": {"damage_taken": 80.0},
                        "stats_beta": {"kills": 1, "damage_dealt": 80.0}})
        self.assertIsNotNone(ko)
        self.assertEqual(ko.get("status"), "tournament_battle")
        self.assertEqual(ko.get("battle_winner"), "beta")
        rx, wx = vault_pkg.load_brain(self.id_x)
        self.assertEqual(rx["record"]["wins"], 1)
        self.assertEqual(rx["record"]["battles"], 1)
        self.assertEqual(len(wx), self.exp_len)
        rc, _wc = vault_pkg.load_brain(self.id_c)
        self.assertEqual(rc["record"]["losses"], 1)
        # Leaving tournament mode after a mixed bout restores clean boots.
        f = self._rpc({"type": "free_mode"})
        self.assertEqual(f.get("status"), "free_ready")

    def test_tournament_flow(self):
        res = self._rpc({"type": "tournament_load", "alpha_path": self.path_a,
                         "beta_path": self.path_b, "tournament_id": "UT",
                         "match": "R1M1", "lr_scale": 0.5})
        self.assertIsNotNone(res)
        self.assertEqual(res.get("status"), "brains_loaded")
        step = self._rpc({"type": "step", "alpha": {}, "beta": {}})
        self.assertEqual(step.get("status"), "ok")
        ko = self._rpc({"type": "round_over",
                        "stats_alpha": {"kills": 1, "damage_dealt": 80.0},
                        "stats_beta": {"damage_taken": 80.0}})
        self.assertIsNotNone(ko)
        self.assertEqual(ko.get("status"), "tournament_battle")
        self.assertEqual(ko.get("battle_winner"), "alpha")
        # No evolution in tournament mode: generation stays pinned.
        self.assertNotIn("new_generation", ko)
        draw = self._rpc({"type": "round_over", "stats_alpha": {},
                          "stats_beta": {}, "arena_draw": True})
        self.assertEqual(draw.get("battle_winner"), "draw")
        m = self._rpc({"type": "tournament_match", "match_winner": "alpha"})
        self.assertEqual(m.get("status"), "match_recorded")
        e = self._rpc({"type": "tournament_end", "champion": "alpha"})
        self.assertEqual(e.get("status"), "tournament_closed")
        # Leaving tournament mode restores pristine boot brains.
        f = self._rpc({"type": "free_mode"})
        self.assertEqual(f.get("status"), "free_ready")
        ra, _w = vault_pkg.load_brain(self.id_a)
        rb, _w2 = vault_pkg.load_brain(self.id_b)
        # 1 battle win + 1 draw battle, 1 match win, 1 title. No double count.
        self.assertEqual(ra["record"]["battles"], 2)
        self.assertEqual(ra["record"]["wins"], 1)
        self.assertEqual(ra["record"]["draws"], 1)
        self.assertEqual(ra["record"]["matches"], 1)
        self.assertEqual(ra["record"]["matches_won"], 1)
        self.assertEqual(ra["record"]["tournaments_won"], 1)
        self.assertEqual(rb["record"]["losses"], 1)
        self.assertGreaterEqual(len(ra["training"]["sessions"]), 1)


class TestLegacyCompat(unittest.TestCase):
    """Pre-mapping brains (records WITHOUT the 'mapping' key) run the
    legacy regime: fused loom channel, legacy decoder thrust gain, no
    gain pinning. Brains carrying the key (even None) run the current
    stack. This keeps neuro-mappings opt-in without rewriting old
    training."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def test_legacy_marker(self):
        from sensory_motor import is_legacy_record
        self.assertTrue(is_legacy_record(
            {"name": "Old", "generator_params": {"seed": 1}}))
        self.assertFalse(is_legacy_record(
            {"name": "New", "generator_params": {"seed": 1, "mapping": None}}))
        self.assertFalse(is_legacy_record(
            {"name": "Map", "generator_params": {"mapping": "mbon"}}))
        self.assertFalse(is_legacy_record(None))
        # Fresh records always carry the key -> current stack.
        self.assertFalse(is_legacy_record(vault_pkg.new_record("Fresh", {})))

    def test_legacy_encoder_fused_loom(self):
        # Split tree keys alone must not drive LPLC2 for legacy brains;
        # the fused key they trained on drives LC4.
        lplc2 = set(self.pops["visual_lplc2"]["left"]
                    + self.pops["visual_lplc2"]["right"])
        lc4 = set(self.pops["visual_lc4"]["all"])
        split = {"visual_tree_left_looming": 0.8,
                 "visual_target_visible": False}
        legacy = SensoryEncoder(self.pops, legacy=True)
        self.assertEqual(len(legacy.encode(split)), 0)
        fused = dict(split, visual_looming_rate=0.8)
        spikes = set(int(s) for s in legacy.encode(fused))
        self.assertGreater(len(spikes), 0)
        for s in spikes:
            self.assertIn(s, lc4)
            self.assertNotIn(s, lplc2)
        # Current stack keeps the split behavior.
        current = SensoryEncoder(self.pops)
        spikes_c = set(int(s) for s in current.encode(split))
        self.assertGreater(len(spikes_c), 0)
        for s in spikes_c:
            self.assertIn(s, set(self.pops["visual_lplc2"]["left"]))

    def test_legacy_decoder_thrust_gain(self):
        # Same DN volley: legacy thrust expresses, current stays ~baseline.
        dn = list(self.pops["descending_all"]["all"][:20])
        leg = MotorDecoder(self.pops, legacy=True).decode(dn)
        cur = MotorDecoder(self.pops).decode(dn)
        self.assertAlmostEqual(leg["thrust"], 0.2 + 20 * 0.008, places=5)
        self.assertAlmostEqual(cur["thrust"], 0.2 + 20 * 0.0005, places=5)
        self.assertGreater(leg["thrust"], cur["thrust"] + 0.1)

    def _fake_rig(self):
        # Tiny synthetic wiring + pools for fast deterministic plasticity
        # tests (no 25M-synapse connectome boot).
        from dopamine_learning import DopamineReinforcement
        rng = np.random.default_rng(7)
        n, deg = 200, 6
        indptr = np.arange(n + 1, dtype=np.int32) * deg
        indices = rng.integers(0, n, size=n * deg).astype(np.int32)
        base_w = rng.normal(4.0, 0.5, size=n * deg).astype(np.float32)
        sens = list(range(0, 20))
        fake_pops = {
            "pheromone_da1": {"left": sens[:10], "right": sens[10:]},
            "pheromone_va1v": {"left": [], "right": []},
            "visual_lc10": {"left": [], "right": []},
            "visual_lc4": {"left": [], "right": []},
            "visual_lplc2": {"left": [], "right": []},
            "dopamine_pam": {"all": []}, "dopamine_ppl1": {"all": []},
            "motor_turn_dnp20": {"left": [100], "right": [101]},
            "motor_thrust_dnp09": {"all": [102]},
            "motor_ram_dnpe017": {"all": [103]},
            "motor_giant_fiber": {"all": [104]},
            "descending_all": {"left": [100], "right": [101],
                               "all": [100, 101, 102]},
            "mushroom_body_kc": [], "mbon_app": {"all": []},
            "mbon_av": {"all": []},
        }
        rl = DopamineReinforcement(
            fake_pops, base=(indptr, indices, base_w.copy()))

        class _Brain:
            pass

        def _make():
            b = _Brain()
            b.indptr = indptr
            b.indices = indices
            b.weights = base_w.copy()
            return b
        pos = DopamineReinforcement._row_positions(indptr, sens)
        return rl, _make, pos, sens

    def test_spear_branch_credit_assignment(self):
        # Aimed lunges with positive DA potentiate the lobula-feature
        # efferents; punished lunges depress them; sub-threshold or
        # un-aimed spear commands leave weights untouched.
        from dopamine_learning import DopamineReinforcement
        rng = np.random.default_rng(11)
        n, deg = 200, 6
        indptr = np.arange(n + 1, dtype=np.int32) * deg
        indices = rng.integers(0, n, size=n * deg).astype(np.int32)
        base_w = rng.normal(4.0, 0.5, size=n * deg).astype(np.float32)
        feat = list(range(0, 20))
        fake_pops = {
            "pheromone_da1": {"left": [], "right": []},
            "pheromone_va1v": {"left": [], "right": []},
            "visual_lc10": {"left": [], "right": []},
            "visual_lc4": {"left": [], "right": []},
            "visual_lplc2": {"left": [], "right": []},
            "visual_lc11": {"left": feat[:10], "right": feat[10:]},
            "visual_lc15": {"left": [], "right": []},
            "visual_lc17": {"left": [], "right": []},
            "visual_lc18": {"left": [], "right": []},
            "gyro_jo": {"left": [], "right": []},
            "dopamine_pam": {"all": []}, "dopamine_ppl1": {"all": []},
            "motor_turn_dnp20": {"left": [100], "right": [101]},
            "motor_thrust_dnp09": {"all": [102]},
            "motor_ram_dnpe017": {"all": [103]},
            "motor_giant_fiber": {"all": [104]},
            "descending_all": {"left": [100], "right": [101],
                               "all": [100, 101, 102]},
            "mushroom_body_kc": [], "mbon_app": {"all": []},
            "mbon_av": {"all": []},
        }
        rl = DopamineReinforcement(fake_pops)

        class _Brain:
            pass

        def _make():
            b = _Brain()
            b.indptr = indptr
            b.indices = indices
            b.weights = base_w.copy()
            return b

        pos = DopamineReinforcement._row_positions(indptr, feat)
        frontal = {"visual_target_visible": True, "visual_target_azimuth": 5.0,
                   "pheromone_conc_left": 0.0, "pheromone_conc_right": 0.0}
        hot = _make()
        rl.apply_plasticity(hot, frontal, {"yaw_torque": 0.0,
                                           "roll_torque": 0.0,
                                           "spear_thrust": 0.6},
                            1.0, gain_cap=0.3)
        self.assertGreater(float(np.abs(hot.weights[pos]).mean()),
                           float(np.abs(base_w[pos]).mean()))
        cold = _make()
        rl.apply_plasticity(cold, frontal, {"yaw_torque": 0.0,
                                            "roll_torque": 0.0,
                                            "spear_thrust": 0.6},
                            -1.0, gain_cap=0.3)
        self.assertLess(float(np.abs(cold.weights[pos]).mean()),
                        float(np.abs(base_w[pos]).mean()))
        for senses, motor in (
                (frontal, {"spear_thrust": 0.2}),  # sub-threshold
                ({"visual_target_visible": False,  # un-aimed
                  "visual_target_azimuth": 170.0}, {"spear_thrust": 0.6})):
            b = _make()
            before = b.weights.copy()
            rl.apply_plasticity(b, senses, motor, 1.0, gain_cap=0.3)
            np.testing.assert_array_equal(b.weights, before)

    def test_subfloor_abandonment(self):
        # Both regimes abandon pools ground below a tenth of reference:
        # dust in healthy winners is usually learned irrelevance, and
        # re-animating it mid-tournament scrambles learned policies
        # (vault-wide spinning incident). Dead channels stay dead until
        # a human runs the scoped repair tool; the probe makes the
        # collapse visible instead of hiding it.
        rl, _make, pos, _sens = self._fake_rig()
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                dead = _make()
                dead.weights[pos] *= 0.05
                before = dead.weights.copy()
                rl.pin_gains(dead, legacy=legacy)
                np.testing.assert_array_equal(dead.weights, before)

    def test_depression_budget(self):
        # Per-episode depression budget: one bad episode (120x0.98 =
        # 0.088x unguarded) must stall at 0.5x instead of grinding into
        # the abandonment gap; potentiation never consumes budget;
        # budgets reset per episode and never leak across brains.
        from dopamine_learning import DopamineReinforcement
        rl, _make, _pos, _sens = self._fake_rig()
        # Canonical pool list (budget tracks object identity).
        pool = rl.da1_left
        pos = DopamineReinforcement._row_positions(
            _make().indptr, pool)
        base = float(np.abs(_make().weights[pos]).mean())
        b = _make()
        rl.begin_episode(b)
        for _ in range(200):
            rl._scale_outgoing(b, pool, 0.98, cap=0.3)
        ratio = float(np.abs(b.weights[pos]).mean()) / base
        self.assertGreaterEqual(ratio, 0.49)
        self.assertLess(ratio, 0.9)
        # Potentiation still applies on top of a spent budget.
        before = b.weights.copy()
        rl._scale_outgoing(b, pool, 1.2, cap=0.3)
        self.assertGreater(float(np.abs(b.weights[pos]).mean()),
                           float(np.abs(before[pos]).mean()))
        # Reset restores full budget; brains are independent.
        rl.begin_episode(b)
        b2 = _make()
        rl.begin_episode(b2)
        for _ in range(200):
            rl._scale_outgoing(b2, pool, 0.98, cap=0.3)
        r2 = float(np.abs(b2.weights[pos]).mean()) / base
        self.assertGreaterEqual(r2, 0.49)
        # Untracked (legacy-direct) path is unbudgeted as before
        # (fresh list object each time defeats identity tracking).
        c = _make()
        for _ in range(200):
            rl._modulate_pathway(c, list(pool), set(), 0.98)
        rc = float(np.abs(c.weights[pos]).mean()) / base
        self.assertLess(rc, 0.49)

    def test_legacy_runaway_only_pin(self):
        # Legacy pinning corrects runaway (>2x) but never touches
        # suppression-side learning: a 40x pool pins back, a 0.3x pool
        # and a dust pool are left exactly as learned.
        rl, _make, pos, _sens = self._fake_rig()
        hot = _make()
        hot.weights[pos] *= 40.0
        rl.pin_gains(hot, legacy=True)
        self.assertAlmostEqual(
            float(np.abs(hot.weights[pos]).mean()) / rl._base_means["sens"],
            1.0, delta=0.05)
        mild = _make()
        mild.weights[pos] *= 0.3
        before = mild.weights.copy()
        rl.pin_gains(mild, legacy=True)
        np.testing.assert_array_equal(mild.weights, before)
        # Current stack keeps full bands (mild suppression still pinned).
        mild2 = _make()
        mild2.weights[pos] *= 0.3
        rl.pin_gains(mild2)
        self.assertAlmostEqual(
            float(np.abs(mild2.weights[pos]).mean()) / rl._base_means["sens"],
            1.0, delta=0.05)

    def test_depression_floor_guard(self):
        # Repeated depression must stall at the floor instead of grinding
        # a pool to numerical zero (the dead-channel pathology): 60x 0.9
        # would reach 0.002x unguarded; the guard holds ~10%+ while
        # potentiation below the floor still applies.
        rl, _make, pos, sens = self._fake_rig()
        base = rl._base_means["sens"]
        b = _make()
        for _ in range(60):
            rl._scale_outgoing(b, sens, 0.9)
        ratio = float(np.abs(b.weights[pos]).mean()) / base
        self.assertGreaterEqual(ratio, 0.09)
        self.assertLess(ratio, 1.0)
        # Potentiation from below the floor is never blocked.
        b2 = _make()
        b2.weights[pos] *= 0.05
        before = float(np.abs(b2.weights[pos]).mean())
        rl._scale_outgoing(b2, sens, 1.1)
        self.assertGreater(float(np.abs(b2.weights[pos]).mean()), before)
        # No reference (base=None): guard off, legacy scaling unchanged.
        from dopamine_learning import DopamineReinforcement as RL
        rl_nb = RL.__new__(RL)
        import copy
        rl_nb.__dict__.update(copy.deepcopy(rl.__dict__))
        rl_nb._base_means = None
        b3 = _make()
        for _ in range(60):
            rl_nb._scale_outgoing(b3, sens, 0.9)
        self.assertLess(
            float(np.abs(b3.weights[pos]).mean()) / base, 0.01)

    def test_phantom_scheme_rejected(self):
        # Audit: every name in KNOWN_MAPPINGS must have an implementation
        # (encoder, decoder, or plasticity branch). 'retinal' had none and
        # was silently accepted as base, so it was removed; unknown names
        # must keep raising instead of degrading silently.
        from sensory_motor import KNOWN_MAPPINGS, normalize_mapping
        self.assertNotIn("retinal", KNOWN_MAPPINGS)
        with self.assertRaises(ValueError):
            normalize_mapping("retinal")
        with self.assertRaises(ValueError):
            normalize_mapping("nope")

    def test_explicit_mapping_graduates_record(self):
        # An old (mapping-less) brain trained with an explicit mapping
        # joins the current regime: the record is stamped and the run is
        # not legacy. Without one it stays legacy.
        import train_job
        rec = {"id": "grad", "training": {"episodes": 0, "sessions": []},
               "generator_params": {"seed": 1}}
        captured = {}

        def fake_run_training(**kw):
            captured.update(kw)
            return ("p", np.zeros(4, dtype=np.float32), {})
        real = train_job.run_training
        train_job.run_training = fake_run_training
        try:
            train_job.train_brain(rec, np.zeros(4, dtype=np.float32), 1,
                                  {"mapping": ["mbon"]}, save=False)
            self.assertEqual(rec["generator_params"]["mapping"], ["mbon"])
            self.assertFalse(captured.get("legacy", True))
            rec2 = {"id": "stay", "training": {"episodes": 0, "sessions": []},
                    "generator_params": {"seed": 1}}
            captured.clear()
            train_job.train_brain(rec2, np.zeros(4, dtype=np.float32), 1,
                                  {}, save=False)
            self.assertNotIn("mapping", rec2["generator_params"])
            self.assertTrue(captured.get("legacy", False))
        finally:
            train_job.run_training = real

    def test_codec_binding_regimes(self):
        import brain_server as bs
        cache = {}
        enc_l, dec_l = bs._bind_codecs(
            {"name": "Old", "generator_params": {"seed": 1}},
            self.pops, cache)
        self.assertTrue(enc_l.legacy)
        self.assertTrue(dec_l.legacy)
        enc_c, dec_c = bs._bind_codecs(
            {"name": "New", "generator_params": {"mapping": None}},
            self.pops, cache)
        self.assertFalse(enc_c.legacy)
        self.assertFalse(dec_c.legacy)
        # Distinct cache entries: legacy and current never share codecs.
        self.assertIsNot(enc_l, enc_c)
        self.assertIsNot(dec_l, dec_c)


class TestExternalMapping(unittest.TestCase):
    """Validates the mapped pools against the raw MaleCNS annotation and
    neurotransmitter tables (the FlyWire-pipeline ground truth) plus
    published counts: 1314 descending_neuron superclass rows (MANC paper:
    1328 DNs), 97 MBONs with full NT coverage, bilateral DN pairs."""
    @classmethod
    def setUpClass(cls):
        import pandas as pd
        from connectome_loader import (_retained_annotations, _body_side,
                                       _nt_sign_map)
        cls.ann = pd.read_feather(os.path.join(
            PROJECT_ROOT, "connectome_data", "malecns_v1", "annotations.feather"))
        cls.ntm = _nt_sign_map()
        cls.pops = load_or_extract_populations()
        cls.df = _retained_annotations()
        cls.sides = _body_side(cls.df)
        cls.body_ids = cls.df["bodyId"].values.astype(np.int64)
        cls.id2i = {int(b): int(i) for i, b in enumerate(cls.body_ids)}
        cls.types = cls.df["type"].astype(str)

    def _member_types(self, pool):
        idx2body = dict(zip(range(len(self.body_ids)), self.body_ids))
        return [str(self.df["type"].iloc[i]) for i in pool["all"]]

    def test_dn_counts_vs_literature(self):
        dn = self.df[self.df["superclass"] == "descending_neuron"]
        self.assertEqual(len(dn), 1314)
        self.assertEqual(set(self.pops["descending_all"]["all"]),
                         set(dn.index.tolist()))
        n = len(self.pops["descending_all"]["all"])
        self.assertGreaterEqual(n, 1300)
        self.assertLessEqual(n, 1340)
        parts = (len(self.pops["descending_all"]["left"])
                 + len(self.pops["descending_all"]["right"]))
        self.assertLessEqual(parts, n)

    def test_pool_type_purity(self):
        # Every pool member must carry the annotated family it claims.
        expect = {
            "pheromone_da1": {"ORN_DA1"},
            "pheromone_va1v": {"ORN_VA1v"},
            "visual_lc4": {"LC4"},
            "visual_lplc2": {"LPLC2"},
            "motor_thrust_dnp09": {"DNp09"},
            "motor_turn_dnp20": {"DNp20"},
            "motor_giant_fiber": {"DNp01"},
            "motor_ram_dnpe017": {"DNpe017"},
        }
        for pool_name, allowed in expect.items():
            with self.subTest(pool=pool_name):
                got = set(self._member_types(self.pops[pool_name]))
                self.assertTrue(got, f"{pool_name} is empty")
                self.assertEqual(got, allowed, f"{pool_name} contaminated: {got - allowed}")
        # LC10 subtypes share the prefix; thrust/steer/JO/VS/HS/PAM/PPL1
        # families share theirs (anchored regexes in the loader).
        for pool_name, prefix in [("visual_lc10", "LC10"),
                                  ("motor_flight_thrust", ("DLMn", "DVMn")),
                                  ("motor_steer", ("MNad",)),
                                  ("gyro_jo", ("JO",)),
                                  ("flow_vs", ("VS",)),
                                  ("flow_hs", ("HS",)),
                                  ("dopamine_pam", ("PAM",)),
                                  ("dopamine_ppl1", ("PPL1",)),
                                  ("mbon", ("MBON",))]:
            with self.subTest(pool=pool_name):
                got = set(self._member_types(self.pops[pool_name]))
                self.assertTrue(got)
                fams = (prefix,) if isinstance(prefix, str) else tuple(prefix)
                bad = [t for t in got
                       if not any(t.startswith(f) for f in fams)]
                self.assertEqual(bad, [], f"{pool_name} has {bad}")
        # Kenyon cells come from the class column, not type names.
        kc = self.df[self.df["class"] == "Kenyon_Cell"].index.tolist()
        self.assertEqual(set(kc), set(self.pops["mushroom_body_kc"]))
        self.assertEqual(len(kc), 4064)

    def test_lc4_exact_not_substring(self):
        # Regression: substring "LC4" matched LC40/41/43/44/46b + LPLC4
        # (173 non-loom cells). The rival-loom channel is true LC4 only.
        self.assertEqual(len(self.pops["visual_lc4"]["all"]), 126)

    def test_da1_asymmetry_is_real(self):
        # 51L/105R/48-unknown comes from instance suffixes in the table
        # (somaSide is empty on ORNs), not from a mapping bug.
        da1 = self.ann[self.ann["type"].astype(str).eq("ORN_DA1")]
        suf = da1["instance"].astype(str)
        l = int(suf.str.endswith("_L").sum())
        r = int(suf.str.endswith("_R").sum())
        self.assertEqual((l, r, len(da1) - l - r), (51, 105, 48))

    def test_mbon_valence_matches_nt_table(self):
        bodies = [int(b) for b in self.df["bodyId"].iloc[self.pops["mbon"]["all"]]]
        self.assertEqual(len(bodies), 97)
        for b in bodies:
            self.assertIn(b, self.ntm)
        app = {int(b) for b in self.df["bodyId"].iloc[self.pops["mbon_app"]["all"]]}
        avv = {int(b) for b in self.df["bodyId"].iloc[self.pops["mbon_av"]["all"]]}
        self.assertEqual(app | avv, set(bodies))
        self.assertEqual(app & avv, set())
        for b in app:
            self.assertGreater(self.ntm[b], 0.0)
        for b in avv:
            self.assertLess(self.ntm[b], 0.0)

    def test_dn_bilateral_pairs(self):
        # The named steering/thrust/escape DNs are single bilateral pairs.
        for pool_name in ("motor_thrust_dnp09", "motor_turn_dnp20",
                          "motor_giant_fiber", "motor_ram_dnpe017"):
            with self.subTest(pool=pool_name):
                p = self.pops[pool_name]
                self.assertEqual(len(p["all"]), 2)
                self.assertEqual(len(p["left"]) + len(p["right"]), 2)

    def test_vs_documented_split(self):
        self.assertEqual((len(self.pops["flow_vs"]["left"]),
                          len(self.pops["flow_vs"]["right"])), (16, 18))

    def test_lplc2_dn_ipsilateral_base(self):
        # Justification for the contralateral experiment, measured on the
        # product CSR: base LPLC2->DN wiring must be overwhelmingly
        # ipsilateral (raw-table audit: 24499 vs 20 by weight).
        csr = load_or_build_csr()
        indptr = np.asarray(csr.indptr)
        indices = np.asarray(csr.indices)
        data = np.asarray(csr.data, dtype=np.float64)
        dn_l = set(self.pops["descending_all"]["left"])
        dn_r = set(self.pops["descending_all"]["right"])
        w_ipsi = w_contra = 0.0
        for side, pool, same in (("left", self.pops["visual_lplc2"]["left"], dn_l),
                                 ("right", self.pops["visual_lplc2"]["right"], dn_r)):
            other = dn_r if side == "left" else dn_l
            for pre in pool:
                s, e = int(indptr[pre]), int(indptr[pre + 1])
                if e <= s:
                    continue
                row_idx = indices[s:e]
                row_w = np.abs(data[s:e])
                is_same = np.isin(row_idx, list(same))
                is_other = np.isin(row_idx, list(other))
                w_ipsi += float(row_w[is_same].sum())
                w_contra += float(row_w[is_other].sum())
        self.assertGreater(w_ipsi, 100.0 * max(w_contra, 1e-9))


class TestWiringGeneric(unittest.TestCase):
    """Every registered experiment must satisfy the wiring contract, not
    just lplc2_contra_dn: deterministic, shaped, suffixed, pass-through
    on empty, with injected edges provably present in the product."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_each_experiment_deterministic_and_shaped(self):
        from experimental_wiring import EXPERIMENTS
        self.assertIn("lplc2_contra_dn", EXPERIMENTS)
        for name, fn in EXPERIMENTS.items():
            with self.subTest(experiment=name):
                a = fn(self.pops)
                b = fn(self.pops)
                for x, y in zip(a, b):
                    np.testing.assert_array_equal(x, y)
                pre, post, w = a
                self.assertEqual(len(pre), len(post))
                self.assertEqual(len(pre), len(w))
                self.assertTrue((w > 0).all())
                self.assertTrue(((pre >= 0) & (pre < 166700)).all())
                self.assertTrue(((post >= 0) & (post < 166700)).all())

    def test_suffix_and_empty_variants(self):
        from experimental_wiring import experiment_suffix, experiment_arrays
        self.assertEqual(experiment_suffix(None), "")
        self.assertEqual(experiment_suffix(""), "")
        self.assertEqual(experiment_suffix("none"), "")
        self.assertEqual(experiment_suffix("lplc2_contra_dn"),
                         "__exp_lplc2_contra_dn")
        for empty in ("", "none"):
            indptr, indices, data = experiment_arrays(
                empty, self.csr, self.pops)
            np.testing.assert_array_equal(indptr, self.csr.indptr)
            np.testing.assert_array_equal(indices, self.csr.indices)
            np.testing.assert_array_equal(data, self.csr.data)

    def test_overlay_passthrough(self):
        from experimental_wiring import apply_overlay
        indptr, indices, data = apply_overlay(self.csr, None, None, None)
        np.testing.assert_array_equal(indptr, self.csr.indptr)
        np.testing.assert_array_equal(indices, self.csr.indices)
        np.testing.assert_array_equal(data, self.csr.data)

    def test_injected_edges_present(self):
        # Stronger than arity ranges: sampled injected (pre, post) pairs
        # must exist as edges in the built product.
        from experimental_wiring import EXPERIMENTS, experiment_arrays
        for name, fn in EXPERIMENTS.items():
            with self.subTest(experiment=name):
                pre, post, _w = fn(self.pops)
                indptr, indices, _data = experiment_arrays(
                    name, self.csr, self.pops)
                indptr = np.asarray(indptr)
                indices = np.asarray(indices)
                step = max(len(pre) // 50, 1)
                checked = 0
                for s, q in zip(pre[::step], post[::step]):
                    row = indices[indptr[int(s)]:indptr[int(s) + 1]]
                    self.assertIn(int(q), set(row.tolist()))
                    checked += 1
                self.assertGreater(checked, 0)


class TestWiringMixes(unittest.TestCase):
    """Additive wiring mixes: normalization, filename-safe suffixes,
    order-independent determinism, edge-union integrity, and priority
    conflict resolution."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_normalize_experiment(self):
        from experimental_wiring import normalize_experiment, EXPERIMENTS
        self.assertIsNone(normalize_experiment(None))
        self.assertIsNone(normalize_experiment(""))
        self.assertIsNone(normalize_experiment("none"))
        self.assertIsNone(normalize_experiment("base"))
        self.assertIsNone(normalize_experiment([]))
        self.assertEqual(normalize_experiment("spear_lunge"), ("spear_lunge",))
        self.assertEqual(normalize_experiment(["spear_lunge", "retina_wide"]),
                         ("retina_wide", "spear_lunge"))
        self.assertEqual(normalize_experiment("spear_lunge+retina_wide"),
                         ("retina_wide", "spear_lunge"))
        self.assertEqual(normalize_experiment("retina_wide,spear_lunge"),
                         ("retina_wide", "spear_lunge"))
        self.assertEqual(normalize_experiment(["base", "spear_lunge"]),
                         ("spear_lunge",))
        with self.assertRaises(ValueError):
            normalize_experiment("not_a_real_wiring")
        with self.assertRaises(ValueError):
            normalize_experiment(["spear_lunge", "bogus"])
        for name in EXPERIMENTS:
            self.assertIn(name, normalize_experiment(name))

    def test_mix_suffix_filename_safe(self):
        from experimental_wiring import experiment_suffix
        self.assertEqual(experiment_suffix(None), "")
        self.assertEqual(experiment_suffix("spear_lunge"), "__exp_spear_lunge")
        self.assertEqual(
            experiment_suffix(["spear_lunge", "retina_wide"]),
            "__exp_retina_wide__spear_lunge")
        self.assertEqual(
            experiment_suffix("spear_lunge+retina_wide"),
            "__exp_retina_wide__spear_lunge")
        for bad in (" ", "/", "\\", ":"):
            self.assertNotIn(bad, experiment_suffix(
                ["lplc2_contra_dn", "retina_wide", "spear_lunge"]))

    def test_mix_order_independent(self):
        from experimental_wiring import experiment_arrays
        a = experiment_arrays(["spear_lunge", "retina_wide"],
                              self.csr, self.pops)
        b = experiment_arrays(["retina_wide", "spear_lunge"],
                              self.csr, self.pops)
        c = experiment_arrays("spear_lunge+retina_wide",
                              self.csr, self.pops)
        for x, y in zip(a, b):
            np.testing.assert_array_equal(x, y)
        for x, y in zip(a, c):
            np.testing.assert_array_equal(x, y)

    def test_mix_contains_each_wiring_edges(self):
        from experimental_wiring import EXPERIMENTS, experiment_arrays
        mix = ["lplc2_contra_dn", "retina_wide", "spear_lunge"]
        indptr, indices, _data = experiment_arrays(mix, self.csr, self.pops)
        indptr = np.asarray(indptr)
        indices = np.asarray(indices)
        for name in mix:
            with self.subTest(wiring=name):
                pre, post, _w = EXPERIMENTS[name](self.pops)
                step = max(len(pre) // 20, 1)
                checked = 0
                for s, q in zip(pre[::step], post[::step]):
                    row = indices[indptr[int(s)]:indptr[int(s) + 1]]
                    self.assertIn(int(q), set(row.tolist()))
                    checked += 1
                self.assertGreater(checked, 0)

    def test_priority_override_and_conflict(self):
        # Synthetic registry entries (restored afterwards): identical
        # edges dedup, differing weights resolve by priority, equal
        # priority raises a hard conflict.
        import experimental_wiring as ew
        saved_exp = dict(ew.EXPERIMENTS)
        saved_prio = dict(ew.WIRING_PRIORITY)
        try:
            ew.EXPERIMENTS["zz_low"] = lambda pops: (
                np.array([1, 2], dtype=np.int32),
                np.array([3, 4], dtype=np.int32),
                np.array([100.0, 100.0], dtype=np.float32))
            ew.EXPERIMENTS["zz_high"] = lambda pops: (
                np.array([1, 5], dtype=np.int32),
                np.array([3, 6], dtype=np.int32),
                np.array([200.0, 200.0], dtype=np.float32))
            ew.WIRING_PRIORITY["zz_low"] = 5
            ew.WIRING_PRIORITY["zz_high"] = 50
            pre, post, w = ew.combine_overlays(
                ("zz_high", "zz_low"), self.pops)
            got = {(int(s), int(q)): float(v)
                   for s, q, v in zip(pre, post, w)}
            # Shared edge (1,3): higher priority wins, kept once.
            self.assertEqual(got[(1, 3)], 200.0)
            self.assertEqual(got[(2, 4)], 100.0)
            self.assertEqual(got[(5, 6)], 200.0)
            self.assertEqual(len(got), 3)
            # Equal priority on a differing edge: hard reject.
            ew.WIRING_PRIORITY["zz_high"] = 5
            with self.assertRaises(ValueError):
                ew.combine_overlays(("zz_high", "zz_low"), self.pops)
        finally:
            ew.EXPERIMENTS.clear()
            ew.EXPERIMENTS.update(saved_exp)
            ew.WIRING_PRIORITY.clear()
            ew.WIRING_PRIORITY.update(saved_prio)


class TestWiringGenome(unittest.TestCase):
    """Genome layer: frozen legacy byte-identity, deterministic random
    generation under role constraints, validation rejects, stable ids.
    Pops-only (no CSR) so it runs without the connectome cache."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def test_frozen_byte_identity(self):
        # Frozen genomes must reproduce the historical overlays exactly
        # (pre-refactor hashes in tests/fixtures/frozen_genome_hashes.json).
        import hashlib
        import json
        import os
        import experimental_wiring as ew
        fix_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "fixtures", "frozen_genome_hashes.json")
        with open(fix_path) as f:
            fix = json.load(f)
        for name in ("lplc2_contra_dn", "retina_wide", "spear_lunge"):
            with self.subTest(wiring=name):
                pre, post, w = ew.EXPERIMENTS[name](self.pops)
                self.assertEqual(len(pre), fix[name]["n_edges"])
                h = hashlib.sha256()
                h.update(pre.tobytes())
                h.update(post.tobytes())
                h.update(w.tobytes())
                self.assertEqual(h.hexdigest(), fix[name]["sha256"])
                # Frozen rules compile to the same bytes directly.
                cpre, cpost, cw = ew.compile_genome(
                    ew.FROZEN_GENOMES[name], self.pops)
                np.testing.assert_array_equal(pre, cpre)
                np.testing.assert_array_equal(post, cpost)
                np.testing.assert_array_equal(w, cw)

    def test_generate_deterministic(self):
        import numpy as np
        import experimental_wiring as ew
        a = ew.generate_genome(np.random.default_rng(11), self.pops, 4)
        b = ew.generate_genome(np.random.default_rng(11), self.pops, 4)
        self.assertEqual(a, b)
        c = ew.generate_genome(np.random.default_rng(12), self.pops, 4)
        self.assertNotEqual(a, c)
        self.assertEqual(len(a["rules"]), 4)

    def test_generate_roles(self):
        import numpy as np
        import experimental_wiring as ew
        reg = ew.build_pool_registry(self.pops)
        for seed in range(200):
            g = ew.generate_genome(
                np.random.default_rng(seed), self.pops, 3)
            self.assertEqual(len(g["rules"]), 3)
            for r in g["rules"]:
                self.assertEqual(reg[r["source"]]["role"], "sensory")
                self.assertIn(reg[r["target"]]["role"], ("motor", "central"))
                self.assertIn(r["source_side"], ("left", "right"))
                self.assertIn(r["target_side"], ("left", "right"))
                self.assertIn(r["sign"], (1.0, -1.0))
                self.assertTrue(0.0 < r["weight"] <= 2000.0)
                self.assertTrue(1 <= r["fanout"] <= 64)

    def test_validator_rejects(self):
        import experimental_wiring as ew
        good = dict(ew.FROZEN_GENOMES["lplc2_contra_dn"]["rules"][0])
        ew.validate_rule(good)  # frozen rules are valid
        bad_variants = []
        for k in ("source", "sign", "stream_seed"):
            v = dict(good)
            del v[k]
            bad_variants.append(v)
        for kw in ({"source_side": "up"}, {"target_side": "down"},
                   {"sign": 0.0}, {"sign": 2.0},
                   {"weight": 0.0}, {"weight": -5.0}, {"weight": 99999.0},
                   {"fanout": 0}, {"fanout": -2}, {"fanout": True},
                   {"fanout": 999}, {"topography": "retinotopic"},
                   {"stream": ""}, {"stream_seed": -1}):
            vv = dict(good)
            vv.update(kw)
            bad_variants.append(vv)
        for bad in bad_variants:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    ew.validate_rule(bad)
        with self.assertRaises(ValueError):
            ew.validate_genome({"name": "x", "rules": []})
        with self.assertRaises(ValueError):
            ew.validate_genome({"name": "x",
                                "rules": [good, dict(good)]})
        # Unknown pools pass shape validation but fail with pops given.
        v = dict(good, source="no_such_pool_xyz")
        ew.validate_rule(v)
        with self.assertRaises(ValueError):
            ew.validate_genome({"name": "x", "rules": [v]}, self.pops)
        ew.validate_genome({"name": "x", "rules": [good]}, self.pops)
        with self.assertRaises(ValueError):
            ew.generate_genome(np.random.default_rng(3), self.pops, 0)

    def test_derive_mapping(self):
        import experimental_wiring as ew
        # Frozen genomes derive their historical pairings (retina_wide
        # wiring <-> retina mapping; spear's LC sources read retina too,
        # matching historical usage - the mouth readout is always on).
        self.assertEqual(
            ew.derive_mapping(ew.FROZEN_GENOMES["retina_wide"]),
            ("retina",))
        self.assertEqual(
            ew.derive_mapping(ew.FROZEN_GENOMES["spear_lunge"]),
            ("retina",))
        t4rule = {"source": "visual_t4a", "source_side": "left",
                  "target": "descending_all", "target_side": "left",
                  "sign": 1.0, "weight": 100.0, "fanout": 4,
                  "topography": "random", "stream": "t", "stream_seed": 1}
        self.assertEqual(
            ew.derive_mapping({"name": None, "rules": [t4rule]}),
            ("flow_trans",))
        mnrule = dict(t4rule, source="visual_lc11", target="motor_steer",
                      target_side="right", stream="u")
        self.assertEqual(
            ew.derive_mapping({"name": None, "rules": [t4rule, mnrule]}),
            ("flow_trans", "muscles_up", "retina"))
        # Scent pools have no scheme: DA1 wiring derives base ().
        da1 = dict(t4rule, source="pheromone_da1", stream="v")
        self.assertEqual(
            ew.derive_mapping({"name": None, "rules": [da1]}), ())
        # Generated genomes always derive a valid (possibly base) stack.
        import numpy as np
        from sensory_motor import normalize_mapping
        for seed in range(30):
            g = ew.generate_genome(
                np.random.default_rng(seed), self.pops, 3)
            normalize_mapping(list(ew.derive_mapping(g)))

    def test_mutate_genome(self):
        import numpy as np
        import experimental_wiring as ew
        base = ew.generate_genome(np.random.default_rng(31), self.pops, 3)
        a = ew.mutate_genome(np.random.default_rng(7), base, self.pops, 1)
        b = ew.mutate_genome(np.random.default_rng(7), base, self.pops, 1)
        self.assertEqual(a, b)
        self.assertGreaterEqual(len(a["rules"]), 1)
        # Input untouched by mutation.
        self.assertEqual(len(base["rules"]), 3)
        # max_changes bounds the edit count (rule-list diff).
        for seed in range(20):
            m = ew.mutate_genome(
                np.random.default_rng(seed), base, self.pops, 1)
            diff = sum(1 for r in m["rules"]
                       if r not in base["rules"]) + sum(
                           1 for r in base["rules"] if r not in m["rules"])
            self.assertLessEqual(diff, 3)
        with self.assertRaises(ValueError):
            ew.mutate_genome(np.random.default_rng(0), base, self.pops, 0)

    def test_remap_weights(self):
        import numpy as np
        import experimental_wiring as ew
        base = ew.generate_genome(np.random.default_rng(41), self.pops, 2)
        be = ew.compile_genome(base, self.pops)
        n = len(be[0])
        old_w = np.arange(n, dtype=np.float32)
        # Identity remap preserves every weight.
        same = ew.remap_weights(be, be, old_w,
                                np.random.default_rng(1))
        np.testing.assert_array_equal(same, old_w)
        # Mutated child: survivors keep weights, fresh init is finite
        # and nonzero-scaled, aligned to the child arity.
        child = ew.mutate_genome(
            np.random.default_rng(9), base, self.pops, 2)
        ce = ew.compile_genome(child, self.pops)
        new_w = ew.remap_weights(be, ce, old_w,
                                 np.random.default_rng(2))
        self.assertEqual(len(new_w), len(ce[0]))
        self.assertTrue(bool(np.all(np.isfinite(new_w))))
        old_map = {(int(s), int(q)): float(v) for s, q, v in
                   zip(be[0].tolist(), be[1].tolist(), be[2].tolist())}
        for i, (s, q) in enumerate(zip(ce[0].tolist(), ce[1].tolist())):
            if (int(s), int(q)) in old_map:
                self.assertAlmostEqual(float(new_w[i]),
                                       old_map[(int(s), int(q))])
        # Full pipeline entry point (legacy-mix parent included).
        re_mix = ew.combine_overlays(("retina_wide",), self.pops)
        old_w2 = np.arange(len(re_mix[0]), dtype=np.float32)
        rw = ew.remap_for_genome("retina_wide", None, child, old_w2,
                                 np.random.default_rng(3), self.pops)
        self.assertEqual(len(rw), len(ce[0]))
        # Arity mismatch is loud, never silent.
        with self.assertRaises(ValueError):
            ew.remap_for_genome("retina_wide", None, child, old_w,
                                np.random.default_rng(3), self.pops)

    def test_genome_from_seed_and_attach(self):
        import experimental_wiring as ew
        a = ew.genome_from_seed(77, 3)
        b = ew.genome_from_seed(77, 3)
        self.assertEqual(a, b)
        self.assertEqual(len(a["rules"]), 3)
        ew.validate_genome(a, self.pops)
        params = {}
        ew.attach_genome(params, a)
        self.assertEqual(params["genome"], a)
        self.assertEqual(params["genome_id"], ew.genome_label(a))

    def test_derive_mapping_cli(self):
        import io
        import json
        import types
        from contextlib import redirect_stdout
        import vault_cli
        ns = types.SimpleNamespace(genome="", genome_seed=42,
                                   genome_rules=3, result_file="")
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = vault_cli.cmd_derive_mapping(ns)
        self.assertEqual(code, 0)
        payload = json.loads(buf.getvalue().strip().splitlines()[-1])
        self.assertTrue(payload.get("ok", False))
        self.assertEqual(payload["genome_id"], "0e5f52b8c9")
        self.assertEqual(payload["mapping"], ["muscles_up"])
        self.assertEqual(payload["n_rules"], 3)

    def test_genome_id_stable(self):
        import numpy as np
        import experimental_wiring as ew
        a = ew.generate_genome(np.random.default_rng(21), self.pops, 3)
        b = ew.generate_genome(np.random.default_rng(21), self.pops, 3)
        self.assertEqual(ew.genome_id(a), ew.genome_id(b))
        self.assertEqual(ew.genome_label(a), "g" + ew.genome_id(a))
        renamed = dict(a, name="whatever")
        self.assertEqual(ew.genome_id(renamed), ew.genome_id(a))
        c = ew.generate_genome(np.random.default_rng(22), self.pops, 3)
        self.assertNotEqual(ew.genome_id(a), ew.genome_id(c))
        self.assertRegex(ew.genome_label(a), r"^g[0-9a-f]{10}$")


class TestWiringAttribution(unittest.TestCase):
    """Attribution miner on synthetic brackets: outcome extraction,
    vault-meta join, exactly-one-side scoring (no files, no CSR)."""
    def _rec(self, bid, genome=None, experiment=None, mapping=None):
        gp = {"experiment": experiment, "genome": genome,
              "mapping": mapping}
        return {"id": bid, "generator_params": gp}

    def _tourney(self, matches):
        # matches: [(a, b, winner)] -> rounds-shaped dict.
        return {"rounds": [[{"a_id": a, "b_id": b, "winner_id": w}
                            for a, b, w in matches]]}

    def test_outcomes_skip_junk(self):
        import mine_wiring_fitness as mw
        t = {"rounds": [[
            {"a_id": "a", "b_id": "b", "winner_id": "a"},
            {"a_id": "c", "b_id": "", "winner_id": "c", "bye": True},
            {"a_id": "", "b_id": "", "winner_id": "", "vacant": True},
            {"a_id": "d", "b_id": "e", "winner_id": ""},
        ]]}
        self.assertEqual(mw.match_outcomes(t), [("a", "b")])

    def test_pool_lift(self):
        import mine_wiring_fitness as mw
        import experimental_wiring as ew
        retina = ew.FROZEN_GENOMES["retina_wide"]
        base_rec = self._rec("base1")
        ret_rec = self._rec("ret1", genome=dict(retina))
        metas = {"base1": mw.brain_meta(base_rec),
                 "ret1": mw.brain_meta(ret_rec)}
        self.assertIn("visual_lc11", metas["ret1"]["pools"])
        self.assertEqual(metas["base1"]["pools"], set())
        # Retina brain beats base 3-1: pool lift must be positive.
        outcomes = [("ret1", "base1")] * 3 + [("base1", "ret1")]
        stats = mw.tally(outcomes, metas)
        self.assertEqual(stats["matches"], 4)
        w, n = stats["pools"]["visual_lc11"]
        self.assertEqual((w, n), (3, 4))
        # Mirror matches (both touch) never score.
        stats2 = mw.tally([("ret1", "ret1")], metas)
        self.assertEqual(stats2["matches"], 1)
        self.assertNotIn("visual_lc11", stats2["pools"])
        # Unknown brains are skipped, not crashed on.
        stats3 = mw.tally([("ghost", "base1")], metas)
        self.assertEqual(stats3["matches"], 0)

    def test_mapping_and_rules(self):
        import mine_wiring_fitness as mw
        m1 = self._rec("m1", mapping=["retina"])
        m2 = self._rec("m2", mapping=None)
        metas = {"m1": mw.brain_meta(m1), "m2": mw.brain_meta(m2)}
        self.assertEqual(metas["m1"]["mapping"], ("retina",))
        self.assertEqual(metas["m2"]["mapping"], ())
        stats = mw.tally([("m1", "m2"), ("m1", "m2"), ("m2", "m1")], metas)
        w, n = stats["mappings"][("retina",)]
        self.assertEqual((w, n), (2, 3))
        self.assertAlmostEqual(stats["rules_winners"], 0.0)
        rep = mw.report(stats, min_n=1)
        self.assertIn("retina", rep)
        self.assertIn("scored matches: 3", rep)


class TestGenomeNovelty(unittest.TestCase):
    """Frequency-dependent genome fitness: pool extraction, bonus math
    and caps, persistence, kill-dominance. CSR-free (tmp checkpoint dir)."""
    def _mgr(self):
        import tempfile
        from evolution_engine import EvolutionManager
        return EvolutionManager(
            checkpoints_dir=tempfile.mkdtemp(prefix="evo_nov_"))

    def _rec(self, genome=None, experiment=None):
        return {"id": "x", "generator_params": {"genome": genome,
                                                "experiment": experiment}}

    def test_wiring_pools(self):
        import experimental_wiring as ew
        from evolution_engine import EvolutionManager
        mgr = self._mgr()
        g = {"name": None, "rules": [dict(
            ew.FROZEN_GENOMES["retina_wide"]["rules"][0])]}
        pools = mgr.wiring_pools(self._rec(genome=g))
        self.assertIn("visual_lc11", pools)
        self.assertIn("descending_all", pools)
        mix_pools = mgr.wiring_pools(self._rec(experiment="retina_wide"))
        self.assertTrue(pools < mix_pools)
        self.assertIn("visual_lc15", mix_pools)
        self.assertEqual(mgr.wiring_pools(self._rec()), set())
        self.assertEqual(mgr.wiring_pools({"genome": g}), pools)

    def test_novelty_bonus_and_cap(self):
        from evolution_engine import EvolutionManager
        mgr = self._mgr()
        self.assertEqual(mgr.genome_novelty_bonus(set()), 0.0)
        fresh = mgr.genome_novelty_bonus({"a", "b", "c"})
        self.assertEqual(fresh, 3 * mgr.NOVELTY_PER_POOL)
        many = mgr.genome_novelty_bonus({f"p{i}" for i in range(50)})
        self.assertEqual(many, mgr.NOVELTY_CAP)
        mgr.pool_counts = {"a": 99}
        self.assertEqual(mgr.genome_novelty_bonus({"a", "b"}),
                         mgr.NOVELTY_PER_POOL)

    def test_evaluate_match_novelty(self):
        from evolution_engine import EvolutionManager
        mgr = self._mgr()
        stats = {"kills": 0, "damage_dealt": 10.0, "damage_taken": 10.0,
                 "tracking_time_s": 5.0, "tail_time_s": 0.0,
                 "nectar_consumed": 0.0}
        w0, fa0, fb0 = mgr.evaluate_match(dict(stats), dict(stats))
        # No records: legacy behavior, no novelty keys beyond zero.
        self.assertEqual(fa0, fb0)
        import experimental_wiring as ew
        g = {"name": None, "rules": [dict(
            ew.FROZEN_GENOMES["retina_wide"]["rules"][0])]}
        ra = self._rec(genome=g)
        rb = self._rec()
        w1, fa1, fb1 = mgr.evaluate_match(dict(stats), dict(stats), ra, rb)
        self.assertEqual(w1, "alpha")
        self.assertGreater(fa1, fa0)
        self.assertEqual(fb1, fb0)
        self.assertEqual(mgr.history[-1]["novelty_beta"], 0.0)
        self.assertGreater(mgr.history[-1]["novelty_alpha"], 0.0)
        # Winner pools counted; a reloaded manager sees them (persistence).
        mgr2 = EvolutionManager(checkpoints_dir=mgr.checkpoints_dir)
        self.assertGreater(
            mgr2.pool_counts.get("visual_lc11", 0), 0)
        # Kill dominance survives novelty: a kill beats max novelty.
        killer = dict(stats, kills=1)
        w2, fk, _fb = mgr.evaluate_match(dict(killer), dict(stats), rb, ra)
        self.assertEqual(w2, "alpha")

    def test_evaluate_match_legacy_identical(self):
        from evolution_engine import EvolutionManager
        m1 = self._mgr()
        m2 = self._mgr()
        stats = {"kills": 0, "damage_dealt": 20.0, "damage_taken": 5.0,
                 "tracking_time_s": 8.0, "tail_time_s": 2.0,
                 "nectar_consumed": 0.0}
        r1 = m1.evaluate_match(dict(stats), dict(stats))
        r2 = m2.evaluate_match(dict(stats), dict(stats), None, None)
        self.assertEqual(r1, r2)


class TestStagedTraining(unittest.TestCase):
    """Two-step training: sequencer, summary merge, staging helper,
    stage-2 params (all with mocked run_training - no CSR needed)."""
    def _rec(self):
        return {"id": "staged", "training": {"episodes": 0, "sessions": []},
                "generator_params": {"seed": 1}}

    def test_train_staged_sequences(self):
        import train_job
        calls = []

        def fake_run_training(**kw):
            calls.append(kw)
            w = kw["init_weights"]
            cb = kw.get("progress_cb")
            for ep in range(1, kw["num_episodes"] + 1):
                if cb is not None:
                    cb(ep, kw["num_episodes"])
            return ("p", w + 1.0, {"episodes": kw["num_episodes"],
                                   "successes": kw["num_episodes"]})
        real = train_job.run_training
        train_job.run_training = fake_run_training
        try:
            import numpy as np
            prog = []
            rec, w, summaries = train_job.train_staged(
                self._rec(), np.zeros(3, dtype=np.float32),
                [(2, {"seed": 1}, "pre-train"),
                 (3, {"seed": 1}, "school")],
                progress_cb=lambda ep, total: prog.append((ep, total)),
                save=False)
            self.assertEqual(len(summaries), 2)
            self.assertEqual(rec["training"]["episodes"], 5)
            self.assertEqual(
                [s["notes"] for s in rec["training"]["sessions"]],
                ["pre-train", "school"])
            # Weights handed stage 1 -> stage 2 (+1 each).
            np.testing.assert_array_equal(
                w, np.full(3, 2.0, dtype=np.float32))
            # Progress rescaled to the combined total, monotonic.
            self.assertEqual(prog[-1], (5, 5))
            for (ep, total) in prog:
                self.assertEqual(total, 5)
            self.assertEqual(
                [ep for ep, _t in prog], sorted(ep for ep, _t in prog))
            merged = train_job.merge_summaries(summaries)
            self.assertEqual(merged["episodes"], 5)
            self.assertEqual(merged["successes"], 5)
            self.assertEqual(len(merged["stages"]), 2)
        finally:
            train_job.run_training = real

    def test_train_staged_stage2_failure_keeps_stage1(self):
        import train_job
        calls = []

        def fake_run_training(**kw):
            calls.append(kw)
            if len(calls) > 1:
                raise RuntimeError("school blew up")
            return ("p", kw["init_weights"],
                    {"episodes": kw["num_episodes"]})
        real = train_job.run_training
        train_job.run_training = fake_run_training
        try:
            import numpy as np
            rec = self._rec()
            with self.assertRaises(RuntimeError):
                train_job.train_staged(
                    rec, np.zeros(2, dtype=np.float32),
                    [(1, {}, "pre-train"), (1, {}, "school")], save=False)
            self.assertEqual(len(rec["training"]["sessions"]), 1)
            self.assertEqual(rec["training"]["episodes"], 1)
        finally:
            train_job.run_training = real

    def test_staged_or_single(self):
        import train_job
        import evo_breeder
        seen = []

        def fake_train_brain(record, weights, episodes, params=None,
                             progress_cb=None, notes="", save=True):
            seen.append((episodes, dict(params or {}), notes))
            return record, weights, {"episodes": episodes}
        real = train_job.train_brain
        train_job.train_brain = fake_train_brain
        try:
            import numpy as np
            rec = self._rec()
            # Single stage: one call, params untouched.
            evo_breeder._staged_or_single(
                rec, np.zeros(1), 2, {"seed": 1, "a": 1}, "n1",
                None, None, "n2", None)
            self.assertEqual(len(seen), 1)
            self.assertEqual(seen[0][0], 2)
            # Staged: stage-2 inherits unset keys, keeps its own.
            seen.clear()
            evo_breeder._staged_or_single(
                rec, np.zeros(1), 2, {"seed": 1, "a": 1}, "n1",
                3, {"b": 2}, "n2", None)
            self.assertEqual(len(seen), 2)
            self.assertEqual(seen[0][0], 2)
            self.assertEqual(seen[1][0], 3)
            self.assertEqual(seen[1][1]["b"], 2)
            self.assertEqual(seen[1][1]["a"], 1)
            self.assertEqual(seen[1][1]["seed"], 1)
        finally:
            train_job.train_brain = real

    def test_parse_params2(self):
        import types
        import vault_cli
        self.assertIsNone(vault_cli._parse_params2(types.SimpleNamespace()))
        ns = types.SimpleNamespace(params2='{"curriculum": "school"}',
                                   params2_file="")
        self.assertEqual(vault_cli._parse_params2(ns),
                         {"curriculum": "school"})
        bad = types.SimpleNamespace(params2='{oops', params2_file="")
        self.assertIn("__error", vault_cli._parse_params2(bad))


class TestFlightSchool(unittest.TestCase):
    """Advanced Flight School: anchored camps, planned paths, scheduler,
    difficulty curves (KinematicFly-level, no CSR needed)."""
    def test_anchored_target_never_moves(self):
        from train_homing import KinematicFly
        t = KinematicFly(x=5.0, y=7.0, z=-3.0, heading_rad=0.7, anchored=True)
        p0 = t.pos.copy()
        for _ in range(20):
            t.step(thrust=1.0, yaw_torque=0.9, pitch_cmd=0.5, dt=0.05)
        np.testing.assert_array_equal(t.pos, p0)
        self.assertEqual(t.last_speed, 0.0)
        f = KinematicFly(x=5.0, y=7.0, z=-3.0, heading_rad=0.7)
        f.step(thrust=1.0, yaw_torque=0.0, dt=0.05)
        self.assertGreater(float(np.linalg.norm(f.pos - p0)), 0.0)

    def test_plan_path_properties(self):
        import numpy as np
        from train_homing import plan_path
        for arch in ("patrol", "weave", "flee", "orbit"):
            p = plan_path(np.random.default_rng(4), 4, archetype=arch)
            self.assertEqual(p["archetype"], arch)
            self.assertEqual(len(p["points"]), 4)
            for pt, sp in zip(p["points"], p["speeds"]):
                self.assertTrue(-40.0 <= pt[0] <= 40.0)
                self.assertTrue(4.0 <= pt[1] <= 14.0)
                self.assertTrue(-40.0 <= pt[2] <= 40.0)
                self.assertTrue(0.7 <= sp <= 1.0)
        a = plan_path(np.random.default_rng(4), 3)
        b = plan_path(np.random.default_rng(4), 3)
        self.assertEqual(a, b)
        c = plan_path(np.random.default_rng(5), 3)
        self.assertNotEqual(a["points"], c["points"])

    def test_step_path_target_advances(self):
        import numpy as np
        from train_homing import KinematicFly, plan_path, step_path_target
        t = KinematicFly(x=-14.0, z=0.0, heading_rad=0.0)
        path = plan_path(np.random.default_rng(9), 3)
        state = {"wp": 0}
        seen = {0}
        for _ in range(400):
            step_path_target(t, path, state, 6.0, dt=0.05)
            seen.add(int(state["wp"]))
            if len(seen) > 1:
                break
        self.assertGreater(len(seen), 1)

    def test_scheduler_coverage_and_determinism(self):
        import numpy as np
        from train_homing import (pick_school_scenario, _school_diff,
                                  SCHOOL_BEHAVIORS, SCHOOL_ENVS)
        a = pick_school_scenario(np.random.default_rng(2), 0.1, {})
        b = pick_school_scenario(np.random.default_rng(2), 0.1, {})
        self.assertEqual(a, b)
        self.assertIn(a[0], SCHOOL_BEHAVIORS)
        self.assertIn(a[1], SCHOOL_ENVS)
        kinds = set()
        for seed in range(60):
            kinds.add(pick_school_scenario(
                np.random.default_rng(seed), 0.5, {})[0])
        self.assertEqual(kinds, set(SCHOOL_BEHAVIORS))
        self.assertAlmostEqual(_school_diff(0.0, {}, "camp_dist"), 20.0)
        self.assertAlmostEqual(_school_diff(1.0, {}, "camp_dist"), 35.0)
        self.assertAlmostEqual(
            _school_diff(0.5, {"difficulty": {"camp_dist": [0.0, 10.0]}},
                         "camp_dist"), 5.0)

    def test_anchored_target_senses(self):
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly(x=-14.0, z=0.0, heading_rad=0.0)
        camp = KinematicFly(x=12.0, z=2.0, heading_rad=1.0, anchored=True)
        senses, dist = compute_agent_senses(fly, camp, prev_dist=20.0)
        self.assertGreater(dist, 20.0)
        self.assertIn("scent_lost", senses)
        self.assertIn("scent_cast", senses)
        self.assertIn("scent_surge", senses)
        self.assertGreater(senses["pheromone_conc_left"]
                           + senses["pheromone_conc_right"], 0.0)


class TestT4Recurrence(unittest.TestCase):
    """T4/T5 cannot self-sustain: saturated drive evokes exactly the
    forced set (each cell fires once, no refire), and silence follows
    stimulus removal immediately - on fresh AND 20x-potentiated
    efferents. Guards the no-seizure verdict: if T4 counts ever reach
    thousands per tick again, one of these fails first."""
    POOLS = ["visual_t4a", "visual_t4b", "visual_t4c", "visual_t4d",
             "visual_t5a", "visual_t5b", "visual_t5c", "visual_t5d"]

    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()
        cls.t4ids = set()
        for k in cls.POOLS:
            cls.t4ids.update(cls.pops[k]["all"])

    def _brain(self, potentiate=1.0):
        from lif_brain import FlyBrain
        w = np.ascontiguousarray(
            np.asarray(self.csr.data, dtype=np.float32).copy())
        if potentiate != 1.0:
            indptr = np.asarray(self.csr.indptr)
            for pre in self.t4ids:
                s, e = int(indptr[pre]), int(indptr[pre + 1])
                if e > s:
                    w[s:e] *= potentiate
        return FlyBrain(self.csr.indptr, self.csr.indices, w)

    def _hot_stim(self):
        from sensory_motor import SensoryEncoder
        enc = SensoryEncoder(self.pops, mapping="flow_trans")
        return enc.encode({"visual_flow_ventral": 1.0,
                           "visual_flow_lateral": 1.0,
                           "visual_flow_expansion": 1.0,
                           "visual_flow_climb": 1.0})

    def _t4hits(self, spikes):
        from collections import Counter
        c = Counter(int(s) for s in spikes)
        hits = sum(v for k, v in c.items() if k in self.t4ids)
        uniq = sum(1 for k in c if k in self.t4ids)
        return hits, uniq

    def test_no_refire_fresh(self):
        brain = self._brain()
        last = None
        for _ in range(5):
            last = brain.integrate_50ms(self._hot_stim())
        hits, uniq = self._t4hits(last)
        # Forced set only (<= 480 stimulus ids), each exactly once.
        self.assertLessEqual(uniq, 480)
        self.assertEqual(hits, uniq)

    def test_no_persistence(self):
        brain = self._brain()
        for _ in range(5):
            brain.integrate_50ms(self._hot_stim())
        from sensory_motor import SensoryEncoder
        enc = SensoryEncoder(self.pops, mapping="flow_trans")
        for _ in range(3):
            s = brain.integrate_50ms(enc.encode({}))
            hits, _u = self._t4hits(s)
            self.assertEqual(hits, 0)
            self.assertEqual(len(s), 0)

    def test_no_refire_potentiated(self):
        brain = self._brain(potentiate=20.0)
        last = None
        for _ in range(5):
            last = brain.integrate_50ms(self._hot_stim())
        hits, uniq = self._t4hits(last)
        self.assertEqual(hits, uniq)
        s = brain.integrate_50ms(
            SensoryEncoder(self.pops, mapping="flow_trans").encode({}))
        self.assertEqual(len(s), 0)


class TestMappingMatrix(unittest.TestCase):
    """Certifies every wiring x mapping regime: each combination must
    integrate, decode a complete finite control set, and stay isolated
    (legacy ignores split keys, mapped schemes compose). Includes the
    mirror-direction readouts the old suite only tested one-sided."""
    CTRL_KEYS = {"thrust", "yaw_torque", "pitch_torque", "roll_torque",
                 "approach_bias", "ram_burst", "emergency_evade",
                 "spear_thrust"}

    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    _MISSING = object()

    def _rec(self, experiment, mapping=None, use_mapping=False):
        gp = {}
        if experiment is not None:
            gp["experiment"] = experiment
        if use_mapping:
            gp["mapping"] = mapping
        return {"name": "Mx", "generator_params": gp}

    def _finite_ctrl(self, ctrl):
        for k in self.CTRL_KEYS:
            self.assertIn(k, ctrl)
            v = ctrl[k]
            if isinstance(v, bool):
                continue
            self.assertTrue(np.isfinite(float(v)), f"{k}={v}")

    def test_wiring_x_regime_integrate_and_decode(self):
        import brain_server as bs
        from experimental_wiring import experiment_arrays
        _pres = [0.0] * 21
        _size = [0.0] * 21
        _loom = [0.0] * 21
        _wood = [0.0] * 21
        _pres[9] = 1.0
        _size[9] = 0.4
        _loom[9] = 0.5
        _wood[11] = 0.6
        stim = {"pheromone_conc_left": 0.7, "pheromone_conc_right": 0.2,
                "visual_target_visible": True, "visual_target_azimuth": -20.0,
                "visual_rival_looming": 0.3, "visual_tree_left_looming": 0.4,
                "visual_tree_looming": 0.4, "visual_looming_rate": 0.4,
                "angular_yaw_rate": 0.5, "angular_roll_rate": -0.3,
                "angular_pitch_rate": 0.2, "visual_sec_presence": _pres,
                "visual_sec_size": _size, "visual_sec_loom": _loom,
                "visual_sec_tree": _wood}
        for exp in (None, "lplc2_contra_dn", "retina_wide", "spear_lunge"):
            indptr, indices, wbasis = experiment_arrays(
                exp, self.csr, self.pops)
            for mapping in (None, "muscles_up", "gyro_flow", "mbon",
                            ["muscles_up", "gyro_flow", "mbon"], "retina",
                            "flow_trans", ["retina", "flow_trans"]):
                with self.subTest(wiring=exp or "base", mapping=mapping):
                    rec = self._rec(exp, mapping=mapping, use_mapping=True)
                    brain = bs._bind_brain(
                        rec, np.ascontiguousarray(np.asarray(
                            wbasis, dtype=np.float32).copy()),
                        self.csr, self.pops, {})
                    enc, dec = bs._bind_codecs(rec, self.pops, {})
                    spikes = brain.integrate_50ms(enc.encode(stim))
                    self._finite_ctrl(dec.decode(spikes, sensory_hint=stim))
            with self.subTest(wiring=exp or "base", mapping="legacy"):
                rec = self._rec(exp)
                brain = bs._bind_brain(
                    rec, np.ascontiguousarray(np.asarray(
                        wbasis, dtype=np.float32).copy()),
                    self.csr, self.pops, {})
                enc, dec = bs._bind_codecs(rec, self.pops, {})
                self.assertTrue(enc.legacy)
                self.assertTrue(dec.legacy)
                spikes = brain.integrate_50ms(enc.encode(stim))
                self._finite_ctrl(dec.decode(spikes, sensory_hint=stim))

    def test_mix_integrate_and_decode(self):
        # Representative additive mix across regimes: union wiring must
        # integrate and decode a complete finite control set like singles.
        import brain_server as bs
        from experimental_wiring import experiment_arrays, experiment_suffix
        mix = ["retina_wide", "spear_lunge"]
        self.assertEqual(experiment_suffix(mix),
                         "__exp_retina_wide__spear_lunge")
        indptr, indices, wbasis = experiment_arrays(mix, self.csr, self.pops)
        stim = {"pheromone_conc_left": 0.6, "pheromone_conc_right": 0.3,
                "visual_target_visible": True, "visual_target_azimuth": 10.0,
                "visual_rival_looming": 0.4,
                "visual_sec_presence": [1.0 if i == 10 else 0.0 for i in range(21)],
                "visual_sec_size": [0.8 if i == 10 else 0.0 for i in range(21)],
                "visual_sec_loom": [0.8 if i == 10 else 0.0 for i in range(21)],
                "visual_sec_tree": [0.0] * 21}
        for mapping in (None, "retina", ["retina", "mbon"]):
            with self.subTest(mapping=mapping):
                rec = {"name": "Mx",
                       "generator_params": {"experiment": mix,
                                            "mapping": mapping}}
                brain = bs._bind_brain(
                    rec, np.ascontiguousarray(np.asarray(
                        wbasis, dtype=np.float32).copy()),
                    self.csr, self.pops, {})
                enc, dec = bs._bind_codecs(rec, self.pops, {})
                spikes = brain.integrate_50ms(enc.encode(stim))
                self._finite_ctrl(dec.decode(spikes, sensory_hint=stim))

    def test_mirror_steering(self):
        # Readout directionality, both sides (old suite: right only).
        dn_l = list(self.pops["descending_all"]["left"]) * 2
        dn_r = list(self.pops["descending_all"]["right"]) * 2
        hint = {"visual_target_visible": True, "visual_target_azimuth": 0.0}
        base = MotorDecoder(self.pops)
        y_r = base.decode(dn_r, sensory_hint=hint)["yaw_torque"]
        y_l = base.decode(dn_l, sensory_hint=hint)["yaw_torque"]
        self.assertGreater(y_r, 0.0)
        self.assertLess(y_l, 0.0)
        self.assertGreater(y_r - y_l, 0.5)
        # LC10 right mirror of the existing left test.
        enc = SensoryEncoder(self.pops)
        sp_r = set(int(s) for s in enc.encode(
            {"visual_target_visible": True, "visual_target_azimuth": 30.0}))
        self.assertGreater(len(sp_r), 0)
        for s in sp_r:
            self.assertIn(s, set(self.pops["visual_lc10"]["right"]))
        # Dead-ahead splits both sides, roughly balanced.
        sp_0 = [int(s) for s in enc.encode(
            {"visual_target_visible": True, "visual_target_azimuth": 0.0})]
        lc_l = set(self.pops["visual_lc10"]["left"])
        lc_r = set(self.pops["visual_lc10"]["right"])
        n_l = sum(1 for s in sp_0 if s in lc_l)
        n_r = sum(1 for s in sp_0 if s in lc_r)
        self.assertGreater(n_l, 0)
        self.assertGreater(n_r, 0)
        self.assertLessEqual(max(n_l, n_r) / max(min(n_l, n_r), 1), 2.0)
        # Tree-right drives LPLC2-R only.
        sp_t = set(int(s) for s in enc.encode(
            {"visual_tree_right_looming": 0.8,
             "visual_target_visible": False}))
        self.assertGreater(len(sp_t), 0)
        for s in sp_t:
            self.assertIn(s, set(self.pops["visual_lplc2"]["right"]))

    def test_mirror_gyro_muscle_flow(self):
        # JO-L on leftward spin; MN-L steers left of base; VS-L banks left.
        gyro = SensoryEncoder(self.pops, mapping="gyro_flow")
        spin_l = {"angular_yaw_rate": -0.8, "angular_pitch_rate": 0.0,
                  "angular_roll_rate": 0.0}
        sp = [int(s) for s in gyro.encode(spin_l)]
        jo_l = set(self.pops["gyro_jo"]["left"])
        self.assertGreater(len(sp), 0)
        self.assertGreater(
            sum(1 for s in sp if s in jo_l) / len(sp), 0.5)
        base = MotorDecoder(self.pops, mapping="base")
        musc = MotorDecoder(self.pops, mapping="muscles_up")
        steer_l = self.pops["motor_steer"]["left"] * 2
        self.assertLess(musc.decode(steer_l)["yaw_torque"],
                        base.decode(steer_l)["yaw_torque"])
        flow = MotorDecoder(self.pops, mapping="gyro_flow")
        vs_l = list(self.pops["flow_vs"]["left"]) * 2
        self.assertLess(flow.decode(vs_l)["roll_torque"], 0.0)
        vs_r = list(self.pops["flow_vs"]["right"]) * 2
        both = flow.decode(vs_l + vs_r)["roll_torque"]
        self.assertAlmostEqual(both, 0.0, delta=0.15)
        hs_r = list(self.pops["flow_hs"]["right"]) * 2
        self.assertGreater(flow.decode(hs_r)["roll_torque"], 0.0)

    def test_ram_threshold(self):
        dec = MotorDecoder(self.pops)
        gf_pool = list(self.pops["motor_ram_dnpe017"]["all"])
        self.assertFalse(dec.decode(gf_pool[:1])["ram_burst"])
        self.assertTrue(dec.decode(gf_pool[:2])["ram_burst"])

    def test_mixed_regime_battle_pair(self):
        # exp-vs-exp and legacy-vs-mapped pairs integrate side by side
        # with native arity and full control sets (extends the base/exp
        # coverage to every regime the bracket can pair).
        import brain_server as bs
        from experimental_wiring import experiment_arrays
        pairs = [
            ({"experiment": "lplc2_contra_dn"},
             {"experiment": "lplc2_contra_dn", "mapping": "mbon"}),
            ({}, {"mapping": ["muscles_up", "gyro_flow"]}),
        ]
        stim = {"pheromone_conc_left": 0.5, "pheromone_conc_right": 0.5,
                "visual_target_visible": True, "visual_target_azimuth": 10.0}
        for gpa, gpb in pairs:
            with self.subTest(pair=(gpa, gpb)):
                brains, ctrls = [], []
                for gp in (gpa, gpb):
                    rec = {"name": "P", "generator_params": dict(gp)}
                    exp = gp.get("experiment")
                    _ip, _ix, wb = experiment_arrays(exp, self.csr, self.pops)
                    brains.append(bs._bind_brain(
                        rec, np.ascontiguousarray(np.asarray(
                            wb, dtype=np.float32).copy()),
                        self.csr, self.pops, {}))
                    enc, dec = bs._bind_codecs(rec, self.pops, {})
                    ctrls.append((enc, dec))
                for (enc, dec), brain in zip(ctrls, brains):
                    spikes = brain.integrate_50ms(enc.encode(stim))
                    self._finite_ctrl(dec.decode(spikes, sensory_hint=stim))


class TestTrainerArenaContract(unittest.TestCase):
    """Machine-checked boundary contracts: every sensory key the arena or
    trainer emits must be consumed (or explicitly ignored), stale caches
    must degrade to zero-channels, and legacy+schemes combos stay inert."""

    # Mirror of FlyPhysics.gd get_sensory_data (update together).
    ARENA_KEYS = {"pheromone_conc_left", "pheromone_conc_right",
                  "scent_lost", "scent_cast", "scent_surge",
                  "visual_target_azimuth", "visual_target_elevation",
                  "visual_target_visible", "visual_rival_looming",
                  "visual_tree_left_looming", "visual_tree_ahead_looming",
                  "visual_tree_right_looming", "visual_tree_looming",
                  "visual_looming_rate", "altitude", "angular_yaw_rate",
                  "angular_pitch_rate", "angular_roll_rate", "tail_chase",
                  "visual_sec_presence", "visual_sec_size",
                  "visual_sec_loom", "visual_sec_tree",
                  "visual_flow_ventral", "visual_flow_lateral",
                  "visual_flow_expansion", "visual_flow_climb"}

    def test_trainer_covers_arena_keys(self):
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly()
        tgt = KinematicFly(x=10.0, z=2.0)
        senses, _ = compute_agent_senses(fly, tgt, prev_dist=15.0)
        self.assertEqual(set(senses.keys()), self.ARENA_KEYS)

    def test_encoder_consumes_both_dicts(self):
        from train_homing import KinematicFly, compute_agent_senses
        enc = SensoryEncoder(load_or_extract_populations())
        fly = KinematicFly()
        tgt = KinematicFly(x=10.0, z=2.0)
        senses, _ = compute_agent_senses(fly, tgt, prev_dist=15.0)
        self.assertTrue(set(senses.keys()) >= self.ARENA_KEYS)
        enc.encode(senses)  # must not raise
        arena_style = dict(senses)
        arena_style["visual_tree_looming"] = max(
            arena_style["visual_tree_left_looming"],
            arena_style["visual_tree_ahead_looming"],
            arena_style["visual_tree_right_looming"])
        enc.encode(arena_style)  # must not raise

    def test_controls_fully_consumed(self):
        # Every decoder control key must be consumed by the trainer's
        # arena control application (no silently dropped channels).
        from train_homing import KinematicFly, apply_arena_controls
        for key in ("thrust", "yaw_torque", "pitch_torque", "roll_torque",
                    "approach_bias", "ram_burst", "emergency_evade",
                    "spear_thrust"):
            self.assertIn(key, TestMappingMatrix.CTRL_KEYS)
        ctrl = {"thrust": 0.5, "yaw_torque": 0.2, "pitch_torque": 0.1,
                "roll_torque": 0.0, "approach_bias": 0.1,
                "ram_burst": True, "emergency_evade": False,
                "spear_thrust": 0.0}
        fly = KinematicFly()
        tgt = KinematicFly(x=10.0, z=0.0)
        from train_homing import compute_agent_senses
        senses, dist = compute_agent_senses(fly, tgt, prev_dist=15.0)
        event, aimed = apply_arena_controls(fly, ctrl, senses, dist)
        self.assertIsNone(event)
        self.assertIsInstance(aimed, bool)
        # Ram burst expresses as extra speed vs the same thrust calm.
        calm = KinematicFly()
        apply_arena_controls(
            calm, dict(ctrl, ram_burst=False), senses, dist)
        self.assertGreater(fly.last_speed, calm.last_speed)

    def test_trainer_lunge_trigger_contact_cooldown_aim(self):
        from train_homing import KinematicFly, apply_arena_controls
        frontal = {"visual_target_visible": True, "visual_target_azimuth": 5.0}
        ctrl = {"thrust": 0.4, "yaw_torque": 0.0, "pitch_torque": 0.0,
                "roll_torque": 0.0, "approach_bias": 0.0,
                "ram_burst": False, "emergency_evade": False,
                "spear_thrust": 0.6}
        # Contact range: trigger + contact on the aimed strike.
        fly = KinematicFly()
        event, aimed = apply_arena_controls(fly, ctrl, frontal, 1.5)
        self.assertTrue(aimed)
        self.assertEqual(event, "contact")
        # Cooldown: the next command cannot retrigger a fresh strike.
        self.assertGreater(fly.lunge_cooldown, 0.0)
        # Rear/unseen: never aimed, never a strike.
        for bad in ({"visual_target_visible": False,
                     "visual_target_azimuth": 170.0},
                    {"visual_target_visible": True,
                     "visual_target_azimuth": 120.0}):
            f = KinematicFly()
            event, aimed = apply_arena_controls(f, ctrl, bad, 1.5)
            self.assertFalse(aimed)
        # Below-threshold command: no launch (lunge state untouched;
        # normal thrust still steps the fly forward).
        f = KinematicFly(x=0.0, z=0.0)
        event, _ = apply_arena_controls(
            f, dict(ctrl, spear_thrust=0.2), frontal, 1.5)
        self.assertIsNone(event)
        self.assertEqual(f.lunge_t, 0.0)
        self.assertEqual(f.lunge_boost, 0.0)
        self.assertEqual(f.lunge_cooldown, 0.0)

    def test_stale_cache_fallbacks(self):
        # Missing new pools degrade to zero channels, never crash.
        thin = {
            "pheromone_da1": {"left": [1], "right": [2]},
            "pheromone_va1v": {"left": [], "right": []},
            "visual_lc10": {"left": [3], "right": [4]},
            "visual_lc4": {"left": [5], "right": [6]},
            "visual_lplc2": {"left": [7], "right": []},
            "motor_thrust_dnp09": {"all": [10]},
            "motor_turn_dnp20": {"left": [11], "right": [12]},
            "motor_giant_fiber": {"all": [13]},
            "motor_ram_dnpe017": {"all": [14]},
        }
        enc = SensoryEncoder(thin, mapping="gyro_flow")
        self.assertEqual(len(enc.encode({"angular_yaw_rate": 0.8})), 0)
        dec = MotorDecoder(thin, mapping=["muscles_up", "gyro_flow", "mbon"])
        ctrl = dec.decode([10, 11, 12])
        for k in ("thrust", "yaw_torque", "pitch_torque", "roll_torque",
                  "approach_bias"):
            self.assertIn(k, ctrl)
        self.assertEqual(ctrl["roll_torque"], 0.0)
        self.assertEqual(ctrl["approach_bias"], 0.0)

    def test_legacy_scheme_combos_inert(self):
        pops = load_or_extract_populations()
        spin = {"angular_yaw_rate": 0.8, "angular_pitch_rate": 0.0,
                "angular_roll_rate": 0.0}
        enc = SensoryEncoder(pops, mapping="gyro_flow", legacy=True)
        self.assertEqual(len(enc.encode(spin)), 0)
        app = list(pops["mbon_app"]["all"]) * 3
        dec = MotorDecoder(pops, mapping="mbon", legacy=True)
        self.assertEqual(dec.decode(app)["approach_bias"], 0.0)
        musc = MotorDecoder(pops, mapping="muscles_up", legacy=True)
        base = MotorDecoder(pops, legacy=True)
        stim = list(pops["motor_steer"]["right"]) * 2
        self.assertEqual(musc.decode(stim)["yaw_torque"],
                         base.decode(stim)["yaw_torque"])

    def test_sector_grid_consistent(self):
        # The panoramic grid: rival occupies exactly one cell with matching
        # presence/size/loom, tree rays fan all 7 columns, geometry maps
        # to the documented cell (front band, center column here).
        from train_homing import KinematicFly, compute_agent_senses
        import train_homing as th
        fly = KinematicFly(x=0.0, z=0.0, heading_rad=0.0)
        tgt = KinematicFly(x=20.0, z=0.0, heading_rad=np.pi)
        th.TREES = []
        senses, _ = compute_agent_senses(fly, tgt, prev_dist=25.0)
        for k in ("visual_sec_presence", "visual_sec_size",
                  "visual_sec_loom", "visual_sec_tree"):
            self.assertEqual(len(senses[k]), 21)
        self.assertEqual(sum(senses["visual_sec_presence"]), 1.0)
        cell = senses["visual_sec_presence"].index(1.0)
        self.assertEqual(cell, 1 * 7 + 3)  # level band, 0-deg column
        self.assertGreater(senses["visual_sec_size"][cell], 0.0)
        self.assertGreater(senses["visual_sec_loom"][cell], 0.0)
        self.assertEqual(sum(senses["visual_sec_tree"]), 0.0)
        # Rear rival lands in a rear column (tracking only, never evade).
        tgt_back = KinematicFly(x=-20.0, z=0.0, heading_rad=0.0)
        back, _ = compute_agent_senses(fly, tgt_back, prev_dist=25.0)
        rear_cell = back["visual_sec_presence"].index(1.0)
        self.assertIn(rear_cell % 7, (0, 6))

    def test_gyro_full_scale(self):
        # Full right deflection must span the full JO range (regression:
        # the trainer clip capped it at ~0.375 while live reaches 1.0).
        from train_homing import KinematicFly, compute_agent_senses
        fly = KinematicFly(heading_rad=0.0)
        tgt = KinematicFly(x=10.0, z=0.0)
        fly.step(thrust=0.5, yaw_torque=1.0, pitch_cmd=0.0, dt=0.05)
        senses, _ = compute_agent_senses(fly, tgt)
        self.assertAlmostEqual(senses["angular_yaw_rate"], 1.0, places=5)


class TestRetinaVision(unittest.TestCase):
    """Panoramic 21-sector eye: grid geometry, side-gated feature drive,
    rear tracking without evade, and opt-in isolation (other regimes
    never see the sector keys)."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def _grid(self, band, col, size=0.0, loom=0.0, wood=0.0):
        pres = [0.0] * 21
        size_a = [0.0] * 21
        loom_a = [0.0] * 21
        wood_a = [0.0] * 21
        idx = band * 7 + col
        pres[idx] = 1.0
        size_a[idx] = size
        loom_a[idx] = loom
        wood_a[idx] = wood
        return {"visual_sec_presence": pres, "visual_sec_size": size_a,
                "visual_sec_loom": loom_a, "visual_sec_tree": wood_a}

    def test_sector_isolation(self):
        # One frontal-left cell drives LC pools on the left only.
        enc = SensoryEncoder(self.pops, mapping="retina")
        lc11_l = set(self.pops["visual_lc11"]["left"])
        lc11_r = set(self.pops["visual_lc11"]["right"])
        sp = set(int(s) for s in enc.encode(
            dict(self._grid(1, 1, size=0.5),
                 visual_target_visible=True)))
        self.assertGreater(len(sp & lc11_l), 0)
        self.assertEqual(len(sp & lc11_r), 0)

    def test_rear_tracks_never_evades(self):
        # Rear cells (cols 0 and 6) drive LC11 tracking but no loom
        # pools, and the decoder never evades on rear input.
        enc = SensoryEncoder(self.pops, mapping="retina")
        dec = MotorDecoder(self.pops, mapping="retina")
        loom_pools = (set(self.pops["visual_lc15"]["all"])
                      | set(self.pops["visual_lc17"]["all"])
                      | set(self.pops["visual_lc18"]["all"]))
        for col in (0, 6):
            with self.subTest(col=col):
                d = dict(self._grid(0, col, size=0.8, loom=0.9),
                         visual_target_visible=False,
                         visual_target_azimuth=170.0 if col == 0 else -170.0)
                sp = list(enc.encode(d))
                self.assertEqual(
                    len(set(int(s) for s in sp) & loom_pools), 0)
                ctrl = dec.decode(sp, sensory_hint=d)
                self.assertFalse(ctrl["emergency_evade"])

    def test_retina_lateralizes_both_ways(self):
        enc = SensoryEncoder(self.pops, mapping="retina")
        dec = MotorDecoder(self.pops, mapping="retina")
        hint_l = {"visual_target_visible": True, "visual_target_azimuth": -50.0}
        hint_r = {"visual_target_visible": True, "visual_target_azimuth": 50.0}
        dl = dict(self._grid(1, 1, size=0.5), **hint_l)
        dr = dict(self._grid(1, 5, size=0.5), **hint_r)
        y_l = dec.decode(enc.encode(dl), sensory_hint=hint_l)["yaw_torque"]
        y_r = dec.decode(enc.encode(dr), sensory_hint=hint_r)["yaw_torque"]
        self.assertLess(y_l, 0.0)
        self.assertGreater(y_r, 0.0)

    def test_other_regimes_ignore_sectors(self):
        d = dict(self._grid(1, 1, size=0.9, loom=0.9, wood=0.9),
                 visual_target_visible=False)
        for kwargs in ({}, {"mapping": "base"}, {"mapping": "muscles_up"},
                       {"legacy": True}):
            with self.subTest(kwargs=kwargs):
                enc = SensoryEncoder(self.pops, **kwargs)
                lc_all = (set(self.pops["visual_lc11"]["all"])
                          | set(self.pops["visual_lc15"]["all"])
                          | set(self.pops["visual_lc17"]["all"])
                          | set(self.pops["visual_lc18"]["all"]))
                sp = set(int(s) for s in enc.encode(d))
                self.assertEqual(len(sp & lc_all), 0)

    def test_retina_pursuit_smoke(self):
        # Closed loop: a fresh retina brain must make progress toward the
        # target (deterministic seed; generous margin, not a performance
        # benchmark). Catches wiring regressions that unit probes miss
        # (dead downstream paths, sign flips, silent channels).
        import os
        from train_homing import run_training, CHECKPOINTS_DIR
        os.makedirs(os.path.join(CHECKPOINTS_DIR, "tmp"), exist_ok=True)
        out = os.path.join(CHECKPOINTS_DIR, "tmp", "retina_smoke.npz")
        self.addCleanup(lambda: os.path.exists(out) and os.remove(out))
        _save, _w, summary = run_training(
            num_episodes=3, variant="custom", seed=11,
            target_evasion=0.2, learning_rate=0.008, dist_gain=0.15,
            experiment="retina_wide", mapping="retina", init_weights=None,
            save_name=os.path.join("tmp", "retina_smoke.npz"),
            return_brain=True)
        self.assertEqual(summary["episodes"], 3)
        self.assertGreater(summary["avg_closed"], 5.0)

    def test_sector_wood_drives_lplc2(self):
        enc = SensoryEncoder(self.pops, mapping="retina")
        lplc2_l = set(self.pops["visual_lplc2"]["left"])
        d = self._grid(1, 1)
        d["visual_sec_tree"][1 * 7 + 1] = 0.8
        sp = set(int(s) for s in enc.encode(
            dict(d, visual_target_visible=False)))
        self.assertGreater(len(sp & lplc2_l), 0)


class TestRetinaWiring(unittest.TestCase):
    """retina_wide overlay: registered, deterministic, ipsilateral
    (pursuit-toward), sized to recruit tens (not hundreds) of DNs, with
    its own checkpoint namespace."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_registered_and_shaped(self):
        from experimental_wiring import EXPERIMENTS, experiment_suffix
        self.assertIn("retina_wide", EXPERIMENTS)
        self.assertEqual(experiment_suffix("retina_wide"), "__exp_retina_wide")
        a = EXPERIMENTS["retina_wide"](self.pops)
        b = EXPERIMENTS["retina_wide"](self.pops)
        for x, y in zip(a, b):
            np.testing.assert_array_equal(x, y)
        pre, post, w = a
        self.assertEqual(len(pre), len(post))
        self.assertEqual(len(pre), len(w))
        self.assertTrue((w > 0).all())

    def test_ipsilateral_pursuit_direction(self):
        # Every injected edge runs same-side (feature-L -> DN-L):
        # pursuit toward, never away.
        from experimental_wiring import EXPERIMENTS
        pre, post, _w = EXPERIMENTS["retina_wide"](self.pops)
        dn_l = set(self.pops["descending_all"]["left"])
        dn_r = set(self.pops["descending_all"]["right"])
        feat_l, feat_r = set(), set()
        for key in ("visual_lc11", "visual_lc15", "visual_lc17", "visual_lc18"):
            feat_l |= set(self.pops[key]["left"])
            feat_r |= set(self.pops[key]["right"])
        for s, q in zip(pre.tolist(), post.tolist()):
            if s in feat_l:
                self.assertIn(q, dn_l)
            elif s in feat_r:
                self.assertIn(q, dn_r)
            else:
                self.fail(f"injected pre {s} is not a retina feature cell")

    def test_retina_dopamine_branch(self):
        # Retina-scheme LC11 pursuit learns laterally (mirrors LC10);
        # base schemes leave LC11 weights untouched.
        from dopamine_learning import DopamineReinforcement
        rng = np.random.default_rng(11)
        n, deg = 200, 6
        indptr = np.arange(n + 1, dtype=np.int32) * deg
        indices = rng.integers(0, n, size=n * deg).astype(np.int32)
        base_w = rng.normal(4.0, 0.5, size=n * deg).astype(np.float32)
        lc11_l = list(range(0, 10))
        lc11_r = list(range(10, 20))
        fake_pops = {
            "pheromone_da1": {"left": [], "right": []},
            "pheromone_va1v": {"left": [], "right": []},
            "visual_lc10": {"left": [], "right": []},
            "visual_lc4": {"left": [], "right": []},
            "visual_lplc2": {"left": [], "right": []},
            "visual_lc11": {"left": lc11_l, "right": lc11_r},
            "dopamine_pam": {"all": []}, "dopamine_ppl1": {"all": []},
            "motor_turn_dnp20": {"left": [100], "right": [101]},
            "motor_thrust_dnp09": {"all": [102]},
            "motor_ram_dnpe017": {"all": [103]},
            "motor_giant_fiber": {"all": [104]},
            "descending_all": {"left": [100], "right": [101],
                               "all": [100, 101, 102]},
            "mushroom_body_kc": [], "mbon_app": {"all": []},
            "mbon_av": {"all": []},
        }
        rl = DopamineReinforcement(
            fake_pops, base=(indptr, indices, base_w.copy()))

        class _Brain:
            pass

        def _make():
            b = _Brain()
            b.indptr = indptr
            b.indices = indices
            b.weights = base_w.copy()
            return b

        pos_l = DopamineReinforcement._row_positions(indptr, lc11_l)
        sens = {"pheromone_conc_left": 0.9, "pheromone_conc_right": 0.1,
                "visual_target_azimuth": -40.0}
        motor = {"yaw_torque": -0.5, "thrust": 0.3}
        b = _make()
        w0 = b.weights.copy()
        rl.apply_plasticity(b, sens, motor, 1.0, schemes=("retina",))
        self.assertFalse(bool((b.weights[pos_l] == w0[pos_l]).all()))
        b2 = _make()
        w02 = b2.weights.copy()
        rl.apply_plasticity(b2, sens, motor, 1.0, schemes=())
        # Base schemes never touch LC11 rows (DN-incoming steering may
        # still learn, which is the point of the shared base branches).
        np.testing.assert_array_equal(b2.weights[pos_l], w02[pos_l])

    def test_recruitment_band(self):
        # A full frontal-cell volley must recruit a useful but bounded
        # DN volley through the overlay (measured tuning: tens/tick,
        # comparable to odor drive, far from saturating).
        from experimental_wiring import experiment_arrays
        from sensory_motor import SensoryEncoder
        from lif_brain import FlyBrain
        indptr, indices, wbasis = experiment_arrays(
            "retina_wide", self.csr, self.pops)
        brain = FlyBrain(indptr, indices, np.ascontiguousarray(
            np.asarray(wbasis, dtype=np.float32)).copy())
        enc = SensoryEncoder(self.pops, mapping="retina")
        pres = [0.0] * 21
        size = [0.0] * 21
        loom = [0.0] * 21
        wood = [0.0] * 21
        pres[10] = 1.0
        size[10] = 0.5
        loom[10] = 0.6
        stim = {"visual_sec_presence": pres, "visual_sec_size": size,
                "visual_sec_loom": loom, "visual_sec_tree": wood}
        dn = set(self.pops["descending_all"]["all"])
        tot = 0
        for _ in range(4):
            sp = brain.integrate_50ms(enc.encode(stim))
            tot += len(set(int(x) for x in sp) & dn)
        self.assertGreater(tot, 10)
        self.assertLess(tot, 400)


class TestFlowTrans(unittest.TestCase):
    """Translational optic flow: T4/T5 pool purity, direction-gated
    encoding, cruise/drift/flare readout, dopamine + trainer support."""
    @classmethod
    def setUpClass(cls):
        cls.pops = load_or_extract_populations()

    def test_t4t5_pool_purity(self):
        from connectome_loader import _retained_annotations
        df = _retained_annotations()
        expect = {"visual_t4a": "T4a", "visual_t4b": "T4b",
                  "visual_t4c": "T4c", "visual_t4d": "T4d",
                  "visual_t5a": "T5a", "visual_t5b": "T5b",
                  "visual_t5c": "T5c", "visual_t5d": "T5d"}
        for key, typ in expect.items():
            with self.subTest(pool=key):
                m = self.pops[key]
                self.assertGreater(len(m["all"]), 1500)
                self.assertGreater(len(m["left"]), 700)
                self.assertGreater(len(m["right"]), 700)
                types = set(df["type"].iloc[i] for i in m["all"])
                self.assertEqual(types, {typ})

    def test_encoder_direction_gating(self):
        from sensory_motor import SensoryEncoder
        enc = SensoryEncoder(self.pops, mapping="flow_trans")
        t4a = set(self.pops["visual_t4a"]["all"])
        t5a = set(self.pops["visual_t5a"]["all"])
        t4b = set(self.pops["visual_t4b"]["all"])
        t4d = set(self.pops["visual_t4d"]["all"])
        t4c = set(self.pops["visual_t4c"]["all"])
        other = (set(self.pops["visual_lc10"]["all"])
                 | set(self.pops["visual_lc4"]["all"]))
        sp = set(int(s) for s in enc.encode({"visual_flow_ventral": 0.9}))
        self.assertGreater(len(sp & (t4a | t5a)), 0)
        self.assertEqual(len(sp & (t4b | t4d | t4c)), 0)
        sp = set(int(s) for s in enc.encode({"visual_flow_lateral": 0.8}))
        self.assertGreater(len(sp & t4b), 0)
        sp = set(int(s) for s in enc.encode({"visual_flow_expansion": 0.9}))
        self.assertGreater(len(sp & t4d), 0)
        sp = set(int(s) for s in enc.encode({"visual_flow_climb": 0.9}))
        self.assertGreater(len(sp & t4c), 0)
        for s in sp:
            self.assertNotIn(s, other)
        # Base scheme and legacy: no T4/T5 spikes ever.
        base = SensoryEncoder(self.pops)
        self.assertEqual(len(base.encode({"visual_flow_ventral": 0.9,
                                          "visual_flow_expansion": 0.9})), 0)
        leg = SensoryEncoder(self.pops, mapping="flow_trans", legacy=True)
        self.assertEqual(len(leg.encode({"visual_flow_ventral": 0.9})), 0)

    def test_decoder_cruise_drift_flare(self):
        from sensory_motor import MotorDecoder, FLOW_CRUISE
        dec = MotorDecoder(self.pops, mapping="flow_trans")
        base = MotorDecoder(self.pops)
        hint_low = {"visual_flow_ventral": 0.0, "visual_flow_lateral": 0.0,
                    "visual_flow_expansion": 0.0}
        hint_high = {"visual_flow_ventral": 1.0, "visual_flow_lateral": 0.0,
                     "visual_flow_expansion": 0.0}
        dn = list(self.pops["descending_all"]["all"][:40])
        t_slow = dec.decode(dn, sensory_hint=hint_low)["thrust"]
        t_fast = dec.decode(dn, sensory_hint=hint_high)["thrust"]
        self.assertGreater(t_slow, t_fast)
        self.assertAlmostEqual(
            dec.decode(dn, sensory_hint={
                "visual_flow_ventral": FLOW_CRUISE,
                "visual_flow_lateral": 0.0,
                "visual_flow_expansion": 0.0})["thrust"],
            base.decode(dn)["thrust"], places=5)
        # Flare cuts thrust; drift trims yaw right on rightward slip.
        f0 = dec.decode(dn, sensory_hint=hint_low)["thrust"]
        f1 = dec.decode(dn, sensory_hint={
            "visual_flow_ventral": 0.0, "visual_flow_lateral": 0.0,
            "visual_flow_expansion": 1.0})["thrust"]
        self.assertLess(f1, f0)
        y = dec.decode(dn, sensory_hint={
            "visual_flow_ventral": FLOW_CRUISE, "visual_flow_lateral": 0.6,
            "visual_flow_expansion": 0.0})["yaw_torque"]
        y0 = dec.decode(dn, sensory_hint={
            "visual_flow_ventral": FLOW_CRUISE, "visual_flow_lateral": 0.0,
            "visual_flow_expansion": 0.0})["yaw_torque"]
        self.assertGreater(y, y0)
        # Legacy: flow keys inert (same decoder, with/without hint).
        leg = MotorDecoder(self.pops, mapping="flow_trans", legacy=True)
        self.assertEqual(leg.decode(dn, sensory_hint=hint_high)["thrust"],
                         leg.decode(dn)["thrust"])
        # Base decoder ignores flow keys entirely.
        self.assertEqual(base.decode(dn, sensory_hint=hint_high)["thrust"],
                         base.decode(dn)["thrust"])

    def test_dopamine_flow_branch_and_reward(self):
        from dopamine_learning import DopamineReinforcement
        rl = DopamineReinforcement(self.pops)
        t4a = (list(self.pops["visual_t4a"]["left"])
               + list(self.pops["visual_t4a"]["right"]))
        r0 = rl.compute_reward(10.0, 10.1, 10.0)
        r1 = rl.compute_reward(10.0, 10.1, 10.0, ventral=0.35,
                               schemes=("flow_trans",))
        self.assertGreater(r1, r0)
        r2 = rl.compute_reward(10.0, 10.1, 10.0, ventral=0.35)
        self.assertEqual(r2, r0)


class TestSpearLunge(unittest.TestCase):
    """Mouth-motor spear attack: MNxm pool registration, spear_lunge
    wiring (deterministic, mouth-targeted), decoder readout with aim
    gate, and safety (unwired brains read exactly 0)."""
    @classmethod
    def setUpClass(cls):
        cls.csr = load_or_build_csr()
        cls.pops = load_or_extract_populations()

    def test_mouth_pool_registered(self):
        m = self.pops["motor_mouth"]
        self.assertEqual(len(m["all"]), 6)
        self.assertEqual((len(m["left"]), len(m["right"])), (3, 3))
        from connectome_loader import _retained_annotations
        df = _retained_annotations()
        types = set(df["type"].iloc[i] for i in m["all"])
        for t in types:
            self.assertTrue(t.startswith("MNxm"), t)

    def test_wiring_registered_deterministic_mouth_only(self):
        from experimental_wiring import EXPERIMENTS, experiment_suffix
        self.assertIn("spear_lunge", EXPERIMENTS)
        self.assertEqual(experiment_suffix("spear_lunge"), "__exp_spear_lunge")
        a = EXPERIMENTS["spear_lunge"](self.pops)
        b = EXPERIMENTS["spear_lunge"](self.pops)
        for x, y in zip(a, b):
            np.testing.assert_array_equal(x, y)
        pre, post, w = a
        self.assertEqual(len(pre), len(post))
        self.assertEqual(len(pre), len(w))
        self.assertTrue((w > 0).all())
        mx = set(self.pops["motor_mouth"]["all"])
        feat = set()
        for key in ("visual_lc11", "visual_lc15", "visual_lc17", "visual_lc18"):
            feat |= set(self.pops[key]["all"])
        for s, q in zip(pre.tolist(), post.tolist()):
            self.assertIn(q, mx)
            self.assertIn(s, feat)

    def test_decoder_spear_gating(self):
        dec = MotorDecoder(self.pops)
        mx = list(self.pops["motor_mouth"]["all"])
        frontal = {"visual_target_visible": True, "visual_target_azimuth": 10.0}
        rear = {"visual_target_visible": False, "visual_target_azimuth": 170.0}
        blind = {"visual_target_visible": True, "visual_target_azimuth": 120.0}
        self.assertEqual(dec.decode(mx[:2], sensory_hint=frontal)["spear_thrust"], 0.0)
        full = dec.decode(mx, sensory_hint=frontal)["spear_thrust"]
        self.assertGreater(full, 0.0)
        self.assertLessEqual(full, 1.0)
        self.assertEqual(dec.decode(mx, sensory_hint=rear)["spear_thrust"], 0.0)
        self.assertEqual(dec.decode(mx, sensory_hint=blind)["spear_thrust"], 0.0)
        # Hint-less diagnostic calls keep the raw readout (like GF evade).
        self.assertAlmostEqual(dec.decode(mx)["spear_thrust"], 0.6)
        # Key present in every output shape, including empty/reflex paths.
        for ctrl in (dec.decode([]),
                     dec.decode([], sensory_hint=frontal)):
            self.assertIn("spear_thrust", ctrl)
            self.assertEqual(ctrl["spear_thrust"], 0.0)

    def test_unwired_brains_read_zero(self):
        # Base wiring drives ~0 MNxm spikes: the readout exists for every
        # brain but only spear_lunge-wired brains can ever fire it.
        from experimental_wiring import experiment_arrays
        from lif_brain import FlyBrain
        from sensory_motor import SensoryEncoder
        for exp in (None, "spear_lunge"):
            indptr, indices, wbasis = experiment_arrays(
                exp, self.csr, self.pops)
            brain = FlyBrain(indptr, indices, np.ascontiguousarray(
                np.asarray(wbasis, dtype=np.float32)).copy())
            enc = SensoryEncoder(self.pops, mapping="retina")
            mx = set(self.pops["motor_mouth"]["all"])
            tot = 0
            pres = [0.0] * 21
            size = [0.0] * 21
            loom = [0.0] * 21
            wood = [0.0] * 21
            pres[10] = 1.0
            size[10] = 0.8
            loom[10] = 0.8
            stim = {"visual_sec_presence": pres, "visual_sec_size": size,
                    "visual_sec_loom": loom, "visual_sec_tree": wood,
                    "visual_target_visible": True, "visual_target_azimuth": 0.0}
            for _ in range(4):
                sp = brain.integrate_50ms(enc.encode(stim))
                tot += len(set(int(x) for x in sp) & mx)
            if exp is None:
                self.assertEqual(tot, 0)
            else:
                self.assertGreater(tot, 4)


class TestEvoLoop(unittest.TestCase):
    """Eternal evolution loop: biggest-loser query, archive/restore
    round-trip, breeder parameter validation (no training runs here)."""
    def _bracket(self, matches):
        return {"rounds": [matches]}

    def test_biggest_loser_earliest_exit(self):
        import evo_breeder as evo
        import random
        t = self._bracket([
            {"a_id": " champ ", "b_id": "mid", "wins_a": 4, "wins_b": 1},
            {"a_id": "early1", "b_id": "early2", "wins_a": 0, "wins_b": 4},
        ])
        t["rounds"].append([
            {"a_id": " champ ", "b_id": "early2", "wins_a": 4, "wins_b": 2},
        ])
        # early1 exited round 0 with 0 wins -> biggest loser.
        pick, info = evo.biggest_loser(t, random.Random(0))
        self.assertEqual(pick, "early1")
        self.assertEqual(info["last_round"], 0)
        self.assertEqual(info["battle_wins"], 0)

    def test_biggest_loser_tiebreak_seeded(self):
        import evo_breeder as evo
        import random
        t = self._bracket([
            {"a_id": "x", "b_id": "y", "wins_a": 2, "wins_b": 2},
        ])
        picks = {evo.biggest_loser(t, random.Random(s))[0]
                 for s in range(10)}
        # Seeded tie-breaks vary across seeds but stay in the tied set.
        self.assertTrue(picks <= {"x", "y"})
        self.assertGreater(len(picks), 1)

    def test_biggest_loser_empty_raises(self):
        import evo_breeder as evo
        with self.assertRaises(ValueError):
            evo.biggest_loser({"rounds": []})
        with self.assertRaises(ValueError):
            evo.biggest_loser({})

    def test_wild_name_deterministic(self):
        import random
        import evo_breeder as evo
        a = evo.wild_name(random.Random(42), 3)
        b = evo.wild_name(random.Random(42), 3)
        self.assertEqual(a, b)
        self.assertTrue(a.endswith(" G3"))
        # One-word stem plus generation tag (never "Adjective_Callsign").
        parts = a.split(" ")
        self.assertEqual(len(parts), 2)
        self.assertIn(parts[0], evo.WILD_STEMS)
        self.assertEqual(parts[1], "G3")
        self.assertNotIn("_", parts[0])
        names = {evo.wild_name(random.Random(s), 3) for s in range(40)}
        self.assertGreater(len(names), 30)

    def test_unique_wild_name_collision(self):
        import random
        import evo_breeder as evo
        base = evo.wild_name(random.Random(7), 2)
        # No collision: plain deterministic name.
        self.assertEqual(
            evo.unique_wild_name(random.Random(7), 2, set()), base)
        # Collision: deterministic Mk suffix, repeatable.
        u1 = evo.unique_wild_name(random.Random(7), 2, {base})
        self.assertTrue(u1.startswith(base + " Mk"))
        self.assertEqual(
            u1, evo.unique_wild_name(random.Random(7), 2, {base}))
        u2 = evo.unique_wild_name(random.Random(7), 2, {base, u1})
        self.assertNotEqual(u2, u1)
        self.assertTrue(u2.startswith(base + " Mk"))



    def test_biggest_loser_byes_draws_quick(self):
        import evo_breeder as evo
        import random
        # Bye walkovers and vacant cards must not crown phantom losers;
        # draws still count as played rounds.
        t = {"rounds": [[
            {"a_id": "bye_guy", "b_id": "", "wins_a": 0, "wins_b": 0,
             "bye": True, "winner_id": "bye_guy"},
            {"a_id": "", "b_id": "", "vacant": True},
            {"a_id": "f1", "b_id": "f2", "wins_a": 3, "wins_b": 4,
             "draws": 1},
        ], [
            {"a_id": "bye_guy", "b_id": "f2", "wins_a": 0, "wins_b": 4},
        ]]}
        pick, info = evo.biggest_loser(t, random.Random(1))
        self.assertEqual(pick, "f1")
        self.assertEqual(info["last_round"], 0)
        # Quick battle: loser is simply the one with fewer wins.
        q = {"rounds": [[
            {"a_id": "qa", "b_id": "qb", "wins_a": 1, "wins_b": 0}]]}
        pick, _info = evo.biggest_loser(q, random.Random(0))
        self.assertEqual(pick, "qb")
        # Missing keys default to zero, never crash.
        r = {"rounds": [[{"a_id": "m1", "b_id": "m2"}]]}
        pick, info = evo.biggest_loser(r, random.Random(0))
        self.assertIn(pick, ("m1", "m2"))
        self.assertEqual(info["battle_wins"], 0)

    def test_archive_edge_cases(self):
        import tempfile
        import brain_package as vault
        tmp = tempfile.mkdtemp(prefix="vault_evo_edge_")
        old_vault, old_index = vault.VAULT_DIR, vault.VAULT_INDEX
        old_arch, old_log = vault.ARCHIVE_DIR, vault.ARCHIVE_LOG
        vault.VAULT_DIR = tmp
        vault.VAULT_INDEX = os.path.join(tmp, "vault_index.json")
        vault.ARCHIVE_DIR = os.path.join(tmp, "archive")
        vault.ARCHIVE_LOG = os.path.join(tmp, "archive", "log.json")
        try:
            with self.assertRaises(FileNotFoundError):
                vault.archive_brain("ghost")
            r1 = vault.new_record("EdgeA", {})
            vault.save_brain(r1, np.zeros(16, dtype=np.float32),
                             backup=False)
            # IDs derive from wall-clock ms: space them out so the two
            # same-named brains don't share a filename.
            time.sleep(0.02)
            r2 = vault.new_record("EdgeA", {})
            vault.save_brain(r2, np.zeros(16, dtype=np.float32),
                             backup=False)
            vault.archive_brain(r1["id"], reason="edge test")
            vault.archive_brain(r2["id"], reason="edge test")
            # Ambiguous substring match must fail loud, not restore wrong.
            with self.assertRaises(ValueError):
                vault.restore_brain("EdgeA")
            vault.restore_brain(r1["id"])
            # Restoring twice: second hits the gone-file path.
            with self.assertRaises(FileNotFoundError):
                vault.restore_brain(r1["id"])
        finally:
            vault.VAULT_DIR, vault.VAULT_INDEX = old_vault, old_index
            vault.ARCHIVE_DIR, vault.ARCHIVE_LOG = old_arch, old_log
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)

    def test_archive_restore_roundtrip(self):
        import tempfile
        import brain_package as vault
        tmp = tempfile.mkdtemp(prefix="vault_evo_test_")
        old_vault, old_index = vault.VAULT_DIR, vault.VAULT_INDEX
        old_arch, old_log = vault.ARCHIVE_DIR, vault.ARCHIVE_LOG
        vault.VAULT_DIR = tmp
        vault.VAULT_INDEX = os.path.join(tmp, "vault_index.json")
        vault.ARCHIVE_DIR = os.path.join(tmp, "archive")
        vault.ARCHIVE_LOG = os.path.join(tmp, "archive", "log.json")
        try:
            rec = vault.new_record("EvoTest", {})
            vault.save_brain(
                rec, np.zeros(32, dtype=np.float32), backup=False)
            entry = vault.archive_brain(rec["id"], reason="test loser")
            self.assertEqual(entry["id"], rec["id"])
            self.assertFalse(os.path.isfile(
                os.path.join(tmp, rec["filename"])))
            self.assertEqual(
                [e["id"] for e in vault.list_archive()
                 if e["present"]], [rec["id"]])
            back = vault.restore_brain(rec["id"])
            self.assertEqual(back["id"], rec["id"])
            self.assertTrue(os.path.isfile(
                os.path.join(tmp, rec["filename"])))
            with self.assertRaises(FileNotFoundError):
                vault.restore_brain("nope-not-here")
        finally:
            vault.VAULT_DIR, vault.VAULT_INDEX = old_vault, old_index
            vault.ARCHIVE_DIR, vault.ARCHIVE_LOG = old_arch, old_log
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)

    def test_breed_random_params_valid(self):
        # Random param construction without training: valid genome,
        # derived mapping, yaw_bias ranges (mirrors breed_random's draws).
        import random as _random
        import numpy as _np
        from experimental_wiring import (validate_genome, derive_mapping,
                                         genome_label, generate_genome)
        from sensory_motor import (normalize_mapping, normalize_yaw_bias,
                                   draw_yaw_bias, YAW_BIAS_LO, YAW_BIAS_HI)
        from connectome_loader import load_or_extract_populations
        pops = load_or_extract_populations()
        for seed in range(20):
            rr = _random.Random(seed)
            grng = _np.random.default_rng(seed)
            genome = generate_genome(grng, pops, 1 + int(grng.integers(0, 4)))
            validate_genome(genome, pops)
            stack = list(derive_mapping(genome))
            normalize_mapping(stack or None)
            genome_label(genome)
            v = draw_yaw_bias(rr)
            normalize_yaw_bias(v)
            self.assertGreaterEqual(v, YAW_BIAS_LO)
            self.assertLessEqual(v, YAW_BIAS_HI)


_ELO_MISSING = object()


class TestElo(unittest.TestCase):
    """ELO ratings: zero-sum math, defaults, backfill, inheritance.
    No training runs here (CSR-free); server call sites are covered by
    mocked handler tests below."""
    def _rec(self, elo=_ELO_MISSING, wins=0, losses=0):
        r = {"battles": wins + losses, "wins": wins, "losses": losses,
             "draws": 0, "matches": 0, "matches_won": 0,
             "matches_lost": 0, "tournaments_won": 0}
        if elo is not _ELO_MISSING:
            r["elo"] = elo
        return {"id": "t", "record": r}

    def test_elo_zero_sum(self):
        import brain_package as vault
        a, b = self._rec(1200.0), self._rec(1200.0)
        na, nb = vault.apply_elo(a, b, "win", vault.ELO_K_BATTLE)
        self.assertAlmostEqual(na, 1205.0)
        self.assertAlmostEqual(nb, 1195.0)
        self.assertAlmostEqual(na + nb, 2400.0)

    def test_elo_upset_swings_more(self):
        import brain_package as vault
        a, b = self._rec(1200.0), self._rec(1600.0)
        na, _nb = vault.apply_elo(a, b, "win", 10.0)
        underdog_gain = na - 1200.0
        c, d = self._rec(1200.0), self._rec(1600.0)
        _nc, nd = vault.apply_elo(c, d, "loss", 10.0)
        favorite_gain = nd - 1600.0
        self.assertGreater(underdog_gain, 5.0)
        self.assertGreater(underdog_gain, favorite_gain)

    def test_elo_draw_equal_no_change(self):
        import brain_package as vault
        a, b = self._rec(1200.0), self._rec(1200.0)
        na, nb = vault.apply_elo(a, b, "draw", 10.0)
        self.assertEqual(na, 1200.0)
        self.assertEqual(nb, 1200.0)

    def test_elo_bad_outcome_raises(self):
        import brain_package as vault
        with self.assertRaises(ValueError):
            vault.apply_elo(self._rec(), self._rec(), "banana", 10.0)

    def test_elo_missing_key_defaults(self):
        import brain_package as vault
        a, b = self._rec(), self._rec()
        na, nb = vault.apply_elo(a, b, "win", 10.0)
        self.assertAlmostEqual(na, 1205.0)
        self.assertAlmostEqual(nb, 1195.0)
        self.assertIn("elo", a["record"])

    def test_draw3_penalty(self):
        import brain_package as vault
        a, b = self._rec(1300.0), self._rec(1100.0)
        na, nb = vault.apply_draw3_penalty(a, b)
        self.assertAlmostEqual(na, 1300.0 - vault.ELO_DRAW3_PENALTY)
        self.assertAlmostEqual(nb, 1100.0 - vault.ELO_DRAW3_PENALTY)

    def test_new_record_default(self):
        import brain_package as vault
        rec = vault.new_record("Rookie")
        self.assertEqual(rec["record"]["elo"], vault.ELO_DEFAULT)

    def test_backfill(self):
        import tempfile
        import shutil
        import brain_package as vault
        tmp = tempfile.mkdtemp(prefix="vault_elo_")
        old_vault, old_index = vault.VAULT_DIR, vault.VAULT_INDEX
        vault.VAULT_DIR = tmp
        vault.VAULT_INDEX = os.path.join(tmp, "vault_index.json")
        try:
            rec = vault.new_record("Vet")
            del rec["record"]["elo"]
            rec["record"]["wins"] = 6
            rec["record"]["losses"] = 2
            vault.save_brain(rec, np.zeros(64, dtype=np.float32))
            rec2 = vault.new_record("Fresh")
            vault.save_brain(rec2, np.zeros(64, dtype=np.float32))
            self.assertEqual(vault.backfill_elo(), 1)
            got, _w = vault.load_brain(rec["id"])
            self.assertAlmostEqual(got["record"]["elo"], 1200.0 + 25.0 * 4)
            self.assertEqual(vault.backfill_elo(), 0)
        finally:
            vault.VAULT_DIR, vault.VAULT_INDEX = old_vault, old_index
            shutil.rmtree(tmp, ignore_errors=True)

    def test_inherit_elo(self):
        import evo_breeder as evo
        self.assertAlmostEqual(evo.inherit_elo(1500.0), 1410.0)
        self.assertAlmostEqual(evo.inherit_elo(1200.0), 1200.0)
        # Below-mean parents breed upward toward the mean.
        self.assertAlmostEqual(evo.inherit_elo(800.0), 920.0)

    def test_breed_clone_stamps_inherited_elo(self):
        import numpy as np
        from unittest import mock
        import evo_breeder as evo
        parent = {"id": "p1", "name": "Champ",
                  "generator_params": {"seed": 3},
                  "record": {"battles": 4, "wins": 4, "losses": 0,
                             "draws": 0, "matches": 1, "matches_won": 1,
                             "matches_lost": 0, "tournaments_won": 0,
                             "elo": 1500.0},
                  "training": {"episodes": 0, "sessions": []},
                  "lineage": {"parent_ids": [], "source": "x"}}

        def fake_train_brain(child, start_weights, episodes, params,
                             progress_cb=None, notes="", save=True):
            return child, start_weights, {"episodes": episodes}

        with mock.patch("brain_package.load_brain",
                        return_value=(parent, np.zeros(8,
                                                      dtype=np.float32))), \
                mock.patch("train_job.train_brain",
                           side_effect=fake_train_brain):
            rec, _w, _s = evo.breed_clone("p1", "Kid", seed=5, episodes=1,
                                          mutate_structure=False)
        self.assertAlmostEqual(rec["record"]["elo"], 1410.0)


class TestGodotArenaHeadless(unittest.TestCase):
    """Verifies that Godot 4 compiles all GDScripts and runs each scene without errors."""
    def _run_headless(self, scene=""):
        godot_exe = os.path.join(PROJECT_ROOT, "tools", "godot", "Godot_v4.7.2-stable_win64_console.exe")
        arena_dir = os.path.join(PROJECT_ROOT, "arena")

        args = [godot_exe, "--headless", "--path", arena_dir]
        if scene:
            args.append(scene)
        # Clean exit (not terminate): piped stdout is block-buffered, so a
        # kill would discard buffered errors and blind this test.
        args += ["--quit-after", "180"]
        proc = subprocess.Popen(
            args,
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        try:
            out, _ = proc.communicate(timeout=120.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
        return out

    def test_godot_headless_execution(self):
        for scene in ("", "res://scenes/ArenaGlade.tscn"):
            label = "menu" if not scene else scene
            with self.subTest(scene=label):
                out = self._run_headless(scene)
                self.assertNotIn("SCRIPT ERROR", out, f"Godot raised script error:\n{out}")
                self.assertNotIn("Parse Error", out, f"Godot raised parse error:\n{out}")


class TestBattleTransaction(unittest.TestCase):
    """Isolated battle persistence: draw learning skip + journaled saves.

    No connectome, no UDP server: tiny synthetic weights in a temp vault
    plus a temp tournaments dir, so these run in milliseconds."""
    @classmethod
    def setUpClass(cls):
        import tempfile
        import brain_server as srv
        cls.srv = srv
        cls._real_root = srv.PROJECT_ROOT
        cls._real_vault = vault_pkg.VAULT_DIR
        cls._real_index = vault_pkg.VAULT_INDEX
        cls.tmp = tempfile.mkdtemp(prefix="battle_txn_")
        srv.PROJECT_ROOT = cls.tmp
        vault_pkg.VAULT_DIR = os.path.join(cls.tmp, "brains")
        vault_pkg.VAULT_INDEX = os.path.join(cls.tmp, "brains", "vault_index.json")

    @classmethod
    def tearDownClass(cls):
        import shutil
        cls.srv.PROJECT_ROOT = cls._real_root
        vault_pkg.VAULT_DIR = cls._real_vault
        vault_pkg.VAULT_INDEX = cls._real_index
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def tearDown(self):
        for f in (self.srv._pending_battle_path(), self.srv._last_verdict_path()):
            try:
                os.remove(f)
            except OSError:
                pass

    def _two_fighters(self):
        import copy
        from types import SimpleNamespace
        rec_a = vault_pkg.new_record("TxnA", {})
        rec_b = vault_pkg.new_record("TxnB", {})
        # new_record ids are millisecond timestamps: back-to-back calls
        # can collide, and id-prefix lookup would then resolve both to
        # the same file. Regenerate until distinct.
        while rec_b["id"] == rec_a["id"]:
            time.sleep(0.002)
            rec_b = vault_pkg.new_record("TxnB", {})
        wa = np.arange(32, dtype=np.float32)
        wb = -np.arange(32, dtype=np.float32)
        vault_pkg.save_brain(rec_a, wa)
        vault_pkg.save_brain(rec_b, wb)
        sta = {"rec": copy.deepcopy(rec_a),
               "brain": SimpleNamespace(weights=wa.copy())}
        stb = {"rec": copy.deepcopy(rec_b),
               "brain": SimpleNamespace(weights=wb.copy())}
        return rec_a, rec_b, wa, wb, sta, stb

    def test_draw_skips_all_learning(self):
        class _FakeRL:
            def __init__(self):
                self.calls = []
            def begin_episode(self, brain):
                self.calls.append(("begin",))
            def apply_plasticity(self, brain, sens, ctrl, sig, schemes=()):
                self.calls.append(("plastic", sig))
            def pin_gains(self, brain, legacy=False):
                self.calls.append(("pin", legacy))

        class _FakeBrain:
            def __init__(self, n=8):
                self.weights = np.arange(n, dtype=np.float32)

        rl, ba, bb = _FakeRL(), _FakeBrain(), _FakeBrain()
        wa, wb = ba.weights.copy(), bb.weights.copy()
        self.srv._apply_round_learning(
            rl, ba, bb, "alpha", {}, {}, {"yaw_torque": 0.0},
            {"yaw_torque": 0.0}, 0.5, (), (), False, False,
            arena_draw=True)
        self.assertEqual(rl.calls, [])
        np.testing.assert_array_equal(ba.weights, wa)
        np.testing.assert_array_equal(bb.weights, wb)
        # A decided battle still budgets, teaches both sides, pins both.
        rl2 = _FakeRL()
        self.srv._apply_round_learning(
            rl2, ba, bb, "alpha", {}, {}, {"yaw_torque": 0.0},
            {"yaw_torque": 0.0}, 0.5, (), (), False, False,
            arena_draw=False)
        self.assertEqual(len(rl2.calls), 6)
        self.assertEqual([c[0] for c in rl2.calls],
                         ["begin", "begin", "plastic", "plastic",
                          "pin", "pin"])

    def test_pending_roundtrip_and_retry_idempotent(self):
        import copy
        rec_a, rec_b, wa, wb, sta, stb = self._two_fighters()
        ra = copy.deepcopy(rec_a)
        rb = copy.deepcopy(rec_b)
        vault_pkg.record_battle_result(ra, "win")
        vault_pkg.record_battle_result(rb, "loss")
        key = {"tournament_id": "T", "match": "M",
               "battle_id": "B1", "draw": False}
        resp = {"status": "tournament_battle", "battle_winner": "alpha",
                "fitness_alpha": 1.0, "fitness_beta": 0.0,
                "battle_id": "B1"}
        self.srv._write_pending_battle(
            key, resp,
            [{"side": "alpha", "record": ra},
             {"side": "beta", "record": rb}],
            {"alpha": wa, "beta": wb})
        # Crash before any vault save: wipe both packages.
        os.remove(vault_pkg.package_path(rec_a))
        os.remove(vault_pkg.package_path(rec_b))
        self.srv._recover_pending_battle((sta, stb))
        la, wa2 = vault_pkg.load_brain(rec_a["id"])
        lb, wb2 = vault_pkg.load_brain(rec_b["id"])
        self.assertEqual((la["record"]["wins"], la["record"]["battles"]), (1, 1))
        self.assertEqual((lb["record"]["losses"], lb["record"]["battles"]), (1, 1))
        np.testing.assert_array_equal(wa2, wa)
        np.testing.assert_array_equal(wb2, wb)
        stored = self.srv._read_last_verdict()
        self.assertEqual(stored["key"], key)
        self.assertEqual(stored["result"], resp)
        self.assertEqual(sta["rec"]["record"]["wins"], 1)
        np.testing.assert_array_equal(sta["brain"].weights, wa)
        self.assertFalse(os.path.exists(self.srv._pending_battle_path()))
        # A second replay is a no-op: counters are not banked twice.
        self.srv._recover_pending_battle((sta, stb))
        la2, _ = vault_pkg.load_brain(rec_a["id"])
        self.assertEqual(la2["record"]["battles"], 1)

    def test_interrupted_second_save_replays(self):
        import copy
        rec_a, rec_b, wa, wb, _sta, _stb = self._two_fighters()
        ra = copy.deepcopy(rec_a)
        rb = copy.deepcopy(rec_b)
        vault_pkg.record_battle_result(ra, "win")
        vault_pkg.record_battle_result(rb, "loss")
        key = {"tournament_id": "T", "match": "M",
               "battle_id": "B2", "draw": False}
        resp = {"status": "tournament_battle", "battle_winner": "alpha",
                "fitness_alpha": 2.0, "fitness_beta": 1.0,
                "battle_id": "B2"}
        self.srv._write_pending_battle(
            key, resp,
            [{"side": "alpha", "record": ra},
             {"side": "beta", "record": rb}],
            {"alpha": wa, "beta": wb})
        # Crash between the two vault saves: alpha persisted, beta stale,
        # no verdict yet.
        vault_pkg.save_brain(ra, wa, backup=False, fast=True)
        self.assertIsNone(self.srv._read_last_verdict())
        self.srv._recover_pending_battle()
        lb, wb2 = vault_pkg.load_brain(rec_b["id"])
        self.assertEqual((lb["record"]["losses"], lb["record"]["battles"]), (1, 1))
        np.testing.assert_array_equal(wb2, wb)
        stored = self.srv._read_last_verdict()
        self.assertEqual(stored["key"], key)
        self.assertEqual(stored["result"], resp)

    def test_unkeyed_journal_preserves_previous_verdict(self):
        import copy
        seed_key = {"tournament_id": "T", "match": "M",
                    "battle_id": "B0", "draw": False}
        seed_resp = {"status": "tournament_battle",
                     "battle_winner": "alpha", "fitness_alpha": 1.0,
                     "fitness_beta": 0.0, "battle_id": "B0"}
        self.srv._write_last_verdict(seed_key, seed_resp)
        rec_a, rec_b, wa, wb, _sta, _stb = self._two_fighters()
        ra = copy.deepcopy(rec_a)
        rb = copy.deepcopy(rec_b)
        vault_pkg.record_battle_result(ra, "draw")
        vault_pkg.record_battle_result(rb, "draw")
        resp = {"status": "tournament_battle", "battle_winner": "draw",
                "fitness_alpha": 0.0, "fitness_beta": 0.0, "battle_id": ""}
        self.srv._write_pending_battle(
            None, resp,
            [{"side": "alpha", "record": ra},
             {"side": "beta", "record": rb}],
            {"alpha": wa, "beta": wb})
        self.srv._recover_pending_battle()
        la, _ = vault_pkg.load_brain(rec_a["id"])
        self.assertEqual(la["record"]["draws"], 1)
        stored = self.srv._read_last_verdict()
        self.assertEqual(stored["key"], seed_key)
        self.assertEqual(stored["result"], seed_resp)

    def test_handle_draw_records_draws_without_sessions(self):
        _rec_a, _rec_b, wa, wb, sta, stb = self._two_fighters()
        sent = {}

        class _FakeSock:
            def sendto(self, data, addr):
                sent["data"] = data

        key = {"tournament_id": "T", "match": "M",
               "battle_id": "BD", "draw": True}
        self.srv._handle_tournament_round_over(
            _FakeSock(), ("127.0.0.1", 1), {"arena_draw": True},
            "alpha", 5.0, 5.0, sta, stb,
            {"tournament_id": "T", "match": "M"},
            0.5, 0.5, lambda: "tourney T match M",
            battle_id="BD", battle_key=key)
        body = json.loads(sent["data"].decode("utf-8"))
        self.assertEqual(body["battle_winner"], "draw")
        la, wla = vault_pkg.load_brain(sta["rec"]["id"])
        lb, wlb = vault_pkg.load_brain(stb["rec"]["id"])
        self.assertEqual((la["record"]["draws"], la["record"]["battles"]), (1, 1))
        self.assertEqual((lb["record"]["draws"], lb["record"]["battles"]), (1, 1))
        self.assertEqual(la["training"]["sessions"], [])
        self.assertEqual(lb["training"]["sessions"], [])
        np.testing.assert_array_equal(wla, wa)
        np.testing.assert_array_equal(wlb, wb)
        stored = self.srv._read_last_verdict()
        self.assertEqual(stored["key"], key)
        self.assertEqual(stored["result"]["battle_winner"], "draw")

    def test_battle_elo_banked(self):
        _rec_a, _rec_b, wa, wb, sta, stb = self._two_fighters()
        sent = {}

        class _FakeSock:
            def sendto(self, data, addr):
                sent["data"] = data

        key = {"tournament_id": "T", "match": "M",
               "battle_id": "BE", "draw": False}
        self.srv._handle_tournament_round_over(
            _FakeSock(), ("127.0.0.1", 1), {"arena_draw": False},
            "alpha", 5.0, 4.0, sta, stb,
            {"tournament_id": "T", "match": "M"},
            0.5, 0.5, lambda: "tourney T match M",
            battle_id="BE", battle_key=key)
        la, _wla = vault_pkg.load_brain(sta["rec"]["id"])
        lb, _wlb = vault_pkg.load_brain(stb["rec"]["id"])
        self.assertEqual((la["record"]["wins"], la["record"]["battles"]), (1, 1))
        self.assertEqual((lb["record"]["losses"], lb["record"]["battles"]), (1, 1))
        self.assertAlmostEqual(la["record"]["elo"], 1205.0)
        self.assertAlmostEqual(lb["record"]["elo"], 1195.0)

    def test_battle_draw_penalty(self):
        _rec_a, _rec_b, wa, wb, sta, stb = self._two_fighters()

        class _FakeSock:
            def sendto(self, data, addr):
                pass

        key = {"tournament_id": "T", "match": "M",
               "battle_id": "BD3", "draw": True}
        self.srv._handle_tournament_round_over(
            _FakeSock(), ("127.0.0.1", 1),
            {"arena_draw": True, "draw_penalty": True},
            "alpha", 5.0, 5.0, sta, stb,
            {"tournament_id": "T", "match": "M"},
            0.5, 0.5, lambda: "tourney T match M",
            battle_id="BD3", battle_key=key)
        la, _wla = vault_pkg.load_brain(sta["rec"]["id"])
        lb, _wlb = vault_pkg.load_brain(stb["rec"]["id"])
        self.assertEqual(la["record"]["draws"], 1)
        # Normal draw moves nothing between equals; penalty docks both.
        self.assertAlmostEqual(la["record"]["elo"], 1200.0 - 25.0)
        self.assertAlmostEqual(lb["record"]["elo"], 1200.0 - 25.0)

    def test_match_elo_banked(self):
        _rec_a, _rec_b, wa, wb, sta, stb = self._two_fighters()
        self.assertTrue(self.srv._bank_match_result(sta, stb, "alpha"))
        la, _wla = vault_pkg.load_brain(sta["rec"]["id"])
        lb, _wlb = vault_pkg.load_brain(stb["rec"]["id"])
        self.assertEqual(la["record"]["matches_won"], 1)
        self.assertEqual(lb["record"]["matches_lost"], 1)
        self.assertAlmostEqual(la["record"]["elo"], 1215.0)
        self.assertAlmostEqual(lb["record"]["elo"], 1185.0)

    def test_corrupt_journal_quarantined(self):
        p = self.srv._pending_battle_path()
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(b"not a zip at all")
        with self.assertRaises(Exception):
            self.srv._recover_pending_battle()
        self.assertFalse(os.path.exists(p))
        quarantined = [f for f in os.listdir(os.path.dirname(p))
                       if f.startswith("_pending_battle.npz.corrupt-")]
        self.assertTrue(quarantined)
        for f in quarantined:
            os.remove(os.path.join(os.path.dirname(p), f))


if __name__ == "__main__":
    unittest.main(verbosity=2)
