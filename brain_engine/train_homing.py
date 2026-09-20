import os
import sys
import time
import json
import numpy as np

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from sensory_motor import SensoryEncoder, MotorDecoder, normalize_mapping
from dopamine_learning import DopamineReinforcement
from experimental_wiring import experiment_arrays, experiment_suffix

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKPOINTS_DIR = os.path.join(PROJECT_ROOT, "checkpoints")
os.makedirs(CHECKPOINTS_DIR, exist_ok=True)

# Trainer trunk field (mirrors the arena play forest: sparse, collision trunks).
# Module-level so compute_agent_senses + collision checks share one layout.
# Each tree: (x, z, radius, top_y).
TREES = []
OBSTACLE_RAY_LENGTH = 14.0
BODY_RADIUS = 0.4


def build_trunk_field(seed=777, count=16, half_extent=38.0, min_spacing=7.0):
    # Mirrors the arena forest (24 trunks, spawn pads + center clear) so
    # pre-training transfers: dense enough to teach dodging, sparse enough
    # that cruise flight between trunks is safe.
    rng = np.random.default_rng(seed)
    trees = []
    tries = 0
    while len(trees) < count and tries < count * 60:
        tries += 1
        x = float(rng.uniform(-half_extent, half_extent))
        z = float(rng.uniform(-half_extent, half_extent))
        if np.hypot(x + 14.0, z) < 8.0 or np.hypot(x - 14.0, z) < 8.0:
            continue
        if np.hypot(x, z) < 10.0:
            continue
        if any(np.hypot(x - tx, z - tz) < min_spacing for tx, tz, _, _ in trees):
            continue
        s = float(rng.uniform(0.8, 1.4))
        trees.append((x, z, 0.8 * s, 16.0 * s))
    return trees


def ray_trunk_distance(origin, direction, max_dist=OBSTACLE_RAY_LENGTH):
    """Nearest nose-ray hit against vertical trunks (2D circle + y overlap)."""
    best = max_dist
    ox, oy, oz = float(origin[0]), float(origin[1]), float(origin[2])
    dx, dz = float(direction[0]), float(direction[2])
    n = np.hypot(dx, dz) + 1e-6
    dx, dz = dx / n, dz / n
    for tx, tz, r, top in TREES:
        if oy < 0.0 or oy > top:
            continue
        lx, lz = tx - ox, tz - oz
        t = lx * dx + lz * dz
        if t < 0.0 or t > best:
            continue
        perp2 = lx * lx + lz * lz - t * t
        if perp2 < r * r:
            best = t - np.sqrt(max(r * r - perp2, 0.0))
    return best if best < max_dist else None


def check_trunk_collision(fly):
    """Body-circle vs trunks. Returns (impact_speed, tx, tz) and pushes out."""
    for tx, tz, r, top in TREES:
        if fly.pos[1] < 0.0 or fly.pos[1] > top:
            continue
        dx, dz = float(fly.pos[0] - tx), float(fly.pos[2] - tz)
        d = np.hypot(dx, dz)
        if d < r + BODY_RADIUS:
            push = (r + BODY_RADIUS + 0.1) / max(d, 1e-4)
            fly.pos[0] = tx + dx * push
            fly.pos[2] = tz + dz * push
            return float(fly.last_speed), tx, tz
    return None


def nearest_trunk_distance(fly):
    """Closest trunk skin distance (any direction), for proximity shaping."""
    best = float("inf")
    for tx, tz, r, top in TREES:
        if fly.pos[1] < 0.0 or fly.pos[1] > top:
            continue
        d = float(np.hypot(float(fly.pos[0] - tx), float(fly.pos[2] - tz)) - r)
        if d < best:
            best = d
    return best


class KinematicFly:
    """Lightweight 3D kinematic fly agent for fast headless reinforcement training."""
    # Spear-lunge constants mirror FlyPhysics.gd so pre-training transfers:
    # same trigger, aim gate, cooldown, extension window, and kick scale.
    LUNGE_TRIGGER = 0.4
    LUNGE_COOLDOWN = 1.2
    LUNGE_TIME = 0.35
    LUNGE_KICK = 7.0
    STRIKE_REACH = 2.0  # spike tip (~1.35m) + extension (0.35m) + margin
    def __init__(self, x=0.0, y=7.0, z=0.0, heading_rad=0.0, pitch_rad=0.0):
        self.pos = np.array([x, y, z], dtype=np.float32)
        self.heading = heading_rad # 0 rad = facing along +X (yaw)
        self.pitch = pitch_rad     # >0 = nose up (matches Godot rotate_x sign)
        # Spear-lunge state (arena-like): cooldown between strikes,
        # extension-window timer, and decaying lunge boost (m/s).
        self.lunge_cooldown = 0.0
        self.lunge_t = 0.0
        self.lunge_boost = 0.0
        self.lunge_count = 0
        self.base_speed = 3.0
        self.max_speed = 12.0
        self.turn_rate = 8.0 # matches FlyPhysics: hover-capable snap turns
        self.pitch_rate = 2.5 # matches FlyPhysics pitch_rate
        self.health = 100.0
        self.last_speed = 0.0
        # Body angular rates (rad/s), refreshed every step: the trainer's
        # JO-gyro synth. No roll axis here (2D heading + pitch), so roll
        # trains later via live arena dopamine, not pre-training.
        self.yaw_rate = 0.0
        self.pitch_rate_applied = 0.0

    def forward_vec(self):
        cp = float(np.cos(self.pitch))
        return np.array([cp * np.cos(self.heading), float(np.sin(self.pitch)),
                         cp * np.sin(self.heading)], dtype=np.float32)

    def right_vec(self):
        # Horizontal right vector for the dual-antenna scent model.
        return np.array([np.sin(self.heading), 0.0, -np.cos(self.heading)], dtype=np.float32)

    def step(self, thrust, yaw_torque, pitch_cmd=0.0, dt=0.05, arena_radius=55.0):
        prev_heading, prev_pitch = self.heading, self.pitch
        # Update heading and pitch (pitch self-stabilizes toward level)
        self.heading -= yaw_torque * self.turn_rate * dt
        self.heading = (self.heading + np.pi) % (2.0 * np.pi) - np.pi
        self.pitch += (pitch_cmd * self.pitch_rate - self.pitch * 1.2) * dt
        self.pitch = float(np.clip(self.pitch, -1.2, 1.2))

        # Forward speed along the 3D nose vector
        speed = self.base_speed + (self.max_speed - self.base_speed) * np.clip(thrust, 0.0, 1.0)
        self.last_speed = float(speed)
        self.pos += self.forward_vec() * (speed * dt)
        # Hard altitude limits (mirror FlyPhysics CEILING/FLOOR)
        self.pos[1] = float(np.clip(self.pos[1], 0.5, 30.0))

        # Arena boundary constraint (trees bounce/turn inward, horizontal)
        dist_from_center = float(np.linalg.norm(self.pos[[0, 2]]))
        if dist_from_center > arena_radius:
            inward = -self.pos[[0, 2]] / dist_from_center
            self.heading = np.arctan2(inward[1], inward[0])
            self.pos[0] = -inward[0] * (arena_radius - 0.5)
            self.pos[2] = -inward[1] * (arena_radius - 0.5)

        # Body angular rates over this step (wrap-aware for heading).
        # Clipped at the physical turn limit so the /8.0 JO normalization
        # below spans the full +/-1 range exactly like the arena's
        # per-frame readout (clipping at +/-3 first capped training JO
        # drive at ~0.375 while live flight reaches 1.0).
        dh = (self.heading - prev_heading + np.pi) % (2.0 * np.pi) - np.pi
        self.yaw_rate = float(np.clip(dh / dt, -8.0, 8.0))
        self.pitch_rate_applied = float(np.clip((self.pitch - prev_pitch) / dt, -3.0, 3.0))

    def update_lunge(self, spear_cmd, senses, dist, dt=0.05):
        """Arena-like spear strike. Returns (event, aimed).

        event is 'triggered' (a strike launched this step), 'contact'
        (rival within STRIKE_REACH during the extension window), or None.
        aimed mirrors the decoder/arena gate (visible + frontal). The
        lunge boost displaces the fly along its nose vector and decays
        like arena drag, so lunges close distance instead of just
        flagging intent.
        """
        self.lunge_cooldown = max(0.0, self.lunge_cooldown - dt)
        cmd = float(spear_cmd or 0.0)
        aimed = bool(senses.get("visual_target_visible", False)) \
            and abs(float(senses.get("visual_target_azimuth", 0.0))) < 50.0
        event = None
        if cmd > self.LUNGE_TRIGGER and self.lunge_cooldown <= 0.0:
            self.lunge_cooldown = self.LUNGE_COOLDOWN
            self.lunge_t = self.LUNGE_TIME
            self.lunge_boost = self.LUNGE_KICK * min(max(cmd, 0.0), 1.0)
            self.lunge_count += 1
            event = "triggered"
        if self.lunge_t > 0.0:
            self.lunge_t = max(0.0, self.lunge_t - dt)
            self.pos += self.forward_vec() * (self.lunge_boost * dt)
            self.lunge_boost *= 0.85
            if float(dist) <= self.STRIKE_REACH:
                event = "contact"
        return event, aimed


def apply_arena_controls(fly, ctrl, senses, dist, dt=0.05):
    """Applies the full decoder control set the way the arena does.

    Consumes every control key (thrust, yaw/pitch, ram burst, evade dive,
    spear lunge) so headless training cannot silently drop a channel.
    approach_bias is pre-folded into thrust/yaw by the decoder;
    roll_torque has no axis in this 2D-heading trainer (JO-roll learns
    live in the arena). Returns the lunge (event, aimed) tuple.
    """
    thrust_eff = float(ctrl.get("thrust", 0.2))
    if ctrl.get("emergency_evade", False):
        thrust_eff *= 0.5
        pitch_eff = -1.0
    else:
        pitch_eff = float(ctrl.get("pitch_torque", 0.0))
    if ctrl.get("ram_burst", False):
        thrust_eff *= 1.5  # mirrors the arena's 1.5x ram speed
    _ = float(ctrl.get("approach_bias", 0.0))
    _ = float(ctrl.get("roll_torque", 0.0))
    fly.step(thrust=thrust_eff,
             yaw_torque=float(ctrl.get("yaw_torque", 0.0)),
             pitch_cmd=pitch_eff, dt=dt)
    return fly.update_lunge(ctrl.get("spear_thrust", 0.0), senses, dist, dt)


def compute_agent_senses(agent, target, prev_dist=None):
    """3D scent gradient + visual angles (nose-relative elevation for pitch).

    prev_dist (last step's distance) enables the rival-looming channel
    with the arena's formula; None (first step, diagnostics) reports 0.
    """
    to_target = target.pos - agent.pos
    dist = float(np.linalg.norm(to_target))
    to_target_dir = to_target / max(dist, 1e-4)
    if prev_dist is None:
        rival_looming = 0.0
    else:
        rival_looming = float(np.clip(
            ((float(prev_dist) - dist) / max(dist, 1.0)) * 5.0, 0.0, 1.0))

    # Horizontal frame for antennae/azimuth (heading only, unaffected by pitch)
    to_h = to_target[[0, 2]]
    h_dist = float(np.linalg.norm(to_h)) + 1e-4
    to_h_dir = to_h / h_dist
    forward_h = np.array([np.cos(agent.heading), np.sin(agent.heading)], dtype=np.float32)
    right_h = np.array([np.sin(agent.heading), -np.cos(agent.heading)], dtype=np.float32)

    # Scent never dies with distance: linear falloff over 150m (effectively
    # infinite inside the play area) with a constant gradient slope, so a
    # separated fly always has a trail to follow and keeps pursuit.
    # Directional smelling (mirrors the arena): strength follows where
    # the nose points - nose-on-target is full scent, facing away a faint
    # trace - so the odor gradient leads toward the rival.
    nose_dot = float(np.dot(forward_h, to_h_dir))
    face = 0.15 + 0.85 * float(np.clip((nose_dot + 0.2) / 1.2, 0.0, 1.0))
    c_base = np.clip((1.0 - dist / 150.0) * face, 0.0, 1.0)

    # Directional antenna vectors (+/- 45 deg lateral)
    ant_left = (forward_h - right_h * 0.7) / np.linalg.norm(forward_h - right_h * 0.7)
    ant_right = (forward_h + right_h * 0.7) / np.linalg.norm(forward_h + right_h * 0.7)

    align_l = float(np.dot(ant_left, to_h_dir))
    align_r = float(np.dot(ant_right, to_h_dir))

    factor_l = 0.45 + 0.55 * np.clip((align_l + 0.3) / 1.3, 0.0, 1.0)
    factor_r = 0.45 + 0.55 * np.clip((align_r + 0.3) / 1.3, 0.0, 1.0)

    c_left = float(np.clip(c_base * factor_l, 0.0, 1.0))
    c_right = float(np.clip(c_base * factor_r, 0.0, 1.0))

    # Visual azimuth (horizontal) and nose-relative elevation (for pitch)
    dot_fwd = np.clip(float(np.dot(forward_h, to_h_dir)), -1.0, 1.0)
    dot_right = np.clip(float(np.dot(right_h, to_h_dir)), -1.0, 1.0)
    azimuth_rad = np.arctan2(dot_right, dot_fwd)
    azimuth_deg = float(np.degrees(azimuth_rad))
    true_elev_deg = float(np.degrees(np.arctan2(to_target[1], h_dist)))
    apparent_elev_deg = true_elev_deg - float(np.degrees(agent.pitch))
    visible = abs(azimuth_deg) < 80.0 and abs(apparent_elev_deg) < 60.0

    # Tail-chase signal: agent sits in the target's rear hemisphere (target's
    # butt faces the agent) while facing the target's tail. Mirrors the arena
    # kill rule, so pre-training rewards the exact position that can finish.
    victim_fwd_h = np.array([np.cos(target.heading), np.sin(target.heading)], dtype=np.float32)
    to_self_h = (agent.pos[[0, 2]] - target.pos[[0, 2]])
    to_self_h = to_self_h / (float(np.linalg.norm(to_self_h)) + 1e-4)
    behind_victim = float(np.dot(victim_fwd_h, to_self_h)) < -0.15
    tail_chase = 1.0 if (behind_victim and visible and abs(azimuth_deg) < 35.0) else 0.0

    # Obstacle cone: three nose rays (-35/0/+35 relative to heading). Mirrors
    # the arena's FlyPhysics._ray_loom fan: the trainer must hand the encoder
    # the same side-gated tree channels so pre-training transfers. Rotation
    # convention flips vs Godot - here a ray at heading -0.61 points to the
    # fly's LEFT (azimuth<0), matching LPLC2-L on the arena left.
    tree_left = 0.0
    tree_ahead = 0.0
    tree_right = 0.0
    if TREES:
        fw = np.array([np.cos(agent.heading), 0.0, np.sin(agent.heading)], dtype=np.float32)

        def _rot(dir3, ang):
            x, z = float(dir3[0]), float(dir3[2])
            return np.array([x * np.cos(ang) + z * np.sin(ang), 0.0,
                             -x * np.sin(ang) + z * np.cos(ang)], dtype=np.float32)

        for name, ang in (("left", -0.61), ("ahead", 0.0), ("right", 0.61)):
            hit = ray_trunk_distance(agent.pos, _rot(fw, ang))
            loom = 0.0
            if hit is not None:
                loom = float(np.clip((OBSTACLE_RAY_LENGTH - hit) / OBSTACLE_RAY_LENGTH, 0.0, 1.0))
            if name == "left":
                tree_left = loom
            elif name == "ahead":
                tree_ahead = loom
            else:
                tree_right = loom

    # Panoramic sector grid (retina scheme; mirrors the arena's
    # FlyPhysics grid cell-for-cell): 7 azimuth columns x 3 elevation
    # bands = 21 cells. Rival occupies one cell (presence + angular size
    # + loom); 7 column rays fan the full circle for wood (no elevation).
    az_cols = (-150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0)
    wrapped_az = (azimuth_deg + 180.0) % 360.0 - 180.0
    best_col = min(range(7),
                   key=lambda ci: abs((wrapped_az - az_cols[ci] + 180.0) % 360.0 - 180.0))
    if apparent_elev_deg > 20.0:
        band = 0
    elif apparent_elev_deg < -20.0:
        band = 2
    else:
        band = 1
    sec_presence = [0.0] * 21
    sec_size = [0.0] * 21
    sec_loom = [0.0] * 21
    sec_tree = [0.0] * 21
    rcell = band * 7 + best_col
    sec_presence[rcell] = 1.0
    sec_size[rcell] = float(np.clip(1.1 / max(dist, 0.5), 0.0, 1.0))
    sec_loom[rcell] = rival_looming
    if TREES:
        fw = np.array([np.cos(agent.heading), 0.0, np.sin(agent.heading)], dtype=np.float32)

        def _rot2(dir3, ang):
            x, z = float(dir3[0]), float(dir3[2])
            return np.array([x * np.cos(ang) + z * np.sin(ang), 0.0,
                             -x * np.sin(ang) + z * np.cos(ang)], dtype=np.float32)

        for ci, acol in enumerate(az_cols):
            hit = ray_trunk_distance(agent.pos, _rot2(fw, np.radians(acol)))
            wood = 0.0
            if hit is not None:
                wood = float(np.clip(
                    (OBSTACLE_RAY_LENGTH - hit) / OBSTACLE_RAY_LENGTH, 0.0, 1.0))
            sec_tree[ci] = wood
            sec_tree[7 + ci] = wood
            sec_tree[14 + ci] = wood

    # Translational optic flow (mirrors FlyPhysics cell-for-cell):
    # ventral = horizontal speed over altitude (/2 so cruise reads
    # ~FLOW_CRUISE), expansion/climb from vertical speed over altitude.
    # Lateral is always 0.0 here: the kinematic fly moves along its nose
    # (no sideslip axis), so drift-cancel learns live in the arena.
    _hspeed = float(np.linalg.norm(agent.forward_vec()[[0, 2]])
                    * agent.last_speed)
    _alt = max(float(agent.pos[1]), 1.0)
    _vy = float(agent.forward_vec()[1] * agent.last_speed)
    flow_ventral = float(np.clip(_hspeed / _alt / 2.0, 0.0, 1.0))
    flow_expansion = float(np.clip(max(0.0, -_vy) / _alt / 2.0, 0.0, 1.0))
    flow_climb = float(np.clip(max(0.0, _vy) / _alt / 2.0, 0.0, 1.0))
    return {
        "pheromone_conc_left": c_left,
        "pheromone_conc_right": c_right,
        "visual_target_azimuth": azimuth_deg,
        "visual_target_elevation": apparent_elev_deg,
        "visual_target_visible": visible,
        "visual_rival_looming": rival_looming,
        "visual_tree_left_looming": tree_left,
        "visual_tree_ahead_looming": tree_ahead,
        "visual_tree_right_looming": tree_right,
        "visual_tree_looming": max(tree_left, tree_ahead, tree_right),
        "visual_looming_rate": max(rival_looming, tree_left, tree_ahead,
                                   tree_right),
        "altitude": float(agent.pos[1]),
        "tail_chase": tail_chase,
        "visual_flow_ventral": flow_ventral,
        "visual_flow_lateral": 0.0,
        "visual_flow_expansion": flow_expansion,
        "visual_flow_climb": flow_climb,
        "visual_sec_presence": sec_presence,
        "visual_sec_size": sec_size,
        "visual_sec_loom": sec_loom,
        "visual_sec_tree": sec_tree,
        # JO-gyro synth: trainer-frame angular rates normalized like the
        # arena (yaw/turn_rate, pitch/pitch_rate). No roll axis in 2D.
        # Sign: trainer heading DECREASES on right turns (heading -= yaw
        # * rate), so dh/dt is negative for rightward spin while the
        # arena/conventions read + as right - negate to match.
        "angular_yaw_rate": float(np.clip(-agent.yaw_rate / 8.0, -1.0, 1.0)),
        "angular_pitch_rate": float(np.clip(agent.pitch_rate_applied / 2.5, -1.0, 1.0)),
        "angular_roll_rate": 0.0
    }, dist


VARIANTS = {
    # Charger (Fly Alpha): rewards raw closing speed, sluggish target.
    "A": dict(label="charger", seed=11, learning_rate=0.008,
              dist_gain=0.25, align_bonus=(0.5, 0.2, -0.3),
              target_evasion=0.2, save_name="trained_homing_A.npz"),
    # Flanker (Fly Beta): rewards gaze fixation, evasive target.
    "B": dict(label="flanker", seed=77, learning_rate=0.010,
              dist_gain=0.08, align_bonus=(0.9, 0.4, -0.5),
              target_evasion=0.6, save_name="trained_homing_B.npz"),
}


def run_training(num_episodes=50, max_steps_per_episode=120, variant="A",
                 save_name=None, seed=None, target_evasion=0.2,
                 learning_rate=0.008, dist_gain=0.15, align_bonus=(0.5, 0.2, -0.3),
                 experiment=None, init_weights=None, progress_cb=None,
                 return_brain=False, mapping=None, yaw_bias=None, legacy=False):
    global TREES
    cfg = VARIANTS.get(variant, {})
    label = cfg.get("label", variant)
    if seed is None:
        seed = cfg.get("seed", 0)
    # Seeds may arrive as floats (JSON round-trip through the Godot menu);
    # np.random.seed(float) raises a safe-casting TypeError on NumPy 2.
    seed = int(seed)
    np.random.seed(seed)
    if save_name is None:
        save_name = cfg.get("save_name", "trained_homing_champion.npz")
    if experiment:
        base = save_name.removesuffix(".npz") if save_name.endswith(".npz") else save_name
        save_name = f"{base}{experiment_suffix(experiment)}.npz"
    target_evasion = cfg.get("target_evasion", target_evasion)
    learning_rate = cfg.get("learning_rate", learning_rate)
    dist_gain = cfg.get("dist_gain", dist_gain)
    align_bonus = cfg.get("align_bonus", align_bonus)
    print("=" * 65)
    print(f"   DOPAMINE-GATED TRAINING [{label.upper()}]: SEARCH & CLOSE-IN CURRICULUM")
    print("=" * 65)

    csr = load_or_build_csr()
    pops = load_or_extract_populations()

    # Build the brain's CSR from the base connectome plus the experimental
    # wiring (if any). Arity changes with injected edges, so checkpoints for
    # this run carry the experiment suffix and are never mixed with base files.
    indptr, indices, wbasis = experiment_arrays(experiment, csr, pops)
    start_weights = wbasis.copy() if init_weights is None else np.ascontiguousarray(
        np.asarray(init_weights, dtype=np.float32).copy())
    if len(start_weights) != len(wbasis):
        raise ValueError(
            f"init_weights arity {len(start_weights)} != connectome arity {len(wbasis)}; "
            "never mix base/experiment brains.")
    brain = FlyBrain(indptr, indices, start_weights)
    # Neuro-mapping scheme for this run (menu "Neuro mapping" dropdown):
    # encoder/decoder follow the mapping; readout-only schemes never
    # change CSR arity, so mapping is metadata unless an experiment
    # overlay is also attached.
    mapping = normalize_mapping(mapping)
    # Legacy brains (pre-mapping records) train in their original regime:
    # fused loom channel, legacy decoder operating point, no gain pinning.
    encoder = SensoryEncoder(pops, mapping=mapping, legacy=legacy)
    decoder = MotorDecoder(pops, mapping=mapping, legacy=legacy,
                           yaw_bias=yaw_bias)
    schemes = () if legacy else mapping
    dopamine_rl = DopamineReinforcement(pops, learning_rate=learning_rate,
                                        dist_gain=dist_gain, align_bonus=align_bonus,
                                        base=(indptr, indices, wbasis))
    # Gain pinning (per-episode, in dopamine_rl.pin_gains) replaces the old
    # global-mean guard: pool-aware magnitude pins preserve learned ratios
    # while stopping localized runaway in frequently-scaled rows.

    base_trees = build_trunk_field(seed=777 + int(seed))
    TREES = base_trees
    print(f"[Train] Trunk field: {len(TREES)} collision trees (seed {777 + int(seed)}).")

    print(f"[Train] Initialized FlyBrain with {brain.num_neurons:,} neurons.")
    print(f"[Train] Running {num_episodes} training episodes (max {max_steps_per_episode * 0.05:.1f}s each)...")

    results = []

    for ep in range(1, num_episodes + 1):
        # Spawn Fly Alpha and Target Fly at starting positions (~28m apart)
        # Randomize target position slightly to prevent overfitting
        target_x = 12.0 + np.random.uniform(-4.0, 4.0)
        target_z = np.random.uniform(-8.0, 8.0)
        target = KinematicFly(x=target_x, z=target_z, heading_rad=np.pi)

        # Half the episodes are knock-recovery upsets: random altitude and a
        # knocked nose (up/down) the fly must level out of while re-engaging.
        upset = (np.random.rand() < 0.5)
        # Learning Fly starts at opposite end facing the target head-on
        # (plus small jitter). Fully random headings trained circling/search;
        # head-on spawns train direct jousting and match the arena.
        start_x = -14.0 + np.random.uniform(-2.0, 2.0)
        start_z = np.random.uniform(-4.0, 4.0)
        start_heading = float(np.arctan2(target_z - start_z, target_x - start_x)
                              + np.random.uniform(-0.4, 0.4))
        if upset:
            fly = KinematicFly(x=start_x, y=float(np.random.uniform(4.0, 22.0)), z=start_z,
                               heading_rad=start_heading,
                               pitch_rad=float(np.random.uniform(-1.0, 1.0)))
        else:
            fly = KinematicFly(x=start_x, z=start_z, heading_rad=start_heading)

        # Encounter curriculum: open runs, slalom gates, and forest crossings.
        # Difficulty ramps with progress (gaps shrink 3.5->2.2m, clusters grow
        # 4->8 trunks) so the fly keeps meeting wood it must actively avoid
        # instead of getting lucky clean corridors.
        progress = ep / max(num_episodes, 1)
        roll = np.random.rand()
        if roll < 0.30:
            enc_type = "OPEN"
            extra = []
        elif roll < 0.65:
            enc_type = "SLALOM"
            t = float(np.random.uniform(0.3, 0.7))
            gx = start_x + (target_x - start_x) * t
            gz = start_z + (target_z - start_z) * t
            dx, dz = target_x - start_x, target_z - start_z
            n = max(np.hypot(dx, dz), 1e-4)
            px, pz = -dz / n, dx / n # perpendicular
            gap = float(3.5 + (2.2 - 3.5) * progress)
            extra = [(gx + px * off, gz + pz * off, 0.9, 16.0) for off in (-gap, 0.0, gap)]
        else:
            enc_type = "FOREST"
            mx = (start_x + target_x) / 2.0 + float(np.random.uniform(-4.0, 4.0))
            mz = (start_z + target_z) / 2.0 + float(np.random.uniform(-4.0, 4.0))
            ntrees = 4 + int(progress * 4.0)
            placed_c = []
            tries = 0
            while len(placed_c) < ntrees and tries < 200:
                tries += 1
                cx = mx + float(np.random.uniform(-7.0, 7.0))
                cz = mz + float(np.random.uniform(-7.0, 7.0))
                if all(np.hypot(cx - qx, cz - qz) >= 3.0 for qx, qz in placed_c):
                    placed_c.append((cx, cz))
            extra = [(cx, cz, 0.9, 16.0) for cx, cz in placed_c]
        TREES = base_trees + extra

        brain.reset_state()
        # Per-episode depression budget: a pool may lose at most half
        # its magnitude per episode, so one bad episode can never grind
        # a channel into the abandonment gap (the recurring vault-wide
        # collapse). Potentiation is never budgeted.
        dopamine_rl.begin_episode(brain)

        _, prev_dist = compute_agent_senses(fly, target)
        initial_dist = prev_dist
        total_da = 0.0
        success = False
        strike = False
        crashed = False
        close_calls = 0
        lunges = 0
        strikes = 0

        t_ep_start = time.time()

        for step in range(max_steps_per_episode):
            # 1. Sense environment
            senses, current_dist = compute_agent_senses(
                fly, target, prev_dist=prev_dist)

            # 2. Encode sensory inputs to Poisson spike trains
            stim = encoder.encode(senses)

            # 3. Simulate 50 ms in biological LIF connectome
            spikes = brain.integrate_50ms(stim)

            # 4. Decode descending motor controls (brain + reflex assist)
            ctrl = decoder.decode(spikes, sensory_hint=senses)

            # 5. Compute Dopamine reward (closing distance + gaze alignment + tail chase)
            da = dopamine_rl.compute_reward(
                current_dist=current_dist,
                prev_dist=prev_dist,
                azimuth_deg=senses["visual_target_azimuth"],
                dt=0.05,
                tail_chase=senses.get("tail_chase", 0.0),
                ventral=senses.get("visual_flow_ventral", 0.0),
                schemes=schemes
            )
            # Recovery shaping: penalize knocked attitudes and ceiling/floor
            # excursions so the brain learns pursuit policies that stay
            # flyable (level, in-band) instead of, e.g., firewalling thrust
            # while pointed at the sky.
            alt = senses.get("altitude", 7.0)
            da -= abs(fly.pitch) * 0.4
            if alt < 2.0 or alt > 24.0:
                da -= 0.5
            # Proximity shaping: dense punishment for flying close to bark,
            # not just for hitting it. Contact is rare; near-misses are the
            # teachable signal (up to -1.8 at skin distance).
            skin = nearest_trunk_distance(fly)
            if skin < 3.0:
                da -= (3.0 - skin) * 0.6
                if skin < 2.0:
                    close_calls += 1
            total_da += da

            # 6. Update physics through the arena control application
            # (full control set: thrust/yaw/pitch, ram burst, evade dive,
            # spear lunge with cooldown + extension window + contact).
            lunge_event, lunge_aimed = apply_arena_controls(
                fly, ctrl, senses, current_dist, dt=0.05)
            # Target fly evasion: variant B trains against a twitchier target.
            target.step(thrust=0.15, yaw_torque=np.random.uniform(-target_evasion, target_evasion), dt=0.05)

            # 6b. Spear shaping: aimed committed lunges earn a little,
            # blind or wild long-range lunges cost, and contact pays big
            # and ends the episode as a strike kill.
            if lunge_event == "triggered":
                lunges += 1
                if lunge_aimed and current_dist <= 6.0:
                    da += 0.3
                elif current_dist > 8.0:
                    # Softened: punished lunges share rows with pursuit
                    # thrust (retina_wide), so wild-lunge taxes stay
                    # small — the miss itself is the lesson.
                    da -= 0.1
                else:
                    da -= 0.15
            elif lunge_event == "contact":
                lunges += 1
                strikes += 1
                da += 2.0
                strike = True

            # 7. Apply Dopamine-Gated Plasticity (run's own schemes: new
            # branches learn only on brains generated from those schemes).
            # Micro-gain cap: 6000 calls/session must stay micro, or high
            # learning rates compound into mid-episode runaway.
            dopamine_rl.apply_plasticity(brain, senses, ctrl, da,
                                         schemes=schemes, gain_cap=0.02)

            # 8. Trunk collision: same tiers as the arena. Two fast slams kill.
            # Crashes cost health plus a full aversive pulse (depress the
            # mapping that flew into the tree); zero health ends the episode
            # as a crash, not a hunt.
            crash = check_trunk_collision(fly)
            if crash is not None:
                impact, _tx, _tz = crash
                if impact > 11.0:
                    fly.health -= 50.0
                elif impact > 6.5:
                    fly.health -= 15.0
                if fly.health > 0.0:
                    da_crash = -2.0
                    total_da += da_crash
                    dopamine_rl.apply_plasticity(brain, senses, ctrl, da_crash,
                                                 schemes=schemes, gain_cap=0.02)
                else:
                    crashed = True
                    break

            prev_dist = current_dist

            # Success threshold: spear contact kills outright; otherwise
            # closing within striking distance (3.5m) ends the hunt.
            if strike or current_dist < 3.5:
                success = True
                break

        ep_duration = (step + 1) * 0.05
        distance_closed = initial_dist - current_dist
        results.append({
            "episode": ep,
            "initial_dist": initial_dist,
            "final_dist": current_dist,
            "closed": distance_closed,
            "success": success,
            "strike": strike,
            "upset": upset,
            "crashed": crashed,
            "enc": enc_type,
            "close_calls": close_calls,
            "lunges": lunges,
            "strikes": strikes,
            "avg_da": total_da / (step + 1)
        })

        tag = ("UPSET+" if upset else "") + enc_type
        if crashed:
            status_str = "CRASHED into trunk!"
        elif strike:
            status_str = "SUCCESS (SPEAR STRIKE!)"
        elif success:
            status_str = "SUCCESS (RAM RANGE!)"
        else:
            status_str = f"Closed {distance_closed:+.1f}m"
        print(f"[Episode {ep:02d}/{num_episodes:02d} {tag:12s}] "
              f"Dist: {initial_dist:.1f}m -> {current_dist:.1f}m | "
              f"Avg DA: {total_da / (step + 1):+.2f} | "
              f"Time: {ep_duration:.2f}s | {status_str}")

        # Pool-aware gain pinning: preserve learned ratios, pin magnitudes
        # to the reference wiring (replaces the old global-mean guard,
        # which allowed localized runaway in frequently-scaled rows:
        # sensory efferents were measured at 100x base). Skipped for
        # legacy brains, whose regime never had it.
        dopamine_rl.pin_gains(brain, legacy=legacy)
        if progress_cb is not None:
            try:
                progress_cb(ep, num_episodes)
            except Exception:
                pass

    # Save the trained variant weights
    save_path = os.path.join(CHECKPOINTS_DIR, save_name)
    np.savez_compressed(save_path, weights=brain.weights)
    print(f"\n[Train:{label}] Training complete! Saved {label} weights to {save_path}")

    # Summary statistics
    successes = sum(1 for r in results if r["success"])
    avg_closed = np.mean([r["closed"] for r in results])
    upset_eps = [r for r in results if r.get("upset")]
    upset_ok = sum(1 for r in upset_eps if r["success"])
    print(f"[Train:{label}] Results Summary: {successes}/{num_episodes} reached strike range. Average distance closed: {avg_closed:.1f} meters.")
    if upset_eps:
        print(f"[Train:{label}] Upset recovery: {upset_ok}/{len(upset_eps)} knock-spawn episodes recovered to strike range.")
    crashes = sum(1 for r in results if r.get("crashed"))
    print(f"[Train:{label}] Tree crashes: {crashes}/{num_episodes} episodes ended in a trunk.")
    lunges_tot = sum(r.get("lunges", 0) for r in results)
    strikes_tot = sum(r.get("strikes", 0) for r in results)
    print(f"[Train:{label}] Spear lunges: {lunges_tot} triggered, {strikes_tot} contacts.")
    close_tot = sum(r.get("close_calls", 0) for r in results)
    print(f"[Train:{label}] Close calls (<2m bark): {close_tot} steps total.")
    for et in ("SLALOM", "FOREST"):
        eps = [r for r in results if r.get("enc") == et]
        if eps:
            ok = sum(1 for r in eps if r["success"])
            print(f"[Train:{label}] {et}: {ok}/{len(eps)} threaded to strike range.")
    summary = {"successes": successes, "episodes": num_episodes,
               "avg_closed": float(avg_closed), "crashes": crashes,
               "close_calls": close_tot}
    if return_brain:
        return save_path, np.ascontiguousarray(brain.weights.copy()), summary
    return save_path


def run_dual_training(num_episodes=100, experiment=None):
    """Trains two distinct variants: charger (A) and flanker (B)."""
    suffix = experiment_suffix(experiment)
    path_a = run_training(num_episodes=num_episodes, variant="A", experiment=experiment)
    path_b = run_training(num_episodes=num_episodes, variant="B", experiment=experiment)
    # Keep a legacy single-file champion (charger) for backward compat.
    import shutil
    legacy = os.path.join(CHECKPOINTS_DIR, f"trained_homing_champion{suffix}.npz")
    shutil.copyfile(path_a, legacy)
    print(f"[Train] Dual training complete:\n  Alpha (charger): {path_a}\n  Beta (flanker):  {path_b}")
    return path_a, path_b


if __name__ == "__main__":
    run_dual_training(num_episodes=100, experiment=os.environ.get("EXPERIMENT") or None)
