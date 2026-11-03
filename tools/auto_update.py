"""Keeps one Dynmap map up to date around the places players changed or explored (runs on the server host, stdlib only).

    python3 tools/auto_update.py --map-id 30002 --persp iso_SE_30_hires --zoom-max 7 --extra-groups 1001 \
        --world-dir /srv/minecraft/worlds/flat/region

How it finds the places: every Anvil region file keeps a "last saved" timestamp per chunk in its header. Chunks the game
server saved after the previous cycle (new terrain generated while walking, blocks placed or broken, redstone, growth)
are the changed ones. Their 3x3 neighbourhood (light and face culling look one chunk over) is projected into tiles with
the map's perspective; the 8x8 mega tiles those tiles belong to are re-rendered in the low priority container
(docker/run.sh), written to TiDB with the usual hash skip and the zoom-out parents are rebuilt. Unchanged tiles cost
nothing. Cheap polling: region files whose mtime did not change are not even opened.

Load protection (players may be online, unlike the whole-map job): a cycle only starts when the 1-minute load is below
--max-load, at most --max-megas mega tiles are rendered per cycle, the rest stays queued in the state file.
"""
import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import queue_runner as qr  # noqa: E402  (tools(), log())

PERSPECTIVES = {
    "iso_S_90_lowres": (180.0, 90.0, 4),
    "iso_S_90_hires": (180.0, 90.0, 16),
    "iso_SE_30_hires": (135.0, 30.0, 16),
    "iso_SE_30_lowres": (135.0, 30.0, 4),
}
TILE = 128


def matmul(m, a):
    return [[sum(m[i][k] * a[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def persp_matrix(name):
    """world->map matrix, same maths as scripts/persp.gd / tools/mapplan.py (pure Python)."""
    az_cfg, incl, scale = PERSPECTIVES[name]
    az = 90.0 + az_cfg
    if az >= 360.0:
        az -= 360.0

    def rxy(a, d):
        s, c = math.sin(math.radians(d)), math.cos(math.radians(d))
        return matmul([[c, s, 0], [-s, c, 0], [0, 0, 1]], a)

    def ryz(a, d):
        s, c = math.sin(math.radians(d)), math.cos(math.radians(d))
        return matmul([[1, 0, 0], [0, c, s], [0, -s, c]], a)

    t = [[0, 0, -1], [-1, 0, 0], [0, 1, 0]]
    t = rxy(t, 180.0 - az)
    t = ryz(t, 90.0 - incl)
    t = matmul([[1, 0, 0], [0, 1, 0], [0, math.tan(math.radians(90.0 - incl)), 1]], t)
    t = matmul([[scale, 0, 0], [0, scale, 0], [0, 0, math.sin(math.radians(incl))]], t)
    return t, scale


def changed_chunks(world_dir, state, since):
    """Chunks saved after `since` (epoch seconds) in region files whose mtime moved. Updates state['mtimes']."""
    out = []
    mt = state.setdefault("mtimes", {})
    with os.scandir(world_dir) as it:
        for e in it:
            m = re.fullmatch(r"r\.(-?\d+)\.(-?\d+)\.mca", e.name)
            if not m:
                continue
            st = e.stat()
            if mt.get(e.name) == st.st_mtime_ns:
                continue
            mt[e.name] = st.st_mtime_ns
            if st.st_mtime < since:
                continue
            with open(e.path, "rb") as f:
                head = f.read(8192)
            if len(head) < 8192:
                continue
            rx, rz = int(m[1]), int(m[2])
            stamps = struct.unpack(">1024I", head[4096:])
            for i, ts in enumerate(stamps):
                if ts > since and head[i * 4 + 3] != 0:
                    out.append((rx * 32 + i % 32, rz * 32 + i // 32))
    return out


def tiles_of(chunks, name, y0, y1):
    """Tiles any of the chunks (plus their 8 neighbours) can project into."""
    m, s = persp_matrix(name)
    ring = {(cx + dx, cz + dz) for cx, cz in chunks for dx in (-1, 0, 1) for dz in (-1, 0, 1)}
    tiles = set()
    for cx, cz in ring:
        xs, ys = [], []
        for wx in (cx * 16, cx * 16 + 16):
            for wz in (cz * 16, cz * 16 + 16):
                for wy in (y0, y1):
                    xs.append(m[0][0] * wx + m[0][1] * wy + m[0][2] * wz)
                    ys.append(m[1][0] * wx + m[1][1] * wy + m[1][2] * wz)
        for ty in range(math.floor((min(ys) - s) / TILE), math.floor((max(ys) + s) / TILE) + 1):
            for tx in range(math.floor((min(xs) - s) / TILE), math.floor((max(xs) + s) / TILE) + 1):
                tiles.add((tx, ty))
    return tiles


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map-id", type=int, required=True)
    ap.add_argument("--world-dir", required=True)
    ap.add_argument("--persp", required=True, choices=sorted(PERSPECTIVES))
    ap.add_argument("--mega", type=int, default=8)
    ap.add_argument("--zoom-max", type=int, default=10)
    ap.add_argument("--min-y", type=int, default=-64)
    ap.add_argument("--max-y", type=int, default=320)
    ap.add_argument("--interval", type=float, default=60, help="seconds between polls")
    ap.add_argument("--overlap", type=float, default=30,
                    help="seconds of overlap between polls (second-resolution timestamps, files written during a poll)")
    ap.add_argument("--max-load", type=float, default=2.5)
    ap.add_argument("--max-megas", type=int, default=4, help="mega tiles rendered per cycle")
    ap.add_argument("--rate", type=float, default=2_000_000)
    ap.add_argument("--local", action="store_true",
                    help="run inside the toro-gpu-renderer image (resident container): render and upload in-process")
    ap.add_argument("--once", action="store_true", help="one cycle, then exit")
    ap.add_argument("--dry-run", action="store_true", help="render but do not write to TiDB")
    ap.add_argument("--state", default=None)
    ap.add_argument("--uploader", choices=["container", "python"], default="container")
    ap.add_argument("--tools-image", default="toro-gpu-tools:dev")
    ap.add_argument("--db-host", default="127.0.0.1")
    ap.add_argument("--db-port", type=int, default=4000)
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data"))
    ap.add_argument("--extra-groups", default="")
    ap.add_argument("--work-dir", default="/dev/shm/toro-gpu-watch")
    a = ap.parse_args()

    state_path = a.state or os.path.join(os.path.expanduser("~"), f".toro-gpu-watch-{a.map_id}.json")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    state.setdefault("since", time.time())  # first start: only look at what changes from now on
    state.setdefault("pending", [])
    os.makedirs(a.work_dir, exist_ok=True)
    env = dict(os.environ, WORLD_DIR=a.world_dir, DATA_DIR=a.data_dir, EXTRA_GROUPS=a.extra_groups)
    qr.log(f"watching {a.world_dir} for map {a.map_id} ({a.persp}), state {state_path}")

    while True:
        cycle_start = time.time()
        cutoff = cycle_start - a.overlap
        try:
            ch = changed_chunks(a.world_dir, state, state["since"])
            ch = [c for c in ch]  # timestamps already > since
        except OSError as e:
            qr.log(f"scan failed: {e}")
            ch = []
        if ch:
            fresh = tiles_of(ch, a.persp, a.min_y, a.max_y)
            megas = {(x // a.mega, y // a.mega) for x, y in fresh}
            pending = {tuple(p) for p in state["pending"]} | megas
            state["pending"] = sorted(pending)
            qr.log(f"{len(ch)} changed chunks -> {len(megas)} mega tiles ({len(pending)} pending)")
        # the next poll starts a little before this one so nothing saved while we were reading is missed
        state["since"] = cutoff
        if state["pending"]:
            load1 = os.getloadavg()[0]
            if load1 > a.max_load:
                qr.log(f"load1={load1:.2f} > {a.max_load}, postponing {len(state['pending'])} mega tiles")
            else:
                group = [tuple(p) for p in state["pending"][:a.max_megas]]
                if render_and_upload(a, env, group):
                    state["pending"] = state["pending"][len(group):]
        json.dump(state, open(state_path, "w"))
        if a.once:
            return
        time.sleep(max(1.0, a.interval - (time.time() - cycle_start)))


def render_and_upload(a, env, group):
    m = a.mega
    out = os.path.join(a.work_dir, "batch")
    shutil.rmtree(out, ignore_errors=True)
    env = dict(env, OUT_DIR=out)
    rects = ";".join(f"{mx * m},{my * m},{m},{m}" for mx, my in group)
    t0 = time.time()
    if a.local:  # inside the resident container: render straight through the cage entrypoint, no nested docker
        r = subprocess.run([os.path.join(ROOT, "docker", "entrypoint.sh"), "--region-dir", a.world_dir, "--tiles", rects,
                            "--out", out, "--persp", a.persp, "--min-y", str(a.min_y), "--max-y", str(a.max_y)],
                           env=env, capture_output=True, text=True)
    else:
        r = subprocess.run(["bash", os.path.join(ROOT, "docker", "run.sh"), "--region-dir", "/world", "--tiles", rects,
                            "--out", "/out", "--persp", a.persp, "--min-y", str(a.min_y), "--max-y", str(a.max_y)],
                           env=env, capture_output=True, text=True)
    dirs = [os.path.join(out, f"r{mx * m}_{my * m}" if len(group) > 1 else "") for mx, my in group]
    if r.returncode != 0 or not all(os.path.exists(os.path.join(d, "manifest.json")) for d in dirs):
        qr.log(f"render failed (rc={r.returncode})\n" + (r.stdout + r.stderr)[-600:])
        return False
    t1 = time.time()
    up_args = ["upload", "--zoom-max", str(a.zoom_max), "--map-id", str(a.map_id), "--host", a.db_host,
               "--port", str(a.db_port), "--rate", str(a.rate)] + (["--dry-run"] if a.dry_run else [])
    cdirs = ["/out/" + os.path.relpath(d, out) if d != out else "/out" for d in dirs] if a.uploader != "python" and not a.local else dirs
    ns = argparse.Namespace(uploader="python" if a.local else a.uploader, tools_image=a.tools_image)
    up = qr.tools(ns, up_args + ["--dir"] + cdirs, [(out, "/out", "ro")])
    if up.returncode != 0:
        qr.log("upload failed\n" + (up.stdout + up.stderr)[-600:])
        return False
    shutil.rmtree(out, ignore_errors=True)
    summary = " | ".join(l for l in up.stdout.splitlines() if l.startswith(("zoom 0", "zoom 1")))
    qr.log(f"megas {group[0]}..{group[-1]} ({len(group)}) render {t1 - t0:.1f}s upload {time.time() - t1:.1f}s | {summary}")
    return True


if __name__ == "__main__":
    main()
