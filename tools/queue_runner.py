"""Player-aware batch driver for the iGPU renderer (runs on the server host). Feature set of Dynmap-GPU's `run`.

    python tools/queue_runner.py --map-id 30002 --persp iso_SE_30_hires --extra-groups 1001 --zoom-max 7 \
        --world-dir /srv/minecraft/worlds/flat/region

Steps: scan the world once (scripts/scan_world.gd in the container, cached), plan the candidate tiles and mega tiles
(tools/tiledb.py plan, optionally only those with missing tiles), then for every group of mega tiles wait until nobody is
online and the host is idle, render it in the low priority container (docker/run.sh), upload zoom 0 to TiDB
(tools/tiledb.py upload) and delete the temporary files. The zoom-out levels are rebuilt once at the end from the tiles
that changed. Progress is kept in a state file so the job can be stopped and resumed at any time.

Quiet rule (same convention as dynmap-throttle.sh): the proxy plugin writes "<online> <unix time>" to --online-file;
a missing/stale file or online > --max-players means "busy". Only the batch in flight is finished when players join.

Options matching Dynmap-GPU: --bbox, --limit, --skip-megas, --only-missing, --count-missing, --zoom-all, --zoom-since,
--mega, --zoom-max, --rate, --keep-png (= --out), --scan-cache (= --cache).
"""
import argparse
import json
import os
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


def tools(a, args, mounts=()):
    """Runs tools/tiledb.py in the Python tools image (numpy/Pillow/PyMySQL stay off the production host)."""
    if a.uploader == "python":
        return subprocess.run(["nice", "-n", "19", sys.executable, os.path.join(HERE, "tiledb.py")] + args,
                              capture_output=True, text=True)
    cmd = ["docker", "run", "--rm", "--network", "host", "--user", f"{os.getuid()}:{os.getgid()}",
           "--cpus", "1", "--cpu-shares", "32", "--memory", "1g", "--read-only", "--tmpfs", "/tmp",
           "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "-v", f"{HERE}:/tools:ro"]
    for host, ctr, mode in mounts:
        cmd += ["-v", f"{host}:{ctr}:{mode}"]
    return subprocess.run(["nice", "-n", "19"] + cmd + [a.tools_image] + args, capture_output=True, text=True)


def db_args(a):
    return ["--map-id", str(a.map_id), "--host", a.db_host, "--port", str(a.db_port), "--rate", str(a.rate)]


def ensure_scan(a, work):
    cache = a.scan_cache or os.path.join(work, f"scan-{a.map_id}.bin")
    if os.path.exists(cache) and not a.rescan:
        return cache
    log(f"scanning {a.world_dir} (cache {cache})")
    out = os.path.join(work, "scan-out")
    shutil.rmtree(out, ignore_errors=True)
    env = dict(os.environ, WORLD_DIR=a.world_dir, DATA_DIR=a.data_dir, OUT_DIR=out, EXTRA_GROUPS=a.extra_groups,
               GODOT_SCRIPT="scripts/scan_world.gd")
    r = subprocess.run(["bash", os.path.join(ROOT, "docker", "run.sh"), "--region-dir", "/world", "--out", "/out/scan.bin"],
                       env=env, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(os.path.join(out, "scan.bin")):
        log("scan failed\n" + (r.stdout + r.stderr)[-800:])
        sys.exit(1)
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    shutil.move(os.path.join(out, "scan.bin"), cache)
    log([l for l in r.stdout.splitlines() if l.startswith("scan:")][-1:] or "scan done")
    return cache


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map-id", type=int, required=True)
    ap.add_argument("--world-dir", required=True, help="region directory on this host")
    ap.add_argument("--persp", default="iso_S_90_lowres",
                    choices=["iso_S_90_lowres", "iso_S_90_hires", "iso_SE_30_hires", "iso_SE_30_lowres"])
    ap.add_argument("--mode", choices=["mesh", "fast"], default="mesh",
                    help="mesh = any perspective, exact (default); fast = flat iso_S_90_lowres column shader")
    ap.add_argument("--bbox", help="tx0,ty0,tx1,ty1 inclusive")
    ap.add_argument("--mega", type=int, default=8)
    ap.add_argument("--per-run", type=int, default=8, help="mega tiles per renderer container run (amortises start-up)")
    ap.add_argument("--zoom-max", type=int, default=10)
    ap.add_argument("--rate", type=float, default=8_000_000)
    ap.add_argument("--only-missing", action="store_true", help="only render/write tiles that have no row yet")
    ap.add_argument("--count-missing", action="store_true", help="dry run: count the missing tiles and exit")
    ap.add_argument("--zoom-all", action="store_true", help="re-check every parent of every level (scans whole levels)")
    ap.add_argument("--zoom-since", type=int, help="also seed the zoom rebuild with candidate tiles written at/after this ms epoch")
    ap.add_argument("--skip-megas", type=int, default=0, help="skip the first N mega tiles of the plan")
    ap.add_argument("--scan-cache", help="scan cache file (default: work dir)")
    ap.add_argument("--rescan", action="store_true")
    ap.add_argument("--keep-png", help="copy the rendered PNG/WebP tiles of every batch here")
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
    ap.add_argument("--limit", type=int, default=0, help="stop after N mega tiles (testing)")
    ap.add_argument("--dry-run", action="store_true", help="render but do not write to TiDB")
    a = ap.parse_args()

    state_path = a.state or os.path.join(os.path.expanduser("~"), f".toro-gpu-render-{a.map_id}.json")
    done = set(json.load(open(state_path))) if os.path.exists(state_path) else set()
    work = a.work_dir
    os.makedirs(work, exist_ok=True)
    plan_dir = os.path.join(work, f"plan-{a.map_id}")
    os.makedirs(plan_dir, exist_ok=True)

    scan = ensure_scan(a, work)
    pargs = ["plan", "--scan", "/scan.bin", "--persp", a.persp, "--mega", str(a.mega), "--out-dir", "/plan"] + db_args(a)
    if a.bbox:
        pargs += ["--bbox", a.bbox]
    if a.only_missing:
        pargs += ["--only-missing"]
    if a.count_missing:
        pargs += ["--count-missing"]
    mounts = [(scan, "/scan.bin", "ro"), (plan_dir, "/plan", "rw")]
    if a.uploader == "python":
        pargs[pargs.index("/scan.bin")] = scan
        pargs[pargs.index("/plan")] = plan_dir
    p = tools(a, pargs, mounts)
    print(p.stdout.strip(), flush=True)
    if p.returncode != 0:
        log("plan failed\n" + p.stderr[-800:])
        sys.exit(1)
    if a.count_missing:
        return
    plan = json.load(open(os.path.join(plan_dir, "plan.json")))
    megas = [tuple(m) for m in plan["megas"]][a.skip_megas:]
    m = a.mega
    todo = [b for b in megas if f"{b[0]},{b[1]}" not in done]
    log(f"{len(megas)} mega tiles ({m}x{m}), {len(todo)} to do, state {state_path}")
    changed_file = os.path.join(plan_dir, "changed.txt")
    cand_in_tools = "/plan/tiles.npy" if a.uploader != "python" else os.path.join(plan_dir, "tiles.npy")
    rec_in_tools = "/plan/changed.txt" if a.uploader != "python" else changed_file

    env = dict(os.environ, WORLD_DIR=a.world_dir, DATA_DIR=a.data_dir, EXTRA_GROUPS=a.extra_groups)
    n_done = 0
    for g in range(0, len(todo), a.per_run):
        group = todo[g:g + a.per_run]
        wait_quiet(a)
        out = os.path.join(work, "batch")
        shutil.rmtree(out, ignore_errors=True)
        env["OUT_DIR"] = out
        rects = ";".join(f"{mx * m},{my * m},{m},{m}" for mx, my in group)
        t0 = time.time()
        r = subprocess.run(["bash", os.path.join(ROOT, "docker", "run.sh"), "--region-dir", "/world",
                            "--tiles", rects, "--out", "/out", "--persp", a.persp, "--mode", a.mode,
                            "--min-y", str(plan["min_y"]), "--max-y", str(plan["max_y"])],
                           env=env, capture_output=True, text=True)
        dirs = [os.path.join(out, f"r{mx * m}_{my * m}" if len(group) > 1 else "") for mx, my in group]
        if r.returncode != 0 or not all(os.path.exists(os.path.join(d, "manifest.json")) for d in dirs):
            log(f"batch {group[0]}..: render failed (rc={r.returncode})\n" + (r.stdout + r.stderr)[-800:])
            sys.exit(1)
        t1 = time.time()
        up_args = ["upload", "--zoom-max", str(a.zoom_max), "--candidates", cand_in_tools, "--no-zoom",
                   "--record", rec_in_tools] + db_args(a)
        up_args += ["--dry-run"] if a.dry_run else []
        up_args += ["--only-missing"] if a.only_missing else []
        cdirs = ["/out/" + os.path.relpath(d, out) if d != out else "/out" for d in dirs] if a.uploader != "python" else dirs
        up = tools(a, up_args + ["--dir"] + cdirs, [(out, "/out", "ro"), (plan_dir, "/plan", "rw")])
        if up.returncode != 0:
            log(f"batch {group[0]}..: upload failed\n" + (up.stdout + up.stderr)[-800:])
            sys.exit(1)
        if a.keep_png:
            os.makedirs(a.keep_png, exist_ok=True)
            for d in dirs:
                for f in os.listdir(d):
                    if f.endswith((".png", ".webp")):
                        shutil.copy(os.path.join(d, f), a.keep_png)
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

    # zoom-out levels, once, from every tile recorded as changed (also by earlier interrupted runs)
    seeds = os.path.exists(changed_file) and os.path.getsize(changed_file) > 0
    if (seeds or a.zoom_all or a.zoom_since) and not a.dry_run:
        wait_quiet(a)
        zargs = ["zoom", "--zoom-max", str(a.zoom_max)] + db_args(a)
        if seeds:
            zargs += ["--seed", rec_in_tools]
        if a.zoom_all:
            zargs += ["--all"]
        if a.zoom_since:
            zargs += ["--since", str(a.zoom_since), "--candidates", cand_in_tools]
        log("rebuilding zoom-out levels")
        z = tools(a, zargs, [(plan_dir, "/plan", "ro")])
        if z.returncode != 0:
            log("zoom failed\n" + (z.stdout + z.stderr)[-800:])
            sys.exit(1)
        print(z.stdout.strip(), flush=True)
        if seeds:
            os.replace(changed_file, changed_file + ".done")
    log("finished" if not a.limit else "stopped at limit")


if __name__ == "__main__":
    main()
