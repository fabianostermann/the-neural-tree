# The Neural Tree
*by Fabian Ostermann & Tim Löhde*

A live performance system in which a neural network is *grown* rather than trained.
Two performers: one shapes a growing network by hand, the other plays the MIDI stream
it produces. A tree, rendered from the network's own topology, is projected for the
audience.

There is no fitness function. The only selection pressure is the human ear.

<!-- ![screenshot](docs/screenshot.png) -->

## How it works

The system is built on the [BbMuse](https://github.com/fabianostermann/bbmuse) blackboard framework
and consists of two programs that talk over TCP.

**Python — sound and structure.** `HumanInput` collects four commands (`mutate_neuron`,
`thicken`, `new_leaf`, `grow_branch`); `Controller` applies them to the `NeuralTree`;
`Prober` maps the activations of all leaf nodes to MIDI notes and control changes;
`MIDISender` flushes them to a MIDI port or to a FluidSynth instance it starts itself.
The network is fed a constant input, so its output only changes when a command changes
its shape.

**Godot — visuals.** `Layout` turns the transmitted graph into branch angles, `Simulation`
adds growth and wind, `Renderer` draws it. Two full-screen shaders follow: a glitch stage
that fires on every structural change, and one emulating a screen filmed with a phone camera.

## Requirements

- Python 3.12+, [`BbMuse`](https://pypi.org/project/bbmuse/), [`mido`](https://mido.readthedocs.io/) with a backend (`python-rtmidi`)
- [Godot](https://godotengine.org/) 4.7+ (only for the visuals)
- [FluidSynth](https://www.fluidsynth.org/) and a General MIDI SoundFont — **not included**,
  see `fluidsynth.conf` for the expected path, or, for advanced users, you can send MIDI streams to other synthesizers (recommended for serious performances)

## Install
```bash
pip install -r requirements.txt
```
or
```bash
conda env create -f environment.yml -n bbmuse
```

## Running

On Linux, use the run script (needs the conda-based installation):
```bash
bash run.sh
```
Starts Godot first (it listens on `127.0.0.1:9999`) and the BbMuse program (started with `bbmuse .`) automatically connects to it.

Both sides reconnect on their own, so either can be restarted mid-performance.
To run the visuals on a second machine, change `HOST` in `modules/Visualizer.py`.

Out of the box, `HumanInput` fires random commands so the system runs unattended.
In performance this module is live coded — you may want to replace it, or configure it.

## Performing

If you'd like to perform this piece in public, let us know and we will happily allow it!

## Citing

This piece was performed at AIMC'26 in Berlin, Germany, and a companion paper is available:

```bibtex
@inproceedings{neuraltree,
  author  = {Fabian Ostermann and Tim Löhde},
  title   = {Planting and Shaping the Neural Tree: Growing a Musical Collaborator Through Objective-Free Neuroevolution in Open-Ended Exploration},
  booktitle = {The AI Music Creativity Conference (AIMC)},
  address = {Berlin, Germany},
  year    = {2026},
  doi     = {TBA},
}
```
