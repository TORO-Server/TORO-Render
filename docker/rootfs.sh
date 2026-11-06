#!/bin/sh
# Copies what the renderer needs at run time into /rootfs: the programs, what they load, and the data they read.
# Everything else in the Ubuntu image (apt, perl, the other Vulkan drivers, documentation...) stays behind.
set -eu

root=/rootfs
lib=/usr/lib/x86_64-linux-gnu

# Programs, and the libraries that are opened with dlopen at run time, so ldd on the programs does not list them.
programs="
/usr/local/bin/godot
/usr/bin/cage
/usr/bin/Xwayland
/usr/bin/renice
/usr/bin/ionice
$lib/libvulkan.so.1
$lib/libvulkan_intel.so
$lib/libEGL_mesa.so.0
$lib/gbm/dri_gbm.so
$lib/libwayland-client.so.0
$lib/libwayland-cursor.so.0
$lib/libwayland-egl.so.1
$lib/libxkbcommon.so.0
$lib/libdecor-0.so.0
"

# Data read at run time.
data="
/usr/share/vulkan/icd.d/intel_icd.json
/usr/share/glvnd/egl_vendor.d/50_mesa.json
/usr/share/drirc.d
/usr/share/xkeyboard-config-2
/usr/share/X11/xkb
"

copy() {
    mkdir -p "$root$(dirname "$1")"
    # Regular files in place of symbolic links: only the names that ld.so asks for are copied.
    cp -L "$1" "$root$1"
}

for program in $programs; do
    copy "$program"
    missing=$(ldd "$program" | grep 'not found' || true)
    if [ -n "$missing" ]; then
        echo "$program: $missing" >&2
        exit 1
    fi
    for library in $(ldd "$program" | awk '$2 == "=>" { print $3 } $1 ~ /^\// { print $1 }'); do
        [ -e "$root$library" ] || copy "$library"
    done
done

for path in $data; do
    mkdir -p "$root$(dirname "$path")"
    cp -a "$path" "$root$(dirname "$path")/"
done

# A static shell and mkdir for the entry scripts (Ubuntu's busybox has no nice; renice and ionice are copied above).
copy /usr/bin/busybox
mkdir -p "$root/bin"
for applet in sh mkdir; do
    ln -s /usr/bin/busybox "$root/bin/$applet"
done

mkdir -p "$root/tmp"
chmod 1777 "$root/tmp"

# ld.so finds the libraries by name without a search of every directory.
mkdir -p "$root/etc"
ldconfig -r "$root"
