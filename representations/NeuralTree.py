import random

def _validate():
    #n = Neuron(3)
    #print(n.forward([1,2,3]))
    
    assert tree._children[0]._parent == tree
    
def thicken():
    # instanciate a new leaf at random position
    branch = Leaf.instances[0]
    while isinstance(branch, Leaf):
        branch = random.choice(TreeComponent.instances)
    branch.thicken()
    
def mutate_neuron():
    # choose random neuron and call mutate
    random.choice(Neuron.instances).mutate()
    
def new_leaf():
    # instanciate a new leaf at random position
    branch = Leaf.instances[0]
    while isinstance(branch, Leaf):
        branch = random.choice(TreeComponent.instances)
    branch.add_leaf()
    
def grow_branch():
    # grow a new branch between a random leaf and its old parent
    leaf = tree
    while not isinstance(leaf, Leaf):
        leaf = random.choice(TreeComponent.instances)
    leaf.grow_branch()
    
class Neuron:
    instances = []
    
    def __init__(self, in_size: int, weight_range=[-0.5,0.5], bias_range=[-0.1,0.1]):
        self._weights = [ random.uniform(*weight_range) ] * in_size
        self._bias = random.uniform(*bias_range)
        self.activation = Neuron.relu
        Neuron.instances.append(self)
        
    def forward(self, x):
        assert len(x) == len(self._weights), "input size does not match num of weights"
        x = sum([ w_i*x_i for w_i, x_i in zip(self._weights, x)])
        x = x + self._bias
        self.activation(x)
        return x
        
    def relu(x):
        return max(0, x)
        
    def mutate(self):
        self._weights[random.randrange(len(self._weights))] += random.gauss(mu=0.0, sigma=1.0)
        if random.random() < 0.2:
            self._bias += random.gauss(mu=0.0, sigma=0.2)
        
class TreeComponent:
    instances = []
    
    def __init__(self, in_size: int, out_size: int, parent=None):
        self._neurons = [ Neuron(in_size) for o in range(out_size) ]
        self._parent = parent
        self._children = []
        self._values = None
        TreeComponent.instances.append(self)
    
    def forward(self, x):
        assert len(x) == self.get_in_size(), f"input sizes do not match: {self} {len(x)} {self.get_in_size()}"
        
        x = [ n.forward(x) for n in self._neurons ]
        return x
        
    def eval_subtree(self):
        x = self._parent.get_values()
        self._values = self.forward(x)
        for child in self._children:
            child.eval_subtree()
            
    def get_values(self):
        return self._values
        
    def get_in_size(self):
        return len(self._neurons[0]._weights)
        
    def get_out_size(self):
        return len(self._neurons)
        
    def add_leaf(self):
        self._children.append(Leaf(self.get_out_size(), parent=self))
        
    def thicken(self):
        self._neurons.append(Neuron(self.get_in_size()))
        for child in self._children:
            for neuron in child._neurons:
                neuron._weights.append(random.uniform(-0.1,0.1))

class Root(TreeComponent):
    instance = None

    def __init__(self):
        super().__init__(2,2)
        assert Root.instance is None, "Root exists already."
        
        # guarantee one initial leaf
        self.add_leaf()
        
        Root.instance = self
        
    def eval_subtree(self):
        self._values = self.forward([1.0]*self.get_in_size())
        for child in self._children:
            child.eval_subtree()
            
    def thicken(self):
        super().thicken()
        for neuron in self._neurons:
            neuron._weights.append(random.uniform(-0.1,0.1))
        
class Leaf(TreeComponent):
    instances = []
    DEFAULT_OUT_SIZE = 2

    def __init__(self, in_size: int, parent=None):
        super().__init__(in_size, Leaf.DEFAULT_OUT_SIZE, parent=parent)
        assert parent
        self._children = None
        Leaf.instances.append(self)
        
    def eval_subtree(self):
        x = self._parent.get_values()
        self._values = self.forward(x)
        assert not self._children
        
    def add_leaf(self):
        assert False, "Called add_leaf on a leaf instance."
        
    def thicken(self):
        assert False, "Called thicken on a leaf instance"
        
    def grow_branch(self):
        # create a brand new branch
        new_branch = TreeComponent(self.get_in_size(), self.get_out_size(), parent=self._parent)
        new_branch._children.append(self)
        
        # adjust neurons
        new_branch._neurons = self._neurons
        self._neurons = [ Neuron(new_branch.get_out_size()) for o in range(Leaf.DEFAULT_OUT_SIZE) ]
        
        # integrate new branch into tree
        self._parent._children.append(new_branch)
        self._parent._children.remove(self)
        self._parent = new_branch
        

tree = Root()
        
        
