"""Writes renderer output into Dynmap's TiDB tile table and rebuilds the zoom-out levels.

    python tools/tiledb.py upload --map-id 60001 --dir out --zoom-max 10 [--host 127.0.0.1 --port 4000]
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


def load_dir(d):
    manifest = json.load(open(os.path.join(d, "manifest.json")))
    tiles = {}
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
    db = Db(args.host, args.port, args.map_id, args.rate, args.dry_run)
    tiles = load_dir(args.dir)
    now = int(time.time() * 1000)
    coords = list(tiles)
    existing = db.hashes(0, coords)
    changed = {}  # (x, y) -> image or None (deleted)
    writes, deletes, same = [], [], 0
    for xy, t in tiles.items():
        if t is None:
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
    print(f"zoom 0: wrote {len(writes)}, deleted {len(deletes)}, unchanged {same}, blank {sum(1 for t in tiles.values() if t is None)}")

    level = changed
    for zoom in range(0, args.zoom_max):
        parents = sorted({parent_of(x, y, zoom) for x, y in level})
        if not parents:
            break
        need = sorted({c for p in parents for c in children_of(p[0], p[1], zoom) if c not in level})
        fetched = db.read_images(zoom, need) if need else {}
        old = db.hashes(zoom + 1, parents)
        nxt, pw, pd = {}, [], []
        for p in parents:
            kids = [level[c] if c in level else fetched.get(c) for c in children_of(p[0], p[1], zoom)]
            img = zoom_combine(kids)
            if img is None or is_blank(img):
                if p in old:
                    pd.append(p)
                    nxt[p] = None
                continue
            h = crc_hash(img)
            if old.get(p) == h:
                continue
            pw.append((p[0], p[1], h, encode_webp(img)))
            nxt[p] = img
        db.write(zoom + 1, pw, now)
        db.delete(zoom + 1, pd)
        print(f"zoom {zoom + 1}: wrote {len(pw)}, deleted {len(pd)} (of {len(parents)} parents)")
        level = nxt
    print("dry run, nothing written" if args.dry_run else "done")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("upload")
    u.add_argument("--map-id", type=int, required=True)
    u.add_argument("--dir", required=True)
    u.add_argument("--zoom-max", type=int, default=10)
    u.add_argument("--host", default="127.0.0.1")
    u.add_argument("--port", type=int, default=4000)
    u.add_argument("--rate", type=float, default=8_000_000, help="bytes/s shared by reads and writes, 0 = unlimited")
    u.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.cmd == "upload":
        upload(a)


if __name__ == "__main__":
    sys.exit(main())
