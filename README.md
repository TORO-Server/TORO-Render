# TORO-GPU-Renderer

Dynmap-compatible map tile renderer that runs on the TORO server's integrated GPU (Intel UHD 730, Mesa ANV Vulkan),
written as a Godot 4.7 project (GDScript + GLSL compute shaders) with a Python uploader for TiDB.

Status: **working prototype** for flat (`iso_S_90_lowres`, 4 px per block) maps. Hardware survey and decisions:
[docs/igpu-report.md](docs/igpu-report.md).

## Pipeline

```
.mca region -> scripts/nbt.gd, chunk_data.gd, gpu_world.gd   (CPU: NBT parse, pack palette/long arrays/light as buffers)
            -> shaders/resolve_columns.glsl                    (GPU: per block column layers + Dynmap light words)
            -> shaders/flat_tile.glsl                          (GPU: texture, tint, smooth light, translucency -> pixels)
            -> scripts/tile_codec.gd                           (PNG / lossless WebP, Dynmap CRC32 HashCode)
            -> tools/tiledb.py                                 (hash skip, TiDB write, zoom-out rebuild)
tools/queue_runner.py  = player-aware batch loop around the two stages (runs on the server)
```

`--columns cpu` uses the GDScript column builder instead (`scripts/world_reader.gd`); `--verify 1` renders with the
GPU builder and reports how many columns differ from the CPU one (0 on both RTX 3060 and UHD 730).

Output per tile: `{x}_{y}.png`, `{x}_{y}.webp` (lossless, the `NewImage` payload for `Format=2`) and `manifest.json`
with the HashCode (CRC32 over ARGB ints little-endian). Tile `(tx,ty)` covers block x in `[32*tx, 32*tx+32)` and block z
in `[-32*ty-32, -32*ty-1]`; image row 0 is the north edge.

## Setup

1. Lookup data from a Minecraft client jar (not committed): `python tools/build_data.py --jar client-26.3.jar --out data`
   (needs Pillow).
2. Local dev run on Windows (visible 64x64 window, any Vulkan GPU):
   `tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out [-Ref ref_pngs] [-Extra "--verify 1"]`
3. Server (Docker, iGPU). `tools/deploy.ps1` copies the tree to `~/gpu-renderer-lab` and builds the images
   `toro-gpu-renderer:dev` (Godot + Mesa + cage) and `toro-gpu-tools:dev` (Python uploader).
   Single render:
   ```
   WORLD_DIR=/path/to/region EXTRA_GROUPS=1001 DATA_DIR=$PWD/data OUT_DIR=/dev/shm/out \
     docker/run.sh --region-dir /world --tiles "-8,4,2,2" --out /out
   ```
   Several rectangles in one container start: `--tiles "0,0,8,8;8,0,8,8"` (outputs in `out/r{tx}_{ty}/`).
4. Whole-map job (needs the SSH-less direct TiDB port 4000 on the host):
   ```
   python3 tools/queue_runner.py --map-id 60001 --world-dir <region dir> --extra-groups 1001 --zoom-max 10
   ```
   Add `--dry-run` to render and read hashes without writing, `--bbox tx0,ty0,tx1,ty1` to limit the area, `--limit N`
   to stop early. Progress is kept in `~/.toro-gpu-render-<map-id>.json`, so the job can be stopped and resumed.

## Production safety

* Containers: 1 CPU at the lowest share, `nice 19`, `ionice idle`, 512 MB-1 GB memory, read-only root and world mount,
  no capabilities, temporary files in `/dev/shm` (no SSD writes).
* The runner only works while `online.txt` (written by the proxy plugin, same convention as `dynmap-throttle.sh`)
  says 0 players and is fresh, and the 1-minute load is below 4; otherwise it waits. Only the batch in flight is finished.
* TiDB: point lookups `(MapID,x,y,zoom) IN (...)` only, writes rate-limited (`--rate`, default 8 MB/s), unchanged hashes
  are skipped, blank tiles delete the row.

## Why a Wayland compositor in the container

Godot's `--headless` has no RenderingDevice, and Xvfb has no DRI3 so Mesa falls back to llvmpipe (CPU).
`cage` with the wlroots headless backend gives Godot a Vulkan-presentable surface on the iGPU render node
(`docker/entrypoint.sh`). The Mobile renderer is used (Forward+ needs ~8 s more start-up).

## Known differences from Dynmap

Only top faces: stairs/slabs/carpets use their top texture; fences, plants and entity blocks are not drawn
(Dynmap-GPU skips entity blocks too); one water layer per column; no `uvlock`. Measured against the Rust renderer
(which is ~99.7% exact against Dynmap on flat maps): 99.9% on plain tiles, 95% on a mixed 16-tile area.

## Isometric (30°) feasibility

`scripts/iso_probe.gd` renders a block mesh with Godot's own rasteriser (orthographic camera, offscreen SubViewport,
readback) and works on the iGPU under cage (1024x1024 in ~230 ms including pipeline set-up). A Dynmap-exact iso renderer
still needs: Dynmap's world-to-map transform, per-face shading classes and smooth light, non-cube block models
(blockstate/model JSON), translucent ordering and entity blocks - see the Rust `Dynmap-GPU` sources for the reference.
