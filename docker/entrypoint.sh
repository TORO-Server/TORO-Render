#!/bin/sh
# Starts a headless wlroots compositor (cage) on the iGPU's render node and runs the Godot renderer inside it.
# Godot's --headless driver has no RenderingDevice, and Xvfb has no DRI3 (Mesa then falls back to llvmpipe),
# so a headless Wayland compositor is what gives Godot a presentable Vulkan surface on the Intel GPU.
set -eu

export HOME=/tmp
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export WLR_BACKENDS=headless
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER=gles2
export WLR_RENDER_DRM_DEVICE=${RENDER_NODE:-/dev/dri/renderD128}

# lowest CPU and IO priority; the game server always wins
renice -n 19 -p $$ > /dev/null
ionice -c3 -p $$
exec cage -- /app/docker/render.sh "$@"
