#!/bin/bash

set -e

GODOT_BINARY="godot_binary/Godot_v4.7.1-stable_linux.x86_64"

if [ ! -f "$GODOT_BINARY" ];
then
  echo "Download godot binary first:"
  echo "  -> https://downloads.godotengine.org/?version=4.7.1&flavor=stable&slug=linux.x86_64.zip&platform=linux.64"
  echo "Then unzip and place godot binary at:" $GODOT_BINARY
  exit
fi

if [ "$1" != "--dev" ];
then
  cd godot_project
  ../$GODOT_BINARY --resolution 1920x1080 &
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
