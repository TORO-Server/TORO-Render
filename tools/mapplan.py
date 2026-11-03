"""World scan cache, perspective maths and tile/mega-tile planning (port of Dynmap-GPU driver.rs scan_world/tile_set).

The scan cache is the same binary format Dynmap-GPU writes: little-endian int32 quadruples (cx, cz, min_y, max_y) for every
full chunk that holds non-air blocks, so caches made by either renderer can be shared. scripts/scan_world.gd creates it.
"""
import math
import os

import numpy as np

TILE = 128


def _rxy(a, deg):
    r = math.radians(deg)
    s, c = math.sin(r), math.cos(r)
    return np.array([[c, s, 0], [-s, c, 0], [0, 0, 1]]) @ a


def _ryz(a, deg):
    r = math.radians(deg)
    s, c = math.sin(r), math.cos(r)
    return np.array([[1, 0, 0], [0, c, s], [0, -s, c]]) @ a


PERSPECTIVES = {
    "iso_S_90_lowres": (180.0, 90.0, 4),
    "iso_S_90_hires": (180.0, 90.0, 16),
    "iso_SE_30_hires": (135.0, 30.0, 16),
    "iso_SE_30_lowres": (135.0, 30.0, 4),
}


def persp_matrix(name):
    """(world->map 3x3 matrix, scale, inclination) exactly as Persp.make in scripts/persp.gd."""
    az_cfg, incl, scale = PERSPECTIVES[name]
    az = 90.0 + az_cfg
    if az >= 360.0:
        az -= 360.0
    t = np.array([[0, 0, -1], [-1, 0, 0], [0, 1, 0]], dtype=float)
    t = _rxy(t, 180.0 - az)
    t = _ryz(t, 90.0 - incl)
    t = np.array([[1, 0, 0], [0, 1, 0], [0, math.tan(math.radians(90.0 - incl)), 1]]) @ t
    t = np.diag([scale, scale, math.sin(math.radians(incl))]) @ t
    return t, scale, incl


def load_scan(path):
    b = np.fromfile(path, dtype="<i4")
    if b.size == 0 or b.size % 4:
        raise SystemExit(f"bad scan cache {path}")
    return b.reshape(-1, 4)


def y_range(scan):
    return int(scan[:, 2].min()), int(scan[:, 3].max())


def key_of(tx, ty):
    """int64 key of tile coordinates (arrays or scalars), ordered by (tx, ty): tx in the high 32 bits, ty biased by 2^31."""
    return (np.asarray(tx, dtype=np.int64) << 32) | ((np.asarray(ty, dtype=np.int64) + 0x80000000) & 0xFFFFFFFF)


def unkey(k):
    k = np.asarray(k, dtype=np.int64)
    return (k >> 32), (k & 0xFFFFFFFF) - 0x80000000


def tile_keys(scan, name, batch=250_000):
    """Sorted unique int64 keys of the zoom-0 tiles that any scanned chunk can project into (Dynmap-GPU tile_set)."""
    m, s, _ = persp_matrix(name)
    acc = np.empty(0, dtype=np.int64)
    for b0 in range(0, len(scan), batch):
        part = scan[b0:b0 + batch]
        cx = part[:, 0].astype(np.int64) * 16
        cz = part[:, 1].astype(np.int64) * 16
        lo, hi = part[:, 2].astype(np.float64), part[:, 3].astype(np.float64)
        x0 = np.full(len(part), np.inf)
        x1 = np.full(len(part), -np.inf)
        y0 = np.full(len(part), np.inf)
        y1 = np.full(len(part), -np.inf)
        for dx in (0, 16):
            for dz in (0, 16):
                for wy in (lo, hi):
                    wx = (cx + dx).astype(np.float64)
                    wz = (cz + dz).astype(np.float64)
                    mx = m[0, 0] * wx + m[0, 1] * wy + m[0, 2] * wz
                    my = m[1, 0] * wx + m[1, 1] * wy + m[1, 2] * wz
                    x0, x1 = np.minimum(x0, mx), np.maximum(x1, mx)
                    y0, y1 = np.minimum(y0, my), np.maximum(y1, my)
        tx0 = np.floor((x0 - s) / TILE).astype(np.int64)
        tx1 = np.floor((x1 + s) / TILE).astype(np.int64)
        ty0 = np.floor((y0 - s) / TILE).astype(np.int64)
        ty1 = np.floor((y1 + s) / TILE).astype(np.int64)
        keys = [acc]
        for ox in range(int((tx1 - tx0).max()) + 1):
            for oy in range(int((ty1 - ty0).max()) + 1):
                ok = (tx0 + ox <= tx1) & (ty0 + oy <= ty1)
                keys.append(key_of(tx0[ok] + ox, ty0[ok] + oy))
        acc = np.unique(np.concatenate(keys))
    return acc


def megas_of(keys, mega, bbox=None):
    """(sorted unique mega keys filtered by bbox, keys kept). Mega order: row-major by my, then mx (Dynmap-GPU)."""
    tx, ty = unkey(keys)
    if bbox:
        a, b, c, d = bbox
        ok = (tx >= a) & (tx <= c) & (ty >= b) & (ty <= d)
        keys, tx, ty = keys[ok], tx[ok], ty[ok]
    mx, my = tx // mega, ty // mega
    mk = np.unique(key_of(my, mx))  # my in the high bits: sorted order is (my, mx)
    return mk, keys


def mega_list(mk):
    my, mx = unkey(mk)
    return [(int(a), int(b)) for a, b in zip(mx, my)]


class Candidates:
    """Membership test over sorted int64 tile keys."""

    def __init__(self, keys):
        self.keys = np.asarray(keys, dtype=np.int64)

    @classmethod
    def load(cls, path):
        return cls(np.load(path))

    def has(self, x, y):
        k = int(key_of(x, y))
        i = int(np.searchsorted(self.keys, k))
        return i < len(self.keys) and int(self.keys[i]) == k

    def in_rect(self, x0, y0, w, h):
        """Candidate tiles inside [x0, x0+w) x [y0, y0+h) as a list of (x, y)."""
        out = []
        for x in range(x0, x0 + w):
            lo = int(np.searchsorted(self.keys, int(key_of(x, y0))))
            hi = int(np.searchsorted(self.keys, int(key_of(x, y0 + h - 1)), side="right"))
            tx, ty = unkey(self.keys[lo:hi])
            out += [(int(a), int(b)) for a, b in zip(tx, ty)]
        return out
