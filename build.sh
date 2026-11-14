#!/bin/sh
# Build the driver for Android (arm64) and package it into dist/.
#
# usage: ./build.sh [path-to-android-ndk]
#   The NDK can also come from ANDROID_NDK_HOME or ANDROID_NDK_ROOT. Linux only (WSL works):
#   the first stage builds host tools that need LLVM. macOS works too with MacPorts (meson,
#   ninja, glslangValidator, pkg-config, python3 with mako/packaging/pyyaml, and one LLVM
#   major version: llvm, clang, libclc and spirv-llvm-translator).
#   BUILD_DIR overrides the Android build directory (default: build-android-$API).
#   API overrides the Android API level (default: 31). Below 31 is experimental: the gralloc
#   backend's stubs are generated from Android 12 platform libraries, and old phones are only
#   tested when someone with one reports back. MIN_API overrides the meta.json floor.
#   GRALLOC=0 builds without the libui gralloc backend (see README.md, Gralloc).
#
# Two stages:
#   1. build-host: mesa_clc, vtn_bindgen2 and panfrost_compile, native, from this tree. They
#      compile the driver's OpenCL helper kernels (libpan, poly) at build time, so they have to be
#      built from the same compiler sources as the driver.
#   2. build-android: libvulkan_panfrost.so, cross-compiled with the NDK, using those tools,
#      after generating the link stubs for the gralloc backend (android/gralloc/mkstubs.py).
#
# Requires: meson, ninja, python3 (mako, packaging, pyyaml), pkg-config, glslangValidator, and for
# stage 1 LLVM with clang, libclc and the SPIR-V LLVM translator of one major version (Ubuntu:
# llvm-dev libclang-dev libclc-XX-dev libllvmspirvlib-XX-dev clang).
set -eu

cd "$(dirname "$0")"

NDK="${1:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
   echo "error: pass the Android NDK path or set ANDROID_NDK_HOME" >&2
   exit 1
fi

case "$(uname -s)" in
   Linux*) HOST=linux-x86_64 ;;
   Darwin*) HOST=darwin-x86_64 ;;
   *) echo "error: build on Linux, WSL or macOS (MacPorts LLVM); stage 1 needs LLVM" >&2; exit 1 ;;
esac

BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
API="${API:-31}"
if [ ! -x "$BIN/aarch64-linux-android$API-clang" ]; then
   echo "error: no API $API arm64 compiler in $BIN" >&2
   exit 1
fi

for tool in meson ninja python3 pkg-config glslangValidator; do
   if ! command -v "$tool" >/dev/null 2>&1; then
      echo "error: $tool not found in PATH" >&2
      exit 1
   fi
done

# --- stage 1: host tools ----------------------------------------------------------------------
HOSTB=build-host
# A host-only SPIRV-Tools (CI stages the dev packages under $SPIRV_HOST_PREFIX): mesa_clc
# links it, but only host-arch libraries exist, so it stays out of the cross build below.
OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
OLD_CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-}"
if [ -n "${SPIRV_HOST_PREFIX:-}" ]; then
   SPIRV_PC_DIR="$(find "$SPIRV_HOST_PREFIX" -name SPIRV-Tools.pc -printf '%h' -quit 2>/dev/null)"
   if [ -n "$SPIRV_PC_DIR" ]; then
      PKG_CONFIG_PATH="$SPIRV_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      export PKG_CONFIG_PATH
   else
      echo "warning: no SPIRV-Tools.pc under $SPIRV_HOST_PREFIX" >&2
   fi
   CMAKE_PREFIX_PATH="$SPIRV_HOST_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
   export CMAKE_PREFIX_PATH
fi
if [ ! -f "$HOSTB/build.ninja" ]; then
   # The SPIR-V translator's .pc file lives next to LLVM, not on pkg-config's default path
   # (MacPorts: /opt/local/libexec/llvm-*/lib/pkgconfig).
   if command -v llvm-config >/dev/null 2>&1; then
      PKG_CONFIG_PATH="$(llvm-config --libdir)/pkgconfig:${PKG_CONFIG_PATH:-}"
      export PKG_CONFIG_PATH
   fi
   meson setup "$HOSTB" \
      -Dbuildtype=debugoptimized \
      -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
      -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dplatforms= -Dllvm=enabled \
      -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled -Dgbm=disabled \
      -Dtools= -Dvideo-codecs= \
      -Dallow-fallback-for=libdrm --force-fallback-for=libdrm,expat,zlib \
      -Dlibdrm:default_library=static
fi
ninja -C "$HOSTB" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 \
   src/panfrost/clc/panfrost_compile
mkdir -p "$HOSTB/bin"
cp "$HOSTB/src/compiler/clc/mesa_clc" "$HOSTB/src/compiler/spirv/vtn_bindgen2" \
   "$HOSTB/src/panfrost/clc/panfrost_compile" "$HOSTB/bin/"
PATH="$PWD/$HOSTB/bin:$PATH"
export PATH
# Back to the ambient paths for the cross build below (see above).
if [ -z "$OLD_PKG_CONFIG_PATH" ]; then unset PKG_CONFIG_PATH; else PKG_CONFIG_PATH="$OLD_PKG_CONFIG_PATH"; export PKG_CONFIG_PATH; fi
if [ -z "$OLD_CMAKE_PREFIX_PATH" ]; then unset CMAKE_PREFIX_PATH; else CMAKE_PREFIX_PATH="$OLD_CMAKE_PREFIX_PATH"; export CMAKE_PREFIX_PATH; fi

# --- stage 2: the driver ----------------------------------------------------------------------
BUILD="${BUILD_DIR:-build-android-$API}"
mkdir -p "$BUILD" "$BUILD/pkgconfig-empty"

GRALLOC_DEPS=
if [ "${GRALLOC:-1}" != 0 ]; then
   # Headers from android/gralloc, stand-in libraries generated here: nothing from a device.
   GRALLOC_DEPS="$PWD/$BUILD/gralloc"
   rm -rf "$GRALLOC_DEPS"
   mkdir -p "$GRALLOC_DEPS"
   cp -r android/gralloc/include android/gralloc/abi_override "$GRALLOC_DEPS/"
   python3 android/gralloc/mkstubs.py "$BIN/aarch64-linux-android$API-clang" "$GRALLOC_DEPS/libs-a$API"
fi

cat > "$BUILD/cross.ini" <<EOF
[binaries]
c = '$BIN/aarch64-linux-android$API-clang'
cpp = '$BIN/aarch64-linux-android$API-clang++'
ar = '$BIN/llvm-ar'
strip = '$BIN/llvm-strip'
pkg-config = 'pkg-config'

[properties]
# Keep the host's .pc files out of the cross build.
pkg_config_libdir = ['$PWD/$BUILD/pkgconfig-empty']
cpp_link_args = ['-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

if [ ! -f "$BUILD/build.ninja" ]; then
   meson setup "$BUILD" --cross-file "$BUILD/cross.ini" \
      -Dbuildtype=debugoptimized -Db_ndebug=true \
      -Dplatforms=android -Dplatform-sdk-version="$API" -Dandroid-stub=true -Dandroid-strict=false \
      -Dandroid-libbacktrace=disabled \
      -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dvulkan-layers= -Dtools= -Dvideo-codecs= \
      -Dxclipse-gralloc-deps="$GRALLOC_DEPS" \
      -Dmesa-clc=system -Dprecomp-compiler=system \
      -Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
      -Dglx=disabled -Dgbm=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
      -Dallow-fallback-for=libdrm,perfetto --force-fallback-for=expat,libdrm,zlib \
      -Dlibdrm:default_library=static -Dexpat:default_library=static -Dzlib:default_library=static
else
   # An existing build directory follows GRALLOC too.
   meson configure "$BUILD" -Dxclipse-gralloc-deps="$GRALLOC_DEPS"
fi

ninja -C "$BUILD" src/panfrost/vulkan/libvulkan_panfrost.so

mkdir -p dist
"$BIN/llvm-strip" -o "$BUILD/libvulkan_panfrost.so" "$BUILD/src/panfrost/vulkan/libvulkan_panfrost.so"
MIN_API="${MIN_API:-$API}" python3 android/package.py "$BUILD/libvulkan_panfrost.so" dist
