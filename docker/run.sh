#!/bin/bash
# Runs the renderer container on the iGPU with minimal priority.
#   docker/run.sh --region-dir /world --tiles "-8,4,2,2" --out /out
# Env: WORLD_DIR (region dir on the host), DATA_DIR (tools/build_data.py output), OUT_DIR, IMAGE, CPUS, MEMORY
set -euo pipefail

IMAGE=${IMAGE:-toro-gpu-renderer:dev}
DATA_DIR=${DATA_DIR:-$PWD/data}
OUT_DIR=${OUT_DIR:-$PWD/out}
WORLD_DIR=${WORLD_DIR:?set WORLD_DIR to the world region directory}
RENDER_GID=$(getent group render | cut -d: -f3)
mkdir -p "$OUT_DIR"

# EXTRA_GROUPS: space separated gids that may read the world files (e.g. the game server's group)
GROUPS_ARGS=(--group-add "$RENDER_GID")
for g in ${EXTRA_GROUPS:-}; do GROUPS_ARGS+=(--group-add "$g"); done

exec docker run --rm --name toro-gpu-render \
    --user "$(id -u):$(id -g)" "${GROUPS_ARGS[@]}" \
    --device /dev/dri/renderD128 \
    --cpus "${CPUS:-1}" --cpu-shares 32 --memory "${MEMORY:-1g}" --pids-limit 256 \
    --read-only --tmpfs /tmp:size=128m,exec \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$DATA_DIR:/data:ro" -v "$WORLD_DIR:/world:ro" -v "$OUT_DIR:/out" \
    "$IMAGE" "$@"
