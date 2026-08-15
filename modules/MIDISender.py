USES = []
REQUIRES = [ "MIDIMessages" ]
PROVIDES = [ "ext. MIDI device" ]

from time import sleep, time as timestamp
import sys, os, subprocess, signal
import mido
from pathlib import Path

FLUIDSYNTH_PROCESS = None
MIDI_OUT = None

MIDI_DEVICE_NAME = "Fluidsynth" # "Vir" or "UA-25EX"; if "Fluidsynth": opens a fluidsynth instance 
FLUIDSYNTH_CONF = "./fluidsynth.conf"

def open_matching_midi_out(match):
    """ Find a device, e.g. "UA-25", "Fluid", "Timidity", etc. """
    ports = mido.get_output_names()
    print("All avail. ports:", ports)

    matching = [p for p in ports if match.lower() in p.lower()]
    print("Matching ports:", matching)

    return mido.open_output(matching[0])

def create_fluidsynth_out(name="default"):
    global FLUIDSYNTH_PROCESS
    name = "bbmuse-"+name
    cmd = ["fluidsynth",
            "-a", "pulseaudio",
            "-m", "alsa_seq",
            "-o", "midi.portname="+str(name),
        ]
    if os.path.isfile(FLUIDSYNTH_CONF):
        cmd += ["-f", FLUIDSYNTH_CONF]
        print(f"Found fluidsynth config file at '{Path(FLUIDSYNTH_CONF).absolute()}'.")
    else:
        print(f"Fluidsynth config file '{FLUIDSYNTH_CONF}' not found. Falling back to default config (usually ~/.fluidsynth).")
    FLUIDSYNTH_PROCESS = subprocess.Popen(
        cmd,
        start_new_session=True,
        stdin=subprocess.PIPE,
        stdout=sys.stdout,
        stderr=sys.stdout,
    )
    sleep(1)

    return open_matching_midi_out(name)

def _init():
    global MIDI_OUT

    if MIDI_DEVICE_NAME != "Fluidsynth":
        MIDI_OUT = open_matching_midi_out(MIDI_DEVICE_NAME)
    else:
        MIDI_OUT = create_fluidsynth_out()

def _update(bb):
    """Sends all MIDI messages queued in the blackboard."""

    if MIDI_OUT is None:
        return

    for msg in bb.MIDIMessages.cc:
        send_message(msg)
        
    for msg in bb.MIDIMessages.note_off:
        send_message(msg)
        
    for msg in bb.MIDIMessages.note_on:
        send_message(msg)
            
    bb.MIDIMessages.clear()

def send_message(msg):
    if msg.time < timestamp():
        #print("Sending:", msg)
        MIDI_OUT.send(msg)

        if msg.time > 0:
            latency_ms = (timestamp() - msg.time)*1000
            if latency_ms >= 0.5:
                latency_ms = round(latency_ms, 2)
                print("WARNING: Sending msg to MIDI_OUT with latency of", latency_ms, "ms")

def _close():
    global MIDI_OUT

    if MIDI_OUT is not None:
        # all notes off
        for ch in range(16):
            for pitch in range(128):
                MIDI_OUT.send(mido.Message('note_off', note=pitch, channel=ch))

        MIDI_OUT.close()
        MIDI_OUT = None
        print("MIDI OUT closed cleanly.")

    if FLUIDSYNTH_PROCESS:
        os.killpg(os.getpgid(FLUIDSYNTH_PROCESS.pid), signal.SIGTERM)
