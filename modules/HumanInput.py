USES = []
REQUIRES = [ "MidiInEvents" ]
PROVIDES = [ "Commands" ]

import random, time

SIMULATE = False

START = time.time()

def _update(bb):
    global START
    bb.Commands.reset_all()
    
    # handle MIDI events
    if bb.MidiInEvents.event_list:
        bb.Commands.started = True
        for msg in bb.MidiInEvents.event_list:
            if msg.type == "note_on":
                # A: mut_A_te
                bb.Commands.mutate_neuron = msg.note % 12 == 9
                # F#: fat
                bb.Commands.thicken = msg.note % 12 == 6
                # Bb: _B_orn
                bb.Commands.new_leaf = msg.note % 12 == 10
                # G: _G_row
                bb.Commands.grow_branch = msg.note % 12 == 7
        bb.MidiInEvents.event_list.clear()
    
    elapsed = time.time() - START
    if SIMULATE and elapsed > 1.0:
        # simulation of real human inputs
        bb.Commands.mutate_neuron = random.random() < 0.5
        bb.Commands.thicken = random.random() < 0.2
        bb.Commands.new_leaf = random.random() < 0.2
        bb.Commands.grow_branch = random.random() < 0.1
        
        START = time.time()
        
        bb.Commands.started = True
