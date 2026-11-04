#!/bin/sh
# Runs inside the cage compositor. Arguments: <command> [options] of scripts/main.gd (--data-dir defaults to /data).
cmd=$1
shift
exec godot --main-pack /app/renderer.pck --rendering-driver vulkan --rendering-method "${GODOT_RENDERING_METHOD:-mobile}" \
    --display-driver wayland --audio-driver Dummy \
    --resolution 64x64 -s res://scripts/main.gd -- "$cmd" --data-dir "${DATA_DIR:-/data}" "$@"
