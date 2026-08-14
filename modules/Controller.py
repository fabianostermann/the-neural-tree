USES = [ "NeuralTree" ]
REQUIRES = [ "Commands" ]
PROVIDES = [ "NeuralTree" ]

import random, time

def _update(bb):
    print(bb.NeuralTree.TreeComponent.instances)
    
    if bb.Commands.mutate_neuron:
        bb.NeuralTree.mutate_neuron()
    if bb.Commands.thicken:
        bb.NeuralTree.thicken()
    if bb.Commands.new_leaf:
        bb.NeuralTree.new_leaf()
    if bb.Commands.grow_branch:
        bb.NeuralTree.grow_branch()
        
    print(bb.NeuralTree.TreeComponent.instances)
    
    bb.NeuralTree.tree.eval_subtree()
    
    time.sleep(1.0)
