# TORO-GPU-Renderer

Dynmap-compatible map tile renderer that runs on the TORO server's integrated GPU (Intel UHD 730, Mesa ANV Vulkan),
written as a Godot 4.7 project (GDScript + GLSL compute shader).

Status: **prototype**. Renders flat (`iso_S_90_lowres`, 4 px per block) 128 px tiles. Details of the hardware
survey and the decisions are in [docs/igpu-report.md](docs/igpu-report.md).

## What it does

```
.mca region -> scripts/nbt.gd, chunk_data.gd, world_reader.gd   (CPU: columns of up to 5 layers + Dynmap light words)
            -> shaders/flat_tile.glsl                              (GPU: texture, tint, smooth light, translucency)
            -> scripts/tile_codec.gd                               (PNG / lossless WebP, Dynmap CRC32 HashCode)
```

Output per tile: `{x}_{y}.png`, `{x}_{y}.webp` (lossless, the `NewImage` payload for `Format=2`) and `manifest.json`
with the HashCode (CRC32 over ARGB ints little-endian). Tile coordinates are Dynmap's: tile `(tx,ty)` covers world
x in `[32*tx, 32*tx+32)` and z in `(-32*ty-32, -32*ty]`, image row 0 = north.

Writing into TiDB `dynmap_Tiles` is not implemented here yet (see "Next steps" in the report).

## Setup

1. Generate the lookup data from a Minecraft client jar (not committed):
   `python tools/build_data.py --jar client-26.3.jar --out data` (needs Pillow)
2. Local dev run on Windows (visible 64x64 window, any Vulkan GPU):
   `tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out [-Ref ref_pngs]`
3. Server run (Docker, iGPU):
   ```
   docker build -t toro-gpu-renderer:dev -f docker/Dockerfile .
   WORLD_DIR=/path/to/region EXTRA_GROUPS=1001 DATA_DIR=$PWD/data OUT_DIR=$PWD/out \
     docker/run.sh --region-dir /world --tiles "-8,4,2,2" --out /out
   ```
   The container is limited to 1 CPU with the lowest share, `nice 19`, `ionice idle`, read-only world mount,
   no capabilities. `EXTRA_GROUPS` must contain the gid that can read the world files.

## Why a Wayland compositor in the container

Godot's `--headless` has no RenderingDevice, and Xvfb has no DRI3 so Mesa falls back to llvmpipe (CPU).
`cage` with the wlroots headless backend gives Godot a Vulkan-presentable surface on the iGPU render node
(`docker/entrypoint.sh`).

## Known differences from Dynmap

Only cube-like top faces are drawn (stairs/slabs use their top texture; fences, plants, entity blocks, glass are skipped
or approximated), one water layer per column, no `uvlock`, no zoom-out tiles yet.
