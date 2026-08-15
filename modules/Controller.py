USES = [ "NeuralTree" ]
REQUIRES = [ "Commands" ]
PROVIDES = [ "NeuralTree" ]

import random, time

def _update(bb):    
    changed = False
    
    if not bb.Commands.started:
        return
        
    if not bb.NeuralTree.tree:
        bb.NeuralTree.tree = bb.NeuralTree.Root()
        bb.NeuralTree.tree.eval_subtree()
    
    if bb.Commands.mutate_neuron:
        print("Got mutate_neuron() command!")
        bb.NeuralTree.mutate_neuron()
        changed = True
    if bb.Commands.thicken:
        print("Got thicken() command!")
        bb.NeuralTree.thicken()
        changed = True
    if bb.Commands.new_leaf:
        print("Got new_leaf() command!")
        bb.NeuralTree.new_leaf()
        changed = True
    if bb.Commands.grow_branch:
        print("Got grow_branch() command!")
        bb.NeuralTree.grow_branch()
        changed = True
        
    if changed:
        bb.NeuralTree.tree.eval_subtree()
        print(bb.NeuralTree.TreeComponent.instances)

