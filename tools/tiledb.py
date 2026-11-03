"""Writes renderer output into Dynmap's TiDB tile table and rebuilds the zoom-out levels.

    python tools/tiledb.py upload --map-id 60001 --dir out [out2 ...] --zoom-max 10 [--host 127.0.0.1 --port 4000]
                                  [--rate 8000000] [--dry-run]

Rules (same as the Rust renderer Dynmap-GPU):
  * dynmap_Tiles has (MapID,x,y,zoom) as primary key and large image blobs: only point lookups, never scans.
  * a tile whose HashCode is unchanged is skipped; a blank tile deletes an existing row.
  * rows are written with Format=2 (lossless WebP in NewImage, Image NULL).
  * parents are rebuilt from the 4 children (changed ones from memory, others point-read) with a 2x2 mean,
    child order 0=top-right 1=bottom-right 2=top-left 3=bottom-left.
  * writes and blob reads share one byte budget (--rate) so the server link is not saturated.
"""
import argparse
import io
import json
import os
import sys
import time
import zlib

import numpy as np
import pymysql
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mapplan  # noqa: E402

T = 128


def crc_hash(rgba: np.ndarray) -> int:
    """Dynmap MapStorage.calculateImageHashCode: ARGB ints little-endian = bytes B,G,R,A."""
    return zlib.crc32(np.ascontiguousarray(rgba[..., [2, 1, 0, 3]]).tobytes()) & 0xFFFFFFFF


def is_blank(rgba: np.ndarray) -> bool:
    return not rgba[..., 3].any()


def encode_webp(rgba: np.ndarray, method: int = 4) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, "WEBP", lossless=True, quality=100, method=method, exact=False)
    return buf.getvalue()


def decode_any(blob: bytes) -> np.ndarray | None:
    try:
        im = Image.open(io.BytesIO(blob)).convert("RGBA")
    except Exception:
        return None
    if im.size != (T, T):
        return None
    return np.array(im, dtype=np.uint8)


def parent_of(x: int, y: int, zoom: int):
    s2 = 2 * (1 << zoom)
    return (x // s2) * s2, -((-y) // s2 * s2)


def children_of(px: int, py: int, zoom: int):
    s = 1 << zoom
    return [(px + s, py), (px + s, py - s), (px, py), (px, py - s)]


def zoom_combine(children):
    if all(c is None for c in children):
        return None
    out = np.zeros((T, T, 4), dtype=np.uint8)
    half = T // 2
    for i, src in enumerate(children):
        if src is None:
            continue
        ox = 0 if (i >> 1) != 0 else half
        oy = (i & 1) * half
        s = src.astype(np.uint32)
        mean = (s[0::2, 0::2] + s[0::2, 1::2] + s[1::2, 0::2] + s[1::2, 1::2]) >> 2
        out[oy:oy + half, ox:ox + half] = mean.astype(np.uint8)
    return out


class Db:
    def __init__(self, host, port, map_id, rate, dry_run=False):
        self.map_id = map_id
        self.rate = rate
        self.dry_run = dry_run
        self.sent = 0
        self.t0 = time.monotonic()
        self.conn = pymysql.connect(host=host, port=port, user="root", database="dynmap", autocommit=True)

    def throttle(self, nbytes):
        if self.rate <= 0:
            return
        self.sent += nbytes
        due = self.sent / self.rate
        el = time.monotonic() - self.t0
        if due > el:
            time.sleep(due - el)

    @staticmethod
    def _in_clause(map_id, zoom, coords):
        sql = ",".join(["(%s,%s,%s,%s)"] * len(coords))
        params = []
        for x, y in coords:
            params += [map_id, x, y, zoom]
        return sql, params

    def hashes(self, zoom, coords):
        out = {}
        with self.conn.cursor() as c:
            for i in range(0, len(coords), 400):
                part = coords[i:i + 400]
                sql, params = self._in_clause(self.map_id, zoom, part)
                c.execute(f"SELECT x,y,HashCode FROM dynmap_Tiles WHERE (MapID,x,y,zoom) IN ({sql})", params)
                for x, y, h in c.fetchall():
                    out[(x, y)] = int(h)
        return out

    def read_images(self, zoom, coords):
        out = {}
        with self.conn.cursor() as c:
            for i in range(0, len(coords), 100):
                part = coords[i:i + 100]
                sql, params = self._in_clause(self.map_id, zoom, part)
                c.execute(f"SELECT x,y,COALESCE(NewImage,Image) FROM dynmap_Tiles WHERE (MapID,x,y,zoom) IN ({sql})", params)
                nbytes = 0
                for x, y, blob in c.fetchall():
                    if blob:
                        nbytes += len(blob)
                        img = decode_any(blob)
                        if img is not None:
                            out[(x, y)] = img
                self.throttle(nbytes)
        return out

    def write(self, zoom, tiles, now_ms):
        """tiles: list of (x, y, hash, webp bytes)."""
        if self.dry_run or not tiles:
            return
        with self.conn.cursor() as c:
            for i in range(0, len(tiles), 24):
                part = tiles[i:i + 24]
                sql = ("INSERT INTO dynmap_Tiles (MapID,x,y,zoom,HashCode,LastUpdate,Format,NewImage,Image) VALUES "
                       + ",".join(["(%s,%s,%s,%s,%s,%s,2,%s,NULL)"] * len(part))
                       + " ON DUPLICATE KEY UPDATE HashCode=VALUES(HashCode), LastUpdate=VALUES(LastUpdate),"
                         " Format=VALUES(Format), NewImage=VALUES(NewImage), Image=NULL")
                params = []
                nbytes = 0
                for x, y, h, blob in part:
                    params += [self.map_id, x, y, zoom, h, now_ms, blob]
                    nbytes += len(blob)
                c.execute(sql, params)
                self.throttle(nbytes)

    def delete(self, zoom, coords):
        if self.dry_run or not coords:
            return
        with self.conn.cursor() as c:
            for x, y in coords:
                c.execute("DELETE FROM dynmap_Tiles WHERE MapID=%s AND zoom=%s AND x=%s AND y=%s", (self.map_id, zoom, x, y))

    def updated_since(self, zoom, coords, since_ms):
        """Subset of coords whose row was written at/after since_ms (point lookups only)."""
        out = []
        with self.conn.cursor() as c:
            for i in range(0, len(coords), 400):
                part = coords[i:i + 400]
                sql, params = self._in_clause(self.map_id, zoom, part)
                c.execute(f"SELECT x,y FROM dynmap_Tiles WHERE LastUpdate>=%s AND (MapID,x,y,zoom) IN ({sql})", [since_ms] + params)
                out += [(x, y) for x, y in c.fetchall()]
        return out

    def all_hashes(self, zoom):
        """Every (x, y) -> HashCode of one zoom level, read in y bands. Scans the whole level: use only on request."""
        out = {}
        with self.conn.cursor() as c:
            c.execute("SELECT MIN(x), MAX(x), MIN(y), MAX(y) FROM dynmap_Tiles WHERE MapID=%s AND zoom=%s", (self.map_id, zoom))
            x0, x1, y0, y1 = c.fetchone()
            if x0 is None:
                return out
            band = 64 << zoom
            y = y0
            while y <= y1:
                y_end = min(y + band - 1, y1)
                c.execute("SELECT x,y,HashCode FROM dynmap_Tiles WHERE MapID=%s AND zoom=%s AND x>=%s AND x<=%s AND y>=%s AND y<=%s",
                          (self.map_id, zoom, x0, x1, y, y_end))
                for x, yy, h in c.fetchall():
                    out[(x, yy)] = int(h)
                y = y_end + 1
        return out

    def existing_rect(self, x0, x1, y0, y1):
        """HashCodes of the zoom-0 tiles in [x0,x1] x [y0,y1] via one batched point lookup."""
        return self.hashes(0, [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)])


def load_dirs(dirs):
    """Tiles of one or more render output directories: (x, y) -> None (blank) or (rgba, hash, webp bytes)."""
    tiles = {}
    for d in dirs:
        manifest = json.load(open(os.path.join(d, "manifest.json")))
        for e in manifest:
            x, y = e["x"], e["y"]
            if e["blank"]:
                tiles[(x, y)] = None
                continue
            png = os.path.join(d, f"{x}_{y}.png")
            webp = os.path.join(d, f"{x}_{y}.webp")
            img = np.array(Image.open(png).convert("RGBA"), dtype=np.uint8)
            tiles[(x, y)] = (img, int(e["hash"]), open(webp, "rb").read())
    return tiles


def upload(args):
    """Zoom-0 upload of render output dirs. Tile selection (Dynmap-GPU driver.rs):
    default: candidate tiles and tiles that already exist; --only-missing: candidate tiles without a row.
    Candidates come from `plan` (--candidates tiles.npy); without it every rendered tile counts as a candidate."""
    db = Db(args.host, args.port, args.map_id, args.rate, args.dry_run)
    tiles = load_dirs(args.dir)
    now = int(time.time() * 1000)
    coords = list(tiles)
    existing = db.hashes(0, coords)
    cand = mapplan.Candidates.load(args.candidates) if args.candidates else None
    changed = {}  # (x, y) -> image or None (deleted)
    writes, deletes, same, blank = [], [], 0, 0
    for xy, t in tiles.items():
        is_cand = cand is None or cand.has(*xy)
        wanted = (is_cand and xy not in existing) if args.only_missing else (is_cand or xy in existing)
        if not wanted:
            continue
        if t is None:
            blank += 1
            if xy in existing:
                deletes.append(xy)
                changed[xy] = None
            continue
        img, h, blob = t
        if existing.get(xy) == h:
            same += 1
            continue
        writes.append((xy[0], xy[1], h, blob))
        changed[xy] = img
    db.write(0, writes, now)
    db.delete(0, deletes)
    print(f"zoom 0: wrote {len(writes)}, deleted {len(deletes)}, unchanged {same}, blank {blank}")
    if args.record:
        with open(args.record, "a") as f:
            for xy in changed:
                f.write(f"{xy[0]} {xy[1]}\n")
    if not args.no_zoom:
        rebuild_zoom(db, set(changed), changed, args.zoom_max, False, now)
    print("dry run, nothing written" if args.dry_run else "done")


def rebuild_zoom(db, keys, known, zoom_max, zoom_all, now, method=4):
    """Rebuilds zoom-out levels above zoom 0 for the parents of `keys` (tiles changed at the level below).

    known: (x, y) -> RGBA image (or None for deleted) for tiles already in memory; other children are point-read.
    zoom_all: also re-check every existing parent of each level (scans whole levels; fixes stale quadrants and orphans).
    """
    level_keys = set(keys)
    level_known = dict(known)
    if zoom_all:
        level_keys |= set(db.all_hashes(0))
        print(f"zoom-all: {len(level_keys)} zoom-0 tiles in the database")
    for zoom in range(0, zoom_max):
        parents = {parent_of(x, y, zoom) for x, y in level_keys}
        if zoom_all:
            old = db.all_hashes(zoom + 1)
            parents |= set(old)
        parents = sorted(parents)
        if not parents:
            break
        if not zoom_all:
            old = db.hashes(zoom + 1, parents)
        need = sorted({c for p in parents for c in children_of(p[0], p[1], zoom) if c not in level_known})
        fetched = db.read_images(zoom, need) if need else {}
        nxt_keys, nxt_known, pw, pd = set(), {}, [], []
        for p in parents:
            kids = [level_known[c] if c in level_known else fetched.get(c) for c in children_of(p[0], p[1], zoom)]
            img = zoom_combine(kids)
            if img is None or is_blank(img):
                if p in old:
                    pd.append(p)
                    nxt_keys.add(p)
                    nxt_known[p] = None
                continue
            h = crc_hash(img)
            if old.get(p) == h:
                continue
            pw.append((p[0], p[1], h, encode_webp(img, method)))
            nxt_keys.add(p)
            nxt_known[p] = img
        db.write(zoom + 1, pw, now)
        db.delete(zoom + 1, pd)
        print(f"zoom {zoom + 1}: wrote {len(pw)}, deleted {len(pd)} (of {len(parents)} parents)")
        level_keys, level_known = nxt_keys, nxt_known


def plan_cmd(args):
    """World scan -> candidate tiles and mega-tile list (driver.rs tile_set / megas / --only-missing / --count-missing)."""
    scan = mapplan.load_scan(args.scan)
    lo, hi = mapplan.y_range(scan)
    keys = mapplan.tile_keys(scan, args.persp)
    bbox = tuple(int(v) for v in args.bbox.split(",")) if args.bbox else None
    mk, keys = mapplan.megas_of(keys, args.mega, bbox)
    print(f"{len(keys)} candidate tiles, y range {lo}..{hi}, {len(mk)} mega-tiles of {args.mega}x{args.mega}")
    megas = mapplan.mega_list(mk)
    if args.only_missing or args.count_missing:
        db = Db(args.host, args.port, args.map_id, args.rate, True)
        tx, ty = mapplan.unkey(keys)
        per = mapplan.key_of(ty // args.mega, tx // args.mega)
        order = np.argsort(per, kind="stable")
        per_sorted = per[order]
        lo_i = np.searchsorted(per_sorted, mk, "left")
        hi_i = np.searchsorted(per_sorted, mk, "right")
        keep, miss_tiles = [], 0
        batch_m, batch_c = [], []

        def flush():
            nonlocal miss_tiles
            have = db.hashes(0, batch_c) if batch_c else {}
            for m, cs in batch_m:
                n = sum(1 for c in cs if c not in have)
                if n:
                    keep.append(m)
                    miss_tiles += n

        for i, m in enumerate(megas):
            sel = order[lo_i[i]:hi_i[i]]
            cs = list(zip(tx[sel].tolist(), ty[sel].tolist()))
            batch_m.append((m, cs))
            batch_c += cs
            if len(batch_c) >= 400:
                flush()
                batch_m, batch_c = [], []
            if (i + 1) % 2000 == 0:
                print(f"checked {i + 1}/{len(megas)}", flush=True)
        flush()
        print(f"missing: {miss_tiles} tiles in {len(keep)} of {len(megas)} mega-tiles")
        if args.count_missing:
            return
        megas = keep
    os.makedirs(args.out_dir, exist_ok=True)
    np.save(os.path.join(args.out_dir, "tiles.npy"), keys)
    json.dump({"megas": megas, "min_y": lo, "max_y": hi, "tiles": int(len(keys))},
              open(os.path.join(args.out_dir, "plan.json"), "w"))


def zoom_cmd(args):
    db = Db(args.host, args.port, args.map_id, args.rate, args.dry_run)
    keys = set()
    for p in args.seed or []:
        for line in open(p):
            if line.strip():
                x, y = line.split()
                keys.add((int(x), int(y)))
    if args.since:
        # tiles written by earlier, interrupted runs whose changed set was lost: candidates from --candidates
        ck = np.load(args.candidates)
        cx, cy = mapplan.unkey(ck)
        cand = list(zip(cx.tolist(), cy.tolist()))
        keys |= set(db.updated_since(0, cand, args.since))
        print(f"zoom-since: {len(keys)} tiles written since the cutoff")
    rebuild_zoom(db, keys, {}, args.zoom_max, args.all, int(time.time() * 1000))
    print("dry run, nothing written" if args.dry_run else "done")


def common(p):
    p.add_argument("--map-id", type=int, required=True)
    p.add_argument("--zoom-max", type=int, default=10)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=4000)
    p.add_argument("--rate", type=float, default=8_000_000, help="bytes/s shared by reads and writes, 0 = unlimited")
    p.add_argument("--dry-run", action="store_true")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("upload")
    common(u)
    u.add_argument("--dir", required=True, nargs="+", help="one or more render output directories")
    u.add_argument("--only-missing", action="store_true", help="write only candidate tiles that have no row yet")
    u.add_argument("--candidates", help="tiles.npy from the plan subcommand (default: every rendered tile is a candidate)")
    u.add_argument("--no-zoom", action="store_true", help="skip the zoom-out rebuild (use the zoom subcommand later)")
    u.add_argument("--record", help="append the changed zoom-0 tiles to this file (seed for the zoom subcommand)")
    z = sub.add_parser("zoom", help="rebuild zoom-out levels from recorded or recently written tiles")
    common(z)
    z.add_argument("--seed", nargs="*", help="files written by upload --record")
    z.add_argument("--since", type=int, help="seed with candidate tiles written at/after this time (ms since epoch)")
    z.add_argument("--candidates", help="tiles.npy for --since")
    z.add_argument("--all", action="store_true", help="re-check every parent of every level (scans whole levels)")
    pl = sub.add_parser("plan", help="scan cache -> candidate tiles + mega-tile list (+ missing-tile check)")
    common(pl)
    pl.add_argument("--scan", required=True, help="scan cache made by scripts/scan_world.gd")
    pl.add_argument("--persp", required=True, choices=sorted(mapplan.PERSPECTIVES))
    pl.add_argument("--mega", type=int, default=8)
    pl.add_argument("--bbox", help="tx0,ty0,tx1,ty1 inclusive")
    pl.add_argument("--out-dir", help="writes tiles.npy and plan.json here")
    pl.add_argument("--only-missing", action="store_true", help="keep only mega-tiles with candidate tiles that have no row")
    pl.add_argument("--count-missing", action="store_true", help="dry run: count missing tiles and exit")
    a = ap.parse_args()
    if a.cmd == "upload":
        upload(a)
    elif a.cmd == "plan":
        plan_cmd(a)
    else:
        zoom_cmd(a)


if __name__ == "__main__":
    sys.exit(main())
