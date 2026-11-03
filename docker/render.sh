#!/bin/sh
# Runs inside the cage compositor. Arguments are passed to scripts/render_tiles.gd.
exec godot --path /app --rendering-driver vulkan --rendering-method "${GODOT_RENDERING_METHOD:-mobile}" \
    --display-driver wayland --audio-driver Dummy \
    --resolution 64x64 -s "${GODOT_SCRIPT:-scripts/render_tiles.gd}" -- --data-dir /data "$@"
