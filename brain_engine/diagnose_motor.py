import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAIN_ENGINE_DIR = os.path.join(PROJECT_ROOT, "brain_engine")
if BRAIN_ENGINE_DIR not in sys.path:
    sys.path.insert(0, BRAIN_ENGINE_DIR)

import numpy as np
from lif_brain import FlyBrain
from connectome_loader import load_or_build_csr, load_or_extract_populations
from sensory_motor import SensoryEncoder, MotorDecoder

csr = load_or_build_csr()
pops = load_or_extract_populations()

chk_path = os.path.join(PROJECT_ROOT, "checkpoints", "trained_homing_A.npz")
chk = np.load(chk_path)
brain = FlyBrain(csr.indptr, csr.indices, chk['weights'])
encoder = SensoryEncoder(pops)
decoder = MotorDecoder(pops)

dn09_set = set(pops['motor_thrust_dnp09']['all'])
dn20_l_set = set(pops['motor_turn_dnp20']['left'])
dn20_r_set = set(pops['motor_turn_dnp20']['right'])
gf_set = set(pops['motor_giant_fiber']['all'])

scenarios = [
    ('Rival DIRECTLY AHEAD, strong scent', {
        'pheromone_conc_left': 0.9, 'pheromone_conc_right': 0.9,
        'visual_target_visible': True, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0
    }),
    ('Rival to the LEFT', {
        'pheromone_conc_left': 0.7, 'pheromone_conc_right': 0.2,
        'visual_target_visible': True, 'visual_target_azimuth': -45.0, 'visual_looming_rate': 0.0
    }),
    ('Rival to the RIGHT', {
        'pheromone_conc_left': 0.2, 'pheromone_conc_right': 0.7,
        'visual_target_visible': True, 'visual_target_azimuth': 45.0, 'visual_looming_rate': 0.0
    }),
    ('FAR AWAY (28m, weak scent)', {
        'pheromone_conc_left': 0.42, 'pheromone_conc_right': 0.20,
        'visual_target_visible': True, 'visual_target_azimuth': -20.0, 'visual_looming_rate': 0.0
    }),
    ('No stimulus (resting)', {
        'pheromone_conc_left': 0.0, 'pheromone_conc_right': 0.0,
        'visual_target_visible': False, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0
    }),
    ('Floor baseline (far trace, symmetric)', {
        'pheromone_conc_left': 0.06, 'pheromone_conc_right': 0.06,
        'visual_target_visible': False, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0,
        'scent_lost': 0.0, 'scent_cast': 0.0, 'scent_surge': 0.0
    }),
    ('Glued on (saturated symmetric)', {
        'pheromone_conc_left': 0.95, 'pheromone_conc_right': 0.95,
        'visual_target_visible': True, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0,
        'scent_lost': 0.0, 'scent_cast': 0.0, 'scent_surge': 0.0
    }),
    ('Lost 10s, cast right (search)', {
        'pheromone_conc_left': 0.05, 'pheromone_conc_right': 0.05,
        'visual_target_visible': False, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0,
        'scent_lost': 10.0, 'scent_cast': 1.0, 'scent_surge': 0.0
    }),
    ('Closing surge (rising scent)', {
        'pheromone_conc_left': 0.6, 'pheromone_conc_right': 0.6,
        'visual_target_visible': True, 'visual_target_azimuth': 0.0, 'visual_looming_rate': 0.0,
        'scent_lost': 0.0, 'scent_cast': 0.0, 'scent_surge': 1.0
    }),
]

for name, senses in scenarios:
    brain.reset_state()
    encoder.reset_odor()
    stim = encoder.encode(senses)
    spikes = brain.integrate_50ms(stim)
    # Scenarios carrying scent dynamics get the full hint path (reflex
    # contrast, lost-search, surge); legacy ones stay brain-only.
    hint = senses if any(k.startswith("scent_") for k in senses) else None
    ctrl = decoder.decode(spikes, sensory_hint=hint)
    spk_list = list(spikes)
    dnp09_spk = sum(1 for s in spk_list if s in dn09_set)
    dnp20_l_spk = sum(1 for s in spk_list if s in dn20_l_set)
    dnp20_r_spk = sum(1 for s in spk_list if s in dn20_r_set)
    gf_spk = sum(1 for s in spk_list if s in gf_set)
    total = len(spk_list)
    print(f"SCENARIO: {name}")
    print(f"  Total spikes: {total}")
    print(f"  DNp09 (thrust):   {dnp09_spk}")
    print(f"  DNp20-L (turn L): {dnp20_l_spk}")
    print(f"  DNp20-R (turn R): {dnp20_r_spk}")
    print(f"  GiantFiber:       {gf_spk}")
    print(f"  => thrust={ctrl['thrust']:.3f}, yaw={ctrl['yaw_torque']:.3f}, ram={ctrl['ram_burst']}, evade={ctrl['emergency_evade']}")
    print()
