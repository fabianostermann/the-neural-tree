USES = [ "MIDIMessages" ]
REQUIRES = [ "NeuralTree" ]
PROVIDES = [ "MIDIMessages" ]

def _update(bb):
    # TODO: make midi timing here
    for leaf in bb.NeuralTree.Leaf.instances:
        print(leaf.get_activations())
