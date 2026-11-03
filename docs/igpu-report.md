# TORO server iGPU rendering report (2026-11-04)

## 1. Server survey (read-only)

| Item | Result |
|---|---|
| Host | production server, Ubuntu 26.04.1, kernel 7.0.0-42-generic, i3-12100, 8 threads, 46 GB RAM (about 11 GB available, swap 4 GB in use) |
| GPU | Intel UHD Graphics 730 (Alder Lake-S GT1, `8086:4692`), bound to **i915** (`xe` is loaded but not bound) |
| Device nodes | `/dev/dri/card0` (root:video), `/dev/dri/renderD128` (root:render, gid 993). User `serviceuser` is **not** in `render` |
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
* **Identical output on both GPUs**: the 4 test tiles have the same HashCode (e.g. `-8,4` = 54807240) on the RTX 3060
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
  (`~/gpu-renderer-lab`) and the `toro-gpu-renderer:dev` image (~600 MB).
* `docker/run.sh`: `--cpus 1 --cpu-shares 32`, `nice -n 19`, `ionice -c3`, 1 GB memory, `--read-only` root,
  world mounted read-only, no capabilities, `no-new-privileges`, auto-removed.
* World reads are limited to the region files that contain the requested tiles. Run when few players are online.
* `tools/queue_runner.py` only renders when the proxy's `online.txt` reports 0 players (fresh) and load1 < 4.
* TiDB writes (`tools/tiledb.py`): point lookups only, 8 MB/s default budget, hash skip, blank-tile delete. Verified
  end to end on scratch MapIDs 99001/99002 (rows deleted afterwards); its zoom-out matches the stored parents of
  MapID 30001 (14 of 15 sampled parents hash-identical, the 15th differs only in transparent pixels' RGB).

## 6. Open items

* Iso 30° view: Godot's rasteriser works offscreen on the iGPU (`scripts/iso_probe.gd`), but Dynmap-exact output needs
  the full model/lighting port.
* Entity blocks, `uvlock`, multi-layer water, non-cube models.
* A real production run has not been started: no map has been written other than the scratch MapIDs.
* NBT parsing is GDScript (~1.5 ms/chunk); a native module would remove it, but the GPU parts are no longer limiting.
