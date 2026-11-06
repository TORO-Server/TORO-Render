# Three stages: (1) export the project to a .pck, (2) collect only the files needed at run time, (3) put them on scratch.
# The image has no package manager, no editor and no Vulkan driver other than Intel's. Build context: the repository root.

FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c AS pack

ARG GODOT_VERSION=4.7.2-stable

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*

# Godot is verified against the SHA512 sums published with the release. The editor imports and exports the project;
# the release export template (about half the size of the editor) runs it.
RUN set -eux; \
    base=https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}; \
    editor=Godot_v${GODOT_VERSION}_linux.x86_64.zip; \
    templates=Godot_v${GODOT_VERSION}_export_templates.tpz; \
    cd /tmp; \
    curl -fsSL -O "$base/$editor" -O "$base/$templates" -O "$base/SHA512-SUMS.txt"; \
    grep -E " ($editor|$templates)\$" SHA512-SUMS.txt | sha512sum -c -; \
    unzip -q "$editor"; \
    mv "Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot; \
    mkdir -p /out/usr/local/bin; \
    unzip -p "$templates" templates/linux_release.x86_64 > /out/usr/local/bin/godot; \
    chmod 755 /out/usr/local/bin/godot; \
    rm -f "$editor" "$templates" SHA512-SUMS.txt

WORKDIR /app
COPY project.godot export_presets.cfg main.tscn ./
COPY shaders ./shaders
COPY scripts ./scripts
RUN godot --headless --path /app --import >/dev/null 2>&1; \
    godot --headless --path /app --export-pack Linux /out/usr/local/bin/godot.pck \
 && test -s /out/usr/local/bin/godot.pck


FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c AS rootfs

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mesa-vulkan-drivers libvulkan1 libgl1 libegl1 cage xwayland busybox-static xkb-data \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libdecor-0-0 libxkbcommon0

COPY --from=pack /out/usr/local/bin/godot /usr/local/bin/godot
COPY docker/rootfs.sh /tmp/rootfs.sh
RUN sh /tmp/rootfs.sh


FROM scratch
COPY --from=rootfs /rootfs/ /
# Official release templates have no --main-pack: they load the .pck named after the binary, next to the binary.
COPY --from=pack /out/usr/local/bin/godot.pck /usr/local/bin/godot.pck
COPY --chmod=755 docker/entrypoint.sh docker/render.sh /app/docker/
ENV PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp
# Runs with any uid that may use the render node; see docker/compose.watch.yaml.
USER 65532:65532
ENTRYPOINT ["/app/docker/entrypoint.sh"]
