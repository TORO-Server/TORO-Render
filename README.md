# TORO-GPU-Renderer

Dynmap-compatible map tile renderer that runs on the TORO server's integrated GPU (Intel UHD 730, Mesa ANV Vulkan),
written as a Godot 4.7 project (GDScript + GLSL shaders) with a Python planner/uploader for TiDB.

It renders **every Dynmap perspective the Rust renderer Dynmap-GPU supports** (`iso_S_90_lowres/hires`,
`iso_SE_30_lowres/hires`) from real block models. Against Dynmap-GPU on the same snapshots: 100.00% of the pixels on
the flat perspectives and ≥ 99.99% on the oblique ones (8x8 mega tiles of the main and flat worlds; the few remaining
pixels are blend rounding of a different GPU).
Hardware survey and decisions: [docs/igpu-report.md](docs/igpu-report.md).

## Pipeline

```
.mca region -> scripts/nbt.gd, chunk_data.gd, gpu_world.gd     CPU: NBT parse, pack palette / long arrays / light as buffers
            -> shaders/mesh_chunks.glsl  (compute)              GPU: block states -> quads (culling, smooth light, tint, fluids)
            -> shaders/raster.glsl       (vertex + fragment)    GPU: orthographic raster, depth, Dynmap shading, translucent pass
            -> shaders/finish.glsl       (compute)              GPU: un-premultiply into tile images
            -> scripts/tile_codec.gd                            PNG / lossless WebP, Dynmap CRC32 HashCode
            -> tools/tiledb.py                                  plan, hash skip, TiDB write, zoom-out rebuild
tools/queue_runner.py = player-aware batch driver around all of it (runs on the server)
```

* `scripts/state_registry.gd` bakes blockstates + models (multipart, variants, element rotation, rescale, face rotation,
  x/y state rotation) into quads with the same float32 arithmetic as Dynmap-GPU, so tie-breaks on 45° plants match.
* `scripts/persp.gd` is Dynmap's `IsoHDPerspective` world-to-map transform (double precision).
* Translucent quads are sorted back to front on the CPU in float32-of-double like Dynmap-GPU, ties in chunk / block / quad
  order, so water and glass blend identically.
* `scripts/mesher.gd` is the CPU reference mesher (`--mesher cpu`); `--cmp-chunk cx,cz` diffs it against the GPU one.
* `--mode fast` keeps the older column shader (`resolve_columns.glsl` + `flat_tile.glsl`): flat `iso_S_90_lowres` only,
  top faces only, approximate. The default (`--mode mesh`) is the exact one.

Output per tile: `{x}_{y}.png`, `{x}_{y}.webp` (lossless, the `NewImage` payload for `Format=2`) and `manifest.json`
with the HashCode (CRC32 over ARGB ints little-endian). Tile `(tx,ty)` of `iso_S_90_lowres` covers block x in
`[32*tx, 32*tx+32)` and z in `[-32*ty-32, -32*ty-1]`; image row 0 is the north edge.

## Setup

1. Data from a Minecraft client jar (not committed; needs Pillow):
   ```
   python tools/build_data.py   --jar client-26.3.jar --out data     # biomes, fast-mode tables
   python tools/build_assets.py --jar client-26.3.jar --out data     # blockstates, models, textures, block defaults
   ```
   `build_assets.py` also wants the data generator's `reports/blocks.json` (`--reports`).
2. Local run on Windows (visible 64x64 window, any Vulkan GPU, `--gpu-index N` picks the device):
   `tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out -Extra "--persp iso_SE_30_hires"`
3. Server (Docker, iGPU). `tools/deploy.ps1` copies the tree to `~/gpu-renderer-lab` and builds the images
   `toro-gpu-renderer:dev` (Godot + Mesa + cage) and `toro-gpu-tools:dev` (Python planner/uploader). Single render:
   ```
   WORLD_DIR=/path/to/region EXTRA_GROUPS=1001 DATA_DIR=$PWD/data OUT_DIR=/dev/shm/out \
     docker/run.sh --region-dir /world --tiles "0,2,8,8" --persp iso_SE_30_hires --out /out
   ```
   Several rectangles in one container start: `--tiles "0,0,8,8;8,0,8,8"` (outputs in `out/r{tx}_{ty}/`).
4. Whole-map job (direct TiDB port 4000 on the host):
   ```
   python3 tools/queue_runner.py --map-id 30002 --persp iso_SE_30_hires --extra-groups 1001 --zoom-max 7 \
       --world-dir /srv/minecraft/worlds/flat/region
   ```

## Dynmap-GPU feature map

| Dynmap-GPU | here |
| --- | --- |
| `render <region> <persp> tx ty w h out [min_y max_y]` | `render_tiles.gd --region-dir --persp --tiles --out --min-y --max-y` (several rects with `;`) |
| `run --persp --map-id --db-port --rate --zoom-max --mega` | `queue_runner.py --persp --map-id --rate --zoom-max --mega` |
| `--bbox`, `--limit`, `--skip-megas` | same names (`--limit` counts mega tiles) |
| `--only-missing`, `--count-missing` | same; checked per mega tile with point lookups |
| `--zoom-all`, `--zoom-since` | same; zoom levels are rebuilt once at the end from every changed tile (recorded in the plan dir) |
| `--cache` (scan cache) | `--scan-cache`; same binary format as Dynmap-GPU (`scripts/scan_world.gd`) |
| `--out DIR` (PNG copies) | `--keep-png DIR` |
| `scan`, `dump`, `column`, `topblocks`, `colblocks`, `encodetest` | `scan_world.gd --hist 1`, `dev_tools.gd <command>` |
| `DG_GPU` adapter pick | Godot `--gpu-index`; the container only sees the iGPU render node |
| regress / compare tools | `tools/compare-ref.ps1` (pixel match against `dg-run.exe render` on the same snapshot) |

Beyond Dynmap-GPU: runs unprivileged in a read-only container on the Intel iGPU at `nice 19`, waits for 0 players,
resumes from a state file, defers zoom-out to one final pass.

## Production safety

* Containers: 1 CPU at the lowest share, `nice 19`, `ionice idle`, 1 GB memory, read-only root and world mount,
  no capabilities, temporary files in `/dev/shm` (no SSD writes).
* The runner only works while `online.txt` (written by the proxy plugin, same convention as `dynmap-throttle.sh`)
  says 0 players and is fresh, and the 1-minute load is below 4; otherwise it waits. Only the batch in flight is finished.
* TiDB: point lookups `(MapID,x,y,zoom) IN (...)` only, writes rate-limited (`--rate`, default 8 MB/s), unchanged hashes
  are skipped, blank tiles delete the row. `--zoom-all` scans whole levels: run it only on request.

## Speed

8x8 mega tile (64 tiles, 1.14 M quads, `iso_SE_30_hires`): 1.3 s render + 0.25 s hash/WebP on the UHD 730 in the
low-priority container (pack 0.76 s, mesh 0.46 s, raster 0.05 s); the same area with the CPU mesher takes minutes.
GDScript NBT parsing (~1.7 ms/chunk) is now the largest cost.

## Why a Wayland compositor in the container

Godot's `--headless` has no RenderingDevice, and Xvfb has no DRI3 so Mesa falls back to llvmpipe (CPU).
`cage` with the wlroots headless backend gives Godot a Vulkan-presentable surface on the iGPU render node
(`docker/entrypoint.sh`). The Mobile renderer is used (Forward+ needs ~8 s more start-up).

## Known differences

* Entity blocks (chests, beds, signs, banners, skulls) and `uvlock` are not drawn, like Dynmap-GPU.
* Two GPUs differ in fixed-function blend rounding and depth interpolation: a handful of pixels per 16 k on translucent
  edges or coplanar leaves (the UHD 730 differs from the RTX in 22 of 16384 pixels on a forest tile).
* Imported resources (`.glsl`) must be re-imported after editing: `godot --headless --path . --import` (the Docker
  build and `compare-ref.ps1` do it).
