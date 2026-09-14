REQUIRES = []
PROVIDES = ["MidiInEvents"]
import mido
from time import perf_counter as timestamp

MIDI_INS = []
DESIRED_MIDI_DEVICES = [
    #"UA-25",
    "microKEY",
    #"X4III"
] # <--- add your device

def _init():
    global MIDI_INS

    ports = mido.get_input_names()

    for device in DESIRED_MIDI_DEVICES:
        matching = [p for p in ports if device.lower() in p.lower()]
        if matching:
            MIDI_INS.append(mido.open_input(matching[0]))
              
    print("MIDI INS are:", MIDI_INS)

def _update(bb):

    for midi_in in MIDI_INS:
        for msg in midi_in.iter_pending():
            msg.time = timestamp()
            print(msg)
            bb.MidiInEvents.event_list.append(msg)


def _close():
    global MIDI_INS
    for midi_in in MIDI_INS:
        midi_in.close()
        midi_in = None
        
    print("MIDI INS were closed cleanly.")
