"""Extracts everything the mesh renderer needs from a Minecraft client jar (and the data generator's blocks report).

Outputs (into --out, default ./data):
  assets/blockstates/*.json      raw blockstate definitions
  assets/models/block/**.json    raw block models (parents are resolved at run time)
  textures.bin                   count * 16*16*4 RGBA8, first animation frame, box-resampled to 16x16 like Dynmap-GPU
  textures.json                  texture index -> name ("block/stone"); index 0 is the missing-texture checker
  block_defaults.json            block name -> default property values (palette entries omit defaulted properties)

Usage: python tools/build_assets.py --jar client-26.3.jar [--reports blocks.json] [--out data]
"""
import argparse
import io
import json
import os
import zipfile

from PIL import Image

TEX = 16


def decode16(png):
    """16x16 RGBA of the first frame, or None. Mirrors Dynmap-GPU assets.rs decode_png_16."""
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    w, h = img.size
    if w == 0 or h < w:
        return None
    px = img.load()
    out = bytearray(TEX * TEX * 4)
    if w == TEX:
        for y in range(TEX):
            for x in range(TEX):
                o = (y * TEX + x) * 4
                out[o:o + 4] = bytes(px[x, y])
    elif w % TEX == 0:
        r = w // TEX
        for y in range(TEX):
            for x in range(TEX):
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
                o = (y * TEX + x) * 4
                out[o:o + 4] = bytes((sr // d, sg // d, sb // d, sa // (r * r)))
    else:
        for y in range(TEX):
            for x in range(TEX):
                o = (y * TEX + x) * 4
                out[o:o + 4] = bytes(px[x * w // TEX, y * w // TEX])
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jar", required=True)
    ap.add_argument("--reports", default=r"C:\dynmap-gpu\assets\gen\reports\blocks.json")
    ap.add_argument("--out", default="data")
    a = ap.parse_args()
    z = zipfile.ZipFile(a.jar)
    names = sorted(z.namelist())
    counts = {"blockstates": 0, "models": 0}
    for n in names:
        for prefix, key in (("assets/minecraft/blockstates/", "blockstates"), ("assets/minecraft/models/block/", "models")):
            if n.startswith(prefix) and n.endswith(".json"):
                rel = n[len("assets/minecraft/"):]
                dst = os.path.join(a.out, "assets", rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "wb") as f:
                    f.write(z.read(n))
                counts[key] += 1
    tex_names = ["missingno"]
    data = bytearray()
    checker = bytearray()
    for y in range(TEX):
        for x in range(TEX):
            checker += bytes((248, 0, 248, 255) if (x // 8 + y // 8) % 2 == 0 else (0, 0, 0, 255))
    data += checker
    prefix = "assets/minecraft/textures/"
    skipped = 0
    for n in names:
        if n.startswith(prefix + "block/") and n.endswith(".png"):
            t = decode16(z.read(n))
            if t is None:
                skipped += 1
                continue
            tex_names.append(n[len(prefix):-4])
            data += t
    with open(os.path.join(a.out, "textures.bin"), "wb") as f:
        f.write(bytes(data))
    with open(os.path.join(a.out, "textures.json"), "w") as f:
        json.dump(tex_names, f, separators=(",", ":"))
    defaults = {}
    if os.path.exists(a.reports):
        with open(a.reports, "rb") as f:
            rep = json.load(f)
        for name, b in rep.items():
            for s in b.get("states", []):
                if s.get("default"):
                    defaults[name] = {k: str(v) for k, v in s.get("properties", {}).items()}
    else:
        print("warning: blocks report missing, default block properties unavailable")
    with open(os.path.join(a.out, "block_defaults.json"), "w") as f:
        json.dump(defaults, f, separators=(",", ":"))
    print(f"blockstates {counts['blockstates']}, models {counts['models']}, textures {len(tex_names)} (skipped {skipped}), defaults {len(defaults)}")


if __name__ == "__main__":
    main()
