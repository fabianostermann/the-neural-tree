REQUIRES = [ "NeuralTree" ]
PROVIDES = [ "MIDIMessages" ]

import math, random, time
import mido

TARGET_TIME = None

LEAF_PER_NEW_CHANNEL = 8
NUM_OF_CHANNEL = 8

def _update(bb):
    global TARGET_TIME
    
    if TARGET_TIME is None:
        TARGET_TIME = future()

    if TARGET_TIME <= time.time(): 
        raw_activations = []
        for leaf in bb.NeuralTree.Leaf.instances:
            raw_activations.append(leaf.get_activations())
        
        if raw_activations:
            make_note_on(bb.MIDIMessages.note_on, raw_activations)
            make_note_off(bb.MIDIMessages.note_off, raw_activations)
            make_cc(bb.MIDIMessages.cc, raw_activations)
            
        num_of_leafs = max(1, len(bb.NeuralTree.Leaf.instances))
        TARGET_TIME = future(k=num_of_leafs)
        
def make_note_on(send_list, acts):
    # take a random leaf and generate a note on event
    act = random.choice(acts)
    num_of_leafs = max(1, len(acts))
    
    note = int(act[0]*127)
    velo = int(act[1]*127)
    
    # new channel every 4 leaves
    max_chan = min(NUM_OF_CHANNEL-1,int(num_of_leafs/LEAF_PER_NEW_CHANNEL))+1
    chan = random.choice(range(max_chan))
    
    send_list.append(
        mido.Message('note_on', channel=chan, note=note, velocity=velo, time=time.time())
    )

def make_note_off(send_list, acts, exponent=0.1):
    num_of_leafs = max(1, len(acts))

    # target polyphony: 1 note at 1 leaf, ~6 at 200 leaves
    target_voices = num_of_leafs ** exponent

    # this many blind shots are needed for that density to settle in
    expected = 128.0 / target_voices - 1.0

    count = int(expected)
    if random.random() < (expected - count):
        count += 1

    # new channel every 4 leaves
    max_chan = min(NUM_OF_CHANNEL-1,int(num_of_leafs/LEAF_PER_NEW_CHANNEL))+1
    
    count *= max_chan
    for note in random.choices(range(0, 128), k=count):  
        chan = random.choice(range(max_chan))
        send_list.append(
            mido.Message('note_off', channel=chan, note=note, velocity=0)
        )
    
def make_cc(send_list, acts):
    for i, act in enumerate(acts):
    
        mu = act[0]
        sigma = act[1] * 0.05
        
        # send same CC to all channels
        for chan in range(NUM_OF_CHANNEL):
            # sample value from normal distribution
            value = max(0, min(int(random.gauss(mu, sigma)*127), 127))
            send_list.append(
                mido.Message('control_change', control=i%117 + 11, value=value, channel=chan)
            )
        
        random.shuffle(send_list) # ensure to be able to manually catch different events in a DAW
        
        
def future(k=0):
    # TODO make this human changeable, e.g. through REQUIRE(HumanInput)
    return time.time() + random.uniform(0.05, 2.0)**2 / (0.05*k + 1.0)
