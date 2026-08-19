#!/bin/bash
set -e

MINUTES=20

GODOT_BINARY="./godot_binary/Godot_v4.7.1-stable_linux.x86_64"
GODOT_PROJECT="godot_project/"

# Absolute, because --path makes Godot chdir into the project directory
CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/captures"

# Override with: AUDIO_SOURCE=... ./capture.sh
AUDIO_SOURCE="${AUDIO_SOURCE:-alsa_output.usb-Roland_EDIROL_UA-25EX-00.analog-stereo.monitor}"
FPS=30

GODOT_PID=""
FFMPEG_PID=""
PAREC_PID=""
FIFO=""
FILENAME_STEM=""

if [ ! -f "$GODOT_BINARY" ]; then
  echo "Download godot binary first:"
  echo "  -> https://downloads.godotengine.org/?version=4.7.1&flavor=stable&slug=linux.x86_64.zip&platform=linux.64"
  echo "Then unzip and place godot binary at: $GODOT_BINARY"
  exit 1
fi

for cmd in parec ffmpeg conda; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

if ! pactl list short sources 2>/dev/null | grep -qF "$AUDIO_SOURCE"; then
  echo "Audio source not found: $AUDIO_SOURCE"
  echo "Available sources:"
  pactl list short sources 2>/dev/null | awk '{print "  " $2}'
  exit 1
fi

# Order matters: parec must die first so ffmpeg sees EOF and finalizes the wav.
cleanup() {
  if [ -n "$PAREC_PID" ]; then
    kill "$PAREC_PID" 2>/dev/null || true
  fi
  if [ -n "$FFMPEG_PID" ]; then
    wait "$FFMPEG_PID" 2>/dev/null || true
  fi
  if [ -n "$GODOT_PID" ]; then
    kill "$GODOT_PID" 2>/dev/null || true
    wait "$GODOT_PID" 2>/dev/null || true
  fi
  if [ -n "$FIFO" ]; then
    rm -f "$FIFO"
  fi
  if [ -n "$FILENAME_STEM" ]; then
    echo
    echo "Capture written to:"
    echo "  $FILENAME_STEM.avi"
    echo "  $FILENAME_STEM.wav"
  fi
}

mkdir -p "$CAPTURE_DIR"
FILENAME_STEM="$CAPTURE_DIR/capture_$(date +%s%N)"

"$GODOT_BINARY" --path "$GODOT_PROJECT" \
    --fixed-fps "$FPS" \
    --write-movie "$FILENAME_STEM.avi" &
GODOT_PID=$!
echo "Godot Engine is running with PID $GODOT_PID..."

# FIFO instead of a shell pipeline so both PIDs are addressable.
# ($! on a pipeline only gives you the last process, i.e. ffmpeg.)
FIFO="$(mktemp -u)"
mkfifo "$FIFO"

ffmpeg -nostdin -f s16le -ac 2 -ar 44100 -i "$FIFO" \
       -sample_fmt s16 -compression_level 12 "$FILENAME_STEM.wav" \
       2> "$FILENAME_STEM.ffmpeg.log" &
FFMPEG_PID=$!

parec -d "$AUDIO_SOURCE" > "$FIFO" &
PAREC_PID=$!

echo "Recording audio from $AUDIO_SOURCE (parec $PAREC_PID -> ffmpeg $FFMPEG_PID)..."
sleep 2s

conda run -n bbmuse --live-stream bbmuse . --quit-after $((60*$MINUTES))

sleep 2s

echo "Cleanup.."
cleanup

echo "Muxing.."
ffmpeg -i "$FILENAME_STEM.avi" -i "$FILENAME_STEM.wav" \
       -map 0:v:0 -map 1:a:0 \
       -c:v libx264 -crf 18 -pix_fmt yuv420p \
       -c:a aac -b:a 320k \
       -shortest "$FILENAME_STEM.mp4"
