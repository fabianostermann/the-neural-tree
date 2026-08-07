import random

def _validate():
    n = Neuron(3)
    print(n.forward([1,2,3]))
    
    assert tree._children[0]._parent == tree
    
    EXIT_SUCCESS
    
def thicken():
    # TODO: Thicken root or branches
    raise NotImplementedError("Not yet implemented")
    
def mutate_neuron():
    # TODO: choose random neuron and call mutate
    raise NotImplementedError("Not yet implemented")
    
def new_leaf():
    # TODO: instanciate a new leaf at random position
    raise NotImplementedError("Not yet implemented")
    
def grow():
    # TODO: grow a new branch between a random leaf and its old parent
    raise NotImplementedError("Not yet implemented")

    
class Neuron:
    instances = []
    
    def __init__(self, in_size: int, weight_range=[-0.5,0.5], bias_range=[-0.1,0.1]):
        self.weights = [ random.uniform(*weight_range) ] * in_size
        self.bias = random.uniform(*bias_range)
        self.activation = Neuron.relu
        Neuron.instances.append(self)
        
    def forward(self, x):
        assert len(x) == len(self.weights), "input size does not match num of weights"
        x = sum([ w_i*x_i for w_i, x_i in zip(self.weights, x)])
        x = x + self.bias
        self.activation(x)
        return x
        
    def relu(x):
        return max(0, x)
    
        
class TreeComponent:
    instances = []
    
    def __init__(self, in_size: int, out_size: int, parent=None):
        self._neurons = [ Neuron(in_size) for o in range(out_size) ]
        self._parent = parent
        self._children = []
        TreeComponent.instances.append(self)
    
    def forward(self, x):
        assert len(x) == self.get_in_size(), "input sizes do not match"
        
        x = [ n.forward(x) for n in self._neurons ]
        return x
        
    def get_in_size(self):
        return len(self._neurons[0].weights)
        
    def get_out_size(self):
        return len(self._neurons)

class Root(TreeComponent):
    instance = None

    def __init__(self):
        super().__init__(2,2)
        assert Root.instance is None, "Root exists already."
        
        # make one initial leaf
        self._children.append(Leaf(self.get_out_size(), parent=self))
        
        Root.instance = self
        
        
class Leaf(TreeComponent):
    instances = []

    def __init__(self, in_size: int, parent=None):
        super().__init__(in_size, 2, parent=parent)
        assert parent
        Leaf.instances.append(self)
        

tree = Root()
        
        
