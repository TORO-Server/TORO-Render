#!/bin/bash
# One-off job container on the iGPU with minimal priority.
#   docker/run.sh render --region-dir /world --tiles "-8,4,2,2" --out /out
#   docker/run.sh run --map-id 30002 --state-dir /state          (needs CONFIG, see docker/maps.example.json)
# Env:
#   WORLD_DIR     region directory on the host, mounted read-only at /world
#   DATA_DIR      output of `build-data` (default ./data), mounted read-only at /data
#   OUT_DIR       mounted at /out (default ./out)
#   STATE_DIR     mounted at /state: scan caches and job progress (default ./state)
#   CONFIG        maps.json mounted read-only at /config/maps.json
#   ONLINE_FILE   proxy presence file mounted at /online.txt (use with run --online-file /online.txt)
#   EXTRA_GROUPS  space separated gids that may read the world files
#   NETWORK       docker network (default: $DB_NETWORK or minecraft-network for run/zoom/watch, none otherwise)
#   DB_PASSWORD_FILE    file with the database password, mounted read-only at /run/secrets/db_password
#   DYNMAP_DB_PASSWORD  the password itself: passed by name, so its value stays off the docker command line
#   IMAGE, CPUS, MEMORY
set -euo pipefail

IMAGE=${IMAGE:-toro-renderer:dev}
DATA_DIR=${DATA_DIR:-$PWD/data}
OUT_DIR=${OUT_DIR:-$PWD/out}
STATE_DIR=${STATE_DIR:-$PWD/state}
RENDER_GID=$(getent group render | cut -d: -f3)
mkdir -p "$OUT_DIR" "$STATE_DIR"

case "${1:-}" in
    run|zoom|watch) NETWORK=${NETWORK:-${DB_NETWORK:-minecraft-network}} ;;
    *) NETWORK=${NETWORK:-none} ;;
esac

MOUNTS=(-v "$DATA_DIR:/data:ro" -v "$OUT_DIR:/out" -v "$STATE_DIR:/state")
[ -n "${WORLD_DIR:-}" ] && MOUNTS+=(-v "$WORLD_DIR:/world:ro")
[ -n "${CONFIG:-}" ] && MOUNTS+=(-v "$CONFIG:/config/maps.json:ro")
[ -n "${ONLINE_FILE:-}" ] && MOUNTS+=(-v "$ONLINE_FILE:/online.txt:ro")

DB_ARGS=()
if [ -n "${DB_PASSWORD_FILE:-}" ]; then
    MOUNTS+=(-v "$DB_PASSWORD_FILE:/run/secrets/db_password:ro")
    DB_ARGS+=(-e DYNMAP_DB_PASSWORD_FILE=/run/secrets/db_password)
fi
[ -n "${DYNMAP_DB_PASSWORD:-}" ] && DB_ARGS+=(-e DYNMAP_DB_PASSWORD)

GROUPS_ARGS=(--group-add "$RENDER_GID")
for g in ${EXTRA_GROUPS:-}; do GROUPS_ARGS+=(--group-add "$g"); done

exec docker run --rm --name toro-renderer --network "$NETWORK" \
    --user "$(id -u):$(id -g)" "${GROUPS_ARGS[@]}" \
    --device /dev/dri/renderD128 \
    --cpus "${CPUS:-1}" --cpu-shares 32 --memory "${MEMORY:-1g}" --pids-limit 256 \
    --read-only --tmpfs /tmp:size=256m,exec \
    --cap-drop ALL --security-opt no-new-privileges \
    -e GODOT_RENDERING_METHOD="${GODOT_RENDERING_METHOD:-mobile}" "${DB_ARGS[@]}" \
    "${MOUNTS[@]}" "$IMAGE" "$@"
