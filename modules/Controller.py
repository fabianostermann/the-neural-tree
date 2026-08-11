USES = [ "NeuralTree" ]
REQUIRES = [ "Commands" ]
PROVIDES = [ "NeuralTree" ]

import random, time

def _update(bb):
    print(bb.NeuralTree.TreeComponent.instances)
    
    random.choice([
        bb.NeuralTree.mutate_neuron,
        bb.NeuralTree.mutate_neuron,
        bb.NeuralTree.mutate_neuron,
        bb.NeuralTree.new_leaf,
        bb.NeuralTree.new_leaf,
        bb.NeuralTree.new_leaf,
        bb.NeuralTree.new_leaf,
        bb.NeuralTree.thicken,
        bb.NeuralTree.thicken,
        bb.NeuralTree.grow_branch,
    ])()
    print(bb.NeuralTree.TreeComponent.instances)
    
    bb.NeuralTree.tree.eval_subtree()
    
    time.sleep(1.0)
