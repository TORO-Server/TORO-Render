FROM ubuntu:26.04

ARG GODOT_VERSION=4.7.2-stable

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip \
      mesa-vulkan-drivers libvulkan1 libgl1 libegl1 cage \
      libx11-6 libxcursor1 libxinerama1 libxi6 libxrandr2 libxkbcommon0 \
      libwayland-client0 libwayland-cursor0 libwayland-egl1 libdecor-0-0 \
      libasound2t64 libpulse0 libdbus-1-3 libfontconfig1 libudev1 \
      python3 python3-numpy python3-pil python3-pymysql \
 && rm -rf /var/lib/apt/lists/*

# Godot is verified against the SHA512 sums published with the release.
RUN set -eux; \
    base=https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}; \
    f=Godot_v${GODOT_VERSION}_linux.x86_64.zip; \
    cd /tmp; \
    curl -fsSL -o "$f" "$base/$f"; \
    curl -fsSL -o SHA512-SUMS.txt "$base/SHA512-SUMS.txt"; \
    grep " $f\$" SHA512-SUMS.txt | sha512sum -c -; \
    unzip -q "$f"; \
    mv "Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot; \
    rm -f "$f" SHA512-SUMS.txt

WORKDIR /app
COPY project.godot ./
COPY shaders ./shaders
COPY scripts ./scripts
COPY docker ./docker
COPY tools ./tools
RUN chmod +x docker/*.sh && godot --headless --path /app --import >/dev/null 2>&1 && chmod -R a+rX /app

ENTRYPOINT ["/app/docker/entrypoint.sh"]
