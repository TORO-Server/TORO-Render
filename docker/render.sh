#!/bin/sh
# Runs inside the cage compositor. Arguments are passed to scripts/render_tiles.gd.
exec godot --path /app --rendering-driver vulkan --display-driver wayland --audio-driver Dummy \
    --resolution 64x64 -s scripts/render_tiles.gd -- --data-dir /data "$@"
