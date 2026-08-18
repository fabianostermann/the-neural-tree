#!/bin/bash
set -e

GODOT_BINARY="./godot_binary/Godot_v4.7.1-stable_linux.x86_64"
GODOT_PROJECT="godot_project/"
RESOLUTION="1920x1080"

GODOT_PID=""

if [ ! -f "$GODOT_BINARY" ]; then
  echo "Download godot binary first:"
  echo "  -> https://downloads.godotengine.org/?version=4.7.1&flavor=stable&slug=linux.x86_64.zip&platform=linux.64"
  echo "Then unzip and place godot binary at: $GODOT_BINARY"
  exit 1
fi

# Cleanup when the script ends, no matter how
cleanup() {
  if [ -n "$GODOT_PID" ]; then
    kill "$GODOT_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [ "$1" != "--dev" ]; then

  if [ "$1" == "-f" ]; then
    "$GODOT_BINARY" --path "$GODOT_PROJECT" --fullscreen &
  else
    "$GODOT_BINARY" --path "$GODOT_PROJECT" --resolution "$RESOLUTION" &
  fi
  GODOT_PID=$!

  echo "Godot Engine is running with PID $GODOT_PID..."
  sleep 2s
fi

conda run -n bbmuse --live-stream bbmuse .

sleep 2s
