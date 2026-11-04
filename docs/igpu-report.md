# TORO server iGPU rendering report (2026-11-04)

## 1. Server survey (read-only)

| Item | Result |
|---|---|
| Host | production game server, Ubuntu 26.04.1, kernel 7.0.0-42-generic, i3-12100, 8 threads, 46 GB RAM (about 11 GB available, swap 4 GB in use) |
| GPU | Intel UHD Graphics 730 (Alder Lake-S GT1, `8086:4692`), bound to **i915** (`xe` is loaded but not bound) |
| Device nodes | `/dev/dri/card0` (root:video), `/dev/dri/renderD128` (root:render, gid 993). The service user is **not** in `render` |
| Host packages | `mesa-vulkan-drivers` + `libvulkan1` + `libgl1-mesa-dri` 26.0.8 installed; no `vulkaninfo`, `vainfo`, Xvfb on the host |
| Vulkan (checked in a throw-away `ubuntu:26.04` container) | Vulkan 1.4.335, `Intel(R) UHD Graphics 730 (ADL-S GT1)`, Mesa ANV 26.0.8, conformant 1.4. `maxImageDimension2D` 16384, `maxStorageBufferRange` 128 MB, shared memory 32 KB, `shaderInt64`, `shaderFloat16`. llvmpipe is listed as a second (CPU) device |
| Container access | `docker run --device /dev/dri/renderD128 --group-add 993` is sufficient (non-root user, `--cap-drop ALL`) |
| Production load | `toro-main` (Java) ~100% of one core, TiKV/TiDB/PD busy; the GPU itself is idle (no display session) |

Conclusion: the iGPU is usable for compute and rendering from containers without touching the host configuration.

## 2. Headless Godot on the iGPU

| Method | Result |
|---|---|
| `godot --headless` | The RenderingServer is a dummy; `RenderingDevice` (also local) is `null`. Unusable for GPU work |
| Xvfb + `--display-driver x11` | Mesa reports "No DRI3 support", Godot selects **llvmpipe** (CPU). Not the iGPU |
| `cage` (wlroots, `WLR_BACKENDS=headless`, `WLR_RENDERER=gles2`, `WLR_RENDER_DRM_DEVICE=renderD128`) + `--display-driver wayland --rendering-driver vulkan` | **`Using Device #0: Intel - Intel(R) UHD Graphics 730`**, local RenderingDevice available. This is what `docker/entrypoint.sh` does |

Godot: latest stable is **4.7.2** (2026-08-18; 4.8 is in beta). The official `linux.x86_64` zip runs on the server;
the Dockerfile verifies it with the release's `SHA512-SUMS.txt`.

## 3. Prototype results

* Flat tiles rendered by a GLSL compute shader through Godot's `RenderingDevice`.
* Accuracy against the Rust renderer (`Dynmap-GPU`, itself ~99.7% pixel-exact versus Dynmap on flat maps):
  99.85% exact pixels on 4 plain tiles, 94.9% on a 16-tile area with buildings and trees.
* **Identical output on both GPUs**: the 4 test tiles have the same HashCodes on the RTX 3060
  and on the server's UHD 730.
* Timing on the server iGPU (container limited to 1 CPU, lowest priority). The first version built block columns in
  GDScript (~47 ms/tile). **Column resolution now runs on the GPU** (`shaders/resolve_columns.glsl` reads the
  bit-packed palette/long arrays and light nibbles directly), with 0 differing columns versus the CPU builder on both
  GPUs. 16 tiles take ~90-107 ms cold (NBT parsing in GDScript is the rest), a whole 8x8-mega group of 256 tiles
  about 1.6 s plus 4 s container start-up. GPU dispatch + readback is ~1 ms/tile.
* Start-up: Forward+ initialisation took 8.5 s in the container; the Mobile renderer takes 2.5 s, so it is the default.
* Hash and lossless WebP encoding use Godot's `Image.save_webp_to_buffer(false, 1.0)`; sizes are similar to the Rust
  encoder for plain tiles.

## 4. BlueMap

BlueMap stores per-map `tiles/<lod>/x<N>/z<N>.prbm.gz` (hires: GZip-compressed binary 3D meshes, "PRBM", a modified
PRWM) plus lowres image tiles; the **browser** draws the meshes with WebGL. Server-side work is chunk parsing, block
model meshing and texture packing, which is CPU/memory-bound and not a rasterisation job, so an iGPU renderer would
not speed it up in a straightforward way. Image-like data (lowres heightmap/colour tiles) could be produced from the
same compute pipeline. Writing hires PRBM would need the exact format specification from the BlueMap source and is
not covered by this prototype. (Source of the format facts: BlueMap release notes/wiki; not verified against code.)

## 5. Safe operation on the production host

* Image build and runs happen in Docker; the host only gets the container, a work directory
  (`~/gpu-renderer-lab`) and the `toro-renderer:dev` image (~600 MB).
* `docker/run.sh`: `--cpus 1 --cpu-shares 32`, `nice -n 19`, `ionice -c3`, 1 GB memory, `--read-only` root,
  world mounted read-only, no capabilities, `no-new-privileges`, auto-removed.
* World reads are limited to the region files that contain the requested tiles. Run when few players are online.
* The `run` command only renders while nobody is online (live player feed and/or the proxy's presence file) and load1 < 4.
* TiDB writes (`scripts/store/`): point lookups only, 8 MB/s default budget, hash skip, blank-tile delete. Verified
  end to end on scratch MapIDs 99001/99002 (rows deleted afterwards); its zoom-out matches the stored parents of
  MapID 30001 (14 of 15 sampled parents hash-identical, the 15th differs only in transparent pixels' RGB).

## 6. Update 2026-11-04: full Dynmap-GPU feature parity

The Godot project now renders every perspective Dynmap-GPU does, from real block models:

* Mesh renderer: `state_registry.gd` (blockstates/models -> quads, float32-exact), `mesh_chunks.glsl` (GPU mesher),
  `raster.glsl` (orthographic raster, depth, Dynmap shading, translucent pass), `persp.gd` (Dynmap transform).
* Verified against `dg-run.exe render` on the same snapshots: `iso_S_90_lowres/hires` 100.00%, `iso_SE_30_lowres/hires`
  >= 99.99% over 8x8 mega tiles of the main and flat worlds (`tools/compare-ref.ps1`).
* Intel UHD 730 in the production container: an 8x8 oblique mega tile (1.14 M quads, 456 chunks) takes 1.3 s render
  (pack 0.76 s, GPU mesh 0.46 s, raster 0.05 s) plus 0.25 s hash/WebP at `nice 19`. The CPU reference mesher needs
  ~140 ms per chunk, i.e. minutes per mega tile; it is kept for verification (`--mesher cpu`, `--cmp-chunk`).
* Driver parity (the `run` command; originally a Python driver, see section 8): world scan with the Dynmap-GPU cache format,
  candidate tiles / mega tiles (840,035 tiles for flat/t, identical to Dynmap-GPU), `--only-missing`, `--count-missing`,
  `--zoom-all`, `--zoom-since`, `--bbox`, `--limit`, `--skip-megas`, resume state, deferred zoom-out. Verified on scratch
  MapID 99001 on the server (rows deleted afterwards).
* Differences measured on the iGPU: 22 of 16384 pixels of a forest tile differ from the RTX/Rust result
  (depth interpolation / blend rounding of a different GPU).

## 7. Open items

* Entity blocks, `uvlock` (neither is drawn by Dynmap-GPU either).
* `flat/t` and `main/t` were filled by Dynmap-GPU; the resident `watch` command only re-renders where the server saved chunks.
  Starting a full fill with `--count-missing` and then `--only-missing` is the safe way.
* NBT parsing is GDScript (~1.7 ms/chunk) and is now the largest cost; a native module would remove it.

## 8. Update: one runtime, no Python

Planner, tile store (a small MySQL client over `StreamPeerTCP`), zoom-out (a compute shader), the whole-map job, the
resident updater and the asset extraction from the client jar are GDScript now; `scripts/main.gd` is the single entry
point and the image no longer contains Python. Parity checks against the Python implementation that this replaced:

* `build-data` output is byte-identical (blocks, atlas, biomes, textures, block defaults; 4171 raw asset files).
* Plan for the flat world: 403,076 chunks -> 840,035 tiles / 14,289 mega tiles, same as the Python planner.
* Upload + zoom-out of two mega tiles (181 rows over zoom 0-5): every HashCode and every visible pixel equal to what the
  Python uploader produced. A second run changes nothing; `--zoom-all` finds every parent consistent.
* The zoom shader equals its CPU reference on random tiles, and a stored production parent is reproduced bit for bit from
  its stored children.

Found on the way: `TileCodec.crc_hash` used a signed 32-bit table and returned non-standard HashCodes (they did not equal
zlib's CRC32 over the same bytes). Fixed; tiles written before the fix carry the old value and are rewritten once, with
identical pixels, the next time they are rendered.
