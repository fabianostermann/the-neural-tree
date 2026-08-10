#!/bin/bash

set -e

if [ "$1" != "--dev" ];
then
  cd godot_project
  ../godot_binary/Godot_v4.7.1-stable_linux.x86_64 &
  PID=$!
  cd ..

  # Trap für Cleanup wenn Skript endet
  trap "kill $PID 2>/dev/null" EXIT INT TERM

  echo "Godot Engine is running with PID $PID..."
  sleep 2s
fi

conda run -n bbmuse --live-stream bbmuse .

sleep 2s
# exit
