import os
import sys
import time
import json
import numpy as np

from connectome_loader import load_or_build_csr, load_or_extract_populations
from lif_brain import FlyBrain
from sensory_motor import (SensoryEncoder, MotorDecoder, normalize_mapping,
                            drive_speed, RAM_EXTRA, SPEED_CAP, RAM_TIME,
                            RAM_COOLDOWN)
from dopamine_learning import DopamineReinforcement
from experimental_wiring import (experiment_arrays, experiment_suffix,
                                   build_genome_arrays, genome_suffix,
                                   genome_label, normalize_experiment)

# Wiring struct cache (mirrors brain_server._bind_brain): indptr/indices/
# wbasis per wiring, so multi-stage breeds/trains stop rebuilding the
# ~25M-edge overlay add per stage. Keyed by wiring identity + CSR object
# (the loader memo keeps the object alive, so ids are stable and a changed
# CSR file forces a rebuild). Capped at 4 wirings (~200 MB each).
_WIRING_STRUCT_CACHE = {}

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
    def __init__(self, x=0.0, y=7.0, z=0.0, heading_rad=0.0, pitch_rad=0.0,
                 anchored=False):
        self.pos = np.array([x, y, z], dtype=np.float32)
        self.heading = heading_rad # 0 rad = facing along +X (yaw)
        self.pitch = pitch_rad     # >0 = nose up (matches Godot rotate_x sign)
        # Anchored targets (stationary camp scenario) never move; their
        # pheromone still smells like a rival (area battle).
        self.anchored = bool(anchored)
        # Spear-lunge state (arena-like): cooldown between strikes,
        # extension-window timer, and decaying lunge boost (m/s).
        self.lunge_cooldown = 0.0
        self.lunge_t = 0.0
        self.lunge_boost = 0.0
        self.lunge_count = 0
        # base_speed stays for mover-target scoring normalization;
        # the AGENT fly itself has no base cruise (hover at zero drive).
        self.base_speed = 3.0
        self.max_speed = 12.0
        self.turn_rate = 8.0 # matches FlyPhysics: hover-capable snap turns
        self.pitch_rate = 2.5 # matches FlyPhysics pitch_rate
        self.health = 100.0
        self.last_speed = 0.0
        # Body angular rates (rad/s), refreshed every step: the trainer's
        # JO-gyro synth. Roll integrates from roll_cmd with auto-level
        # toward wings-level (mirrors the arena); zero command holds
        # zero bank, so legacy episodes (roll_cmd 0) are byte-identical.
        self.yaw_rate = 0.0
        self.pitch_rate_applied = 0.0
        self.roll = 0.0
        self.roll_rate = 3.0
        self.roll_rate_applied = 0.0
        # Scent dynamics (mirrors FlyPhysics cell-for-cell): smoothed
        # total for surge, lost-timer for search, free-running cast.
        self.scent_prev_smooth = -1.0
        self.scent_lost_time = 0.0
        self.scent_cast_phase = 0.0
        # Seizure state (behavioral detector: saturated yaw + spin).
        self.seizure_time = 0.0
        self.seizure_clear = 0.0
        self.seizing = False
        self.seizure_events = 0
        # Crosswind gusts: the kinematic fly moves along its nose, so
        # without gusts lateral flow would stay exactly zero and drift
        # behavior could only ever learn live in the arena.
        self.gust_steps = 0
        self.gust_val = 0.0
        # Ram charge refractory (mirrors FlyPhysics RAM_TIME/COOLDOWN):
        # one charge window per sustained DNpe017 drive.
        self.ram_t = 0.0
        self.ram_cooldown = 0.0
        self.ram_latched = 0.0
        self.ram_charges = 0
        # Strike-contact recovery (arena asymmetry: scripted targets
        # have no physics to exchange momentum with, so the attacker
        # alone loses momentum on contact instead).
        self.slow_t = 0.0
        # Ground-scrape detection (mirror FlyPhysics scrape_time): the
        # floor band; the train loop pays a per-step aversive on this
        # signal, so ground-clipping learns away.
        self.scrape_time = 0.0
        self.ground_now = 0.0

    def forward_vec(self):
        cp = float(np.cos(self.pitch))
        return np.array([cp * np.cos(self.heading), float(np.sin(self.pitch)),
                         cp * np.sin(self.heading)], dtype=np.float32)

    def right_vec(self):
        # Horizontal right vector for the dual-antenna scent model.
        return np.array([np.sin(self.heading), 0.0, -np.cos(self.heading)], dtype=np.float32)

    def ram_charge_tick(self, dt, drive):
        """Effective ram headroom this tick (mirrors FlyPhysics
        _ram_charge_tick): latched rate during the window, 0 in the
        refractory. Thresholds kept in sync."""
        self.ram_cooldown = max(0.0, self.ram_cooldown - dt)
        if self.ram_t > 0.0:
            self.ram_t = max(0.0, self.ram_t - dt)
            return self.ram_latched
        if drive > 0.0 and self.ram_cooldown <= 0.0:
            self.ram_t = RAM_TIME
            self.ram_cooldown = RAM_COOLDOWN
            self.ram_latched = float(np.clip(drive, 0.0, 1.0))
            self.ram_charges += 1
            return self.ram_latched
        return 0.0

    def step(self, thrust, yaw_torque, pitch_cmd=0.0, dt=0.05,
             arena_radius=55.0, roll_cmd=0.0, ram_drive=0.0):
        prev_heading, prev_pitch, prev_roll = \
            self.heading, self.pitch, self.roll
        if self.anchored:
            self.yaw_rate = 0.0
            self.pitch_rate_applied = 0.0
            self.roll_rate_applied = 0.0
            self.last_speed = 0.0
            return
        # Update heading and pitch (pitch self-stabilizes toward level)
        self.heading -= yaw_torque * self.turn_rate * dt
        self.heading = (self.heading + np.pi) % (2.0 * np.pi) - np.pi
        self.pitch += (pitch_cmd * self.pitch_rate - self.pitch * 1.2) * dt
        self.pitch = float(np.clip(self.pitch, -1.2, 1.2))
        # Roll integrates from command, auto-levels toward wings-level
        # (mirrors FlyPhysics: strong level at ~0 command, weak in a
        # bank). Banked turns couple into heading like the arena's
        # rotated body axes. Zero command holds zero: legacy identical.
        self.roll += float(roll_cmd) * self.roll_rate * dt
        lvl = 2.5 if abs(float(roll_cmd)) < 0.01 else 1.0
        self.roll += (0.0 - self.roll) * min(1.0, lvl * dt)
        self.roll = float(np.clip(self.roll, -0.9, 0.9))
        self.heading -= self.roll * 1.5 * dt
        self.heading = (self.heading + np.pi) % (2.0 * np.pi) - np.pi

        # Activation-driven cruise (no base speed): motor activation
        # maps to speed on the shared log curve (hover at zero drive),
        # plus the ram charge headroom (refractory: one per window).
        # Mirrors FlyPhysics target speed - keep the two in sync.
        # Lunge transients ride on top (decaying boost below); the
        # hard cap binds sustained abuse.
        eff_ram = self.ram_charge_tick(dt, ram_drive)
        # Strike-contact recovery: a landing lunge costs momentum
        # (cruise 0.6x for 1 s), so spearing is not free.
        self.slow_t = max(0.0, self.slow_t - dt)
        slow = 0.6 if self.slow_t > 0.0 else 1.0
        cruise = min(drive_speed(thrust)
                     + RAM_EXTRA * float(np.clip(eff_ram, 0.0, 1.0)),
                     SPEED_CAP) * slow
        speed = float(cruise)
        self.last_speed = float(speed)
        self.pos += self.forward_vec() * (speed * dt)
        # Hard altitude limits (mirror FlyPhysics CEILING/FLOOR)
        self.pos[1] = float(np.clip(self.pos[1], 0.5, 30.0))
        # Ground-scrape signal: in the floor band (bumping or clip-
        # through). Refreshed per step; the train loop feeds it to the
        # dopamine term.
        if self.pos[1] <= 0.8:
            self.scrape_time += dt
            self.ground_now = 1.0
        else:
            self.ground_now = 0.0

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
        self.roll_rate_applied = float(np.clip((self.roll - prev_roll) / dt, -3.0, 3.0))

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
                self.slow_t = 1.0  # contact momentum loss (recovery)
        return event, aimed


# Seizure detection (behavioral, motor-output level): a saturated yaw
# command that is actually spinning the body, sustained over
# SEIZURE_WINDOW, latches seizing and drains health in small increments.
# Distinct from the disproven T4-recurrence hypothesis (no neural refire
# persists tick to tick); this watches what the body does. Thresholds
# mirror FlyPhysics.seizure_tick — keep the two in sync.
SEIZURE_YAW_CMD = 0.85    # |yaw_torque| above this counts as saturated
SEIZURE_YAW_RATE = 2.0    # measured |yaw_rate| (rad/s) above this = spinning
SEIZURE_WINDOW = 1.5      # sustained seconds before onset
SEIZURE_RECOVER = 1.0     # clear seconds before the accumulator resets
SEIZURE_DRAIN = 3.0       # health per second while seizing (slow bleed)
SEIZURE_DA = -0.3         # aversive pulse per step while seizing


def update_seizure(fly, yaw_cmd, dt=0.05):
    """Advance the seizure state machine on fly.seizure_time/_clear/
    seizing/seizure_events. Returns (seizing, onset). Pure enough for
    headless unit tests (needs only fly.yaw_rate refreshed)."""
    t = float(getattr(fly, "seizure_time", 0.0))
    c = float(getattr(fly, "seizure_clear", 0.0))
    was = bool(getattr(fly, "seizing", False))
    if abs(float(yaw_cmd)) > SEIZURE_YAW_CMD \
            and abs(float(fly.yaw_rate)) > SEIZURE_YAW_RATE:
        t += dt
        c = 0.0
    else:
        c += dt
        if c >= SEIZURE_RECOVER:
            t = 0.0
    seizing = t >= SEIZURE_WINDOW and c < SEIZURE_RECOVER
    fly.seizure_time, fly.seizure_clear, fly.seizing = t, c, seizing
    if seizing and not was:
        fly.seizure_events = int(getattr(fly, "seizure_events", 0)) + 1
    return seizing, (seizing and not was)


def apply_arena_controls(fly, ctrl, senses, dist, dt=0.05):
    """Applies the full decoder control set the way the arena does.

    Consumes every control key (thrust, yaw/pitch/roll, ram burst,
    evade dive, spear lunge) so headless training cannot silently drop
    a channel. approach_bias is pre-folded into thrust/yaw by the
    decoder. Returns the lunge (event, aimed) tuple.
    """
    thrust_eff = float(ctrl.get("thrust", 0.2))
    if ctrl.get("emergency_evade", False):
        thrust_eff *= 0.5
        pitch_eff = -1.0
    else:
        pitch_eff = float(ctrl.get("pitch_torque", 0.0))
    ram_drive = float(ctrl.get("ram_drive", 0.0))
    if ram_drive <= 0.0 and bool(ctrl.get("ram_burst", False)):
        ram_drive = 1.0  # legacy callers pass the gate without a rate
    _ = float(ctrl.get("approach_bias", 0.0))
    fly.step(thrust=thrust_eff,
             yaw_torque=float(ctrl.get("yaw_torque", 0.0)),
             pitch_cmd=pitch_eff, dt=dt, ram_drive=ram_drive,
             roll_cmd=float(ctrl.get("roll_torque", 0.0)))
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

    # Scent dynamics, part 1 (mirrors FlyPhysics 2b): surge on rising
    # total. Trainer steps are 50 ms like brain ticks.
    _sdt = 0.05
    _total = c_left + c_right
    if agent.scent_prev_smooth < 0.0:
        agent.scent_prev_smooth = _total
    _smooth = agent.scent_prev_smooth + (_total - agent.scent_prev_smooth) * min(1.0, _sdt * 2.0)
    scent_surge = float(np.clip((_smooth - agent.scent_prev_smooth) / _sdt * 3.0, 0.0, 1.0))
    agent.scent_prev_smooth = _smooth

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

    # Scent dynamics, part 2: floor-relative lost timer (usable scent
    # or eyes reset it) + free-running cast bias for search steering.
    if _total > 0.12 or visible:
        agent.scent_lost_time = 0.0
    else:
        agent.scent_lost_time += _sdt
    agent.scent_cast_phase += _sdt * 0.8
    scent_cast = float(np.sin(agent.scent_cast_phase))

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
    # Lateral comes from crosswind gust windows (2-4 s, bounded): the
    # kinematic fly moves along its nose, so without gusts drift-cancel
    # could only ever learn live in the arena.
    _hspeed = float(np.linalg.norm(agent.forward_vec()[[0, 2]])
                    * agent.last_speed)
    _alt = max(float(agent.pos[1]), 1.0)
    _vy = float(agent.forward_vec()[1] * agent.last_speed)
    flow_ventral = float(np.clip(_hspeed / _alt / 2.0, 0.0, 1.0))
    flow_expansion = float(np.clip(max(0.0, -_vy) / _alt / 2.0, 0.0, 1.0))
    flow_climb = float(np.clip(max(0.0, _vy) / _alt / 2.0, 0.0, 1.0))
    if agent.gust_steps <= 0:
        agent.gust_val = 0.0
        if np.random.rand() < 0.008:
            agent.gust_steps = int(np.random.uniform(40, 80))
            agent.gust_val = float(np.random.uniform(-0.6, 0.6))
    else:
        agent.gust_steps -= 1
    flow_lateral = float(np.clip(agent.gust_val, -1.0, 1.0))
    return {
        "pheromone_conc_left": c_left,
        "pheromone_conc_right": c_right,
        "scent_lost": agent.scent_lost_time,
        "scent_cast": scent_cast,
        "scent_surge": scent_surge,
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
        "visual_flow_lateral": flow_lateral,
        "visual_flow_expansion": flow_expansion,
        "visual_flow_climb": flow_climb,
        "visual_sec_presence": sec_presence,
        "visual_sec_size": sec_size,
        "visual_sec_loom": sec_loom,
        "visual_sec_tree": sec_tree,
        # JO-gyro synth: trainer-frame angular rates normalized like the
        # arena (yaw/turn_rate, pitch/pitch_rate, roll/roll_rate).
        # Sign: trainer heading DECREASES on right turns (heading -= yaw
        # * rate), so dh/dt is negative for rightward spin while the
        # arena/conventions read + as right - negate to match.
        "angular_yaw_rate": float(np.clip(-agent.yaw_rate / 8.0, -1.0, 1.0)),
        "angular_pitch_rate": float(np.clip(agent.pitch_rate_applied / 2.5, -1.0, 1.0)),
        "angular_roll_rate": float(np.clip(agent.roll_rate_applied / 3.0, -1.0, 1.0))
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


# ── Advanced Flight School ────────────────────────────────────────────
# Scenario registry curriculum. Behavior (target CAMP/MOVER/DUEL) and
# environment (OPEN/SLALOM/FOREST) draw independently per episode, so
# every combination randomizes and no layout ever repeats. Difficulty
# sets DISTRIBUTIONS (lerped by progress), never fixed values, so brains
# learn goals (close the tail, spike the target, dodge wood), not
# patterns. Activated by run_training(curriculum={...}); None (default)
# runs the legacy curriculum byte-identically.
SCHOOL_BEHAVIORS = ("camp", "mover", "duel", "dodge", "stalk")
SCHOOL_ENVS = ("open", "slalom", "forest")
SCHOOL_STAGES = [
    {"until": 0.30,
     "behaviors": {"camp": 0.5, "mover": 0.2, "duel": 0.2,
                   "dodge": 0.05, "stalk": 0.05},
     "envs": {"open": 0.5, "slalom": 0.3, "forest": 0.2}},
    {"until": 0.65,
     "behaviors": {"camp": 0.25, "mover": 0.3, "duel": 0.3,
                   "dodge": 0.1, "stalk": 0.05},
     "envs": {"open": 0.3, "slalom": 0.35, "forest": 0.35}},
    {"until": 1.01,
     "behaviors": {"camp": 0.15, "mover": 0.35, "duel": 0.25,
                   "dodge": 0.15, "stalk": 0.1},
     "envs": {"open": 0.2, "slalom": 0.3, "forest": 0.5}},
]
# Difficulty endpoints [start, end] lerped by progress; curriculum JSON
# may override any key.
SCHOOL_DIFFICULTY = {
    "camp_dist": [20.0, 35.0],
    "camp_ring": [0, 8],
    "mover_speed": [4.0, 9.0],
    "mover_waypoints": [2, 5],
    "mover_wobble": [0.05, 0.25],
    "trunks": [12, 28],
    "gap": [3.5, 2.2],
    "upset": [0.3, 0.7],
    "heading_jitter": [0.4, 1.2],
    "dodge_speed": [4.0, 9.0],
    "dodge_dist": [15.0, 25.0],
}
SCHOOL_TAKEDOWN_PAY = 4.5
SCHOOL_TAIL_RATE = 1.0
# Mover path lessons: archetype draw is stage-gated like behaviors
# (early tiers drill weave/zigzag/slow-circle; double-back and fast
# circle unlock late). Curriculum JSON may override the whole table
# via "mover_archetypes". Speed mults pace each lesson relative to
# mover_speed (double-back slightly faster; circles split slow/fast).
MOVER_ARCHETYPES = ("patrol", "weave", "flee", "orbit",
                    "zigzag", "doubleback", "circle_slow", "circle_fast")
MOVER_ARCHETYPE_STAGES = [
    {"until": 0.30,
     "archetypes": {"patrol": 0.2, "weave": 0.2, "flee": 0.15,
                    "orbit": 0.15, "zigzag": 0.2, "doubleback": 0.0,
                    "circle_slow": 0.1, "circle_fast": 0.0}},
    {"until": 0.65,
     "archetypes": {"patrol": 0.15, "weave": 0.15, "flee": 0.1,
                    "orbit": 0.1, "zigzag": 0.2, "doubleback": 0.1,
                    "circle_slow": 0.15, "circle_fast": 0.05}},
    {"until": 1.01,
     "archetypes": {"patrol": 0.1, "weave": 0.1, "flee": 0.1,
                    "orbit": 0.1, "zigzag": 0.15, "doubleback": 0.2,
                    "circle_slow": 0.1, "circle_fast": 0.15}},
]
ARCHETYPE_SPEED_MULT = {"patrol": 1.0, "weave": 1.0, "flee": 1.1,
                         "orbit": 1.0, "zigzag": 1.0, "doubleback": 1.15,
                         "circle_slow": 0.8, "circle_fast": 1.2}
# Stalk gaze lessons want lateral sweepers, never fleeing targets:
# flat table (no tier gating), curriculum "mover_archetypes" still wins.
STALK_ARCHETYPES = {"zigzag": 0.30, "weave": 0.25, "doubleback": 0.15,
                    "circle_slow": 0.10, "circle_fast": 0.10,
                    "patrol": 0.05, "orbit": 0.05, "flee": 0.0}
# Pre-training score (per episode): scenario-weighted reaching beats
# distance partial credit; skill skills (dodge/stalk/gates) score the
# lessons themselves; crashes earn nothing. Curriculum JSON may
# override any weight. NOTE: skill composition re-baselines stamped
# scores - pre-skill eval numbers are not comparable with post-skill
# ones (ELO/battles/titles are separate systems, unaffected).
SCHOOL_SCORE_WEIGHTS = {
    "takedown": 10.0,   # spike kill (mover/duel takedowns)
    "camp": 8.0,        # camp capture (arrival bonus paid)
    "dodge": 8.0,       # clean head-on pass (untouched, min_dist < 8m)
    "reach": 6.0,       # other-scenario success (3.5m / spear contact)
    "partial_max": 4.0, # distance-closed fraction when not reaching
    "gaze": 4.0,        # stalk lock fraction when not reaching
    "gate": 2.0,        # slalom gate threaded (stacks, capped at takedown)
}
# Scenario predictiveness multipliers, fitted against ELO (see the
# score-correlations CLI report): behavior × env scales the
# non-takedown base so school points track combat rating instead of
# rewarding ELO-neutral navigation. Defaults 1.0 = legacy scoring;
# curriculum "scenario_mult" {"behaviors": {}, "envs": {}} overrides.
# Fitted 2026-09-27 against ELO (score-correlations, n=23
# battle-tested brains, seed-7 probes): camp/open/slalom predict,
# dodge strongly anti-predicts (fighters ram through dodge passes
# instead of threading them cleanly), forest mildly anti-predicts,
# duel is table stakes (r~0). Refit as the meta evolves; changing
# these re-baselines future scores (banked history is untouched).
SCENARIO_BEHAVIOR_MULT = {
    "camp": 1.40, "mover": 1.16, "duel": 1.00, "dodge": 0.38,
    "stalk": 1.05,
}
SCENARIO_ENV_MULT = {
    "open": 1.04, "slalom": 1.23, "forest": 0.77,
}


def _scenario_mult(entry, curriculum):
    """Behavior × env multiplier for this episode's scenario family
    ("DUEL+OPEN" style keys, case-insensitive; unknown families 1.0)."""
    override = (curriculum or {}).get("scenario_mult", {}) or {}
    beh_tab = dict(SCENARIO_BEHAVIOR_MULT)
    beh_tab.update(override.get("behaviors", {}) or {})
    env_tab = dict(SCENARIO_ENV_MULT)
    env_tab.update(override.get("envs", {}) or {})
    parts = str(entry.get("scenario", "") or "").lower().split("+")
    beh = beh_tab.get(parts[0], 1.0) if parts and parts[0] else 1.0
    env = env_tab.get(parts[1], 1.0) if len(parts) > 1 else 1.0
    try:
        return max(0.0, float(beh) * float(env))
    except (TypeError, ValueError):
        return 1.0


def _school_score(entry, curriculum):
    """Pre-training score for one episode from its results entry."""
    w = dict(SCHOOL_SCORE_WEIGHTS)
    w.update((curriculum or {}).get("score_weights", {}) or {})
    if entry.get("takedown", False):
        return float(w["takedown"])
    if entry.get("camp", False):
        base = float(w["camp"])
    elif entry.get("dodge", False) and entry.get("success", False) \
            and not entry.get("dodge_failed", False) \
            and float(entry.get("min_dist", 1e9)) < 8.0:
        base = float(w["dodge"])
    elif entry.get("success", False):
        base = float(w["reach"])
    elif entry.get("crashed", False) or entry.get("seized_out", False):
        return 0.0
    elif entry.get("dodge", False):
        # Failed dodge passes earn nothing (the lesson is the miss).
        base = 0.0
    elif float(entry.get("gaze_lock_frac", 0.0)) > 0.0:
        # Stalk tracking quality replaces distance partial credit.
        base = float(np.clip(float(entry.get("gaze_lock_frac", 0.0)),
                             0.0, 1.0)) * float(w["gaze"])
    else:
        initial = max(float(entry.get("initial_dist", 1.0)), 1e-6)
        frac = float(np.clip(float(entry.get("closed", 0.0)) / initial,
                             0.0, 1.0))
        base = frac * float(w["partial_max"])
    # Scenario predictiveness: scale the base toward combat rating
    # (takedowns keep fixed supremacy above; crashes already exited).
    base = base * _scenario_mult(entry, curriculum)
    if bool(entry.get("gate_paid", False)):
        # Threading bonus stacks, capped at takedown supremacy (explicit
        # weight overrides still punch through uncapped).
        base = min(base + float(w["gate"]), float(w["takedown"]))
    return base


def _school_stage(progress, curriculum):
    """Stage dict for this progress (curriculum stages override)."""
    for stage in (curriculum.get("stages", None) or SCHOOL_STAGES):
        if progress <= float(stage.get("until", 1.0)):
            return stage
    return (curriculum.get("stages", None) or SCHOOL_STAGES)[-1]


def scenario_marginals(by_scenario):
    """Per-family {family: avg/ep} from a summary's by_scenario table:
    each "BEHAVIOR+ENV" combo contributes its points to both its
    behavior and its env marginal (episodes-weighted). Keys uppercase
    ("DUEL", "FOREST")."""
    acc = {}
    for combo, cell in (by_scenario or {}).items():
        if not isinstance(cell, dict):
            continue
        try:
            eps = int(cell.get("episodes", 0))
            sc = float(cell.get("score", 0.0))
        except (TypeError, ValueError):
            continue
        if eps <= 0:
            continue
        for part in str(combo).upper().split("+"):
            part = part.strip()
            if not part:
                continue
            a = acc.setdefault(part, {"score": 0.0, "episodes": 0})
            a["score"] += sc
            a["episodes"] += eps
    return {fam: (v["score"] / v["episodes"]) for fam, v in acc.items()}


def _school_draw(rng, weights, keys):
    """Weighted draw from a {key: weight} table (seeded stream)."""
    total = sum(max(float(weights.get(k, 0.0)), 0.0) for k in keys)
    if total <= 0.0:
        return keys[0]
    roll = float(rng.random()) * total
    acc = 0.0
    for k in keys:
        acc += max(float(weights.get(k, 0.0)), 0.0)
        if roll <= acc:
            return k
    return keys[-1]


def _school_diff(progress, curriculum, key):
    """Lerped difficulty value (curriculum override or default pair)."""
    lo, hi = (curriculum.get("difficulty", {}).get(key, None)
              or SCHOOL_DIFFICULTY[key])
    return float(lo) + (float(hi) - float(lo)) * progress


def stalk_gaze_pay(behavior, visible, az_abs, dist):
    """Gaze-tracking reward for the stalk lesson only: (pay, locked).
    Peaks dead-ahead inside spear geometry (dist <= 3m), tapering to
    zero at 35 degrees / 9 m. Every other behavior pays exactly 0.0,
    so tracking can never outbid killing elsewhere."""
    if behavior != "stalk" or not visible or az_abs > 35.0:
        return 0.0, False
    az_factor = 1.0 - az_abs / 35.0
    range_factor = float(np.clip((9.0 - dist) / 6.0, 0.0, 1.0))
    return 0.4 * az_factor * range_factor, True


def pick_school_scenario(rng, progress, curriculum):
    """(behavior, env) for this episode from the stage weight tables.
    Curriculum "pin_behaviors"/"pin_envs" lists restrict the draw to
    those families (per-scenario probes); unknown names are ignored,
    and a pin that matches nothing falls back to the full table."""
    stage = _school_stage(progress, curriculum)
    behaviors = list(SCHOOL_BEHAVIORS)
    envs = list(SCHOOL_ENVS)
    pinned_b = [b for b in ((curriculum or {}).get("pin_behaviors", []) or [])
                if str(b).lower() in behaviors]
    if pinned_b:
        behaviors = [b for b in behaviors if b in [str(p).lower() for p in pinned_b]]
    pinned_e = [e for e in ((curriculum or {}).get("pin_envs", []) or [])
                if str(e).lower() in envs]
    if pinned_e:
        envs = [e for e in envs if e in [str(p).lower() for p in pinned_e]]
    return (_school_draw(rng, stage.get("behaviors", {}), behaviors),
            _school_draw(rng, stage.get("envs", {}), envs))


def _mover_archetype(rng, progress, curriculum, behavior="mover"):
    """Stage-gated path lesson for mover episodes (curriculum JSON may
    override the tier tables via "mover_archetypes"). Stalk episodes
    draw lateral sweepers from STALK_ARCHETYPES instead (same override
    wins)."""
    override = (curriculum or {}).get("mover_archetypes", None)
    if override:
        tables = override
    elif behavior == "stalk":
        return _school_draw(rng, STALK_ARCHETYPES,
                            list(MOVER_ARCHETYPES))
    else:
        tables = MOVER_ARCHETYPE_STAGES
    for stage in tables:
        if progress <= float(stage.get("until", 1.0)):
            return _school_draw(rng, stage.get("archetypes", {}),
                                list(MOVER_ARCHETYPES))
    return _school_draw(rng, tables[-1].get("archetypes", {}),
                        list(MOVER_ARCHETYPES))


def plan_path(rng, n_waypoints, extent=30.0, archetype=None):
    """Planned target path: waypoints + per-leg speeds + archetype.

    Archetypes (sampled, mirrored): patrol (loop), weave (sinusoid),
    flee (outward spiral), orbit (circle), zigzag (tight high-frequency
    lateral chase), doubleback (pole-to-pole ping-pong with 180-degree
    reversals), circle_slow / circle_fast (large steady-pace loops;
    pace comes from ARCHETYPE_SPEED_MULT, geometry is shared). Returns
    {"points": [(x, y, z)], "speeds": [...], "archetype": str}.
    Altitudes wander 4..14 m so climbs/dives train too.
    """
    arch = archetype or str(rng.choice(["patrol", "weave", "flee", "orbit"]))
    mirror = -1.0 if float(rng.random()) < 0.5 else 1.0
    pts, speeds = [], []
    cx = float(rng.uniform(-10.0, 10.0))
    cz = float(rng.uniform(-10.0, 10.0)) * mirror
    r = float(rng.uniform(10.0, extent))
    steady = 0.0
    if arch in ("circle_slow", "circle_fast"):
        rr = float(0.7 * extent + 0.3 * r)
        steady = float(rng.uniform(0.8, 0.9))
    for i in range(max(int(n_waypoints), 2)):
        t = i / max(int(n_waypoints) - 1, 1)
        ang = t * 2.0 * np.pi * (1 if arch in ("patrol", "orbit",
                                               "circle_slow",
                                               "circle_fast") else 0.5)
        if arch == "weave":
            px = cx + (t - 0.5) * 2.0 * r
            pz = cz + mirror * np.sin(t * 4.0 * np.pi) * r * 0.4
        elif arch == "flee":
            rr = 8.0 + t * r
            px = cx + np.cos(ang + 1.0) * rr
            pz = cz + np.sin(ang + 1.0) * rr
        elif arch == "zigzag":
            px = cx + (t - 0.5) * 2.0 * r
            pz = cz + mirror * np.sin(t * 6.0 * np.pi) * r * 0.5
        elif arch == "doubleback":
            pole = 1.0 if i % 2 == 0 else -1.0
            px = cx + pole * r
            pz = cz + mirror * (t - 0.5) * r
        elif arch in ("circle_slow", "circle_fast"):
            px = cx + np.cos(ang) * rr
            pz = cz + np.sin(ang) * rr
        else:
            px = cx + np.cos(ang) * r
            pz = cz + np.sin(ang) * r
        py = float(np.clip(7.0 + np.sin(t * 3.0 + r) * 5.0, 4.0, 14.0))
        pts.append((float(np.clip(px, -40.0, 40.0)), py,
                    float(np.clip(pz, -40.0, 40.0))))
        if arch in ("circle_slow", "circle_fast"):
            speeds.append(steady)
        else:
            speeds.append(float(rng.uniform(0.7, 1.0)))
    return {"points": pts, "speeds": speeds, "archetype": arch,
            "mirror": mirror}


def step_path_target(target, path, state, base_speed, dt=0.05,
                      wobble=0.0, jrng=None):
    """Steers a KinematicFly along a planned path (proportional nav to
    the active waypoint, per-leg speed fraction of base_speed, altitude
    tracking via pitch, optional seeded wobble so paths aren't
    mechanical). state={"wp": int} persists across steps."""
    pts = path["points"]
    wp = int(state.get("wp", 0)) % len(pts)
    gx, gy, gz = pts[wp]
    dx, dy, dz = gx - target.pos[0], gy - target.pos[1], gz - target.pos[2]
    if np.hypot(dx, dz) < 4.0:
        wp = (wp + 1) % len(pts)
        state["wp"] = wp
        gx, gy, gz = pts[wp]
        dx, dy, dz = gx - target.pos[0], gy - target.pos[1], gz - target.pos[2]
    desired = np.arctan2(dz, dx)
    err = (desired - target.heading + np.pi) % (2.0 * np.pi) - np.pi
    yaw = float(np.clip(-err * 2.0, -1.0, 1.0))
    if jrng is not None and wobble > 0.0:
        yaw = float(np.clip(
            yaw + float(jrng.uniform(-wobble, wobble)), -1.0, 1.0))
    pitch = float(np.clip(dy * 0.15, -1.0, 1.0))
    leg = base_speed * float(path["speeds"][wp])
    thrust = float(np.clip((leg - 3.0) / 9.0, 0.0, 1.5))
    target.step(thrust=thrust, yaw_torque=yaw, pitch_cmd=pitch, dt=dt)
    return wp


def _school_episode(rngs, progress, curriculum, start_x, start_z,
                    target_x, target_z):
    """Full flight-school episode setup, replacing the legacy draws.

    Returns (target, fly, upset, env, extra, ctx): behavior + env drawn
    from the stage tables, difficulty lerped by progress, every draw
    from a dedicated stream. ctx drives step-loop rewards (tail-close,
    camp bonus, takedown pay) and results tags.
    """
    behavior, env = pick_school_scenario(rngs["spawn"], progress, curriculum)
    diff = lambda k: _school_diff(progress, curriculum, k)
    hj = diff("heading_jitter")
    start_heading = float(np.arctan2(target_z - start_z, target_x - start_x)
                          + float(rngs["spawn"].uniform(-hj, hj)))
    upset = bool(float(rngs["spawn"].random()) < diff("upset"))
    if upset:
        fly = KinematicFly(
            x=start_x, y=float(rngs["spawn"].uniform(4.0, 22.0)), z=start_z,
            heading_rad=start_heading,
            pitch_rad=float(rngs["spawn"].uniform(-1.0, 1.0)))
    else:
        fly = KinematicFly(x=start_x, z=start_z, heading_rad=start_heading)
    path = None
    path_state = {"wp": 0}
    base_speed = 4.35
    arch = ""
    if behavior == "camp":
        dist = diff("camp_dist")
        ang = float(rngs["target"].uniform(0.0, 2.0 * np.pi))
        tx = float(np.clip(start_x + np.cos(ang) * dist, -40.0, 40.0))
        tz = float(np.clip(start_z + np.sin(ang) * dist, -40.0, 40.0))
        ty = float(rngs["target"].uniform(4.0, 14.0))
        th = float(rngs["target"].uniform(-np.pi, np.pi))
        target = KinematicFly(x=tx, y=ty, z=tz, heading_rad=th, anchored=True)
    elif behavior in ("mover", "stalk"):
        # Stalk is a mover with lateral-sweeper paths (gaze targets):
        # same catchable mechanics, same takedown pay.
        target = KinematicFly(x=target_x, z=target_z, heading_rad=np.pi)
        nwp = max(2, int(round(diff("mover_waypoints"))))
        arch = _mover_archetype(rngs["path"], progress, curriculum,
                                behavior)
        path = plan_path(rngs["path"], nwp, archetype=arch)
        base_speed = diff("mover_speed")
    elif behavior == "dodge":
        # Head-on threat: spawned ahead along the fly's nose at dodge
        # dist, homing straight at the agent every step (see dispatch).
        # The lesson is the near-miss: bank away, don't get touched.
        dist = diff("dodge_dist")
        hx = float(np.cos(start_heading))
        hz = float(np.sin(start_heading))
        tx = float(np.clip(start_x + hx * dist, -40.0, 40.0))
        tz = float(np.clip(start_z + hz * dist, -40.0, 40.0))
        ty = float(np.clip(
            fly.pos[1] + float(rngs["target"].uniform(-2.0, 2.0)),
            4.0, 14.0))
        target = KinematicFly(x=tx, y=ty, z=tz,
                              heading_rad=start_heading + np.pi)
    else:
        target = KinematicFly(x=target_x, z=target_z, heading_rad=np.pi)
    gate_line = None
    if env == "open":
        extra = []
    elif env == "slalom":
        t = float(rngs["forest"].uniform(0.3, 0.7))
        gx = start_x + (target.pos[0] - start_x) * t
        gz = start_z + (target.pos[2] - start_z) * t
        dx, dz = target.pos[0] - start_x, target.pos[2] - start_z
        n = max(float(np.hypot(dx, dz)), 1e-4)
        px, pz = -dz / n, dx / n
        gap = diff("gap")
        extra = [(gx + px * off, gz + pz * off, 0.9, 16.0)
                 for off in (-gap, 0.0, gap)]
        gate_line = (gx, gz, px, pz, gap)
    else:
        ntrees = max(1, int(round(diff("trunks"))))
        mx = (start_x + target.pos[0]) / 2.0 + float(
            rngs["forest"].uniform(-4.0, 4.0))
        mz = (start_z + target.pos[2]) / 2.0 + float(
            rngs["forest"].uniform(-4.0, 4.0))
        placed_c = []
        tries = 0
        while len(placed_c) < ntrees and tries < 200:
            tries += 1
            cx = mx + float(rngs["forest"].uniform(-7.0, 7.0))
            cz = mz + float(rngs["forest"].uniform(-7.0, 7.0))
            if all(float(np.hypot(cx - qx, cz - qz)) >= 3.0
                   for qx, qz in placed_c):
                placed_c.append((cx, cz))
        extra = [(cx, cz, 0.9, 16.0) for cx, cz in placed_c]
    if behavior == "camp":
        # Defensive trunk ring around the camp (counts toward extras).
        ring = int(round(diff("camp_ring")))
        placed_r = 0
        tries = 0
        while placed_r < ring and tries < 60:
            tries += 1
            ang = float(rngs["forest"].uniform(0.0, 2.0 * np.pi))
            rad = float(rngs["forest"].uniform(5.0, 8.0))
            cx = float(target.pos[0] + np.cos(ang) * rad)
            cz = float(target.pos[2] + np.sin(ang) * rad)
            extra.append((cx, cz, 0.9, 16.0))
            placed_r += 1
    gates = []
    if gate_line is not None:
        # Bonus openings between the trunk posts (posts sit at -gap,
        # 0, +gap off the start->target line; openings at half-gaps).
        gx, gz, px, pz, gap = gate_line
        gates = [(gx - px * gap / 2.0, gz - pz * gap / 2.0),
                 (gx + px * gap / 2.0, gz + pz * gap / 2.0)]
    ctx = {"behavior": behavior, "env": env,
           "scenario": behavior.upper() + "+" + env.upper(),
           "path": path, "path_state": path_state,
           "base_speed": base_speed,
           "archetype": arch,
           "speed_mult": float(ARCHETYPE_SPEED_MULT.get(arch, 1.0)),
           "wobble": diff("mover_wobble"),
           "camp_bonus_paid": False,
           "contact_pay": SCHOOL_TAKEDOWN_PAY,
           "threat_speed": diff("dodge_speed"),
           "min_dist": float("inf"),
           "dodge_failed": False,
           "gates": gates,
           "gate_paid": False}
    return target, fly, upset, env, extra, ctx


def run_training(num_episodes=50, max_steps_per_episode=120, variant="A",
                 save_name=None, seed=None, target_evasion=0.2,
                 learning_rate=0.008, dist_gain=0.15, align_bonus=(0.5, 0.2, -0.3),
                 experiment=None, init_weights=None, progress_cb=None,
                 return_brain=False, mapping=None, yaw_bias=None, legacy=False,
                 genome=None, curriculum=None, eval_only=False, blends=None):
    global TREES
    cfg = VARIANTS.get(variant, {})
    label = cfg.get("label", variant)
    if seed is None:
        seed = cfg.get("seed", 0)
    # Seeds may arrive as floats (JSON round-trip through the Godot menu);
    # np.random.seed(float) raises a safe-casting TypeError on NumPy 2.
    seed = int(seed)
    np.random.seed(seed)
    # Flight-school streams: per-aspect seeded Generators so spawn, path,
    # forest, and target draws never couple. Legacy path keeps the global
    # np.random stream byte-identical.
    school_rngs = None
    if isinstance(curriculum, dict):
        school_rngs = {
            key: np.random.default_rng((seed ^ mask) % (2 ** 32))
            for key, mask in (("spawn", 0xC0FFEE), ("path", 0xF00D),
                              ("forest", 0x7EE5), ("target", 0xBE57))}
        print(f"   FLIGHT SCHOOL curriculum: "
              f"{sorted(curriculum.keys()) if curriculum else 'defaults'}")
    if save_name is None:
        save_name = cfg.get("save_name", "trained_homing_champion.npz")
    if genome is not None:
        base = save_name.removesuffix(".npz") if save_name.endswith(".npz") else save_name
        save_name = f"{base}{genome_suffix(genome)}.npz"
    elif experiment:
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
    # wiring or genome (if any). Arity changes with injected edges, so
    # checkpoints for this run carry the experiment/genome suffix and are
    # never mixed with base files. Genome wins when both are given.
    # Wiring struct cache (mirrors brain_server._bind_brain): the ~25M-edge
    # overlay add rebuilt per stage now serves memory on repeat wirings
    # (multi-stage breeds/trains), keyed by wiring identity + CSR stamp.
    global _WIRING_STRUCT_CACHE
    if genome is not None:
        try:
            wkey = ("genome:" + genome_label(genome), id(csr))
        except ValueError:
            wkey = (None,)
        if wkey not in _WIRING_STRUCT_CACHE:
            _WIRING_STRUCT_CACHE[wkey] = build_genome_arrays(genome, csr, pops)
            while len(_WIRING_STRUCT_CACHE) > 4:
                _WIRING_STRUCT_CACHE.pop(next(iter(_WIRING_STRUCT_CACHE)))
        indptr, indices, wbasis = _WIRING_STRUCT_CACHE[wkey]
    else:
        wkey = (normalize_experiment(experiment), id(csr))
        if wkey not in _WIRING_STRUCT_CACHE:
            _WIRING_STRUCT_CACHE[wkey] = experiment_arrays(experiment, csr, pops)
            while len(_WIRING_STRUCT_CACHE) > 4:
                _WIRING_STRUCT_CACHE.pop(next(iter(_WIRING_STRUCT_CACHE)))
        indptr, indices, wbasis = _WIRING_STRUCT_CACHE[wkey]
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
                           yaw_bias=yaw_bias, blends=blends)
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
        # Fresh nose per episode: habituation must not carry a saturated
        # gain into a new spawn.
        encoder.reset_odor()
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

        # Flight-school override (curriculum set): scheduler picks
        # behavior+env, difficulty lerps by progress, all draws from
        # dedicated streams. Replaces the legacy spawn/env above.
        school_ctx = None
        if school_rngs is not None:
            (target, fly, upset, _env, extra,
             school_ctx) = _school_episode(
                 school_rngs, progress, curriculum,
                 start_x, start_z, target_x, target_z)
            TREES = base_trees + extra
            # Uppercase env keeps results/breakdown keys identical.
            enc_type = _env.upper()

        brain.reset_state()
        # Per-episode depression budget: a pool may lose at most half
        # its magnitude per episode, so one bad episode can never grind
        # a channel into the abandonment gap (the recurring vault-wide
        # collapse). Potentiation is never budgeted.
        dopamine_rl.begin_episode(brain)

        _s0, prev_dist = compute_agent_senses(fly, target)
        initial_dist = prev_dist
        prev_scent = float(_s0.get("pheromone_conc_left", 0.0)
                           + _s0.get("pheromone_conc_right", 0.0))
        total_da = 0.0
        success = False
        strike = False
        takedown = False
        crashed = False
        seized_out = False
        seizure_steps = 0
        seizure_events = 0
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

            # 4. Decode descending motor controls (brain + reflex assist).
            # Reusable counts dict (server precedent): decode builds it
            # once per step instead of twice.
            _step_counts = {}
            ctrl = decoder.decode(spikes, sensory_hint=senses,
                                  _counts_out=_step_counts)

            # 5. Compute Dopamine reward (closing distance + gaze alignment
            # + tail chase + scent gradient ascent)
            scent_now = float(senses.get("pheromone_conc_left", 0.0)
                              + senses.get("pheromone_conc_right", 0.0))
            da = dopamine_rl.compute_reward(
                current_dist=current_dist,
                prev_dist=prev_dist,
                azimuth_deg=senses["visual_target_azimuth"],
                dt=0.05,
                tail_chase=senses.get("tail_chase", 0.0),
                ventral=senses.get("visual_flow_ventral", 0.0),
                schemes=schemes,
                scent_now=scent_now,
                scent_prev=prev_scent,
                ground=float(getattr(fly, "ground_now", 0.0))
            )
            prev_scent = scent_now
            # School extras: tail-close bonus (behind + closing pays up to
            # +1.0) and camp arrival bonus (first touch inside 6 m, +0.5).
            if school_ctx is not None:
                tail_rate = (prev_dist - current_dist) / 0.05
                if senses.get("tail_chase", 0.0) > 0.5 and tail_rate > 0.0:
                    da += min(tail_rate * 0.15, SCHOOL_TAIL_RATE)
                if school_ctx["behavior"] == "camp" \
                        and not school_ctx["camp_bonus_paid"] \
                        and current_dist < 6.0:
                    school_ctx["camp_bonus_paid"] = True
                    da += 0.5
                if school_ctx["behavior"] == "dodge":
                    # Near-miss lesson: track closest approach; contact
                    # (<1.2m) fails the dodge with an aversive pulse but
                    # the threat flies through, so the episode continues.
                    school_ctx["min_dist"] = min(
                        float(school_ctx.get("min_dist", 1e9)),
                        current_dist)
                    if not bool(school_ctx.get("dodge_failed", False)) \
                            and current_dist < 1.2:
                        school_ctx["dodge_failed"] = True
                        da -= 1.0
                    # Bank-away shaping: bank magnitude on the opposite
                    # side of the threat azimuth pays (dead-ahead reads
                    # zero - symmetric threats teach nothing).
                    az = float(senses.get("visual_target_azimuth", 0.0))
                    away = -float(np.sign(az)) * float(fly.roll)
                    if away > 0.15:
                        da += 0.3
                # Slalom gate bonus: first pass within 1.5m of either
                # opening midpoint pays once (threading, not ramming).
                if not bool(school_ctx.get("gate_paid", False)):
                    for gx, gz in (school_ctx.get("gates", []) or []):
                        if float(np.hypot(fly.pos[0] - gx,
                                          fly.pos[2] - gz)) < 1.5:
                            school_ctx["gate_paid"] = True
                            da += 0.5
                            break
                # Stalk gaze reward (THIS lesson only): keeping the
                # target in the front eye pays, best at spear geometry
                # and tapering to the 35-degree gate. Catchable target,
                # so takedown pay still dominates and stare-then-lunge
                # combos can emerge instead of fixation.
                pay, locked = stalk_gaze_pay(
                    school_ctx["behavior"],
                    bool(senses.get("visual_target_visible", False)),
                    abs(float(senses.get("visual_target_azimuth", 0.0))),
                    current_dist)
                da += pay
                if locked:
                    school_ctx["gaze_locks"] = int(
                        school_ctx.get("gaze_locks", 0)) + 1
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

            # 6c. Seizure watch: saturated yaw that keeps spinning the
            # body drains health in small increments plus a mild
            # aversive pulse (the mapping that spins gets depressed);
            # zero health ends the episode seized-out, scoring like a
            # crash (0.0, not a hunt).
            seizing, onset = update_seizure(
                fly, float(ctrl.get("yaw_torque", 0.0)), dt=0.05)
            if onset:
                seizure_events += 1
                print(f"[Episode {ep:02d}/{num_episodes:02d}] "
                      f"SEIZURE detected - draining health.")
            if seizing:
                seizure_steps += 1
                fly.health -= SEIZURE_DRAIN * 0.05
                total_da += SEIZURE_DA
                if not eval_only:
                    dopamine_rl.apply_plasticity(brain, senses, ctrl,
                                                 SEIZURE_DA,
                                                 schemes=schemes,
                                                 gain_cap=0.02)
                if fly.health <= 0.0:
                    seized_out = True
                    break
            # Target behavior: school mover follows its planned path
            # (camp is anchored: step() is a heartbeat no-op); legacy
            # duel keeps the constant-speed random walk.
            if school_ctx is not None \
                    and school_ctx["behavior"] in ("mover", "stalk"):
                step_path_target(target, school_ctx["path"],
                                 school_ctx["path_state"],
                                 float(school_ctx["base_speed"])
                                 * float(school_ctx.get("speed_mult", 1.0)),
                                 dt=0.05,
                                 wobble=school_ctx["wobble"],
                                 jrng=school_rngs["target"])
            elif school_ctx is not None \
                    and school_ctx["behavior"] == "camp":
                target.step(thrust=0.0, yaw_torque=0.0, dt=0.05)
            elif school_ctx is not None \
                    and school_ctx["behavior"] == "dodge":
                # Head-on threat: home straight at the agent every step
                # (deterministic, no draws). The agent learns the
                # near-miss; the threat never dodges back.
                to_a = fly.pos - target.pos
                hd = float(np.hypot(to_a[0], to_a[2])) + 1e-4
                target.heading = float(np.arctan2(to_a[2], to_a[0]))
                spd = float(school_ctx.get("threat_speed", 6.0))
                thr = float(np.clip(
                    (spd - target.base_speed)
                    / max(target.max_speed - target.base_speed, 1e-4),
                    0.0, 1.0))
                target.step(thrust=thr, yaw_torque=0.0, dt=0.05)
            elif school_ctx is not None:
                # School duel: legacy random walk on the school stream so
                # school episodes never consume global draws.
                target.step(thrust=0.15, yaw_torque=float(
                    school_rngs["target"].uniform(
                        -target_evasion, target_evasion)), dt=0.05)
            else:
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
                # Takedown-dominant school pay (+4.5) vs legacy +2.0.
                da += school_ctx["contact_pay"] if school_ctx is not None else 2.0
                strike = True
                takedown = True

            # 7. Apply Dopamine-Gated Plasticity (run's own schemes: new
            # branches learn only on brains generated from those schemes).
            # Micro-gain cap: 6000 calls/session must stay micro, or high
            # learning rates compound into mid-episode runaway.
            if not eval_only:
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
                    if not eval_only:
                        dopamine_rl.apply_plasticity(brain, senses, ctrl, da_crash,
                                                     schemes=schemes, gain_cap=0.02)
                else:
                    crashed = True
                    break

            prev_dist = current_dist

            # Success threshold: spear contact kills outright; otherwise
            # closing within striking distance (3.5m) ends the hunt. A
            # touched dodge threat never counts: the pass already failed.
            dodge_bad = bool(school_ctx is not None
                             and school_ctx.get("behavior", "") == "dodge"
                             and school_ctx.get("dodge_failed", False))
            if strike or (current_dist < 3.5 and not dodge_bad):
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
            "takedown": takedown,
            "camp": bool(school_ctx is not None
                         and school_ctx["camp_bonus_paid"]),
            "dodge": bool(school_ctx is not None
                          and school_ctx.get("behavior", "") == "dodge"),
            "dodge_failed": bool(school_ctx is not None
                                 and school_ctx.get("dodge_failed", False)),
            "min_dist": float(school_ctx.get("min_dist", -1.0))
            if school_ctx is not None else -1.0,
            "gate_paid": bool(school_ctx is not None
                              and school_ctx.get("gate_paid", False)),
            "gaze_lock_frac": (
                float(school_ctx.get("gaze_locks", 0)) / (step + 1)
                if school_ctx is not None
                and school_ctx.get("behavior", "") == "stalk"
                else 0.0),
            "upset": upset,
            "crashed": crashed,
            "seized_out": seized_out,
            "seizure_steps": seizure_steps,
            "seizure_events": seizure_events,
            "enc": enc_type,
            "scenario": school_ctx["scenario"] if school_ctx is not None else enc_type,
            "archetype": school_ctx.get("archetype", "") if school_ctx is not None else "",
            "close_calls": close_calls,
            "lunges": lunges,
            "strikes": strikes,
            "avg_da": total_da / (step + 1)
        })

        tag = ("UPSET+" if upset else "") + (
            school_ctx["scenario"] if school_ctx is not None else enc_type)
        if seized_out:
            status_str = "SEIZED OUT (spun down)!"
        elif crashed:
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
        # legacy brains, whose regime never had it. Skipped entirely in
        # eval mode (scoring must not move weights).
        if not eval_only:
            dopamine_rl.pin_gains(brain, legacy=legacy)
        if progress_cb is not None:
            try:
                progress_cb(ep, num_episodes)
            except Exception:
                pass

    # Save the trained variant weights (eval mode scores without
    # touching weights or disk: no checkpoint, save_path None).
    if eval_only:
        save_path = None
        print(f"\n[Train:{label}] Eval complete (no learning, no checkpoint).")
    else:
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
    seized = sum(1 for r in results if r.get("seized_out"))
    seiz_steps = sum(int(r.get("seizure_steps", 0)) for r in results)
    print(f"[Train:{label}] Seizures: {seized}/{num_episodes} episodes seized out, {seiz_steps} seizing steps total.")
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
    takedowns = sum(1 for r in results if r.get("takedown"))
    if takedowns:
        print(f"[Train:{label}] Takedowns: {takedowns}/{num_episodes} spike kills.")
    by_scenario = {}
    for r, s in zip(results, [_school_score(r, curriculum) for r in results]):
        sc = r.get("scenario", r.get("enc", "?"))
        cell = by_scenario.setdefault(sc, {"episodes": 0, "successes": 0,
                                           "takedowns": 0, "score": 0.0})
        cell["episodes"] += 1
        cell["successes"] += 1 if r["success"] else 0
        cell["takedowns"] += 1 if r.get("takedown") else 0
        cell["score"] += s
    for sc in sorted(by_scenario):
        cell = by_scenario[sc]
        print(f"[Train:{label}] {sc}: {cell['successes']}/{cell['episodes']} "
              f"ok, {cell['takedowns']} takedowns, score {cell['score']:.1f}.")
    by_archetype = {}
    for r, s in zip(results, [_school_score(r, curriculum) for r in results]):
        ak = r.get("archetype", "") or "none"
        cell = by_archetype.setdefault(ak, {"episodes": 0, "successes": 0,
                                            "takedowns": 0, "score": 0.0})
        cell["episodes"] += 1
        cell["successes"] += 1 if r["success"] else 0
        cell["takedowns"] += 1 if r.get("takedown") else 0
        cell["score"] += s
    for ak in sorted(by_archetype):
        cell = by_archetype[ak]
        print(f"[Train:{label}] path {ak}: {cell['successes']}/{cell['episodes']} "
              f"ok, {cell['takedowns']} takedowns, score {cell['score']:.1f}.")
    scores = [_school_score(r, curriculum) for r in results]
    total_score = float(sum(scores))
    avg_score = total_score / max(num_episodes, 1)
    print(f"[Train:{label}] Pre-training score: {total_score:.1f} "
          f"(avg {avg_score:.2f}/episode).")
    summary = {"successes": successes, "episodes": num_episodes,
               "avg_closed": float(avg_closed), "crashes": crashes,
               "close_calls": close_tot, "takedowns": takedowns,
               "score": total_score, "avg_score": avg_score,
               "by_scenario": by_scenario, "by_archetype": by_archetype}
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
