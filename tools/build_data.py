"""Builds the renderer's lookup data from a Minecraft client jar.

Outputs (into --out, default ./data):
  blocks.json   block name -> [tex index, kind, tint]
                kind: 0 = not drawn from above (air, plants, entity blocks), 1 = solid top face, 2 = fluid (water/lava)
                tint: 0 none, 1 grass, 2 foliage, 3 water, 0x1000000|rgb fixed colour
  atlas.bin     tex count * 16 texels * RGBA8: every texture box-resampled to 4x4 (alpha weighted, like Dynmap's lowres)
  atlas.json    tex index -> texture name (debugging)
  biomes.json   biome name -> [grass, foliage, water] RGB ints

Usage: python tools/build_data.py --jar client-26.3.jar [--out data]
"""
import argparse
import io
import json
import zipfile

from PIL import Image

TEX = 16
S = 4

FIXED_FOLIAGE = {"spruce_leaves": 0x619961, "birch_leaves": 0x80A755, "lily_pad": 0x208030}
WATER_BLOCKS = {"water", "bubble_column", "kelp", "kelp_plant", "seagrass", "tall_seagrass"}
LAVA_BLOCKS = {"lava"}
NEVER_DRAWN = {"air", "cave_air", "void_air", "barrier", "light", "structure_void", "moving_piston", "piston_head"}


class Jar:
    def __init__(self, path):
        self.z = zipfile.ZipFile(path)
        self.names = set(self.z.namelist())

    def get(self, name):
        return self.z.read(name) if name in self.names else None

    def json(self, name):
        b = self.get(name)
        return json.loads(b) if b is not None else None


def strip_ns(s):
    return s.split(":", 1)[1] if ":" in s else s


def load_model(jar, ref, cache):
    ref = strip_ns(ref)
    if ref in cache:
        return cache[ref]
    m = jar.json(f"assets/minecraft/models/{ref}.json")
    cache[ref] = None
    if m is None:
        return None
    textures = {}
    elements = m.get("elements")
    parent = m.get("parent")
    builtin = False
    if parent:
        if strip_ns(parent).startswith("builtin/"):
            builtin = True
        else:
            p = load_model(jar, parent, cache)
            if p:
                textures = dict(p["textures"])
                builtin = p["builtin"]
                if elements is None:
                    elements = p["elements"]
    textures.update(m.get("textures", {}))
    out = {"textures": textures, "elements": elements or [], "builtin": builtin}
    cache[ref] = out
    return out


def resolve_tex(textures, ref):
    # 26.x texture entries may be objects: {"sprite": "minecraft:block/glass", "force_translucent": true}
    seen = 0
    while seen < 16:
        if isinstance(ref, dict):
            ref = ref.get("sprite")
        if isinstance(ref, str) and ref.startswith("#"):
            ref = textures.get(ref[1:])
            seen += 1
            continue
        break
    return ref if isinstance(ref, str) and not ref.startswith("#") else None


def first_model(state):
    if "variants" in state:
        v = next(iter(state["variants"].values()))
        if isinstance(v, list):
            v = v[0]
        return v.get("model")
    if "multipart" in state:
        for part in state["multipart"]:
            a = part.get("apply")
            if isinstance(a, list):
                a = a[0]
            if a and "model" in a:
                return a["model"]
    return None


def top_face(model):
    """(texture ref, tintindex or None) of the highest element with a large upward face, else None."""
    best = None
    for e in model["elements"]:
        up = e.get("faces", {}).get("up")
        if not up:
            continue
        f, t = e["from"], e["to"]
        area = abs(t[0] - f[0]) * abs(t[2] - f[2])
        if area < 64 or e.get("rotation", {}).get("angle", 0) not in (0, 90, 180, 270):
            continue
        key = (t[1], area)
        if best is None or key > best[0]:
            best = (key, up)
    if best is None:
        return None
    up = best[1]
    return resolve_tex(model["textures"], up["texture"]), up.get("tintindex")


def resample(img):
    img = img.convert("RGBA")
    if img.height > img.width:
        img = img.crop((0, 0, img.width, img.width))
    img = img.resize((TEX, TEX), Image.NEAREST) if img.width != TEX else img
    px = img.load()
    r = TEX // S
    out = bytearray()
    for y in range(S):
        for x in range(S):
            sr = sg = sb = sa = 0
            for yy in range(r):
                for xx in range(r):
                    p = px[x * r + xx, y * r + yy]
                    a = p[3]
                    sr += p[0] * a
                    sg += p[1] * a
                    sb += p[2] * a
                    sa += a
            d = max(sa, 1)
            out += bytes((sr // d, sg // d, sb // d, sa // (r * r)))
    return bytes(out)


class Atlas:
    def __init__(self, jar):
        self.jar = jar
        self.index = {}
        self.names = []
        self.data = bytearray()

    def add(self, ref):
        ref = strip_ns(ref)
        if ref in self.index:
            return self.index[ref]
        b = self.jar.get(f"assets/minecraft/textures/{ref}.png")
        if b is None:
            return None
        self.index[ref] = len(self.names)
        self.names.append(ref)
        self.data += resample(Image.open(io.BytesIO(b)))
        return self.index[ref]


def colormap_at(img, temp, down):
    t = min(max(temp, 0.0), 1.0)
    d = min(max(down, 0.0), 1.0) * t
    w = img.width
    x = min(int((1.0 - t) * 255.0), w - 1)
    y = min(int((1.0 - d) * 255.0), w - 1)
    p = img.getpixel((x, y))
    return p[0] << 16 | p[1] << 8 | p[2]


def find_key(v, key):
    if isinstance(v, dict):
        if key in v:
            return v[key]
        for c in v.values():
            r = find_key(c, key)
            if r is not None:
                return r
    elif isinstance(v, list):
        for c in v:
            r = find_key(c, key)
            if r is not None:
                return r
    return None


def parse_color(v):
    if isinstance(v, int):
        return v & 0xFFFFFF
    if isinstance(v, str):
        return int(v.lstrip("#"), 16)
    return None


def build_biomes(jar):
    grass_map = Image.open(io.BytesIO(jar.get("assets/minecraft/textures/colormap/grass.png"))).convert("RGB")
    fol_map = Image.open(io.BytesIO(jar.get("assets/minecraft/textures/colormap/foliage.png"))).convert("RGB")
    out = {}
    prefix = "data/minecraft/worldgen/biome/"
    for n in sorted(jar.names):
        if not (n.startswith(prefix) and n.endswith(".json")):
            continue
        short = n[len(prefix):-5]
        j = jar.json(n)
        temp = find_key(j, "temperature")
        down = find_key(j, "downfall")
        temp = 0.8 if temp is None else float(temp)
        down = 0.4 if down is None else float(down)
        g = parse_color(find_key(j, "grass_color"))
        f = parse_color(find_key(j, "foliage_color"))
        w = parse_color(find_key(j, "water_color"))
        w = 0x3F76E4 if w is None else w
        modifier = find_key(j, "grass_color_modifier") or ""
        grass = g if g is not None else colormap_at(grass_map, temp, down)
        if g is None or modifier == "dark_forest":
            if modifier == "dark_forest":
                grass = ((grass & 0xFEFEFE) + 0x28340A) >> 1
            elif modifier == "swamp":
                grass = 0x6A7039
        fol = f if f is not None else colormap_at(fol_map, temp, down)
        out["minecraft:" + short] = [grass, fol, w]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jar", required=True)
    ap.add_argument("--out", default="data")
    a = ap.parse_args()
    import os

    os.makedirs(a.out, exist_ok=True)
    jar = Jar(a.jar)
    atlas = Atlas(jar)
    cache = {}
    blocks = {}
    prefix = "assets/minecraft/blockstates/"
    for n in sorted(jar.names):
        if not (n.startswith(prefix) and n.endswith(".json")):
            continue
        short = n[len(prefix):-5]
        full = "minecraft:" + short
        if short in NEVER_DRAWN:
            blocks[full] = [0, 0, 0]
            continue
        if short in WATER_BLOCKS:
            blocks[full] = [atlas.add("block/water_still"), 2, 3]
            continue
        if short in LAVA_BLOCKS:
            blocks[full] = [atlas.add("block/lava_still"), 2, 0]
            continue
        state = jar.json(n)
        mref = first_model(state) if state else None
        model = load_model(jar, mref, cache) if mref else None
        if not model or model["builtin"]:
            blocks[full] = [0, 0, 0]
            continue
        tf = top_face(model)
        if not tf or not tf[0]:
            blocks[full] = [0, 0, 0]
            continue
        tex = atlas.add(tf[0])
        if tex is None:
            blocks[full] = [0, 0, 0]
            continue
        tint = 0
        if tf[1] is not None:
            if short in FIXED_FOLIAGE:
                tint = 0x1000000 | FIXED_FOLIAGE[short]
            elif "leaves" in short:
                tint = 2
            else:
                tint = 1
        blocks[full] = [tex, 1, tint]
    # water/lava registered before other textures may have been added; indices are final here
    json.dump(blocks, open(os.path.join(a.out, "blocks.json"), "w"), separators=(",", ":"))
    open(os.path.join(a.out, "atlas.bin"), "wb").write(bytes(atlas.data))
    json.dump(atlas.names, open(os.path.join(a.out, "atlas.json"), "w"))
    json.dump(build_biomes(jar), open(os.path.join(a.out, "biomes.json"), "w"), separators=(",", ":"))
    solid = sum(1 for v in blocks.values() if v[1] == 1)
    print(f"blocks {len(blocks)} (solid {solid}), textures {len(atlas.names)}, biomes written")


if __name__ == "__main__":
    main()
