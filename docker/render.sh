#!/bin/sh
# Runs inside the cage compositor. Arguments: <command> [options] of scripts/main.gd (--data-dir defaults to /data).
cmd=$1
shift
exec godot --path /app --rendering-driver vulkan --rendering-method "${GODOT_RENDERING_METHOD:-mobile}" \
    --display-driver wayland --audio-driver Dummy \
    --resolution 64x64 -s scripts/main.gd -- "$cmd" --data-dir "${DATA_DIR:-/data}" "$@"
