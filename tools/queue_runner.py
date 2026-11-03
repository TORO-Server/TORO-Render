"""Player-aware batch runner for the iGPU renderer (runs on the server host).

    python tools/queue_runner.py --map-id 60001 --world-dir /srv/minecraft/worlds/map/region \
        --zoom-max 10 --extra-groups 1001

Splits the world into mega tiles (default 8x8 tiles), and for each one: waits until nobody is online and the host is
idle, renders it in the low priority container (docker/run.sh), uploads it to TiDB (tools/tiledb.py) and deletes the
temporary files. Progress is kept in a state file so the job can be stopped and resumed at any time.

Quiet rule (same convention as dynmap-throttle.sh): the proxy plugin writes "<online> <unix time>" to --online-file;
a missing/stale file or online > --max-players means "busy". Only the batch in flight is finished when players join.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def is_quiet(a):
    try:
        n, t = open(a.online_file).read().split()[:2]
        if time.time() - int(t) > a.stale_after or int(n) > a.max_players:
            return False, f"online={n}"
    except Exception as e:  # unreadable -> busy
        return False, f"online.txt unreadable ({e})"
    load1 = os.getloadavg()[0]
    if load1 > a.max_load:
        return False, f"load1={load1:.2f}"
    return True, ""


def wait_quiet(a):
    announced = False
    while True:
        ok, why = is_quiet(a)
        if ok:
            if announced:
                log("quiet again, resuming")
            return
        if not announced:
            log(f"waiting: {why}")
            announced = True
        time.sleep(a.poll)


def region_bbox(world_dir):
    xs, zs = [], []
    for f in glob.glob(os.path.join(world_dir, "r.*.*.mca")):
        m = re.match(r"r\.(-?\d+)\.(-?\d+)\.mca$", os.path.basename(f))
        if m and os.path.getsize(f) > 8192:
            xs.append(int(m[1]))
            zs.append(int(m[2]))
    if not xs:
        raise SystemExit("no region files")
    # region (X,Z) covers tiles tx 16X..16X+15 and ty -16Z-16..-16Z-1
    return 16 * min(xs), -16 * max(zs) - 16, 16 * max(xs) + 15, -16 * min(zs) - 1, set(zip(xs, zs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map-id", type=int, required=True)
    ap.add_argument("--world-dir", required=True, help="region directory on this host")
    ap.add_argument("--bbox", help="tx0,ty0,tx1,ty1 inclusive (default: all region files)")
    ap.add_argument("--mega", type=int, default=8)
    ap.add_argument("--per-run", type=int, default=8, help="mega tiles per renderer container run (amortises start-up)")
    ap.add_argument("--zoom-max", type=int, default=10)
    ap.add_argument("--rate", type=float, default=8_000_000)
    ap.add_argument("--uploader", choices=["container", "python"], default="container",
                    help="run tiledb.py in the tools image (default) or with this interpreter")
    ap.add_argument("--tools-image", default="toro-gpu-tools:dev")
    ap.add_argument("--db-host", default="127.0.0.1")
    ap.add_argument("--db-port", type=int, default=4000)
    ap.add_argument("--data-dir", default=os.path.join(ROOT, "data"))
    ap.add_argument("--extra-groups", default="", help="gids that may read the world files")
    ap.add_argument("--work-dir", default="/dev/shm/toro-gpu-render")
    ap.add_argument("--state", default=None)
    ap.add_argument("--online-file", default="/srv/proxy/online.txt")
    ap.add_argument("--max-players", type=int, default=0)
    ap.add_argument("--stale-after", type=int, default=120)
    ap.add_argument("--max-load", type=float, default=4.0)
    ap.add_argument("--poll", type=float, default=30)
    ap.add_argument("--gap", type=float, default=1.0, help="seconds between batches")
    ap.add_argument("--limit", type=int, default=0, help="stop after N batches (testing)")
    ap.add_argument("--dry-run", action="store_true", help="render but do not write to TiDB")
    a = ap.parse_args()

    state_path = a.state or os.path.join(os.path.expanduser("~"), f".toro-gpu-render-{a.map_id}.json")
    done = set(json.load(open(state_path))) if os.path.exists(state_path) else set()

    rbx0, rby0, rbx1, rby1, regions = region_bbox(a.world_dir)
    if a.bbox:
        bx0, by0, bx1, by1 = map(int, a.bbox.split(","))
    else:
        bx0, by0, bx1, by1 = rbx0, rby0, rbx1, rby1
    m = a.mega
    batches = []
    for my in range(by0 // m, by1 // m + 1):
        for mx in range(bx0 // m, bx1 // m + 1):
            tx0, ty0 = mx * m, my * m
            # skip megas that touch no existing region file
            rx = {tx // 16 for tx in (tx0, tx0 + m - 1)}
            rz = {(-ty - 1) // 16 for ty in (ty0, ty0 + m - 1)}
            if not any((x, z) in regions for x in rx for z in rz):
                continue
            batches.append((mx, my))
    todo = [b for b in batches if f"{b[0]},{b[1]}" not in done]
    log(f"{len(batches)} mega tiles ({m}x{m}), {len(todo)} to do, state {state_path}")

    os.makedirs(a.work_dir, exist_ok=True)
    env = dict(os.environ, WORLD_DIR=a.world_dir, DATA_DIR=a.data_dir, EXTRA_GROUPS=a.extra_groups)
    n_done = 0
    for g in range(0, len(todo), a.per_run):
        group = todo[g:g + a.per_run]
        wait_quiet(a)
        out = os.path.join(a.work_dir, "batch")
        shutil.rmtree(out, ignore_errors=True)
        env["OUT_DIR"] = out
        rects = ";".join(f"{mx * m},{my * m},{m},{m}" for mx, my in group)
        t0 = time.time()
        r = subprocess.run(["bash", os.path.join(ROOT, "docker", "run.sh"), "--region-dir", "/world",
                            "--tiles", rects, "--out", "/out"], env=env, capture_output=True, text=True)
        dirs = [os.path.join(out, f"r{mx * m}_{my * m}" if len(group) > 1 else "") for mx, my in group]
        if r.returncode != 0 or not all(os.path.exists(os.path.join(d, "manifest.json")) for d in dirs):
            log(f"batch {group[0]}..: render failed (rc={r.returncode})\n" + (r.stdout + r.stderr)[-800:])
            sys.exit(1)
        t1 = time.time()
        up_args = ["upload", "--map-id", str(a.map_id), "--zoom-max", str(a.zoom_max), "--host", a.db_host,
                   "--port", str(a.db_port), "--rate", str(a.rate)] + (["--dry-run"] if a.dry_run else [])
        if a.uploader == "python":
            cmd = [sys.executable, os.path.join(HERE, "tiledb.py")] + up_args + ["--dir"] + dirs
        else:
            cdirs = ["/out/" + os.path.relpath(d, out) if d != out else "/out" for d in dirs]
            cmd = ["docker", "run", "--rm", "--network", "host", "--user", f"{os.getuid()}:{os.getgid()}",
                   "--cpus", "1", "--cpu-shares", "32", "--memory", "512m", "--read-only", "--tmpfs", "/tmp",
                   "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                   "-v", f"{HERE}:/tools:ro", "-v", f"{out}:/out:ro", a.tools_image] + up_args + ["--dir"] + cdirs
        up = subprocess.run(["nice", "-n", "19"] + cmd, capture_output=True, text=True)
        if up.returncode != 0:
            log(f"batch {group[0]}..: upload failed\n" + (up.stdout + up.stderr)[-800:])
            sys.exit(1)
        shutil.rmtree(out, ignore_errors=True)
        for mx, my in group:
            done.add(f"{mx},{my}")
        json.dump(sorted(done), open(state_path, "w"))
        n_done += len(group)
        summary = " | ".join(l for l in up.stdout.splitlines() if l.startswith("zoom 0"))
        log(f"megas {group[0]}..{group[-1]} [{n_done}/{len(todo)}] render {t1 - t0:.1f}s upload {time.time() - t1:.1f}s | {summary}")
        if a.limit and n_done >= a.limit:
            break
        time.sleep(a.gap)
    log("finished" if not a.limit else "stopped at limit")


if __name__ == "__main__":
    main()