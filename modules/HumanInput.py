USES = []
REQUIRES = []
PROVIDES = [ "Commands" ]

import random, time

START = time.time()

def _update(bb):
    global START
    bb.Commands.reset_all()
    
    elapsed = time.time() - START
    if elapsed > 1.0:
        # simulation of real human inputs
        bb.Commands.mutate_neuron = random.random() < 0.5
        bb.Commands.thicken = random.random() < 0.2
        bb.Commands.new_leaf = random.random() < 0.2
        bb.Commands.grow_branch = random.random() < 0.1
        
        START = time.time()
        
        bb.Commands.started = True
