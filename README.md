# TORO-GPU-Renderer

Dynmap-compatible map tile renderer for an integrated GPU (developed on an Intel UHD 730 with Mesa ANV Vulkan), written
as a single Godot 4.7 project: GDScript for everything, GLSL for the heavy lifting. It reads Minecraft Anvil worlds,
rasterises the real block models, and writes Dynmap's TiDB tile table (`dynmap_Tiles`) including the zoom-out levels.

It renders every Dynmap perspective the Rust renderer Dynmap-GPU supports (`iso_S_90_lowres/hires`,
`iso_SE_30_lowres/hires`). Against Dynmap-GPU on the same snapshots: 100.00% of the pixels on the flat perspectives and
>= 99.99% on the oblique ones (the few remaining pixels are blend rounding of a different GPU).
Hardware survey and decisions: [docs/igpu-report.md](docs/igpu-report.md).

## One entry point

```
godot --path . -s scripts/main.gd -- <command> [--option value] [--flag]
```

| command | what it does |
| --- | --- |
| `render` | tile rectangles -> PNG / lossless WebP / `manifest.json` (debugging, comparison with Dynmap-GPU) |
| `scan` | world scan cache: `(cx, cz, min_y, max_y)` of every non-empty chunk |
| `run` | whole-map job: scan, plan, render, upload, rebuild zoom-out levels; resumable |
| `watch` | resident updater for every map of a config: re-renders where the server saved chunks, closest to players first |
| `zoom` | rebuild zoom-out levels without rendering |
| `build-data` | extract blocks, models, textures, biomes from a Minecraft client jar |
| `dev` | debugging helpers: `dump`, `column`, `topblocks`, `colblocks`, `encodetest`, `zoomtest`, `dbtest` |

```
scripts/main.gd                 dispatch
scripts/cli/                    Args (command line), Term (log, waiting)
scripts/render/                 NBT, chunk decoding, block models -> quads, GPU mesher, rasteriser, perspectives
scripts/store/                  Mysql (wire protocol), TileStore (dynmap_Tiles), ZoomBuilder (+ shaders/zoom.glsl)
scripts/map/                    MapDef, ScanCache, Planner (tiles / mega tiles), AnvilChanges
scripts/job/                    RendererPool, Publisher, RunJob, WatchJob, Gate, LiveFeed
scripts/cmd/                    the commands above
shaders/                        mesh_chunks (mesher), raster, finish (un-premultiply), zoom (2x2 mean)
```

## Pipeline

```
.mca region -> scripts/render/nbt.gd, chunk_data.gd, gpu_world.gd   CPU: NBT parse, pack palette / long arrays / light as buffers
            -> shaders/mesh_chunks.glsl  (compute)                  GPU: block states -> quads (culling, smooth light, tint, fluids)
            -> shaders/raster.glsl       (vertex + fragment)        GPU: orthographic raster, depth, Dynmap shading, translucent pass
            -> shaders/finish.glsl       (compute)                  GPU: un-premultiply into tile images
            -> scripts/job/publisher.gd                             CRC32 HashCode, hash skip, lossless WebP, TiDB write
            -> shaders/zoom.glsl         (compute)                  GPU: parents = 2x2 mean of four children, per zoom level
```

* `state_registry.gd` bakes blockstates + models (multipart, variants, element rotation, rescale, face rotation, x/y
  state rotation) into quads with the same float32 arithmetic as Dynmap-GPU, so tie-breaks on 45° plants match.
* `persp.gd` is Dynmap's `IsoHDPerspective` world-to-map transform (double precision); the planner and the change
  detector use the same matrix.
* Translucent quads are sorted back to front on the CPU in float32-of-double like Dynmap-GPU, ties in chunk / block / quad
  order, so water and glass blend identically.
* `mesher.gd` is the CPU reference mesher (`render --mesher cpu`; `--cmp-chunk cx,cz` diffs it against the GPU one).
* `mysql.gd` is a small MySQL client (text protocol, `mysql_native_password`, no TLS): the database is on the same host or
  behind a tunnel, and blobs go in as `X'hex'` literals, so no driver is needed.

Tile `(tx,ty)` of `iso_S_90_lowres` covers block x in `[32*tx, 32*tx+32)` and z in `[-32*ty-32, -32*ty-1]`; image row 0 is
the north edge. HashCode = CRC32 over the ARGB ints little-endian (what Dynmap stores).

## Setup

1. Data from a Minecraft client jar (not committed). `--reports` is the data generator's `reports/blocks.json` (default
   block properties); takes ~10 s:
   ```
   godot --headless --path . -s scripts/main.gd -- build-data --jar client-26.3.jar --reports blocks.json --out data
   ```
2. Local run (any Vulkan GPU, a visible 64x64 window; `--gpu-index N` picks the device):
   `tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out -Extra "--persp iso_SE_30_hires"`
3. Container (Mesa + a headless Wayland compositor, see below): `docker build -f docker/Dockerfile -t toro-gpu-renderer:dev .`
   (`tools/deploy.ps1` ships a working tree to a server and builds there). One-off jobs go through `docker/run.sh`:
   ```
   WORLD_DIR=/path/to/region DATA_DIR=$PWD/data OUT_DIR=/dev/shm/out \
     docker/run.sh render --region-dir /world --tiles "0,2,8,8" --persp iso_SE_30_hires --out /out
   ```

## Maps config

`run` and `watch` read the maps from one JSON file ([docker/maps.example.json](docker/maps.example.json)):

```json
{
  "db": { "host": "127.0.0.1", "port": 4000, "user": "root", "database": "dynmap" },
  "live": "wss://map.example.net/up/ws",
  "maps": [ { "id": 30002, "region": "/worlds/flat/region", "persp": "iso_SE_30_hires", "zoom_max": 7 } ]
}
```

`id` is the Dynmap MapID. The Dynmap world of a map is looked up in `dynmap_Maps`. A database password, if any, goes
into the environment variable `DYNMAP_DB_PASSWORD`.

## Whole-map job

```
docker/run.sh run --map-id 30002 --config /config/maps.json --state-dir /state --only-missing
```

Scans the world once (cached in the state directory), plans the candidate tiles and mega tiles, then renders groups of
mega tiles while the server is quiet and uploads them. Zoom-out levels are rebuilt once at the end from the tiles that
changed. Options: `--bbox tx0,ty0,tx1,ty1`, `--limit N` (mega tiles), `--skip-megas N`, `--only-missing`,
`--count-missing` (dry run, no GPU needed), `--zoom-all` (re-check every parent; scans whole levels), `--zoom-since MS`,
`--per-run N`, `--keep-png DIR`, `--dry-run`, `--rate BYTES/S`, `--rescan`. It stops and resumes at any time.

Quiet rule: the 1-minute load stays below `--max-load` (4) and nobody is online (`--max-players 0`). Presence comes from
the live feed (below) and/or `--online-file FILE`, a file `"<online> <unix time>"` written by the proxy; a missing or
stale file, or a feed that is not connected, counts as busy. Only the batch in flight is finished when players join.

## Resident updater

```
docker compose -f docker/compose.watch.yaml up -d
```

One process for all maps of the config. Every cycle it reads the 8 KB header of each region file whose mtime moved: Anvil
keeps a "last saved" timestamp per chunk, so chunks saved since the previous cycle (terrain generated while players
explore, blocks placed or broken) are the changed ones, and nothing needs to hook into the game server. The changed chunks
and their neighbours are projected into mega tiles, queued (kept in the state directory), and worked off below
`--max-load` (2.5), `--max-megas` (4) per batch, written with the hash skip, followed by the zoom-out parents. The
renderer stays set up between batches.

**Player positions over WebSocket.** When the config has a `live` URL, a [`LiveFeed`](scripts/job/live_feed.gd) subscribes
to each watched Dynmap world on the map site's `/up/ws` and receives `{"type":"players","players":[{account, world, x, y,
z, ...}]}` whenever positions change (the players the map shows). The updater uses it to order the queue: mega tiles near
a player first (distance in mega tiles through the map's own projection), everything else in the order it was queued, and
anything waiting longer than `--stale-after-queue` seconds (600) goes ahead of all. `run` additionally treats a visible
player as "not quiet". The feed reconnects on its own and costs one idle socket per world.

## Production safety

* Containers: 1 CPU at the lowest share, `nice 19`, `ionice idle`, 1-1.5 GB memory, read-only root and world mount,
  no capabilities, temporary files in `/tmp` (tmpfs).
* The renderer works only below a load limit (and, for `run`, while nobody is online).
* TiDB: point lookups `(MapID,x,y,zoom) IN (...)` only, writes rate-limited (`--rate`, default 8 MB/s), unchanged hashes
  are skipped, blank tiles delete the row. `--zoom-all` scans whole levels: run it only on request.

## Speed

8x8 mega tile (64 tiles, 1.14 M quads, `iso_SE_30_hires`): 1.3 s render + 0.25 s hash/WebP on the UHD 730 in the
low-priority container (pack 0.76 s, mesh 0.46 s, raster 0.05 s); the same area with the CPU mesher takes minutes.
GDScript NBT parsing (~1.7 ms/chunk) is the largest cost.

## Why a Wayland compositor in the container

Godot's `--headless` has no RenderingDevice, and Xvfb has no DRI3 so Mesa falls back to llvmpipe (CPU).
`cage` with the wlroots headless backend gives Godot a Vulkan-presentable surface on the iGPU render node
(`docker/entrypoint.sh`). The Mobile renderer is used (Forward+ needs ~8 s more start-up). Commands that need no GPU
(`scan`, `build-data`, `dev`, `run --count-missing`) also work with `--headless`.

## Known differences

* Entity blocks (chests, beds, signs, banners, skulls) and `uvlock` are not drawn, like Dynmap-GPU.
* Two GPUs differ in fixed-function blend rounding and depth interpolation: a handful of pixels per 16 k on translucent
  edges or coplanar leaves (the UHD 730 differs from an RTX in 22 of 16384 pixels on a forest tile).
* Imported resources (`.glsl`) must be re-imported after editing: `godot --headless --path . --import` (the Docker
  build and `compare-ref.ps1` do it).
* Pixels that are fully transparent are stored as (0,0,0,0); tiles read back from the database get the same canonical
  value, so tiles rebuilt from stored children equal the ones built from fresh renders.
