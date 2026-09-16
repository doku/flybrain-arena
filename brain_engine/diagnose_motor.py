import numpy as np
from lif_brain import FlyBrain
from connectome_loader import load_or_build_csr, load_or_extract_populations
from sensory_motor import SensoryEncoder, MotorDecoder

csr = load_or_build_csr()
pops = load_or_extract_populations()

chk = np.load('../checkpoints/trained_homing_A.npz')
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
]

for name, senses in scenarios:
    brain.reset_state()
    stim = encoder.encode(senses)
    spikes = brain.integrate_50ms(stim)
    ctrl = decoder.decode(spikes)
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
