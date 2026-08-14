USES = []
REQUIRES = []
PROVIDES = [ "Commands" ]

import random

def _update(bb):
    bb.Commands.reset_all()
    
    # TODO: replace simulation with real human inputs
    bb.Commands.mutate_neuron = random.random() < 0.5
    bb.Commands.thicken = random.random() < 0.3
    bb.Commands.new_leaf = random.random() < 0.3
    bb.Commands.grow_branch = random.random() < 0.1
