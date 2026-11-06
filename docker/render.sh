#!/bin/sh
# Runs inside the cage compositor. Arguments: <command> [options] of scripts/main.gd (--data-dir defaults to /data).
# The release template ignores -s, so scripts/main.gd runs as the main loop named in project.godot.
cmd=$1
shift
exec godot --rendering-driver vulkan --rendering-method "${GODOT_RENDERING_METHOD:-mobile}" \
    --display-driver wayland --audio-driver Dummy \
    --resolution 64x64 -- "$cmd" --data-dir "${DATA_DIR:-/data}" "$@"
